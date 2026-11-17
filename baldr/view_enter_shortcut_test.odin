package baldr

@(require) import "core:fmt"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Enter yields a chord the app bound with `shortcut` (a file manager's
// Alt+Enter for Properties) instead of activating the item, exactly as
// Space does, in all three item views; and a view with nothing to activate
// declines Enter rather than swallowing it, so it goes on to the window's
// shortcuts and to a dialog's default button.

@(private = "file")
VE_COLS := []Column{
	{title = "Name", sortable = true},
	{title = "Size", width = 80, numeric = true},
}

@(private = "file")
ve_table_view :: proc(ui: ^Ui(Ov_Msg), sel: ^Selection, bind: string) -> Node {
	set_viewport(&ui.tree, {500, 300})
	begin_view(ui)
	if bind != "" do shortcut(ui, bind, Ov_Msg{kind = .Close_Pop})
	column(ui, flex = 1)
	first, last := table(ui, VE_COLS, 40, sel,
		on_select = proc(e: Ev(int)) -> Ov_Msg { return {kind = .Pick, i = e.value} },
		on_activate = proc(e: Ev(int)) -> Ov_Msg { return {kind = .Delete, i = e.value} },
		label = "Files", key = 1)
	for i in first ..< last {
		table_row(ui, i)
		cell_text(ui, fmt.tprintf("file-%02d", i))
		cell_text(ui, fmt.tprintf("%d KB", i))
		end(ui)
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {500, 300})
	return node_first(&ui.tree, node_first(&ui.tree, ui.root))
}

@(private = "file")
ve_table_settled :: proc(ui: ^Ui(Ov_Msg), sel: ^Selection, bind: string) -> Node {
	n := ve_table_view(ui, sel, bind)
	for _ in 0 ..< 3 {
		ui.needs_rebuild = false
		ui_after_events(ui, 1)
		if !ui.needs_rebuild do break
		ui.needs_rebuild = false
		n = ve_table_view(ui, sel, bind)
	}
	clear(&ui.msgs)
	return n
}

// The same table with no on_activate: rows you pick from rather than open.
@(private = "file")
ve_table_inert_view :: proc(ui: ^Ui(Ov_Msg), sel: ^Selection) -> Node {
	set_viewport(&ui.tree, {500, 300})
	begin_view(ui)
	column(ui, flex = 1)
	first, last := table(ui, VE_COLS, 40, sel,
		on_select = proc(e: Ev(int)) -> Ov_Msg { return {kind = .Pick, i = e.value} },
		label = "Files", key = 1)
	for i in first ..< last {
		table_row(ui, i)
		cell_text(ui, fmt.tprintf("file-%02d", i))
		cell_text(ui, fmt.tprintf("%d KB", i))
		end(ui)
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {500, 300})
	return node_first(&ui.tree, node_first(&ui.tree, ui.root))
}

@(private = "file")
ve_table_inert_settled :: proc(ui: ^Ui(Ov_Msg), sel: ^Selection) -> Node {
	n := ve_table_inert_view(ui, sel)
	for _ in 0 ..< 3 {
		ui.needs_rebuild = false
		ui_after_events(ui, 1)
		if !ui.needs_rebuild do break
		ui.needs_rebuild = false
		n = ve_table_inert_view(ui, sel)
	}
	clear(&ui.msgs)
	return n
}

@(private = "file")
ve_grid_view :: proc(ui: ^Ui(Ov_Msg), sel: ^Selection, bind: string) -> Node {
	set_viewport(&ui.tree, {500, 300})
	begin_view(ui)
	if bind != "" do shortcut(ui, bind, Ov_Msg{kind = .Close_Pop})
	column(ui, flex = 1)
	first, last := icon_view(ui, 40, sel,
		on_select = proc(e: Ev(int)) -> Ov_Msg { return {kind = .Pick, i = e.value} },
		on_activate = proc(e: Ev(int)) -> Ov_Msg { return {kind = .Delete, i = e.value} },
		label = "Files", key = 2)
	for i in first ..< last do icon_item(ui, i, .File, fmt.tprintf("file-%02d", i))
	end(ui)
	end_view(ui)
	frame(&ui.tree, {500, 300})
	return node_first(&ui.tree, node_first(&ui.tree, ui.root))
}

@(private = "file")
ve_grid_settled :: proc(ui: ^Ui(Ov_Msg), sel: ^Selection, bind: string) -> Node {
	n := ve_grid_view(ui, sel, bind)
	for _ in 0 ..< 3 {
		ui.needs_rebuild = false
		ui_after_events(ui, 1)
		if !ui.needs_rebuild do break
		ui.needs_rebuild = false
		n = ve_grid_view(ui, sel, bind)
	}
	clear(&ui.msgs)
	return n
}

@(private = "file")
ve_tree_build :: proc(ui: ^Ui(Ov_Msg), bind: string) -> Node {
	set_viewport(&ui.tree, {300, 400})
	begin_view(ui)
	column(ui, flex = 1)
	if bind != "" do shortcut(ui, bind, Ov_Msg{kind = .Close_Pop})
	tree := tree_view(ui, label = "Project", flex = 1)
	tree_item(ui, "notes.md", Ov_Msg{kind = .Pick, i = 1},
		on_activate = proc(e: Ev(int)) -> Ov_Msg { return {kind = .Delete, i = 1} }, key = 1)
	tree_item(ui, "main.odin", Ov_Msg{kind = .Pick, i = 2},
		on_activate = proc(e: Ev(int)) -> Ov_Msg { return {kind = .Delete, i = 2} }, key = 2)
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {300, 400})
	clear(&ui.msgs)
	return tree
}

// ve_cursor_home puts the cursor on the first item, as End / Home do, and
// drops the selection message that follows it.
@(private = "file")
ve_cursor_home :: proc(t: ^testing.T, ui: ^Ui(Ov_Msg)) {
	testing.expect(t, key_event(ui, .Home, true, {}), "Home moves the cursor to the first item")
	clear(&ui.msgs)
}

@(test)
a_table_leaves_a_bound_alt_enter_to_the_app :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	tbl := ve_table_settled(&ui, &sel, "Alt+Enter")
	set_focus(&ui.tree, tbl, true)
	ve_cursor_home(t, &ui)

	// Alt+Enter is Properties: the table must not open the row with it.
	testing.expect(t, !key_event(&ui, .Enter, true, {.Alt}), "the table declines the chord the app bound")
	testing.expect_value(t, len(ui.msgs), 0)
	testing.expect(t, shortcut_fire(&ui, .Enter, true, {.Alt}), "…so the window's own shortcut fires")
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0].kind, Ov_Kind.Close_Pop)
	clear(&ui.msgs)

	// Plain Enter still opens the row it is on.
	testing.expect(t, key_event(&ui, .Enter, true, {}), "plain Enter is the table's")
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0].kind, Ov_Kind.Delete)
	testing.expect_value(t, ui.msgs[0].i, 0)
}

// Space yields a plain Space the app bound (Quick Look), and
// Enter reads the same way: what the app bound is the app's, modifiers or
// none. An app that wants Enter for itself *and* rows that open on Enter
// binds a chord instead.
@(test)
a_table_leaves_a_bound_plain_enter_to_the_app :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	tbl := ve_table_settled(&ui, &sel, "Enter")
	set_focus(&ui.tree, tbl, true)
	ve_cursor_home(t, &ui)
	testing.expect(t, !key_event(&ui, .Enter, true, {}), "the app bound Enter, so Enter is the app's")
	testing.expect_value(t, len(ui.msgs), 0)
	testing.expect(t, shortcut_fire(&ui, .Enter, true, {}))
	testing.expect_value(t, ui.msgs[0].kind, Ov_Kind.Close_Pop)
}

// A view with no on_activate has nothing to do with Enter, so it declines
// it: the key reaches the window's shortcuts, and a dialog's default
// button.
@(test)
a_table_with_nothing_to_open_declines_enter :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	tbl := ve_table_inert_settled(&ui, &sel)
	set_focus(&ui.tree, tbl, true)
	ve_cursor_home(t, &ui)
	testing.expect(t, !key_event(&ui, .Enter, true, {}), "nothing to open: Enter is not the table's")
	testing.expect_value(t, len(ui.msgs), 0)
	// …and the keys it does use are untouched.
	testing.expect(t, key_event(&ui, .Down, true, {}))
	testing.expect_value(t, sel.cursor, 1)
}

@(test)
an_icon_view_leaves_a_bound_alt_enter_to_the_app :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	view := ve_grid_settled(&ui, &sel, "Alt+Enter")
	set_focus(&ui.tree, view, true)
	ve_cursor_home(t, &ui)
	testing.expect(t, !key_event(&ui, .Enter, true, {.Alt}), "the icon view declines the chord the app bound")
	testing.expect_value(t, len(ui.msgs), 0)
	testing.expect(t, shortcut_fire(&ui, .Enter, true, {.Alt}))
	testing.expect_value(t, ui.msgs[0].kind, Ov_Kind.Close_Pop)
	clear(&ui.msgs)
	testing.expect(t, key_event(&ui, .Enter, true, {}), "plain Enter is the view's")
	testing.expect_value(t, ui.msgs[0].kind, Ov_Kind.Delete)
	testing.expect_value(t, ui.msgs[0].i, 0)
}

@(test)
a_tree_leaves_a_bound_alt_enter_to_the_app :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tree := ve_tree_build(&ui, "Alt+Enter")
	set_focus(&ui.tree, tree, true)
	ve_cursor_home(t, &ui)
	testing.expect(t, !key_event(&ui, .Enter, true, {.Alt}), "the tree declines the chord the app bound")
	testing.expect_value(t, len(ui.msgs), 0)
	testing.expect(t, shortcut_fire(&ui, .Enter, true, {.Alt}))
	testing.expect_value(t, ui.msgs[0].kind, Ov_Kind.Close_Pop)
	clear(&ui.msgs)
	testing.expect(t, key_event(&ui, .Enter, true, {}), "plain Enter is the tree's")
	testing.expect_value(t, ui.msgs[0].kind, Ov_Kind.Delete)
	testing.expect_value(t, ui.msgs[0].i, 1)
}

}
