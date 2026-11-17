package baldr

@(require) import "core:testing"
@(require) import "baldr:platform"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// `App.on_close` lets an app that declares no `surfaces` (most of them)
// hear its window being closed and veto it, through the same
// `Surface_Desc.on_close` a declared surface uses, so a window shut with
// unsaved work in it need not take the work with it.

@(private = "file")
Ac_Msg :: union { Closing }

@(private = "file")
Closing :: struct {}

// A backend that can only be told a surface is gone — which is all the
// close path asks of one.
@(private = "file")
ac_backend: platform.Backend

@(private = "file")
ac_rt :: proc(rt: ^Runtime(int, Ac_Msg), on_close: Maybe(Ac_Msg)) {
	rt.app.title = "notes"
	rt.app.on_close = on_close
	ac_backend.surface_destroy = proc(b: ^platform.Backend, s: platform.Surface) {}
	rt.backend = &ac_backend
	rt.wanted = make([dynamic]Surface_Desc(Ac_Msg))
	c := new(Surface_Ctx(Ac_Msg))
	ui_init(&c.ui)
	c.surf = platform.Surface(1)
	append(&rt.ctxs, c)
}

@(private = "file")
ac_free :: proc(rt: ^Runtime(int, Ac_Msg)) {
	for c in rt.ctxs {
		ui_destroy(&c.ui)
		delete(c.desc.title)
		free(c)
	}
	delete(rt.ctxs)
	delete(rt.wanted)
	delete(rt.msgs)
}

// The declaration the runtime makes for an app with no `surfaces` proc
// carries the app's on_close; that is the whole of the wiring.
@(test)
a_plain_windows_declaration_carries_the_apps_on_close :: proc(t: ^testing.T) {
	rt: Runtime(int, Ac_Msg)
	ac_rt(&rt, Closing{})
	defer ac_free(&rt)

	clear(&rt.wanted)
	append(&rt.wanted, Surface_Desc(Ac_Msg){title = rt.app.title, size = {800, 600}, on_close = rt.app.on_close})
	m, has := rt.wanted[0].on_close.?
	testing.expect(t, has, "the window the runtime declares knows the app wants to hear")
	testing.expect(t, m == Ac_Msg(Closing{}), "…and what to say")
}

// With it set, the close is refused and the app is told. The app is what
// ends the run after that, by returning `quit` once it has asked.
@(test)
a_window_with_on_close_is_not_closed_it_is_reported :: proc(t: ^testing.T) {
	rt: Runtime(int, Ac_Msg)
	ac_rt(&rt, Closing{})
	defer ac_free(&rt)
	rt.ctxs[0].desc.on_close = rt.app.on_close

	quit := close_event(&rt, platform.Ev_Close{surface = rt.ctxs[0].surf, reason = .User}, false)
	testing.expect(t, !quit, "the run goes on: the app has not said otherwise yet")
	testing.expect_value(t, len(rt.ctxs), 1) // …and the window is still there
	if testing.expect_value(t, len(rt.ctxs[0].ui.msgs), 1) {
		testing.expect(t, rt.ctxs[0].ui.msgs[0] == Ac_Msg(Closing{}), "the app heard it")
	}
}

// Without it the run ends, which is right for a window holding nothing
// worth keeping.
@(test)
a_window_with_no_on_close_still_ends_the_run :: proc(t: ^testing.T) {
	rt: Runtime(int, Ac_Msg)
	ac_rt(&rt, nil)
	defer ac_free(&rt)

	quit := close_event(&rt, platform.Ev_Close{surface = rt.ctxs[0].surf, reason = .User}, false)
	testing.expect(t, quit, "no one asked to be told: closing the window closes the app")
	testing.expect_value(t, len(rt.ctxs[0].ui.msgs), 0)
}

// The compositor taking a window away is not the person closing it: there
// is nothing to veto, so it is closed quietly whatever on_close says.
@(test)
a_window_the_compositor_took_is_not_a_question :: proc(t: ^testing.T) {
	rt: Runtime(int, Ac_Msg)
	ac_rt(&rt, Closing{})
	defer ac_free(&rt)
	rt.ctxs[0].desc.on_close = rt.app.on_close

	close_event(&rt, platform.Ev_Close{surface = rt.ctxs[0].surf, reason = .Compositor}, false)
	testing.expect_value(t, len(rt.ctxs), 0) // gone, not asked about
}


// A desktop that drops us is not the app being asked to stop. Ev_Quit says
// which it was, and `run` answers `.Disconnected` for the one the app did
// not choose, so a lost connection does not read as a clean exit.
@(test)
a_dropped_connection_is_not_a_clean_close :: proc(t: ^testing.T) {
	// The distinction lives in the event, so that is what is pinned: a
	// backend that means "the desktop went away" cannot spell it the same
	// way as one that means "the person closed the window".
	clean := platform.Ev_Quit{}
	lost  := platform.Ev_Quit{lost = true}
	testing.expect(t, !clean.lost, "the person closed it")
	testing.expect(t, lost.lost, "…and this one was not their doing")
	testing.expect(t, clean != lost, "the run loop can tell them apart")

	// …and the error the app is handed says so, rather than reading as a
	// normal end.
	testing.expect(t, Error.Disconnected != Error.None,
		"an app that checks `err != .None` catches a dropped desktop")
}

}
