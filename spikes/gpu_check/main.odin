#+build linux
// gpu_check — drives package gpu against a live Wayland compositor: an xdg
// toplevel from the generated `wl` bindings, a VkSurfaceKHR from
// vkCreateWaylandSurfaceKHR, and one gpu.render per frame callback with a
// scene that exercises every Cmd kind: background quad, a grid of rounded /
// bordered quads (incl. pill and circle), nested clips, tinted Alpha8 glyphs
// from a synthetic anti-aliased circle page, and RGBA8 glyphs from a
// synthetic gradient page.
//
//   ./build/gpu_check [--seconds N] [--frames N] [--maximize] [--transparent]
//
// Exit 0 = clean; 3 = a render failed or the validation layer reported errors.
package main

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:sys/linux"
import "core:time"
import vk "vendor:vulkan"
import "baldr:gpu"
import wl "baldr:platform/wayland/wl"

DEFAULT_WIDTH  :: 960
DEFAULT_HEIGHT :: 640

App :: struct {
	display, registry, compositor, wm_base: wl.Proxy,
	surface, xdg_surface, toplevel:         wl.Proxy,

	pending_w, pending_h: i32,
	pending_serial:       u32,
	configure_pending:    bool,
	configured:           bool,
	width, height:        i32,
	resize_needed:        bool,
	state_line:           string,

	frame_cb:      wl.Proxy,
	frame_pending: bool,

	running:     bool,
	exit_reason: string,
	frames:      u64,
	max_frames:  u64,
	deadline_ns: i64,
	start:       time.Tick,
	maximize_at: u64,
	maximized:   bool,
	transparent: bool,
	errors:      int,

	r:           gpu.Renderer,
	target:      gpu.Target,
	circle_page: gpu.Page,
	grad_page:   gpu.Page,
	cmds:        [dynamic]gpu.Cmd,
}

app: App

log :: proc(format: string, args: ..any) {
	fmt.printf("gpu_check: ")
	fmt.printfln(format, ..args)
}

// ------------------------------------------------------------- listeners

on_global :: proc "c" (data: rawptr, reg: wl.Proxy, name: u32, iface: cstring, version: u32) {
	context = runtime.default_context()
	a := (^App)(data)
	switch string(iface) {
	case "wl_compositor":
		a.compositor = wl.wl_registry_bind(reg, name, &wl.wl_compositor_interface, min(version, wl.WL_COMPOSITOR_VERSION))
	case "xdg_wm_base":
		a.wm_base = wl.wl_registry_bind(reg, name, &wl.xdg_wm_base_interface, min(version, wl.XDG_WM_BASE_VERSION))
	}
}

on_ping :: proc "c" (data: rawptr, p: wl.Proxy, serial: u32) {
	wl.xdg_wm_base_pong(p, serial)
}

on_xdg_surface_configure :: proc "c" (data: rawptr, p: wl.Proxy, serial: u32) {
	a := (^App)(data)
	a.pending_serial = serial
	a.configure_pending = true
}

on_toplevel_configure :: proc "c" (data: rawptr, p: wl.Proxy, width, height: i32, states: ^wl.Array) {
	context = runtime.default_context()
	a := (^App)(data)
	a.pending_w, a.pending_h = width, height
	delete(a.state_line)
	a.state_line = fmt.aprintf("%v", wl.array_slice(states, wl.Xdg_Toplevel_State))
}

on_toplevel_close :: proc "c" (data: rawptr, p: wl.Proxy) {
	a := (^App)(data)
	a.running = false
	a.exit_reason = "xdg_toplevel.close"
}

on_frame_done :: proc "c" (data: rawptr, callback: wl.Proxy, callback_data: u32) {
	a := (^App)(data)
	wl.proxy_destroy(callback) // wl_callback.done is a destructor event
	if a.frame_cb == callback { a.frame_cb = nil }
	a.frame_pending = false
}

// --------------------------------------------------------------- helpers

apply_configure :: proc(a: ^App) {
	a.configure_pending = false
	w, h := a.pending_w, a.pending_h
	if w == 0 || h == 0 {
		w = a.width if a.width > 0 else DEFAULT_WIDTH
		h = a.height if a.height > 0 else DEFAULT_HEIGHT
	}
	if a.configured && (w != a.width || h != a.height) {
		a.resize_needed = true
		log("configure %dx%d -> %dx%d (serial %d, states %s)", a.width, a.height, w, h, a.pending_serial, a.state_line)
	}
	a.width, a.height = w, h
	wl.xdg_surface_ack_configure(a.xdg_surface, a.pending_serial)
	if !a.configured {
		a.configured = true
		log("configured %dx%d (serial %d, states %s)", w, h, a.pending_serial, a.state_line)
	}
}

// pump: prepare_read / flush / poll / read_events / dispatch_pending — Mesa's
// WSI shares the socket, so plain wl_display_dispatch is not an option.
pump :: proc(a: ^App, timeout_ms: i32) -> bool {
	for !wl.display_prepare_read(a.display) {
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
			a.maximize_at = 60 // request set_maximized after 60 frames → real configure + resize
		case "--transparent":
			a.transparent = true
		case "--help", "-h":
			fmt.println("usage: gpu_check [--seconds N] [--frames N] [--maximize] [--transparent]")
			os.exit(0)
		case:
			fmt.eprintln("unknown argument:", args[i])
			return false
		}
	}
	return true
}

// ------------------------------------------------------------- the scene

// Synthetic Alpha8 page: a 64×64 anti-aliased disc (1 px linear fringe).
make_circle_page :: proc(a: ^App) -> gpu.Page {
	N :: 64
	page := gpu.atlas_create(&a.r, .Alpha8, {N, N})
	if page == 0 { return 0 }
	pixels: [N * N]u8
	for y in 0 ..< N {
		for x in 0 ..< N {
			dx := f32(x) + 0.5 - N / 2
			dy := f32(y) + 0.5 - N / 2
			d := math.sqrt(dx * dx + dy * dy) - (N / 2 - 2)
			pixels[y * N + x] = u8(clamp(0.5 - d, 0, 1) * 255 + 0.5)
		}
	}
	gpu.atlas_upload(&a.r, page, 0, 0, N, N, pixels[:])
	return page
}

// Synthetic RGBA8 page: red along x, green along y, constant blue, opaque,
// with a transparent hole in the middle to prove alpha is honoured.
make_gradient_page :: proc(a: ^App) -> gpu.Page {
	N :: 64
	page := gpu.atlas_create(&a.r, .RGBA8, {N, N})
	if page == 0 { return 0 }
	pixels: [N * N * 4]u8
	for y in 0 ..< N {
		for x in 0 ..< N {
			i := (y * N + x) * 4
			pixels[i + 0] = u8(x * 255 / (N - 1))
			pixels[i + 1] = u8(y * 255 / (N - 1))
			pixels[i + 2] = 160
			dx := f32(x) + 0.5 - N / 2
			dy := f32(y) + 0.5 - N / 2
			hole := math.sqrt(dx * dx + dy * dy) - 12
			pixels[i + 3] = u8(clamp(hole + 0.5, 0, 1) * 255 + 0.5)
		}
	}
	gpu.atlas_upload(&a.r, page, 0, 0, N, N, pixels[:])
	return page
}

quad :: proc(a: ^App, rect: [4]f32, color: [4]f32, radius: f32 = 0, border_w: f32 = 0, border: [4]f32 = {}) {
	append(&a.cmds, gpu.Quad{rect = rect, color = color, radius = radius, border_w = border_w, border = border})
}

glyph :: proc(a: ^App, rect: [4]f32, page: gpu.Page, color: [4]f32, uv: [4]f32 = {0, 0, 1, 1}) {
	append(&a.cmds, gpu.Glyph{rect = rect, uv = uv, page = page, color = color})
}

build_scene :: proc(a: ^App, t: f32) {
	clear(&a.cmds)
	W, H := f32(a.width), f32(a.height)

	// Background: full-window quad. With --transparent it is translucent so
	// the desktop shows through (clear alpha is 0 in that mode).
	bg := [4]f32{0.09, 0.10, 0.13, 0.55 if a.transparent else 1.0}
	quad(a, {0, 0, W, H}, bg)

	// Header strip + accent pill that moves with time (proves frames are live).
	quad(a, {0, 0, W, 44}, {0.14, 0.16, 0.21, 1})
	px := 20 + (W - 160) * (0.5 + 0.5 * math.sin(t * 1.5))
	quad(a, {px, 12, 120, 20}, {0.30, 0.65, 1.0, 1}, radius = 100)

	// Grid of rounded / bordered quads: 4 × 2 tiles of 150×90.
	radii   := [8]f32{0, 4, 8, 16, 24, 45, 200, 200} // 45 = half height → pill; 200 clamps to pill
	borders := [8]f32{0, 1, 2, 4, 8, 0, 3, 6}
	fills   := [8][4]f32{
		{0.85, 0.30, 0.30, 1}, {0.30, 0.75, 0.40, 1}, {0.30, 0.50, 0.90, 1}, {0.90, 0.75, 0.25, 1},
		{0.65, 0.40, 0.85, 1}, {0.25, 0.75, 0.75, 1}, {0, 0, 0, 0},         {0.95, 0.95, 0.95, 0.15},
	}
	for i in 0 ..< 8 {
		col := f32(i % 4)
		row := f32(i / 4)
		rect := [4]f32{30 + col * 170, 70 + row * 110, 150, 90}
		if i == 7 { rect.z = 90 } // square + huge radius = circle
		quad(a, rect, fills[i], radius = radii[i], border_w = borders[i], border = {1, 1, 1, 0.9})
	}
	// Half-pixel offset tile: the AA fringe must look even, not stair-stepped.
	quad(a, {30.5, 290.5, 150, 40}, {0.5, 0.5, 0.55, 1}, radius = 6, border_w = 1, border = {1, 0.6, 0.2, 1})

	// Clipping: an outer clip (dashed frame drawn as a border-only quad so the
	// clip edge is visible), a big red quad that must be cut to it, a nested
	// clip cutting a yellow quad further, then pop → green quad cut only by
	// the outer clip, pop → blue quad not cut at all.
	outer := [4]f32{30, 350, 320, 180}
	quad(a, {outer.x - 1, outer.y - 1, outer.z + 2, outer.w + 2}, {0, 0, 0, 0}, border_w = 1, border = {1, 1, 1, 0.5})
	append(&a.cmds, gpu.Clip_Push{rect = outer})
	quad(a, {-40, 320, 300, 240}, {0.80, 0.25, 0.25, 1}, radius = 30)
	inner := [4]f32{120, 400, 300, 80}
	append(&a.cmds, gpu.Clip_Push{rect = inner})
	quad(a, {100, 380, 400, 200}, {0.95, 0.85, 0.20, 1}, radius = 12)
	append(&a.cmds, gpu.Clip_Pop{})
	quad(a, {250, 360, 200, 60}, {0.30, 0.75, 0.40, 1}, radius = 8) // clipped at x = 350 by the outer clip
	append(&a.cmds, gpu.Clip_Pop{})
	quad(a, {300, 500, 120, 60}, {0.30, 0.50, 0.90, 1}, radius = 8) // unclipped: straddles the outer edge

	// Alpha8 glyphs: the disc tinted in several colours and sizes; the AA edge
	// comes from the bitmap, the tint from `color`.
	tints := [5][4]f32{{1, 1, 1, 1}, {1, 0.35, 0.35, 1}, {0.35, 1, 0.45, 1}, {0.4, 0.6, 1, 1}, {1, 1, 1, 0.35}}
	for i in 0 ..< 5 {
		s := f32(64 - i * 8)
		glyph(a, {400 + f32(i) * 70, 360, s, s}, a.circle_page, tints[i])
	}
	// Pulsing tint + upscaled (bilinear) and downscaled draws.
	pulse := 0.5 + 0.5 * math.sin(t * 3)
	glyph(a, {400, 440, 96, 96}, a.circle_page, {1, pulse, 0.2, 1})
	glyph(a, {510, 440, 24, 24}, a.circle_page, {0.9, 0.9, 0.9, 1})
	// Half of the atlas via uv (right half of the disc).
	glyph(a, {550, 440, 32, 64}, a.circle_page, {0.6, 0.9, 1, 1}, uv = {0.5, 0, 1, 1})
	// Page 0 → built-in white page: renders as a plain tinted quad, no crash.
	glyph(a, {600, 440, 40, 40}, 0, {0.9, 0.5, 0.9, 1})

	// RGBA8 glyphs: gradient with a transparent hole, full and half alpha,
	// and one over a bright quad so the alpha hole is obvious.
	glyph(a, {700, 360, 96, 96}, a.grad_page, {1, 1, 1, 1})
	glyph(a, {810, 360, 96, 96}, a.grad_page, {1, 1, 1, 0.5})
	quad(a, {700, 470, 96, 96}, {0.95, 0.95, 0.95, 1}, radius = 10)
	glyph(a, {700, 470, 96, 96}, a.grad_page, {1, 1, 1, 1})

	// Footer: window size readout as a bar (no text yet), stroke only.
	quad(a, {30, H - 40, W - 60, 24}, {0, 0, 0, 0}, radius = 12, border_w = 2, border = {0.35, 0.40, 0.50, 1})
	quad(a, {32, H - 38, (W - 64) * (0.5 + 0.5 * math.sin(t)), 20}, {0.35, 0.70, 0.95, 1}, radius = 10)
}

// ------------------------------------------------------------------ main

main :: proc() {
	a := &app
	if !parse_args(a) { os.exit(2) }
	a.start = time.tick_now()
	a.running = true

	// ---- Wayland: connect, registry, globals
	if ok, missing := wl.load(); !ok {
		fmt.eprintln("gpu_check: cannot load libwayland-client:", missing)
		os.exit(1)
	}
	a.display = wl.display_connect()
	if a.display == nil {
		fmt.eprintln("gpu_check: wl_display_connect failed (is WAYLAND_DISPLAY set?)")
		os.exit(1)
	}
	a.registry = wl.wl_display_get_registry(a.display)
	rl := wl.wl_registry_listener_noop()
	rl.global = on_global
	wl.wl_registry_add_listener(a.registry, &rl, a)
	wl.display_roundtrip(a.display)
	if a.compositor == nil || a.wm_base == nil {
		fmt.eprintln("gpu_check: compositor lacks wl_compositor or xdg_wm_base")
		os.exit(1)
	}
	log("connected; wl_compositor v%d, xdg_wm_base v%d", wl.proxy_version(a.compositor), wl.proxy_version(a.wm_base))

	wml := wl.xdg_wm_base_listener_noop()
	wml.ping = on_ping
	wl.xdg_wm_base_add_listener(a.wm_base, &wml, a)

	// ---- surface + xdg role, first commit → configure
	a.surface     = wl.wl_compositor_create_surface(a.compositor)
	a.xdg_surface = wl.xdg_wm_base_get_xdg_surface(a.wm_base, a.surface)
	xsl := wl.xdg_surface_listener_noop()
	xsl.configure = on_xdg_surface_configure
	wl.xdg_surface_add_listener(a.xdg_surface, &xsl, a)
	a.toplevel = wl.xdg_surface_get_toplevel(a.xdg_surface)
	tl := wl.xdg_toplevel_listener_noop()
	tl.configure = on_toplevel_configure
	tl.close     = on_toplevel_close
	wl.xdg_toplevel_add_listener(a.toplevel, &tl, a)
	wl.xdg_toplevel_set_title(a.toplevel, "Baldr gpu_check")
	wl.xdg_toplevel_set_app_id(a.toplevel, "baldr.gpu_check")
	wl.xdg_toplevel_set_min_size(a.toplevel, 64, 64)
	wl.wl_surface_commit(a.surface)
	wl.display_flush(a.display)
	for a.running && !a.configure_pending {
		if wl.display_dispatch(a.display) < 0 {
			fmt.eprintln("gpu_check: display error while waiting for configure")
			os.exit(1)
		}
	}
	if !a.running { log("closed before configure"); os.exit(0) }
	apply_configure(a)

	// ---- gpu: instance, surface, target, atlas pages
	r := &a.r
	exts := [1]cstring{vk.KHR_WAYLAND_SURFACE_EXTENSION_NAME}
	if ok, why := gpu.init(r, exts[:], "Baldr gpu_check"); !ok {
		fmt.eprintln("gpu_check: gpu.init failed:", why)
		os.exit(1)
	}
	log("vulkan instance %d.%d, validation layer: %s", r.instance_version >> 22, (r.instance_version >> 12) & 0x3ff,
		"enabled" if r.validation else "not installed")
	sinfo := vk.WaylandSurfaceCreateInfoKHR{
		sType   = .WAYLAND_SURFACE_CREATE_INFO_KHR,
		display = (^vk.wl_display)(a.display),
		surface = (^vk.wl_surface)(a.surface),
	}
	vk_surface: vk.SurfaceKHR
	if res := vk.CreateWaylandSurfaceKHR(gpu.instance(r), &sinfo, nil, &vk_surface); res != .SUCCESS {
		fmt.eprintfln("gpu_check: vkCreateWaylandSurfaceKHR: %v", res)
		os.exit(1)
	}
	target, tok := gpu.target_add(r, vk_surface, {u32(a.width), u32(a.height)}, a.transparent)
	if !tok {
		fmt.eprintln("gpu_check: target_add failed:", r.last_error)
		os.exit(1)
	}
	a.target = target
	ts := &r.targets[int(target) - 1]
	log("device: %s, queue family %d, %s, incremental_present=%v", r.device_name, r.qfamily,
		"VK_KHR_dynamic_rendering" if r.khr_dynamic_rendering else "core 1.3 dynamic rendering", r.has_incremental_present)
	log("swapchain %dx%d, %d images, %v/%v, transparent=%v", ts.extent.width, ts.extent.height, len(ts.images),
		ts.format.format, ts.format.colorSpace, a.transparent)

	a.circle_page = make_circle_page(a)
	a.grad_page   = make_gradient_page(a)
	if a.circle_page == 0 || a.grad_page == 0 {
		fmt.eprintln("gpu_check: atlas_create failed:", r.last_error)
		os.exit(1)
	}
	log("atlas pages: circle Alpha8 = %d, gradient RGBA8 = %d (white page = %d)", a.circle_page, a.grad_page, gpu.WHITE_PAGE)

	clear_color := [4]f32{0, 0, 0, 0} if a.transparent else [4]f32{0.09, 0.10, 0.13, 1}

	// ---- main loop: draw on frame callbacks, never spin
	for a.running {
		if a.configure_pending { apply_configure(a) }
		if a.resize_needed {
			a.resize_needed = false
			gpu.target_resize(r, a.target, {u32(a.width), u32(a.height)})
			log("resize -> swapchain %dx%d (%d images)", ts.extent.width, ts.extent.height, len(ts.images))
			// A frame request left pending cannot fire until WSI commits again.
			if a.frame_cb != nil { wl.proxy_destroy(a.frame_cb); a.frame_cb = nil }
			a.frame_pending = false
		}
		if !a.frame_pending {
			a.frame_cb = wl.wl_surface_frame(a.surface)
			fl := wl.wl_callback_listener_noop()
			fl.done = on_frame_done
			wl.wl_callback_add_listener(a.frame_cb, &fl, a)
			a.frame_pending = true

			t := f32(time.duration_seconds(time.tick_since(a.start)))
			build_scene(a, t)
			damage := [1][4]f32{{0, 0, f32(a.width), f32(a.height)}}
			res := gpu.render(r, a.target, a.cmds[:], clear_color, damage[:])
			switch res {
			case .OK, .Recreated:
				a.frames += 1
				if res == .Recreated { log("render: swapchain recreated (%dx%d)", ts.extent.width, ts.extent.height) }
				if a.frames == 1 { log("first frame presented (%d cmds)", len(a.cmds)) }
				if a.maximize_at != 0 && a.frames == a.maximize_at && !a.maximized {
					a.maximized = true
					wl.xdg_toplevel_set_maximized(a.toplevel)
					log("requested set_maximized (expect configure with a new size)")
				}
				if a.max_frames != 0 && a.frames >= a.max_frames {
					a.running = false
					a.exit_reason = fmt.tprintf("--frames %d reached", a.max_frames)
				}
			case .Skipped:
				// zero-size target: no present, so no frame callback will come; drop the request
				if a.frame_cb != nil { wl.proxy_destroy(a.frame_cb); a.frame_cb = nil }
				a.frame_pending = false
			case .Lost, .Error:
				a.errors += 1
				log("render failed: %v (%s)", res, r.last_error)
				a.running = false
				a.exit_reason = "render error"
			}
		}
		if !a.running { break }
		if !pump(a, remaining_ms(a)) {
			fmt.eprintln("gpu_check: display connection lost")
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

	// ---- teardown: gpu (owns the VkSurfaceKHR; WSI talks to the wl_surface) before the proxies
	validation_errors := r.validation_errors
	gpu.atlas_destroy(r, a.grad_page)
	gpu.atlas_destroy(r, a.circle_page)
	gpu.destroy(r)
	if a.frame_cb != nil { wl.proxy_destroy(a.frame_cb) }
	wl.xdg_toplevel_destroy(a.toplevel)
	wl.xdg_surface_destroy(a.xdg_surface)
	wl.wl_surface_destroy(a.surface)
	wl.xdg_wm_base_destroy(a.wm_base)
	wl.proxy_destroy(a.compositor)
	wl.proxy_destroy(a.registry)
	wl.display_roundtrip(a.display)
	if e := wl.display_get_error(a.display); e != 0 {
		fmt.eprintfln("gpu_check: display error %d", e)
		a.errors += 1
	}
	wl.display_disconnect(a.display)
	delete(a.cmds)

	if validation_errors > 0 { log("validation: %d errors", validation_errors) }
	if a.errors > 0 || validation_errors > 0 { os.exit(3) }
	os.exit(0)
}
