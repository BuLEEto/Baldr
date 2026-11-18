package baldr

// Text: measurement, shaping, and glyph rasterisation through runa.
//
// One Text_Engine per app owns the embedded fonts (Inter Variable for UI
// text, Twemoji for colour emoji), runa's shape cache, the glyph atlas
// (alpha pages for mono glyphs, RGBA pages for colour), the rasterised-glyph
// cache, a small cache of laid-out lines, and the GPU page handles the
// renderer hands back (render.odin). Install it on a Tree with
// tree_use_text_engine; layout then measures through runa and render_prepare
// draws through the same laid-out lines.
//
// Consistency rule: measurement and rendering both go through text_lines with
// the same (string, size, wrap width) and the same Paragraph_Opts, so a
// Text node is drawn with exactly the line breaks it was measured with.
// Sizes are logical px per em (CSS font-size); device scaling happens only
// in render_prepare.
//
// Fonts are #load'ed: no file IO at runtime. runa's Cache and Atlas are
// single-threaded; the engine must only be touched from the UI thread.

import "base:runtime"
import "core:math"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import runa "baldr:third_party/runa"

// Font_Slot indexes the embedded font stack, in fallback order: the first
// font whose cmap covers a codepoint shapes it.
Font_Slot :: enum u8 {
	UI,     // UI text, regular weight: Latin, Greek, Cyrillic. Defines line height and ascent.
	Bold,   // the same UI font at semibold (variable wght axis), for headline/title roles.
	Italic, // the UI face's italic companion (rich text)
	Bold_Italic,
	Medium, // the UI font at medium (variable wght axis): labels a design sets in 500
	Medium_Italic,
	Mono,   // JetBrains Mono: code (the code editor, `mono` text). Its own line height.
	Emoji,  // Twemoji Mozilla: COLRv0 colour emoji.
}

// BALDR_ITALIC_FONT is the italic companion of the UI typeface.
BALDR_ITALIC_FONT :: #config(BALDR_ITALIC_FONT, "../assets/fonts/InterVariable-Italic.ttf")

// BALDR_MONO_FONT is the monospace typeface, embedded like the UI one.
BALDR_MONO_FONT :: #config(BALDR_MONO_FONT, "../assets/fonts/JetBrainsMono-Variable.ttf")

// BALDR_UI_FONT is the UI typeface, a variable TTF with a wght axis, embedded
// at compile time. Override with -define:BALDR_UI_FONT=<path relative to
// baldr/text.odin> to try another face (see examples/02_theme_lab).
BALDR_UI_FONT :: #config(BALDR_UI_FONT, "../assets/fonts/InterVariable.ttf")

// BOLD_WEIGHT is the wght value used for the Bold slots (Semibold).
BOLD_WEIGHT :: #config(BALDR_BOLD_WEIGHT, 600)

// MEDIUM_WEIGHT is the wght value used for the Medium slots.
MEDIUM_WEIGHT :: #config(BALDR_MEDIUM_WEIGHT, 500)

// Font_File is an embedded font file; several slots share one (the UI
// typeface at three weights).
@(private)
Font_File :: enum u8 { UI, Italic, Mono, Emoji }

// FONT_FILES is the embedded font files, read-only.
@(rodata, private)
FONT_FILES := [Font_File][]u8{
	.UI     = #load(BALDR_UI_FONT),
	.Italic = #load(BALDR_ITALIC_FONT),
	.Mono   = #load(BALDR_MONO_FONT),
	.Emoji  = #load("../assets/fonts/Twemoji-Mozilla.ttf"),
}

// ATLAS_PAGE_SIZE is the side of every atlas page in device px. Alpha pages
// are 1 MB, RGBA pages 4 MB; a page holds ~2000 body-size glyphs at 2×.
ATLAS_PAGE_SIZE :: 1024

// MAX_GLYPH_PX is the largest device px-per-em that is rasterised into the
// atlas. Larger text lays out and measures normally but emits no glyphs.
MAX_GLYPH_PX :: 512

// MAX_TEXT_SIZE is the largest logical font size that is measured or laid
// out; beyond it text measures as zero and draws nothing.
MAX_TEXT_SIZE :: 4096

// LINES_CACHE_MAX is the soft cap of cached laid-out paragraphs. Past it the
// least-recently-used half is evicted. A rebuild walking a long view in
// order looks like LRU's worst case, but widgets such as `markdown_view`
// keep their own per-block caches, so unchanged text never reaches
// `text_lines` and a bigger cap buys nothing. A slow first layout of a long
// view is answered by `list` with `estimated_height`, not by this cap.
LINES_CACHE_MAX :: 256

// Text_Engine is everything text needs at runtime. See the file comment.
// Zero value is not usable: call text_engine_init and check its result.
Text_Engine :: struct {
	allocator: runtime.Allocator,
	fonts:     [Font_Slot]^runa.Font,       // heap-allocated so the engine may be moved
	stack:     [2]^runa.Font,               // regular fallback order: UI, Emoji
	stack_bold: [2]^runa.Font,              // bold fallback order: Bold, Emoji
	stack_mono: [3]^runa.Font,              // code: Mono, then UI, Emoji
	stack_italic: [2]^runa.Font,            // italic, Emoji
	stack_bold_italic: [2]^runa.Font,       // bold italic, Emoji
	stack_medium: [2]^runa.Font,            // medium: Medium, Emoji
	stack_medium_italic: [2]^runa.Font,     // medium italic, Emoji
	cache:     runa.Cache,                  // shaped runs keyed by (font, size, text)
	icons:     map[Icon_Key]Glyph_Entry,    // rasterised icons by (icon, device px)
	shaped:    int,                         // paragraphs shaped since the last frame report (a cache miss each)
	icons_made: int,                        // icons rasterised since the last frame report
	icon_ms:   f64,                         // …and the time they took
	flush_ms:  f64,                         // atlas uploads since the last frame report
	images:    map[Image_Key]Glyph_Entry,   // uploaded pictures by (identity, version)
	theme_icons: map[string]Theme_Icon_Entry, // icon theme icons by name, directory and device px (theme_icon.odin)
	theme_icon_families: map[string]Theme_Icon_Family, // each icon's sizes loaded (name, directory): drawn while another size loads
	theme_icon_stale:    map[string]Theme_Icon_Family, // the same from before the icon theme last changed: drawn until the new one answers
	font_index: Font_Index,                 // the families this machine has, once looked for (font_scan.odin)
	font_scanner: Font_Scanner,             // …read from the cache and built on a worker, in an app (font_cache.odin)
	families:   [dynamic]Font_Family,       // …and the ones an app asked to draw in (font_family.odin)
	family_ids: map[string]Family_Id,       // family name, folded → id (1-based into `families`)
	face_ids:   map[rawptr]u16,             // every face drawn with, numbered for the glyph cache
	// What Family_Id 0 — "the theme's own text" — is set in: the families
	// the theme names, or 0 for the embedded faces. The names are kept as
	// asked, so one not found yet is looked for again when the font list
	// arrives; they are the engine's to free.
	ui_family:   Family_Id,
	mono_family: Family_Id,
	ui_name:     string,
	mono_name:   string,
	// The same for each step of the type scale that names a family of its
	// own (Text_Style.family): what draws (0: as Family_Id 0 does)
	// and the name asked for.
	role_family: [Text_Role]Family_Id,
	role_names:  [Text_Role]string,
	typeset_faces: map[Typeset_Face_Key]Typeset_Face, // faces text in pictures is set in, by family, weight and slant (typeset.odin)
	typeset_blobs: map[string][]u8,         // …and the bytes behind them, by file and face, read once
	typeset_retired: [dynamic]^runa.Font,   // faces forgotten while Typesets may still point at them (typeset_faces_refresh)
	icon_loader: Icon_Loader,               // finds and decodes them off the UI thread
	image_atlas: runa.Atlas,                // pictures, apart from glyphs so a full one can start over
	image_pages: [dynamic]Page_State,       // GPU handle per picture page
	next_image_id: u64,
	fallback:  Fallback_State,              // faces from the system for what the toolkit's fonts cannot draw (text_fallback.odin)
	lang:      string,                      // the desktop's locale ("ja_JP"): which Han shapes a fallback prefers; owned
	image_frame_px: int,                    // picture pixels drawn this frame (and the last), to tell a full atlas from a busy screen
	images_full: bool,                      // the picture atlas passed its page budget or refused a picture: start over next frame
	picture_said: bool,                     // a picture that stopped adding up has been reported once (render.odin)
	pictures:  map[u64]Picture_Page,        // pictures with a texture of their own, by identity (render.odin)
	picture_budget: int,                    // bytes of those not drawn lately kept before the oldest go (PICTURE_IDLE_BYTES)
	atlas:     runa.Atlas,                  // rasterised glyph bitmaps, alpha + colour pages
	cell_shapes: map[Cell_Shape_Key]Glyph_Entry, // a terminal's box drawing, blocks and braille, by character and cell size (terminal_glyphs.odin)
	mono_bold: ^runa.Font,                  // the monospace face at the bold weight, for a terminal (terminal_draw.odin)
	glyphs:    map[Glyph_Key]Glyph_Entry,   // (font, glyph, device size, subpixel) -> atlas slot
	lines:     map[Lines_Key]Lines_Entry,   // (string, size, wrap width) -> laid-out lines
	tick:      u64,                         // LRU clock for `lines`
	pages:     [runa.Atlas_Format][dynamic]Page_State, // GPU handle per runa page, by format
	next_page: u32,                         // headless page-id counter (no sink)
	ok:        bool,
}

// Glyph_Key identifies one rasterised bitmap. `size_q` is device px × 4:
// quarter-pixel size buckets keep fractional scales from exploding the cache
// while staying visually exact; `subpx` is the quarter-pixel x offset (0..3).
@(private)
Glyph_Key :: struct {
	font:   u16, // face_id: the embedded slots first, then a family's faces
	subpx:  u8,
	gid:    runa.Glyph_ID,
	size_q: u32,
}

// Icon_Key identifies a rasterised icon: which one, at how many device px.
@(private)
Icon_Key :: struct {
	icon: Icon,
	px:   u16,
}

// Image_Key identifies an uploaded picture: which one, at which version.
@(private)
Image_Key :: struct {
	id:      u64,
	version: u64,
}

// Glyph_Entry is a cached raster result. `ok` is false for glyphs that draw
// nothing (spaces, empty outlines, raster or atlas failures) so they are not
// retried every frame.
@(private)
Glyph_Entry :: struct {
	slot: runa.Atlas_Slot,
	ok:   bool,
}

// Lines_Key is the paragraph cache key. `str` is a clone owned by the engine
// once stored; lookups borrow the caller's string.
@(private)
Lines_Key :: struct {
	str:    string,
	size:   f32,
	wrap_w: f32,
	weight: Font_Weight,
	mono:   bool,
	italic: bool,
	no_liga: bool, // ligatures off (code)
	tabular: bool, // figures of one width (tnum)
	tab:    u8,   // mono: cells per tab stop
	family: Family_Id, // 0: the theme's own fonts
}

@(private)
Lines_Entry :: struct {
	lines: []runa.Line, // allocated with Text_Engine.allocator
	used:  u64,
}

// text_engine_init loads the embedded fonts and prepares the caches and
// atlas. Everything is allocated with `allocator`. Returns false (and leaves
// the engine safely destroyable) if a font fails to parse — which cannot
// happen with the shipped assets but is handled rather than asserted.
text_engine_init :: proc(te: ^Text_Engine, allocator := context.allocator) -> bool {
	te^ = {}
	te.allocator = allocator
	for slot in Font_Slot {
		loaded, err := runa.font_load(font_data(slot), allocator)
		if err != .None {
			text_engine_destroy(te)
			return false
		}
		f := new(runa.Font, allocator)
		f^ = loaded
		wght := runa.Axis_Tag(u32('w') << 24 | u32('g') << 16 | u32('h') << 8 | u32('t'))
		#partial switch slot { // best effort: a font without a wght axis just stays regular
		case .Bold, .Bold_Italic:     _ = runa.font_set_variation(f, wght, f32(BOLD_WEIGHT))
		case .Medium, .Medium_Italic: _ = runa.font_set_variation(f, wght, f32(MEDIUM_WEIGHT))
		}
		te.fonts[slot] = f
	}
	te.stack = {te.fonts[.UI], te.fonts[.Emoji]}
	te.stack_bold = {te.fonts[.Bold], te.fonts[.Emoji]}
	te.stack_mono = {te.fonts[.Mono], te.fonts[.UI], te.fonts[.Emoji]}
	te.stack_italic = {te.fonts[.Italic], te.fonts[.Emoji]}
	te.stack_bold_italic = {te.fonts[.Bold_Italic], te.fonts[.Emoji]}
	te.stack_medium = {te.fonts[.Medium], te.fonts[.Emoji]}
	te.stack_medium_italic = {te.fonts[.Medium_Italic], te.fonts[.Emoji]}
	te.families = make([dynamic]Font_Family, allocator)
	te.family_ids = make(map[string]Family_Id, allocator)
	te.face_ids = make(map[rawptr]u16, allocator)
	te.typeset_faces = make(map[Typeset_Face_Key]Typeset_Face, allocator)
	te.typeset_blobs = make(map[string][]u8, allocator)
	for slot in Font_Slot do face_id(te, te.fonts[slot]) // the embedded faces first, so their glyph keys never move
	te.cache  = runa.cache_make(allocator)
	te.icons  = make(map[Icon_Key]Glyph_Entry, allocator)
	te.images = make(map[Image_Key]Glyph_Entry, allocator)
	te.pictures = make(map[u64]Picture_Page, allocator)
	te.picture_budget = PICTURE_IDLE_BYTES
	te.theme_icons = make(map[string]Theme_Icon_Entry, allocator)
	te.theme_icon_families = make(map[string]Theme_Icon_Family, allocator)
	te.theme_icon_stale = make(map[string]Theme_Icon_Family, allocator)
	icon_loader_init(&te.icon_loader, allocator)
	te.atlas  = runa.atlas_make(ATLAS_PAGE_SIZE, ATLAS_PAGE_SIZE, allocator)
	te.image_atlas = runa.atlas_make(ATLAS_PAGE_SIZE, ATLAS_PAGE_SIZE, allocator)
	te.image_pages = make([dynamic]Page_State, allocator)
	te.glyphs = make(map[Glyph_Key]Glyph_Entry, allocator)
	te.cell_shapes = make(map[Cell_Shape_Key]Glyph_Entry, allocator)
	te.lines  = make(map[Lines_Key]Lines_Entry, allocator)
	for &p in te.pages do p = make([dynamic]Page_State, allocator)
	te.ok = true
	return true
}

// text_engine_destroy frees everything the engine owns. GPU pages created
// through an Atlas_Sink are the renderer's to destroy. Safe on a
// partially-initialised engine.
text_engine_destroy :: proc(te: ^Text_Engine) {
	font_scanner_stop(te) // first: its worker stops before the index goes
	font_index_destroy(&te.font_index)
	families_destroy(te)
	typeset_faces_destroy(te)
	fallback_destroy(te)
	delete(te.ui_name, te.allocator)
	delete(te.mono_name, te.allocator)
	for name in te.role_names do delete(name, te.allocator)
	delete(te.lang, te.allocator)
	icon_loader_destroy(&te.icon_loader) // first: its thread stops before anything goes
	for k in te.theme_icons do delete(k, te.allocator)
	delete(te.theme_icons)
	theme_icon_families_clear(te, &te.theme_icon_families)
	theme_icon_families_clear(te, &te.theme_icon_stale)
	delete(te.theme_icon_families)
	delete(te.theme_icon_stale)
	for k, &e in te.lines {
		lines_free(te, e.lines)
		delete(k.str, te.allocator)
	}
	delete(te.lines)
	delete(te.glyphs)
	delete(te.cell_shapes)
	if te.mono_bold != nil {
		runa.font_destroy(te.mono_bold)
		free(te.mono_bold, te.allocator)
	}
	for &p in te.pages do delete(p)
	runa.cache_destroy(&te.cache)
	delete(te.icons)
	delete(te.images)
	delete(te.pictures)
	runa.atlas_destroy(&te.atlas)
	runa.atlas_destroy(&te.image_atlas)
	delete(te.image_pages)
	for slot in Font_Slot {
		if f := te.fonts[slot]; f != nil {
			runa.font_destroy(f)
			free(f, te.allocator)
		}
	}
	te^ = {}
}

// tree_use_text_engine makes `t` measure text through `te` (and lets
// render_prepare draw it). Passing nil, or an engine that failed to init,
// reverts to the headless mono measurer. Layout is invalidated either way,
// and the families the tree's theme names are looked for.
tree_use_text_engine :: proc(t: ^Tree, te: ^Text_Engine) {
	if te != nil && te.ok {
		t.text = te
		t.measure_text = text_measure
	} else {
		t.text = nil
		t.measure_text = measure_text_mono
	}
	mark_layout_dirty(t, t.root)
	tree_fonts_follow(t) // a theme set before the engine arrived still names its family
}

// text_measure is the Text_Measure installed by tree_use_text_engine: the
// width and total height, in logical px, of `s` at `size`, wrapping at
// `max_w` when it is > 0. Height is lines × text_line_height; "" is one
// line. Falls back to the mono measurer when the tree has no engine.
text_measure :: proc(t: ^Tree, s: string, size: f32, max_w: f32, weight: Font_Weight, mono: bool = false, family: Family_Id = 0, tabular: bool = false) -> [2]f32 {
	return text_measure_as(t, s, size, max_w, weight, mono, family, tabular)
}

// text_measure_as is text_measure with the italic face as an option, which
// the Text_Measure hook does not carry.
@(private)
text_measure_as :: proc(t: ^Tree, s: string, size: f32, max_w: f32, weight: Font_Weight, mono: bool = false, family: Family_Id = 0, tabular: bool = false, italic := false) -> [2]f32 {
	te := t.text
	if te == nil || !te.ok do return measure_text_mono(t, s, size, max_w, weight, mono, family, tabular)
	if !text_size_ok(size) do return {0, 0}
	lh := text_line_height(te, size, mono, family)
	if len(s) == 0 do return {0, lh}
	lines := text_lines(te, s, size, max(max_w, 0), weight, mono, italic = italic, family = family, tabular = tabular)
	w: f32
	for l in lines do w = max(w, l.width)
	return {w, f32(max(len(lines), 1)) * lh}
}

// text_line_height is the distance between baselines at `size`, from
// the UI font's hhea metrics (ascent − descent + line gap, scaled by
// size / upem) — the mono font's for code (`mono`), and the family's own
// where one is drawing (`family`, or the one the theme names: a taller
// face gets taller rows rather than clipped ones). Used for measurement
// and for placing every line, whatever fallback fonts a line contains.
text_line_height :: proc(te: ^Text_Engine, size: f32, mono := false, family: Family_Id = 0) -> f32 {
	fam := family_now(te, family, mono)
	f := te.fonts[.Mono] if mono else te.fonts[.UI]
	if ff := family_font(te, fam); ff != nil do f = ff
	if f == nil || f.units_per_em == 0 do return size * 1.25
	return (f.ascent - f.descent + f.line_gap) * size / f32(f.units_per_em)
}

// text_ascent is the baseline's distance below the top of a line at `size`,
// from the UI font's metrics (the mono font's for code, the family's own
// where one is drawing).
text_ascent :: proc(te: ^Text_Engine, size: f32, mono := false, family: Family_Id = 0) -> f32 {
	fam := family_now(te, family, mono)
	f := te.fonts[.Mono] if mono else te.fonts[.UI]
	if ff := family_font(te, fam); ff != nil do f = ff
	if f == nil || f.units_per_em == 0 do return size
	return f.ascent * size / f32(f.units_per_em)
}

// text_advance is the width of one cell of the mono font at `size` (the
// advance of "0"); the code editor lays its gutter and tab stops on it.
text_advance :: proc(te: ^Text_Engine, size: f32, family: Family_Id = 0) -> f32 {
	if te == nil || !te.ok do return size * 0.5
	return prefix_width(te, "0", size, mono = true, family = family)
}

// text_size_ok rejects sizes that cannot be laid out: non-positive, NaN,
// infinite, or absurd.
@(private)
text_size_ok :: proc "contextless" (size: f32) -> bool {
	return size > 0 && size <= MAX_TEXT_SIZE
}

@(private)
font_data :: proc "contextless" (slot: Font_Slot) -> []u8 {
	switch slot {
	case .UI, .Medium, .Bold:                   return FONT_FILES[.UI]
	case .Italic, .Medium_Italic, .Bold_Italic: return FONT_FILES[.Italic]
	case .Mono:                                 return FONT_FILES[.Mono]
	case .Emoji:                                return FONT_FILES[.Emoji]
	}
	return nil
}

@(private)
font_slot_of :: proc(te: ^Text_Engine, f: ^runa.Font) -> (Font_Slot, bool) {
	for slot in Font_Slot do if te.fonts[slot] == f do return slot, true
	return .UI, false
}

// tabular_figures asks the face for figures of one width (OpenType `tnum`).
// A variable rather than a constant because it needs an address to slice,
// as runa's NO_LIGATURES does. A face without the feature ignores it. A
// name that is not four bytes gives tag 0 with no error, so a test asserts
// the four bytes.
@(private)
tabular_figures := [1]runa.Feature_Setting{runa.feature("tnum")}

// text_opts is the one place Paragraph_Opts are built, so measurement and
// rendering cannot drift apart.
@(private)
text_opts :: proc(te: ^Text_Engine, size, wrap_w: f32, weight := Font_Weight.Regular, mono := false, italic := false, no_liga := false, family: Family_Id = 0, tabular := false) -> runa.Paragraph_Opts {
	fam := family_now(te, family, mono) // 0: the family the theme's text is set in, if it names one
	stack := te.stack[:]
	switch {
	case mono:   stack = te.stack_mono[:]
	case italic: stack = te.stack_bold_italic[:] if weight == .Semibold else te.stack_medium_italic[:] if weight == .Medium else te.stack_italic[:]
	case:        stack = te.stack_bold[:] if weight == .Semibold else te.stack_medium[:] if weight == .Medium else te.stack[:]
	}
	if fs := family_stack(te, fam, weight, italic); fs != nil do stack = fs // the family asked for (or the theme's), the toolkit's fonts behind it
	opts := runa.Paragraph_Opts{fonts = runa.Font_Stack(stack), size = size, direction = .Auto, align = .Start, max_width = wrap_w}
	// One or the other: code turns ligatures off, and no code face has
	// proportional figures to correct.
	switch {
	case no_liga: opts.features = runa.NO_LIGATURES[:] // code: "->" stays two glyphs
	case tabular: opts.features = tabular_figures[:]   // a number that changes keeps its width
	}
	return opts
}

// text_lines returns the laid-out lines of `s` at `size`, wrapped at `wrap_w`
// (0 = unwrapped), from the paragraph cache or freshly through runa. The
// slice is owned by the engine and valid until the entry is evicted — use it
// immediately, do not store it. Returns nil when the size is invalid or
// runa fails.
@(private)
text_lines :: proc(te: ^Text_Engine, s: string, size, wrap_w: f32, weight := Font_Weight.Regular, mono := false, tab: u8 = 0, italic := false, no_liga := false, family: Family_Id = 0, tabular := false) -> []runa.Line {
	if !te.ok || !text_size_ok(size) do return nil
	// Resolved before the key, so a paragraph laid out in the family one
	// theme named is not found again under a theme that names another.
	fam := family_now(te, family, mono)
	te.tick += 1
	// Quantised to whole pixels because `wrap_w` is part of the key: a width
	// that wobbles by a fraction of a pixel between rebuilds (a scrollbar, a
	// flex rounding) would otherwise miss on every paragraph. Rounded down,
	// so the text never overflows its box.
	wrap_q := math.floor(wrap_w)
	key := Lines_Key{str = s, size = size, wrap_w = wrap_q, weight = weight, mono = mono, tab = tab if mono else 0, italic = italic && !mono, no_liga = no_liga, tabular = tabular, family = fam}
	if e, hit := &te.lines[key]; hit {
		e.used = te.tick
		return e.lines
	}
	te.shaped += 1 // a cache miss: shaped from scratch (BALDR_DEBUG_FRAMES reports these)
	lines, err := text_layout(te, s, text_opts(te, size, wrap_q, weight, mono, italic, no_liga, fam, tabular), te.allocator)
	if err != .None do return nil
	control_advances(te, s, lines, size, mono, tab)
	if len(te.lines) >= LINES_CACHE_MAX do lines_cache_evict(te)
	key.str = strings.clone(s, te.allocator)
	te.lines[key] = Lines_Entry{lines = lines, used = te.tick}
	return lines
}

// text_layout lays `s` out with `opts`, its stack widened by the system
// faces that draw what it cannot (text_fallback.odin). Those only fill in:
// the lines keep the height and baseline of the stack that was asked for,
// so a line with a Japanese name in it sits as its neighbours do. Every
// layout goes through here, so measuring and drawing agree.
@(private)
text_layout :: proc(te: ^Text_Engine, s: string, opts: runa.Paragraph_Opts, allocator: runtime.Allocator) -> ([]runa.Line, runa.Error) {
	extra := text_fallbacks(te, s, cast([]^runa.Font)opts.fonts)
	if len(extra) == 0 do return runa.layout_paragraph(s, opts, &te.cache, allocator)
	base := cast([]^runa.Font)opts.fonts
	height, baseline: f32
	for f in base { // as the shaper takes them, from the stack asked for
		k := opts.size / f32(f.units_per_em)
		height = max(height, (f.ascent - f.descent + f.line_gap) * k)
		baseline = max(baseline, f.ascent * k)
	}
	stack := make([]^runa.Font, len(base) + len(extra), context.temp_allocator)
	copy(stack, base)
	copy(stack[len(base):], extra)
	wide := opts
	wide.fonts = runa.Font_Stack(stack)
	lines, err := runa.layout_paragraph(s, wide, &te.cache, allocator)
	for &l in lines do l.height, l.baseline = height, baseline
	return lines, err
}

// control_advances: a control character takes no room (the "\n" a line
// broke at, a "\r"), and a tab reaches the next stop, `tab` cells of "0"
// (4 when 0), the way an editor shows code. The shaper gave them the
// missing glyph's width; render_text draws nothing for them. Line widths
// follow.
@(private)
control_advances :: proc(te: ^Text_Engine, s: string, lines: []runa.Line, size: f32, mono: bool, tab: u8) {
	cell: f32 = -1 // measured at the first tab
	for &l in lines {
		pen: f32
		touched := false
		for &g in l.glyphs {
			if is_control_at(s, int(g.cluster)) {
				touched = true
				g.x_advance, g.x_offset = 0, 0
				if s[g.cluster] == '\t' {
					if cell < 0 do cell = prefix_width(te, "0", size, mono = mono) * f32(int(tab) if tab > 0 else 4)
					if cell > 0 {
						g.x_advance = cell - math.mod(pen, cell)
						if g.x_advance < cell * 0.05 do g.x_advance += cell // sitting on a stop: jump to the next
					}
				}
			}
			pen += g.x_advance
		}
		if touched do l.width = pen
	}
}

// is_control_at: the character at byte `i` is a control — it takes no room
// and draws nothing. The C0 set and DEL, the C1 set (NEL, U+0085, among
// them), and the line and paragraph separators (U+2028, U+2029).
//
// It reads the rune, not the byte: NEL is 0xC2 0x85 and LS is 0xE2 0x80
// 0xA8, and neither first byte is below 0x20. A shaper maps these to
// .notdef, which most fonts draw as a visible box. runa blanks them too;
// both holding is harmless.
@(private)
is_control_at :: proc(s: string, i: int) -> bool {
	if i < 0 || i >= len(s) do return false
	b := s[i]
	if b < 0x80 do return b < 0x20 || b == 0x7F
	r, _ := utf8.decode_rune_in_string(s[i:])
	return (r >= 0x80 && r <= 0x9F) || r == 0x2028 || r == 0x2029
}

// lines_cache_evict drops the least-recently-used half of the paragraph
// cache. Runs once per LINES_CACHE_MAX/2 insertions, so the sort is cheap.
@(private)
lines_cache_evict :: proc(te: ^Text_Engine) {
	Aged :: struct {
		key:  Lines_Key,
		used: u64,
	}
	all := make([dynamic]Aged, 0, len(te.lines), context.temp_allocator)
	for k, e in te.lines do append(&all, Aged{key = k, used = e.used})
	slice.sort_by(all[:], proc(a, b: Aged) -> bool { return a.used < b.used })
	for a in all[:len(all) / 2] {
		if e, hit := te.lines[a.key]; hit do lines_free(te, e.lines)
		delete_key(&te.lines, a.key)
		delete(a.key.str, te.allocator)
	}
}

@(private)
lines_free :: proc(te: ^Text_Engine, lines: []runa.Line) {
	for &l in lines do runa.line_destroy(&l, te.allocator)
	delete(lines, te.allocator)
}

// glyph_slot returns the atlas slot for `gid` of `font` at `px` device px
// per em with quarter-pixel x offset `subpx`, rasterising on first use.
// Colour glyphs are rasterised without a subpixel shift (runa's COLR path
// ignores it), so they share one bitmap across buckets. `ok` is false when
// there is nothing to draw (blank glyph, too large, or a raster / atlas
// failure); such results are cached too.
@(private)
glyph_slot :: proc(te: ^Text_Engine, font: ^runa.Font, gid: runa.Glyph_ID, px: f32, subpx: u8) -> (slot: runa.Atlas_Slot, ok: bool) {
	fs := face_id(te, font)
	if fs == 0 || !(px > 0) || px > MAX_GLYPH_PX do return
	size_q := u32(math.round(px * 4))
	if size_q == 0 do return
	bucket := subpx & 3
	if runa.font_has_color_layers(font, gid) do bucket = 0
	key := Glyph_Key{font = fs, subpx = bucket, gid = gid, size_q = size_q}
	if e, hit := te.glyphs[key]; hit do return e.slot, e.ok
	s, err := runa.raster_glyph(font, gid, f32(size_q) / 4, key.subpx, &te.atlas, te.allocator)
	ok = err == .None && s.px_size.x > 0 && s.px_size.y > 0
	if ok do slot = s
	te.glyphs[key] = Glyph_Entry{slot = slot, ok = ok}
	return
}

// Positions in one shaped line, whose glyphs come in visual order whatever
// their direction: a character's caret edge is its left side when it runs
// left to right and its right side when it runs right to left, so a caret,
// a click and a selection land where the eye expects in Arabic and Hebrew.

// line_has_rtl says whether any of a line's glyphs runs right to left.
@(private)
line_has_rtl :: proc(glyphs: []runa.Paragraph_Glyph) -> bool {
	for g in glyphs do if g.level % 2 == 1 do return true
	return false
}

// line_caret_x is the x of the caret before byte `off`: at the near edge of
// the character there, or past the far edge of the one before it when `off`
// starts none (the end of the line, or inside a cluster).
@(private)
line_caret_x :: proc(glyphs: []runa.Paragraph_Glyph, off: int) -> f32 {
	at_x, at_found := f32(0), false
	before_c, before_x := -1, f32(0)
	pen: f32
	for g in glyphs {
		c := int(g.cluster)
		rtl := g.level % 2 == 1
		if c == off && !at_found {
			// a cluster's glyphs are adjacent; its near edge is where they start (LTR) or end (RTL)
			at_x, at_found = pen + (g.x_advance if rtl else 0), true
		} else if c == off && rtl {
			at_x = pen + g.x_advance
		}
		if c < off && c >= before_c {
			if c > before_c do before_x = pen if rtl else pen + g.x_advance
			else if rtl do before_x = min(before_x, pen)
			else do before_x = max(before_x, pen + g.x_advance)
			before_c = c
		}
		pen += g.x_advance
	}
	if at_found do return at_x
	if before_c >= 0 do return before_x
	return 0
}

// line_ranges is where bytes [a, z) of a line are drawn, as x ranges left to
// right, adjacent glyphs merged; several where directions mix. In the frame's
// temp memory.
@(private)
line_ranges :: proc(glyphs: []runa.Paragraph_Glyph, a, z: int) -> [][2]f32 {
	out := make([dynamic][2]f32, context.temp_allocator)
	pen: f32
	for g in glyphs {
		c := int(g.cluster)
		if c >= a && c < z {
			if n := len(out); n > 0 && abs(out[n - 1][1] - pen) < 0.01 {
				out[n - 1][1] = pen + g.x_advance
			} else {
				append(&out, [2]f32{pen, pen + g.x_advance})
			}
		}
		pen += g.x_advance
	}
	return out[:]
}
