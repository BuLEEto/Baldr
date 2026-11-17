package baldr

@(require) import "core:testing"

// Every text selection in the toolkit has to be seen, 3:1 off the surface
// it is on (WCAG's bar for a change of state), and the words in it have to
// read, 4.5:1 on the band. A translucent wash clears neither bar on a light
// theme or on a filled bubble, which is why the selected words change colour.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
sp_themes :: proc() -> [5]Theme {
	return {theme_light(), theme_dim(), theme_dark(),
		theme_high_contrast(.Light), theme_high_contrast(.Dark)}
}

// Every built-in theme, on every surface a selection lands on. A field or a
// reply on the theme's own surfaces gets the theme's pair; a bubble passes
// its fill and ink, and one filled with the accent gets reverse video.
@(test)
every_theme_s_selection_can_be_seen_and_read :: proc(t: ^testing.T) {
	themes := sp_themes()
	for th in themes {
		theme := th
		c := theme.color
		cases := [?]struct{ what: string, fill, ink: Color, known: bool }{
			{"surface", c.surface, c.on_surface, false},
			{"surface_high", c.surface_high, c.on_surface, false},
			{"a grey bubble", c.surface_high, c.on_surface, true},
			{"an accent bubble", c.primary, c.on_primary, true},
		}
		for k in cases {
			band, text: Color
			if k.known { band, text = selection_pair(&theme, k.fill, k.ink) } else { band, text = selection_pair(&theme) }
			shows := contrast_ratio(band, k.fill)
			reads := contrast_ratio(text, band)
			testing.expectf(t, shows >= SELECTION_BAND_MIN, "%s, %s: the band stands only %.2f:1 off it", theme.name, k.what, shows)
			testing.expectf(t, reads >= SELECTION_TEXT_MIN, "%s, %s: selected words read only %.2f:1", theme.name, k.what, reads)
		}
	}
}

// The dark theme's grey bubble: `surface_high` with `on_surface` text,
// passed as the bubble's `on` and `ink`.
@(test)
the_reported_dark_bubble_shows_its_selection :: proc(t: ^testing.T) {
	theme := theme_dark()
	bubble, ink := theme.color.surface_high, theme.color.on_surface
	band, text := selection_pair(&theme, bubble, ink)
	testing.expectf(t, contrast_ratio(band, bubble) >= SELECTION_BAND_MIN,
		"the band stands %.2f:1 off the bubble (it was 1.12:1)", contrast_ratio(band, bubble))
	testing.expectf(t, contrast_ratio(text, band) >= SELECTION_TEXT_MIN,
		"and the selected words read %.2f:1 on it", contrast_ratio(text, band))
}

// A wash cannot do it there, which is why the words change colour: no
// single tone stands 3:1 off that bubble *and* keeps the light ink at 4.5:1
// on top. This pins the arithmetic the design rests on: a stronger wash is
// not the answer.
@(test)
no_wash_keeps_the_ink_and_shows_on_a_dark_bubble :: proc(t: ^testing.T) {
	theme := theme_dark()
	bubble, ink := theme.color.surface_high, theme.color.on_surface
	found := false
	for i in 0 ..= 100 {
		k := f32(i) / 100
		for away in ([2]Color{{0, 0, 0, 1}, {1, 1, 1, 1}}) {
			band := mix(bubble, away, k)
			if contrast_ratio(band, bubble) >= SELECTION_BAND_MIN && contrast_ratio(ink, band) >= SELECTION_TEXT_MIN do found = true
		}
	}
	testing.expect(t, !found, "if a wash of black or white ever does both, the recolouring is not needed here")
}

// An editor on a page the theme did not choose knows only its ink. Reverse
// video against the ink is right whatever the page is, because the ink is
// the one colour known to read on it.
@(test)
an_ink_on_an_unknown_page_selects_in_reverse :: proc(t: ^testing.T) {
	theme := theme_dark()
	slate := Color{0.08, 0.07, 0.05, 1}
	band, text := selection_pair(&theme, nil, slate)
	testing.expect_value(t, band, slate)
	testing.expectf(t, contrast_ratio(text, band) >= SELECTION_TEXT_MIN, "the words read %.2f:1", contrast_ratio(text, band))
}

// The overpaint redraws the selected words and nothing else: a clip, an
// opaque band, the text again in the selection's colour, its underline with
// it, and not a code chip's wash, which the band is meant to cover.
@(test)
selection_overpaint_redraws_only_the_words :: proc(t: ^testing.T) {
	tr: Tree
	tr.paint_opacity = 1 // set per node in a real paint; zero on a bare tree, which would draw nothing
	l: Layer
	defer delete(l.cmds)
	ink := Color{0.9, 0.9, 0.9, 1}
	append(&l.cmds, Draw_Rect{rect = {0, 2, 60, 16}, color = with_alpha(ink, 0.16)}) // a code chip's wash: tall
	append(&l.cmds, Draw_Text{pos = {0, 0}, str = "hello there", size = 14, color = ink})
	append(&l.cmds, Draw_Rect{rect = {0, 17, 80, 1}, color = ink})                   // its underline: thin
	from, to := 0, len(l.cmds)

	band, text := Color{0.1, 0.3, 0.8, 1}, Color{1, 1, 1, 1}
	sel := [1]Rect{{10, 0, 40, 20}}
	selection_overpaint(&tr, &l, from, to, sel[:], band, text)

	added := l.cmds[to:]
	testing.expect_value(t, len(added), 5) // clip, band, text, underline, pop
	if len(added) != 5 do return
	clip, is_clip := added[0].(Draw_Clip_Push)
	testing.expect(t, is_clip && clip.rect == sel[0], "clipped to the selection")
	b, is_band := added[1].(Draw_Rect)
	testing.expect(t, is_band && b.color == band && b.rect == sel[0], "an opaque band over the old words")
	tx, is_text := added[2].(Draw_Text)
	testing.expect(t, is_text && tx.color == text && tx.str == "hello there", "the words again, in the selection's colour")
	u, is_under := added[3].(Draw_Rect)
	testing.expect(t, is_under && u.rect.h == 1 && u.color == text, "the underline comes with them")
	_, is_pop := added[4].(Draw_Clip_Pop)
	testing.expect(t, is_pop, "and the clip is closed")
}

// A field's selection, painted: the band can be seen on the field and the
// selected characters are drawn over it in the colour that reads there.
@(test)
a_text_input_paints_a_selection_that_can_be_seen :: proc(t: ^testing.T) {
	ui: Ui(int)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_theme(&ui.tree, theme_light()) // where a translucent wash is hardest to see
	v: Text
	text_set(&v, "north gate at seven")
	defer text_destroy(&v)

	build :: proc(ui: ^Ui(int), v: ^Text) -> Node {
		set_viewport(&ui.tree, {360, 120})
		begin_view(ui)
		column(ui, padding = .md)
		n := text_input(ui, v, label = "Where", key = 1)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {360, 120})
		return n
	}
	n := build(&ui, &v)
	set_focus(&ui.tree, n, true)
	text_input_set_selection(&ui.tree, n, 0, 5) // "north"
	mark_paint_dirty(&ui.tree, n)
	build(&ui, &v)

	band, text := selection_pair(&ui.tree.theme)
	bands, words := 0, 0
	clipped := false
	for _, l in ui.tree.layers do for c in l.cmds {
		#partial switch v in c {
		case Draw_Clip_Push: clipped = true
		case Draw_Rect:      if v.color == band do bands += 1
		case Draw_Text:      if clipped && v.color == text do words += 1
		}
	}
	testing.expect(t, bands > 0, "the band is drawn")
	testing.expect(t, words > 0, "and the selected characters over it, in the selection's colour")
	testing.expectf(t, contrast_ratio(band, ui.tree.theme.color.surface) >= SELECTION_BAND_MIN,
		"it stands %.2f:1 off the surface", contrast_ratio(band, ui.tree.theme.color.surface))
}

}
