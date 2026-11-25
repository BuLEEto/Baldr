package baldr

@(require) import "core:math"
@(require) import "core:testing"
@(require) import "baldr:gpu"

// Turned text, for a chart's axis labels: laid out upright and turned about
// where it starts.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Turn_Msg :: union { int }

@(private = "file")
turn_glyphs :: proc(te: ^Text_Engine, dt: Draw_Text) -> []gpu.Glyph {
	cmds := make([dynamic]gpu.Cmd, context.temp_allocator)
	render_text(te, dt, 1, nil, &cmds)
	out := make([dynamic]gpu.Glyph, context.temp_allocator)
	for c in cmds do if g, ok := c.(gpu.Glyph); ok do append(&out, g)
	return out[:]
}

// At a right angle the glyphs are the upright ones, turned about the
// label's start; off one they are rasterised at twice the size and drawn at
// half, so a 45° label keeps crisp edges.
@(test)
a_turned_label_turns_its_glyphs_about_its_start :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init: embedded fonts failed to load")
	defer text_engine_destroy(&te)
	dt := Draw_Text{pos = {100, 100}, str = "Rainfall", size = 16, color = {1, 1, 1, 1}}
	upright := turn_glyphs(&te, dt)
	dt.angle = -math.PI / 2
	turned := turn_glyphs(&te, dt)
	testing.expect(t, len(upright) > 0 && len(upright) == len(turned), "every glyph drawn")
	for g, i in turned {
		testing.expect(t, g.angle == dt.angle && g.pivot == [2]f32{100, 100}, "turned about the label's start")
		testing.expect_value(t, g.rect, upright[i].rect)
		testing.expect_value(t, g.uv, upright[i].uv)
	}

	dt.angle = -math.PI / 4
	slant := turn_glyphs(&te, dt)
	testing.expect_value(t, len(slant), len(upright))
	for g, i in slant {
		u := upright[i]
		testing.expectf(t, abs(g.rect[2] - u.rect[2]) <= 1 && abs(g.rect[3] - u.rect[3]) <= 1, "glyph %d drawn the same size (%v vs %v)", i, g.rect, u.rect)
		ratio := (g.uv[2] - g.uv[0]) / max(u.uv[2] - u.uv[0], 1e-6)
		testing.expectf(t, ratio > 1.6 && ratio < 2.4, "glyph %d from a bitmap twice the size (uv %v)", i, ratio)
	}
}

// What a turned label covers is the turned box, which the paint-bounds check
// and a custom node's own size are judged by.
@(test)
a_turned_label_covers_its_turned_box :: proc(t: ^testing.T) {
	ui: Ui(Turn_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree
	dt := Draw_Text{pos = {50, 80}, str = "Rainfall", size = 16}
	up := drawn_text_rect(tr, dt)
	testing.expect(t, up.w > up.h && up.h > 0, "a measured label")
	dt.angle = -math.PI / 2
	r := drawn_text_rect(tr, dt)
	near :: proc(a, b: f32) -> bool { return abs(a - b) < 0.01 }
	testing.expectf(t, near(r.x, 50) && near(r.y, 80 - up.w) && near(r.w, up.h) && near(r.h, up.w), "reading up from its start: %v", r)
}

// The painter's draw_text passes the angle on, and a glow under turned text
// turns with it.
@(test)
a_custom_painter_turns_its_text :: proc(t: ^testing.T) {
	ui: Ui(Turn_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {300, 200})
	begin_view(&ui)
	custom(&ui, proc(p: ^Painter) {
		draw_text(p, {p.rect.x + 20, p.rect.y + 120}, "Rainfall (mm)", size = 13, angle = -math.PI / 2)
	}, width = 200, height = 160)
	end_view(&ui)
	frame(&ui.tree, {300, 200})
	found := false
	for c in draw_list(&ui.tree) do if dt, ok := c.(Draw_Text); ok && dt.str == "Rainfall (mm)" {
		found = true
		testing.expect_value(t, dt.angle, f32(-math.PI / 2))
	}
	testing.expect(t, found, "the label is drawn")

	out := make([dynamic]gpu.Cmd, context.temp_allocator)
	append(&out, gpu.Glyph{rect = {10, 10, 8, 12}, uv = {0, 0, 0.1, 0.1}, page = 2, color = {1, 1, 1, 1}, angle = 0.5, pivot = {4, 4}})
	glow_under(&out, 0, Glow{color = {0, 0, 0, 1}, radius = 3}, 1)
	gl, is_glow := out[0].(gpu.Glow)
	testing.expect(t, is_glow && gl.angle == 0.5 && gl.pivot == [2]f32{4, 4}, "the halo turns with its glyph")
}

}
