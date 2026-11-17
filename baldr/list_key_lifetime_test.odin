package baldr

@(require) import "core:testing"

// `key_of` reads the app's model, which an app may keep in the frame's temp
// memory: rows are built "between list and end". So what `key_user` points
// at lives only for the build, and nothing may ask for it afterwards.
// `list_tick` (run from `ui_after_events`) re-takes the reader's place when
// the scroll has moved since the last build, so it names the row from
// `built_keys`, what the last build built, and never calls `key_of`.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Lf_Msg :: union { List_At }

@(private = "file")
LF_VIEW :: [2]f32{520, 600}

// The app's rows, and a record of what the list asked and when. `live` is
// the window in which answering is allowed: an app's real `key_user` would
// be dangling outside it.
@(private = "file")
Lf_Feed :: struct {
	count:   int,
	live:    bool, // a build is running
	outside: int,  // key_of calls that came from no build: a dangling read
	bad_idx: int,  // key_of calls for an index outside the count being built
	asks:    int,
}

@(private = "file")
lf_key_of :: proc(user: rawptr, index: int) -> u64 {
	f := (^Lf_Feed)(user)
	f.asks += 1
	if !f.live do f.outside += 1
	if index < 0 || index >= f.count do f.bad_idx += 1
	return u64(index + 1) * 10
}

@(private = "file")
lf_build :: proc(ui: ^Ui(Lf_Msg), f: ^Lf_Feed) -> Node {
	set_viewport(&ui.tree, LF_VIEW)
	f.live = true
	begin_view(ui)
	column(ui, flex = 1)
	first, last := list(ui, f.count, estimated_height = 72, key_of = lf_key_of, key_user = f,
		follow_end = true, gap = .xs, padding = .sm, gutter = true, key = 1)
	n := ui.scopes[len(ui.scopes) - 1].node
	for i in first ..< last do box(ui, height = 44 + f32((i % 3) * 26), key = lf_key_of(f, i))
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, LF_VIEW)
	f.live = false
	return n
}

// A scroll smaller than a row asks for no rebuild, so the list hears about
// it in the tick, when the app's rows may already be gone.
@(test)
the_tick_never_asks_the_app_for_a_key :: proc(t: ^testing.T) {
	ui: Ui(Lf_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	f := Lf_Feed{count = 300}
	n: Node
	for _ in 0 ..< 6 do n = lf_build(&ui, &f)
	scroll_to(&ui.tree, n, {0, 5000})
	for _ in 0 ..< 4 do lf_build(&ui, &f)
	testing.expect(t, f.asks > 0, "the list does ask during a build")

	// a nudge too small to change the visible range, then the tick
	scroll_by(&ui.tree, n, {0, -30})
	list_tick(&ui)
	testing.expect(t, !ui.needs_rebuild, "a nudge this small asks for no build")
	testing.expectf(t, f.outside == 0, "no key_of call came from outside a build (%d did)", f.outside)

	// and a nudge big enough that it does want one: still not from the tick
	scroll_by(&ui.tree, n, {0, -400})
	list_tick(&ui)
	testing.expectf(t, f.outside == 0, "nor when the tick asks for a rebuild (%d)", f.outside)
}

// The anchor the tick takes must still be the right row: read from
// `built_keys`, it names the same row `key_of` would have.
@(test)
the_place_the_tick_notes_is_still_the_row_on_screen :: proc(t: ^testing.T) {
	ui: Ui(Lf_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	f := Lf_Feed{count = 300}
	n: Node
	for _ in 0 ..< 6 do n = lf_build(&ui, &f)
	scroll_to(&ui.tree, n, {0, 5000})
	for _ in 0 ..< 4 do lf_build(&ui, &f)

	scroll_by(&ui.tree, n, {0, -30})
	list_tick(&ui)
	st := ui.lists[n]
	off := scroll_offset(&ui.tree, n).y
	top := list_row_at(st, off)
	testing.expectf(t, st.anchor_key == lf_key_of(&f, top),
		"the anchor is the row under the viewport's top (%d, row %d is %d)", st.anchor_key, top, lf_key_of(&f, top))
	testing.expectf(t, abs(st.note_off - off) < 0.01,
		"and it was taken at the offset they scrolled to (%.1f vs %.1f)", st.note_off, off)
}

// Between builds the list knows only the last build's count, so an app
// answering from its live model could be asked for a row it no longer has.
// Nothing may ask for an index the running build did not pass.
@(test)
a_key_is_never_asked_for_a_row_that_is_gone :: proc(t: ^testing.T) {
	ui: Ui(Lf_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	f := Lf_Feed{count = 300}
	n: Node
	for _ in 0 ..< 6 do n = lf_build(&ui, &f)
	scroll_to(&ui.tree, n, {0, 5000})
	for _ in 0 ..< 4 do lf_build(&ui, &f)

	// the reader clicks another conversation: `update` throws the rows away
	f.count = 0
	scroll_by(&ui.tree, n, {0, -30})
	list_tick(&ui)
	testing.expectf(t, f.outside == 0, "the tick asked nothing after the rows went (%d)", f.outside)
	for _ in 0 ..< 3 do lf_build(&ui, &f)
	testing.expectf(t, f.bad_idx == 0, "and no build asked for an index outside its own count (%d)", f.bad_idx)

	// the new conversation loads
	f.count = 120
	for _ in 0 ..< 3 do lf_build(&ui, &f)
	testing.expectf(t, f.bad_idx == 0, "nor once the next conversation arrived (%d)", f.bad_idx)
	testing.expectf(t, f.outside == 0, "and still nothing outside a build (%d)", f.outside)
}

// An empty list is the case the guard is written for: there is no row to
// rest on, so the anchor is cleared rather than left naming a row that has
// gone.
@(test)
an_empty_list_rests_on_nothing :: proc(t: ^testing.T) {
	ui: Ui(Lf_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	f := Lf_Feed{count = 40}
	n: Node
	for _ in 0 ..< 5 do n = lf_build(&ui, &f)
	f.count = 0
	for _ in 0 ..< 3 do lf_build(&ui, &f)
	st := ui.lists[n]
	testing.expectf(t, st.anchor_key == 0, "no row is under the top of an empty list (%d)", st.anchor_key)
	testing.expect(t, f.outside == 0 && f.bad_idx == 0, "and nothing was asked of the app it could not answer")
}

}
