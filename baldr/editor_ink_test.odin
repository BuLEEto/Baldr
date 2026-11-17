#+build linux
package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: about 9 GB without this `when`, 1 GB with it.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// An editor writes in the colour it is given, so a page of the app's own
// colour (a sticky note's yellow paper) does not get the theme's near-white
// text on it.


@(private = "file")
Ei_Msg :: enum { None }

@(private = "file")
ei_view :: proc(ui: ^Ui(Ei_Msg), doc: ^Document, ink: Maybe(Color)) -> Node {
	set_viewport(&ui.tree, {400, 240})
	begin_view(ui)
	column(ui, flex = 1)
	ed := text_area(ui, doc, placeholder = "Write a note…", width = 300, height = 160, key = 4)
	editor_options(ui, ed, ink = ink)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 240})
	return ed
}

@(private = "file")
ei_text_colours :: proc(ui: ^Ui(Ei_Msg)) -> (out: [dynamic]Color) {
	out = make([dynamic]Color, context.temp_allocator)
	for c in draw_list(&ui.tree) do if v, is_text := c.(Draw_Text); is_text do append(&out, v.color)
	return
}

@(test)
an_editor_writes_in_the_colour_it_is_given :: proc(t: ^testing.T) {
	ui: Ui(Ei_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_theme(&ui.tree, theme_dark()) // a dark desktop: the theme's ink is near-white
	doc := document_make("Milk, bread, jam")
	defer document_destroy(&doc)

	ei_view(&ui, &doc, nil)
	for c in ei_text_colours(&ui) do testing.expect(t, luminance(c) > 0.5, "by default it writes in the theme's light ink")

	// a yellow note wants dark ink, whatever the desktop is
	slate := Color{0.08, 0.07, 0.05, 1}
	ed := ei_view(&ui, &doc, slate)
	drawn := ei_text_colours(&ui)
	testing.expect(t, len(drawn) > 0)
	for c in drawn do testing.expect_value(t, Color{c.r, c.g, c.b, 1}, slate)

	// …and the caret and the selection come with it: the theme's accent was
	// chosen for the theme's surfaces, not for this page
	s := &ui.tree.areas[ed]
	testing.expect_value(t, area_ink(&ui.tree, s), slate)
	// the selection is reverse video against the ink: the editor is never
	// told the paper, but its ink is the one colour known to read on it, so
	// a band of the ink shows on the paper and the words go to whichever of
	// black and white reads on the band (selection_paint.odin)
	paper := Color{1, 0.93, 0.6, 1}
	band, text := area_selection_pair(&ui.tree, s)
	testing.expect_value(t, band, slate)
	testing.expectf(t, contrast_ratio(band, paper) >= SELECTION_BAND_MIN,
		"the band stands %.2f:1 off the paper", contrast_ratio(band, paper))
	testing.expectf(t, contrast_ratio(text, band) >= SELECTION_TEXT_MIN,
		"and the selected words read %.2f:1 on it", contrast_ratio(text, band))
	testing.expect(t, contrast_ratio(area_ink_muted(&ui.tree, s), Color{1, 0.93, 0.6, 1}) > 3,
		"and the placeholder still reads on the paper")

	// it stays until changed, like every other editor option
	ei_view(&ui, &doc, nil)
	testing.expect_value(t, area_ink(&ui.tree, &ui.tree.areas[ed]), slate)
}

// …and a markdown editor writes in it too: the rich painter has its own
// path to the theme's colours, separate from the plain one.
@(test)
a_markdown_editor_writes_in_the_colour_it_is_given :: proc(t: ^testing.T) {
	ui: Ui(Ei_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_theme(&ui.tree, theme_dark())
	doc := document_make("plain words here\n- a bullet\n1. a number")
	defer document_destroy(&doc)
	slate := Color{0.08, 0.07, 0.05, 1}

	set_viewport(&ui.tree, {420, 260})
	begin_view(&ui)
	column(&ui, flex = 1)
	ed := markdown_editor(&ui, &doc, placeholder = "Write a note…", width = 320, height = 180, key = 5)
	editor_options(&ui, ed, ink = slate)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {420, 260})

	drawn := ei_text_colours(&ui)
	testing.expect(t, len(drawn) > 0, "it drew something")
	for c in drawn {
		testing.expectf(t, luminance(c) < 0.2, "a word is drawn at luminance %.3f, not the ink's", luminance(c))
	}
	// the bullet's dot and the number take it too, faded as the theme fades
	// its own muted text
	s := &ui.tree.areas[ed]
	testing.expect_value(t, area_ink_muted(&ui.tree, s).rgb, slate.rgb)
	// a link keeps the accent's hue but is pulled toward the ink, so it
	// reads on paper the theme did not choose
	link := area_ink_accent(&ui.tree, s)
	testing.expect(t, luminance(link) < luminance(ui.tree.theme.color.primary))
}

// A scrollbar is toolkit furniture drawn on the page: an editor given its
// own ink gets a scrollbar in that ink, or a long note has a grey thumb on
// yellow paper.
@(test)
an_editors_scrollbar_takes_its_ink :: proc(t: ^testing.T) {
	ui: Ui(Ei_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_theme(&ui.tree, theme_dark())
	long := document_make("one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\ntwelve")
	defer document_destroy(&long)
	slate := Color{0.08, 0.07, 0.05, 1}

	ed := ei_view(&ui, &long, slate)
	// it scrolls: the document is taller than the box
	testing.expect(t, .Scroll_V in node_get(&ui.tree, ed).flags)
	scroll_to(&ui.tree, ed, {0, 40})
	ei_view(&ui, &long, nil)                      // a paint that sees the scroll (the ink stays until changed)
	for i in 1 ..= 10 do ui_tick(&ui, f64(i) * 16) // …then the bar fades in
	ei_view(&ui, &long, nil)
	frame(&ui.tree, {400, 240})

	bars := 0
	for _, l in ui.tree.layers do for c in l.cmds {
		if r, is_rect := c.(Draw_Rect); is_rect && r.color.a > 0 && r.color.a <= 0.9 && r.rect.w < 8 && r.rect.h > 8 {
			bars += 1
			testing.expectf(t, luminance(r.color) < 0.2, "a scrollbar part is drawn at luminance %.3f", luminance(r.color))
		}
	}
	testing.expect(t, bars > 0, "the scrollbar is drawn at all")
}

} // when ODIN_TEST