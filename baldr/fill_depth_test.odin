#+build linux
package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: about 9 GB without this `when`, 1 GB with it.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A wash on a tile, and the track on it, separate as well in a light theme
// as in a dark one. The same veil is worth far less against a light
// background than a dark one, so tokens that look alike in the absolute
// do not.


// A veil over what is under it, and how far it moves it, in OKLab
// lightness, which is built to be uniform. A fraction of the background
// flatters a dark theme (a hair of light is a large share of very little),
// and a contrast ratio leans the same way more gently.
@(private = "file")
veiled :: proc(base, veil: Color) -> Color {
	return {
		veil.r * veil.a + base.r * (1 - veil.a),
		veil.g * veil.a + base.g * (1 - veil.a),
		veil.b * veil.a + base.b * (1 - veil.a),
		1,
	}
}
@(private = "file")
step :: proc(base, veil: Color) -> f32 {
	l0, _, _ := oklch_of(base)
	l1, _, _ := oklch_of(veiled(base, veil))
	return abs(l0 - l1)
}

// What a wash is worth, in OKLab lightness. Dim's tile sits at 0.037 and
// reads; these are the floors under it.
@(private = "file")
FILL_FLOOR :: f32(0.030)
@(private = "file")
STRONG_FLOOR :: f32(0.050)

@(test)
a_fill_is_worth_as_much_in_light_as_in_dark :: proc(t: ^testing.T) {
	steps: [Theme_Mode][2]f32
	for mode in Theme_Mode {
		th := theme_from_seed(BALDR_BLUE, mode)
		c := th.color
		tile := step(c.surface, c.fill)
		strong := step(c.surface, c.fill_strong)
		steps[mode] = {tile, strong}
		testing.expectf(t, tile >= FILL_FLOOR, "%v: a tile on its surface moves it by dL %.4f", mode, tile)
		testing.expectf(t, strong > tile, "%v: fill_strong is not stronger than fill", mode)
		testing.expectf(t, strong >= STRONG_FLOOR, "%v: a switched-off toggle on a tile is dL %.4f", mode, strong)
	}
	// …and within a factor of two across the modes. They are not meant to be
	// equal (a dark theme's washes carry more of its depth; a light theme has
	// the shadow instead), but a fifth of one another is a bug, not a spread.
	for mode in Theme_Mode {
		for other in Theme_Mode {
			testing.expectf(t, steps[mode][0] >= steps[other][0] * 0.5,
				"a tile in %v is dL %.4f against %v's %.4f", mode, steps[mode][0], other, steps[other][0])
			testing.expectf(t, steps[mode][1] >= steps[other][1] * 0.5,
				"an off toggle in %v is dL %.4f against %v's %.4f", mode, steps[mode][1], other, steps[other][1])
		}
	}
}

// The picked segment of a segmented control against the track it sits in.
// `surface_variant` is both a card on the window and this track, and in a
// light theme those pull opposite ways: choice_track steps away when they
// are too close rather than the theme having to choose.
@(test)
a_picked_segment_stands_off_its_track :: proc(t: ^testing.T) {
	for mode in Theme_Mode {
		for contrast in Theme_Contrast {
			th := theme_from_seed(BALDR_BLUE, mode, contrast)
			got := contrast_ratio(choice_track(&th), th.color.surface_high)
			testing.expectf(t, got >= CHOICE_TRACK_SEPARATION, "%v %v: picked segment on its track is %.3f:1", mode, contrast, got)
		}
	}
	// where the theme already separates them, the track is the theme's own
	dim := theme_dim()
	testing.expect_value(t, choice_track(&dim), dim.color.surface_variant)
}

// …and it is worth the same on a glass surface as on the app's own, though
// the wash takes a different path to the screen there: blended in linear
// light, written premultiplied in sRGB, composited in that space.
@(test)
a_wash_on_glass_is_worth_what_it_is_on_a_window :: proc(t: ^testing.T) {
	for mode in Theme_Mode {
		for backdrop in ([]f32{0.01, 0.2, 0.9}) { // a near-black wallpaper, a middling one, a near-white one
			th := theme_from_seed(BALDR_BLUE, mode)
			th.glass = .Frosted
			want := glass_step_opaque(th.color.surface, th.color.on_surface, th.color.fill.a)
			glass_legible(&th, .Panel, Backdrop_Range{backdrop, backdrop, backdrop})
			m := th.material[.Frosted].panel
			tint := Color{m.tint.r, m.tint.g, m.tint.b, 1}
			ink := th.color.on_surface
			l0, _, _ := oklch_of(glass_screen(tint, m.tint.a, ink, 0, backdrop))
			l1, _, _ := oklch_of(glass_screen(tint, m.tint.a, ink, th.color.fill.a, backdrop))
			got := abs(l0 - l1)
			testing.expectf(t, got >= want * 0.9,
				"%v over %.2f: a tile on glass moves it by dL %.4f, where the same wash on a window moves it %.4f",
				mode, backdrop, got, want)
			// the hover layer is the same wash by another name: a control
			// with no background of its own answers the pointer with it
			want_hover := glass_step_opaque(th.color.surface, th.color.on_surface, theme_from_seed(BALDR_BLUE, mode).state.hover)
			lh, _, _ := oklch_of(glass_screen(tint, m.tint.a, ink, th.state.hover, backdrop))
			testing.expectf(t, abs(l0 - lh) >= want_hover * 0.9,
				"%v over %.2f: a hover on glass moves it by dL %.4f, where it moves a window %.4f",
				mode, backdrop, abs(l0 - lh), want_hover)
		}
	}
}

// The hover and press layers are washes too: `on_surface` at one shared
// alpha is worth dL 0.027 on a white card and 0.185 on a near-black one,
// seven times as much, so a ghost button in Light would barely answer the
// pointer.
@(test)
a_hover_is_worth_seeing_in_every_theme :: proc(t: ^testing.T) {
	steps: [Theme_Mode][2]f32
	for mode in Theme_Mode {
		th := theme_from_seed(BALDR_BLUE, mode)
		c := th.color
		l0, _, _ := oklch_of(c.surface)
		lh, _, _ := oklch_of(veiled(c.surface, with_alpha(c.on_surface, th.state.hover)))
		lp, _, _ := oklch_of(veiled(c.surface, with_alpha(c.on_surface, th.state.press)))
		steps[mode] = {abs(l0 - lh), abs(l0 - lp)}
		testing.expectf(t, steps[mode][0] >= 0.06, "%v: a hover moves its surface by dL %.4f", mode, steps[mode][0])
		testing.expectf(t, steps[mode][1] > steps[mode][0], "%v: a press is not stronger than a hover", mode)
	}
	// Light stays subtler than the dark themes — a light interface is — but
	// within a factor of three, not seven
	for mode in Theme_Mode {
		for other in Theme_Mode {
			testing.expectf(t, steps[mode][0] >= steps[other][0] / 3,
				"a hover in %v is dL %.4f against %v's %.4f", mode, steps[mode][0], other, steps[other][0])
		}
	}
}

} // when ODIN_TEST