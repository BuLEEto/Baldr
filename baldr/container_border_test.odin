package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A border on a column, a row, a stack, a wrap or a box — the outline of a
// card that says it is the selected one — drawn just inside the node, so it
// takes no room and moves nothing as it comes and goes.

@(private = "file")
Bd_Msg :: union { int }

@(private = "file")
Bd_Nodes :: struct { col, inner, st, wr, bx: Node }

@(private = "file")
border_build :: proc(ui: ^Ui(Bd_Msg), border: Color, width: f32 = 1) -> (n: Bd_Nodes) {
	begin_view(ui)
	n.col = column(ui, padding = .md, gap = .sm, radius = 8, border = border, border_width = width)
	n.inner = row(ui, gap = .sm, border = border, border_width = width)
	box(ui, width = 20, height = 20, bg = {0.2, 0.2, 0.2, 1})
	end(ui)
	n.st = stack(ui, width = 60, height = 30, border = border, border_width = width)
	end(ui)
	n.wr = wrap(ui, width = 80, border = border, border_width = width)
	box(ui, width = 20, height = 20)
	end(ui)
	n.bx = box(ui, width = 40, height = 40, border = border, border_width = width)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {300, 300})
	return
}

@(private = "file")
border_nodes :: proc(n: Bd_Nodes) -> [5]Node {
	return {n.col, n.inner, n.st, n.wr, n.bx}
}

// The rects drawn with this border, by where they are.
@(private = "file")
border_rects :: proc(ui: ^Ui(Bd_Msg), border: Color) -> (out: [dynamic]Draw_Rect) {
	out = make([dynamic]Draw_Rect, context.temp_allocator)
	for c in draw_list(&ui.tree) do if r, ok := c.(Draw_Rect); ok && r.border_w > 0 && r.border == border do append(&out, r)
	return
}

@(test)
a_container_draws_the_border_it_is_given :: proc(t: ^testing.T) {
	ui: Ui(Bd_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	orange := Color{1, 0.5, 0, 1}

	plain := border_build(&ui, {})
	before: [5]Rect
	for n, i in border_nodes(plain) {
		d := node_get(&ui.tree, n)
		before[i] = d.abs
		testing.expect_value(t, d.style.border_w, 0)
	}
	testing.expect_value(t, len(border_rects(&ui, orange)), 0)

	// Two px of orange round each of them, drawn where each one is.
	bordered := border_build(&ui, orange, 2)
	rects := border_rects(&ui, orange)
	testing.expect_value(t, len(rects), 5)
	for n, i in border_nodes(bordered) {
		d := node_get(&ui.tree, n)
		testing.expect_value(t, d.style.border_w, 2)
		testing.expect_value(t, d.style.border, orange)
		// …and inside it: nothing moved or grew to make room for the line
		testing.expect_value(t, d.abs, before[i])
		drawn := false
		for r in rects do if r.rect == d.abs && r.border_w == 2 do drawn = true
		testing.expectf(t, drawn, "node %d drew its border at its own rect", i)
	}
	// the column's radius goes round the line as well
	for r in rects do if r.rect == node_get(&ui.tree, bordered.col).abs do testing.expect_value(t, r.radius, 8)

	// A colour alone is a hairline.
	thin := border_build(&ui, orange)
	for n in border_nodes(thin) do testing.expect_value(t, node_get(&ui.tree, n).style.border_w, 1)

	// And it goes when the next build leaves it out, as `bg` does.
	gone := border_build(&ui, {})
	for n in border_nodes(gone) do testing.expect_value(t, node_get(&ui.tree, n).style.border_w, 0)
	testing.expect_value(t, len(border_rects(&ui, orange)), 0)
}

// A width with no colour is no border, rather than a black one.
@(test)
a_width_without_a_colour_draws_nothing :: proc(t: ^testing.T) {
	ui: Ui(Bd_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := border_build(&ui, {}, 3)
	for node in border_nodes(n) do testing.expect_value(t, node_get(&ui.tree, node).style.border_w, 0)
}

} // when ODIN_TEST
