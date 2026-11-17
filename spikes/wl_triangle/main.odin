#+build linux
package main

// Baldr spike: Wayland toplevel + Vulkan triangle, no SDL/GLFW, no C in-tree,
// no build-time linking of libwayland or libvulkan (both dlopen'd).
//
//   ./build/wl_triangle [--seconds N] [--frames N] [--maximize]

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:sys/linux"
import "core:time"

DEFAULT_WIDTH  :: 800
DEFAULT_HEIGHT :: 600

App :: struct {
	display:     Display,
	registry:    Proxy,
	compositor:  Proxy,
	wm_base:     Proxy,
	surface:     Proxy,
	xdg_surface: Proxy,
	toplevel:    Proxy,

	// registry globals we care about
	compositor_name, compositor_version: u32,
	wm_base_name,    wm_base_version:    u32,

	// xdg configure handshake
	pending_w, pending_h: i32, // from xdg_toplevel.configure; 0 = client decides
	pending_serial:       u32, // from xdg_surface.configure
	configure_pending:    bool,
	configured:           bool,
	width, height:        i32,
	resize_needed:        bool,
	state_line:           string,

	// frame pacing
	frame_cb:      Proxy,
	frame_pending: bool,

	running:        bool,
	exit_reason:    string,
	frames:         u64,
	max_frames:     u64,
	deadline_ns:    i64, // 0 = none
	start:          time.Tick,
	maximize_at:    u64, // --maximize: request set_maximized after this many frames (0 = never)
	maximized:      bool,

	r: Renderer,
}

app: App

log :: proc(format: string, args: ..any) {
	fmt.printf("wl_triangle: ")
	fmt.printfln(format, ..args)
}

// ------------------------------------------------------------- listeners

on_registry_global :: proc "c" (data: rawptr, registry: Proxy, name: u32, interface: cstring, version: u32) {
	a := (^App)(data)
	switch string(interface) {
	case "wl_compositor": a.compositor_name = name; a.compositor_version = version
	case "xdg_wm_base":   a.wm_base_name = name;    a.wm_base_version = version
	}
}
on_registry_global_remove :: proc "c" (data: rawptr, registry: Proxy, name: u32) {}

registry_listener := Registry_Listener{on_registry_global, on_registry_global_remove}

on_wm_base_ping :: proc "c" (data: rawptr, wm_base: Proxy, serial: u32) {
	context = runtime.default_context()
	xdg_wm_base_pong(wm_base, serial)
}
wm_base_listener := Xdg_Wm_Base_Listener{on_wm_base_ping}

on_xdg_surface_configure :: proc "c" (data: rawptr, xdg_surface: Proxy, serial: u32) {
	a := (^App)(data)
	a.pending_serial = serial
	a.configure_pending = true
}
xdg_surface_listener := Xdg_Surface_Listener{on_xdg_surface_configure}

on_toplevel_configure :: proc "c" (data: rawptr, toplevel: Proxy, width, height: i32, states: ^Wl_Array) {
	context = runtime.default_context()
	a := (^App)(data)
	a.pending_w = width
	a.pending_h = height
	line := ""
	for s in wl_array_u32s(states) {
		switch s {
		case XDG_TOPLEVEL_STATE_MAXIMIZED:  line = fmt.tprintf("%s maximized", line)
		case XDG_TOPLEVEL_STATE_FULLSCREEN: line = fmt.tprintf("%s fullscreen", line)
		case XDG_TOPLEVEL_STATE_RESIZING:   line = fmt.tprintf("%s resizing", line)
		case XDG_TOPLEVEL_STATE_ACTIVATED:  line = fmt.tprintf("%s activated", line)
		}
	}
	delete(a.state_line)
	a.state_line = fmt.aprintf("%s", line)
}
on_toplevel_close :: proc "c" (data: rawptr, toplevel: Proxy) {
	a := (^App)(data)
	a.running = false
	a.exit_reason = "xdg_toplevel.close"
}
on_toplevel_configure_bounds :: proc "c" (data: rawptr, toplevel: Proxy, width, height: i32) {}
on_toplevel_wm_capabilities  :: proc "c" (data: rawptr, toplevel: Proxy, capabilities: ^Wl_Array) {}

toplevel_listener := Xdg_Toplevel_Listener{
	on_toplevel_configure, on_toplevel_close, on_toplevel_configure_bounds, on_toplevel_wm_capabilities,
}

on_frame_done :: proc "c" (data: rawptr, callback: Proxy, callback_data: u32) {
	a := (^App)(data)
	wl.proxy_destroy(callback) // wl_callback.done is a destructor event: client frees the proxy
	if a.frame_cb == callback { a.frame_cb = nil }
	a.frame_pending = false
}
frame_listener := Callback_Listener{on_frame_done}

// --------------------------------------------------------------- helpers

// Apply a pending xdg_surface.configure: adopt the size and ack it.
apply_configure :: proc(a: ^App) {
	a.configure_pending = false
	w, h := a.pending_w, a.pending_h
	if w == 0 || h == 0 {
		w = a.width if a.width > 0 else DEFAULT_WIDTH
		h = a.height if a.height > 0 else DEFAULT_HEIGHT
	}
	if a.configured && (w != a.width || h != a.height) {
		a.resize_needed = true
		log("configure %dx%d -> %dx%d (serial %d, states:%s)", a.width, a.height, w, h, a.pending_serial, a.state_line)
	}
	a.width, a.height = w, h
	xdg_surface_ack_configure(a.xdg_surface, a.pending_serial)
	if !a.configured {
		a.configured = true
		log("configured %dx%d (serial %d, states:%s)", w, h, a.pending_serial, a.state_line)
	}
}

// One iteration of the fd-driven event pump: dispatch what is queued,
// flush, poll the display fd with a timeout, read + dispatch. This is the
// libwayland prepare_read/read_events protocol, not a blocking dispatch, so
// it composes with other fds (D-Bus, timers) in a real event loop.
pump :: proc(a: ^App, timeout_ms: i32) -> bool {
	for wl.display_prepare_read(a.display) != 0 {
		if wl.display_dispatch_pending(a.display) < 0 { return false }
	}
	wl.display_flush(a.display)
	fds := [1]linux.Poll_Fd{{fd = linux.Fd(wl.display_get_fd(a.display)), events = {.IN}}}
	n, _ := linux.poll(fds[:], timeout_ms)
	if n > 0 {
		if wl.display_read_events(a.display) < 0 { return false }
	} else {
		wl.display_cancel_read(a.display)
	}
	return wl.display_dispatch_pending(a.display) >= 0
}

remaining_ms :: proc(a: ^App) -> i32 {
	if a.deadline_ns == 0 { return -1 }
	left := a.deadline_ns - time.duration_nanoseconds(time.tick_since(a.start))
	if left <= 0 { return 0 }
	return i32(min(left / 1_000_000 + 1, 1000))
}

parse_args :: proc(a: ^App) -> bool {
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--seconds":
			if i + 1 >= len(args) { fmt.eprintln("--seconds needs a value"); return false }
			i += 1
			v, ok := strconv.parse_f64(args[i])
			if !ok { fmt.eprintln("bad --seconds value"); return false }
			a.deadline_ns = i64(v * 1e9)
		case "--frames":
			if i + 1 >= len(args) { fmt.eprintln("--frames needs a value"); return false }
			i += 1
			v, ok := strconv.parse_u64(args[i])
			if !ok { fmt.eprintln("bad --frames value"); return false }
			a.max_frames = v
		case "--maximize":
			// Ask the compositor to maximize after 60 frames: a real configure with
			// a new size arrives, exercising ack + swapchain recreation.
			a.maximize_at = 60
		case "--help", "-h":
			fmt.println("usage: wl_triangle [--seconds N] [--frames N] [--maximize]")
			os.exit(0)
		case:
			fmt.eprintln("unknown argument:", args[i])
			return false
		}
	}
	return true
}

// ------------------------------------------------------------------ main

main :: proc() {
	a := &app
	if !parse_args(a) { os.exit(2) }
	a.start = time.tick_now()
	a.running = true

	// ---- Wayland: connect, registry, globals
	if !wl_load() { os.exit(1) }
	a.display = wl.display_connect(nil)
	if a.display == nil {
		fmt.eprintln("wl_triangle: wl_display_connect failed (is WAYLAND_DISPLAY set?)")
		os.exit(1)
	}
	log("connected (WAYLAND_DISPLAY=%s, fd %d)", os.get_env("WAYLAND_DISPLAY", context.temp_allocator), wl.display_get_fd(a.display))

	a.registry = wl_display_get_registry(a.display)
	wl_add_listener(a.registry, &registry_listener, a)
	wl.display_roundtrip(a.display)
	if a.compositor_name == 0 || a.wm_base_name == 0 {
		fmt.eprintln("wl_triangle: compositor lacks wl_compositor or xdg_wm_base")
		os.exit(1)
	}
	if a.compositor_version < 4 {
		fmt.eprintln("wl_triangle: wl_compositor v4+ required, got", a.compositor_version)
		os.exit(1)
	}
	comp_v := min(a.compositor_version, u32(wl.wl_compositor_interface.version))
	wm_v   := min(a.wm_base_version, u32(xdg_wm_base_interface.version))
	a.compositor = wl_registry_bind(a.registry, a.compositor_name, wl.wl_compositor_interface, comp_v)
	a.wm_base    = wl_registry_bind(a.registry, a.wm_base_name, &xdg_wm_base_interface, wm_v)
	wl_add_listener(a.wm_base, &wm_base_listener, a)
	log("globals bound: wl_compositor v%d (advertised v%d), xdg_wm_base v%d (advertised v%d)",
		comp_v, a.compositor_version, wm_v, a.wm_base_version)

	// ---- surface + xdg role, then the first commit to request a configure
	a.surface     = wl_compositor_create_surface(a.compositor)
	a.xdg_surface = xdg_wm_base_get_xdg_surface(a.wm_base, a.surface)
	wl_add_listener(a.xdg_surface, &xdg_surface_listener, a)
	a.toplevel = xdg_surface_get_toplevel(a.xdg_surface)
	wl_add_listener(a.toplevel, &toplevel_listener, a)
	xdg_toplevel_set_title(a.toplevel, "Baldr spike")
	xdg_toplevel_set_app_id(a.toplevel, "baldr.spike")
	xdg_toplevel_set_min_size(a.toplevel, 64, 64)
	wl_surface_commit(a.surface)
	wl.display_flush(a.display)

	for a.running && !a.configure_pending {
		if wl.display_dispatch(a.display) < 0 {
			fmt.eprintln("wl_triangle: display error while waiting for configure")
			os.exit(1)
		}
	}
	if !a.running { log("closed before configure"); os.exit(0) }
	apply_configure(a)

	// ---- Vulkan
	r := &a.r
	if !vk_boot(r) || !vk_create_instance(r) { os.exit(1) }
	log("vulkan instance %d.%d, validation layer: %s", r.instance_version >> 22, (r.instance_version >> 12) & 0x3ff,
		"enabled (VK_LAYER_KHRONOS_validation + VK_EXT_debug_utils)" if r.validation else "not installed")
	if !vk_create_wayland_surface(r, a.display, a.surface) { os.exit(1) }
	if !vk_pick_physical_device(r) || !vk_create_device(r) { os.exit(1) }
	log("device: %s, queue family %d, %s", r.device_name, r.qfamily,
		"VK_KHR_dynamic_rendering" if r.khr_dynamic_rendering else "core 1.3 dynamic rendering")
	if !vk_create_pipeline(r) { os.exit(1) }
	if !vk_create_swapchain(r, u32(a.width), u32(a.height)) { os.exit(1) }
	log("swapchain created: %dx%d, %d images, %v/%v, %v", r.extent.width, r.extent.height, len(r.images),
		r.format.format, r.format.colorSpace, r.present_mode)

	// ---- main loop: draw when the compositor asks (frame callback), never spin
	for a.running {
		if a.configure_pending { apply_configure(a) }
		if a.resize_needed {
			a.resize_needed = false
			if !vk_create_swapchain(r, u32(a.width), u32(a.height)) { os.exit(1) }
			log("resize -> swapchain %dx%d (%d images)", r.extent.width, r.extent.height, len(r.images))
			// A frame request left in pending state cannot fire until WSI commits again.
			if a.frame_cb != nil { wl.proxy_destroy(a.frame_cb); a.frame_cb = nil }
			a.frame_pending = false
		}
		if !a.frame_pending {
			a.frame_cb = wl_surface_frame(a.surface)
			wl_add_listener(a.frame_cb, &frame_listener, a)
			a.frame_pending = true
			t := f32(time.duration_seconds(time.tick_since(a.start)))
			presented, out_of_date := vk_draw(r, t)
			if presented {
				a.frames += 1
				if a.frames == 1 { log("first frame presented") }
				if a.maximize_at != 0 && a.frames == a.maximize_at && !a.maximized {
					a.maximized = true
					xdg_toplevel_set_maximized(a.toplevel)
					log("requested set_maximized (expect configure with a new size)")
				}
				if a.max_frames != 0 && a.frames >= a.max_frames {
					a.running = false
					a.exit_reason = fmt.tprintf("--frames %d reached", a.max_frames)
				}
			}
			if out_of_date && !presented {
				a.resize_needed = true
			}
		}
		if !a.running { break }
		if !pump(a, remaining_ms(a)) {
			fmt.eprintln("wl_triangle: display connection lost")
			a.running = false
			a.exit_reason = "display error"
		}
		if a.deadline_ns != 0 && time.duration_nanoseconds(time.tick_since(a.start)) >= a.deadline_ns {
			a.running = false
			a.exit_reason = fmt.tprintf("--seconds %.1f elapsed", f64(a.deadline_ns) / 1e9)
		}
	}

	elapsed := time.duration_seconds(time.tick_since(a.start))
	log("closing (%s): %d frames in %.2fs (%.1f fps)", a.exit_reason, a.frames, elapsed, f64(a.frames) / max(elapsed, 0.001))

	// ---- teardown: Vulkan (WSI talks to the wl_surface) before the proxies
	vk_shutdown(r)
	if a.frame_cb != nil { wl.proxy_destroy(a.frame_cb) }
	xdg_toplevel_destroy(a.toplevel)
	xdg_surface_destroy(a.xdg_surface)
	wl_surface_destroy(a.surface)
	xdg_wm_base_destroy(a.wm_base)
	wl.proxy_destroy(a.compositor)
	wl.proxy_destroy(a.registry)
	wl.display_flush(a.display)
	wl.display_disconnect(a.display)

	if r.validation {
		log("validation: %d errors, %d warnings", r.validation_errors, r.validation_warnings)
		if r.validation_errors > 0 { os.exit(3) }
	}
	os.exit(0)
}
