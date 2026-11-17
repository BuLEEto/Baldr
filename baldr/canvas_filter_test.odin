package baldr

@(require) import "core:testing"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Filters and adjustments, checked on the CPU reference.


@(private = "file")
px :: proc(g: Gpu, c: Canvas, x, y: int) -> [4]u8 {
	e := canvas_entry(g, c)
	p := e.pixels[(y * e.size.x + x) * 4:][:4]
	return {p[0], p[1], p[2], p[3]}
}

@(private = "file")
filled :: proc(g: Gpu, size: [2]int, v: [4]f32, format := Canvas_Format.RGBA8, space := Color_Space.sRGB) -> Canvas {
	c, _ := canvas_create(g, size, format, space)
	canvas_fill(g, c, 0, 0, size.x, size.y, v)
	return c
}

// Matrices: Invert flips the colour and keeps alpha; a saturation of 0
// greys by luminance; a filter may write back onto its own canvas.
@(test)
colour_matrices_invert_and_grey :: proc(t: ^testing.T) {
	g := gpu_reference()
	defer gpu_close(&g)
	c := filled(g, {4, 4}, {0.2, 0.6, 1, 0.5})
	testing.expect(t, canvas_matrix(g, c, 0, 0, 4, 4, c, {0, 0}, COLOR_MATRIX_INVERT), "in place")
	testing.expect_value(t, px(g, c, 2, 2), [4]u8{204, 102, 0, 128})
	d := filled(g, {4, 4}, {1, 0, 0, 1})
	canvas_matrix(g, d, 0, 0, 4, 4, d, {0, 0}, color_matrix_saturate(0))
	p := px(g, d, 0, 0)
	testing.expect(t, p.r == p.g && p.g == p.b && p.r == 54, "red's luminance, grey: 0.2126") // 0.2126 × 255
}

// Curves: each channel through its own curve, interpolated between
// points; the same table posterizes when stepped.
@(test)
curves_map_each_channel :: proc(t: ^testing.T) {
	g := gpu_reference()
	defer gpu_close(&g)
	curve, ok := canvas_curve_make(g, {{0, 1, 0, 0}, {0.25, 1, 0.5, 0.5}, {1, 1, 1, 1}}) // red bends down, green is always 1
	testing.expect(t, ok, "made")
	c := filled(g, {2, 2}, {0.5, 0.2, 0.75, 1})
	testing.expect(t, canvas_curves(g, c, 0, 0, 2, 2, c, {0, 0}, curve), "curved")
	p := px(g, c, 0, 0)
	testing.expect(t, abs(int(p.r) - 64) <= 1 && p.g == 255 && abs(int(p.b) - 191) <= 1 && p.a == 255, "0.5 → 0.25, green 1, 0.75 → 0.75")
	_, bad := canvas_curve_make(g, {{0, 0, 0, 0}})
	testing.expect(t, !bad, "a curve needs two points")
}

// Converting between spaces: sRGB's 0.5 is 0.214 of light; P3's white is
// sRGB's white; P3's pure red is outside sRGB and clips to sRGB's red.
@(test)
conversion_between_spaces :: proc(t: ^testing.T) {
	g := gpu_reference()
	defer gpu_close(&g)
	s := filled(g, {2, 2}, {0.5, 0.5, 0.5, 1})
	l, _ := canvas_create(g, {2, 2}, .RGBA32F, .Linear)
	canvas_convert(g, s, 0, 0, 2, 2, l, {0, 0})
	v := canvas_decode(.RGBA32F, canvas_entry(g, l).pixels[:16])
	testing.expect(t, abs(v.r - 0.2158605) < 1e-4 && v.a == 1, "sRGB 128 is 0.216 of light") // 128/255 decoded
	p3 := filled(g, {2, 2}, {1, 1, 1, 1}, space = .Display_P3)
	canvas_fill(g, p3, 1, 0, 1, 2, {1, 0, 0, 1})
	out := filled(g, {2, 2}, {0, 0, 0, 0})
	canvas_convert(g, p3, 0, 0, 2, 2, out, {0, 0})
	testing.expect_value(t, px(g, out, 0, 0), [4]u8{255, 255, 255, 255})
	testing.expect_value(t, px(g, out, 1, 0), [4]u8{255, 0, 0, 255})
}

// A 3D LUT: the identity changes nothing; one that swaps red and blue
// swaps them, between its points too.
@(test)
a_3d_lut_maps_colours :: proc(t: ^testing.T) {
	g := gpu_reference()
	defer gpu_close(&g)
	N :: 3
	ident, swap: [N * N * N][3]f32
	for b in 0 ..< N do for gg in 0 ..< N do for r in 0 ..< N {
		v := [3]f32{f32(r), f32(gg), f32(b)} / (N - 1)
		ident[(b * N + gg) * N + r] = v
		swap[(b * N + gg) * N + r] = {v.b, v.g, v.r}
	}
	li, _ := canvas_lut_make(g, N, ident[:])
	ls, _ := canvas_lut_make(g, N, swap[:])
	c := filled(g, {2, 2}, {0.8, 0.3, 0.1, 1})
	canvas_lut(g, c, 0, 0, 2, 2, c, {0, 0}, li)
	testing.expect_value(t, px(g, c, 0, 0), [4]u8{204, 77, 26, 255})
	canvas_lut(g, c, 0, 0, 2, 2, c, {0, 0}, ls)
	testing.expect_value(t, px(g, c, 0, 0), [4]u8{26, 77, 204, 255})
}

// A blur keeps a flat colour flat (edges too: a texel past the canvas is
// its edge's), spreads a point while keeping its total, and blurs colour
// premultiplied: a red square's soft edge stays red as it fades.
@(test)
blur_spreads_and_keeps_colour :: proc(t: ^testing.T) {
	g := gpu_reference()
	defer gpu_close(&g)
	flat := filled(g, {16, 16}, {0.3, 0.6, 0.9, 1})
	canvas_blur(g, flat, 0, 0, 16, 16, flat, {0, 0}, 2)
	testing.expect_value(t, px(g, flat, 0, 0), [4]u8{77, 153, 230, 255})

	dot, _ := canvas_create(g, {33, 33}, .RGBA32F, .Linear)
	canvas_fill(g, dot, 16, 16, 1, 1, {1, 1, 1, 1})
	canvas_blur(g, dot, 0, 0, 33, 33, dot, {0, 0}, 2)
	e := canvas_entry(g, dot)
	total: f32
	for i in 0 ..< 33 * 33 do total += canvas_decode(.RGBA32F, e.pixels[i * 16:][:16]).a
	testing.expectf(t, abs(total - 1) < 1e-3, "its total kept: %v", total)

	red, _ := canvas_create(g, {20, 20})
	canvas_fill(g, red, 0, 0, 20, 20, {1, 1, 1, 0}) // transparent white around it: blurred straight, it would bleed white in
	canvas_fill(g, red, 5, 5, 10, 10, {1, 0, 0, 1})
	canvas_blur(g, red, 0, 0, 20, 20, red, {0, 0}, 1.5)
	edge := px(g, red, 4, 10)
	testing.expect(t, edge.a > 20 && edge.a < 200 && edge.r == 255 && edge.g == 0, "fading, still red")
}

// Sharpening leaves flat areas alone, pushes an edge apart, and a
// threshold above the difference leaves it as it was.
@(test)
sharpening_pushes_edges_apart :: proc(t: ^testing.T) {
	g := gpu_reference()
	defer gpu_close(&g)
	c := filled(g, {20, 20}, {0.4, 0.4, 0.4, 1})
	canvas_fill(g, c, 10, 0, 10, 20, {0.6, 0.6, 0.6, 1})
	d, _ := canvas_create(g, {20, 20})
	canvas_sharpen(g, c, 0, 0, 20, 20, d, {0, 0}, 1, 1.5)
	testing.expect_value(t, px(g, d, 2, 5).r, px(g, c, 2, 5).r) // flat: unchanged
	testing.expect(t, px(g, d, 9, 5).r < px(g, c, 9, 5).r && px(g, d, 10, 5).r > px(g, c, 10, 5).r, "the edge's sides pushed apart")
	canvas_sharpen(g, c, 0, 0, 20, 20, d, {0, 0}, 1, 1.5, threshold = 0.5)
	testing.expect_value(t, px(g, d, 9, 5).r, px(g, c, 9, 5).r)
}

} // when ODIN_TEST