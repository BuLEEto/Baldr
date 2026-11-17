package baldr

@(require) import "core:testing"

// A virtual list whose rows size to their content.
//
// With `estimated_height` the list measures each row once it has been laid
// out, keeps the height by key, and places the rest from the estimate. A
// row's height is known only after layout, but the range to build is chosen
// during the build, so the list works from last frame's measurements and
// converges: a row appears at the estimate, is measured, and the next build
// places it exactly.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Lv_Msg :: union { int }

// lv_height is row i's height: three sizes, so nothing can pass by assuming
// one pitch.
@(private = "file")
lv_height :: proc(i: int) -> f32 {
	switch i % 3 {
	case 0: return 30
	case 1: return 90
	}
	return 150
}

@(private = "file")
LV_COUNT :: 400

@(private = "file")
lv_build :: proc(ui: ^Ui(Lv_Msg), estimate: f32) -> (n: Node, first, last: int) {
	set_viewport(&ui.tree, {400, 300})
	begin_view(ui)
	column(ui, flex = 1)
	first, last = list(ui, LV_COUNT, estimated_height = estimate, label = "Chat", key = 1)
	n = ui.scopes[len(ui.scopes) - 1].node
	for i in first ..< last {
		card(ui, height = lv_height(i), key = u64(i + 1))
		end(ui)
	}
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 300})
	return
}

// lv_settle builds until the measurements stop changing — the convergence
// the ordering forces. It should take very few passes.
@(private = "file")
lv_settle :: proc(ui: ^Ui(Lv_Msg), estimate: f32, passes := 6) -> (n: Node, first, last: int) {
	for _ in 0 ..< passes do n, first, last = lv_build(ui, estimate)
	return
}

// Only a screenful is built, out of four hundred rows — the point of a
// virtual list, and it has to survive the rows being different heights.
@(test)
a_variable_list_builds_only_what_is_on_screen :: proc(t: ^testing.T) {
	ui: Ui(Lv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	_, first, last := lv_settle(&ui, 90)
	testing.expect_value(t, first, 0)
	testing.expectf(t, last < 40, "a 300 px viewport built %d of %d rows", last - first, LV_COUNT)
	testing.expectf(t, last > 2, "…and more than a couple (%d)", last)
}

// The heights it measures are the heights the rows actually are, kept by
// key, and the content height is their sum — not count × estimate.
@(test)
a_variable_list_measures_its_rows_and_totals_them :: proc(t: ^testing.T) {
	ui: Ui(Lv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n, first, last := lv_settle(&ui, 90)
	st := &ui.lists[n]
	testing.expect(t, st != nil, "the list has state")

	for i in first ..< last {
		h, known := st.heights[u64(i + 1)]
		testing.expectf(t, known, "row %d was measured", i)
		testing.expectf(t, abs(h - lv_height(i)) < 0.51, "row %d measured %.1f, is %.1f", i, h, lv_height(i))
	}
	// the rows past the window stand at the estimate, so the total is the
	// measured ones plus the estimate for the rest
	want: f32
	for i in 0 ..< LV_COUNT {
		if h, known := st.heights[u64(i + 1)]; known { want += h } else { want += st.estimate }
	}
	testing.expectf(t, abs(list_height(st^) - want) < 1, "content height %.1f, expected %.1f", list_height(st^), want)
	testing.expectf(t, list_height(st^) != f32(LV_COUNT) * 90, "…and not simply count x estimate")
}

// Scrolling past rows of mixed heights lands on the right one: the window
// is found by searching the measured offsets, not by dividing by a pitch.
@(test)
a_variable_list_finds_the_row_under_a_scroll :: proc(t: ^testing.T) {
	ui: Ui(Lv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n, _, _ := lv_settle(&ui, 90)
	st := &ui.lists[n]

	// row 0 is 30 tall, row 1 is 90, row 2 is 150 — so 125 px down is row 2
	// (0..30, 30..120, 120..270) with no gap
	testing.expect_value(t, st.gap, 0)
	testing.expect_value(t, list_row_at(st^, 0), 0)
	testing.expect_value(t, list_row_at(st^, 29), 0)
	testing.expect_value(t, list_row_at(st^, 31), 1)
	testing.expect_value(t, list_row_at(st^, 125), 2)
	// a fixed-pitch list would have said 125/90 = 1
	testing.expect(t, list_row_at(st^, 125) != 1, "not the answer a fixed pitch gives")
}

// A row's measured height survives its index moving, because it is kept by
// key — which is what makes paging older messages in above possible at all.
@(test)
a_variable_list_keeps_heights_by_key :: proc(t: ^testing.T) {
	ui: Ui(Lv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n, _, last := lv_settle(&ui, 90)
	st := &ui.lists[n]
	before := make(map[u64]f32, context.temp_allocator)
	for i in 0 ..< last do if h, known := st.heights[u64(i + 1)]; known do before[u64(i + 1)] = h
	testing.expect(t, len(before) > 2, "some rows were measured")

	// another build changes nothing: the measurements are kept, not redone
	lv_build(&ui, 90)
	st = &ui.lists[n]
	for k, h in before {
		got, known := st.heights[k]
		testing.expectf(t, known && abs(got - h) < 0.01, "key %d kept its height (%.1f vs %.1f)", k, got, h)
	}
}

// A fixed-height list is untouched: no estimate, same pitch, same rows.
@(test)
a_fixed_list_is_unchanged_by_variable_support :: proc(t: ^testing.T) {
	ui: Ui(Lv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {400, 300})
	begin_view(&ui)
	column(&ui, flex = 1)
	first, last := list(&ui, 1000, row_height = 50, label = "Fixed", key = 2)
	n := ui.scopes[len(ui.scopes) - 1].node
	for i in first ..< last {
		card(&ui, key = u64(i + 1))
		end(&ui)
	}
	end(&ui)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 300})

	st := &ui.lists[n]
	testing.expect_value(t, st.estimate, 0)
	testing.expect_value(t, first, 0)
	testing.expectf(t, last < 20, "a 300 px viewport of 50 px rows built %d", last)
	testing.expectf(t, abs(list_height(st^) - 1000 * 50) < 1, "content is count x pitch (%.0f)", list_height(st^))
}


// ---------------------------------------------------------- arriving rows
//
// A chat loads older messages above what you are reading. A list anchored
// on an index would shift the view with every one; it anchors on a key.

// Lv_Feed gives each row a stable identity that survives a prepend: the app
// owns the numbering, as a chat owns its message ids.
@(private = "file")
Lv_Feed :: struct {
	before: int, // rows prepended so far
	count:  int,
}

@(private = "file")
lv_key_of :: proc(user: rawptr, i: int) -> u64 {
	f := (^Lv_Feed)(user)
	// id 1000 is the row that was first at the start; prepending pushes
	// smaller ids in front of it
	return u64(1000 + i - f.before)
}

@(private = "file")
lv_feed_build :: proc(ui: ^Ui(Lv_Msg), f: ^Lv_Feed, follow := false) -> (n: Node, first, last: int) {
	set_viewport(&ui.tree, {400, 300})
	begin_view(ui)
	column(ui, flex = 1)
	first, last = list(ui, f.count, estimated_height = 60, key_of = lv_key_of, key_user = f,
		follow_end = follow, label = "Chat", key = 1)
	n = ui.scopes[len(ui.scopes) - 1].node
	for i in first ..< last {
		card(ui, height = lv_height(int(lv_key_of(f, i))), key = lv_key_of(f, i))
		end(ui)
	}
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 300})
	return
}

// Scroll into the middle, load fifty older messages above, and the row you
// were looking at is still under the same pixel.
@(test)
prepending_rows_does_not_move_what_is_on_screen :: proc(t: ^testing.T) {
	ui: Ui(Lv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	f := Lv_Feed{count = 200}
	n: Node
	for _ in 0 ..< 6 do n, _, _ = lv_feed_build(&ui, &f)

	scroll_to(&ui.tree, n, {0, 2000})
	for _ in 0 ..< 4 do n, _, _ = lv_feed_build(&ui, &f)
	st := &ui.lists[n]
	key_before := st.anchor_key
	delta_before := st.anchor_delta
	off_before := scroll_offset(&ui.tree, n).y
	testing.expect(t, key_before != 0, "the view is resting on a row")

	// fifty older messages arrive above
	f.before += 50
	f.count += 50
	for _ in 0 ..< 4 do n, _, _ = lv_feed_build(&ui, &f)
	st = &ui.lists[n]

	// The offset moves down by exactly the height that arrived above. An
	// unchanged anchor key alone proves nothing: with index-derived keys the
	// key at the top is the same after a prepend, only a different message.
	added: f32
	for i in 0 ..< 50 do added += list_top(st^, i + 1) - list_top(st^, i)
	off_after := scroll_offset(&ui.tree, n).y
	testing.expectf(t, abs((off_after - off_before) - added) < 2,
		"the view moved down by the %.0f px that arrived above it (moved %.0f)", added, off_after - off_before)
	testing.expectf(t, st.anchor_key == key_before,
		"still resting on the same row (%d, was %d)", st.anchor_key, key_before)
	testing.expectf(t, abs(st.anchor_delta - delta_before) < 2,
		"and at the same place within it (%.1f, was %.1f)", st.anchor_delta, delta_before)
}

// Without the anchoring the same prepend throws the view down the
// conversation — this pins how far, so the test above cannot pass by luck.
@(test)
prepending_rows_would_move_the_view_a_long_way :: proc(t: ^testing.T) {
	ui: Ui(Lv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	f := Lv_Feed{count = 200}
	n: Node
	for _ in 0 ..< 6 do n, _, _ = lv_feed_build(&ui, &f)
	scroll_to(&ui.tree, n, {0, 2000})
	for _ in 0 ..< 4 do n, _, _ = lv_feed_build(&ui, &f)
	st := &ui.lists[n]
	moved := list_top(st^, 50) - list_top(st^, 0)
	testing.expectf(t, moved > 300, "fifty rows is more than a viewport of movement to undo (%.0f px)", moved)
}

// With follow_end, a view already at the bottom stays at the bottom when a
// message arrives; one that is not stays where it is.
@(test)
a_list_follows_the_end_only_when_it_is_at_the_end :: proc(t: ^testing.T) {
	ui: Ui(Lv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	f := Lv_Feed{count = 100}
	n: Node
	for _ in 0 ..< 6 do n, _, _ = lv_feed_build(&ui, &f, follow = true)
	st := &ui.lists[n]

	// a following list opens at the newest message: no scrolling needed
	st = &ui.lists[n]
	testing.expect(t, st.at_end, "the view is at the end")
	f.count += 1
	for _ in 0 ..< 3 do n, _, _ = lv_feed_build(&ui, &f, follow = true)
	st = &ui.lists[n]
	testing.expect(t, st.at_end, "a new message keeps it at the end")

	// …and reading further up is not dragged down by one arriving
	scroll_to(&ui.tree, n, {0, 500})
	for _ in 0 ..< 3 do n, _, _ = lv_feed_build(&ui, &f, follow = true)
	st = &ui.lists[n]
	testing.expect(t, !st.at_end, "reading further up is not at the end")
	before := scroll_offset(&ui.tree, n).y
	f.count += 1
    for _ in 0 ..< 3 do n, _, _ = lv_feed_build(&ui, &f, follow = true)
	after := scroll_offset(&ui.tree, n).y
	testing.expectf(t, abs(after - before) < 2, "and stays put (%.0f, was %.0f)", after, before)
}


// ------------------------------------- where it is resting, and jumping

// A chat fetches older history as the reader nears the top and shows a
// "jump to newest" while they are not at the bottom, so it has to be told.
@(test)
a_list_reports_where_it_is_resting :: proc(t: ^testing.T) {
	ui: Ui(Lv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	f := Lv_Feed{count = 200}
	n: Node
	for _ in 0 ..< 6 do n, _, _ = lv_feed_build(&ui, &f)
	st := &ui.lists[n]

	// at the top: near the start, not at the end
	scroll_to(&ui.tree, n, {0, 0})
	for _ in 0 ..< 2 do n, _, _ = lv_feed_build(&ui, &f)
	st = &ui.lists[n]
	top := list_at(&ui.tree, n, st^)
	testing.expect(t, top.near_start, "at the top it says so, so older history can be fetched")
	testing.expect(t, !top.at_end, "and it is not at the end")
	testing.expect_value(t, top.first_key, lv_key_of(&f, 0))

	// well down: neither
	scroll_to(&ui.tree, n, {0, 3000})
	for _ in 0 ..< 2 do n, _, _ = lv_feed_build(&ui, &f)
	st = &ui.lists[n]
	mid := list_at(&ui.tree, n, st^)
	testing.expect(t, !mid.near_start, "well down it is not near the start")
	testing.expectf(t, mid.first_key != top.first_key, "and rests on a different row (%d)", mid.first_key)
}

// Jumping to a search hit puts it a third down, not jammed against the top
// where it would read as the start of the conversation.
@(test)
a_list_reveals_a_key_a_third_of_the_way_down :: proc(t: ^testing.T) {
	ui: Ui(Lv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	f := Lv_Feed{count = 200}
	n: Node
	for _ in 0 ..< 6 do n, _, _ = lv_feed_build(&ui, &f)

	want := lv_key_of(&f, 120)
	reveal_put(&ui, Reveal_Ask{view = 1, key = want, at = 0.33}) // asked once, as an app asks (reveal_cmd.odin)
	for _ in 0 ..< 12 {
		set_viewport(&ui.tree, {400, 300})
		begin_view(&ui)
		column(&ui, flex = 1)
		first, last := list(&ui, f.count, estimated_height = 60, key_of = lv_key_of, key_user = &f,
			label = "Chat", key = 1)
		n = ui.scopes[len(ui.scopes) - 1].node
		for i in first ..< last {
			card(&ui, height = lv_height(int(lv_key_of(&f, i))), key = lv_key_of(&f, i))
			end(&ui)
		}
		end(&ui)
		end(&ui)
		end_view(&ui)
		frame(&ui.tree, {400, 300})
	}
	st := &ui.lists[n]
	sc := ui.tree.scrolls[n]
	// A third down, and it stays there: the first placement is exact, but
	// the rows above are measured in the builds after it and the content
	// grows beneath the scroll, so a reveal that stopped after one placement
	// would drift.
	into := list_top(st^, 120) - sc.offset.y
	testing.expectf(t, abs(into - sc.viewport.y / 3) < 8,
		"the row sits a third down and stayed there (%.0f px into a %.0f viewport)", into, sc.viewport.y)
}

// Asking for the same row again ("jump to newest" twice with no message in
// between, or searching for the hit already on screen) reveals it again: a
// reveal is a command, so asking twice is calling it twice, and not calling
// it leaves the view alone.
@(test)
a_list_reveals_the_same_key_again_when_it_is_asked_again :: proc(t: ^testing.T) {
	ui: Ui(Lv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	f := Lv_Feed{count = 200}
	n: Node

	want := lv_key_of(&f, 120)
	builds :: proc(ui: ^Ui(Lv_Msg), f: ^Lv_Feed, key: u64, times: int) -> Node {
		n: Node
		if key != 0 do reveal_put(ui, Reveal_Ask{view = 1, key = key, at = 0.33}) // the ask, once, before the builds it settles over
		for _ in 0 ..< times {
			set_viewport(&ui.tree, {400, 300})
			begin_view(ui)
			column(ui, flex = 1)
			first, last := list(ui, f.count, estimated_height = 60, key_of = lv_key_of, key_user = f,
				label = "Chat", key = 1)
			n = ui.scopes[len(ui.scopes) - 1].node
			for i in first ..< last {
				card(ui, height = lv_height(int(lv_key_of(f, i))), key = lv_key_of(f, i))
				end(ui)
			}
			end(ui)
			end(ui)
			end_view(ui)
			frame(&ui.tree, {400, 300})
		}
		return n
	}

	// land on it, then let the reader scroll right away from it
	n = builds(&ui, &f, want, 12)
	st := &ui.lists[n]
	landed := list_top(st^, 120) - ui.tree.scrolls[n].offset.y
	testing.expectf(t, abs(landed - ui.tree.scrolls[n].viewport.y / 3) < 8, "landed a third down (%.0f)", landed)

	scroll_to(&ui.tree, n, {0, 0})
	n = builds(&ui, &f, 0, 1) // no ask this time: the view is left where it is
	st = &ui.lists[n]
	testing.expectf(t, ui.tree.scrolls[n].offset.y < 8,
		"an unchanged ask does not move it (%.0f)", ui.tree.scrolls[n].offset.y)

	n = builds(&ui, &f, want, 12) // asked again, for the same row
	st = &ui.lists[n]
	again := list_top(st^, 120) - ui.tree.scrolls[n].offset.y
	testing.expectf(t, abs(again - ui.tree.scrolls[n].viewport.y / 3) < 8,
		"the same row is revealed again when it is asked again (%.0f px in)", again)
}

}
