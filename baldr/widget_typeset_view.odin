package baldr

import "core:math"
import "core:strings"

// typeset_view: a range of a laid-out paragraph's lines, drawn in the UI —
// a book reader's page.
//
// A page is the end of one paragraph, some whole ones, and the start of
// another. The app lays each paragraph out once with `typeset` (lines with
// byte ranges, heights and baselines), decides where the page breaks, and
// builds one of these per paragraph on the page, naming which lines to draw.
//
// Nothing is laid out here: a type-size change re-lays the chapter once, and
// turning pages costs only drawing. Each glyph is rasterised at its run's
// size in device pixels, so the page is crisp at any scale.
//
// The Typeset belongs to the app and must outlive every build that names it:
// the node holds a pointer, not a copy, and so does the screen reader's text.
// Lay out in `update`, keep it in the app's state, and `typeset_destroy` it
// when the chapter or the type size changes.
//
//	// the lines of this paragraph that fall on this page
//	baldr.typeset_view(ui, &s.paras[i].ts, first = 4, count = 9)

// Typeset_View_State is what a typeset_view node keeps past the build, so
// paint has it. The Typeset itself is the app's.
@(private)
Typeset_View_State :: struct {
	ts:           ^Typeset,
	serial:       u64,    // the Typeset's serial when last read: a freed address can be reused, a serial is not
	first, count: int,
	ink:          Color,
	over:         f32,    // how far the glyphs reach outside the box (typeset_view_overhang)
	read:         string, // the text a reader is given: the Typeset's own bytes, or a cleaned copy
	read_owned:   bool,   // …and whether that copy is this widget's to free
}

// typeset_view draws lines `first ..< first + count` of `ts` (a `count` of
// -1, the default, is the rest of them). The node is as wide as the
// Typeset's box and as tall as the lines it draws, so a column of them
// stacks into a page with the paragraph spacing the app puts between them.
//
// `ink` is what text is drawn in — the theme's own text colour when it is
// left out. A run that carries its own `ink` keeps it, which is how a link,
// dimmed text or a sepia theme's colours reach the page; a run whose ink has
// no alpha takes this one.
//
// `label` names the node for a screen reader; the words themselves are its
// accessible text, the paragraph's source over those lines, so a word broken
// across a line is still one word and the drawn hyphen is not in it.
typeset_view :: proc(ui: ^Ui($Msg), ts: ^Typeset, first: int = 0, count: int = -1,
	ink: Color = {}, label: string = "", width: f32 = 0, flex: f32 = 0,
	key: u64 = 0, loc := #caller_location) -> Node {
	n, created := reconcile_child(ui, .Custom, key, loc)
	t := &ui.tree
	d := node_get(t, n)
	if d == nil do return n
	if created {
		d.access.role = .Text
		t.typesets[n] = Typeset_View_State{}
	}
	st := &t.typesets[n]
	if st == nil do return n

	lo, hi := typeset_view_range(ts, first, count)
	serial := ts.serial if ts != nil else 0
	changed := st.ts != ts || st.serial != serial || st.first != lo || st.count != hi - lo
	if changed || st.ink != ink {
		st.ts, st.serial, st.first, st.count, st.ink = ts, serial, lo, hi - lo, ink
		mark_paint_dirty(t, n)
	}
	if changed || created {
		st.over = typeset_view_overhang(ts, lo, hi, width if width > 0 else typeset_view_width(ts))
		typeset_view_set_read(t, st, ts, lo, hi)
	}

	// The box changes under a surviving node when the chapter is re-laid
	// out. Writing the size straight into the node would skip the relayout
	// and stack the next paragraph at the old height, so both the intrinsic
	// size and the layout props go through a comparison, as in `image` and
	// `lines`.
	w, h := typeset_view_size(ts, lo, hi)
	box := [2]f32{width if width > 0 else w, h}
	if ck, ok := d.kind.(Custom_Kind); !ok || ck.size != box || ck.overhang != st.over {
		d.kind = Custom_Kind{size = box, paint = typeset_view_paint, overhang = st.over}
		mark_layout_dirty(t, n)
	}
	lay := d.layout
	lay.width, lay.height, lay.flex = box.x, box.y, flex
	set_layout(t, n, lay)
	set_name(t, n, label)
	d.access.value_text = st.read
	return n
}

// typeset_view_width is the measure a page is set to: the Typeset's own box.
@(private)
typeset_view_width :: proc(ts: ^Typeset) -> f32 {
	return ts.size.x if ts != nil else 0
}

// typeset_view_overhang is how far the drawn glyphs reach outside the
// node's box, so damage and culling cover the ink and not only the measure:
// hanging punctuation sits outside the margin on purpose, and a dropped
// capital or an oversized run does the same. A surviving node repaints only
// its own bounds, so without this the overhang would be clipped.
//
// Glyphs are measured by advance box and face ascent/descent, not outlines
// (`typeset_ink` walks outlines, too costly per build), so ink past its own
// advance — a swash, a deep italic tail — is not counted.
@(private)
typeset_view_overhang :: proc(ts: ^Typeset, lo, hi: int, w: f32) -> f32 {
	if ts == nil || lo >= hi do return 0
	y0 := ts.lines[lo].rect.y
	h: f32
	for i in lo ..< hi do h += ts.lines[i].rect.h
	over: f32
	for li in lo ..< hi {
		span := ts.spans[li]
		for gi in span[0] ..< span[0] + span[1] {
			g := ts.glyphs[gi]
			if g.blank || g.font == nil do continue
			top := g.pos.y - y0 - g.font.ascent * g.scale
			bot := g.pos.y - y0 - g.font.descent * g.scale // descent is negative in a face's metrics
			over = max(over, -g.x0, g.x1 - w, -top, bot - h)
		}
	}
	return math.ceil(max(over, 0))
}

// typeset_view_set_read keeps the text a screen reader is given: the
// paragraph's source over the drawn lines, so a word broken across a line
// is one word and the drawn hyphen is not in it. Soft hyphens (U+00AD) and
// zero-width spaces are taken out, since nothing draws them and they would
// trip a search or a spelling. ZWJ and ZWNJ stay: they change what the text
// is (an emoji sequence, an Indic cluster).
//
// Each U+FFFC (a `Typeset_Object`) is replaced by its object's `label`, or
// dropped when it has none, so a picture in the line still reads.
//
// The cleaned copy is the tree's, freed when the node goes; a text needing
// no cleaning is the Typeset's own bytes and costs nothing.
@(private)
typeset_view_set_read :: proc(t: ^Tree, st: ^Typeset_View_State, ts: ^Typeset, lo, hi: int) {
	src := typeset_view_text(ts, lo, hi)
	if st.read_owned do delete(st.read, t.allocator)
	st.read, st.read_owned = src, false
	has_obj := strings.contains_rune(src, 0xFFFC)
	if !has_obj && !strings.contains_rune(src, 0x00AD) && !strings.contains_rune(src, 0x200B) do return
	base := 0 // where `src` starts in the paragraph, for an object's byte offset
	if ts != nil && lo < hi do base = clamp(ts.lines[lo].start, 0, len(ts.text))
	b := strings.builder_make(t.allocator)
	for r, i in src {
		switch r {
		case 0x00AD, 0x200B: // nothing drawn, nothing to hear
		case 0xFFFC:
			if ts != nil do for o in ts.objects do if o.at == base + i && o.label != "" {
				strings.write_string(&b, o.label)
				break
			}
		case:
			strings.write_rune(&b, r)
		}
	}
	st.read, st.read_owned = strings.to_string(b), true
}

// typeset_view_state_free gives back the cleaned text a node owned.
@(private)
typeset_view_state_free :: proc(t: ^Tree, st: ^Typeset_View_State) {
	if st.read_owned do delete(st.read, t.allocator)
	st.read, st.read_owned = "", false
}

// typeset_view_range clamps a line range to the Typeset, so an app that
// counted wrong draws fewer lines rather than reading past the end.
@(private)
typeset_view_range :: proc(ts: ^Typeset, first, count: int) -> (lo, hi: int) {
	if ts == nil do return 0, 0
	lo = clamp(first, 0, len(ts.lines))
	hi = len(ts.lines) if count < 0 else clamp(lo + count, lo, len(ts.lines))
	return
}

// typeset_view_size is the box the drawn lines need: the Typeset's own width
// (so a column of paragraphs shares one measure, and a justified edge lines
// up down the page) by the heights of the lines actually drawn.
@(private)
typeset_view_size :: proc(ts: ^Typeset, lo, hi: int) -> (w, h: f32) {
	if ts == nil || lo >= hi do return 0, 0
	w = ts.size.x
	for i in lo ..< hi do h += ts.lines[i].rect.h
	return
}

// typeset_view_text is the source text the drawn lines cover.
@(private)
typeset_view_text :: proc(ts: ^Typeset, lo, hi: int) -> string {
	if ts == nil || lo >= hi do return ""
	a := clamp(ts.lines[lo].start, 0, len(ts.text))
	b := clamp(ts.lines[hi - 1].end, a, len(ts.text))
	return ts.text[a:b]
}

@(private)
typeset_view_paint :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer) {
	st := &t.typesets[n]
	if st == nil || st.ts == nil || st.count <= 0 do return
	ink := st.ink if st.ink.a > 0 else t.theme.color.on_surface
	if disabled_within(t, n) do ink = t.theme.color.on_surface_muted
	append(&l.cmds, Draw_Typeset{
		pos = {d.abs.x, d.abs.y}, ts = st.ts, first = st.first, count = st.count,
		color = ink, scale = 1,
	})
}

// typeset_view_line_at is the line of `ts` under `y`, measured from the top
// of the range a typeset_view drew, or -1 past its end. It is what turns a
// click on a page into a place in the text, together with `typeset_hit`.
typeset_view_line_at :: proc(ts: ^Typeset, first, count: int, y: f32) -> int {
	lo, hi := typeset_view_range(ts, first, count)
	top: f32
	for i in lo ..< hi {
		h := ts.lines[i].rect.h
		if y < top + h do return i
		top += h
	}
	return -1
}
