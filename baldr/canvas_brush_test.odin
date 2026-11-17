package baldr

@(require) import "core:math"
@(require) import "core:testing"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Brush dabs and strokes, checked on the CPU reference.


@(private = "file")
cov :: proc(g: Gpu, c: Canvas, x, y: int) -> f32 {
	e := canvas_entry(g, c)
	return canvas_decode(e.format, e.pixels[(y * e.size.x + x) * 8:][:8]).a
}

// A hard round dab covers its disc (its rim anti-aliased) and nothing
// past it; a soft one is full at the centre and fades to nothing at its
// radius; two half-strength dabs on one spot make three quarters.
@(test)
dabs_cover_their_shape_and_build_up :: proc(t: ^testing.T) {
	g := gpu_reference()
	defer gpu_close(&g)
	s, _ := canvas_create(g, {64, 64}, .RGBA16, .Linear)
	testing.expect(t, canvas_dabs(g, s, {{centre = {32, 32}, radius = 10, hardness = 1, strength = 1}}), "stamped")
	testing.expect(t, cov(g, s, 32, 32) == 1 && cov(g, s, 32, 44) == 0, "inside full, outside empty")
	total: f32
	for y in 0 ..< 64 do for x in 0 ..< 64 do total += cov(g, s, x, y)
	testing.expectf(t, abs(total - f32(math.PI) * 100) / (f32(math.PI) * 100) < 0.01, "its area: %v", total)

	soft, _ := canvas_create(g, {64, 64}, .RGBA16, .Linear)
	canvas_dabs(g, soft, {{centre = {32, 32}, radius = 10, hardness = 0, strength = 1}})
	testing.expect(t, cov(g, soft, 31, 31) > 0.98 && cov(g, soft, 36, 32) > 0.2 && cov(g, soft, 36, 32) < 0.8 && cov(g, soft, 42, 32) < 0.01, "full, fading, gone")

	twice, _ := canvas_create(g, {16, 16}, .RGBA16, .Linear)
	half := Dab{centre = {8, 8}, radius = 6, hardness = 1, strength = 0.5}
	canvas_dabs(g, twice, {half, half})
	testing.expect(t, abs(cov(g, twice, 8, 8) - 0.75) < 0.001, "0.5 then 0.5: 0.75")
}

// A stroke places a dab where it starts and then one every spacing × size
// along the pointer's path, carrying what is left over from one move to
// the next; pressure scales the size when asked.
@(test)
a_stroke_spaces_its_dabs :: proc(t: ^testing.T) {
	b := Brush{size = 10, hardness = 1, flow = 1, spacing = 0.25} // a dab every 2.5 texels
	path: Brush_Path
	dabs := make([dynamic]Dab, context.temp_allocator)
	brush_stroke(b, &path, {0, 0}, 1, &dabs)
	brush_stroke(b, &path, {6, 0}, 1, &dabs) // 2.5, 5.0; 1 left over
	brush_stroke(b, &path, {10, 0}, 1, &dabs) // 7.5, 10.0
	testing.expect_value(t, len(dabs), 5)
	for d, i in dabs do testing.expectf(t, abs(d.centre.x - 2.5 * f32(i)) < 1e-4, "dab %d at %v", i, d.centre.x)

	soft := Brush{size = 20, hardness = 0.5, flow = 0.8, spacing = 0.5, size_pressure = true, flow_pressure = true}
	p2: Brush_Path
	clear(&dabs)
	brush_stroke(soft, &p2, {0, 0}, 0.5, &dabs)
	testing.expect(t, dabs[0].radius == 5 && abs(dabs[0].strength - 0.4) < 1e-6, "half the pressure: half the size and the flow")
}

// A stroke is painted in its colour through its coverage, opacity capping
// it; an eraser takes alpha away and keeps the colour.
@(test)
a_stroke_is_painted_through_its_coverage :: proc(t: ^testing.T) {
	g := gpu_reference()
	defer gpu_close(&g)
	layer, _ := canvas_create(g, {8, 8})
	canvas_fill(g, layer, 0, 0, 8, 8, {1, 1, 1, 1})
	stroke, _ := canvas_create(g, {8, 8}, .RGBA16, .Linear)
	canvas_fill(g, stroke, 0, 0, 4, 8, {1, 1, 1, 1})
	canvas_fill(g, stroke, 4, 0, 2, 8, {0.5, 0.5, 0.5, 0.5})
	testing.expect(t, canvas_paint(g, layer, 0, 0, 8, 8, {1, 0, 0, 1}, opacity = 0.8, mask = stroke), "painted")
	e := canvas_entry(g, layer)
	at :: proc(e: ^Canvas_Entry, x, y: int) -> [4]u8 { p := e.pixels[(y * 8 + x) * 4:][:4]; return {p[0], p[1], p[2], p[3]} }
	testing.expect_value(t, at(e, 1, 1), [4]u8{255, 51, 51, 255}) // 80 % red over white
	testing.expect_value(t, at(e, 4, 1), [4]u8{255, 153, 153, 255}) // half the coverage: 40 %
	testing.expect_value(t, at(e, 7, 1), [4]u8{255, 255, 255, 255}) // none
	canvas_paint(g, layer, 0, 0, 8, 8, {0, 0, 0, 1}, mask = stroke, erase = true)
	testing.expect_value(t, at(e, 1, 1), [4]u8{255, 51, 51, 0}) // erased: alpha gone, colour kept
	testing.expect_value(t, at(e, 4, 1), [4]u8{255, 153, 153, 127}) // 16-bit 0.5 is 32768: a hair over half taken
}

} // when ODIN_TEST