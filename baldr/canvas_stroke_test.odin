package baldr

@(require) import "core:testing"
@(require) import "core:math"

// Runs with the rest: `./build.sh test`.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// These pin what a stroke *means*, so the GPU path is checked against
// something already agreed rather than deciding the semantics itself.

// The width really does vary along a stroke: a ribbon that starts fat and
// ends thin is thick at one end and thin at the other, and the edge between
// them slopes rather than stepping.
@(test)
a_strokes_width_follows_its_points :: proc(t: ^testing.T) {
	wide_then_narrow := []Stroke_Point{{{10, 20}, 16}, {{50, 20}, 4}}

	// On the centre line, covered from end to end.
	testing.expect_value(t, stroke_coverage(wide_then_narrow, {12, 20}, 1), f32(1))
	testing.expect_value(t, stroke_coverage(wide_then_narrow, {48, 20}, 1), f32(1))

	// Six texels off the line: inside at the fat end, outside at the thin.
	testing.expect_value(t, stroke_coverage(wide_then_narrow, {11, 26}, 1), f32(1))
	testing.expect_value(t, stroke_coverage(wide_then_narrow, {49, 26}, 1), f32(0))

	// And the edge in between is where the taper says, not at either width:
	// half way along, the half-width is 5, so 4 off the line is in and 7 out.
	testing.expect_value(t, stroke_coverage(wide_then_narrow, {30, 24}, 1), f32(1))
	testing.expect_value(t, stroke_coverage(wide_then_narrow, {30, 27}, 1), f32(0))
}

// The ends are round, not square: a point beyond the last sample is still
// covered if it is within the half-width of it.
@(test)
a_stroke_has_round_caps :: proc(t: ^testing.T) {
	line := []Stroke_Point{{{20, 20}, 10}, {{40, 20}, 10}}
	testing.expect_value(t, stroke_coverage(line, {16, 20}, 1), f32(1)) // 4 beyond the end, half-width 5
	testing.expect_value(t, stroke_coverage(line, {44, 20}, 1), f32(1))
	testing.expect_value(t, stroke_coverage(line, {27, 20}, 1), f32(1)) // and well past it, nothing
	testing.expect(t, stroke_coverage(line, {14, 20}, 1) == 0, "a cap is a half circle, not a square")

	// Round, so the corner of the square that would enclose it is outside.
	testing.expect_value(t, stroke_coverage(line, {16, 24}, 1), f32(0))
}

// The union rule: a stroke that crosses itself is exactly as covered at the
// crossing as anywhere else, never more, so a translucent highlighter is one
// flat colour instead of darkening where it doubles back. A build-up of
// coverage would get this wrong.
@(test)
a_stroke_that_crosses_itself_is_no_more_covered_there :: proc(t: ^testing.T) {
	// An X: down-right, then up-right, crossing at {30, 30}.
	cross := []Stroke_Point{{{20, 20}, 8}, {{40, 40}, 8}, {{40, 20}, 8}, {{20, 40}, 8}}
	at_crossing := stroke_coverage(cross, {30, 30}, 1)
	elsewhere := stroke_coverage(cross, {24, 24}, 1)
	testing.expect_value(t, at_crossing, f32(1))
	testing.expect_value(t, elsewhere, f32(1))
	testing.expect_value(t, at_crossing, elsewhere)

	// The same where the coverage is partial: an edge that two segments share
	// is as covered as the one that covers it most, not the sum. Two segments
	// exactly on top of each other must read the same as one.
	once := []Stroke_Point{{{10, 10}, 6}, {{30, 10}, 6}}
	twice := []Stroke_Point{{{10, 10}, 6}, {{30, 10}, 6}, {{10, 10}, 6}, {{30, 10}, 6}}
	for dy in ([]f32{2.6, 2.8, 3.0, 3.2, 3.4}) { // across the soft edge
		a := stroke_coverage(once, {20, 10 + dy}, 1)
		b := stroke_coverage(twice, {20, 10 + dy}, 1)
		testing.expect_value(t, a, b)
	}
}

// A join between two segments is filled, with no notch on the outside of
// the turn and no seam on the inside.
@(test)
a_join_is_filled :: proc(t: ^testing.T) {
	corner := []Stroke_Point{{{20, 20}, 10}, {{40, 20}, 10}, {{40, 40}, 10}}
	testing.expect_value(t, stroke_coverage(corner, {40, 20}, 1), f32(1)) // the corner itself
	testing.expect_value(t, stroke_coverage(corner, {43, 17}, 1), f32(1)) // outside of the turn, within the round join
	testing.expect_value(t, stroke_coverage(corner, {37, 23}, 1), f32(1)) // inside of the turn
}

// One sample is a dot. A pen tapped once draws something.
@(test)
a_stroke_of_one_point_is_a_dot :: proc(t: ^testing.T) {
	dot := []Stroke_Point{{{30, 30}, 12}}
	testing.expect_value(t, stroke_coverage(dot, {30, 30}, 1), f32(1))
	testing.expect_value(t, stroke_coverage(dot, {35, 30}, 1), f32(1)) // half-width 6
	testing.expect_value(t, stroke_coverage(dot, {38, 30}, 1), f32(0))
	testing.expect_value(t, stroke_coverage([]Stroke_Point{}, {30, 30}, 1), f32(0))
}

// The edge is soft over about one texel — antialiased, not a hard step —
// and runs monotonically from covered to not.
@(test)
a_strokes_edge_is_soft_over_a_texel :: proc(t: ^testing.T) {
	line := []Stroke_Point{{{10, 30}, 10}, {{50, 30}, 10}}
	last: f32 = 2
	partial := 0
	for i in 0 ..< 20 { // walk out across the edge, half a texel at a time
		y := 30 + 4 + f32(i) * 0.25
		c := stroke_coverage(line, {30, y}, 1)
		testing.expect(t, c <= last + 1e-6, "coverage never rises as the texel moves away")
		if c > 0 && c < 1 do partial += 1
		last = c
	}
	testing.expect(t, partial >= 2, "there is a soft edge, not a step")
}

// The scale multiplies the width: it is how the transform's zoom reaches
// the stroke, and how "hold the width on screen" is expressed.
@(test)
the_scale_multiplies_a_strokes_width :: proc(t: ^testing.T) {
	line := []Stroke_Point{{{20, 20}, 4}, {{40, 20}, 4}}
	testing.expect_value(t, stroke_coverage(line, {30, 23}, 1), f32(0)) // half-width 2
	testing.expect_value(t, stroke_coverage(line, {30, 23}, 2), f32(1)) // …4 at twice the scale
}

// The rectangle a stroke can touch covers its soft edge and is clipped to
// the canvas, so nothing is drawn outside and nothing is clipped short.
@(test)
a_strokes_bounds_hold_all_of_it :: proc(t: ^testing.T) {
	line := []Stroke_Point{{{20, 20}, 10}, {{40, 30}, 10}}
	x, y, w, h := stroke_bounds(line, 1, {100, 100})
	testing.expect(t, x <= 14 && y <= 14, "the half-width and the soft texel are inside the box")
	testing.expect(t, x + w >= 46 && y + h >= 36, "…at the far end too")
	// Every texel with coverage is inside the box.
	for ty in 0 ..< 100 do for tx in 0 ..< 100 {
		if stroke_coverage(line, {f32(tx) + 0.5, f32(ty) + 0.5}, 1) > 0 {
			testing.expect(t, tx >= x && tx < x + w && ty >= y && ty < y + h, "a covered texel outside the bounds")
		}
	}

	// Off the canvas entirely: an empty rectangle rather than a negative one.
	ox, oy, ow, oh := stroke_bounds([]Stroke_Point{{{-90, -90}, 4}}, 1, {100, 100})
	testing.expect(t, ow == 0 && oh == 0, "nothing to draw")
	testing.expect(t, ox >= 0 && oy >= 0, "and no negative origin")
}

}
