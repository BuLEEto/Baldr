#+build windows
package win32

// Package win32 is the Windows backend: it fills a `platform.Backend` using
// only core:sys/windows (user32 / dwmapi / advapi32 / gdi32 via the import
// libraries core already links; see sys.odin for the handful of procs core
// lacks).
//
//   b := win32.backend()
//   ok, why := b.init(b)
//   s, _ := b.surface_create(b, {title = "Hi", size = {640, 400}})
//   for ev in b.pump(b, -1) { ... }
//
// Threading: everything except `wake` must run on the thread that called
// `init` (Win32 windows are thread-affine). Events are produced by the window
// procedure while `pump` dispatches messages; they are appended to a queue the
// pump hands back. Strings inside events (Ev_Text) live in an arena reset at
// the start of every pump.
//
// Coordinates: logical pixels (client px / scale, scale = dpi / 96) everywhere
// except Ev_Configure.size_px. Per-monitor-v2 DPI awareness is requested in
// `init`; `WM_DPICHANGED` re-configures the surface with its new scale.

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import win "core:sys/windows"
import "core:time"
import vk "vendor:vulkan"
import "baldr:platform"

CLASS_NAME   :: "BaldrWindow"
WM_APP_WAKE  :: win.WM_APP + 1 // posted to the message-only window by `wake`
RENDER_TIMER :: 1              // SetTimer id used inside the modal size/move loop

// Win32 is the backend state; `platform.Backend.data` points at it and the
// Backend itself is embedded so `backend()` needs one allocation.
Win32 :: struct {
	backend:   platform.Backend,
	allocator: mem.Allocator,
	ctx:       runtime.Context, // the toolkit's context, captured on entry; wnd_proc runs under it

	// The desktop's UI font family, held here because `Ev_Theme`'s strings
	// are the backend's until the next pump and this is the only one win32
	// fills. NUL-padded UTF-8.
	ui_font:        [128]u8,

	hinstance:      win.HINSTANCE,
	wake_hwnd:      win.HWND, // HWND_MESSAGE child; only ever receives WM_APP_WAKE
	awareness:      Dpi_Awareness,
	per_monitor_v2: bool,
	cursors:        [platform.Cursor]win.HCURSOR,
	bg_brush:       win.HBRUSH, // paints the client area until the first Ev_Redraw
	dark:           bool,       // AppsUseLightTheme == 0 at init / last WM_SETTINGCHANGE
	debug:          bool,       // BALDR_WIN32_DEBUG=1
	awake:          bool,       // the display is being held on for some window (idle.odin)

	locale:   platform.Locale,          // the regional settings, read once at init (locale.odin); strings owned
	screens:  [dynamic]platform.Output, // the monitors, re-read on WM_DISPLAYCHANGE (outputs.odin); strings owned
	surfaces: [dynamic]^Surface, // slot i is platform.Surface(i + 1); nil = free
	queue:    [dynamic]platform.Event, // being filled (wnd_proc appends here)
	out:      [dynamic]platform.Event, // handed back by the last pump
	text:     virtual.Arena,           // Ev_Text storage, reset per pump

	png_format:    win.UINT, // the clipboard's number for "PNG", asked for once (clipboard_typed.odin)
	html_format:   win.UINT, // …and for "HTML Format", which is CF_HTML (clipboard_html.odin)
	ole_started:   bool,     // OLE is up for this thread, for drops (drop.odin)
	drop_held:     rawptr,   // ^Drop_Target holding a drop's paths until drag_finish
	watch_dirs:         [dynamic]^Watch_Dir, // directories being read for changes (watch.odin)
	watches:            [dynamic]Watch,      // one per token, filtered to a name for a file watch
	last_refresh_count: u64,       // the DWM refresh the frame clock last reported (frames.odin)
	next_frame_at:      time.Tick,  // …or when the next one is due, on the fallback path
	dwm_warned:         bool,       // the one line about DWM refusing has been said
	woken:         bool, // a WM_APP_WAKE was seen during this pump
	tray:          [dynamic]Tray_Entry, // the notification area (tray.odin)
	next_tray_uid: win.UINT,
	theme_pending: bool, // emit one Ev_Theme at the end of this pump
	serial:        u32,  // Ev_Pointer_Button.serial

	notifs:         [dynamic]Notif, // notifications showing (notify.odin)
	next_notif_uid: win.UINT,       // the shell's number for the next one
	notify_icon:    win.HICON,      // the shell's default, loaded once; a balloon needs a shown icon
}

// backend allocates and fills a Backend for Windows. Call `init` before
// anything else; `shutdown` frees everything including the Backend itself.
backend :: proc(allocator := context.allocator) -> ^platform.Backend {
	w := new(Win32, allocator)
	w.allocator = allocator
	w.backend = platform.Backend{
		name                   = "win32",
		data                   = w,
		init                   = init,
		shutdown               = shutdown,
		vk_instance_extensions = vk_instance_extensions,
		vk_create_surface      = vk_create_surface,
		drawable_create        = drawable_create,
		surface_create         = surface_create,
		surface_destroy        = surface_destroy,
		surface_set_title      = surface_set_title,
		surface_set_dark       = surface_set_dark,
		surface_set_cursor     = surface_set_cursor,
		surface_set_cursor_image = surface_set_cursor_image,
		surface_request_frame  = surface_request_frame,
		keep_awake             = keep_awake,
		frames_wanted          = frames_wanted,
		watch                  = watch,
		unwatch                = unwatch,
		surface_geometry       = surface_geometry,
		surface_position       = surface_position,
		surface_native         = surface_native,
		surface_set_fullscreen = surface_set_fullscreen,
		surface_post_close     = surface_post_close,
		key_name               = key_name,
		ime_set                = ime_set,
		surface_set_size       = surface_set_size,
		activate               = activate,
		outputs                = outputs,
		locale                 = locale,
		pump                   = pump,
		wake                   = wake,
		system_theme           = system_theme,
		clipboard_get          = clipboard_get,
		clipboard_set          = clipboard_set,
		open_url               = open_url,
		notify                 = notify,
		notify_close           = notify_close,
		tray_set               = tray_set,
		tray_remove            = tray_remove,
		open_path              = open_path,
		clipboard_types        = clipboard_types,
		clipboard_get_data     = clipboard_get_data,
		clipboard_set_data     = clipboard_set_data,
		drag_start             = drag_start,
		drag_accept            = drag_accept,
		drag_receive           = drag_receive,
		drag_finish            = drag_finish,
		file_dialog            = file_dialog,
	}
	return &w.backend
}

@(private)
data :: #force_inline proc(b: ^platform.Backend) -> ^Win32 {
	return (^Win32)(b.data)
}

// ------------------------------------------------------------------- init

@(private)
init :: proc(b: ^platform.Backend) -> (ok: bool, why: string) {
	w := data(b)
	w.ctx = context

	// Per-monitor-v2 must be requested before any window exists. It fails with
	// ERROR_ACCESS_DENIED when a manifest (or the session) already set an
	// awareness; that is not fatal — query what we actually have and carry on.
	win.SetProcessDpiAwarenessContext(win.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)
	ctx := win.GetThreadDpiAwarenessContext()
	w.awareness = GetAwarenessFromDpiAwarenessContext(ctx)
	w.per_monitor_v2 = bool(AreDpiAwarenessContextsEqual(ctx, win.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2))

	w.surfaces = make([dynamic]^Surface, w.allocator)
	w.queue = make([dynamic]platform.Event, w.allocator)
	w.out = make([dynamic]platform.Event, w.allocator)
	if virtual.arena_init_growing(&w.text) != nil {
		return false, "win32: text arena allocation failed"
	}

	w.hinstance = win.HINSTANCE(win.GetModuleHandleW(nil))
	w.debug = os.get_env("BALDR_WIN32_DEBUG", context.temp_allocator) == "1"
	w.dark = !apps_use_light_theme()
	outputs_refresh(w) // the screens, before any window asks which one it is on
	w.locale = locale_read(w.allocator)
	w.bg_brush = win.CreateSolidBrush(0x00202020 if w.dark else 0x00F3F3F3) // COLORREF is 0x00BBGGRR
	load_cursors(w)

	class_name := win.utf8_to_wstring(CLASS_NAME)
	wc := win.WNDCLASSEXW{
		cbSize        = size_of(win.WNDCLASSEXW),
		style         = 0, // no CS_H/VREDRAW: Vulkan repaints, WM_ERASEBKGND is answered below
		lpfnWndProc   = wnd_proc,
		hInstance     = w.hinstance,
		hCursor       = w.cursors[.Default],
		// an icon compiled into the program (`-resource:app.rc`, id 1); nil: the system's
		hIcon         = win.LoadIconW(w.hinstance, cstring16(win.MAKEINTRESOURCEW(1))),
		hbrBackground = nil,
		lpszClassName = class_name,
	}
	if win.RegisterClassExW(&wc) == 0 {
		return false, "win32: RegisterClassExW failed"
	}

	// Message-only window: the target of `wake` from other threads. It has no
	// Surface behind it, so wnd_proc passes everything to DefWindowProcW.
	w.wake_hwnd = win.CreateWindowExW(0, class_name, nil, 0, 0, 0, 0, 0, win.HWND_MESSAGE, nil, w.hinstance, nil)
	if w.wake_hwnd == nil {
		win.UnregisterClassW(class_name, w.hinstance)
		return false, "win32: CreateWindowExW (message window) failed"
	}
	return true, ""
}

@(private)
shutdown :: proc(b: ^platform.Backend) {
	w := data(b)
	w.ctx = context
	for s, i in w.surfaces {
		if s != nil { surface_destroy(b, platform.Surface(i + 1)) }
	}
	tray_shutdown(w)   // an icon left in the notification area outlives the app
	notify_shutdown(w) // before the window they hang off goes
	if w.wake_hwnd != nil { win.DestroyWindow(w.wake_hwnd) }
	win.UnregisterClassW(win.utf8_to_wstring(CLASS_NAME), w.hinstance)
	if w.bg_brush != nil { win.DeleteObject(win.HGDIOBJ(w.bg_brush)) }
	virtual.arena_destroy(&w.text)
	outputs_shutdown(w)
	watch_shutdown(w)
	locale_free(&w.locale, w.allocator)
	delete(w.surfaces)
	delete(w.queue)
	delete(w.out)
	free(w, w.allocator)
}

@(private)
load_cursors :: proc(w: ^Win32) {
	// IDC_* are typed cstring in core; LoadCursorW wants LPCWSTR of the same integer.
	idc :: proc(id: rawptr) -> win.HCURSOR { return win.LoadCursorW(nil, win.LPCWSTR(id)) }
	arrow := idc(win._IDC_ARROW)
	w.cursors = {
		.Default     = arrow,
		.Pointer     = idc(win._IDC_HAND),
		.Text        = idc(win._IDC_IBEAM),
		.Crosshair   = idc(win._IDC_CROSS),
		.Move        = idc(win._IDC_SIZEALL),
		.Not_Allowed = idc(win._IDC_NO),
		.Grab        = idc(win._IDC_HAND),    // Windows has no open/closed hand
		.Grabbing    = idc(win._IDC_SIZEALL),
		.Resize_NS   = idc(win._IDC_SIZENS),
		.Resize_EW   = idc(win._IDC_SIZEWE),
		.Resize_NESW = idc(win._IDC_SIZENESW),
		.Resize_NWSE = idc(win._IDC_SIZENWSE),
		.Wait        = idc(win._IDC_WAIT),
		.Progress    = idc(win._IDC_APPSTARTING),
		.Help        = idc(win._IDC_HELP),
		.Hidden      = nil,
		.Picture     = arrow, // until a picture is set: that is its own HCURSOR (cursor_picture.odin)
	}
	for c in platform.Cursor {
		if c != .Hidden && w.cursors[c] == nil { w.cursors[c] = arrow }
	}
}

// ----------------------------------------------------------------- vulkan

@(private)
VK_EXTENSIONS := [?]cstring{"VK_KHR_surface", "VK_KHR_win32_surface"}

@(private)
vk_instance_extensions :: proc(b: ^platform.Backend) -> []cstring {
	return VK_EXTENSIONS[:]
}

// vk_create_surface: vendor:vulkan's instance procs were loaded by the gpu
// package (vk.load_proc_addresses_instance), so CreateWin32SurfaceKHR is ready.
@(private)
vk_create_surface :: proc(b: ^platform.Backend, s: platform.Surface, instance: vk.Instance) -> (vk.SurfaceKHR, bool) {
	w := data(b)
	surf := get_surface(w, s)
	if surf == nil || surf.hwnd == nil || vk.CreateWin32SurfaceKHR == nil { return 0, false }
	info := vk.Win32SurfaceCreateInfoKHR{
		sType     = .WIN32_SURFACE_CREATE_INFO_KHR,
		hinstance = vk.HINSTANCE(w.hinstance),
		hwnd      = vk.HWND(surf.hwnd),
	}
	out: vk.SurfaceKHR
	if vk.CreateWin32SurfaceKHR(instance, &info, nil, &out) != .SUCCESS { return 0, false }
	return out, true
}

// ------------------------------------------------------------------- pump

// pump: wait (MsgWaitForMultipleObjectsEx, so a future IOCP / event handle
// slots in beside the message queue), drain with PeekMessage/Translate/
// Dispatch, then append Ev_Theme / Ev_Redraw for anything marked. Returns as
// soon as at least one event exists, `wake` was called, or the timeout passed.
// A pending frame request makes the wait a poll so Ev_Redraw goes out at once;
// the FIFO swapchain then paces the loop.
@(private)
pump :: proc(b: ^platform.Backend, timeout_ms: i32) -> []platform.Event {
	w := data(b)
	w.ctx = context
	clear(&w.out)
	// What the last pump returned is the caller's no longer. Events queued
	// since, outside a pump (a file dialog's paths, which a command asks for
	// between pumps), hold strings in the same arena: then it is freed at the
	// next pump instead.
	if len(w.queue) == 0 do virtual.arena_free_all(&w.text)
	w.woken = false

	start := time.tick_now()
	for {
		wait_ms := timeout_ms
		if frame_pending(w) || w.theme_pending || len(w.queue) > 0 {
			wait_ms = 0
		} else if timeout_ms > 0 {
			elapsed := i32(time.duration_milliseconds(time.tick_since(start)))
			wait_ms = max(timeout_ms - elapsed, 0)
		}
		// While a surface wants frames the wait never runs past the next
		// vblank, so the clock ticks at the screen's rate (frames.odin).
		clock: Frame_Clock
		ticking := frames_any(w)
		if ticking {
			clock = frame_clock_read(w)
			if wait_ms != 0 {
				due := frame_clock_wait_ms(clock)
				wait_ms = due if wait_ms < 0 else min(wait_ms, due)
			}
		}
		// The watched directories' events wait alongside the message queue,
		// so a file changing wakes the loop rather than being noticed the
		// next time something else does (watch.odin).
		handles: [MAX_WAIT]win.HANDLE
		nh := watch_handles(w, handles[:])
		timed_out := false
		if wait_ms != 0 {
			t := win.INFINITE if wait_ms < 0 else win.DWORD(wait_ms)
			p := &handles[0] if nh > 0 else nil
			// The return value is only read for the timeout: which handle
			// fired does not matter, because every directory is polled below.
			timed_out = MsgWaitForMultipleObjectsEx(nh, p, t, win.QS_ALLINPUT, MWMO_INPUTAVAILABLE) == win.WAIT_TIMEOUT
		}
		drain(w)
		watch_drain(w, &w.queue, virtual.arena_allocator(&w.text))
		if ticking do frame_clock_tick(w, frame_clock_read(w)) // re-read: the wait moved us on
		flush_marks(w)
		if len(w.queue) > 0 || w.woken || timed_out || wait_ms == 0 { break }
	}
	w.queue, w.out = w.out, w.queue
	return w.out[:]
}

@(private)
drain :: proc(w: ^Win32) {
	msg: win.MSG
	for win.PeekMessageW(&msg, nil, 0, 0, win.PM_REMOVE) {
		if msg.message == WM_APP_WAKE && msg.hwnd == w.wake_hwnd {
			w.woken = true
			continue
		}
		// The balloon's callbacks go to the message-only window, whose
		// wnd_proc has no Surface behind it and passes everything on
		// (notify.odin).
		if msg.message == WM_APP_NOTIFY && notify_message(w, msg.hwnd, msg.wParam, msg.lParam) do continue
		// The tray icon's callbacks come to the same window (tray.odin).
		if msg.message == WM_APP_TRAY_MSG && tray_message(w, msg.wParam, msg.lParam) do continue
		if msg.message == win.WM_QUIT {
			append(&w.queue, platform.Ev_Quit{})
			continue
		}
		win.TranslateMessage(&msg)
		win.DispatchMessageW(&msg)
	}
}

// debugf traces what the backend did, under BALDR_WIN32_DEBUG=1 — the
// Windows half of BALDR_WAYLAND_DEBUG.
@(private)
debugf :: proc(w: ^Win32, format: string, args: ..any) {
	if !w.debug do return
	fmt.eprintf("baldr/win32: ")
	fmt.eprintfln(format, ..args)
}

@(private)
frame_pending :: proc(w: ^Win32) -> bool {
	for s in w.surfaces {
		if s != nil && s.frame_requested && can_paint(s) { return true }
	}
	return false
}

@(private)
flush_marks :: proc(w: ^Win32) {
	if w.theme_pending {
		w.theme_pending = false
		append(&w.queue, system_theme(&w.backend))
	}
	for s in w.surfaces {
		if s != nil && s.frame_requested && can_paint(s) {
			s.frame_requested = false
			s.painted = true
			append(&w.queue, platform.Ev_Redraw{surface = s.id})
		}
	}
}

// wake: safe from any thread. PostMessage to the message-only window rather
// than PostThreadMessage, which modal loops drop.
@(private)
wake :: proc(b: ^platform.Backend) {
	w := data(b)
	if w.wake_hwnd != nil { win.PostMessageW(w.wake_hwnd, WM_APP_WAKE, 0, 0) }
}

// ------------------------------------------------------------------ theme

@(private)
reg_dword :: proc(key: win.HKEY, subkey, value: string) -> (v: u32, ok: bool) {
	size: win.DWORD = size_of(v)
	st := win.RegGetValueW(key, win.utf8_to_wstring(subkey), win.utf8_to_wstring(value), win.RRF_RT_REG_DWORD, nil, &v, &size)
	return v, st == 0
}

// apps_use_light_theme reads the "Choose your default app mode" toggle;
// missing value (older Windows 10) = light.
@(private)
apps_use_light_theme :: proc() -> bool {
	v, ok := reg_dword(win.HKEY_CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`, "AppsUseLightTheme")
	return !ok || v != 0
}

@(private)
system_theme :: proc(b: ^platform.Backend) -> platform.Ev_Theme {
	t := platform.Ev_Theme{text_scale = 1}
	t.dark = !apps_use_light_theme()

	// Accent: DWM\AccentColor is the user's accent (0xAABBGGRR); the DWM
	// colorization colour (0xAARRGGBB) is the fallback (frame colour, which
	// only equals the accent when "show accent on title bars" is on).
	if c, ok := reg_dword(win.HKEY_CURRENT_USER, `Software\Microsoft\Windows\DWM`, "AccentColor"); ok {
		t.has_accent = true
		t.accent = {f32(c & 0xff) / 255, f32((c >> 8) & 0xff) / 255, f32((c >> 16) & 0xff) / 255, 1}
	} else {
		color: win.DWORD
		opaque: win.BOOL
		if DwmGetColorizationColor(&color, &opaque) >= 0 {
			t.has_accent = true
			t.accent = {f32((color >> 16) & 0xff) / 255, f32((color >> 8) & 0xff) / 255, f32(color & 0xff) / 255, 1}
		}
	}

	anim: win.BOOL = win.TRUE
	if win.SystemParametersInfoW(win.SPI_GETCLIENTAREAANIMATION, 0, &anim, 0) {
		t.reduce_motion = anim == win.FALSE
	}
	hc := HIGHCONTRASTW{cbSize = size_of(HIGHCONTRASTW)}
	if win.SystemParametersInfoW(win.SPI_GETHIGHCONTRAST, hc.cbSize, &hc, 0) {
		t.high_contrast = hc.dwFlags & HCF_HIGHCONTRASTON != 0
	}
	// A contrast theme is colours the person chose (yellow on black, say),
	// so the toolkit draws in them rather than in its own contrast theme.
	if t.high_contrast do t.palette = sys_palette()
	// Settings > Accessibility > Text size (100..225 %).
	if ts, ok := reg_dword(win.HKEY_CURRENT_USER, `Software\Microsoft\Accessibility`, "TextScaleFactor"); ok && ts >= 100 {
		t.text_scale = f32(ts) / 100
	}
	// Settings > Personalisation > Colours > Transparency effects. There is
	// no SystemParametersInfo for this one — it is a registry value and
	// nothing else — so an absent key means the default, which is on.
	if tr, ok := reg_dword(win.HKEY_CURRENT_USER,
		`Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`, "EnableTransparency"); ok {
		t.reduce_transparency = tr == 0
	}
	t.font_family = ui_font_family(data(b))
	// No monospace font: Windows has no system-wide setting for one, so
	// `mono_family` stays "" and the toolkit keeps its embedded face.
	return t
}

// sys_palette is the active contrast theme's colours, from GetSysColor:
// a COLORREF is 0x00BBGGRR.
sys_palette :: proc() -> (p: platform.System_Palette) {
	COLOR_WINDOW, COLOR_WINDOWTEXT, COLOR_HIGHLIGHT, COLOR_HIGHLIGHTTEXT :: 5, 8, 13, 14
	COLOR_BTNFACE, COLOR_GRAYTEXT, COLOR_BTNTEXT, COLOR_HOTLIGHT :: 15, 17, 18, 26
	rgb :: proc(index: i32) -> [4]f32 {
		c := win.GetSysColor(index)
		return {f32(c & 0xff) / 255, f32((c >> 8) & 0xff) / 255, f32((c >> 16) & 0xff) / 255, 1}
	}
	p.ok = true
	p.window, p.window_text = rgb(COLOR_WINDOW), rgb(COLOR_WINDOWTEXT)
	p.view, p.view_text = p.window, p.window_text
	p.button, p.button_text = rgb(COLOR_BTNFACE), rgb(COLOR_BTNTEXT)
	p.selection, p.selection_text = rgb(COLOR_HIGHLIGHT), rgb(COLOR_HIGHLIGHTTEXT)
	p.link, p.inactive_text = rgb(COLOR_HOTLIGHT), rgb(COLOR_GRAYTEXT)
	return
}

// ui_font_family is the face Windows draws its own UI in
// (NONCLIENTMETRICS' lfMessageFont — the message-box font, which is the one
// Microsoft's own guidance points at for application text). The family only:
// `lfHeight` is a size, and a size here would be a second text scale on top
// of the Accessibility one.
@(private)
ui_font_family :: proc(w: ^Win32) -> string {
	if w.ui_font[0] != 0 do return padded(w.ui_font[:]) // asked once; it changes with a theme event
	m := win.NONCLIENTMETRICSW{cbSize = size_of(win.NONCLIENTMETRICSW)}
	if !win.SystemParametersInfoW(win.SPI_GETNONCLIENTMETRICS, m.cbSize, &m, 0) do return ""
	face := m.lfMessageFont.lfFaceName
	n := 0
	for n < len(face) && face[n] != 0 do n += 1
	if n == 0 do return ""
	utf8, err := win.utf16_to_utf8(face[:n], context.temp_allocator)
	if err != nil || len(utf8) == 0 do return ""
	cut := min(len(utf8), len(w.ui_font) - 1)
	copy(w.ui_font[:cut], utf8[:cut])
	w.ui_font[cut] = 0
	return padded(w.ui_font[:])
}

@(private)
padded :: proc(b: []u8) -> string {
	for c, i in b do if c == 0 do return string(b[:i])
	return string(b)
}

// -------------------------------------------------------------- clipboard

// open_clipboard retries briefly: another process may hold the clipboard.
@(private)
open_clipboard :: proc() -> bool {
	for _ in 0 ..< 8 {
		if win.OpenClipboard(nil) { return true }
		win.Sleep(5)
	}
	return false
}

@(private)
clipboard_get :: proc(b: ^platform.Backend, allocator := context.allocator) -> (string, bool) {
	if !open_clipboard() { return "", false }
	defer win.CloseClipboard()
	h := win.GetClipboardData(win.CF_UNICODETEXT)
	if h == nil { return "", false }
	return global_text(h, allocator)
}

@(private)
clipboard_set :: proc(b: ^platform.Backend, text: string) -> bool {
	utf16 := win.utf8_to_utf16(text, context.temp_allocator)
	h := win.GlobalAlloc(win.GMEM_MOVEABLE, win.SIZE_T((len(utf16) + 1) * size_of(u16)))
	if h == nil { return false }
	p := win.GlobalLock(win.HGLOBAL(h))
	if p == nil {
		win.GlobalFree(h)
		return false
	}
	dst := ([^]u16)(p)
	copy(dst[:len(utf16)], utf16)
	dst[len(utf16)] = 0
	win.GlobalUnlock(win.HGLOBAL(h))

	if !open_clipboard() {
		win.GlobalFree(h)
		return false
	}
	defer win.CloseClipboard()
	win.EmptyClipboard()
	if win.SetClipboardData(win.CF_UNICODETEXT, win.HANDLE(h)) == nil {
		win.GlobalFree(h) // ownership only moves on success
		return false
	}
	return true
}

// drawable_create: this backend's renderer draws into a VkSurfaceKHR, so the
// neutral handle is one. `renderer` is the VkInstance it needs to make it.
@(private)
drawable_create :: proc(b: ^platform.Backend, s: platform.Surface, renderer: rawptr) -> (uintptr, bool) {
	surf, ok := vk_create_surface(b, s, vk.Instance(renderer))
	return uintptr(surf), ok
}
