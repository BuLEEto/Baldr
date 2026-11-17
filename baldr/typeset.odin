package baldr

// Text into a picture: an image editor's text layer, an image viewer's
// caption, a screenshot's annotation. The words become pixels in
// the document at the document's size (a 300 px heading), in any installed
// family at any weight, with the geometry to edit them in place.
//
// typeset lays the text out once. runa shapes each paragraph, with the
// family asked for, the toolkit's fonts behind it and the system's for any
// script they lack (text_layout). The lines are filled here, greedily at
// UAX #14 break opportunities, so that tracking counts when a line is
// filled, a space where a line wraps hangs past the edge instead of pushing
// the words in, and a justified line knows its spaces. The shaper hands
// each paragraph back in the order it is seen; it is put back into the
// order it is read to be wrapped, and each line then into the order it is
// seen (UAX #9 L1 and L2), so right-to-left text wraps as it should.
//
// What comes back answers an editor: the box, the ink, the lines, where the
// caret goes, the offset under a point, and a selection's rectangles.
// typeset_draw and typeset_mask fill the glyphs' outlines with exact
// coverage (path.odin's rasteriser); colour emoji keep their colours.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import runa "baldr:third_party/runa"
import "baldr:third_party/runa/bidi"
import "baldr:third_party/runa/itemize"
import "baldr:third_party/runa/linebreak"

// TYPESET_MAX_SIZE is the largest em typeset takes, in pixels.
TYPESET_MAX_SIZE :: 20000

// COLOR_GLYPH_MAX_PX: a colour glyph is rasterised at most this big and
// scaled up beyond it (an emoji at 3000 px would need a 36 MB bitmap).
@(private)
COLOR_GLYPH_MAX_PX :: 1024

// Typeset_Style says how text is set into a picture. The zero value (with a
// size) is the theme's typeface, regular, unwrapped.
Typeset_Style :: struct {
	family:      string,     // an installed family (installed_fonts); "" is the theme's own typeface
	size:        f32,        // the em, in the picture's pixels
	weight:      int,        // 1–1000: 400 regular, 700 bold (0 is 400); the family's nearest face, or a variable one set to it
	italic:      bool,
	align:       Text_Align, // each line in the box; Start follows the paragraph's direction (the right in Hebrew)
	justify:     bool,       // spread each line a wrap ended to the box's width; a paragraph's last line keeps `align`
	tracking:    f32,        // space added between characters, in thousandths of an em (a type panel's unit); negative tightens
	line_height: f32,        // baseline to baseline, in pixels (0: the typeface's own)
	wrap_width:  f32,        // the box's width, lines wrapping at it (0: lines end only at line breaks)
	runs:        []Typeset_Run, // stretches set differently from the rest; empty is one run in the style's own face
	indent:      f32,        // the first line of each paragraph starts this far in, in pixels; negative hangs it out to the left
	drop_cap_lines: int,     // the paragraph's first letter is set to span this many lines, and they start past it (0: none)
	drop_cap_gap:   f32,     // pixels between the dropped letter and the text beside it (0: a tenth of its size)
	hanging_punctuation: bool, // let quotes, stops, commas and hyphens sit a little outside the margin (typeset_hang_out)
	breaking:    Typeset_Breaking, // how the lines are chosen: one at a time (the default) or all together
	hyphen_limit: int,       // most lines in a row that may end in a hyphen: 0 is two, negative is no limit
	objects:     []Typeset_Object, // boxes the app draws itself, each at a U+FFFC in the text
}

// Typeset_Object is a box in the text that the **app** draws: a picture in
// a line, a formula, an inline chart. It stands where the text has a
// U+FFFC (OBJECT REPLACEMENT CHARACTER), and typesetting only makes room
// for it — where it ended up comes back in `Typeset.objects`, and the app
// draws its own picture there.
//
//	text := "The scholar \ufffc wrote it."  // U+FFFC: a picture goes here
//	at := strings.index(text, "\ufffc")
//	style.objects = []baldr.Typeset_Object{{at = at, size = {14, 16}, baseline = 3, label = "Li Bai"}}
//
// `baseline` is how much of the box hangs **below** the baseline: 0 sits
// it on the line, and a value near a third of its height sets it like a
// letter with a descender. The line grows to hold it, so a tall picture
// opens its own line rather than overlapping the ones around it.
//
// A U+FFFC with no object of its own takes no room and draws nothing,
// rather than the empty box a font would otherwise give it.
//
// The box takes the room it asks for, so one **wider than the column**
// makes its line wider than the measure rather than being shrunk: how a
// picture should be scaled to a page is the app's call, not the
// typesetter's, and it is the app that has the picture.
Typeset_Object :: struct {
	at:       int,    // the byte offset of its U+FFFC in the text
	size:     [2]f32, // the room it takes, in the picture's pixels
	baseline: f32,    // how far below the baseline its bottom edge sits
	label:    string, // what it is, for anything that reads the text aloud ("" is nothing to say)
}

// Typeset_Object_At is where a Typeset_Object was placed: `rect` is in the
// picture's pixels from its box's top-left, as everything else in a
// Typeset is, and `line` is the line it sits on (`Typeset.lines`). An
// object whose U+FFFC is not in the text does not appear here at all.
Typeset_Object_At :: struct {
	index: int,    // into the `objects` the style was given
	at:    int,    // the byte offset, as given
	line:  int,    // the line it sits on
	rect:  Rect,   // where to draw it
	label: string, // what it is, as the style said; the Typeset's own copy
}

// Typeset_Breaking is how a paragraph's lines are chosen.
//
// `.Greedy` fills one line at a time, taking words until the next will not
// fit. It is what a browser and every text editor do, and it is the default
// for a reason that is not typographic: a line's break never depends on
// what comes after it, so typing a word at the end of a paragraph cannot
// re-break the lines above the caret. Text that is being edited in place
// wants that.
//
// `.Even` chooses every break in the paragraph together — Knuth and Plass's
// total fit, runa's `break_lines` — to even how loose or tight the lines
// are. It is what a typesetter does and what a page of a book wants: fewer
// gaping justified lines, fewer hyphens, a rag that does not jag. It also
// makes limits a greedy fill cannot express, because it can trade one line
// against another: `hyphen_limit`, and no hyphen on the last full line of a
// paragraph (which would leave a reader a fragment of a word to finish on).
// It costs about 0.02 ms a paragraph on top of the shaping (spikes/typeset_cost).
//
// Two things fall back to `.Greedy` on their own: a paragraph holding a tab
// (a tab stop's width depends on where the line starts, which is what the
// breaking is still deciding), and one with no `wrap_width` to break to.
Typeset_Breaking :: enum u8 {
	Greedy,
	Even,
}

// TYPESET_HYPHEN_LIMIT is how many lines in a row may end in a hyphen when
// `Typeset_Style.hyphen_limit` is left at zero. Two is the usual house
// rule; a third in a row reads as a ladder down the margin.
TYPESET_HYPHEN_LIMIT :: 2

// TYPESET_HYPHEN_PENALTY is what breaking a word costs the total fit, in
// Knuth's units: enough that a hyphen loses to a comfortable break and wins
// against a loose line. (runa's own `break_text` uses the same 50.)
@(private)
TYPESET_HYPHEN_PENALTY :: f32(50)

// TYPESET_SHRINK is how much of a space a justified line may take back to
// pull its words in, as a fraction of the space's own width. A third is
// Knuth's figure for Computer Modern (1.11pt of a 3.33pt space) and it is
// what the total fit counts on: a line it chose tight is tightened by
// typeset_justify by at most this much. A **ragged** line is never
// tightened, so its glue is offered no shrink at all — a breaker must not
// count on something the filler will not do.
@(private)
TYPESET_SHRINK :: f32(0.33)

// TYPESET_LAST_HYPHEN_DEMERITS is what a hyphen on a paragraph's **last
// full line** costs: a reader should not finish a paragraph on half a word.
// TeX's 5000 is a nudge, worth less than one loose line; this loses to
// nothing but having no other way to break at all. runa's default matches
// it; it stays named here so the rule is stated rather than inherited.
@(private)
TYPESET_LAST_HYPHEN_DEMERITS :: f32(1e6)

// Typeset_Run is a stretch of the text set differently from its
// neighbours: a word in italic, a footnote's raised number, a title in
// another face (a book's paragraph is runs, not one style).
// Runs are in order and together cover the text; `end` is the byte the run
// reaches, so the first covers `0 ..< runs[0].end` and the last must end at
// `len(text)`. `family`, `size`, `weight` and `tracking` take the style's
// value when left empty or zero; the flags (`italic`, `small_caps`,
// `underline`, `strike`) are the run's own, since a `false` cannot be told
// from unset. So once a text has runs, every run says whether it is italic.
//
// **A run boundary breaks shaping**, as a style change does in any
// typesetter: a ligature or a kern never spans one. Set a word in italic and
// the "fi" where the italic starts is two glyphs, which is right — the two
// halves are in different faces.
Typeset_Run :: struct {
	end:         int,    // the byte this run reaches, from the text's start; the last run ends at len(text)
	family:      string, // "" takes the style's
	size:        f32,    // the em in pixels; 0 takes the style's
	weight:      int,    // 0 takes the style's
	italic:      bool,
	small_caps:  bool,   // set the run's lowercase letters as the face's own small capitals (`smcp`), where it has them
	shift:       f32,    // the baseline moves up by this many pixels: a superscript is positive, a subscript negative
	tracking:    f32,    // thousandths of an em; 0 takes the style's
	ink:         Color,  // what to draw it in; a zero alpha takes the colour the draw call was given
	underline:   bool,
	strike:      bool,
}

// typeset_small_caps_ready says whether `Typeset_Run.small_caps` does
// anything: it does. A run asking for small capitals is shaped with the
// face's own `smcp`, as CSS `font-variant: small-caps` means it — lowercase
// letters become small capitals, capitals are left alone. A face without
// `smcp` is set in its ordinary letters, not faked ones (scaled-down
// capitals carry the wrong stem weight); ask `typeset_has_small_caps` about
// the face in hand. The embedded Inter and JetBrains Mono have no `smcp`.
typeset_small_caps_ready :: proc "contextless" () -> bool { return true }

// typeset_has_small_caps reports whether the face `family` resolves to at
// `weight` carries the font's own small capitals, so a `Typeset_Run` asking
// for them is set in real ones rather than left in its ordinary letters. An
// app offering small capitals as a setting can grey it out, or choose
// another face, instead of letting a reader wonder why nothing happened.
// False for a family this machine does not have (the theme's own typeface
// has no `smcp`), or a tree with no text engine. Call it on the tree's
// thread: the first use of a family and weight loads its face.
typeset_has_small_caps :: proc(t: ^Tree, family: string, weight := 0, italic := false) -> bool {
	te := t.text if t != nil else nil
	if te == nil || !te.ok do return false
	f := typeset_face(te, family, weight if weight > 0 else 400, italic)
	if f.font == nil do return false
	return runa.font_has_feature(f.font, "smcp")
}

// Typeset_Line is one line of a Typeset: the bytes of the text on it (its
// line break, if it ends at one, belongs to no line), its box from the
// Typeset's top-left (as wide as its characters, a hanging space not
// counted; the box's width when justified), and its baseline's y.
//
// **A line is as tall as what is on it.** Its height and baseline come from
// the runs that actually reach it, so a footnote's small number does not
// change the leading of the line carrying it, and a line holding a heading's
// run is tall where its neighbours are not. `style.line_height` overrides
// that for every line when it is set.
Typeset_Line :: struct {
	start, end: int,
	rect:       Rect,
	baseline:   f32,
	hyphen:     bool, // it broke at a soft hyphen, so a hyphen is drawn at its end and counted in its width
}

// Typeset is text set for a picture (typeset). Positions are in the
// picture's pixels from its box's top-left: `size` is the box (the wrap
// width, or the widest line, by every line's height), `ink` where the
// glyphs' pixels fall (an italic's overhang or a descender may reach past
// the box). `family` is the family it was set in, as the machine names it:
// "" is the theme's typeface, which is also what sets text in a family this
// machine does not have. `weight` is the weight it was set at. Everything
// is the allocator's it was made with (typeset_destroy); the glyphs point
// at fonts the tree's text engine holds, so a Typeset is drawn while the
// tree lives. The other fields are Baldr's.
Typeset :: struct {
	text:      string,
	size:      [2]f32,
	ink:       Rect,
	lines:     []Typeset_Line,
	family:    string,
	weight:    int,
	glyphs:    []Typeset_Glyph,
	spans:     [][2]int, // each line's glyphs: first, count
	runs:      []Typeset_Run, // as given, always at least one (the style's own); Typeset_Glyph.run indexes it
	objects:   []Typeset_Object_At, // where each box the style gave was placed, in reading order
	drop_cap_run: int,     // the run holding the dropped first letter, last in `runs`; -1 when there is none
	allocator: runtime.Allocator,
	// serial tells one setting from another when their addresses cannot:
	// freeing Typesets and setting new ones can reuse the same memory, so a
	// widget comparing `^Typeset` alone would draw the old words. Stamped by
	// `typeset` from a counter on the Tree, so a copy carries the same
	// serial — a copy *is* that setting — while a fresh setting never
	// repeats one.
	serial:    u64,
}

@(private)
Typeset_Glyph :: struct {
	font:       ^runa.Font,
	id:         runa.Glyph_ID,
	scale:      f32,    // pixels per font unit
	pos:        [2]f32, // its origin on the baseline
	x0, x1:     f32,    // the room it takes on its line
	start, end: int,    // its cluster's bytes
	rtl:        bool,
	color:      bool,   // drawn from colour layers
	blank:      bool,   // a control character: nothing drawn
	run:        i32,    // the Typeset_Run it was set from: its ink, underline and strike
}

// Typeset_Shaped is a glyph while lines are being filled, in reading order.
@(private)
Typeset_Shaped :: struct {
	font:              ^runa.Font,
	id:                runa.Glyph_ID,
	adv, xoff, yoff:   f32,
	track, extra:      f32, // tracking after it; room justification adds
	start, end:        int,
	level:             u8,
	run:               i32,
	hang_l, hang_r:    f32,  // how far it may sit outside the margin when it starts or ends a line
	hang, space, tab, ctrl: bool,
	soft:              bool, // a U+00AD: no room unless its line ends here, and then it is drawn
	hyph_adv:          f32,  // what it costs when it is drawn
	obj:               i32,  // a U+FFFC: which Typeset_Object stands here, or -1 for none of them
}

// Typeset_Pending is a filled line not yet placed.
@(private)
Typeset_Pending :: struct {
	first, count: int, // into the shaped glyphs
	start, end:   int,
	width, hang:  f32, // its characters' width (the last one's tracking not counted), and what hangs past it
	last, rtl:    bool,
	hyphen:       bool, // it ends at a soft hyphen, which is drawn and counted in `width`
	indent:       f32,  // how far in this line starts: the first-line indent, the dropped letter, or both
	lead:         f32,  // an opening quote's width that sits out in the margin, left of where the line starts
}

@(private)
Typeset_Face_Key :: struct {
	family: string, // folded
	weight: i32,
	italic: bool,
}

@(private)
Typeset_Face :: struct {
	font:   ^runa.Font,
	family: string, // as the machine names it ("" the theme's), the engine's
	weight: int,
}

// Typeset_Plan is what one run costs to set: the face it resolved to, the
// stack behind it for characters that face lacks, and the metrics its line
// takes its height from.
@(private)
Typeset_Plan :: struct {
	face:     Typeset_Face,
	stack:    [3]^runa.Font,
	size:     f32,
	tracking: f32, // pixels between characters
	ascent:   f32, // pixels above the baseline
	descent:  f32, // pixels below it, positive
	natural:  f32, // the face's own baseline-to-baseline, in pixels
	shift:    f32, // the run's baseline shift
	feats:    [1]runa.Feature_Setting, // the OpenType features this run asks for by tag
	nfeat:    int,                     // how many of them: `feats[:nfeat]` is what the shaper is given
}

// typeset_runs normalises a style's runs into runs that cover the text,
// each with the style's values filled in. An empty `style.runs` is one run
// in the style's own face, so a caller that never heard of runs is
// unaffected.
//
// A caller cannot lose text by miscounting: a run reaching past the end is
// cut to it, and runs that stop short are followed by one more in the
// style's own face, so the tail is always set rather than silently dropped.
@(private)
typeset_runs :: proc(text: string, style: Typeset_Style, allocator: runtime.Allocator) -> []Typeset_Run {
	weight := style.weight if style.weight > 0 else 400
	out := make([dynamic]Typeset_Run, 0, max(len(style.runs), 1), allocator)
	at := 0
	for r in style.runs {
		end := clamp(r.end, at, len(text))
		if end <= at && len(out) > 0 do continue // reaches nothing: the run before it already covered those bytes
		f := r
		f.end = end
		if f.family == "" do f.family = style.family
		if !(f.size > 0) do f.size = style.size
		if f.weight <= 0 do f.weight = weight
		if f.tracking == 0 do f.tracking = style.tracking
		append(&out, f)
		at = end
	}
	if at < len(text) || len(out) == 0 {
		append(&out, Typeset_Run{end = len(text), family = style.family, size = style.size,
			weight = weight, italic = style.italic, tracking = style.tracking})
	}
	return out[:]
}

// typeset_more is `xs` with one more on the end, in `allocator`.
@(private)
typeset_more :: proc(xs: []$T, x: T, allocator: runtime.Allocator) -> []T {
	out := make([]T, len(xs) + 1, allocator)
	copy(out, xs)
	out[len(xs)] = x
	return out
}

// typeset_shape_into shapes one stretch in one plan and appends its glyphs.
// It is the dropped letter's path: a handful of characters in one face, with
// none of the per-run walking a paragraph needs.
@(private)
typeset_shape_into :: proc(te: ^Text_Engine, s: string, base: int, run: i32, pl: Typeset_Plan, out: ^[dynamic]Typeset_Shaped) {
	stack := pl.stack
	feats := pl.feats // a parameter is not addressable, and the shaper wants a slice
	opts := runa.Paragraph_Opts{fonts = runa.Font_Stack(stack[:]), size = pl.size, direction = .LTR, align = .Start,
		features = feats[:pl.nfeat]}
	lines, err := text_layout(te, s, opts, context.temp_allocator)
	if err != .None do return
	for l in lines {
		gs := slice.clone(l.glyphs, context.temp_allocator)
		typeset_unreorder(gs)
		for g in gs {
			append(out, Typeset_Shaped{
				font = g.font, id = g.glyph_id, adv = g.x_advance, xoff = g.x_offset, yoff = g.y_offset,
				start = base + int(g.cluster), end = base + len(s), run = run,
			})
		}
	}
}

// typeset_cap_span is how many bytes the dropped first letter covers: the
// paragraph's first character, and the character after it when that first
// one is an opening quotation mark — a paragraph beginning “The sets the
// quote and the T together, which is what a typesetter does and what
// ::first-letter means.
@(private)
typeset_cap_span :: proc(text: string) -> int {
	if len(text) == 0 do return 0
	r, w := utf8.decode_rune_in_string(text)
	n := w
	switch r {
	case '"', '\'', 0x2018, 0x201C, 0x00AB, 0x2039: // " ' ‘ “ « ‹
		if n < len(text) {
			_, w2 := utf8.decode_rune_in_string(text[n:])
			n += w2
		}
	}
	return n
}

// typeset_plan resolves a run's face and metrics. False when the family has
// no face at all, which is what stops the whole typeset.
@(private)
typeset_plan :: proc(te: ^Text_Engine, r: Typeset_Run) -> (p: Typeset_Plan, ok: bool) {
	p.face = typeset_face(te, r.family, r.weight, r.italic)
	if p.face.font == nil do return
	f := p.face.font
	k := r.size / f32(f.units_per_em)
	p.size, p.shift = r.size, r.shift
	p.ascent, p.descent = f.ascent * k, -f.descent * k
	p.natural = (f.ascent - f.descent + f.line_gap) * k
	p.tracking = r.tracking * r.size / 1000
	p.stack = {f, te.fonts[.Italic] if r.italic else te.fonts[.UI], te.fonts[.Emoji]}
	// Small capitals are the face's own glyphs or they are nothing: runa
	// applies `smcp` where the font carries it and ignores the tag where it
	// does not, which leaves the run in its ordinary letters rather than in
	// scaled-down capitals (typeset_small_caps_ready).
	if r.small_caps {
		p.feats[0] = runa.feature("smcp")
		p.nfeat = 1
	}
	return p, true
}

// typeset_object_at is the object standing at byte `at`, or -1.
@(private)
typeset_object_at :: proc(objects: []Typeset_Object, at: int) -> int {
	for o, i in objects do if o.at == at do return i
	return -1
}

// typeset_run_at is the run covering byte `at`, from `from` onwards (runs
// are in order, so a walk forward costs nothing across a paragraph).
@(private)
typeset_run_at :: proc(runs: []Typeset_Run, at, from: int) -> int {
	i := from
	for i + 1 < len(runs) && runs[i].end <= at do i += 1
	return i
}

// typeset sets `text` in `style` for drawing into a picture. Paragraphs
// end at line breaks ("\n", "\r\n", U+2028, U+2029). It is false, with
// nothing allocated, when the tree has no text engine (a headless tree
// without one) or the size is not between 0 and TYPESET_MAX_SIZE. The
// Typeset is the caller's (`allocator`): typeset_destroy. Call it on the
// tree's thread: the first use of a family and weight loads its face.
typeset :: proc(t: ^Tree, text: string, style: Typeset_Style, allocator := context.allocator) -> (ts: Typeset, ok: bool) {
	te := t.text if t != nil else nil
	if te == nil || !te.ok || !(style.size > 0) || style.size > TYPESET_MAX_SIZE do return
	runs := typeset_runs(text, style, context.temp_allocator)
	plans := make([]Typeset_Plan, len(runs), context.temp_allocator)
	for r, i in runs {
		plans[i] = typeset_plan(te, r) or_return
	}
	face := plans[0].face
	size := style.size
	k := size / f32(face.font.units_per_em)
	zero := runa.font_lookup_glyph(face.font, '0')
	cell := f32(runa.font_glyph_advance(face.font, zero)) * k * 4 // a tab stop every four figures, as the editors have it
	if !(cell > 0) do cell = size * 2

	shaped := make([dynamic]Typeset_Shaped, context.temp_allocator)
	pending := make([dynamic]Typeset_Pending, context.temp_allocator)
	ind := Typeset_Indent{first = style.indent}
	// The dropped first letter. It is set so the face's ascent spans
	// the lines asked for — its top at the first line's ascender, its
	// baseline on the last line it reaches — and taken **out of the flow**,
	// so the lines beside it start past it and its height never becomes
	// theirs. Its size is worked out from the style's own metrics rather
	// than the laid-out lines, because the room it takes decides where those
	// lines break.
	flow := runs
	cap_bytes, cap_run, ncap := 0, -1, 0
	if style.drop_cap_lines > 1 && len(text) > 0 {
		lh := style.line_height if style.line_height > 0 else plans[0].natural
		target := f32(style.drop_cap_lines - 1) * lh + plans[0].ascent
		f := plans[0].face.font
		per_px := f.ascent / f32(f.units_per_em) // what a 1 px em gives
		if per_px > 0 && target > 0 {
			r := runs[0]
			r.end, r.size, r.shift = typeset_cap_span(text), target / per_px, 0
			r.underline, r.strike = false, false
			if pl, pok := typeset_plan(te, r); pok && r.size > 0 && r.size <= TYPESET_MAX_SIZE {
				cap_run = len(runs)
				runs = typeset_more(runs, r, context.temp_allocator)
				plans = typeset_more(plans, pl, context.temp_allocator)
				typeset_shape_into(te, text[:r.end], 0, i32(cap_run), pl, &shaped)
				ncap = len(shaped)
				if ncap > 0 {
					w: f32
					for g in shaped do w += g.adv
					cap_bytes = r.end
					ind.drop = w + (style.drop_cap_gap if style.drop_cap_gap > 0 else pl.size * 0.1)
					ind.lines = style.drop_cap_lines
				} else {
					cap_run = -1 // nothing to draw: give the room back
				}
			}
		}
	}
	for para in typeset_paragraphs(text[cap_bytes:]) {
		typeset_paragraph(te, text, {para[0] + cap_bytes, para[1] + cap_bytes}, flow, plans, style, cell, &shaped, &pending, ind)
	}

	box_w := style.wrap_width
	if box_w <= 0 do for p in pending do box_w = max(box_w, p.width + max(p.indent, 0))
	ts.allocator = allocator
	ts.text = strings.clone(text, allocator)
	ts.family = strings.clone(face.family, allocator)
	ts.weight = face.weight
	ts.glyphs = make([]Typeset_Glyph, len(shaped), allocator)
	ts.lines = make([]Typeset_Line, len(pending), allocator)
	ts.spans = make([][2]int, len(pending), allocator)
	ts.runs = slice.clone(runs, allocator)
	placed := make([dynamic]Typeset_Object_At, 0, len(style.objects), context.temp_allocator)
	// the families come from the caller's strings; a Typeset owns everything
	// it hands back, so it owns these too
	for &r in ts.runs do if r.family != "" do r.family = strings.clone(r.family, allocator)
	y: f32
	for p, li in pending {
		line := slice.clone(shaped[p.first:][:p.count], context.temp_allocator)
		// the room this line actually has: a first-line indent or a dropped
		// letter takes from it, and everything below measures within it
		avail := box_w - p.indent
		// A line the total fit chose *tight* is pulled in rather than left
		// to overrun: it counted on the spaces giving back up to
		// TYPESET_SHRINK of themselves. Only there — a greedy fill's
		// overlong line is a word longer than the column, and squeezing its
		// spaces would be wrong.
		//
		// The allowance is counted as typeset_justify spends it: the spaces
		// a line ends on hang past the margin and are not spread. `hang` is
		// true of every ordinary space, not only one that hangs: skipping
		// every space with it set would leave no allowance at all.
		give: f32
		if style.breaking == .Even && style.justify {
			last := len(line)
			for last > 0 && line[last - 1].hang do last -= 1
			for g in line[:last] do if g.space do give += g.adv * TYPESET_SHRINK
		}
		// A paragraph's last line is not spread, but it is still tightened
		// when the breaker chose it tight, or it would be wider than its
		// column: the breaker counts every line's shrink and cannot know the
		// last will not be justified.
		over := p.width - avail
		tighten := give > 0 && over > 0 && over <= give + 0.01
		justify := style.justify && style.wrap_width > 0 && (tighten || (!p.last && avail > p.width))
		spread := justify && typeset_justify(line, avail - p.width)
		base: u8 = 1 if p.rtl else 0
		for i := len(line) - 1; i >= 0 && line[i].hang; i -= 1 do line[i].level = base // UAX #9 L1: a hanging space takes the paragraph's direction
		typeset_reorder(line)
		// The line is as tall as what reaches it: the deepest ascent above
		// the baseline and the deepest descent below, each measured with its
		// run's own shift, so a raised footnote number makes room for itself
		// without moving the line it sits on. One run gives exactly the
		// face's own metrics.
		asc, desc, nat := plans[0].ascent, plans[0].descent, plans[0].natural
		for g in line {
			pl := plans[g.run]
			if g.obj >= 0 { // a box the app draws: as tall as it asked to be, where it asked to sit
				o := style.objects[g.obj]
				asc = max(asc, o.size.y - o.baseline + pl.shift)
				desc = max(desc, o.baseline - pl.shift)
				continue
			}
			asc = max(asc, pl.ascent + pl.shift)
			desc = max(desc, pl.descent - pl.shift)
			nat = max(nat, pl.natural)
		}
		natural := max(nat, asc + desc)
		line_h := style.line_height if style.line_height > 0 else natural
		base_y := asc + (line_h - natural) / 2
		width := avail if spread else p.width
		x: f32
		switch {
		case spread:                  x = 0
		case style.align == .Center:  x = (avail - p.width) / 2
		case (style.align == .End) != p.rtl: x = avail - p.width
		}
		if !p.rtl do x += p.indent - p.lead // the indent is at the line's start, which right to left is its right; an opening quote starts out in the margin
		pen := x - (p.hang if p.rtl else 0) // right to left, what hangs is on the left
		for g, i in line {
			adv := g.adv + g.extra
			pl := plans[g.run]
			if g.obj >= 0 { // where the app is to draw its picture
				o := style.objects[g.obj]
				append(&placed, Typeset_Object_At{index = int(g.obj), at = o.at, line = li,
					rect = {pen, y + base_y - pl.shift - (o.size.y - o.baseline), o.size.x, o.size.y},
					label = strings.clone(o.label, allocator) if o.label != "" else ""})
			}
			ts.glyphs[p.first + i] = Typeset_Glyph{
				font = g.font, id = g.id, scale = pl.size / f32(g.font.units_per_em),
				pos = {pen + g.xoff, y + base_y - pl.shift - g.yoff}, x0 = pen, x1 = pen + adv,
				start = g.start, end = g.end, rtl = g.level & 1 == 1, blank = g.ctrl,
				color = !g.ctrl && runa.font_has_color_layers(g.font, g.id), run = g.run,
			}
			pen += adv
		}
		ts.lines[li] = Typeset_Line{start = p.start, end = p.end, rect = {x, y, width, line_h}, baseline = y + base_y, hyphen = p.hyphen}
		ts.spans[li] = {p.first, p.count}
		y += line_h
	}
	ts.objects = slice.clone(placed[:], allocator)
	// The dropped letter, once the lines are placed: at the paragraph's own
	// left edge, its baseline on the last line it spans. It is drawn with
	// the first line, and belongs to it for a reader too, so the letter is
	// not missing from the start of the page.
	ts.drop_cap_run = cap_run
	if ncap > 0 && len(ts.lines) > 0 {
		li := min(style.drop_cap_lines, len(ts.lines)) - 1
		bl := ts.lines[li].baseline
		pen: f32
		for i in 0 ..< ncap {
			g := shaped[i]
			pl := plans[g.run]
			ts.glyphs[i] = Typeset_Glyph{
				font = g.font, id = g.id, scale = pl.size / f32(g.font.units_per_em),
				pos = {pen + g.xoff, bl - g.yoff}, x0 = pen, x1 = pen + g.adv,
				start = g.start, end = g.end, run = g.run,
				color = runa.font_has_color_layers(g.font, g.id),
			}
			pen += g.adv
		}
		ts.spans[0] = {0, ts.spans[0][1] + ncap}
		ts.lines[0].start = 0
	}
	ts.size = {box_w, y}
	ts.ink = typeset_ink(&ts)
	t.typeset_serial += 1 // t is non-nil: the guard at the top returned otherwise
	ts.serial = t.typeset_serial
	return ts, true
}

// typeset_destroy frees a Typeset. Safe on the zero value and twice.
typeset_destroy :: proc(ts: ^Typeset) {
	if ts.allocator.procedure == nil do return
	delete(ts.text, ts.allocator)
	delete(ts.family, ts.allocator)
	delete(ts.glyphs, ts.allocator)
	delete(ts.lines, ts.allocator)
	delete(ts.spans, ts.allocator)
	for r in ts.runs do if r.family != "" do delete(r.family, ts.allocator)
	delete(ts.runs, ts.allocator)
	for o in ts.objects do if o.label != "" do delete(o.label, ts.allocator)
	delete(ts.objects, ts.allocator)
	ts^ = {}
}

// typeset_paragraphs is the text's paragraphs: each one's bytes, up to the
// line break that ends it. A text ending in a line break has an empty last
// paragraph, where the caret goes after it.
@(private)
typeset_paragraphs :: proc(text: string) -> [][2]int {
	out := make([dynamic][2]int, context.temp_allocator)
	start, i := 0, 0
	for i < len(text) {
		r, w := utf8.decode_rune_in_string(text[i:])
		brk := 0
		switch r {
		case '\n', 0x0B, 0x0C, 0x85, 0x2028, 0x2029: brk = w
		case '\r': brk = 2 if i + 1 < len(text) && text[i + 1] == '\n' else 1
		}
		if brk == 0 {
			i += w
			continue
		}
		append(&out, [2]int{start, i})
		i += brk
		start = i
	}
	append(&out, [2]int{start, len(text)})
	return out[:]
}

// typeset_paragraph shapes one paragraph, puts its glyphs in reading order
// with their tracking, and fills its lines.
@(private)
typeset_paragraph :: proc(te: ^Text_Engine, text: string, para: [2]int, runs: []Typeset_Run, plans: []Typeset_Plan, style: Typeset_Style, cell: f32, shaped: ^[dynamic]Typeset_Shaped, pending: ^[dynamic]Typeset_Pending, ind: Typeset_Indent = {}) {
	ps, pe := para[0], para[1]
	s := text[ps:pe]
	rtl := bidi.paragraph_direction(s) == .RTL
	if len(s) == 0 {
		append(pending, Typeset_Pending{first = len(shaped), start = ps, end = ps, last = true, rtl = rtl, indent = typeset_indent_of(ind, 0)})
		return
	}
	first := len(shaped)
	// One shaping call per run within the paragraph. The paragraph's own
	// direction goes to each of them rather than .Auto: resolved per
	// segment, a run holding only a comma would take the direction of
	// whatever it is made of instead of the paragraph it sits in.
	dir := runa.Direction.RTL if rtl else runa.Direction.LTR
	ri := typeset_run_at(runs, ps, 0)
	for seg := ps; seg < pe; {
		ri = typeset_run_at(runs, seg, ri)
		end := min(runs[ri].end, pe)
		if end <= seg { // a run of no bytes inside this paragraph
			if ri + 1 >= len(runs) do break
			ri += 1
			continue
		}
		pl := plans[ri]
		stack := pl.stack
		opts := runa.Paragraph_Opts{fonts = runa.Font_Stack(stack[:]), size = pl.size, direction = dir, align = .Start,
			features = pl.feats[:pl.nfeat]}
		lines, err := text_layout(te, text[seg:end], opts, context.temp_allocator)
		if err == .None do for l in lines {
			gs := slice.clone(l.glyphs, context.temp_allocator)
			typeset_unreorder(gs)
			for g in gs {
				c := seg + int(g.cluster)
				r := utf8.RUNE_ERROR
				if c < pe do r, _ = utf8.decode_rune_in_string(text[c:])
				// A U+FFFC is a box the app draws, not a character: it
				// takes the room its object asked for and nothing is
				// drawn for it. One the style gave no object for takes
				// no room either, rather than the empty box a font
				// would give it.
				obj := i32(-1)
				if r == 0xFFFC {
					obj = i32(typeset_object_at(style.objects, c))
					adv := style.objects[obj].size.x if obj >= 0 else 0
					append(shaped, Typeset_Shaped{
						font = g.font, id = g.glyph_id, adv = adv,
						start = c, level = g.level, run = i32(ri), ctrl = true, obj = obj,
					})
					continue
				}
				append(shaped, Typeset_Shaped{
					font = g.font, id = g.glyph_id, adv = g.x_advance, xoff = g.x_offset, yoff = g.y_offset,
					start = c, level = g.level, run = i32(ri), obj = -1,
					hang = typeset_hangs(r), space = r == ' ' || r == 0xA0 || r == 0x3000,
					tab = r == '\t', ctrl = r < 0x20 || r == 0x7F, soft = r == 0xAD,
				})
			}
		}
		seg = end
	}
	gs := shaped[first:]
	// each cluster's end: the next cluster's start
	starts := make([dynamic]int, 0, len(gs), context.temp_allocator)
	for g in gs do append(&starts, g.start)
	slice.sort(starts[:])
	for &g in gs {
		i, _ := slice.binary_search(starts[:], g.start)
		for i < len(starts) && starts[i] <= g.start do i += 1
		g.end = starts[i] if i < len(starts) else pe
		if g.ctrl && g.obj < 0 do g.adv, g.xoff = 0, 0 // a control character takes no room (a tab takes its stop's, below; an object keeps what it asked for)
	}
	// tracking: after each character but the paragraph's last, never
	// through a joined script, and in the run's own amount
	for i in 0 ..< len(gs) {
		if gs[i].ctrl || i + 1 >= len(gs) || gs[i + 1].start == gs[i].start do continue
		if !typeset_cursive(text, gs[i].start) do gs[i].track = plans[gs[i].run].tracking
	}
	for &g in gs do g.adv += g.track
	// A soft hyphen is a hyphenation point, not a character: no room and
	// nothing drawn unless a line ends there, and then a hyphen.
	//
	// Its own glyph cannot be drawn: a shaper drops U+00AD as a
	// default-ignorable whatever the font's cmap says. So the face's ordinary
	// hyphen and its width are taken here and held until a line ends on it.
	for &g in gs do if g.soft {
		g.adv, g.track, g.xoff, g.yoff = 0, 0, 0, 0
		g.ctrl = true
		pl := plans[g.run]
		f := pl.face.font
		if f == nil do continue
		hg := runa.font_lookup_glyph(f, '-')
		if hg == 0 do continue // a face with no hyphen: the break stands, nothing is drawn
		g.font, g.id = f, hg
		g.hyph_adv = f32(runa.font_glyph_advance(f, hg)) * pl.size / f32(f.units_per_em)
	}
	// How much of a character may sit outside the margin, now that advances
	// are final. A soft hyphen is measured at the width it has when drawn,
	// since that is the only time it is at a margin at all.
	if style.hanging_punctuation do for &g in gs {
		if g.hang || (g.ctrl && !g.soft) do continue
		adv := g.hyph_adv if g.soft else g.adv
		r, _ := utf8.decode_rune_in_string(text[g.start:])
		g.hang_l = typeset_hang_out(r, true) * adv
		g.hang_r = typeset_hang_out(r, false) * adv
	}
	// Which filler. Total fit needs a measure to break to, and it cannot
	// place a tab: a tab's advance depends on where its line starts, which
	// is the thing still being decided. Either way the greedy fill is the
	// answer, and it is the answer a tab wants anyway — a tabbed paragraph
	// is a table, not prose.
	tabbed := false
	for g in gs do if g.tab { tabbed = true; break }
	if style.breaking == .Even && style.wrap_width > 0 && !tabbed {
		typeset_fill_even(text, ps, pe, first, shaped, pending, style, cell, rtl, ind)
	} else {
		typeset_fill(text, ps, pe, first, shaped, pending, style, cell, rtl, ind)
	}
}

// Typeset_Indent is how far each line of a paragraph starts in: the
// first-line indent (negative hangs it out to the left, which is what a
// hanging indent means), and the room a dropped first letter takes from the
// lines beside it.
@(private)
Typeset_Indent :: struct {
	first: f32, // the first line only
	drop:  f32, // every line the dropped letter reaches
	lines: int, // how many that is
}

// typeset_indent_of is where line `n` of a paragraph starts.
@(private)
typeset_indent_of :: proc "contextless" (ind: Typeset_Indent, n: int) -> (x: f32) {
	if n == 0 do x += ind.first
	if n < ind.lines do x += ind.drop
	return
}

// typeset_breaks is where a paragraph's lines may break: each character's
// offset in the text, and whether a line may *start* at it — UAX #14, with
// Thai's dictionary segmentation over it. Both fillers ask this, so they
// cannot come to different conclusions about where a break is allowed.
@(private)
typeset_breaks :: proc(text: string, ps, pe: int) -> (offs: []int, allowed: []bool) {
	s := text[ps:pe]
	runes := make([dynamic]rune, 0, len(s), context.temp_allocator)
	off := make([dynamic]int, 0, len(s), context.temp_allocator)
	for i := 0; i < len(s); {
		r, w := utf8.decode_rune_in_string(s[i:])
		append(&runes, r)
		append(&off, ps + i)
		i += w
	}
	allow := make([]bool, len(runes) + 1, context.temp_allocator)
	for i := 0; i < len(runes); {
		next, _ := linebreak.next_break(runes[:], i)
		if next > 0 && next < len(runes) do allow[next] = true
		i = next if next > i else i + 1
	}
	linebreak.thai_segment_breaks(runes[:], allow[:len(runes)])
	return off[:], allow
}

// typeset_may_break: may a line start at byte `at`?
@(private)
typeset_may_break :: proc(offs: []int, allowed: []bool, at: int) -> bool {
	i, found := slice.binary_search(offs, at)
	return found && allowed[i]
}

// typeset_emit records one filled line, from glyph `a` to glyph `b`.
@(private)
typeset_emit :: proc(pending: ^[dynamic]Typeset_Pending, gs: []Typeset_Shaped, first, a, b, ps, pe: int, last, rtl, hyphen: bool, indent: f32) {
	cur, content, track, out: f32
	for g in gs[a:b] {
		cur += g.adv
		if !g.hang do content, track, out = cur, g.track, g.hang_r
	}
	start := gs[a].start if a > 0 else ps
	end := gs[b].start if b < len(gs) else pe
	// What hangs past the margin is not part of the line's measure, so a
	// line ending in a comma is set as wide as one ending in a letter and
	// the comma goes outside — which is the whole of optical alignment.
	width := content - track - out
	append(pending, Typeset_Pending{first = first + a, count = b - a, start = start, end = end, width = width,
		hang = cur - (content - track), last = last, rtl = rtl, hyphen = hyphen, indent = indent, lead = gs[a].hang_l})
}

// typeset_tab_stop is how far a tab at `cur` reaches.
@(private)
typeset_tab_stop :: proc "contextless" (cur, cell: f32) -> f32 {
	adv := cell - math.mod(cur, cell)
	return adv + cell if adv < cell * 0.05 else adv // on a stop: the next one
}

// typeset_hyphen_show gives a soft hyphen at the end of a line its room and
// its glyph back (typeset_paragraph took them away), and says whether
// anything is actually drawn — a face with no hyphen keeps the break and
// draws nothing, and the line then does not claim to be hyphenated.
@(private)
typeset_hyphen_show :: proc(gs: []Typeset_Shaped, at: int) -> bool {
	if at <= 0 || at > len(gs) || !gs[at - 1].soft || gs[at - 1].hyph_adv <= 0 do return false
	gs[at - 1].adv = gs[at - 1].hyph_adv
	gs[at - 1].ctrl = false
	return true
}

// typeset_fill fills lines from one paragraph's glyphs, greedily: a line
// takes glyphs until the next would pass the wrap width, then breaks at the
// last opportunity UAX #14 gives (or before that glyph's character, when a
// word is longer than the line). Spaces hang: they never push a line over.
//
// `style.hyphen_limit` is honoured as far as a greedy fill can: a word is
// not hyphenated when the lines before it already end in that many hyphens
// *and* the line has a break that needs no hyphen to fall back to. No
// hyphen on the paragraph's last full line is a trade between two lines,
// so it needs `.Even` (Typeset_Breaking).
@(private)
typeset_fill :: proc(text: string, ps, pe, first: int, shaped: ^[dynamic]Typeset_Shaped, pending: ^[dynamic]Typeset_Pending, style: Typeset_Style, cell: f32, rtl: bool, ind: Typeset_Indent = {}) {
	offs, allowed := typeset_breaks(text, ps, pe)
	wrap := style.wrap_width
	limit := style.hyphen_limit if style.hyphen_limit != 0 else TYPESET_HYPHEN_LIMIT
	gs := shaped[first:]
	line, nline := 0, 0
	run_hyphens := 0           // lines in a row, up to here, that end in a hyphen
	cur: f32
	room := wrap - typeset_indent_of(ind, 0) // this line's own width, which the first line and a dropped letter narrow
	brk, brk_w := -1, f32(0)   // the last glyph a line may start at, and the width it would leave behind
	hard := -1                 // the last one that is not a hyphenation point, as the fallback
	for i in 0 ..< len(gs) {
		g := &gs[i]
		if i > line && g.start != gs[i - 1].start && typeset_may_break(offs, allowed, g.start) {
			brk, brk_w = i, cur
			if !gs[i - 1].soft do hard = i
		}
		if g.tab do g.adv = typeset_tab_stop(cur, cell) + g.track
		if wrap > 0 && i > line && !g.hang && cur + g.adv - g.track > room + 1e-3 {
			at := brk
			// Breaking at a hyphenation point costs the hyphen that gets
			// drawn, which the fit above did not count. Where it no longer
			// fits, fall back to the last break that needs no hyphen —
			// and where there is no such break, the hyphen is drawn anyway
			// and the line runs over, as a word longer than its line does.
			// A reader must be told the word continues; three pixels of
			// overhang says less than a missing hyphen would.
			if at > line && gs[at - 1].soft {
				over := brk_w + gs[at - 1].hyph_adv > room + 1e-3
				// …and a hyphen too many in a row is given up where there
				// is somewhere else to break. Greedily there often is not,
				// which is the honest limit of filling a line at a time.
				if over do at = hard
				else if limit > 0 && run_hyphens >= limit && hard > line do at = hard
			}
			if at <= line { // no opportunity: before this character, unless it is the line's first
				at = i
				for at > line && gs[at - 1].start == g.start do at -= 1
			}
			if at > line {
				hyphen := typeset_hyphen_show(gs, at)
				typeset_emit(pending, gs, first, line, at, ps, pe, false, rtl, hyphen, typeset_indent_of(ind, nline))
				run_hyphens = run_hyphens + 1 if hyphen else 0
				line = at
				nline += 1
				room = wrap - typeset_indent_of(ind, nline)
				brk, hard = -1, -1
				cur = 0
				for j in line ..< i {
					if gs[j].tab do gs[j].adv = typeset_tab_stop(cur, cell) + gs[j].track
					cur += gs[j].adv
				}
				if g.tab do g.adv = typeset_tab_stop(cur, cell) + g.track
			}
		}
		cur += g.adv
	}
	if len(gs) == 0 {
		append(pending, Typeset_Pending{first = first, start = ps, end = pe, last = true, rtl = rtl, indent = typeset_indent_of(ind, 0)})
		return
	}
	typeset_emit(pending, gs, first, line, len(gs), ps, pe, true, rtl, false, typeset_indent_of(ind, nline))
}

// Typeset_Break_Item is one item of the stream runa chooses breaks over,
// with the glyph a line *after* that break begins at — which is all the
// filler needs to turn runa's answer back into lines.
@(private)
Typeset_Break_Item :: struct {
	item: linebreak.Item,
	at:   int, // -1 for material no line can break at
}

// typeset_items turns a paragraph's glyphs into the box/glue/penalty stream
// Knuth–Plass works on (runa's `linebreak`), each break candidate carrying
// the glyph the next line starts at.
//
//   - a box is material no line may break inside: a word, and anything a
//     break is not allowed after (a non-breaking space is part of its box);
//   - a run of spaces a line may break after is glue — the space that
//     disappears at a break and stretches where a line is justified;
//   - every other break opportunity is a penalty of no width: after a
//     hyphen already in the text, between two Chinese characters, at a
//     Thai word boundary;
//   - a soft hyphen is a *flagged* penalty as wide as the hyphen that would
//     be drawn, which is how "at most two hyphens in a row" and "no hyphen
//     on the last full line" are expressible at all.
//
// Glue stretches half a space and shrinks a third of one, Knuth's own
// setting — **but only where the lines will be justified**, because only a
// justified line is ever tightened (typeset_justify). Offered shrink it
// cannot use, the breaker would choose lines wider than the measure. So a
// ragged paragraph's glue has no shrink, and `typeset` tightens a line the
// breaker chose tight by at most a third of a space.
@(private)
typeset_items :: proc(gs: []Typeset_Shaped, offs: []int, allowed: []bool, justify: bool) -> []Typeset_Break_Item {
	out := make([dynamic]Typeset_Break_Item, 0, len(gs) / 4 + 8, context.temp_allocator)
	box: f32 // material since the last item
	put :: proc(out: ^[dynamic]Typeset_Break_Item, box: ^f32, it: linebreak.Item, at: int) {
		append(out, Typeset_Break_Item{item = linebreak.box(box^), at = -1})
		box^ = 0
		append(out, Typeset_Break_Item{item = it, at = at})
	}
	for i := 0; i < len(gs); {
		g := gs[i]
		switch {
		case g.soft:
			// A hyphenation point. Nothing is drawn unless a line ends
			// here, so the width belongs to the penalty, not to a box.
			if i > 0 do put(&out, &box, linebreak.penalty(TYPESET_HYPHEN_PENALTY, g.hyph_adv, true), i + 1)
			i += 1
		case g.space || g.hang:
			j, w := i, f32(0)
			for j < len(gs) && (gs[j].space || gs[j].hang) && !gs[j].soft {
				w += gs[j].adv
				j += 1
			}
			if i > 0 && j < len(gs) && typeset_may_break(offs, allowed, gs[j].start) {
				put(&out, &box, linebreak.glue(w, w * 0.5, w * TYPESET_SHRINK if justify else 0), j)
			} else {
				box += w // a space no line may break after: ordinary material
			}
			i = j
		case i > 0 && g.start != gs[i - 1].start && !gs[i - 1].soft && typeset_may_break(offs, allowed, g.start) &&
		     (len(out) == 0 || out[len(out) - 1].at != i): // the glue before it may already be this break
			put(&out, &box, linebreak.penalty(0), i)
			box += g.adv
			i += 1
		case:
			box += g.adv
			i += 1
		}
	}
	append(&out, Typeset_Break_Item{item = linebreak.box(box), at = -1})
	return out[:]
}

// typeset_fill_even fills a paragraph's lines by choosing every break
// together: runa's `break_lines` (Knuth–Plass total fit) over the stream
// typeset_items builds. The lines come back as breakpoints, which are
// turned into the same Typeset_Pending a greedy fill makes — so
// justification, hanging punctuation, the dropped letter and right-to-left
// reordering are the same code afterwards.
//
// Nothing here can fail into nothing: runa widens its tolerance and then
// falls back to a greedy fit, so a paragraph with an unbreakable word
// longer than its measure still comes back with lines (that word overhangs,
// as it does in a greedy fill).
@(private)
typeset_fill_even :: proc(text: string, ps, pe, first: int, shaped: ^[dynamic]Typeset_Shaped, pending: ^[dynamic]Typeset_Pending, style: Typeset_Style, cell: f32, rtl: bool, ind: Typeset_Indent = {}) {
	gs := shaped[first:]
	if len(gs) == 0 {
		append(pending, Typeset_Pending{first = first, start = ps, end = pe, last = true, rtl = rtl, indent = typeset_indent_of(ind, 0)})
		return
	}
	offs, allowed := typeset_breaks(text, ps, pe)
	stream := typeset_items(gs, offs, allowed, style.justify)
	items := make([]linebreak.Item, len(stream), context.temp_allocator)
	for it, i in stream do items[i] = it.item

	// One width per line, the last repeating: the first line's indent and
	// the lines a dropped letter reaches are narrower than the rest, and
	// the breaking has to know that while it chooses, not after.
	nw := max(ind.lines, 1) + 1
	widths := make([]f32, nw, context.temp_allocator)
	for n in 0 ..< nw do widths[n] = style.wrap_width - typeset_indent_of(ind, n)
	widths[nw - 1] = style.wrap_width

	limit := style.hyphen_limit if style.hyphen_limit != 0 else TYPESET_HYPHEN_LIMIT
	params := linebreak.Break_Params{
		ragged                  = !style.justify,
		max_consecutive_hyphens = max(limit, 0),
		final_hyphen_demerits   = TYPESET_LAST_HYPHEN_DEMERITS,
	}
	breaks, ok := linebreak.break_lines(items, widths, params, context.temp_allocator)
	if !ok {
		typeset_fill(text, ps, pe, first, shaped, pending, style, cell, rtl, ind)
		return
	}
	line, nline := 0, 0
	for b in breaks {
		at := stream[b.item].at if b.item < len(stream) else len(gs)
		if at > len(gs) do at = len(gs) // the forced break runa adds past the end
		if at <= line do continue       // a break with nothing on its line
		last := at >= len(gs)
		hyphen := !last && typeset_hyphen_show(gs, at) // a paragraph ending in a soft hyphen draws nothing
		typeset_emit(pending, gs, first, line, at, ps, pe, last, rtl, hyphen, typeset_indent_of(ind, nline))
		line = at
		nline += 1
		if last do return
	}
	typeset_emit(pending, gs, first, line, len(gs), ps, pe, true, rtl, false, typeset_indent_of(ind, nline))
}

// typeset_justify spreads `extra` over a line's spaces (not the ones that
// hang), or where it has none (Chinese, Japanese) between its characters.
// False when there is nowhere to put it.
@(private)
typeset_justify :: proc(line: []Typeset_Shaped, extra: f32) -> bool {
	end := len(line)
	for end > 0 && line[end - 1].hang do end -= 1
	spaces := 0
	for g in line[:end] do if g.space do spaces += 1
	if spaces > 0 {
		for &g in line[:end] do if g.space do g.extra = extra / f32(spaces)
		return true
	}
	gaps := 0
	for i in 0 ..< end - 1 do if line[i + 1].start != line[i].start do gaps += 1
	if gaps == 0 do return false
	for i in 0 ..< end - 1 do if line[i + 1].start != line[i].start do line[i].extra = extra / f32(gaps)
	return true
}

// typeset_hangs is a space that hangs past a line's end when a wrap falls
// after it.
@(private)
typeset_hangs :: proc "contextless" (r: rune) -> bool {
	switch r {
	case ' ', 0x1680, 0x2000 ..= 0x2006, 0x2008 ..= 0x200A, 0x205F, 0x3000: return true
	}
	return false
}

// typeset_hang_out is how much of a character may sit *outside* the margin
// when it begins or ends a line — optical margin alignment, which is what
// makes a justified page look straight. A line ending in a comma is
// optically short where a line ending in "n" is not, because a comma is
// nearly all white space; hanging it fixes what the eye sees rather than
// what the ruler says.
//
// The fractions are chosen, not derived — there is no standard to follow,
// and typesetters differ. They follow how much of the character's own box
// is ink: a stop or a comma is a speck in a wide box and hangs half; a
// hyphen and the quotes are light and narrow and hang most of the way; a
// bracket is heavy enough that hanging it reads as a mistake, so it does
// not. Returned as a fraction of the character's advance, for the start of
// a line and for its end.
@(private)
typeset_hang_out :: proc "contextless" (r: rune, at_start: bool) -> f32 {
	if at_start {
		switch r {
		case '\'', '"', 0x2018, 0x201C, 0x201A, 0x201E, 0x00AB, 0x2039: return 0.7 // the quotes a paragraph opens with
		}
		return 0
	}
	switch r {
	case '.', ',', 0x3001, 0x3002:                                  return 0.5 // a stop or a comma: mostly white
	case '-', 0x2010, 0x2011, 0x2013, 0x2014, 0x00AD:                return 0.6 // hyphens and dashes, including the drawn soft one
	case '\'', '"', 0x2019, 0x201D, 0x00BB, 0x203A:                  return 0.7 // the quotes a sentence closes with
	case ';', ':', '!', '?':                                        return 0.2 // heavier, so only a little
	}
	return 0
}

// typeset_cursive is a character of a script whose letters join, which
// tracking would pull apart.
@(private)
typeset_cursive :: proc(text: string, at: int) -> bool {
	r, _ := utf8.decode_rune_in_string(text[at:])
	tag :: proc "contextless" (s: string) -> itemize.Script_Code {
		return itemize.Script_Code(u32(s[0]) << 24 | u32(s[1]) << 16 | u32(s[2]) << 8 | u32(s[3]))
	}
	switch itemize.script_of(r) {
	case tag("Arab"), tag("Syrc"), tag("Mong"), tag("Nkoo"), tag("Mand"), tag("Adlm"), tag("Rohg"), tag("Phag"): return true
	}
	return false
}

// typeset_unreorder undoes UAX #9 L2 on a line runa gave in the order it
// is seen: the same reversals, lowest level first, give the order it is
// read.
@(private)
typeset_unreorder :: proc(gs: []runa.Paragraph_Glyph) {
	highest, lowest_odd := u8(0), u8(255)
	for g in gs {
		highest = max(highest, g.level)
		if g.level & 1 == 1 do lowest_odd = min(lowest_odd, g.level)
	}
	if lowest_odd == 255 do return
	for level := int(lowest_odd); level <= int(highest); level += 1 {
		for i := 0; i < len(gs); {
			if int(gs[i].level) < level {
				i += 1
				continue
			}
			j := i
			for j < len(gs) && int(gs[j].level) >= level do j += 1
			slice.reverse(gs[i:j])
			i = j
		}
	}
}

// typeset_reorder is UAX #9 L2: a line in the order it is read, put in the
// order it is seen.
@(private)
typeset_reorder :: proc(gs: []Typeset_Shaped) {
	highest, lowest_odd := u8(0), u8(255)
	for g in gs {
		highest = max(highest, g.level)
		if g.level & 1 == 1 do lowest_odd = min(lowest_odd, g.level)
	}
	if lowest_odd == 255 do return
	for level := int(highest); level >= int(lowest_odd); level -= 1 {
		for i := 0; i < len(gs); {
			if int(gs[i].level) < level {
				i += 1
				continue
			}
			j := i
			for j < len(gs) && int(gs[j].level) >= level do j += 1
			slice.reverse(gs[i:j])
			i = j
		}
	}
}

// typeset_ink is where the glyphs' pixels fall: their outlines' bounds, a
// colour glyph's em box.
@(private)
typeset_ink :: proc(ts: ^Typeset) -> Rect {
	lo := [2]f32{max(f32), max(f32)}
	hi := [2]f32{min(f32), min(f32)}
	outline: runa.Outline
	defer runa.outline_destroy(&outline)
	for g in ts.glyphs {
		if g.blank do continue
		if g.color {
			lo = {min(lo.x, g.x0), min(lo.y, g.pos.y - g.font.ascent * g.scale)}
			hi = {max(hi.x, g.x1), max(hi.y, g.pos.y - g.font.descent * g.scale)}
			continue
		}
		clear(&outline.points)
		clear(&outline.contour_ends)
		if runa.font_glyph_outline(g.font, g.id, &outline) != .None do continue
		for pt in outline.points {
			p := [2]f32{g.pos.x + f32(pt.x) * g.scale, g.pos.y - f32(pt.y) * g.scale}
			lo = {min(lo.x, p.x), min(lo.y, p.y)}
			hi = {max(hi.x, p.x), max(hi.y, p.y)}
		}
	}
	if hi.x < lo.x do return {}
	return {lo.x, lo.y, hi.x - lo.x, hi.y - lo.y}
}

// typeset_line_of is the line the caret at byte `offset` is on: where a
// wrap splits the text, the line after it.
typeset_line_of :: proc(ts: ^Typeset, offset: int) -> int {
	n := len(ts.lines)
	if n == 0 do return 0
	o := clamp(offset, 0, len(ts.text))
	for l, i in ts.lines {
		if o < l.start do return max(i - 1, 0) // inside the line break before this line
		if o < l.end do return i
		if o == l.end && (i == n - 1 || ts.lines[i + 1].start != o) do return i
	}
	return n - 1
}

// typeset_caret is where the caret goes at byte `offset`: a rectangle of no
// width at its x, as tall as its line, from the box's top-left. An offset
// inside a character is placed as far through it as its graphemes say (a
// caret inside a ligature); one where a wrap splits the text is at the
// start of the next line.
typeset_caret :: proc(ts: ^Typeset, offset: int) -> Rect {
	if len(ts.lines) == 0 do return {}
	o := clamp(offset, 0, len(ts.text))
	li := typeset_line_of(ts, o)
	l := ts.lines[li]
	return {typeset_caret_x(ts, li, o), l.rect.y, 0, l.rect.h}
}

// typeset_caret_x is the caret's x at `o` on line `li`.
@(private)
typeset_caret_x :: proc(ts: ^Typeset, li, o: int) -> f32 {
	span := ts.spans[li]
	gs := ts.glyphs[span[0]:][:span[1]]
	lo, hi := max(f32), min(f32)
	start, end := -1, -1
	rtl := false
	for g in gs do if g.start <= o && o < g.end { // the character the caret is at
		lo, hi = min(lo, g.x0), max(hi, g.x1)
		start, end, rtl = g.start, g.end, g.rtl
	}
	if start >= 0 {
		f: f32
		if o > start do f = f32(grapheme_count(ts.text[start:o])) / f32(max(grapheme_count(ts.text[start:end]), 1))
		return hi - f * (hi - lo) if rtl else lo + f * (hi - lo)
	}
	before := -1 // none: after the character before it, on its far side
	for g in gs do if g.start < o && g.start > before do before = g.start
	if before < 0 do return ts.lines[li].rect.x + (ts.lines[li].rect.w if ts.lines[li].rect.w > 0 && typeset_line_rtl(ts, li) else 0)
	lo, hi = max(f32), min(f32)
	for g in gs do if g.start == before {
		lo, hi = min(lo, g.x0), max(hi, g.x1)
		rtl = g.rtl
	}
	return lo if rtl else hi
}

// typeset_line_rtl is whether a line's glyphs run right to left.
@(private)
typeset_line_rtl :: proc(ts: ^Typeset, li: int) -> bool {
	span := ts.spans[li]
	for g in ts.glyphs[span[0]:][:span[1]] do return g.rtl
	return false
}

// typeset_hit is the byte offset of the caret place nearest `pos` (from
// the box's top-left): on the line under it, the first or last line above
// or below the text, the nearest grapheme boundary across. Where a wrap
// ends a line, the place before its last character is as far as that line
// goes; the one after it is the next line's first.
typeset_hit :: proc(ts: ^Typeset, pos: [2]f32) -> int {
	n := len(ts.lines)
	if n == 0 do return 0
	li := n - 1
	for l, i in ts.lines do if pos.y < l.rect.y + l.rect.h {
		li = i
		break
	}
	l := ts.lines[li]
	soft := li + 1 < n && ts.lines[li + 1].start == l.end // a wrap ends it
	best, best_d := l.start, max(f32)
	for b := l.start; b <= l.end; b = grapheme_next(ts.text, b) {
		if b == l.end && soft && b > l.start do break
		if d := abs(typeset_caret_x(ts, li, b) - pos.x); d < best_d do best, best_d = b, d
		if b == l.end do break
	}
	return best
}

// typeset_rects is the rectangles covering bytes `lo..hi` of the text, from
// the box's top-left: one per line, and more where a line mixes directions.
// A selection's highlight, or, given one character's bytes, where that
// character is. The slice is `allocator`'s.
typeset_rects :: proc(ts: ^Typeset, lo, hi: int, allocator := context.allocator) -> []Rect {
	a, b := clamp(min(lo, hi), 0, len(ts.text)), clamp(max(lo, hi), 0, len(ts.text))
	out := make([dynamic]Rect, allocator)
	if a == b do return out[:]
	spans := make([dynamic][2]f32, context.temp_allocator)
	for l, li in ts.lines {
		if l.end <= a || l.start >= b do continue
		clear(&spans)
		span := ts.spans[li]
		gs := ts.glyphs[span[0]:][:span[1]]
		for g, i in gs {
			if i > 0 && gs[i - 1].start == g.start do continue // a character's first glyph speaks for it
			s, e := max(a, g.start), min(b, g.end)
			if s >= e do continue
			x0, x1 := max(f32), min(f32)
			for h in gs do if h.start == g.start do x0, x1 = min(x0, h.x0), max(x1, h.x1)
			if s > g.start || e < g.end { // part of a ligature: by its graphemes
				whole := f32(max(grapheme_count(ts.text[g.start:g.end]), 1))
				f0 := f32(grapheme_count(ts.text[g.start:s])) / whole
				f1 := f32(grapheme_count(ts.text[g.start:e])) / whole
				w := x1 - x0
				if g.rtl {
					x0, x1 = x1 - f1 * w, x1 - f0 * w
				} else {
					x0, x1 = x0 + f0 * w, x0 + f1 * w
				}
			}
			append(&spans, [2]f32{x0, x1})
		}
		slice.sort_by(spans[:], proc(p, q: [2]f32) -> bool { return p[0] < q[0] })
		for i := 0; i < len(spans); {
			x0, x1 := spans[i][0], spans[i][1]
			j := i + 1
			for j < len(spans) && spans[j][0] <= x1 + 0.01 {
				x1 = max(x1, spans[j][1])
				j += 1
			}
			append(&out, Rect{x0, l.rect.y, x1 - x0, l.rect.h})
			i = j
		}
	}
	return out[:]
}

// typeset_draw sets the text into `img` with its box's top-left at `at`
// in the picture's pixels (fractions allowed), in `color`. The glyphs'
// outlines are filled with exact coverage and laid on as image_paint lays
// a colour, on the stored sRGB values. Colour emoji keep their own colours
// and fade with `color`'s alpha. The part drawn is touched (image_touch).
typeset_draw :: proc(ts: ^Typeset, img: ^Image, at: [2]f32, color: Color) {
	if ts == nil || img == nil || len(img.pixels) < img.width * img.height * 4 do return
	area := Mask{origin = {0, 0}, size = {img.width, img.height}}
	x0, y0, x1, y1, inside := typeset_area(ts, &area, at)
	if !inside do return
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	m, ok := mask_make({x0, y0}, {x1 - x0, y1 - y0})
	if !ok do return
	typeset_cover(ts, &m, at)
	image_paint(img, &m, color)
	typeset_color(ts, at, clamp(color.a, 0, 1), img, nil)
}

// typeset_mask puts the text's coverage into `m` by `op`, its box's
// top-left at `at` in the mask's space: a text layer's mask, or a
// selection made from type. Colour glyphs count by their shape.
typeset_mask :: proc(ts: ^Typeset, m: ^Mask, at: [2]f32, op := Mask_Op.Add) {
	if ts == nil || m == nil || len(m.alpha) < m.size.x * m.size.y || m.size.x <= 0 do return
	x0, y0, x1, y1, inside := typeset_area(ts, m, at)
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	if op == .Add {
		if inside {
			typeset_cover(ts, m, at)
			typeset_color(ts, at, 1, nil, m)
		}
		return
	}
	cover: Mask
	if inside {
		cover, _ = mask_make({x0, y0}, {x1 - x0, y1 - y0})
		typeset_cover(ts, &cover, at)
		typeset_color(ts, at, 1, nil, &cover)
	}
	clears := op == .Intersect || op == .Replace // outside the text, nothing is kept
	for y in 0 ..< m.size.y {
		row := m.alpha[y * m.size.x:][:m.size.x]
		gy := m.origin.y + y
		if !inside || gy < y0 || gy >= y1 {
			if clears do slice.zero(row)
			continue
		}
		cov := cover.alpha[(gy - y0) * cover.size.x:]
		for &v, x in row {
			gx := m.origin.x + x
			if gx < x0 || gx >= x1 {
				if clears do v = 0
				continue
			}
			c := cov[gx - x0]
			switch op {
			case .Add:       v = max(v, c)
			case .Subtract:  v = min(v, 255 - c)
			case .Intersect: v = min(v, c)
			case .Replace:   v = c
			}
		}
	}
}

// typeset_area is the pixels of `m` the text's ink reaches, placed at `at`.
@(private)
typeset_area :: proc(ts: ^Typeset, m: ^Mask, at: [2]f32) -> (x0, y0, x1, y1: int, ok: bool) {
	if ts.ink.w <= 0 || ts.ink.h <= 0 do return
	x0 = max(int(math.floor(at.x + ts.ink.x)) - 1, m.origin.x)
	y0 = max(int(math.floor(at.y + ts.ink.y)) - 1, m.origin.y)
	x1 = min(int(math.ceil(at.x + ts.ink.x + ts.ink.w)) + 1, m.origin.x + m.size.x)
	y1 = min(int(math.ceil(at.y + ts.ink.y + ts.ink.h)) + 1, m.origin.y + m.size.y)
	return x0, y0, x1, y1, x1 > x0 && y1 > y0
}

// typeset_cover adds every outline glyph's coverage into `m` (the union:
// each glyph on its own, so two that overlap never cancel). Working
// memory is the context's.
@(private)
typeset_cover :: proc(ts: ^Typeset, m: ^Mask, at: [2]f32) {
	r := mask_raster_make(m, .Add, true)
	xf := mask_xf(m)
	outline: runa.Outline
	for g in ts.glyphs {
		if g.color || g.blank do continue
		clear(&outline.points)
		clear(&outline.contour_ends)
		if runa.font_glyph_outline(g.font, g.id, &outline) != .None || len(outline.contour_ends) == 0 do continue
		p := svg_path_make(SVG_XF_ID)
		svg_glyph_path(&p, &outline, at + g.pos, g.scale)
		svg_raster_path(r, &p, xf)
		svg_raster_fill(r, false)
	}
}

// typeset_color draws the colour glyphs: into `img` over what is there,
// at `alpha`, or their coverage into `m`.
@(private)
typeset_color :: proc(ts: ^Typeset, at: [2]f32, alpha: f32, img: ^Image, m: ^Mask) {
	for g in ts.glyphs do if g.color do typeset_color_glyph(g, at, alpha, img, m)
}

// typeset_color_glyph rasterises one colour glyph with memory of its own,
// given back before the next (a big emoji's bitmap is megabytes).
@(private)
typeset_color_glyph :: proc(g: Typeset_Glyph, at: [2]f32, alpha: f32, img: ^Image, m: ^Mask) {
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil do return
	defer virtual.arena_destroy(&scratch)
	context.allocator = virtual.arena_allocator(&scratch)
	context.temp_allocator = context.allocator
	{
		em := g.scale * f32(g.font.units_per_em)
		px := min(em, COLOR_GLYPH_MAX_PX)
		side := u16(clamp(int(px * 2) + 16, 64, 65535))
		atlas := runa.atlas_make(side, side)
		slot, err := runa.raster_glyph(g.font, g.id, px, 0, &atlas, hint = false)
		if err != .None || slot.px_size.x == 0 || slot.px_size.y == 0 || int(slot.page_index) >= len(atlas.pages_color) || !slot.is_color do return
		page := atlas.pages_color[slot.page_index]
		sx := int(slot.uv_rect[0] * f32(page.width) + 0.5)
		sy := int(slot.uv_rect[1] * f32(page.height) + 0.5)
		sw, sh := int(slot.px_size.x), int(slot.px_size.y)
		k := em / px
		o := at + g.pos + slot.bearing * k // the bitmap's top-left
		typeset_color_blit(page.pixels, int(page.width), sx, sy, sw, sh, o, k, alpha, img, m)
	}
}

// typeset_color_blit lays a straight-alpha RGBA bitmap (`sw` × `sh` at
// `sx, sy` in rows `stride` wide) with its top-left at `o`, `k` times its
// size, sampled bilinearly (premultiplied, so edges do not darken).
@(private)
typeset_color_blit :: proc(px: []u8, stride, sx, sy, sw, sh: int, o: [2]f32, k, alpha: f32, img: ^Image, m: ^Mask) {
	bw, bh := f32(sw) * k, f32(sh) * k
	lo_x, lo_y := int(math.floor(o.x)), int(math.floor(o.y))
	hi_x, hi_y := int(math.ceil(o.x + bw)), int(math.ceil(o.y + bh))
	if img != nil {
		lo_x, lo_y = max(lo_x, 0), max(lo_y, 0)
		hi_x, hi_y = min(hi_x, img.width), min(hi_y, img.height)
	} else {
		lo_x, lo_y = max(lo_x, m.origin.x), max(lo_y, m.origin.y)
		hi_x, hi_y = min(hi_x, m.origin.x + m.size.x), min(hi_y, m.origin.y + m.size.y)
	}
	if hi_x <= lo_x || hi_y <= lo_y do return
	texel :: proc(px: []u8, stride, sx, sy, sw, sh, x, y: int) -> [4]f32 {
		if x < 0 || y < 0 || x >= sw || y >= sh do return {}
		p := px[((sy + y) * stride + sx + x) * 4:][:4]
		a := f32(p[3]) / 255
		return {f32(p[0]) / 255 * a, f32(p[1]) / 255 * a, f32(p[2]) / 255 * a, a}
	}
	for y in lo_y ..< hi_y {
		for x in lo_x ..< hi_x {
			u := (f32(x) + 0.5 - o.x) / k - 0.5
			v := (f32(y) + 0.5 - o.y) / k - 0.5
			ix, iy := int(math.floor(u)), int(math.floor(v))
			fx, fy := u - f32(ix), v - f32(iy)
			c := texel(px, stride, sx, sy, sw, sh, ix, iy) * (1 - fx) * (1 - fy) + texel(px, stride, sx, sy, sw, sh, ix + 1, iy) * fx * (1 - fy) + texel(px, stride, sx, sy, sw, sh, ix, iy + 1) * (1 - fx) * fy + texel(px, stride, sx, sy, sw, sh, ix + 1, iy + 1) * fx * fy
			sa := c.a * alpha
			if sa <= 0 do continue
			if m != nil {
				i := (y - m.origin.y) * m.size.x + (x - m.origin.x)
				m.alpha[i] = max(m.alpha[i], u8(clamp(c.a, 0, 1) * 255 + 0.5))
				continue
			}
			d := img.pixels[(y * img.width + x) * 4:][:4]
			da := f32(d[3]) / 255
			oa := sa + da * (1 - sa)
			for ch in 0 ..< 3 {
				out := (c[ch] * alpha + f32(d[ch]) / 255 * da * (1 - sa)) / oa
				d[ch] = u8(clamp(out, 0, 1) * 255 + 0.5)
			}
			d[3] = u8(clamp(oa, 0, 1) * 255 + 0.5)
		}
	}
	if img != nil do image_touch(img, lo_x, lo_y, hi_x - lo_x, hi_y - lo_y)
}

// typeset_face is the face for a family, weight and slant, loaded the
// first time: the family's nearest face (a variable one set to the weight),
// or the theme's typeface for "" and for a family this machine does not
// have. A face the shaper draws few glyphs of (CID-keyed CFF) is passed
// over, as the fallback passes it over.
@(private)
typeset_face :: proc(te: ^Text_Engine, family: string, weight: int, italic: bool) -> Typeset_Face {
	w := clamp(weight, 1, 1000)
	// "" is the theme's typeface — which is a family of this machine's when
	// the theme names one, keyed under that name so a run that asked for it
	// outright is the same face.
	family := family
	if family == "" do family = text_family_name(te, te.ui_family)
	key := Typeset_Face_Key{strings.to_lower(family, context.temp_allocator), i32(w), italic}
	if f, had := te.typeset_faces[key]; had do return f
	out: Typeset_Face
	if family != "" {
		idx := font_index(te)
		for name, files in idx.families do if strings.equal_fold(name, family) {
			if file, found := family_pick(files[:], w, italic); found {
				if f := typeset_face_load(te, file, italic); f != nil {
					out = {font = f, family = strings.clone(name, te.allocator), weight = file.weight}
					if file.variable do out.weight = typeset_set_weight(f, w, file.weight)
				}
			}
			break
		}
	}
	if out.font == nil {
		slot := Font_Slot.Italic if italic else Font_Slot.UI
		if loaded, err := runa.font_load(font_data(slot), te.allocator); err == .None {
			f := new(runa.Font, te.allocator)
			f^ = loaded
			out = {font = f, weight = typeset_set_weight(f, w, 400)}
		}
	}
	key.family = strings.clone(key.family, te.allocator)
	te.typeset_faces[key] = out
	return out
}

// typeset_face_load loads a face's file (its bytes read once, whatever
// weights it is set to), sloping a variable face that has no italic of its
// own through its ital or slnt axis.
@(private)
typeset_face_load :: proc(te: ^Text_Engine, file: Font_Face_File, italic: bool) -> ^runa.Font {
	name := fmt.tprintf("%s#%d", file.path, file.face)
	blob, had := te.typeset_blobs[name]
	if !had {
		data, err := os.read_entire_file_from_path(file.path, te.allocator)
		if err != nil do return nil
		face, copied, ok := sfnt_face_extract(data, file.face, te.allocator)
		if copied do delete(data, te.allocator)
		if !ok {
			if !copied do delete(data, te.allocator)
			return nil
		}
		blob = face
		te.typeset_blobs[strings.clone(name, te.allocator)] = blob
	}
	loaded, ferr := runa.font_load(blob, te.allocator)
	if ferr != .None do return nil
	f := new(runa.Font, te.allocator)
	f^ = loaded
	if italic && !file.italic && file.variable {
		ital := runa.Axis_Tag(u32('i') << 24 | u32('t') << 16 | u32('a') << 8 | u32('l'))
		slnt := runa.Axis_Tag(u32('s') << 24 | u32('l') << 16 | u32('n') << 8 | u32('t'))
		if runa.font_set_variation(f, ital, 1) != .None do _ = runa.font_set_variation(f, slnt, -10)
	}
	return f
}

// typeset_set_weight sets a face's wght axis to `weight`, within the axis's
// range, and says what it was set to (`fallback` for a face without one).
@(private)
typeset_set_weight :: proc(f: ^runa.Font, weight, fallback: int) -> int {
	wght := runa.Axis_Tag(u32('w') << 24 | u32('g') << 16 | u32('h') << 8 | u32('t'))
	for ax in runa.font_axes(f) do if ax.tag == wght {
		v := clamp(f32(weight), ax.min_value, ax.max_value)
		_ = runa.font_set_variation(f, wght, v)
		return int(math.round(v))
	}
	return fallback
}

// typeset_faces_refresh forgets the faces that stood in for a family not
// found while the font list was being read, so the next
// typeset looks for it again. Their fonts stay until the engine goes: a
// Typeset set with one still points at it.
@(private)
typeset_faces_refresh :: proc(te: ^Text_Engine) {
	stale := make([dynamic]Typeset_Face_Key, context.temp_allocator)
	for key, face in te.typeset_faces do if key.family != "" && face.family == "" do append(&stale, key)
	for key in stale {
		face := te.typeset_faces[key]
		if face.font != nil do append(&te.typeset_retired, face.font)
		delete_key(&te.typeset_faces, key)
		delete(key.family, te.allocator)
	}
}

@(private)
typeset_faces_destroy :: proc(te: ^Text_Engine) {
	for f in te.typeset_retired {
		runa.font_destroy(f)
		free(f, te.allocator)
	}
	delete(te.typeset_retired)
	for key, face in te.typeset_faces {
		if face.font != nil {
			runa.font_destroy(face.font)
			free(face.font, te.allocator)
		}
		if len(face.family) > 0 do delete(face.family, te.allocator)
		delete(key.family, te.allocator)
	}
	delete(te.typeset_faces)
	for name, blob in te.typeset_blobs {
		delete(name, te.allocator)
		delete(blob, te.allocator)
	}
	delete(te.typeset_blobs)
}
