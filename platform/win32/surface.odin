#+build windows
package win32

// surface.odin — one HWND per platform.Surface: creation sized as a *logical*
// client area at the monitor's DPI, dark title bar following the system
// setting, min/max/fixed size, title, cursor, frame requests, geometry.

import "core:math"
import win "core:sys/windows"
import "baldr:platform"

DEFAULT_SIZE :: [2]f32{800, 600}

Surface :: struct {
	id:   platform.Surface,
	w:    ^Win32,
	hwnd: win.HWND,
	icon: win.HICON, // the app's own icon, set with WM_SETICON; ours to destroy
	awake: bool, // the app asks for the display to stay on while this window shows (idle.odin)
	kind: platform.Surface_Kind,
	// dark_app is what the toolkit said of the theme drawn in this window
	// (surface_set_dark): 0 nothing yet, so the caption follows the system's
	// app mode, 1 light, 2 dark.
	dark_app: u8,

	style, exstyle: u32,
	dpi:            u32,
	size_px:        [2]u32,
	logical_size:   [2]f32, // requested size; min = max for fixed_size
	min_size:       [2]f32,
	max_size:       [2]f32,
	fixed_size:     bool,

	maximized, activated, focused, minimized: bool,
	ime_on: bool, // composing is enabled for this window (ime.odin)
	// out on the whole screen, and where it was before (fullscreen.odin)
	fullscreen:  bool,
	placement:   win.WINDOWPLACEMENT,
	saved_style: i32,
	drop: rawptr, // ^Drop_Target while the window takes drops (drop.odin)
	live:            bool, // false while Windows sends creation/destruction messages: record state, emit nothing
	frame_requested: bool,
	frames_on:       bool, // wants an Ev_Frame per display frame (frames.odin)
	painted:         bool, // first Ev_Redraw went out (or a modal redraw ran): stop erasing the background
	in_size_move:    bool,
	configured:      bool,
	last_configure:  platform.Ev_Configure,

	cursor:         platform.Cursor,
	cursor_pic:     win.HCURSOR, // a picture the app drew, which wins over `cursor` (cursor_picture.odin)
	pointer_inside: bool, // Ev_Pointer_Enter sent, no Leave yet
	pointer_pos:    [2]f32, // last reported position; Windows repeats WM_MOUSEMOVE after capture/geometry changes
	tracking:       bool, // TrackMouseEvent(TME_LEAVE) armed
	buttons:        bit_set[platform.Mouse_Button],
	high_surrogate: u16,
}

@(private)
get_surface :: proc(w: ^Win32, s: platform.Surface) -> ^Surface {
	i := int(s) - 1
	if i < 0 || i >= len(w.surfaces) { return nil }
	return w.surfaces[i]
}

@(private)
scale_of :: #force_inline proc(s: ^Surface) -> f32 {
	return f32(s.dpi) / 96 if s.dpi != 0 else 1
}

@(private)
can_paint :: #force_inline proc(s: ^Surface) -> bool {
	return s.hwnd != nil && !s.minimized && s.size_px.x > 0 && s.size_px.y > 0
}

// ----------------------------------------------------------------- create

@(private)
surface_create :: proc(b: ^platform.Backend, desc: platform.Surface_Desc) -> (platform.Surface, bool) {
	w := data(b)
	w.ctx = context
	if desc.kind == .Lock || desc.kind == .Applet { return 0, false } // no session-lock or bar-applet equivalent on Windows (the toolkit opens an applet as a window)

	s := new(Surface, w.allocator)
	s.w = w
	s.kind = desc.kind
	s.cursor = .Default
	s.logical_size = desc.size
	if s.logical_size.x <= 0 { s.logical_size.x = DEFAULT_SIZE.x }
	if s.logical_size.y <= 0 { s.logical_size.y = DEFAULT_SIZE.y }
	s.min_size = desc.min_size
	s.max_size = desc.max_size
	s.fixed_size = desc.fixed_size

	switch desc.kind {
	case .Window:
		s.exstyle = win.WS_EX_APPWINDOW
		if desc.undecorated {
			// Client-drawn frame: no caption/borders. WS_MINIMIZEBOX keeps the
			// taskbar/Win+Down working; resizing is the client's business.
			s.style = win.WS_POPUP | win.WS_SYSMENU | win.WS_MINIMIZEBOX
			if !desc.fixed_size { s.style |= win.WS_MAXIMIZEBOX }
		} else {
			s.style = win.WS_OVERLAPPEDWINDOW
			if desc.fixed_size { s.style &~= win.WS_THICKFRAME | win.WS_MAXIMIZEBOX }
		}
	case .Layer:
		// Best effort for a panel/dock: undecorated tool window, topmost for
		// Top/Overlay, never activated unless the desc asks for keyboard input.
		s.style = win.WS_POPUP
		s.exstyle = win.WS_EX_TOOLWINDOW
		if desc.layer.level >= .Top { s.exstyle |= win.WS_EX_TOPMOST }
		if desc.layer.keyboard == .None { s.exstyle |= win.WS_EX_NOACTIVATE }
	case .Lock, .Applet:
		unreachable()
	}

	// Slot first: wnd_proc needs s.id for the (unemitted) creation messages.
	id: platform.Surface
	for slot, i in w.surfaces {
		if slot == nil {
			w.surfaces[i] = s
			id = platform.Surface(i + 1)
			break
		}
	}
	if id == 0 {
		append(&w.surfaces, s)
		id = platform.Surface(len(w.surfaces))
	}
	s.id = id

	class_name := win.utf8_to_wstring(CLASS_NAME)
	// An owner keeps a window above it and minimises it with it.
	owner: win.HWND
	if p := get_surface(w, desc.parent); p != nil && desc.kind == .Window do owner = p.hwnd
	hwnd := win.CreateWindowExW(
		s.exstyle, class_name, win.utf8_to_wstring(desc.title), s.style,
		win.CW_USEDEFAULT, win.CW_USEDEFAULT, i32(s.logical_size.x), i32(s.logical_size.y),
		owner, nil, w.hinstance, s)
	if hwnd == nil {
		w.surfaces[int(id) - 1] = nil
		free(s, w.allocator)
		return 0, false
	}
	// s.hwnd was set in WM_NCCREATE.
	if s.icon = icon_from_argb(desc.icon.w, desc.icon.h, desc.icon.argb); s.icon != nil {
		win.SendMessageW(hwnd, win.WM_SETICON, 1, win.LPARAM(uintptr(s.icon))) // ICON_BIG: Alt+Tab, the taskbar
		win.SendMessageW(hwnd, win.WM_SETICON, 0, win.LPARAM(uintptr(s.icon))) // ICON_SMALL: the title bar
	}

	// Now that the monitor is known, size the frame so the client area is the
	// requested logical size at this DPI.
	s.dpi = u32(win.GetDpiForWindow(hwnd))
	if s.dpi == 0 { s.dpi = 96 }
	client := px_size(s.logical_size, scale_of(s))
	rc := win.RECT{0, 0, client.x, client.y}
	win.AdjustWindowRectExForDpi(&rc, s.style, win.FALSE, s.exstyle, s.dpi)
	fw, fh := rc.right - rc.left, rc.bottom - rc.top
	flags: u32 = win.SWP_NOMOVE | win.SWP_NOZORDER | win.SWP_NOACTIVATE
	x, y: i32
	if desc.kind == .Layer {
		x, y, fw, fh = layer_rect(desc.layer, {fw, fh}, scale_of(s))
		flags &~= win.SWP_NOMOVE
	} else if p, want := desc.position.?; want && desc.kind == .Window {
		// Where it asked to open: the frame's corner in device pixels, as
		// `Output.pos`, SetWindowPos and GetWindowRect all have it, so a
		// saved position goes back exactly without creeping by a border.
		x, y = p.x, p.y
		flags &~= win.SWP_NOMOVE
	} else if desc.undecorated {
		// Popups ignore CW_USEDEFAULT (they land at 0,0): centre on the work area.
		mi := win.MONITORINFO{cbSize = size_of(win.MONITORINFO)}
		if win.GetMonitorInfoW(win.MonitorFromWindow(hwnd, .MONITOR_DEFAULTTONEAREST), &mi) {
			x = mi.rcWork.left + (mi.rcWork.right - mi.rcWork.left - fw) / 2
			y = mi.rcWork.top + (mi.rcWork.bottom - mi.rcWork.top - fh) / 2
			flags &~= win.SWP_NOMOVE
		}
	}
	win.SetWindowPos(hwnd, nil, x, y, fw, fh, flags)
	apply_dark_title_bar(s)

	show := win.SW_SHOW
	if desc.kind == .Layer && desc.layer.keyboard == .None { show = win.SW_SHOWNOACTIVATE }
	if desc.maximized && desc.kind == .Window { show = win.SW_SHOWMAXIMIZED } // a window coming back the way it was left
	win.ShowWindow(hwnd, show)

	// State recorded during creation (WM_SIZE / WM_ACTIVATE / WM_SETFOCUS
	// arrived with live = false); now announce it in the contract's order.
	crc: win.RECT
	win.GetClientRect(hwnd, &crc)
	s.size_px = {u32(max(crc.right - crc.left, 0)), u32(max(crc.bottom - crc.top, 0))}
	s.maximized = bool(win.IsZoomed(hwnd))
	s.live = true
	drop_register(w, s) // files dragged from Explorer land here (drop.odin)
	emit_configure(s)
	if s.focused { append(&w.queue, platform.Ev_Focus{surface = s.id, focused = true}) }
	return id, true
}

@(private)
px_size :: proc(logical: [2]f32, scale: f32) -> [2]i32 {
	return {i32(math.round(logical.x * scale)), i32(math.round(logical.y * scale))}
}

// layer_rect places a layer surface on the primary monitor per its anchors
// and margins (exclusive_zone is not honoured: that needs SHAppBarMessage).
@(private)
layer_rect :: proc(l: platform.Layer_Desc, frame: [2]i32, scale: f32) -> (x, y, cx, cy: i32) {
	mi := win.MONITORINFO{cbSize = size_of(win.MONITORINFO)}
	win.GetMonitorInfoW(win.MonitorFromPoint({0, 0}, .MONITOR_DEFAULTTOPRIMARY), &mi)
	area := mi.rcMonitor
	m := [4]i32{ // top, right, bottom, left in px
		i32(math.round(f32(l.margin[0]) * scale)), i32(math.round(f32(l.margin[1]) * scale)),
		i32(math.round(f32(l.margin[2]) * scale)), i32(math.round(f32(l.margin[3]) * scale)),
	}
	cx, cy = frame.x, frame.y
	switch {
	case .Left in l.anchor && .Right in l.anchor:
		x = area.left + m[3]
		cx = area.right - m[1] - x
	case .Right in l.anchor:
		x = area.right - m[1] - cx
	case .Left in l.anchor:
		x = area.left + m[3]
	case:
		x = area.left + (area.right - area.left - cx) / 2
	}
	switch {
	case .Top in l.anchor && .Bottom in l.anchor:
		y = area.top + m[0]
		cy = area.bottom - m[2] - y
	case .Bottom in l.anchor:
		y = area.bottom - m[2] - cy
	case .Top in l.anchor:
		y = area.top + m[0]
	case:
		y = area.top + (area.bottom - area.top - cy) / 2
	}
	return
}

// apply_dark_title_bar gives the caption the theme the app draws in the
// window (surface_set_dark), and the system's app mode until the toolkit has
// said. Fails harmlessly on Windows 10 builds before 20H1 (the attribute id
// differed).
@(private)
apply_dark_title_bar :: proc(s: ^Surface) {
	if s.hwnd == nil || s.style & win.WS_CAPTION != win.WS_CAPTION { return }
	is_dark := s.w.dark if s.dark_app == 0 else s.dark_app == 2
	dark: win.BOOL = win.TRUE if is_dark else win.FALSE
	win.DwmSetWindowAttribute(s.hwnd, u32(win.DWMWINDOWATTRIBUTE.DWMWA_USE_IMMERSIVE_DARK_MODE), &dark, size_of(dark))
}

// surface_set_dark is the toolkit saying whether the theme drawn in the
// window is dark (Backend.surface_set_dark): its caption follows that, not
// the system's app mode, so a dark app on a light desktop has a dark title
// bar.
@(private)
surface_set_dark :: proc(b: ^platform.Backend, id: platform.Surface, dark: bool) {
	s := get_surface(data(b), id)
	if s == nil { return }
	s.dark_app = 2 if dark else 1
	apply_dark_title_bar(s)
}

// emit_configure queues an Ev_Configure for the current state, skipping exact
// repeats (WM_SIZE + WM_DPICHANGED + WM_ACTIVATE often coincide).
@(private)
emit_configure :: proc(s: ^Surface) {
	if !s.live { return }
	scale := scale_of(s)
	ev := platform.Ev_Configure{
		surface   = s.id,
		size      = {f32(s.size_px.x) / scale, f32(s.size_px.y) / scale},
		size_px   = s.size_px,
		scale     = scale,
		maximized  = s.maximized,
		activated  = s.activated,
		fullscreen = s.fullscreen,
	}
	if s.configured && ev == s.last_configure { return }
	debugf(s.w, "configure out: %.0fx%.0f fullscreen=%v maximized=%v", ev.size.x, ev.size.y, ev.fullscreen, ev.maximized)
	s.configured = true
	s.last_configure = ev
	append(&s.w.queue, ev)
}

// ---------------------------------------------------------------- destroy

@(private)
surface_destroy :: proc(b: ^platform.Backend, id: platform.Surface) {
	w := data(b)
	w.ctx = context
	s := get_surface(w, id)
	if s == nil { return }
	s.live = false // WM_KILLFOCUS / WM_ACTIVATE / WM_DESTROY must not queue events for a dead surface
	idle_release(w, s) // a window that has gone does not hold the display on (idle.odin)
	cursor_picture_drop(s)
	drop_revoke(w, s)
	if s.hwnd != nil {
		if s.in_size_move { win.KillTimer(s.hwnd, RENDER_TIMER) }
		win.DestroyWindow(s.hwnd) // WM_NCDESTROY clears GWLP_USERDATA and s.hwnd
	}
	if s.icon != nil {
		win.DestroyIcon(s.icon)
		s.icon = nil
	}
	w.surfaces[int(id) - 1] = nil
	free(s, w.allocator)
}

// ------------------------------------------------------------- properties

@(private)
surface_set_title :: proc(b: ^platform.Backend, id: platform.Surface, title: string) {
	s := get_surface(data(b), id)
	if s == nil || s.hwnd == nil { return }
	win.SetWindowTextW(s.hwnd, win.utf8_to_wstring(title))
}

@(private)
surface_set_cursor :: proc(b: ^platform.Backend, id: platform.Surface, c: platform.Cursor) {
	s := get_surface(data(b), id)
	if s == nil { return }
	s.cursor = c
	cursor_picture_drop(s) // a shape replaces a picture, as the contract says
	// WM_SETCURSOR only fires on mouse movement; apply now if we own the pointer.
	if s.pointer_inside { win.SetCursor(s.w.cursors[c]) }
}

// surface_set_size gives a floating window a size of its own choosing (a
// window rolled up to its title bar, and back). `size` is the *client* area
// in logical pixels, so the frame is grown around it at this window's DPI,
// exactly as window creation does.
//
// A maximised or full-screen window is the desktop's to size, so it is left
// alone; {0, 0} hands the size back, which on Windows means doing nothing.
// No Ev_Configure from here: SetWindowPos sends WM_SIZE, which emits one.
@(private)
surface_set_size :: proc(b: ^platform.Backend, id: platform.Surface, size: [2]f32) {
	s := get_surface(data(b), id)
	if s == nil || s.hwnd == nil { return }
	if size.x <= 0 || size.y <= 0 { return } // {0, 0}: the desktop's again, which is what it already is
	if s.maximized || bool(win.IsZoomed(s.hwnd)) { return }
	client := px_size(size, scale_of(s))
	rc := win.RECT{0, 0, client.x, client.y}
	win.AdjustWindowRectExForDpi(&rc, s.style, win.FALSE, s.exstyle, s.dpi if s.dpi != 0 else 96)
	win.SetWindowPos(s.hwnd, nil, 0, 0, rc.right - rc.left, rc.bottom - rc.top,
		win.SWP_NOMOVE | win.SWP_NOZORDER | win.SWP_NOACTIVATE)
}

// activate asks for this window to be brought forward and given the
// keyboard. `token` is Wayland's xdg-activation token and has no equivalent
// here.
//
// Windows may refuse, and that is the contract working: the foreground lock
// lets only a process the person recently used take the foreground, and
// anyone else gets a flashing taskbar button. The return value is not
// checked — there is nothing else to try, and forcing past the lock is what
// badly-behaved applications do. A minimised window is restored first.
@(private)
activate :: proc(b: ^platform.Backend, id: platform.Surface, token: string) {
	s := get_surface(data(b), id)
	if s == nil || s.hwnd == nil { return }
	if bool(win.IsIconic(s.hwnd)) { win.ShowWindow(s.hwnd, win.SW_RESTORE) }
	win.SetForegroundWindow(s.hwnd)
}

@(private)
surface_request_frame :: proc(b: ^platform.Backend, id: platform.Surface) {
	s := get_surface(data(b), id)
	if s != nil { s.frame_requested = true }
}

@(private)
surface_geometry :: proc(b: ^platform.Backend, id: platform.Surface) -> (size: [2]f32, size_px: [2]u32, scale: f32) {
	s := get_surface(data(b), id)
	if s == nil { return {}, {}, 1 }
	scale = scale_of(s)
	return {f32(s.size_px.x) / scale, f32(s.size_px.y) / scale}, s.size_px, scale
}


// surface_native hands out the window's HWND, which is the only handle UI
// Automation can be answered through: a client's first question arrives as a
// WM_GETOBJECT on it, so the toolkit's bridge has to be able to find it.
// Nothing else may use it — see `platform.Backend.surface_native`.
surface_native :: proc(b: ^platform.Backend, id: platform.Surface) -> rawptr {
	s := get_surface(data(b), id)
	return rawptr(s.hwnd) if s != nil else nil
}

// surface_position is where the window's frame has its top-left corner, in
// virtual-screen device pixels — the plane `Output.pos` uses here, because
// Windows has no logical desktop plane (platform.odin). The frame's corner,
// not the client area's, so passing it back as `Surface_Desc.position`
// reopens the window exactly where it was rather than a border's width
// further each time.
surface_position :: proc(b: ^platform.Backend, id: platform.Surface) -> (pos: [2]i32, ok: bool) {
	w := data(b)
	s := get_surface(w, id)
	if s == nil || s.hwnd == nil do return {}, false
	rc: win.RECT
	if !win.GetWindowRect(s.hwnd, &rc) do return {}, false
	return {rc.left, rc.top}, true
}
