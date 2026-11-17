#+build windows
package main

// win32_check — exercises platform/win32 end to end: one Window surface,
// Vulkan presenting a clear colour on every Ev_Redraw (the colour follows the
// pointer and flashes on button presses so a screenshot proves input reached
// the app), every event logged with its fields to stdout and `--log <file>`.
// Driven on a Windows interactive desktop by tools/run_check.ps1
// (scheduled tasks; tools/inject.ps1 injects mouse/keys, maximizes, closes).
//
//   win32_check.exe [--seconds N] [--log <path>]
//
// Exit codes: 0 normal, 1 setup failure, 2 bad arguments.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:thread"
import "core:time"
import "baldr:platform"
import "baldr:platform/win32"

App :: struct {
	b:              ^platform.Backend,
	s:              platform.Surface,
	r:              Renderer,
	vk_ready:       bool,
	size_px:        [2]u32, // last Ev_Configure (or surface_geometry inside the modal loop)
	size:           [2]f32,
	swapchain_size: [2]u32,
	pointer:        [2]f32,
	flash:          f32,

	frames:         u64,
	modal_redraws:  int,
	counts:         [len(EVENT_NAMES)]int,
	running:        bool,
	exit_reason:    string,
	start:          time.Tick,
	deadline_ns:    i64, // 0 = none
	log_file:       ^os.File,
}

// The events this spike gives a counter of its own. Anything else (the
// shell tier, a drag, a watch) lands in the last slot.
EVENT_NAMES := [?]string{
	"Ev_Configure", "Ev_Close", "Ev_Focus", "Ev_Redraw", "Ev_Pointer_Enter", "Ev_Pointer_Leave",
	"Ev_Pointer_Motion", "Ev_Pointer_Button", "Ev_Scroll", "Ev_Key", "Ev_Text", "Ev_Theme", "Ev_Quit",
	"other",
}

app: App

// ------------------------------------------------------------------- log

@(private="file")
emit :: proc(to: ^os.File, line: string) {
	os.write_string(to, line)
	if app.log_file != nil { os.write_string(app.log_file, line) }
}

log :: proc(format: string, args: ..any) {
	elapsed := time.duration_seconds(time.tick_since(app.start))
	emit(os.stdout, fmt.tprintf("win32_check +%.3fs: %s\n", elapsed, fmt.tprintf(format, ..args)))
}

log_err :: proc(args: ..any) {
	emit(os.stderr, fmt.tprintf("win32_check: %s\n", fmt.tprint(..args)))
}
log_errf :: proc(format: string, args: ..any) {
	emit(os.stderr, fmt.tprintf("win32_check: %s\n", fmt.tprintf(format, ..args)))
}

die :: proc(code: int) -> ! {
	if app.log_file != nil { os.close(app.log_file) }
	os.exit(code)
}

// ---------------------------------------------------------------- events

event_index :: proc(ev: platform.Event) -> int {
	// `#partial`, and the fallthrough is the point: these get a counter,
	// everything else is "other", so a new `platform.Event` variant does
	// not break the spike.
	#partial switch _ in ev {
	case platform.Ev_Configure:      return 0
	case platform.Ev_Close:          return 1
	case platform.Ev_Focus:          return 2
	case platform.Ev_Redraw:         return 3
	case platform.Ev_Pointer_Enter:  return 4
	case platform.Ev_Pointer_Leave:  return 5
	case platform.Ev_Pointer_Motion: return 6
	case platform.Ev_Pointer_Button: return 7
	case platform.Ev_Scroll:         return 8
	case platform.Ev_Key:            return 9
	case platform.Ev_Text:           return 10
	case platform.Ev_Theme:          return 11
	case platform.Ev_Quit:           return 12
	}
	return len(EVENT_NAMES) - 1 // "other"
}

handle :: proc(a: ^App, ev: platform.Event) {
	idx := event_index(ev)
	a.counts[idx] += 1
	// Ev_Redraw arrives every frame; log the first and count the rest.
	if _, is_redraw := ev.(platform.Ev_Redraw); !is_redraw || a.counts[idx] == 1 {
		log("%v", ev)
	}
	// `#partial` for the same reason as `event_index` above: the events this
	// spike acts on, and no list of the ones it does not.
	#partial switch e in ev {
	case platform.Ev_Configure:
		a.size_px = e.size_px
		a.size = e.size
		a.b.surface_request_frame(a.b, a.s)
	case platform.Ev_Redraw:
		render(a)
		a.b.surface_request_frame(a.b, a.s) // keep presenting; FIFO paces the loop
	case platform.Ev_Close:
		a.running = false
		a.exit_reason = "Ev_Close"
	case platform.Ev_Quit:
		a.running = false
		a.exit_reason = "Ev_Quit"
	case platform.Ev_Pointer_Enter:
		a.pointer = e.pos
	case platform.Ev_Pointer_Motion:
		a.pointer = e.pos
	case platform.Ev_Pointer_Button:
		if e.pressed { a.flash = 1 }
	}
}

// ----------------------------------------------------------------- frame

// render presents one frame at a.size_px, recreating the swapchain when the
// size changed. Clear colour: red = pointer x, green = pointer y (logical
// fractions), blue flashes white on button presses.
render :: proc(a: ^App) {
	if !a.vk_ready || !a.running || a.size_px.x == 0 || a.size_px.y == 0 { return }
	r := &a.r
	if a.swapchain_size != a.size_px {
		if !vk_create_swapchain(r, a.size_px.x, a.size_px.y) {
			a.running = false
			a.exit_reason = "swapchain recreation failed"
			return
		}
		// Win32 dictates currentExtent (the live client rect), which can be
		// ahead of the Ev_Configure still in the queue: record what we got.
		a.swapchain_size = {r.extent.width, r.extent.height}
		log("swapchain %dx%d (%d images)", r.extent.width, r.extent.height, len(r.images))
	}
	px := clamp(a.pointer.x / max(a.size.x, 1), 0, 1)
	py := clamp(a.pointer.y / max(a.size.y, 1), 0, 1)
	clear := [4]f32{0.15 + 0.6 * px, 0.15 + 0.6 * py, 0.3 + 0.7 * a.flash, 1}
	a.flash = max(a.flash - 0.05, 0)
	presented, out_of_date := vk_draw(r, clear)
	if presented {
		a.frames += 1
		if a.frames == 1 { log("first frame presented (%dx%d)", r.extent.width, r.extent.height) }
	}
	if out_of_date { a.swapchain_size = {} }
}

// Called by the backend from inside the Win32 modal size/move loop (WM_TIMER /
// WM_PAINT); the Ev_Configure for the new size is still queued, so ask.
modal_redraw :: proc(user: rawptr, s: platform.Surface) {
	a := (^App)(user)
	size, size_px, _ := a.b.surface_geometry(a.b, s)
	a.size, a.size_px = size, size_px
	a.modal_redraws += 1
	if a.modal_redraws == 1 { log("redraw_callback from the modal loop: %dx%d px", size_px.x, size_px.y) }
	render(a)
}

remaining_ms :: proc(a: ^App) -> i32 {
	if a.deadline_ns == 0 { return -1 }
	left := a.deadline_ns - time.duration_nanoseconds(time.tick_since(a.start))
	if left <= 0 { return 0 }
	return i32(min(left / 1_000_000 + 1, 1000))
}

// ------------------------------------------------------------------ args

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
		case "--log":
			if i + 1 >= len(args) { fmt.eprintln("--log needs a path"); return false }
			i += 1
			f, err := os.open(args[i], {.Write, .Create, .Append})
			if err != nil { fmt.eprintfln("cannot open log file %s: %v", args[i], err); return false }
			a.log_file = f
		case "--help", "-h":
			fmt.println("usage: win32_check [--seconds N] [--log <path>]")
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
	a.start = time.tick_now()
	if !parse_args(a) { die(2) }
	a.running = true
	log("start: %v", os.args)

	// ---- backend
	b := win32.backend()
	a.b = b
	if ok, why := b.init(b); !ok {
		log_errf("backend init failed: %s", why)
		die(1)
	}
	b.redraw_callback = modal_redraw
	b.redraw_user = a
	log("backend %s initialised", b.name)
	log("system_theme: %v", b.system_theme(b))

	// Clipboard round trip (restores the previous text afterwards).
	before, had_before := b.clipboard_get(b)
	set_ok := b.clipboard_set(b, "baldr win32_check ✓")
	after, get_ok := b.clipboard_get(b)
	log("clipboard: set %v, get %v, text %q, round-trip %s", set_ok, get_ok, after,
		"ok" if set_ok && get_ok && after == "baldr win32_check ✓" else "MISMATCH")
	if had_before { b.clipboard_set(b, before) }

	// wake from another thread must interrupt a blocking pump (which then
	// returns nothing): no surface exists yet, so nothing else can wake it.
	{
		t0 := time.tick_now()
		th := thread.create_and_start_with_data(b, proc(data: rawptr) {
			time.sleep(300 * time.Millisecond)
			bb := (^platform.Backend)(data)
			bb.wake(bb)
		})
		evs := b.pump(b, 5000)
		waited := time.duration_milliseconds(time.tick_since(t0))
		thread.join(th)
		thread.destroy(th)
		log("wake: pump(5000) returned %d events after %.0f ms (%s)", len(evs), waited,
			"ok" if waited < 2000 else "TIMED OUT: wake did not interrupt the pump")
	}

	// ---- surface
	s, sok := b.surface_create(b, {kind = .Window, title = "Baldr win32_check", size = {640, 400}, min_size = {200, 120}})
	if !sok {
		log_err("surface_create failed")
		die(1)
	}
	a.s = s
	size, size_px, scale := b.surface_geometry(b, s)
	log("surface %d created: %vx%v logical, %dx%d px, scale %v", s, size.x, size.y, size_px.x, size_px.y, scale)

	// ---- Vulkan through the backend's two hooks
	r := &a.r
	if !vk_boot(r) || !vk_create_instance(r, b.vk_instance_extensions(b)) { die(1) }
	log("vulkan instance %d.%d, extensions %v", r.instance_version >> 22, (r.instance_version >> 12) & 0x3ff, b.vk_instance_extensions(b))
	surf, vok := b.vk_create_surface(b, s, r.instance)
	if !vok {
		log_err("vk_create_surface failed")
		die(1)
	}
	r.surface = surf
	log("VkSurfaceKHR from backend.vk_create_surface")
	if !vk_pick_physical_device(r) || !vk_create_device(r) { die(1) }
	log("device: %s, driver: %s", r.device_name, r.driver_info)
	a.vk_ready = true

	// ---- loop: pump → handle (Ev_Redraw renders and re-requests) → repeat
	for a.running {
		evs := b.pump(b, remaining_ms(a))
		for ev in evs { handle(a, ev) }
		if a.deadline_ns != 0 && time.duration_nanoseconds(time.tick_since(a.start)) >= a.deadline_ns && a.running {
			a.running = false
			a.exit_reason = fmt.aprintf("--seconds %.1f elapsed", f64(a.deadline_ns) / 1e9)
		}
	}

	elapsed := time.duration_seconds(time.tick_since(a.start))
	summary := fmt.tprintf("%d frames in %.2fs (%.1f fps), %d modal redraws", a.frames, elapsed, f64(a.frames) / max(elapsed, 0.001), a.modal_redraws)
	for n, i in EVENT_NAMES {
		if a.counts[i] > 0 { summary = fmt.tprintf("%s, %s x%d", summary, n, a.counts[i]) }
	}
	log("closing (%s): %s", a.exit_reason, summary)

	vk_shutdown(r)
	b.surface_destroy(b, s)
	b.shutdown(b)
	die(0)
}
