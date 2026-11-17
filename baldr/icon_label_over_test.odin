#+build linux
package baldr

@(require) import "core:fmt"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: about 9 GB without this `when`, 1 GB with it.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A desktop's labels sit on the person's wallpaper, which the app did not
// choose and cannot measure: on a pale one, the theme's near-white ink is
// the same colour as what is behind it. `label_over = .Anything` gives every
// glyph a halo in the opposite tone, which carries a label over sky and
// hedge alike.


@(private = "file")
Lo_Msg :: enum { None }

@(private = "file")
lo_view :: proc(ui: ^Ui(Lo_Msg), sel: ^Selection, over: Label_Over) -> Node {
	set_viewport(&ui.tree, {480, 360})
	begin_view(ui)
	column(ui, flex = 1)
	first, last := icon_view(ui, 3, sel, label_over = over, label = "Desktop", key = 6)
	for i in first ..< last do icon_item(ui, i, .File, fmt.tprintf("name-%d", i))
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {480, 360})
	return node_first(&ui.tree, node_first(&ui.tree, ui.root))
}

@(private = "file")
lo_glows :: proc(ui: ^Ui(Lo_Msg)) -> (pushes: int, last: Glow) {
	for c in draw_list(&ui.tree) {
		if g, is_push := c.(Draw_Glow_Push); is_push && g.glow.radius > 0 && g.glow.color.a > 0 {
			pushes += 1
			last = g.glow
		}
	}
	return
}

@(test)
icon_labels_over_a_wallpaper_carry_their_own_contrast :: proc(t: ^testing.T) {
	ui: Ui(Lo_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)

	pushes, _ := lo_glows(&ui)
	lo_view(&ui, &sel, .Surface)
	pushes, _ = lo_glows(&ui)
	testing.expect_value(t, pushes, 0) // on the app's own surface the theme's colours are right

	lo_view(&ui, &sel, .Anything)
	halo: Glow
	pushes, halo = lo_glows(&ui)
	testing.expect_value(t, pushes, 6) // three tiles: the icon and the label of each
	ink := ui.tree.theme.color.on_surface
	dark_ink := luminance(ink) < 0.5
	testing.expect(t, (luminance(halo.color) > 0.5) == dark_ink, "the halo is the opposite tone to the ink")
	testing.expect(t, halo.color.a > 0.5 && halo.radius > 0)
	// …and it is laid down more than once: over a pale wallpaper one blurred
	// copy of a glyph leaves its outline at about 2:1, four passes past 9:1.
	testing.expect(t, halo.passes >= 2, "a halo that carries text over a wallpaper is laid down several times")
	// the halo's job is to stand off the ink it surrounds, so the glyph has
	// an edge whatever is behind it
	testing.expect(t, contrast_ratio(halo.color, ink) > 4.5, "the halo reads against the ink")

	// a light theme flips it, because the ink flipped
	set_theme(&ui.tree, theme_light())
	lo_view(&ui, &sel, .Anything)
	_, light_halo := lo_glows(&ui)
	testing.expect(t, luminance(light_halo.color) != luminance(halo.color), "dark text gets a light halo")

	// a selected tile has a plate behind it already: no halo on that one
	set_theme(&ui.tree, theme_dark())
	selection_set(&sel, 1)
	lo_view(&ui, &sel, .Anything)
	pushes, _ = lo_glows(&ui)
	testing.expect_value(t, pushes, 4) // two unselected tiles
	testing.expect(t, lint(&ui.tree) == 0)
}

} // when ODIN_TEST