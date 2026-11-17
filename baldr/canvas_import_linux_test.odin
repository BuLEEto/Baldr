#+build linux
package baldr

// The part of importing a GPU buffer that only Linux has a descriptor for.
// Its own file because an import cannot sit inside a `when`.

@(require) import "core:sys/linux"
@(require) import "core:testing"

when ODIN_TEST || #config(BALDR_TESTS, false) {

// bal_readers_gone says whether the read end of a pipe has been closed, by
// asking the pipe rather than the descriptor number: `odin test` runs tests
// on several threads, so between the close and the question another test can
// be handed the very number we closed, and "is this fd still valid" would
// answer about someone else's file. POLLERR on the write end is the pipe
// itself saying it has no readers left.
@(private = "file")
bal_readers_gone :: proc(write_end: linux.Fd) -> bool {
	fds := []linux.Poll_Fd{{fd = write_end, events = {.OUT}}}
	linux.poll(fds, 0)
	return .ERR in fds[0].revents
}

// "The fence is taken over" is the promise an app writes no close against,
// so it has to hold on the paths where nothing else does — a descriptor kept
// by a refusal leaks one per frame, which at sixty a second is a process out
// of descriptors in a few minutes.
@(test)
an_acquire_fence_is_taken_over_even_when_it_is_refused :: proc(t: ^testing.T) {
	g := gpu_reference()
	defer gpu_close(&g)
	c, _ := canvas_create(g, {8, 8})

	testing.expect(t, !canvas_acquire_fence(g, c, -1), "nothing to take over")
	testing.expect(t, !canvas_acquire_fence(g, 0, -1), "nor for a handle that is nothing")

	fds: [2]linux.Fd
	if linux.pipe2(&fds, {}) != .NONE do testing.fail_now(t, "no pipe to make a descriptor from")
	defer linux.close(fds[1])
	testing.expect(t, !bal_readers_gone(fds[1]), "the pipe has a reader to begin with")
	testing.expect(t, !canvas_acquire_fence(g, c, int(fds[0])), "refused: this canvas was not imported")
	testing.expect(t, bal_readers_gone(fds[1]), "…and the descriptor was closed all the same")
}

}
