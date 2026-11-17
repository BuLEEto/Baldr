package baldr

@(require) import "core:strings"
@(require) import "core:testing"
@(require) import "baldr:gpu"

// See canvas_test.odin for why test files sit behind this `when`.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Text outside the clips around it is skipped when the frame is prepared,
// so an editor of very long rows does not send every glyph of every row to
// the GPU each frame, the caret's blink included. Both halves matter: far
// fewer glyphs, and exactly the glyphs that show, so the culled frame is
// compared, glyph for glyph, with each of the editor's lines drawn uncut
// and cut to the window by hand.

@(private = "file")
Cull_Msg :: union { int }

@(private = "file")
cull_glyphs :: proc(cmds: []gpu.Cmd) -> [dynamic]gpu.Glyph {
	out := make([dynamic]gpu.Glyph, context.temp_allocator)
	for c in cmds do if g, ok := c.(gpu.Glyph); ok do append(&out, g)
	return out
}

@(private = "file")
meets :: proc(r, clip: [4]f32) -> bool {
	return r.x < clip.x + clip.z && r.x + r.z > clip.x && r.y < clip.y + clip.w && r.y + r.w > clip.y
}

@(test)
an_editors_long_rows_send_only_what_shows_to_the_gpu :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init: embedded fonts failed to load")
	defer text_engine_destroy(&te)
	ui: Ui(Cull_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tree_use_text_engine(&ui.tree, &te)

	// 30 rows of 3,000 characters in an editor 400 × 200: a dozen rows of a
	// few dozen characters show.
	b := strings.builder_make(context.temp_allocator)
	for row in 0 ..< 30 {
		for i in 0 ..< 3000 do strings.write_byte(&b, u8('a' + (i + row) % 26) if i % 9 != 8 else ' ')
		if row < 29 do strings.write_byte(&b, '\n')
	}
	doc := document_make(strings.to_string(b))
	defer document_destroy(&doc)
	begin_view(&ui)
	column(&ui)
	ed := code_editor(&ui, &doc, nil, label = "Code", width = 400, height = 200)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 200})
	area := node_get(&ui.tree, ed).abs
	window := [4]f32{area.x, area.y, area.w, area.h}

	out := make([dynamic]gpu.Cmd, context.temp_allocator)
	render_prepare(&ui.tree, 1, nil, &out)
	culled := cull_glyphs(out[:])

	// Each of the editor's lines drawn with nothing to cut it, then cut to
	// the editor's own rect by hand: what a person sees.
	uncut := 0
	want := make([dynamic]gpu.Glyph, context.temp_allocator)
	for c in draw_list(&ui.tree) {
		dt, is_text := c.(Draw_Text)
		if !is_text || len(dt.str) < 1000 do continue // the long rows, not the gutter's numbers
		all := make([dynamic]gpu.Cmd, context.temp_allocator)
		render_text(&te, dt, 1, nil, &all)
		for g in cull_glyphs(all[:]) {
			uncut += 1
			if meets(g.rect, window) do append(&want, g)
		}
	}
	testing.expectf(t, uncut > 20_000, "uncut, every glyph of every row goes: %d", uncut)
	testing.expectf(t, len(culled) < 3_000, "culled, only what is near the window: %d glyphs in all", len(culled))
	testing.expectf(t, len(want) > 100, "and the window shows a good deal: %d glyphs", len(want))
	for w in want {
		found := false
		for g in culled do if g == w { found = true; break }
		if !found {
			testing.expectf(t, false, "a glyph that shows went missing: %v", w.rect)
			break
		}
	}
}

}
