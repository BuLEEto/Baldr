#+build darwin
package cocoa

// Package cocoa is the macOS backend: it fills a `platform.Backend` using
// AppKit and the objc runtime, with no Vulkan anywhere — macOS is drawn by
// the native Metal renderer rather than MoltenVK.
//
//   b := cocoa.backend()
//   ok, why := b.init(b)
//   s, _ := b.surface_create(b, {title = "Hi", size = {640, 400}})
//   for ev in b.pump(b, -1) { ... }
//
// Threading: everything except `wake` must run on the thread that called
// `init`, as AppKit requires. Delegate callbacks append to a queue that
// `pump` hands back; they all land inside a pump call, except a
// backend-initiated `setFrame`, which is re-entrant within it — so the queue
// needs no lock, only tolerance of re-entrancy.
//
// Coordinates: logical pixels with a top-left origin, like every other
// backend. AppKit's are bottom-left, so the view overrides `isFlipped` and
// pointer positions are flipped once, here, rather than at every use.

import CA "vendor:darwin/QuartzCore"
import NS "vendor:darwin/AppKit"
import ObjC "core:sys/darwin/ObjectiveC"
import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:time"
import vk "vendor:vulkan"
import "baldr:platform"

// Cocoa is the backend state; `platform.Backend.data` points at it and the
// Backend is embedded so `backend()` needs one allocation.
Cocoa :: struct {
	backend:   platform.Backend,
	allocator: mem.Allocator,
	ctx:       runtime.Context, // captured at init; callbacks run under it

	app:        ^NS.Application,
	pool:       ^NS.AutoreleasePool,
	view_class: ObjC.Class, // registered once, on first surface
	notify_class: ObjC.Class, // …and the notification delegate's, likewise
	policy:       NS.ApplicationActivationPolicy, // Regular with a window, Accessory without (policy_sync)
	tray_class:   ObjC.Class, // …and the status item's target
	tray_target:  ^NS.Object,
	tray:         [dynamic]Tray_Entry, // the menu bar's status items (tray.odin)
	tray_ids:     map[uintptr]u32,     // NSMenuItem -> the toolkit's id
	notify:       Notify_State, // notify.odin: what the system answered, on its own threads
	locale:       platform.Locale, // locale.odin: read once at init, the backend's to free
	idle_token:   ^NS.Object, // idle.odin: NSProcessInfo's activity, while a window asks
	menu:         ^NS.Object,   // menu.odin: the main menu bar, built once at init
	menu_class:   ObjC.Class,     // …its items' target class
	menu_target:  ^NS.Object,   // …and the one instance of it
	menu_titles:  [dynamic]string, // every title's bytes: an NSString here does not copy them
	drag_in:      Drag_In,  // drag.odin: a drag over one of our windows
	drag_out:     Drag_Out, // …and one that left one
	screens:      [dynamic]platform.Output, // outputs.odin: the desktop's screens, re-read when AppKit says they changed
	screens_watch: ^NS.Object,              // …the observer that hears it
	watches:      [dynamic]^Watch,          // watch.odin: one FSEvents stream per watched path

	surfaces: [dynamic]^Surface,       // slot i is platform.Surface(i + 1); nil = free
	// The desktop's UI fonts, held here because Ev_Theme's strings are the
	// backend's until the next pump. NUL-padded UTF-8.
	ui_font:   [128]u8,
	mono_font: [128]u8,
	queue:    [dynamic]platform.Event, // callbacks append here
	out:      [dynamic]platform.Event, // handed back by the last pump
	text:     virtual.Arena,           // Ev_Text storage, reset per pump
	debug_files: bool, // BALDR_DEBUG_EVENTS: say what a file dialog answered with

	serial: u32,
	// frame_clock.odin: the one object every surface's CADisplayLink sends
	// its tick to, and the class it is an instance of.
	clock_class:  ObjC.Class,
	clock_target: ^NS.Object,
	in_wait:      bool, // …and whether the pump is inside its wait, so a tick knows if anyone is listening
	clock_off:    bool, // BALDR_NO_DISPLAY_LINK: fall back to the fixed clamp
	// prefs_watch.odin: the observer that hears the desktop's preferences
	// change, and whether one is owed an Ev_Theme this pump.
	prefs_watch:   ^NS.Object,
	theme_pending: bool,
}

// Surface is one window. The view holds a pointer back to this in its
// indexed ivars, which is how a `proc "c"` callback finds its way home
// without a global.
Surface :: struct {
	cocoa: ^Cocoa,
	id:    platform.Surface,
	win:   ^NS.Window,
	view:  ^NS.View,
	del:   ^NS.WindowDelegate,

	awake: bool, // idle.odin: this window asks for the screen to stay on
	// The last left press in this window, retained: AppKit begins a drag
	// from the event it started with, and by the time the toolkit asks the
	// event has long since been autoreleased (drag.odin).
	press: ^NS.Event,
	ime:   Ime, // ime.odin: whether an input method is wanted here, and where its candidate window goes
	ime_eaten: u32, // …the key code of a press a composition swallowed, so its release goes too
	cursor:        ^Cur_Cursor, // cursor.odin: the pointer's shape over this window
	cursor_owned:  bool,        // …and whether we allocated it (a picture) or AppKit shares it
	cursor_hidden: bool,        // …and whether the pointer is hidden for it

	// `initWithOdinString` is `initWithBytesNoCopy`, so the bytes behind a
	// title must outlive the NSString. This owns them.
	title: string,

	layer:   ^CA.MetalLayer, // the renderer's drawable, made on demand (metal_layer)
	size:    [2]f32, // logical, content
	scale:   f32,
	// `frames` is continuous drawing (frames_wanted); `frame_requested` is a
	// single frame asked for by surface_request_frame. They are different
	// questions and the answer to both is an Ev_Redraw.
	frames:          bool,
	frame_requested: bool,
	clock:           Clock, // frame_clock.odin: the display saying when, and the rate it reports
	closing: bool,
}

// backend allocates and fills a Backend for macOS. Call `init` before
// anything else; `shutdown` frees everything including the Backend itself.
backend :: proc(allocator := context.allocator) -> ^platform.Backend {
	c := new(Cocoa, allocator)
	c.allocator = allocator
	c.backend = platform.Backend {
		name = "cocoa",
		data = c,

		init     = b_init,
		shutdown = b_shutdown,

		surface_create        = b_surface_create,
		surface_destroy       = b_surface_destroy,
		surface_set_title     = b_surface_set_title,
		surface_set_dark      = b_surface_set_dark,
		surface_geometry      = b_surface_geometry,
		surface_native        = b_surface_native,
		file_dialog           = file_dialog,
		activate              = b_activate,
		surface_request_frame = b_surface_request_frame,
		surface_set_cursor    = b_surface_set_cursor,
		frames_wanted         = b_frames_wanted,

		drawable_create = b_drawable_create,

		pump = b_pump,
		wake = b_wake,

		system_theme = b_system_theme,

		// locale.odin: the dates, names and separators the person has set.
		locale = b_locale,

		// idle.odin: hold the screen on for a window showing something.
		keep_awake = b_keep_awake,

		// close this window down the same path its close button uses.
		surface_post_close = b_surface_post_close,

		// key_name.odin: what this keyboard's layout calls a key.
		key_name = b_key_name,

		// cursor.odin: a picture the app drew for the pointer.
		surface_set_cursor_image = b_surface_set_cursor_image,

		// open.odin: the browser, and the Finder.
		open_url  = b_open_url,
		open_path = b_open_path,

		// notify.odin: UNUserNotificationCenter, for a bundled app.
		notify       = b_notify,
		notify_close = b_notify_close,

		// tray.odin: NSStatusItem in the menu bar.
		tray_set    = b_tray_set,
		tray_remove = b_tray_remove,

		// `surface_ack_configure` is left nil, as on X11 and Win32: it is
		// the Wayland configure/ack exchange, and an empty body would look
		// like a real answer.

		// clipboard.odin for the text pair, clipboard_typed.odin for the
		// forms — pictures, files, formatted text. The primary selection
		// stays nil: macOS has no middle-click selection at all.
		clipboard_get      = b_clipboard_get,
		clipboard_set      = b_clipboard_set,
		clipboard_types    = b_clipboard_types,
		clipboard_get_data = b_clipboard_get_data,
		clipboard_set_data = b_clipboard_set_data,

		// drag.odin: files and pictures leaving a window and arriving in
		// one. The toolkit takes these four as a group.
		// outputs.odin: the screens, and where a window is on them.
		outputs          = b_outputs,
		surface_position = b_surface_position,

		// window_size.odin: a window sized by its app, and one given the
		// whole screen.
		surface_set_size       = b_surface_set_size,
		surface_set_fullscreen = b_surface_set_fullscreen,

		// watch.odin: FSEvents, so a `watch` subscription reports something.
		watch   = b_watch,
		unwatch = b_unwatch,

		// ime.odin: NSTextInputClient, so composing works at all.
		ime_set = b_ime_set,

		drag_start   = b_drag_start,
		drag_accept  = b_drag_accept,
		drag_receive = b_drag_receive,
		drag_finish  = b_drag_finish,

		// Not Vulkan: the Metal renderer is reached through
		// `drawable_create` above. These answer rather than being nil, so a
		// caller that asks gets `false` instead of a crash.
		vk_instance_extensions = proc(b: ^platform.Backend) -> []cstring { return nil },
		vk_create_surface = proc(b: ^platform.Backend, s: platform.Surface, instance: vk.Instance) -> (vk.SurfaceKHR, bool) {
			return 0, false
		},
	}
	return &c.backend
}

@(private)
self :: proc "contextless" (b: ^platform.Backend) -> ^Cocoa {
	return (^Cocoa)(b.data)
}

@(private)
b_init :: proc(b: ^platform.Backend) -> (ok: bool, why: string) {
	c := self(b)
	c.ctx = context
	c.pool = NS.AutoreleasePool.alloc()->init()
	c.app = NS.Application.sharedApplication()
	if c.app == nil do return false, "NSApplication.sharedApplication returned nil"

	// .Regular makes a bare binary a foreground app with a Dock tile and a
	// menu bar; without it a window appears but never takes focus. An app
	// that lives in the menu bar drops to .Accessory when its last window
	// goes (policy_sync).
	c.app->setActivationPolicy(.Regular)
	// AppKit does start-up work inside [NSApp run], which Baldr never calls
	// because `pump` owns the loop.
	c.app->finishLaunching()

	c.surfaces = make([dynamic]^Surface, c.allocator)
	c.queue = make([dynamic]platform.Event, c.allocator)
	c.out = make([dynamic]platform.Event, c.allocator)
	if err := virtual.arena_init_growing(&c.text); err != nil do return false, "text arena"
	c.debug_files = os.get_env("BALDR_DEBUG_EVENTS", context.temp_allocator) != ""
	clock_init(c) // the frame clock's escape hatch, read once (frame_clock.odin)
	c.locale = locale_read(c.allocator) // the desktop's dates, names and separators
	if c.debug_files { // the same line the Wayland backend prints, for the same reason
		fmt.eprintfln("baldr/cocoa: locale %s: dates %s, first weekday %d, %s, decimal %q, group %q",
			c.locale.tag, c.locale.date_format, c.locale.first_weekday,
			"24h" if c.locale.time_24h else "12h", c.locale.decimal, c.locale.thousands)
	}
	notify_init(c) // asks for permission once, and listens for what the person does
	tray_init(c)
	outputs_refresh(c) // the screens, before any window asks which one it is on
	outputs_watch(c)   // …and AppKit says when they change
	prefs_watch(c)     // …as it does when the desktop's preferences do
	// A Mac app has a menu bar the way it has a close button, and the
	// standard chords live in it: without one, Cmd-Q types a q.
	menu_install(c)

	b.caps = {} // no layer shell, no session lock, no backdrop blur yet
	return true, ""
}

@(private)
b_shutdown :: proc(b: ^platform.Backend) {
	c := self(b)
	locale_free(&c.locale, c.allocator)
	watch_shutdown(c)   // the file watches and their streams
	outputs_shutdown(c) // the screen list and its observer
	prefs_shutdown(c)   // …and the preferences observer, off all three centres
	drag_shutdown(c)   // a drop's snapshot, if one was in flight
	menu_shutdown(c)   // the bar goes before the app it was handed to
	tray_shutdown(c)   // status items go before the app they point at
	notify_shutdown(c) // the delegate goes before the backend it points at
	for s in c.surfaces do if s != nil do destroy_surface(c, s)
	delete(c.surfaces)
	delete(c.queue)
	delete(c.out)
	virtual.arena_destroy(&c.text)
	if c.pool != nil do c.pool->drain()
	free(c, c.allocator)
}

// --- surfaces

@(private)
b_surface_create :: proc(b: ^platform.Backend, desc: platform.Surface_Desc) -> (platform.Surface, bool) {
	c := self(b)
	size := desc.size
	if size.x <= 0 do size.x = 800
	if size.y <= 0 do size.y = 600

	rect := NS.Rect{{0, 0}, {NS.Float(size.x), NS.Float(size.y)}}
	style := NS.WindowStyleMask{.Titled, .Closable, .Miniaturizable, .Resizable}
	win := NS.Window.alloc()->initWithContentRect(rect, style, .Buffered, false)
	if win == nil do return 0, false

	s := new(Surface, c.allocator)
	s.cocoa = c
	s.win = win
	s.size = size
	s.scale = f32(win->backingScaleFactor())

	// claim a slot: the handle is the index + 1, so 0 is never a surface
	idx := -1
	for existing, i in c.surfaces do if existing == nil { idx = i; break }
	if idx < 0 {
		append(&c.surfaces, s)
		idx = len(c.surfaces) - 1
	} else {
		c.surfaces[idx] = s
	}
	s.id = platform.Surface(idx + 1)

	s.view = view_make(c, s, rect)
	if s.view == nil {
		c.surfaces[idx] = nil
		free(s, c.allocator)
		return 0, false
	}
	s.view->setWantsLayer(true) // layer-backed: what a CAMetalLayer replaces
	win->setContentView(s.view)
	win->setAcceptsMouseMovedEvents(true)
	_ = intrinsics.objc_send(NS.BOOL, win, "makeFirstResponder:", s.view)

	s.del = make_delegate(c, s)
	if s.del != nil do win->setDelegate(s.del)

	// The size range the app asked for. AppKit measures these as *content*
	// sizes, which is what the toolkit means by them too: the frame grows
	// by whatever the title bar takes, at both ends.
	if desc.min_size.x > 0 || desc.min_size.y > 0 {
		intrinsics.objc_send(nil, win, "setContentMinSize:",
			NS.Size{NS.Float(max(desc.min_size.x, 1)), NS.Float(max(desc.min_size.y, 1))})
	}
	if desc.max_size.x > 0 || desc.max_size.y > 0 {
		// A zero on one axis is "no limit" here and "zero" to AppKit, so an
		// unasked axis is given the largest size it will take rather than
		// being pinned shut.
		big :: NS.Float(1e7)
		intrinsics.objc_send(nil, win, "setContentMaxSize:", NS.Size{
			big if desc.max_size.x <= 0 else NS.Float(desc.max_size.x),
			big if desc.max_size.y <= 0 else NS.Float(desc.max_size.y),
		})
	}
	set_title(c, s, desc.title)
	policy_sync(c) // a window makes this a regular app again, and activates it
	// Where the app asked for, if it asked — a window coming back where it
	// was left (outputs.odin turns the desktop's coordinates into AppKit's).
	// Centred when it did not, which is what a new window should do.
	if pos, asked := desc.position.?; asked {
		surface_place(win, pos)
	} else {
		win->center()
	}
	win->makeKeyAndOrderFront(nil)
	// …and in the state it asked to open in, which is the rest of a window
	// coming back the way it was left. Both are requests: what actually
	// happened arrives in the configure the delegate sends.
	if desc.maximized && !window_is_zoomed(win) do intrinsics.objc_send(nil, win, "zoom:", ObjC.id(nil))
	if desc.fullscreen do b_surface_set_fullscreen(b, s.id, true)

	// The first configure, so the app knows its size before any event.
	append(&c.queue, configure_of(s))
	return s.id, true
}

@(private)
destroy_surface :: proc(c: ^Cocoa, s: ^Surface) {
	idle_release(c, s)  // a window that asked for the screen to stay on, going away
	cursor_release(s)   // …and a picture cursor it owned
	clock_stop(s)       // …and its display link, before the view it hangs off goes
	if s.win != nil {
		s.win->setDelegate(nil)
		s.win->close()
	}
	delete(s.title, c.allocator)
	idx := int(s.id) - 1
	if idx >= 0 && idx < len(c.surfaces) do c.surfaces[idx] = nil
	free(s, c.allocator)
}

@(private)
b_surface_destroy :: proc(b: ^platform.Backend, id: platform.Surface) {
	c := self(b)
	if s := find(c, id); s != nil do destroy_surface(c, s)
	policy_sync(c)
}

// policy_sync keeps the Dock honest: an app with a window is a regular app,
// and one with none is an accessory — in the menu bar, out of the Dock and
// out of Cmd-Tab, as a tray-resident app should be. The window decides, not
// the tray: switching to .Regular when a window opens is what lets "show my
// window" bring a hidden app back where it can be reached.
@(private)
policy_sync :: proc(c: ^Cocoa) {
	if c.app == nil do return
	live := 0
	for s in c.surfaces do if s != nil do live += 1
	want: NS.ApplicationActivationPolicy = .Regular if live > 0 else .Accessory
	if c.policy == want do return
	c.policy = want
	c.app->setActivationPolicy(want)
	// Coming back from .Accessory needs the app activated, or the window
	// opens behind whatever was in front.
	if want == .Regular {
		if NS.respondsToSelector(c.app, ObjC.sel_registerName("activate")) {
			intrinsics.objc_send(nil, c.app, "activate")
		} else {
			c.app->activateIgnoringOtherApps(true)
		}
	}
}

// b_surface_native hands out the window's NSView, which is the only object
// NSAccessibility can be answered through: AppKit asks the view what its
// accessible children are, so the toolkit's bridge has to be able to find
// it. Nothing else may use it — see `Backend.surface_native`.
@(private)
b_surface_native :: proc(b: ^platform.Backend, id: platform.Surface) -> rawptr {
	s := find(self(b), id)
	return rawptr(s.view) if s != nil else nil
}

@(private)
find :: proc "contextless" (c: ^Cocoa, id: platform.Surface) -> ^Surface {
	i := int(id) - 1
	if i < 0 || i >= len(c.surfaces) do return nil
	return c.surfaces[i]
}

@(private)
set_title :: proc(c: ^Cocoa, s: ^Surface, title: string) {
	// Owned, because initWithOdinString does not copy. NS.AT is not
	// an option: it is CFSTR and mangles anything above \177.
	delete(s.title, c.allocator)
	s.title = string(copy_bytes(title, c.allocator))
	// Never hand setTitle: a nil NSString: it raises, and an ObjC exception
	// out of a Baldr frame aborts the process. The UTF-8 initialisers return
	// nil for invalid UTF-8, so such a title becomes an empty one.
	ns := NS.String.alloc()->initWithOdinString(s.title)
	if ns == nil do ns = NS.String.alloc()->initWithOdinString("")
	if ns != nil do s.win->setTitle(ns)
}

@(private)
copy_bytes :: proc(src: string, allocator: mem.Allocator) -> []u8 {
	out := make([]u8, len(src), allocator)
	copy(out, transmute([]u8)src)
	return out
}

@(private)
b_surface_set_title :: proc(b: ^platform.Backend, id: platform.Surface, title: string) {
	c := self(b)
	if s := find(c, id); s != nil do set_title(c, s, title)
}

// b_surface_set_dark gives the window's title bar the appearance of the theme
// the app draws in it (Backend.surface_set_dark): Dark Aqua for a dark one,
// Aqua for a light one. It is the window's own appearance, not the
// application's, so `appearance_is_dark` — which reads NSApp's — still
// answers what the desktop is set to.
@(private)
b_surface_set_dark :: proc(b: ^platform.Backend, id: platform.Surface, dark: bool) {
	c := self(b)
	s := find(c, id)
	if s == nil || s.win == nil do return
	ap := NS.Appearance.appearanceNamed(NS.AppearanceNameDarkAqua if dark else NS.AppearanceNameAqua)
	if ap == nil do return
	intrinsics.objc_send(nil, s.win, "setAppearance:", ap)
}

// b_activate brings a window to the front and gives it the keyboard, which
// is what a tray-resident app's "Show window" does (an app with its window
// hidden stops declaring the surface and declares it again; the toolkit
// holds the `activate` until there is a window to raise).
//
// `token` is the Wayland activation token and has no macOS equivalent.
//
// `activate` where it exists (macOS 14 and later, what Apple asks for now),
// `activateIgnoringOtherApps:` before that; asking the object which it
// answers to is the only way to tell at runtime.
@(private)
b_activate :: proc(b: ^platform.Backend, id: platform.Surface, token: string) {
	c := self(b)
	if c.app != nil {
		if NS.respondsToSelector(c.app, ObjC.sel_registerName("activate")) {
			intrinsics.objc_send(nil, c.app, "activate")
		} else {
			c.app->activateIgnoringOtherApps(true)
		}
	}
	if s := find(c, id); s != nil && s.win != nil do s.win->makeKeyAndOrderFront(nil)
}

@(private)
b_surface_geometry :: proc(b: ^platform.Backend, id: platform.Surface) -> (size: [2]f32, size_px: [2]u32, scale: f32) {
	c := self(b)
	s := find(c, id)
	if s == nil do return {}, {}, 1
	return s.size, {u32(s.size.x * s.scale), u32(s.size.y * s.scale)}, s.scale
}

@(private)
b_surface_request_frame :: proc(b: ^platform.Backend, id: platform.Surface) {
	c := self(b)
	if s := find(c, id); s != nil {
		s.frame_requested = true
		clock_want(c, s, true)
	}
}

@(private)
b_frames_wanted :: proc(b: ^platform.Backend, id: platform.Surface, on: bool) {
	c := self(b)
	if s := find(c, id); s != nil {
		s.frames = on
		clock_want(c, s, on || s.frame_requested)
	}
}

// --- the loop

// b_wake posts an event, because only an event ends a pump that is waiting
// (frame_clock.odin).
@(private)
b_wake :: proc(b: ^platform.Backend) {
	wake_post(self(b))
}

@(private)
b_system_theme :: proc(b: ^platform.Backend) -> platform.Ev_Theme {
	// `text_scale` is 1 and not 0: macOS has no global text size the way
	// GNOME and Windows do — it is per app — so there is nothing to follow
	// and the toolkit must not read a missing answer as "no text".
	t := platform.Ev_Theme{dark = appearance_is_dark(), text_scale = 1}
	if ws := shared_workspace(); ws != nil {
		// System Settings > Accessibility > Display.
		t.reduce_motion = bool(intrinsics.objc_send(NS.BOOL, ws, "accessibilityDisplayShouldReduceMotion"))
		t.reduce_transparency = bool(intrinsics.objc_send(NS.BOOL, ws, "accessibilityDisplayShouldReduceTransparency"))
		t.high_contrast = bool(intrinsics.objc_send(NS.BOOL, ws, "accessibilityDisplayShouldIncreaseContrast"))
	}
	if c, ok := accent_srgb(); ok {
		t.has_accent = true
		t.accent = c
	}
	c := self(b)
	t.font_family = font_family_of(c.ui_font[:], "systemFontOfSize:")
	t.mono_family = font_family_of(c.mono_font[:], "monospacedSystemFontOfSize:weight:")
	return t
}

// accent_srgb is the user's accent colour (System Settings > Appearance), in
// sRGB, which is the space `platform.Ev_Theme.accent` is stated in.
//
// `controlAccentColor` is 10.14 and later, so it is asked for rather than
// assumed: on anything older the app keeps its own accent. The colour is
// converted into a real colour space before its components are read: asking
// a catalogue colour for its red raises.
@(private)
accent_srgb :: proc() -> (out: [4]f32, ok: bool) {
	if !bool(intrinsics.objc_send(NS.BOOL, Color_NS, "respondsToSelector:",
		ObjC.sel_registerName("controlAccentColor"))) {
		return {}, false
	}
	c := intrinsics.objc_send(^Color_NS, Color_NS, "controlAccentColor")
	if c == nil do return {}, false
	space := intrinsics.objc_send(^Color_Space, Color_Space, "sRGBColorSpace")
	if space == nil do return {}, false
	conv := intrinsics.objc_send(^Color_NS, c, "colorUsingColorSpace:", space)
	if conv == nil do return {}, false
	r, g, bl, a: NS.Float
	intrinsics.objc_send(nil, conv, "getRed:green:blue:alpha:", &r, &g, &bl, &a)
	return {f32(r), f32(g), f32(bl), 1}, true
}

// font_family_of is the family name of one of the system fonts, cached in
// `buf` because `Ev_Theme`'s strings are the backend's until the next pump.
//
// The family and not the size: macOS states a size with every system font
// and a size here would be a second text scale. `monospacedSystemFontOfSize:
// weight:` is 10.15 and later, so it is asked for rather than assumed.
@(private)
font_family_of :: proc(buf: []u8, sel: cstring) -> string {
	if buf[0] != 0 do return cocoa_padded(buf)
	if !bool(intrinsics.objc_send(NS.BOOL, Font_NS, "respondsToSelector:", ObjC.sel_registerName(sel))) {
		return ""
	}
	f: ^NS.Object
	if sel == "systemFontOfSize:" {
		f = intrinsics.objc_send(^NS.Object, Font_NS, "systemFontOfSize:", NS.Float(0))
	} else {
		f = intrinsics.objc_send(^NS.Object, Font_NS, "monospacedSystemFontOfSize:weight:", NS.Float(0), NS.Float(0))
	}
	if f == nil do return ""
	name := intrinsics.objc_send(^NS.String, f, "familyName")
	if name == nil do return ""
	s := name->odinString()
	if len(s) == 0 do return ""
	// macOS answers with a private family (".AppleSystemUIFont"): a leading
	// dot marks a name no font lookup resolves. Nothing is reported, so the
	// embedded faces stand.
	if s[0] == '.' do return ""
	cut := min(len(s), len(buf) - 1)
	copy(buf[:cut], s[:cut])
	buf[cut] = 0
	return cocoa_padded(buf)
}

@(private)
cocoa_padded :: proc(b: []u8) -> string {
	for c, i in b do if c == 0 do return string(b[:i])
	return string(b)
}

@(private, objc_class = "NSFont")
Font_NS :: struct { using _: NS.Object }

// The two classes this file talks to that core:sys/darwin does not wrap
// (NSWorkspace is already declared in open.odin). Nothing is stored in them:
// they exist to tell the compiler which class a message is going to.
@(private, objc_class = "NSColor")
Color_NS :: struct { using _: NS.Object }

@(private, objc_class = "NSColorSpace")
Color_Space :: struct { using _: NS.Object }

// appearance_is_dark reads the effective appearance. NSAppearance is not in
// the bindings and Foundation's msgSend is package-private, so this goes
// through the objc runtime directly.
@(private)
appearance_is_dark :: proc "contextless" () -> bool {
	app := NS.Application.sharedApplication()
	if app == nil do return false
	ap := intrinsics.objc_send(^NS.Object, app, "effectiveAppearance")
	if ap == nil do return false
	n := intrinsics.objc_send(^NS.String, ap, "name")
	if n == nil do return false
	name := string(n->odinString())
	// NSAppearanceNameDarkAqua, and the high-contrast and vibrant variants
	for i in 0 ..< len(name) do if i + 4 <= len(name) && name[i:i + 4] == "Dark" do return true
	return false
}

// COCOA_FRAME_WAIT is the longest b_pump waits for an event while a frame is
// already due: one 60 Hz interval. See the comment at its use.
@(private)
COCOA_FRAME_WAIT :: NS.TimeInterval(1.0 / 60.0)

@(private)
b_pump :: proc(b: ^platform.Backend, timeout_ms: i32) -> []platform.Event {
	c := self(b)
	clear(&c.out)
	// An app that never opens a window at all — one that lives in the menu
	// bar — would otherwise keep the Dock tile it was given at start.
	policy_sync(c)
	notify_drain(c) // what the system's own threads reported since the last pump
	// What the last pump returned is no longer the caller's, so `text` can
	// go — but only when nothing is already waiting, as in the win32 and x11
	// pumps: a file dialog answers between pumps and its paths live in this
	// arena, so freeing it then would release them in the pump that hands
	// them over.
	if len(c.queue) == 0 do virtual.arena_free_all(&c.text)

	// The timeout AppKit is asked for is advisory: 16 ms can become 29 ms
	// idle, and a few hundred around a window's structural changes. A caller
	// pacing frames off it must not assume it was honoured.
	secs := NS.TimeInterval(f64(timeout_ms) / 1000.0)
	if timeout_ms < 0 do secs = 0.05

	// A frame already due must not wait for an event first: Ev_Redraw is
	// emitted after this loop, so blocking for an NSEvent would pace every
	// frame at the timeout. It waits at most one refresh instead, not zero:
	// `nextDrawable` does not block here, so `secs = 0` would spin a core.
	// A display link that has ticked ends the wait itself (it posts a wake);
	// the clamp is the fallback for a surface whose link is silent.
	for s in c.surfaces do if s != nil && (s.frame_requested || s.frames) {
		// A link that is merely running might be silent (a view not in a
		// window yet, a sleeping display), so the clamp stays until it has
		// ticked.
		if s.clock.ticked do continue
		// The display's own interval once known, the 60 Hz guess until then.
		wait := COCOA_FRAME_WAIT
		if s.clock.measured do wait = NS.TimeInterval(s.clock.refresh_ms / 1000.0)
		secs = min(secs, wait) // and 0 stays 0: a message already queued waits for nothing
		break
	}

	deadline := time.tick_now()
	for {
		until := NS.Date.dateWithTimeIntervalSinceNow(secs)
		c.in_wait = secs > 0 // a display tick posts a wake only while this is true
		ev := c.app->nextEventMatchingMask(NS.EventMaskAny, until, NS.DefaultRunLoopMode, true)
		c.in_wait = false
		if ev == nil do break
		// A wake is not an event anybody wants: it exists to end the wait
		// above, and handing it to AppKit would be giving it something it
		// never sent (frame_clock.odin).
		if !wake_event(ev) {
			translate(c, ev)
			c.app->sendEvent(ev) // AppKit's own handling; delegates fire in here
		}
		secs = 0 // drain whatever else is queued without waiting again
		// The escape applies to a wake too, or a steady tick stream would
		// keep this loop going for ever.
		if time.duration_milliseconds(time.tick_since(deadline)) > 100 do break
	}

	// A preference changed while we waited: one Ev_Theme, however many
	// notifications said so (prefs_watch.odin).
	prefs_flush(c)

	// Ev_Redraw is what draws a frame; Ev_Frame is only the clock. app.odin
	// asks through surface_request_frame and runs `do_frame` on the Ev_Redraw
	// that comes back, so a backend answering with Ev_Frame alone never draws.
	for s in c.surfaces do if s != nil && (s.frame_requested || s.frames) {
		want_clock := s.frames // before the one-shot request is taken
		s.frame_requested = false
		// The link stops with the last frame anybody wanted, or a one-shot
		// request would leave it waking this pump at the display's rate.
		clock_want(c, s, s.frames)
		append(&c.queue, platform.Ev_Redraw{surface = s.id})
		// Ev_Frame only while continuous frames are wanted: the runtime
		// answers one by asking to draw again (app.odin), so sending it beside
		// a one-shot redraw would loop for ever.
		if want_clock {
			// The interval the display link reported for this window's own
			// screen, and `estimated` only until it has reported one.
			ms := s.clock.refresh_ms if s.clock.measured else 1000.0 / 60.0
			append(&c.queue, platform.Ev_Frame{
				surface = s.id, ahead_ms = 0, refresh_ms = ms, estimated = !s.clock.measured,
			})
		}
	}

	append(&c.out, ..c.queue[:])
	clear(&c.queue)
	return c.out[:]
}

// translate turns an NSEvent into Baldr's events. Keys, pointer and scroll
// all come off the queue; the window's own changes arrive by delegate.
@(private)
translate :: proc(c: ^Cocoa, ev: ^NS.Event) {
	win := ev->window()
	s: ^Surface
	for cand in c.surfaces do if cand != nil && cand.win == win { s = cand; break }
	if s == nil do return

	kind := ev->type()
	#partial switch kind {
	case .KeyDown, .KeyUp:
		code := u32(ev->keyCode())
		mods := mods_from_flags(u64(transmute(NS.UInteger)ev->modifierFlags()))
		down := kind == .KeyDown
		key := key_from_code(code)
		// A chord the menu bar owns is the menu's alone: `sendEvent` matches
		// it against the menu's key equivalents, and delivering it here too
		// would fire an app's own shortcut beside the menu's action
		// (menu.odin).
		if menu_owns_chord(key, mods) do return
		// A key a composition owns is the input method's (ime.odin): a Return
		// that commits a phrase must not also reach the app. The flag is read
		// before this event reaches the input context, and the release of a
		// swallowed press is swallowed with it.
		if down && s.ime.composing {
			s.ime_eaten = code
			return
		}
		if !down && s.ime_eaten == code && code != 0 {
			s.ime_eaten = 0
			return
		}
		append(&c.queue, platform.Ev_Key{
			surface = s.id, key = key, native = code,
			pressed = down, repeat = bool(ev->isARepeat()), mods = mods,
		})
		// The text comes from the input method, not from `characters`: the
		// view hands this key to its input context in `keyDown:`, and the
		// result arrives as Ev_Text or Ev_Ime (ime.odin).
	case .LeftMouseDown, .LeftMouseUp, .RightMouseDown, .RightMouseUp, .OtherMouseDown, .OtherMouseUp:
		pressed := kind == .LeftMouseDown || kind == .RightMouseDown || kind == .OtherMouseDown
		if kind == .LeftMouseDown { // the event a drag out of this window would begin with
			if s.press != nil do intrinsics.objc_send(nil, s.press, "release")
			s.press = intrinsics.objc_send(^NS.Event, ev, "retain")
		}
		btn := platform.Mouse_Button.Left
		#partial switch kind {
		case .RightMouseDown, .RightMouseUp: btn = .Right
		case .OtherMouseDown, .OtherMouseUp: btn = .Middle
		}
		c.serial += 1
		append(&c.queue, platform.Ev_Pointer_Button{
			surface = s.id, button = btn, pressed = pressed, pos = point(s, ev),
			mods = mods_from_flags(u64(transmute(NS.UInteger)ev->modifierFlags())),
			serial = c.serial, time_ms = u32(f64(ev->timestamp()) * 1000),
		})
	case .MouseMoved, .LeftMouseDragged, .RightMouseDragged:
		append(&c.queue, platform.Ev_Pointer_Motion{
			surface = s.id, pos = point(s, ev), time_ms = u32(f64(ev->timestamp()) * 1000),
			mods = mods_from_flags(u64(transmute(NS.UInteger)ev->modifierFlags())),
		})
	case .ScrollWheel:
		precise := bool(ev->hasPreciseScrollingDeltas())
		append(&c.queue, platform.Ev_Scroll{
			surface = s.id,
			delta = scroll_delta(f32(ev->scrollingDeltaX()), f32(ev->scrollingDeltaY()), precise),
			pos = point(s, ev), precise = precise,
			mods = mods_from_flags(u64(transmute(NS.UInteger)ev->modifierFlags())),
		})
	case .MouseEntered:
		append(&c.queue, platform.Ev_Pointer_Enter{surface = s.id, pos = point(s, ev)})
	case .MouseExited:
		append(&c.queue, platform.Ev_Pointer_Leave{surface = s.id})
	}
}

// point is an event's position in Baldr's coordinates: logical pixels from
// the top left. locationInWindow measures from the bottom left, so the y
// is flipped once, here.
@(private)
point :: proc "contextless" (s: ^Surface, ev: ^NS.Event) -> [2]f32 {
	p := ev->locationInWindow()
	return {f32(p.x), s.size.y - f32(p.y)}
}

// arena_str copies text into the per-pump arena. Strings inside events are
// the backend's and live until the next pump, which is what platform.odin
// promises.
@(private)
arena_str :: proc(c: ^Cocoa, src: string) -> string {
	if len(src) == 0 do return ""
	buf := make([]u8, len(src), virtual.arena_allocator(&c.text))
	copy(buf, transmute([]u8)src)
	return string(buf)
}

// drag_corner_hint is a testing aid: a surface's bottom-right corner in
// CGEvent's coordinates (global display pixels, origin top left), which is
// what `tools/mac_click` takes. NSWindow measures from the bottom left.
drag_corner_hint :: proc(b: ^platform.Backend, id: platform.Surface) -> string {
	c := self(b)
	s := find(c, id)
	if s == nil do return "0,0"
	f := s.win->frame()
	screen_h := 0.0
	if sc := NS.Screen.screens(); sc != nil && sc->count() > 0 {
		screen_h = f64(sc->objectAs(0, ^NS.Screen)->frame().size.height)
	}
	x := f64(f.origin.x) + f64(f.size.width) - 3
	y := screen_h - f64(f.origin.y) - 3 // flip: NS bottom-left -> CG top-left
	return fmt.tprintf("%.0f,%.0f", x, y)
}

// b_drawable_create is the renderer seam: on macOS the thing a renderer
// draws into is the view's CAMetalLayer, where every Vulkan backend hands
// back a VkSurfaceKHR. `renderer` is ignored — Metal needs nothing from the
// renderer to make one.
@(private)
b_drawable_create :: proc(b: ^platform.Backend, id: platform.Surface, renderer: rawptr) -> (uintptr, bool) {
	layer := metal_layer(b, id)
	if layer == nil do return 0, false
	return uintptr(uintptr(rawptr(layer))), true
}

// metal_layer attaches a CAMetalLayer to a surface's view and returns it, or
// returns the one already there. This is the renderer seam on macOS, in
// place of `vk_create_surface`: the Metal renderer asks the backend for the
// layer to draw into, exactly as the Vulkan one asks for a VkSurfaceKHR.
//
// `setWantsLayer(true)` has already happened in surface_create; the layer is
// set after it, because the other order leaves AppKit free to replace it.
// The drawable size tracks the view's bounds times the backing scale
// and is refreshed here on every call, since a resize or a move to another
// display changes it and a stale drawable silently stretches the frame.
metal_layer :: proc(b: ^platform.Backend, id: platform.Surface) -> ^CA.MetalLayer {
	c := self(b)
	s := find(c, id)
	if s == nil || s.view == nil do return nil
	if s.layer == nil {
		layer := CA.MetalLayer.layer()
		if layer == nil do return nil
		// sRGB: Baldr's colours are linear and the surface encodes them, as
		// the Vulkan swapchain does. gpu/metal.odin carries the full note.
		layer->setPixelFormat(.BGRA8Unorm_sRGB)
		// Not framebuffer-only: the glass path samples the drawable, and
		// framebufferOnly lets Metal pick a layout that cannot be sampled.
		// A little bandwidth on every surface buys glass on any window.
		layer->setFramebufferOnly(false)
		// Present inside the CATransaction that carries the bounds change, or
		// AppKit stretches the last frame across a live resize. On for the
		// surface's life: set from windowWillStartLiveResize it does not reach
		// the renderer's next frame. It costs a waitUntilScheduled per frame.
		layer->setPresentsWithTransaction(true)
		s.view->setLayer(layer)
		s.layer = layer
	}
	bounds := s.view->bounds()
	scale := f64(s.win->backingScaleFactor())
	s.layer->setDrawableSize({NS.Float(f64(bounds.size.width) * scale), NS.Float(f64(bounds.size.height) * scale)})
	return s.layer
}
