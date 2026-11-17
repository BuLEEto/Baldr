package baldr

@(require) import "core:mem"
@(require) import "core:testing"

// See canvas_test.odin for why test files sit behind this `when`.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// BALDR_DEBUG_MEMORY's report names the lines whose live memory grew since
// the last one, net: a line that freed what it made and made it again (a
// page laid out afresh) is not listed, and a line that keeps what it makes
// is listed by how much it kept.

@(private = "file")
memory_watch_free_for_test :: proc(w: ^Memory_Watch) {
	delete(w.last_groups)
	mem.tracking_allocator_destroy(&w.track)
	free(w)
}

@(private = "file")
memory_line_grew :: proc(grew: []Memory_Group, line: i32) -> (Memory_Group, bool) {
	for g in grew do if g.line == line do return g, true
	return {}, false
}

@(test)
the_memory_report_names_the_lines_that_grew :: proc(t: ^testing.T) {
	w := memory_watch_make(10_000)
	defer memory_watch_free_for_test(w)
	tracked := mem.tracking_allocator(&w.track)

	// Three laps of the same code: one line keeps what it makes (one block,
	// then two, then none), another frees its block and makes another.
	kept_per_lap := [3]int{1, 2, 0}
	kept := make([dynamic]rawptr, context.temp_allocator)
	churn: rawptr
	keep_line, churn_line: i32
	for lap in 0 ..< 3 {
		for _ in 0 ..< kept_per_lap[lap] {
			append(&kept, mem.alloc(100, allocator = tracked) or_else nil); keep_line = i32(#location().line)
		}
		if churn != nil do mem.free(churn, tracked)
		churn = mem.alloc(64, allocator = tracked) or_else nil; churn_line = i32(#location().line)

		grew, _, _, _, _ := memory_watch_measure(w)
		defer delete(grew)
		g, kept_listed := memory_line_grew(grew[:], keep_line)
		_, churn_listed := memory_line_grew(grew[:], churn_line)
		switch lap {
		case 0: // the first measure: everything live is new
			testing.expect(t, kept_listed && churn_listed && len(grew) == 2, "the first report lists both lines")
		case 1:
			testing.expect(t, kept_listed, "the line that keeps what it makes is listed")
			testing.expect_value(t, g.count, 2)
			testing.expect_value(t, g.bytes, 200)
			testing.expect(t, !churn_listed, "the line that made again what it freed is not")
			testing.expect_value(t, len(grew), 1)
		case 2:
			testing.expect_value(t, len(grew), 0) // a lap that keeps nothing lists nothing
		}
	}

	// A free of memory made before the watch began goes to the heap it came
	// from (the test runner's own tracker would call it a leak otherwise),
	// and is counted.
	before := mem.alloc(32) or_else nil
	mem.free(before, tracked)
	testing.expect_value(t, w.untracked_frees, 1)

	for p in kept do mem.free(p, tracked)
	mem.free(churn, tracked)
}

}
