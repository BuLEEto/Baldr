package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: behind this `when`, checking a program costs
// 1.0 GB instead of 9.2 GB. ODIN_TEST is set by `odin test`; BALDR_TESTS
// lets ./build.sh check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
add_box :: proc(tr: ^Tree, parent: Node, l: Layout_Props) -> Node {
	n := node_new(tr, Box_Kind{})
	node_get(tr, n).layout = l
	node_append(tr, parent, n)
	return n
}

@(private = "file")
abs_of :: proc(tr: ^Tree, n: Node) -> Rect { return node_get(tr, n).abs }

@(test)
layout_column_places_fixed_children_with_gap_and_padding :: proc(t: ^testing.T) {
	tr: Tree
	tree_init(&tr)
	defer tree_destroy(&tr)
	node_get(&tr, tr.root).layout = {axis = .Column, gap = 10, padding = pad4(5)}
	a := add_box(&tr, tr.root, {width = 100, height = 20})
	b := add_box(&tr, tr.root, {width = 50, height = 30})

	layout(&tr, {400, 300})

	testing.expect_value(t, abs_of(&tr, a), Rect{5, 5, 100, 20})
	testing.expect_value(t, abs_of(&tr, b), Rect{5, 35, 50, 30})
	testing.expect_value(t, abs_of(&tr, tr.root), Rect{0, 0, 400, 300})
}

@(test)
layout_row_flex_shares_free_space_and_stretches_cross :: proc(t: ^testing.T) {
	tr: Tree
	tree_init(&tr)
	defer tree_destroy(&tr)
	node_get(&tr, tr.root).layout = {axis = .Row, align = .Stretch}
	a := add_box(&tr, tr.root, {width = 100})
	b := add_box(&tr, tr.root, {flex = 1})
	c := add_box(&tr, tr.root, {flex = 3})

	layout(&tr, {400, 300})

	testing.expect_value(t, abs_of(&tr, a), Rect{0, 0, 100, 300})
	testing.expect_value(t, abs_of(&tr, b), Rect{100, 0, 75, 300})
	testing.expect_value(t, abs_of(&tr, c), Rect{175, 0, 225, 300})
}

@(test)
layout_justify_and_align_center :: proc(t: ^testing.T) {
	tr: Tree
	tree_init(&tr)
	defer tree_destroy(&tr)
	node_get(&tr, tr.root).layout = {axis = .Column, justify = .Center, align = .Center}
	a := add_box(&tr, tr.root, {width = 40, height = 20})

	layout(&tr, {400, 300})

	testing.expect_value(t, abs_of(&tr, a), Rect{180, 140, 40, 20})
}

@(test)
layout_space_between :: proc(t: ^testing.T) {
	tr: Tree
	tree_init(&tr)
	defer tree_destroy(&tr)
	node_get(&tr, tr.root).layout = {axis = .Row, justify = .Space_Between}
	a := add_box(&tr, tr.root, {width = 50, height = 10})
	b := add_box(&tr, tr.root, {width = 50, height = 10})
	c := add_box(&tr, tr.root, {width = 50, height = 10})

	layout(&tr, {400, 100})

	testing.expect_value(t, abs_of(&tr, a).x, f32(0))
	testing.expect_value(t, abs_of(&tr, b).x, f32(175))
	testing.expect_value(t, abs_of(&tr, c).x, f32(350))
}

@(test)
layout_text_uses_measurer :: proc(t: ^testing.T) {
	tr: Tree
	tree_init(&tr)
	defer tree_destroy(&tr)
	node_get(&tr, tr.root).layout = {axis = .Column} // no stretch: intrinsic width
	n := node_new(&tr, Text_Kind{str = "hello", size = 16})
	node_append(&tr, tr.root, n)

	layout(&tr, {400, 300})

	testing.expect_value(t, abs_of(&tr, n), Rect{0, 0, 40, 20}) // 5 runes × 8, line height 20

	// The root's default is align = .Stretch, so text fills the width.
	node_get(&tr, tr.root).layout = {axis = .Column, align = .Stretch}
	mark_layout_dirty(&tr, tr.root)
	layout(&tr, {400, 300})
	testing.expect_value(t, abs_of(&tr, n).w, f32(400))
}

@(test)
layout_hidden_children_take_no_space :: proc(t: ^testing.T) {
	tr: Tree
	tree_init(&tr)
	defer tree_destroy(&tr)
	node_get(&tr, tr.root).layout = {axis = .Column, gap = 10}
	a := add_box(&tr, tr.root, {width = 10, height = 10})
	b := add_box(&tr, tr.root, {width = 10, height = 10})
	c := add_box(&tr, tr.root, {width = 10, height = 10})
	layout(&tr, {100, 100})
	testing.expect_value(t, abs_of(&tr, c).y, f32(40))

	set_hidden(&tr, b, true)
	layout(&tr, {100, 100})
	testing.expect(t, abs_of(&tr, c).y == 20, "gap for the hidden middle child disappears")
	testing.expect_value(t, abs_of(&tr, a).y, f32(0))
}

@(test)
layout_clean_subtrees_are_skipped :: proc(t: ^testing.T) {
	tr: Tree
	tree_init(&tr)
	defer tree_destroy(&tr)
	node_get(&tr, tr.root).layout = {axis = .Column}
	// A: a boundary with 100 leaves. B: a sibling leaf.
	a := add_box(&tr, tr.root, {axis = .Column, width = 200, height = 200})
	node_get(&tr, a).flags += {.Relayout_Boundary}
	leaves: [100]Node
	for i in 0 ..< 100 do leaves[i] = add_box(&tr, a, {width = 10, height = 1})
	b := add_box(&tr, tr.root, {width = 10, height = 10})
	layout(&tr, {400, 400})
	testing.expect(t, tr.stats.layout_nodes >= 103, "first layout visits everything")

	// Change B only: the root relays, A is clean with unchanged constraints → skipped.
	tr.stats = {}
	set_layout(&tr, b, {width = 20, height = 20})
	layout(&tr, {400, 400})
	testing.expect_value(t, tr.stats.layout_nodes, 2) // root + b

	// Change one leaf inside A: A is the dirty root; the root and B are not visited.
	tr.stats = {}
	set_layout(&tr, leaves[50], {width = 10, height = 2})
	layout(&tr, {400, 400})
	testing.expect_value(t, tr.stats.layout_nodes, 2) // a + the leaf
	testing.expect_value(t, abs_of(&tr, leaves[51]).y, f32(52))
}

@(test)
layout_boundary_size_change_escalates :: proc(t: ^testing.T) {
	tr: Tree
	tree_init(&tr)
	defer tree_destroy(&tr)
	node_get(&tr, tr.root).layout = {axis = .Column}
	a := add_box(&tr, tr.root, {axis = .Column}) // auto-sized boundary
	node_get(&tr, a).flags += {.Relayout_Boundary}
	leaf := add_box(&tr, a, {width = 10, height = 10})
	b := add_box(&tr, tr.root, {width = 10, height = 10})
	layout(&tr, {100, 100})
	testing.expect_value(t, abs_of(&tr, b).y, f32(10))

	set_layout(&tr, leaf, {width = 10, height = 30}) // A grows → parent must move B
	layout(&tr, {100, 100})
	testing.expect_value(t, abs_of(&tr, b).y, f32(30))
}

// A row that does not fit takes the deficit from what can give: the text
// with an ellipsis is trimmed, the button keeps its label on one line at
// its full width.
@(test)
row_shrinks_ellipsised_text_before_a_button :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {600, 300})
	begin_view(&ui)
	column(&ui)
	column(&ui, width = 600) // room for everything: the reference
	row(&ui, gap = .sm)
	text(&ui, "A long message title that will need trimming somewhere", nowrap = true, ellipsis = .End)
	ref_btn := button(&ui, "Pick", Test_Msg.Inc, variant = .Ghost)
	end(&ui)
	end(&ui)
	column(&ui, width = 200) // squeezed
	row(&ui, gap = .sm)
	title := text(&ui, "A long message title that will need trimming somewhere", nowrap = true, ellipsis = .End)
	btn := button(&ui, "Pick", Test_Msg.Inc, variant = .Ghost)
	end(&ui)
	end(&ui)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 300})
	rb, b := node_get(&ui.tree, ref_btn).abs, node_get(&ui.tree, btn).abs
	testing.expectf(t, b.w == rb.w, "the button keeps its width: %g vs %g unsqueezed", b.w, rb.w)
	testing.expectf(t, b.h == rb.h, "…and its label on one line: %g vs %g", b.h, rb.h)
	tk := node_get(&ui.tree, title).kind.(Text_Kind)
	testing.expect(t, len(tk.display) > 0, "the title gave the width up and was trimmed")
	td := node_get(&ui.tree, title).abs
	testing.expect(t, td.x + td.w <= b.x, "the title ends before the button")
	testing.expect(t, b.x + b.w <= 200.01, "the row fits its 200 px")
}

// Words are never broken apart while a row can still be made to fit some
// other way: a wrapping text keeps at least its longest word.
@(test)
row_keeps_words_whole_before_squeezing :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {600, 300})
	begin_view(&ui)
	column(&ui, width = 150)
	row(&ui, gap = .sm)
	txt := text(&ui, "Inbox messages pending")
	button(&ui, "Clear", Test_Msg.Inc, variant = .Outline)
	end(&ui)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 300})
	tk := node_get(&ui.tree, txt).kind.(Text_Kind)
	longest := ui.tree.measure_text(&ui.tree, "messages", tk.size, 0, tk.weight, tk.mono, tk.family, false).x
	td := node_get(&ui.tree, txt).abs
	testing.expectf(t, td.w >= longest - 0.01, "the text keeps its longest word: %g wide, word %g", td.w, longest)
	lh := ui.tree.measure_text(&ui.tree, "x", tk.size, 0, tk.weight, tk.mono, tk.family, false).y
	testing.expectf(t, td.h <= 3 * lh + 0.5, "it wraps at word boundaries, not letters: %g tall for line height %g", td.h, lh)
	// when even the floors do not fit, nothing is broken: the row overflows
	begin_view(&ui)
	column(&ui, width = 60)
	row(&ui, gap = .sm)
	txt2 := text(&ui, "Inbox messages pending")
	btn2 := button(&ui, "Clear", Test_Msg.Inc, variant = .Outline)
	end(&ui)
	end(&ui)
	column(&ui, width = 600)
	row(&ui)
	ref := button(&ui, "Clear", Test_Msg.Inc, variant = .Outline)
	end(&ui)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 300})
	testing.expect_value(t, node_get(&ui.tree, btn2).abs.w, node_get(&ui.tree, ref).abs.w)
	testing.expect_value(t, node_get(&ui.tree, btn2).abs.h, node_get(&ui.tree, ref).abs.h)
	testing.expect(t, node_get(&ui.tree, txt2).abs.w >= longest - 0.01, "the longest word survives even then")
}

// row(vertical = true) stacks its children top to bottom, stretched across.
@(test)
row_vertical_stacks_children :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {300, 300})
	begin_view(&ui)
	column(&ui, width = 300)
	row(&ui, gap = .sm, vertical = true)
	a := box(&ui, height = 10)
	b := box(&ui, height = 10)
	end(&ui)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {300, 300})
	ar, br := node_get(&ui.tree, a).abs, node_get(&ui.tree, b).abs
	testing.expect(t, br.y > ar.y + ar.h - 0.01, "second child below the first")
	testing.expect_value(t, ar.w, f32(300))
	testing.expect_value(t, br.w, f32(300))
}

} // when ODIN_TEST