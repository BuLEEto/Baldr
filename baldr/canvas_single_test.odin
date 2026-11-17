package baldr

@(require) import "baldr:gpu"
@(require) import "core:testing"

when ODIN_TEST || #config(BALDR_TESTS, false) {

// One-channel canvases, for the coverage an editor is made of
// — selections, layer masks, strokes, the shape of text — where four
// channels spend four bytes to carry one.

@(private = "file")
sc_texel :: proc(g: Gpu, c: Canvas, x, y: int) -> [4]f32 {
	e := canvas_entry(g, c)
	b := gpu.canvas_bpp(e.format)
	return canvas_decode(e.format, e.pixels[(y * e.size.x + x) * b:][:b])
}

@(test)
single_channel_canvases_cost_one_byte_a_texel :: proc(t: ^testing.T) {
	g := gpu_reference()
	defer gpu_close(&g)
	r8, ok8 := canvas_create(g, {64, 64}, .R8)
	r16, ok16 := canvas_create(g, {64, 64}, .R16)
	rgba, _ := canvas_create(g, {64, 64}, .RGBA8)
	testing.expect(t, ok8 && ok16, "both one-channel formats are made")
	testing.expect_value(t, len(canvas_entry(g, r8).pixels), 64 * 64)      // one byte a texel…
	testing.expect_value(t, len(canvas_entry(g, r16).pixels), 64 * 64 * 2) // …two for 16 bits
	testing.expect_value(t, len(canvas_entry(g, rgba).pixels), 64 * 64 * 4)
	testing.expect(t, gpu.canvas_format_single(.R8) && gpu.canvas_format_single(.R16), "and they are coverage")
	testing.expect(t, !gpu.canvas_format_single(.RGBA8))

	// filled and read as coverage: the value is in r, and it reads opaque
	canvas_fill(g, r8, 0, 0, 4, 4, {0.5, 0.25, 0.75, 0.125})
	c := sc_texel(g, r8, 1, 1)
	testing.expect(t, abs(c.r - 0.5) < 0.01, "the first channel is what it keeps")
	testing.expect_value(t, c.a, 1) // coverage is not alpha: it reads opaque
	testing.expect_value(t, canvas_entry(g, r8).pixels[65], u8(128))

	canvas_fill(g, r16, 0, 0, 2, 2, {1, 0, 0, 1})
	e := canvas_entry(g, r16)
	testing.expect(t, e.pixels[0] == 0xFF && e.pixels[1] == 0xFF, "16 bits of it, little-endian")
}

@(test)
a_one_channel_canvas_is_a_mask_like_any_other :: proc(t: ^testing.T) {
	// The point of the format: a mask that costs a quarter as much must do
	// everything a four-channel mask does.
	g := gpu_reference()
	defer gpu_close(&g)
	src, _ := canvas_create(g, {8, 8}, .RGBA32F, .Linear)
	one, _ := canvas_create(g, {8, 8}, .RGBA32F, .Linear)
	four, _ := canvas_create(g, {8, 8}, .RGBA32F, .Linear)
	mask8, _ := canvas_create(g, {8, 8}, .R8)
	mask_rgba, _ := canvas_create(g, {8, 8}, .RGBA8)
	canvas_fill(g, src, 0, 0, 8, 8, {1, 0, 0, 1})
	canvas_fill(g, mask8, 0, 0, 8, 8, {0.5, 0, 0, 0})
	canvas_fill(g, mask_rgba, 0, 0, 8, 8, {0.5, 0.5, 0.5, 1})

	testing.expect(t, canvas_blend(g, src, 0, 0, 8, 8, one, {0, 0}, .Normal, 1, mask8), "blended through R8")
	testing.expect(t, canvas_blend(g, src, 0, 0, 8, 8, four, {0, 0}, .Normal, 1, mask_rgba), "…and through RGBA8")
	a, b := sc_texel(g, one, 3, 3), sc_texel(g, four, 3, 3)
	for k in 0 ..< 4 do testing.expectf(t, abs(a[k] - b[k]) < 0.001,
		"channel %d: through R8 %v, through RGBA8 %v — the same mask", k, a[k], b[k])
	testing.expect(t, abs(a.a - 0.5) < 0.01, "and half the coverage let half of it through")
}

@(test)
one_channel_canvases_copy_to_and_from_colour :: proc(t: ^testing.T) {
	g := gpu_reference()
	defer gpu_close(&g)
	rgba, _ := canvas_create(g, {8, 8}, .RGBA8)
	r8, _ := canvas_create(g, {8, 8}, .R8)
	canvas_fill(g, rgba, 0, 0, 8, 8, {0.75, 0.3, 0.1, 1})

	testing.expect(t, canvas_copy(g, rgba, 0, 0, 8, 8, r8, {0, 0}), "colour into coverage")
	testing.expect(t, abs(sc_texel(g, r8, 2, 2).r - 0.75) < 0.01, "…which keeps the first channel")

	back, _ := canvas_create(g, {8, 8}, .RGBA8)
	testing.expect(t, canvas_copy(g, r8, 0, 0, 8, 8, back, {0, 0}), "coverage into colour")
	c := sc_texel(g, back, 2, 2)
	testing.expect(t, abs(c.r - 0.75) < 0.01 && c.g == 0 && c.b == 0, "…which reads it as (r, 0, 0)")
	testing.expect_value(t, c.a, 1)
}

@(test)
a_canvas_can_be_made_without_mips :: proc(t: ^testing.T) {
	// On the reference there are no levels to count; what matters here is
	// that the option is taken and the canvas behaves. The levels are the
	// GPU's, and spikes/canvas_parity is where that is watched.
	g := gpu_reference()
	defer gpu_close(&g)
	c, ok := canvas_create(g, {32, 32}, .RGBA8, .sRGB, mips = false)
	testing.expect(t, ok, "made without mips")
	testing.expect(t, canvas_fill(g, c, 0, 0, 4, 4, {1, 1, 1, 1}), "and draws as any other")
	testing.expect_value(t, sc_texel(g, c, 1, 1), [4]f32{1, 1, 1, 1})
}

@(test)
a_one_channel_mask_can_be_feathered :: proc(t: ^testing.T) {
	// A feathered selection is a blurred mask, which is why blur has to take
	// these formats.
	g := gpu_reference()
	defer gpu_close(&g)
	hard, _ := canvas_create(g, {32, 32}, .R8)
	soft, _ := canvas_create(g, {32, 32}, .R8)
	canvas_fill(g, hard, 8, 8, 16, 16, {1, 0, 0, 0}) // a square selection

	testing.expect(t, canvas_blur(g, hard, 0, 0, 32, 32, soft, {0, 0}, 2), "blurred")
	inside := sc_texel(g, soft, 16, 16).r
	outside := sc_texel(g, soft, 2, 2).r
	edge := sc_texel(g, soft, 8, 16).r
	testing.expect(t, inside > 0.9, "the middle of the selection is still in it")
	testing.expect(t, outside < 0.05, "well outside it is still out")
	testing.expect(t, edge > 0.1 && edge < 0.9, "and its edge is feathered, which is the point")
}

} // when ODIN_TEST
