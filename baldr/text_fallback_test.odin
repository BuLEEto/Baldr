package baldr

@(require) import "core:fmt"
@(require) import "core:log"
@(require) import "core:os"
@(require) import "core:strings"
@(require) import "core:testing"
@(require) import "core:time"
@(require) import runa "baldr:third_party/runa"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Text in every script, drawn from the system's fonts where the toolkit's
// own have no glyph. These read the fonts installed on the machine running
// them; a script no installed font covers is skipped, not failed.


@(test)
a_codepoint_finds_its_unicode_range :: proc(t: ^testing.T) {
	cases := [?]struct { r: rune, bit: u8 }{
		{'A', 0}, {'é', 1}, {'א', 11}, {'ع', 13}, {'क', 15}, {'ก', 24},
		{'あ', 49}, {'カ', 50}, {'한', 56}, {'日', 59}, {'Ж', 9},
	}
	for c in cases {
		bit, ok := unicode_range_bit(c.r)
		testing.expectf(t, ok && bit == c.bit, "%c (U+%04X): bit %d, want %d", c.r, c.r, bit, c.bit)
	}
}

// each glyph drawn by some font, not the missing-glyph box, and the line as
// tall as a line of Latin text in the same stack
@(private = "file")
drawn :: proc(t: ^testing.T, te: ^Text_Engine, s: string, script: string) -> (fell_back: bool) {
	lines := text_lines(te, s, 14, 0)
	if len(lines) == 0 do return
	boxes := 0
	for g in lines[0].glyphs do if g.glyph_id == 0 do boxes += 1
	if boxes > 0 {
		log.infof("%s: no installed font draws it here (%d of %d glyphs missing): skipped", script, boxes, len(lines[0].glyphs))
		return
	}
	for g in lines[0].glyphs do if g.font != te.fonts[.UI] do fell_back = true
	testing.expectf(t, fell_back, "%s drawn by a face from the system", script)
	latin := text_lines(te, "Latin", 14, 0)
	if len(latin) > 0 do testing.expectf(t, lines[0].height == latin[0].height && lines[0].baseline == latin[0].baseline,
		"%s keeps the line's height and baseline: %v/%v, Latin %v/%v", script, lines[0].height, lines[0].baseline, latin[0].height, latin[0].baseline)
	return
}

@(test)
text_in_other_scripts_is_drawn_from_the_systems_fonts :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)
	te.lang = strings.clone("en_GB", te.allocator)

	text_lines(&te, "Plain ASCII, as most text is", 14, 0)
	testing.expect(t, !te.font_index.built, "ASCII text looks for nothing: no scan")

	start := time.tick_now()
	drawn(t, &te, "日本語のファイル名.txt", "Japanese")
	log.infof("first CJK text, scan and load included: %.0f ms", time.duration_milliseconds(time.tick_since(start)))
	drawn(t, &te, "שלום עולם", "Hebrew")
	drawn(t, &te, "مرحبا بالعالم", "Arabic")
	drawn(t, &te, "नमस्ते दुनिया", "Devanagari")
	drawn(t, &te, "สวัสดีชาวโลก", "Thai")
	drawn(t, &te, "안녕하세요", "Korean")
	loaded := len(te.fallback.fonts)
	drawn(t, &te, "日本語", "Japanese again")
	testing.expect_value(t, len(te.fallback.fonts), loaded) // found once, kept
	for f in te.fallback.fonts do testing.expect(t, f != te.fonts[.UI], "loaded faces are the system's")
}

// A face from a collection (.ttc) is made a font of its own, which the
// shaper loads: every table where the directory says it is.
@(test)
a_collections_face_is_made_a_font_of_its_own :: proc(t: ^testing.T) {
	path := "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		log.infof("no %s here: skipped", path)
		return
	}
	defer delete(data)
	faces := int(be32(data, 8))
	testing.expect(t, faces > 1, "a collection")
	for i in 0 ..< min(faces, 3) {
		face, copied, ok := sfnt_face_extract(data, i)
		testing.expect(t, ok && copied, "extracted")
		if !ok do continue
		f, ferr := runa.font_load(face)
		testing.expectf(t, ferr == .None, "face %d loads: %v", i, ferr)
		if ferr == .None {
			testing.expect(t, runa.font_lookup_glyph(&f, '日') != 0, fmt.tprintf("face %d draws 日", i))
			runa.font_destroy(&f)
		}
		delete(face)
	}
}

// The Han characters take the desktop language's shapes: of a CJK family's
// variants, the Simplified Chinese one ranks first on a Chinese desktop, the
// Korean on a Korean, else the Japanese.
@(test)
han_takes_the_locales_shapes :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)
	file := Font_Face_File{weight = 400, width = 5}
	for c in ([]struct { lang, want: string }{{"zh_CN.UTF-8", "SC"}, {"zh_TW.UTF-8", "TC"}, {"ko_KR.UTF-8", "KR"}, {"en_GB.UTF-8", "JP"}, {"ja_JP.UTF-8", "JP"}}) {
		delete(te.lang, te.allocator)
		te.lang = strings.clone(c.lang, te.allocator)
		best, best_score := "", min(int)
		for v in ([]string{"JP", "KR", "SC", "TC", "HK"}) {
			sc := fallback_score(&te, fmt.tprintf("Noto Sans CJK %s", v), file, 59)
			if sc > best_score do best, best_score = v, sc
		}
		testing.expectf(t, best == c.want, "%s: %s ranks first, want %s", c.lang, best, c.want)
	}
}

// Every glyph of a CJK text is drawn, with ink, whichever face is picked.
// The common CJK faces are CID-keyed CFF, whose glyphs draw only when runa
// picks each glyph's subroutines from its own Font DICT (FDArray/FDSelect).
@(test)
cjk_text_is_drawn_with_ink :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)
	for s in ([]string{"日本語のファイル名", "안녕하세요", "混ざった文"}) {
		lines := text_lines(&te, s, 14, 0)
		if len(lines) == 0 do continue
		blank := 0
		for g in lines[0].glyphs {
			if g.glyph_id == 0 {
				blank += 1
				continue
			}
			slot, err := runa.raster_glyph(g.font, g.glyph_id, 28, 0, &te.atlas, te.allocator)
			if err != .None || slot.px_size.x == 0 || slot.px_size.y == 0 do blank += 1
		}
		if blank == len(lines[0].glyphs) {
			log.infof("%s: nothing installed draws it here: skipped", s)
			continue
		}
		testing.expectf(t, blank == 0, "%s: every glyph drawn with ink, %d of %d blank", s, blank, len(lines[0].glyphs))
	}
}

} // when ODIN_TEST