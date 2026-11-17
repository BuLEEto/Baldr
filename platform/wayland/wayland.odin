#+build linux
// Package wayland is Baldr's Wayland backend: it fills a platform.Backend
// using libwayland-client (loaded at runtime by baldr:platform/wayland/wl)
// and libxkbcommon (xkb.odin). Everything the toolkit sees is in logical
// pixels; the compositor's fractional scale is applied through
// wp_fractional_scale_v1 + wp_viewporter so the swapchain is `size_px` while
// the surface stays `size` logical.
//
// Threading: single-threaded except `wake`, which only writes an eventfd.
// Event pump: Mesa's Vulkan WSI shares our
// wl_display and commits on our wl_surface from inside vkQueuePresentKHR, so
// the pump is prepare_read → flush → poll → read_events/cancel_read →
// dispatch_pending, never wl_display_dispatch.
//
// Set BALDR_WAYLAND_DEBUG=1 to log globals, configures, and scale changes.
package wayland

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:c/libc"
import "core:sys/linux"
import "core:time"
import vk "vendor:vulkan"
import "baldr:dbus" // only for the bus descriptor in the poll set
import "baldr:platform"
import "baldr:platform/xkb"
import wl "baldr:platform/wayland/wl"
import "baldr:platform/xdg"

// Output is a bound wl_output.
Output :: struct {
	name:      u32, // registry name
	proxy:     wl.Proxy,
	scale:     i32,
	pos:       [2]i32,
	mode_px:   [2]i32,
	refresh:   i32, // mHz
	out_name:  string, // wl_output.name (v4)
	listener:  wl.Wl_Output_Listener,
	st:        ^State,
	done:      bool,
	transform:    wl.Wl_Output_Transform,
	make_model:   string, // wl_output.geometry: the description when nothing better comes
	description:  string, // wl_output.description (v4) or xdg-output
	xdg:          wl.Proxy, // zxdg_output_v1, when the manager exists
	xdg_l:        wl.Zxdg_Output_V1_Listener,
	logical_pos:  [2]i32,
	logical_size: [2]i32, // 0 until xdg-output says
}

// State is the backend's private data (platform.Backend.data).
State :: struct {
	ctx:      runtime.Context, // context the backend was created with; used inside "c" callbacks
	debug:    bool,

	display:  wl.Proxy,
	registry: wl.Proxy,
	fd:       linux.Fd,

	// globals
	compositor:      wl.Proxy,
	wm_base:         wl.Proxy,
	seat:            wl.Proxy,
	shortcuts_mgr:   wl.Proxy, // zwp_keyboard_shortcuts_inhibit_manager_v1, nil when the compositor has none
	idle_mgr:        wl.Proxy, // zwp_idle_inhibit_manager_v1, nil when the compositor has none (idle.odin)
	fractional_mgr:  wl.Proxy,
	viewporter:      wl.Proxy,
	shm:             wl.Proxy, // wl_shm: a cursor picture's pixels (cursor_picture.odin)
	cursor_surface:  wl.Proxy, // the pointer's cursor picture
	cursor_viewport: wl.Proxy,
	cursor_shape_mgr: wl.Proxy,
	activation:       wl.Proxy, // xdg_activation_v1: a window brought forward (activation.odin)
	exporter:         wl.Proxy, // zxdg_exporter_v2: a window named to another program, a dialog's parent (export.odin)
	tablet_mgr:       wl.Proxy, // zwp_tablet_manager_v2: pens (tablet.odin)
	tablet_seat:      wl.Proxy,
	tools:            [dynamic]^Tool_State,
	launch_token:     string,   // XDG_ACTIVATION_TOKEN this process was started with, for its first window; owned
	decoration_mgr:  wl.Proxy,
	layer_shell:     wl.Proxy,
	lock_mgr:        wl.Proxy,          // ext_session_lock_manager_v1, may be nil (lock.odin)
	lock:            ^Lock_State,       // this app's live session lock, nil when none
	locks_withdrawn: [dynamic]^Lock_State, // unlocked before the compositor answered: ended when it does
	unlock_sent:     bool,              // an unlock_and_destroy went out: shutdown makes sure it arrives
	locale:          platform.Locale, // read from libc at init (locale.odin)
	bg_effect_mgr:   wl.Proxy, // ext_background_effect_manager_v1, may be nil
	bg_effect_l:     wl.Ext_Background_Effect_Manager_V1_Listener,
	blur_ok:         bool,     // the manager's capabilities event said Blur
	backdrop_mgr:    wl.Proxy, // rikkiti_backdrop_manager_v1, may be nil: how bright blurred surfaces' backdrops are
	applet_mgr:      wl.Proxy, // rikkiti_applet_manager_v1, may be nil: applet surfaces inside a shell's bars
	applet_host:     wl.Proxy, // rikkiti_applet_host_v1, may be nil: a bar's slots for other programs' applets (slots.odin)
	slots:           [dynamic]^Slot_State,
	next_slot:       u32,
	// windows and workspaces for a taskbar (taskbar.odin)
	toplevel_mgr:       wl.Proxy, // zwlr_foreign_toplevel_manager_v1, may be nil
	toplevel_mgr_l:     wl.Zwlr_Foreign_Toplevel_Manager_V1_Listener,
	toplevels:          [dynamic]^Toplevel_State,
	toplevels_view:     [dynamic]platform.Toplevel, // Backend.toplevels' answer, rebuilt when asked
	toplevels_changed:  bool,                       // a `done` came: pump says so once
	next_toplevel:      u64,
	workspace_mgr:      wl.Proxy, // ext_workspace_manager_v1, may be nil
	workspace_mgr_l:    wl.Ext_Workspace_Manager_V1_Listener,
	ws_groups:          [dynamic]^Ws_Group,
	ws_list:            [dynamic]^Ws_State,
	workspaces_view:    [dynamic]platform.Workspace,
	workspaces_changed: bool,
	next_workspace:     u64,
	outputs:         [dynamic]^Output,
	outputs_view:    [dynamic]platform.Output, // Backend.outputs' answer, rebuilt when asked
	outputs_changed: bool,                     // a screen was added, removed or changed: pump says so
	xdg_output_mgr:  wl.Proxy,                 // zxdg_output_manager_v1, may be nil

	// listeners need stable addresses for the life of the proxy
	registry_l: wl.Wl_Registry_Listener,
	wm_base_l:  wl.Xdg_Wm_Base_Listener,
	seat_l:     wl.Wl_Seat_Listener,
	pointer_l:  wl.Wl_Pointer_Listener,
	touch:       wl.Proxy,
	touch_l:     wl.Wl_Touch_Listener,
	touch_focus: ^Surface_State, // surface of the current touch sequence
	keyboard_l: wl.Wl_Keyboard_Listener,

	surfaces: [dynamic]^Surface_State, // index + 1 = platform.Surface; nil = free slot

	// input
	pointer:          wl.Proxy,
	keyboard:         wl.Proxy,
	cursor_device:    wl.Proxy, // wp_cursor_shape_device_v1 for `pointer`
	ptr_focus:        ^Surface_State,
	ptr_pos:          [2]f32,
	ptr_enter_serial: u32,
	kbd_enter_serial: u32, // the keyboard's latest enter: a popup's grab before any input goes with it
	input_serial:     u32, // last key / button / touch serial: proof of a user action for set_selection
	scroll:           Scroll_Acc,
	keys:              xkb.Xkb,
	kbd_focus:        ^Surface_State,
	kbd_info:         xkb.Xkb_Keyboard, // the lock keys and layout last told (keyboard_sync)
	mods:             platform.Mods,
	repeat_rate:      i32, // keys per second, 0 = off
	repeat_delay:     i32, // ms
	repeat_keycode:   u32, // xkb keycode currently repeating, 0 = none
	repeat_fd:        linux.Fd,
	wake_fd:          linux.Fd,
	extra_fds:        [4]linux.Fd, // fds the toolkit asked us to poll (watch_fd): the accessibility bus; -1 = empty
	cursor_warned:    bool,
	cursor_themes:    Cursor_Themes, // the desktop's cursor theme, where there is no cursor-shape protocol (cursor_theme.odin)

	// Events accumulate in `pending` (from listeners during dispatch, or from
	// surface_request_frame between pumps) and move to `out`, which is what
	// pump returns and what the caller owns until the next pump. Strings in
	// events live in text_arena, freed at the top of pump unless events
	// queued outside one (a keymap during init's roundtrips) still wait.
	pending:    [dynamic]platform.Event,
	out:        [dynamic]platform.Event,
	text_arena: virtual.Arena,
	lost:       bool, // display error already reported as Ev_Quit

	// clipboard (clipboard.odin): the seat's data device, the offers it
	// announces, the one that is the selection, and our own source
	// input methods (ime.odin)
	ime: Ime,

	data_mgr:      wl.Proxy, // wl_data_device_manager, may be nil
	data_device:   wl.Proxy,
	data_device_l: wl.Wl_Data_Device_Listener,
	offers:        [dynamic]^Data_Offer, // announced, not yet named selection or drag
	selection:     ^Data_Offer,          // nil = empty (or ours: see source)
	dnd_offer:     ^Data_Offer,          // a drag from another client (or our own, back over us): released on leave / finish
	dnd_serial:    u32,                  // its enter serial, for accept
	dnd_surface:   ^Surface_State,       // the surface it is over
	dnd_pos:       [2]f32,               // its last position
	dnd_dropped:   bool,                 // drop came: the offer lives until drag_finish
	drag_source:   wl.Proxy,             // our outgoing drag's data source
	drag_source_l: wl.Wl_Data_Source_Listener,
	drag_items:    []platform.Clip_Item, // what it offers (owned)
	drag_action:   wl.Wl_Data_Device_Manager_Dnd_Action, // what the target chose for it (the source's action event)
	drag_icon:     wl.Proxy,             // the surface the compositor draws beside the pointer while it carries our drag
	drag_icon_pic: Cursor_Picture,       // its buffer, size and scale (the same shm picture a cursor uses)
	drag_icon_vp:  wl.Proxy,             // its viewport, where there is a viewporter to size it in logical px
	dnd_read:          [dynamic]u8, // a drop's data, read from its pipe between events (drag_receive)
	dnd_read_fd:       linux.Fd,
	dnd_reading:       bool,
	dnd_read_deadline: time.Tick,   // gives up when the source writes nothing more by then
	source:        wl.Proxy,             // our selection, nil when another client owns it
	source_l:      wl.Wl_Data_Source_Listener,
	source_items:  []platform.Clip_Item, // what `source` offers, one per mime (owned)
	primary:       Primary,              // the primary selection, pasted with a middle click (primary.odin)

	inotify: platform.Inotify, // file watches (platform/inotify_linux.odin); fd -1 when unavailable

	// The desktop's own services — the Settings portal's theme, desktop
	// notifications, opening links and files, the file chooser — over the
	// session bus. None of it is Wayland's, so none of it lives here:
	// platform/xdg owns the lot and the X11 backend will use the same copy.
	// Wired up in xdg.odin.
	xdg: xdg.Xdg,

	flush_pending: bool, // a wl_display_flush could not send it all: poll for writability and flush again

	app_id:        string, // the first surface's, which is what a notification is signed with (owned)
	alloc:         runtime.Allocator,
}

// backend allocates a Wayland platform.Backend. Call `init` through it; the
// returned pointer and its data are freed by `shutdown`.
backend :: proc(allocator := context.allocator) -> ^platform.Backend {
	b := new(platform.Backend, allocator)
	st := new(State, allocator)
	st.alloc = allocator
	b.name = "wayland"
	b.data = st
	b.init = init
	b.shutdown = shutdown
	b.vk_instance_extensions = vk_instance_extensions
	b.vk_create_surface = vk_create_surface
	b.drawable_create = drawable_create
	b.surface_create = surface_create
	b.surface_destroy = surface_destroy
	b.surface_set_title = surface_set_title
	b.surface_set_cursor = surface_set_cursor
	b.surface_set_cursor_image = surface_set_cursor_image
	b.open_url = open_url
	b.notify = notify
	b.frames_wanted = frames_wanted
	b.notify_close = notify_close
	b.tray_set = tray_set       // StatusNotifierItem + dbusmenu (xdg/tray.odin)
	b.tray_remove = tray_remove
	b.open_path = open_path
	b.surface_set_size = surface_set_size
	b.session_lock = session_lock
	b.session_unlock = session_unlock
	b.surface_request_frame = surface_request_frame
	b.surface_geometry = surface_geometry
	b.surface_set_backdrop = surface_set_backdrop
	b.surface_set_layer = surface_set_layer
	b.surface_set_input_region = surface_set_input_region
	b.surface_set_blur_region = surface_set_blur_region
	b.surface_set_applet = surface_set_applet
	b.surface_set_size_hint = surface_set_size_hint
	b.toplevels = backend_toplevels
	b.toplevel_request = toplevel_request
	b.toplevel_set_rectangle = toplevel_set_rectangle
	b.workspaces = backend_workspaces
	b.workspace_request = workspace_request
	b.slot_create = slot_create
	b.slot_set_geometry = slot_set_geometry
	b.slot_destroy = slot_destroy
	b.popup_create = popup_create
	b.popup_reposition = popup_reposition
	b.pump = pump
	b.outputs = backend_outputs
	b.wake = wake
	b.system_theme = system_theme
	b.file_dialog = file_dialog // portal hook: FileChooser
	b.clipboard_get = clipboard_get
	b.clipboard_set = clipboard_set
	b.primary_get = primary_get
	b.primary_set = primary_set
	b.ime_set = ime_set
	b.clipboard_types = clipboard_types
	b.clipboard_get_data = clipboard_get_data
	b.clipboard_set_data = clipboard_set_data
	b.clipboard_read = clipboard_read
	b.watch_fd = watch_fd
	b.surface_ack_configure = surface_ack_configure
	b.surface_set_fullscreen = surface_set_fullscreen
	b.surface_act = surface_act
	b.surface_post_close = surface_post_close
	b.inhibit_shortcuts = inhibit_shortcuts
	b.keep_awake = keep_awake
	b.activate = surface_activate
	b.key_name = key_name
	b.watch = watch
	b.unwatch = unwatch
	b.drag_start = drag_start
	b.drag_accept = drag_accept
	b.drag_receive = drag_receive
	b.drag_finish = drag_finish
	b.locale = locale
	return b
}

@(private)
state :: #force_inline proc(b: ^platform.Backend) -> ^State { return (^State)(b.data) }

// watch_fd adds an fd to the poll set, or takes it out (see Backend.watch_fd).
@(private)
watch_fd :: proc(b: ^platform.Backend, fd: i32, on: bool) {
	st := state(b)
	want := linux.Fd(fd)
	for &slot in st.extra_fds {
		if slot == want { // already there: take it out, or leave it
			if !on do slot = -1
			return
		}
	}
	if !on do return
	for &slot in st.extra_fds {
		if slot < 0 {
			slot = want
			return
		}
	}
	debugf(st, "watch_fd: no room for fd %d", fd)
}

@(private)
debugf :: proc(st: ^State, format: string, args: ..any) {
	if !st.debug do return
	fmt.eprintf("baldr/wayland: ")
	fmt.eprintfln(format, ..args)
}

@(private)
push :: proc(st: ^State, ev: platform.Event) {
	append(&st.pending, ev)
}

// text_allocator: strings inside events live here until the next pump.
@(private)
text_allocator :: proc(st: ^State) -> runtime.Allocator {
	return virtual.arena_allocator(&st.text_arena)
}

// ------------------------------------------------------------------ init

@(private)
init :: proc(b: ^platform.Backend) -> (ok: bool, why: string) {
	st := state(b)
	st.ctx = context
	st.debug = os.get_env("BALDR_WAYLAND_DEBUG", context.temp_allocator) == "1"

	if lok, missing := wl.load(); !lok {
		return false, fmt.tprintf("libwayland-client not usable (missing %v)", missing)
	}
	st.display = wl.display_connect()
	if st.display == nil {
		return false, "wl_display_connect failed (is WAYLAND_DISPLAY set?)"
	}
	st.fd = linux.Fd(wl.display_get_fd(st.display))
	// the token a launcher started this process with brings its first window
	// forward; not handed on to what it starts in turn
	if tok := os.get_env("XDG_ACTIVATION_TOKEN", context.temp_allocator); tok != "" {
		st.launch_token = strings.clone(tok)
		os.unset_env("XDG_ACTIVATION_TOKEN")
	}

	st.pending = make([dynamic]platform.Event)
	st.out = make([dynamic]platform.Event)
	st.surfaces = make([dynamic]^Surface_State)
	st.outputs = make([dynamic]^Output)
	if err := virtual.arena_init_growing(&st.text_arena); err != nil {
		return false, "text arena allocation failed"
	}

	efd, eerr := linux.eventfd(0, {.CLOEXEC, .NONBLOCK})
	if eerr != .NONE do return false, "eventfd failed"
	st.wake_fd = efd
	st.extra_fds = {-1, -1, -1, -1} // poll ignores -1; 0 would be stdin
	tfd, terr := linux.timerfd_create(.MONOTONIC, {.CLOEXEC, .NONBLOCK})
	if terr != .NONE do return false, "timerfd_create failed"
	st.repeat_fd = tfd

	if xok, miss := xkb.load(&st.keys); !xok {
		debugf(st, "libxkbcommon unavailable (%s): keys report Key.Unknown and no text", miss)
	}

	st.registry = wl.wl_display_get_registry(st.display)
	st.registry_l = wl.wl_registry_listener_noop()
	st.registry_l.global = on_global
	st.registry_l.global_remove = on_global_remove
	wl.wl_registry_add_listener(st.registry, &st.registry_l, st)
	// Two roundtrips: the first delivers the globals (and binds them), the
	// second delivers the bound objects' initial events (seat capabilities,
	// output geometry) so surface_create sees a complete picture.
	wl.display_roundtrip(st.display)
	clipboard_init(st) // the data device's first events ride the second roundtrip
	primary_init(st)   // …and the primary selection's
	ime_init(st)       // …and the text input's, when the compositor relays input methods
	tablet_init(st)    // …and the pens the seat has (tablet.odin)
	wl.display_roundtrip(st.display)

	if st.compositor == nil do return false, "compositor lacks wl_compositor"
	if st.wm_base == nil do return false, "compositor lacks xdg_wm_base"
	if wl.proxy_version(st.compositor) < 4 do return false, "wl_compositor v4+ required"

	xdg_wire(st)
	xdg.init(&st.xdg) // the session bus, appearance and notifications (never fatal)
	if !platform.inotify_open(&st.inotify) do debugf(st, "inotify unavailable: file watches report nothing")
	st.locale = xdg.locale_read()
	debugf(st, "locale %s: dates %s, first weekday %d, %s, decimal %q", st.locale.tag, st.locale.date_format, st.locale.first_weekday, "24h" if st.locale.time_24h else "12h", st.locale.decimal)

	b.caps = {.Transparent}
	if st.layer_shell != nil do b.caps += {.Layer_Shell}
	if st.lock_mgr != nil do b.caps += {.Session_Lock}
	if st.wm_base != nil do b.caps += {.Popups}
	if st.backdrop_mgr != nil do b.caps += {.Backdrop_Luminance}
	if st.applet_mgr != nil do b.caps += {.Applets}
	if st.applet_host != nil do b.caps += {.Applet_Slots}
	if st.toplevel_mgr != nil do b.caps += {.Toplevels}
	if st.workspace_mgr != nil do b.caps += {.Workspaces}
	b.caps = blur_caps(st, b.caps)
	st.outputs_changed = false // the toolkit reads the startup set itself (windows and workspaces may still be arriving: their first pump says so)

	debugf(st, "connected fd=%d; xdg_wm_base v%d, seat=%v, fractional=%v, viewporter=%v, cursor_shape=%v, decoration=%v, layer_shell=%v, session_lock=%v, blur=%v, backdrops=%v, applets=%v, windows=%v (%d), workspaces=%v (%d), clipboard=%v, outputs=%d",
		st.fd, wl.proxy_version(st.wm_base), st.seat != nil, st.fractional_mgr != nil, st.viewporter != nil,
		st.cursor_shape_mgr != nil, st.decoration_mgr != nil, st.layer_shell != nil, st.lock_mgr != nil, .Backdrop_Blur in b.caps, .Backdrop_Luminance in b.caps, .Applets in b.caps,
		.Toplevels in b.caps, len(st.toplevels), .Workspaces in b.caps, len(st.ws_list), st.data_device != nil, len(st.outputs))
	for o in st.outputs {
		debugf(st, "output %s: %dx%d@%dmHz scale %d at %v", o.out_name, o.mode_px.x, o.mode_px.y, o.refresh, o.scale, o.pos)
	}
	return true, ""
}

@(private)
shutdown :: proc(b: ^platform.Backend) {
	st := state(b)
	lock_shutdown(st) // first, while everything its dispatch reaches is alive; it never unlocks
	delete(st.launch_token)
	st.launch_token = ""
	tablet_shutdown(st)
	cursor_picture_shutdown(st)
	cursor_themes_shutdown(st) // after the cursor surface: the theme owns the buffers it showed
	xdg.shutdown(&st.xdg) // the openers still running, the bus, the notification table
	xdg.locale_free(&st.locale)
	for s in st.surfaces {
		if s != nil do surface_teardown(st, s)
	}
	delete(st.surfaces)
	clipboard_teardown(st)
	primary_teardown(st)
	ime_teardown(st)
	delete(st.app_id, st.alloc)
	platform.inotify_close(&st.inotify)
	input_teardown(st)
	xkb.unload(&st.keys)
	for o in st.outputs {
		if o.xdg != nil do wl.zxdg_output_v1_destroy(o.xdg)
		if o.proxy != nil do wl.wl_output_release(o.proxy)
		delete(o.out_name)
		delete(o.make_model)
		delete(o.description)
		free(o)
	}
	delete(st.outputs)
	delete(st.outputs_view)
	destroy_global :: proc(p: ^wl.Proxy, destroy: proc "contextless" (p: wl.Proxy)) {
		if p^ != nil do destroy(p^)
		p^ = nil
	}
	destroy_global(&st.cursor_shape_mgr, wl.wp_cursor_shape_manager_v1_destroy)
	destroy_global(&st.exporter, wl.zxdg_exporter_v2_destroy)
	destroy_global(&st.decoration_mgr, wl.zxdg_decoration_manager_v1_destroy)
	destroy_global(&st.fractional_mgr, wl.wp_fractional_scale_manager_v1_destroy)
	destroy_global(&st.viewporter, wl.wp_viewporter_destroy)
	destroy_global(&st.layer_shell, wl.zwlr_layer_shell_v1_destroy)
	destroy_global(&st.bg_effect_mgr, wl.ext_background_effect_manager_v1_destroy)
	destroy_global(&st.backdrop_mgr, wl.rikkiti_backdrop_manager_v1_destroy)
	destroy_global(&st.applet_mgr, wl.rikkiti_applet_manager_v1_destroy)
	slots_shutdown(st)
	taskbar_shutdown(st)
	destroy_global(&st.xdg_output_mgr, wl.zxdg_output_manager_v1_destroy)
	destroy_global(&st.wm_base, wl.xdg_wm_base_destroy)
	if st.seat != nil do wl.wl_seat_release(st.seat)
	if st.compositor != nil do wl.proxy_destroy(st.compositor)
	if st.registry != nil do wl.proxy_destroy(st.registry)
	// The lock object is never sent anything here: a live lock outlives
	// the connection, and the compositor keeps the session hidden.
	if st.display != nil {
		wl.display_flush(st.display)
		wl.display_disconnect(st.display)
	}
	lock_free(st)
	if st.wake_fd != 0 do linux.close(st.wake_fd)
	if st.repeat_fd != 0 do linux.close(st.repeat_fd)
	delete(st.pending)
	delete(st.out)
	virtual.arena_destroy(&st.text_arena)
	free(st)
	free(b)
}

// -------------------------------------------------------------- registry

@(private)
on_global :: proc "c" (data: rawptr, reg: wl.Proxy, name: u32, iface: cstring, version: u32) {
	st := (^State)(data)
	context = st.ctx
	switch string(iface) {
	case "wl_compositor":
		st.compositor = wl.wl_registry_bind(reg, name, &wl.wl_compositor_interface, min(version, wl.WL_COMPOSITOR_VERSION))
	case "wl_shm":
		st.shm = wl.wl_registry_bind(reg, name, &wl.wl_shm_interface, min(version, 1))
	case "xdg_wm_base":
		st.wm_base = wl.wl_registry_bind(reg, name, &wl.xdg_wm_base_interface, min(version, wl.XDG_WM_BASE_VERSION))
		st.wm_base_l = wl.xdg_wm_base_listener_noop()
		st.wm_base_l.ping = on_wm_base_ping
		wl.xdg_wm_base_add_listener(st.wm_base, &st.wm_base_l, st)
	case "wl_seat":
		if st.seat != nil do return // one seat is enough for now
		st.seat = wl.wl_registry_bind(reg, name, &wl.wl_seat_interface, min(version, wl.WL_SEAT_VERSION))
		st.seat_l = wl.wl_seat_listener_noop()
		st.seat_l.capabilities = on_seat_capabilities
		wl.wl_seat_add_listener(st.seat, &st.seat_l, st)
	case "zwp_keyboard_shortcuts_inhibit_manager_v1":
		st.shortcuts_mgr = wl.wl_registry_bind(reg, name, &wl.zwp_keyboard_shortcuts_inhibit_manager_v1_interface, 1)
	case "zwp_idle_inhibit_manager_v1":
		st.idle_mgr = wl.wl_registry_bind(reg, name, &wl.zwp_idle_inhibit_manager_v1_interface, 1)
	case "zwp_text_input_manager_v3":
		st.ime.mgr = wl.wl_registry_bind(reg, name, &wl.zwp_text_input_manager_v3_interface, 1)
		ime_init(st)
	case "zwp_primary_selection_device_manager_v1":
		st.primary.mgr = wl.wl_registry_bind(reg, name, &wl.zwp_primary_selection_device_manager_v1_interface, 1)
	case "wl_data_device_manager":
		st.data_mgr = wl.wl_registry_bind(reg, name, &wl.wl_data_device_manager_interface, min(version, wl.WL_DATA_DEVICE_MANAGER_VERSION))
	case "wl_output":
		o := new(Output)
		o.st = st
		o.name = name
		o.scale = 1
		o.proxy = wl.wl_registry_bind(reg, name, &wl.wl_output_interface, min(version, wl.WL_OUTPUT_VERSION))
		o.listener = wl.wl_output_listener_noop()
		o.listener.geometry = on_output_geometry
		o.listener.mode = on_output_mode
		o.listener.scale = on_output_scale
		o.listener.name = on_output_name
		o.listener.done = on_output_done
		o.listener.description = on_output_description
		wl.wl_output_add_listener(o.proxy, &o.listener, o)
		append(&st.outputs, o)
		output_attach_xdg(st, o)
		st.outputs_changed = true
	case "zxdg_output_manager_v1":
		st.xdg_output_mgr = wl.wl_registry_bind(reg, name, &wl.zxdg_output_manager_v1_interface, min(version, wl.ZXDG_OUTPUT_MANAGER_V1_VERSION))
		for o in st.outputs do output_attach_xdg(st, o)
	case "wp_fractional_scale_manager_v1":
		st.fractional_mgr = wl.wl_registry_bind(reg, name, &wl.wp_fractional_scale_manager_v1_interface, 1)
	case "wp_viewporter":
		st.viewporter = wl.wl_registry_bind(reg, name, &wl.wp_viewporter_interface, 1)
	case "zwp_tablet_manager_v2":
		st.tablet_mgr = wl.wl_registry_bind(reg, name, &wl.zwp_tablet_manager_v2_interface, min(version, wl.ZWP_TABLET_MANAGER_V2_VERSION))
	case "xdg_activation_v1":
		st.activation = wl.wl_registry_bind(reg, name, &wl.xdg_activation_v1_interface, min(version, wl.XDG_ACTIVATION_V1_VERSION))
	case "zxdg_exporter_v2":
		st.exporter = wl.wl_registry_bind(reg, name, &wl.zxdg_exporter_v2_interface, min(version, wl.ZXDG_EXPORTER_V2_VERSION))
	case "wp_cursor_shape_manager_v1":
		// BALDR_NO_CURSOR_SHAPE=1 leaves it unbound, to try the theme path
		// (cursor_theme.odin) on a compositor that has the protocol.
		if os.get_env("BALDR_NO_CURSOR_SHAPE", context.temp_allocator) != "" do break
		st.cursor_shape_mgr = wl.wl_registry_bind(reg, name, &wl.wp_cursor_shape_manager_v1_interface, min(version, wl.WP_CURSOR_SHAPE_MANAGER_V1_VERSION))
	case "zxdg_decoration_manager_v1":
		st.decoration_mgr = wl.wl_registry_bind(reg, name, &wl.zxdg_decoration_manager_v1_interface, 1)
	case "zwlr_layer_shell_v1":
		st.layer_shell = wl.wl_registry_bind(reg, name, &wl.zwlr_layer_shell_v1_interface, min(version, wl.ZWLR_LAYER_SHELL_V1_VERSION))
	case "ext_session_lock_manager_v1":
		st.lock_mgr = wl.wl_registry_bind(reg, name, &wl.ext_session_lock_manager_v1_interface, 1)
	case "ext_background_effect_manager_v1":
		st.bg_effect_mgr = wl.wl_registry_bind(reg, name, &wl.ext_background_effect_manager_v1_interface, min(version, wl.EXT_BACKGROUND_EFFECT_MANAGER_V1_VERSION))
		st.bg_effect_l = wl.ext_background_effect_manager_v1_listener_noop()
		st.bg_effect_l.capabilities = on_bg_effect_capabilities
		wl.ext_background_effect_manager_v1_add_listener(st.bg_effect_mgr, &st.bg_effect_l, st)
	case "rikkiti_backdrop_manager_v1":
		st.backdrop_mgr = wl.wl_registry_bind(reg, name, &wl.rikkiti_backdrop_manager_v1_interface, min(version, wl.RIKKITI_BACKDROP_MANAGER_V1_VERSION))
	case "rikkiti_applet_manager_v1":
		st.applet_mgr = wl.wl_registry_bind(reg, name, &wl.rikkiti_applet_manager_v1_interface, min(version, wl.RIKKITI_APPLET_MANAGER_V1_VERSION))
	case "rikkiti_applet_host_v1":
		st.applet_host = wl.wl_registry_bind(reg, name, &wl.rikkiti_applet_host_v1_interface, min(version, wl.RIKKITI_APPLET_HOST_V1_VERSION))
	case "zwlr_foreign_toplevel_manager_v1":
		toplevels_bind(st, reg, name, version)
	case "ext_workspace_manager_v1":
		workspaces_bind(st, reg, name, version)
	}
}

// on_bg_effect_capabilities: the compositor says whether it blurs, at bind
// and again whenever that changes (effects or reduce transparency switched);
// pump turns a change into Ev_Caps.
@(private)
on_bg_effect_capabilities :: proc "c" (data: rawptr, p: wl.Proxy, flags: wl.Ext_Background_Effect_Manager_V1_Capability) {
	st := (^State)(data)
	st.blur_ok = (flags & wl.EXT_BACKGROUND_EFFECT_MANAGER_V1_CAPABILITY_BLUR) != 0
}

// blur_caps is `caps` with Backdrop_Blur as the compositor last said.
@(private)
blur_caps :: proc(st: ^State, caps: platform.Caps) -> platform.Caps {
	out := caps - {.Backdrop_Blur}
	if st.bg_effect_mgr != nil && st.blur_ok do out += {.Backdrop_Blur}
	return out
}

@(private)
on_global_remove :: proc "c" (data: rawptr, reg: wl.Proxy, name: u32) {
	st := (^State)(data)
	context = st.ctx
	for o, i in st.outputs {
		if o.name != name do continue
		for s in st.surfaces {
			if s != nil && s.output == o do s.output = nil
			if s != nil && s.lock_output == o do s.lock_output = nil // the app closes it; until then it covers nothing
		}
		if o.xdg != nil do wl.zxdg_output_v1_destroy(o.xdg)
		wl.wl_output_release(o.proxy)
		delete(o.out_name)
		delete(o.make_model)
		delete(o.description)
		free(o)
		ordered_remove(&st.outputs, i)
		st.outputs_changed = true
		return
	}
}

@(private)
on_wm_base_ping :: proc "c" (data: rawptr, p: wl.Proxy, serial: u32) {
	wl.xdg_wm_base_pong(p, serial)
}

@(private)
on_output_geometry :: proc "c" (data: rawptr, p: wl.Proxy, x, y, physical_width, physical_height: i32, subpixel: wl.Wl_Output_Subpixel, make, model: cstring, transform: wl.Wl_Output_Transform) {
	o := (^Output)(data)
	context = o.st.ctx
	o.pos = {x, y}
	o.transform = transform
	delete(o.make_model)
	o.make_model = strings.clone(strings.trim_space(strings.concatenate({string(make), " ", string(model)}, context.temp_allocator)))
}

@(private)
on_output_mode :: proc "c" (data: rawptr, p: wl.Proxy, flags: wl.Wl_Output_Mode, width, height, refresh: i32) {
	o := (^Output)(data)
	if flags & wl.WL_OUTPUT_MODE_CURRENT != 0 {
		o.mode_px = {width, height}
		o.refresh = refresh
	}
}

@(private)
on_output_scale :: proc "c" (data: rawptr, p: wl.Proxy, factor: i32) {
	o := (^Output)(data)
	o.scale = max(factor, 1)
}

@(private)
on_output_name :: proc "c" (data: rawptr, p: wl.Proxy, name: cstring) {
	o := (^Output)(data)
	context = o.st.ctx
	delete(o.out_name)
	o.out_name = strings.clone(string(name))
}

@(private)
on_output_description :: proc "c" (data: rawptr, p: wl.Proxy, description: cstring) {
	o := (^Output)(data)
	context = o.st.ctx
	delete(o.description)
	o.description = strings.clone(string(description))
}

// output_attach_xdg asks xdg-output for an output's logical geometry (the
// manager and the outputs arrive in either order).
@(private)
output_attach_xdg :: proc(st: ^State, o: ^Output) {
	if st.xdg_output_mgr == nil || o.xdg != nil do return
	o.xdg = wl.zxdg_output_manager_v1_get_xdg_output(st.xdg_output_mgr, o.proxy)
	o.xdg_l = wl.zxdg_output_v1_listener_noop()
	o.xdg_l.logical_position = on_xdg_output_position
	o.xdg_l.logical_size = on_xdg_output_size
	o.xdg_l.description = on_xdg_output_description
	o.xdg_l.done = on_xdg_output_done
	wl.zxdg_output_v1_add_listener(o.xdg, &o.xdg_l, o)
}

@(private)
on_xdg_output_position :: proc "c" (data: rawptr, p: wl.Proxy, x, y: i32) {
	o := (^Output)(data)
	o.logical_pos = {x, y}
	o.st.outputs_changed = true
}

@(private)
on_xdg_output_size :: proc "c" (data: rawptr, p: wl.Proxy, width, height: i32) {
	o := (^Output)(data)
	o.logical_size = {width, height}
	o.st.outputs_changed = true
}

@(private)
on_xdg_output_description :: proc "c" (data: rawptr, p: wl.Proxy, description: cstring) {
	o := (^Output)(data)
	context = o.st.ctx
	if o.description != "" do return // wl_output v4 said it already
	o.description = strings.clone(string(description))
}

@(private)
on_xdg_output_done :: proc "c" (data: rawptr, p: wl.Proxy) {
	o := (^Output)(data)
	o.st.outputs_changed = true
}

// backend_outputs answers Backend.outputs: the screens that have sent
// their first done, in logical px from xdg-output when the compositor has
// it (the mode divided by the integer scale otherwise).
@(private)
backend_outputs :: proc(b: ^platform.Backend) -> []platform.Output {
	st := state(b)
	clear(&st.outputs_view)
	for o in st.outputs {
		if !o.done do continue
		po := platform.Output{
			name = o.out_name, description = o.description if o.description != "" else o.make_model,
			pos = o.pos, mode_px = o.mode_px, refresh = o.refresh, transform = platform.Output_Transform(u8(o.transform)),
		}
		#partial switch o.transform {
		case ._90, ._270, .Flipped_90, .Flipped_270: po.mode_px = {o.mode_px.y, o.mode_px.x} // the long side runs down
		}
		if o.logical_size.x > 0 && o.logical_size.y > 0 {
			po.pos, po.size = o.logical_pos, o.logical_size
			po.scale = f32(po.mode_px.x) / f32(o.logical_size.x)
		} else {
			sc := max(o.scale, 1)
			po.size = {po.mode_px.x / sc, po.mode_px.y / sc}
			po.scale = f32(sc)
		}
		append(&st.outputs_view, po)
	}
	return st.outputs_view[:]
}

@(private)
on_output_done :: proc "c" (data: rawptr, p: wl.Proxy) {
	o := (^Output)(data)
	context = o.st.ctx
	o.done = true
	o.st.outputs_changed = true
	// An output scale change reaches surfaces that rely on it (no fractional scale).
	for s in o.st.surfaces {
		if s != nil && s.output == o do surface_update_scale(s)
	}
}

// ---------------------------------------------------------------- vulkan

@(private)
vk_instance_extensions :: proc(b: ^platform.Backend) -> []cstring {
	@(static) exts := [2]cstring{"VK_KHR_surface", "VK_KHR_wayland_surface"}
	return exts[:]
}

@(private)
vk_create_surface :: proc(b: ^platform.Backend, s: platform.Surface, instance: vk.Instance) -> (vk.SurfaceKHR, bool) {
	st := state(b)
	ss := lookup(st, s)
	if ss == nil || vk.CreateWaylandSurfaceKHR == nil do return 0, false
	info := vk.WaylandSurfaceCreateInfoKHR{
		sType   = .WAYLAND_SURFACE_CREATE_INFO_KHR,
		display = (^vk.wl_display)(st.display),
		surface = (^vk.wl_surface)(ss.wl_surface),
	}
	out: vk.SurfaceKHR
	if res := vk.CreateWaylandSurfaceKHR(instance, &info, nil, &out); res != .SUCCESS {
		debugf(st, "vkCreateWaylandSurfaceKHR: %v", res)
		return 0, false
	}
	return out, true
}

// ------------------------------------------------------------------ pump

@(private)
pump :: proc(b: ^platform.Backend, timeout_ms: i32) -> []platform.Event {
	st := state(b)
	clear(&st.out)
	// What the last pump returned is the caller's no longer. Events queued
	// since, outside a pump (a keymap during init), may hold strings in the
	// arena too: then it is freed at the next pump instead.
	if len(st.pending) == 0 do virtual.arena_free_all(&st.text_arena)

	deadline: time.Tick
	if timeout_ms > 0 do deadline = time.tick_add(time.tick_now(), time.Duration(timeout_ms) * time.Millisecond)
	// Block until at least one event is queued or the timeout passes; a
	// readable socket does not necessarily yield an Event (keymap, output
	// metadata), so loop.
	for {
		remaining := timeout_ms
		if timeout_ms > 0 {
			left := time.tick_diff(time.tick_now(), deadline)
			if left <= 0 do remaining = 0
			else do remaining = i32(max(left / time.Millisecond, 1))
		}
		if len(st.pending) > 0 do remaining = 0
		if st.dnd_reading { // a drop's data is on its way: wake in time to give up on it
			left := i32(max(time.tick_diff(time.tick_now(), st.dnd_read_deadline) / time.Millisecond, 0)) + 1
			if remaining < 0 || remaining > left do remaining = left
		}
		woke := pump_once(st, remaining)
		dnd_read_check(st)
		xdg.poll(&st.xdg) // how the openers we started went (platform/xdg/open_url.odin)
		if caps := blur_caps(st, b.caps); caps != b.caps { // glass follows the compositor
			b.caps = caps
			push(st, platform.Ev_Caps{caps = caps})
		}
		if st.outputs_changed { // a screen came, went or changed
			st.outputs_changed = false
			push(st, platform.Ev_Outputs{})
		}
		if st.toplevels_changed { // the compositor's windows changed
			st.toplevels_changed = false
			push(st, platform.Ev_Toplevels{})
		}
		if st.workspaces_changed {
			st.workspaces_changed = false
			push(st, platform.Ev_Workspaces{})
		}
		if woke || len(st.pending) > 0 || remaining == 0 || st.lost do break
	}
	return deliver(st)
}

// pump_once: one prepare_read / flush / poll / read / dispatch cycle. Returns
// true when `wake` was called (the caller wants control back even without
// events).
@(private)
pump_once :: proc(st: ^State, timeout_ms: i32) -> (woke: bool) {
	if st.lost {
		// Connection gone: honour the timeout (wake still interrupts) so a
		// caller that ignores Ev_Quit does not spin.
		fds := [1]linux.Poll_Fd{{fd = st.wake_fd, events = {.IN}}}
		if n, _ := linux.poll(fds[:], timeout_ms); n > 0 {
			buf: [8]u8
			linux.read(st.wake_fd, buf[:])
			return true
		}
		return false
	}
	// Dispatch anything already queued (e.g. read by a roundtrip inside
	// surface_create), then make sure nothing is pending before reading.
	for !wl.display_prepare_read(st.display) {
		if wl.display_dispatch_pending(st.display) < 0 {
			connection_lost(st)
			return false
		}
	}
	// wl_display_flush returns -1/EAGAIN when the socket's send buffer is
	// full and the bytes stay queued in libwayland: wait for the fd to be
	// writable and flush again. Ignored, the requests sit there on an idle
	// app with nothing to wake the pump, and once the 4 KB buffer overflows
	// the connection is torn down.
	st.flush_pending = wl.display_flush(st.display) < 0 && linux.Errno(libc.errno()^) == .EAGAIN

	fds := [10]linux.Poll_Fd{
		{fd = st.fd, events = {.IN, .OUT} if st.flush_pending else {.IN}},
		{fd = st.wake_fd, events = {.IN}},
		{fd = st.repeat_fd, events = {.IN}},
		{fd = dbus.fd(st.xdg.bus), events = {.IN}}, // portal hook: -1 when there is no bus (poll ignores it)
		{fd = st.inotify.fd, events = {.IN}},   // file watches: -1 when unavailable
		{fd = st.dnd_read_fd if st.dnd_reading else -1, events = {.IN}}, // a drop's data on its way
		{fd = st.extra_fds[0], events = {.IN}}, // watch_fd: the toolkit's own connections
		{fd = st.extra_fds[1], events = {.IN}},
		{fd = st.extra_fds[2], events = {.IN}},
		{fd = st.extra_fds[3], events = {.IN}},
	}
	n, perr := linux.poll(fds[:], timeout_ms)
	if perr == .EINTR do n = 0
	if n > 0 && st.flush_pending && .OUT in fds[0].revents {
		st.flush_pending = wl.display_flush(st.display) < 0 && linux.Errno(libc.errno()^) == .EAGAIN
	}
	if n > 0 && fds[0].revents & {.IN, .ERR, .HUP} != {} {
		if wl.display_read_events(st.display) < 0 {
			connection_lost(st)
			return false
		}
	} else {
		wl.display_cancel_read(st.display)
	}
	if wl.display_dispatch_pending(st.display) < 0 {
		connection_lost(st)
		return false
	}
	if n > 0 && .IN in fds[1].revents {
		buf: [8]u8
		linux.read(st.wake_fd, buf[:])
		woke = true
	}
	if n > 0 && .IN in fds[2].revents {
		buf: [8]u8
		if got, _ := linux.read(st.repeat_fd, buf[:]); got == 8 {
			key_repeat_fire(st)
		}
	}
	if n > 0 && fds[3].revents & {.IN, .ERR, .HUP} != {} do xdg.dispatch(&st.xdg) // portal hook: SettingChanged → Ev_Theme
	if n > 0 && .IN in fds[4].revents do platform.inotify_drain(&st.inotify, &st.pending, text_allocator(st))
	if n > 0 && fds[5].revents & {.IN, .ERR, .HUP} != {} do dnd_read_more(st)
	// watch_fd: a connection the toolkit reads itself (the accessibility
	// bus). We do not touch it — we only stop waiting, so the caller gets
	// its turn; leaving it unread here would spin.
	if n > 0 do for f in fds[6:] do if f.fd >= 0 && f.revents & {.IN, .ERR, .HUP} != {} do woke = true
	// Events we produced may need requests flushed (pong, ack_configure,
	// set_shape) before the caller goes back to rendering.
	wl.display_flush(st.display)
	return woke
}

// -------------------------------------------------------------- watches

@(private)
watch :: proc(b: ^platform.Backend, path: string, token: u64) -> bool {
	return platform.inotify_watch(&state(b).inotify, path, token)
}

@(private)
unwatch :: proc(b: ^platform.Backend, token: u64) {
	platform.inotify_unwatch(&state(b).inotify, token)
}

// deliver moves pending events to the caller-owned slice.
@(private)
deliver :: proc(st: ^State) -> []platform.Event {
	append(&st.out, ..st.pending[:])
	clear(&st.pending)
	return st.out[:]
}

// connection_lost: the compositor has gone, or has dropped us. Always
// printed, debug or not: otherwise the app quits with status 0, looking
// exactly like the person closed the window. EPROTO means we broke the
// protocol, and the interface and error code then name the rule and object.
@(private)
connection_lost :: proc(st: ^State) {
	if st.lost do return
	st.lost = true
	err := wl.display_get_error(st.display)
	if err == i32(linux.Errno.EPROTO) {
		code, iface, id := wl.display_get_protocol_error(st.display)
		fmt.eprintfln("baldr: the compositor dropped this window: protocol error %d on %s (object %d)",
			code, iface if iface != "" else "an unnamed interface", id)
	} else {
		fmt.eprintfln("baldr: the connection to the compositor was lost (errno %d). The window is gone; the app is stopping.", err)
	}
	push(st, platform.Ev_Quit{lost = true})
}

@(private)
wake :: proc(b: ^platform.Backend) {
	st := state(b)
	one := u64(1)
	linux.write(st.wake_fd, (^[8]u8)(&one)[:])
}

@(private)
system_theme :: proc(b: ^platform.Backend) -> platform.Ev_Theme {
	return xdg.theme(&state(b).xdg) // portal Settings, or the defaults when no bus/portal
}

// debug_key_probe runs an evdev keycode through the keyboard translation
// path without a key event — for diagnostics and spikes (the keymap is the
// one the compositor sent on wl_keyboard.keymap, so a keyboard must exist).
debug_key_probe :: proc(b: ^platform.Backend, evdev: u32, allocator := context.temp_allocator) -> (key: platform.Key, keysym: u32, text: string, ok: bool) {
	st := state(b)
	if st.keys.state == nil do return .Unknown, 0, "", false
	key, keysym, text = xkb.translate(&st.keys, evdev + xkb.EVDEV_OFFSET, allocator)
	return key, keysym, text, true
}

// drawable_create: this backend's renderer draws into a VkSurfaceKHR, so the
// neutral handle is one. `renderer` is the VkInstance it needs to make it.
@(private)
drawable_create :: proc(b: ^platform.Backend, s: platform.Surface, renderer: rawptr) -> (uintptr, bool) {
	surf, ok := vk_create_surface(b, s, vk.Instance(renderer))
	return uintptr(surf), ok
}
