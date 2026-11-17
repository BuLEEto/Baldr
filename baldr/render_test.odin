package baldr

@(require) import "core:math"
@(require) import "core:testing"
@(require) import "baldr:gpu"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them. ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh
// check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file") WHITE :: Color{1, 1, 1, 1}
@(private = "file") GREY  :: Color{0.2, 0.2, 0.2, 1}
@(private = "file") TEAL  :: Color{0, 0.5, 0.5, 1}

// gpu rects are [4]f32{x, y, w, h}; name the indices so tests read clearly.
@(private = "file") X :: 0
@(private = "file") Y :: 1
@(private = "file") W :: 2
@(private = "file") H :: 3

// Rec_Sink is an Atlas_Sink that records what the renderer would be asked
// to do. Page ids start at 101 so they cannot be confused with the headless
// numbering.
@(private = "file")
Rec_Sink :: struct {
	creates: [dynamic]Rec_Create,
	uploads: [dynamic]Rec_Upload,
}
@(private = "file")
Rec_Create :: struct {
	format: gpu.Page_Format,
	size:   [2]u32,
}
@(private = "file")
Rec_Upload :: struct {
	page:       gpu.Page,
	x, y, w, h: u32,
	bytes:      int,
}

@(private = "file")
rec_create :: proc(user: rawptr, format: gpu.Page_Format, size: [2]u32) -> gpu.Page {
	r := (^Rec_Sink)(user)
	append(&r.creates, Rec_Create{format = format, size = size})
	return gpu.Page(100 + len(r.creates))
}

@(private = "file")
rec_upload :: proc(user: rawptr, page: gpu.Page, x, y, w, h: u32, pixels: []u8) {
	r := (^Rec_Sink)(user)
	append(&r.uploads, Rec_Upload{page = page, x = x, y = y, w = w, h = h, bytes = len(pixels)})
}

@(private = "file")
rec_destroy :: proc(r: ^Rec_Sink) {
	delete(r.creates)
	delete(r.uploads)
}

// text_tree builds an engine-backed tree whose root is a padded column
// holding one white text node, laid out and painted at `viewport`.
@(private = "file")
text_tree :: proc(t: ^testing.T, te: ^Text_Engine, tr: ^Tree, s: string, size: f32, viewport: [2]f32) -> Node {
	if !text_engine_init(te) do testing.fail_now(t, "text_engine_init: embedded fonts failed to load")
	tree_init(tr)
	tree_use_text_engine(tr, te)
	node_get(tr, tr.root).layout = {axis = .Column, padding = pad4(10)}
	n := node_new(tr, Text_Kind{str = s, size = size})
	node_get(tr, n).style.fg = WHITE
	node_append(tr, tr.root, n)
	frame(tr, viewport)
	return n
}

@(private = "file")
glyphs_of :: proc(cmds: []gpu.Cmd, allocator := context.temp_allocator) -> []gpu.Glyph {
	out := make([dynamic]gpu.Glyph, allocator)
	for c in cmds do if g, ok := c.(gpu.Glyph); ok do append(&out, g)
	return out[:]
}

@(private = "file")
is_integral :: proc(r: [4]f32) -> bool {
	for v in r do if v != math.floor(v) do return false
	return true
}

@(test)
render_scales_and_snaps_rects :: proc(t: ^testing.T) {
	tr: Tree
	tree_init(&tr)
	defer tree_destroy(&tr)
	r := node_get(&tr, tr.root)
	r.layout = {axis = .Column, padding = pad4(10)}
	r.style.bg = GREY
	c := node_new(&tr, Box_Kind{})
	node_get(&tr, c).layout = {width = 50, height = 50}
	node_get(&tr, c).style = {bg = TEAL, radius = 4, border_w = 1, border = WHITE, opacity = 1}
	node_append(&tr, tr.root, c)
	txt := node_new(&tr, Text_Kind{str = "no engine", size = 16}) // no Text_Engine: text is skipped, not a crash
	node_get(&tr, txt).style.fg = WHITE
	node_append(&tr, tr.root, txt)
	frame(&tr, {200, 150})

	out := make([dynamic]gpu.Cmd, context.temp_allocator)
	render_prepare(&tr, 2, nil, &out)
	testing.expect_value(t, len(out), 2)
	q0 := out[0].(gpu.Quad)
	testing.expect_value(t, q0.rect, [4]f32{0, 0, 400, 300})
	testing.expect_value(t, q0.color, GREY)
	q1 := out[1].(gpu.Quad)
	testing.expect_value(t, q1.rect, [4]f32{20, 20, 100, 100})
	testing.expect_value(t, q1.radius, 8)
	testing.expect_value(t, q1.border_w, 2)
	testing.expect_value(t, q1.border, WHITE)

	// Fractional logical coordinates snap so edges land on device pixels.
	node_get(&tr, tr.root).layout.padding = pad4(10.3)
	mark_layout_dirty(&tr, tr.root)
	frame(&tr, {200, 150})
	clear(&out)
	render_prepare(&tr, 1.5, nil, &out)
	q1 = out[1].(gpu.Quad)
	testing.expect(t, is_integral(q1.rect), "snapped rect has integral edges")
	testing.expect_value(t, q1.rect, [4]f32{15, 15, 75, 75}) // round(15.45)=15, round(90.45)=90

	// Clip rects scale and snap the same way.
	node_get(&tr, tr.root).flags += {.Clips}
	mark_paint_dirty(&tr, tr.root)
	frame(&tr, {200, 150})
	clear(&out)
	render_prepare(&tr, 2, nil, &out)
	push, is_push := out[1].(gpu.Clip_Push)
	_, is_pop := out[len(out) - 1].(gpu.Clip_Pop)
	testing.expect(t, is_push && is_pop, "clip push after the root quad, pop last")
	testing.expect_value(t, push.rect, [4]f32{0, 0, 400, 300})
}

@(test)
render_emits_one_glyph_per_visible_glyph :: proc(t: ^testing.T) {
	te: Text_Engine
	tr: Tree
	n := text_tree(t, &te, &tr, "hello world", 16, {300, 100})
	defer text_engine_destroy(&te)
	defer tree_destroy(&tr)

	out := make([dynamic]gpu.Cmd, context.temp_allocator)
	render_prepare(&tr, 1, nil, &out)
	gs := glyphs_of(out[:])
	testing.expect_value(t, len(gs), 10) // 11 glyphs minus the space

	pos := node_get(&tr, n).abs
	lh := text_line_height(&te, 16)
	measured := text_measure(&tr, "hello world", 16, 0, .Regular)
	for g, i in gs {
		testing.expect_value(t, g.page, gpu.Page(1)) // headless: first page, numbered from 1
		testing.expect_value(t, g.color, WHITE)
		testing.expect(t, g.rect[W] > 0 && g.rect[H] > 0, "glyph has a bitmap")
		testing.expect(t, is_integral(g.rect), "glyph rect is on device pixels")
		testing.expect(t, g.rect[X] >= pos.x - 1 && g.rect[Y] >= pos.y - 1, "glyph starts inside the node")
		testing.expect(t, g.rect[Y] + g.rect[H] <= pos.y + lh + 2, "glyph stays inside the line")
		testing.expect(t, g.uv[2] > g.uv[0] && g.uv[3] > g.uv[1] && g.uv[2] <= 1 && g.uv[3] <= 1, "normalised uv")
		if i > 0 do testing.expect(t, g.rect[X] > gs[i - 1].rect[X], "glyphs advance left to right")
	}
	last := gs[len(gs) - 1]
	testing.expect(t, math.abs((last.rect[X] + last.rect[W]) - (pos.x + measured.x)) <= 2, "run ends where measurement says")

	// At 2x every glyph is rasterised at twice the size and placed at twice the position.
	clear(&out)
	render_prepare(&tr, 2, nil, &out)
	gs2 := glyphs_of(out[:])
	testing.expect_value(t, len(gs2), 10)
	last2 := gs2[len(gs2) - 1]
	testing.expect(t, math.abs((last2.rect[X] + last2.rect[W]) - 2 * (pos.x + measured.x)) <= 3, "2x run ends at twice the width")
	testing.expect(t, last2.rect[H] > last.rect[H], "2x glyph bitmaps are taller")
	testing.expect(t, gs2[0].rect[Y] >= 2 * pos.y - 1, "2x glyphs start at twice the y")
}

@(test)
render_is_deterministic :: proc(t: ^testing.T) {
	te: Text_Engine
	tr: Tree
	text_tree(t, &te, &tr, "Baldr 🦊 text", 18, {300, 100})
	defer text_engine_destroy(&te)
	defer tree_destroy(&tr)

	a := make([dynamic]gpu.Cmd, context.temp_allocator)
	b := make([dynamic]gpu.Cmd, context.temp_allocator)
	render_prepare(&tr, 1.25, nil, &a)
	render_prepare(&tr, 1.25, nil, &b)
	testing.expect_value(t, len(a), len(b))
	testing.expect_value(t, len(glyphs_of(a[:])), 10) // one glyph per non-space glyph, emoji included
	for i in 0 ..< min(len(a), len(b)) {
		testing.expect(t, a[i] == b[i], "same command on both frames")
	}
}

@(test)
render_colour_emoji_lands_on_rgba_page :: proc(t: ^testing.T) {
	te: Text_Engine
	tr: Tree
	n := text_tree(t, &te, &tr, "🦊", 16, {100, 100})
	defer text_engine_destroy(&te)
	defer tree_destroy(&tr)
	rec: Rec_Sink
	defer rec_destroy(&rec)
	sink := Atlas_Sink{user = &rec, create = rec_create, upload = rec_upload}

	out := make([dynamic]gpu.Cmd, context.temp_allocator)
	render_prepare(&tr, 2, &sink, &out)
	gs := glyphs_of(out[:])
	testing.expect_value(t, len(gs), 1)
	testing.expect_value(t, len(rec.creates), 1)
	testing.expect_value(t, rec.creates[0].format, gpu.Page_Format.RGBA8)
	testing.expect_value(t, rec.creates[0].size, [2]u32{ATLAS_PAGE_SIZE, ATLAS_PAGE_SIZE})
	testing.expect_value(t, gs[0].page, gpu.Page(101))
	testing.expect_value(t, gs[0].color, WHITE) // colour passes through; gpu modulates by alpha
	testing.expect(t, gs[0].rect[W] >= 28 && gs[0].rect[H] >= 24, "32px emoji bitmap")
	// A new page is uploaded whole, tightly packed RGBA8.
	testing.expect_value(t, len(rec.uploads), 1)
	up := rec.uploads[0]
	testing.expect_value(t, up.page, gpu.Page(101))
	testing.expect_value(t, [4]u32{up.x, up.y, up.w, up.h}, [4]u32{0, 0, ATLAS_PAGE_SIZE, ATLAS_PAGE_SIZE})
	testing.expect_value(t, up.bytes, int(up.w * up.h) * 4)

	// Nothing new: no more creates or uploads.
	clear(&out)
	render_prepare(&tr, 2, &sink, &out)
	testing.expect_value(t, len(rec.creates), 1)
	testing.expect_value(t, len(rec.uploads), 1)

	// Mixed text: mono glyphs open an Alpha8 page; each glyph knows its page.
	set_text(&tr, n, "a🦊")
	frame(&tr, {100, 100})
	clear(&out)
	render_prepare(&tr, 2, &sink, &out)
	gs = glyphs_of(out[:])
	testing.expect_value(t, len(gs), 2)
	testing.expect_value(t, len(rec.creates), 2)
	testing.expect_value(t, rec.creates[1].format, gpu.Page_Format.Alpha8)
	testing.expect_value(t, gs[0].page, gpu.Page(102)) // 'a' on the new alpha page
	testing.expect_value(t, gs[1].page, gpu.Page(101)) // fox still on the colour page
	testing.expect_value(t, len(rec.uploads), 2)
	testing.expect_value(t, rec.uploads[1].bytes, int(rec.uploads[1].w * rec.uploads[1].h)) // Alpha8: 1 byte/px

	// A later dirty rect is uploaded as just that rect.
	set_text(&tr, n, "a🦊Zg")
	frame(&tr, {100, 100})
	clear(&out)
	render_prepare(&tr, 2, &sink, &out)
	testing.expect_value(t, len(rec.creates), 2)
	testing.expect_value(t, len(rec.uploads), 3)
	up = rec.uploads[2]
	testing.expect_value(t, up.page, gpu.Page(102))
	testing.expect(t, up.w < ATLAS_PAGE_SIZE && up.h < ATLAS_PAGE_SIZE && up.w > 0 && up.h > 0, "partial dirty rect")
	testing.expect_value(t, up.bytes, int(up.w * up.h))
}

@(test)
render_wrapped_text_matches_measurement :: proc(t: ^testing.T) {
	te: Text_Engine
	tr: Tree
	s := "The quick brown fox jumps over the lazy dog and keeps running"
	n := text_tree(t, &te, &tr, s, 16, {120, 300}) // 10 px padding: text wraps at 100
	defer text_engine_destroy(&te)
	defer tree_destroy(&tr)

	d := node_get(&tr, n)
	lh := text_line_height(&te, 16)
	testing.expect_value(t, [2]f32{d.rect.w, d.rect.h}, text_measure(&tr, s, 16, 100, .Regular))
	lines := int(math.round(d.rect.h / lh))
	testing.expect(t, lines >= 4, "long sentence wraps to several lines at 100 px")

	out := make([dynamic]gpu.Cmd, context.temp_allocator)
	render_prepare(&tr, 1, nil, &out)
	gs := glyphs_of(out[:])
	starts := 1
	for g, i in gs {
		if i > 0 && g.rect[X] < gs[i - 1].rect[X] do starts += 1
		testing.expect(t, g.rect[X] + g.rect[W] <= d.abs.x + 100 + 2, "no glyph escapes the wrap width")
		testing.expect(t, g.rect[Y] + g.rect[H] <= d.abs.y + d.abs.h + 2, "no glyph escapes the node height")
	}
	testing.expect_value(t, starts, lines) // rendered with the line breaks layout measured
}

} // when ODIN_TEST