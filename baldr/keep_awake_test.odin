package baldr

// Keeping the screen on: a flag the view declares, and a desktop told
// about it only when the answer changes.

@(require) import "core:testing"
@(require) import "baldr:platform"

when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Awake_Msg :: union { bool }

@(private = "file")
Awake_Call :: struct {
	surface: platform.Surface,
	on:      bool,
}

@(private = "file")
Awake_Log :: struct {
	calls: [dynamic]Awake_Call,
}

@(private = "file")
awake_backend :: proc(log: ^Awake_Log) -> platform.Backend {
	b := platform.Backend{data = log}
	b.keep_awake = proc(b: ^platform.Backend, surface: platform.Surface, on: bool) {
		append(&(^Awake_Log)(b.data).calls, Awake_Call{surface, on})
	}
	return b
}

// The flag is the latest view's, like every other thing a view declares: a
// build that asks has it, a build that does not has it cleared. That is what
// makes "while it is playing" the whole of the app's side — a player that
// stops drawing the video stops holding the screen on by doing nothing.
@(test)
the_screen_is_kept_on_only_while_a_view_asks :: proc(t: ^testing.T) {
	ui: Ui(Awake_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	begin_view(&ui)
	keep_awake(&ui, true)
	end_view(&ui)
	testing.expect(t, ui.keep_awake, "asked for")

	begin_view(&ui)
	end_view(&ui)
	testing.expect(t, !ui.keep_awake, "a build that does not ask gives it back")

	begin_view(&ui)
	keep_awake(&ui, false)
	end_view(&ui)
	testing.expect(t, !ui.keep_awake, "and asking for `false` is the same as not asking")

	// Two players in one window: either one playing is enough, which falls
	// out of the flag being the view's rather than a node's.
	begin_view(&ui)
	keep_awake(&ui, false)
	keep_awake(&ui, true)
	keep_awake(&ui, false)
	end_view(&ui)
	testing.expect(t, ui.keep_awake, "one of them is playing")
}

// The desktop hears about a change and nothing else. The request is a
// standing one, so repeating it every pass would be sixty identical
// requests a second.
@(test)
the_desktop_is_told_the_screen_should_stay_on_once :: proc(t: ^testing.T) {
	log := Awake_Log{}
	defer delete(log.calls)
	b := awake_backend(&log)
	held: bool

	awake_sync(&b, 3, true, &held)
	awake_sync(&b, 3, true, &held)
	awake_sync(&b, 3, true, &held)
	testing.expect_value(t, len(log.calls), 1)
	testing.expect_value(t, log.calls[0], Awake_Call{3, true})
	testing.expect(t, held, "…and it is being held on")

	awake_sync(&b, 3, false, &held)
	testing.expect_value(t, len(log.calls), 2)
	testing.expect_value(t, log.calls[1], Awake_Call{3, false})
	testing.expect(t, !held, "given back")
	awake_sync(&b, 3, false, &held)
	testing.expect_value(t, len(log.calls), 2) // not told twice about that either
}

// A desktop that cannot keep the screen on is not an error: the app asks,
// nothing happens, and everything else goes on working. Baldr still tracks
// the answer, so the window is in the right state if it ever can.
@(test)
a_desktop_that_cannot_keep_the_screen_on_is_no_trouble :: proc(t: ^testing.T) {
	none := platform.Backend{} // no keep_awake: a backend or compositor without the protocol
	held: bool
	awake_sync(&none, 1, true, &held)
	testing.expect(t, held, "asked for, and remembered")
	awake_sync(nil, 1, false, &held)
	testing.expect(t, !held, "and given back with no backend at all")
}

}
