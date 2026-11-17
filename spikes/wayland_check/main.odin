#+build linux
// wayland_check — exercises platform/wayland through the platform.Backend
// contract: one surface, Vulkan (VkSurfaceKHR from backend.vk_create_surface),
// a triangle presented on every Ev_Redraw, and every event printed with its
// fields. Exit with --seconds N, closing the window, or Ctrl+C.
//
//   ./build/wayland_check [--seconds N] [--layer] [--quiet-redraw]
//
//   --layer          create a .Layer surface (top-anchored 32 px bar) instead of a window
//   --quiet-redraw   count Ev_Redraw instead of printing each one
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:sys/linux"
import "core:thread"
import "core:time"
import "baldr:platform"
import wayland "baldr:platform/wayland"

Opts :: struct {
	seconds:      f64,
	layer:        bool,
	quiet_redraw: bool,
}

parse_args :: proc() -> (o: Opts, ok: bool) {
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--seconds":
			if i + 1 >= len(args) { fmt.eprintln("--seconds needs a value"); return o, false }
			i += 1
			v, vok := strconv.parse_f64(args[i])
			if !vok { fmt.eprintln("bad --seconds value"); return o, false }
			o.seconds = v
		case "--layer":
			o.layer = true
		case "--quiet-redraw":
			o.quiet_redraw = true
		case "--help", "-h":
			fmt.println("usage: wayland_check [--seconds N] [--layer] [--quiet-redraw]")
			os.exit(0)
		case:
			fmt.eprintln("unknown argument:", args[i])
			return o, false
		}
	}
	return o, true
}

cpu_seconds :: proc() -> f64 {
	ru: linux.RUsage
	linux.getrusage(.SELF, &ru)
	return f64(ru.utime.seconds) + f64(ru.utime.microseconds) * 1e-6 +
		f64(ru.stime.seconds) + f64(ru.stime.microseconds) * 1e-6
}

// xkb_probe feeds evdev keycodes through the backend's translation path —
// a unit-style check that does not need real key presses.
xkb_probe :: proc(b: ^platform.Backend) {
	Probe :: struct { evdev: u32, want_key: platform.Key, want_text: string }
	probes := [?]Probe{
		{30, .A, "a"},      // KEY_A
		{2, .N1, "1"},      // KEY_1
		{28, .Enter, ""},   // KEY_ENTER (control char: no text)
		{1, .Escape, ""},   // KEY_ESC
		{57, .Space, " "},  // KEY_SPACE
		{105, .Left, ""},   // KEY_LEFT
		{59, .F1, ""},      // KEY_F1
		{42, .Shift_L, ""}, // KEY_LEFTSHIFT
		{12, .Minus, "-"},  // KEY_MINUS
		{79, .KP_1, ""},    // KEY_KP1 (NumLock off → KP_End keysym, text "")
	}
	pass := 0
	for p in probes {
		key, sym, text, ok := wayland.debug_key_probe(b, p.evdev)
		if !ok {
			fmt.println("xkb_probe: no keymap yet (no wl_keyboard on the seat?)")
			return
		}
		good := key == p.want_key && (p.want_text == "" || text == p.want_text)
		if good do pass += 1
		fmt.printfln("xkb_probe: evdev %3d -> key=%-8v keysym=0x%04x text=%q %s", p.evdev, key, sym, text, "ok" if good else "MISMATCH")
	}
	fmt.printfln("xkb_probe: %d/%d passed", pass, len(probes))
}

// wake_test: a blocked pump must return when another thread calls wake,
// even though no event arrived.
wake_test :: proc(b: ^platform.Backend) {
	waker :: proc(t: ^thread.Thread) {
		time.sleep(250 * time.Millisecond)
		bk := (^platform.Backend)(t.data)
		bk.wake(bk)
	}
	th := thread.create(waker)
	th.data = b
	thread.start(th)
	t0 := time.tick_now()
	evs := b.pump(b, 3000)
	ms := time.duration_milliseconds(time.tick_since(t0))
	thread.join(th)
	thread.destroy(th)
	fmt.printfln("wake_test: pump(3000 ms) returned after %.0f ms with %d events (%s)", ms, len(evs),
		"ok" if ms < 1000 else "FAILED: wake did not interrupt")
}

main :: proc() {
	opts, aok := parse_args()
	if !aok do os.exit(2)
	start := time.tick_now()

	b := wayland.backend()
	if ok, why := b.init(b); !ok {
		fmt.eprintln("wayland_check: init failed:", why)
		os.exit(1)
	}
	fmt.printfln("wayland_check: backend %q initialised", b.name)
	wake_test(b)

	desc := platform.Surface_Desc{
		kind   = .Window,
		title  = "Baldr wayland_check",
		app_id = "baldr.wayland_check",
		size   = {640, 400},
	}
	if opts.layer {
		desc.kind = .Layer
		desc.size = {0, 32}
		desc.layer = {level = .Top, anchor = {.Top, .Left, .Right}, exclusive_zone = 32, keyboard = .None}
	}
	s, sok := b.surface_create(b, desc)
	if !sok {
		fmt.eprintln("wayland_check: surface_create failed")
		os.exit(1)
	}
	fmt.printfln("wayland_check: surface %d created (%v)", s, desc.kind)

	r: Renderer
	if !vk_boot(&r) || !vk_create_instance(&r, b.vk_instance_extensions(b)) do os.exit(1)
	vsurf, vok := b.vk_create_surface(b, s, r.instance)
	if !vok {
		fmt.eprintln("wayland_check: vk_create_surface failed")
		os.exit(1)
	}
	r.surface = vsurf
	if !vk_pick_physical_device(&r) || !vk_create_device(&r) || !vk_create_pipeline(&r) do os.exit(1)
	fmt.printfln("wayland_check: vulkan ready on %s", r.device_name)

	running := true
	need_swapchain := false
	size_px: [2]u32
	frames, redraws, configures: u64
	first_redraw_at: time.Tick
	probed := false
	cursor: platform.Cursor = .Default
	deadline_ns := i64(opts.seconds * 1e9)

	for running {
		timeout: i32 = -1
		if deadline_ns > 0 {
			left := deadline_ns - time.duration_nanoseconds(time.tick_since(start))
			if left <= 0 do break
			timeout = i32(min(left / 1_000_000 + 1, 1000))
		}
		events := b.pump(b, timeout)
		for ev in events {
			t := time.duration_milliseconds(time.tick_since(start))
			// `#partial`: only the events this spike acts on, so a new
			// `platform.Event` variant does not break it.
			#partial switch e in ev {
			case platform.Ev_Redraw:
				redraws += 1
				if redraws == 1 do first_redraw_at = time.tick_now()
				if !opts.quiet_redraw do fmt.printfln("[%8.1f ms] %v", t, e)
				if r.swapchain != 0 && !need_swapchain {
					presented, out_of_date := vk_draw(&r, f32(t) / 1000)
					if presented do frames += 1
					if out_of_date do need_swapchain = true
				}
				b.surface_request_frame(b, s)
			case platform.Ev_Configure:
				configures += 1
				fmt.printfln("[%8.1f ms] %v", t, e)
				if e.size_px != size_px {
					size_px = e.size_px
					need_swapchain = true
				}
			case platform.Ev_Close:
				fmt.printfln("[%8.1f ms] %v", t, e)
				running = false
			case platform.Ev_Quit:
				fmt.printfln("[%8.1f ms] %v", t, e)
				running = false
			case platform.Ev_Pointer_Motion:
				fmt.printfln("[%8.1f ms] %v", t, e)
				// Exercise surface_set_cursor: the cursor shape follows the pointer's third of the width.
				want: platform.Cursor = .Text if e.pos.x < 213 else (.Default if e.pos.x < 426 else .Pointer)
				if want != cursor {
					cursor = want
					b.surface_set_cursor(b, s, cursor)
					fmt.printfln("[%8.1f ms] cursor -> %v", t, cursor)
				}
			case platform.Ev_Focus, platform.Ev_Pointer_Enter, platform.Ev_Pointer_Leave,
				platform.Ev_Pointer_Button, platform.Ev_Scroll, platform.Ev_Key, platform.Ev_Text, platform.Ev_Theme:
				fmt.printfln("[%8.1f ms] %v", t, e)
			}
		}
		if need_swapchain && size_px.x > 0 && size_px.y > 0 {
			need_swapchain = false
			if !vk_create_swapchain(&r, size_px.x, size_px.y) do os.exit(1)
			fmt.printfln("wayland_check: swapchain %dx%d (%d images)", r.extent.width, r.extent.height, len(r.images))
			b.surface_request_frame(b, s)
		}
		if configures > 0 && !probed {
			probed = true
			xkb_probe(b)
		}
	}

	elapsed := time.duration_seconds(time.tick_since(start))
	redraw_window := time.duration_seconds(time.tick_since(first_redraw_at)) if redraws > 0 else 0
	fmt.printfln("wayland_check: %d configures, %d redraws, %d frames presented in %.2fs (%.1f redraws/s over %.2fs), cpu %.3fs (%.1f%%)",
		configures, redraws, frames, elapsed, f64(redraws) / max(redraw_window, 0.001), redraw_window,
		cpu_seconds(), 100 * cpu_seconds() / max(elapsed, 0.001))

	vk_shutdown(&r)
	b.surface_destroy(b, s)
	b.shutdown(b)
	fmt.println("wayland_check: clean shutdown")
}
