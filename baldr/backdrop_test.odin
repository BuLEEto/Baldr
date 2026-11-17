package baldr

@(require) import "core:testing"
@(require) import "baldr:platform"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too (see glass_test.odin): ODIN_TEST is set by `odin
// test`, BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A surface without glass can watch its backdrop, its view can read the
// numbers, and `legible_ink` turns them into an ink and a halo.

@(private = "file")
Bk_Msg :: enum { None }

@(private = "file")
Bk_State :: struct {}

@(private = "file")
Bk_Halo_Case :: struct { ink: Color, light: bool }

// bk_srgb makes a colour from sRGB bytes, the way a wallpaper or a theme
// file names one.
@(private = "file")
bk_srgb :: proc(r, g, b: u8) -> Color {
	return {srgb_to_linear(f32(r) / 255), srgb_to_linear(f32(g) / 255), srgb_to_linear(f32(b) / 255), 1}
}

// BK_GREY (#656667) is a desktop readout's grey, to be kept where it reads:
// 3.0:1 over a near-black wallpaper, 1.1:1 over a mid-tone one, where it
// cannot be read.
@(private = "file")
BK_GREY :: proc() -> Color { return bk_srgb(0x65, 0x66, 0x67) }

// A dark wallpaper, a mid-tone one (a plain lilac, the brightness the grey
// disappears into), and a photograph that runs from a dark hedge to a
// bright sky under one line of text.
@(private = "file") BK_DARK  :: Backdrop_Range{0.000, 0.004, 0.010}
@(private = "file") BK_LILAC :: Backdrop_Range{0.140, 0.153, 0.170}
@(private = "file") BK_PHOTO :: Backdrop_Range{0.010, 0.350, 0.950}

// The numbers reach the view, and a report on a watched surface builds it
// again — the theme is not touched, because the surface has no glass to
// adapt and the ink is the app's own.
@(test)
a_watched_surface_hands_its_backdrop_to_the_view :: proc(t: ^testing.T) {
	ui: Ui(Bk_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tree_theme(&ui.tree, theme_dim())
	_, before := backdrop_range(&ui)
	testing.expect(t, !before, "nothing measured yet: the view draws what it would have drawn")

	tree_glass(&ui.tree, false, false, .Panel, true, true) // measured, not glass
	ink := ui.tree.theme.color.on_surface
	tint := ui.tree.theme.material[.Frosted].panel.tint.a
	testing.expect(t, tree_backdrop(&ui.tree, BK_LILAC), "a report its view reads builds the view again")
	bd, ok := backdrop_range(&ui)
	testing.expect(t, ok, "and the numbers are there")
	testing.expect_value(t, bd, BK_LILAC)
	testing.expect_value(t, ui.tree.theme.color.on_surface, ink)
	testing.expect_value(t, ui.tree.theme.material[.Frosted].panel.tint.a, tint)
	testing.expect(t, !tree_backdrop(&ui.tree, BK_LILAC), "the same report changes nothing")
}

// A surface that is neither glass nor watching still gets reports — an
// applet keeps its backdrop object while its bar is Solid — and must not
// cost a view build four times a second for numbers nothing reads.
@(test)
a_report_nothing_reads_builds_no_view :: proc(t: ^testing.T) {
	ui: Ui(Bk_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tree_glass(&ui.tree, false, false, .Applet, true, false)
	testing.expect(t, !tree_backdrop(&ui.tree, BK_PHOTO), "no glass to adapt and no view reading it")
	bd, ok := backdrop_range(&ui)
	testing.expect(t, ok && bd == BK_PHOTO, "the numbers are still kept for whatever asks")
}

// Through the run loop: a .Measure surface is asked to be measured, is not
// glass, and keeps being measured when the desktop asks for less
// transparency — a theme turning Solid must not take the numbers away from
// a view that reads them.
@(test)
a_measured_surface_keeps_being_measured_when_glass_goes :: proc(t: ^testing.T) {
	log: [dynamic]platform.Backdrop
	defer delete(log)
	backend := platform.Backend{caps = {.Transparent, .Backdrop_Blur, .Backdrop_Luminance}, data = &log}
	backend.surface_set_backdrop = proc(b: ^platform.Backend, s: platform.Surface, backdrop: platform.Backdrop) {
		append((^[dynamic]platform.Backdrop)(b.data), backdrop)
	}
	rt: Runtime(Bk_State, Bk_Msg)
	rt.backend = &backend
	rt.theme = theme_dark()
	defer delete(rt.ctxs)
	c := new(Surface_Ctx(Bk_Msg))
	defer free(c)
	ui_init(&c.ui)
	defer ui_destroy(&c.ui)
	c.desc = {kind = .Layer, transparent = true, backdrop = .Measure}
	append(&rt.ctxs, c)

	apply_theme(&rt)
	testing.expect(t, len(log) == 1 && log[0] == .Measure, "asked for the brightness and nothing else")
	testing.expect(t, !c.ui.surface.glass, "and it is not glass: nothing is blurred behind it")
	testing.expect(t, c.ui.tree.glass.watch, "the tree knows its view reads the numbers")

	rt.prefs = {reduce_transparency = true} // the desktop asks for less: the theme goes Solid
	apply_theme(&rt)
	testing.expect(t, c.ui.tree.theme.glass == .Solid, "the preference is folded in")
	testing.expect(t, len(log) == 1, "and nothing was taken back")
	testing.expect(t, c.ui.tree.glass.watch)
}

// What the backend is asked for at creation: the brightness alone, and only
// where the desktop both shows through the surface and measures.
@(test)
measure_is_asked_for_only_where_it_can_be_answered :: proc(t: ^testing.T) {
	desc := Surface_Desc(Bk_Msg){kind = .Layer, transparent = true, backdrop = .Measure, layer = {anchor = {.Bottom, .Left}}}
	full := platform.Caps{.Transparent, .Layer_Shell, .Backdrop_Luminance}
	testing.expect_value(t, surface_resolve(desc, full, "app").backdrop, platform.Backdrop.Measure)
	testing.expect(t, surface_watches_backdrop(desc, full))

	no_report := platform.Caps{.Transparent, .Layer_Shell}
	testing.expect_value(t, surface_resolve(desc, no_report, "app").backdrop, platform.Backdrop.None)
	testing.expect(t, !surface_watches_backdrop(desc, no_report), "a compositor that does not measure")

	opaque := desc
	opaque.transparent = false
	testing.expect_value(t, surface_resolve(opaque, full, "app").backdrop, platform.Backdrop.None)
	testing.expect(t, !surface_watches_backdrop(opaque, full), "nothing shows through it to measure")

	glass := desc
	glass.backdrop = .Blur
	testing.expect(t, !surface_watches_backdrop(glass, full), "glass asks on its own account")

	// Nothing is painted behind the text: clearing a measured surface to the
	// glass tint would put a pale card between the readouts and the
	// wallpaper they measure.
	th := theme_dim()
	testing.expect_value(t, surface_clear(&th, desc, false), Color{})
	testing.expect_value(t, surface_shape(&th, desc, false), Color{})
	round := desc
	round.radius = 12
	testing.expect_value(t, surface_clear(&th, round, false), Color{})
}

// The wallpaper the colour was chosen for: it is left exactly as it is,
// with no halo.
@(test)
a_colour_that_reads_over_the_wallpaper_is_left_alone :: proc(t: ^testing.T) {
	grey := BK_GREY()
	ink, glow := legible_ink(BK_DARK, grey, 3)
	testing.expect_value(t, ink, grey)
	testing.expect_value(t, glow, Glow{})
	testing.expectf(t, ink_worst(ink, BK_DARK) >= 3, "and it does read: %.2f:1", ink_worst(ink, BK_DARK))
}

// A mid-tone wallpaper the grey vanishes into: the ink moves until it
// reads over the whole of it, and still wears no halo — one colour reads
// everywhere here, which is the whole point of measuring.
@(test)
a_mid_tone_wallpaper_moves_the_ink_and_needs_no_halo :: proc(t: ^testing.T) {
	grey := BK_GREY()
	testing.expectf(t, ink_worst(grey, BK_LILAC) < 1.5, "the grey is invisible on it: %.2f:1", ink_worst(grey, BK_LILAC))
	ink, glow := legible_ink(BK_LILAC, grey, 3)
	testing.expectf(t, ink_worst(ink, BK_LILAC) >= 3, "the ink reads over all of it: %.2f:1", ink_worst(ink, BK_LILAC))
	testing.expect_value(t, glow, Glow{})
	testing.expect(t, ink != grey)
}

// Where both a darker and a lighter ink would read, the one that moves less
// wins: a light grey over a dark-mid wallpaper goes lighter, not to near
// black, because the point is to keep the colour the app asked for.
@(test)
the_ink_moves_as_little_as_it_can :: proc(t: ^testing.T) {
	pale := bk_srgb(0xcc, 0xcc, 0xcc)
	bd := Backdrop_Range{0.15, 0.18, 0.20}
	testing.expectf(t, ink_worst(pale, bd) < 3, "it does not read as it is: %.2f:1", ink_worst(pale, bd))
	ink, glow := legible_ink(bd, pale, 3)
	testing.expectf(t, luminance(ink) > luminance(pale), "lighter, not darker (%.3f from %.3f)", luminance(ink), luminance(pale))
	testing.expectf(t, ink_worst(ink, bd) >= 3, "%.2f:1", ink_worst(ink, bd))
	testing.expect_value(t, glow, Glow{})
}

// A photograph under one line of text: no single colour can read over dark
// hedge and bright sky, so the ink reads over the average and a halo in the
// opposite tone carries it over the rest.
@(test)
a_backdrop_too_wide_for_one_colour_gets_a_halo :: proc(t: ^testing.T) {
	grey := BK_GREY()
	ink, glow := legible_ink(BK_PHOTO, grey, 3)
	mid := Backdrop_Range{BK_PHOTO.avg, BK_PHOTO.avg, BK_PHOTO.avg}
	testing.expectf(t, ink_worst(ink, mid) >= 3, "it reads over the average: %.2f:1", ink_worst(ink, mid))
	testing.expect(t, glow.radius > 0 && glow.passes > 1, "and wears the halo")
	testing.expect_value(t, glow, legible_halo_over(ink, BK_PHOTO.avg))
	testing.expect(t, (luminance(glow.color) > 0.5) != (luminance(ink) > 0.5), "the halo is the opposite tone to the ink")
}

// The halo's tone is decided by what the ink was picked against, not by the
// ink alone. A dark photograph with a light band across it reads
// 0.001 / 0.061 / 0.401: the average is dark, so the ink is lifted to read
// against it, and what it then fails against is the bright band. A halo
// chosen from the ink's own luminance would be white there (the ink is dark
// in absolute terms) and would smear into the band it exists to stand off.
@(test)
a_light_ink_over_a_dark_photo_takes_a_dark_halo :: proc(t: ^testing.T) {
	photo := Backdrop_Range{0.001, 0.061, 0.401}
	ink, glow := legible_ink(photo, BK_GREY(), 3)
	testing.expectf(t, luminance(ink) > photo.avg, "the ink is lifted over the average (%.3f over %.3f)", luminance(ink), photo.avg)
	testing.expect(t, luminance(ink) < 0.5, "and is still dark in absolute terms, which is what misled the blind rule")
	testing.expect(t, glow != Glow{}, "no one colour reads over that range")
	bright := glass_over({}, 0, photo.max)
	testing.expectf(t, contrast_ratio(glow.color, bright) >= 3,
		"the halo stands off the bright part the ink cannot (%.2f:1)", contrast_ratio(glow.color, bright))
	testing.expectf(t, contrast_ratio(glow.color, ink) >= 3,
		"and off the ink itself (%.2f:1)", contrast_ratio(glow.color, ink))
	testing.expect_value(t, glow.color.r, f32(0)) // a dark halo
}

// The blind rule — for an icon view's labels, which know nothing of what is
// behind them — picks the tone by contrast, not by a midpoint. The crossover
// is a luminance of about 0.18: a mid-light grey is 10:1 against black and
// 2.1:1 against white.
@(test)
a_halo_with_nothing_measured_is_the_tone_that_stands_off_the_ink :: proc(t: ^testing.T) {
	cases := [3]Bk_Halo_Case{
		{{0.02, 0.02, 0.02, 1}, true},  // near-black ink: a white outline
		{{0.90, 0.90, 0.90, 1}, false}, // near-white: a black one
		{{0.45, 0.45, 0.45, 1}, false}, // mid-light: black at 10:1, where white would be 2.1:1
	}
	for c in cases {
		g := legible_halo(c.ink)
		testing.expectf(t, (g.color.r > 0.5) == c.light, "ink %.2f took the wrong tone", luminance(c.ink))
		testing.expectf(t, contrast_ratio(g.color, c.ink) >= 3, "and it must stand off the ink (%.2f:1)", contrast_ratio(g.color, c.ink))
	}
}

// Nothing measured is the worst case — anything from black to white — and
// no single colour beats that, so the halo is what is left. A view with no
// report yet is better served by its own fallback, which is why
// backdrop_range says whether there has been one.
@(test)
an_unmeasured_backdrop_falls_back_to_the_halo :: proc(t: ^testing.T) {
	ink, glow := legible_ink(BACKDROP_UNKNOWN, BK_GREY(), 3)
	testing.expect(t, glow != Glow{})
	testing.expect_value(t, glow, legible_halo_over(ink, BACKDROP_UNKNOWN.avg))
}

// The move keeps the colour's hue: a warm readout stays warm, it only gets
// lighter or darker. Moving to plain black or white would throw away the
// one thing the app chose.
@(test)
the_ink_keeps_its_hue :: proc(t: ^testing.T) {
	amber := bk_srgb(0xc8, 0x8a, 0x2c)
	_, _, want := oklch_of(amber)
	ink, _ := legible_ink(Backdrop_Range{0.70, 0.80, 0.90}, amber, 4.5)
	_, chroma, hue := oklch_of(ink)
	testing.expectf(t, abs(hue - want) < 5, "hue %.1f° from %.1f°", hue, want)
	testing.expect(t, chroma > 0.01, "and some of its chroma")
	testing.expectf(t, ink_worst(ink, Backdrop_Range{0.70, 0.80, 0.90}) >= 4.5, "%.2f:1", ink_worst(ink, Backdrop_Range{0.70, 0.80, 0.90}))
}


// An ink the backdrop's own middle hides.
//
// `ink_worst` checks three numbers, and a photograph is not three numbers.
// A grey halfway between the ends reaches `contrast` against the darkest
// part, the brightest part *and* the average, while a fifth of what is
// behind sits at its own brightness, where it reads 1.1:1. Here: 30% of the
// cells near black, 20% at 0.15, half of them white, under a grey of
// luminance 0.132.
//
// What it must not answer is the preferred grey, bare.
@(test)
an_ink_the_middle_of_a_backdrop_hides :: proc(t: ^testing.T) {
	grey := rgb(0x656667)
	bd := Backdrop_Range{min = 0.002, avg = 0.3 * 0.002 + 0.2 * 0.15 + 0.5 * 1.0, max = 1.0}
	ink, glow := legible_ink(bd, grey, 3)
	testing.expectf(t, luminance(grey) > bd.min && luminance(grey) < bd.max,
		"the premise: the ink's own luminance %.3f lies inside the backdrop", luminance(grey))
	testing.expectf(t, ink != grey || glow != Glow{},
		"an ink inside the backdrop's range needs moving or a halo: got the preferred grey bare (worst %.2f:1)",
		ink_worst(grey, bd))

	// What it answers, and why that is the right answer rather than merely
	// a different one. The grey *does* read against the average (3.2:1), so
	// it is kept — `legible_ink`'s contract is the colour nearest preferred
	// that reads over the average — and the halo carries it over the rest.
	testing.expect_value(t, ink, grey)
	testing.expectf(t, contrast_ratio(ink, {bd.avg, bd.avg, bd.avg, 1}) >= 3,
		"kept because it reads against the average: %.2f:1", contrast_ratio(ink, {bd.avg, bd.avg, bd.avg, 1}))
	testing.expect(t, glow != Glow{}, "and it is carried by a halo")
	// A **light** halo: the ink is darker than the average, so what it
	// cannot read against is the dark end, and the outline has to be the
	// bright one. Over the 0.15 band that hid the glyph, white reads 5.3:1.
	testing.expectf(t, glow.color.r > 0.5 && glow.color.a > 0.5,
		"a light halo, not a dark one: %v", glow.color)
	// (contrast_ratio reads luminance, which is the three channels: the
	// halo's own alpha is how dense the outline is drawn, not its colour.)
	testing.expectf(t, contrast_ratio(glow.color, {0.15, 0.15, 0.15, 1}) >= 4.5,
		"and it reads over the band the ink does not: %.2f:1",
		contrast_ratio(glow.color, {0.15, 0.15, 0.15, 1}))
}

// …and the same rule must not cost a halo where one colour really does
// read everywhere. Glass is the ordinary case: the backdrop is blurred, so
// its range is narrow, and an ink that clears the contrast at both ends of
// a narrow range is already outside it.
@(test)
an_ink_clear_of_a_narrow_backdrop_still_passes_bare :: proc(t: ^testing.T) {
	bd := Backdrop_Range{min = 0.70, avg = 0.80, max = 0.90} // frosted glass over something bright
	ink, glow := legible_ink(bd, rgb(0x101010), 4.5)
	testing.expect(t, glow == Glow{}, "nothing is hidden behind glass this even: no halo")
	testing.expectf(t, luminance(ink) < bd.min, "and the ink sits clear of it: %.3f", luminance(ink))
}
}
