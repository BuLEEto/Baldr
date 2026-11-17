package baldr

@(require) import "core:testing"

// A chat's rows grow after they were measured: a picture is a placeholder
// until it decodes, a link preview is a title until its image lands, a
// reaction chip appears under a bubble laid out a minute ago.
//
// A row arriving is `count` changing, which `list_keep_place` is told about.
// A row growing is not: only a number in the heights map changes, and if the
// row is above the reader everything below it slides by the difference. As
// with a prepend, the visible content must stay where it is.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Gr_Msg :: union { List_At }

@(private = "file")
GR_ROWS :: 200

@(private = "file")
GR_VIEW :: [2]f32{520, 600}

@(private = "file")
gr_key_of :: proc(user: rawptr, index: int) -> u64 { return u64(index + 1) * 10 }

// The app's own heights, so a test can make one row grow the way a decoded
// picture does. Everything else is a one-line message.
@(private = "file")
Gr_Feed :: struct {
	tall: map[int]f32,
}

@(private = "file")
gr_height :: proc(f: ^Gr_Feed, i: int) -> f32 {
	if h, ok := f.tall[i]; ok do return h
	return 64
}

@(private = "file")
gr_build :: proc(ui: ^Ui(Gr_Msg), f: ^Gr_Feed, count := GR_ROWS) -> Node {
	set_viewport(&ui.tree, GR_VIEW)
	begin_view(ui)
	column(ui, flex = 1)
	first, last := list(ui, count, estimated_height = 72, key_of = gr_key_of, follow_end = true,
		gap = .xs, padding = .sm, gutter = true, key = 1)
	n := ui.scopes[len(ui.scopes) - 1].node
	for i in first ..< last {
		box(ui, height = gr_height(f, i), key = gr_key_of(nil, i))
	}
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, GR_VIEW)
	return n
}

// where row `i` is drawn on screen, or nothing if it is not built
@(private = "file")
gr_row_y :: proc(ui: ^Ui(Gr_Msg), n: Node, i: int) -> (y: f32, built: bool) {
	t := &ui.tree
	key := gr_key_of(nil, i)
	for c := node_first(t, n); c != NODE_NONE; c = node_next(t, c) {
		d := node_get(t, c)
		if d != nil && d.key == key do return d.abs.y, true
	}
	return 0, false
}

// Reading back through a chat while the pictures above decode: each one
// that grows would push everything below it down, and the message being
// read would walk off the screen.
@(test)
a_row_growing_above_the_reader_does_not_move_what_they_are_reading :: proc(t: ^testing.T) {
	ui: Ui(Gr_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	f: Gr_Feed
	defer delete(f.tall)
	n: Node
	for _ in 0 ..< 6 do n = gr_build(&ui, &f)

	// read back up the conversation, and let it settle there
	scroll_to(&ui.tree, n, {0, 5000})
	for _ in 0 ..< 4 do gr_build(&ui, &f)
	st := ui.lists[n]
	testing.expect(t, !st.following, "reading further up is not riding the end")
	mid := (st.first + st.last) / 2
	before, built := gr_row_y(&ui, n, mid)
	testing.expect(t, built, "the row being read is on screen")

	// a picture two rows above the top of the viewport decodes: 64 -> 320
	f.tall[st.first] = 320
	for _ in 0 ..< 3 do gr_build(&ui, &f)

	after, still := gr_row_y(&ui, n, mid)
	testing.expect(t, still, "it is still built")
	testing.expectf(t, abs(after - before) < 2,
		"the message being read stayed under the same pixel (%.0f, was %.0f)", after, before)
}

// The same event at the other end: a reaction chip appears under a bubble
// below the viewport. Nothing the reader can see has changed, so nothing
// they can see may move.
@(test)
a_row_growing_below_the_reader_does_not_move_the_view :: proc(t: ^testing.T) {
	ui: Ui(Gr_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	f: Gr_Feed
	defer delete(f.tall)
	n: Node
	for _ in 0 ..< 6 do n = gr_build(&ui, &f)
	scroll_to(&ui.tree, n, {0, 5000})
	for _ in 0 ..< 4 do gr_build(&ui, &f)
	st := ui.lists[n]
	mid := (st.first + st.last) / 2
	before, _ := gr_row_y(&ui, n, mid)

	f.tall[st.last - 1] = 260 // a reaction strip on a bubble below the fold
	for _ in 0 ..< 3 do gr_build(&ui, &f)

	after, _ := gr_row_y(&ui, n, mid)
	testing.expectf(t, abs(after - before) < 2,
		"the view did not move (%.0f, was %.0f)", after, before)
}

// And while riding the newest message: the picture in the bubble you are
// looking at decodes and the bubble grows under you. Following means the
// chat stays on its last message, not that it keeps the old offset.
@(test)
a_row_growing_while_following_keeps_the_view_on_the_newest :: proc(t: ^testing.T) {
	ui: Ui(Gr_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	f: Gr_Feed
	defer delete(f.tall)
	n: Node
	for _ in 0 ..< 6 do n = gr_build(&ui, &f)
	sc := ui.tree.scrolls[n]
	testing.expect(t, sc.offset.y >= list_max_off(sc) - SCROLL_END_EPS, "it opens on the newest message")

	f.tall[GR_ROWS - 1] = 420 // the newest message is a picture, and it decodes
	for _ in 0 ..< 3 do gr_build(&ui, &f)

	sc = ui.tree.scrolls[n]
	testing.expectf(t, sc.offset.y >= list_max_off(sc) - SCROLL_END_EPS,
		"still on it after it grew (%.0f of %.0f)", sc.offset.y, list_max_off(sc))
	y, built := gr_row_y(&ui, n, GR_ROWS - 1)
	d := node_get(&ui.tree, n)
	testing.expect(t, built, "the newest row is built")
	testing.expectf(t, y + 420 <= d.abs.y + d.abs.h + 2,
		"and its bottom is on screen (%.0f + 420 vs %.0f)", y, d.abs.y + d.abs.h)
}

// Scrolling while rows decode: the list puts the reader's place back on the
// build after a row grew, and that place must be where they have scrolled
// to, not where they were when the last build ended, or every notch is
// undone by the next picture.
@(test)
scrolling_while_rows_above_grow_keeps_the_scrolling :: proc(t: ^testing.T) {
	ui: Ui(Gr_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	f: Gr_Feed
	defer delete(f.tall)
	n: Node
	for _ in 0 ..< 6 do n = gr_build(&ui, &f)
	scroll_to(&ui.tree, n, {0, 5000})
	for _ in 0 ..< 4 do gr_build(&ui, &f)

	// the run loop: a notch, then a build only if the list asks for one
	notch :: proc(ui: ^Ui(Gr_Msg), f: ^Gr_Feed, n: Node) {
		scroll_by(&ui.tree, n, {0, -SCROLL_STEP_PX})
		list_tick(ui)
		if ui.needs_rebuild {
			ui.needs_rebuild = false
			gr_build(ui, f)
			return
		}
		frame(&ui.tree, GR_VIEW)
	}
	start := scroll_offset(&ui.tree, n).y
	grown: f32
	for i in 0 ..< 8 {
		if i == 2 { // a picture just above the window decodes, mid-scroll
			// It has to be a row the list is building: one further up
			// than the overscan has never been measured, so changing what
			// the app would draw there changes nothing until it is reached.
			f.tall[ui.lists[n].first] = 320
			grown = 320 - 64
		}
		notch(&ui, &f, n)
	}
	moved := start - scroll_offset(&ui.tree, n).y
	// Eight notches up, less the content that grew above them and pushed
	// the offset back down by its own height: the reader still travelled.
	testing.expectf(t, moved >= SCROLL_STEP_PX * 7 - grown,
		"eight notches still moved them up the conversation (%.0f px, %.0f of which the growth gave back)", moved, grown)
}

// A scroll small enough not to change which rows are built asks for no
// build, so the list hears about it only when something else causes one.
// Putting back the place noted at the end of the last build would quietly
// undo that nudge.
@(test)
a_scroll_too_small_to_rebuild_survives_a_row_growing :: proc(t: ^testing.T) {
	ui: Ui(Gr_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	f: Gr_Feed
	defer delete(f.tall)
	n: Node
	for _ in 0 ..< 6 do n = gr_build(&ui, &f)
	scroll_to(&ui.tree, n, {0, 5000})
	for _ in 0 ..< 4 do gr_build(&ui, &f)

	NUDGE :: f32(30) // less than a row: the visible range does not move
	scroll_by(&ui.tree, n, {0, -NUDGE})
	list_tick(&ui)
	testing.expect(t, !ui.needs_rebuild, "a nudge this small asks for no build")
	nudged := scroll_offset(&ui.tree, n).y

	f.tall[ui.lists[n].first] = 320 // the picture just above the window decodes
	for _ in 0 ..< 3 do gr_build(&ui, &f)

	// the content above them grew by 256, so the offset must grow with it to
	// leave the same message under their eye — and their nudge is still in it
	want := nudged + (320 - 64)
	got := scroll_offset(&ui.tree, n).y
	testing.expectf(t, abs(got - want) < 8,
		"their nudge survived the picture (%.0f, wanted %.0f — %.0f px of it was lost)", got, want, want - got)
}

}
