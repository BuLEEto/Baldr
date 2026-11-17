package baldr

@(require) import "core:testing"
@(require) import "core:fmt"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
TCOLS := []Column{
	{title = "Name", sortable = true},
	{title = "Size", width = 80, numeric = true, sortable = true},
	{title = "Kind", width = 100},
}

@(private = "file")
table_view :: proc(ui: ^Ui(Ov_Msg), sel: ^Selection, sort: Sort) -> Node {
	set_viewport(&ui.tree, {600, 400}) // as the run loop does before the first view
	begin_view(ui)
	column(ui, flex = 1)
	first, last := table(ui, TCOLS, 10_000, sel,
		on_select = proc(e: Ev(int)) -> Ov_Msg { return {kind = .Pick, i = e.value} },
		on_activate = proc(e: Ev(int)) -> Ov_Msg { return {kind = .Delete, i = e.value} },
		sort = sort, on_sort = proc(e: Ev(int)) -> Ov_Msg { return {kind = .Close_Pop, i = e.value} },
		label = "Files", key = 3)
	for i in first ..< last {
		table_row(ui, i)
		cell_text(ui, fmt.tprintf("file-%05d", i))
		cell_text(ui, fmt.tprintf("%d KB", i * 3))
		cell_text(ui, "Text", muted = true)
		end(ui)
	}
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	return node_first(&ui.tree, node_first(&ui.tree, ui.root))
}

// settled builds until the table's geometry matches its width (the run loop
// does this through needs_rebuild after the first frame).
@(private = "file")
settled :: proc(ui: ^Ui(Ov_Msg), sel: ^Selection, sort: Sort) -> Node {
	tbl := table_view(ui, sel, sort)
	for _ in 0 ..< 3 {
		ui.needs_rebuild = false
		ui_after_events(ui, 1)
		if !ui.needs_rebuild do break
		ui.needs_rebuild = false
		tbl = table_view(ui, sel, sort)
	}
	return tbl
}

@(private = "file")
row_node :: proc(ui: ^Ui(Ov_Msg), tbl: Node, index: int) -> Node {
	ts := ui.tree.tables[tbl]
	for c := node_first(&ui.tree, ts.list); c != NODE_NONE; c = node_next(&ui.tree, c) {
		if ref, ok := ui.rows[c]; ok && ref.index == index do return c
	}
	return NODE_NONE
}

// A table can size itself to N rows. An app guessing the height from the
// font size is right on one platform's fonts and a few px short on another's,
// and the table scrolls; the toolkit knows the row height.
@(test)
a_table_can_size_itself_to_a_number_of_rows :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {600, 400})
	begin_view(&ui)
	column(&ui, flex = 1)
	first, last := table(&ui, TCOLS, 10_000, rows = 3, row_height = 20, label = "Files", key = 3)
	for i in first ..< last {
		table_row(&ui, i)
		cell_text(&ui, "a")
		cell_text(&ui, "b")
		cell_text(&ui, "c")
		end(&ui)
	}
	end(&ui)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 400})

	// Three rows and the header, which is one row tall — the part an app
	// guessing from the font size forgets.
	tbl := NODE_NONE
	for n, _ in ui.tree.tables do tbl = n
	testing.expect(t, tbl != NODE_NONE, "the table is there")
	testing.expect_value(t, node_get(&ui.tree, tbl).rect.h, f32(20 * 4))

	// And it does not stretch: the column it sits in is taller than it.
	testing.expect(t, node_get(&ui.tree, tbl).rect.h < 400, "sized, not filling")
}

@(test)
table_builds_virtual_rows_with_aligned_columns :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	tbl := settled(&ui, &sel, {column = -1})
	td := node_get(&ui.tree, tbl)
	testing.expect_value(t, td.access.role, Role.Table)
	testing.expect_value(t, td.access.name, "Files")
	ts := ui.tree.tables[tbl]
	testing.expect(t, node_child_count(&ui.tree, ts.list) < 30, "a screen of rows")
	testing.expect(t, len(ui.tree.nodes) < 400, "node pool stays small")
	// header and body cells line up
	hdr := node_get(&ui.tree, ts.header)
	r0 := row_node(&ui, tbl, 0)
	testing.expect(t, r0 != NODE_NONE)
	hc, bc := hdr.first, node_get(&ui.tree, r0).first
	for hc != NODE_NONE && bc != NODE_NONE {
		testing.expect_value(t, node_get(&ui.tree, bc).abs.x, node_get(&ui.tree, hc).abs.x)
		testing.expect_value(t, node_get(&ui.tree, bc).abs.w, node_get(&ui.tree, hc).abs.w)
		hc, bc = node_get(&ui.tree, hc).next, node_get(&ui.tree, bc).next
	}
	testing.expect_value(t, node_get(&ui.tree, node_get(&ui.tree, hdr.first).next).abs.w, 80)
	testing.expect_value(t, node_get(&ui.tree, r0).access.name, "file-00000")
	testing.expect_value(t, node_get(&ui.tree, r0).access.role, Role.Row)
	testing.expect(t, lint(&ui.tree) == 0, "every row, header and cell is named")
	// text in cells never wraps
	first_cell := node_get(&ui.tree, r0).first
	txt := node_get(&ui.tree, node_get(&ui.tree, first_cell).first)
	testing.expect(t, txt.kind.(Text_Kind).nowrap)
}

@(test)
table_pointer_selection_single_ctrl_shift_and_double_click :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	tbl := settled(&ui, &sel, {column = -1})
	click_row :: proc(ui: ^Ui(Ov_Msg), tbl: Node, index: int, mods: Mods, now: f64) {
		r := node_get(&ui.tree, row_node(ui, tbl, index)).abs
		p := [2]f32{r.x + 20, r.y + r.h / 2}
		ui.tree.now_ms = now
		ui.pointer.mods = mods
		pointer_button(ui, .Left, true, p)
		pointer_button(ui, .Left, false, p)
	}
	click_row(&ui, tbl, 2, {}, 1000)
	testing.expect(t, selection_contains(&sel, 2) && selection_count(&sel) == 1)
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1].kind, Ov_Kind.Pick)
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1].i, 2)
	testing.expect_value(t, ui.tree.focus, tbl)
	click_row(&ui, tbl, 4, {.Ctrl}, 2000)
	testing.expect(t, selection_contains(&sel, 2) && selection_contains(&sel, 4) && selection_count(&sel) == 2, "ctrl adds")
	click_row(&ui, tbl, 6, {.Shift}, 3000)
	testing.expect_value(t, selection_count(&sel), 3) // anchor 4 .. 6
	testing.expect(t, selection_contains(&sel, 5) && !selection_contains(&sel, 2), "shift ranges from the anchor")
	ui.needs_rebuild = false
	table_view(&ui, &sel, {column = -1})
	r5 := node_get(&ui.tree, row_node(&ui, tbl, 5))
	testing.expect(t, .Selected in r5.access.states, "selected rows carry the state")
	testing.expect(t, r5.style.bg == ui.theme.color.primary_container, "and the highlight")
	// double-click activates
	before := len(ui.msgs)
	click_row(&ui, tbl, 1, {}, 5000)
	click_row(&ui, tbl, 1, {}, 5200)
	found := false
	for m in ui.msgs[before:] do if m.kind == .Delete && m.i == 1 do found = true
	testing.expect(t, found, "double-click sent on_activate")
}

@(test)
table_keyboard_cursor_ranges_select_all_enter_and_sort :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	tbl := settled(&ui, &sel, {column = -1})
	set_focus(&ui.tree, tbl, true)
	testing.expect(t, key_event(&ui, .Down, true, {}))
	testing.expect_value(t, sel.cursor, 0)
	testing.expect(t, key_event(&ui, .Down, true, {}))
	testing.expect(t, key_event(&ui, .Down, true, {.Shift}))
	testing.expect_value(t, sel.cursor, 2)
	testing.expect_value(t, selection_count(&sel), 2) // 1..2
	testing.expect(t, key_event(&ui, .Space, true, {}))
	testing.expect_value(t, selection_count(&sel), 1) // toggled 2 off
	testing.expect(t, key_event(&ui, .End, true, {}))
	testing.expect_value(t, sel.cursor, 9_999)
	ts := ui.tree.tables[tbl]
	settle(&ui)
	testing.expect(t, scroll_offset(&ui.tree, ts.list).y > 0, "scrolled to the last row")
	ui_after_events(&ui, ui.tree.now_ms + 100)
	testing.expect(t, ui.needs_rebuild)
	ui.needs_rebuild = false
	table_view(&ui, &sel, {column = -1})
	testing.expect(t, row_node(&ui, tbl, 9_999) != NODE_NONE, "the last row is built after the reveal")
	testing.expect(t, key_event(&ui, .A, true, {.Ctrl}))
	testing.expect_value(t, selection_count(&sel), 10_000)
	before := len(ui.msgs)
	testing.expect(t, key_event(&ui, .Enter, true, {}))
	testing.expect_value(t, ui.msgs[before].kind, Ov_Kind.Delete)
	testing.expect_value(t, ui.msgs[before].i, 9_999)
	// sort: click a sortable header
	hdr := node_get(&ui.tree, ts.header)
	h1 := node_get(&ui.tree, hdr.first).next
	testing.expect(t, click(&ui, h1))
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1].kind, Ov_Kind.Close_Pop)
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1].i, 1)
	table_view(&ui, &sel, {column = 1, descending = true})
	h1 = node_get(&ui.tree, node_get(&ui.tree, ts.header).first).next
	testing.expect(t, .Selected in node_get(&ui.tree, h1).access.states, "sorted column is marked")
	testing.expect_value(t, node_child_count(&ui.tree, h1), 2) // label + arrow
}

@(test)
table_header_divider_drag_resizes_the_column :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	tbl := settled(&ui, &sel, {column = -1})
	ts := ui.tree.tables[tbl]
	hdr := node_get(&ui.tree, ts.header)
	h1 := node_get(&ui.tree, node_get(&ui.tree, hdr.first).next)
	name_w := node_get(&ui.tree, hdr.first).abs.w
	edge := [2]f32{h1.abs.x + h1.abs.w, h1.abs.y + 10}
	pointer_button(&ui, .Left, true, edge)
	testing.expect_value(t, ui.col_resize.table, tbl)
	testing.expect_value(t, ui.col_resize.col, 1)
	pointer_move(&ui, edge + {40, 0})
	testing.expect_value(t, ui.tree.tables[tbl].widths[1], 120)
	testing.expect(t, ui.needs_rebuild)
	pointer_button(&ui, .Left, false, edge + {40, 0})
	testing.expect_value(t, ui.col_resize.table, NODE_NONE)
	testing.expect_value(t, ui.tree.tables[tbl].resize_col, -1)
	ui.needs_rebuild = false
	settled(&ui, &sel, {column = -1}) // the app re-runs the view during the drag; the divider is at its new x
	pointer_move(&ui, edge + {40, 0})
	testing.expect_value(t, cursor_for(&ui), Cursor.Resize_EW) // the divider followed the pointer
	name_hdr := node_get(&ui.tree, node_get(&ui.tree, ts.header).first)
	testing.expect_value(t, name_hdr.abs.w, name_w) // the flexible column to the left kept its size …
	kind_hdr := node_get(&ui.tree, node_get(&ui.tree, ts.header).last)
	testing.expect_value(t, kind_hdr.abs.x, edge.x + 40)   // … and the column to the right shifted
	pointer_leave(&ui)
	testing.expect_value(t, cursor_for(&ui), Cursor.Default)
	frame(&ui.tree, {600, 400})
	guides := 0
	for c in draw_list(&ui.tree) {
		if r, ok := c.(Draw_Rect); ok && r.rect.w == 2 && r.rect.h == node_get(&ui.tree, tbl).abs.h do guides += 1
	}
	testing.expect_value(t, guides, 0) // the guide is gone after the release
	h1 = node_get(&ui.tree, node_get(&ui.tree, node_get(&ui.tree, ts.header).first).next)
	testing.expect_value(t, h1.abs.w, 120)
	r0 := node_get(&ui.tree, row_node(&ui, tbl, 0))
	testing.expect_value(t, node_get(&ui.tree, node_get(&ui.tree, r0.first).next).abs.w, 120)
	testing.expect_value(t, len(ui.msgs), 0) // a resize is not a selection or a sort
}

@(test)
table_divider_hover_shows_a_resize_cursor_and_guide :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	tbl := settled(&ui, &sel, {column = -1})
	ts := ui.tree.tables[tbl]
	hdr := node_get(&ui.tree, ts.header)
	h0 := node_get(&ui.tree, hdr.first)
	edge := [2]f32{h0.abs.x + h0.abs.w, h0.abs.y + 10}
	testing.expect_value(t, cursor_for(&ui), Cursor.Default)
	pointer_move(&ui, edge + {2, 0})
	testing.expect_value(t, cursor_for(&ui), Cursor.Resize_EW)
	testing.expect_value(t, ui.col_hover.col, 0)
	frame(&ui.tree, {600, 400})
	dividers, guides := 0, 0
	for c in draw_list(&ui.tree) {
		if r, ok := c.(Draw_Rect); ok {
			if r.rect.w == 1 && r.rect.h == hdr.abs.h - 18 do dividers += 1
			if r.rect.w == 2 && r.rect.h == node_get(&ui.tree, tbl).abs.h && r.color == ui.theme.color.primary do guides += 1
		}
	}
	testing.expect_value(t, dividers, 2) // three columns, two dividers
	testing.expect_value(t, guides, 1)
	pointer_move(&ui, {h0.abs.x + 20, h0.abs.y + 10})
	testing.expect_value(t, cursor_for(&ui), Cursor.Pointer) // over a sortable header cell
	testing.expect_value(t, ui.col_hover.table, NODE_NONE)
}

@(test)
table_columns_reorder_by_header_drag_and_keyboard :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	tbl := settled(&ui, &sel, {column = -1})
	ts := &ui.tree.tables[tbl]
	hdr := node_get(&ui.tree, ts.header)
	// drag the last column ("Kind") to the far left
	last := node_get(&ui.tree, hdr.last)
	p := [2]f32{last.abs.x + 30, last.abs.y + 10}
	pointer_move(&ui, p)
	pointer_button(&ui, .Left, true, p)
	testing.expect_value(t, ui.col_move.slot, 2)
	testing.expect(t, !ui.col_move.dragging)
	pointer_move(&ui, {hdr.abs.x + 5, p.y})
	testing.expect(t, ui.col_move.dragging)
	testing.expect_value(t, cursor_for(&ui), Cursor.Grabbing)
	testing.expect_value(t, ts.drop_slot, 0)
	pointer_button(&ui, .Left, false, {hdr.abs.x + 5, p.y})
	testing.expect_value(t, len(ui.msgs), 0) // a drag is not a sort click
	testing.expect(t, ts.order[0] == 2 && ts.order[1] == 0 && ts.order[2] == 1, "Kind moved to the first slot")
	ui.needs_rebuild = false
	settled(&ui, &sel, {column = -1})
	hdr = node_get(&ui.tree, ts.header)
	kind_hdr := node_get(&ui.tree, hdr.last) // still the third child (declared order) …
	testing.expect_value(t, kind_hdr.abs.x, hdr.abs.x) // … but laid out first
	r0 := node_get(&ui.tree, row_node(&ui, tbl, 0))
	kind_cell := node_get(&ui.tree, r0.last)
	testing.expect_value(t, kind_cell.abs.x, r0.abs.x)
	// keyboard: focus the "Size" header (declared 1, now slot 2) and move it left
	size_hdr := node_get(&ui.tree, hdr.first).next
	set_focus(&ui.tree, size_hdr, true)
	testing.expect(t, key_event(&ui, .Left, true, {.Ctrl}))
	testing.expect(t, ts.order[1] == 1 && ts.order[2] == 0, "Size moved before Name")
	w_before := ts.ws[1]
	testing.expect(t, key_event(&ui, .Right, true, {.Shift}))
	ui.needs_rebuild = false
	settled(&ui, &sel, {column = -1})
	testing.expect_value(t, ts.ws[1], w_before + TABLE_KEY_RESIZE_STEP)
}

// A single-select table (selection_make() without multi) treats Ctrl and
// Shift clicks and Ctrl+A as plain clicks; a table given no selection at
// all never selects, but Enter / double-click still activate.
@(test)
table_single_select_and_no_selection :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make()
	defer selection_destroy(&sel)
	tbl := settled(&ui, &sel, {column = -1})
	click_row :: proc(ui: ^Ui(Ov_Msg), tbl: Node, index: int, mods: Mods, now: f64) {
		r := node_get(&ui.tree, row_node(ui, tbl, index)).abs
		p := [2]f32{r.x + 20, r.y + r.h / 2}
		ui.tree.now_ms = now
		ui.pointer.mods = mods
		pointer_button(ui, .Left, true, p)
		pointer_button(ui, .Left, false, p)
	}
	click_row(&ui, tbl, 2, {}, 1000)
	click_row(&ui, tbl, 4, {.Ctrl}, 2000)
	testing.expect(t, selection_contains(&sel, 4) && !selection_contains(&sel, 2) && selection_count(&sel) == 1, "Ctrl-click just selects")
	click_row(&ui, tbl, 6, {.Shift}, 3000)
	testing.expect(t, selection_contains(&sel, 6) && selection_count(&sel) == 1, "Shift-click just selects")
	ui.pointer.mods = {}
	set_focus(&ui.tree, tbl, true)
	key_event(&ui, .A, true, {.Ctrl})
	testing.expect_value(t, selection_count(&sel), 1)
	key_event(&ui, .Down, true, {.Shift})
	testing.expect(t, selection_contains(&sel, 7) && selection_count(&sel) == 1, "Shift+Down moves the single selection")
	// no selection at all
	ui2: Ui(Ov_Msg)
	ui_init(&ui2)
	defer ui_destroy(&ui2)
	tbl2 := settled(&ui2, nil, {column = -1})
	click_row(&ui2, tbl2, 2, {}, 1000)
	ui2.needs_rebuild = false
	table_view(&ui2, nil, {column = -1})
	r2 := node_get(&ui2.tree, row_node(&ui2, tbl2, 2))
	testing.expect(t, .Selected not_in r2.access.states, "nothing to select into")
	before := len(ui2.msgs)
	click_row(&ui2, tbl2, 2, {}, 2000)
	click_row(&ui2, tbl2, 2, {}, 2200)
	found := false
	for m in ui2.msgs[before:] do if m.kind == .Delete && m.i == 2 do found = true
	testing.expect(t, found, "double-click still activates")
}

} // when ODIN_TEST