#+build windows
package win32

@(require) import "core:testing"

// Runs on Windows: `odin test platform/win32`.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Rounding the wait down wakes the pump just before the vblank; the tick
// then declines because the refresh has not happened, and every frame lands
// on the second pass, at half the refresh rate.
@(test)
the_frame_wait_never_lands_before_the_frame :: proc(t: ^testing.T) {
	Case :: struct { ahead_ms: f64, want: i32 }
	cases := []Case{
		{16.667, 17}, // 60 Hz: a 16 ms wait would run at half rate
		{8.333,   9}, // 120 Hz
		{0.1,     1}, // nearly there, but not there: never a zero wait, or the pump spins
		{1.0,     1},
		{0,       0}, // due now
		{-2.5,    0}, // already past: do not wait at all
	}
	for c in cases {
		got := frame_clock_wait_ms(Frame_Clock{ahead_ms = c.ahead_ms})
		testing.expectf(t, got == c.want, "ahead %.3f ms -> wait %d ms, wanted %d", c.ahead_ms, got, c.want)
		if c.ahead_ms > 0 {
			testing.expectf(t, f64(got) >= c.ahead_ms, "ahead %.3f ms -> wait %d ms, which is short of the frame", c.ahead_ms, got)
		}
	}
}

}
