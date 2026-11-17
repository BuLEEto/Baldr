package baldr

@(require) import "core:testing"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Compositing canvases, checked on the CPU reference against values worked
// by hand from the formulas.


@(private = "file")
px8 :: proc(g: Gpu, c: Canvas, x, y: int) -> [4]u8 {
	e := canvas_entry(g, c)
	p := e.pixels[(y * e.size.x + x) * 4:][:4]
	return {p[0], p[1], p[2], p[3]}
}

@(private = "file")
pair :: proc(g: Gpu, back, front: [4]f32) -> (dst, src: Canvas) {
	dst, _ = canvas_create(g, {4, 4})
	src, _ = canvas_create(g, {4, 4})
	canvas_fill(g, dst, 0, 0, 4, 4, back)
	canvas_fill(g, src, 0, 0, 4, 4, front)
	return
}

// The separable and non-separable modes give what their formulas give:
// multiply darkens, screen lightens, overlay keys off the backdrop, hard
// light off the source, difference, divide, and luminosity keeps the
// backdrop's colour at the source's lightness.
@(test)
blend_modes_give_what_their_formulas_give :: proc(t: ^testing.T) {
	g := gpu_reference()
	defer gpu_close(&g)
	Case :: struct { mode: Blend_Mode, back, front: [4]f32, want: [4]u8 }
	cases := []Case{
		{.Normal,       {0.2, 0.4, 0.6, 1}, {0.8, 0.1, 0.3, 1}, {204, 26, 77, 255}},
		{.Multiply,     {0.5, 0.5, 1, 1},   {0.5, 1, 0.5, 1},   {64, 128, 128, 255}},   // 0.25 → 63.75
		{.Screen,       {0.5, 0, 1, 1},     {0.5, 0.5, 0.5, 1}, {192, 128, 255, 255}},  // 128 is 0.502 stored: 0.752, 0.502, 1
		{.Overlay,      {0.25, 0.75, 0.5, 1}, {0.5, 0.5, 1, 1}, {64, 191, 255, 255}},   // 2bs; 1 - 2(1-b)(1-s)
		{.Hard_Light,   {0.25, 0.75, 0.5, 1}, {0.5, 0.5, 0.25, 1}, {65, 191, 64, 255}}, // keyed off the source (0.502: the screen half)
		{.Difference,   {0.8, 0.2, 0.5, 1}, {0.3, 0.7, 0.5, 1}, {127, 128, 0, 255}},   // 204 - 77, 179 - 51
		{.Linear_Burn,  {0.8, 0.3, 1, 1},   {0.5, 0.5, 1, 1},   {77, 0, 255, 255}},     // b + s - 1, floored at 0
		{.Linear_Dodge, {0.8, 0.3, 0, 1},   {0.5, 0.5, 0, 1},   {255, 205, 0, 255}},    // capped at 1; 77 + 128
		{.Divide,       {0.25, 0.5, 0.5, 1}, {1, 0.25, 0, 1},   {64, 255, 255, 255}},   // by 0: 1 where b > 0
		{.Hard_Mix,     {0.6, 0.4, 0.5, 1}, {0.5, 0.5, 0.5, 1}, {255, 0, 255, 255}},    // b + s ≥ 1
		{.Color_Dodge,  {0.5, 0, 0.5, 1},   {0.5, 0.5, 1, 1},   {255, 0, 255, 255}},    // b / (1 - s)
		{.Color_Burn,   {0.5, 1, 0.5, 1},   {0.5, 0, 0, 1},     {2, 255, 0, 255}},      // 1 - (1 - b) / s
	}
	for c in cases {
		dst, src := pair(g, c.back, c.front)
		testing.expect(t, canvas_blend(g, src, 0, 0, 4, 4, dst, {0, 0}, c.mode), "blended")
		testing.expectf(t, px8(g, dst, 1, 1) == c.want, "%v: %v, want %v", c.mode, px8(g, dst, 1, 1), c.want)
	}
	grey, red := pair(g, {0.5, 0.5, 0.5, 1}, {0.8, 0, 0, 1})
	canvas_blend(g, red, 0, 0, 4, 4, grey, {0, 0}, .Luminosity) // the grey's colour (none) at red's lightness (0.24)
	testing.expect_value(t, px8(g, grey, 0, 0), [4]u8{61, 61, 61, 255})
	grey2, red2 := pair(g, {0.5, 0.5, 0.5, 1}, {1, 0, 0, 1})
	canvas_blend(g, red2, 0, 0, 4, 4, grey2, {0, 0}, .Color) // red's colour at the grey's lightness
	p := px8(g, grey2, 0, 0)
	testing.expect(t, p.r > p.g && p.g == p.b && abs(0.3 * f32(p.r) + 0.7 * f32(p.g) - 127.5) < 2, "red, as light as the grey")
}

// Alpha composites as a layer does: a half-transparent source lays half of
// itself over an opaque backdrop; over nothing it keeps its own colour and
// alpha, whatever the mode; opacity and the mask scale the source's alpha.
@(test)
blending_composites_by_alpha_opacity_and_mask :: proc(t: ^testing.T) {
	g := gpu_reference()
	defer gpu_close(&g)
	blue, red := pair(g, {0, 0, 1, 1}, {1, 0, 0, 0.5})
	canvas_blend(g, red, 0, 0, 4, 4, blue, {0, 0})
	testing.expect_value(t, px8(g, blue, 0, 0), [4]u8{128, 0, 127, 255}) // alpha 128 is 0.502 stored

	empty, green := pair(g, {0, 0, 0, 0}, {0, 1, 0, 0.5})
	canvas_blend(g, green, 0, 0, 4, 4, empty, {0, 0}, .Multiply) // nothing under it: the source as it is
	testing.expect_value(t, px8(g, empty, 0, 0), [4]u8{0, 255, 0, 128})

	white, black := pair(g, {1, 1, 1, 1}, {0, 0, 0, 1})
	canvas_blend(g, black, 0, 0, 4, 4, white, {0, 0}, opacity = 0.25)
	testing.expect_value(t, px8(g, white, 0, 0), [4]u8{191, 191, 191, 255})

	under, over := pair(g, {1, 1, 1, 1}, {0, 0, 0, 1})
	mask, _ := canvas_create(g, {4, 4})
	canvas_fill(g, mask, 0, 0, 2, 4, {1, 1, 1, 1}) // the left half shows, the right does not
	canvas_blend(g, over, 0, 0, 4, 4, under, {0, 0}, mask = mask)
	testing.expect_value(t, px8(g, under, 0, 0), [4]u8{0, 0, 0, 255})
	testing.expect_value(t, px8(g, under, 3, 0), [4]u8{255, 255, 255, 255})

	small, _ := canvas_create(g, {2, 2})
	testing.expect(t, !canvas_blend(g, over, 0, 0, 4, 4, under, {0, 0}, mask = small), "a mask short of the source: refused")
	testing.expect(t, !canvas_blend(g, under, 0, 0, 4, 4, under, {0, 0}), "onto itself: refused")
}

// Linear maths blends light: half white over black is 0.5 stored in stored
// maths (128), but half the light in linear maths (188 once encoded).
@(test)
linear_blending_mixes_light :: proc(t: ^testing.T) {
	g := gpu_reference()
	defer gpu_close(&g)
	a, w := pair(g, {0, 0, 0, 1}, {1, 1, 1, 1})
	canvas_blend(g, w, 0, 0, 4, 4, a, {0, 0}, opacity = 0.5)
	testing.expect_value(t, px8(g, a, 0, 0).r, 128)
	b, w2 := pair(g, {0, 0, 0, 1}, {1, 1, 1, 1})
	canvas_blend(g, w2, 0, 0, 4, 4, b, {0, 0}, opacity = 0.5, linear = true)
	testing.expect_value(t, px8(g, b, 0, 0).r, 188)
}

// Dissolve lays whole pixels of the source by chance at its alpha: about
// half at 50 %, each either the source or untouched, the same pattern for
// the same seed.
@(test)
dissolve_lays_whole_pixels_by_chance :: proc(t: ^testing.T) {
	g := gpu_reference()
	defer gpu_close(&g)
	run :: proc(g: Gpu, seed: u32) -> (black: int, pattern: [dynamic]u8) {
		dst, _ := canvas_create(g, {64, 64})
		src, _ := canvas_create(g, {64, 64})
		canvas_fill(g, dst, 0, 0, 64, 64, {1, 1, 1, 1})
		canvas_fill(g, src, 0, 0, 64, 64, {0, 0, 0, 0.5})
		canvas_blend(g, src, 0, 0, 64, 64, dst, {0, 0}, .Dissolve, seed = seed)
		pattern = make([dynamic]u8, context.temp_allocator)
		for y in 0 ..< 64 do for x in 0 ..< 64 {
			p := px8(g, dst, x, y)
			append(&pattern, p.r)
			if p.r == 0 do black += 1
		}
		return
	}
	black, a := run(g, 1)
	testing.expectf(t, black > 64 * 64 * 4 / 10 && black < 64 * 64 * 6 / 10, "about half: %d", black)
	for v in a do testing.expect(t, v == 0 || v == 255, "whole pixels only")
	_, b := run(g, 1)
	_, c := run(g, 2)
	testing.expect(t, string(a[:]) == string(b[:]), "the same seed, the same pattern")
	testing.expect(t, string(a[:]) != string(c[:]), "another seed, another")
}

} // when ODIN_TEST