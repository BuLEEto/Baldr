#+build linux
// wl_gen_check — exercises the generated `wl` bindings against the live
// compositor without Vulkan: registry, bind, surface + xdg toplevel,
// configure/ack round trip, teardown. Exit 0 = the generated tables,
// signatures, and listeners are accepted by a real compositor.
package main

import "base:runtime"
import "core:fmt"
import "core:os"
import wl "baldr:platform/wayland/wl"

State :: struct {
	compositor, wm_base, surface, xdg_surface, toplevel: wl.Proxy,
	globals:    int,
	configured: bool,
	serial:     u32,
	pings:      int,
}

on_global :: proc "c" (data: rawptr, reg: wl.Proxy, name: u32, iface: cstring, version: u32) {
	context = runtime.default_context()
	s := (^State)(data)
	s.globals += 1
	switch string(iface) {
	case "wl_compositor":
		s.compositor = wl.wl_registry_bind(reg, name, &wl.wl_compositor_interface, min(version, wl.WL_COMPOSITOR_VERSION))
	case "xdg_wm_base":
		s.wm_base = wl.wl_registry_bind(reg, name, &wl.xdg_wm_base_interface, min(version, wl.XDG_WM_BASE_VERSION))
	}
}

on_ping :: proc "c" (data: rawptr, p: wl.Proxy, serial: u32) {
	s := (^State)(data)
	s.pings += 1
	wl.xdg_wm_base_pong(p, serial)
}

on_configure :: proc "c" (data: rawptr, p: wl.Proxy, serial: u32) {
	s := (^State)(data)
	s.serial = serial
	s.configured = true
	wl.xdg_surface_ack_configure(p, serial)
}

on_toplevel_configure :: proc "c" (data: rawptr, p: wl.Proxy, width, height: i32, states: ^wl.Array) {
	context = runtime.default_context()
	st := wl.array_slice(states, wl.Xdg_Toplevel_State)
	fmt.printfln("wl_gen_check: toplevel configure %dx%d states=%v", width, height, st)
}

main :: proc() {
	ok, missing := wl.load()
	if !ok {
		fmt.eprintln("wl_gen_check: cannot load libwayland-client:", missing)
		os.exit(1)
	}
	display := wl.display_connect()
	if display == nil {
		fmt.eprintln("wl_gen_check: no Wayland display")
		os.exit(1)
	}
	fmt.printfln("wl_gen_check: connected fd=%d", wl.display_get_fd(display))

	s: State
	registry := wl.wl_display_get_registry(display)
	rl := wl.wl_registry_listener_noop()
	rl.global = on_global
	wl.wl_registry_add_listener(registry, &rl, &s)
	wl.display_roundtrip(display)
	fmt.printfln("wl_gen_check: %d globals; wl_compositor v%d, xdg_wm_base v%d", s.globals,
		wl.proxy_version(s.compositor), wl.proxy_version(s.wm_base))
	if s.compositor == nil || s.wm_base == nil {
		fmt.eprintln("wl_gen_check: required globals missing")
		os.exit(1)
	}

	wml := wl.xdg_wm_base_listener_noop()
	wml.ping = on_ping
	wl.xdg_wm_base_add_listener(s.wm_base, &wml, &s)

	s.surface = wl.wl_compositor_create_surface(s.compositor)
	s.xdg_surface = wl.xdg_wm_base_get_xdg_surface(s.wm_base, s.surface)
	xsl := wl.xdg_surface_listener_noop()
	xsl.configure = on_configure
	wl.xdg_surface_add_listener(s.xdg_surface, &xsl, &s)
	s.toplevel = wl.xdg_surface_get_toplevel(s.xdg_surface)
	tl := wl.xdg_toplevel_listener_noop()
	tl.configure = on_toplevel_configure
	wl.xdg_toplevel_add_listener(s.toplevel, &tl, &s)
	wl.xdg_toplevel_set_title(s.toplevel, "Baldr wl_gen_check")
	wl.xdg_toplevel_set_app_id(s.toplevel, "baldr.wl_gen_check")
	wl.xdg_toplevel_set_min_size(s.toplevel, 64, 64)
	wl.wl_surface_commit(s.surface)
	fmt.printfln("wl_gen_check: surface #%d xdg_surface #%d toplevel #%d committed",
		wl.proxy_id(s.surface), wl.proxy_id(s.xdg_surface), wl.proxy_id(s.toplevel))

	for i := 0; i < 50 && !s.configured; i += 1 do wl.display_roundtrip(display)
	if !s.configured {
		fmt.eprintln("wl_gen_check: no configure after 50 round trips")
		os.exit(1)
	}
	fmt.printfln("wl_gen_check: configured (serial %d), acked", s.serial)

	// since-guard: damage_buffer is v4+; on a v5 compositor it goes through.
	wl.wl_surface_damage_buffer(s.surface, 0, 0, 1, 1)

	wl.xdg_toplevel_destroy(s.toplevel)
	wl.xdg_surface_destroy(s.xdg_surface)
	wl.wl_surface_destroy(s.surface)
	wl.xdg_wm_base_destroy(s.wm_base)
	wl.proxy_destroy(s.compositor)
	wl.proxy_destroy(registry)
	wl.display_roundtrip(display)
	if e := wl.display_get_error(display); e != 0 {
		fmt.eprintfln("wl_gen_check: display error %d", e)
		os.exit(1)
	}
	wl.display_disconnect(display)
	fmt.println("wl_gen_check: clean teardown, no protocol errors")
}
