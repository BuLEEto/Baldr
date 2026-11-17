package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A video player has to be in step with the display: at 30 fps on a 60 Hz
// screen each frame should be shown for exactly two refreshes, which
// `every(16)` cannot do because nothing ties it to the screen.
//
// `frames` is the one thing in Baldr that gives up drawing-only-on-change,
// so it must be exactly as live as its declaration and no longer.

@(private = "file")
Fr_Msg :: union { Frame_Time }

@(private = "file")
fr_heard :: proc(e: Ev(Frame_Time)) -> Fr_Msg { return e.value }

@(test)
a_frames_line_lives_exactly_as_long_as_it_is_declared :: proc(t: ^testing.T) {
	sch: Sched(Fr_Msg)
	defer sched_destroy(&sch, nil, nil)

	testing.expect(t, !sched_wants_frames(&sch), "nothing asked for yet")

	// declared
	subs := []Sub(Fr_Msg){frames(Fr_Msg, fr_heard)}
	sched_sync(&sch, subs, 0, nil, nil, nil)
	testing.expect(t, sched_wants_frames(&sch), "asked for")

	// declared again next build: the same line, not a second one
	sched_sync(&sch, subs, 16, nil, nil, nil)
	testing.expect_value(t, len(sch.frames), 1)

    // and gone when it is not declared — a player that paused
	none: []Sub(Fr_Msg)
	sched_sync(&sch, none, 32, nil, nil, nil)
	testing.expect(t, !sched_wants_frames(&sch), "dropped with its line")
}

// Every declared line hears each frame, with its own tag.
@(test)
each_frame_reaches_everyone_who_asked :: proc(t: ^testing.T) {
	sch: Sched(Fr_Msg)
	defer sched_destroy(&sch, nil, nil)
	subs := []Sub(Fr_Msg){frames(Fr_Msg, fr_heard, tag = 1), frames(Fr_Msg, fr_heard, tag = 2)}
	sched_sync(&sch, subs, 0, nil, nil, nil)
	testing.expect_value(t, len(sch.frames), 2)

	msgs := make([dynamic]Fr_Msg, context.temp_allocator)
	sched_frame_event(&sch, Frame_Time{now_ms = 100, present_ms = 116.7, refresh_ms = 16.7}, &msgs)
	if !testing.expect_value(t, len(msgs), 2) do return
	ft := msgs[0].(Frame_Time)
	testing.expect_value(t, ft.present_ms, 116.7)
	testing.expect_value(t, ft.refresh_ms, 16.7)

	// present_ms is ahead of now: it is when the frame will be seen, and a
	// player aims the picture at it
	testing.expect(t, ft.present_ms > ft.now_ms, "the frame is shown after it is drawn")
}

}
