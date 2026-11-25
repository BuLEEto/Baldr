package gpu

@(require) import "core:math"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports it would
// type-check them too: they sit behind this `when` (see baldr/canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A turned glyph's corners turn about its pivot and sample the atlas as an
// upright one does; its glow turns with it; an upright one is untouched.
@(test)
a_turned_glyph_turns_its_corners_not_its_atlas :: proc(t: ^testing.T) {
	near :: proc(a, b: [2]f32) -> bool { return abs(a.x - b.x) < 1e-3 && abs(a.y - b.y) < 1e-3 }
	verts: [dynamic]Vertex
	defer delete(verts)
	g := Glyph{rect = {110, 100, 10, 20}, uv = {0.1, 0.2, 0.3, 0.4}, color = {1, 1, 1, 1}}
	emit_glyph(&verts, g, KIND_ALPHA_GLYPH)
	upright := verts[:6]
	testing.expect(t, near(upright[0].pos, {110, 100}) && near(upright[2].pos, {120, 120}), "upright: as given")

	g.angle, g.pivot = -math.PI / 2, {100, 100} // reading up a chart's side
	emit_glyph(&verts, g, KIND_ALPHA_GLYPH)
	turned := verts[6:12]
	testing.expect(t, near(turned[0].pos, {100, 90}), "the top-left corner, ten px along, is ten px up")
	testing.expect(t, near(turned[1].pos, {100, 80}), "the top-right")
	testing.expect(t, near(turned[2].pos, {120, 80}), "the bottom-right")
	testing.expect(t, near(turned[5].pos, {120, 90}), "the bottom-left")
	for i in 0 ..< 6 do testing.expect_value(t, turned[i].uv, upright[i].uv)

	emit_glow(&verts, Glow{rect = g.rect, uv = g.uv, color = {0, 0, 0, 1}, radius = 2, angle = g.angle, pivot = g.pivot}, false)
	glow := verts[12:18]
	e := f32(2 * 1.5)
	testing.expect(t, near(glow[0].pos, turn_point({110 - e, 100 - e}, {100, 100}, -math.PI / 2)), "the glow turns with its glyph")
}

}
