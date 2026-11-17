package baldr

@(require) import "core:testing"
@(require) import "core:fmt"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: about 9 GB without this `when`, 1 GB with it.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(test)
text_ellipsis_end_middle_and_two_lines :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	// the mono measure: 8 px per rune at size 16, 20 px lines
	begin_view(&ui)
	column(&ui, align = .Start)
	a := text(&ui, "abcdefghijklmnop", size = 16, nowrap = true, ellipsis = .End)
	set_layout(&ui.tree, a, Layout_Props{max_w = 80})
	b := text(&ui, "abcdefghijklmnop", size = 16, nowrap = true, ellipsis = .Middle)
	set_layout(&ui.tree, b, Layout_Props{max_w = 80})
	c := text(&ui, "abcdefghijklmnopqrstuvwxyz0123", size = 16, ellipsis = .Middle, max_lines = 2)
	set_layout(&ui.tree, c, Layout_Props{max_w = 80})
	d := text(&ui, "short", size = 16, nowrap = true, ellipsis = .End)
	set_layout(&ui.tree, d, Layout_Props{max_w = 80})
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {300, 300})
	ka := node_get(&ui.tree, a).kind.(Text_Kind)
	testing.expect_value(t, ka.display, "abcdefghi…") // 10 runes = 80 px
	testing.expect_value(t, node_get(&ui.tree, a).abs.w, 80)
	testing.expect_value(t, node_get(&ui.tree, a).access.name, "abcdefghijklmnop") // the accessible name stays whole
	kb := node_get(&ui.tree, b).kind.(Text_Kind)
	testing.expect_value(t, kb.display, "abcde…mnop")
	kc := node_get(&ui.tree, c).kind.(Text_Kind)
	testing.expect_value(t, kc.display, "abcdefghij…vwxyz0123") // 20 runes: two lines of 10
	testing.expect_value(t, node_get(&ui.tree, c).abs.h, 40)
	kd := node_get(&ui.tree, d).kind.(Text_Kind)
	testing.expect_value(t, kd.display, "")
	shown := 0
	for cmd in draw_list(&ui.tree) do if dt, ok := cmd.(Draw_Text); ok && dt.str == "abcdefghi…" do shown += 1
	testing.expect_value(t, shown, 1)
}

@(private = "file")
TCOLS2 := []Column{{title = "Name"}, {title = "Size", width = 80, numeric = true}}

@(private = "file")
files_view :: proc(ui: ^Ui(Ov_Msg), sel: ^Selection, ctx_open: bool) -> Node {
	set_viewport(&ui.tree, {600, 400})
	begin_view(ui)
	column(ui, flex = 1)
	first, last := table(ui, TCOLS2, 100, sel,
		on_select = proc(e: Ev(int)) -> Ov_Msg { return {kind = .Pick, i = e.value} },
		on_context = proc(e: Ev(int)) -> Ov_Msg { return {kind = .Close_Pop, i = e.value} },
		label = "Files", key = 3)
	for i in first ..< last {
		table_row(ui, i)
		cell_text(ui, fmt.tprintf("file-%02d-with-a-rather-long-name-that-will-not-fit-in-the-name-column-at-this-window-width-at-all.txt", i))
		cell_text(ui, "1 KB")
		end(ui)
	}
	end(ui)
	if context_menu(ui, ctx_open, Ov_Msg{kind = .Close_Dialog}) {
		menu_item(ui, "Open", Ov_Msg{kind = .Delete})
		menu_item(ui, "New folder", Ov_Msg{kind = .None})
		end(ui)
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	return node_first(&ui.tree, node_first(&ui.tree, ui.root))
}

@(private = "file")
settle_grid :: proc(ui: ^Ui(Ov_Msg), sel: ^Selection, ctx: bool) -> Node {
	v := files_view(ui, sel, ctx)
	for _ in 0 ..< 3 {
		ui.needs_rebuild = false
		ui_after_events(ui, 1)
		if !ui.needs_rebuild do break
		ui.needs_rebuild = false
		v = files_view(ui, sel, ctx)
	}
	return v
}

@(private = "file")
row_of :: proc(ui: ^Ui(Ov_Msg), tbl: Node, index: int) -> Node {
	for n, ref in ui.rows do if ref.table == tbl && ref.index == index && node_valid(&ui.tree, n) do return n
	return NODE_NONE
}

@(test)
context_requests_by_right_click_and_keyboard_open_a_menu_at_the_pointer :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	tbl := settle_grid(&ui, &sel, false)
	// cells trim with an end ellipsis rather than spilling
	r0 := node_get(&ui.tree, row_of(&ui, tbl, 0))
	name_txt := node_get(&ui.tree, node_get(&ui.tree, r0.first).first).kind.(Text_Kind)
	testing.expect(t, len(name_txt.display) > 0 && name_txt.display[len(name_txt.display) - 3:] == "…", "long cell text ends with …")
	// right-click on an unselected row selects it and asks for its menu
	r3 := node_get(&ui.tree, row_of(&ui, tbl, 3)).abs
	p := [2]f32{r3.x + 30, r3.y + 10}
	pointer_move(&ui, p)
	testing.expect(t, pointer_button(&ui, .Right, true, p))
	pointer_button(&ui, .Right, false, p)
	testing.expect(t, selection_contains(&sel, 3) && selection_count(&sel) == 1)
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1].kind, Ov_Kind.Close_Pop)
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1].i, 3)
	testing.expect_value(t, ui.context_pos, p)
	// the app opens the menu: it appears at the pointer, with focus on its first item
	tbl = settle_grid(&ui, &sel, true)
	m := node_first(&ui.tree, ui.tree.overlay)
	testing.expect(t, m != NODE_NONE)
	md := node_get(&ui.tree, m)
	testing.expect_value(t, md.access.role, Role.Menu)
	testing.expect_value(t, md.abs.x, p.x)
	testing.expect_value(t, md.abs.y, p.y)
	testing.expect_value(t, node_get(&ui.tree, ui.tree.focus).access.role, Role.Menu_Item)
	testing.expect(t, key_event(&ui, .Escape, true, {}))
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1].kind, Ov_Kind.Close_Dialog)
	clear(&ui.msgs)
	tbl = settle_grid(&ui, &sel, false)
	// right-click on a selected row of a multi-selection keeps the selection
	selection_range(&sel, 5)
	testing.expect_value(t, selection_count(&sel), 3)
	settle_grid(&ui, &sel, false)
	r5 := node_get(&ui.tree, row_of(&ui, tbl, 5)).abs
	pointer_button(&ui, .Right, true, {r5.x + 30, r5.y + 10})
	testing.expect_value(t, selection_count(&sel), 3)
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1].i, 5)
	// right-click below the last row: background (-1); the tail pad makes that space exist
	ts := ui.tree.tables[tbl]
	st := ui.tree.scrolls[ts.list]
	testing.expect_value(t, st.content.y, 100 * ts.row_height + ts.row_height)
	key_event(&ui, .End, true, {})
	scroll_to(&ui.tree, ts.list, {0, 1e9}) // all the way down: the pad after row 99 is on screen
	settle_grid(&ui, &sel, false)
	ld := node_get(&ui.tree, ts.list).abs
	below := [2]f32{ld.x + 30, ld.y + ld.h - 4}
	testing.expect(t, !(interactive_target(&ui, hit_test(&ui.tree, below)) in ui.rows), "the pad below the last row is background")
	pointer_button(&ui, .Right, true, below)
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1].i, -1)
	// keyboard: the Menu key asks for the cursor row at its position
	clear(&ui.msgs)
	set_focus(&ui.tree, tbl, true)
	testing.expect(t, key_event(&ui, .Menu, true, {}))
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1].i, sel.cursor)
	testing.expect(t, key_event(&ui, .F10, true, {.Shift}))
}

@(test)
table_rubber_band_from_the_background_selects_rows :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	tbl := settle_grid(&ui, &sel, false)
	ts := ui.tree.tables[tbl]
	key_event(&ui, .End, true, {})
	scroll_to(&ui.tree, ts.list, {0, 1e9}) // all the way down: rows 90..99 plus the pad
	settle_grid(&ui, &sel, false)
	selection_clear(&sel)
	ld := node_get(&ui.tree, ts.list).abs
	start := [2]f32{ld.x + 40, ld.y + ld.h - 4} // in the pad below row 99
	pointer_move(&ui, start)
	pointer_button(&ui, .Left, true, start)
	testing.expect_value(t, ui.marquee, tbl)
	r97 := node_get(&ui.tree, row_of(&ui, tbl, 97)).abs
	pointer_move(&ui, {ld.x + 40, r97.y + 5})
	testing.expect(t, selection_contains(&sel, 97) && selection_contains(&sel, 98) && selection_contains(&sel, 99), "band up over the last three rows")
	testing.expect_value(t, selection_count(&sel), 3)
	frame(&ui.tree, {600, 400})
	bands := 0
	for c in draw_list(&ui.tree) do if r, ok := c.(Draw_Rect); ok && r.border_w == 1 && r.radius == 2 do bands += 1
	testing.expect_value(t, bands, 1)
	pointer_button(&ui, .Left, false, {ld.x + 40, r97.y + 5})
	testing.expect_value(t, ui.marquee, NODE_NONE)
	testing.expect_value(t, selection_count(&sel), 3)
}

@(private = "file")
FIXED_COLS := []Column{{title = "Name"}, {title = "Size", width = 80, numeric = true}}

@(private = "file")
fixed_view :: proc(ui: ^Ui(Ov_Msg), sel: ^Selection, ctx: bool) -> Node {
	set_viewport(&ui.tree, {600, 400})
	begin_view(ui)
	column(ui, flex = 1)
	first, last := table(ui, FIXED_COLS, 50, sel,
		on_select = proc(e: Ev(int)) -> Ov_Msg { return {kind = .Pick, i = e.value} },
		on_context = proc(e: Ev(int)) -> Ov_Msg { return {kind = .Close_Pop, i = e.value} }, label = "Files", key = 3)
	for i in first ..< last {
		table_row(ui, i)
		cell_text(ui, fmt.tprintf("file-%02d", i))
		cell_text(ui, "1 KB")
		end(ui)
	}
	end(ui)
	if context_menu(ui, ctx, Ov_Msg{kind = .Close_Dialog}) {
		menu_item(ui, "Delete", Ov_Msg{kind = .Delete})
		end(ui)
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	return node_first(&ui.tree, node_first(&ui.tree, ui.root))
}

@(private = "file")
fixed_settled :: proc(ui: ^Ui(Ov_Msg), sel: ^Selection, ctx: bool) -> Node {
	v := fixed_view(ui, sel, ctx)
	for _ in 0 ..< 3 {
		ui.needs_rebuild = false
		ui_after_events(ui, 1)
		if !ui.needs_rebuild do break
		ui.needs_rebuild = false
		v = fixed_view(ui, sel, ctx)
	}
	return v
}

@(test)
table_rows_are_full_width_and_their_blank_parts_start_bands :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	tbl := fixed_settled(&ui, &sel, false)
	ts := ui.tree.tables[tbl]
	r0 := NODE_NONE
	for n, ref in ui.rows do if ref.table == tbl && ref.index == 0 && node_valid(&ui.tree, n) do r0 = n
	rd := node_get(&ui.tree, r0)
	ld := node_get(&ui.tree, ts.list)
	testing.expect_value(t, rd.abs.w, ld.abs.w) // the highlight spans the row
	blank := [2]f32{rd.abs.x + 300, rd.abs.y + 10} // past the name text, inside the Name column
	testing.expect(t, node_get(&ui.tree, hit_test(&ui.tree, blank)).access.role == .Cell, "the blank part of a cell")
	// a click on the blank part selects the row
	pointer_move(&ui, blank)
	pointer_button(&ui, .Left, true, blank)
	testing.expect_value(t, ui.band_pending.view, tbl)
	pointer_button(&ui, .Left, false, blank)
	testing.expect(t, selection_contains(&sel, 0) && selection_count(&sel) == 1, "click selected the row")
	testing.expect_value(t, ui.band_pending.view, NODE_NONE)
	// a drag from the blank part is a rubber band over rows, not a click
	msgs := len(ui.msgs)
	pointer_button(&ui, .Left, true, blank)
	pointer_move(&ui, {blank.x, blank.y + 2.5 * ts.row_height})
	testing.expect_value(t, ui.marquee, tbl)
	testing.expect_value(t, selection_count(&sel), 3)
	testing.expect(t, selection_contains(&sel, 0) && selection_contains(&sel, 2))
	pointer_button(&ui, .Left, false, {blank.x, blank.y + 2.5 * ts.row_height})
	testing.expect_value(t, ui.marquee, NODE_NONE)
	testing.expect_value(t, selection_count(&sel), 3)
	picks := 0
	for m in ui.msgs[msgs:] do if m.kind == .Pick do picks += 1
	testing.expect(t, picks >= 1, "the band reported its selection")
	// a press on the name text is the item's (a drag there moves it), never a band
	on_text := [2]f32{rd.abs.x + 20, rd.abs.y + 10}
	pointer_move(&ui, on_text)
	pointer_button(&ui, .Left, true, on_text)
	testing.expect_value(t, ui.band_pending.view, NODE_NONE)
	pointer_move(&ui, {on_text.x, on_text.y + 2 * ts.row_height})
	testing.expect_value(t, ui.marquee, NODE_NONE)
	pointer_button(&ui, .Left, false, {on_text.x, on_text.y + 2 * ts.row_height})
	// right-click on the blank part of a row is still the row's menu
	pointer_move(&ui, blank)
	pointer_button(&ui, .Right, true, blank)
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1].i, 0)
	pointer_button(&ui, .Right, false, blank)
	// with the context menu open over the rows, a press on the menu is the menu's, not a band under it
	fixed_settled(&ui, &sel, true)
	m := node_first(&ui.tree, ui.tree.overlay)
	item := node_get(&ui.tree, m).first
	id := node_get(&ui.tree, item).abs
	p := [2]f32{id.x + 10, id.y + id.h / 2}
	before := selection_count(&sel)
	pointer_move(&ui, p)
	pointer_button(&ui, .Left, true, p)
	testing.expect_value(t, ui.marquee, NODE_NONE)
	testing.expect_value(t, ui.band_pending.view, NODE_NONE)
	testing.expect_value(t, selection_count(&sel), before) // untouched
	n_before := len(ui.msgs)
	pointer_button(&ui, .Left, false, p)
	clicked := false
	for m2 in ui.msgs[n_before:] do if m2.kind == .Delete do clicked = true
	testing.expect(t, clicked, "the item was clicked")
}

@(test)
text_lines_align_within_their_node :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	column(&ui, align = .Start)
	c := text(&ui, "abcdefghijklmnopqrst", size = 16, align = .Center) // wraps into two lines of 10 runes at 80 px
	set_layout(&ui.tree, c, Layout_Props{max_w = 80})
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {300, 300})
	found := false
	for cmd in draw_list(&ui.tree) do if dt, ok := cmd.(Draw_Text); ok && dt.str == "abcdefghijklmnopqrst" {
		found = true
		testing.expect_value(t, dt.align, Text_Align.Center)
		testing.expect_value(t, dt.box_w, 80)
	}
	testing.expect(t, found)
}

@(test)
grid_scrollbar_takes_the_press_before_the_rows :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	tbl := settle_grid(&ui, &sel, false)
	list := ui.tree.tables[tbl].list
	ld := node_get(&ui.tree, list)
	testing.expect(t, .Scroll_V in ld.flags, "the table's rows scroll")
	scroll_by(&ui.tree, list, {0, 200}) // moved: the bar is showing
	track, thumb, ok := scrollbar_geometry(&ui.tree, list)
	testing.expect(t, ok)
	zone, _ := scrollbar_zone(&ui.tree, list)
	on_thumb := [2]f32{zone.x + zone.w / 2, thumb.y + thumb.h / 2}
	testing.expect(t, pointer_button(&ui, .Left, true, on_thumb), "the press is taken")
	testing.expect_value(t, ui.pointer.scroll_drag, list) // by the scrollbar, not a row's blank part
	testing.expect_value(t, ui.marquee, NODE_NONE)
	before := ui.tree.scrolls[list].offset.y
	pointer_move(&ui, on_thumb + {0, 40})
	testing.expect(t, ui.tree.scrolls[list].offset.y > before, "dragging the thumb scrolls")
	pointer_button(&ui, .Left, false, on_thumb + {0, 40})
	testing.expect_value(t, ui.pointer.scroll_drag, NODE_NONE)
	_ = track
}

} // when ODIN_TEST