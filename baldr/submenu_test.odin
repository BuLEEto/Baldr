package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
sub_view :: proc(ui: ^Ui(Ov_Msg), open: bool) -> (anchor: Node) {
	begin_view(ui)
	column(ui, padding = .lg, gap = .md)
	anchor = button(ui, "Actions", Ov_Msg{kind = .None})
	if menu(ui, anchor, open, Ov_Msg{kind = .Close_Pop}) {
		menu_item(ui, "Rename", Ov_Msg{kind = .None}, shortcut = "F2")
		if submenu(ui, "Sort by") {
			menu_item(ui, "Name", Ov_Msg{kind = .Pick, i = 1}, checked = true, radio = true)
			menu_item(ui, "Size", Ov_Msg{kind = .Pick, i = 2}, checked = false, radio = true)
			end(ui)
		}
		menu_item(ui, "Delete", Ov_Msg{kind = .Delete}, shortcut = "Del")
		end(ui)
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	return
}

// menu_parts: the root menu (the overlay child holding the "Sort by" row),
// that row, and the submenu popup (or NONE). Overlay children are not in
// opening order, so they are told apart by content.
@(private = "file")
menu_parts :: proc(ui: ^Ui(Ov_Msg)) -> (m, row, pop: Node) {
	t := &ui.tree
	m, row, pop = NODE_NONE, NODE_NONE, NODE_NONE
	for c := node_first(t, t.overlay); c != NODE_NONE; c = node_next(t, c) {
		if .Exiting in node_get(t, c).flags do continue // a closed popup fading out
		found := false
		for item := node_first(t, c); item != NODE_NONE; item = node_next(t, item) {
			if node_get(t, item).access.name == "Sort by" {
				m, row, found = c, item, true
				break
			}
		}
		if !found do pop = c
	}
	return
}

@(test)
submenu_opens_from_the_keyboard_and_closes_back_to_its_row :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	anchor := sub_view(&ui, false)
	set_focus(&ui.tree, anchor, true) // a keyboard user: Tab reaches the button, Enter opens the menu
	sub_view(&ui, true)
	m, row, pop := menu_parts(&ui)
	testing.expect_value(t, node_get(&ui.tree, row).access.name, "Sort by")
	testing.expect_value(t, pop, NODE_NONE)
	testing.expect(t, .Collapsed in node_get(&ui.tree, row).access.states)
	testing.expect(t, key_event(&ui, .Down, true, {}), "Down reaches the row")
	testing.expect_value(t, ui.tree.focus, row)
	testing.expect(t, key_event(&ui, .Right, true, {}), "Right opens it")
	testing.expect(t, ui.open[row] && ui.needs_rebuild, "self-managed: open and rebuild")
	ui.needs_rebuild = false
	sub_view(&ui, true)
	m, row, pop = menu_parts(&ui)
	testing.expect(t, pop != NODE_NONE, "the popup is a second overlay child")
	pd := node_get(&ui.tree, pop)
	testing.expect_value(t, pd.access.role, Role.Menu)
	testing.expect(t, .Expanded in node_get(&ui.tree, row).access.states)
	rd := node_get(&ui.tree, row)
	testing.expect(t, pd.abs.x >= rd.abs.x + rd.abs.w - 8 && pd.abs.x > rd.abs.x + rd.abs.w / 2, "beside the row, to the right")
	first := node_first(&ui.tree, pop)
	testing.expect_value(t, node_get(&ui.tree, first).abs.y, rd.abs.y) // its first item level with the row
	testing.expect_value(t, ui.tree.focus, first) // keyboard-opened: focus went in
	testing.expect(t, .Checked in node_get(&ui.tree, first).access.states, "Name is the checked radio")
	testing.expect(t, .Checked not_in node_get(&ui.tree, node_next(&ui.tree, first)).access.states)
	testing.expect(t, lint(&ui.tree) == 0)

	testing.expect(t, key_event(&ui, .Left, true, {}), "Left closes the submenu")
	testing.expect(t, !ui.open[row])
	testing.expect_value(t, ui.tree.focus, row)
	ui.needs_rebuild = false
	sub_view(&ui, true)
	_, _, pop = menu_parts(&ui)
	testing.expect_value(t, pop, NODE_NONE)
	testing.expect_value(t, len(ui.msgs), 0) // nothing reached the app: the submenu is the widget's own state
}

@(test)
submenu_item_closes_the_whole_chain :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	anchor := sub_view(&ui, false)
	set_focus(&ui.tree, anchor, true) // opened from the keyboard
	sub_view(&ui, true)
	key_event(&ui, .Down, true, {})
	key_event(&ui, .Right, true, {})
	ui.needs_rebuild = false
	sub_view(&ui, true)
	_, row, pop := menu_parts(&ui)
	testing.expect(t, pop != NODE_NONE)
	testing.expect(t, key_event(&ui, .Down, true, {}), "Down to Size")
	testing.expect(t, key_event(&ui, .Enter, true, {}), "Enter picks it")
	testing.expect_value(t, len(ui.msgs), 2)
	testing.expect(t, ui.msgs[0].kind == .Pick && ui.msgs[0].i == 2, "the item's message")
	testing.expect_value(t, ui.msgs[1].kind, Ov_Kind.Close_Pop) // and the root menu's dismiss
	testing.expect(t, !ui.open[row], "the submenu is closed too")
}

@(test)
submenu_opens_when_the_pointer_rests_and_closes_on_a_sibling :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sub_view(&ui, false)
	sub_view(&ui, true)
	m, row, _ := menu_parts(&ui)
	ui.pointer.inside = true
	ui.pointer.hover = node_first(&ui.tree, row) // the label inside the row counts as the row
	submenu_tick(&ui, 0)
	testing.expect(t, !ui.open[row], "not at once")
	submenu_tick(&ui, 100)
	testing.expect(t, !ui.open[row], "still resting")
	submenu_tick(&ui, 200)
	testing.expect(t, ui.open[row], "open after the pause")
	testing.expect_value(t, ui.tree.focus, node_first(&ui.tree, m)) // pointer-opened: focus stayed
	ui.needs_rebuild = false
	sub_view(&ui, true)
	pop: Node
	_, row, pop = menu_parts(&ui)
	testing.expect(t, pop != NODE_NONE)
	// a press inside the submenu is inside the menu: nothing dismisses
	pd := node_get(&ui.tree, pop)
	testing.expect(t, !dismiss_outside(&ui, {pd.abs.x + 4, pd.abs.y + 4}))
	// resting on Delete (a sibling of the row) closes the submenu
	del := node_get(&ui.tree, m).last
	ui.pointer.hover = del
	submenu_tick(&ui, 300)
	testing.expect(t, ui.open[row], "not yet")
	submenu_tick(&ui, 600)
	testing.expect(t, !ui.open[row], "closed after the pause on a sibling")
	// a press far away closes everything
	testing.expect(t, dismiss_outside(&ui, {590, 390}))
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0].kind, Ov_Kind.Close_Pop)
}

} // when ODIN_TEST