#+build linux
package baldr

@(require) import "core:fmt"
@(require) import "core:testing"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A card has to read as a card. Depth is relative, not absolute: ten levels
// away from a background of 41 is a quarter of it again, eight away from 245
// is a thirty-third, so equal steps separate a light theme's surfaces far
// less than a dark one's. These floors are contrast ratios, measured the way
// the eye reads them.


// A card against its window. Dark sits at 1.09, Dim at 1.16, Light at 1.17.
@(private = "file")
CARD_FLOOR :: f32(1.08)

// A popover or a menu against the window it is over. It is the thing most
// often seen against something the toolkit did not draw (a wallpaper), so
// it carries more.
@(private = "file")
POPOVER_FLOOR :: f32(1.15)

// A light theme has no lightness left above a card, so its shadow is its
// depth; a dark one separates by lightness and needs less.
@(private = "file")
SHADOW_FLOOR :: f32(0.25)

@(test)
every_theme_separates_its_surfaces :: proc(t: ^testing.T) {
	for seed in ([]Color{BALDR_BLUE, {0.5, 0.5, 0.5, 1}, {0.8, 0.2, 0.3, 1}}) {
		for mode in Theme_Mode {
			for contrast in Theme_Contrast {
				th := theme_from_seed(seed, mode, contrast)
				c := th.color
				card := contrast_ratio(c.bg, c.surface)
				pop := contrast_ratio(c.bg, c.surface_high)
				testing.expectf(t, card >= CARD_FLOOR, "%v %v: a card on its window is %.3f:1", mode, contrast, card)
				testing.expectf(t, pop >= POPOVER_FLOOR, "%v %v: a popover on its window is %.3f:1", mode, contrast, pop)
				testing.expectf(t, contrast_ratio(c.surface, c.surface_high) > 1.01,
					"%v %v: a popover is the same colour as a card", mode, contrast)
				testing.expectf(t, contrast_ratio(c.bg, c.surface_variant) > 1.01,
					"%v %v: a sidebar is the same colour as its window", mode, contrast)
				testing.expectf(t, c.shadow.a >= SHADOW_FLOOR, "%v %v: shadow alpha %.2f", mode, contrast, c.shadow.a)
				// …and the text still reads on every one of them
				for bg in ([]Color{c.bg, c.surface, c.surface_variant, c.surface_high}) {
					testing.expectf(t, contrast_ratio(bg, c.on_surface) >= 4.5,
						"%v %v: text on %v is %.2f:1", mode, contrast, bg, contrast_ratio(bg, c.on_surface))
				}
			}
		}
	}
}

// The Light theme's own numbers, so a change to them is deliberate rather
// than a side effect: it builds its ladder downwards from white.
@(test)
the_light_theme_builds_its_depth_downwards_from_white :: proc(t: ^testing.T) {
	th := theme_light()
	c := th.color
	testing.expect(t, luminance(c.bg) < luminance(c.surface), "the window sits back from a card")
	testing.expect(t, luminance(c.surface) < luminance(c.surface_high), "…and a card from a popover")
	testing.expect(t, luminance(c.surface_high) > 0.97, "a popover is as light as it can be")
	testing.expect(t, th.color.shadow.a >= theme_dim().color.shadow.a * 0.7,
		"its shadow is in the same family as the dark themes', not a third of it")
	fmt.printf("") // keeps the import when the expectations are quiet
}

} // when ODIN_TEST