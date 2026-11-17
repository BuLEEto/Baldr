package baldr

// Glass that reads on any backdrop. A glass surface shows the
// blurred desktop through its material's tint, so what is behind is part of
// its text's background, and fixed colours can't be trusted. The compositor
// reports how bright that backdrop is (Ev_Backdrop: its darkest part,
// average and brightest part); glass_legible then raises the tint only as
// far as the text needs to reach 4.5:1 against the darkest and the brightest
// part, keeps the theme's secondary text colour when it reads and fades it
// from the text colour only as far as it still does, and on Clear takes the
// text family that reads best: the Light family's dark text over a bright
// backdrop, the Dim family's light text over a dark one, with the glow in
// the opposite tone. A compositor that doesn't report gets the worst case,
// anything from black to white. Popups adapt to their own backdrops.

// Backdrop_Range: how bright what shows through a glass surface is, as
// relative luminance 0..1.
Backdrop_Range :: struct {
	min, avg, max: f32,
}

// BACKDROP_UNKNOWN is what glass assumes when the compositor doesn't say.
BACKDROP_UNKNOWN :: Backdrop_Range{0, 0.2, 1}

// Glass_Role: which material tints a glass surface. An applet has none of
// its own: what shows through it is its bar's glass, which the compositor
// measures with the bar's tint in it.
Glass_Role :: enum u8 { Panel, Window, Popover, Applet }

GLASS_TEXT_CONTRAST :: f32(4.5)  // text, secondary text included, against every part of the backdrop
GLASS_TINT_MAX      :: f32(0.98) // as far as the tint rises
GLASS_IN_APP_FLOOR  :: f32(0.55) // glass over the app's own content, whose brightness nobody reports
GLOW_OVERHANG       :: f32(9)    // how far a glow reaches past its text (1.5 × GLOW_MAX_RADIUS, rounded up)

// Tree_Glass: whether a tree's surface shows the desktop through glass, and
// how bright it is behind (set by the run loop).
@(private)
Tree_Glass :: struct {
	on:       bool,           // blurred desktop shows through the surface's material (an applet: its bar's)
	popups:   bool,           // its popups are glass over the desktop
	role:     Glass_Role,     // .Panel for a layer surface, .Window for a window, .Applet for an applet
	reported: bool,           // the compositor reports backdrops (Cap.Backdrop_Luminance)
	known:    bool,           // …and a report has come
	watch:    bool,           // the surface asked to be measured without glass (Backdrop.Measure): its view reads the numbers
	backdrop: Backdrop_Range,
}

// Glass_Families caches the Light and Dim colours of a seed, which Clear
// glass picks its text from.
@(private)
Glass_Families :: struct {
	seed:     Color,
	contrast: Theme_Contrast,
	made:     bool,
	roles:    [2]Color_Roles, // Light, Dim
}

// glass_legible adapts `th` for text on glass of `role` over `bd`. The tint
// rises in steps of 0.01 until the text colour reads (4.5:1) against the
// darkest and brightest part, or GLASS_TINT_MAX; secondary text keeps its
// colour when that reads, else it is the text colour faded toward the
// backdrop only as far as it still reads. On Clear with `families` (the
// seed's Light and Dim colours), the colours are the family that reads best
// and the glow takes the opposite tone. An applet has no tint: its colours
// become the family that reads best whenever its own text doesn't, on any
// level (the glow only on Clear). Solid glass is left alone. `linear` says
// the toolkit draws this glass over the app's own content rather than the
// compositor laying it over the wallpaper: a different blend, and a
// different answer (glass_over).
glass_legible :: proc(th: ^Theme, role: Glass_Role, bd: Backdrop_Range, families: ^[2]Color_Roles = nil, linear := false) {
	if th.glass == .Solid do return
	ms := &th.material[th.glass]
	m: ^Material
	switch role {
	case .Panel:   m = &ms.panel
	case .Window:  m = &ms.window
	case .Popover: m = &ms.popover
	case .Applet:  // on its bar's glass: no tint of its own to raise
	}
	if m != nil && !has_material(m^) do return
	cands: [2]Color_Roles
	count := 1
	cands[0] = th.color
	// Clear takes the family that reads best; an applet, which has no tint to
	// thicken, does so on any level once its own text doesn't read.
	flip := families != nil && th.glass == .Clear
	if families != nil && role == .Applet && !flip {
		flip = min(glass_worst(th.color.on_surface, {}, 0, bd, linear), glass_worst(th.color.on_bg, {}, 0, bd, linear)) < GLASS_TEXT_CONTRAST
	}
	if flip {
		cands = families^
		count = 2
	}
	tint: [3]f32
	a: f32
	if m != nil {
		tint = {linear_to_srgb(m.tint.r), linear_to_srgb(m.tint.g), linear_to_srgb(m.tint.b)}
		a = m.tint.a
	}
	pick := 0
	for {
		best: f32 = -1
		for i in 0 ..< count {
			w := min(glass_worst(cands[i].on_surface, tint, a, bd, linear), glass_worst(cands[i].on_bg, tint, a, bd, linear))
			if w > best {
				best = w
				pick = i
			}
		}
		if best >= GLASS_TEXT_CONTRAST || m == nil || a >= GLASS_TINT_MAX do break
		a = min(a + 0.01, GLASS_TINT_MAX)
	}
	fam := cands[pick]
	on := fam.on_surface
	muted := fam.on_surface_muted
	if glass_worst(muted, tint, a, bd, linear) < GLASS_TEXT_CONTRAST {
		avg := glass_over(tint, a, bd.avg, linear)
		muted = on
		for f := f32(0.40); f > 0.01; f -= 0.05 {
			faded := mix_srgb(on, avg, f)
			if glass_worst(faded, tint, a, bd, linear) >= GLASS_TEXT_CONTRAST {
				muted = faded
				break
			}
		}
		muted = ensure_contrast(muted, fam.surface_variant, GLASS_TEXT_CONTRAST) // and still on the theme's own wells
	}
	if m != nil do m.tint.a = a
	if flip {
		th.color = fam
		dark_text := luminance(on) < 0.2
		th.dark = !dark_text
		if th.glass == .Clear do ms.glow = {color = {1, 1, 1, 0.75} if dark_text else {0, 0, 0, 0.60}, radius = GLOW_RADIUS}
	}
	th.color.on_surface_muted = muted
	// The washes on this glass, solved last: a flip replaces the whole
	// colour set, so solving them before it would throw the answer away.
	if m != nil do glass_fills_for(th, m^, a, bd)
	// Coloured text (links and ghost buttons, errors, warnings, successes)
	// reads too: its lightness moves toward the text colour's only as far as
	// it needs, keeping its hue; the focus ring gets 3:1.
	c := &th.color
	c.primary = glass_toward(c.primary, on, tint, a, bd, GLASS_TEXT_CONTRAST, linear)
	c.danger  = glass_toward(c.danger, on, tint, a, bd, GLASS_TEXT_CONTRAST, linear)
	c.warning = glass_toward(c.warning, on, tint, a, bd, GLASS_TEXT_CONTRAST, linear)
	c.success = glass_toward(c.success, on, tint, a, bd, GLASS_TEXT_CONTRAST, linear)
	c.focus_ring = glass_toward(c.focus_ring, on, tint, a, bd, 3, linear)
}

// glass_toward moves colour `fg`'s OKLCH lightness toward `on`'s side (the
// text that reads over the glass) just far enough for `min` contrast over
// it, keeping hue and chroma; `fg` itself when it already reads. A vivid
// colour may need to pass the text's own lightness, so the search runs to
// the end of that side. Toward the text is away from what the colour's
// fills carry (on_primary, on_danger), so they read better too.
@(private)
glass_toward :: proc(fg, on: Color, tint: [3]f32, a: f32, bd: Backdrop_Range, min: f32, linear := false) -> Color {
	if glass_worst(fg, tint, a, bd, linear) >= min do return fg
	L, C, h := oklch_of(fg)
	onL, _, _ := oklch_of(on)
	end: f32 = 1 if onL >= L else 0
	best := oklch(end, 0, h, fg.a)
	lo, hi := f32(0), f32(1) // how far toward the end
	for _ in 0 ..< 18 {
		mid := (lo + hi) / 2
		cand := oklch(L + (end - L) * mid, C, h, fg.a)
		if glass_worst(cand, tint, a, bd, linear) >= min {
			best = cand
			hi = mid
		} else {
			lo = mid
		}
	}
	return best
}

// GLASS_DESIGN_STAGE is the backdrop the design's glass tokens were drawn
// over (#909d8a, sRGB), where glass_token_alpha matches Baldr to them.
@(private)
GLASS_DESIGN_STAGE :: [3]f32{0x90 / 255.0, 0x9d / 255.0, 0x8a / 255.0}

// glass_token_alpha converts a design token: `ink` (linear) at sRGB alpha
// `token`, as a browser lays it over glass of tint `glass` (and over
// `under_token` of `under_ink` when given: a tile below a track, the edge
// below a rim). It returns the alpha at which Baldr, laying the ink in
// linear light (over `under` of `under_ink`) on a transparent surface the
// compositor adds over the backdrop, separates it from what is below by as
// much on screen. A dark ink on light glass needs more than its token, a
// light one on dark glass less. Matched over GLASS_DESIGN_STAGE by the
// luminance of the sRGB values.
@(private)
glass_token_alpha :: proc(ink: [3]f32, token: f32, glass: Color, under_ink: [3]f32 = {}, under: f32 = 0, under_token: f32 = 0) -> f32 {
	Px :: struct { rgb: [3]f32, a: f32 } // a surface pixel: premultiplied linear rgb
	enc :: proc "contextless" (v: [3]f32) -> [3]f32 { return {linear_to_srgb(v.r), linear_to_srgb(v.g), linear_to_srgb(v.b)} }
	lum :: proc "contextless" (v: [3]f32) -> f32 { return 0.2126 * v.r + 0.7152 * v.g + 0.0722 * v.b }
	css_over :: proc "contextless" (below, c: [3]f32, a: f32) -> [3]f32 { return c * a + below * (1 - a) }
	over :: proc "contextless" (p: Px, c: [3]f32, a: f32) -> Px { return {c * a + p.rgb * (1 - a), a + p.a * (1 - a)} }
	shown :: proc "contextless" (p: Px) -> [3]f32 {
		if p.a <= 0 do return GLASS_DESIGN_STAGE
		return enc(p.rgb / p.a) * p.a + GLASS_DESIGN_STAGE * (1 - p.a)
	}
	if token <= 0 do return 0
	css_glass := css_over(GLASS_DESIGN_STAGE, enc(glass.rgb), glass.a)
	css_below := css_over(css_glass, enc(under_ink), under_token) if under_token > 0 else css_glass
	css_top := css_over(css_below, enc(ink), token)
	below := Px{glass.rgb * glass.a, glass.a}
	if under > 0 do below = over(below, under_ink, under)
	target := lum(shown(below)) + lum(css_top) - lum(css_below)
	lighter := lum(css_top) > lum(css_below)
	lo, hi: f32 = 0, 0.95
	for _ in 0 ..< 40 {
		mid := (lo + hi) / 2
		if (lum(shown(over(below, ink, mid))) < target) == lighter { lo = mid } else { hi = mid }
	}
	return (lo + hi) / 2
}

// glass_in_app is material `m` for glass over the app's own content, which
// nobody measures: its tint at least GLASS_IN_APP_FLOOR.
glass_in_app :: proc "contextless" (m: Material) -> Material {
	out := m
	out.tint.a = max(out.tint.a, GLASS_IN_APP_FLOOR)
	return out
}

// glass_over is the colour a tint (sRGB, alpha `a`) makes over a grey
// backdrop of luminance `lum`.
//
// Two glasses, two blends. A glass surface is composited by the compositor,
// which lays premultiplied sRGB over the wallpaper and so mixes the encoded
// values: the default here. Glass the toolkit draws over the app's own
// content is mixed by `ui.frag` in linear light (`linear = true`). Over a
// bright backdrop a dark tint mixed in linear light lands much lighter than
// in sRGB, so solving with the wrong blend promises a contrast the renderer
// does not deliver.
@(private)
glass_over :: proc "contextless" (tint: [3]f32, a, lum: f32, linear := false) -> Color {
	b := clamp(lum, 0, 1)
	if linear {
		out := Color{0, 0, 0, 1}
		for i in 0 ..< 3 do out[i] = srgb_to_linear(tint[i]) * a + b * (1 - a)
		return out
	}
	g := linear_to_srgb(b)
	return {srgb_to_linear(tint.r * a + g * (1 - a)), srgb_to_linear(tint.g * a + g * (1 - a)), srgb_to_linear(tint.b * a + g * (1 - a)), 1}
}

// glass_worst is the lowest contrast of `fg` over the tinted backdrop: at
// its darkest or its brightest part (a colour between the two can't pass
// against both, so those two decide). `linear` picks the blend: see
// glass_over.
@(private)
glass_worst :: proc "contextless" (fg: Color, tint: [3]f32, a: f32, bd: Backdrop_Range, linear := false) -> f32 {
	return min(contrast_ratio(fg, glass_over(tint, a, bd.min, linear)), contrast_ratio(fg, glass_over(tint, a, bd.max, linear)))
}

// mix_srgb blends two linear colours by t in sRGB, as the eye sees a fade.
@(private)
mix_srgb :: proc "contextless" (a, b: Color, t: f32) -> Color {
	out: Color
	for i in 0 ..< 3 {
		x, y := linear_to_srgb(a[i]), linear_to_srgb(b[i])
		out[i] = srgb_to_linear(x + (y - x) * t)
	}
	out.a = a.a
	return out
}

// glass_adapt adapts `th` for glass of `role` over what the compositor
// reported, the worst case when it doesn't report, or not yet while a
// report is on its way.
@(private)
glass_adapt :: proc(t: ^Tree, th: ^Theme, role: Glass_Role, known: bool, bd: Backdrop_Range, waited := false, linear := false) {
	// Waiting for a report is right while one is coming: a worst-case tint
	// corrected a frame later reads as glass arriving after the popover. But
	// a report that never comes must not leave the theme unadapted (dark text
	// on a dark card). `waited` says the wait is over: take the worst case.
	if !known && !waited && (t.glass.reported || role == .Applet) do return // an applet has no tint to thicken against the worst case
	glass_legible(th, role, bd if known else BACKDROP_UNKNOWN, glass_families(t, th, role), linear)
}

// glass_fills_for re-solves the washes — `fill`, `fill_strong`, and the
// hover and press layers — for a surface the compositor will composite,
// rather than one that ends up opaque.
//
// A wash on an opaque window lands as the theme intends; on glass in a light
// theme it nearly vanishes. Baldr blends in linear light into a premultiplied
// scene and present.frag writes `encode(colour) × alpha`, since a compositor
// composites premultiplied sRGB. A dark veil over light glass lowers the
// colour and raises the alpha about equally, and once encoded the two nearly
// cancel, leaving a fraction of the wash; a light veil over dark glass is
// amplified instead.
//
// So the alpha is solved for that path: the step the wash makes on the
// theme's opaque surface is the target, found over this backdrop by
// bisection. Only ever stronger: a backdrop that flatters a wash keeps what
// the design asked for.
@(private)
glass_fills_for :: proc(th: ^Theme, m: Material, tint_a: f32, bd: Backdrop_Range) {
	if !has_material(m) || tint_a <= 0 do return
	c := &th.color
	tint := Color{m.tint.r, m.tint.g, m.tint.b, 1}
	ink := c.on_surface
	// what the same wash is worth where it lands as drawn: an opaque surface
	want_faint := glass_step_opaque(c.surface, ink, c.fill.a)
	want_strong := glass_step_opaque(glass_veil(c.surface, ink, c.fill.a), ink, c.fill_strong.a)
	faint := glass_fill_alpha(tint, tint_a, ink, bd.avg, 0, want_faint)
	strong := glass_fill_alpha(tint, tint_a, ink, bd.avg, faint, want_strong)
	c.fill = with_alpha(ink, max(faint, c.fill.a))
	c.fill_strong = with_alpha(ink, max(strong, c.fill_strong.a))
	// The state layers are the same wash by another name (`on_surface` at
	// `state.hover`), so they take the same path and need the same solve, or
	// ghost buttons on light glass show no hover.
	want_hover := glass_step_opaque(c.surface, ink, th.state.hover)
	want_press := glass_step_opaque(c.surface, ink, th.state.press)
	th.state.hover = max(glass_fill_alpha(tint, tint_a, ink, bd.avg, 0, want_hover), th.state.hover)
	th.state.press = max(glass_fill_alpha(tint, tint_a, ink, bd.avg, 0, want_press), th.state.press)
}

// GLASS_FILL_MAX is as far as a wash's alpha is taken: past this it stops
// being a wash and becomes a plate, which is a different design.
@(private)
GLASS_FILL_MAX :: f32(0.55)

// glass_veil is `ink` at `a` laid over `base`, in linear light.
@(private)
glass_veil :: proc(base, ink: Color, a: f32) -> Color {
	return {ink.r * a + base.r * (1 - a), ink.g * a + base.g * (1 - a), ink.b * a + base.b * (1 - a), 1}
}

// glass_step_opaque is how far a wash moves an opaque surface, in OKLab
// lightness — the yardstick that leans neither light nor dark.
@(private)
glass_step_opaque :: proc(base, ink: Color, a: f32) -> f32 {
	l0, _, _ := oklch_of(base)
	l1, _, _ := oklch_of(glass_veil(base, ink, a))
	return abs(l0 - l1)
}

// glass_fill_alpha bisects for the alpha whose wash moves the screen by
// `want` (OKLab lightness), laid over `under` of the same ink.
@(private)
glass_fill_alpha :: proc(tint: Color, tint_a: f32, ink: Color, backdrop: f32, under, want: f32) -> f32 {
	if want <= 0 do return 0
	l_base, _, _ := oklch_of(glass_screen(tint, tint_a, ink, under, backdrop))
	lo, hi := under, GLASS_FILL_MAX
	for _ in 0 ..< 20 {
		mid := (lo + hi) * 0.5
		l, _, _ := oklch_of(glass_screen(tint, tint_a, ink, mid, backdrop))
		if abs(l - l_base) < want { lo = mid } else { hi = mid }
	}
	return (lo + hi) * 0.5
}

// glass_screen is what one pixel of `tint` glass with `veil_a` of `ink` on
// it looks like on screen: blended in linear light into a premultiplied
// scene, written as premultiplied sRGB (present.frag), composited by the
// compositor in that space over a backdrop of relative luminance
// `backdrop`.
@(private)
glass_screen :: proc(tint: Color, tint_a: f32, ink: Color, veil_a: f32, backdrop: f32) -> Color {
	p := [3]f32{tint.r * tint_a, tint.g * tint_a, tint.b * tint_a}
	pa := tint_a
	if veil_a > 0 {
		p = {ink.r * veil_a + p.r * (1 - veil_a), ink.g * veil_a + p.g * (1 - veil_a), ink.b * veil_a + p.b * (1 - veil_a)}
		pa = veil_a + pa * (1 - veil_a)
	}
	inv := 1 / max(pa, 0.0001)
	back := linear_to_srgb(clamp(backdrop, 0, 1))
	out: Color
	for i in 0 ..< 3 {
		colour := clamp(p[i] * inv, 0, 1)
		out[i] = srgb_to_linear(clamp(linear_to_srgb(colour) * pa + back * (1 - pa), 0, 1))
	}
	out.a = 1
	return out
}

// glass_families is the Light and Dim colours of th's seed, made once per
// seed; nil when th has no seed, or isn't Clear glass or an applet.
@(private)
glass_families :: proc(t: ^Tree, th: ^Theme, role: Glass_Role) -> ^[2]Color_Roles {
	if (th.glass != .Clear && role != .Applet) || th.seed == {} do return nil
	f := &t.glass_families
	if !f.made || f.seed != th.seed || f.contrast != th.contrast {
		f^ = {seed = th.seed, contrast = th.contrast, made = true}
		f.roles[0] = theme_from_seed(th.seed, .Light, th.contrast).color
		f.roles[1] = theme_from_seed(th.seed, .Dim, th.contrast).color
	}
	return &f.roles
}

// tree_glass tells a tree whether its surface is glass, whether its popups
// are, which material tints it, whether the compositor reports backdrops
// and whether the surface watches its own without being glass; the theme is
// adapted again when that changed. Returns whether it did.
@(private)
tree_glass :: proc(t: ^Tree, on, popups: bool, role: Glass_Role, reported: bool, watch := false) -> bool {
	g := t.glass
	g.on, g.popups, g.role, g.reported, g.watch = on, popups, role, reported, watch
	if !on && !watch do g.known = false // blurred or watched again later, it is measured again
	if g == t.glass do return false
	t.glass = g
	tree_theme(t, t.theme_asked)
	return true
}

// tree_backdrop takes the compositor's report for a tree's own surface.
// Returns whether the view is built again: the theme changed (glass), or
// the surface watches its backdrop so that its view can read it
// (backdrop_range: text straight on the desktop). A surface that is neither
// says no: an applet keeps its backdrop object while its bar is Solid, and
// its view need not rebuild for numbers nothing reads.
@(private)
tree_backdrop :: proc(t: ^Tree, bd: Backdrop_Range) -> bool {
	if t.glass.known && t.glass.backdrop == bd do return false
	t.glass.known = true
	t.glass.backdrop = bd
	if !t.glass.on do return t.glass.watch
	tree_theme(t, t.theme_asked)
	return true
}

// popup_theme is the theme a glass popup on a surface of its own draws
// with: the tree's, before its surface's backdrop, adapted to the popup's.
@(private)
popup_theme :: proc(t: ^Tree, n: Node) -> (th: Theme, ok: bool) {
	if !t.glass.popups || !t.popups_on do return
	place, open := t.popups[n]
	if !open || !place.glass do return
	if cached, hit := t.popup_themes[n]; hit do return cached, true
	th = t.theme_base
	// A popup whose own report has not come reads over what it opened from
	// until it does; if it never does, the wait ends and the worst case is
	// better than a theme made for somewhere else.
	waited := !place.measured && t.now_ms >= place.wait_until
	glass_adapt(t, &th, .Popover, place.known, place.backdrop, waited)
	if place.known || waited do t.popup_themes[n] = th // provisional while it is still waiting: not cached
	return th, true
}

// popup_backdrop takes the compositor's report for popup `n`'s surface.
// Returns whether the view builds again: its theme changed, or it was
// waiting for this report to show (popup_waiting).
@(private)
popup_backdrop :: proc(t: ^Tree, n: Node, bd: Backdrop_Range) -> bool {
	place, open := &t.popups[n]
	if !open do return false
	first := !place.measured
	place.measured = true
	if place.known && place.backdrop == bd do return first && place.glass && t.glass.popups // as it started from: nothing to adapt, but it shows now
	place.known = true
	place.backdrop = bd
	delete_key(&t.popup_themes, n)
	mark_paint_dirty(t, n)
	return place.glass && t.glass.popups
}

// glass_under says whether layer root `n` sits on glass: the nearest
// material or opaque fill above it decides, else the surface does.
@(private)
glass_under :: proc(t: ^Tree, n: Node) -> bool {
	d := node_get(t, n)
	p := d.parent if d != nil else NODE_NONE
	for p != NODE_NONE {
		pd := node_get(t, p)
		if pd == nil do break
		if on, decided := glass_decides(t, pd); decided do return on
		p = pd.parent
	}
	return t.glass.on
}

// glass_decides: a node with live glass puts what it holds on glass, one
// with an opaque fill takes it off; any other node leaves it as it was.
@(private)
glass_decides :: proc "contextless" (t: ^Tree, d: ^Node_Data) -> (on, decided: bool) {
	if has_material(d.style.material) && t.theme.glass != .Solid do return true, true
	if d.style.bg.a >= 0.5 || d.style.bg2.a >= 0.5 do return false, true
	return false, false
}
