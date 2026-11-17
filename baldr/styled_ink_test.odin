package baldr

@(require) import "core:testing"

// An outgoing chat bubble is filled with the accent, so its text must be
// that fill's "on" colour: the theme's surface colours read at about 1.6:1
// on such a bubble, and a primary selection wash is invisible on it.
//
// These are contrast measurements, not shape assertions: an accessibility
// fault is not fixed by code that reads as though it should work.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Sink_Msg :: union { int }

// sink_over is `c` composited over `bg`, which is what a wash of the ink
// actually looks like: contrast_ratio takes opaque colours.
@(private = "file")
sink_over :: proc(c, bg: Color) -> Color {
	return {bg.r + (c.r - bg.r) * c.a, bg.g + (c.g - bg.g) * c.a, bg.b + (c.b - bg.b) * c.a, 1}
}

@(private = "file")
sink_themes :: proc() -> [3]Theme {
	return {theme_light(), theme_dim(), theme_dark()}
}

// Over a bubble filled with `primary`, the ink's own palette reads. The
// numbers are WCAG 2: 4.5 for body text, 3 for something that only has to
// be seen (a selection wash, a code chip).
@(test)
an_inked_styled_text_reads_on_its_own_bubble :: proc(t: ^testing.T) {
	themes := sink_themes()
	for th in themes {
		theme := th
		bubble := theme.color.primary
		ink := theme.color.on_primary
		pal := styled_ink(&theme, ink, bubble)

		body := contrast_ratio(pal.body, bubble)
		testing.expectf(t, body >= 4.5, "%s: body text on its bubble is %.2f:1", theme.name, body)

		muted := contrast_ratio(sink_over(pal.muted, bubble), bubble)
		testing.expectf(t, muted >= 3, "%s: muted text is %.2f:1", theme.name, muted)

		link := contrast_ratio(sink_over(pal.link, bubble), bubble)
		testing.expectf(t, link >= 4.5, "%s: a link is %.2f:1", theme.name, link)

		// the chip and the selection only have to be *seen* against the fill
		chip := contrast_ratio(sink_over(pal.code, bubble), bubble)
		testing.expectf(t, chip >= 1.1, "%s: the code chip shows at %.2f:1", theme.name, chip)
		// The selection has to be seen, not merely present: 3:1 is WCAG's
		// bar for a change of state. The words in it are redrawn in a
		// colour that reads on the band, so they owe 4.5:1 to the band.
		band, text := selection_pair(&theme, bubble, ink)
		shows := contrast_ratio(band, bubble)
		testing.expectf(t, shows >= SELECTION_BAND_MIN, "%s: the selection stands %.2f:1 off the bubble", theme.name, shows)
		reads := contrast_ratio(text, band)
		testing.expectf(t, reads >= SELECTION_TEXT_MIN, "%s: selected words read %.2f:1 on it", theme.name, reads)
	}
}

// Why the ink is needed, as a measurement: the theme's own surface colours
// on a bubble filled with primary.
@(test)
the_old_fixed_colours_really_were_unreadable_there :: proc(t: ^testing.T) {
	theme := theme_dark()
	bubble := theme.color.primary

	was := contrast_ratio(theme.color.on_surface, bubble)
	testing.expectf(t, was < 3, "on_surface on a primary bubble was %.2f:1 — this is what was reported", was)

	sel_was := with_alpha(theme.color.primary, 0.28) // a translucent primary wash
	testing.expectf(t, contrast_ratio(sink_over(sel_was, bubble), bubble) < 1.1,
		"and a primary selection on a primary bubble is invisible")

	// with the ink it reads
	now := contrast_ratio(styled_ink(&theme, theme.color.on_primary, bubble).body, bubble)
	testing.expectf(t, now >= 4.5, "with the ink it is %.2f:1", now)
}

// Without an ink: the theme's own colours on a surface.
@(test)
styled_text_without_an_ink_is_unchanged :: proc(t: ^testing.T) {
	theme := theme_dark()
	pal := styled_ink(&theme, {}, {})
	testing.expect_value(t, pal.body, theme.color.on_surface)
	testing.expect_value(t, pal.muted, theme.color.on_surface_muted)
	testing.expect_value(t, pal.link, theme.color.primary)
	testing.expect_value(t, pal.code, theme.color.surface_variant)
}

// The builder's ink reaches the node, and options override one part
// without disturbing the others.
@(test)
styled_text_options_override_one_part :: proc(t: ^testing.T) {
	ui: Ui(Sink_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ink := Color{1, 0.5, 0.25, 1}
	lime := Color{0, 1, 0, 1}

	set_viewport(&ui.tree, {300, 200})
	begin_view(&ui)
	column(&ui, padding = .sm)
	n := styled_text(&ui, "hello there", ink = ink, key = 1)
	styled_text_options(&ui, n, link = lime)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {300, 200})

	s := &ui.tree.styled[n]
	testing.expect_value(t, s.ink, ink)
	pal := styled_colors(&ui.tree.theme, s)
	testing.expect_value(t, pal.link, lime)   // overridden
	testing.expect_value(t, pal.body, ink)    // still from the ink
	// the band is opaque (the words in it are redrawn over it), and the
	// pair for this ink holds both bars
	testing.expect_value(t, pal.selection.a, f32(1))
	band, text := styled_selection_pair(&ui.tree.theme, s)
	testing.expectf(t, contrast_ratio(text, band) >= SELECTION_TEXT_MIN, "selected words read on the band")
}

// The selection is actually drawn, in the computed colour: the contrast
// numbers above are only worth having if the band reaches the paint output.
@(test)
a_selection_is_painted_in_the_computed_colour :: proc(t: ^testing.T) {
	ui: Ui(Sink_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_theme(&ui.tree, theme_light())
	th := &ui.tree.theme
	ink, fill := th.color.on_primary, th.color.primary

	build :: proc(ui: ^Ui(Sink_Msg), ink, fill: Color) -> Node {
		set_viewport(&ui.tree, {360, 200})
		begin_view(ui)
		column(ui, padding = .sm)
		n := styled_text(ui, "shipping tonight, see the notes", ink = ink, on = fill, key = 1)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {360, 200})
		return n
	}
	n := build(&ui, ink, fill)

	// nothing selected: no band
	want, want_text := selection_pair(th, fill, ink)
	found := 0
	for _, l in ui.tree.layers do for c in l.cmds {
		if r, ok := c.(Draw_Rect); ok && r.color == want do found += 1
	}
	testing.expect_value(t, found, 0)

	// select the first few words and paint again
	s := &ui.tree.styled[n]
	s.anchor, s.caret = 0, 16
	mark_paint_dirty(&ui.tree, n)
	build(&ui, ink, fill)

	found = 0
	widest := f32(0)
	for _, l in ui.tree.layers do for c in l.cmds {
		if r, ok := c.(Draw_Rect); ok && r.color == want {
			found += 1
			widest = max(widest, r.rect.w)
		}
	}
	testing.expectf(t, found > 0, "the selection band is drawn (%v)", want)
	testing.expectf(t, widest > 10, "and it covers the words, not a sliver (%.0f px)", widest)

	// the band can be seen on the bubble, and the selected words are drawn
	// again over it in the colour that reads there — inside a clip, so the
	// words outside the selection keep the ink
	testing.expectf(t, contrast_ratio(want, fill) >= SELECTION_BAND_MIN,
		"the band stands %.2f:1 off the bubble", contrast_ratio(want, fill))
	recoloured, clipped := 0, false
	for _, l in ui.tree.layers do for c in l.cmds {
		if _, ok := c.(Draw_Clip_Push); ok do clipped = true
		if tx, ok := c.(Draw_Text); ok && clipped && tx.color == want_text do recoloured += 1
	}
	testing.expectf(t, recoloured > 0, "the selected words are redrawn in %v over the band", want_text)
	testing.expectf(t, contrast_ratio(want_text, want) >= SELECTION_TEXT_MIN,
		"and they read %.2f:1 on it", contrast_ratio(want_text, want))
}

// Driven through the real pointer path: press, move, release, as the
// compositor sends them.
@(test)
a_pointer_drag_selects_styled_text :: proc(t: ^testing.T) {
	ui: Ui(Sink_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	th := &ui.tree.theme
	ink, fill := th.color.on_primary, th.color.primary

	set_viewport(&ui.tree, {360, 200})
	begin_view(&ui)
	column(&ui, padding = .sm)
	n := styled_text(&ui, "shipping tonight, see the notes and the rest", ink = ink, on = fill, key = 1)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {360, 200})

	r := node_get(&ui.tree, n).abs
	testing.expectf(t, r.w > 50 && r.h > 5, "the paragraph has a rect (%.0fx%.0f)", r.w, r.h)
	y := r.y + r.h / 2

	pointer_move(&ui, {r.x + 4, y}, true)
	pointer_button(&ui, .Left, true, {r.x + 4, y})
	pointer_move(&ui, {r.x + r.w * 0.6, y}, true)
	pointer_button(&ui, .Left, false, {r.x + r.w * 0.6, y})

	s := &ui.tree.styled[n]
	lo, hi := styled_sel(s)
	testing.expectf(t, hi > lo, "a drag across it selects something (%d..%d)", lo, hi)
	testing.expect(t, !s.dragging, "and the release ended the drag")
}

}
