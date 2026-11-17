package baldr

@(require) import "core:testing"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Part of a window in colours of its own: a reader's Paper, Sepia, Dusk or
// Night page, its controls included, so a Light desktop does not put a white
// bar over a Night page.

@(private = "file")
Ta_Msg :: union { int }

// Four grounds, as a reader offers them.
@(private = "file")
Ta_Ground :: struct {
	name:            string,
	bg, ink, accent: Color,
}

@(private = "file")
TA_GROUNDS := [4]Ta_Ground{
	{"Paper", rgb(0xFBF8F2), rgb(0x1E1B17), rgb(0x8A4B1C)},
	{"Sepia", rgb(0xF2E6CE), rgb(0x3A2E21), rgb(0x7A3E12)},
	{"Dusk",  rgb(0x2A2826), rgb(0xD8D2C6), rgb(0xE3A65F)},
	{"Night", rgb(0x0A0A0A), rgb(0xA8A29A), rgb(0xC08A4E)},
}

// Every role that carries text or an edge is readable over the ground it
// sits on — the point of deriving a theme rather than tinting one. The
// targets are theme_from_seed's own, so an app's page is held to what the
// toolkit's themes are held to.
@(test)
a_derived_ground_is_readable_in_every_role :: proc(t: ^testing.T) {
	base := theme_light()
	for g in TA_GROUNDS {
		th := theme_on_ground(base, g.bg, g.ink, g.accent, g.name)
		c := th.color
		testing.expect_value(t, th.name, g.name)
		testing.expectf(t, contrast_ratio(c.on_bg, c.bg) >= 7, "%s: text on the page %.1f:1", g.name, contrast_ratio(c.on_bg, c.bg))
		testing.expectf(t, contrast_ratio(c.on_surface, c.surface) >= 7, "%s: text on a card %.1f:1", g.name, contrast_ratio(c.on_surface, c.surface))
		testing.expectf(t, contrast_ratio(c.on_surface_muted, c.surface_variant) >= 4.5, "%s: muted text %.1f:1", g.name, contrast_ratio(c.on_surface_muted, c.surface_variant))
		testing.expectf(t, contrast_ratio(c.primary, c.surface) >= 4.5, "%s: a link or ghost button %.1f:1", g.name, contrast_ratio(c.primary, c.surface))
		testing.expectf(t, contrast_ratio(c.on_primary, c.primary) >= 4.5, "%s: a primary button's label %.1f:1", g.name, contrast_ratio(c.on_primary, c.primary))
		testing.expectf(t, contrast_ratio(c.on_primary_container, c.primary_container) >= 4.5, "%s: a secondary button's label %.1f:1", g.name, contrast_ratio(c.on_primary_container, c.primary_container))
		testing.expectf(t, contrast_ratio(c.focus_ring, c.bg) >= 3, "%s: the focus ring %.1f:1", g.name, contrast_ratio(c.focus_ring, c.bg))
		testing.expectf(t, contrast_ratio(c.outline, c.surface) >= 1.35, "%s: a border %.2f:1", g.name, contrast_ratio(c.outline, c.surface))
		testing.expectf(t, contrast_ratio(c.danger, c.surface) >= 3, "%s: danger %.1f:1", g.name, contrast_ratio(c.danger, c.surface))
	}
}

// A card has to be visible on the page, which over cream paper means a
// *darker* cream: there is no white left above it. Over a dark page the
// ladder goes the other way, as the toolkit's own dark themes do.
@(test)
a_derived_ground_steps_where_it_has_room :: proc(t: ^testing.T) {
	base := theme_light()
	for g in TA_GROUNDS {
		th := theme_on_ground(base, g.bg, g.ink, g.accent, g.name)
		bgL, _, _ := oklch_of(th.color.bg)
		sfL, _, _ := oklch_of(th.color.surface)
		hiL, _, _ := oklch_of(th.color.surface_high)
		testing.expectf(t, abs(sfL - bgL) > 0.02, "%s: a card is a different shade from the page (%.3f vs %.3f)", g.name, sfL, bgL)
		testing.expectf(t, abs(hiL - bgL) > abs(sfL - bgL), "%s: and a popover is further still", g.name)
		if bgL > 0.9 {
			testing.expectf(t, sfL < bgL, "%s: cream paper has no white left, so its cards are darker", g.name)
		} else {
			testing.expectf(t, sfL > bgL, "%s: a dark page lifts its cards", g.name)
		}
		testing.expect_value(t, th.dark, bgL < 0.5)
	}
}

// The desktop's preferences are the user's, not the app's: a page in the
// app's colours still reduces motion, still turns glass off where it was
// off, and still meets the higher contrast a high-contrast desktop asks
// for. (The text size rides in the type scale, which is copied whole.)
@(test)
a_derived_ground_keeps_the_desktops_preferences :: proc(t: ^testing.T) {
	base := theme_high_contrast(.Light)
	base.motion.reduce = true
	theme_text_scale(&base, 1.5)
	g := TA_GROUNDS[3] // Night
	th := theme_on_ground(base, g.bg, g.ink, g.accent)

	testing.expect(t, th.motion.reduce, "reduce motion is still on")
	testing.expect_value(t, th.glass, Glass_Level.Solid)
	testing.expect_value(t, th.contrast, Theme_Contrast.High)
	testing.expect_value(t, th.type.body.size, base.type.body.size) // the desktop's text size rode along
	testing.expectf(t, contrast_ratio(th.color.on_bg, th.color.bg) >= 10,
		"high contrast holds the page to 10:1, not 7: %.1f", contrast_ratio(th.color.on_bg, th.color.bg))
	testing.expectf(t, contrast_ratio(th.color.on_surface_muted, th.color.surface_variant) >= 7,
		"…and muted text to 7: %.1f", contrast_ratio(th.color.on_surface_muted, th.color.surface_variant))
	for ms in th.material do testing.expect(t, ms.popover.tint.a == 1, "nothing shows through")
}

// An accent left out keeps the base theme's own, rather than painting the
// links in the page's ink.
@(test)
a_derived_ground_without_an_accent_keeps_the_base_one :: proc(t: ^testing.T) {
	base := theme_light()
	g := TA_GROUNDS[1]
	th := theme_on_ground(base, g.bg, g.ink)
	_, _, want := oklch_of(base.color.primary)
	_, c, got := oklch_of(th.color.primary)
	testing.expect(t, c > 0.02, "the accent is still a colour, not the ink")
	testing.expectf(t, abs(got - want) < 25, "and still the base's hue: %.0f against %.0f", got, want)
}

// The area itself: a button inside takes the page's colours, a button
// outside keeps the window's, and the tree has its own theme back when the
// scope closes.
@(test)
a_theme_area_builds_its_children_in_its_own_theme :: proc(t: ^testing.T) {
	ui: Ui(Ta_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_theme(&ui.tree, theme_light())
	window := ui.tree.theme
	g := TA_GROUNDS[3] // Night
	page := theme_on_ground(window, g.bg, g.ink, g.accent, "Night")

	begin_view(&ui)
	column(&ui)
	outside := button(&ui, "Settings", Ta_Msg(1), variant = .Ghost)
	area := column(&ui)
	theme_area(&ui, area, page)
	inside := button(&ui, "Next chapter", Ta_Msg(2), variant = .Ghost)
	label := text(&ui, "Chapter 3")
	end(&ui)
	after := button(&ui, "Shelf", Ta_Msg(3), variant = .Ghost)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 400})

	din := node_get(&ui.tree, inside)
	dout := node_get(&ui.tree, outside)
	dlab := node_get(&ui.tree, label)
	dafter := node_get(&ui.tree, after)
	testing.expect_value(t, din.style.fg, page.color.primary)
	testing.expect_value(t, dout.style.fg, window.color.primary)
	testing.expect_value(t, dlab.style.fg, page.color.on_surface)
	testing.expectf(t, dafter.style.fg == window.color.primary, "the theme goes back when the scope closes")
	testing.expect(t, .Theme_Area in node_get(&ui.tree, area).flags, "the area is marked for painting")
	testing.expect_value(t, ui.tree.theme.color, window.color)
}

// …and it *paints* with it too, which is the half a build-time swap alone
// does not cover: a page's own ink reaches what a widget resolves while it
// draws. typeset_view is the reader's own case — it takes the theme's text
// colour when the app names none.
@(test)
a_theme_area_paints_its_children_in_its_own_theme :: proc(t: ^testing.T) {
	te: Text_Engine; ui: Ui(Ta_Msg)
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init: embedded fonts failed to load")
	ui_init(&ui)
	defer { ui_destroy(&ui); text_engine_destroy(&te) }
	tree_use_text_engine(&ui.tree, &te)
	set_theme(&ui.tree, theme_light())
	window := ui.tree.theme
	g := TA_GROUNDS[3]
	page := theme_on_ground(window, g.bg, g.ink, g.accent, "Night")

	ts, ok := typeset(&ui.tree, "Everything starts somewhere.", Typeset_Style{size = 16, wrap_width = 300})
	testing.expect(t, ok, "typeset")
	defer typeset_destroy(&ts)

	begin_view(&ui)
	column(&ui)
	outside := typeset_view(&ui, &ts, key = 1)
	area := column(&ui)
	theme_area(&ui, area, page)
	inside := typeset_view(&ui, &ts, key = 2)
	end(&ui)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 400})

	ink_of :: proc(ui: ^Ui(Ta_Msg), n: Node) -> (Color, bool) {
		d := node_get(&ui.tree, n)
		for c in draw_list(&ui.tree) {
			want := [2]f32{d.abs.x, d.abs.y} // a literal in the condition reads as the if's body
			if v, is := c.(Draw_Typeset); is && v.pos == want do return v.color, true
		}
		return {}, false
	}
	in_ink, got_in := ink_of(&ui, inside)
	out_ink, got_out := ink_of(&ui, outside)
	testing.expect(t, got_in && got_out, "both pages reached the layer")
	testing.expect_value(t, in_ink, page.color.on_surface)
	testing.expect_value(t, out_ink, window.color.on_surface)
}

// A popup opened from inside the area keeps the window's theme: it is its
// own surface over the whole window, not part of the page, and a
// Night-coloured menu over a Light window reads as another app's.
@(test)
a_popup_opened_inside_an_area_keeps_the_windows_theme :: proc(t: ^testing.T) {
	ui: Ui(Ta_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_theme(&ui.tree, theme_light())
	ui.tree.popups_on = true
	window := ui.tree.theme
	g := TA_GROUNDS[3]
	page := theme_on_ground(window, g.bg, g.ink, g.accent, "Night")

	begin_view(&ui)
	column(&ui)
	area := column(&ui)
	theme_area(&ui, area, page)
	anchor := button(&ui, "How the book looks", Ta_Msg(1), variant = .Ghost)
	inside := text(&ui, "Chapter 3")
	if popover(&ui, anchor, true, Ta_Msg(0)) {
		in_popup := button(&ui, "Sepia", Ta_Msg(2), variant = .Ghost)
		_ = in_popup
		end(&ui)
		popped := node_get(&ui.tree, in_popup)
		testing.expect_value(t, popped.style.fg, window.color.primary)
	}
	end(&ui)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 400})

	testing.expect_value(t, node_get(&ui.tree, inside).style.fg, page.color.on_surface)
	testing.expect_value(t, ui.tree.theme.color, window.color) // and the window has its own back
}

}
