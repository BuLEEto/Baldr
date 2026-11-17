package baldr

@(require) import "core:testing"
@(require) import "baldr:platform"

when ODIN_TEST || #config(BALDR_TESTS, false) {

// A glass popup inside its window is over the app's own content (white
// paper as easily as a dark page), and nothing measures that: the
// compositor's report describes the desktop behind the window, which the
// page hides. Such a popup takes the worst case instead, as glass over an
// unmeasured backdrop always does (in_app_theme).

@(private = "file")
Giw_Msg :: enum { None, Close }

// giw_on is `fg`'s contrast on material `m` over a backdrop of relative
// luminance `lum`, mixed in linear light: the blend `ui.frag` does for glass
// over the app's own content, not the sRGB one the compositor does over a
// wallpaper, which would promise more contrast than the screen shows.
@(private = "file")
giw_on :: proc(m: Material, fg: Color, lum: f32) -> f32 {
	tint := [3]f32{linear_to_srgb(m.tint.r), linear_to_srgb(m.tint.g), linear_to_srgb(m.tint.b)}
	return contrast_ratio(fg, glass_over(tint, m.tint.a, lum, true))
}

// giw_glow_at is the glow behind the text `str` as render would draw it
// (radius -1: no such text).
@(private = "file")
giw_glow_at :: proc(cmds: []Draw_Cmd, str: string) -> Glow {
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

// A window whose glass is over a dark wallpaper, a context menu over the
// app's own bright page.
@(test)
a_menu_over_its_windows_own_page_reads :: proc(t: ^testing.T) {
	ui: Ui(Giw_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree
	th := theme_from_seed(BALDR_BLUE, .Dim)
	th.glass = .Frosted
	set_theme(tr, th)
	tree_glass(tr, true, false, .Window, true)
	tree_backdrop(tr, {0.01, 0.04, 0.10}) // the desktop behind the window: dark

	lbl, note: Node
	begin_view(&ui)
	set_viewport(tr, {900, 700})
	if context_menu(&ui, true, Giw_Msg.Close) {
		lbl = text(&ui, "Copy")
		note = text(&ui, "Copied just now", muted = true)
		end(&ui)
	}
	end_view(&ui)

	pop := node_first(tr, tr.overlay)
	pd := node_get(tr, pop)
	testing.expect(t, pd != nil && .Glass_In_App in pd.flags, "its glass is over the app's content")
	if pd == nil do return
	m := pd.style.material
	recipe := tr.theme_base.material[tr.theme_base.glass].popover.tint.a
	window := tr.theme.material[tr.theme.glass].popover.tint.a
	testing.expectf(t, m.tint.a > recipe && m.tint.a > window,
		"a tint for the worst case, not the recipe's %.2f or the window's %.2f: %.2f", recipe, window, m.tint.a)
	for n in ([]Node{lbl, note}) {
		d := node_get(tr, n)
		if d == nil {
			testing.fail(t)
			continue
		}
		for i in 0 ..= 10 { // anything the app may have drawn under it, white paper included
			lum := f32(i) / 10
			testing.expectf(t, giw_on(m, d.style.fg, lum) >= GLASS_TEXT_CONTRAST,
				"%v over luminance %.1f: %.2f:1", d.style.fg, lum, giw_on(m, d.style.fg, lum))
		}
	}
}

// A popup on a surface of its own is measured where it lands, so it keeps
// the tint made for that: the worst case would thicken a bar's menus for
// nothing.
@(test)
a_popup_on_its_own_surface_keeps_its_measured_tint :: proc(t: ^testing.T) {
	giw_bar_view :: proc(c: ^Surface_Ctx(Giw_Msg)) {
		begin_view(&c.ui)
		set_viewport(&c.ui.tree, {800, 36})
		row(&c.ui, flex = 1, align = .Center)
		anchor := button(&c.ui, "Control", Giw_Msg.None)
		end(&c.ui)
		if popover(&c.ui, anchor, true, Giw_Msg.Close) {
			text(&c.ui, "Control Centre")
			end(&c.ui)
		}
		end_view(&c.ui)
	}
	b := platform.Backend{caps = {.Popups}}
	b.popup_create = proc(b: ^platform.Backend, d: platform.Popup_Desc) -> (platform.Surface, bool) { return 11, true }
	b.surface_destroy = proc(b: ^platform.Backend, s: platform.Surface) {}
	c: Surface_Ctx(Giw_Msg)
	c.desc.kind = .Layer
	c.surf = 1
	ui_init(&c.ui)
	defer ui_destroy(&c.ui)
	defer delete(c.popups)
	defer popups_close_all(&b, nil, &c)
	tr := &c.ui.tree
	th := theme_from_seed(BALDR_BLUE, .Dim)
	th.glass = .Frosted
	set_theme(tr, th)
	bar := Backdrop_Range{0.05, 0.1, 0.2}
	tree_glass(tr, true, true, .Panel, true)
	tree_backdrop(tr, bar)

	giw_bar_view(&c)
	popups_sync(&b, nil, &c)
	testing.expect_value(t, len(c.popups), 1)
	if len(c.popups) != 1 do return
	n := c.popups[0].node
	_ = popup_backdrop(tr, n, Backdrop_Range{0.06, 0.11, 0.22}) // the compositor measures its own surface
	giw_bar_view(&c) // …and the build after that draws it with the theme for it

	pd := node_get(tr, n)
	testing.expect(t, pd != nil && .Glass_In_App not_in pd.flags, "measured, not guessed")
	want, ok := popup_theme(tr, n)
	testing.expect(t, ok, "a theme of its own backdrop")
	if pd == nil || !ok do return
	testing.expect_value(t, pd.style.material.tint, want.material[want.glass].popover.tint)
	testing.expect(t, pd.style.material.tint.a < tr.in_app_theme.material[tr.in_app_theme.glass].popover.tint.a,
		"thinner than the worst case, which is what being measured buys")
}

// Its own layers — a scroll inside a menu — paint in the theme the menu was
// built with, not the window's. The focus ring is the instrument: paint
// colours it from the theme rather than from the node's style, and a layer
// is painted on its own rather than under its card.
@(test)
a_layer_inside_a_menu_paints_in_the_menus_theme :: proc(t: ^testing.T) {
	ui: Ui(Giw_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree
	th := theme_from_seed(BALDR_BLUE, .Light)
	th.glass = .Frosted
	set_theme(tr, th)
	tree_glass(tr, true, false, .Window, true)
	tree_backdrop(tr, {0.70, 0.80, 0.95}) // a bright desktop behind the window
	tree_keyboard_set(tr, true)
	tr.focus_visible = true

	inner, item: Node
	begin_view(&ui)
	set_viewport(tr, {900, 700})
	if context_menu(&ui, true, Giw_Msg.Close) {
		inner = scroll(&ui, height = 60)
		item = button(&ui, "Sepia", Giw_Msg.None, variant = .Ghost)
		end(&ui)
		end(&ui)
	}
	end_view(&ui)
	set_focus(tr, item, true) // by key: the ring shows
	frame(tr, {900, 700})

	mine := tr.in_app_theme.color.focus_ring
	window := tr.theme.color.focus_ring
	testing.expectf(t, mine != window, "fixture: the two themes ring differently (%v, %v)", mine, window)
	l, has := &tr.layers[inner]
	testing.expect(t, has, "the scroll is a layer of its own")
	if !has do return
	ring, found := Color{}, false
	for cmd in l.cmds {
		if r, is_rect := cmd.(Draw_Rect); is_rect && r.border_w == 2 {
			ring, found = r.border, true
		}
	}
	testing.expect(t, found, "its focus ring was painted in there")
	testing.expect_value(t, ring, mine)
}

}
