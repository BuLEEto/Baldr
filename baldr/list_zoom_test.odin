package baldr

@(require) import "core:testing"

// A list whose every row changes height at once: a document zoomed.
//
// The estimating path converges over builds, which a zoom defeats: every
// measurement describes the old scale, and a pan made in the same build is
// clamped to the width the last layout left. `height_of` is for a list that
// knows its heights: nothing estimated or measured, the offsets exact in the
// same build as the new scale. `hold` and `hold_at` keep a point of a page,
// or whatever is at a spot of the viewport, where it is across the zoom.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Lz_Msg :: union { int }

@(private = "file")
LZ_COUNT :: 400

@(private = "file")
LZ_VIEW :: [2]f32{600, 400}

// A document of portrait pages with a landscape one every seventh, so
// nothing can pass by assuming one pitch.
@(private = "file")
lz_base :: proc(i: int) -> f32 {
	return 220 if i % 7 == 3 else 300
}

@(private = "file")
Lz_State :: struct {
	scale:    f32,
	gen:      u64, // bumped at each zoom and folded into the row keys
	estimate: f32, // > 0: the estimating path instead of height_of
	width:    f32, // content_width: the widest page at this zoom
	pan:      f32, // where the app pans to, from inside the build
	grow:     f32, // a row that lays itself out taller than it was told
	page_w:   f32, // > 0: a page of this width centred in a content_width-wide row
	hold:     u64,
	point:    [2]f32,
	at:       [2]f32,
	hold_ask: bool, // ask on this build, the way `update` returns the command once
	axes:     Hold_Axes, // which offsets the hold may move; {} is both
	spot:     [2]f32,    // `hold_at`: the spot of the viewport to keep
	spot_ask: bool,      // …asked on this build, once
}

@(private = "file")
lz_height :: proc(user: rawptr, i: int) -> f32 {
	s := (^Lz_State)(user)
	return lz_base(i) * s.scale
}

// The app's row keys carry its zoom generation, which is how an estimating
// list is told that the heights measured for the old keys are no use.
@(private = "file")
lz_key :: proc(user: rawptr, i: int) -> u64 {
	s := (^Lz_State)(user)
	return (s.gen << 32) | u64(i + 1)
}

@(private = "file")
lz_build :: proc(ui: ^Ui(Lz_Msg), s: ^Lz_State) -> (n: Node, first, last: int) {
	set_viewport(&ui.tree, LZ_VIEW)
	begin_view(ui)
	column(ui, flex = 1)
	// The `hold` command (reveal_cmd.odin), put before the build that acts
	// on it and spent by it, as `update` returns it beside the zoom.
	if s.hold_ask {
		hold_put(ui, Hold_Ask{view = 1, key = s.hold, point = s.point, at = s.at, axes = s.axes})
		s.hold_ask = false
	}
	// `hold_at`: no row named, so there is nothing for the app to have
	// noted and nothing of its to go stale.
	if s.spot_ask {
		hold_put(ui, Hold_Ask{view = 1, at = s.spot, axes = s.axes, by_spot = true})
		s.spot_ask = false
	}
	first, last = list(ui, LZ_COUNT,
		estimated_height = s.estimate, height_of = nil if s.estimate > 0 else lz_height,
		key_of = lz_key, key_user = s, content_width = s.width,
		label = "Pages", key = 1)
	n = ui.scopes[len(ui.scopes) - 1].node
	// A pan the app makes from the build that changed the zoom, which is
	// what keeping the point under the pointer still asks for sideways.
	if s.pan > 0 do scroll_to(&ui.tree, n, {s.pan, scroll_offset(&ui.tree, n).y})
	for i in first ..< last {
		if s.page_w > 0 { // a page centred in a row as wide as the content
			row(ui, justify = .Center, height = lz_height(s, i), key = lz_key(s, i))
			card(ui, width = s.page_w, height = lz_height(s, i), key = 1)
			end(ui)
			end(ui)
			continue
		}
		card(ui, height = lz_height(s, i) + s.grow, key = lz_key(s, i))
		end(ui)
	}
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, LZ_VIEW)
	return
}

@(private = "file")
lz_settle :: proc(ui: ^Ui(Lz_Msg), s: ^Lz_State, passes := 6) -> (n: Node, first, last: int) {
	for _ in 0 ..< passes do n, first, last = lz_build(ui, s)
	return
}

// The row built with this key, which is also the proof it was built.
@(private = "file")
lz_row :: proc(t: ^Tree, n: Node, key: u64) -> Node {
	for c := node_first(t, n); c != NODE_NONE; c = node_next(t, c) {
		d := node_get(t, c)
		if d != nil && d.key == key do return c
	}
	return NODE_NONE
}

// A list told its heights places every row from them, on the first
// build: no estimate, no measurement, nothing to converge on.
@(test)
a_list_told_its_heights_is_exact_at_once :: proc(t: ^testing.T) {
	ui: Ui(Lz_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	s := Lz_State{scale = 1}
	n, _, _ := lz_build(&ui, &s)
	st := &ui.lists[n]
	testing.expect(t, st != nil, "the list has state")
	testing.expect_value(t, len(st.heights), 0) // nothing was measured

	want: f32
	for i in 0 ..< LZ_COUNT {
		testing.expectf(t, abs(list_top(st^, i) - want) < 0.01, "row %d is at %.1f, should be %.1f",
			i, list_top(st^, i), want)
		want += lz_base(i) * s.scale + st.gap
	}
	if LZ_COUNT > 0 do want -= st.gap
	testing.expectf(t, abs(list_height(st^) - want) < 0.01, "the document is %.1f tall, should be %.1f",
		list_height(st^), want)
}

// A zoom is noticed from the rows on screen answering a different height,
// without the app being made to say so — and in the same build, so nothing
// is ever placed from the old scale.
@(test)
a_zoom_works_the_offsets_out_again_in_the_same_build :: proc(t: ^testing.T) {
	ui: Ui(Lz_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	s := Lz_State{scale = 1}
	n, _, _ := lz_settle(&ui, &s)
	st := &ui.lists[n]
	was := list_top(st^, 40)

	s.scale = 2
	lz_build(&ui, &s)
	st = &ui.lists[n]
	want := f32(0)
	for i in 0 ..< 40 do want += lz_base(i) * 2 + st.gap
	testing.expectf(t, abs(list_top(st^, 40) - want) < 0.01,
		"zoomed to 200%%, row 40 is at %.1f (was %.1f at 100%%), should be %.1f",
		list_top(st^, 40), was, want)
}

// The rows are *made* the heights they were given: the spacers, the reveal
// and the hold are all worked out from those numbers, so a row that laid
// itself out taller would put everything below it somewhere else.
@(test)
a_row_is_made_the_height_it_was_given :: proc(t: ^testing.T) {
	ui: Ui(Lz_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	s := Lz_State{scale = 1, grow = 60} // every card asks for 60 px more than the list allows it
	n, first, _ := lz_settle(&ui, &s)
	st := &ui.lists[n]
	row := lz_row(&ui.tree, n, lz_key(&s, first))
	testing.expect(t, row != NODE_NONE, "the first row was built")
	d := node_get(&ui.tree, row)
	testing.expectf(t, abs(d.rect.h - lz_base(first)) < 0.01,
		"row %d is %.1f tall, was told %.1f", first, d.rect.h, lz_base(first))
	// …and the row below it starts where the list says, not 60 px lower
	below := lz_row(&ui.tree, n, lz_key(&s, first + 1))
	testing.expect(t, below != NODE_NONE, "the row below it was built too")
	gapped := node_get(&ui.tree, below).rect.y - d.rect.y
	testing.expectf(t, abs(gapped - (lz_base(first) + st.gap)) < 0.01,
		"the next row is %.1f lower, should be %.1f", gapped, lz_base(first) + st.gap)
}

// The point the reader was looking at comes out of the zoom where it went
// in, and stays there over the builds that follow: list_keep_place must not
// undo it.
@(test)
a_held_point_lands_where_it_was_asked_for_and_stays :: proc(t: ^testing.T) {
	ui: Ui(Lz_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	s := Lz_State{scale = 1}
	n, _, _ := lz_settle(&ui, &s)

	// the reader is on page 10, 50 px into it, 120 px down the view
	st := &ui.lists[n]
	scroll_to(&ui.tree, n, {0, list_top(st^, 10) + 50 - 120})
	lz_build(&ui, &s)

	// zoom to 200%: the same place in the page is twice as far into it
	s.scale = 2
	s.hold, s.point, s.at, s.hold_ask = lz_key(&s, 10), {0, 100}, {0, 120}, true
	for pass in 0 ..< 4 { // the build that zoomed, and three after it
		lz_build(&ui, &s)
		row := lz_row(&ui.tree, n, lz_key(&s, 10))
		testing.expectf(t, row != NODE_NONE, "pass %d: page 10 is on screen", pass)
		if row == NODE_NONE do continue
		into := lz_in_view(&ui.tree, n, row).y
		testing.expectf(t, abs(into - 20) < 0.51,
			"pass %d: page 10 starts %.1f px down the view, should be 20 (100 px into it at 120)",
			pass, into)
	}

	// Asked once. The reader can scroll away afterwards and stay away.
	st = &ui.lists[n]
	off := scroll_offset(&ui.tree, n).y
	scroll_to(&ui.tree, n, {0, off + 500})
	lz_build(&ui, &s)
	testing.expectf(t, abs(scroll_offset(&ui.tree, n).y - (off + 500)) < 0.51,
		"a hold already done does not take the view back: %.1f, left at %.1f",
		scroll_offset(&ui.tree, n).y, off + 500)
}

// Where `c` sits in `n`'s viewport. A node's rect is relative to its parent,
// so a page centred in a row is two steps from the list: the row carries the
// pan, the page its place within the row.
@(private = "file")
lz_in_view :: proc(t: ^Tree, n, c: Node) -> (at: [2]f32) {
	for cur := c; cur != NODE_NONE && cur != n; cur = node_parent(t, cur) {
		d := node_get(t, cur)
		if d == nil do break
		at += {d.rect.x, d.rect.y}
	}
	return
}

// The page itself, inside the row that centres it.
@(private = "file")
lz_page :: proc(t: ^Tree, n: Node, key: u64) -> Node {
	r := lz_row(t, n, key)
	return NODE_NONE if r == NODE_NONE else node_first(t, r)
}

// Sideways: `hold`'s point is px into the row, and with `content_width` the
// row is that whole width, so a page centred in it is at
// `(content_width - page) / 2` from the content's left edge, not from inside
// the list's padding.
@(test)
a_held_point_sideways_lands_under_the_pixel_it_named :: proc(t: ^testing.T) {
	ui: Ui(Lz_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	s := Lz_State{scale = 1, width = 1500, page_w = 500}
	n, _, _ := lz_settle(&ui, &s)

	// the middle of page 6 (its row is 1500 wide, so the page starts at 500)
	// under x = 300 of the viewport, and its top at the top of the view
	s.hold, s.point, s.at, s.hold_ask = lz_key(&s, 5), {500 + 250, 0}, {300, 0}, true
	lz_build(&ui, &s)
	page := lz_page(&ui.tree, n, lz_key(&s, 5))
	testing.expect(t, page != NODE_NONE, "page 6 was built")
	if page == NODE_NONE do return
	d := node_get(&ui.tree, page)
	testing.expectf(t, abs(d.rect.w - 500) < 0.51, "the page is %.1f wide, asked for 500", d.rect.w)
	at := lz_in_view(&ui.tree, n, page)
	sc := &ui.tree.scrolls[n]
	testing.expectf(t, abs(at.x + d.rect.w / 2 - 300) < 0.51,
		"the middle of the page is %.1f px into the view, should be 300 (offset %v)",
		at.x + d.rect.w / 2, sc.offset)
	testing.expectf(t, abs(at.y) < 0.51, "its top is %.1f px down the view, should be 0", at.y)
}

// A hold happens when it is asked for and not before: an app may note the
// row it is tracking every build, and only the command pins the view, so it
// cannot beat a reveal opening the document at its saved place.
@(test)
a_hold_happens_when_it_is_asked_for_and_not_before :: proc(t: ^testing.T) {
	ui: Ui(Lz_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	s := Lz_State{scale = 1}
	n, _, _ := lz_settle(&ui, &s)
	st := &ui.lists[n]
	scroll_to(&ui.tree, n, {0, list_top(st^, 20)})
	lz_build(&ui, &s)
	was := scroll_offset(&ui.tree, n).y
	testing.expectf(t, was > 1, "the view is down the document (%.1f)", was)

	// tracked, every build, and never asked for: the reader stays put
	for i in 0 ..< 3 {
		s.hold, s.point, s.at = lz_key(&s, 2 + i), {0, 40}, {0, 0}
		lz_build(&ui, &s)
		testing.expectf(t, abs(scroll_offset(&ui.tree, n).y - was) < 0.51,
			"build %d: an unasked hold moved the view to %.1f, should have left it at %.1f",
			i, scroll_offset(&ui.tree, n).y, was)
	}
	// …and the command is what asks
	s.hold_ask = true
	lz_build(&ui, &s)
	st = &ui.lists[n]
	want := list_top(st^, 4) + 40
	testing.expectf(t, abs(scroll_offset(&ui.tree, n).y - want) < 0.51,
		"asked for, it holds: %.1f, should be %.1f", scroll_offset(&ui.tree, n).y, want)
}

// A new estimate is a new set of offsets. The rows that were measured keep
// what they measured; every other row stands at the new estimate.
@(test)
a_new_estimate_works_the_offsets_out_again :: proc(t: ^testing.T) {
	ui: Ui(Lz_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	s := Lz_State{scale = 1, estimate = 100}
	n, _, _ := lz_settle(&ui, &s)
	st := &ui.lists[n]
	before, measured := list_height(st^), len(st.heights)
	testing.expectf(t, measured > 2, "some rows were measured (%d)", measured)

	s.estimate = 200
	lz_build(&ui, &s)
	st = &ui.lists[n]
	grew := list_height(st^) - before
	want := f32(LZ_COUNT - measured) * 100
	testing.expectf(t, abs(grew - want) < 0.51,
		"the estimate doubled: the document grew %.1f, should be %.1f (%d rows still estimated)",
		grew, want, LZ_COUNT - measured)
}

// New row keys say the measurements are no use: the app bumps a generation
// into them at each zoom, and the offsets must be worked out again from the
// estimate rather than from heights that describe the old scale.
@(test)
new_row_keys_let_go_of_the_old_measurements :: proc(t: ^testing.T) {
	ui: Ui(Lz_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	s := Lz_State{scale = 1, estimate = 300}
	n, _, _ := lz_settle(&ui, &s)
	st := &ui.lists[n]
	testing.expectf(t, len(st.heights) > 2, "the rows on screen were measured (%d)", len(st.heights))
	// a landscape page among them, so the measured answer is not the estimate
	h, known := st.heights[lz_key(&s, 3)]
	testing.expect(t, known, "page 3 was measured")
	testing.expectf(t, abs(h - 220) < 0.51, "page 3 measured %.1f, is 220", h)

	s.scale, s.gen = 2, 1 // zoomed, and the keys say so
	lz_build(&ui, &s)
	st = &ui.lists[n]
	want := 10 * (s.estimate + st.gap)
	testing.expectf(t, abs(list_top(st^, 10) - want) < 0.01,
		"after the keys changed, row 10 is at %.1f, should be the estimate %.1f away",
		list_top(st^, 10), want)
	_, still := st.heights[lz_key(&s, 3)]
	testing.expect(t, !still, "the new key for page 3 has no height yet")
}

// Sideways: a pan in the build that zoomed is clamped to the width the rows
// are *about* to be laid out at, not the one the last layout left.
@(test)
a_pan_is_clamped_to_the_width_that_is_coming :: proc(t: ^testing.T) {
	ui: Ui(Lz_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	s := Lz_State{scale = 1, width = 1500}
	n, _, _ := lz_settle(&ui, &s)
	sc := &ui.tree.scrolls[n]
	testing.expect(t, sc != nil, "the list scrolls")
	testing.expectf(t, abs(sc.content.x - 1500) < 0.51, "laid out 1500 wide, content.x %.1f", sc.content.x)

	// zoomed to 200%: twice as wide, and the app pans to 2400 in the same
	// build. The old width allowed 900.
	s.width, s.pan = 3000, 2400
	lz_build(&ui, &s)
	testing.expectf(t, abs(scroll_offset(&ui.tree, n).x - 2400) < 0.51,
		"panned to %.1f of 2400 (the old width would have stopped it at 900)",
		scroll_offset(&ui.tree, n).x)
}

// ------------------------------------------------------ holding a spot

// lz_at_spot is what the list has at this spot of the viewport right now:
// which row, and how far into it. The same question `hold_at` answers for
// itself, asked here to check its answer.
@(private = "file")
lz_at_spot :: proc(ui: ^Ui(Lz_Msg), n: Node, y: f32) -> (row: int, frac: f32) {
	st := &ui.lists[n]
	cy := scroll_offset(&ui.tree, n).y + y
	row = list_row_at(st^, cy)
	h := list_span(st^, row)
	frac = (cy - list_top(st^, row)) / h if h > 0 else 0
	return
}

// A hold needs no notes from the app: `hold_at` names a spot of the
// viewport instead of a row, and the list resolves it against the offset it
// is actually on, so a zoom comes out exactly where it went in.
@(test)
a_hold_at_a_spot_keeps_what_was_there_across_a_zoom :: proc(t: ^testing.T) {
	ui: Ui(Lz_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	s := Lz_State{scale = 1}
	n, _, _ := lz_settle(&ui, &s)
	st := &ui.lists[n]
	scroll_to(&ui.tree, n, {0, list_top(st^, 20) + 73}) // mid-page, not on a boundary
	lz_build(&ui, &s)

	SPOT :: f32(200)
	row, frac := lz_at_spot(&ui, n, SPOT)
	testing.expectf(t, row > 0 && frac > 0.01 && frac < 0.99,
		"the spot is inside row %d, %.2f of the way down it", row, frac)

	// the zoom, and the ask, in one build — as `update` returns them
	s.scale, s.gen, s.spot, s.spot_ask = 2, s.gen + 1, {0, SPOT}, true
	lz_build(&ui, &s)

	row2, frac2 := lz_at_spot(&ui, n, SPOT)
	testing.expectf(t, row2 == row, "the same row is at the spot: %d, was %d", row2, row)
	testing.expectf(t, abs(frac2 - frac) < 0.02,
		"the same part of it: %.3f of the way down, was %.3f", frac2, frac)
}

// A list does not rebuild for a scroll that keeps the same rows on screen
// (dragging the bar inside one tall page), so what the app noted at the last
// build is behind by that much. A hold by row and pixel is off by it; a hold
// by spot is not, because the list reads its own offset.
@(test)
a_hold_by_spot_does_not_go_stale_between_builds :: proc(t: ^testing.T) {
	SPOT :: f32(150)
	DRIFT :: f32(37) // the bar dragged within one page: no new rows, no rebuild

	// What the app noted at its last build, then a scroll it never heard
	// about, then the zoom. The error is measured against what the reader
	// was looking at when the zoom happened: the spot after the drift.
	stale: f32
	{
		ui: Ui(Lz_Msg)
		ui_init(&ui)
		defer ui_destroy(&ui)
		s := Lz_State{scale = 1}
		n, _, _ := lz_settle(&ui, &s)
		st := &ui.lists[n]
		scroll_to(&ui.tree, n, {0, list_top(st^, 20)})
		lz_build(&ui, &s)
		noted_row, noted_frac := lz_at_spot(&ui, n, SPOT) // the app's notes
		scroll_to(&ui.tree, n, {0, scroll_offset(&ui.tree, n).y + DRIFT}) // …and then this
		_, frac_true := lz_at_spot(&ui, n, SPOT)          // what the reader sees now
		testing.expectf(t, abs(frac_true - noted_frac) > 0.05,
			"the drift is worth noticing: %.3f of the row against the noted %.3f", frac_true, noted_frac)
		s.scale, s.gen = 2, s.gen + 1
		s.hold, s.point, s.at, s.hold_ask =
			lz_key(&s, noted_row), {0, noted_frac * lz_base(noted_row) * 2}, {0, SPOT}, true
		lz_build(&ui, &s)
		_, after := lz_at_spot(&ui, n, SPOT)
		stale = abs(after - frac_true)
	}

	ui: Ui(Lz_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	s := Lz_State{scale = 1}
	n, _, _ := lz_settle(&ui, &s)
	st := &ui.lists[n]
	scroll_to(&ui.tree, n, {0, list_top(st^, 20)})
	lz_build(&ui, &s)
	scroll_to(&ui.tree, n, {0, scroll_offset(&ui.tree, n).y + DRIFT})
	row, frac := lz_at_spot(&ui, n, SPOT) // the truth, which only the list knows
	s.scale, s.gen, s.spot, s.spot_ask = 2, s.gen + 1, {0, SPOT}, true
	lz_build(&ui, &s)

	row2, frac2 := lz_at_spot(&ui, n, SPOT)
	testing.expectf(t, row2 == row, "the same row is at the spot: %d, was %d", row2, row)
	testing.expectf(t, abs(frac2 - frac) < 0.02,
		"by spot it is exact: %.3f of the way down, was %.3f", frac2, frac)
	testing.expectf(t, stale > abs(frac2 - frac),
		"…and better than the app's own notes, which were out by %.3f", stale)
}

// A hold can leave an axis alone: scrolling across a page is the reader's,
// and an app zooming by page height should not have to pass a noted offset
// back to keep it.
@(test)
a_hold_can_leave_an_axis_alone :: proc(t: ^testing.T) {
	ui: Ui(Lz_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	s := Lz_State{scale = 1, width = 1500, page_w = 500}
	n, _, _ := lz_settle(&ui, &s)
	scroll_to(&ui.tree, n, {420, 0}) // the reader scrolled across
	lz_build(&ui, &s)
	across := scroll_offset(&ui.tree, n).x
	testing.expectf(t, across > 1, "the view is across the page (%.1f)", across)

	// A hold that names only the vertical: the x the reader chose stays.
	s.hold, s.point, s.at, s.axes, s.hold_ask = lz_key(&s, 5), {0, 40}, {0, 0}, {.Y}, true
	lz_build(&ui, &s)
	testing.expectf(t, abs(scroll_offset(&ui.tree, n).x - across) < 0.51,
		"x was left alone: %.1f, should be %.1f", scroll_offset(&ui.tree, n).x, across)
	st := &ui.lists[n]
	want := list_top(st^, 5) + 40 // lz_key(&s, 5) is row 5's
	testing.expectf(t, abs(scroll_offset(&ui.tree, n).y - want) < 0.51,
		"…and y was held: %.1f, should be %.1f", scroll_offset(&ui.tree, n).y, want)
}

} // when ODIN_TEST
