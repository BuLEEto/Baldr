package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

Tr_Kind :: enum { Pick, Open, Act }
Tr_Msg :: struct {
	kind: Tr_Kind,
	i:    int,
	on:   bool,
}

@(private = "file")
on_open :: proc(e: Ev(bool)) -> Tr_Msg { return {kind = .Open, i = int(e.tag), on = e.value} }

// src ▸ ui ▸ button.odin, src ▸ main.odin, README.md
@(private = "file")
tree_fixture :: proc(ui: ^Ui(Tr_Msg), open: [3]bool, sel: int) -> (tree: Node) {
	set_viewport(&ui.tree, {300, 400})
	begin_view(ui)
	column(ui)
	tree = tree_view(ui, label = "Project", flex = 1)
	if tree_item(ui, "src", Tr_Msg{kind = .Pick, i = 1}, expanded = open[1], on_change = on_open, selected = sel == 1, icon = .Folder, tag = 1, key = 1) {
		if tree_item(ui, "ui", Tr_Msg{kind = .Pick, i = 2}, expanded = open[2], on_change = on_open, selected = sel == 2, icon = .Folder, tag = 2, key = 2) {
			tree_item(ui, "button.odin", Tr_Msg{kind = .Pick, i = 3}, selected = sel == 3, icon = .File_Code, on_activate = Tr_Msg{kind = .Act, i = 3}, key = 3)
			end(ui)
		}
		tree_item(ui, "main.odin", Tr_Msg{kind = .Pick, i = 4}, selected = sel == 4, icon = .File_Code, key = 4)
		end(ui)
	}
	tree_item(ui, "README.md", Tr_Msg{kind = .Pick, i = 5}, selected = sel == 5, key = 5)
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {300, 400})
	return
}

@(private = "file")
take :: proc(ui: ^Ui(Tr_Msg)) -> []Tr_Msg {
	out := make([]Tr_Msg, len(ui.msgs), context.temp_allocator)
	copy(out, ui.msgs[:])
	clear(&ui.msgs)
	return out
}

@(private = "file")
center :: proc(ui: ^Ui(Tr_Msg), n: Node) -> [2]f32 {
	r := node_get(&ui.tree, n).abs
	return {r.x + r.w / 2, r.y + r.h / 2}
}

// Only expanded branches contribute rows; each level is indented; the a11y
// tree says which rows are branches and whether they are open.
@(test)
tree_view_builds_visible_rows_with_depth_and_a11y :: proc(t: ^testing.T) {
	ui: Ui(Tr_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tree := tree_fixture(&ui, {false, true, false}, 4)
	rows := tree_rows_in_order(&ui.tree, tree)
	testing.expect_value(t, len(rows), 4) // src, ui, main.odin, README.md
	names := make([dynamic]string, context.temp_allocator)
	for r in rows do append(&names, node_get(&ui.tree, r).access.name)
	testing.expect_value(t, strings.join(names[:], ",", context.temp_allocator), "src,ui,main.odin,README.md")
	testing.expect_value(t, ui.tree.tree_rows[rows[0]].depth, 0)
	testing.expect_value(t, ui.tree.tree_rows[rows[1]].depth, 1)
	testing.expect_value(t, ui.tree.tree_rows[rows[3]].depth, 0)
	x0 := node_get(&ui.tree, rows[0]).abs.x
	testing.expect_value(t, node_get(&ui.tree, rows[1]).abs.x, x0 + TREE_INDENT)
	testing.expect(t, node_get(&ui.tree, rows[1]).abs.y > node_get(&ui.tree, rows[0]).abs.y, "children come below their branch")
	dump := access_dump(&ui.tree)
	testing.expect(t, strings.contains(dump, "Tree \"Project\""), dump)
	testing.expect(t, strings.contains(dump, "Tree_Item \"src\"") && strings.contains(dump, "Expanded"), dump)
	testing.expect(t, strings.contains(dump, "Tree_Item \"ui\"") && strings.contains(dump, "Collapsed"), dump)
	testing.expect(t, !strings.contains(dump, "button.odin"), "a collapsed branch's children are not built")
	testing.expect(t, strings.contains(dump, "Tree_Item \"main.odin\"") && strings.contains(dump, "Selected"), dump)
	testing.expect(t, !strings.contains(dump, "Text \"src\""), "labels are not separate a11y nodes")
	// the tree is one Tab stop; rows are not
	testing.expect(t, .Focusable in node_get(&ui.tree, tree).flags)
	testing.expect(t, .Focusable not_in node_get(&ui.tree, rows[0]).flags)
}

// A click on a row selects it (on_click) and moves the cursor; a click on
// the chevron toggles the branch (on_change with the item's tag); a second
// click on a row within the double-click time activates it.
@(test)
tree_view_click_selects_chevron_toggles_double_click_activates :: proc(t: ^testing.T) {
	ui: Ui(Tr_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tree := tree_fixture(&ui, {false, true, true}, 0)
	rows := tree_rows_in_order(&ui.tree, tree)
	testing.expect_value(t, len(rows), 5)
	ui.tree.now_ms = 1000
	p := center(&ui, rows[1]) // "ui"
	pointer_button(&ui, .Left, true, p)
	pointer_button(&ui, .Left, false, p)
	got := take(&ui)
	testing.expect_value(t, len(got), 1)
	testing.expect_value(t, got[0], Tr_Msg{kind = .Pick, i = 2})
	testing.expect_value(t, ui.tree.focus, tree)
	testing.expect_value(t, ui.tree.tree_views[tree].cursor, rows[1])
	// the chevron of "ui" (expanded): collapse
	chev := ui.tree.tree_rows[rows[1]].chevron
	cp := center(&ui, chev)
	ui.tree.now_ms = 3000
	pointer_button(&ui, .Left, true, cp)
	pointer_button(&ui, .Left, false, cp)
	got = take(&ui)
	testing.expect_value(t, len(got), 1)
	testing.expect_value(t, got[0], Tr_Msg{kind = .Open, i = 2, on = false})
	// double-click on button.odin activates
	bp := center(&ui, rows[2])
	ui.tree.now_ms = 5000
	pointer_button(&ui, .Left, true, bp)
	pointer_button(&ui, .Left, false, bp)
	ui.tree.now_ms = 5200
	pointer_button(&ui, .Left, true, bp)
	pointer_button(&ui, .Left, false, bp)
	got = take(&ui)
	testing.expect_value(t, len(got), 2)
	testing.expect_value(t, got[0], Tr_Msg{kind = .Pick, i = 3})
	testing.expect_value(t, got[1], Tr_Msg{kind = .Act, i = 3})
	// a leaf has no chevron; its slot keeps labels aligned
	testing.expect_value(t, ui.tree.tree_rows[rows[2]].chevron, NODE_NONE)
}

// Keyboard: Down / Up move the cursor and select, Right expands or steps
// in, Left collapses or steps out, Home / End, Enter activates, Space selects.
@(test)
tree_view_keyboard_moves_expands_and_collapses :: proc(t: ^testing.T) {
	ui: Ui(Tr_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	open := [3]bool{false, true, false}
	tree := tree_fixture(&ui, open, 0)
	set_focus(&ui.tree, tree, true)
	rows := tree_rows_in_order(&ui.tree, tree)
	testing.expect(t, key_event(&ui, .Down, true, {}), "Down is the tree's")
	testing.expect_value(t, ui.tree.tree_views[tree].cursor, rows[0])
	testing.expect_value(t, take(&ui)[0], Tr_Msg{kind = .Pick, i = 1})
	key_event(&ui, .Down, true, {})
	testing.expect_value(t, take(&ui)[0], Tr_Msg{kind = .Pick, i = 2}) // "ui", collapsed
	key_event(&ui, .Right, true, {})
	testing.expect_value(t, take(&ui)[0], Tr_Msg{kind = .Open, i = 2, on = true})
	open[2] = true
	tree_fixture(&ui, open, 2) // the app expanded it; the cursor row survives the rebuild
	rows = tree_rows_in_order(&ui.tree, tree)
	testing.expect_value(t, len(rows), 5)
	testing.expect_value(t, ui.tree.tree_views[tree].cursor, rows[1])
	key_event(&ui, .Right, true, {}) // expanded: step into the first child
	testing.expect_value(t, ui.tree.tree_views[tree].cursor, rows[2])
	testing.expect_value(t, take(&ui)[0], Tr_Msg{kind = .Pick, i = 3})
	key_event(&ui, .Left, true, {}) // a leaf: back to the parent
	testing.expect_value(t, ui.tree.tree_views[tree].cursor, rows[1])
	testing.expect_value(t, take(&ui)[0], Tr_Msg{kind = .Pick, i = 2})
	key_event(&ui, .Left, true, {}) // an open branch: collapse
	testing.expect_value(t, take(&ui)[0], Tr_Msg{kind = .Open, i = 2, on = false})
	key_event(&ui, .End, true, {})
	testing.expect_value(t, take(&ui)[0], Tr_Msg{kind = .Pick, i = 5})
	key_event(&ui, .Home, true, {})
	testing.expect_value(t, take(&ui)[0], Tr_Msg{kind = .Pick, i = 1})
	key_event(&ui, .Page_Down, true, {}) // no scroll here: a page is the whole tree
	testing.expect_value(t, take(&ui)[0], Tr_Msg{kind = .Pick, i = 5})
	key_event(&ui, .Page_Up, true, {})
	testing.expect_value(t, take(&ui)[0], Tr_Msg{kind = .Pick, i = 1})
	key_event(&ui, .Up, true, {}) // stays on the first row
	testing.expect_value(t, ui.tree.tree_views[tree].cursor, rows[0])
	clear(&ui.msgs)
	key_event(&ui, .Space, true, {})
	testing.expect_value(t, take(&ui)[0], Tr_Msg{kind = .Pick, i = 1})
	key_event(&ui, .Down, true, {})
	key_event(&ui, .Down, true, {}) // button.odin
	clear(&ui.msgs)
	key_event(&ui, .Enter, true, {})
	testing.expect_value(t, take(&ui)[0], Tr_Msg{kind = .Act, i = 3})
	// focus stays on the tree throughout; Tab leaves it as one stop
	testing.expect_value(t, ui.tree.focus, tree)
}

// The cursor ring and one guide per ancestor level are painted; rows grow
// to the touch target when a touchscreen is present.
@(test)
tree_view_paints_guides_and_cursor_ring_and_grows_for_touch :: proc(t: ^testing.T) {
	ui: Ui(Tr_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tree := tree_fixture(&ui, {false, true, true}, 0)
	rows := tree_rows_in_order(&ui.tree, tree)
	set_focus(&ui.tree, tree, true)
	key_event(&ui, .Down, true, {})
	frame(&ui.tree, {300, 400})
	cursor := node_get(&ui.tree, rows[0]).abs
	ring_found, guides := false, 0
	for _, l in ui.tree.layers do for c in l.cmds {
		if r, ok := c.(Draw_Rect); ok {
			if r.border_w == 2 && r.border == ui.theme.color.focus_ring && r.rect == cursor do ring_found = true
			if r.rect.w == 1 && r.color.a > 0 && r.border_w == 0 && r.rect.h > 20 do guides += 1
		}
	}
	testing.expect(t, ring_found, "the cursor row shows the focus ring")
	// ui (1 level), button.odin (2 levels), main.odin (1 level) = 4 guide segments
	testing.expect_value(t, guides, 4)
	h := node_get(&ui.tree, rows[0]).abs.h
	testing.expect(t, h >= TREE_ROW_MIN_H && h < TOUCH_TARGET, "desktop rows are compact")
	set_touch(&ui.tree, true)
	tree_fixture(&ui, {false, true, true}, 0)
	testing.expect(t, node_get(&ui.tree, rows[0]).abs.h >= TOUCH_TARGET, "touch rows reach the target size")
}

} // when ODIN_TEST