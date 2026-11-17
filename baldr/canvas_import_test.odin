package baldr

// A GPU buffer from another process, as the app sees it.
// Everything here is the CPU reference, which has no device and therefore
// nothing to import: what is being checked is that the calls say so plainly
// instead of doing something half-done, and that the promises an app writes
// its code against hold on the path where nothing works. The import itself
// is checked in `spikes/dmabuf_import`, which needs a card.

@(require) import "core:testing"

when ODIN_TEST || #config(BALDR_TESTS, false) {

// Where there is no device there is nothing to import, and the app's answer
// is to copy its frames in instead — so the refusal has to be an ordinary
// false, not a crash and not a canvas that half exists.
@(test)
a_buffer_from_elsewhere_is_refused_where_there_is_no_card :: proc(t: ^testing.T) {
	g := gpu_reference()
	defer gpu_close(&g)

	card := gpu_card(g)
	testing.expect(t, !card.shares && !card.known && card.node == "", "the reference shares nothing and is no card")

	mods: [8]u64
	testing.expect_value(t, canvas_import_modifiers(g, DRM_FORMAT_XBGR8888, mods[:]), 0)

	c, ok := canvas_import_dmabuf(g, Dmabuf{fd = 0, width = 64, height = 64, fourcc = DRM_FORMAT_XBGR8888, stride = 256})
	testing.expect(t, !ok && c == 0, "nothing imported, and no handle handed out")
}

// A canvas of Baldr's own is not an imported one, and every question about
// importing answers that way rather than refusing to answer.
@(test)
an_ordinary_canvas_is_not_a_buffer_from_elsewhere :: proc(t: ^testing.T) {
	g := gpu_reference()
	defer gpu_close(&g)
	c, _ := canvas_create(g, {8, 8})

	testing.expect(t, !canvas_imported(g, c), "ours")
	testing.expect(t, canvas_import_idle(g, c), "nothing is holding it")
	testing.expect(t, !canvas_imported(g, 0), "and a handle that is nothing is not imported either")
	testing.expect(t, canvas_import_idle(g, 0), "…nor held")

	// It can be written, which is the difference that matters: an imported
	// canvas refuses all of this, because the memory is the producer's.
	testing.expect(t, canvas_fill(g, c, 0, 0, 2, 2, {1, 0, 0, 1}), "ours to fill")
}

}
