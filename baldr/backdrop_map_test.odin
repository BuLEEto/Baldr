package baldr

@(require) import "core:testing"

// Text that reads what is behind *that piece* of it.
//
// Under a wallpaper light at the top and near-black at the bottom, one range
// for the whole surface gives every line the single ink that reads over the
// whole span (dark, with a white halo), which looks embossed and rough over
// the dark half. Each line takes the colour that reads over its own part.

when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Bdm_Msg :: enum { None }

// bdm_byte is a relative luminance as the compositor sends it: the 8-bit
// sRGB grey of the same brightness.
@(private = "file")
bdm_byte :: proc(lum: f32) -> u8 {
	return u8(clamp(linear_to_srgb(lum) * 255 + 0.5, 0, 255))
}

// bdm_split builds a map of `cols` x `rows` cells whose top half is `top`
// and bottom half is `bottom`: a wallpaper light above and dark below.
@(private = "file")
bdm_split :: proc(t: ^Tree, cols, rows, cell: int, top, bottom: f32) {
	cells := make([]u8, cols * rows, context.temp_allocator)
	for r in 0 ..< rows {
		v := bdm_byte(top if r < rows / 2 else bottom)
		for c in 0 ..< cols do cells[r * cols + c] = v
	}
	tree_backdrop_map(t, cols, rows, cell, {0, 0}, cells)
}

@(test)
backdrop_map_decodes_the_bytes_as_srgb :: proc(t: ^testing.T) {
	// The byte is an sRGB grey, not a linear one. Dividing by 255 would call
	// a mid grey twice as bright as it is and send every ink the wrong way.
	ui: Ui(Bdm_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree
	tree_backdrop(tr, Backdrop_Range{0, 0.5, 1})

	cells := []u8{128, 128, 128, 128}
	tree_backdrop_map(tr, 2, 2, 10, {0, 0}, cells)
	bd, ok := tree_range_in(tr, Rect{0, 0, 20, 20})
	testing.expect(t, ok)
	// sRGB 128/255 is a relative luminance near 0.216, not 0.502.
	testing.expect(t, bd.avg > 0.19 && bd.avg < 0.24,
		"a mid sRGB grey decodes to about 0.216 relative luminance")
}

@(test)
backdrop_range_in_reads_only_the_cells_under_the_rect :: proc(t: ^testing.T) {
	ui: Ui(Bdm_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree
	tree_backdrop(tr, Backdrop_Range{0.02, 0.31, 0.6})
	bdm_split(tr, 10, 10, 10, 0.6, 0.02) // 100 x 100 px: light on top, near-black below

	top, ok_top := tree_range_in(tr, Rect{0, 0, 100, 40})
	testing.expect(t, ok_top)
	testing.expect(t, top.max > 0.5, "the top half is the light part")
	testing.expect(t, top.min > 0.5, "…and none of it is dark")

	bottom, ok_bottom := tree_range_in(tr, Rect{0, 60, 100, 40})
	testing.expect(t, ok_bottom)
	testing.expect(t, bottom.max < 0.1, "the bottom half is the dark part")

	// A rect across the middle sees both, which is the one place a halo is
	// still the right answer.
	both, _ := tree_range_in(tr, Rect{0, 30, 100, 40})
	testing.expect(t, both.min < 0.1 && both.max > 0.5, "a rect over the join sees both")
}

@(test)
backdrop_range_in_falls_back_to_the_surface_without_a_map :: proc(t: ^testing.T) {
	// A v2 compositor, or the frames before the first map: the answer is the
	// whole surface's range.
	ui: Ui(Bdm_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree
	whole := Backdrop_Range{0.02, 0.31, 0.6}
	tree_backdrop(tr, whole)

	bd, ok := tree_range_in(tr, Rect{0, 0, 50, 20})
	testing.expect(t, ok)
	testing.expect_value(t, bd, whole)

	// …and with nothing measured at all, nothing is claimed.
	ui2: Ui(Bdm_Msg)
	ui_init(&ui2)
	defer ui_destroy(&ui2)
	_, none := tree_range_in(&ui2.tree, Rect{0, 0, 50, 20})
	testing.expect(t, !none, "no backdrop reported: no range")
}

@(test)
backdrop_map_gives_two_lines_over_a_gradient_different_inks :: proc(t: ^testing.T) {
	// Over a wallpaper that runs light to dark, one
	// surface-wide range gives both lines one ink; the map should give the
	// line on the light part a dark ink and the line on the dark part a
	// light one, and neither a halo, because each sits over something even.
	ui: Ui(Bdm_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree
	set_viewport(tr, {200, 200})
	tree_backdrop(tr, Backdrop_Range{0.02, 0.31, 0.6})
	bdm_split(tr, 20, 20, 10, 0.6, 0.02) // 200 x 200 px

	begin_view(&ui)
	column(&ui, flex = 1)
	high := text(&ui, "over the light part", role = .Body)
	spacer(&ui, 120)
	low := text(&ui, "over the dark part", role = .Body)
	end(&ui)
	end_view(&ui)
	frame(tr, {200, 200})

	grey := Color{0.4, 0.4, 0.4, 1}
	legible_over(&ui, high, grey, 3)
	legible_over(&ui, low, grey, 3)
	frame(tr, {200, 200}) // the pass runs between layout and paint

	hd, ld := node_get(tr, high), node_get(tr, low)
	testing.expect(t, hd != nil && ld != nil)
	testing.expect(t, hd.abs.y < 100 && ld.abs.y > 100, "one line on each half")

	hl := luminance(hd.style.fg)
	ll := luminance(ld.style.fg)
	testing.expect(t, hl < ll,
		"the line over the light part takes the darker ink of the two")
	testing.expect(t, contrast_ratio(hd.style.fg, Color{0.6, 0.6, 0.6, 1}) >= 3 ||
		hd.style.glow != Glow{}, "and it reads over the light part, or wears a halo")
}

@(test)
backdrop_map_repicks_when_the_wallpaper_changes :: proc(t: ^testing.T) {
	// A new map and no view rebuild, as a wallpaper slideshow gives: the
	// node's ink changes under it.
	ui: Ui(Bdm_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree
	set_viewport(tr, {100, 100})
	tree_backdrop(tr, Backdrop_Range{0.9, 0.9, 0.9})
	bdm_split(tr, 10, 10, 10, 0.9, 0.9) // all light

	begin_view(&ui)
	column(&ui, flex = 1)
	n := text(&ui, "readout", role = .Body)
	end(&ui)
	end_view(&ui)
	frame(tr, {100, 100})
	legible_over(&ui, n, Color{0.5, 0.5, 0.5, 1}, 3)
	frame(tr, {100, 100})
	over_light := node_get(tr, n).style.fg

	// the wallpaper is swapped for a near-black one
	bdm_split(tr, 10, 10, 10, 0.02, 0.02)
	legible_pass(tr)
	over_dark := node_get(tr, n).style.fg

	testing.expect(t, over_light != over_dark, "the ink followed the wallpaper")
	testing.expect(t, luminance(over_dark) > luminance(over_light),
		"a near-black wallpaper takes a lighter ink than a near-white one")
}

@(test)
backdrop_map_ignores_a_map_that_does_not_fit_its_own_size :: proc(t: ^testing.T) {
	// A short array is a protocol error on the other side, not something to
	// read past the end of.
	ui: Ui(Bdm_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree
	tree_backdrop(tr, Backdrop_Range{0.1, 0.2, 0.3})
	short := []u8{10, 20}
	testing.expect(t, !tree_backdrop_map(tr, 4, 4, 8, {0, 0}, short),
		"fewer bytes than cells: refused")
	bd, _ := tree_range_in(tr, Rect{0, 0, 32, 32})
	testing.expect_value(t, bd, Backdrop_Range{0.1, 0.2, 0.3}) // still the surface's
}


@(test)
icon_labels_drop_their_halo_over_a_plain_wallpaper :: proc(t: ^testing.T) {
	// A desktop's icon names wear a blind halo because
	// nothing is known about what is behind them. Where the backdrop *is*
	// reported cell by cell, a name over a plain part of a wallpaper should
	// lose the halo and only one lying across an edge should keep it.
	ui: Ui(Bdm_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree
	set_viewport(tr, {400, 300})
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)

	build :: proc(ui: ^Ui(Bdm_Msg), sel: ^Selection) {
		begin_view(ui)
		column(ui, flex = 1)
		first, last := icon_view(ui, 2, sel, label = "Desktop", label_over = .Anything, key = 1)
		for i in first ..< last do icon_item(ui, i, .File, "report.pdf")
		end(ui)
		end_view(ui)
		frame(&ui.tree, {400, 300})
	}

	// Nothing measured: the blind halo.
	build(&ui, &sel)
	testing.expect(t, !backdrop_mapped(&ui), "no map yet")
	haloed := 0
	walk_glows(tr, ui.root, &haloed)
	testing.expect(t, haloed > 0, "without a map the names wear their blind halo")

	// A plain wallpaper, measured: no name needs a halo.
	tree_backdrop(tr, Backdrop_Range{0.02, 0.02, 0.02})
	bdm_split(tr, 40, 30, 10, 0.02, 0.02)
	testing.expect(t, backdrop_mapped(&ui), "the map arrived")
	build(&ui, &sel)
	plain := 0
	walk_glows(tr, ui.root, &plain)
	testing.expect_value(t, plain, 0)

	// …and over a wallpaper whose light and dark fall *under* the names —
	// a photograph's detail, not a gradient's halves — something does. (A
	// split wallpaper is not enough: tiles in its light half read a flat
	// range and are right to stay bare.)
	cells := make([]u8, 40 * 30, context.temp_allocator)
	for r in 0 ..< 30 {
		for c in 0 ..< 40 {
			cells[r * 40 + c] = bdm_byte(0.9 if (r + c) % 2 == 0 else 0.02)
		}
	}
	tree_backdrop_map(tr, 40, 30, 10, {0, 0}, cells)
	build(&ui, &sel)
	mixed := 0
	walk_glows(tr, ui.root, &mixed)
	testing.expect(t, mixed > 0, "a name over both light and dark keeps its halo")
}

// walk_glows counts the nodes currently carrying a glow.
@(private = "file")
walk_glows :: proc(t: ^Tree, n: Node, out: ^int) {
	d := node_get(t, n)
	if d == nil do return
	if d.style.glow != (Glow{}) do out^ += 1
	for c := d.first; c != NODE_NONE; c = node_get(t, c).next do walk_glows(t, c, out)
}

}
