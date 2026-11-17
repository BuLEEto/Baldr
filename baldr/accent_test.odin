package baldr

@(require) import "core:testing"
@(require) import "baldr:platform"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// An app with its own accent still belongs on the desktop it runs on:
// `App.theme` keeps the brand and follows nothing, `App.accent` keeps the
// brand and follows the desktop's light/dark and its contrast setting.


@(private = "file")
ROSE :: Color{0.788, 0.322, 0.498, 1} // a brand rose, 0xc9527f

@(test)
an_accent_follows_the_desktops_light_and_dark :: proc(t: ^testing.T) {
	light, _ := pick_theme({}, ROSE, platform.Ev_Theme{dark = false})
	dark, _ := pick_theme({}, ROSE, platform.Ev_Theme{dark = true})

	testing.expect_value(t, light.mode, Theme_Mode.Light) // a light desktop, a light app
	testing.expect_value(t, dark.mode, Theme_Mode.Dark)
	testing.expect_value(t, light.seed, ROSE) // …and the app's colour through both
	testing.expect_value(t, dark.seed, ROSE)
	testing.expect(t, light.color.bg != dark.color.bg, "the two are not the same theme")
	testing.expect_value(t, light.contrast, Theme_Contrast.Normal)

	// without an accent: Baldr's own themes
	plain_light, _ := pick_theme({}, {}, platform.Ev_Theme{dark = false})
	plain_dark, _ := pick_theme({}, {}, platform.Ev_Theme{dark = true})
	testing.expect_value(t, plain_light.name, theme_light().name)
	testing.expect_value(t, plain_dark.name, theme_dark().name)

	// an app that named a theme outright still follows nothing
	named := theme_from_seed(ROSE, .Dark, name = "acme")
	by_name, _ := pick_theme(named, {}, platform.Ev_Theme{dark = false})
	testing.expect_value(t, by_name.name, "acme")
	by_name_rose, _ := pick_theme(named, ROSE, platform.Ev_Theme{dark = false})
	testing.expect_value(t, by_name_rose.mode, Theme_Mode.Dark)
}

@(test)
the_desktops_high_contrast_is_followed :: proc(t: ^testing.T) {
	// a person who turns high contrast on gets it, accent or no accent
	for dark in ([]bool{false, true}) {
		mode := Theme_Mode.Dark if dark else Theme_Mode.Light

		plain := desktop_theme({}, dark, true)
		testing.expect_value(t, plain.contrast, Theme_Contrast.High)
		testing.expect_value(t, plain.mode, mode)

		seeded := desktop_theme(ROSE, dark, true)
		testing.expect_value(t, seeded.contrast, Theme_Contrast.High)
		testing.expect_value(t, seeded.mode, mode)
		testing.expect_value(t, seeded.seed, ROSE) // the brand survives high contrast

		// and it is a stronger theme than the same seed without it
		normal := desktop_theme(ROSE, dark, false)
		testing.expect_value(t, normal.contrast, Theme_Contrast.Normal)
		testing.expect(t, contrast_ratio(seeded.color.on_bg, seeded.color.bg) >=
			contrast_ratio(normal.color.on_bg, normal.color.bg), "high contrast is not weaker")
	}
}

@(test)
every_generated_theme_stays_readable :: proc(t: ^testing.T) {
	// the accessibility floor holds whatever the desktop asks for: an app's
	// brand colour never costs the person their contrast
	for dark in ([]bool{false, true}) {
		for hc in ([]bool{false, true}) {
			th := desktop_theme(ROSE, dark, hc)
			c := th.color
			body: f32 = 10 if th.contrast == .High else 7
			floor :: proc(t: ^testing.T, name: string, fg, bg: Color, min: f32, dark, hc: bool) {
				r := contrast_ratio(fg, bg)
				testing.expectf(t, r >= min - 0.01, "dark=%v high_contrast=%v: %s = %.2f, wanted >= %.1f", dark, hc, name, r, min)
			}
			floor(t, "on_bg / bg", c.on_bg, c.bg, body, dark, hc)
			floor(t, "on_surface / surface", c.on_surface, c.surface, body, dark, hc)
			floor(t, "muted / surface", c.on_surface_muted, c.surface, 4.5, dark, hc)
			floor(t, "on_primary / primary", c.on_primary, c.primary, 4.5, dark, hc)
			floor(t, "primary as text / surface", c.primary, c.surface, 4.5, dark, hc)
			floor(t, "focus ring / bg", c.focus_ring, c.bg, 3, dark, hc)
		}
	}
}

// An app that generates its theme from an accent and then makes it its own
// (a type scale, tighter radii) keeps those through every rebuild, or the
// first light/dark switch throws its design away.
@(private = "file")
brand_type_and_radius :: proc(th: ^Theme) {
	th.type.headline.size = 19
	th.type.body.size = 13.5
	th.radius.md = 7
	th.radius.lg = 10
}

@(test)
an_apps_own_adjustments_survive_every_rebuild :: proc(t: ^testing.T) {
	// as it starts, on a light desktop
	light, _ := pick_theme({}, ROSE, platform.Ev_Theme{dark = false}, brand_type_and_radius)
	testing.expect_value(t, light.mode, Theme_Mode.Light)
	testing.expect_value(t, light.seed, ROSE)
	testing.expect_value(t, light.type.headline.size, f32(19)) // the app's, not the theme's
	testing.expect_value(t, light.radius.md, f32(7))

	// the desktop switches to dark: the theme is built again from the seed,
	// and the app's own last word is said again over it
	dark := desktop_theme(ROSE, true, false)
	theme_finish(&dark, brand_type_and_radius)
	testing.expect_value(t, dark.mode, Theme_Mode.Dark)
	testing.expect_value(t, dark.seed, ROSE)
	testing.expect_value(t, dark.type.headline.size, f32(19))
	testing.expect_value(t, dark.radius.lg, f32(10))
	testing.expect(t, dark.color.bg != light.color.bg, "and it really is the other theme")

	// high contrast too, which is built by another path
	hc := desktop_theme(ROSE, true, true)
	theme_finish(&hc, brand_type_and_radius)
	testing.expect_value(t, hc.contrast, Theme_Contrast.High)
	testing.expect_value(t, hc.type.body.size, f32(13.5))

	// an app that named a theme outright is adjusted as well: the rule is
	// every theme the runtime hands out, so there is nothing to remember
	named, _ := pick_theme(theme_from_seed(ROSE, .Dark, name = "acme"), {}, platform.Ev_Theme{}, brand_type_and_radius)
	testing.expect_value(t, named.name, "acme")
	testing.expect_value(t, named.radius.md, f32(7))

	// and with no hook, the generated theme is untouched
	plain, _ := pick_theme({}, ROSE, platform.Ev_Theme{dark = false})
	testing.expect_value(t, plain.radius.md, theme_from_seed(ROSE, .Light).radius.md)
}

} // when ODIN_TEST