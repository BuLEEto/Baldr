package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
big_table :: proc(ui: ^Ui(Ov_Msg), row_height: f32) -> (tbl, list: Node) {
	set_viewport(&ui.tree, {600, 400})
	begin_view(ui)
	column(ui, flex = 1)
	cols := []Column{{title = "Name"}, {title = "Size", width = 100, numeric = true}}
	first, last := table(ui, cols, 100_000, nil, row_height = row_height, label = "Files", key = 3)
	for i in first ..< last {
		table_row(ui, i)
		cell_text(ui, "row")
		cell_text(ui, "1 KB")
		end(ui)
	}
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	tbl = node_first(&ui.tree, node_first(&ui.tree, ui.root))
	list = ui.tree.tables[tbl].list
	return
}

@(test)
table_zoom_keeps_the_top_row :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	_, list := big_table(&ui, 36)
	scroll_to(&ui.tree, list, {0, 36 * 34_000})
	big_table(&ui, 36)
	before := ui.lists[list].first
	testing.expect(t, before >= 34_000 - LIST_OVERSCAN - 1 && before <= 34_000, "scrolled to row 34 000")
	_, list2 := big_table(&ui, 48) // zoomed in: taller rows
	testing.expect_value(t, list2, list)
	after := ui.lists[list].first
	testing.expect(t, abs(after - before) <= 1, "the same row stays at the top")
	testing.expect_value(t, ui.tree.scrolls[list].offset.y, 48 * 34_000)
	_, _ = big_table(&ui, 24) // and out again
	testing.expect(t, abs(ui.lists[list].first - before) <= 1, "and on the way out")
}

@(private = "file")
big_grid :: proc(ui: ^Ui(Ov_Msg), tile: [2]f32) -> (view: Node, first: int) {
	set_viewport(&ui.tree, {600, 400})
	begin_view(ui)
	column(ui, flex = 1)
	f, l := icon_view(ui, 100_000, nil, tile = tile, label = "Pictures", key = 5)
	for i in f ..< l do icon_item(ui, i, .File, "pic")
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	view = node_first(&ui.tree, node_first(&ui.tree, ui.root))
	return view, f
}

@(test)
icon_view_zoom_keeps_the_top_item :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	view, _ := big_grid(&ui, {96, 100})
	vs := ui.tree.icon_views[view]
	pitch := vs.tile.y + vs.gap
	scroll_to(&ui.tree, vs.list, {0, pitch * 500}) // row 500 of the small tiles
	_, before := big_grid(&ui, {96, 100})
	cols_before := ui.tree.icon_views[view].cols
	testing.expect(t, cols_before >= 4, "several columns of small tiles")
	item_before := before + LIST_OVERSCAN * cols_before // the row at the top, past the overscan
	_, after := big_grid(&ui, {160, 170}) // zoomed in: fewer, bigger columns
	vs2 := ui.tree.icon_views[view]
	testing.expect(t, vs2.cols < cols_before, "fewer columns")
	item_after := after + LIST_OVERSCAN * vs2.cols
	testing.expect(t, abs(item_after - item_before) < cols_before + vs2.cols, "the same item is still at the top of the view")
}

} // when ODIN_TEST