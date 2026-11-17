package baldr

@(require) import "core:testing"
@(require) import "core:fmt"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: behind this `when`, checking a program costs
// 1.0 GB instead of 9.2 GB. ODIN_TEST is set by `odin test`; BALDR_TESTS
// lets ./build.sh check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
list_view :: proc(ui: ^Ui(Ov_Msg), count: int) -> Node {
	begin_view(ui)
	column(ui, flex = 1)
	first, last := list(ui, count, row_height = 40, label = "Rows", key = 7)
	for i in first ..< last {
		b := button(ui, fmt.tprintf("row %d", i), Ov_Msg{}, key = u64(i + 1))
		set_layout(&ui.tree, b, Layout_Props{height = 40})
	}
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	return node_first(&ui.tree, node_first(&ui.tree, ui.root))
}

// settle advances the tree clock through ~1.5 s of frames so every tween and
// smooth scroll reaches its target (a keyboard jump eases).
settle :: proc(ui: ^Ui($Msg)) {
	start := ui.tree.now_ms
	for i in 1 ..= 90 do ui_tick(ui, start + f64(i) * 16)
}

@(test)
list_builds_only_the_visible_rows_and_follows_scrolling :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := list_view(&ui, 100_000)
	ld := node_get(&ui.tree, n)
	testing.expect_value(t, ld.access.role, Role.List)
	testing.expect_value(t, ld.access.name, "Rows")
	built := node_child_count(&ui.tree, n)
	testing.expect(t, built < 30, "a screen of rows, not all of them")
	st := ui.tree.scrolls[n]
	testing.expect_value(t, st.content.y, f32(100_000) * 40)
	testing.expect(t, len(ui.tree.nodes) < 200, "node pool stays small")
	testing.expect(t, lint(&ui.tree) == 0)

	// Scroll far down: the range moves, the view is asked to rebuild, rows follow.
	scroll_to(&ui.tree, n, {0, 40 * 50_000})
	ui_after_events(&ui, 1000)
	testing.expect(t, ui.needs_rebuild, "range changed → rebuild")
	ui.needs_rebuild = false
	list_view(&ui, 100_000)
	frame(&ui.tree, {600, 400})
	ls := ui.lists[n]
	testing.expect(t, ls.first <= 50_000 && ls.last > 50_000, "rows around the scroll position are built")
	// The row at the top of the viewport is the one the offset says.
	found := false
	for c := node_first(&ui.tree, n); c != NODE_NONE; c = node_next(&ui.tree, c) {
		cd := node_get(&ui.tree, c)
		if cd.access.name == "row 50000" {
			found = true
			testing.expect(t, abs(cd.abs.y - ld.abs.y) < 0.5, "row 50000 sits at the viewport top")
		}
	}
	testing.expect(t, found, "row 50000 exists")
	ui_after_events(&ui, 1100)
	testing.expect(t, !ui.needs_rebuild, "settled")

	// Shrinking the list past the current range clamps.
	list_view(&ui, 10)
	frame(&ui.tree, {600, 400})
	testing.expect_value(t, ui.lists[n].last, 10)
	testing.expect_value(t, node_get(&ui.tree, n).access.role, Role.List)
}

@(test)
list_unkeyed_rows_are_diagnosed :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	first, last := list(&ui, 50, row_height = 20)
	for _ in first ..< last do text(&ui, "x") // no key
	end(&ui)
	end_view(&ui)
	testing.expect_value(t, len(ui.tree.diags), 1)
}

@(test)
scroll_keyboard_focus_scrolls_into_view_and_page_keys_work :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	column(&ui, flex = 1)
	sc := scroll(&ui, height = 100)
	rows: [10]Node
	for i in 0 ..< 10 {
		rows[i] = button(&ui, fmt.tprintf("b%d", i), Ov_Msg{}, key = u64(i + 1))
		set_layout(&ui.tree, rows[i], Layout_Props{height = 30})
	}
	end(&ui)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {300, 300})
	testing.expect_value(t, scroll_offset(&ui.tree, sc).y, 0)
	set_focus(&ui.tree, rows[7], true)
	settle(&ui)
	frame(&ui.tree, {300, 300})
	off := scroll_offset(&ui.tree, sc).y
	testing.expect(t, off > 0, "scrolled to reveal the focused row")
	rd := node_get(&ui.tree, rows[7])
	sd := node_get(&ui.tree, sc)
	testing.expect(t, rd.abs.y >= sd.abs.y && rd.abs.y + rd.abs.h <= sd.abs.y + sd.abs.h + 0.5, "row is inside the viewport")
	// Page keys scroll the container that holds focus.
	testing.expect(t, key_event(&ui, .Home, true, {}))
	mid := scroll_offset(&ui.tree, sc).y
	testing.expect(t, mid > 0 && mid <= off, "a keyboard jump eases: not there yet")
	settle(&ui)
	testing.expect_value(t, scroll_offset(&ui.tree, sc).y, 0)
	testing.expect(t, key_event(&ui, .Page_Down, true, {}))
	settle(&ui)
	testing.expect_value(t, scroll_offset(&ui.tree, sc).y, 90)
	testing.expect(t, key_event(&ui, .End, true, {}))
	settle(&ui)
	testing.expect_value(t, scroll_offset(&ui.tree, sc).y, 200)
	testing.expect(t, key_event(&ui, .Page_Up, true, {}))
	settle(&ui)
	testing.expect_value(t, scroll_offset(&ui.tree, sc).y, 110)
}

// `list_node` hands out the list's own node, which `scroll_by` takes (`list`
// returns the row range). A `tag` on the plain container each row is drawn
// in is the only way a `pointer_track` handler, a plain proc, can learn
// which row it is on.
@(test)
a_list_hands_out_its_node_and_a_container_carries_a_tag :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	track :: proc(e: Ev(Pointer_At)) -> Ov_Msg { return {kind = .Pick, i = int(e.tag)} }
	inside, after: Node
	row_col: Node
	begin_view(&ui)
	column(&ui, flex = 1)
	first, last := list(&ui, 40, row_height = 30, label = "Blocks")
	inside = list_node(&ui) // asked for between `list` and its `end`
	for i in first ..< last {
		c := column(&ui, height = 30, tag = u64(i + 1)) // the row's own container, tagged
		if i == first {
			row_col = c
			pointer_track(&ui, c, track)
		}
		end(&ui)
	}
	end(&ui) // the list
	after = list_node(&ui) // the column's scope now: not a list's
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {300, 200})

	testing.expect(t, inside != NODE_NONE, "the list handed its node out")
	testing.expect(t, inside in ui.lists, "…and it is the node the list's own state hangs off")
	testing.expect_value(t, after, NODE_NONE) // asking outside a list is NODE_NONE, not a lie
	testing.expect_value(t, node_get(&ui.tree, row_col).tag, u64(1))

	// It is the node the scroll procs take.
	testing.expect(t, scroll_by(&ui.tree, inside, {0, 90}), "scroll_by moves the list by its node")
	testing.expect_value(t, scroll_offset(&ui.tree, inside).y, 90)

	// And the tag reaches the tracker, which is the whole point of it: the
	// handler is a plain proc and `Ev.tag` is all it has to go on.
	clear(&ui.msgs)
	rd := node_get(&ui.tree, row_col)
	pointer_move(&ui, {rd.abs.x + rd.abs.w / 2, rd.abs.y + rd.abs.h / 2})
	ui_after_events(&ui, ui.tree.now_ms + 1)
	found := false
	for m in ui.msgs do if m.kind == .Pick && m.i == 1 do found = true
	testing.expect(t, found, "the tracked row's handler heard its own tag")
}

// A window-level binding of Page Down beats a scroll the pointer is merely
// over: a click in a sidebar whose rows take no focus leaves the pointer
// there, and the binding (turn the page) must still fire. Focus inside a
// scroll still wins over the binding.
@(private = "file")
bound_page_view :: proc(ui: ^Ui(Ov_Msg), bind: bool) -> (sc: Node, row: Node) {
	begin_view(ui)
	if bind do shortcut(ui, "Page_Down", Ov_Msg{kind = .Pick, i = 9})
	column(ui, flex = 1)
	sc = scroll(ui, height = 100)
	for i in 0 ..< 10 {
		n := button(ui, fmt.tprintf("b%d", i), Ov_Msg{}, key = u64(i + 1))
		set_layout(&ui.tree, n, Layout_Props{height = 30})
		if i == 0 do row = n
	}
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {300, 300})
	return
}

@(test)
a_bound_page_key_beats_a_scroll_the_pointer_is_only_over :: proc(t: ^testing.T) {
	hover_over_the_scroll :: proc(t: ^testing.T, ui: ^Ui(Ov_Msg), sc: Node) {
		sd := node_get(&ui.tree, sc)
		pointer_move(ui, {sd.abs.x + sd.abs.w / 2, sd.abs.y + sd.abs.h / 2})
		testing.expect(t, ui.tree.scroll_hover == sc, "the pointer is over the scroll")
	}

	{ // the control: with nothing bound, hover scrolls
		ui: Ui(Ov_Msg)
		ui_init(&ui)
		defer ui_destroy(&ui)
		sc, _ := bound_page_view(&ui, false)
		hover_over_the_scroll(t, &ui, sc)
		testing.expect(t, key_event(&ui, .Page_Down, true, {}), "unbound, the hovered scroll takes it")
		settle(&ui)
		testing.expect_value(t, scroll_offset(&ui.tree, sc).y, 90)
	}
	{ // bound: the window's, and the contents stay where they were
		ui: Ui(Ov_Msg)
		ui_init(&ui)
		defer ui_destroy(&ui)
		sc, _ := bound_page_view(&ui, true)
		hover_over_the_scroll(t, &ui, sc)
		clear(&ui.msgs)
		testing.expect(t, !key_event(&ui, .Page_Down, true, {}), "bound, hover does not claim it")
		settle(&ui)
		testing.expect_value(t, scroll_offset(&ui.tree, sc).y, 0)
		testing.expect(t, shortcut_fire(&ui, .Page_Down, true, {}), "…so the window's shortcut fires")
		testing.expect_value(t, len(ui.msgs), 1)
		testing.expect_value(t, ui.msgs[0].i, 9)
	}
	{ // bound, but the keyboard is *inside* the scroll: it keeps the key
		ui: Ui(Ov_Msg)
		ui_init(&ui)
		defer ui_destroy(&ui)
		sc, row := bound_page_view(&ui, true)
		set_focus(&ui.tree, row, true)
		settle(&ui)
		testing.expect(t, key_event(&ui, .Page_Down, true, {}), "focus inside it still takes the key")
		settle(&ui)
		testing.expect_value(t, scroll_offset(&ui.tree, sc).y, 90)
	}
}

@(test)
scrollbar_reveals_on_hover_and_widens_in_its_zone :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	column(&ui, flex = 1)
	sc := scroll(&ui, height = 100)
	for i in 0 ..< 10 {
		b := box(&ui, height = 30, key = u64(i + 1))
		_ = b
	}
	end(&ui)
	end(&ui)
	end_view(&ui)
	ui_tick(&ui, 5000)
	frame(&ui.tree, {300, 300})
	sd := node_get(&ui.tree, sc)
	testing.expect(t, scrollbar_visible(&ui.tree, sc) == 0, "hidden at rest")
	pointer_move(&ui, {sd.abs.x + 20, sd.abs.y + 20})
	ui_tick(&ui, 9000)
	testing.expect_value(t, ui.tree.scroll_hover, sc)
	scrollbar_visible(&ui.tree, sc) // starts the fade-in
	ui_tick(&ui, 10_000)
	v := scrollbar_visible(&ui.tree, sc)
	testing.expect(t, v > 0.5 && v < 0.6, "dimmed bar while the pointer is inside")
	track, _, _ := scrollbar_geometry(&ui.tree, sc)
	testing.expect_value(t, track.w, SCROLLBAR_W)
	pointer_move(&ui, {sd.abs.x + sd.abs.w - 5, sd.abs.y + 20})
	ui_tick(&ui, 13000)
	testing.expect_value(t, ui.tree.bar_hover, sc)
	track, _, _ = scrollbar_geometry(&ui.tree, sc)
	testing.expect_value(t, track.w, SCROLLBAR_W_WIDE)
	scrollbar_visible(&ui.tree, sc)
	ui_tick(&ui, 14_000)
	testing.expect(t, scrollbar_visible(&ui.tree, sc) > 0.99, "full when on the bar")
	// A press in the zone below the thumb jumps the thumb (track click).
	pointer_button(&ui, .Left, true, {sd.abs.x + sd.abs.w - 5, sd.abs.y + sd.abs.h - 6})
	testing.expect(t, scroll_offset(&ui.tree, sc).y > 0, "track click scrolled")
	pointer_button(&ui, .Left, false, {sd.abs.x + sd.abs.w - 5, sd.abs.y + sd.abs.h - 6})
	pointer_leave(&ui)
	ui_tick(&ui, 20_000)
	testing.expect_value(t, ui.tree.scroll_hover, NODE_NONE)
	testing.expect_value(t, ui.tree.bar_hover, NODE_NONE)
}

@(test)
scroll_keyboard_focus_scrolls_a_row_horizontally :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	column(&ui, align = .Start)
	sc := scroll(&ui, .Row, width = 200)
	items: [6]Node
	for i in 0 ..< 6 {
		items[i] = button(&ui, fmt.tprintf("tab %d", i), Ov_Msg{}, key = u64(i + 1))
		set_layout(&ui.tree, items[i], Layout_Props{width = 80, height = 30})
	}
	end(&ui)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {300, 300})
	testing.expect_value(t, scroll_offset(&ui.tree, sc).x, 0)
	set_focus(&ui.tree, items[4], true)
	settle(&ui)
	frame(&ui.tree, {300, 300})
	testing.expect(t, scroll_offset(&ui.tree, sc).x > 0, "scrolled right to reveal the focused item")
	id := node_get(&ui.tree, items[4])
	sd := node_get(&ui.tree, sc)
	testing.expect(t, id.abs.x >= sd.abs.x && id.abs.x + id.abs.w <= sd.abs.x + sd.abs.w + 0.5, "item is inside the viewport")
	set_focus(&ui.tree, items[0], true)
	settle(&ui)
	frame(&ui.tree, {300, 300})
	testing.expect_value(t, scroll_offset(&ui.tree, sc).x, 0)
}

// A list makes every row exactly row_height tall and clips it, whatever the
// row's content asked for: overflow must never paint into the next row.
@(test)
list_rows_are_row_height_tall_and_clipped :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {300, 300})
	begin_view(&ui)
	first, last := list(&ui, 20, row_height = 40, label = "Rows")
	rows := make([dynamic]Node, context.temp_allocator)
	for i in first ..< last {
		r := card(&ui, key = u64(i + 1)) // no height given, and content taller than the row
		box(&ui, height = 90)
		end(&ui)
		append(&rows, r)
	}
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {300, 300})
	testing.expect(t, len(rows) > 2)
	for r, i in rows {
		d := node_get(&ui.tree, r)
		testing.expectf(t, d.abs.h == 40, "row %d is row_height tall, got %g", i, d.abs.h)
		testing.expect(t, .Clips in d.flags, "and clips its content")
		if i > 0 do testing.expect_value(t, d.abs.y, node_get(&ui.tree, rows[i - 1]).abs.y + 40)
	}
}

} // when ODIN_TEST