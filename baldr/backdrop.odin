package baldr

// Text that knows what is behind it.
//
// A surface drawn straight on the desktop — a corner of system readouts, a
// clock on the wallpaper — has no background of its own, so nothing about
// its colours can be settled when it is written: the grey that reads over a
// dark photograph disappears into a pale one. A halo on every glyph always
// reads, but looks heavy over a plain wallpaper.
//
// `Surface_Desc.backdrop = .Measure` asks the compositor how bright what is
// behind the surface is without asking it to blur anything;
// `backdrop_range` hands a view those numbers, and `legible_ink` turns them
// into the ink and the halo to draw with — the preferred colour where it
// reads, a darker or lighter one where it does not, and a halo only where
// no single colour can read over the whole range.
//
// Glass is the other half of the same question, and the toolkit answers it
// on its own (glass.odin): a glass surface has a tint and a theme to adapt.
// Here the app decides, because the text is its own and so is the colour it
// would rather keep.

// backdrop_range is how bright what lies behind this surface is, as the
// compositor last reported it, and whether it has reported at all.
//
// `ok` is false when there are no numbers: the compositor does not measure
// backdrops (`Cap.Backdrop_Luminance`), the surface never asked
// (`Surface_Desc.backdrop` is `.None`), or its first report has not arrived
// (a frame or two after mapping). The view is built again when the report
// comes, so pass `ok` on rather than waiting for it. For a glass surface
// the numbers are what shows through the blur, and the theme is already
// adapted to them (`glass_legible`).
backdrop_range :: proc(ui: ^Ui($Msg)) -> (bd: Backdrop_Range, ok: bool) {
	g := ui.tree.glass
	return g.backdrop, g.known
}

// legible_ink picks the colour to draw text in over a measured backdrop,
// and the halo it needs there — the rule `glass_legible` follows for glass,
// for an app that draws straight on the desktop.
//
// In order: `preferred` itself, with no halo, where it reaches `contrast`
// over the whole backdrop; else `preferred` with its OKLCH lightness moved
// (down or up, whichever moves less) just far enough, still with no halo;
// else, where no single colour reads over the whole range, the colour
// nearest `preferred` that reads over the backdrop's average, with a halo
// (`legible_halo_over`) to carry it over the rest. `contrast` defaults to
// the toolkit's text ratio; 3 is the floor for large or decorative text.
// The glow is `{}` when none is needed, so it can go to `set_glow` as is.
legible_ink :: proc(bd: Backdrop_Range, preferred: Color, contrast: f32 = GLASS_TEXT_CONTRAST) -> (ink: Color, glow: Glow) {
	if ink_worst(preferred, bd) >= contrast do return preferred, {}
	if c, ok := ink_against(preferred, bd, contrast); ok do return c, {}
	mid := Backdrop_Range{bd.avg, bd.avg, bd.avg}
	if ink_worst(preferred, mid) >= contrast do return preferred, legible_halo_over(preferred, bd.avg)
	c, _ := ink_against(preferred, mid, contrast)
	return c, legible_halo_over(c, bd.avg)
}

// legible_halo is the glow that makes a glyph read over a backdrop nobody
// measured (an icon view's labels over a wallpaper): whichever of white or
// black stands off the ink more, dense enough to be an outline
// (LABEL_HALO_*). The tone is
// chosen by contrast, not by a luminance midpoint: black and white stand
// off an ink equally at a luminance of about 0.18, not 0.5. Where the
// backdrop has been measured, use `legible_halo_over`.
legible_halo :: proc "contextless" (ink: Color) -> Glow {
	return halo_tone(contrast_ratio(ink, {1, 1, 1, 1}) >= contrast_ratio(ink, {0, 0, 0, 1}))
}

// legible_halo_over is the halo for an ink picked to read against a
// backdrop's average (`legible_ink`'s last resort). Its tone is the far
// side of that average from the ink, not the tone that stands off the ink
// most: the halo carries the text over the parts of the backdrop beyond the
// average, so a light ink over a dark photograph takes a dark halo, where
// the blind rule (`legible_halo`) would give a white one that vanishes into
// the bright patches. The halo still stands off the ink by at least
// `contrast`, since the ink clears that against the average.
legible_halo_over :: proc "contextless" (ink: Color, avg: f32) -> Glow {
	return halo_tone(luminance(ink) <= avg) // darker than what it was picked against → a light halo
}

// halo_tone is the outline itself: white or black at the density an
// outline needs.
@(private)
halo_tone :: proc "contextless" (light: bool) -> Glow {
	return {
		color  = {1, 1, 1, LABEL_HALO_ALPHA} if light else {0, 0, 0, LABEL_HALO_ALPHA},
		radius = LABEL_HALO_RADIUS,
		passes = LABEL_HALO_PASSES,
	}
}

// set_glow puts a halo behind one node's own text or icons (`legible_ink`'s
// second answer); `{}` takes it off. Set it on the text or icon node, not
// its row: the renderer leaves room around a glowing glyph (GLOW_OVERHANG)
// only for the node that carries the glow.
set_glow :: proc(t: ^Tree, n: Node, glow: Glow) {
	d := node_get(t, n)
	if d == nil || d.style.glow == glow do return
	st := d.style
	st.glow = glow
	set_style(t, n, st)
}

// INK_STEPS is how finely legible_ink moves a colour's lightness toward
// black or white, taking the first step that reads. A scan, not a
// bisection: contrast over a range is not monotonic in the move (darkening
// gains against the brightest part and loses against the darkest), so the
// steps that read form a band that halving can step over.
@(private)
INK_STEPS :: 100

// ink_worst is the lowest contrast `fg` has over the backdrop: against its
// darkest part, its brightest and its average, and 1:1 whenever its own
// brightness lies between the ends. Summary numbers cannot say how much of
// a picture sits at the ink's own brightness, so an ink inside the range is
// treated as unreadable: one that clears both ends and the average can still
// vanish against a band of its own brightness. Over a narrow backdrop
// (glass, where the blur leaves little spread) an ink that clears both ends
// is already outside the range, so only bare ink over a photograph pays.
@(private)
ink_worst :: proc "contextless" (fg: Color, bd: Backdrop_Range) -> f32 {
	// The ink's own brightness is somewhere behind it: that part reads 1:1.
	if y := luminance(fg); y > bd.min && y < bd.max do return 1
	return min(glass_worst(fg, {}, 0, bd), contrast_ratio(fg, glass_over({}, 0, bd.avg)))
}

// ink_against moves `preferred` toward black and toward white and answers
// with the smaller move that reaches `contrast` over the whole backdrop.
// `ok` is false when neither end does; the colour is then the better of the
// two ends, which is as far as one colour goes there.
@(private)
ink_against :: proc(preferred: Color, bd: Backdrop_Range, contrast: f32) -> (Color, bool) {
	dark, dark_at, dark_ok := ink_toward(preferred, 0, bd, contrast)
	light, light_at, light_ok := ink_toward(preferred, 1, bd, contrast)
	switch {
	case dark_ok && light_ok: return (dark if dark_at <= light_at else light), true
	case dark_ok:             return dark, true
	case light_ok:            return light, true
	}
	return (dark if ink_worst(dark, bd) >= ink_worst(light, bd) else light), false
}

// ink_toward is `preferred` with its OKLCH lightness moved toward `end` (0
// black, 1 white) as little as it takes to reach `contrast` over the whole
// backdrop, how far that was (0..1 of the way there), and whether it got
// there. Hue and chroma are kept, so a tinted grey stays that grey's hue;
// the gamut takes the chroma down if it has to. The end itself, pure, when
// nothing on the way reads.
@(private)
ink_toward :: proc(preferred: Color, end: f32, bd: Backdrop_Range, contrast: f32) -> (ink: Color, moved: f32, ok: bool) {
	L, C, h := oklch_of(preferred)
	for i in 1 ..= INK_STEPS { // 0 is `preferred`, which the caller has tried
		t := f32(i) / INK_STEPS
		cand := oklch(L + (end - L) * t, C, h, preferred.a)
		if ink_worst(cand, bd) >= contrast do return cand, t, true
	}
	return oklch(end, 0, h, preferred.a), 1, false
}
