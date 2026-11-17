package gpu

// The staging pool's policy (canvas_staging.odin): which idle buffer answers
// a request, and when one is let go. The policy is shared code so it needs no
// device: the choosing is the part that can be wrong, and it can be read off
// a list of sizes.

@(require) import "core:testing"

when ODIN_TEST || #config(BALDR_TESTS, false) {

// STAGE_MAPPED stands in for a real staging buffer's mapped address. The pool
// keeps only CPU-writable memory, which it tells by `ptr`, and never reads
// through it, so any non-nil address will do.
@(private = "file")
STAGE_MAPPED :: rawptr(uintptr(0x1000))

// stage_give puts buffers of `sizes` on the idle list, as finished ones
// arrive there.
@(private = "file")
stage_give :: proc(r: ^Renderer, sizes: []int, use := Buffer_Use.Upload) {
	for s in sizes {
		b := Buffer{size = s, ptr = STAGE_MAPPED, use = use}
		staging_give(r, &b)
	}
}

// A buffer handed back is handed out again for a request of the same size,
// as a video frame is every frame.
@(test)
a_finished_staging_buffer_answers_the_next_write_of_its_size :: proc(t: ^testing.T) {
	r: Renderer
	defer staging_shutdown(&r)
	stage_give(&r, {8 << 20, 8 << 20, 8 << 20})
	testing.expect_value(t, len(r.staging.free), 3)
	testing.expect_value(t, r.staging.bytes, 3 * (8 << 20))

	b, ok := staging_reuse(&r, 8 << 20, .Upload)
	testing.expect(t, ok, "an idle buffer answered")
	testing.expect_value(t, b.size, 8 << 20)
	testing.expect_value(t, r.staging.reused, 1)
	testing.expect_value(t, len(r.staging.free), 2)
	testing.expect_value(t, r.staging.bytes, 2 * (8 << 20))
	testing.expect_value(t, r.staging.made, 0) // nothing was created: there was no device to create it with

	// …and the one taken is no longer on the list, so two writes in a frame
	// get two buffers rather than the same one twice.
	c, again := staging_reuse(&r, 8 << 20, .Upload)
	testing.expect(t, again && c.size == b.size, "a second of the same size")
	testing.expect_value(t, len(r.staging.free), 1)
	testing.expect_value(t, r.staging.reused, 2)
}

// A request takes the snuggest buffer that fits, and refuses one more than a
// quarter too big: otherwise one 4K frame's buffer would end up serving every
// small write after it.
@(test)
a_staging_buffer_far_bigger_than_the_write_is_not_handed_over :: proc(t: ^testing.T) {
	r: Renderer
	defer staging_shutdown(&r)
	stage_give(&r, {33 << 20, 1300, 1100, 900})

	_, ok := staging_reuse(&r, 1024, .Upload)
	testing.expect(t, ok, "1024 bytes is answered")
	// 1100 and 1300 both fit 1024; 1024 + 1024/4 = 1280 rules 1300 out, and
	// 900 is too small, so 1100 is the only one — and the snuggest.
	testing.expect_value(t, len(r.staging.free), 3)
	left: [3]int
	for ib, i in r.staging.free do left[i] = ib.buf.size
	testing.expect(t, left == {33 << 20, 1300, 900} || left == {33 << 20, 900, 1300}, "the 1100 went")

	_, big := staging_reuse(&r, 8 << 20, .Upload)
	testing.expect(t, !big, "the 33 MB one is not spent on an 8 MB write")
	_, fits := staging_reuse(&r, 30 << 20, .Upload)
	testing.expect(t, fits, "…but it answers a write within a quarter of it")
}

// Upload and vertex buffers are different things to the device (Vulkan
// declares the usage at creation), so one is never handed out as the other.
@(test)
a_staging_buffer_is_only_reused_for_the_work_it_was_made_for :: proc(t: ^testing.T) {
	r: Renderer
	defer staging_shutdown(&r)
	stage_give(&r, {4096}, .Vertex)
	_, wrong := staging_reuse(&r, 4096, .Upload)
	testing.expect(t, !wrong, "a vertex buffer does not answer a write")
	_, right := staging_reuse(&r, 4096, .Vertex)
	testing.expect(t, right, "…and does answer the next dabs")
}

// A buffer nobody wants is let go, so a burst's peak is not held for the
// rest of the run. Reuse resets the wait.
@(test)
an_idle_staging_buffer_is_let_go_in_the_end :: proc(t: ^testing.T) {
	r: Renderer
	defer staging_shutdown(&r)
	stage_give(&r, {33 << 20})
	for _ in 0 ..< STAGING_IDLE_FLUSHES do staging_age(&r)
	testing.expect_value(t, len(r.staging.free), 1) // not yet: it has waited exactly its allowance

	_, ok := staging_reuse(&r, 33 << 20, .Upload)
	testing.expect(t, ok, "taken in time")
	stage_give(&r, {33 << 20}) // back on the list, its wait starting again
	for _ in 0 ..< STAGING_IDLE_FLUSHES do staging_age(&r)
	testing.expect_value(t, len(r.staging.free), 1)
	staging_age(&r)
	testing.expect_value(t, len(r.staging.free), 0)
	testing.expect_value(t, r.staging.bytes, 0)
	testing.expect_value(t, r.staging.dropped, 1)
}

// The idle list is capped, so writes in sizes that never repeat cannot grow
// the pool without bound.
@(test)
the_idle_staging_list_holds_no_more_than_its_cap :: proc(t: ^testing.T) {
	r: Renderer
	defer staging_shutdown(&r)
	each := 33 << 20
	for _ in 0 ..< (STAGING_FREE_BYTES / each) + 3 do stage_give(&r, {each})
	testing.expect(t, r.staging.bytes <= STAGING_FREE_BYTES, "within the cap")
	testing.expect(t, r.staging.bytes + each > STAGING_FREE_BYTES, "and full: the next one would not fit")
	testing.expect(t, r.staging.dropped >= 3, "the ones past it were let go")

	// Clearing it (a device reset, or the run ending) leaves the counters,
	// which are a run's totals and outlive the device.
	staging_clear(&r)
	testing.expect_value(t, len(r.staging.free), 0)
	testing.expect_value(t, r.staging.bytes, 0)
	testing.expect(t, canvas_staging_stats(&r).dropped > 0, "what it has let go is still on the record")
}

// Nothing is kept that the CPU cannot write into (a device-local buffer) or
// that is not there at all, however it arrives.
@(test)
the_staging_list_keeps_only_buffers_it_can_hand_back :: proc(t: ^testing.T) {
	r: Renderer
	defer staging_shutdown(&r)
	none := Buffer{}
	staging_give(&r, &none)
	device_local := Buffer{size = 4096} // no ptr: nothing to fill
	staging_give(&r, &device_local)
	testing.expect_value(t, len(r.staging.free), 0)
	testing.expect_value(t, r.staging.bytes, 0)

	_, ok := staging_reuse(&r, 0, .Upload)
	testing.expect(t, !ok, "a request for nothing is not answered")
}

}
