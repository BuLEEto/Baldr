package baldr

@(require) import "core:strings"

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A clickable's own on_double_click: a click selects, a double-click acts.
// A pointer_area on the same node cannot do it — pointer_area_press stops
// at the hovered node, which for a control is the area itself, so the
// press is never paired.

@(private = "file")
Dbl_Msg :: union { int }

@(private = "file")
cd_view :: proc(ui: ^Ui(Dbl_Msg), dbl: Maybe(Dbl_Msg)) -> Node {
	set_viewport(&ui.tree, {300, 200})
	begin_view(ui)
	col := column(ui, padding = .md, key = 1)
	text(ui, "a card", key = 2)
	end(ui)
	clickable(ui, col, Dbl_Msg(1), label = "Card", on_double_click = dbl)
	end_view(ui)
	frame(&ui.tree, {300, 200})
	return col
}

@(private = "file")
cd_click :: proc(ui: ^Ui(Dbl_Msg), n: Node, at: [2]f32, ms: f64) {
	ui.tree.now_ms = ms
	ui.pointer.time_ms = ms // what a pair is timed on: the click, not the frame
	ui.pointer.pos = at
	click(ui, n)
}

// Two clicks close together: the second sends the double as well, after its
// own click.
@(test)
a_clickable_answers_a_double_click :: proc(t: ^testing.T) {
	ui: Ui(Dbl_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := cd_view(&ui, Dbl_Msg(2))

	cd_click(&ui, n, {20, 20}, 1000)
	testing.expect_value(t, len(ui.msgs), 1) // the click alone
	testing.expect_value(t, ui.msgs[0], Dbl_Msg(1))

	cd_click(&ui, n, {21, 20}, 1200) // 200 ms and 1 px later
	if testing.expect_value(t, len(ui.msgs), 3) {
		testing.expect_value(t, ui.msgs[1], Dbl_Msg(1)) // its own click first…
		testing.expect_value(t, ui.msgs[2], Dbl_Msg(2)) // …then the double
	}

	// a third click starts a new pair rather than making a triple
	clear(&ui.msgs)
	cd_click(&ui, n, {21, 20}, 1300)
	testing.expect_value(t, len(ui.msgs), 1)
}

// A double-click asked for with no on_click is reported, not swallowed.
// A clickable's other answers hang off its click, so `on_click = nil` drops
// them — which is how a clickable is removed, and a trap for anyone who
// wanted a double-click without a plain one.
@(test)
a_double_click_with_no_click_is_reported :: proc(t: ^testing.T) {
	ui: Ui(Dbl_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	set_viewport(&ui.tree, {300, 200})
	begin_view(&ui)
	c := column(&ui, padding = .md, key = 1)
	end(&ui)
	clickable(&ui, c, nil, on_double_click = Dbl_Msg(2), on_context = Dbl_Msg(3))
	end_view(&ui)

	testing.expect_value(t, len(ui.tree.diags), 1)
	if len(ui.tree.diags) == 1 {
		msg := ui.tree.diags[0].msg
		testing.expect(t, strings.contains(msg, "on_double_click"), "it names the handler that went")
		testing.expect(t, strings.contains(msg, "on_context"), "…and the other one")
		testing.expect(t, strings.contains(msg, "no on_click"), "…and why")
	}

	// And nothing is reported for the ordinary teardown: no click and none of
	// the three, which is an app taking a clickable away.
	for d in ui.tree.diags do delete(d.msg, ui.tree.allocator) // `diag` clones; clearing alone leaks it
	clear(&ui.tree.diags)
	begin_view(&ui)
	c2 := column(&ui, padding = .md, key = 1)
	end(&ui)
	clickable(&ui, c2, nil)
	end_view(&ui)
	testing.expect_value(t, len(ui.tree.diags), 0)
}

// A pair is timed on the clicks, not on the frames. `Tree.now_ms` says when
// the app last woke up, so a gap read from it is the real gap plus however
// long the frame took, and a slow frame (a first click with cold caches)
// would break a double-click.
@(test)
a_double_click_is_timed_on_the_clicks_and_not_the_frames :: proc(t: ^testing.T) {
	ui: Ui(Dbl_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := cd_view(&ui, Dbl_Msg(2))

	// Two clicks 100 ms apart, with a frame clock that crawled five seconds
	// between them: still a double-click.
	ui.tree.now_ms = 1000
	ui.pointer.time_ms, ui.pointer.pos = 50_000, {20, 20}
	click(&ui, n)
	ui.tree.now_ms = 6000
	ui.pointer.time_ms = 50_100
	click(&ui, n)
	testing.expect_value(t, len(ui.msgs), 3) // click, click, double

	// And the other way: no time passed on the frame clock, but the person
	// clicked half a second apart, so it is not one.
	clear(&ui.msgs)
	ui.tree.now_ms = 9000
	ui.pointer.time_ms = 60_000
	click(&ui, n)
	ui.pointer.time_ms = 60_500
	click(&ui, n)
	testing.expect_value(t, len(ui.msgs), 2) // two clicks, no double

	// The platform clock is 32-bit milliseconds and wraps about every 49
	// days. A gap subtracted across the wrap goes negative, which passes a
	// check of the upper bound alone.
	clear(&ui.msgs)
	ui.pointer.time_ms = 4_294_967_285 // ten milliseconds before a 32-bit counter runs out
	click(&ui, n)
	ui.pointer.time_ms = 5 // the counter went round
	click(&ui, n)
	testing.expect_value(t, len(ui.msgs), 2) // two clicks, no double
}

// Too slow, or too far, and it is two separate clicks.
@(test)
a_double_click_needs_to_be_close_in_time_and_place :: proc(t: ^testing.T) {
	ui: Ui(Dbl_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := cd_view(&ui, Dbl_Msg(2))

	cd_click(&ui, n, {20, 20}, 1000)
	cd_click(&ui, n, {20, 20}, 1000 + MULTI_CLICK_MS + 1) // a moment too slow
	testing.expect_value(t, len(ui.msgs), 2) // two clicks, no double
	clear(&ui.msgs)

	cd_click(&ui, n, {20, 20}, 3000)
	cd_click(&ui, n, {20 + MULTI_CLICK_PX + 1, 20}, 3100) // a pixel too far
	testing.expect_value(t, len(ui.msgs), 2)
}

// A clickable that asks for no double still just clicks, and taking the
// click away takes the double with it.
@(test)
a_clickable_without_a_double_is_unchanged :: proc(t: ^testing.T) {
	ui: Ui(Dbl_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := cd_view(&ui, nil)

	cd_click(&ui, n, {20, 20}, 1000)
	cd_click(&ui, n, {20, 20}, 1100)
	testing.expect_value(t, len(ui.msgs), 2) // two clicks and nothing else
	testing.expect(t, len(ui.double_clicks) == 0 && len(ui.click_pairs) == 0, "nothing was kept for it")
}

}
