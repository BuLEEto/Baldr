#+build linux
package x11

// The X11 backend: windows through libxcb with VK_KHR_xcb_surface, input
// (core, XInput2, xkb, ibus), the clipboard, XDND drag and drop, cursors
// and a frame clock. A Backend proc left nil is one the toolkit degrades
// without.
//
// Shaped after platform/win32 rather than platform/wayland: X has no
// configure/ack and no per-surface scale, so a surface's size is what the
// server last said.
//
//   b := x11.backend()
//   ok, why := b.init(b)
//   s, _ := b.surface_create(b, {title = "Hi", size = {640, 400}})
//   for ev in b.pump(b, -1) { ... }
//
// Coordinates are logical pixels, as everywhere outside gpu/. X has one DPI
// for the session, so `scale` is session-wide, from Xft.dpi (props.odin).

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"
import vk "vendor:vulkan"
import "baldr:platform"
import "baldr:platform/xdg"
import "baldr:platform/xkb"

// Atoms the backend interns once at init. Named rather than looked up each
// time: an intern is a round trip.
Atoms :: struct {
	wm_protocols:      Atom,
	wm_delete_window:  Atom,
	net_wm_name:       Atom,
	utf8_string:       Atom,
	wm_class:          Atom,
	net_wm_state:      Atom,
	net_wm_state_fullscreen: Atom,
	net_wm_state_maximized_horz: Atom,
	net_wm_state_maximized_vert: Atom,
	// selections (clipboard.odin)
	clipboard:       Atom,
	targets:         Atom,
	text:            Atom,
	text_plain_utf8: Atom,
	incr:            Atom,
	baldr_selection: Atom, // the property a paste's answer is written onto
	baldr_drop:      Atom, // …and a drop's, which is asked for without waiting
	net_active_window: Atom,
	// XDND (xdnd.odin)
	xdnd_aware:       Atom,
	xdnd_enter:       Atom,
	xdnd_position:    Atom,
	xdnd_status:      Atom,
	xdnd_leave:       Atom,
	xdnd_drop:        Atom,
	xdnd_finished:    Atom,
	xdnd_selection:   Atom,
	xdnd_type_list:   Atom,
	xdnd_action_copy: Atom,
}

Surface :: struct {
	id:      platform.Surface,
	x:       ^X11,
	window:  Window,
	kind:    platform.Surface_Kind,
	awake:   bool, // it asked for the screen to be held on (idle.odin)
	size_px: [2]u32,
	pos:     [2]i32,
	live:    bool, // false once destroyed: events for it are dropped
	cursor:  platform.Cursor,
	cursor_pic: Cursor_Id, // a picture the app drew, which wins over `cursor` (cursor_picture.odin)
	pointer_inside: bool,
	pointer_pos:    [2]f32,
	mapped:  bool,
	frame_requested: bool,
	frames_on:       bool, // wants an Ev_Frame per display frame (frames.odin)
	// the measured vblank clock, when Present can give one (present.odin)
	present_eid: u32,
	present_msc: u64,
	present_ust: u64,
	refresh_ms:  f64,
	measured:    bool,
	present_warned: bool, // the one line about unbelievable timings has been said
	configured: bool,
	maximized, fullscreen, focused: bool,
	title:   string, // owned
}

X11 :: struct {
	backend:   platform.Backend,
	allocator: mem.Allocator,
	ctx:       runtime.Context,

	conn:       Connection,
	screen:     ^Screen,
	screen_num: c.int,
	fd:         linux.Fd,
	atoms:      Atoms,
	scale:      f32,  // the session's one scale, from Xft.dpi (props.odin)
	screens:    [dynamic]platform.Output, // the monitors, from RandR (randr.odin); strings owned
	debug:      bool,

	next_frame_at:  time.Tick, // when the next Ev_Frame is due (frames.odin)
	present_opcode: u8,        // 0 when the server has no Present (present.odin)
	xi_opcode:      u8,        // 0 when the server has no XInput2 (xinput2.odin)
	scroll_axes:    [dynamic]Scroll_Axis, // the scrolling valuators it reports
	ime:            Ime,       // the input method, zero when there is none (ime.odin)
	wheel_echo_ms:    Timestamp, // when a valuator last scrolled, to know the compatibility
	wheel_echo_delta: [2]f32,    // buttons that follow it from an injected click (xinput2.odin)
	serial:    u32,      // Ev_Pointer_Button.serial
	keys:       xkb.Xkb, // keymap and translation, shared with Wayland (platform/xkb)
	xkb_device: i32,     // the server's core keyboard
	held:       u32,     // the keycode last pressed and not yet released, for auto-repeat
	clip_window: Window,        // owns selections, unmapped (clipboard.odin)
	owned:       [Selection]Owned, // what this app has put on each selection
	incr_out:    [dynamic]Incr_Out, // transfers this app is sending a piece at a time (incr.odin)
	xdnd:        Xdnd,              // a drag from another program over this app (xdnd.odin)
	drag:        Drag_Out,          // …and one of ours on its way out (xdnd_source.odin)
	// a request for a drag or clipboard form not yet made. One slot: a
	// second request while this one waits is refused.
	drag_waiting: ^Selection_Wait,
	cursor_ctx:  rawptr, // xcb_cursor_context_t (cursor.odin)
	cursor_font: Font,   // the core `cursor` font, opened once when a theme gives nothing
	cursors:    map[platform.Cursor]Cursor_Id, // shapes loaded from the theme, once each
	kbd_focus: ^Surface, // the surface the keyboard is on, nil when none

	extra_fds: [dynamic]linux.Fd, // descriptors the toolkit asked us to poll (ewmh.odin, watch_fd)

	wake_fd: linux.Fd, // eventfd: how another thread interrupts the poll
	woken:   bool,

	surfaces: [dynamic]^Surface, // slot i is platform.Surface(i + 1); nil = free
	queue:    [dynamic]platform.Event,
	out:      [dynamic]platform.Event,
	text:     virtual.Arena, // strings inside events, reset per pump

	locale: platform.Locale, // libc's, read through platform/xdg
	// The desktop's services over the session bus (theme, notifications,
	// file chooser, opening links), owned by platform/xdg and shared with
	// Wayland. Wired in xdg.odin.
	xdg: xdg.Xdg,

	inotify: platform.Inotify, // file watches (watch.odin); fd -1 when unavailable
}

// backend allocates an X11 platform.Backend. Call `init` through it; the
// pointer and its data are freed by `shutdown`.
backend :: proc(allocator := context.allocator) -> ^platform.Backend {
	x := new(X11, allocator)
	x.allocator = allocator
	x.backend = platform.Backend{
		name                   = "x11",
		data                   = x,
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
		clipboard_get          = clipboard_get,
		clipboard_set          = clipboard_set,
		primary_get            = primary_get,
		primary_set            = primary_set,
		clipboard_types        = clipboard_types,
		clipboard_get_data     = clipboard_get_data,
		clipboard_set_data     = clipboard_set_data,
		drag_start             = drag_start,
		drag_accept            = drag_accept,
		drag_receive           = drag_receive,
		drag_finish            = drag_finish,
		surface_request_frame  = surface_request_frame,
		frames_wanted          = frames_wanted,
		surface_geometry       = surface_geometry,
		surface_position       = surface_position,
		keep_awake             = keep_awake,
		outputs                = outputs,
		surface_set_size       = surface_set_size,
		surface_post_close     = surface_post_close,
		surface_set_fullscreen = surface_set_fullscreen,
		activate               = activate,
		ime_set                = ime_set,
		key_name               = key_name,
		watch_fd               = watch_fd,
		pump                   = pump,
		wake                   = wake,
		// the desktop's own services, shared with Wayland (xdg.odin)
		system_theme           = system_theme,
		locale                 = locale,
		open_url               = open_url,
		open_path              = open_path,
		notify                 = notify,
		notify_close           = notify_close,
		tray_set               = tray_set,
		tray_remove            = tray_remove,
		file_dialog            = file_dialog,
		// file watches are platform-neutral on Linux (platform/inotify_linux.odin)
		watch                  = watch,
		unwatch                = unwatch,
	}
	return &x.backend
}

@(private)
data :: #force_inline proc(b: ^platform.Backend) -> ^X11 { return (^X11)(b.data) }

@(private)
debugf :: proc(x: ^X11, format: string, args: ..any) {
	if !x.debug do return
	fmt.eprintf("baldr/x11: ")
	fmt.eprintfln(format, ..args)
}

// ------------------------------------------------------------------- init

@(private)
init :: proc(b: ^platform.Backend) -> (ok: bool, why: string) {
	x := data(b)
	x.ctx = context
	x.debug = os.get_env("BALDR_X11_DEBUG", context.temp_allocator) == "1"

	if loaded, missing := load(); !loaded {
		return false, fmt.tprintf("libxcb unavailable (%v)", missing)
	}
	x.conn = api.connect(nil, &x.screen_num)
	if x.conn == nil || api.connection_has_error(x.conn) != 0 {
		return false, "xcb_connect failed (is DISPLAY set?)"
	}
	setup := api.get_setup(x.conn)
	if setup == nil do return false, "the X server sent no setup"
	it := api.setup_roots_iterator(setup)
	for _ in 0 ..< int(x.screen_num) do api.screen_next(&it)
	x.screen = it.data
	if x.screen == nil do return false, "the X server has no screen"
	x.fd = linux.Fd(api.get_file_descriptor(x.conn))

	intern_atoms(x)
	x.scale = session_scale(x)
	randr_load() // absent is not an error: outputs() then reports one screen
	outputs_refresh(x)
	// On the root: PropertyChange for RESOURCE_MANAGER (Xft.dpi can change
	// while running), StructureNotify because the root resizes when a
	// monitor is plugged in, unplugged or changes mode.
	root_mask := [1]u32{EVENT_MASK_PROPERTY_CHANGE | EVENT_MASK_STRUCTURE_NOTIFY}
	api.change_window_attributes(x.conn, x.screen.root, CW_EVENT_MASK, raw_data(root_mask[:]))

	efd, eerr := linux.eventfd(0, {.CLOEXEC, .NONBLOCK})
	if eerr != .NONE do return false, "eventfd failed"
	x.wake_fd = linux.Fd(efd)

	x.surfaces = make([dynamic]^Surface, x.allocator)
	x.queue = make([dynamic]platform.Event, x.allocator)
	x.out = make([dynamic]platform.Event, x.allocator)
	if virtual.arena_init_growing(&x.text) != nil do return false, "text arena allocation failed"

	xdg_start(x)
	watch_start(x)
	x.locale = xdg.locale_read(x.allocator)
	if !keyboard_start(x) do debugf(x, "no keyboard: keys will not reach the app")
	cursor_start(x)
	render_start(x)
	present_start(x)
	xi2_start(x)
	ime_start(x)
	clipboard_start(x)
	xdnd_start(x)

	debugf(x, "connected to %s, fd %d, screen %d: %dx%d px, depth %d",
		os.get_env("DISPLAY", context.temp_allocator), i32(x.fd), x.screen_num,
		x.screen.width_in_pixels, x.screen.height_in_pixels, x.screen.root_depth)
	debugf(x, "session scale %.2f (Xft.dpi)", x.scale)
	return true, ""
}

@(private)
shutdown :: proc(b: ^platform.Backend) {
	x := data(b)
	x.ctx = context
	for s, i in x.surfaces {
		if s != nil do surface_destroy(b, platform.Surface(i + 1))
	}
	delete(x.surfaces)
	xdg_stop(x)
	watch_stop(x)
	outputs_shutdown(x)
	keyboard_stop(x)
	cursor_stop(x)
	render_stop()
	present_stop()
	xi2_stop(x)
	ime_stop(x)
	clipboard_stop(x)
	incr_stop(x)
	xdnd_stop(x)
	drag_out_clear(x)
	selection_wait_stop(x)
	xdg.locale_free(&x.locale, x.allocator)
	if x.wake_fd != 0 do linux.close(x.wake_fd)
	if x.conn != nil do api.disconnect(x.conn)
	virtual.arena_destroy(&x.text)
	delete(x.extra_fds)
	delete(x.queue)
	delete(x.out)
	free(x, x.allocator)
}

// intern_atoms asks for every atom at once and reads the replies after, so
// the round trips overlap instead of queueing one behind another.
@(private)
intern_atoms :: proc(x: ^X11) {
	names := [?]string{
		"WM_PROTOCOLS", "WM_DELETE_WINDOW", "_NET_WM_NAME", "UTF8_STRING", "WM_CLASS",
		"_NET_WM_STATE", "_NET_WM_STATE_FULLSCREEN",
		"_NET_WM_STATE_MAXIMIZED_HORZ", "_NET_WM_STATE_MAXIMIZED_VERT",
		"CLIPBOARD", "TARGETS", "TEXT", "text/plain;charset=utf-8", "INCR",
		"BALDR_SELECTION", "_NET_ACTIVE_WINDOW",
		"XdndAware", "XdndEnter", "XdndPosition", "XdndStatus", "XdndLeave",
		"XdndDrop", "XdndFinished", "XdndSelection", "XdndTypeList", "XdndActionCopy",
		// A drop's answer goes on its own property, so a paste waiting on
		// BALDR_SELECTION never takes a drop's reply; the two can overlap.
		"BALDR_DROP",
	}
	cookies: [len(names)]Intern_Atom_Cookie
	for n, i in names {
		cookies[i] = api.intern_atom(x.conn, 0, u16(len(n)), cstring(raw_data(n)))
	}
	out: [len(names)]Atom
	for i in 0 ..< len(names) {
		err: ^Generic_Error
		reply := api.intern_atom_reply(x.conn, cookies[i], &err)
		if reply != nil {
			out[i] = reply.atom
			free_reply(reply)
		}
		free_reply(err)
	}
	x.atoms = {
		wm_protocols = out[0], wm_delete_window = out[1], net_wm_name = out[2],
		utf8_string = out[3], wm_class = out[4], net_wm_state = out[5],
		net_wm_state_fullscreen = out[6],
		net_wm_state_maximized_horz = out[7], net_wm_state_maximized_vert = out[8],
		clipboard = out[9], targets = out[10], text = out[11],
		text_plain_utf8 = out[12], incr = out[13], baldr_selection = out[14],
		net_active_window = out[15],
		xdnd_aware = out[16], xdnd_enter = out[17], xdnd_position = out[18],
		xdnd_status = out[19], xdnd_leave = out[20], xdnd_drop = out[21],
		xdnd_finished = out[22], xdnd_selection = out[23], xdnd_type_list = out[24],
		xdnd_action_copy = out[25], baldr_drop = out[26],
	}
}

// ---------------------------------------------------------------- vulkan

@(private)
vk_instance_extensions :: proc(b: ^platform.Backend) -> []cstring {
	@(static) exts := [2]cstring{"VK_KHR_surface", "VK_KHR_xcb_surface"}
	return exts[:]
}

@(private)
vk_create_surface :: proc(b: ^platform.Backend, s: platform.Surface, instance: vk.Instance) -> (vk.SurfaceKHR, bool) {
	x := data(b)
	ss := get_surface(x, s)
	if ss == nil || vk.CreateXcbSurfaceKHR == nil do return 0, false
	info := vk.XcbSurfaceCreateInfoKHR{
		sType      = .XCB_SURFACE_CREATE_INFO_KHR,
		connection = (^vk.xcb_connection_t)(x.conn),
		window     = vk.xcb_window_t(ss.window),
	}
	out: vk.SurfaceKHR
	if res := vk.CreateXcbSurfaceKHR(instance, &info, nil, &out); res != .SUCCESS {
		debugf(x, "vkCreateXcbSurfaceKHR: %v", res)
		return 0, false
	}
	return out, true
}

// ---------------------------------------------------------------- surfaces

@(private)
get_surface :: proc(x: ^X11, id: platform.Surface) -> ^Surface {
	i := int(id) - 1
	if i < 0 || i >= len(x.surfaces) do return nil
	return x.surfaces[i]
}

@(private)
surface_of_window :: proc(x: ^X11, w: Window) -> ^Surface {
	for s in x.surfaces do if s != nil && s.window == w do return s
	return nil
}

@(private)
surface_create :: proc(b: ^platform.Backend, desc: platform.Surface_Desc) -> (platform.Surface, bool) {
	x := data(b)
	if x.conn == nil || x.screen == nil do return 0, false

	w, h := u16(desc.size.x), u16(desc.size.y)
	if w == 0 do w = 640
	if h == 0 do h = 480

	wid := Window(api.generate_id(x.conn))
	// No background, and NorthWest gravity to keep the old pixels. A
	// background makes the server paint the window on every resize before
	// we present at the new size, and the default Forget gravity paints all
	// of it, so dragging an edge flashes. Every pixel comes from the GPU.
	values := [3]u32{
		BACK_PIXMAP_NONE,
		GRAVITY_NORTH_WEST,
		EVENT_MASK_EXPOSURE | EVENT_MASK_STRUCTURE_NOTIFY | EVENT_MASK_FOCUS_CHANGE |
		EVENT_MASK_PROPERTY_CHANGE | EVENT_MASK_KEY_PRESS | EVENT_MASK_KEY_RELEASE |
		EVENT_MASK_BUTTON_PRESS | EVENT_MASK_BUTTON_RELEASE | EVENT_MASK_POINTER_MOTION |
		EVENT_MASK_ENTER_WINDOW | EVENT_MASK_LEAVE_WINDOW,
	}
	// Where it asked to open. The coordinates alone are ignored by most
	// window managers, so wm_normal_hints below carries US_POSITION too.
	px, py: i16
	if p, want := desc.position.?; want {
		px, py = i16(p.x), i16(p.y)
	}
	api.create_window(x.conn, COPY_FROM_PARENT, wid, x.screen.root,
		px, py, w, h, 0, WINDOW_CLASS_INPUT_OUTPUT, x.screen.root_visual,
		CW_BACK_PIXMAP | CW_BIT_GRAVITY | CW_EVENT_MASK, raw_data(values[:]))
	// Where it asked to be, and how large it may be dragged. `fixed_size`
	// pins both limits to the opening size, as on Wayland.
	min_size, max_size := desc.min_size, desc.max_size
	if desc.fixed_size do min_size, max_size = {f32(w), f32(h)}, {f32(w), f32(h)}
	pos: Maybe([2]i16)
	if _, want := desc.position.?; want do pos = [2]i16{px, py}
	wm_normal_hints(x, wid, pos, {w, h},
		{u16(max(min_size.x, 0)), u16(max(min_size.y, 0))},
		{u16(max(max_size.x, 0)), u16(max(max_size.y, 0))})

	ss := new(Surface, x.allocator)
	ss.x, ss.window, ss.kind = x, wid, desc.kind
	ss.size_px = {u32(w), u32(h)}
	ss.live = true

	// a free slot, or a new one
	id := -1
	for s, i in x.surfaces do if s == nil { id = i; break }
	if id < 0 {
		append(&x.surfaces, ss)
		id = len(x.surfaces) - 1
	} else {
		x.surfaces[id] = ss
	}
	ss.id = platform.Surface(id + 1)

	set_title(x, ss, desc.title)
	set_class(x, ss, desc.app_id)
	set_icon(x, ss, desc.icon)
	if p := get_surface(x, desc.parent); p != nil && desc.kind == .Window {
		// WM_TRANSIENT_FOR: kept above its parent and minimised with it
		parent := u32(p.window)
		api.change_property(x.conn, PROP_MODE_REPLACE, ss.window, ATOM_WM_TRANSIENT_FOR, ATOM_WINDOW, 32, 1, &parent)
	}
	// Without WM_DELETE_WINDOW the close button kills the connection rather
	// than telling the app: the X equivalent of pulling the plug.
	if x.atoms.wm_protocols != ATOM_NONE && x.atoms.wm_delete_window != ATOM_NONE {
		d := x.atoms.wm_delete_window
		api.change_property(x.conn, PROP_MODE_REPLACE, wid, x.atoms.wm_protocols, ATOM_ATOM, 32, 1, &d)
	}

	xdnd_advertise(x, wid) // without this a drag passes over us as though we were the desktop
	xi2_watch(x, wid)      // smooth scrolling, where the server has it (xinput2.odin)
	// Opened maximised: the state is set as a property before mapping. The
	// _NET_WM_STATE client message is honoured only once mapped, so it would
	// show the small size first and then snap out.
	if desc.maximized && desc.kind == .Window && x.atoms.net_wm_state != ATOM_NONE &&
	   x.atoms.net_wm_state_maximized_horz != ATOM_NONE && x.atoms.net_wm_state_maximized_vert != ATOM_NONE {
		states := [2]Atom{x.atoms.net_wm_state_maximized_horz, x.atoms.net_wm_state_maximized_vert}
		api.change_property(x.conn, PROP_MODE_REPLACE, wid, x.atoms.net_wm_state, ATOM_ATOM, 32, 2, &states[0])
	}
	api.map_window(x.conn, wid)
	api.flush(x.conn)
	debugf(x, "surface %d created (%v, window %d, %dx%d)", ss.id, desc.kind, u32(wid), w, h)
	return ss.id, true
}

@(private)
surface_destroy :: proc(b: ^platform.Backend, id: platform.Surface) {
	x := data(b)
	ss := get_surface(x, id)
	if ss == nil do return
	ss.live = false
	idle_release(x, ss) // a window that closes while playing stops asking
	if x.kbd_focus == ss do x.kbd_focus = nil
	if ss.window != WINDOW_NONE {
		api.destroy_window(x.conn, ss.window)
		api.flush(x.conn)
	}
	delete(ss.title, x.allocator)
	x.surfaces[int(id) - 1] = nil
	free(ss, x.allocator)
}

@(private)
surface_set_title :: proc(b: ^platform.Backend, id: platform.Surface, title: string) {
	x := data(b)
	ss := get_surface(x, id)
	if ss == nil do return
	set_title(x, ss, title)
	api.flush(x.conn)
}

@(private)
set_title :: proc(x: ^X11, ss: ^Surface, title: string) {
	t := title if title != "" else "Baldr"
	if ss.title != t {
		delete(ss.title, x.allocator)
		ss.title = strings.clone(t, x.allocator)
	}
	// WM_NAME is Latin-1 by the letter of ICCCM and the fallback in
	// practice; _NET_WM_NAME is UTF-8 and what a modern WM reads.
	api.change_property(x.conn, PROP_MODE_REPLACE, ss.window, ATOM_WM_NAME, ATOM_STRING, 8, u32(len(t)), raw_data(t))
	if x.atoms.net_wm_name != ATOM_NONE && x.atoms.utf8_string != ATOM_NONE {
		api.change_property(x.conn, PROP_MODE_REPLACE, ss.window, x.atoms.net_wm_name, x.atoms.utf8_string, 8, u32(len(t)), raw_data(t))
	}
}

// set_icon writes _NET_WM_ICON: width, height, then the ARGB words, the
// form every EWMH window manager and taskbar reads.
@(private)
set_icon :: proc(x: ^X11, ss: ^Surface, icon: platform.Window_Icon) {
	if icon.w <= 0 || icon.h <= 0 || len(icon.argb) < icon.w * icon.h do return
	prop := intern(x, "_NET_WM_ICON")
	if prop == ATOM_NONE do return
	words := make([]u32, 2 + icon.w * icon.h, context.temp_allocator)
	words[0], words[1] = u32(icon.w), u32(icon.h)
	copy(words[2:], icon.argb[:icon.w * icon.h])
	api.change_property(x.conn, PROP_MODE_REPLACE, ss.window, prop, ATOM_CARDINAL, 32, u32(len(words)), raw_data(words))
}

// surface_set_dark writes _GTK_THEME_VARIANT, "dark" or "light": how a
// window tells an X window manager the theme it is drawn in, so the frame
// can match. A manager that does not read it ignores it
// (Backend.surface_set_dark).
@(private)
surface_set_dark :: proc(b: ^platform.Backend, id: platform.Surface, dark: bool) {
	x := data(b)
	ss := get_surface(x, id)
	if ss == nil || x.atoms.utf8_string == ATOM_NONE do return
	prop := intern(x, "_GTK_THEME_VARIANT")
	if prop == ATOM_NONE do return
	v := "dark" if dark else "light"
	api.change_property(x.conn, PROP_MODE_REPLACE, ss.window, prop, x.atoms.utf8_string, 8, u32(len(v)), raw_data(v))
	api.flush(x.conn)
}

// set_class writes WM_CLASS, which is instance then class, each
// NUL-terminated. A desktop matches a window to its .desktop file by it, so
// it is the app id or nothing useful.
@(private)
set_class :: proc(x: ^X11, ss: ^Surface, app_id: string) {
	if x.atoms.wm_class == ATOM_NONE do return
	id := app_id if app_id != "" else "baldr"
	buf := strings.builder_make(context.temp_allocator)
	strings.write_string(&buf, id)
	strings.write_byte(&buf, 0)
	strings.write_string(&buf, id)
	strings.write_byte(&buf, 0)
	s := strings.to_string(buf)
	api.change_property(x.conn, PROP_MODE_REPLACE, ss.window, x.atoms.wm_class, ATOM_STRING, 8, u32(len(s)), raw_data(s))
}

@(private)
surface_geometry :: proc(b: ^platform.Backend, id: platform.Surface) -> (size: [2]f32, size_px: [2]u32, scale: f32) {
	x := data(b)
	ss := get_surface(x, id)
	if ss == nil do return {}, {}, 1
	// X has one DPI for the whole session and no per-window scale, so every
	// window shares `x.scale` (props.odin).
	sc := x.scale if x.scale > 0 else 1
	return {f32(ss.size_px.x) / sc, f32(ss.size_px.y) / sc}, ss.size_px, sc
}

@(private)
surface_set_size :: proc(b: ^platform.Backend, id: platform.Surface, size: [2]f32) {
	x := data(b)
	ss := get_surface(x, id)
	if ss == nil || size.x <= 0 || size.y <= 0 do return
	wh := [2]u32{u32(size.x), u32(size.y)}
	api.configure_window(x.conn, ss.window, CONFIG_WINDOW_WIDTH | CONFIG_WINDOW_HEIGHT, raw_data(wh[:]))
	api.flush(x.conn)
}

@(private)
surface_request_frame :: proc(b: ^platform.Backend, id: platform.Surface) {
	ss := get_surface(data(b), id)
	if ss != nil do ss.frame_requested = true
}

// surface_post_close asks for this surface to close as if its frame's close
// button had been pressed.
@(private)
surface_post_close :: proc(b: ^platform.Backend, id: platform.Surface) {
	x := data(b)
	ss := get_surface(x, id)
	if ss != nil && ss.live do append(&x.queue, platform.Ev_Close{surface = ss.id, reason = .User})
}

// drawable_create: this backend's renderer draws into a VkSurfaceKHR, so the
// neutral handle is one. `renderer` is the VkInstance it needs to make it.
@(private)
drawable_create :: proc(b: ^platform.Backend, s: platform.Surface, renderer: rawptr) -> (uintptr, bool) {
	surf, ok := vk_create_surface(b, s, vk.Instance(renderer))
	return uintptr(surf), ok
}
