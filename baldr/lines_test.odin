package baldr

@(require) import "core:math"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Polylines drawn over a node, dashed, with a dash offset that moves. What
// is checked is the draw list (how many capsules come out and where),
// because that is the whole of the widget: there is no state, no input and
// no layout beyond the box.

@(private = "file")
Lines_Msg :: union { int }

// drawn builds one `lines` node in a 400 × 300 view and hands back every
// segment it painted, in order.
@(private = "file")
drawn :: proc(ui: ^Ui(Lines_Msg), runs: []Polyline, thickness: f32 = 1, color := Color{1, 1, 1, 1},
	dashes: []f32 = nil, dash_offset: f32 = 0, outline := Color{}, crisp := true) -> []Draw_Line {
	begin_view(ui)
	column(ui, padding = .none)
	lines(ui, runs, thickness = thickness, color = color, dashes = dashes, dash_offset = dash_offset,
		outline = outline, crisp = crisp, width = 400, height = 300)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 300})
	out := make([dynamic]Draw_Line, context.temp_allocator)
	for _, l in ui.tree.layers do for c in l.cmds {
		if v, ok := c.(Draw_Line); ok do append(&out, v)
	}
	return out[:]
}

// first_whole_dash is where the first dash that is not cut short by the
// start of the path begins — which is how far the pattern has slid.
@(private = "file")
first_whole_dash :: proc(ui: ^Ui(Lines_Msg), pts: [][2]f32, off: f32) -> f32 {
	segs := drawn(ui, {{pts, false}}, dashes = {4, 4}, dash_offset = off)
	for s in segs do if seg_len(s) > 3.9 do return s.a.x
	return -1
}

@(private = "file")
seg_len :: proc(l: Draw_Line) -> f32 {
	return math.sqrt((l.b.x - l.a.x) * (l.b.x - l.a.x) + (l.b.y - l.a.y) * (l.b.y - l.a.y))
}

// A run without a pattern is one capsule a segment, round-ended — which is
// what joins it to the next without any geometry for the join.
@(test)
lines_draws_one_capsule_a_segment :: proc(t: ^testing.T) {
	ui: Ui(Lines_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	pts := [][2]f32{{10, 10}, {110, 10}, {110, 60}}
	segs := drawn(&ui, {{pts[:], false}})
	testing.expect_value(t, len(segs), 2)
	for s in segs do testing.expect(t, !s.flat, "round ends, so the corner joins itself")
	testing.expect_value(t, seg_len(segs[0]), 100)
	testing.expect_value(t, seg_len(segs[1]), 50)
}

// Closing a run adds the segment back to the first point, and no more.
@(test)
lines_closes_a_loop_with_one_more_segment :: proc(t: ^testing.T) {
	ui: Ui(Lines_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	pts := [][2]f32{{10, 10}, {110, 10}, {110, 60}}
	open := len(drawn(&ui, {{pts[:], false}}))
	shut := len(drawn(&ui, {{pts[:], true}}))
	testing.expect_value(t, open, 2)
	testing.expect_value(t, shut, 3)
}

// The dashes are the lengths asked for. A 100 px line with {4, 4} is 4 px
// of line then 4 px of nothing, over and over: twelve full dashes and a
// last one running into the end.
@(test)
lines_dashes_are_the_lengths_asked_for :: proc(t: ^testing.T) {
	ui: Ui(Lines_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	pts := [][2]f32{{10, 10}, {110, 10}}
	segs := drawn(&ui, {{pts[:], false}}, dashes = {4, 4})
	testing.expect(t, len(segs) >= 12, "a hundred pixels of four-on four-off is twelve dashes and a bit")
	for s in segs {
		testing.expect(t, s.flat, "a dash has flat ends: round ones would lengthen it by its own width")
		testing.expectf(t, seg_len(s) <= 4.001, "no dash is longer than the pattern says: %v", seg_len(s))
	}
	// The gaps are the other four: dash n starts eight past dash n - 1.
	testing.expect_value(t, segs[0].a.x - 10, 0)
	testing.expect_value(t, segs[1].a.x - segs[0].a.x, 8)
	testing.expect_value(t, segs[2].a.x - segs[1].a.x, 8)
	testing.expect_value(t, seg_len(segs[0]), 4)
	testing.expect_value(t, seg_len(segs[1]), 4)
}

// An odd pattern runs twice with on and off swapped, as SVG's dasharray
// does, so {5} is five on and five off rather than five on for ever.
@(test)
lines_repeats_an_odd_pattern_with_on_and_off_swapped :: proc(t: ^testing.T) {
	ui: Ui(Lines_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	pts := [][2]f32{{0, 10}, {100, 10}}
	segs := drawn(&ui, {{pts[:], false}}, dashes = {5})
	testing.expect(t, len(segs) >= 9 && len(segs) <= 11, "ten five-pixel dashes across a hundred")
	for s in segs do testing.expectf(t, seg_len(s) <= 5.001, "no dash longer than five: %v", seg_len(s))
	testing.expect_value(t, segs[1].a.x - segs[0].a.x, 10)
}

// The offset slides the pattern forward along the path: the first dash
// starts that much earlier, which is the whole of marching ants.
@(test)
lines_dash_offset_slides_the_pattern_along :: proc(t: ^testing.T) {
	ui: Ui(Lines_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	pts := [][2]f32{{0, 10}, {100, 10}}
	// A whole pattern on is back where it started; a third of one has moved.
	testing.expect_value(t, first_whole_dash(&ui, pts[:], 0), first_whole_dash(&ui, pts[:], 8))
	testing.expect(t, first_whole_dash(&ui, pts[:], 2) != first_whole_dash(&ui, pts[:], 0),
		"two pixels along is not where it was")
}

// Marching ants are black and white alternating: the outline fills the
// gaps the colour leaves rather than running solid underneath, since two
// antialiased one-pixel strokes in the same place make grey.
@(test)
lines_outline_fills_the_gaps_between_the_dashes :: proc(t: ^testing.T) {
	ui: Ui(Lines_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	pts := [][2]f32{{0, 10}, {100, 10}}
	segs := drawn(&ui, {{pts[:], false}}, color = {0, 0, 0, 1}, outline = {1, 1, 1, 1}, dashes = {4, 4})
	white, black: [dynamic]Draw_Line
	defer { delete(white); delete(black) }
	for s in segs {
		testing.expectf(t, seg_len(s) <= 4.001, "nothing runs solid: %v", seg_len(s))
		if s.color == (Color{1, 1, 1, 1}) do append(&white, s)
		if s.color == (Color{0, 0, 0, 1}) do append(&black, s)
	}
	testing.expect(t, len(white) >= 11 && len(black) >= 11, "about as many of each")
	testing.expect(t, segs[0].color == (Color{1, 1, 1, 1}), "the outline is laid first")
	// The white ones sit in the black ones' gaps: each starts one dash
	// length after the black one before it, and they do not overlap.
	testing.expect_value(t, black[0].a.x, 0)
	testing.expect_value(t, white[0].a.x, 4)
	testing.expect_value(t, black[1].a.x, 8)
	testing.expect_value(t, white[1].a.x - black[1].a.x, 4)
}

// Without dashes there is nothing to alternate with, so the outline is a
// halo: the same line, wider, underneath — which is what makes a white
// guide readable on a white picture.
@(test)
lines_outline_is_a_halo_when_there_are_no_dashes :: proc(t: ^testing.T) {
	ui: Ui(Lines_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	pts := [][2]f32{{0, 10}, {100, 10}}
	segs := drawn(&ui, {{pts[:], false}}, thickness = 2, color = {0, 0, 0, 1}, outline = {1, 1, 1, 1})
	testing.expect_value(t, len(segs), 2)
	testing.expect(t, segs[0].color == (Color{1, 1, 1, 1}), "the halo is laid first")
	testing.expect_value(t, segs[0].width, 4) // two wider than the line it is under
	testing.expect_value(t, segs[1].width, 2)
	testing.expect_value(t, seg_len(segs[0]), 100) // both run the whole way
	testing.expect_value(t, seg_len(segs[1]), 100)
}

// Several runs share the node's style and its dash phase, so a selection
// with a hole marches round both loops together.
@(test)
lines_draws_every_run_it_is_given :: proc(t: ^testing.T) {
	ui: Ui(Lines_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	outer := [][2]f32{{0, 0}, {100, 0}, {100, 100}, {0, 100}}
	hole := [][2]f32{{40, 40}, {60, 40}, {60, 60}, {40, 60}}
	segs := drawn(&ui, {{outer[:], true}, {hole[:], true}})
	testing.expect_value(t, len(segs), 8) // four sides each, both closed
}

// A horizontal or vertical line is asked to land on whole device pixels;
// one at an angle is not, because it has no grid to land on.
@(test)
lines_asks_for_crispness_only_where_there_is_a_grid :: proc(t: ^testing.T) {
	ui: Ui(Lines_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	pts := [][2]f32{{10, 10}, {110, 10}}
	on := drawn(&ui, {{pts[:], false}})
	testing.expect(t, on[0].snap, "crisp by default")
	off := drawn(&ui, {{pts[:], false}}, crisp = false)
	testing.expect(t, !off[0].snap, "…and not when it is turned off")
}

// snap_line is what crispness means in the end: a 1 px line's centre put
// where its edges land on whole pixels, and left alone once it is there.
@(test)
snapping_a_line_lands_it_on_whole_pixels :: proc(t: ^testing.T) {
	testing.expect_value(t, snap_line(10.3, 1), 10.5)
	testing.expect_value(t, snap_line(10.5, 1), 10.5) // already there: unmoved
	testing.expect_value(t, snap_line(10.9, 1), 10.5) // 10.4 to 11.4 is more of 10..11 than of 11..12
	testing.expect_value(t, snap_line(11.1, 1), 11.5) // …and past the midpoint it goes to the next
	testing.expect_value(t, snap_line(10.3, 2), 10) // an even width centres on the edge
	testing.expect_value(t, snap_line(10.0, 2), 10)
}

// A pattern of nothing but zeroes has no length to walk, and must answer at
// once rather than spin: a `dashes = {0, 0}` from an app is a mistake, not a
// hang.
@(test)
lines_survives_a_pattern_of_zeroes :: proc(t: ^testing.T) {
	ui: Ui(Lines_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	pts := [][2]f32{{0, 10}, {100, 10}}
	segs := drawn(&ui, {{pts[:], false}}, dashes = {0, 0})
	testing.expect_value(t, len(segs), 0)
}

}
