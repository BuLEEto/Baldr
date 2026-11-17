package baldr

@(require) import "core:testing"

// A list that follows its end must still scroll up. `follow_end` is sticky:
// cleared when the reader scrolls up, set again when they come back to the
// bottom. "At the bottom" must be tighter than a wheel notch, or a reader
// who stops one notch up is dragged back down by the next build, and a
// touchpad's small deltas never escape at all.
//
// These run the loop the way an app does: an input event, `list_tick`, and
// a build only if the tick asked for one. The assertions are the offset the
// view ends up at and the `List_At` the app is told about, never a private
// flag.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Su_Msg :: union { List_At }

// A chat's shape: 300 rows of mixed heights around a 72 px estimate,
// following the end, with a gutter for the scrollbar.
@(private = "file")
SU_ROWS :: 300

@(private = "file")
SU_VIEW :: [2]f32{720, 660}

@(private = "file")
su_key_of :: proc(user: rawptr, index: int) -> u64 { return u64(index + 1) * 10 }

@(private = "file")
su_height :: proc(i: int) -> f32 {
	if i >= SU_ROWS do return 180 // a message that arrives is a picture: well over the estimate
	hs := [4]f32{44, 58, 72, 96}  // mean 67.5: the content *shrinks* as it is measured
	return hs[i % 4]
}

@(private = "file")
su_build :: proc(ui: ^Ui(Su_Msg), count := SU_ROWS, follow := true) -> Node {
	set_viewport(&ui.tree, SU_VIEW)
	begin_view(ui)
	column(ui, flex = 1)
	first, last := list(ui, count, estimated_height = 72, key_of = su_key_of, follow_end = follow,
		gap = .xs, padding = .sm, gutter = true, key = 7)
	n := ui.scopes[len(ui.scopes) - 1].node
	for i in first ..< last {
		box(ui, height = su_height(i), key = su_key_of(nil, i))
	}
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, SU_VIEW)
	return n
}

// A chat opened at its newest message, settled: the heights are measured and
// the view is against the bottom.
@(private = "file")
su_settled :: proc(ui: ^Ui(Su_Msg)) -> Node {
	n: Node
	for _ in 0 ..< 6 do n = su_build(ui)
	return n
}

// One wheel or touchpad event, then what the run loop does after it: the
// list asks for a rebuild when the visible range moved, and only then is the
// view built again.
@(private = "file")
su_scroll :: proc(ui: ^Ui(Su_Msg), dy: f32) {
	for n in ui.lists {
		scroll_by(&ui.tree, n, {0, dy})
		break
	}
	list_tick(ui)
	if ui.needs_rebuild {
		ui.needs_rebuild = false
		su_build(ui)
		return
	}
	frame(&ui.tree, SU_VIEW)
}

@(private = "file")
su_off :: proc(ui: ^Ui(Su_Msg), n: Node) -> f32 { return scroll_offset(&ui.tree, n).y }

// A wheel notch (SCROLL_STEP_PX) must not be undone by the build it asks
// for.
@(test)
wheel_notches_scroll_a_following_chat_up :: proc(t: ^testing.T) {
	ui: Ui(Su_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := su_settled(&ui)
	start := su_off(&ui, n)
	for _ in 0 ..< 10 do su_scroll(&ui, -SCROLL_STEP_PX)
	moved := start - su_off(&ui, n)
	testing.expectf(t, moved >= SCROLL_STEP_PX * 9,
		"ten notches up should move about %.0f px, moved %.0f", SCROLL_STEP_PX * 10, moved)
	testing.expect(t, !list_at(&ui.tree, n, ui.lists[n]).at_end,
		"and the chat says it is no longer at the end, so the app can offer '↓ Newest'")
}

// A touchpad sends a few pixels at a time, and each must move the chat
// rather than fall inside the list's slack.
@(test)
touchpad_deltas_scroll_a_following_chat_up :: proc(t: ^testing.T) {
	ui: Ui(Su_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := su_settled(&ui)
	start := su_off(&ui, n)
	for _ in 0 ..< 60 do su_scroll(&ui, -6)
	moved := start - su_off(&ui, n)
	testing.expectf(t, moved >= 6 * 50, "sixty 6 px deltas up should move about 360 px, moved %.0f", moved)
}

// A chat is rebuilt for its own reasons (a message, a reaction, a typing
// line), and a reader who scrolled one notch up and stopped must not be
// pulled back to the bottom by the next build.
@(test)
a_build_the_reader_did_not_ask_for_keeps_their_place :: proc(t: ^testing.T) {
	ui: Ui(Su_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := su_settled(&ui)
	su_scroll(&ui, -SCROLL_STEP_PX) // one notch up, then let go
	parked := su_off(&ui, n)
	testing.expect(t, parked > 0, "the notch moved the view")
	// The message they are on, not the offset: rows that just came into
	// view are measured after the build that placed them, and the list then
	// moves the offset so the reader's row stays under the same pixel. What
	// must not change is which message is at the top of the window, and that
	// they are still away from the end.
	top := list_at(&ui.tree, n, ui.lists[n]).first_key
	for _ in 0 ..< 4 do su_build(&ui)
	at := list_at(&ui.tree, n, ui.lists[n])
	testing.expectf(t, at.first_key == top,
		"four builds later they are still on the same message (%d, was %d)", at.first_key, top)
	testing.expect(t, !at.at_end, "and still not at the end, so nothing dragged them back")
	// …and a message arriving does not move them either.
	su_build(&ui, SU_ROWS + 1)
	su_build(&ui, SU_ROWS + 1)
	at = list_at(&ui.tree, n, ui.lists[n])
	testing.expectf(t, at.first_key == top, "a new message leaves them where they are (%d, was %d)", at.first_key, top)
	testing.expect(t, !at.at_end, "and does not resume following")
}

// The other half of the contract: coming back to the bottom follows again,
// so the chat rides the next message and the app's "↓ Newest" can come down.
@(test)
scrolling_back_to_the_bottom_follows_again :: proc(t: ^testing.T) {
	ui: Ui(Su_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := su_settled(&ui)
	bottom := su_off(&ui, n)
	for _ in 0 ..< 5 do su_scroll(&ui, -SCROLL_STEP_PX)
	testing.expect(t, su_off(&ui, n) < bottom - 100, "well up the conversation")
	for _ in 0 ..< 8 do su_scroll(&ui, SCROLL_STEP_PX) // back down, past the end: the clamp stops it there
	testing.expect(t, list_at(&ui.tree, n, ui.lists[n]).at_end, "at the end again, and following")
	// a message arrives: the chat rides it
	before := su_off(&ui, n)
	for _ in 0 ..< 3 do su_build(&ui, SU_ROWS + 1)
	testing.expectf(t, su_off(&ui, n) > before, "the new message is shown (%.0f, was %.0f)", su_off(&ui, n), before)
	testing.expect(t, list_at(&ui.tree, n, ui.lists[n]).at_end, "still at the end")
}

// The settle itself must not be read as the reader scrolling. These rows
// average 67.5 px against a 72 px estimate, so measuring them shrinks the
// content and the pin moves the view up, which is what scrolling up looks
// like from the offset alone. A chat must still be following when it has
// finished settling.
@(test)
settling_shorter_rows_than_estimated_still_follows :: proc(t: ^testing.T) {
	ui: Ui(Su_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := su_settled(&ui)
	testing.expect(t, list_at(&ui.tree, n, ui.lists[n]).at_end,
		"a chat that has just opened is at the end")
	before := su_off(&ui, n)
	for _ in 0 ..< 3 do su_build(&ui, SU_ROWS + 1)
	testing.expectf(t, su_off(&ui, n) > before, "and follows the message that arrives (%.0f, was %.0f)", su_off(&ui, n), before)
}

// Following means on the newest message, not nearly. A row is measured by
// the layout after the build that placed it, so a build pinning to the end
// from the heights it had falls short by the new row's estimate error, and
// nothing asks for another build. `scroll`'s own follow_end pins in layout,
// which is why the list passes it down.
@(test)
following_lands_on_the_newest_message_not_near_it :: proc(t: ^testing.T) {
	ui: Ui(Su_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := su_settled(&ui)
	// a message arrives: one build, as the run loop gives it
	su_build(&ui, SU_ROWS + 1)
	sc := ui.tree.scrolls[n]
	testing.expectf(t, sc.offset.y >= list_max_off(sc) - SCROLL_END_EPS,
		"the view is on the end, not %.0f px short of it", list_max_off(sc) - sc.offset.y)
}

// Arriving at the bottom is not always a change of which rows are on screen:
// the last pixels of a flick down, or a touchpad's final deltas, move the
// view without bringing a new row in, so nothing asks for a build. The list
// must still learn the reader is back and follow again.
@(test)
arriving_at_the_bottom_is_noticed_without_a_new_row :: proc(t: ^testing.T) {
	ui: Ui(Su_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := su_settled(&ui)
	su_scroll(&ui, -SCROLL_STEP_PX) // up a notch: no longer riding the end
	testing.expect(t, !list_at(&ui.tree, n, ui.lists[n]).at_end, "scrolled up: not at the end")
	for _ in 0 ..< 80 do su_scroll(&ui, 1) // and back down a pixel at a time
	sc := ui.tree.scrolls[n]
	testing.expectf(t, sc.offset.y >= list_max_off(sc) - SCROLL_END_EPS,
		"the creep reached the bottom (off %.0f of %.0f)", sc.offset.y, list_max_off(sc))
	testing.expect(t, list_at(&ui.tree, n, ui.lists[n]).at_end,
		"and the chat knows it is riding the newest row again")
}

// A list of three rows has nothing to scroll, so nothing has ever moved its
// view and the scroll has no memory of being at the end; yet the view is at
// the end, and an app reading `at_end` must be told so. A list that does not
// follow has only the geometry to go on.
@(test)
a_list_too_short_to_scroll_is_at_its_end :: proc(t: ^testing.T) {
	ui: Ui(Su_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n: Node
	for _ in 0 ..< 3 do n = su_build(&ui, 3, follow = false)
	sc := ui.tree.scrolls[n]
	testing.expectf(t, list_max_off(sc) == 0, "three rows do not fill the window (%.0f px of scroll)", list_max_off(sc))
	at := list_at(&ui.tree, n, ui.lists[n])
	testing.expect(t, at.at_end, "it is at the end, with or without anything having moved")
	testing.expect(t, at.near_start, "and at the start, which is the same place")
}

// Rows of one height follow their end too: the list passes `follow_end` to
// its scroll whatever its row heights. A log that appends is the case: no
// estimate, no keys, just a view that stays on the last line until the
// reader scrolls away from it.
@(test)
a_fixed_height_list_follows_its_end_too :: proc(t: ^testing.T) {
	ui: Ui(Su_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	build :: proc(ui: ^Ui(Su_Msg), count: int) -> Node {
		set_viewport(&ui.tree, SU_VIEW)
		begin_view(ui)
		column(ui, flex = 1)
		first, last := list(ui, count, row_height = 32, follow_end = true, label = "Log", key = 3)
		n := ui.scopes[len(ui.scopes) - 1].node
		for i in first ..< last do box(ui, height = 32, key = u64(i + 1))
		end(ui)
		end(ui)
		end_view(ui)
		frame(&ui.tree, SU_VIEW)
		return n
	}
	n: Node
	for _ in 0 ..< 3 do n = build(&ui, 200)
	sc := ui.tree.scrolls[n]
	testing.expectf(t, sc.offset.y >= list_max_off(sc) - SCROLL_END_EPS,
		"a log opens on its last line (%.0f of %.0f)", sc.offset.y, list_max_off(sc))
	for i in 0 ..< 4 do build(&ui, 200 + i + 1) // lines arrive
	sc = ui.tree.scrolls[n]
	testing.expectf(t, sc.offset.y >= list_max_off(sc) - SCROLL_END_EPS,
		"and stays on it as lines arrive (%.0f of %.0f)", sc.offset.y, list_max_off(sc))
	// …until the reader scrolls up, and then it leaves them alone
	scroll_by(&ui.tree, n, {0, -200})
	build(&ui, 205)
	parked := scroll_offset(&ui.tree, n).y
	for i in 0 ..< 3 do build(&ui, 205 + i + 1)
	testing.expectf(t, abs(scroll_offset(&ui.tree, n).y - parked) < 2,
		"reading further up is left alone (%.0f, was %.0f)", scroll_offset(&ui.tree, n).y, parked)
}

}
