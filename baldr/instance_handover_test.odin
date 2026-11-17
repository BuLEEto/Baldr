package baldr

@(require) import "core:testing"
@(require) import "core:time"

// One instance of an app, and what a second launch does, on every platform:
// a socket on Linux and macOS, a named pipe on Windows. The round trip
// (claiming, being refused, handing the arguments over and hearing them)
// runs in one process: the thing under test is the channel, not a second
// program.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Inst_Msg :: union { Inst_Again }

@(private = "file")
Inst_Again :: struct { args: []string }

@(test)
a_second_launch_hands_over_its_arguments_and_stops :: proc(t: ^testing.T) {
	id := "baldr.test.instance.handover"
	mb: Mailbox(Inst_Msg)
	jobs: [dynamic]^Job(Inst_Msg)
	defer delete(jobs)
	defer jobs_shutdown(&mb, &jobs)

	first, owner := instance_claim(id, {"/bin/app"})
	testing.expect(t, owner, "the first launch owns the instance")
	defer instance_stop(&first)
	instance_listen(&first, &mb, proc(e: Ev(Relaunch)) -> Inst_Msg {
		return Inst_Again{e.value.args}
	})

	second, owner2 := instance_claim(id, {"/bin/app", "/some/file.txt", "--open"})
	testing.expect(t, !owner2, "the second launch is told there is already one")
	when ODIN_OS == .Windows {
		testing.expect(t, second.pipe == nil, "…and it has nothing of its own to clean up")
	} else {
		testing.expect(t, second.fd == 0, "…and it has nothing of its own to clean up")
	}

	// The listener is a thread; it looks for an arrival a few times a
	// second, so this waits rather than assuming.
	out := make([dynamic]Inst_Msg, context.temp_allocator)
	for _ in 0 ..< 40 {
		if mailbox_drain(&mb, &jobs, &out) do break
		time.sleep(50 * time.Millisecond)
	}
	testing.expectf(t, len(out) == 1, "the first launch heard exactly one relaunch (%d)", len(out))
	if len(out) != 1 do return
	again, ok := out[0].(Inst_Again)
	testing.expect(t, ok, "…as its own message")
	if !ok do return
	testing.expect_value(t, len(again.args), 3)
	if len(again.args) == 3 {
		testing.expect_value(t, again.args[1], "/some/file.txt")
		testing.expect_value(t, again.args[2], "--open")
	}
	mailbox_release(&mb) // frees the op the message pointed into
}

} // when ODIN_TEST
