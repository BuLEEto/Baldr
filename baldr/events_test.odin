package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: about 9 GB without this `when`, 1 GB with it.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
counter :: proc(ui: ^Ui(Test_Msg)) -> (minus, plus: Node) {
	begin_view(ui)
	column(ui, gap = .md, padding = .lg)
	text(ui, "Count")
	row(ui, gap = .sm)
	minus = button(ui, "-", Test_Msg.Dec)
	plus = button(ui, "+", Test_Msg.Inc)
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 300})
	return
}

@(private = "file")
center :: proc(t: ^Tree, n: Node) -> [2]f32 {
	r := node_get(t, n).abs
	return {r.x + r.w / 2, r.y + r.h / 2}
}

@(test)
events_hover_sets_flag_and_dirties_only_that_node :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	_, plus := counter(&ui)
	take_damage(&ui.tree)

	testing.expect(t, pointer_move(&ui, center(&ui.tree, plus)), "hover change reported")
	testing.expect(t, .Hovered in node_get(&ui.tree, plus).flags)
	testing.expect_value(t, ui.pointer.hover, plus)
	testing.expect(t, !pointer_move(&ui, center(&ui.tree, plus) + {1, 1}), "same target: no change")

	ui.stats = {}
	frame(&ui.tree, {400, 300})
	testing.expect_value(t, ui.stats.layout_nodes, 0)
	testing.expect_value(t, damage_bounds(take_damage(&ui.tree)), paint_bounds(node_get(&ui.tree, plus))) // includes its shadow

	testing.expect(t, pointer_move(&ui, {1, 1}), "moving to empty space clears hover")
	testing.expect_value(t, ui.pointer.hover, NODE_NONE)
	testing.expect(t, .Hovered not_in node_get(&ui.tree, plus).flags)
}

@(test)
events_click_is_press_and_release_on_same_node :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	minus, plus := counter(&ui)

	p := center(&ui.tree, plus)
	pointer_button(&ui, .Left, true, p)
	testing.expect(t, .Pressed in node_get(&ui.tree, plus).flags)
	testing.expect_value(t, len(ui.msgs), 0)
	pointer_button(&ui, .Left, false, p)
	testing.expect(t, .Pressed not_in node_get(&ui.tree, plus).flags)
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0], Test_Msg.Inc)

	// Press on +, drag off, release elsewhere: no message.
	clear(&ui.msgs)
	pointer_button(&ui, .Left, true, p)
	pointer_move(&ui, center(&ui.tree, minus))
	testing.expect(t, .Pressed not_in node_get(&ui.tree, plus).flags, "press feedback lifts while off the node")
	pointer_button(&ui, .Left, false, center(&ui.tree, minus))
	testing.expect_value(t, len(ui.msgs), 0)

	// Right button never clicks.
	pointer_button(&ui, .Right, true, p)
	pointer_button(&ui, .Right, false, p)
	testing.expect_value(t, len(ui.msgs), 0)
}

@(test)
events_disabled_nodes_are_not_targets :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	b := button(&ui, "Nope", Test_Msg.Inc, disabled = true)
	end_view(&ui)
	frame(&ui.tree, {200, 100})
	p := center(&ui.tree, b)
	pointer_button(&ui, .Left, true, p)
	pointer_button(&ui, .Left, false, p)
	testing.expect_value(t, len(ui.msgs), 0)
	testing.expect_value(t, ui.pointer.hover, NODE_NONE)
	testing.expect_value(t, cursor_for(&ui), Cursor.Default)
}

@(test)
events_hit_test_prefers_topmost_sibling :: proc(t: ^testing.T) {
	tr: Tree
	tree_init(&tr)
	defer tree_destroy(&tr)
	a := node_new(&tr, Box_Kind{})
	node_get(&tr, a).layout = {width = 100, height = 100}
	b := node_new(&tr, Box_Kind{})
	node_get(&tr, b).layout = {width = 100, height = 100}
	node_append(&tr, tr.root, a)
	node_append(&tr, tr.root, b) // the root is a Column, so b sits below a
	node_get(&tr, tr.root).layout = {axis = .Column}
	layout(&tr, {200, 300})
	testing.expect_value(t, hit_test(&tr, {50, 50}), a)
	testing.expect_value(t, hit_test(&tr, {50, 150}), b)
	testing.expect_value(t, hit_test(&tr, {150, 250}), tr.root)
	testing.expect_value(t, hit_test(&tr, {500, 500}), NODE_NONE)
}

} // when ODIN_TEST