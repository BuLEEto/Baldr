package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(test)
color_oklch_round_trips_and_contrast_math :: proc(t: ^testing.T) {
	c := rgb(0x3B82F6)
	L, C, h := oklch_of(c)
	testing.expect(t, L > 0.55 && L < 0.70, "blue's lightness")
	testing.expect(t, C > 0.15, "vivid")
	testing.expect(t, h > 250 && h < 275, "blue hue")
	back := oklch(L, C, h)
	testing.expect(t, abs(back.r - c.r) < 0.01 && abs(back.g - c.g) < 0.01 && abs(back.b - c.b) < 0.01, "round trip")
	white, black := Color{1, 1, 1, 1}, Color{0, 0, 0, 1}
	testing.expect(t, abs(contrast_ratio(white, black) - 21) < 0.01)
	testing.expect(t, abs(contrast_ratio(white, white) - 1) < 0.001)
	vivid := oklch(0.7, 0.4, 30) // out of gamut: mapped by reducing chroma
	testing.expect(t, vivid.r <= 1 && vivid.g >= 0 && vivid.b >= 0)
	l2, _, h2 := oklch_of(vivid)
	testing.expect(t, abs(l2 - 0.7) < 0.02 && abs(h2 - 30) < 3, "lightness and hue survive gamut mapping")
	fixed := ensure_contrast(oklch(0.5, 0.05, 260), oklch(0.45, 0.01, 260), 4.5)
	testing.expect(t, contrast_ratio(fixed, oklch(0.45, 0.01, 260)) >= 4.5, "ensure_contrast reaches the ratio")
}

@(private = "file")
check_theme :: proc(t: ^testing.T, th: Theme) {
	c := th.color
	body: f32 = 10 if th.contrast == .High else 7
	ok :: proc(t: ^testing.T, name: string, fg, bg: Color, min: f32, theme: string) {
		r := contrast_ratio(fg, bg)
		testing.expectf(t, r >= min - 0.01, "%s: %s = %.2f, wanted ≥ %.1f", theme, name, r, min)
	}
	ok(t, "on_bg / bg", c.on_bg, c.bg, body, th.name)
	ok(t, "on_surface / surface", c.on_surface, c.surface, body, th.name)
	ok(t, "on_surface / surface_variant", c.on_surface, c.surface_variant, 4.5, th.name)
	ok(t, "on_surface / surface_high", c.on_surface, c.surface_high, 4.5, th.name)
	ok(t, "muted / surface", c.on_surface_muted, c.surface, 4.5, th.name)
	ok(t, "muted / surface_variant", c.on_surface_muted, c.surface_variant, 4.5, th.name)
	ok(t, "on_primary / primary", c.on_primary, c.primary, 4.5, th.name)
	ok(t, "on_primary_container / primary_container", c.on_primary_container, c.primary_container, 4.5, th.name)
	ok(t, "on_secondary / secondary", c.on_secondary, c.secondary, 4.5, th.name)
	ok(t, "on_danger / danger", c.on_danger, c.danger, 4.5, th.name)
	ok(t, "primary as text / surface", c.primary, c.surface, 4.5, th.name)
	ok(t, "danger / surface", c.danger, c.surface, 3, th.name)
	ok(t, "focus ring / bg", c.focus_ring, c.bg, 3, th.name)
	ok(t, "outline / surface", c.outline, c.surface, 1.3, th.name)
	// syntax colours read over the editor's well in every theme
	code_cols := [7]Color{c.code.keyword, c.code.type, c.code.string, c.code.number, c.code.constant, c.code.attribute, c.code.comment}
	code_names := [7]string{"code.keyword", "code.type", "code.string", "code.number", "code.constant", "code.attribute", "code.comment"}
	for col, i in code_cols do ok(t, code_names[i], col, c.surface_variant, 4.5, th.name)
	// no pure black or white anywhere in text and surfaces
	for col in ([]Color{c.bg, c.surface, c.on_surface, c.on_bg}) {
		testing.expect(t, col.r + col.g + col.b > 0.003 && col.r + col.g + col.b < 2.997, "never pure black or white")
	}
	// surfaces step up in lightness with elevation (dark) or stay flat/white (light)
	lb, _, _ := oklch_of(c.bg)
	ls, _, _ := oklch_of(c.surface)
	lh, _, _ := oklch_of(c.surface_high)
	if th.mode != .Light do testing.expect(t, lb < ls && ls < lh, "elevation steps up")
	if th.mode == .Light do testing.expect(t, ls >= lb, "cards sit on a slightly darker page")
	if th.contrast == .High do testing.expect(t, th.glass == .Solid && th.material[.Solid].panel.tint.a == 1, "high contrast makes glass Solid and opaque")
}

@(test)
built_in_themes_meet_contrast_and_comfort_rules :: proc(t: ^testing.T) {
	check_theme(t, theme_dark())
	check_theme(t, theme_dim())
	check_theme(t, theme_light())
	check_theme(t, theme_high_contrast(.Dark))
	check_theme(t, theme_high_contrast(.Light))
	testing.expect(t, theme_dark().dark && theme_dim().dark && !theme_light().dark)
}

@(test)
seeded_themes_are_readable_for_any_hue :: proc(t: ^testing.T) {
	for hue in ([]f32{0, 30, 60, 100, 150, 200, 240, 262, 290, 330}) {
		seed := oklch(0.6, 0.18, hue)
		for mode in Theme_Mode {
			for contrast in Theme_Contrast {
				th := theme_from_seed(seed, mode, contrast)
				check_theme(t, th)
				_, pc, ph := oklch_of(th.color.primary)
				testing.expect(t, pc > 0.05, "the accent keeps its colour")
				dh := abs(ph - hue)
				if dh > 180 do dh = 360 - dh
				testing.expect(t, dh < 12, "the accent keeps its hue")
			}
		}
	}
	// A grey seed gets a grey accent, not a default hue at the mode's full
	// chroma; the tests below pin the rest of what it gives.
	grey := theme_from_seed(oklch(0.5, 0, 0), .Dark)
	_, gc, _ := oklch_of(grey.color.primary)
	testing.expect(t, gc < 0.004, "a grey seed gets a grey accent")
}

// A dark, flat, monochrome desktop style's neutral accent. A seed this grey
// must give a grey theme, not one whose sidebar and switches light up in a
// default hue beside the desktop's grey title bars and menus.
@(private = "file")
NIBBLE_GREY :: 0x8a8a8a

@(test)
a_grey_seed_gives_a_grey_theme :: proc(t: ^testing.T) {
	for mode in Theme_Mode {
		for contrast in Theme_Contrast {
			th := theme_from_seed(rgb(NIBBLE_GREY), mode, contrast, name = "Nibble")
			check_theme(t, th) // readable by construction, exactly as a coloured seed is
			cols := [16]Color{
				th.color.primary, th.color.on_primary,
				th.color.primary_container, th.color.on_primary_container,
				th.color.secondary, th.color.on_secondary,
				th.color.focus_ring, th.color.selection,
				th.color.bg, th.color.surface, th.color.surface_variant, th.color.surface_high,
				th.color.on_bg, th.color.on_surface_muted,
				th.color.outline, th.color.outline_variant,
			}
			names := [16]string{
				"primary", "on_primary",
				"primary_container", "on_primary_container",
				"secondary", "on_secondary",
				"focus_ring", "selection",
				"bg", "surface", "surface_variant", "surface_high",
				"on_bg", "on_surface_muted",
				"outline", "outline_variant",
			}
			for col, i in cols {
				_, c, _ := oklch_of(col)
				testing.expectf(t, c < 0.004, "%v %v: %s has chroma %.4f, wanted neutral", mode, contrast, names[i], c)
			}
		}
	}
}

@(test)
a_grey_theme_still_warns_in_colour :: proc(t: ^testing.T) {
	// The accent is identity and goes grey with the seed; danger, warning,
	// success and the syntax colours carry *meaning* and do not.
	for mode in Theme_Mode {
		th := theme_from_seed(rgb(NIBBLE_GREY), mode)
		cols := [3]Color{th.color.danger, th.color.warning, th.color.success}
		hues := [3]f32{25, 75, 150}
		names := [3]string{"danger", "warning", "success"}
		for col, i in cols {
			_, c, h := oklch_of(col)
			testing.expectf(t, c > 0.08, "%v: %s lost its colour (chroma %.3f)", mode, names[i], c)
			dh := abs(h - hues[i])
			if dh > 180 do dh = 360 - dh
			testing.expectf(t, dh < 12, "%v: %s moved hue (%.0f, wanted about %.0f)", mode, names[i], h, hues[i])
		}
		_, kc, _ := oklch_of(th.color.code.keyword)
		_, sc, _ := oklch_of(th.color.code.string)
		testing.expectf(t, kc > 0.05 && sc > 0.05, "%v: the code palette keeps its colours (%.3f, %.3f)", mode, kc, sc)
	}
}

// A style whose colours are a design of their own rather than something to
// generate: its dark window is lighter than Baldr's Dim window, and its
// views sit *darker* than the window they are in.
@(private = "file")
given_greys :: proc(mode: Theme_Mode) -> Theme_Palette {
	switch mode {
	case .Light:
		return {
			bg = rgb(0xcecece), surface = rgb(0xfcfcfc), surface_variant = rgb(0xe4e4e4), surface_high = rgb(0xf5f5f5),
			on_bg = rgb(0x3c3c3c), on_surface = rgb(0x212121), on_surface_muted = rgb(0x858585),
			outline = rgb(0x828282), primary = rgb(0x8d8d8d), on_primary = rgb(0xffffff),
		}
	case .Dim:
		return {
			bg = rgb(0x4a4d4f), surface = rgb(0x3c3e40), surface_variant = rgb(0x44474a), surface_high = rgb(0x56595c),
			on_bg = rgb(0xeeeeee), on_surface = rgb(0xf6f6f6), on_surface_muted = rgb(0xa3a4a5),
			outline = rgb(0x2a2c2d), primary = rgb(0x9a9a9a), on_primary = rgb(0xffffff),
		}
	case .Dark:
		return {
			bg = rgb(0x3b3e3f), surface = rgb(0x2d2e30), surface_variant = rgb(0x353839), surface_high = rgb(0x45484a),
			on_bg = rgb(0xeeeeee), on_surface = rgb(0xffffff), on_surface_muted = rgb(0x959697),
			outline = rgb(0x1d1f1f), primary = rgb(0x949494), on_primary = rgb(0xffffff),
		}
	}
	return {}
}

@(test)
a_palette_is_taken_as_given :: proc(t: ^testing.T) {
	for mode in Theme_Mode {
		p := given_greys(mode)
		th := theme_from_palette(p, mode, name = "Given greys")
		testing.expect_value(t, th.mode, mode) // the caller's, never read off the colours
		// The grounds are what the style drew: nothing moves them, because
		// contrast is solved by moving what sits *on* them.
		testing.expect_value(t, th.color.bg, p.bg)
		testing.expect_value(t, th.color.surface, p.surface)
		testing.expect_value(t, th.color.surface_variant, p.surface_variant)
		testing.expect_value(t, th.color.surface_high, p.surface_high)
	}
	// and the ladder is the palette's business: these views sit darker
	// than the window they are in, which a generated theme never does
	dark := theme_from_palette(given_greys(.Dark), .Dark)
	lb, _, _ := oklch_of(dark.color.bg)
	ls, _, _ := oklch_of(dark.color.surface)
	testing.expectf(t, ls < lb, "the palette's own ladder is kept (bg %.3f, surface %.3f)", lb, ls)
	// High contrast is not a palette's to override: a mid-grey window
	// cannot carry 10:1 text whatever is put on it, so the generated
	// theme — grey too, for a grey accent — comes back instead.
	p_dark := given_greys(.Dark)
	hc := theme_from_palette(p_dark, .Dark, .High)
	testing.expect_value(t, hc.color.bg, theme_from_seed(p_dark.primary, .Dark, .High).color.bg)
	testing.expect(t, hc.color.bg != p_dark.bg, "the palette's own window is not used under high contrast")
	// a palette that names nothing is the generated theme, unchanged
	none := theme_from_palette({}, .Dark)
	seeded := theme_from_seed(BALDR_BLUE, .Dark)
	testing.expect_value(t, none.color.bg, seeded.color.bg)
	testing.expect_value(t, none.color.primary, seeded.color.primary)
}

@(test)
a_palette_is_readable_anyway :: proc(t: ^testing.T) {
	ok :: proc(t: ^testing.T, name: string, fg, bg: Color, min: f32, mode: Theme_Mode, contrast: Theme_Contrast) {
		r := contrast_ratio(fg, bg)
		testing.expectf(t, r >= min - 0.01, "%v %v: %s = %.2f, wanted ≥ %.1f", mode, contrast, name, r, min)
	}
	for mode in Theme_Mode {
		for contrast in Theme_Contrast {
			c := theme_from_palette(given_greys(mode), mode, contrast).color
			body: f32 = 10 if contrast == .High else 7
			muted: f32 = 7 if contrast == .High else 4.5
			ok(t, "on_bg / bg", c.on_bg, c.bg, body, mode, contrast)
			ok(t, "on_surface / surface", c.on_surface, c.surface, body, mode, contrast)
			ok(t, "muted / surface_variant", c.on_surface_muted, c.surface_variant, muted, mode, contrast)
			ok(t, "on_primary / primary", c.on_primary, c.primary, 4.5, mode, contrast)
			// The as-text bar is on `accent_text`, not `primary`: one colour
			// cannot be both the exact fill a style named and readable ink.
			ok(t, "accent_text / surface", c.accent_text, c.surface, 4.5, mode, contrast)
			ok(t, "on_secondary / secondary", c.on_secondary, c.secondary, 4.5, mode, contrast)
			ok(t, "on_danger / danger", c.on_danger, c.danger, 4.5, mode, contrast)
			ok(t, "focus ring / bg", c.focus_ring, c.bg, 3, mode, contrast)
		}
	}
	// The light style's muted grey is about 3.2:1 on its sidebar, so it
	// comes back moved: readable beats faithful for a text colour.
	given := given_greys(.Light)
	got := theme_from_palette(given, .Light).color.on_surface_muted
	testing.expect(t, got != given.on_surface_muted, "a muted grey short of 4.5:1 is pushed")
	testing.expect(t, contrast_ratio(given.on_surface_muted, given.surface_variant) < 4.5, "…and it was short to begin with")
	// …but the *accent* is not pushed: it is the fill the style named, and
	// the ink that has to clear 4.5:1 is `accent_text`. For a fill, faithful
	// wins: a selection bar that is not the style's grey is simply wrong.
	fill := theme_from_palette(given, .Light).color.primary
	testing.expect(t, contrast_ratio(given.primary, given.surface) < 4.5, "the style's accent is short of 4.5:1 as text")
	testing.expectf(t, abs(fill.r - given.primary.r) < 0.002 && abs(fill.g - given.primary.g) < 0.002 && abs(fill.b - given.primary.b) < 0.002,
		"…and is still kept as the fill (%v vs %v)", fill, given.primary)
}

@(test)
what_a_palette_leaves_out_belongs_to_it :: proc(t: ^testing.T) {
	// The roles the table does not name are mixed from the ones it does,
	// not left at the generated theme's own lightnesses — those belong to
	// a ladder this palette is not on.
	for mode in Theme_Mode {
		p := given_greys(mode)
		c := theme_from_palette(p, mode).color
		lo, _, _ := oklch_of(c.outline_variant)
		l_outline, _, _ := oklch_of(c.outline)
		l_surface, _, _ := oklch_of(c.surface)
		between := (lo >= min(l_outline, l_surface) - 0.01) && (lo <= max(l_outline, l_surface) + 0.01)
		testing.expectf(t, between, "%v: outline_variant %.3f sits between outline %.3f and surface %.3f", mode, lo, l_outline, l_surface)

		l_secondary, _, _ := oklch_of(c.secondary)
		l_bg, _, _ := oklch_of(c.bg)
		testing.expectf(t, abs(l_secondary - l_bg) < 0.12, "%v: the secondary ground is the palette's, not the recipe's (%.3f against bg %.3f)", mode, l_secondary, l_bg)

		testing.expect_value(t, c.selection.a, f32(0.30))
		_, sel_c, _ := oklch_of(c.selection)
		testing.expectf(t, sel_c < 0.004, "%v: a grey palette selects in grey (chroma %.4f)", mode, sel_c)
	}
}

@(test)
the_accent_fades_in_without_a_cliff :: proc(t: ^testing.T) {
	// A seed's chroma ramps the accent's rather than switching it: two
	// seeds the eye cannot tell apart must not give grey against blue.
	seeds := []f32{0, 0.005, 0.010, 0.015, 0.019, 0.021, 0.04, 0.18}
	last: f32 = -1
	for sc in seeds {
		_, pc, _ := oklch_of(theme_from_seed(oklch(0.6, sc, NEUTRAL_CODE_HUE), .Dark).color.primary)
		testing.expectf(t, pc >= last - 0.001, "seed chroma %.3f gave %.4f after %.4f: the accent only rises", sc, pc, last)
		last = pc
	}
	_, below, _ := oklch_of(theme_from_seed(oklch(0.6, 0.019, NEUTRAL_CODE_HUE), .Dark).color.primary)
	_, above, _ := oklch_of(theme_from_seed(oklch(0.6, 0.021, NEUTRAL_CODE_HUE), .Dark).color.primary)
	testing.expectf(t, abs(above - below) < 0.02, "no cliff at the ramp's top (%.4f against %.4f)", below, above)
	// and at the top the accent has Dark's own chroma, 0.13
	_, full, _ := oklch_of(theme_from_seed(oklch(0.6, NEUTRAL_SEED_C, NEUTRAL_CODE_HUE), .Dark).color.primary)
	testing.expectf(t, abs(full - 0.13) < 0.005, "a seed at the ramp's top keeps the mode's chroma, not %.4f", full)
}

// An app that works a size out in `adjust_theme` (a text size setting) must
// see it change when it re-applies the theme, and must not see it compound,
// which is what running the adjust again over the running theme would do.
@(private = "file")
Th_Msg :: enum { None }

@(test)
refresh_theme_runs_the_apps_adjust_again_without_compounding :: proc(t: ^testing.T) {
	ui: Ui(Th_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree

	// An adjust that *multiplies*, which is what makes compounding visible.
	tr.adjust_theme = proc(th: ^Theme) { th.type.body.size *= 2 }

	base := tr.theme
	base.type.body.size = 10
	tree_desktop_theme(tr, base, base)
	tr.theme_app = false

	refresh_theme(tr)
	once := tr.theme.type.body.size
	testing.expectf(t, once == 20, "the adjust ran: body %v, wanted 20", once)

	refresh_theme(tr)
	twice := tr.theme.type.body.size
	testing.expectf(t, twice == 20, "the adjust ran over its own output: body %v, wanted 20", twice)

	// The same for a theme the app pinned.
	pinned := tr.theme
	pinned.type.body.size = 7
	set_theme(tr, pinned)
	testing.expectf(t, tr.theme.type.body.size == 14, "set_theme adjusts once: %v", tr.theme.type.body.size)
	refresh_theme(tr)
	testing.expectf(t, tr.theme.type.body.size == 14, "refresh of a pinned theme does not compound: %v", tr.theme.type.body.size)

	// And going back to the desktop's re-derives rather than reinstalling
	// what was finished at the last desktop change.
	tr.adjust_theme = proc(th: ^Theme) { th.type.body.size *= 3 }
	follow_system_theme(tr)
	testing.expectf(t, tr.theme.type.body.size == 30, "follow_system_theme ran the new adjust: %v", tr.theme.type.body.size)
}

} // when ODIN_TEST