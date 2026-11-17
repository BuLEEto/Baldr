package baldr

@(require) import "core:os"
@(require) import "core:strings"
@(require) import "core:sync"
@(require) import "core:testing"
@(require) import "core:time"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: about 9 GB without this `when`, 1 GB with it.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private="file")
File_Io_Msg :: union {
	FLoaded,
	FSaved,
}
@(private="file")
FLoaded :: struct { ok: bool, text: string, error: string, tag: u64 }
@(private="file")
FSaved :: struct { ok: bool, error: string }

@(private="file")
floaded :: proc(e: Ev(File_Read)) -> File_Io_Msg { return FLoaded{e.value.ok, string(e.value.data), e.value.error, e.tag} }
@(private="file")
fsaved :: proc(e: Ev(File_Written)) -> File_Io_Msg { return FSaved{e.value.ok, e.value.error} }

// wait_for pumps the mailbox until `n` messages arrived or two seconds passed.
@(private="file")
wait_for :: proc(mb: ^Mailbox(File_Io_Msg), jobs: ^[dynamic]^Job(File_Io_Msg), out: ^[dynamic]File_Io_Msg, n: int) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < 2 * time.Second {
		mailbox_drain(mb, jobs, out)
		if len(out) >= n do return true
		time.sleep(time.Millisecond)
	}
	return false
}

@(test)
file_write_then_read_off_the_main_thread :: proc(t: ^testing.T) {
	os.make_directory("build")
	path := "build/file_io_test.txt"
	io: Io
	defer io_stop(&io)
	mb: Mailbox(File_Io_Msg)
	defer { mailbox_release(&mb); delete(mb.finished); delete(mb.mail) }
	jobs := make([dynamic]^Job(File_Io_Msg)); defer delete(jobs)
	out := make([dynamic]File_Io_Msg); defer delete(out)

	file_write(&io, &mb, &jobs, path, transmute([]u8)string("hello, disk\n"), fsaved, 0)
	testing.expect(t, wait_for(&mb, &jobs, &out, 1), "the write reports back")
	w, wok := out[0].(FSaved)
	testing.expect(t, wok && w.ok, "written")
	testing.expect_value(t, w.error, "")

	file_read(&io, &mb, &jobs, path, floaded, 9)
	testing.expect(t, wait_for(&mb, &jobs, &out, 2), "the read reports back")
	r, rok := out[1].(FLoaded)
	testing.expect(t, rok && r.ok, "read")
	testing.expect_value(t, r.text, "hello, disk\n")
	testing.expect_value(t, r.tag, 9)
	testing.expect_value(t, len(mb.finished), 2) // freed by mailbox_release after update handled them
	testing.expect(t, io.ok || len(jobs) == 0, "nbio ran it, or the fallback thread has been reaped")
}

@(test)
file_read_missing_reports_the_error :: proc(t: ^testing.T) {
	io: Io
	defer io_stop(&io)
	mb: Mailbox(File_Io_Msg)
	defer { mailbox_release(&mb); delete(mb.finished); delete(mb.mail) }
	jobs := make([dynamic]^Job(File_Io_Msg)); defer delete(jobs)
	out := make([dynamic]File_Io_Msg); defer delete(out)
	file_read(&io, &mb, &jobs, "build/no-such-file-here.txt", floaded, 0)
	testing.expect(t, wait_for(&mb, &jobs, &out, 1), "reports back")
	r, ok := out[0].(FLoaded)
	testing.expect(t, ok && !r.ok, "not ok")
	testing.expect(t, len(r.error) > 0, "with a reason")
	testing.expect_value(t, len(r.text), 0)
}

// A GUI toolkit's IO thread must cost nothing while it waits: nbio's tick
// only blocks while its loop has work (on Windows it returns at once when
// it has none), so the thread parks itself between operations.
@(test)
the_io_thread_parks_between_operations :: proc(t: ^testing.T) {
	os.make_directory("build")
	io: Io
	defer io_stop(&io)
	mb: Mailbox(File_Io_Msg)
	defer { mailbox_release(&mb); delete(mb.finished); delete(mb.mail) }
	jobs := make([dynamic]^Job(File_Io_Msg)); defer delete(jobs)
	out := make([dynamic]File_Io_Msg); defer delete(out)

	file_write(&io, &mb, &jobs, "build/file_io_idle_test.txt", transmute([]u8)string("idle\n"), fsaved, 0)
	testing.expect(t, wait_for(&mb, &jobs, &out, 1), "the write reports back")
	if !io.ok do return // nbio cannot run here; each operation got a thread of its own, and no loop spins

	time.sleep(20 * time.Millisecond) // it settles after the last outcome
	settled := sync.atomic_load(&io.ticks)
	time.sleep(50 * time.Millisecond)
	idle := sync.atomic_load(&io.ticks)
	testing.expectf(t, idle == settled, "the thread parks with nothing in flight (it went round %d more times in 50ms)", idle - settled)
	testing.expect_value(t, sync.atomic_load(&io.inflight), 0)

	// and it takes the next operation without anything to nudge it
	file_read(&io, &mb, &jobs, "build/file_io_idle_test.txt", floaded, 3)
	testing.expect(t, wait_for(&mb, &jobs, &out, 2), "a read after the park reports back")
	r, rok := out[1].(FLoaded)
	testing.expect(t, rok && r.ok && r.tag == 3, "read")
	testing.expect_value(t, r.text, "idle\n")
}

// The IO thread spends its life parked, and stopping it wakes it twice over:
// the semaphore it waits on, and the event loop it may be ticking. The wake
// must not reach a loop the thread has already given up, so start and stop it
// over and over — a stop that races the thread's exit crashes here.
@(test)
the_io_thread_stops_cleanly_over_and_over :: proc(t: ^testing.T) {
	os.make_directory("build")
	for round in 0 ..< 20 {
		io: Io
		mb: Mailbox(File_Io_Msg)
		jobs := make([dynamic]^Job(File_Io_Msg))
		out := make([dynamic]File_Io_Msg)
		file_write(&io, &mb, &jobs, "build/file_io_stop_test.txt", transmute([]u8)string("round\n"), fsaved, 0)
		testing.expectf(t, wait_for(&mb, &jobs, &out, 1), "the write reports back (round %d)", round)
		io_stop(&io) // while it is parked with nothing in flight
		mailbox_release(&mb)
		delete(mb.finished); delete(mb.mail); delete(jobs); delete(out)
	}
}

// nbio asserts on a zero-length buffer, which a buffer sized from stat
// would be for an empty file. An empty file reads as empty and successful; a
// file that stat calls empty but has contents (/proc) reads as what is in
// it; a file larger than the first buffer reads whole. Both ways: on the IO
// thread, and on a fallback thread where nbio cannot run.
@(test)
file_read_takes_what_is_there_whatever_its_size :: proc(t: ^testing.T) {
	os.make_directory("build")
	empty := "build/file_io_empty.txt"
	_ = os.write_entire_file(empty, []u8{})
	big := "build/file_io_big.txt"
	big_data := make([]u8, 200_000)
	defer delete(big_data)
	for &b, i in big_data do b = u8('a' + i % 26)
	_ = os.write_entire_file(big, big_data)

	for fallback in ([2]bool{false, true}) {
		io: Io
		if fallback do io.tried = true // as where nbio can't start: each read on a thread of its own
		mb: Mailbox(File_Io_Msg)
		jobs := make([dynamic]^Job(File_Io_Msg))
		out := make([dynamic]File_Io_Msg)
		defer { io_stop(&io); mailbox_release(&mb); delete(mb.finished); delete(mb.mail); delete(jobs); delete(out) }
		how := "a fallback thread" if fallback else "the IO thread"

		file_read(&io, &mb, &jobs, empty, floaded, 1)
		testing.expectf(t, wait_for(&mb, &jobs, &out, 1), "%s: the empty file reports back", how)
		if len(out) >= 1 {
			r, _ := out[0].(FLoaded)
			testing.expectf(t, r.ok && len(r.text) == 0 && r.error == "", "%s: empty, and fine (%v)", how, r)
		}

		file_read(&io, &mb, &jobs, big, floaded, 2)
		testing.expectf(t, wait_for(&mb, &jobs, &out, 2), "%s: the big file reports back", how)
		if len(out) >= 2 {
			r, _ := out[1].(FLoaded)
			testing.expectf(t, r.ok && len(r.text) == len(big_data) && r.text == string(big_data), "%s: all %d bytes (%d)", how, len(big_data), len(r.text))
		}

		when ODIN_OS == .Linux {
			file_read(&io, &mb, &jobs, "/proc/self/status", floaded, 3) // stat says 0 bytes; it has lines
			testing.expectf(t, wait_for(&mb, &jobs, &out, 3), "%s: /proc reports back", how)
			if len(out) >= 3 {
				r, _ := out[2].(FLoaded)
				testing.expectf(t, r.ok && strings.contains(r.text, "Name:"), "%s: /proc/self/status read as what is in it (%d bytes)", how, len(r.text))
			}
		}
	}
}

} // when ODIN_TEST