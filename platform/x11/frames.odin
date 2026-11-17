#+build linux
package x11

// A frame clock: a message for every frame the display is about to show,
// which `frames()` turns into a subscription.
//
// X core has nothing like wl_surface.frame. Where the Present extension
// measures a vblank interval (present.odin) the clock paces on that;
// otherwise on the screen's nominal rate from RandR, with
// `Ev_Frame.estimated` true.
//
// The pacing follows the Windows backend:
//
//   - Round the wait up, never to zero. Waking just before the frame means
//     the tick declines and the next is a whole interval away: half rate.
//   - Wait until the deadline, not for an interval. A fixed interval adds
//     to the paint time, so the rate becomes the paint's, not the screen's.

import "core:math"
import "core:time"
import "baldr:platform"

@(private = "file") DEFAULT_REFRESH_MS :: 1000.0 / 60

// frames_wanted: this surface wants an Ev_Frame per display frame
// (Backend.frames_wanted). Nothing has to be started — while any surface
// wants them the pump shortens its own wait.
@(private)
frames_wanted :: proc(b: ^platform.Backend, id: platform.Surface, on: bool) {
	x := data(b)
	s := get_surface(x, id)
	if s == nil || s.frames_on == on do return
	s.frames_on = on
	if on && x.next_frame_at == (time.Tick{}) do x.next_frame_at = time.tick_now()
	// Present can say when a vblank really happened; without it the pacing
	// below is all there is (present.odin).
	present_watch(x, s, on)
	debugf(x, "surface %d: frames %v", id, on)
}

@(private)
frames_any :: proc(x: ^X11) -> bool {
	for s in x.surfaces {
		if s != nil && s.live && s.frames_on && s.mapped do return true
	}
	return false
}

// frames_refresh_ms is the interval to pace on: what Present measured for a
// surface if it could, else the screen's nominal mode from RandR
// (randr.odin), else 60 Hz.
@(private)
frames_refresh_ms :: proc(x: ^X11, s: ^Surface = nil) -> f64 {
	if s != nil && s.measured && s.refresh_ms > 0 do return s.refresh_ms
	for o in x.screens {
		if o.refresh > 0 do return 1000.0 / (f64(o.refresh) / 1000.0)
	}
	return DEFAULT_REFRESH_MS
}

// frames_measured says whether any surface has a measured interval, which
// decides what pacing the clock uses.
@(private = "file")
frames_measured :: proc(x: ^X11) -> (f64, bool) {
	for s in x.surfaces {
		if s != nil && s.live && s.frames_on && s.measured && s.refresh_ms > 0 do return s.refresh_ms, true
	}
	return 0, false
}

// frames_wait_ms is how long the pump may wait before the next frame is
// due: rounded up, and never zero while a frame is still ahead.
@(private)
frames_wait_ms :: proc(x: ^X11) -> i32 {
	if x.next_frame_at == (time.Tick{}) do return 0
	ahead := time.duration_milliseconds(time.tick_diff(time.tick_now(), x.next_frame_at))
	if ahead <= 0 do return 0
	return max(i32(math.ceil(ahead)), 1)
}

// frames_tick reports a frame to every surface that asked, once per
// interval, and steps the deadline on rather than restarting it from now —
// which is what stops the rate drifting slower than the screen, one
// rounding at a time.
@(private)
frames_tick :: proc(x: ^X11) {
	if !frames_any(x) do return
	refresh, measured := frames_measured(x)
	if !measured do refresh = frames_refresh_ms(x)
	now := time.tick_now()
	if x.next_frame_at != (time.Tick{}) &&
	   time.duration_milliseconds(time.tick_diff(now, x.next_frame_at)) > 0.5 {
		return // not due yet
	}
	step := time.Duration(refresh * f64(time.Millisecond))
	if x.next_frame_at == (time.Tick{}) ||
	   time.duration_milliseconds(time.tick_diff(x.next_frame_at, now)) > refresh {
		x.next_frame_at = time.tick_add(now, step) // first frame, or too far behind to catch up
	} else {
		x.next_frame_at = time.tick_add(x.next_frame_at, step)
	}
	for s in x.surfaces {
		if s == nil || !s.live || !s.frames_on || !s.mapped do continue
		push(x, platform.Ev_Frame{
			surface    = s.id,
			ahead_ms   = refresh,
			refresh_ms = refresh,
			estimated  = !measured, // false once Present has timed a vblank
		})
	}
}
