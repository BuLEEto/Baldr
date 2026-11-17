package baldr

// How the fallback ranks faces (text_fallback.odin). These build the index
// by hand rather than reading the machine's fonts, so they assert the
// ranking itself and say the same thing on every OS, though the font sets
// they model are macOS's.

@(require) import "core:strings"
@(require) import "core:testing"

when ODIN_TEST || #config(BALDR_TESTS, false) {

CJK_IDEOGRAPHS :: u8(59) // OS/2 bit for CJK Unified Ideographs

// claims returns ranges with `bits` set, as a face's OS/2 words would be.
@(private = "file")
claims :: proc(bits: ..u8) -> (r: [4]u32) {
	for b in bits do r[b / 32] |= u32(1) << (b % 32)
	return
}

// spread returns ranges claiming `n` blocks, for the breadth tests.
@(private = "file")
spread :: proc(n: int) -> (r: [4]u32) {
	for i in 0 ..< n do r[i / 32] |= u32(1) << u32(i % 32)
	return
}

@(private = "file")
rank_engine :: proc() -> Text_Engine {
	te: Text_Engine
	te.lang = "ja_JP"
	return te
}

// A face's size decides, not its name. macOS ships `.CJK Symbols Fallback`,
// a punctuation face that claims the ideograph block and holds a few hundred
// glyphs; scored by name, it would outrank every face that can draw a kanji.
@(test)
a_symbols_face_never_outranks_a_text_face :: proc(t: ^testing.T) {
	te := rank_engine()
	cjk := claims(CJK_IDEOGRAPHS)
	symbols := Font_Face_File{glyphs = 400, weight = 542, ranges = cjk}
	text := Font_Face_File{glyphs = 20_000, weight = 400, ranges = cjk}

	// macOS's own pairing, names and all
	sym_score := fallback_score(&te, ".CJK Symbols Fallback JA", symbols, CJK_IDEOGRAPHS)
	txt_score := fallback_score(&te, "Hiragino Sans", text, CJK_IDEOGRAPHS)
	testing.expectf(t, txt_score > sym_score,
		"a 20k-glyph text face must beat a 400-glyph symbols face: %d vs %d", txt_score, sym_score)

	// and the name must not be what decides it: swap them over and the
	// 20k-glyph face still wins, even called the symbols one.
	a := fallback_score(&te, ".CJK Symbols Fallback JA", text, CJK_IDEOGRAPHS)
	b := fallback_score(&te, "Hiragino Sans", symbols, CJK_IDEOGRAPHS)
	testing.expectf(t, a > b, "the glyph count decides, not the family name: %d vs %d", a, b)
}

// The locale's Han shapes are a preference between faces that both work, so
// it must never lift an unusable face above a usable one.
@(test)
the_han_variant_cannot_beat_real_coverage :: proc(t: ^testing.T) {
	te := rank_engine()
	cjk := claims(CJK_IDEOGRAPHS)
	tiny_ja := Font_Face_File{glyphs = 300, weight = 400, ranges = cjk}  // named for the locale, no kanji
	big_other := Font_Face_File{glyphs = 18_000, weight = 400, ranges = cjk}
	ja := fallback_score(&te, "Noto Sans CJK JP", tiny_ja, CJK_IDEOGRAPHS)
	other := fallback_score(&te, "Noto Sans CJK SC", big_other, CJK_IDEOGRAPHS)
	testing.expectf(t, other > ja, "coverage before the locale's shapes: %d vs %d", other, ja)
}

// Breadth is read off the face, not off a list of family names.
@(test)
a_broad_face_is_recognised_by_what_it_claims :: proc(t: ^testing.T) {
	testing.expect_value(t, blocks_claimed(Font_Face_File{ranges = claims(0, 1, 59)}), 3)
	testing.expect_value(t, blocks_claimed(Font_Face_File{ranges = spread(70)}), 70)
	testing.expect(t, fallback_broad(Font_Face_File{ranges = spread(FALLBACK_BROAD_BLOCKS)}), "claims enough blocks")
	testing.expect(t, !fallback_broad(Font_Face_File{ranges = spread(FALLBACK_BROAD_BLOCKS - 1)}), "one short")
	testing.expect(t, !fallback_broad(Font_Face_File{ranges = claims(CJK_IDEOGRAPHS)}), "a single-block face is not broad")
}

// One collection must not take the whole budget: `CJKSymbolsFallback.ttc`
// holds ten faces, and all ten at the top of the list would spend
// `FALLBACK_TRIES` before a face that can draw Japanese was loaded.
@(test)
one_family_cannot_fill_the_candidate_list :: proc(t: ^testing.T) {
	te := rank_engine()
	defer fallback_destroy(&te)
	te.font_index.allocator = context.allocator
	te.font_index.families = make(map[string][dynamic]Font_Face_File)
	defer {
		for _, files in te.font_index.families do delete(files)
		delete(te.font_index.families)
	}
	cjk := claims(CJK_IDEOGRAPHS)
	add :: proc(idx: ^Font_Index, family: string, n: int, glyphs: int, ranges: [4]u32) {
		files := make([dynamic]Font_Face_File)
		for i in 0 ..< n do append(&files, Font_Face_File{path = "x.ttc", face = i, glyphs = glyphs, weight = 400, ranges = ranges})
		idx.families[family] = files
	}
	// ten faces of one symbols collection, as macOS has, and two ordinary
	// text families besides
	add(&te.font_index, ".CJK Symbols Fallback", 10, 400, cjk)
	add(&te.font_index, "Arial Unicode MS", 1, 50_000, cjk)
	add(&te.font_index, "Songti SC", 1, 25_000, cjk)
	te.font_index.built = true

	list := fallback_ranked(&te, CJK_IDEOGRAPHS)
	testing.expect(t, len(list) > 0, "candidates")

	// no family may hold more than its share
	per := make(map[string]int, context.temp_allocator)
	for file in list {
		for family, files in te.font_index.families do for f in files {
			if f.path == file.path && f.face == file.face && f.glyphs == file.glyphs do per[family] += 1
		}
	}
	for family, n in per {
		testing.expectf(t, n <= FALLBACK_PER_FAMILY, "%q took %d of the list, cap is %d", family, n, FALLBACK_PER_FAMILY)
	}

	// and the faces that can actually draw a kanji are inside the budget
	found := 0
	for file, i in list {
		if i >= FALLBACK_TRIES do break
		if file.glyphs >= 25_000 do found += 1
	}
	testing.expectf(t, found >= 2, "both text faces must be tried within the first %d, found %d", FALLBACK_TRIES, found)
}

}
