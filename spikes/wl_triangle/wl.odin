#+build linux
package main

// wl.odin — libwayland-client loaded at runtime with core:dynlib, plus
// hand-written xdg-shell interface tables and small request helpers.
//
// Nothing here is linked at build time: `wl_proxy_*` / `wl_display_*` come
// from dlsym, and so do the core-protocol `wl_*_interface` *data* symbols.
// xdg-shell is not part of libwayland-client, so its wl_interface /
// wl_message tables are written out below, derived from
// /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml.

import "core:c"
import "core:dynlib"
import "core:fmt"

// ------------------------------------------------------------------ ABI types

Proxy   :: distinct rawptr // struct wl_proxy*   (every protocol object)
Display :: distinct rawptr // struct wl_display* (is-a wl_proxy too)

// struct wl_message { const char *name; const char *signature; const struct wl_interface **types; }
Wl_Message :: struct {
	name:      cstring,
	signature: cstring,
	types:     [^]^Wl_Interface,
}

// struct wl_interface { const char *name; int version; int method_count;
//                       const struct wl_message *methods; int event_count; const struct wl_message *events; }
Wl_Interface :: struct {
	name:         cstring,
	version:      c.int,
	method_count: c.int,
	methods:      [^]Wl_Message,
	event_count:  c.int,
	events:       [^]Wl_Message,
}

// struct wl_array { size_t size; size_t alloc; void *data; }
Wl_Array :: struct {
	size:  c.size_t,
	alloc: c.size_t,
	data:  rawptr,
}

// union wl_argument — 8 bytes. The marshaller reads the member named by the
// request signature letter; for a `n` (new_id) slot the *library* writes the
// freshly created proxy into `.o`, so callers pass nil there.
Argument :: struct #raw_union {
	i: i32,      // int
	u: u32,      // uint
	f: i32,      // fixed (24.8)
	s: cstring,  // string
	o: rawptr,   // object (wl_proxy*)
	n: u32,      // new_id (wire); as an argument use .o = nil
	a: ^Wl_Array,
	h: i32,      // fd
}
#assert(size_of(Argument) == 8)

WL_MARSHAL_FLAG_DESTROY :: u32(1)

// ------------------------------------------------------------- function table

Wl_Api :: struct {
	display_connect:          proc "c" (name: cstring) -> Display,
	display_disconnect:       proc "c" (d: Display),
	display_roundtrip:        proc "c" (d: Display) -> c.int,
	display_dispatch:         proc "c" (d: Display) -> c.int,
	display_dispatch_pending: proc "c" (d: Display) -> c.int,
	display_flush:            proc "c" (d: Display) -> c.int,
	display_get_fd:           proc "c" (d: Display) -> c.int,
	display_prepare_read:     proc "c" (d: Display) -> c.int,
	display_read_events:      proc "c" (d: Display) -> c.int,
	display_cancel_read:      proc "c" (d: Display),

	// Variadic C entry point (what wayland-scanner output calls). Odin can
	// declare it with #c_vararg; we dlsym it to prove presence but marshal
	// through the array variant below, which has a fixed ABI.
	proxy_marshal_flags:       proc "c" (p: Proxy, opcode: u32, iface: ^Wl_Interface, version: u32, flags: u32, #c_vararg args: ..any) -> Proxy,
	proxy_marshal_array_flags: proc "c" (p: Proxy, opcode: u32, iface: ^Wl_Interface, version: u32, flags: u32, args: [^]Argument) -> Proxy,
	proxy_add_listener:        proc "c" (p: Proxy, implementation: rawptr, data: rawptr) -> c.int,
	proxy_get_version:         proc "c" (p: Proxy) -> u32,
	proxy_destroy:             proc "c" (p: Proxy),
	proxy_set_user_data:       proc "c" (p: Proxy, data: rawptr),
	proxy_get_user_data:       proc "c" (p: Proxy) -> rawptr,
	proxy_get_id:              proc "c" (p: Proxy) -> u32,

	// Exported DATA symbols: `const struct wl_interface wl_xxx_interface`.
	wl_display_interface:    ^Wl_Interface,
	wl_registry_interface:   ^Wl_Interface,
	wl_callback_interface:   ^Wl_Interface,
	wl_compositor_interface: ^Wl_Interface,
	wl_surface_interface:    ^Wl_Interface,
	wl_seat_interface:       ^Wl_Interface, // referenced by xdg_toplevel / xdg_popup request types
	wl_output_interface:     ^Wl_Interface, // referenced by xdg_toplevel.set_fullscreen
}

wl: Wl_Api
wl_lib: dynlib.Library

@(private="file")
sym :: proc(lib: dynlib.Library, name: string, $T: typeid, missing: ^[dynamic]string) -> T {
	p, ok := dynlib.symbol_address(lib, name)
	if !ok || p == nil {
		append(missing, name)
		z: T
		return z
	}
	return transmute(T)p
}

wl_load :: proc() -> bool {
	lib, ok := dynlib.load_library("libwayland-client.so.0")
	if !ok {
		fmt.eprintln("wl: dlopen libwayland-client.so.0 failed:", dynlib.last_error())
		return false
	}
	wl_lib = lib
	missing := make([dynamic]string, context.temp_allocator)
	a := &wl
	a.display_connect          = sym(lib, "wl_display_connect",          type_of(a.display_connect), &missing)
	a.display_disconnect       = sym(lib, "wl_display_disconnect",       type_of(a.display_disconnect), &missing)
	a.display_roundtrip        = sym(lib, "wl_display_roundtrip",        type_of(a.display_roundtrip), &missing)
	a.display_dispatch         = sym(lib, "wl_display_dispatch",         type_of(a.display_dispatch), &missing)
	a.display_dispatch_pending = sym(lib, "wl_display_dispatch_pending", type_of(a.display_dispatch_pending), &missing)
	a.display_flush            = sym(lib, "wl_display_flush",            type_of(a.display_flush), &missing)
	a.display_get_fd           = sym(lib, "wl_display_get_fd",           type_of(a.display_get_fd), &missing)
	a.display_prepare_read     = sym(lib, "wl_display_prepare_read",     type_of(a.display_prepare_read), &missing)
	a.display_read_events      = sym(lib, "wl_display_read_events",      type_of(a.display_read_events), &missing)
	a.display_cancel_read      = sym(lib, "wl_display_cancel_read",      type_of(a.display_cancel_read), &missing)
	a.proxy_marshal_flags       = sym(lib, "wl_proxy_marshal_flags",       type_of(a.proxy_marshal_flags), &missing)
	a.proxy_marshal_array_flags = sym(lib, "wl_proxy_marshal_array_flags", type_of(a.proxy_marshal_array_flags), &missing)
	a.proxy_add_listener        = sym(lib, "wl_proxy_add_listener",        type_of(a.proxy_add_listener), &missing)
	a.proxy_get_version         = sym(lib, "wl_proxy_get_version",         type_of(a.proxy_get_version), &missing)
	a.proxy_destroy             = sym(lib, "wl_proxy_destroy",             type_of(a.proxy_destroy), &missing)
	a.proxy_set_user_data       = sym(lib, "wl_proxy_set_user_data",       type_of(a.proxy_set_user_data), &missing)
	a.proxy_get_user_data       = sym(lib, "wl_proxy_get_user_data",       type_of(a.proxy_get_user_data), &missing)
	a.proxy_get_id              = sym(lib, "wl_proxy_get_id",              type_of(a.proxy_get_id), &missing)
	a.wl_display_interface    = sym(lib, "wl_display_interface",    ^Wl_Interface, &missing)
	a.wl_registry_interface   = sym(lib, "wl_registry_interface",   ^Wl_Interface, &missing)
	a.wl_callback_interface   = sym(lib, "wl_callback_interface",   ^Wl_Interface, &missing)
	a.wl_compositor_interface = sym(lib, "wl_compositor_interface", ^Wl_Interface, &missing)
	a.wl_surface_interface    = sym(lib, "wl_surface_interface",    ^Wl_Interface, &missing)
	a.wl_seat_interface       = sym(lib, "wl_seat_interface",       ^Wl_Interface, &missing)
	a.wl_output_interface     = sym(lib, "wl_output_interface",     ^Wl_Interface, &missing)
	if len(missing) > 0 {
		fmt.eprintln("wl: missing libwayland-client symbols:", missing[:])
		return false
	}
	xdg_init_tables()
	return true
}

// ------------------------------------------------------ core protocol opcodes
// From /usr/share/wayland/wayland.xml (request index within each interface).

WL_DISPLAY_GET_REGISTRY      :: u32(1) // sig "n"   -> wl_registry
WL_REGISTRY_BIND             :: u32(0) // sig "usun"
WL_COMPOSITOR_CREATE_SURFACE :: u32(0) // sig "n"   -> wl_surface
WL_SURFACE_DESTROY           :: u32(0)
WL_SURFACE_ATTACH            :: u32(1) // "?oii"
WL_SURFACE_DAMAGE            :: u32(2) // "iiii"
WL_SURFACE_FRAME             :: u32(3) // "n"       -> wl_callback
WL_SURFACE_COMMIT            :: u32(6)
WL_SURFACE_DAMAGE_BUFFER     :: u32(9) // "4iiii" (since v4)

// ------------------------------------------------------- xdg-shell opcodes
// From xdg-shell.xml (v7). Request index within each interface.

XDG_WM_BASE_DESTROY            :: u32(0)
XDG_WM_BASE_CREATE_POSITIONER  :: u32(1) // "n"  -> xdg_positioner
XDG_WM_BASE_GET_XDG_SURFACE    :: u32(2) // "no" -> xdg_surface, wl_surface
XDG_WM_BASE_PONG               :: u32(3) // "u"

XDG_SURFACE_DESTROY             :: u32(0)
XDG_SURFACE_GET_TOPLEVEL        :: u32(1) // "n" -> xdg_toplevel
XDG_SURFACE_GET_POPUP           :: u32(2) // "n?oo"
XDG_SURFACE_SET_WINDOW_GEOMETRY :: u32(3) // "iiii"
XDG_SURFACE_ACK_CONFIGURE       :: u32(4) // "u"

XDG_TOPLEVEL_DESTROY      :: u32(0)
XDG_TOPLEVEL_SET_PARENT   :: u32(1) // "?o"
XDG_TOPLEVEL_SET_TITLE    :: u32(2) // "s"
XDG_TOPLEVEL_SET_APP_ID   :: u32(3) // "s"
XDG_TOPLEVEL_SET_MAX_SIZE :: u32(7) // "ii"
XDG_TOPLEVEL_SET_MIN_SIZE :: u32(8) // "ii"
XDG_TOPLEVEL_SET_MAXIMIZED   :: u32(9)
XDG_TOPLEVEL_UNSET_MAXIMIZED :: u32(10)

// xdg_toplevel.state enum values carried in configure's `states` array (u32 each)
XDG_TOPLEVEL_STATE_MAXIMIZED  :: u32(1)
XDG_TOPLEVEL_STATE_FULLSCREEN :: u32(2)
XDG_TOPLEVEL_STATE_RESIZING   :: u32(3)
XDG_TOPLEVEL_STATE_ACTIVATED  :: u32(4)

// --------------------------------------------- xdg-shell interface tables
// Filled at runtime by xdg_init_tables() because the `types` entries that
// refer to core interfaces (wl_surface, wl_seat, wl_output) are pointers we
// only learn from dlsym. A generated scanner output would do the same patch.

xdg_wm_base_interface:    Wl_Interface
xdg_positioner_interface: Wl_Interface
xdg_surface_interface:    Wl_Interface
xdg_toplevel_interface:   Wl_Interface
xdg_popup_interface:      Wl_Interface

@(private="file") xdg_types: [25]^Wl_Interface
@(private="file") xdg_wm_base_requests:    [4]Wl_Message
@(private="file") xdg_wm_base_events:      [1]Wl_Message
@(private="file") xdg_positioner_requests: [10]Wl_Message
@(private="file") xdg_surface_requests:    [5]Wl_Message
@(private="file") xdg_surface_events:      [1]Wl_Message
@(private="file") xdg_toplevel_requests:   [14]Wl_Message
@(private="file") xdg_toplevel_events:     [4]Wl_Message
@(private="file") xdg_popup_requests:      [3]Wl_Message
@(private="file") xdg_popup_events:        [3]Wl_Message

@(private="file")
xdg_init_tables :: proc() {
	t := &xdg_types
	// [0..3]  all-nil run, shared by every message whose args carry no object
	t[4]  = &xdg_positioner_interface                                  // create_positioner "n"
	t[5]  = &xdg_surface_interface;  t[6] = wl.wl_surface_interface     // get_xdg_surface "no"
	t[7]  = &xdg_toplevel_interface                                    // get_toplevel "n"
	t[8]  = &xdg_popup_interface;    t[9] = &xdg_surface_interface;    t[10] = &xdg_positioner_interface // get_popup "n?oo"
	t[11] = wl.wl_seat_interface;    t[12] = nil; t[13] = nil; t[14] = nil // show_window_menu "ouii"
	t[15] = wl.wl_seat_interface;    t[16] = nil                       // move "ou"
	t[17] = wl.wl_seat_interface;    t[18] = nil; t[19] = nil          // resize "ouu"
	t[20] = wl.wl_output_interface                                     // set_fullscreen "?o"
	t[21] = &xdg_toplevel_interface                                    // set_parent "?o"
	t[22] = wl.wl_seat_interface;    t[23] = nil                       // grab "ou"
	t[24] = &xdg_positioner_interface                                  // reposition "3ou" (+ t[0] for the u)
	nil4 := &t[0]

	xdg_wm_base_requests = {
		{"destroy",           "",   nil4},
		{"create_positioner", "n",  &t[4]},
		{"get_xdg_surface",   "no", &t[5]},
		{"pong",              "u",  nil4},
	}
	xdg_wm_base_events = {
		{"ping", "u", nil4},
	}
	xdg_wm_base_interface = {"xdg_wm_base", 7, len(xdg_wm_base_requests), &xdg_wm_base_requests[0], len(xdg_wm_base_events), &xdg_wm_base_events[0]}

	xdg_positioner_requests = {
		{"destroy",                   "",     nil4},
		{"set_size",                  "ii",   nil4},
		{"set_anchor_rect",           "iiii", nil4},
		{"set_anchor",                "u",    nil4},
		{"set_gravity",               "u",    nil4},
		{"set_constraint_adjustment", "u",    nil4},
		{"set_offset",                "ii",   nil4},
		{"set_reactive",              "3",    nil4},
		{"set_parent_size",           "3ii",  nil4},
		{"set_parent_configure",      "3u",   nil4},
	}
	xdg_positioner_interface = {"xdg_positioner", 7, len(xdg_positioner_requests), &xdg_positioner_requests[0], 0, nil}

	xdg_surface_requests = {
		{"destroy",             "",     nil4},
		{"get_toplevel",        "n",    &t[7]},
		{"get_popup",           "n?oo", &t[8]},
		{"set_window_geometry", "iiii", nil4},
		{"ack_configure",       "u",    nil4},
	}
	xdg_surface_events = {
		{"configure", "u", nil4},
	}
	xdg_surface_interface = {"xdg_surface", 7, len(xdg_surface_requests), &xdg_surface_requests[0], len(xdg_surface_events), &xdg_surface_events[0]}

	xdg_toplevel_requests = {
		{"destroy",          "",     nil4},
		{"set_parent",       "?o",   &t[21]},
		{"set_title",        "s",    nil4},
		{"set_app_id",       "s",    nil4},
		{"show_window_menu", "ouii", &t[11]},
		{"move",             "ou",   &t[15]},
		{"resize",           "ouu",  &t[17]},
		{"set_max_size",     "ii",   nil4},
		{"set_min_size",     "ii",   nil4},
		{"set_maximized",    "",     nil4},
		{"unset_maximized",  "",     nil4},
		{"set_fullscreen",   "?o",   &t[20]},
		{"unset_fullscreen", "",     nil4},
		{"set_minimized",    "",     nil4},
	}
	xdg_toplevel_events = {
		{"configure",        "iia", nil4},
		{"close",            "",    nil4},
		{"configure_bounds", "4ii", nil4},
		{"wm_capabilities",  "5a",  nil4},
	}
	xdg_toplevel_interface = {"xdg_toplevel", 7, len(xdg_toplevel_requests), &xdg_toplevel_requests[0], len(xdg_toplevel_events), &xdg_toplevel_events[0]}

	xdg_popup_requests = {
		{"destroy",    "",    nil4},
		{"grab",       "ou",  &t[22]},
		{"reposition", "3ou", &t[24]},
	}
	xdg_popup_events = {
		{"configure",    "iiii", nil4},
		{"popup_done",   "",     nil4},
		{"repositioned", "3u",   nil4},
	}
	xdg_popup_interface = {"xdg_popup", 7, len(xdg_popup_requests), &xdg_popup_requests[0], len(xdg_popup_events), &xdg_popup_events[0]}
}

// --------------------------------------------------------------- listeners
// One `proc "c"` per event, in XML event order. libwayland indexes the
// struct by opcode and ABORTS on a nil entry, so every slot must be filled.

Registry_Listener :: struct {
	global:        proc "c" (data: rawptr, registry: Proxy, name: u32, interface: cstring, version: u32),
	global_remove: proc "c" (data: rawptr, registry: Proxy, name: u32),
}

Callback_Listener :: struct {
	done: proc "c" (data: rawptr, callback: Proxy, callback_data: u32),
}

Xdg_Wm_Base_Listener :: struct {
	ping: proc "c" (data: rawptr, wm_base: Proxy, serial: u32),
}

Xdg_Surface_Listener :: struct {
	configure: proc "c" (data: rawptr, xdg_surface: Proxy, serial: u32),
}

Xdg_Toplevel_Listener :: struct {
	configure:        proc "c" (data: rawptr, toplevel: Proxy, width, height: i32, states: ^Wl_Array),
	close:            proc "c" (data: rawptr, toplevel: Proxy),
	configure_bounds: proc "c" (data: rawptr, toplevel: Proxy, width, height: i32),
	wm_capabilities:  proc "c" (data: rawptr, toplevel: Proxy, capabilities: ^Wl_Array),
}

// ------------------------------------------------------------ request glue

// Fire-and-forget request (no new object).
wl_request :: proc(p: Proxy, opcode: u32, args: []Argument = nil, flags: u32 = 0) {
	wl.proxy_marshal_array_flags(p, opcode, nil, wl.proxy_get_version(p), flags, raw_data(args))
}

// Constructor request: `args` must contain the new_id slot as {o = nil};
// the new proxy inherits the parent's version (what wayland-scanner does).
wl_request_new :: proc(p: Proxy, opcode: u32, iface: ^Wl_Interface, args: []Argument) -> Proxy {
	return wl.proxy_marshal_array_flags(p, opcode, iface, wl.proxy_get_version(p), 0, raw_data(args))
}

// wl_registry.bind: the "usun" signature is (name, interface_name, version, new_id).
wl_registry_bind :: proc(registry: Proxy, name: u32, iface: ^Wl_Interface, version: u32) -> Proxy {
	args := [4]Argument{{u = name}, {s = iface.name}, {u = version}, {o = nil}}
	return wl.proxy_marshal_array_flags(registry, WL_REGISTRY_BIND, iface, version, 0, &args[0])
}

wl_add_listener :: proc(p: Proxy, listener: ^$T, data: rawptr) -> bool {
	return wl.proxy_add_listener(p, listener, data) == 0
}

// The wl_display handle is itself a wl_proxy, so requests marshal through it.
wl_display_get_registry :: proc(d: Display) -> Proxy {
	args := [1]Argument{{o = nil}}
	return wl_request_new(Proxy(d), WL_DISPLAY_GET_REGISTRY, wl.wl_registry_interface, args[:])
}

wl_compositor_create_surface :: proc(compositor: Proxy) -> Proxy {
	args := [1]Argument{{o = nil}}
	return wl_request_new(compositor, WL_COMPOSITOR_CREATE_SURFACE, wl.wl_surface_interface, args[:])
}

wl_surface_frame :: proc(surface: Proxy) -> Proxy {
	args := [1]Argument{{o = nil}}
	return wl_request_new(surface, WL_SURFACE_FRAME, wl.wl_callback_interface, args[:])
}

wl_surface_commit :: proc(surface: Proxy) {
	wl_request(surface, WL_SURFACE_COMMIT)
}

xdg_wm_base_get_xdg_surface :: proc(wm_base: Proxy, surface: Proxy) -> Proxy {
	args := [2]Argument{{o = nil}, {o = rawptr(surface)}}
	return wl_request_new(wm_base, XDG_WM_BASE_GET_XDG_SURFACE, &xdg_surface_interface, args[:])
}

xdg_wm_base_pong :: proc(wm_base: Proxy, serial: u32) {
	args := [1]Argument{{u = serial}}
	wl_request(wm_base, XDG_WM_BASE_PONG, args[:])
}

xdg_surface_get_toplevel :: proc(xdg_surface: Proxy) -> Proxy {
	args := [1]Argument{{o = nil}}
	return wl_request_new(xdg_surface, XDG_SURFACE_GET_TOPLEVEL, &xdg_toplevel_interface, args[:])
}

xdg_surface_ack_configure :: proc(xdg_surface: Proxy, serial: u32) {
	args := [1]Argument{{u = serial}}
	wl_request(xdg_surface, XDG_SURFACE_ACK_CONFIGURE, args[:])
}

xdg_surface_set_window_geometry :: proc(xdg_surface: Proxy, x, y, w, h: i32) {
	args := [4]Argument{{i = x}, {i = y}, {i = w}, {i = h}}
	wl_request(xdg_surface, XDG_SURFACE_SET_WINDOW_GEOMETRY, args[:])
}

xdg_toplevel_set_title :: proc(toplevel: Proxy, title: cstring) {
	args := [1]Argument{{s = title}}
	wl_request(toplevel, XDG_TOPLEVEL_SET_TITLE, args[:])
}

xdg_toplevel_set_app_id :: proc(toplevel: Proxy, app_id: cstring) {
	args := [1]Argument{{s = app_id}}
	wl_request(toplevel, XDG_TOPLEVEL_SET_APP_ID, args[:])
}

xdg_toplevel_set_min_size :: proc(toplevel: Proxy, w, h: i32) {
	// Experiment: the variadic C entry point through a dlsym'd pointer.
	wl.proxy_marshal_flags(toplevel, XDG_TOPLEVEL_SET_MIN_SIZE, nil, wl.proxy_get_version(toplevel), 0, w, h)
}

xdg_toplevel_set_maximized :: proc(toplevel: Proxy) {
	wl_request(toplevel, XDG_TOPLEVEL_SET_MAXIMIZED)
}

// Destructor requests: marshal with the DESTROY flag so libwayland frees the
// proxy after sending (the scanner does this for every `type="destructor"`).
xdg_toplevel_destroy :: proc(p: Proxy) { wl_request(p, XDG_TOPLEVEL_DESTROY, nil, WL_MARSHAL_FLAG_DESTROY) }
xdg_surface_destroy  :: proc(p: Proxy) { wl_request(p, XDG_SURFACE_DESTROY,  nil, WL_MARSHAL_FLAG_DESTROY) }
xdg_wm_base_destroy  :: proc(p: Proxy) { wl_request(p, XDG_WM_BASE_DESTROY,  nil, WL_MARSHAL_FLAG_DESTROY) }
wl_surface_destroy   :: proc(p: Proxy) { wl_request(p, WL_SURFACE_DESTROY,   nil, WL_MARSHAL_FLAG_DESTROY) }

// Iterate a `u32` wl_array (e.g. xdg_toplevel.configure states).
wl_array_u32s :: proc(a: ^Wl_Array) -> []u32 {
	if a == nil || a.data == nil { return nil }
	return ([^]u32)(a.data)[:int(a.size) / size_of(u32)]
}
