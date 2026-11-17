package baldr

@(require) import "core:testing"

when ODIN_TEST || #config(BALDR_TESTS, false) {

// A list whose rows are wider than it: a document zoomed past "fit width"
// draws each page as a row. Without `content_width`, layout's deficit pass
// (where a box has no floor) squeezes each page into the list's width.
// `content_width` lays the rows out that wide and the list pans across
// them, with a bar along its bottom.

@(private = "file")
Lbw_Msg :: enum { None }

// lbw_view builds a 600x400 list of 20 pages, each `page_w` wide, in a list
// `content_width` wide. Returns the list's node and its first built row.
@(private = "file")
lbw_view :: proc(ui: ^Ui(Lbw_Msg), content_width: f32, page_w: f32 = 1500, odd_page_w: f32 = 0) -> (list_n, first_row: Node) {
	begin_view(ui)
	column(ui, flex = 1)
	first, last := list(ui, 20, row_height = 100, content_width = content_width, label = "Pages")
	list_n = list_node(ui)
	for i in first ..< last {
		r := row(ui, key = u64(i + 1))
		if i == first do first_row = r
		w := odd_page_w if odd_page_w > 0 && i % 2 == 1 else page_w
		box(ui, width = w, height = 100)
		end(ui)
	}
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	return
}

// lbw_rect_count is how many rects in `cmds` are exactly `want`.
@(private = "file")
lbw_rect_count :: proc(cmds: []Draw_Cmd, want: Rect) -> (n: int) {
	for c in cmds do if r, ok := c.(Draw_Rect); ok && r.rect == want do n += 1
	return
}

// lbw_fades is how many of the gradient rects emit_scroll_fades draws are in
// `cmds` (a rect fading sideways to nothing).
@(private = "file")
lbw_fades :: proc(cmds: []Draw_Cmd) -> (n: int) {
	for c in cmds {
		if r, ok := c.(Draw_Rect); ok && r.horizontal && (r.color.a == 0 || r.color2.a == 0) do n += 1
	}
	return
}

@(test)
a_lists_rows_keep_their_width_and_it_pans_sideways :: proc(t: ^testing.T) {
	ui: Ui(Lbw_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree
	n, row_n := lbw_view(&ui, 1600)
	ld, rd := node_get(tr, n), node_get(tr, row_n)
	testing.expect(t, ld != nil && rd != nil, "the list built a row")
	if ld == nil || rd == nil do return
	page := node_get(tr, node_first(tr, row_n))
	testing.expect(t, page != nil, "the row built its page")
	if page == nil do return

	testing.expect_value(t, ld.rect.w, 600) // the list is still the window's width…
	testing.expect_value(t, rd.rect.w, 1600) // …and its rows are as wide as the content
	testing.expect_value(t, page.rect.w, 1500) // the page is not squeezed into the viewport
	st := tr.scrolls[n]
	testing.expect_value(t, st.content.x, 1600)
	testing.expect_value(t, st.viewport.x, 600)

	testing.expect(t, scroll_by(tr, n, {400, 0}), "it pans sideways")
	testing.expect_value(t, scroll_offset(tr, n).x, 400)
	lbw_view(&ui, 1600)
	testing.expect_value(t, node_get(tr, row_n).abs.x, ld.abs.x - 400)
	testing.expect(t, scroll_by(tr, n, {1000, 0}), "it pans on") // …to the end: 1600 - 600
	testing.expect_value(t, scroll_offset(tr, n).x, 1000)
	testing.expect(t, !scroll_by(tr, n, {1000, 0}), "and stops there")
}

// A list left to size itself — in a column that does not stretch its
// children — takes the content width for its rows all the same, through the
// shrink-wrapped stretch rather than the stretched one.
@(test)
a_list_that_sizes_itself_still_takes_the_content_width :: proc(t: ^testing.T) {
	ui: Ui(Lbw_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree
	list_n, row_n: Node
	begin_view(&ui)
	column(&ui, flex = 1, align = .Start) // …so the list's width is loose
	first, last := list(&ui, 20, row_height = 100, content_width = 1600, height = 300, label = "Pages")
	list_n = list_node(&ui)
	for i in first ..< last {
		r := row(&ui, key = u64(i + 1))
		if i == first do row_n = r
		box(&ui, width = 900, height = 100)
		end(&ui)
	}
	end(&ui)
	end(&ui)
	end_view(&ui)
	frame(tr, {600, 400})

	testing.expect_value(t, node_get(tr, row_n).rect.w, 1600) // not the 900 the page asks for
	testing.expect_value(t, tr.scrolls[list_n].content.x, 1600)
}

// A page wider than the width the app gave keeps its width, and the rows
// around it are widened to match, so every row still lines up.
@(test)
a_row_wider_than_the_content_width_takes_the_others_with_it :: proc(t: ^testing.T) {
	ui: Ui(Lbw_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree
	n, row_n := lbw_view(&ui, 1600, page_w = 2000, odd_page_w = 800) // one page wide, the next narrow
	testing.expect_value(t, node_get(tr, row_n).rect.w, 2000)
	testing.expect_value(t, tr.scrolls[n].content.x, 2000)
	for c := node_first(tr, n); c != NODE_NONE; c = node_next(tr, c) {
		cd := node_get(tr, c)
		if cd.rect.h != 100 do continue // the two spacers that stand for the rows not built
		testing.expect_value(t, cd.rect.w, 2000)
	}
}

// The width the app gave is the width of the content, whether or not any row
// needs it: the rows are stretched to it and the list pans across it, so a
// row's hover wash and selection reach the far side like every other row's.
@(test)
every_row_takes_the_content_width_even_where_none_needs_it :: proc(t: ^testing.T) {
	ui: Ui(Lbw_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree
	n, row_n := lbw_view(&ui, 1600, page_w = 300) // every page narrower than the list itself
	testing.expect_value(t, node_get(tr, row_n).rect.w, 1600)
	testing.expect_value(t, tr.scrolls[n].content.x, 1600)
	testing.expect(t, scroll_by(tr, n, {500, 0}), "and it still pans")
}

// Both bars are drawn, each along its own edge of the viewport, and neither
// runs into the other's end.
@(test)
a_list_that_scrolls_both_ways_has_a_bar_on_each_edge :: proc(t: ^testing.T) {
	ui: Ui(Lbw_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree
	tr.theme.motion.reduce = true // the bars show at once rather than fading in over a clock the test does not run
	n, _ := lbw_view(&ui, 1600)
	scroll_by(tr, n, {100, 100}) // activity: the bars are showing
	lbw_view(&ui, 1600)
	ld := node_get(tr, n)

	vt, vth, vok := scrollbar_geometry(tr, n, 1)
	ht, hth, hok := scrollbar_geometry(tr, n, 0)
	testing.expect(t, vok && hok, "a bar for each axis")
	if !vok || !hok do return
	testing.expect(t, vt.x + vt.w > ld.abs.x + ld.abs.w - SCROLLBAR_GUTTER, "the vertical one at the right edge")
	testing.expect(t, ht.y + ht.h > ld.abs.y + ld.abs.h - SCROLLBAR_GUTTER, "the horizontal one along the bottom")
	testing.expect_value(t, vt.y + vt.h, ld.abs.y + ld.abs.h - SCROLLBAR_MARGIN - SCROLLBAR_GUTTER) // each stops short of the other's end
	testing.expect_value(t, ht.x + ht.w, ld.abs.x + ld.abs.w - SCROLLBAR_MARGIN - SCROLLBAR_GUTTER)

	l, has := &tr.layers[n]
	testing.expect(t, has, "the list owns a layer")
	if !has do return
	for want in ([]Rect{vt, vth, ht, hth}) {
		testing.expect(t, lbw_rect_count(l.cmds[:], want) == 1, "each track and thumb is drawn once")
	}
	testing.expect_value(t, lbw_fades(l.cmds[:]), 0) // bars, not fades lying over the pages' edges

	// The pointer in one bar's zone widens that bar, and only it.
	pointer_move(&ui, {ht.x + ht.w / 2, ld.abs.y + ld.abs.h - 4})
	testing.expect(t, tr.bar_hover == n && tr.bar_hover_axis == 0, "the pointer is on the bottom bar")
	wide, _, _ := scrollbar_geometry(tr, n, 0)
	tall, _, _ := scrollbar_geometry(tr, n, 1)
	testing.expect_value(t, wide.h, SCROLLBAR_W_WIDE)
	testing.expect_value(t, tall.w, SCROLLBAR_W)
}

// A strip that only scrolls sideways (a tab bar, a chip row) keeps its
// fades; a bar there would be furniture.
@(test)
a_strip_that_only_scrolls_sideways_keeps_its_fades :: proc(t: ^testing.T) {
	ui: Ui(Lbw_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree
	strip: Node
	begin_view(&ui)
	column(&ui, flex = 1)
	strip = scroll(&ui, .Row, height = 40, bg = tr.theme.color.surface)
	for i in 0 ..< 10 do box(&ui, width = 120, height = 40, key = u64(i + 1))
	end(&ui)
	end(&ui)
	end_view(&ui)
	frame(tr, {600, 400})
	scroll_by(tr, strip, {100, 0})
	frame(tr, {600, 400})

	l, has := &tr.layers[strip]
	testing.expect(t, has, "the strip owns a layer")
	if !has do return
	testing.expect(t, lbw_fades(l.cmds[:]) > 0, "its clipped ends still fade")
	_, _, hok := scrollbar_geometry(tr, strip, 0)
	testing.expect(t, hok, "it has the geometry for a bar…")
	if !hok do return
	ht, hth, _ := scrollbar_geometry(tr, strip, 0)
	testing.expect_value(t, lbw_rect_count(l.cmds[:], ht), 0) // …and deliberately draws none
	testing.expect_value(t, lbw_rect_count(l.cmds[:], hth), 0)
}

// The bar along the bottom takes a press and drags the list sideways; the
// corner, where the two zones meet, stays the vertical bar's.
@(test)
the_bar_along_the_bottom_drags_the_list_sideways :: proc(t: ^testing.T) {
	ui: Ui(Lbw_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree
	n, _ := lbw_view(&ui, 1600)
	ld := node_get(tr, n)
	_, hth, ok := scrollbar_geometry(tr, n, 0)
	testing.expect(t, ok, "a horizontal bar")
	if !ok do return

	on_thumb := [2]f32{hth.x + hth.w / 2, ld.abs.y + ld.abs.h - 4}
	testing.expect(t, scrollbar_press(tr, n, on_thumb), "the press goes to the bar")
	testing.expect(t, tr.scrolls[n].thumb_drag && tr.scrolls[n].thumb_axis == 0, "dragging the horizontal thumb")
	testing.expect(t, scrollbar_drag(tr, n, on_thumb + {120, 0}), "and it moves")
	moved := scroll_offset(tr, n)
	testing.expect(t, moved.x > 200 && moved.y == 0, "sideways only")
	scrollbar_release(tr, n)

	// The corner the two tracks leave between them is neither bar's: a
	// press there goes to the content, as it does in every toolkit that
	// stops one bar short of the other.
	corner := [2]f32{ld.abs.x + ld.abs.w - 4, ld.abs.y + ld.abs.h - 4}
	testing.expect(t, !scrollbar_press(tr, n, corner), "the corner between them is neither bar's")
	// Just above it is the vertical bar's, and that zone wins wherever the
	// two overlap.
	above := [2]f32{corner.x, ld.abs.y + ld.abs.h - SCROLLBAR_GUTTER - 6}
	testing.expect(t, scrollbar_press(tr, n, above), "the strip above it is the vertical bar's")
	testing.expect_value(t, tr.scrolls[n].thumb_axis, 1)
	scrollbar_release(tr, n)
}

// Shift turns the paging keys sideways where there is a sideways to go, so
// the pan is not the wheel's alone.
@(test)
shift_pages_a_list_sideways :: proc(t: ^testing.T) {
	ui: Ui(Lbw_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree
	n, _ := lbw_view(&ui, 1600)
	ld := node_get(tr, n)
	pointer_move(&ui, {ld.abs.x + ld.abs.w / 2, ld.abs.y + ld.abs.h / 2})
	testing.expect(t, tr.scroll_hover == n, "the pointer is over the list")

	testing.expect(t, scroll_key(tr, .Page_Down, true, {}), "Page Down pages it down")
	settle(&ui)
	testing.expect(t, scroll_offset(tr, n).y > 300 && scroll_offset(tr, n).x == 0, "down, not across")

	testing.expect(t, scroll_key(tr, .Page_Down, true, {.Shift}), "Shift+Page Down pages it across")
	settle(&ui)
	testing.expect_value(t, scroll_offset(tr, n).x, 540) // 600 viewport, nine tenths of it
	testing.expect(t, scroll_key(tr, .End, true, {.Shift}), "Shift+End goes to the far side")
	settle(&ui)
	testing.expect_value(t, scroll_offset(tr, n).x, 1000)
}

}
