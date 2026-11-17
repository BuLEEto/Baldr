package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: behind this `when`, checking a program costs
// 1.0 GB instead of 9.2 GB. ODIN_TEST is set by `odin test`; BALDR_TESTS
// lets ./build.sh check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// An app that keeps running with no window (a file copy finishing).


@(private = "file")
KState :: struct { copying: bool }
@(private = "file")
KeepRunning_KMsg :: enum { None }

@(test)
keep_running_holds_a_run_with_no_surface :: proc(t: ^testing.T) {
	rt: Runtime(KState, KeepRunning_KMsg)
	testing.expect(t, !run_holds(&rt), "no keep_running: a run with no surface ends")
	rt.app.keep_running = proc(s: ^KState) -> bool { return s.copying }
	testing.expect(t, !run_holds(&rt), "not busy: it ends")
	rt.state.copying = true
	testing.expect(t, run_holds(&rt), "busy: it carries on")
}

// An app with no `surfaces` proc gets the default window, so one that also
// leaves out `view` would build through a nil pointer and crash with
// nothing on stderr. `run` refuses it with a sentence that names the fix;
// the check is before any backend, so this runs headlessly.
@(test)
a_window_with_no_view_is_refused_rather_than_crashed_into :: proc(t: ^testing.T) {
	err := run(App(KState, KeepRunning_KMsg){title = "no view"})
	testing.expect_value(t, err, Error.Platform)
}

} // when ODIN_TEST