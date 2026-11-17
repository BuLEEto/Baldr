package baldr

// AT-SPI's `showing` is "is being shown", not "exists". A row scrolled out
// of a sidebar is visible and not showing.

@(require) import "core:testing"

when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Sh_Msg :: enum { None }

// sh_rows builds a scroll 120 px tall holding `n` rows of 40 px, so only the
// first three can be in view, and returns the row nodes.
@(private = "file")
sh_rows :: proc(ui: ^Ui(Sh_Msg), n: int, rows: ^[dynamic]Node) {
	set_viewport(&ui.tree, {300, 600})
	begin_view(ui)
	column(ui, flex = 1)
	scroll(ui, .Column, height = 120, key = 9)
	for i in 0 ..< n {
		r := box(ui, width = 200, height = 40, key = u64(100 + i))
		node_get(&ui.tree, r).access.role = .List_Item
		append(rows, r)
	}
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {300, 600})
}

@(private = "file")
sh_states :: proc(ui: ^Ui(Sh_Msg), n: Node) -> A11y_Flags {
	return a11y_flags(&ui.tree, n, node_get(&ui.tree, n))
}

// A row's `showing` follows the viewport, not its place in the tree.
@(test)
a_row_scrolled_out_of_its_viewport_is_visible_but_not_showing :: proc(t: ^testing.T) {
	ui: Ui(Sh_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	rows := make([dynamic]Node, context.temp_allocator)
	sh_rows(&ui, 20, &rows)
	if !testing.expect_value(t, len(rows), 20) do return

	first := sh_states(&ui, rows[0])
	testing.expect(t, .Visible in first, "the first row is visible")
	testing.expect(t, .Showing in first, "…and being shown")

	// 120 px of viewport, 40 px a row: row 10 sits at y = 400, long past it
	far := sh_states(&ui, rows[10])
	testing.expect(t, .Visible in far, "a scrolled-off row is still visible: it is in the tree")
	testing.expect(t, .Showing not_in far, "…but it is not being shown, which is the whole request")

	// and the two really are different answers for the same tree, so this is
	// not a test that would pass with `showing` simply switched off
	testing.expect(t, (.Showing in first) != (.Showing in far), "showing tells the two apart")
}

// Scrolling is what moves a row across the line, so the state has to follow
// the offset rather than the build.
@(test)
scrolling_brings_a_row_into_showing_and_takes_another_out :: proc(t: ^testing.T) {
	ui: Ui(Sh_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	rows := make([dynamic]Node, context.temp_allocator)
	sh_rows(&ui, 20, &rows)
	sc := node_get(&ui.tree, rows[0]).parent

	testing.expect(t, .Showing in sh_states(&ui, rows[0]), "row 0 starts in view")
	testing.expect(t, .Showing not_in sh_states(&ui, rows[10]), "row 10 starts out of view")

	// down to row 10: 400 px, through the real scrolling path
	testing.expect(t, scroll_by(&ui.tree, sc, {0, 400}), "it scrolled")
	frame(&ui.tree, {300, 600})
	testing.expect_value(t, scroll_offset(&ui.tree, sc).y, f32(400))

	testing.expect(t, .Showing not_in sh_states(&ui, rows[0]), "row 0 has gone off the top")
	testing.expect(t, .Showing in sh_states(&ui, rows[10]), "row 10 has come into view")
}

// A node with no clipping ancestor is showing wherever it is: a popup is laid
// out in window coordinates but presents on its own surface, so clipping to
// the window would call an open menu not-showing.
@(test)
nothing_clipping_means_showing :: proc(t: ^testing.T) {
	ui: Ui(Sh_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {300, 600})
	begin_view(&ui)
	column(&ui, flex = 1)
	n := box(&ui, width = 200, height = 40, key = 1)
	node_get(&ui.tree, n).access.role = .Button
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {300, 600})
	testing.expect(t, .Showing in sh_states(&ui, n), "no clipping ancestor: showing")

	d := node_get(&ui.tree, n)
	d.abs.y = 5000 // past the window, with nothing clipping it
	testing.expect(t, .Showing in sh_states(&ui, n), "and still showing past the window's edge")
}

}
