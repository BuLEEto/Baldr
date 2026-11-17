package baldr

// Fallback fonts from the system: text in any script.
//
// The toolkit's own fonts are Inter and an emoji font, which leaves most of
// the world's writing as empty boxes. A character the requested fonts cannot
// draw is looked for in the fonts installed on the machine, as any desktop
// does.
//
// Looking reads what the scan already has (font_scan.odin): every installed
// face's OS/2 ulUnicodeRange bits, which say which Unicode blocks it means to
// cover (unicode_ranges.odin maps a codepoint to its bit). The faces that
// claim the block are ranked — by glyph count and blocks claimed, then the
// locale's variant for Han, regular weight and width, sans before serif — and
// the first whose cmap really has the character is loaded and kept. The
// ranking reads what the face is rather than family names, since a name list
// is only current on the machine it was written on. What was found is
// remembered per block, what was not per character, so a search runs once.
//
// A text needing a fallback is shaped with its own stack: the fonts it asked
// for, then only the fallbacks it needs. The shared stack never grows, so a
// line with no such characters is laid out unchanged, and a line with them
// keeps its fonts' height and baseline (the shaper takes a line's height from
// the tallest font in its stack).
//
// unicode_ranges.odin is generated from fontTools:
//
//	from fontTools.ttLib.tables import O_S_2f_2 as m
//	rows = sorted((lo, hi, bit, name) for bit, blocks in enumerate(m.OS2_UNICODE_RANGES)
//	              if bit != 57 for name, (lo, hi) in blocks)   # then drop any row overlapping the one before

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import runa "baldr:third_party/runa"

// FALLBACK_TRIES is how many faces claiming a block are loaded, at most,
// looking for one that has the character: the ranking puts the right one
// first, and a machine with hundreds of fonts must not load them all.
@(private)
FALLBACK_TRIES :: 8

// FALLBACK_PER_FAMILY is how many faces of one family may sit in a block's
// candidate list. The faces of a family cover the same characters, so a
// second is nearly always a wasted load, and one large collection must not
// take every try.
@(private)
FALLBACK_PER_FAMILY :: 2

// FALLBACK_BROAD_BLOCKS is how many Unicode blocks a face must claim to be
// tried for a block it does not claim (its OS/2 bits may simply be wrong).
// The common broad fallback faces all claim far more than this.
@(private)
FALLBACK_BROAD_BLOCKS :: 40

// FALLBACK_MISSING_MAX bounds the characters remembered as drawn by nothing,
// so garbage text cannot grow the memory without end.
@(private)
FALLBACK_MISSING_MAX :: 4096

// Fallback_State is what the engine has found and loaded.
@(private)
Fallback_State :: struct {
	loaded:  map[string]^runa.Font,        // by "path#face": a face is loaded once whatever block wanted it
	blobs:   [dynamic][]u8,                // the files behind them, which must outlive them
	by_bit:  map[u8]^runa.Font,            // the face a block's last character was found in: tried first for the next
	missing: map[rune]struct{},            // drawn by nothing on this machine
	fonts:   [dynamic]^runa.Font,          // every face loaded, to free
	ranked:  map[u8][dynamic]Font_Face_File, // a block's candidate faces, best first, ranked once (paths are the index's)
}

@(private)
fallback_destroy :: proc(te: ^Text_Engine) {
	fb := &te.fallback
	for f in fb.fonts {
		runa.font_destroy(f)
		free(f, te.allocator)
	}
	for b in fb.blobs do delete(b, te.allocator)
	for k in fb.loaded do delete(k, te.allocator)
	delete(fb.loaded)
	delete(fb.blobs)
	delete(fb.by_bit)
	delete(fb.missing)
	delete(fb.fonts)
	for _, list in fb.ranked do delete(list)
	delete(fb.ranked)
	fb^ = {}
}

// fallback_forget throws away what was found, with the scan it came from
// (fonts_forget): a font just installed is looked at next time.
@(private)
fallback_forget :: proc(te: ^Text_Engine) {
	clear(&te.fallback.by_bit)
	clear(&te.fallback.missing)
	for _, list in te.fallback.ranked do delete(list)
	clear(&te.fallback.ranked) // its paths were the scan's, which is gone
}

// unicode_range_bit is the OS/2 ulUnicodeRange bit of the block `r` is in,
// false for one the table does not name.
@(private)
unicode_range_bit :: proc(r: rune) -> (u8, bool) {
	lo, hi := 0, len(UNICODE_RANGES) - 1
	for lo <= hi {
		mid := (lo + hi) / 2
		e := UNICODE_RANGES[mid]
		switch {
		case r < e.lo: hi = mid - 1
		case r > e.hi: lo = mid + 1
		case:          return e.bit, true
		}
	}
	return 0, false
}

// fallback_skip is a character no fallback is looked for: one the shaper
// draws as nothing (joiners, variation selectors, direction marks), or one
// in a private use area, which means whatever an icon font says it means.
@(private)
fallback_skip :: proc(r: rune) -> bool {
	switch r {
	case 0x200B ..= 0x200F, 0x2028 ..= 0x202E, 0x2060 ..= 0x206F, 0xFE00 ..= 0xFE0F, 0xFEFF, 0xE0000 ..= 0xE0FFF: return true
	case 0xE000 ..= 0xF8FF, 0xF0000 ..= 0x10FFFF: return true
	}
	return false
}

// text_fallbacks is the fallback faces `s` needs beyond `stack`, in the
// order its characters first need them: nil for text the stack draws (all
// of it ASCII costs one pass over the bytes). The slice is the frame's temp
// memory; the faces are the engine's.
@(private)
text_fallbacks :: proc(te: ^Text_Engine, s: string, stack: []^runa.Font) -> []^runa.Font {
	ascii := true
	for i in 0 ..< len(s) do if s[i] >= 0x80 {
		ascii = false
		break
	}
	if ascii do return nil
	out: [dynamic]^runa.Font
	for r in s {
		if r < 0x80 || fallback_skip(r) do continue
		covered := false
		for f in stack do if runa.font_lookup_glyph(f, r) != 0 {
			covered = true
			break
		}
		if !covered do for f in out do if runa.font_lookup_glyph(f, r) != 0 {
			covered = true
			break
		}
		if covered do continue
		if f := fallback_for(te, r); f != nil {
			if out == nil do out = make([dynamic]^runa.Font, context.temp_allocator)
			append(&out, f)
		}
	}
	return out[:]
}

// fallback_for is the installed face that draws `r`, loading it the first
// time; nil when nothing on this machine does.
@(private)
fallback_for :: proc(te: ^Text_Engine, r: rune) -> ^runa.Font {
	fb := &te.fallback
	if _, gone := fb.missing[r]; gone do return nil
	bit, known := unicode_range_bit(r)
	if known {
		if f, had := fb.by_bit[bit]; had && f != nil && runa.font_lookup_glyph(f, r) != 0 do return f
	}
	list := fallback_ranked(te, bit if known else 255)
	tries := 0
	for file in list {
		f := fallback_load(te, file)
		if f == nil do continue
		if runa.font_lookup_glyph(f, r) != 0 {
			if known do fb.by_bit[bit] = f
			return f
		}
		tries += 1
		if tries >= FALLBACK_TRIES do break
	}
	if len(fb.missing) >= FALLBACK_MISSING_MAX do clear(&fb.missing)
	fb.missing[r] = {}
	return nil
}

// fallback_ranked is block `bit`'s candidate faces, best first, ranked
// the first time the block needs one (255: a block the table does not
// name). The installed faces that claim the block, then the broad faces
// most machines have, by their cmap, for a font whose bits are wrong.
@(private)
fallback_ranked :: proc(te: ^Text_Engine, bit: u8) -> []Font_Face_File {
	fb := &te.fallback
	if list, had := fb.ranked[bit]; had do return list[:]
	idx := font_index(te)
	Candidate :: struct { file: Font_Face_File, family: string, score: int }
	candidate_before :: proc(a, b: Candidate) -> bool {
		if a.score != b.score do return a.score > b.score
		if a.family != b.family do return a.family < b.family
		if a.file.path != b.file.path do return a.file.path < b.file.path
		return a.file.face < b.file.face
	}
	cands := make([dynamic]Candidate, context.temp_allocator)
	if bit != 255 {
		word, b := bit / 32, bit % 32
		for family, files in idx.families do for file in files {
			if file.italic || file.ranges[word] & (u32(1) << b) == 0 do continue
			append(&cands, Candidate{file, family, fallback_score(te, family, file, bit)})
		}
	}
	for family, files in idx.families do for file in files {
		if file.italic || !fallback_broad(file) do continue
		append(&cands, Candidate{file, family, fallback_score(te, family, file, bit) - 1000})
	}
	slice.sort_by(cands[:], candidate_before) // the same order every run, so a machine always picks the same face
	// At most FALLBACK_PER_FAMILY faces of any one family: otherwise a single
	// collection of symbol faces can fill every try. Breadth across families
	// is what finds a character.
	list := make([dynamic]Font_Face_File, 0, min(len(cands), 2 * FALLBACK_TRIES), te.allocator)
	taken := make(map[string]int, 2 * FALLBACK_TRIES, context.temp_allocator)
	for c in cands {
		if len(list) >= 2 * FALLBACK_TRIES do break // no more are ever tried
		if taken[c.family] >= FALLBACK_PER_FAMILY do continue
		taken[c.family] += 1
		append(&list, c.file)
	}
	fb.ranked[bit] = list
	return list[:]
}

// fallback_broad is a face that covers many scripts, worth trying by its
// cmap when no face claims the block (a font whose OS/2 bits are wrong).
// It asks the face how much it claims rather than matching family names, so
// it works on whatever fonts a platform ships.
@(private)
fallback_broad :: proc(file: Font_Face_File) -> bool {
	return blocks_claimed(file) >= FALLBACK_BROAD_BLOCKS
}

// blocks_claimed is how many Unicode blocks a face's OS/2 bits claim.
@(private)
blocks_claimed :: proc(file: Font_Face_File) -> (n: int) {
	for word in file.ranges do for b in 0 ..< u32(32) do if word & (1 << b) != 0 do n += 1
	return
}

// fallback_score ranks a face for block `bit`. What the face is decides the
// order — how many glyphs it really has and how many blocks it claims — and
// the family name is read only for what a name genuinely settles: the style
// of the face, and which Han shapes a locale wants. A glyph count separates a
// text face from a symbols face on any OS; a list of names does not.
@(private)
fallback_score :: proc(te: ^Text_Engine, family: string, file: Font_Face_File, bit: u8) -> (score: int) {
	// Size is the strongest evidence of a real text face rather than a few
	// symbols in the block. CJK asks for far more: a usable Japanese face
	// carries thousands of kanji, a kana-only or symbols face a few hundred
	// glyphs.
	if cjk_bit(bit) {
		score += min(file.glyphs / 500, 60)
	} else {
		score += min(file.glyphs / 100, 30)
	}
	// Breadth: a face claiming many blocks is built to be a fallback.
	score += min(blocks_claimed(file), 60) / 3

	low := strings.to_lower(family, context.temp_allocator)
	// Style, which a name does settle: prefer a plain upright sans.
	if strings.contains(low, "serif") do score -= 60
	if strings.contains(low, "mono") do score -= 40
	for word in ([]string{"condensed", "narrow", "display", "rounded", "slanted"}) do if strings.contains(low, word) do score -= 20
	if strings.has_suffix(low, " ui") do score += 5 // metrics made for interfaces
	// The locale's Han shapes: a name test, since a face declares them nowhere
	// readable. Small on purpose, a preference between faces that both work
	// that cannot lift an unusable face above a usable one.
	if cjk_bit(bit) && strings.has_suffix(low, cjk_variant(te)) do score += 15
	score -= abs(file.weight - 400) / 10
	if file.width > 0 do score -= abs(file.width - 5) * 10
	return
}

// cjk_bit is a block written with CJK faces: kana, Hangul, the ideographs
// and their punctuation and forms.
@(private)
cjk_bit :: proc(bit: u8) -> bool {
	switch bit {
	case 48 ..= 56, 59, 61, 65, 68: return true
	}
	return false
}

// cjk_variant is the Noto / Source Han suffix for the Han shapes the
// desktop's language uses: Japanese unless it says Korean or Chinese.
@(private)
cjk_variant :: proc(te: ^Text_Engine) -> string {
	lang := te.lang
	if lang == "" do lang = os.get_env("LANG", context.temp_allocator)
	switch {
	case strings.has_prefix(lang, "ko"):    return " kr"
	case strings.has_prefix(lang, "zh_TW"): return " tc"
	case strings.has_prefix(lang, "zh_HK"): return " hk"
	case strings.has_prefix(lang, "zh"):    return " sc"
	}
	return " jp"
}

// fallback_load loads a face once, whatever block asked for it.
@(private)
fallback_load :: proc(te: ^Text_Engine, file: Font_Face_File) -> ^runa.Font {
	fb := &te.fallback
	key := fmt.tprintf("%s#%d", file.path, file.face)
	if f, had := fb.loaded[key]; had do return f
	blob, f := font_file_load(te, file)
	fb.loaded[strings.clone(key, te.allocator)] = f // a face that failed is not read again
	if f == nil do return nil
	append(&fb.blobs, blob)
	append(&fb.fonts, f)
	return f
}
