package baldr

@(require) import "core:testing"

// A "↓ Newest" button reveals the last row with `reveal_key`. Revealing the
// last row rides the end again, so the list reports at_end as soon as it
// arrives and the app can take its button down; revealing any other row
// lets go of the end.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Rf_Msg :: union { List_At }

@(private = "file")
rf_key_of :: proc(user: rawptr, index: int) -> u64 { return u64(index + 1) * 10 }

@(private = "file")
RF_ROWS :: 60

// One build: `reveal` names the row to bring into view, 0 for none, and
// `count` lets a message arrive while the reveal is still settling.
// `reveal_key` is a command, so the test asks before the build rather than
// passing it in (reveal_cmd.odin).
@(private = "file")
rf_build :: proc(ui: ^Ui(Rf_Msg), reveal: u64, count := RF_ROWS) {
	if reveal != 0 do reveal_put(ui, Reveal_Ask{view = 1, key = reveal, at = 0.33})
	set_viewport(&ui.tree, {420, 300})
	begin_view(ui)
	column(ui, flex = 1)
	first, last := list(ui, count, estimated_height = 30, key_of = rf_key_of, follow_end = true,
		key = 1)
	for i in first ..< last {
		box(ui, height = 30, key = rf_key_of(nil, i))
	}
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {420, 300})
}

@(test)
revealing_the_last_row_keeps_the_list_following :: proc(t: ^testing.T) {
	ui: Ui(Rf_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	for _ in 0 ..< 3 do rf_build(&ui, 0) // settle at the end
	st := &ui.lists[rf_list_node(&ui)]
	testing.expect(t, st != nil && st.following, "follow_end starts at the newest row")

	// the reader scrolls up
	scroll_to(&ui.tree, rf_list_node(&ui), {0, 200})
	rf_build(&ui, 0)
	testing.expect(t, !st.following, "scrolling up lets go of the end")

	// "↓ Newest": reveal the last row's key
	last_key := rf_key_of(nil, RF_ROWS - 1)
	rf_build(&ui, last_key)
	testing.expect(t, st.following, "revealing the last row rides it again")
	at := list_at(&ui.tree, rf_list_node(&ui), st^) // what on_at hands the app
	testing.expectf(t, at.at_end, "it reports at_end straight away, got %v", at)
}

// A reveal re-places its row for up to LIST_REVEAL_TRIES builds, so it
// lands once the rows around it are measured. On an idle list those builds
// are the reader's own Space presses and wheel notches, so a scroll by
// anyone else ends the reveal rather than being put back.
@(test)
a_scroll_by_someone_else_ends_a_reveal_being_refined :: proc(t: ^testing.T) {
	mid := rf_key_of(nil, 20) // a row in the middle: not the "to the end" path

	placed_at: f32
	{ // Left alone, the reveal is still pending and still placing, which is
	  // what makes the other half of this test mean anything.
		ui: Ui(Rf_Msg)
		ui_init(&ui)
		defer ui_destroy(&ui)
		rf_build(&ui, 0)
		rf_build(&ui, mid)
		n := rf_list_node(&ui)
		st := &ui.lists[n]
		placed_at = scroll_offset(&ui.tree, n).y
		testing.expect(t, placed_at > 0, "the reveal moved the view")
		testing.expect_value(t, st.reveal_pend, mid)
		rf_build(&ui, 0) // no new ask: the list refines the one it has
		testing.expect_value(t, st.reveal_pend, mid) // still refining
		testing.expect_value(t, scroll_offset(&ui.tree, n).y, placed_at)
	}

	{ // The reader scrolls while it is refining: the reveal lets go, and the
	  // view stays where they put it.
		ui: Ui(Rf_Msg)
		ui_init(&ui)
		defer ui_destroy(&ui)
		rf_build(&ui, 0)
		rf_build(&ui, mid)
		n := rf_list_node(&ui)
		st := &ui.lists[n]
		testing.expect_value(t, st.reveal_pend, mid)

		scroll_by(&ui.tree, n, {0, 60}) // a Space, a wheel notch, a bar drag
		moved := scroll_offset(&ui.tree, n).y
		testing.expect_value(t, moved, placed_at + 60)

		// The builds that follow carry no new ask: `reveal_key` is a
		// command, so an app cannot keep passing the row.
		rf_build(&ui, 0)
		testing.expect_value(t, st.reveal_pend, u64(0)) // the reveal has had its turn
		testing.expect_value(t, scroll_offset(&ui.tree, n).y, moved)
		rf_build(&ui, 0) // and it stays let go of
		testing.expect_value(t, scroll_offset(&ui.tree, n).y, moved)
	}
}

// The end moves while the reveal settles: the row that was newest when
// "↓ Newest" was pressed is one from the end by the time it lands. That is
// still a reveal of the end, not a jump to an older message, so the list
// keeps following.
@(test)
to_the_end_still_means_the_end_when_a_message_arrives :: proc(t: ^testing.T) {
	ui: Ui(Rf_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	count := RF_ROWS
	for _ in 0 ..< 3 do rf_build(&ui, 0, count)
	st := &ui.lists[rf_list_node(&ui)]
	scroll_to(&ui.tree, rf_list_node(&ui), {0, 200}) // the reader scrolls up
	rf_build(&ui, 0, count)
	testing.expect(t, !st.following, "scrolling up lets go of the end")

	// "↓ Newest", and a message arrives in the same breath
	last_key := rf_key_of(nil, count - 1)
	rf_build(&ui, last_key, count)
	count += 1
	for _ in 0 ..< 3 do rf_build(&ui, 0, count) // asked once; these are the builds it settles over

	at := list_at(&ui.tree, rf_list_node(&ui), st^)
	testing.expectf(t, at.at_end, "it is at the end, so the button can come down (got %v)", at)
	sc := ui.tree.scrolls[rf_list_node(&ui)]
	testing.expectf(t, sc.offset.y >= list_max_off(sc) - SCROLL_END_EPS,
		"and the newest message is on screen (%.0f of %.0f)", sc.offset.y, list_max_off(sc))
}

// A reveal that is not the last row still lets go of the end: being sent
// to a search hit is not riding the newest message.
@(test)
revealing_any_other_row_still_lets_go :: proc(t: ^testing.T) {
	ui: Ui(Rf_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	for _ in 0 ..< 3 do rf_build(&ui, 0)
	st := &ui.lists[rf_list_node(&ui)]
	testing.expect(t, st != nil && st.following, "it starts at the end")

	rf_build(&ui, rf_key_of(nil, 4)) // a hit near the top
	testing.expect(t, !st.following, "sent somewhere else: not following")
	at := list_at(&ui.tree, rf_list_node(&ui), st^)
	testing.expect(t, !at.at_end, "and not reported as at the end")
}

// the one list in the tree
@(private = "file")
rf_list_node :: proc(ui: ^Ui(Rf_Msg)) -> Node {
	for n in ui.lists do return n
	return NODE_NONE
}

}
