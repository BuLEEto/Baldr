package baldr

@(require) import "core:fmt"
@(require) import "core:math"
@(require) import "core:strings"
@(require) import "core:testing"
@(require) import "core:unicode/utf8"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
LONG :: "The quick brown fox jumps over the lazy dog and keeps running"

// text_fixture builds an engine and a tree that measures through it.
@(private = "file")
text_fixture :: proc(t: ^testing.T, te: ^Text_Engine, tr: ^Tree) {
	if !text_engine_init(te) do testing.fail_now(t, "text_engine_init: embedded fonts failed to load")
	tree_init(tr)
	tree_use_text_engine(tr, te)
}

@(test)
text_measure_width_and_line_height :: proc(t: ^testing.T) {
	te: Text_Engine
	tr: Tree
	text_fixture(t, &te, &tr)
	defer text_engine_destroy(&te)
	defer tree_destroy(&tr)

	lh := text_line_height(&te, 16)
	hello := text_measure(&tr, "hello", 16, 0, .Regular)
	testing.expect(t, hello.x > 0, "hello has width")
	testing.expect_value(t, hello.y, lh)
	world := text_measure(&tr, "hello world", 16, 0, .Regular)
	testing.expect(t, world.x > hello.x, "hello world is wider than hello")
	testing.expect_value(t, world.y, lh)
	testing.expect_value(t, text_measure(&tr, "", 16, 0, .Regular), [2]f32{0, lh})
	testing.expect(t, text_measure(&tr, "hello", 32, 0, .Regular).x > hello.x, "a bigger size is wider")

	// Inter Variable: upem 2048, ascent 1984, descent -494, line gap 0.
	testing.expect(t, math.abs(lh - 16 * 2478.0 / 2048) < 1e-3, "line height from Inter's hhea metrics")
	testing.expect(t, math.abs(text_ascent(&te, 16) - 16 * 1984.0 / 2048) < 1e-3, "ascent from Inter's hhea metrics")
	testing.expect(t, text_ascent(&te, 16) < lh, "ascent is inside the line")
}

@(test)
text_measure_wraps_at_max_width :: proc(t: ^testing.T) {
	te: Text_Engine
	tr: Tree
	text_fixture(t, &te, &tr)
	defer text_engine_destroy(&te)
	defer tree_destroy(&tr)

	lh := text_line_height(&te, 16)
	flat := text_measure(&tr, LONG, 16, 0, .Regular)
	testing.expect_value(t, flat.y, lh)
	wrapped := text_measure(&tr, LONG, 16, 100, .Regular)
	testing.expect(t, wrapped.y > flat.y, "wrapped text is taller than unwrapped")
	testing.expect(t, wrapped.x <= 100, "wrapped lines fit the max width")
	testing.expect(t, wrapped.x < flat.x, "wrapped text is narrower")
	lines := wrapped.y / lh
	testing.expect(t, lines >= 2 && math.abs(lines - math.round(lines)) < 1e-4, "height is a whole number of lines")
	testing.expect_value(t, text_measure(&tr, LONG, 16, 1000, .Regular), flat) // wide enough: no wrapping
	testing.expect_value(t, text_measure(&tr, LONG, 16, -5, .Regular), flat)   // negative = unbounded
}

@(test)
text_measure_survives_odd_input :: proc(t: ^testing.T) {
	te: Text_Engine
	tr: Tree
	text_fixture(t, &te, &tr)
	defer text_engine_destroy(&te)
	defer tree_destroy(&tr)

	testing.expect_value(t, text_measure(&tr, "x", 0, 0, .Regular), [2]f32{0, 0})
	testing.expect_value(t, text_measure(&tr, "x", -3, 0, .Regular), [2]f32{0, 0})
	testing.expect_value(t, text_measure(&tr, "x", 1e9, 0, .Regular), [2]f32{0, 0})
	testing.expect_value(t, text_measure(&tr, "x", math.inf_f32(1), 0, .Regular), [2]f32{0, 0})
	testing.expect_value(t, text_measure(&tr, "x", math.nan_f32(), 0, .Regular), [2]f32{0, 0})
	testing.expect(t, text_measure(&tr, "A", 2000, 0, .Regular).x > 0, "large but sane size measures")
	testing.expect(t, text_measure(&tr, "hello world", 16, 1, .Regular).y > text_line_height(&te, 16), "absurd wrap width breaks per glyph")
	testing.expect(t, text_measure(&tr, "a\xffb", 16, 0, .Regular).x > 0, "invalid UTF-8 measures")
	testing.expect(t, text_measure(&tr, "日本語 עברית 🦊", 16, 0, .Regular).x > 0, "uncovered scripts fall back to .notdef, no panic")
	testing.expect_value(t, text_measure(&tr, "a\nb", 16, 0, .Regular).y, 2 * text_line_height(&te, 16))
}

@(test)
text_layout_uses_engine_measurements :: proc(t: ^testing.T) {
	te: Text_Engine
	tr: Tree
	text_fixture(t, &te, &tr)
	defer text_engine_destroy(&te)
	defer tree_destroy(&tr)

	node_get(&tr, tr.root).layout = {axis = .Column}
	n := node_new(&tr, Text_Kind{str = LONG, size = 16})
	node_append(&tr, tr.root, n)

	layout(&tr, {400, 300})
	d := node_get(&tr, n)
	m := text_measure(&tr, LONG, 16, 400, .Regular)
	testing.expect_value(t, [2]f32{d.rect.w, d.rect.h}, m)
	testing.expect_value(t, d.kind.(Text_Kind).wrap_w, 400) // paint carries the measured width to render

	layout(&tr, {100, 300}) // narrower: the same text wraps
	d = node_get(&tr, n)
	m = text_measure(&tr, LONG, 16, 100, .Regular)
	testing.expect_value(t, [2]f32{d.rect.w, d.rect.h}, m)
	testing.expect(t, d.rect.h > text_line_height(&te, 16), "wrapped node is taller than one line")
	testing.expect_value(t, d.kind.(Text_Kind).wrap_w, 100)

	tree_use_text_engine(&tr, nil) // back to the headless measurer
	testing.expect_value(t, text_measure(&tr, "hello", 16, 0, .Regular), measure_text_mono(&tr, "hello", 16, 0, .Regular))
}

@(test)
text_lines_cache_is_bounded :: proc(t: ^testing.T) {
	te: Text_Engine
	tr: Tree
	text_fixture(t, &te, &tr)
	defer text_engine_destroy(&te)
	defer tree_destroy(&tr)

	for i in 0 ..< LINES_CACHE_MAX + 40 {
		s := fmt.tprintf("w%d", i)
		testing.expect(t, text_measure(&tr, s, 16, 0, .Regular).x > 0, "every string measures")
	}
	testing.expect(t, len(te.lines) <= LINES_CACHE_MAX, "paragraph cache is capped")
	testing.expect(t, len(te.lines) > LINES_CACHE_MAX / 2, "eviction keeps the recent half")
	first := text_measure(&tr, "w0", 16, 0, .Regular)
	testing.expect_value(t, text_measure(&tr, "w0", 16, 0, .Regular), first) // evicted then re-laid-out: same answer
}

// A wrapped text given less height than it needs (a fixed-height row at
// phone width) keeps the lines that fit and ends with "…" instead of
// painting past its box; a text with room, or an unwrapped one, is untouched.
@(test)
text_fits_a_bounded_height_by_dropping_lines :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	long := "Wheel, Page Up/Down, Home/End, drag the thumb or click the track. Rows are built on demand, and this goes on for a while."
	set_viewport(&ui.tree, {220, 400})
	begin_view(&ui)
	column(&ui)
	column(&ui, height = 44, width = 220)
	squeezed := text(&ui, long)
	end(&ui)
	column(&ui, height = 300, width = 220)
	roomy := text(&ui, long)
	end(&ui)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {220, 400})
	sk := node_get(&ui.tree, squeezed).kind.(Text_Kind)
	sd := node_get(&ui.tree, squeezed).abs
	testing.expect(t, sd.h <= 44, "the node stays inside its box")
	testing.expect(t, len(sk.display) > 0 && strings.has_suffix(sk.display, "…"), "the shown text is trimmed with an ellipsis")
	testing.expect(t, utf8.rune_count_in_string(sk.display) < utf8.rune_count_in_string(long), "…and shorter than the source")
	lh := ui.tree.measure_text(&ui.tree, "x", sk.size, 0, .Regular, false, 0, false).y
	testing.expect(t, sd.h >= lh, "at least one line always shows")
	rk := node_get(&ui.tree, roomy).kind.(Text_Kind)
	testing.expect(t, len(rk.display) == 0, "a text with room is not trimmed")
	testing.expect(t, node_get(&ui.tree, roomy).abs.h > 3 * lh, "…and wraps to all its lines")
}

// Ligatures can be switched off per call: Inter turns "->" into one arrow
// glyph by default; with ligatures off the two characters stay two glyphs.
@(test)
text_ligatures_off_keeps_two_glyphs :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init: embedded fonts failed to load")
	defer text_engine_destroy(&te)
	on := text_lines(&te, "->", 15, 0)
	off := text_lines(&te, "->", 15, 0, no_liga = true)
	testing.expect(t, len(on) == 1 && len(off) == 1)
	testing.expect_value(t, len(on[0].glyphs), 1)
	testing.expect_value(t, len(off[0].glyphs), 2)
	testing.expect(t, off[0].width > on[0].width, "two glyphs are wider than the arrow")
}

} // when ODIN_TEST