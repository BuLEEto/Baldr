package baldr

@(require) import "core:testing"

// A table whose columns are wider together than it is scrolls sideways: the
// header pans with the rows, the vertical bar stays in view, and every
// column can be reached with the wheel, the keyboard or a header cell.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Pan_Msg :: union { int }

@(private = "file")
PAN_WIDE := []Column{{title = "Name", width = 250}, {title = "Size", width = 250}, {title = "Kind", width = 250}}

@(private = "file")
PAN_FITS := []Column{{title = "Name"}, {title = "Size"}, {title = "Kind"}}

@(private = "file")
pan_build :: proc(ui: ^Ui(Pan_Msg), cols: []Column, sel: ^Selection, w: f32 = 400) -> (tbl: Node) {
	set_viewport(&ui.tree, {w + 40, 320})
	begin_view(ui)
	column(ui, width = w, height = 260, key = 1)
	first, last := table(ui, cols, 40, sel, label = "Files", key = 2)
	for i in first ..< last {
		table_row(ui, i)
		cell_text(ui, "name"); cell_text(ui, "size"); cell_text(ui, "kind")
		end(ui)
	}
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {w + 40, 320})
	for n, _ in ui.tree.tables do tbl = n
	return
}

// pan_cells is the x of each header cell and of each cell of the first
// row built, in display order.
@(private = "file")
pan_cells :: proc(ui: ^Ui(Pan_Msg), tbl: Node) -> (head, row: [3]f32) {
	t := &ui.tree
	ts := &t.tables[tbl]
	i := 0
	for ch := node_get(t, ts.header).first; ch != NODE_NONE && i < 3; ch = node_get(t, ch).next {
		head[i] = node_get(t, ch).abs.x
		i += 1
	}
	r := NODE_NONE
	for n, ref in ui.rows do if ref.table == tbl && ref.index == 0 do r = n
	i = 0
	for ch := node_get(t, r).first; ch != NODE_NONE && i < 3; ch = node_get(t, ch).next {
		row[i] = node_get(t, ch).abs.x
		i += 1
	}
	return
}

@(test)
a_wide_tables_header_pans_with_its_rows :: proc(t: ^testing.T) {
	ui: Ui(Pan_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel: Selection
	defer selection_destroy(&sel)
	tbl := pan_build(&ui, PAN_WIDE, &sel)
	tr := &ui.tree
	ts := &tr.tables[tbl]
	ld := node_get(tr, ts.list)
	testing.expect(t, .Scroll_H in ld.flags && .Scroll_V in ld.flags, "the rows scroll both ways")
	head, row := pan_cells(&ui, tbl)
	testing.expect_value(t, head, row)

	r := node_get(tr, ts.list).abs
	scroll_event(&ui, {r.x + r.w / 2, r.y + r.h / 2}, {200, 0}, true, {})
	frame(tr, tr.viewport)
	testing.expect_value(t, scroll_offset(tr, ts.list).x, f32(200))
	head2, row2 := pan_cells(&ui, tbl)
	testing.expect_value(t, head2, row2) // the header kept with the rows
	testing.expect_value(t, head2[0], head[0] - 200)
	testing.expect_value(t, node_get(tr, ts.list).abs, r) // the rows' box stays put…
	track, _, has := scrollbar_geometry(tr, ts.list, 1)
	testing.expect(t, has && track.x + track.w <= r.x + r.w + 0.5 && track.x >= r.x, "…and so does its vertical bar")

	// a sideways wheel over the header pans the rows too
	hd := node_get(tr, ts.header).abs
	scroll_event(&ui, {hd.x + 20, hd.y + hd.h / 2}, {-120, 0}, true, {})
	frame(tr, tr.viewport)
	testing.expect_value(t, scroll_offset(tr, ts.list).x, f32(80))
	head3, row3 := pan_cells(&ui, tbl)
	testing.expect_value(t, head3, row3)
}

@(test)
a_table_that_fits_does_not_scroll_sideways :: proc(t: ^testing.T) {
	ui: Ui(Pan_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel: Selection
	defer selection_destroy(&sel)
	tbl := pan_build(&ui, PAN_FITS, &sel)
	tr := &ui.tree
	ts := &tr.tables[tbl]
	testing.expect(t, .Scroll_H not_in node_get(tr, ts.list).flags, "nothing to scroll to")
	r := node_get(tr, ts.list).abs
	scroll_event(&ui, {r.x + r.w / 2, r.y + r.h / 2}, {200, 0}, true, {})
	frame(tr, tr.viewport)
	testing.expect_value(t, scroll_offset(tr, ts.list).x, f32(0))
}

// Scrolled sideways, then made wide enough for every column: the pan goes,
// and the header goes with it in the same layout, not a frame later.
@(test)
a_table_made_wide_enough_lets_go_of_its_pan_header_and_all :: proc(t: ^testing.T) {
	ui: Ui(Pan_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel: Selection
	defer selection_destroy(&sel)
	tbl := pan_build(&ui, PAN_WIDE, &sel)
	tr := &ui.tree
	ts := &tr.tables[tbl]
	r := node_get(tr, ts.list).abs
	scroll_event(&ui, {r.x + r.w / 2, r.y + r.h / 2}, {300, 0}, true, {})
	frame(tr, tr.viewport)
	testing.expect(t, scroll_offset(tr, ts.list).x > 0, "panned")
	pan_build(&ui, PAN_WIDE, &sel, w = 900)
	testing.expect_value(t, scroll_offset(tr, ts.list).x, f32(0))
	head, row := pan_cells(&ui, tbl)
	testing.expect_value(t, head, row)
	testing.expect_value(t, head[0], node_get(tr, ts.header).abs.x)
}

@(test)
the_keyboard_reaches_a_wide_tables_far_columns :: proc(t: ^testing.T) {
	ui: Ui(Pan_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel: Selection
	defer selection_destroy(&sel)
	tbl := pan_build(&ui, PAN_WIDE, &sel)
	tr := &ui.tree
	ts := &tr.tables[tbl]
	settle :: proc(ui: ^Ui(Pan_Msg)) {
		for _ in 0 ..< 60 do scroll_tick(&ui.tree, 0.05)
		frame(&ui.tree, ui.tree.viewport)
	}
	set_focus(tr, tbl, true)
	testing.expect(t, key_event(&ui, .Right, true, {}), "Right pans")
	settle(&ui)
	testing.expect_value(t, scroll_offset(tr, ts.list).x, TABLE_PAN_STEP)
	testing.expect(t, !key_event(&ui, .Right, true, {.Alt}), "Alt+Right is the window's")
	testing.expect(t, key_event(&ui, .Left, true, {}), "Left pans back")
	settle(&ui)
	testing.expect_value(t, scroll_offset(tr, ts.list).x, f32(0))

	// the last column's heading takes the keyboard: the rows pan to show it
	last := node_get(tr, node_get(tr, ts.header).first).next
	last = node_get(tr, last).next
	set_focus(tr, last, true)
	settle(&ui)
	ld := node_get(tr, last).abs
	hd := node_get(tr, ts.header).abs
	testing.expectf(t, ld.x >= hd.x && ld.x + ld.w <= hd.x + hd.w + 0.5, "the heading is in view (%v in %v)", ld, hd)
	head, row := pan_cells(&ui, tbl)
	testing.expect_value(t, head, row)
}

// Panned, a divider is found and drawn where it shows.
@(test)
a_wide_tables_dividers_follow_the_pan :: proc(t: ^testing.T) {
	ui: Ui(Pan_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel: Selection
	defer selection_destroy(&sel)
	tbl := pan_build(&ui, PAN_WIDE, &sel)
	tr := &ui.tree
	ts := &tr.tables[tbl]
	r := node_get(tr, ts.list).abs
	scroll_event(&ui, {r.x + r.w / 2, r.y + r.h / 2}, {200, 0}, true, {})
	frame(tr, tr.viewport)
	hd := node_get(tr, ts.header).abs
	x := hd.x + 250 - 200 // after the first column, panned 200
	at, slot := table_divider_at(tr, {x, hd.y + hd.h / 2})
	testing.expect(t, at == tbl && slot == 0, "the divider under the pointer is the first")
	_, none := table_divider_at(tr, {hd.x + 250, hd.y + hd.h / 2})
	testing.expect_value(t, none, -1) // where it was before the pan, nothing
}

}
