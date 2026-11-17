package baldr

@(require) import "core:testing"
@(require) import "baldr:platform"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: about 9 GB without this `when`, 1 GB with it.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A layer surface that hides at its edge.


@(test)
hiding_follows_the_pointer_popovers_the_keyboard_and_the_delay :: proc(t: ^testing.T) {
	always := Layer_Hide{mode = .Always, delay_ms = 400}
	shown, wake := hide_decide(Layer_Hide{}, false, false, false, 0, 10000)
	testing.expect(t, shown && wake == 0, "Never: shown")
	shown, wake = hide_decide(always, false, false, false, 1000, 1200)
	testing.expect(t, shown && wake == 1400, "Always: shown until the delay after the pointer left, with a wake-up then")
	shown, _ = hide_decide(always, false, false, false, 1000, 1400)
	testing.expect(t, !shown, "then hidden")
	for holds in ([][3]bool{{true, false, false}, {false, true, false}, {false, false, true}}) {
		shown, _ = hide_decide(always, holds[0], holds[1], holds[2], 0, 10000)
		testing.expectf(t, shown, "the pointer on it, a popover open on it, or the keyboard keep it shown: %v", holds)
	}
	overlap := Layer_Hide{mode = .Overlap}
	shown, _ = hide_decide(overlap, false, false, false, 0, 10000)
	testing.expect(t, shown, "Overlap, not covered: shown")
	overlap.covered = true
	shown, wake = hide_decide(overlap, false, false, false, 9800, 10000)
	testing.expect(t, shown && wake == 9800 + f64(HIDE_DELAY_MS), "covered: hidden the default delay after the pointer left")
	shown, _ = hide_decide(overlap, true, false, false, 0, 10000)
	testing.expect(t, shown, "covered, with the pointer on it: shown")
}

@(test)
a_hiding_surface_slides_off_its_edge_and_keeps_a_strip_there :: proc(t: ^testing.T) {
	size := [2]f32{600, 64}
	testing.expect_value(t, hide_offset(.Bottom, size, 1), [2]f32{0, 64})
	testing.expect_value(t, hide_offset(.Top, size, 0.5), [2]f32{0, -32})
	testing.expect_value(t, hide_offset(.Left, size, 1), [2]f32{-600, 0})
	testing.expect_value(t, hide_offset(.Right, size, 0.25), [2]f32{150, 0})
	testing.expect_value(t, hide_strip(.Bottom, size, 0), [4]f32{0, 62, 600, 2})
	testing.expect_value(t, hide_strip(.Top, size, 4), [4]f32{0, 0, 600, 4})
	testing.expect_value(t, hide_strip(.Right, size, 3), [4]f32{597, 0, 3, 64})
}

@(test)
surface_rect_places_a_layer_surface_on_its_screen :: proc(t: ^testing.T) {
	screen := [2]f32{1280, 720}
	testing.expect_value(t, layer_rect(Layer_Desc{anchor = {.Bottom}}, {600, 64}, screen), Rect{340, 656, 600, 64})
	testing.expect_value(t, layer_rect(Layer_Desc{anchor = {.Top, .Left, .Right}, margin = {4, 8, 0, 8}}, {1264, 36}, screen), Rect{8, 4, 1264, 36})
	testing.expect_value(t, layer_rect(Layer_Desc{anchor = {.Bottom, .Right}, margin = {0, 12, 10, 0}}, {300, 200}, screen), Rect{968, 510, 300, 200})
	_, _, ok := surface_rect(99)
	testing.expect(t, !ok, "a tag with no surface")
}

@(test)
a_hiding_surface_takes_no_exclusive_zone_and_draws_its_tint_as_its_shape :: proc(t: ^testing.T) {
	d := Surface_Desc(int){kind = .Layer, transparent = true, backdrop = .Blur, layer = {anchor = {.Bottom}, exclusive_zone = 64}}
	th := theme_dark()
	testing.expect_value(t, layer_placed(d).exclusive_zone, 64)
	testing.expect(t, surface_shape(&th, d, true) == {}, "square and never hiding: its tint is its clear")
	e := d
	e.hide = {mode = .Always}
	testing.expect_value(t, layer_placed(e).exclusive_zone, 0)
	testing.expect_value(t, surface_resolve(e, {.Layer_Shell, .Transparent, .Backdrop_Blur}, "test").layer.exclusive_zone, 0)
	testing.expect(t, surface_shape(&th, e, true) != {} && surface_clear(&th, e, true) == {}, "hiding: its tint is its shape, to slide with it")
	testing.expect(t, .Hide in surface_changes(d, e) && .Hide in SURFACE_LIVE_CHANGES, "a live change")
}

@(test)
a_hiding_surface_shows_for_the_pointer_popovers_and_the_keyboard :: proc(t: ^testing.T) {
	c: Surface_Ctx(int)
	ui_init(&c.ui)
	defer ui_destroy(&c.ui)
	c.kind = .Layer
	c.surf = 1
	c.desc = Surface_Desc(int){kind = .Layer, transparent = true, layer = {anchor = {.Bottom}}, hide = {mode = .Always, delay_ms = 400}}
	c.hide_st.left_ms = 1000

	hide_sync(&c, 1100)
	testing.expect(t, !c.fc.hidden && c.ui.tree.wake_at_ms == 1400, "shown for its delay, with a wake-up at its end")
	testing.expect_value(t, c.fc.hide_edge, Edge.Bottom)
	hide_sync(&c, 1400)
	testing.expect(t, c.fc.hidden && c.needs_frame && !c.fc.input_sent_ok, "hidden: a frame, and its input region again")

	c.needs_frame = false
	c.hide_st.pointer_on = 1 // the pointer reached its strip
	hide_sync(&c, 2000)
	testing.expect(t, !c.fc.hidden && c.needs_frame, "shown")
	hide_pointer_left(&c, 2, 2100)
	testing.expect_value(t, c.hide_st.pointer_on, platform.Surface(1)) // another surface's leave changes nothing
	hide_pointer_left(&c, 1, 2100)
	hide_sync(&c, 2400)
	testing.expect(t, !c.fc.hidden, "within its delay after the pointer left")

	c.ui.dismiss[Node(5)] = {} // a menu open on it
	hide_sync(&c, 9000)
	testing.expect(t, !c.fc.hidden, "a menu open keeps it shown")
	delete_key(&c.ui.dismiss, Node(5))
	c.hide_st.focus_on = 2 // its menu's surface has the keyboard
	hide_sync(&c, 9000)
	testing.expect(t, !c.fc.hidden, "the keyboard in it keeps it shown")
	hide_surface_closed(&c, 2, 9000) // the menu closes; a compositor may send no leave for a surface it destroyed
	hide_sync(&c, 9000)
	testing.expect(t, c.fc.hidden, "nothing holds it: hidden")

	c.fc.slide = {0, 30}
	testing.expect_value(t, popup_pointer(&c, 1, {100, 40}), [2]f32{100, 10}) // the pointer over its moved drawing
	c.desc.hide.mode = .Never
	hide_sync(&c, 9000)
	testing.expect(t, !c.fc.hidden, "Never: shown again")
}

@(private = "file")
Hide_Log :: struct {
	inputs, blurs, backdrops: int,
	rects:                    [dynamic][4]f32,
	radii:                    [dynamic]f32,
	all:                      bool,
}

@(private = "file")
hide_backend :: proc(log: ^Hide_Log) -> platform.Backend {
	b := platform.Backend{data = log}
	b.surface_set_input_region = proc(b: ^platform.Backend, s: platform.Surface, rects: [][4]f32, all: bool) {
		lg := (^Hide_Log)(b.data)
		lg.inputs += 1
		clear(&lg.rects)
		append(&lg.rects, ..rects)
		lg.all = all
	}
	b.surface_set_blur_region = proc(b: ^platform.Backend, s: platform.Surface, rects: [][4]f32, radii: []f32) {
		lg := (^Hide_Log)(b.data)
		lg.blurs += 1
		clear(&lg.rects)
		append(&lg.rects, ..rects)
		clear(&lg.radii)
		append(&lg.radii, ..radii)
	}
	b.surface_set_backdrop = proc(b: ^platform.Backend, s: platform.Surface, backdrop: platform.Backdrop) {
		(^Hide_Log)(b.data).backdrops += 1
	}
	return b
}

// Hidden, it takes the pointer on its strip, its drawing slides off, its blur
// goes with it and a change on it presents all of it; shown, all come back.
@(test)
a_hidden_surface_takes_the_pointer_on_its_strip_and_its_blur_goes_with_it :: proc(t: ^testing.T) {
	log: Hide_Log
	defer {
		delete(log.rects)
		delete(log.radii)
	}
	b := hide_backend(&log)
	ui: Ui(int)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.motion.reduce = true
	begin_view(&ui)
	text(&ui, "Dock")
	end_view(&ui)
	frame(&ui.tree, {600, 64})
	take_damage(&ui.tree)
	fc := Frame_Ctx{tree = &ui.tree, backend = &b, surface = 1, size = {600, 64}, size_px = {600, 64}, drawn_px = {600, 64}, scale = 1,
		input = .All, hide = {mode = .Always}, hide_edge = .Bottom, hidden = true, blur_whole = true, shape_radius = 16}
	defer delete(fc.input_sent)
	defer delete(fc.damage)
	defer delete(fc.blur_sent)

	input_region_sync(&fc)
	testing.expect(t, log.inputs == 1 && !log.all && len(log.rects) == 1 && log.rects[0] == [4]f32{0, 62, 600, 2}, "hidden: its strip")
	input_region_sync(&fc)
	testing.expect_value(t, log.inputs, 1) // unchanged: not sent again

	hide_frame(&fc)
	testing.expect(t, fc.slide == [2]f32{0, 64} && fc.present_whole, "slid off its edge, presented whole")
	backdrop_region_sync(&fc)
	testing.expect(t, log.blurs == 1 && len(log.rects) == 1 && log.rects[0][3] == 0 && log.radii[0] == 16, "its blur went with it")
	damage_add(&ui.tree, Rect{10, 10, 20, 20})
	fc.present_whole = false
	testing.expect(t, frame_damage(&fc) && len(fc.damage) == 0, "a change on it while slid: all of it")

	fc.hidden = false
	fc.input_sent_ok = false
	input_region_sync(&fc)
	testing.expect(t, log.inputs == 2 && len(log.rects) > 1, "shown: its rounded shape takes the pointer again")
	hide_frame(&fc)
	testing.expect_value(t, fc.slide, [2]f32{})
	backdrop_region_sync(&fc)
	testing.expect_value(t, log.backdrops, 1) // blurred behind as a whole again
}

// A surface blurred behind its marked cards moves that blur with its slide.
@(test)
a_hiding_surfaces_marked_blur_slides_with_it :: proc(t: ^testing.T) {
	log: Hide_Log
	defer {
		delete(log.rects)
		delete(log.radii)
	}
	b := hide_backend(&log)
	ui: Ui(int)
	ui_init(&ui)
	defer ui_destroy(&ui)
	card_n: Node
	begin_view(&ui)
	column(&ui, padding = f32(8))
	card_n = card(&ui, width = 200, height = 40)
	backdrop_area(&ui, card_n)
	end(&ui)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 64})
	fc := Frame_Ctx{tree = &ui.tree, backend = &b, surface = 1, size = {600, 64}, scale = 1, backdrop_region = .Marked, slide = {0, 20}}
	defer delete(fc.blur_sent)
	backdrop_region_sync(&fc)
	cd := node_get(&ui.tree, card_n)
	testing.expect(t, log.blurs == 1 && len(log.rects) == 1 && log.rects[0] == [4]f32{cd.abs.x, cd.abs.y + 20, cd.abs.w, cd.abs.h}, "moved with its drawing")
}

// A floating bar that hides keeps the gap it asks for while it
// shows, and sits at the screen's own edge only while it is out of sight, so
// the pointer in the corner still finds its reveal strip.
@(test)
a_hiding_surface_keeps_its_margin_until_it_is_out_of_sight :: proc(t: ^testing.T) {
	floating := Surface_Desc(int){kind = .Layer, transparent = true, layer = {anchor = {.Bottom}, margin = {6, 6, 6, 6}, exclusive_zone = 64}}
	testing.expect_value(t, layer_placed(floating, true).margin, [4]i32{6, 6, 6, 6}) // never hiding: as declared, wherever it is
	hiding := floating
	hiding.hide = {mode = .Overlap}
	testing.expect_value(t, layer_placed(hiding).margin, [4]i32{6, 6, 6, 6})           // shown: its gap
	testing.expect_value(t, layer_placed(hiding, true).margin, [4]i32{6, 6, 0, 6})     // hidden: at the screen's edge, the other margins kept
	testing.expect_value(t, layer_placed(hiding, true).exclusive_zone, 0)

	for e in ([]struct{ anchor: bit_set[Edge; u8], out: [4]i32 } {
		{{.Top}, {0, 6, 6, 6}},
		{{.Left}, {6, 6, 6, 0}},
		{{.Right}, {6, 0, 6, 6}},
	}) {
		d := hiding
		d.layer.anchor = e.anchor
		testing.expectf(t, layer_placed(d, true).margin == e.out, "%v: only that edge's margin goes (%v)", e.anchor, layer_placed(d, true).margin)
	}

	// the strip is then along the screen's own edge, where the pointer can reach it
	screen := [2]f32{1280, 720}
	size := [2]f32{600, 64}
	shown := layer_rect(layer_placed(hiding), size, screen)
	hidden := layer_rect(layer_placed(hiding, true), size, screen)
	testing.expect_value(t, shown.y + shown.h, screen.y - 6) // its gap while it shows
	testing.expect_value(t, hidden.y + hidden.h, screen.y)   // at the edge while hidden
	strip := hide_strip(.Bottom, size, 0)
	testing.expect_value(t, hidden.y + strip[1] + strip[3], screen.y)

	// it moves only once it is fully slid out, and comes back as it slides in
	fc: Frame_Ctx
	fc.hide = hiding.hide
	fc.hide_edge = .Bottom
	fc.size = size
	testing.expect(t, !hide_at_edge(&fc), "shown: its margin stays")
	fc.hidden = true
	fc.slide = hide_offset(.Bottom, size, 0.5)
	testing.expect(t, !hide_at_edge(&fc), "still sliding: not yet")
	fc.slide = hide_offset(.Bottom, size, 1)
	testing.expect(t, hide_at_edge(&fc), "out of sight: now")
	fc.hidden = false
	testing.expect(t, !hide_at_edge(&fc), "coming back: its margin first")
	fc.hide.mode = .Never
	fc.hidden = true
	testing.expect(t, !hide_at_edge(&fc), "a surface that never hides never moves")
}

@(test)
a_hidden_bar_shows_for_a_drag :: proc(t: ^testing.T) {
	// A hidden bar slides out when a drag reaches it, as a hidden taskbar
	// or Dock does; that is how a file gets onto a dock icon at all. A drag
	// the compositor carries arrives as Ev_Drag_Enter and brings no
	// wl_pointer.enter with it, so the drag must hold the bar itself.
	always := Layer_Hide{mode = .Always, delay_ms = 400}
	st: Hide_State
	testing.expect(t, !hide_held(st), "nothing holds it to begin with")

	st.drag_on = 7 // a drag came over the bar, or over its reveal strip
	testing.expect(t, hide_held(st), "a drag over it holds it open")
	shown, _ := hide_decide(always, hide_held(st), false, false, 0, 10_000)
	testing.expect(t, shown, "so it is shown")

	hide_left_st(&st, 7, 10_000, drag = true)
	testing.expect(t, !hide_held(st), "and lets go when the drag leaves")
	testing.expect_value(t, st.left_ms, f64(10_000))
	held: bool
	wake: f64
	held, wake = hide_decide(always, hide_held(st), false, false, st.left_ms, 10_100)
	testing.expect(t, held && wake == 10_400, "it stays up for the delay, as it does for the pointer")
	shown, _ = hide_decide(always, hide_held(st), false, false, st.left_ms, 10_500)
	testing.expect(t, !shown, "then hides")
}

@(test)
a_drag_that_ends_does_not_hold_the_bar_open :: proc(t: ^testing.T) {
	// A drop is not followed by a leave, and a drag that ends is reported
	// to every window at once naming no surface, so that must clear the
	// hold or the bar stays out for good.
	st := Hide_State{drag_on = 7}
	hide_left_st(&st, 0, 5_000, drag = true) // "wherever it was"
	testing.expect(t, !hide_held(st), "a drag ending anywhere lets go of the bar")

	st = Hide_State{drag_on = 7}
	hide_left_st(&st, 9, 5_000, drag = true)
	testing.expect(t, hide_held(st), "a leave for a different surface is not ours")
}

@(test)
the_pointer_and_a_drag_hold_the_bar_apart :: proc(t: ^testing.T) {
	// The ordinary way a file reaches a dock: the pointer is already on
	// the bar when the drag arrives, or the drag arrives first and the
	// pointer follows. Whichever goes first must not start the delay
	// while the other is still there — the bar would hide under the file.
	st := Hide_State{pointer_on = 3, drag_on = 3}
	hide_left_st(&st, 3, 1_000, drag = false)
	testing.expect(t, hide_held(st), "the pointer going leaves the drag holding it")
	testing.expect_value(t, st.left_ms, f64(0))
	hide_left_st(&st, 3, 2_000, drag = true)
	testing.expect(t, !hide_held(st), "and the drag going lets it go")
	testing.expect_value(t, st.left_ms, f64(2_000))

	st = Hide_State{pointer_on = 3, drag_on = 3}
	hide_left_st(&st, 3, 1_000, drag = true)
	testing.expect(t, hide_held(st), "and the other way round")
	testing.expect_value(t, st.left_ms, f64(0))
}

} // when ODIN_TEST