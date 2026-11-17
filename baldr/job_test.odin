package baldr

@(require) import "core:sync"
@(require) import "core:testing"
@(require) import "core:time"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: behind this `when`, checking a program costs
// 1.0 GB instead of 9.2 GB. ODIN_TEST is set by `odin test`; BALDR_TESTS
// lets ./build.sh check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private="file")
JMsg :: union {
	JProgress,
	JDone,
}
@(private="file")
JProgress :: struct { n: int }
@(private="file")
JDone :: struct { cancelled: bool, tag: u64 }

@(private="file")
jdone :: proc(e: Ev(Job_Done)) -> JMsg { return JDone{e.value.cancelled, e.tag} }

// drain_until_idle pumps the mailbox the way the run loop does until every
// job was reaped (or two seconds passed).
@(private="file")
drain_until_idle :: proc(mb: ^Mailbox(JMsg), jobs: ^[dynamic]^Job(JMsg), out: ^[dynamic]JMsg) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < 2 * time.Second {
		mailbox_drain(mb, jobs, out)
		if len(jobs) == 0 do return true
		time.sleep(time.Millisecond)
	}
	return false
}

@(private="file")
count_wake :: proc(user: rawptr) { sync.atomic_add((^int)(user), 1) }

@(test)
job_posts_in_order_then_done :: proc(t: ^testing.T) {
	wakes: int
	mb := Mailbox(JMsg){wake = count_wake, wake_user = &wakes}
	defer delete(mb.mail)
	jobs := make([dynamic]^Job(JMsg)); defer delete(jobs)
	out := make([dynamic]JMsg); defer delete(out)

	work :: proc(j: ^Job(JMsg)) {
		for i in 1 ..= 3 do post(j, JProgress{i})
	}
	j := job_start(&mb, work, nil, jdone, 7)
	testing.expect(t, j != nil, "a thread should start")
	append(&jobs, j)
	testing.expect(t, drain_until_idle(&mb, &jobs, &out), "the job should finish and be reaped")

	testing.expect_value(t, len(out), 4)
	for i in 0 ..< 3 {
		p, ok := out[i].(JProgress)
		testing.expect(t, ok && p.n == i + 1, "progress arrives in the order it was posted")
	}
	d, ok := out[3].(JDone)
	testing.expect(t, ok, "the done message comes last")
	testing.expect(t, !d.cancelled, "not cancelled")
	testing.expect_value(t, d.tag, 7)
	testing.expect(t, sync.atomic_load(&wakes) >= 1, "posting wakes the loop")
	testing.expect_value(t, len(jobs), 0)
}

@(test)
job_cancel_is_reported_in_done :: proc(t: ^testing.T) {
	mb: Mailbox(JMsg)
	defer delete(mb.mail)
	jobs := make([dynamic]^Job(JMsg)); defer delete(jobs)
	out := make([dynamic]JMsg); defer delete(out)

	work :: proc(j: ^Job(JMsg)) {
		for !cancelled(j) do time.sleep(time.Millisecond) // a worker that runs until told to stop
		post(j, JProgress{-1})
	}
	j := job_start(&mb, work, nil, jdone, 3)
	append(&jobs, j)
	time.sleep(5 * time.Millisecond)
	mailbox_drain(&mb, &jobs, &out)
	testing.expect_value(t, len(out), 0) // nothing yet: the worker is waiting
	job_stop(j) // what the cancel command does
	testing.expect(t, drain_until_idle(&mb, &jobs, &out), "a cancelled worker returns")
	testing.expect_value(t, len(out), 2)
	d, ok := out[1].(JDone)
	testing.expect(t, ok && d.cancelled, "done reports the cancellation")
}

@(test)
jobs_shutdown_stops_workers :: proc(t: ^testing.T) {
	mb: Mailbox(JMsg)
	defer delete(mb.mail)
	jobs := make([dynamic]^Job(JMsg)); defer delete(jobs)
	work :: proc(j: ^Job(JMsg)) {
		for !cancelled(j) do time.sleep(time.Millisecond)
	}
	for tag in 1 ..= 3 do append(&jobs, job_start(&mb, work, nil, nil, u64(tag)))
	start := time.tick_now()
	jobs_shutdown(&mb, &jobs)
	testing.expect_value(t, len(jobs), 0)
	testing.expect(t, time.tick_since(start) < JOB_QUIT_GRACE, "workers that listen end at once")
}

@(test)
batch_and_cancel_build_commands :: proc(t: ^testing.T) {
	work :: proc(j: ^Job(JMsg)) {}
	one := job(JMsg, work, tag = 1)
	testing.expect_value(t, one.kind, Cmd_Kind.Job)
	testing.expect_value(t, batch(JMsg, one).kind, Cmd_Kind.Job) // one command is itself
	b := batch(JMsg, one, cancel(JMsg, 1))
	testing.expect_value(t, b.kind, Cmd_Kind.Batch)
	testing.expect_value(t, len(b.list), 2)
	testing.expect_value(t, b.list[1].kind, Cmd_Kind.Cancel)
	testing.expect_value(t, b.list[1].tag, 1)
}

} // when ODIN_TEST