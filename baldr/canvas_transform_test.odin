package baldr

@(require) import "baldr:gpu"
@(require) import "core:math"
@(require) import "core:testing"

when ODIN_TEST || #config(BALDR_TESTS, false) {

// A canvas drawn into another through a transform. These check the CPU
// reference, which is the shader's spec: what it must agree with.

@(private = "file")
tx_texel :: proc(g: Gpu, c: Canvas, x, y: int) -> [4]f32 {
	e := canvas_entry(g, c)
	b := gpu.canvas_bpp(e.format)
	return canvas_decode(e.format, e.pixels[(y * e.size.x + x) * b:][:b])
}

@(private = "file")
tx_identity :: matrix[3, 3]f32{1, 0, 0, 0, 1, 0, 0, 0, 1}

@(private = "file")
tx_move :: proc(dx, dy: f32) -> matrix[3, 3]f32 { return {1, 0, dx, 0, 1, dy, 0, 0, 1} }

@(private = "file")
tx_scale :: proc(sx, sy: f32) -> matrix[3, 3]f32 { return {sx, 0, 0, 0, sy, 0, 0, 0, 1} }

@(test)
canvas_transform_moves_a_whole_number_of_texels_exactly :: proc(t: ^testing.T) {
	// The case every other op can already do: no resampling should happen,
	// and the texels must land unchanged, or nothing else can be trusted.
	g := gpu_reference()
	defer gpu_close(&g)
	src, _ := canvas_create(g, {8, 8})
	dst, _ := canvas_create(g, {8, 8})
	canvas_fill(g, src, 2, 2, 2, 2, {1, 0.5, 0.25, 1})

	testing.expect(t, canvas_transform(g, src, 0, 0, 8, 8, dst, tx_move(3, 1), .Bilinear), "drawn")
	was := tx_texel(g, src, 2, 2) // what RGBA8 actually stored, not the float asked for
	testing.expect_value(t, tx_texel(g, dst, 5, 3), was) // 2,2 moved by 3,1
	testing.expect_value(t, tx_texel(g, dst, 6, 4), was)
	testing.expect_value(t, tx_texel(g, dst, 4, 3), [4]f32{})               // outside the moved square
}

@(test)
canvas_transform_scales_up_without_inventing_colour :: proc(t: ^testing.T) {
	// A flat square scaled ×2 stays that colour inside it: interpolation
	// between equal texels must not drift.
	g := gpu_reference()
	defer gpu_close(&g)
	src, _ := canvas_create(g, {4, 4})
	dst, _ := canvas_create(g, {16, 16})
	canvas_fill(g, src, 0, 0, 4, 4, {0.25, 0.5, 0.75, 1})

	testing.expect(t, canvas_transform(g, src, 0, 0, 4, 4, dst, tx_scale(2, 2), .Bilinear), "drawn")
	mid := tx_texel(g, dst, 4, 4)
	testing.expect(t, abs(mid.r - 0.25) < 0.02 && abs(mid.g - 0.5) < 0.02 && abs(mid.b - 0.75) < 0.02, "the colour inside is its own")
	testing.expect(t, mid.a > 0.98, "and it is opaque inside")
	testing.expect_value(t, tx_texel(g, dst, 12, 12), [4]f32{}) // past the scaled square: nothing
}

@(test)
canvas_transform_downscales_by_averaging :: proc(t: ^testing.T) {
	// The sparkle test: a checkerboard scaled to a quarter must come out
	// flat grey, not a sample of whichever texel the centre happened to hit.
	g := gpu_reference()
	defer gpu_close(&g)
	src, _ := canvas_create(g, {16, 16}, .RGBA32F, .Linear)
	dst, _ := canvas_create(g, {8, 8}, .RGBA32F, .Linear)
	for y in 0 ..< 16 do for x in 0 ..< 16 {
		v: f32 = 1 if (x + y) % 2 == 0 else 0
		canvas_fill(g, src, x, y, 1, 1, {v, v, v, 1})
	}
	testing.expect(t, canvas_transform(g, src, 0, 0, 16, 16, dst, tx_scale(0.25, 0.25), .Bilinear), "drawn")
	c := tx_texel(g, dst, 1, 1)
	testing.expect(t, abs(c.r - 0.5) < 0.12, "a quarter of a checkerboard is grey, not a sampled texel")

	// nearest is allowed to alias: that is what it is for
	near, _ := canvas_create(g, {8, 8}, .RGBA32F, .Linear)
	canvas_transform(g, src, 0, 0, 16, 16, near, tx_scale(0.25, 0.25), .Nearest)
	n := tx_texel(g, near, 1, 1)
	testing.expect(t, n.r == 0 || n.r == 1, "nearest takes one texel, whole")
}

@(test)
canvas_transform_leaves_a_clean_edge :: proc(t: ^testing.T) {
	// A rotated layer must fade at its edge rather than smear its border
	// texel across the destination, and must not touch what it does not
	// cover.
	g := gpu_reference()
	defer gpu_close(&g)
	src, _ := canvas_create(g, {8, 8}, .RGBA32F, .Linear)
	dst, _ := canvas_create(g, {24, 24}, .RGBA32F, .Linear)
	canvas_fill(g, src, 0, 0, 8, 8, {1, 1, 1, 1})
	canvas_fill(g, dst, 0, 0, 24, 24, {0, 0, 0, 1})

	a := f32(math.PI / 6)
	rot := matrix[3, 3]f32{math.cos(a), -math.sin(a), 8, math.sin(a), math.cos(a), 4, 0, 0, 1}
	testing.expect(t, canvas_transform(g, src, 0, 0, 8, 8, dst, rot, .Bilinear), "drawn")
	testing.expect_value(t, tx_texel(g, dst, 23, 23), [4]f32{0, 0, 0, 1}) // a far corner: untouched
	inside := tx_texel(g, dst, 11, 8)
	testing.expect(t, inside.r > 0.9, "inside the rotated square it is the source's white")

	// somewhere along the edge the coverage is partial: neither 0 nor 1
	partial := false
	for y in 0 ..< 24 do for x in 0 ..< 24 {
		c := tx_texel(g, dst, x, y)
		if c.r > 0.15 && c.r < 0.85 do partial = true
	}
	testing.expect(t, partial, "the edge is antialiased, not a hard cut")
}

@(test)
canvas_transform_refuses_what_it_cannot_do :: proc(t: ^testing.T) {
	g := gpu_reference()
	defer gpu_close(&g)
	src, _ := canvas_create(g, {8, 8})
	dst, _ := canvas_create(g, {8, 8})
	flat := matrix[3, 3]f32{0, 0, 0, 0, 0, 0, 0, 0, 1} // everything lands on one point
	testing.expect(t, !canvas_transform(g, src, 0, 0, 8, 8, dst, flat), "a matrix with no inverse")
	testing.expect(t, !canvas_transform(g, src, 0, 0, 9, 8, dst, tx_identity), "a source rectangle off the canvas")
	testing.expect(t, !canvas_transform(g, src, 0, 0, 8, 8, src, tx_identity), "a canvas onto itself")
	testing.expect(t, canvas_transform(g, src, 0, 0, 8, 8, dst, tx_move(100, 100)), "off the destination is not an error")
}

@(test)
canvas_transform_blends_as_a_blend_does :: proc(t: ^testing.T) {
	// With .Normal and opacity 1 it is a transformed copy; with a mode and
	// an opacity it must agree with canvas_blend, which shares the maths.
	g := gpu_reference()
	defer gpu_close(&g)
	src, _ := canvas_create(g, {4, 4}, .RGBA32F, .Linear)
	a, _ := canvas_create(g, {4, 4}, .RGBA32F, .Linear)
	b, _ := canvas_create(g, {4, 4}, .RGBA32F, .Linear)
	canvas_fill(g, src, 0, 0, 4, 4, {0.8, 0.4, 0.2, 1})
	canvas_fill(g, a, 0, 0, 4, 4, {0.2, 0.6, 0.4, 1})
	canvas_fill(g, b, 0, 0, 4, 4, {0.2, 0.6, 0.4, 1})

	canvas_blend(g, src, 0, 0, 4, 4, a, {0, 0}, .Multiply, 0.5)
	canvas_transform(g, src, 0, 0, 4, 4, b, tx_identity, .Nearest, .Multiply, 0.5)
	ta, tb := tx_texel(g, a, 1, 1), tx_texel(g, b, 1, 1)
	for k in 0 ..< 4 do testing.expectf(t, abs(ta[k] - tb[k]) < 0.001,
		"channel %d: transform %v, blend %v — they are the same maths", k, tb[k], ta[k])
}


// A texel beside a clear one must keep its own colour at a lower alpha. The
// gather averages premultiplied values, so the clear neighbour — which is
// black with zero alpha in store — pulls the alpha down and nothing else.
// Straight averaging would drag the colour towards black and give every
// scaled or rotated transparent layer a dark fringe.
@(test)
canvas_transform_keeps_colour_beside_a_clear_texel :: proc(t: ^testing.T) {
	g := gpu_reference()
	defer gpu_close(&g)
	src, _ := canvas_create(g, {2, 1})
	dst, _ := canvas_create(g, {4, 2})
	canvas_fill(g, src, 0, 0, 1, 1, {1, 0, 0, 1}) // red, and the texel beside it left clear

	testing.expect(t, canvas_transform(g, src, 0, 0, 2, 1, dst, tx_scale(2, 2), .Bilinear), "drawn")
	// The texel straddling the join: red at part alpha, not a dark red.
	mid := tx_texel(g, dst, 1, 0)
	testing.expect(t, mid.a > 0.2 && mid.a < 0.9, "part covered")
	testing.expect(t, mid.r > 0.9, "still red")
	testing.expect(t, mid.g < 0.05 && mid.b < 0.05, "and nothing else")
}

// The same for a whole layer: a solid square on a clear canvas, shrunk.
// Its edge texels must be the square's colour at a lower alpha.
@(test)
canvas_transform_shrinks_without_a_dark_fringe :: proc(t: ^testing.T) {
	g := gpu_reference()
	defer gpu_close(&g)
	src, _ := canvas_create(g, {8, 8})
	dst, _ := canvas_create(g, {8, 8})
	canvas_fill(g, src, 0, 0, 8, 8, {0, 0, 1, 1}) // blue, filling its 8 x 8

	testing.expect(t, canvas_transform(g, src, 0, 0, 8, 8, dst, tx_scale(3.0 / 8, 3.0 / 8), .Bilinear), "drawn")
	for y in 0 ..< 3 do for x in 0 ..< 3 {
		c := tx_texel(g, dst, x, y)
		if c.a <= 0.01 do continue
		testing.expectf(t, c.b > 0.9, "texel %d,%d is blue: %v", x, y, c)
		testing.expectf(t, c.r < 0.05 && c.g < 0.05, "texel %d,%d has nothing else in it: %v", x, y, c)
	}
}

// An opaque picture comes through as straight averaging would give it: with
// every alpha 1, premultiplied and straight are the same arithmetic. Only the
// inside is checked — the border fades on purpose, because the kernel there
// reaches past the source rectangle, which is what gives a rotated layer a
// clean edge instead of a smear of its last row.
@(test)
canvas_transform_leaves_an_opaque_picture_alone :: proc(t: ^testing.T) {
	g := gpu_reference()
	defer gpu_close(&g)
	src, _ := canvas_create(g, {16, 16})
	dst, _ := canvas_create(g, {32, 32})
	for y in 0 ..< 16 do for x in 0 ..< 16 do canvas_fill(g, src, x, y, 1, 1, {f32(x) / 15, f32(y) / 15, 0.5, 1})

	testing.expect(t, canvas_transform(g, src, 0, 0, 16, 16, dst, tx_scale(2, 2), .Bilinear), "drawn")
	for y in 3 ..< 29 do for x in 3 ..< 29 {
		c := tx_texel(g, dst, x, y)
		testing.expectf(t, c.a > 0.99, "texel %d,%d stays opaque: %v", x, y, c)
		testing.expectf(t, abs(c.b - 0.5019608) < 0.01, "…and keeps its blue: %v", c)
	}
	// Along a row the red channel only rises: the colours are the source's
	// own, interpolated, not dragged anywhere by the alpha weighting.
	last := f32(-1)
	for x in 3 ..< 29 {
		c := tx_texel(g, dst, x, 16)
		testing.expectf(t, c.r >= last - 0.001, "red rises across the row at %d: %v after %v", x, c.r, last)
		last = c.r
	}
}

} // when ODIN_TEST
