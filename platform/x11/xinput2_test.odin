#+build linux
package x11

@(require) import "core:testing"

// Runs with the rest: `./build.sh test`.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A device with scroll valuators makes the server send the old button 4-7
// events as well, so those are dropped or a scroll counts twice. The test is
// whether this click came with a valuator, not whether the machine has
// valuators: XTEST devices have none, so the wrong test drops every
// injected click.
@(test)
a_wheel_button_is_only_dropped_when_a_valuator_moved_with_it :: proc(t: ^testing.T) {
	x: X11
	x.xi_opcode = 131
	append(&x.scroll_axes, Scroll_Axis{})
	defer delete(x.scroll_axes)

	// The echo of a scroll down: same moment, same direction.
	x.wheel_echo_ms, x.wheel_echo_delta = 10_000, {0, 48}
	testing.expect(t, xi2_wheel_echoed(&x, BUTTON_WHEEL_DOWN, 10_000), "the button the server emulated from a valuator is the echo")
	testing.expect(t, xi2_wheel_echoed(&x, BUTTON_WHEEL_DOWN, 10_020), "a couple of milliseconds later is still that scroll")

	// An injected click: no valuator has moved for a long time. This is real
	// input — xdotool, a remote desktop, an assistive tool — and dropping it
	// is losing it.
	testing.expect(t, !xi2_wheel_echoed(&x, BUTTON_WHEEL_DOWN, 20_000), "a click with no valuator behind it is input, not an echo")

	// The other direction is not this scroll, however close in time.
	testing.expect(t, !xi2_wheel_echoed(&x, BUTTON_WHEEL_UP, 10_000), "scrolling down cannot swallow a click upwards")
	testing.expect(t, !xi2_wheel_echoed(&x, BUTTON_WHEEL_LEFT, 10_000), "a vertical scroll cannot swallow a horizontal click")
	testing.expect(t, !xi2_wheel_echoed(&x, BUTTON_WHEEL_RIGHT, 10_000), "…in either direction")

	// A horizontal scroll, and its own echo.
	x.wheel_echo_delta = {-48, 0}
	testing.expect(t, xi2_wheel_echoed(&x, BUTTON_WHEEL_LEFT, 10_000), "a leftward scroll's echo is button 6")
	testing.expect(t, !xi2_wheel_echoed(&x, BUTTON_WHEEL_DOWN, 10_000), "…and not button 5")
}

// An X timestamp is milliseconds in 32 bits, so it wraps every 49 days and
// an uptime that long is ordinary. Subtracting unsigned keeps the difference
// small across the wrap; subtracting as signed would make it enormous and
// every echo would be counted a second time from then on.
@(test)
a_wheel_echo_survives_the_timestamp_wrapping :: proc(t: ^testing.T) {
	x: X11
	x.xi_opcode = 131
	append(&x.scroll_axes, Scroll_Axis{})
	defer delete(x.scroll_axes)

	x.wheel_echo_ms, x.wheel_echo_delta = Timestamp(max(u32) - 5), {0, 48}
	testing.expect(t, xi2_wheel_echoed(&x, BUTTON_WHEEL_DOWN, Timestamp(max(u32) - 5)), "the scroll's own moment")
	testing.expect(t, xi2_wheel_echoed(&x, BUTTON_WHEEL_DOWN, 4), "ten milliseconds later, the counter having wrapped")
	testing.expect(t, !xi2_wheel_echoed(&x, BUTTON_WHEEL_DOWN, 100), "a click well after the wrap is still input")
}

// Without valuators nothing is dropped: the wheel is buttons 4-7 and that is
// all it is. A server with no XInput2 at all must keep its notched scroll.
@(test)
without_valuators_every_wheel_button_counts :: proc(t: ^testing.T) {
	x: X11 // no opcode, no axes
	x.wheel_echo_ms, x.wheel_echo_delta = 10_000, {0, 48}
	testing.expect(t, !xi2_wheel_echoed(&x, BUTTON_WHEEL_DOWN, 10_000), "no axes: the buttons are the only scroll there is")

	x.xi_opcode = 131 // XI2 present, but this device has no scrolling valuator
	testing.expect(t, !xi2_wheel_echoed(&x, BUTTON_WHEEL_DOWN, 10_000), "XI2 alone is not a valuator")
}

}
