package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
covers :: proc(rects: []Rect, r: Rect) -> bool {
	for dr in rects do if dr.x <= r.x && dr.y <= r.y && dr.x + dr.w >= r.x + r.w && dr.y + dr.h >= r.y + r.h do return true
	return false
}

// Moving keyboard focus must repaint the ring the previous node is losing.
// The ring sits outside the node's rect, and flat nodes (menu-bar titles,
// ghost buttons) have no shadow to widen their paint bounds, so without an
// explicit overhang the fading ring is left on screen.
@(test)
damage_covers_the_focus_ring_of_the_node_focus_left :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {400, 200})
	begin_view(&ui)
	column(&ui)
	bar := menu_bar(&ui)
	if menu_bar_menu(&ui, "File") do end(&ui)
	if menu_bar_menu(&ui, "Edit") do end(&ui)
	end(&ui)
	text(&ui, "page")
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 200})
	take_damage(&ui.tree)
	a := ui.menu_bars[bar].titles[0]
	b := ui.menu_bars[bar].titles[1]
	testing.expect(t, !has_shadow(node_get(&ui.tree, a).style.shadow), "fixture: titles are flat, nothing but the ring reaches outside them")
	set_focus(&ui.tree, a, true)
	frame(&ui.tree, {400, 200})
	take_damage(&ui.tree)
	ad := node_get(&ui.tree, a).abs
	ring := Rect{ad.x - 3, ad.y - 3, ad.w + 6, ad.h + 6}
	// focus moves to b: a's ring starts fading; that frame's damage must cover the whole ring
	set_focus(&ui.tree, b, true)
	ui_tick(&ui, 16)
	frame(&ui.tree, {400, 200})
	testing.expect(t, covers(take_damage(&ui.tree), ring), "the old ring's full extent is repainted")
	// and keeps being repainted while the ring fades out
	ui_tick(&ui, 60)
	frame(&ui.tree, {400, 200})
	testing.expect(t, covers(take_damage(&ui.tree), ring), "still repainted mid-fade")
}


// A halo taken off must be painted over, not just the text under it: the
// glow reaches GLOW_OVERHANG past the node, so damaging only the bare rect
// leaves the old halo's edges on screen either side of the text.
@(test)
damage_covers_a_halo_that_was_taken_away :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {300, 120})

	build :: proc(ui: ^Ui(Ov_Msg), glow: Glow) -> Node {
		begin_view(ui)
		column(ui, flex = 1)
		n := text(ui, "Swap: 0 GiB", role = .Body)
		end(ui)
		end_view(ui)
		set_glow(&ui.tree, n, glow)
		frame(&ui.tree, {300, 120})
		return n
	}

	halo := legible_halo(Color{0.1, 0.1, 0.1, 1})
	n := build(&ui, halo)
	take_damage(&ui.tree)
	d := node_get(&ui.tree, n)
	testing.expect(t, .Glows in d.flags, "it is wearing a halo")
	lit := Rect{
		d.abs.x - GLOW_OVERHANG, d.abs.y - GLOW_OVERHANG,
		d.abs.w + 2 * GLOW_OVERHANG, d.abs.h + 2 * GLOW_OVERHANG,
	}

	// the wallpaper changes and the halo is no longer wanted
	build(&ui, Glow{})
	testing.expect(t, .Glows not_in node_get(&ui.tree, n).flags, "the halo is off")
	testing.expect(t, covers(take_damage(&ui.tree), lit),
		"everything the halo lit is repainted, not only the text's own rect")
}

} // when ODIN_TEST