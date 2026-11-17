package baldr

@(require) import "core:testing"
@(require) import "baldr:platform"
@(require) import "baldr:gpu"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: about 9 GB without this `when`, 1 GB with it.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Glass levels, and text that reads on any backdrop.


@(private = "file")
GMsg :: enum { None, Close }

@(private = "file")
material_of :: proc(th: ^Theme, role: Glass_Role) -> Material {
	ms := th.material[th.glass]
	switch role {
	case .Panel:   return ms.panel
	case .Window:  return ms.window
	case .Popover: return ms.popover
	case .Applet:  // no tint of its own
	}
	return {}
}

// contrast_over is the lowest contrast `fg` has on th's glass of `role` over
// `bd`, at tint alpha `a` (the material's own when a < 0).
@(private = "file")
contrast_over :: proc(th: ^Theme, role: Glass_Role, bd: Backdrop_Range, fg: Color, a: f32 = -1) -> f32 {
	m := material_of(th, role)
	tint := [3]f32{linear_to_srgb(m.tint.r), linear_to_srgb(m.tint.g), linear_to_srgb(m.tint.b)}
	return glass_worst(fg, tint, m.tint.a if a < 0 else a, bd)
}

// text_reads: how well the worst of th's text reads, secondary text and
// coloured text (links, ghost buttons, errors, warnings, successes) included.
@(private = "file")
text_reads :: proc(th: ^Theme, role: Glass_Role, bd: Backdrop_Range) -> f32 {
	c := th.color
	worst := f32(21)
	for fg in ([]Color{c.on_surface, c.on_bg, c.on_surface_muted, c.primary, c.danger, c.warning, c.success}) {
		worst = min(worst, contrast_over(th, role, bd, fg))
	}
	return worst
}

// glow_at is the glow behind the text `str` as render would draw it
// (radius -1: no such text).
@(private = "file")
glow_at :: proc(cmds: []Draw_Cmd, str: string) -> Glow {
	stack := make([dynamic]Glow, context.temp_allocator)
	g: Glow
	for c in cmds {
		#partial switch v in c {
		case Draw_Glow_Push:
			append(&stack, g)
			g = v.glow
		case Draw_Glow_Pop:
			if len(stack) > 0 do g = pop(&stack)
		case Draw_Text:
			if v.str == str do return g
		}
	}
	return {radius = -1}
}

@(private = "file")
Recipe_Row :: struct {
	mode:     Theme_Mode,
	level:    Glass_Level,
	panel:    [3]f32, // tint alpha, blur px, saturation
	popover:  [3]f32,
	window_a: f32,
}

// The glass recipes, per level and mode, as the design's table gives them.
@(test)
glass_levels_are_tuned_per_mode_from_the_agreed_table :: proc(t: ^testing.T) {
	rows := [?]Recipe_Row{
		{.Light, .Clear,   {0.14, 22, 2.1}, {0.36, 26, 2.0}, 0.48},
		{.Dim,   .Clear,   {0.22, 22, 1.6}, {0.50, 26, 1.5}, 0.72},
		{.Dark,  .Clear,   {0.24, 22, 1.6}, {0.52, 26, 1.5}, 0.72},
		{.Light, .Frosted, {0.42, 36, 1.95}, {0.50, 28, 1.85}, 0.55},
		{.Dim,   .Frosted, {0.62, 36, 1.4}, {0.70, 28, 1.3}, 0.82},
		{.Dark,  .Frosted, {0.62, 36, 1.4}, {0.72, 28, 1.3}, 0.82},
		{.Light, .Solid,   {0.97, 0, 1},    {0.98, 0, 1},    0.99},
		{.Dim,   .Solid,   {0.97, 0, 1},    {0.98, 0, 1},    0.99},
		{.Dark,  .Solid,   {0.97, 0, 1},    {0.98, 0, 1},    0.99},
	}
	for r in rows {
		th := theme_from_seed(BALDR_BLUE, r.mode)
		testing.expect_value(t, th.glass, Glass_Level.Frosted) // the default
		ms := th.material[r.level]
		panel := [3]f32{ms.panel.tint.a, ms.panel.blur, ms.panel.saturation}
		popover := [3]f32{ms.popover.tint.a, ms.popover.blur, ms.popover.saturation}
		testing.expectf(t, panel == r.panel && popover == r.popover && ms.window.tint.a == r.window_a, "%v %v: panel %v, popover %v, window %v", r.mode, r.level, panel, popover, ms.window.tint.a)
		testing.expect(t, ms.panel.tint.rgb == th.color.bg.rgb && ms.popover.tint.rgb == th.color.surface_high.rgb, "tinted with the theme's own surfaces")
		glass := r.level != .Solid
		testing.expectf(t, has_material(ms.panel) == glass, "%v %v: Solid has no blur", r.mode, r.level)
		testing.expectf(t, (ms.panel.highlight.a > 0) == glass && (ms.popover.highlight.a > 0) == glass, "%v %v: a bright top edge on glass only", r.mode, r.level)
		if r.level != .Solid { // Light reads as glass only with materially less tint than Dim: a near-white tint hides what shows through
			dim := theme_from_seed(BALDR_BLUE, .Dim).material[r.level]
			if r.mode == .Light {
				testing.expectf(t, ms.window.tint.a <= dim.window.tint.a - 0.15 && ms.sidebar.tint.a <= dim.sidebar.tint.a - 0.15,
					"%v %v: window %v and sidebar %v against Dim's %v and %v", r.mode, r.level, ms.window.tint.a, ms.sidebar.tint.a, dim.window.tint.a, dim.sidebar.tint.a)
			}
		}
		if r.level == .Clear {
			testing.expectf(t, ms.glow.radius > 0 && (ms.glow.color.r > 0.5) == (r.mode == .Light), "%v: Clear's glow is in the opposite tone to the text", r.mode)
		} else {
			testing.expect_value(t, ms.glow, Glow{})
		}
	}
}

@(test)
reduce_transparency_and_high_contrast_make_glass_solid_and_opaque :: proc(t: ^testing.T) {
	tr: Tree
	tree_init(&tr)
	defer tree_destroy(&tr)
	th := theme_dark()
	th.glass = .Clear
	tr.a11y_prefs = {reduce_transparency = true}
	tree_theme(&tr, th)
	testing.expect_value(t, tr.theme.glass, Glass_Level.Solid)
	ms := tr.theme.material[.Solid]
	testing.expect(t, ms.panel.tint.a == 1 && ms.popover.tint.a == 1 && ms.window.tint.a == 1 && ms.glow == {}, "nothing shows through")
	hc := theme_high_contrast(.Light)
	testing.expect(t, hc.glass == .Solid && hc.material[.Solid].panel.tint.a == 1, "high contrast too")
}

// Frosted keeps the theme's text and raises the tint only as far as that
// text, secondary text included, needs over what is behind.
@(test)
frosted_tint_rises_only_as_far_as_its_text_needs :: proc(t: ^testing.T) {
	base := theme_dim()
	recipe := base.material[.Frosted].panel.tint.a
	bright := Backdrop_Range{0.55, 0.7, 0.85}
	th := base
	glass_legible(&th, .Panel, bright)
	a := th.material[.Frosted].panel.tint.a
	testing.expectf(t, a > recipe, "a bright wallpaper lifts the tint: %v", a)
	testing.expectf(t, text_reads(&th, .Panel, bright) >= GLASS_TEXT_CONTRAST, "text and secondary text read: %v", text_reads(&th, .Panel, bright))
	below := min(contrast_over(&th, .Panel, bright, th.color.on_surface, a - 0.01), contrast_over(&th, .Panel, bright, th.color.on_bg, a - 0.01))
	testing.expectf(t, below < GLASS_TEXT_CONTRAST, "and no further than that: %v at %v", below, a - 0.01)
	testing.expect_value(t, th.color.on_surface, base.color.on_surface) // Frosted keeps the theme's text

	dark := Backdrop_Range{0.004, 0.01, 0.02}
	th = base
	glass_legible(&th, .Panel, dark)
	testing.expect_value(t, th.material[.Frosted].panel.tint.a, recipe) // light text reads over it as it is
	testing.expect_value(t, th.color.on_surface_muted, base.color.on_surface_muted) // and so does the secondary colour
	testing.expect(t, text_reads(&th, .Panel, dark) >= GLASS_TEXT_CONTRAST)

	solid := base
	solid.glass = .Solid
	glass_legible(&solid, .Panel, bright)
	testing.expect_value(t, solid.material, base.material) // Solid is left alone
}

// On Clear the text family follows the backdrop: the Light family's dark
// text and accent over a bright one, the Dim family's over a dark one, with
// the glow in the opposite tone. The tint keeps the theme's colour.
@(test)
clear_takes_the_text_family_its_backdrop_needs :: proc(t: ^testing.T) {
	base := theme_dark()
	base.glass = .Clear
	fam := [2]Color_Roles{theme_from_seed(base.seed, .Light).color, theme_from_seed(base.seed, .Dim).color}
	bright := Backdrop_Range{0.7, 0.8, 0.9}
	th := base
	glass_legible(&th, .Panel, bright, &fam)
	testing.expect_value(t, th.color.on_surface, fam[0].on_surface)
	_, _, hue := oklch_of(th.color.primary)
	_, _, fam_hue := oklch_of(fam[0].primary)
	testing.expectf(t, abs(hue - fam_hue) < 1, "the Light family's accent, as dark as it needs to read (hue %v, %v)", hue, fam_hue)
	testing.expect(t, !th.dark && th.material[.Clear].glow.color.r == 1, "dark text with a light glow")
	testing.expect_value(t, th.material[.Clear].panel.tint, base.material[.Clear].panel.tint) // dark text reads through Clear as it is
	testing.expect(t, text_reads(&th, .Panel, bright) >= GLASS_TEXT_CONTRAST)

	dark := Backdrop_Range{0.002, 0.01, 0.03}
	th = base
	glass_legible(&th, .Panel, dark, &fam)
	testing.expect_value(t, th.color.on_surface, fam[1].on_surface)
	testing.expect_value(t, th.color.primary, fam[1].primary) // the Dim accent reads over a dark backdrop as it is
	testing.expect(t, th.dark && th.material[.Clear].glow.color.r == 0, "light text with a dark glow")
	testing.expect(t, text_reads(&th, .Panel, dark) >= GLASS_TEXT_CONTRAST)

	// Over mid-grey, dark text can't reach 4.5:1 through the Dark theme's
	// dark popover tint (more tint only darkens it): the tint rises until
	// light text does, and light text it is.
	grey := Backdrop_Range{0.7, 0.8, 0.9}
	th = base
	glass_legible(&th, .Popover, grey, &fam)
	testing.expect_value(t, th.color.on_surface, fam[1].on_surface)
	testing.expect(t, th.material[.Clear].popover.tint.a > base.material[.Clear].popover.tint.a && text_reads(&th, .Popover, grey) >= GLASS_TEXT_CONTRAST, "a thicker tint and light text")
}

// A long bar over bright and dark parts of the wallpaper reads against both.
@(test)
a_bar_across_bright_and_dark_takes_its_worst_case :: proc(t: ^testing.T) {
	across := Backdrop_Range{0.005, 0.3, 0.95}
	for mode in Theme_Mode {
		for level in ([]Glass_Level{.Clear, .Frosted}) {
			base := theme_from_seed(BALDR_BLUE, mode)
			base.glass = level
			fam := [2]Color_Roles{theme_from_seed(base.seed, .Light).color, theme_from_seed(base.seed, .Dim).color}
			th := base
			glass_legible(&th, .Panel, across, &fam)
			a := th.material[level].panel.tint.a
			testing.expectf(t, a > base.material[level].panel.tint.a, "%v %v: lifted to %v", mode, level, a)
			testing.expectf(t, text_reads(&th, .Panel, across) >= GLASS_TEXT_CONTRAST, "%v %v: reads against both ends (%v at %v)", mode, level, text_reads(&th, .Panel, across), a)
		}
	}
}

// Without reports glass takes the worst case; with them, the recipe until
// the first comes, then what it says. The clear colour follows.
@(test)
glass_waits_for_the_compositor_or_takes_the_worst_case :: proc(t: ^testing.T) {
	tr: Tree
	tree_init(&tr)
	defer tree_destroy(&tr)
	tree_theme(&tr, theme_dim())
	recipe := tr.theme.material[.Frosted].panel.tint.a
	testing.expect(t, tree_glass(&tr, true, true, .Panel, false)) // a compositor that doesn't say what is behind
	floor := tr.theme.material[.Frosted].panel.tint.a
	testing.expectf(t, floor > recipe && text_reads(&tr.theme, .Panel, BACKDROP_UNKNOWN) >= GLASS_TEXT_CONTRAST, "reads over anything from black to white: %v", floor)
	testing.expect(t, tree_glass(&tr, true, true, .Panel, true)) // one that does: the recipe until its report
	testing.expect_value(t, tr.theme.material[.Frosted].panel.tint.a, recipe)
	bright := Backdrop_Range{0.6, 0.75, 0.9}
	testing.expect(t, tree_backdrop(&tr, bright))
	lifted := tr.theme.material[.Frosted].panel.tint.a
	testing.expect(t, lifted > recipe && text_reads(&tr.theme, .Panel, bright) >= GLASS_TEXT_CONTRAST)
	desc := Surface_Desc(Sf_Msg){kind = .Layer, transparent = true, backdrop = .Blur, layer = {anchor = {.Bottom, .Left, .Right}}}
	testing.expect_value(t, surface_clear(&tr.theme, desc, true).a, lifted) // the clear colour follows
	testing.expect(t, !tree_backdrop(&tr, bright), "the same report changes nothing")
	testing.expect(t, tree_glass(&tr, false, false, .Panel, true)) // not glass any more (Solid, or no blur)
	testing.expect_value(t, tr.theme.material[.Frosted].panel.tint.a, recipe)
	testing.expect(t, !tr.glass.known, "measured again when blurred again")
}

// A glass popup on a surface of its own builds and paints with the theme of
// its own backdrop; the bar keeps its own.
@(test)
glass_popups_build_and_paint_over_their_own_backdrop :: proc(t: ^testing.T) {
	ui: Ui(GMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	th := theme_dark()
	th.glass = .Clear
	th.motion.reduce = true
	set_theme(&ui.tree, th)
	ui.tree.popups_on = true
	tree_glass(&ui.tree, true, true, .Panel, true)
	tree_backdrop(&ui.tree, {0.002, 0.01, 0.03}) // dark behind the bar
	build :: proc(ui: ^Ui(GMsg)) -> (bar, inside: Node) {
		begin_view(ui)
		row(ui, flex = 1, align = .Center)
		apps := button(ui, "Apps", GMsg.None)
		bar = text(ui, "Bar")
		end(ui)
		if popover(ui, apps, true, GMsg.Close) {
			inside = text(ui, "Inside")
			end(ui)
		}
		end_view(ui)
		return
	}
	build(&ui)
	frame(&ui.tree, {800, 36})
	pop := node_first(&ui.tree, ui.tree.overlay)
	ui.tree.popups[pop] = {origin = {10, 42}, placed = true, glass = true} // its surface is open
	bright := Backdrop_Range{0.85, 0.9, 0.95}
	testing.expect(t, popup_backdrop(&ui.tree, pop, bright), "a bright window behind the popover")
	bar, inside := build(&ui)
	frame(&ui.tree, {800, 36})

	light := theme_from_seed(th.seed, .Light)
	dim := theme_from_seed(th.seed, .Dim)
	testing.expect_value(t, node_get(&ui.tree, bar).style.fg, dim.color.on_surface)       // light text over the bar's dark backdrop
	testing.expect_value(t, node_get(&ui.tree, inside).style.fg, light.color.on_surface)  // dark text over the popover's bright one
	testing.expect_value(t, ui.tree.theme.color.on_surface, dim.color.on_surface)         // the tree's theme is back after the popover's scope
	pth, ok := popup_theme(&ui.tree, pop)
	testing.expect(t, ok && text_reads(&pth, .Popover, bright) >= GLASS_TEXT_CONTRAST, "the popover's text reads over its backdrop")
	testing.expect_value(t, node_get(&ui.tree, pop).style.material, pth.material[.Clear].popover) // with the tint that took

	bar_glow := glow_at(draw_list(&ui.tree), "Bar")
	pop_glow := glow_at(popup_draw_list(&ui.tree, pop), "Inside")
	testing.expect(t, bar_glow.radius > 0 && bar_glow.color.r == 0, "a dark glow behind the bar's light text")
	testing.expect(t, pop_glow.radius > 0 && pop_glow.color.r == 1, "a light glow behind the popover's dark text")
}

@(test)
glow_goes_behind_text_on_clear_glass_and_not_on_fills :: proc(t: ^testing.T) {
	ui: Ui(GMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	th := theme_dark()
	th.glass = .Clear
	set_theme(&ui.tree, th)
	tree_glass(&ui.tree, true, true, .Panel, true)
	tree_backdrop(&ui.tree, {0.002, 0.01, 0.03})
	build :: proc(ui: ^Ui(GMsg)) -> (glassy, filled: Node) {
		begin_view(ui)
		row(ui, flex = 1, gap = .md)
		glassy = text(ui, "On glass")
		column(ui, padding = .sm, bg = ui.tree.theme.color.primary_container)
		filled = text(ui, "On a fill")
		end(ui)
		end(ui)
		end_view(ui)
		return
	}
	glassy, filled := build(&ui)
	frame(&ui.tree, {400, 36})
	cmds := draw_list(&ui.tree)
	testing.expect(t, glow_at(cmds, "On glass").radius > 0, "text on the glass glows")
	testing.expect_value(t, glow_at(cmds, "On a fill").radius, f32(0)) // text on an opaque fill doesn't
	gd := node_get(&ui.tree, glassy)
	testing.expect(t, .Glows in gd.flags && paint_bounds(gd).x <= gd.abs.x - GLOW_OVERHANG, "it repaints as far as its glow reaches")
	testing.expect(t, .Glows not_in node_get(&ui.tree, filled).flags)

	frosted := th
	frosted.glass = .Frosted
	set_theme(&ui.tree, frosted)
	build(&ui)
	frame(&ui.tree, {400, 36})
	pushes := 0
	for c in draw_list(&ui.tree) do if _, pushed := c.(Draw_Glow_Push); pushed do pushes += 1
	testing.expect_value(t, pushes, 0) // Frosted: no glow anywhere
	testing.expect(t, .Glows not_in node_get(&ui.tree, glassy).flags)
}

@(test)
glows_draw_before_their_glyphs_and_glass_draws_its_rim :: proc(t: ^testing.T) {
	out := make([dynamic]gpu.Cmd, context.temp_allocator)
	append(&out, gpu.Quad{}) // something drawn before the text
	start := len(out)
	for i in 0 ..< 3 do append(&out, gpu.Glyph{rect = {f32(i) * 8, 0, 7, 12}, uv = {0, 0, 0.1, 0.1}, page = 2, color = {1, 1, 1, 0.5}})
	glow_under(&out, start, Glow{color = {0, 0, 0, 0.6}, radius = 5}, 2)
	testing.expect_value(t, len(out), 7)
	for i in 0 ..< 3 {
		g, is_glow := out[start + i].(gpu.Glow)
		testing.expectf(t, is_glow && g.rect == out[start + 3 + i].(gpu.Glyph).rect, "glow %d comes first, under its glyph", i)
		testing.expect(t, g.radius == 10 && abs(g.color.a - 0.3) < 1e-6, "in device px, fading with its glyph")
	}

	tr: Tree
	tree_init(&tr)
	defer tree_destroy(&tr)
	node_get(&tr, tr.root).layout = {axis = .Column}
	n := node_new(&tr, Box_Kind{})
	node_get(&tr, n).layout = {width = 100, height = 50}
	node_get(&tr, n).style.radius = 12
	node_get(&tr, n).style.material = tr.theme.material[.Frosted].popover
	node_append(&tr, tr.root, n)
	frame(&tr, {200, 200})
	cmds := make([dynamic]gpu.Cmd, context.temp_allocator)
	render_prepare(&tr, 2, nil, &cmds)
	testing.expect_value(t, len(cmds), 3)
	if len(cmds) == 3 {
		m := tr.theme.material[.Frosted].popover
		_, is_backdrop := cmds[0].(gpu.Backdrop)
		e, is_edge := cmds[1].(gpu.Quad)
		h, is_rim := cmds[2].(gpu.Highlight)
		testing.expect(t, is_backdrop && is_edge && e.border_w == 2 && e.radius == 24 && e.border == m.edge && e.color.a == 0, "its 1 px edge over the glass, at device scale")
		testing.expect(t, is_rim && h.width == 2 && h.radius == 24 && h.color == m.highlight, "then the rim over the edge")
	}
}

// A glass surface's clear reaches the renderer premultiplied in linear
// light, as the renderer blends: in every mode and glass level no colour
// channel exceeds its alpha, so the present pass has a valid pixel to turn
// into what the compositor reads.
@(test)
glass_clears_are_premultiplied :: proc(t: ^testing.T) {
	for mode in Theme_Mode {
		for level in Glass_Level {
			th := theme_from_seed(BALDR_BLUE, mode)
			th.glass = level
			for kind in ([]Surface_Kind{.Layer, .Window}) {
				desc := Surface_Desc(GMsg){kind = kind, transparent = true, backdrop = .Blur}
				c := frame_clear(surface_clear(&th, desc, true))
				testing.expectf(t, c.r <= c.a + 1e-6 && c.g <= c.a + 1e-6 && c.b <= c.a + 1e-6, "%v %v %v: premultiplied: %v", mode, level, kind, c)
			}
		}
	}
	light := theme_from_seed(BALDR_BLUE, .Light)
	tint := surface_clear(&light, Surface_Desc(GMsg){kind = .Layer, transparent = true, backdrop = .Blur}, true)
	if tint.a < 1 {
		testing.expectf(t, tint.r > tint.a, "fixture: a light tint given straight has colour above alpha: %v", tint)
	}
}

// An overlay opens over controls, so its glass is whole from its first
// frame to its last and only what is on it fades: part-way in or out, the
// controls beneath are never readable through it. Its glass is real glass
// even so, never an opaque stand-in of its tint. Under Solid glass it is an
// opaque card, whole alike.
@(test)
an_overlay_is_whole_while_what_is_on_it_fades :: proc(t: ^testing.T) {
	ui: Ui(GMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.motion.reduce = false
	build :: proc(ui: ^Ui(GMsg), open: bool) -> (card: Node) {
		begin_view(ui)
		column(ui, padding = .lg)
		anchor := button(ui, "Control", GMsg.None)
		end(ui)
		if popover(ui, anchor, open, GMsg.Close) {
			card = ui.scopes[len(ui.scopes) - 1].node
			text(ui, "Control Centre")
			end(ui)
		}
		end_view(ui)
		frame(&ui.tree, {600, 400})
		return
	}
	card := build(&ui, true)
	cd := node_get(&ui.tree, card)
	tint := cd.style.material.tint
	testing.expect(t, has_material(cd.style.material), "fixture: a glass popover")
	testing.expect(t, cd.style.enter.whole && cd.style.exit.whole, "an overlay's transitions keep it whole")
	// The card's rect, give or take its transition: a Fade_Scale grows it
	// from 96%, so this allows a slightly smaller rect about the same middle.
	at :: proc(a, r: Rect) -> bool {
		return abs((a.x + a.w / 2) - (r.x + r.w / 2)) < 8 && abs((a.y + a.h / 2) - (r.y + r.h / 2)) < 8 &&
			a.w > r.w * 0.9 && a.w <= r.w + 0.5 && a.h > r.h * 0.9 && a.h <= r.h + 0.5
	}
	find :: proc(tr: ^Tree, r: Rect, tint: Color) -> (backdrop: Maybe(Draw_Backdrop), stand_in: bool, label_a: f32) {
		label_a = -1
		for c in draw_list(tr) {
			#partial switch v in c {
			case Draw_Backdrop: if at(v.rect, r) do backdrop = v
			case Draw_Rect:     if at(v.rect, r) && v.color.rgb == tint.rgb && v.color.a > 0 do stand_in = true
			case Draw_Text:     if v.str == "Control Centre" do label_a = v.color.a
			}
		}
		return
	}
	whole_and_fading :: proc(t: ^testing.T, ui: ^Ui(GMsg), card: Node, tint: Color, when_: string) {
		cd := node_get(&ui.tree, card)
		if !testing.expectf(t, cd != nil, "%s: the card is still there to look at", when_) do return
		bd, stand_in, label_a := find(&ui.tree, cd.abs, tint)
		b, drawn := bd.?
		testing.expectf(t, drawn && b.fade == 0, "%s: its glass whole (%v)", when_, bd)
		testing.expectf(t, !stand_in, "%s: real glass, no opaque stand-in of its tint", when_)
		testing.expectf(t, label_a > 0.01 && label_a < 0.99, "%s: what is on it fading (%v)", when_, label_a)
		if drawn {
			cmds := make([dynamic]gpu.Cmd, context.temp_allocator)
			render_draw(&ui.tree, {Draw_Cmd(b)}, {}, 1, nil, &cmds)
			for c in cmds do if v, ok := c.(gpu.Highlight); ok {
				testing.expectf(t, abs(v.color.a - b.material.highlight.a) < 1e-4, "%s: its rim whole too (%v)", when_, v.color.a)
			}
		}
	}
	ui_tick(&ui, f64(ui.tree.theme.motion.base) * 0.3)
	frame(&ui.tree, {600, 400})
	whole_and_fading(t, &ui, card, tint, "part-way in")

	ui_tick(&ui, 10_000) // all the way in
	frame(&ui.tree, {600, 400})
	bd, _, label_a := find(&ui.tree, node_get(&ui.tree, card).abs, tint)
	b, drawn := bd.?
	testing.expect(t, drawn && b.fade == 0 && label_a >= 0.999, "fully in: whole, and what is on it too")

	// Half-way through its own exit, which is not motion.base: a popover
	// leaves faster than that on purpose (POPOVER_EXIT_MS), and by
	// base × 0.5 the card would already be swept.
	exit_ms := f64(node_get(&ui.tree, card).style.exit.duration)
	build(&ui, false) // closed: it leaves
	ui_tick(&ui, 10_000 + exit_ms * 0.5)
	frame(&ui.tree, {600, 400})
	whole_and_fading(t, &ui, card, tint, "part-way out")

	solid := ui.tree.theme_base
	solid.glass = .Solid
	set_theme(&ui.tree, solid)
	ui_tick(&ui, 20_000)
	card = build(&ui, true)
	ui_tick(&ui, 20_000 + f64(ui.tree.theme.motion.base) * 0.3)
	frame(&ui.tree, {600, 400})
	cd = node_get(&ui.tree, card)
	bd, _, label_a = find(&ui.tree, cd.abs, tint)
	opaque := false
	for c in draw_list(&ui.tree) do if r, ok := c.(Draw_Rect); ok && at(r.rect, cd.abs) && r.color.a >= 0.999 do opaque = true
	testing.expect(t, bd == nil && opaque, "Solid glass: an opaque card, no backdrop, whole part-way in")
	testing.expectf(t, label_a > 0.01 && label_a < 0.99, "…with what is on it fading (%v)", label_a)
}

// A glass card that isn't an overlay still fades as glass with its own
// transition: tint and rim at what the fade has reached.
@(test)
a_glass_card_that_is_not_an_overlay_fades_as_glass :: proc(t: ^testing.T) {
	ui: Ui(GMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.motion.reduce = false
	begin_view(&ui)
	column(&ui, padding = .lg)
	c := card(&ui, glass = true)
	transition(&ui, c, .Fade_Up, .Fade)
	text(&ui, "A toast")
	end(&ui)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 400})
	testing.expect(t, has_material(node_get(&ui.tree, c).style.material), "fixture: a glass card")
	ui_tick(&ui, f64(ui.tree.theme.motion.base) * 0.3)
	frame(&ui.tree, {600, 400})
	fade: f32 = -1
	for cmd in draw_list(&ui.tree) do if b, ok := cmd.(Draw_Backdrop); ok do fade = b.fade
	testing.expectf(t, fade > 0.01 && fade < 0.99, "part-way in: its glass faded (%v)", fade)
}

// A tile, a track on it, a popover's 1 px edge and its rim separate from
// what is below them on screen as the design's tokens do in a browser,
// within half a level, in every mode, over the stage the design was drawn on
// (the rim over the edge along the top, as the design lays it). Baldr lays
// them in linear light on the popup's surface, which shows premultiplied over the
// backdrop; the design lays sRGB values over each other. A popover casts the
// design's shadow, and Solid glass has no edge.
@(test)
glass_depth_lands_where_the_design_put_it :: proc(t: ^testing.T) {
	stage := [3]f32{0x90 / 255.0, 0x9d / 255.0, 0x8a / 255.0}
	enc :: proc(v: [3]f32) -> [3]f32 { return {linear_to_srgb(v.r), linear_to_srgb(v.g), linear_to_srgb(v.b)} }
	level :: proc(v: [3]f32) -> f32 { return (0.2126 * v.r + 0.7152 * v.g + 0.0722 * v.b) * 255 }
	Px :: struct { rgb: [3]f32, a: f32 }
	lay :: proc(p: Px, c: Color) -> Px { return {c.rgb * c.a + p.rgb * (1 - c.a), c.a + p.a * (1 - c.a)} }
	screen :: proc(p: Px, stage: [3]f32) -> f32 { return level(enc(p.rgb / p.a) * p.a + stage * (1 - p.a)) }
	css :: proc(below, c: [3]f32, a: f32) -> [3]f32 { return c * a + below * (1 - a) }
	for mode in Theme_Mode {
		th := theme_from_seed(BALDR_BLUE, mode)
		tokens := GLASS_TOKENS
		tok := tokens[mode]
		m := th.material[.Frosted].popover
		ink := th.color.on_surface.rgb
		glass := Px{m.tint.rgb * m.tint.a, m.tint.a}
		g := screen(glass, stage)
		tile := lay(glass, th.color.fill)
		edge_ink := ink if mode == .Light else [3]f32{1, 1, 1}
		c_glass := css(stage, enc(m.tint.rgb), m.tint.a)
		c_tile := css(c_glass, enc(ink), tok.fill)
		c_track := css(c_tile, enc(ink), tok.fill_strong)
		c_edge := css(c_glass, enc(edge_ink), tok.edge)
		c_rim := css(c_edge, {1, 1, 1}, tok.rim_frosted)
		Step :: struct { name: string, baldr, design: f32 }
		steps := [?]Step{
			{"tile over the glass", screen(tile, stage) - g, level(c_tile) - level(c_glass)},
			{"track over a tile", screen(lay(tile, th.color.fill_strong), stage) - screen(tile, stage), level(c_track) - level(c_tile)},
			{"edge over the glass", screen(lay(glass, m.edge), stage) - g, level(c_edge) - level(c_glass)},
			{"rim over the edge", screen(lay(lay(glass, m.edge), m.highlight), stage) - screen(lay(glass, m.edge), stage), level(c_rim) - level(c_edge)},
		}
		for s in steps do testing.expectf(t, abs(s.baldr - s.design) < 0.5, "%v %s: %.2f levels, the design %.2f", mode, s.name, s.baldr, s.design)
		testing.expect_value(t, m.shadow, Shadow_Style{offset = {0, 16}, blur = 40, color = {0, 0, 0, tok.shadow}})
		testing.expect_value(t, th.material[.Solid].popover.edge, Color{})
	}
	light, dim := theme_from_seed(BALDR_BLUE, .Light), theme_from_seed(BALDR_BLUE, .Dim)
	testing.expect(t, light.color.fill.a > GLASS_TOKENS[.Light].fill && dim.color.fill.a < GLASS_TOKENS[.Dim].fill, "dark ink on light glass needs more than its token, light ink on dark glass less")
}

// A glass popover has no border of its own: it casts the material's shadow
// after its glass, leaving the card clear, and draws the material's 1 px
// edge between its backdrop and its rim.
@(test)
glass_popover_casts_its_shadow_around_its_card :: proc(t: ^testing.T) {
	ui: Ui(GMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.motion.reduce = true
	card: Node
	begin_view(&ui)
	column(&ui, padding = .lg)
	anchor := button(&ui, "Control", GMsg.None)
	end(&ui)
	if popover(&ui, anchor, true, GMsg.Close) {
		card = ui.scopes[len(ui.scopes) - 1].node
		text(&ui, "Control Centre")
		end(&ui)
	}
	end_view(&ui)
	frame(&ui.tree, {600, 400})
	// Settled first: this is about how the shadow composes with the glass,
	// not the entrance, and part-way through a Fade_Scale every rect here is
	// 96% of its resting size.
	ui_tick(&ui, 10_000)
	frame(&ui.tree, {600, 400})
	cd := node_get(&ui.tree, card)
	m := cd.style.material
	testing.expect(t, has_material(m) && cd.style.border_w == 0 && cd.style.shadow == m.shadow, "glass: the material's shadow, no border")
	backdrop_at, shadow_at := -1, -1
	shadow: Draw_Shadow
	cmds := draw_list(&ui.tree)
	for c, i in cmds {
		#partial switch v in c {
		case Draw_Backdrop: if v.rect == cd.abs do backdrop_at = i
		case Draw_Shadow:   if v.hole == cd.abs { shadow_at = i; shadow = v }
		}
	}
	testing.expect(t, backdrop_at >= 0 && shadow_at > backdrop_at, "its shadow comes after its glass, leaving the card clear")
	testing.expect(t, shadow.rect == Rect{cd.abs.x, cd.abs.y + 16, cd.abs.w, cd.abs.h} && shadow.blur == 40, "the design's shadow, 16 px down")
	if backdrop_at >= 0 {
		out := make([dynamic]gpu.Cmd, context.temp_allocator)
		render_draw(&ui.tree, cmds[backdrop_at:backdrop_at + 1], {}, 1, nil, &out)
		order: [3]int = {-1, -1, -1}
		for c, i in out {
			#partial switch v in c {
			case gpu.Backdrop:  order[0] = i
			case gpu.Quad:      if v.border_w == 1 && v.border == m.edge do order[1] = i
			case gpu.Highlight: order[2] = i
			}
		}
		testing.expect(t, order[0] >= 0 && order[0] < order[1] && order[1] < order[2], "backdrop, then its edge, then its rim")
	}
	testing.expect(t, lint(&ui.tree) == 0)
}

// A shadow draws as far as CSS box-shadow's Gaussian reaches, 1.5 × its blur
// past the offset shape, so a repaint dirties that far and a popup's surface
// leaves room for it: the design's popover shadow, 0 16px 40px, needs 78 px.
@(test)
shadows_repaint_and_make_room_as_far_as_they_reach :: proc(t: ^testing.T) {
	tr: Tree
	tree_init(&tr)
	defer tree_destroy(&tr)
	node_get(&tr, tr.root).layout = {axis = .Column}
	n := node_new(&tr, Box_Kind{})
	node_get(&tr, n).layout = {width = 100, height = 50}
	node_get(&tr, n).style.shadow = {offset = {0, 16}, blur = 40, color = {0, 0, 0, 0.4}}
	node_append(&tr, tr.root, n)
	frame(&tr, {400, 400})
	d := node_get(&tr, n)
	b := paint_bounds(d)
	testing.expect_value(t, b, Rect{d.abs.x - 61, d.abs.y + 16 - 61, d.abs.w + 122, d.abs.h + 122})
	testing.expect_value(t, popup_margin(theme_from_seed(BALDR_BLUE, .Dim).material[.Frosted].popover.shadow), 78)
}

// A popup waits for the compositor to measure what is behind it rather than
// showing a tint made for the worst case and correcting it a frame later.
// But a report that never comes must not leave it unadapted for ever: on a
// Clear popover over a dark wallpaper, a light theme's dark text would sit
// on a dark card.
@(test)
a_popup_whose_report_never_comes_stops_waiting :: proc(t: ^testing.T) {
	ui: Ui(int)
	ui_init(&ui)
	defer ui_destroy(&ui)
	th := theme_from_seed(BALDR_BLUE, .Light)
	th.glass = .Clear
	ui.tree.theme_base = th
	ui.tree.theme = th
	ui.tree.popups_on = true
	ui.tree.glass = {on = true, popups = true, role = .Popover, reported = true, known = false}
	n := Node(1)
	ui.tree.popups[n] = Popup_Place{glass = true, known = false, wait_until = 1000}

	ui.tree.now_ms = 500 // the report may still be coming
	waiting, ok1 := popup_theme(&ui.tree, n)
	testing.expect(t, ok1)
	testing.expect_value(t, waiting.material[.Clear].popover.tint.a, th.material[.Clear].popover.tint.a)

	ui.tree.now_ms = 1500 // …and it never came
	stopped, ok2 := popup_theme(&ui.tree, n)
	testing.expect(t, ok2)
	testing.expect(t, stopped.material[.Clear].popover.tint.a > waiting.material[.Clear].popover.tint.a,
		"the tint thickens for the worst case rather than staying where it was")
	// and the text on it reads against both ends of that worst case
	worst := stopped.material[.Clear].popover
	for lum in ([]f32{0, 1}) {
		base := glass_over({linear_to_srgb(worst.tint.r), linear_to_srgb(worst.tint.g), linear_to_srgb(worst.tint.b)}, worst.tint.a, lum)
		testing.expectf(t, contrast_ratio(stopped.color.on_surface, base) >= 4.0,
			"text over a backdrop of %.0f is %.2f:1", lum, contrast_ratio(stopped.color.on_surface, base))
	}
}

// A surface that wants no blur of its own can still want glass popups: a
// desktop asks for `backdrop = .None` because it is the wallpaper, and its
// menus still open over that wallpaper, so they are measured and adapted
// like any glass.
@(test)
a_surface_that_takes_no_blur_can_still_have_glass_popups :: proc(t: ^testing.T) {
	caps := platform.Caps{.Transparent, .Backdrop_Blur, .Popups}
	desktop := Surface_Desc(int){kind = .Layer, transparent = true, backdrop = .None}
	bar := Surface_Desc(int){kind = .Layer, transparent = true, backdrop = .Blur}
	window := Surface_Desc(int){kind = .Window}

	testing.expect(t, !surface_glass(desktop, caps, .Frosted), "the desktop itself is not glass")
	testing.expect(t, surface_popups_glass(desktop, caps, .Frosted), "…and its menus are")
	testing.expect(t, surface_glass(bar, caps, .Frosted) && surface_popups_glass(bar, caps, .Frosted))
	// an opaque window's menus are unchanged: they sit over its own content
	testing.expect(t, !surface_glass(window, caps, .Frosted) && !surface_popups_glass(window, caps, .Frosted))
	// and Solid is Solid everywhere
	testing.expect(t, !surface_popups_glass(desktop, caps, .Solid))
	// …as is a compositor that cannot blur
	testing.expect(t, !surface_popups_glass(desktop, platform.Caps{.Transparent}, .Frosted))
}

} // when ODIN_TEST