#+build windows
package win32

// A frame clock on Windows: a message for every frame the display is about
// to show, which `frames()` turns into a subscription.
//
// Wayland has wl_surface.frame — the compositor says when to draw next.
// Windows has nothing that calls back, so the clock is built the other way
// round: DWM is asked when the last vblank was and how long a refresh
// lasts, and the pump's wait is shortened so it wakes at the next one. The
// pump already computes a timeout, so this only ever lowers it, and input
// still arrives the moment it is posted.
//
// These times are measured, not estimated: `qpcVBlank` and
// `qpcRefreshPeriod` come from the compositor's own measurements, so
// `Ev_Frame.estimated` is false while DWM answers. It goes true on the
// fallback path — DWM refusing, or composition off — where the interval is
// the screen's nominal mode from `outputs()` and, failing that, 60 Hz.
//
// `DwmFlush` would be a closer match to a frame callback, but it blocks
// until the next composition, and blocking the message pump delays input
// and breaks `wake`. Asking for the time and waiting on messages until then
// gives the same cadence and keeps the loop answering.

import "core:fmt"
import "core:math"
import "core:time"
import win "core:sys/windows"
import "baldr:platform"

@(private = "file") DEFAULT_REFRESH_MS :: 1000.0 / 60 // when nobody will say

// frames_wanted: this surface wants an Ev_Frame per display frame
// (Backend.frames_wanted). Nothing has to be started — while any surface
// wants them the pump shortens its own wait.
@(private)
frames_wanted :: proc(b: ^platform.Backend, id: platform.Surface, on: bool) {
	s := get_surface(data(b), id)
	if s != nil do s.frames_on = on
}

// frames_any says whether the clock should be running at all.
@(private)
frames_any :: proc(w: ^Win32) -> bool {
	for s in w.surfaces {
		if s != nil && s.frames_on && can_paint(s) do return true
	}
	return false
}

// frame_clock is what DWM last said, read once per pump iteration so the
// wait and the tick agree.
@(private)
Frame_Clock :: struct {
	ahead_ms:   f64, // until the next vblank, from now
	refresh_ms: f64,
	count:      u64, // DWM's running refresh count; it advancing is the tick
	measured:   bool,
}

// frame_clock_read asks DWM where the display is in its cycle.
@(private)
frame_clock_read :: proc(w: ^Win32) -> (fc: Frame_Clock) {
	ti: DWM_TIMING_INFO
	ti.cbSize = size_of(ti)
	qpf: win.LARGE_INTEGER
	now: win.LARGE_INTEGER
	hr := DwmGetCompositionTimingInfo(nil, &ti)
	if hr != 0 && !w.dwm_warned {
		// Said once: a machine where DWM will not answer falls back for the
		// whole run, and a line per frame would be 60 a second.
		// 0x80263001 is DWM_E_COMPOSITIONDISABLED.
		w.dwm_warned = true
		fmt.eprintfln("baldr/win32: DwmGetCompositionTimingInfo failed (0x%08X); the frame clock uses the screen's nominal rate", u32(hr))
	}
	if hr == 0 &&
	   win.QueryPerformanceFrequency(&qpf) && win.QueryPerformanceCounter(&now) &&
	   qpf > 0 && ti.qpcRefreshPeriod > 0 {
		ticks := f64(qpf)
		fc.refresh_ms = f64(ti.qpcRefreshPeriod) / ticks * 1000
		fc.count = ti.cRefresh
		fc.measured = true
		// The next vblank after this instant. A pump that has been away for
		// a while (a modal loop, a slow frame) can be several refreshes
		// past the one DWM last recorded, so step forward rather than
		// reporting a time already gone.
		next := f64(ti.qpcVBlank) + f64(ti.qpcRefreshPeriod)
		ahead := (next - f64(now)) / ticks * 1000
		if ahead < 0 && fc.refresh_ms > 0 {
			missed := f64(int(-ahead / fc.refresh_ms)) + 1
			ahead += missed * fc.refresh_ms
		}
		fc.ahead_ms = ahead
		return
	}
	// No DWM answer: the screen's nominal mode, and "ahead" is the time to
	// the deadline frame_clock_tick keeps. Not simply one interval: that
	// would wait a whole interval on top of the paint, and the clock would
	// run at the rate the paint allows (a 14 ms paint plus a 17 ms wait is
	// 32 Hz). A pump that is already late waits not at all.
	fc.refresh_ms = frames_nominal_ms(w)
	fc.measured = false
	fc.ahead_ms = fc.refresh_ms
	if w.next_frame_at != (time.Tick{}) {
		fc.ahead_ms = max(time.duration_milliseconds(time.tick_diff(time.tick_now(), w.next_frame_at)), 0)
	}
	return
}

// frames_nominal_ms is the refresh interval of the first screen that gives
// one (outputs.odin), or 60 Hz.
@(private = "file")
frames_nominal_ms :: proc(w: ^Win32) -> f64 {
	for o in w.screens {
		if o.refresh > 0 do return 1000.0 / (f64(o.refresh) / 1000.0)
	}
	return DEFAULT_REFRESH_MS
}

// frame_clock_wait_ms is how long the pump may wait before the next frame is
// due.
//
// Rounded up, and never zero while a frame is still ahead: rounding down
// wakes the pump just before the vblank, the tick declines because the
// refresh has not happened yet, and every frame lands on the second pass —
// half rate.
@(private)
frame_clock_wait_ms :: proc(fc: Frame_Clock) -> i32 {
	if fc.ahead_ms <= 0 do return 0
	return max(i32(math.ceil(fc.ahead_ms)), 1)
}

// frame_clock_tick queues an Ev_Frame for every surface that asked, once per
// refresh. DWM's count is what says a refresh has passed; on the fallback
// path there is no count, so the toolkit's own clock is used instead and one
// interval has to have elapsed.
@(private)
frame_clock_tick :: proc(w: ^Win32, fc: Frame_Clock) {
	if !frames_any(w) do return
	if fc.measured {
		if fc.count == w.last_refresh_count do return
		w.last_refresh_count = fc.count
	} else {
		// No count to go by, so the toolkit's own clock keeps a deadline and
		// steps it on by one interval per frame. Stepping the deadline
		// rather than restarting it from now is what stops the rate
		// drifting slower than the screen, one rounding at a time; a pump
		// that has been away for longer than an interval catches up in one
		// go instead of reporting every frame it missed.
		now := time.tick_now()
		started := w.next_frame_at != time.Tick{}
		// tick_diff(a, b) is b - a: ahead is how long until the deadline,
		// behind is how far past it we are.
		if started && time.duration_milliseconds(time.tick_diff(now, w.next_frame_at)) > 0.5 do return
		step := time.Duration(fc.refresh_ms * f64(time.Millisecond))
		if !started || time.duration_milliseconds(time.tick_diff(w.next_frame_at, now)) > fc.refresh_ms {
			w.next_frame_at = time.tick_add(now, step) // the first frame, or too far behind to catch up
		} else {
			w.next_frame_at = time.tick_add(w.next_frame_at, step)
		}
	}
	for s in w.surfaces {
		if s == nil || !s.frames_on || !can_paint(s) do continue
		append(&w.queue, platform.Ev_Frame{
			surface    = s.id,
			ahead_ms   = fc.ahead_ms,
			refresh_ms = fc.refresh_ms,
			estimated  = !fc.measured,
		})
	}
}
