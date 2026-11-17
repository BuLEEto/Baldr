package baldr

// What a text selection looks like, and the one way every widget draws it.
//
// The selected words change colour with the band, as every desktop does: no
// wash over text that keeps its own colour can stand 3:1 off a dark surface
// and still leave light text 4.5:1 on top. The pair is the theme's own
// `primary` and `on_primary`; in all five built-in themes the band stands
// 4.22–11.18:1 off `surface` and `surface_high`, and the text reads
// 4.65–13.27:1 on the band. Where the accent cannot show (a fill that is the
// accent, like an outgoing bubble) the selection is reverse video: the band
// is the ink and the text the fill, which reads exactly as well as the
// unselected text did. `th.color.selection`, the wash, stays in the theme
// for an app that paints its own; nothing in the toolkit draws with it.

// SELECTION_BAND_MIN is how far the band must stand off the surface it is on:
// WCAG's 3:1 for a change of state. SELECTION_TEXT_MIN is what the selected
// words must read at on the band: body text's 4.5:1.
SELECTION_BAND_MIN :: f32(3)
SELECTION_TEXT_MIN :: f32(4.5)

// selection_pair is the band a selection draws and the colour the words in
// it are drawn in, for text in `ink` on a surface `fill`.
//
// Either may be nil: a widget on one of the theme's own surfaces knows
// neither, and gets the theme's pair — which stands off every neutral
// surface the theme has. One that knows its fill — a bubble —
// is checked against it. One that knows its ink and not its page — an
// editor on a coloured note — gets reverse video against the ink, because
// its ink is the one thing known to read on that page.
selection_pair :: proc(th: ^Theme, fill: Maybe(Color) = nil, ink: Maybe(Color) = nil) -> (band, text: Color) {
	band = opaque(th.color.primary)
	text = ensure_contrast(opaque(th.color.on_primary), band, SELECTION_TEXT_MIN)
	f, knows_fill := fill.?
	i, knows_ink := ink.?
	if !knows_fill {
		if !knows_ink do return
		// A page we cannot see, in an ink chosen to read on it.
		band = opaque(i)
		return band, extreme_on(band)
	}
	f = opaque(f)
	if contrast_ratio(band, f) >= SELECTION_BAND_MIN do return
	// The accent does not show on this fill: reverse video.
	band = opaque(i) if knows_ink else extreme_on(f)
	if contrast_ratio(band, f) < SELECTION_BAND_MIN do band = extreme_on(f) // an ink that never read on it either
	text = f if contrast_ratio(f, band) >= SELECTION_TEXT_MIN else extreme_on(band)
	return
}

// extreme_on is black or white, whichever stands further off `c`. One of the
// two always reaches 4.58:1 against any colour at all — mid-grey is the
// worst case — so it is the colour that cannot fail.
@(private)
extreme_on :: proc "contextless" (c: Color) -> Color {
	white, black := Color{1, 1, 1, 1}, Color{0, 0, 0, 1}
	return white if contrast_ratio(white, c) >= contrast_ratio(black, c) else black
}

@(private)
opaque :: proc "contextless" (c: Color) -> Color { return {c.r, c.g, c.b, 1} }

// selection_overpaint lays a selection over text a widget has already
// drawn: for each of `rects`, an opaque band and then, clipped to it, the
// text commands in `l.cmds[from:to]` again in `text`. Drawn over rather than
// under, so one routine serves every widget without any of them splitting a
// run at a selection; the band covers the old colour first, so none of it
// fringes the new, and whole runs are redrawn and cut by the clip, so their
// shaping is kept and a ligature half in the selection is half in each
// colour. Underlines and strikes (thin rects) come along recoloured; a code
// chip's wash or a highlighter stripe stays under the band. `paint_opacity`
// (a fading popover) applies to both colours.
selection_overpaint :: proc(t: ^Tree, l: ^Layer, from, to: int, rects: []Rect, band, text: Color, radius: f32 = 2) {
	if len(rects) == 0 do return // no text in range is fine: a selected empty line still shows its band
	b, tx := band, text
	b.a *= t.paint_opacity
	tx.a *= t.paint_opacity
	for r in rects {
		if r.w <= 0 || r.h <= 0 do continue
		append(&l.cmds, Draw_Clip_Push{r})
		append(&l.cmds, Draw_Rect{rect = r, color = b, radius = radius})
		for i in from ..< to {
			#partial switch c in l.cmds[i] {
			case Draw_Text:
				if !overlaps_rows(c.pos.y, c.size, c.wrap_w, r) do continue
				cc := c
				cc.color = {tx.r, tx.g, tx.b, tx.a * min(c.color.a, 1)} // a run's own fade is kept
				append(&l.cmds, cc)
			case Draw_Rect:
				// an underline or a strike, drawn in the run's colour
				if c.rect.h > 2 || c.border_w > 0 || c.color.a <= 0 do continue
				if c.rect.y + c.rect.h < r.y || c.rect.y > r.y + r.h do continue
				cc := c
				cc.color = {tx.r, tx.g, tx.b, tx.a * min(c.color.a, 1)}
				append(&l.cmds, cc)
			}
		}
		append(&l.cmds, Draw_Clip_Pop{})
	}
}

// overlaps_rows is whether a text drawn from `y` could have ink in the rows
// of `r`. The clip makes the exact cut; this only keeps a long document from
// sending every line again for every selected one. A run of one line — most
// of them, every segment of a styled or rich paragraph — is tested exactly,
// with room for ascenders and descenders. A wrapped run (`wrap_w` set) can
// reach down from wherever it starts, so it is kept unless it starts below.
@(private)
overlaps_rows :: proc "contextless" (y, size, wrap_w: f32, r: Rect) -> bool {
	if y > r.y + r.h do return false // starts below the band
	if wrap_w > 0 do return true     // may wrap down into it
	return y + size * 2 > r.y        // one line, with its overshoot
}
