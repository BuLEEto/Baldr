#+build linux
// Package wl is the Wayland client binding: libwayland-client loaded at
// runtime with core:dynlib (nothing is linked at build time), the wire ABI
// types, and generated protocol code (gen_*.odin, produced by
// tools/wl_scanner from the XML files in xml/). Mesa's Vulkan WSI requires
// real libwayland proxies, which is why this package marshals through
// libwayland instead of writing the socket itself.
package wl

import "core:c"
import "core:dynlib"

// Proxy is a `struct wl_proxy*` — every protocol object, including the display.
Proxy :: distinct rawptr

// Fixed is Wayland's 24.8 signed fixed-point number.
Fixed :: distinct i32

fixed_to_f64 :: proc "contextless" (f: Fixed) -> f64 { return f64(i32(f)) / 256.0 }
fixed_to_f32 :: proc "contextless" (f: Fixed) -> f32 { return f32(i32(f)) / 256.0 }
f64_to_fixed :: proc "contextless" (v: f64) -> Fixed { return Fixed(i32(v * 256.0)) }

// Message mirrors `struct wl_message`.
Message :: struct {
	name:      cstring,
	signature: cstring,
	types:     [^]^Interface,
}

// Interface mirrors `struct wl_interface`.
Interface :: struct {
	name:         cstring,
	version:      c.int,
	method_count: c.int,
	methods:      [^]Message,
	event_count:  c.int,
	events:       [^]Message,
}

// Array mirrors `struct wl_array`.
Array :: struct {
	size:  c.size_t,
	alloc: c.size_t,
	data:  rawptr,
}

// array_slice views a wl_array as a slice of T (e.g. u32 for xdg_toplevel states).
array_slice :: proc "contextless" (a: ^Array, $T: typeid) -> []T {
	if a == nil || a.data == nil || a.size == 0 do return nil
	return ([^]T)(a.data)[:int(a.size) / size_of(T)]
}

// Argument mirrors `union wl_argument` (8 bytes). The marshaller reads the
// member named by the signature letter; a new_id slot is passed as {o = nil}
// and libwayland writes the created proxy into it.
Argument :: struct #raw_union {
	i: i32,
	u: u32,
	f: Fixed,
	s: cstring,
	o: rawptr,
	n: u32,
	a: ^Array,
	h: i32,
}
#assert(size_of(Argument) == 8)

MARSHAL_FLAG_DESTROY :: u32(1)

// Api is the dlsym'd function table. Filled by load().
Api :: struct {
	display_connect:           proc "c" (name: cstring) -> Proxy,
	display_disconnect:        proc "c" (d: Proxy),
	display_roundtrip:         proc "c" (d: Proxy) -> c.int,
	display_dispatch:          proc "c" (d: Proxy) -> c.int,
	display_dispatch_pending:  proc "c" (d: Proxy) -> c.int,
	display_flush:             proc "c" (d: Proxy) -> c.int,
	display_get_fd:            proc "c" (d: Proxy) -> c.int,
	display_get_error:         proc "c" (d: Proxy) -> c.int,
	display_get_protocol_error: proc "c" (d: Proxy, iface: ^^Interface, id: ^u32) -> u32,
	display_prepare_read:      proc "c" (d: Proxy) -> c.int,
	display_read_events:       proc "c" (d: Proxy) -> c.int,
	display_cancel_read:       proc "c" (d: Proxy),
	proxy_marshal_array_flags: proc "c" (p: Proxy, opcode: u32, iface: ^Interface, version: u32, flags: u32, args: [^]Argument) -> Proxy,
	proxy_add_listener:        proc "c" (p: Proxy, implementation: rawptr, data: rawptr) -> c.int,
	proxy_get_version:         proc "c" (p: Proxy) -> u32,
	proxy_destroy:             proc "c" (p: Proxy),
	proxy_set_user_data:       proc "c" (p: Proxy, data: rawptr),
	proxy_get_user_data:       proc "c" (p: Proxy) -> rawptr,
	proxy_get_id:              proc "c" (p: Proxy) -> u32,
	proxy_get_class:           proc "c" (p: Proxy) -> cstring,
}

api: Api
@(private) lib: dynlib.Library
@(private) loaded: bool

// load dlopens libwayland-client and fills `api`; then initialises every
// generated protocol table. Safe to call more than once. Returns false (and
// fills `missing`, temp-allocated) when the library or a symbol is absent —
// i.e. not a Wayland system.
load :: proc() -> (ok: bool, missing: []string) {
	if loaded do return true, nil
	l, lok := dynlib.load_library("libwayland-client.so.0")
	if !lok {
		m := make([]string, 1, context.temp_allocator)
		m[0] = "libwayland-client.so.0"
		return false, m
	}
	lib = l
	miss := make([dynamic]string, context.temp_allocator)
	a := &api
	a.display_connect           = sym("wl_display_connect",           type_of(a.display_connect), &miss)
	a.display_disconnect        = sym("wl_display_disconnect",        type_of(a.display_disconnect), &miss)
	a.display_roundtrip         = sym("wl_display_roundtrip",         type_of(a.display_roundtrip), &miss)
	a.display_dispatch          = sym("wl_display_dispatch",          type_of(a.display_dispatch), &miss)
	a.display_dispatch_pending  = sym("wl_display_dispatch_pending",  type_of(a.display_dispatch_pending), &miss)
	a.display_flush             = sym("wl_display_flush",             type_of(a.display_flush), &miss)
	a.display_get_fd            = sym("wl_display_get_fd",            type_of(a.display_get_fd), &miss)
	a.display_get_error         = sym("wl_display_get_error",         type_of(a.display_get_error), &miss)
	a.display_get_protocol_error = sym("wl_display_get_protocol_error", type_of(a.display_get_protocol_error), &miss)
	a.display_prepare_read      = sym("wl_display_prepare_read",      type_of(a.display_prepare_read), &miss)
	a.display_read_events       = sym("wl_display_read_events",       type_of(a.display_read_events), &miss)
	a.display_cancel_read       = sym("wl_display_cancel_read",       type_of(a.display_cancel_read), &miss)
	a.proxy_marshal_array_flags = sym("wl_proxy_marshal_array_flags", type_of(a.proxy_marshal_array_flags), &miss)
	a.proxy_add_listener        = sym("wl_proxy_add_listener",        type_of(a.proxy_add_listener), &miss)
	a.proxy_get_version         = sym("wl_proxy_get_version",         type_of(a.proxy_get_version), &miss)
	a.proxy_destroy             = sym("wl_proxy_destroy",             type_of(a.proxy_destroy), &miss)
	a.proxy_set_user_data       = sym("wl_proxy_set_user_data",       type_of(a.proxy_set_user_data), &miss)
	a.proxy_get_user_data       = sym("wl_proxy_get_user_data",       type_of(a.proxy_get_user_data), &miss)
	a.proxy_get_id              = sym("wl_proxy_get_id",              type_of(a.proxy_get_id), &miss)
	a.proxy_get_class           = sym("wl_proxy_get_class",           type_of(a.proxy_get_class), &miss)
	if len(miss) > 0 {
		dynlib.unload_library(lib)
		lib = nil
		return false, miss[:]
	}
	init_protocols()
	loaded = true
	return true, nil
}

unload :: proc() {
	if lib != nil do dynlib.unload_library(lib)
	lib = nil
	loaded = false
	api = {}
}

@(private)
sym :: proc(name: string, $T: typeid, missing: ^[dynamic]string) -> T {
	p, ok := dynlib.symbol_address(lib, name)
	if !ok || p == nil {
		append(missing, name)
		z: T
		return z
	}
	return transmute(T)p
}

// ------------------------------------------------------------ thin wrappers

display_connect :: proc "contextless" (name: cstring = nil) -> Proxy { return api.display_connect(name) }
display_disconnect :: proc "contextless" (d: Proxy) { api.display_disconnect(d) }
display_roundtrip :: proc "contextless" (d: Proxy) -> int { return int(api.display_roundtrip(d)) }
display_dispatch :: proc "contextless" (d: Proxy) -> int { return int(api.display_dispatch(d)) }
display_dispatch_pending :: proc "contextless" (d: Proxy) -> int { return int(api.display_dispatch_pending(d)) }
display_flush :: proc "contextless" (d: Proxy) -> int { return int(api.display_flush(d)) }
display_get_fd :: proc "contextless" (d: Proxy) -> i32 { return i32(api.display_get_fd(d)) }
display_get_error :: proc "contextless" (d: Proxy) -> i32 { return i32(api.display_get_error(d)) }

// display_get_protocol_error says *which* protocol rule was broken when
// display_get_error is EPROTO: the interface it was broken on, the error
// code that interface defines, and the id of the object it happened to.
// Without it a dropped connection is only ever "errno 71".
display_get_protocol_error :: proc "contextless" (d: Proxy) -> (code: u32, interface: string, id: u32) {
	iface: ^Interface
	code = api.display_get_protocol_error(d, &iface, &id)
	if iface != nil && iface.name != nil do interface = string(iface.name)
	return
}
display_prepare_read :: proc "contextless" (d: Proxy) -> bool { return api.display_prepare_read(d) == 0 }
display_read_events :: proc "contextless" (d: Proxy) -> int { return int(api.display_read_events(d)) }
display_cancel_read :: proc "contextless" (d: Proxy) { api.display_cancel_read(d) }

proxy_version :: proc "contextless" (p: Proxy) -> u32 { return api.proxy_get_version(p) }
proxy_id :: proc "contextless" (p: Proxy) -> u32 { return api.proxy_get_id(p) }
proxy_class :: proc "contextless" (p: Proxy) -> cstring { return api.proxy_get_class(p) }
proxy_set_user_data :: proc "contextless" (p: Proxy, data: rawptr) { api.proxy_set_user_data(p, data) }
proxy_get_user_data :: proc "contextless" (p: Proxy) -> rawptr { return api.proxy_get_user_data(p) }

// proxy_destroy destroys a proxy client-side without sending anything. Use
// the generated `<iface>_destroy` request instead when the protocol has one.
proxy_destroy :: proc "contextless" (p: Proxy) { api.proxy_destroy(p) }

// marshal is what generated request procs call.
@(private)
marshal :: proc "contextless" (p: Proxy, opcode: u32, iface: ^Interface, version: u32, flags: u32, args: [^]Argument) -> Proxy {
	return api.proxy_marshal_array_flags(p, opcode, iface, version, flags, args)
}

@(private)
add_listener :: proc "contextless" (p: Proxy, impl: rawptr, data: rawptr) -> bool {
	return api.proxy_add_listener(p, impl, data) == 0
}
