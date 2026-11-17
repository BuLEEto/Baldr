#+build linux
package x11

// Pointer, wheel and focus. The keyboard is in keyboard.odin.
//
//   - `state` is the modifiers before the event: pressing Shift reports no
//     Shift. The keyboard keeps its own modifier state through xkb; this
//     file uses `state` only for the pointer, where it cannot matter.
//   - The core protocol has no scroll axis: the wheel is buttons 4 to 7, one
//     press and release per click, so a scroll here is a discrete step.
//     Smooth scrolling comes from XInput2 valuators (xinput2.odin).

import "baldr:platform"

// mods_of maps X's modifier mask onto the toolkit's. Alt is Mod1, Super
// Mod4 and Num Lock Mod2 by convention, not by the protocol.
@(private)
mods_of :: proc(state: u16) -> (m: platform.Mods) {
	if state & MOD_SHIFT   != 0 do m += {.Shift}
	if state & MOD_CONTROL != 0 do m += {.Ctrl}
	if state & MOD_1       != 0 do m += {.Alt}
	if state & MOD_4       != 0 do m += {.Super}
	if state & MOD_LOCK    != 0 do m += {.Caps_Lock}
	if state & MOD_2       != 0 do m += {.Num_Lock}
	return
}

// logical turns an event's window coordinates into logical pixels.
@(private)
logical :: proc(x: ^X11, ex, ey: i16) -> [2]f32 {
	sc := x.scale if x.scale > 0 else 1
	return {f32(ex) / sc, f32(ey) / sc}
}

@(private)
on_button :: proc(x: ^X11, e: ^Input_Event, pressed: bool) {
	if x.drag.live && !pressed {
		drag_out_release(x) // letting go is the drop
		return
	}
	s := surface_of_window(x, e.event)
	if s == nil || !s.live do return
	pos := logical(x, e.event_x, e.event_y)

	// The wheel: a press and a release per click, and only the press
	// counts, or every scroll would be doubled.
	switch e.detail {
	case BUTTON_WHEEL_UP, BUTTON_WHEEL_DOWN, BUTTON_WHEEL_LEFT, BUTTON_WHEEL_RIGHT:
		if !pressed do return
		// A device with scroll valuators also gets these buttons sent for
		// pre-XI2 programs; taking both scrolls twice. Only a real echo is
		// dropped: a click with no valuator behind it (an injected one) is
		// honoured (xinput2.odin).
		if xi2_wheel_echoed(x, e.detail, e.time) do return
		if xi2_scrolls(x) {
			debugf(x, "wheel button %d honoured: no valuator moved with it (injected?)", e.detail)
		}
		d: [2]f32
		switch e.detail {
		case BUTTON_WHEEL_UP:    d = {0, -platform.SCROLL_STEP_PX}
		case BUTTON_WHEEL_DOWN:  d = {0, platform.SCROLL_STEP_PX}
		case BUTTON_WHEEL_LEFT:  d = {-platform.SCROLL_STEP_PX, 0}
		case BUTTON_WHEEL_RIGHT: d = {platform.SCROLL_STEP_PX, 0}
		}
		push(x, platform.Ev_Scroll{
			surface = s.id, delta = d, pos = pos,
			precise = false, // a wheel click is a step; XInput2 is what makes it smooth
			mods = mods_of(e.state),
		})
		return
	}

	button: platform.Mouse_Button
	switch e.detail {
	case 1: button = .Left
	case 2: button = .Middle
	case 3: button = .Right
	case BUTTON_BACK:    button = .Back
	case BUTTON_FORWARD: button = .Forward
	case: return // a mouse with more buttons than the toolkit names
	}
	x.serial += 1
	push(x, platform.Ev_Pointer_Button{
		surface = s.id, button = button, pressed = pressed, pos = pos,
		mods = mods_of(e.state), serial = x.serial, time_ms = u32(e.time),
	})
}

@(private)
on_motion :: proc(x: ^X11, e: ^Input_Event) {
	pointer_moved(x, e.event, e.event_x, e.event_y, e.root_x, e.root_y, u32(e.time), mods_of(e.state))
}

// pointer_moved is the single path a pointer move takes, whichever kind of
// event carried it: the core MotionNotify above, or an XI2 motion
// (xinput2.odin) where that is what the server sends instead.
//
// Both can arrive for the same movement, depending on whether a grab is
// up, so a repeat is made harmless: a move to where the pointer already is
// pushes nothing.
@(private)
pointer_moved :: proc(x: ^X11, w: Window, ex, ey, rx, ry: i16, time_ms: u32, mods: platform.Mods) {
	// While one of our drags is in flight the pointer is grabbed and every
	// move is the drag's, wherever it is (xdnd_source.odin).
	if x.drag.live {
		drag_out_motion(x, rx, ry)
		return
	}
	s := surface_of_window(x, w)
	if s == nil || !s.live do return
	pos := logical(x, ex, ey)
	if s.pointer_inside && pos == s.pointer_pos do return
	s.pointer_pos = pos
	// A motion can arrive before the EnterNotify when a grab is involved;
	// the toolkit wants an enter first either way.
	if !s.pointer_inside {
		s.pointer_inside = true
		push(x, platform.Ev_Pointer_Enter{surface = s.id, pos = pos})
	}
	push(x, platform.Ev_Pointer_Motion{surface = s.id, pos = pos, time_ms = time_ms, mods = mods})
}

@(private)
on_crossing :: proc(x: ^X11, e: ^Crossing_Event, entering: bool) {
	s := surface_of_window(x, e.event)
	if s == nil || !s.live do return
	// A grab taking and returning the pointer sends a Leave/Enter pair that
	// nothing crossed; acting on it would end a hover or drag midway.
	if e.mode != NOTIFY_MODE_NORMAL do return
	if entering {
		pos := logical(x, e.event_x, e.event_y)
		s.pointer_pos = pos
		if !s.pointer_inside {
			s.pointer_inside = true
			push(x, platform.Ev_Pointer_Enter{surface = s.id, pos = pos})
		}
	} else if s.pointer_inside {
		s.pointer_inside = false
		push(x, platform.Ev_Pointer_Leave{surface = s.id})
	}
}

@(private)
on_focus :: proc(x: ^X11, e: ^Focus_Event, focused: bool) {
	s := surface_of_window(x, e.event)
	if s == nil || !s.live do return
	if e.mode != NOTIFY_MODE_NORMAL do return // a grab, not the keyboard moving
	if s.focused == focused do return
	s.focused = focused
	push(x, platform.Ev_Focus{surface = s.id, focused = focused})
	// `activated` in a configure is this, so the title bar and the focus
	// ring follow.
	if s.configured do emit_configure(x, s)
	if focused {
		x.kbd_focus = s
	} else if x.kbd_focus == s {
		x.kbd_focus = nil
		keys_released(x, s) // nothing is held once the keyboard has gone
	}
}
