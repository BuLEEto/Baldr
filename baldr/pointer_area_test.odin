package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them. ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh
// check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A picture you can handle: the wheel, a double-click and a pointer shape
// on a plain node, without it becoming a control.


@(private = "file")
Pa_Msg :: union { Scroll, Pa_Kind }

@(private = "file")
Pa_Kind :: enum { None, Fit, Rotate }

@(private = "file")
Pa_Look :: struct {
	area:   bool,
	cursor: Cursor,
}

// viewer: a scroll view holding a 400 × 300 picture (a plain box) with a
// Rotate button over its corner, the picture a pointer area when asked.
@(private = "file")
viewer :: proc(ui: ^Ui(Pa_Msg), look: Pa_Look) -> (view, pic, turn: Node) {
	begin_view(ui)
	view = scroll(ui, height = 300, padding = .lg, key = 1) // the picture off the window's origin: `pos` is over it, not over the window
	pic = stack(ui, width = 400, height = 300, key = 2)
	if look.area {
		pointer_area(ui, pic, on_scroll = proc(e: Ev(Scroll)) -> Pa_Msg { return e.value }, on_double_click = Pa_Kind.Fit, cursor = look.cursor)
	} else {
		pointer_area(ui, pic)
	}
	turn = button(ui, "Turn", Pa_Kind.Rotate, key = 3)
	end(ui)
	box(ui, width = 400, height = 600, key = 4) // more below: the view scrolls
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	return
}

@(private = "file")
fits :: proc(ui: ^Ui(Pa_Msg)) -> (n: int) {
	for m in ui.msgs do if k, ok := m.(Pa_Kind); ok && k == .Fit do n += 1
	return
}

// The wheel over it goes to it, with where the pointer is over it, and not
// to the scroll view around it; it has no role, no focus and no hover or
// press look. Without the area the view scrolls.
@(test)
a_pointer_area_takes_the_wheel_without_becoming_a_control :: proc(t: ^testing.T) {
	ui: Ui(Pa_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	view, pic, _ := viewer(&ui, {area = true, cursor = .Grab})
	pd := node_get(&ui.tree, pic)
	o := [2]f32{pd.abs.x, pd.abs.y}
	testing.expect(t, o.x > 0 && o.y > 0, "fixture: the picture is not at the origin")

	pointer_move(&ui, o + {120, 80})
	testing.expect(t, scroll_event(&ui, o + {120, 80}, {0, SCROLL_STEP_PX}), "taken")
	testing.expect_value(t, len(ui.msgs), 1)
	if len(ui.msgs) == 1 {
		s, ok := ui.msgs[0].(Scroll)
		testing.expect(t, ok && s.steps == {0, 1} && s.pos == {120, 80}, "one step down, at the pointer over it")
	}
	testing.expect_value(t, scroll_offset(&ui.tree, view), [2]f32{0, 0}) // the view did not scroll under the picture
	testing.expect_value(t, ui.pointer.hover, NODE_NONE)                   // nothing to hover: no wash
	testing.expect(t, pd.access.role == .None && .Focusable not_in pd.flags, "no role, no Tab stop")
	pointer_button(&ui, .Left, true, o + {120, 80})
	testing.expect(t, .Pressed not_in pd.flags, "no press look")
	pointer_button(&ui, .Left, false, o + {120, 80})

	clear(&ui.msgs)
	viewer(&ui, {area = false}) // all nil: it is plain again
	testing.expect(t, scroll_event(&ui, o + {120, 80}, {0, SCROLL_STEP_PX}), "the view takes it")
	testing.expect_value(t, len(ui.msgs), 0)
	testing.expect(t, scroll_offset(&ui.tree, view).y > 0, "and scrolls")
}

// Two presses on it close in time and place are a double-click (a third
// starts a new pair); far apart in either, or on a control inside it, they
// are not.
@(test)
a_pointer_area_hears_a_double_click :: proc(t: ^testing.T) {
	ui: Ui(Pa_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	_, pic, turn := viewer(&ui, {area = true})
	pd := node_get(&ui.tree, pic)
	o := [2]f32{pd.abs.x, pd.abs.y}
	press :: proc(ui: ^Ui(Pa_Msg), at: [2]f32, ms: f64) {
		ui.tree.now_ms = ms
		ui.pointer.time_ms = ms // what a pair is timed on: the press, not the frame
		pointer_move(ui, at)
		pointer_button(ui, .Left, true, at)
		pointer_button(ui, .Left, false, at)
	}

	press(&ui, o + {100, 100}, 1000)
	testing.expect_value(t, fits(&ui), 0)
	press(&ui, o + {102, 101}, 1200)
	testing.expect_value(t, fits(&ui), 1)
	press(&ui, o + {102, 101}, 1350) // a third: the start of a new pair
	testing.expect_value(t, fits(&ui), 1)

	clear(&ui.msgs)
	press(&ui, o + {100, 100}, 5000)
	press(&ui, o + {100, 100}, 5000 + MULTI_CLICK_MS + 50) // too slow
	testing.expect_value(t, fits(&ui), 0)
	press(&ui, o + {100 + MULTI_CLICK_PX + 20, 100}, 5000 + MULTI_CLICK_MS + 150) // too far
	testing.expect_value(t, fits(&ui), 0)

	td := node_get(&ui.tree, turn)
	b := [2]f32{td.abs.x + 5, td.abs.y + 5}
	press(&ui, b, 9000)
	press(&ui, b, 9100) // the button's own presses
	testing.expect_value(t, fits(&ui), 0)
	rotates := 0
	for m in ui.msgs do if k, ok := m.(Pa_Kind); ok && k == .Rotate do rotates += 1
	testing.expect_value(t, rotates, 2)
}

// Its cursor shows over it, a control inside it keeps its own, a press that
// started on it keeps its cursor past its edge until the release, and Hidden
// hides the pointer.
@(test)
a_pointer_area_names_the_pointers_shape :: proc(t: ^testing.T) {
	ui: Ui(Pa_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	_, pic, turn := viewer(&ui, {area = true, cursor = .Grab})
	pd := node_get(&ui.tree, pic)
	o := [2]f32{pd.abs.x, pd.abs.y}

	pointer_move(&ui, o + {200, 200})
	testing.expect_value(t, cursor_for(&ui), Cursor.Grab)
	td := node_get(&ui.tree, turn)
	pointer_move(&ui, {td.abs.x + 5, td.abs.y + 5})
	testing.expect_value(t, cursor_for(&ui), Cursor.Pointer) // the button's
	pointer_move(&ui, o + {200, 200})

	pointer_button(&ui, .Left, true, o + {200, 200})
	viewer(&ui, {area = true, cursor = .Grabbing}) // the app saw the press and pans
	pointer_move(&ui, o + {500, 350}) // past its edge, still held
	testing.expect_value(t, cursor_for(&ui), Cursor.Grabbing)
	pointer_button(&ui, .Left, false, o + {500, 350})
	testing.expect_value(t, cursor_for(&ui), Cursor.Default) // let go, outside it

	viewer(&ui, {area = true, cursor = .Hidden}) // a slideshow, the pointer still
	pointer_move(&ui, o + {200, 200})
	testing.expect_value(t, cursor_for(&ui), Cursor.Hidden)
	viewer(&ui, {area = false})
	testing.expect_value(t, cursor_for(&ui), Cursor.Default)
}

@(test)
a_turn_right_icon_beside_the_turn_left :: proc(t: ^testing.T) {
	testing.expect(t, ICON_PATHS[.Rotate_Cw] != "" && ICON_PATHS[.Rotate_Cw] != ICON_PATHS[.Rotate_Ccw], "its own shape")
}

// A cursor the app draws: over the area the pointer is its
// picture, with its hotspot; a control inside keeps its own shape.
@(test)
a_pointer_area_cursor_can_be_a_picture :: proc(t: ^testing.T) {
	ui: Ui(Pa_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	px := make([]u8, 24 * 24 * 4, context.temp_allocator)
	ring, _ := image_from_rgba(24, 24, px)
	defer image_destroy(&ring)
	begin_view(&ui)
	view := scroll(&ui, height = 300, padding = .lg, key = 1)
	pic := stack(&ui, width = 400, height = 300, key = 2)
	pointer_area(&ui, pic, cursor_image = &ring, hotspot = {12, 12})
	turn := button(&ui, "Turn", Pa_Kind.Rotate, key = 3)
	end(&ui)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 400})
	_ = view
	pd := node_get(&ui.tree, pic)
	pointer_move(&ui, {pd.abs.x + 200, pd.abs.y + 200})
	testing.expect_value(t, cursor_for(&ui), Cursor.Picture)
	img, hot, ok := pointer_area_picture(&ui)
	testing.expect(t, ok && img == &ring && hot == {12, 12}, "its picture and hotspot")
	td := node_get(&ui.tree, turn)
	pointer_move(&ui, {td.abs.x + 5, td.abs.y + 5})
	testing.expect_value(t, cursor_for(&ui), Cursor.Pointer) // the button's own
	_, _, ok = pointer_area_picture(&ui)
	testing.expect(t, !ok, "no picture over the button")
}

// An `image` is a perfectly good thing to make a pointer area of — a
// canvas, a photo, the checkerboard `spikes/wincheck` holds a cursor over —
// and giving it a `label`, which every accessible picture should have, must
// not take its cursor away.
@(test)
a_labelled_picture_still_gets_the_pointer_areas_cursor :: proc(t: ^testing.T) {
	ui: Ui(Pa_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	px := make([]u8, 8 * 8 * 4, context.temp_allocator)
	ring, _ := image_from_rgba(8, 8, px)
	defer image_destroy(&ring)
	checks, _ := image_from_rgba(8, 8, px)
	defer image_destroy(&checks)

	begin_view(&ui)
	strip := image(&ui, &checks, width = 400, height = 200, label = "put the pointer here", key = 1)
	pointer_area(&ui, strip, cursor_image = &ring, hotspot = {4, 4})
	end_view(&ui)
	frame(&ui.tree, {600, 400})

	sd := node_get(&ui.tree, strip)
	pointer_move(&ui, {sd.abs.x + 200, sd.abs.y + 100})
	testing.expect_value(t, cursor_for(&ui), Cursor.Picture)
	img, hot, ok := pointer_area_picture(&ui)
	testing.expect(t, ok && img == &ring && hot == {4, 4}, "its picture and hotspot")
}

} // when ODIN_TEST