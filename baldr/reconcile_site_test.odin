package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them. ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh
// check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A view that changes shape (a breakpoint) must not hand one builder's node
// to another builder at the same position.
@(private = "file")
shape_view :: proc(ui: ^Ui(Ov_Msg), wide: bool) -> (second: Node) {
	begin_view(ui)
	row(ui, align = .Center)
	text(ui, "Title")
	if wide {
		second = tab_bar(ui, 0, {"A", "B", "C"}, nil)
	} else {
		second = spacer(ui)
	}
	button(ui, "x", Ov_Msg{})
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 200})
	return
}

@(test)
reconcile_positional_reuse_requires_the_same_builder_site :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sp := shape_view(&ui, false)
	testing.expect_value(t, node_get(&ui.tree, sp).layout.flex, 1)
	bar := shape_view(&ui, true)
	testing.expect(t, bar != sp, "the tab bar got a fresh node, not the spacer's")
	testing.expect(t, !node_valid(&ui.tree, sp), "the spacer's node was removed")
	bd := node_get(&ui.tree, bar)
	testing.expect_value(t, bd.layout.axis, Axis.Row)
	testing.expect_value(t, bd.layout.flex, 0)
	testing.expect_value(t, bd.access.role, Role.Tab_List)
	testing.expect_value(t, node_child_count(&ui.tree, bar), 3)
	first := node_get(&ui.tree, bar).first
	tabs_horizontal := node_get(&ui.tree, node_next(&ui.tree, first)).abs.x > node_get(&ui.tree, first).abs.x
	testing.expect(t, tabs_horizontal, "tabs sit side by side")
	// Same shape again: the node is reused (no churn).
	bar2 := shape_view(&ui, true)
	testing.expect_value(t, bar2, bar)
	sp2 := shape_view(&ui, false)
	testing.expect(t, sp2 != bar && !node_valid(&ui.tree, bar), "back to a spacer: the bar is gone")
}

@(test)
layout_row_shrinks_children_to_fit_instead_of_overflowing :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	column(&ui, align = .Start)
	r := row(&ui, width = 200, gap = .sm)
	a := box(&ui, width = 150, height = 10)
	b := box(&ui, width = 150, height = 10)
	end(&ui)
	r2 := row(&ui, width = 200, gap = .sm)
	f := text_input(&ui, nil, placeholder = "search", flex = 1)
	c := box(&ui, width = 400, height = 10)
	end(&ui)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 400})
	gap := ui.theme.space[.sm]
	// Two 150 px boxes in 200 px: both shrink in proportion.
	testing.expect_value(t, node_get(&ui.tree, a).abs.w, (200 - gap) / 2)
	testing.expect_value(t, node_get(&ui.tree, b).abs.w, (200 - gap) / 2)
	rd := node_get(&ui.tree, r)
	bd := node_get(&ui.tree, b)
	testing.expect(t, bd.abs.x + bd.abs.w <= rd.abs.x + rd.abs.w + 0.5, "no overflow")
	// A flex field keeps its minimum; the oversized box takes the rest.
	testing.expect_value(t, node_get(&ui.tree, f).abs.w, TEXT_INPUT_MIN_WIDTH)
	testing.expect_value(t, node_get(&ui.tree, c).abs.w, 200 - gap - TEXT_INPUT_MIN_WIDTH)
	_ = r2
}

// A branch above that changes shape must not cost later siblings their nodes
// (and with them focus and editing state).
@(private = "file")
branch_view :: proc(ui: ^Ui(Ov_Msg), loaded: bool) -> (field: Node) {
	begin_view(ui)
	column(ui, gap = .sm)
	if loaded {
		box(ui, width = 200, height = 100)
	} else {
		row(ui, gap = .xs)
		spinner(ui, size = 14, label = "Loading")
		text(ui, "Loading")
		end(ui)
		text(ui, "a caption")
	}
	field = text_input(ui, nil, initial = "notes", label = "Name")
	button(ui, "Save", Ov_Msg{})
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	return
}

@(test)
reconcile_later_siblings_keep_their_nodes_when_a_branch_changes_shape :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	field := branch_view(&ui, false)
	set_focus(&ui.tree, field, true)
	text_event(&ui, "!")
	again := branch_view(&ui, true)
	testing.expect_value(t, again, field)
	testing.expect_value(t, ui.tree.focus, field)
	lo, hi := text_input_selection(&ui.tree, field)
	testing.expect(t, lo == len("!") && hi == lo, "the caret stayed where typing left it")
	testing.expect_value(t, branch_view(&ui, false), field) // and back
	testing.expect_value(t, ui.tree.focus, field)
}

// A key is not identity on its own: `Kind_Tag` is four values and `box`,
// `column`, `row`, `button` and `card` are all `.Box`, so a key alone would
// hand a `box`'s node to a `button`, which then skips the padding and role
// it gives itself only when it creates a node; and a `box` reused from a
// `column` would keep children it never built and, being a leaf, never
// sweep them.
//
// The builder is part of the identity, as it is in React, Flutter and
// SwiftUI. The two tests below are the two halves: a different builder gets
// a fresh node, and the same builder keeps its node (and its state) even
// when the call moves to another branch, which is half of what a key is for.

@(private = "file")
Rk_Msg :: union { int }

@(private = "file")
rk_pane :: proc(ui: ^Ui(Rk_Msg), as_button: bool) -> (n: Node) {
	begin_view(ui)
	column(ui)
	if as_button {
		n = button(ui, "Go", Rk_Msg(1), key = 7)
	} else {
		n = column(ui, key = 7, padding = .lg)
		text(ui, "what the column built")
		end(ui)
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 200})
	return
}

@(test)
one_key_does_not_hand_one_builders_node_to_another :: proc(t: ^testing.T) {
	ui: Ui(Rk_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	was := rk_pane(&ui, false)
	testing.expect(t, node_first(&ui.tree, was) != NODE_NONE, "the column built a child")

	now := rk_pane(&ui, true)
	testing.expect(t, now != was, "the button gets a node of its own")
	testing.expect(t, !node_valid(&ui.tree, was), "and the column's is swept")

	d := node_get(&ui.tree, now)
	testing.expect_value(t, d.access.role, Role.Button)             // the setup it only does when it creates one
	testing.expect(t, d.layout.padding.x > 0, "with the padding a button gives itself")
	kids := 0
	for c := node_first(&ui.tree, now); c != NODE_NONE; c = node_next(&ui.tree, c) do kids += 1
	testing.expect_value(t, kids, 1) // its own label, not the column's text
	testing.expect_value(t, d.builder, "button")
}

// …and the other half: the same builder, the same key, a different branch
// and so a different call site — that is a widget moving, not a widget
// changing, and it keeps its node, its focus and what was typed into it.
@(private = "file")
rk_field :: proc(ui: ^Ui(Rk_Msg), wide: bool) -> (field: Node) {
	begin_view(ui)
	column(ui)
	// Two call sites under the same parent: the app's branch, not a move
	// to another container (a widget that changes parent is a different
	// widget wherever it is built, here and in every toolkit that does
	// this).
	if wide {
		field = text_input(ui, nil, initial = "notes", label = "Name", key = 3, width = 300)
	} else {
		field = text_input(ui, nil, initial = "notes", label = "Name", key = 3)
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 200})
	return
}

@(test)
a_keyed_widget_keeps_its_node_when_the_call_moves :: proc(t: ^testing.T) {
	ui: Ui(Rk_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	field := rk_field(&ui, false)
	set_focus(&ui.tree, field, true)
	text_event(&ui, "!")

	again := rk_field(&ui, true)
	testing.expect_value(t, again, field)
	testing.expect_value(t, ui.tree.focus, field)
	lo, hi := text_input_selection(&ui.tree, field)
	testing.expect(t, lo == len("!") && hi == lo, "the caret stayed where typing left it")
}

// The check a person would do by hand in the gallery, done headlessly:
// leave a tab and come back, and find it as you left it. A `tab_panel` is
// parked rather than destroyed (`.Keep`), so its scroll offset, its focus
// and what was typed into it all live in nodes that must be *the same
// nodes* on the way back, and making the builder part of a node's identity
// is the kind of change that would quietly recreate them.
@(private = "file")
Rk_Tabs :: struct {
	panel, list, field: Node,
}

@(private = "file")
rk_tabs :: proc(ui: ^Ui(Rk_Msg), on_second: bool) -> (out: Rk_Tabs) {
	begin_view(ui)
	column(ui, flex = 1)
	tab_bar(ui, 1 if on_second else 0, {"Notes", "Shelf"}, nil)
	if tab_panel(ui, !on_second, key = 1) {
		out.panel = ui.scopes[len(ui.scopes) - 1].node
		out.field = text_input(ui, nil, initial = "notes", label = "Name", key = 2)
		out.list = scroll(ui, .Column, flex = 1, key = 3)
		for i in 0 ..< 40 do box(ui, height = 24, key = u64(i) + 10)
		end(ui)
		end(ui)
	}
	if tab_panel(ui, on_second, key = 4) {
		text(ui, "the other tab")
		end(ui)
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 300})
	return
}

@(test)
a_tab_comes_back_as_it_was_left :: proc(t: ^testing.T) {
	ui: Ui(Rk_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.motion.reduce = true

	first := rk_tabs(&ui, false)
	set_focus(&ui.tree, first.field, true)
	text_event(&ui, "!")
	scroll_by(&ui.tree, first.list, {0, 200})
	frame(&ui.tree, {400, 300})
	was := scroll_offset(&ui.tree, first.list)
	testing.expect(t, was.y > 0, "the list is scrolled")

	rk_tabs(&ui, true)  // away…
	back := rk_tabs(&ui, false) // …and back

	testing.expect_value(t, back.list, first.list)   // the same nodes, not new ones
	testing.expect_value(t, back.field, first.field)
	testing.expect_value(t, scroll_offset(&ui.tree, back.list), was)
	lo, hi := text_input_selection(&ui.tree, back.field)
	testing.expect(t, lo == len("!") && hi == lo, "and the caret is where typing left it")
}

}
