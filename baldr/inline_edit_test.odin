package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: behind this `when`, checking a program costs
// 1.0 GB instead of 9.2 GB. ODIN_TEST is set by `odin test`; BALDR_TESTS
// lets ./build.sh check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
EMsg :: struct { kind: enum { None, Edit, Submit, Cancel, Activate }, row, col: int, text: string }

@(private = "file")
files_table :: proc(ui: ^Ui(EMsg), sel: ^Selection, editing: Cell_Ref) -> (tbl: Node, editor: Node) {
	set_viewport(&ui.tree, {600, 400})
	begin_view(ui)
	column(ui, flex = 1)
	cols := []Column{{title = "Name"}, {title = "Size", width = 100}}
	first, last := table(ui, cols, 50, sel,
		on_activate = proc(e: Ev(int)) -> EMsg { return {kind = .Activate, row = e.value} },
		on_edit = proc(e: Ev(Cell_Ref)) -> EMsg { return {kind = .Edit, row = e.value.row, col = e.value.col} },
		label = "Files", key = 3)
	for i in first ..< last {
		table_row(ui, i)
		if editing == (Cell_Ref{i, 0}) {
			editor = cell_edit(ui, "Report-final.txt", proc(e: Ev(string)) -> EMsg { return {kind = .Submit, row = int(e.tag), text = e.value} }, on_cancel = EMsg{kind = .Cancel})
		} else {
			cell_text(ui, "Report-final.txt")
		}
		if editing == (Cell_Ref{i, 1}) {
			editor = cell_edit(ui, "12", proc(e: Ev(string)) -> EMsg { return {kind = .Submit, row = int(e.tag), col = 1, text = e.value} }, select_stem = false)
		} else {
			cell_text(ui, "12 KB")
		}
		end(ui)
	}
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	tbl = node_first(&ui.tree, node_first(&ui.tree, ui.root))
	return
}

@(test)
inline_edit_f2_asks_the_app_for_the_cursor_row :: proc(t: ^testing.T) {
	ui: Ui(EMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	tbl, _ := files_table(&ui, &sel, {-1, -1})
	set_focus(&ui.tree, tbl, true)
	testing.expect(t, !key_event(&ui, .F2, true, {}), "no cursor row yet: nothing to edit")
	key_event(&ui, .Down, true, {}) // cursor on row 0
	clear(&ui.msgs)
	testing.expect(t, key_event(&ui, .F2, true, {}))
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect(t, ui.msgs[0].kind == .Edit && ui.msgs[0].row == 0 && ui.msgs[0].col == 0, "F2 asks for the cursor row's first cell")
}

@(test)
inline_edit_focuses_selects_the_stem_and_commits_on_enter :: proc(t: ^testing.T) {
	ui: Ui(EMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	_, editor := files_table(&ui, &sel, {2, 0})
	testing.expect(t, editor != NODE_NONE)
	field := node_first(&ui.tree, editor)
	testing.expect_value(t, ui.tree.focus, field)
	lo, hi := text_input_selection(&ui.tree, field)
	testing.expect(t, lo == 0 && hi == len("Report-final"), "the name is selected up to its extension")
	text_event(&ui, "Notes") // typing replaces the selection
	testing.expect(t, key_event(&ui, .Enter, true, {}))
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect(t, ui.msgs[0].kind == .Submit && ui.msgs[0].row == 2 && ui.msgs[0].text == "Notes.txt", "Enter commits the new name for the row")
	testing.expect(t, key_event(&ui, .Enter, true, {}), "still consumed…")
	testing.expect_value(t, len(ui.msgs), 1) // …but it fires once
	ui_after_events(&ui, 1)
	testing.expect_value(t, len(ui.msgs), 1) // and losing nothing on the next tick
}

@(test)
inline_edit_escape_cancels_and_blur_commits :: proc(t: ^testing.T) {
	ui: Ui(EMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	tbl, editor := files_table(&ui, &sel, {1, 0})
	testing.expect(t, key_event(&ui, .Escape, true, {}))
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0].kind, type_of(ui.msgs[0].kind).Cancel)
	// a fresh editor whose focus moves elsewhere commits when the loop ticks
	clear(&ui.msgs)
	_, editor = files_table(&ui, &sel, {-1, -1})
	_, editor = files_table(&ui, &sel, {3, 1})
	field := node_first(&ui.tree, editor)
	lo, hi := text_input_selection(&ui.tree, field)
	testing.expect(t, lo == 0 && hi == 2, "select_stem = false selects it all")
	set_focus(&ui.tree, tbl, true)
	ui_after_events(&ui, 1)
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect(t, ui.msgs[0].kind == .Submit && ui.msgs[0].row == 3 && ui.msgs[0].col == 1 && ui.msgs[0].text == "12", "leaving the field commits")
}

@(test)
inline_edit_tab_commits_and_asks_for_the_next_cell :: proc(t: ^testing.T) {
	ui: Ui(EMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	files_table(&ui, &sel, {4, 0})
	testing.expect(t, key_event(&ui, .Tab, true, {}))
	testing.expect_value(t, len(ui.msgs), 2)
	testing.expect(t, ui.msgs[0].kind == .Submit && ui.msgs[0].row == 4)
	testing.expect(t, ui.msgs[1].kind == .Edit && ui.msgs[1].row == 4 && ui.msgs[1].col == 1, "then the next column")
	clear(&ui.msgs)
	files_table(&ui, &sel, {4, 1})
	key_event(&ui, .Tab, true, {})
	testing.expect(t, ui.msgs[1].kind == .Edit && ui.msgs[1].row == 5 && ui.msgs[1].col == 0, "past the last column: the next row's first")
	clear(&ui.msgs)
	files_table(&ui, &sel, {5, 0})
	key_event(&ui, .Tab, true, {.Shift})
	testing.expect(t, ui.msgs[1].kind == .Edit && ui.msgs[1].row == 4 && ui.msgs[1].col == 1, "Shift+Tab goes back")
}

@(test)
inline_edit_slow_click_on_the_selected_row_asks_but_a_double_click_activates :: proc(t: ^testing.T) {
	ui: Ui(EMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	tbl, _ := files_table(&ui, &sel, {-1, -1})
	row := NODE_NONE
	for n, ref in ui.rows do if ref.table == tbl && ref.index == 1 do row = n
	rd := node_get(&ui.tree, row)
	at := [2]f32{rd.abs.x + 20, rd.abs.y + rd.abs.h / 2}
	ui.tree.now_ms = 1000
	pointer_button(&ui, .Left, true, at)
	pointer_button(&ui, .Left, false, at)
	testing.expect(t, selection_contains(&sel, 1))
	ui_after_events(&ui, 1000)
	testing.expect_value(t, len(ui.msgs), 0) // a first click only selects
	ui.tree.now_ms = 2000 // well after a double could follow
	pointer_button(&ui, .Left, true, at)
	pointer_button(&ui, .Left, false, at)
	ui_after_events(&ui, 2000)
	testing.expect_value(t, len(ui.msgs), 0) // not yet: a second click may still come
	ui_after_events(&ui, 2000 + TABLE_DOUBLE_CLICK_MS + 1)
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect(t, ui.msgs[0].kind == .Edit && ui.msgs[0].row == 1 && ui.msgs[0].col == 0, "a slow second click asks for an edit")
	clear(&ui.msgs)
	ui.tree.now_ms = 4000
	pointer_button(&ui, .Left, true, at)
	pointer_button(&ui, .Left, false, at)
	ui.tree.now_ms = 4100
	pointer_button(&ui, .Left, true, at)
	pointer_button(&ui, .Left, false, at)
	ui_after_events(&ui, 4100 + TABLE_DOUBLE_CLICK_MS + 1)
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0].kind, type_of(ui.msgs[0].kind).Activate) // a double-click opens, and no edit follows
}

@(test)
inline_edit_icon_view_and_tree_ask_the_same_way :: proc(t: ^testing.T) {
	ui: Ui(EMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	set_viewport(&ui.tree, {600, 400})
	begin_view(&ui)
	column(&ui, flex = 1)
	first, last := icon_view(&ui, 20, &sel, on_edit = proc(e: Ev(int)) -> EMsg { return {kind = .Edit, row = e.value} }, label = "Pictures", key = 5)
	for i in first ..< last do icon_item(&ui, i, .File, "pic")
	end(&ui)
	tree_view(&ui, label = "Places", on_edit = proc(e: Ev(int)) -> EMsg { return {kind = .Edit, row = e.value, col = 9} }, key = 6)
	tree_item(&ui, "Home", EMsg{}, selected = true, tag = 42)
	tree_item(&ui, "Work", EMsg{}, tag = 43, on_submit = proc(e: Ev(string)) -> EMsg { return {kind = .Submit, row = int(e.tag), text = e.value} })
	end(&ui)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 400})
	col := node_first(&ui.tree, ui.root)
	view := node_first(&ui.tree, col)
	tree := node_next(&ui.tree, view)
	testing.expect_value(t, node_get(&ui.tree, tree).access.role, Role.Tree)
	// the tree item with on_submit carries an editor with focus and the name selected
	testing.expect(t, ui.tree.focus != NODE_NONE && ui.tree.focus in ui.edits, "the tree's editor has focus")
	lo, hi := text_input_selection(&ui.tree, ui.tree.focus)
	testing.expect(t, lo == 0 && hi == 4)
	key_event(&ui, .Enter, true, {})
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0].kind == .Submit && ui.msgs[0].row == 43 && ui.msgs[0].text == "Work", "Enter commits with the item's tag")
	clear(&ui.msgs)
	// F2 on the icon view's cursor tile and on the tree's cursor item
	set_focus(&ui.tree, view, true)
	key_event(&ui, .Down, true, {})
	clear(&ui.msgs)
	testing.expect(t, key_event(&ui, .F2, true, {}))
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0].kind == .Edit && ui.msgs[0].row == sel.cursor, "the icon view asks with the tile index")
	clear(&ui.msgs)
	set_focus(&ui.tree, tree, true)
	key_event(&ui, .Down, true, {})
	clear(&ui.msgs)
	testing.expect(t, key_event(&ui, .F2, true, {}))
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0].kind == .Edit && ui.msgs[0].row == 42 && ui.msgs[0].col == 9, "the tree asks with the item's tag")
}

@(private = "file")
InlineEdit_DMsg :: struct { kind: enum { None, Qty, Name, Unit, Done }, row: int, n: f32, s: string, i: int }

// A data table: every cell holds a control, as an order form does.
@(test)
data_table_cells_hold_controls_named_by_their_column :: proc(t: ^testing.T) {
	ui: Ui(InlineEdit_DMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	names := [3]Text{text_make("Widget"), text_make("Gadget"), text_make("Gizmo")}
	defer for &n in names do text_destroy(&n)
	set_viewport(&ui.tree, {700, 400})
	begin_view(&ui)
	column(&ui, flex = 1)
	cols := []Column{{title = "Product"}, {title = "Qty", width = 120, numeric = true}, {title = "Unit", width = 140}, {title = "Active", width = 80}}
	first, last := table(&ui, cols, len(names), nil, label = "Order lines", key = 3)
	for i in first ..< last {
		table_row(&ui, i)
		cell(&ui)
		text_input(&ui, &names[i], on_change = proc(e: Ev(string)) -> InlineEdit_DMsg { return {kind = .Name, row = int(e.tag), s = e.value} }, tag = u64(i), flex = 1)
		end(&ui)
		cell(&ui)
		number_input(&ui, f32(i + 1), on_change = proc(e: Ev(f32)) -> InlineEdit_DMsg { return {kind = .Qty, row = int(e.tag), n = e.value} }, tag = u64(i), width = 100)
		end(&ui)
		cell(&ui)
		select(&ui, 0, {"each", "box", "pallet"}, proc(e: Ev(int)) -> InlineEdit_DMsg { return {kind = .Unit, row = int(e.tag), i = e.value} }, tag = u64(i), width = 120)
		end(&ui)
		cell(&ui)
		checkbox(&ui, true, "Active", on_change = proc(e: Ev(bool)) -> InlineEdit_DMsg { return {kind = .Done, row = int(e.tag)} }, tag = u64(i))
		end(&ui)
		end(&ui)
	}
	end(&ui)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {700, 400})
	tbl := node_first(&ui.tree, node_first(&ui.tree, ui.root))
	testing.expect_value(t, lint(&ui.tree), 0) // every control has a name: its column header
	// Tab walks the headers, then the controls of each row in order
	set_focus(&ui.tree, tbl, true)
	for _ in 0 ..< 5 do key_event(&ui, .Tab, true, {})
	f := node_get(&ui.tree, ui.tree.focus)
	testing.expect_value(t, f.access.role, Role.Text_Input)
	testing.expect_value(t, node_get(&ui.tree, f.access.labelled_by).access.name, "Product")
	key_event(&ui, .End, true, {})
	text_event(&ui, "s")
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0].kind == .Name && ui.msgs[0].row == 0 && ui.msgs[0].s == "Widgets", "typing edits the row's own field")
	clear(&ui.msgs)
	key_event(&ui, .Tab, true, {})
	f = node_get(&ui.tree, ui.tree.focus)
	testing.expect_value(t, f.access.role, Role.Spin_Button)
	testing.expect(t, key_event(&ui, .Up, true, {}), "Up steps the number, not the table's cursor")
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0].kind == .Qty && ui.msgs[0].n == 2)
}

} // when ODIN_TEST