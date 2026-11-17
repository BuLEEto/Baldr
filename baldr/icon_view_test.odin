package baldr

@(require) import "core:testing"
@(require) import "core:fmt"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: behind this `when`, checking a program costs
// 1.0 GB instead of 9.2 GB. ODIN_TEST is set by `odin test`; BALDR_TESTS
// lets ./build.sh check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
grid_view :: proc(ui: ^Ui(Ov_Msg), sel: ^Selection) -> Node {
	set_viewport(&ui.tree, {600, 400})
	begin_view(ui)
	column(ui, flex = 1)
	first, last := icon_view(ui, 1000, sel,
		on_select = proc(e: Ev(int)) -> Ov_Msg { return {kind = .Pick, i = e.value} },
		on_activate = proc(e: Ev(int)) -> Ov_Msg { return {kind = .Delete, i = e.value} },
		label = "Files", key = 5)
	for i in first ..< last do icon_item(ui, i, .File, fmt.tprintf("file-%d", i))
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	return node_first(&ui.tree, node_first(&ui.tree, ui.root))
}

@(private = "file")
settled_grid :: proc(ui: ^Ui(Ov_Msg), sel: ^Selection) -> Node {
	v := grid_view(ui, sel)
	for _ in 0 ..< 3 {
		ui.needs_rebuild = false
		ui_after_events(ui, 1)
		if !ui.needs_rebuild do break
		ui.needs_rebuild = false
		v = grid_view(ui, sel)
	}
	return v
}

@(private = "file")
tile_node :: proc(ui: ^Ui(Ov_Msg), view: Node, index: int) -> Node {
	for n, ref in ui.rows do if ref.table == view && ref.index == index && node_valid(&ui.tree, n) do return n
	return NODE_NONE
}

@(test)
icon_view_lays_tiles_in_columns_and_virtualises_rows :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	view := settled_grid(&ui, &sel)
	vd := node_get(&ui.tree, view)
	testing.expect_value(t, vd.access.role, Role.List)
	testing.expect_value(t, vd.access.name, "Files")
	vs := ui.tree.icon_views[view]
	inner := 600 - 2 * ui.theme.space[.sm]
	testing.expect_value(t, vs.cols, int((inner + ui.theme.space[.sm]) / (ICON_TILE.x + ui.theme.space[.sm])))
	testing.expect(t, vs.cols >= 5, "several columns at 600 px")
	testing.expect(t, len(ui.tree.nodes) < 600, "only visible rows exist")
	testing.expect_value(t, len(ui.tree.diags), 0) // scopes balanced: end() closed row, list and view
	t0 := node_get(&ui.tree, tile_node(&ui, view, 0))
	t1 := node_get(&ui.tree, tile_node(&ui, view, 1))
	tc := node_get(&ui.tree, tile_node(&ui, view, vs.cols))
	testing.expect_value(t, t1.abs.x, t0.abs.x + ICON_TILE.x + ui.theme.space[.sm])
	testing.expect_value(t, tc.abs.x, t0.abs.x)
	testing.expect_value(t, tc.abs.y, t0.abs.y + ICON_TILE.y + ui.theme.space[.sm])
	testing.expect_value(t, t0.access.role, Role.List_Item)
	testing.expect_value(t, t0.access.name, "file-0")
	testing.expect(t, lint(&ui.tree) == 0)
}

@(test)
icon_view_selection_keyboard_grid_and_marquee :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	view := settled_grid(&ui, &sel)
	cols := ui.tree.icon_views[view].cols
	click :: proc(ui: ^Ui(Ov_Msg), view: Node, index: int, mods: Mods, now: f64) {
		r := node_get(&ui.tree, tile_node(ui, view, index)).abs
		p := [2]f32{r.x + 10, r.y + 10}
		ui.tree.now_ms = now
		ui.pointer.mods = mods
		pointer_button(ui, .Left, true, p)
		pointer_button(ui, .Left, false, p)
	}
	click(&ui, view, 3, {}, 1000)
	testing.expect(t, selection_contains(&sel, 3) && selection_count(&sel) == 1)
	testing.expect_value(t, ui.tree.focus, view)
	testing.expect(t, key_event(&ui, .Down, true, {}))
	testing.expect_value(t, sel.cursor, 3 + cols)
	testing.expect(t, key_event(&ui, .Right, true, {.Shift}))
	testing.expect_value(t, selection_count(&sel), 2)
	testing.expect(t, key_event(&ui, .Up, true, {}))
	testing.expect_value(t, sel.cursor, 4)
	testing.expect(t, key_event(&ui, .End, true, {}))
	testing.expect_value(t, sel.cursor, 999)
	settle(&ui)
	ui_after_events(&ui, ui.tree.now_ms + 2)
	testing.expect(t, ui.needs_rebuild, "scrolled to the last row → rebuild")
	ui.needs_rebuild = false
	settled_grid(&ui, &sel)
	testing.expect(t, tile_node(&ui, view, 999) != NODE_NONE, "last tile built after the reveal")
	testing.expect(t, key_event(&ui, .Home, true, {}))
	settle(&ui)
	settled_grid(&ui, &sel)
	testing.expect(t, key_event(&ui, .Page_Down, true, {}), "Page Down moves the cursor by a viewport of rows")
	testing.expect(t, sel.cursor > 0 && sel.cursor % cols == 0, "…staying in the same column")
	page_cursor := sel.cursor
	testing.expect(t, key_event(&ui, .Page_Up, true, {}))
	testing.expect_value(t, sel.cursor, 0)
	testing.expect(t, page_cursor >= cols, "a page is at least one row")
	settle(&ui)
	settled_grid(&ui, &sel)
	// double-click activates
	before := len(ui.msgs)
	click(&ui, view, 1, {}, 5000)
	click(&ui, view, 1, {}, 5200)
	activated := false
	for m in ui.msgs[before:] do if m.kind == .Delete && m.i == 1 do activated = true
	testing.expect(t, activated)
	// rubber band from the gap before tile 0 across the first two tiles of row 0
	settled_grid(&ui, &sel)
	t0 := node_get(&ui.tree, tile_node(&ui, view, 0)).abs
	t1 := node_get(&ui.tree, tile_node(&ui, view, 1)).abs
	ld := node_get(&ui.tree, ui.tree.icon_views[view].list)
	start := [2]f32{ld.abs.x + 2, t0.y + t0.h + 2} // in the gap below row 0, left of any tile
	ui.pointer.mods = {}
	pointer_move(&ui, start)
	testing.expect(t, !(ui.pointer.hover in ui.rows), "press lands on empty space")
	pointer_button(&ui, .Left, true, start)
	testing.expect_value(t, ui.marquee, view)
	testing.expect_value(t, selection_count(&sel), 0) // a plain band starts from nothing
	pointer_move(&ui, {t1.x + 10, t0.y + 10})
	testing.expect(t, selection_contains(&sel, 0) && selection_contains(&sel, 1) && selection_count(&sel) == 2, "band covers tiles 0 and 1")
	frame(&ui.tree, {600, 400})
	bands := 0
	for c in draw_list(&ui.tree) do if r, ok := c.(Draw_Rect); ok && r.border_w == 1 && r.radius == 2 do bands += 1
	testing.expect_value(t, bands, 1)
	pointer_button(&ui, .Left, false, {t1.x + 10, t0.y + 10})
	testing.expect_value(t, ui.marquee, NODE_NONE)
	testing.expect_value(t, selection_count(&sel), 2)
	testing.expect(t, sel.cursor >= 0, "band leaves a cursor for the keyboard")
	// Ctrl+band adds to what is selected
	ui.pointer.mods = {.Ctrl}
	pointer_button(&ui, .Left, true, start)
	testing.expect_value(t, selection_count(&sel), 2) // kept
	t2 := node_get(&ui.tree, tile_node(&ui, view, 2)).abs
	pointer_move(&ui, {t2.x + 10, t0.y + 10})
	testing.expect_value(t, selection_count(&sel), 3) // band from below row 0 up over tiles 0..2 → 0, 1, 2
	pointer_button(&ui, .Left, false, {t2.x + 10, t0.y + 10})
	ui.pointer.mods = {}
	testing.expect(t, key_event(&ui, .A, true, {.Ctrl}))
	testing.expect_value(t, selection_count(&sel), 1000)
}

@(test)
icon_tile_shows_a_picture_instead_of_the_icon :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	px := []u8{255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,255,255}
	img, ok := image_from_rgba(4, 1, px)
	testing.expect(t, ok)
	defer image_destroy(&img)
	set_viewport(&ui.tree, {600, 400})
	begin_view(&ui)
	column(&ui, flex = 1)
	first, last := icon_view(&ui, 2, nil, label = "Pictures")
	for i in first ..< last do icon_item(&ui, i, .File, "photo.png", picture = &img if i == 0 else nil)
	end(&ui)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 400})
	view := node_first(&ui.tree, node_first(&ui.tree, ui.root))
	tile0, tile1: Node
	for n, ref in ui.rows do if ref.table == view {
		if ref.index == 0 do tile0 = n
		if ref.index == 1 do tile1 = n
	}
	pic := node_first(&ui.tree, tile0)
	pd := node_get(&ui.tree, pic)
	ck, is_custom := pd.kind.(Custom_Kind)
	testing.expect(t, is_custom && ck.user == rawptr(&img), "the first tile's top child is the picture")
	testing.expect_value(t, Image_Fit(pd.tag), Image_Fit.Contain)
	testing.expect(t, ck.size.x == ck.size.y && ck.size.x >= ICON_TILE_ICON, "a square that fits above the label")
	ik, _ := node_get(&ui.tree, node_first(&ui.tree, tile1)).kind.(Custom_Kind)
	testing.expect(t, ik.user != rawptr(&img), "the second tile keeps its icon")
	testing.expect(t, lint(&ui.tree) == 0)
}

} // when ODIN_TEST