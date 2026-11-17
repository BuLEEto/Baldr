package baldr

@(require) import "core:testing"
@(require) import "baldr:platform"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// The desktop's own colour scheme: a Windows contrast theme is drawn in
// exactly the colours the person chose; a KDE scheme becomes the theme's
// grounds and accent with its text kept readable.

@(private = "file")
palette_srgb :: proc "contextless" (c: [4]f32) -> Color {
	return {srgb_to_linear(c[0]), srgb_to_linear(c[1]), srgb_to_linear(c[2]), 1}
}

// Windows' "Desert"-like contrast theme: dark text on a pale ground, a
// green selection, a blue link.
@(private = "file")
CONTRAST_PALETTE := platform.System_Palette{
	ok = true,
	window = {1, 0.98, 0.94, 1}, window_text = {0.24, 0.24, 0.24, 1},
	view = {1, 0.98, 0.94, 1}, view_text = {0.24, 0.24, 0.24, 1},
	button = {1, 0.98, 0.94, 1}, button_text = {0.24, 0.24, 0.24, 1},
	selection = {0.1, 0.4, 0.2, 1}, selection_text = {1, 1, 1, 1},
	link = {0.1, 0.2, 0.6, 1}, inactive_text = {0.4, 0.4, 0.4, 1},
}

// Breeze Dark.
@(private = "file")
KDE_PALETTE := platform.System_Palette{
	ok = true,
	window = {32.0 / 255, 35.0 / 255, 38.0 / 255, 1}, window_text = {252.0 / 255, 252.0 / 255, 252.0 / 255, 1},
	view = {20.0 / 255, 22.0 / 255, 24.0 / 255, 1}, view_text = {252.0 / 255, 252.0 / 255, 252.0 / 255, 1},
	button = {41.0 / 255, 44.0 / 255, 48.0 / 255, 1}, button_text = {252.0 / 255, 252.0 / 255, 252.0 / 255, 1},
	selection = {61.0 / 255, 174.0 / 255, 233.0 / 255, 1}, selection_text = {252.0 / 255, 252.0 / 255, 252.0 / 255, 1},
	link = {29.0 / 255, 153.0 / 255, 243.0 / 255, 1}, inactive_text = {161.0 / 255, 169.0 / 255, 177.0 / 255, 1},
}

@(test)
a_contrast_theme_is_drawn_in_the_colours_chosen :: proc(t: ^testing.T) {
	th := theme_from_system(CONTRAST_PALETTE, high_contrast = true)
	c := th.color
	testing.expect_value(t, c.bg, palette_srgb(CONTRAST_PALETTE.window))
	testing.expect_value(t, c.on_surface, palette_srgb(CONTRAST_PALETTE.view_text))
	testing.expect_value(t, c.primary, palette_srgb(CONTRAST_PALETTE.selection))
	testing.expect_value(t, c.on_primary, palette_srgb(CONTRAST_PALETTE.selection_text))
	testing.expect_value(t, c.accent_text, palette_srgb(CONTRAST_PALETTE.link))
	testing.expect_value(t, c.outline, palette_srgb(CONTRAST_PALETTE.window_text)) // edges in full ink
	testing.expect_value(t, c.on_surface_muted, palette_srgb(CONTRAST_PALETTE.window_text)) // no grey for secondary text
	testing.expect_value(t, th.mode, Theme_Mode.Light) // a pale ground is a light theme
	testing.expect_value(t, th.glass, Glass_Level.Solid)
	// The app's own accent does not replace a contrast theme's selection.
	branded, _ := pick_theme({}, Color{1, 0, 0, 1}, platform.Ev_Theme{high_contrast = true, palette = CONTRAST_PALETTE})
	testing.expect_value(t, branded.color.primary, palette_srgb(CONTRAST_PALETTE.selection))
}

@(test)
a_kde_scheme_becomes_the_theme :: proc(t: ^testing.T) {
	th, _ := pick_theme({}, {}, platform.Ev_Theme{dark = true, palette = KDE_PALETTE})
	c := th.color
	testing.expect_value(t, th.mode, Theme_Mode.Dark)
	testing.expect_value(t, c.bg, palette_srgb(KDE_PALETTE.window))
	testing.expect_value(t, c.surface, palette_srgb(KDE_PALETTE.view))
	testing.expect_value(t, c.primary, palette_srgb(KDE_PALETTE.selection)) // a given fill is kept exactly
	testing.expect(t, contrast_ratio(c.on_surface, c.surface) >= 7, "body text readable on the scheme's view")
	testing.expect(t, contrast_ratio(c.accent_text, c.surface) >= 4.5, "links readable")
	// An app with its own accent keeps the scheme's grounds and brings its colour.
	rose := Color{0.8, 0.1, 0.3, 1}
	branded, _ := pick_theme({}, rose, platform.Ev_Theme{dark = true, palette = KDE_PALETTE})
	testing.expect_value(t, branded.color.bg, palette_srgb(KDE_PALETTE.window))
	testing.expect_value(t, branded.color.primary, rose)
	// A theme the app names outright follows nothing, the desktop's scheme included.
	named := theme_light()
	own, _ := pick_theme(named, {}, platform.Ev_Theme{palette = KDE_PALETTE})
	testing.expect_value(t, own.color.bg, named.color.bg)
}

} // when ODIN_TEST
