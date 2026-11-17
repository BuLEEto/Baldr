package baldr

@(require) import "core:testing"

when ODIN_TEST || #config(BALDR_TESTS, false) {

// The accent does two jobs: it fills a selection, a switched-on toggle, a
// Primary button, a progress bar; and it inks a ghost button's label, a
// breadcrumb, a link, an unread count. One colour cannot do both when the
// accent is a mid grey: readable as text means 4.5:1 on the view, and a grey
// pushed that far is no longer the grey the style asked for.
//
// So `theme_from_palette` keeps `primary` as the palette named it and puts
// the as-text bar on `accent_text`, which defaults to the fill: #8d8d8d on a
// #cecece view fills with #8d8d8d and inks with #585858.

@(private = "file")
At_Grey :: Color{0.26625, 0.26625, 0.26625, 1} // #8d8d8d, a real style's selection grey

@(private = "file")
at_palette :: proc(ink := Color{}) -> Theme_Palette {
	return {
		bg               = at_hex("#d6d6d6"),
		surface          = at_hex("#cecece"),
		surface_variant  = at_hex("#c4c4c4"),
		on_bg            = at_hex("#1a1a1a"),
		on_surface       = at_hex("#1a1a1a"),
		on_surface_muted = at_hex("#5a5a5a"),
		outline          = at_hex("#9a9a9a"),
		primary          = at_hex("#8d8d8d"),
		accent_text      = ink,
	}
}

@(private = "file")
at_hex :: proc(h: string) -> Color {
	c, _ := color_parse_hex(h)
	return c
}

@(private = "file")
at_close :: proc(a, b: Color) -> bool {
	return abs(a.r - b.r) < 0.002 && abs(a.g - b.g) < 0.002 && abs(a.b - b.b) < 0.002
}

@(test)
a_given_accent_keeps_its_fill :: proc(t: ^testing.T) {
	p := at_palette()
	th := theme_from_palette(p, .Light)
	// the whole point: the colour the style named is the colour it fills with
	testing.expect(t, at_close(th.color.primary, p.primary),
		"a palette's accent is its fill and is taken as asked, not pushed until it reads as text")
	// …and the ink is readable anyway
	testing.expect(t, contrast_ratio(th.color.accent_text, th.color.surface) >= 4.49,
		"the accent as ink is readable on the view it is drawn on")
	// the ink is lifted only as far as the as-text bar needs
	testing.expect(t, contrast_ratio(th.color.accent_text, th.color.surface) < 5.5,
		"…and no further than it needs: the ink is the old lifted primary, not the text colour")
}

@(test)
a_style_can_name_its_own_ink :: proc(t: ^testing.T) {
	ink := at_hex("#1a1a1a")
	th := theme_from_palette(at_palette(ink), .Light)
	testing.expect(t, at_close(th.color.accent_text, ink), "a named ink is taken as given")
	testing.expect(t, at_close(th.color.primary, at_hex("#8d8d8d")), "…and the fill is still the palette's")
	testing.expect(t, contrast_ratio(th.color.accent_text, th.color.surface) > 10,
		"a style that inks with its text colour gets its text colour's contrast")
}

@(test)
a_generated_themes_ink_is_its_fill :: proc(t: ^testing.T) {
	// A generated accent is picked for its mode and then moved until it reads
	// as text, so one colour serves both jobs and nothing about these themes
	// changes. Every seed and mode, including a grey seed.
	for seed in ([]Color{BALDR_BLUE, at_hex("#2e7d32"), at_hex("#8d8d8d"), at_hex("#b00020")}) {
		for mode in ([]Theme_Mode{.Light, .Dim, .Dark}) {
			th := theme_from_seed(seed, mode)
			testing.expect(t, at_close(th.color.accent_text, th.color.primary),
				"a generated theme inks with the colour it fills with")
		}
	}
}

@(test)
an_unset_ink_is_never_invisible :: proc(t: ^testing.T) {
	// A zero here is not a wrong colour, it is a transparent one — every
	// ghost button's label would vanish. theme_finish falls back to the fill,
	// after the app's adjust_theme so an app that moves `primary` is followed.
	th: Theme
	th.color.primary = At_Grey
	theme_finish(&th, nil)
	testing.expect(t, at_close(th.color.accent_text, At_Grey), "an unset ink falls back to the fill")

	moved :: proc(th: ^Theme) {
		th.color.primary = Color{0.2, 0.4, 0.1, 1}
		th.color.accent_text = {} // an app that recolours the accent and says nothing about ink
	}
	th2 := theme_from_seed(BALDR_BLUE, .Light)
	theme_finish(&th2, moved)
	testing.expect(t, at_close(th2.color.accent_text, Color{0.2, 0.4, 0.1, 1}),
		"an adjust_theme that moves the accent and leaves the ink gets ink that follows it")

	kept :: proc(th: ^Theme) {
		th.color.primary = Color{0.2, 0.4, 0.1, 1}
		th.color.accent_text = Color{0.9, 0.9, 0.9, 1}
	}
	th3 := theme_from_seed(BALDR_BLUE, .Light)
	theme_finish(&th3, kept)
	testing.expect(t, at_close(th3.color.accent_text, Color{0.9, 0.9, 0.9, 1}),
		"…and an app that names its own ink keeps it")
}

@(test)
high_contrast_still_has_an_ink :: proc(t: ^testing.T) {
	// High contrast returns the generated theme rather than the palette's
	// greys; the ink must survive that path too.
	th := theme_from_palette(at_palette(), .Light, .High)
	testing.expect(t, th.color.accent_text.a > 0, "high contrast leaves an ink colour set")
	testing.expect(t, contrast_ratio(th.color.accent_text, th.color.surface) >= 4.5,
		"…and a readable one")
}

// --- what actually reaches the pixels -------------------------------------

@(private = "file")
At_Msg :: enum { Go }

@(private = "file")
at_split_theme :: proc() -> Theme {
	// a fill and an ink that cannot be confused for each other
	th := theme_from_seed(BALDR_BLUE, .Light)
	th.color.primary = Color{1, 0, 0, 1}      // the fill
	th.color.accent_text = Color{0, 0, 1, 1}  // the ink
	return th
}

@(private = "file")
at_ink :: proc(ui: ^Ui(At_Msg)) -> (texts, icons: [dynamic]Color) {
	texts = make([dynamic]Color, context.temp_allocator)
	icons = make([dynamic]Color, context.temp_allocator)
	for c in draw_list(&ui.tree) {
		#partial switch v in c {
		case Draw_Text: if v.color.a > 0.01 do append(&texts, v.color)
		case Draw_Icon: if v.color.a > 0.01 do append(&icons, v.color)
		}
	}
	return
}

@(private = "file")
at_has :: proc(cs: [dynamic]Color, want: Color) -> bool {
	for c in cs do if at_close(c, want) do return true
	return false
}

@(test)
a_ghost_buttons_label_is_ink_and_a_progress_bar_is_fill :: proc(t: ^testing.T) {
	ui: Ui(At_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_theme(&ui.tree, at_split_theme())

	set_viewport(&ui.tree, {400, 300})
	begin_view(&ui)
	column(&ui, padding = .lg, gap = .md)
	button(&ui, "Ghost", At_Msg.Go, variant = .Ghost)
	progress(&ui, 0.5, label = "Working")
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 300})

	texts, _ := at_ink(&ui)
	testing.expect(t, at_has(texts, Color{0, 0, 1, 1}), "a Ghost button's label draws in the ink colour")
	testing.expect(t, !at_has(texts, Color{1, 0, 0, 1}), "…and never in the fill colour")

	// the progress bar's own fill is still the accent as a fill
	fills := 0
	for c in draw_list(&ui.tree) {
		if r, ok := c.(Draw_Rect); ok && at_close(r.color, Color{1, 0, 0, 1}) do fills += 1
	}
	testing.expect(t, fills > 0, "a progress bar fills with the accent, not with the ink")
}

@(test)
a_breadcrumb_and_an_unread_count_are_ink :: proc(t: ^testing.T) {
	ui: Ui(At_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_theme(&ui.tree, at_split_theme())

	parts := []string{"home", "docs", "now"}
	set_viewport(&ui.tree, {400, 300})
	begin_view(&ui)
	column(&ui, padding = .lg, gap = .md)
	breadcrumbs(&ui, parts)
	list_row(&ui, "Inbox", At_Msg.Go, value = "3", unread = 3)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 300})

	texts, _ := at_ink(&ui)
	testing.expect(t, at_has(texts, Color{0, 0, 1, 1}),
		"a breadcrumb's current place and an unread count draw in the ink colour")
	testing.expect(t, !at_has(texts, Color{1, 0, 0, 1}),
		"…and neither draws in the fill colour")
}

@(test)
a_selected_row_still_fills_with_the_accent :: proc(t: ^testing.T) {
	// The other half of the contract: what fills must not follow the ink, or
	// a style that inks in its text colour would paint selection bars in it.
	ui: Ui(At_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_theme(&ui.tree, at_split_theme())

	set_viewport(&ui.tree, {400, 300})
	begin_view(&ui)
	column(&ui, padding = .lg)
	list_row(&ui, "Picked", At_Msg.Go, selected = true)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 300})

	ink_fills := 0
	for c in draw_list(&ui.tree) {
		if r, ok := c.(Draw_Rect); ok && r.color.a > 0.01 {
			if at_close(r.color, Color{0, 0, 1, 1}) do ink_fills += 1
		}
	}
	testing.expect_value(t, ink_fills, 0)
}

}
