package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them. ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh
// check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Where the pointer is over a node, as it moves: a dock that grows under it.


@(private = "file")
Track_Msg :: union { Pointer_At, int }

// dock: a 300 x 50 shelf holding one draggable 50 px cell, tracking the pointer unless `tracking` is false; nothing
// when `gone`.
@(private = "file")
dock :: proc(ui: ^Ui(Track_Msg), tracking := true, gone := false) -> (shelf, cell: Node) {
	begin_view(ui)
	column(ui, padding = f32(20), key = 1)
	if !gone {
		shelf = row(ui, width = 300, height = 50, key = 2)
		h: Handler(Track_Msg, Pointer_At)
		if tracking do h = proc(e: Ev(Pointer_At)) -> Track_Msg { return e.value }
		pointer_track(ui, shelf, h)
		cell = box(ui, width = 50, height = 50, key = 3)
		draggable(ui, cell, "icon", tag = 1)
		end(ui)
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 200})
	return
}

// heard runs a frame's tick and returns the last position report and how many came.
@(private = "file")
heard :: proc(ui: ^Ui(Track_Msg), now: f64) -> (at: Pointer_At, n: int) {
	clear(&ui.msgs)
	ui_after_events(ui, now)
	for m in ui.msgs {
		if v, ok := m.(Pointer_At); ok {
			at = v
			n += 1
		}
	}
	return
}

@(test)
a_tracking_node_hears_where_the_pointer_is_as_it_moves :: proc(t: ^testing.T) {
	ui: Ui(Track_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.motion.reduce = true
	ui.pointer.press_serial = 7
	shelf, cell := dock(&ui)
	sd := node_get(&ui.tree, shelf)
	o := [2]f32{sd.abs.x, sd.abs.y}

	pointer_move(&ui, o + {-10, 25})
	_, n := heard(&ui, 10)
	testing.expect_value(t, n, 0) // outside it: nothing

	pointer_move(&ui, o + {100, 25})
	pointer_move(&ui, o + {120, 25})
	pointer_move(&ui, o + {140, 20})
	at: Pointer_At
	at, n = heard(&ui, 20)
	testing.expect_value(t, n, 1) // three moves in a frame: one report, of the last
	testing.expect_value(t, at, Pointer_At{pos = {140, 20}, size = {300, 50}, inside = true})
	_, n = heard(&ui, 30)
	testing.expect_value(t, n, 0) // no motion: no report

	pointer_move(&ui, o + {25, 25})
	at, _ = heard(&ui, 40)
	testing.expect(t, at.inside && at.pos == [2]f32{25, 25}, "over its cell counts as over it")
	pointer_move(&ui, o + {25, 25}, moved = false) // the pointer given back where it already was
	_, n = heard(&ui, 50)
	testing.expect_value(t, n, 0) // nothing new to say

	pointer_move(&ui, o + {320, 25})
	at, n = heard(&ui, 60)
	testing.expect(t, n == 1 && !at.inside && at.pos == [2]f32{320, 25}, "leaving it: once, with inside false")
	pointer_move(&ui, o + {340, 25})
	_, n = heard(&ui, 70)
	testing.expect_value(t, n, 0) // outside it again: nothing more

	pointer_move(&ui, o + {150, 25})
	heard(&ui, 80)
	pointer_button(&ui, .Left, true, o + {150, 25})
	at, _ = heard(&ui, 90)
	testing.expect(t, at.inside && at.held, "a press over it holds it")
	pointer_move(&ui, o + {150, -40})
	at, _ = heard(&ui, 100)
	testing.expect(t, !at.inside && at.held && at.pos == [2]f32{150, -40}, "outside while held: still heard")
	pointer_button(&ui, .Left, false, o + {150, -40})
	at, _ = heard(&ui, 110)
	testing.expect(t, !at.inside && !at.held, "the release outside lets it go")
	pointer_move(&ui, o + {150, -60})
	_, n = heard(&ui, 120)
	testing.expect_value(t, n, 0)

	cd := node_get(&ui.tree, cell)
	c := [2]f32{cd.abs.x + 25, cd.abs.y + 25}
	pointer_move(&ui, c)
	heard(&ui, 130)
	pointer_button(&ui, .Left, true, c)
	pointer_move(&ui, c + {12, 0})
	pointer_move(&ui, c + {60, 0})
	testing.expect(t, ui.drag.active, "fixture: its cell is being dragged")
	at, _ = heard(&ui, 140)
	testing.expect(t, at.held && at.inside && at.pos == c + {60, 0} - o, "the drag takes the motion, and it is still heard")
	pointer_button(&ui, .Left, false, c + {60, 0})
	heard(&ui, 150)

	pointer_move(&ui, o + {200, 25})
	heard(&ui, 160)
	pointer_leave(&ui)
	at, n = heard(&ui, 170)
	testing.expect(t, n == 1 && !at.inside, "leaving the surface")

	dock(&ui, tracking = false)
	pointer_move(&ui, o + {210, 25})
	_, n = heard(&ui, 180)
	testing.expect_value(t, n, 0) // nil stops it

	dock(&ui)
	pointer_move(&ui, o + {220, 25})
	heard(&ui, 190)
	clear(&ui.msgs)
	dock(&ui, gone = true)
	went := false
	for m in ui.msgs {
		if v, ok := m.(Pointer_At); ok && !v.inside do went = true
	}
	testing.expect(t, went, "its node going away: inside false")
}


// Something takes the pointer (a modal overview opens, the dock hears a
// leave and falls flat), then gives it back without a move. The tracking node hears where it came back to, so the dock
// grows back under it and the next click lands on the icon; hoverable still
// waits for a move.
@(test)
a_tracking_node_hears_the_pointer_given_back_without_a_move :: proc(t: ^testing.T) {
	ui: Ui(Track_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.motion.reduce = true
	shelf, cell := dock(&ui)
	hoverable(&ui, cell, proc(e: Ev(bool)) -> Track_Msg { return 1 if e.value else 0 })
	sd := node_get(&ui.tree, shelf)
	o := [2]f32{sd.abs.x, sd.abs.y}

	pointer_move(&ui, o + {25, 25}) // resting on the dock's button
	at, _ := heard(&ui, 10)
	testing.expect(t, at.inside, "tracking it")
	pointer_leave(&ui) // the overview opens and takes the pointer
	at, _ = heard(&ui, 20)
	testing.expect(t, !at.inside, "flat while it's taken")

	clear(&ui.msgs)
	pointer_move(&ui, o + {25, 25}, moved = false) // the overview closes: an enter, the same place, no motion
	back, n := heard(&ui, 30)
	testing.expect(t, n == 1 && back.inside && back.pos == [2]f32{25, 25}, "the tracking node hears where the pointer came back to")
	hovered := false
	for m in ui.msgs do if v, ok := m.(int); ok && v == 1 do hovered = true
	testing.expect(t, !hovered, "while hoverable still waits for a move")
}

// Reports come once a frame, so a press and the moves after it can arrive
// as one report already moved: while held, it says where the press was, and
// a drag going by `pos - press` loses none of its start.
@(test)
a_held_report_says_where_the_press_was :: proc(t: ^testing.T) {
	ui: Ui(Track_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.motion.reduce = true
	shelf, _ := dock(&ui)
	sd := node_get(&ui.tree, shelf)
	o := [2]f32{sd.abs.x, sd.abs.y}

	pointer_move(&ui, o + {200, 20})
	heard(&ui, 10)
	pointer_button(&ui, .Left, true, o + {200, 20}) // the press…
	pointer_move(&ui, o + {230, 30})                // …and a move, in the same frame
	pointer_move(&ui, o + {260, 35})
	at, n := heard(&ui, 20)
	testing.expect_value(t, n, 1)
	testing.expect(t, at.held && at.pos == {260, 35} && at.press == {200, 20}, "one report, moved, still saying where the press was")
	pointer_move(&ui, o + {400, 60}) // on past its edge, held
	at, _ = heard(&ui, 30)
	testing.expect(t, at.held && at.press == {200, 20} && at.pos - at.press == {200, 40}, "the whole drag, from the press")
	pointer_button(&ui, .Left, false, o + {400, 60})
	at, _ = heard(&ui, 40)
	testing.expect(t, !at.held, "let go")
}

// A report says which buttons hold the node, so one that drag-selects with
// the left button and opens a menu with the right can tell the two presses
// apart.
@(test)
a_tracking_node_hears_which_buttons_hold_it :: proc(t: ^testing.T) {
	ui: Ui(Track_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.motion.reduce = true
	shelf, _ := dock(&ui)
	sd := node_get(&ui.tree, shelf)
	o := [2]f32{sd.abs.x, sd.abs.y}

	pointer_move(&ui, o + {100, 20})
	heard(&ui, 10)

	pointer_button(&ui, .Right, true, o + {100, 20})
	at, n := heard(&ui, 20)
	testing.expect_value(t, n, 1)
	testing.expect_value(t, at.buttons, bit_set[Mouse_Button]{.Right})
	testing.expect(t, at.held, "a right press holds it as any press does, unless it was told otherwise")

	pointer_button(&ui, .Right, false, o + {100, 20})
	at, _ = heard(&ui, 30)
	testing.expect_value(t, at.buttons, bit_set[Mouse_Button]{})
	testing.expect(t, !at.held, "and lets go")

	pointer_button(&ui, .Left, true, o + {100, 20})
	at, _ = heard(&ui, 40)
	testing.expect_value(t, at.buttons, bit_set[Mouse_Button]{.Left})
	pointer_button(&ui, .Left, false, o + {100, 20})
	heard(&ui, 50)
}

// Told which buttons it answers, it never hears the others: no hold, no
// report, so a page with a menu on the right button needs no flag of its
// own to know a press is not the start of a drag.
@(test)
a_tracker_can_answer_one_button_only :: proc(t: ^testing.T) {
	ui: Ui(Track_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.motion.reduce = true
	shelf, _ := dock(&ui)
	pointer_track(&ui, shelf, proc(e: Ev(Pointer_At)) -> Track_Msg { return e.value }, buttons = {.Left})
	sd := node_get(&ui.tree, shelf)
	o := [2]f32{sd.abs.x, sd.abs.y}

	pointer_move(&ui, o + {100, 20})
	heard(&ui, 10)

	pointer_button(&ui, .Right, true, o + {100, 20})
	_, n := heard(&ui, 20)
	testing.expect_value(t, n, 0) // not a word about it

	pointer_move(&ui, o + {400, 80}) // and it is not held: outside now, so one report saying so
	at, _ := heard(&ui, 30)
	testing.expect(t, !at.held && !at.inside, "the right press never held it")
	pointer_button(&ui, .Right, false, o + {400, 80})
	_, n2 := heard(&ui, 40)
	testing.expect_value(t, n2, 0)

	pointer_move(&ui, o + {100, 20})
	heard(&ui, 50)
	pointer_button(&ui, .Left, true, o + {100, 20}) // …but the left button still does
	at, _ = heard(&ui, 60)
	testing.expect(t, at.held && at.buttons == {.Left}, "the button it was told to answer")
	pointer_button(&ui, .Left, false, o + {100, 20})
	heard(&ui, 70)
}

// The hold is a set of buttons, not one bool: a second button's press and
// release does not let the node go while the first is still down, so a
// right-click in the middle of a drag does not end it.
@(test)
a_second_buttons_release_does_not_end_a_drag :: proc(t: ^testing.T) {
	ui: Ui(Track_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.motion.reduce = true
	shelf, _ := dock(&ui)
	sd := node_get(&ui.tree, shelf)
	o := [2]f32{sd.abs.x, sd.abs.y}

	pointer_move(&ui, o + {100, 20})
	heard(&ui, 10)
	pointer_button(&ui, .Left, true, o + {100, 20})
	at, _ := heard(&ui, 20)
	testing.expect(t, at.held && at.press == {100, 20}, "the drag is on")

	pointer_button(&ui, .Right, true, o + {120, 20})
	at, _ = heard(&ui, 30)
	testing.expect_value(t, at.buttons, bit_set[Mouse_Button]{.Left, .Right})
	testing.expect(t, at.press == {100, 20}, "and the press it is dragging from is the first one's")

	pointer_button(&ui, .Right, false, o + {120, 20})
	at, _ = heard(&ui, 40)
	testing.expect(t, at.held && at.buttons == {.Left}, "the left button is still down, so the drag is still on")

	pointer_move(&ui, o + {260, 35})
	at, _ = heard(&ui, 50)
	testing.expect(t, at.held && at.pos - at.press == {160, 15}, "and it is still the same drag")

	pointer_button(&ui, .Left, false, o + {260, 35})
	at, _ = heard(&ui, 60)
	testing.expect(t, !at.held && at.buttons == {}, "now it lets go")
}

} // when ODIN_TEST
