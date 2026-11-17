package baldr

@(require) import "core:testing"
@(require) import "baldr:platform"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them. ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh
// check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Every pointer and pen sample for a canvas, once a frame; and a pen that
// works the rest of the window as a pointer does.


@(private = "file")
Ps_Msg :: union { Pointer_Samples, Ps_Click }
@(private = "file")
Ps_Click :: struct {}

@(private = "file")
canvas_pair :: proc(ui: ^Ui(Ps_Msg), hover := false) -> (c, b: Node) {
	begin_view(ui)
	row(ui, padding = f32(20), gap = f32(20))
	c = box(ui, width = 300, height = 200, key = 1)
	pointer_samples(ui, c, proc(e: Ev(Pointer_Samples)) -> Ps_Msg { return e.value }, hover = hover) // as an app does: the slice as given
	b = button(ui, "Tool", Ps_Msg(Ps_Click{}), key = 2)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {700, 300})
	return
}

@(private = "file")
clone_samples :: proc(s: []Pointer_Sample) -> []Pointer_Sample {
	out := make([]Pointer_Sample, len(s), context.temp_allocator)
	copy(out, s)
	return out
}

@(private = "file")
batches :: proc(ui: ^Ui(Ps_Msg)) -> (out: [dynamic]Pointer_Samples) {
	out = make([dynamic]Pointer_Samples, context.temp_allocator)
	for m in ui.msgs do if b, ok := m.(Pointer_Samples); ok do append(&out, b)
	return
}

// A stroke is every sample, in order, with its time and the buttons held,
// from the press through to the release — outside the canvas too — in one
// message a frame.
@(test)
a_canvas_hears_every_sample_of_a_stroke :: proc(t: ^testing.T) {
	ui: Ui(Ps_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	c, _ := canvas_pair(&ui)
	o := node_get(&ui.tree, c).abs
	at :: proc(o: Rect, x, y: f32) -> [2]f32 { return {o.x + x, o.y + y} }

	pointer_move(&ui, at(o, 10, 10))
	mouse_sample(&ui, .Move, .Left, 100, at(o, 10, 10)) // hovering, not asked for: not kept
	pointer_button(&ui, .Left, true, at(o, 10, 10))
	mouse_sample(&ui, .Press, .Left, 101, at(o, 10, 10))
	for i in 1 ..= 5 {
		p := at(o, 10 + f32(i) * 3.25, 10 + f32(i))
		pointer_move(&ui, p)
		mouse_sample(&ui, .Move, .Left, 101 + u32(i), p)
	}
	pointer_move(&ui, at(o, 400, 10)) // out past its edge, still held
	mouse_sample(&ui, .Move, .Left, 107, at(o, 400, 10))
	pointer_button(&ui, .Left, false, at(o, 400, 10))
	mouse_sample(&ui, .Release, .Left, 108, at(o, 400, 10))
	pointer_move(&ui, at(o, 20, 20)) // let go: no more
	mouse_sample(&ui, .Move, .Left, 109, at(o, 20, 20))

	clear(&ui.msgs)
	ui_after_events(&ui, 1)
	// the run loop handles these messages on its next pass, after the frame's
	// temp memory has been freed and used again: the samples must not live there
	free_all(context.temp_allocator)
	junk := make([]u8, 1 << 16, context.temp_allocator)
	for &j in junk do j = 0
	b := batches(&ui)
	testing.expect_value(t, len(b), 1) // one message for the frame
	if len(b) != 1 do return
	s := b[0].samples
	testing.expect_value(t, len(s), 8)
	if len(s) != 8 do return
	testing.expect(t, s[0].kind == .Press && s[0].buttons == {.Left} && s[0].pressure == 1 && s[0].contact, "the press")
	testing.expect_value(t, s[3].pos, [2]f32{19.75, 13}) // sub-pixel, from the canvas' corner
	testing.expect_value(t, s[3].time_ms, f64(104)) // the event's own time
	testing.expect(t, s[6].kind == .Move && s[6].pos.x == 400, "past its edge, still its")
	testing.expect(t, s[7].kind == .Release && s[7].buttons == {} && s[7].pressure == 0, "the release, nothing held")
	testing.expect_value(t, b[0].size, [2]f32{300, 200})

	clear(&ui.msgs)
	ui_after_events(&ui, 2)
	testing.expect_value(t, len(batches(&ui)), 0) // nothing new: no message
}

@(test)
a_canvas_hears_hovering_only_when_asked :: proc(t: ^testing.T) {
	ui: Ui(Ps_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	c, b := canvas_pair(&ui, hover = true)
	o := node_get(&ui.tree, c).abs
	pointer_move(&ui, {o.x + 50, o.y + 50})
	mouse_sample(&ui, .Move, .Left, 10, {o.x + 50, o.y + 50})
	bd := node_get(&ui.tree, b).abs
	pointer_move(&ui, {bd.x + 5, bd.y + 5}) // over the button beside it
	mouse_sample(&ui, .Move, .Left, 11, {bd.x + 5, bd.y + 5})
	clear(&ui.msgs)
	ui_after_events(&ui, 1)
	bs := batches(&ui)
	testing.expect(t, len(bs) == 1 && len(bs[0].samples) == 1 && bs[0].samples[0].pos == {50, 50}, "the hover over it, not beside it")
}

// A pen: its tip presses what it is on, as the left button (the rest of the
// window works with it), and its samples carry pressure, tilt and the tool.
@(test)
a_pen_draws_and_presses :: proc(t: ^testing.T) {
	ui: Ui(Ps_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	c, b := canvas_pair(&ui, hover = true)
	o := node_get(&ui.tree, c).abs
	pen :: proc(ui: ^Ui(Ps_Msg), phase: platform.Pen_Phase, at: [2]f32, pressure: f32, time: u32, tool := platform.Pen_Tool.Pen) {
		pen_event(ui, platform.Ev_Pen{phase = phase, tool = tool, pos = at, pressure = pressure, tilt = {12, -30}, rotation = 5, distance = -1,
			contact = phase == .Down || (phase == .Move && pressure > 0), time_ms = time}, at)
	}
	pen(&ui, .Near, {o.x + 30, o.y + 30}, 0, 1)
	pen(&ui, .Down, {o.x + 30, o.y + 30}, 0.2, 2)
	pen(&ui, .Move, {o.x + 40, o.y + 32}, 0.55, 3)
	pen(&ui, .Up, {o.x + 40, o.y + 32}, 0, 4)
	pen(&ui, .Away, {o.x + 40, o.y + 32}, 0, 5)
	clear(&ui.msgs)
	ui_after_events(&ui, 1)
	bs := batches(&ui)
	if len(bs) != 1 do testing.fail_now(t, "one batch")
	s := bs[0].samples
	testing.expect_value(t, len(s), 5)
	if len(s) == 5 {
		testing.expect(t, s[0].kind == .Enter && s[0].tool == .Pen, "near")
		testing.expect(t, s[2].kind == .Move && s[2].pressure == 0.55 && s[2].tilt == {12, -30} && s[2].rotation == 5 && s[2].contact, "pressure and tilt")
		testing.expect(t, s[3].kind == .Release && s[3].buttons == {}, "the tip up")
		testing.expect(t, s[4].kind == .Leave, "away")
	}

	clear(&ui.msgs) // the pen on a button clicks it
	bd := node_get(&ui.tree, b).abs
	p := [2]f32{bd.x + 5, bd.y + 5}
	pen(&ui, .Near, p, 0, 10)
	pen(&ui, .Down, p, 0.4, 11)
	pen(&ui, .Up, p, 0, 12)
	clicked := false
	for m in ui.msgs do if _, ok := m.(Ps_Click); ok do clicked = true
	testing.expect(t, clicked, "the pen's tip clicks a button")

	pen(&ui, .Near, {o.x + 10, o.y + 10}, 0, 20, tool = .Eraser)
	clear(&ui.msgs)
	ui_after_events(&ui, 2)
	bs = batches(&ui)
	testing.expect(t, len(bs) == 1 && bs[0].samples[len(bs[0].samples) - 1].tool == .Eraser, "the other end: the eraser")
}

} // when ODIN_TEST