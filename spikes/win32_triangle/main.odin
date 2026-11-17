#+build windows
package main

// Baldr spike: Win32 window + Vulkan triangle, no SDL/GLFW, no C in-tree,
// vulkan-1.dll loaded at runtime with core:dynlib. Windows counterpart of
// spikes/wl_triangle (same renderer, same shaders).
//
//   win32_triangle.exe [--seconds N] [--frames N] [--log <path>] [--maximize] [--minimize]
//
// Exit codes: 0 normal, 1 setup/present failure, 2 bad arguments.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"
import win "core:sys/windows"

DEFAULT_WIDTH  :: 800 // logical pixels; the client area is scaled by the monitor DPI
DEFAULT_HEIGHT :: 600

App :: struct {
	hinstance:             win.HINSTANCE,
	hwnd:                  win.HWND,
	dpi:                   u32,
	width, height:         i32, // client area in physical pixels (last WM_SIZE)
	minimized:             bool,
	in_size_move:          bool, // inside WM_ENTERSIZEMOVE..WM_EXITSIZEMOVE
	resize_needed:         bool,
	resize_events:         int,
	swapchain_recreations: int,
	vk_ready:              bool,
	present_failures:      int,

	running:     bool,
	exit_reason: string,
	frames:      u64,
	max_frames:  u64,
	deadline_ns: i64, // 0 = none
	maximize_at: u64, // --maximize: ShowWindow(SW_MAXIMIZE) after this many frames, SW_RESTORE 120 frames later (0 = never)
	minimize_at: u64, // --minimize: ShowWindow(SW_MINIMIZE) after this many frames, SW_RESTORE 2 s later (0 = never)
	minimized_at: time.Tick,
	start:       time.Tick,
	log_file:    ^os.File,

	r: Renderer,
}

app: App

// ------------------------------------------------------------------- log

@(private="file")
emit :: proc(to: ^os.File, line: string) {
	os.write_string(to, line)
	if app.log_file != nil { os.write_string(app.log_file, line) }
}

// Milestone line: stdout + the --log file, prefixed with the elapsed time.
log :: proc(format: string, args: ..any) {
	elapsed := time.duration_seconds(time.tick_since(app.start))
	emit(os.stdout, fmt.tprintf("win32_triangle +%.3fs: %s\n", elapsed, fmt.tprintf(format, ..args)))
}

// Error sinks used by vk.odin in place of fmt.eprintln / fmt.eprintfln.
log_err :: proc(args: ..any) {
	emit(os.stderr, fmt.tprintf("win32_triangle: %s\n", fmt.tprint(..args)))
}
log_errf :: proc(format: string, args: ..any) {
	emit(os.stderr, fmt.tprintf("win32_triangle: %s\n", fmt.tprintf(format, ..args)))
}

die :: proc(code: int) -> ! {
	if app.log_file != nil { os.close(app.log_file) }
	os.exit(code)
}

// ----------------------------------------------------------------- frame

// Draws one frame if there is something to draw. Called from the idle loop
// and, during the modal size/move loop, from WM_TIMER in wnd_proc.
render_frame :: proc(a: ^App) {
	if !a.vk_ready || !a.running || a.minimized || a.width <= 0 || a.height <= 0 { return }
	r := &a.r
	if a.resize_needed {
		a.resize_needed = false
		if !vk_create_swapchain(r, u32(a.width), u32(a.height)) {
			a.running = false
			a.exit_reason = "swapchain recreation failed"
			return
		}
		a.swapchain_recreations += 1
		log("resize -> swapchain %dx%d (%d images)", r.extent.width, r.extent.height, len(r.images))
	}
	t := f32(time.duration_seconds(time.tick_since(a.start)))
	presented, out_of_date := vk_draw(r, t)
	if presented {
		a.frames += 1
		a.present_failures = 0
		if a.frames == 1 { log("first frame presented (%dx%d)", r.extent.width, r.extent.height) }
		if a.maximize_at != 0 && a.frames == a.maximize_at {
			// A real WM_SIZE with a new size follows, exercising swapchain recreation.
			log("requested SW_MAXIMIZE (expect WM_SIZE maximized)")
			win.ShowWindow(a.hwnd, win.SW_MAXIMIZE)
		} else if a.maximize_at != 0 && a.frames == a.maximize_at + 120 {
			log("requested SW_RESTORE (expect WM_SIZE restored)")
			win.ShowWindow(a.hwnd, win.SW_RESTORE)
		}
		if a.minimize_at != 0 && a.frames == a.minimize_at {
			// No frames are produced while minimized, so the restore is timed (see main loop).
			log("requested SW_MINIMIZE (expect WM_SIZE minimized, then an idle wait)")
			a.minimized_at = time.tick_now()
			win.ShowWindow(a.hwnd, win.SW_MINIMIZE)
		}
	} else if !out_of_date {
		a.present_failures += 1
		if a.present_failures >= 3 {
			a.running = false
			a.exit_reason = "3 consecutive draw/present failures"
		}
	}
	if out_of_date { a.resize_needed = true }
	check_limits(a)
}

check_limits :: proc(a: ^App) {
	if !a.running { return }
	if a.max_frames != 0 && a.frames >= a.max_frames {
		a.running = false
		a.exit_reason = fmt.aprintf("--frames %d reached", a.max_frames)
	} else if a.deadline_ns != 0 && time.duration_nanoseconds(time.tick_since(a.start)) >= a.deadline_ns {
		a.running = false
		a.exit_reason = fmt.aprintf("--seconds %.1f elapsed", f64(a.deadline_ns) / 1e9)
	}
}

// Milliseconds until the --seconds deadline, -1 if none (for the wait when minimized).
remaining_ms :: proc(a: ^App) -> i32 {
	if a.deadline_ns == 0 { return -1 }
	left := a.deadline_ns - time.duration_nanoseconds(time.tick_since(a.start))
	if left <= 0 { return 0 }
	return i32(min(left / 1_000_000 + 1, 1000))
}

process_cpu_seconds :: proc() -> f64 {
	to_s :: proc(ft: win.FILETIME) -> f64 {
		return f64(u64(ft.dwHighDateTime) << 32 | u64(ft.dwLowDateTime)) / 1e7
	}
	created, exited, kernel, user: win.FILETIME
	win.GetProcessTimes(win.GetCurrentProcess(), &created, &exited, &kernel, &user)
	return to_s(kernel) + to_s(user)
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
		case "--frames":
			if i + 1 >= len(args) { fmt.eprintln("--frames needs a value"); return false }
			i += 1
			v, ok := strconv.parse_u64(args[i])
			if !ok { fmt.eprintln("bad --frames value"); return false }
			a.max_frames = v
		case "--log":
			if i + 1 >= len(args) { fmt.eprintln("--log needs a path"); return false }
			i += 1
			f, err := os.open(args[i], {.Write, .Create, .Append})
			if err != nil { fmt.eprintfln("cannot open log file %s: %v", args[i], err); return false }
			a.log_file = f
		case "--maximize":
			a.maximize_at = 60
		case "--minimize":
			a.minimize_at = 60
		case "--help", "-h":
			fmt.println("usage: win32_triangle [--seconds N] [--frames N] [--log <path>] [--maximize] [--minimize]")
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

	// ---- window first: Vulkan needs the HWND for the surface
	if !win_create_window(a) { die(1) }

	// ---- Vulkan
	r := &a.r
	if !vk_boot(r) || !vk_create_instance(r) { die(1) }
	log("vulkan instance %d.%d (vulkan-1.dll via core:dynlib), validation layer: %s",
		r.instance_version >> 22, (r.instance_version >> 12) & 0x3ff,
		"enabled (VK_LAYER_KHRONOS_validation + VK_EXT_debug_utils)" if r.validation else "not installed")
	if !vk_create_win32_surface(r, a.hinstance, a.hwnd) { die(1) }
	log("win32 surface created (VK_KHR_win32_surface)")
	if !vk_pick_physical_device(r) || !vk_create_device(r) { die(1) }
	log("device: %s, driver: %s, queue family %d, %s", r.device_name, r.driver_info, r.qfamily,
		"VK_KHR_dynamic_rendering" if r.khr_dynamic_rendering else "core 1.3 dynamic rendering")
	if !vk_create_pipeline(r) { die(1) }
	log("pipeline created (dynamic rendering, dynamic viewport/scissor)")
	if !vk_create_swapchain(r, u32(a.width), u32(a.height)) { die(1) }
	log("swapchain created: %dx%d, %d images (minImageCount %d), %v/%v, %v",
		r.extent.width, r.extent.height, len(r.images), r.min_image_count,
		r.format.format, r.format.colorSpace, r.present_mode)
	a.vk_ready = true
	a.resize_needed = false

	// ---- main loop. Drain the queue, then either draw (FIFO present blocks
	// until the next vblank, so this paces to the refresh rate without a spin)
	// or, when there is nothing to draw, sleep on the queue until a message or
	// the deadline. While the user drags the frame, Windows runs its own loop
	// inside DefWindowProc and WM_TIMER (see wnd_proc) keeps frames coming.
	for a.running {
		if !win_pump_messages(a) { a.running = false; break }
		check_limits(a)
		if !a.running { break }
		if a.minimized || a.width <= 0 || a.height <= 0 {
			wait := remaining_ms(a)
			if a.minimize_at != 0 && a.minimized_at != {} {
				if time.duration_seconds(time.tick_since(a.minimized_at)) >= 2 {
					a.minimized_at = {}
					log("requested SW_RESTORE after 2 s minimized (cpu so far %.2fs)", process_cpu_seconds())
					win.ShowWindow(a.hwnd, win.SW_RESTORE)
				} else if wait < 0 || wait > 100 {
					wait = 100
				}
			}
			win_wait_messages(wait)
		} else {
			render_frame(a)
		}
	}

	elapsed := time.duration_seconds(time.tick_since(a.start))
	log("closing (%s): %d frames in %.2fs (%.1f fps), %d resize events, %d swapchain recreations, cpu %.2fs",
		a.exit_reason, a.frames, elapsed, f64(a.frames) / max(elapsed, 0.001),
		a.resize_events, a.swapchain_recreations, process_cpu_seconds())

	// ---- teardown: Vulkan before the window it presents to
	vk_shutdown(r)
	win_destroy_window(a)
	if r.validation {
		log("validation: %d errors, %d warnings", r.validation_errors, r.validation_warnings)
		if r.validation_errors > 0 { die(3) }
	}
	die(0)
}
