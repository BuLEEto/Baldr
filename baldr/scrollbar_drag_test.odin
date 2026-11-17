package baldr

// Dragging a scroll bar's thumb down a long virtualised view. The wheel and
// the bar are different paths: one adds a delta, the other sets the offset
// from where the thumb now is, and only the second can move the view by a
// whole screen between two frames. So this holds the thumb, drags it the
// length of the bar, and after every frame asks whether there is a row range
// at all and whether any rows were built and drawn.

@(require) import "core:fmt"
@(require) import "core:testing"

when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Sbd_Msg :: enum { None }

@(private = "file")
SBD_COLS := []Column{{title = "Name", width = 220}, {title = "Size", width = 90}}

@(private = "file")
Sbd_Fx :: struct {
	ui:          Ui(Sbd_Msg),
	sel:         Selection,
	first, last: int,
	rows_built:  int,
}

// sbd_view rebuilds the table and records what it was asked to build.
@(private = "file")
sbd_view :: proc(fx: ^Sbd_Fx) {
	set_viewport(&fx.ui.tree, {400, 300})
	begin_view(&fx.ui)
	column(&fx.ui, flex = 1)
	first, last := table(&fx.ui, SBD_COLS, 100_000, &fx.sel, label = "Files", key = 3)
	fx.first, fx.last, fx.rows_built = first, last, 0
	for i in first ..< last {
		table_row(&fx.ui, i)
		cell_text(&fx.ui, fmt.tprintf("file-%06d.txt", i))
		cell_text(&fx.ui, "1 KB")
		end(&fx.ui)
		fx.rows_built += 1
	}
	end(&fx.ui)
	end_view(&fx.ui)
	frame(&fx.ui.tree, {400, 300})
}

// sbd_glyphs counts the text actually painted this frame: a row that was
// built but not drawn is a blank view all the same.
@(private = "file")
sbd_glyphs :: proc(t: ^Tree) -> int {
	n := 0
	for c in draw_list(t) {
		if _, is_text := c.(Draw_Text); is_text do n += 1
	}
	return n
}

// sbd_scroller is the first node under `n` that scrolls vertically.
@(private = "file")
sbd_scroller :: proc(t: ^Tree, n: Node) -> Node {
	d := node_get(t, n)
	if d == nil do return NODE_NONE
	if .Scroll_V in d.flags do return n
	for c := d.first; c != NODE_NONE; c = node_get(t, c).next {
		if got := sbd_scroller(t, c); got != NODE_NONE do return got
	}
	return NODE_NONE
}

@(test)
dragging_a_scroll_bar_keeps_the_rows_on_screen :: proc(t: ^testing.T) {
	fx: Sbd_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	fx.sel = selection_make(multi = true)
	defer selection_destroy(&fx.sel)

	sbd_view(&fx)
	// The bar belongs to whichever node actually scrolls, which is not the
	// table node itself — a table puts its rows in a scrolling child.
	view := sbd_scroller(&fx.ui.tree, fx.ui.root)
	if !testing.expect(t, view != NODE_NONE, "something in the table scrolls") do return
	zone, has_bar := scrollbar_zone(&fx.ui.tree, view)
	if !testing.expect(t, has_bar, "a table of 100 000 rows has a scroll bar") do return
	testing.expect(t, fx.rows_built > 0, "it starts with rows")

	// take hold of the thumb at the top of the bar
	grab := [2]f32{zone.x + zone.w * 0.5, zone.y + 4}
	pointer_move(&fx.ui, grab, moved = true)
	pointer_button(&fx.ui, .Left, true, grab)
	sbd_view(&fx)

	// …and drag it the length of the bar, a frame at a time
	steps := 20
	for s in 1 ..= steps {
		y := zone.y + zone.h * (f32(s) / f32(steps))
		pointer_move(&fx.ui, {grab.x, y}, moved = true)
		sbd_view(&fx)
		testing.expectf(t, fx.last > fx.first,
			"step %d of the drag asked for a range of rows (got %d..<%d)", s, fx.first, fx.last)
		testing.expectf(t, fx.rows_built > 0,
			"step %d of the drag built rows (range %d..<%d)", s, fx.first, fx.last)
		// …and that they were *drawn*: building a row and painting it are
		// different things.
		testing.expectf(t, sbd_glyphs(&fx.ui.tree) > 0,
			"step %d of the drag drew something (range %d..<%d)", s, fx.first, fx.last)
	}
	pointer_button(&fx.ui, .Left, false, {grab.x, zone.y + zone.h})
	sbd_view(&fx)
	testing.expect(t, fx.rows_built > 0, "and it still has rows once the thumb is let go")
}

// sbd_in_view counts the text drawn *inside* the scrolling area. The header
// titles sit outside it, so this is rows and nothing else: zero is a blank
// view.
@(private = "file")
sbd_in_view :: proc(t: ^Tree, view: Node) -> int {
	d := node_get(t, view)
	if d == nil do return 0
	n := 0
	for c in draw_list(t) {
		tx, is_text := c.(Draw_Text)
		if !is_text do continue
		if tx.pos.y >= d.abs.y && tx.pos.y < d.abs.y + d.abs.h &&
		   tx.pos.x >= d.abs.x && tx.pos.x < d.abs.x + d.abs.w {
			n += 1
		}
	}
	return n
}

// sbd_step is one turn of the real run loop: let the toolkit react to what
// the pointer did, and build the view again only if it asked to be. The
// test above rebuilds every step whatever happens, so it cannot tell a
// rebuilt view from one that was never asked for; this one can.
@(private = "file")
sbd_step :: proc(fx: ^Sbd_Fx, now: f64) -> (rebuilt: bool) {
	ui_after_events(&fx.ui, now)
	if fx.ui.needs_rebuild {
		fx.ui.needs_rebuild = false
		sbd_view(fx)
		return true
	}
	frame(&fx.ui.tree, {400, 300}) // no rebuild: lay out and paint what is there
	return false
}

@(test)
a_scroll_bar_drag_asks_for_the_rows_it_scrolled_to :: proc(t: ^testing.T) {
	fx: Sbd_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	fx.sel = selection_make(multi = true)
	defer selection_destroy(&fx.sel)

	sbd_view(&fx)
	view := sbd_scroller(&fx.ui.tree, fx.ui.root)
	if !testing.expect(t, view != NODE_NONE, "something in the table scrolls") do return
	zone, has_bar := scrollbar_zone(&fx.ui.tree, view)
	if !testing.expect(t, has_bar, "a table of 100 000 rows has a scroll bar") do return
	testing.expect(t, sbd_in_view(&fx.ui.tree, view) > 0, "it starts with rows on screen")

	now: f64 = 0
	grab := [2]f32{zone.x + zone.w * 0.5, zone.y + 4}
	pointer_move(&fx.ui, grab, moved = true)
	pointer_button(&fx.ui, .Left, true, grab)
	now += 16
	sbd_step(&fx, now)

	steps := 20
	for s in 1 ..= steps {
		y := zone.y + zone.h * (f32(s) / f32(steps))
		pointer_move(&fx.ui, {grab.x, y}, moved = true)
		now += 16
		sbd_step(&fx, now)
		testing.expectf(t, sbd_in_view(&fx.ui.tree, view) > 0,
			"step %d of the drag has rows on screen (built %d..<%d, offset %.0f)",
			s, fx.first, fx.last, scroll_offset(&fx.ui.tree, view).y)
	}
	pointer_button(&fx.ui, .Left, false, {grab.x, zone.y + zone.h})
	now += 16
	sbd_step(&fx, now)
	testing.expect(t, sbd_in_view(&fx.ui.tree, view) > 0,
		"and rows are on screen once the thumb is let go")
}

// A scroll bar's step is not a wheel notch. One pointer sample of a thumb
// drag moves a 100 000-row list by hundreds of rows, so a frame laid out
// before the view is built again has no rows near the viewport and draws
// none; a wheel notch is 48 px and never leaves the built range.
//
// The run loop's own ordering lives in `run`, around a real backend, and
// cannot be executed here. This pins the two facts it depends on: a single
// step leaves the built range completely, and the toolkit asks for a
// rebuild before the next frame.
@(test)
one_bar_step_leaves_the_built_range_and_asks_for_a_rebuild :: proc(t: ^testing.T) {
	fx: Sbd_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	fx.sel = selection_make(multi = true)
	defer selection_destroy(&fx.sel)

	sbd_view(&fx)
	view := sbd_scroller(&fx.ui.tree, fx.ui.root)
	if !testing.expect(t, view != NODE_NONE, "something in the table scrolls") do return
	zone, has_bar := scrollbar_zone(&fx.ui.tree, view)
	if !testing.expect(t, has_bar, "a table of 100 000 rows has a scroll bar") do return

	grab := [2]f32{zone.x + zone.w * 0.5, zone.y + 4}
	pointer_move(&fx.ui, grab, moved = true)
	pointer_button(&fx.ui, .Left, true, grab)
	sbd_step(&fx, 16)
	built_first, built_last := fx.first, fx.last
	if !testing.expect(t, built_last > built_first, "rows were built before the step") do return

	// one pointer sample's worth of thumb travel — a few pixels
	pointer_move(&fx.ui, {grab.x, grab.y + 3}, moved = true)
	ui_after_events(&fx.ui, 32) // what the run loop does with the input it just dispatched

	testing.expect(t, fx.ui.needs_rebuild,
		"three pixels of thumb asks for the view to be built again before the next frame")

	st, has_state := fx.ui.lists[view]
	if !testing.expect(t, has_state, "the scrolling node is a virtual list") do return
	now_first, now_last := list_range(&fx.ui.tree, view, st)
	testing.expectf(t, now_first >= built_last || now_last <= built_first,
		"three pixels of thumb moved past everything that was built (built %d..<%d, now %d..<%d) — "+
		"so a frame drawn from the old build would have had no rows at all",
		built_first, built_last, now_first, now_last)
}

}
