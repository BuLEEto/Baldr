#+build linux
package wayland

// A frame clock: a message for every frame the display is about to show,
// with the time that frame is expected on screen. A video player has to be
// in step with the display (at 30 fps on 60 Hz, exactly two refreshes per
// frame), which a timer cannot be. While an app asks for frames the surface
// paints at the screen's rate, so the ask is per surface and dropped as soon
// as it is not needed.
//
// The times are worked out from the frame callback and the screen's refresh
// rate, and `estimated` says so on every frame. wp_presentation would make
// them measured, but its feedback attaches to the surface's next commit, and
// with Vulkan that commit is made inside `vkQueuePresentKHR`: feedback asked
// for here lands on a commit with no new buffer and is never answered, so a
// per-frame ask would leak a feedback object per frame. Doing it needs a
// hook just before the present, which matters for variable-refresh screens
// and for noticing dropped frames.

import "baldr:platform"

// frames_wanted: this surface wants an Ev_Frame per display frame
// (Backend.frames_wanted).
@(private)
frames_wanted :: proc(b: ^platform.Backend, s: platform.Surface, on: bool) {
	st := state(b)
	ss := lookup(st, s)
	if ss == nil do return
	if ss.frames_on == on do return
	ss.frames_on = on
	// Turning it on has to start the loop: without a frame in flight there
	// is nothing to hang the next one off, and the surface would sit still
	// waiting for a frame that only a redraw would ask for.
	if on && ss.configured do frame_arm(st, ss)
}

// frame_clock_tick runs from the frame callback, for a surface that asked.
// It reports the frame and asks the compositor to tell us when it lands.
@(private)
frame_clock_tick :: proc(st: ^State, s: ^Surface_State, callback_ms: u32) {
	_ = callback_ms // the compositor's own clock: not ours to mix with (see Ev_Frame)
	if !s.frames_on do return
	refresh := s.refresh_ms if s.refresh_ms > 0 else output_refresh_ms(st, s)
	if refresh <= 0 do refresh = 16.667 // no one has said: 60 Hz is the honest guess

	// The frame callback fires just after a vsync, so the frame about to be
	// drawn is expected one refresh from now. That is true whether or not
	// the compositor reports presentation times — what its feedback buys is
	// a *measured* refresh interval rather than the output's nominal one,
	// which is what drifts on a variable-refresh screen.
	push(st, platform.Ev_Frame{
		surface = s.id, ahead_ms = refresh, refresh_ms = refresh,
		estimated = true, // see the note at the top: not measured yet
	})

	frame_arm(st, s) // keep the clock running for as long as it is wanted
}

// output_refresh_ms is the refresh interval of the screen this surface is
// on, from the output it entered.
@(private = "file")
output_refresh_ms :: proc(st: ^State, s: ^Surface_State) -> f64 {
	for o in st.outputs {
		if o != s.output do continue
		if o.refresh > 0 do return 1000.0 / (f64(o.refresh) / 1000.0)
	}
	return 0
}

