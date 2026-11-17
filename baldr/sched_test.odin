package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private="file")
SMsg :: union {
	STick,
	SLater,
	SChanged,
}
@(private="file")
STick :: struct { n: int }
@(private="file")
SLater :: struct {}
@(private="file")
SChanged :: struct { path, name: string, kind: Change_Kind, tag: u64 }

@(private="file")
Watch_Log :: struct { started, stopped: [dynamic]u64 }

@(private="file")
log_start :: proc(user: rawptr, path: string, token: u64) -> bool {
	append(&(^Watch_Log)(user).started, token)
	return true
}
@(private="file")
log_stop :: proc(user: rawptr, token: u64) { append(&(^Watch_Log)(user).stopped, token) }

@(private="file")
schanged :: proc(e: Ev(File_Change)) -> SMsg { return SChanged{e.value.path, e.value.name, e.value.kind, e.tag} }

@(test)
delay_fires_once_when_due :: proc(t: ^testing.T) {
	s: Sched(SMsg)
	defer sched_destroy(&s, nil, nil)
	out := make([dynamic]SMsg); defer delete(out)
	testing.expect_value(t, sched_timeout(&s, 0), -1)
	sched_delay(&s, 0, 100, SLater{})
	testing.expect_value(t, sched_timeout(&s, 40), 60)
	testing.expect(t, !sched_fire(&s, 99, &out), "not yet")
	testing.expect(t, sched_fire(&s, 100, &out), "due")
	testing.expect_value(t, len(out), 1)
	testing.expect(t, !sched_fire(&s, 500, &out), "a delay fires once")
	testing.expect_value(t, sched_timeout(&s, 500), -1)
}

@(test)
every_repeats_and_keeps_phase_across_syncs :: proc(t: ^testing.T) {
	s: Sched(SMsg)
	defer sched_destroy(&s, nil, nil)
	out := make([dynamic]SMsg); defer delete(out)
	tick := []Sub(SMsg){every(SMsg, 100, STick{1})}
	sched_sync(&s, tick, 0, nil, nil, nil)
	testing.expect_value(t, sched_timeout(&s, 0), 100)
	sched_sync(&s, tick, 50, nil, nil, nil) // declared again: same timer, phase kept
	testing.expect_value(t, len(s.every), 1)
	testing.expect_value(t, sched_timeout(&s, 50), 50)
	testing.expect(t, sched_fire(&s, 100, &out), "first tick")
	testing.expect(t, !sched_fire(&s, 150, &out), "between ticks")
	testing.expect(t, sched_fire(&s, 260, &out), "second tick, late")
	testing.expect_value(t, sched_timeout(&s, 260), 100) // counted from now, not a burst
	testing.expect_value(t, len(out), 2)
	// a new message on the same line replaces what is sent
	sched_sync(&s, []Sub(SMsg){every(SMsg, 100, STick{2})}, 260, nil, nil, nil)
	sched_fire(&s, 360, &out)
	last, ok := out[2].(STick)
	testing.expect(t, ok && last.n == 2, "refreshed message")
	sched_sync(&s, []Sub(SMsg){}, 360, nil, nil, nil) // gone
	testing.expect_value(t, len(s.every), 0)
	testing.expect(t, !sched_fire(&s, 1000, &out), "stopped")
}

@(test)
watch_subscriptions_start_stop_and_report :: proc(t: ^testing.T) {
	s: Sched(SMsg)
	log: Watch_Log
	defer { delete(log.started); delete(log.stopped) }
	defer sched_destroy(&s, log_stop, &log)
	out := make([dynamic]SMsg); defer delete(out)
	sched_sync(&s, []Sub(SMsg){watch(SMsg, "notes.txt", schanged, tag = 5)}, 0, log_start, log_stop, &log)
	testing.expect_value(t, len(log.started), 1)
	a := log.started[0]
	sched_sync(&s, []Sub(SMsg){watch(SMsg, "notes.txt", schanged, tag = 5), watch(SMsg, "pics", schanged)}, 0, log_start, log_stop, &log)
	testing.expect_value(t, len(log.started), 2) // the first line did not restart
	b := log.started[1]
	sched_sync(&s, []Sub(SMsg){watch(SMsg, "pics", schanged)}, 0, log_start, log_stop, &log)
	testing.expect_value(t, len(log.stopped), 1)
	testing.expect_value(t, log.stopped[0], a)
	testing.expect(t, sched_watch_event(&s, b, "cat.png", .Created, &out), "a report for a live watch")
	testing.expect(t, !sched_watch_event(&s, a, "", .Modified, &out), "none for a stopped one")
	c, ok := out[0].(SChanged)
	testing.expect(t, ok && c.path == "pics" && c.name == "cat.png" && c.kind == .Created && c.tag == 0, "the change carries path, entry and kind")
}

} // when ODIN_TEST