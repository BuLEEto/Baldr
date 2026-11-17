package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

Sp_Msg :: struct { size: f32 }

@(private = "file")
on_size :: proc(e: Ev(f32)) -> Sp_Msg { return {e.value} }

@(private = "file")
split_fixture :: proc(ui: ^Ui(Sp_Msg), size: f32, axis: Axis = .Row, sized: Split_Sized = .First) -> (sp, a, b, dv: Node) {
	set_viewport(&ui.tree, {600, 400})
	begin_view(ui)
	sp = split(ui, size, on_change = on_size, min = 100, max = 400, axis = axis, sized = sized)
	a = pane(ui, padding = .sm)
	text(ui, "side")
	end(ui)
	b = pane(ui)
	text(ui, "main")
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	dv = ui.tree.splits[sp].divider
	return
}

@(private = "file")
last_size :: proc(ui: ^Ui(Sp_Msg)) -> f32 {
	if len(ui.msgs) == 0 do return -1
	v := ui.msgs[len(ui.msgs) - 1].size
	clear(&ui.msgs)
	return v
}

// The sized pane takes `size`, the divider is a hairline, the other pane
// fills the rest; both stretch across; the divider is a Separator with a value.
@(test)
split_lays_out_two_panes_and_a_divider :: proc(t: ^testing.T) {
	ui: Ui(Sp_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	_, a, b, dv := split_fixture(&ui, 200)
	ar, br, dr := node_get(&ui.tree, a).abs, node_get(&ui.tree, b).abs, node_get(&ui.tree, dv).abs
	testing.expect_value(t, ar, Rect{0, 0, 200, 400})
	testing.expect_value(t, dr, Rect{200, 0, 1, 400})
	testing.expect_value(t, br, Rect{201, 0, 399, 400})
	dump := access_dump(&ui.tree)
	testing.expect(t, strings.contains(dump, "Separator \"Divider\""), dump)
	testing.expect(t, node_get(&ui.tree, dv).access.value == 200 && .Focusable in node_get(&ui.tree, dv).flags, "the divider is a focusable separator carrying the size")
	// stacked
	_, a2, _, dv2 := split_fixture(&ui, 150, axis = .Column)
	testing.expect_value(t, node_get(&ui.tree, a2).abs, Rect{0, 0, 600, 150})
	testing.expect_value(t, node_get(&ui.tree, dv2).abs, Rect{0, 150, 600, 1})
	// a gutter either side of the divider; the clamp accounts for it
	begin_view(&ui)
	spg := split(&ui, 200, on_change = on_size, min = 100, gap = 16)
	ag := pane(&ui); end(&ui)
	bg := pane(&ui); end(&ui)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 400})
	testing.expect_value(t, node_get(&ui.tree, ag).abs.w, f32(200))
	testing.expect_value(t, node_get(&ui.tree, ui.tree.splits[spg].divider).abs.x, f32(216))
	testing.expect_value(t, node_get(&ui.tree, bg).abs, Rect{233, 0, 367, 400})
	set_focus(&ui.tree, ui.tree.splits[spg].divider, true)
	key_event(&ui, .End, true, {})
	testing.expect_value(t, last_size(&ui), f32(600 - 1 - 32 - 100))
	// the second pane sized
	_, a3, b3, _ := split_fixture(&ui, 200, sized = .Second)
	testing.expect_value(t, node_get(&ui.tree, b3).abs, Rect{400, 0, 200, 400})
	testing.expect_value(t, node_get(&ui.tree, a3).abs.w, f32(399))
}

// Dragging the divider sends the new size through on_change, clamped to
// min / max; the grab zone is wider than the hairline and shows the resize
// cursor; a press outside the zone is not a drag.
@(test)
split_divider_drags_within_limits_with_a_grab_zone :: proc(t: ^testing.T) {
	ui: Ui(Sp_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sp, _, _, dv := split_fixture(&ui, 200)
	testing.expect(t, !pointer_button(&ui, .Left, true, {215, 100}) || ui.split_drag == NODE_NONE, "10 px away is the pane, not the divider")
	pointer_button(&ui, .Left, false, {215, 100})
	pointer_move(&ui, {203, 100}) // inside the 8 px zone
	testing.expect_value(t, ui.split_hover, sp)
	testing.expect_value(t, cursor_for(&ui), Cursor.Resize_EW)
	pointer_button(&ui, .Left, true, {203, 100})
	testing.expect_value(t, ui.split_drag, sp)
	testing.expect_value(t, ui.tree.focus, dv)
	pointer_move(&ui, {253, 100})
	testing.expect_value(t, last_size(&ui), f32(250))
	split_fixture(&ui, 250) // the app applied it
	pointer_move(&ui, {550, 100})
	testing.expect_value(t, last_size(&ui), f32(400)) // max
	pointer_move(&ui, {20, 100})
	testing.expect_value(t, last_size(&ui), f32(100)) // min
	pointer_button(&ui, .Left, false, {20, 100})
	testing.expect_value(t, ui.split_drag, NODE_NONE)
	testing.expect(t, !ui.tree.splits[sp].dragging)
	// the other pane keeps its minimum when max is off
	begin_view(&ui)
	sp2 := split(&ui, 500, on_change = on_size, min = 100)
	pane(&ui); end(&ui)
	pane(&ui); end(&ui)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 400})
	testing.expect_value(t, ui.tree.splits[sp2].size, f32(500))
	pointer_move(&ui, {502, 100})
	pointer_button(&ui, .Left, true, {502, 100})
	pointer_move(&ui, {590, 100})
	testing.expect_value(t, last_size(&ui), f32(499)) // 600 - 1 - 100
	pointer_button(&ui, .Left, false, {590, 100})
	// touch: a wider zone
	set_touch(&ui.tree, true)
	split_fixture(&ui, 200)
	pointer_move(&ui, {210, 100})
	testing.expect(t, ui.split_hover != NODE_NONE, "24 px zone on touch")
}

// A focused divider moves by keyboard: 8 px, 32 with Shift, Home / End to
// the limits; Up / Down do it for a stacked split and are ignored otherwise.
@(test)
split_divider_moves_by_keyboard :: proc(t: ^testing.T) {
	ui: Ui(Sp_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	_, _, _, dv := split_fixture(&ui, 200)
	set_focus(&ui.tree, dv, true)
	testing.expect(t, key_event(&ui, .Right, true, {}))
	testing.expect_value(t, last_size(&ui), f32(208))
	key_event(&ui, .Right, true, {.Shift})
	testing.expect_value(t, last_size(&ui), f32(232))
	key_event(&ui, .Left, true, {})
	testing.expect_value(t, last_size(&ui), f32(192))
	key_event(&ui, .Home, true, {})
	testing.expect_value(t, last_size(&ui), f32(100))
	key_event(&ui, .End, true, {})
	testing.expect_value(t, last_size(&ui), f32(400))
	testing.expect(t, !key_event(&ui, .Up, true, {}), "Up is not a side-by-side divider's key")
	_, _, _, dv2 := split_fixture(&ui, 150, axis = .Column)
	set_focus(&ui.tree, dv2, true)
	key_event(&ui, .Down, true, {})
	testing.expect_value(t, last_size(&ui), f32(158))
	// the second pane sized: Right shrinks it
	_, _, _, dv3 := split_fixture(&ui, 200, sized = .Second)
	set_focus(&ui.tree, dv3, true)
	key_event(&ui, .Right, true, {})
	testing.expect_value(t, last_size(&ui), f32(192))
}

// collapse = .Compact: at phone width the split shows one pane at a time —
// the first until `detail`, then the second fronted by a Back button that
// sends on_close (so does Escape); wider, both panes and the divider return.
@(test)
split_collapses_to_one_pane_at_phone_width :: proc(t: ^testing.T) {
	Cl_Msg :: enum { Back, Other }
	ui: Ui(Cl_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	view :: proc(ui: ^Ui(Cl_Msg), w: f32, detail: bool) -> (sp, a, b: Node) {
		set_viewport(&ui.tree, {w, 400})
		begin_view(ui)
		sp = split(ui, 200, collapse = .Compact, detail = detail, on_close = Cl_Msg.Back, back_label = "Project", min = 100)
		a = pane(ui)
		text(ui, "tree")
		end(ui)
		b = pane(ui)
		text(ui, "details")
		end(ui)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {w, 400})
		return
	}
	sp, a, b := view(&ui, 400, false)
	st := ui.tree.splits[sp]
	testing.expect(t, st.collapsed, "400 px is Compact")
	testing.expect(t, .Hidden not_in node_get(&ui.tree, a).flags && .Hidden in node_get(&ui.tree, b).flags, "the first pane shows, the second is hidden")
	testing.expect_value(t, node_get(&ui.tree, a).abs.w, f32(400))
	testing.expect(t, .Hidden in node_get(&ui.tree, st.divider).flags, "no divider")
	testing.expect(t, !key_event(&ui, .Escape, true, {}), "nothing to go back from")

	_, a, b = view(&ui, 400, true)
	testing.expect(t, .Hidden in node_get(&ui.tree, a).flags && .Hidden not_in node_get(&ui.tree, b).flags, "detail: the second pane fronts the first")
	testing.expect_value(t, node_get(&ui.tree, b).abs.w, f32(400))
	back := node_first(&ui.tree, node_first(&ui.tree, b)) // the back row, then its button
	bd := node_get(&ui.tree, back)
	testing.expect(t, bd != nil && bd.access.role == .Button && bd.access.name == "Project", "a Back button named after the first pane leads the detail pane")
	testing.expect(t, anim_value(&ui.tree, b, .Enter) < 1, "the detail pane fades up when it appears")
	click(&ui, back)
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1], Cl_Msg.Back)
	clear(&ui.msgs)
	testing.expect(t, key_event(&ui, .Escape, true, {}), "Escape goes back too")
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1], Cl_Msg.Back)

	sp, a, b = view(&ui, 900, true)
	st = ui.tree.splits[sp]
	testing.expect(t, !st.collapsed, "wide: a real split again")
	testing.expect(t, .Hidden not_in node_get(&ui.tree, a).flags && .Hidden not_in node_get(&ui.tree, b).flags && .Hidden not_in node_get(&ui.tree, st.divider).flags)
	testing.expect_value(t, node_get(&ui.tree, a).abs.w, f32(200))
	testing.expect(t, node_first(&ui.tree, b) == NODE_NONE || node_get(&ui.tree, node_first(&ui.tree, b)).access.role != .Button, "no Back button when both panes show")
}

// A glass pane takes the theme's sidebar material where
// the surface's glass is live, thinner than the window's own tint; anywhere
// else there is nothing blurred behind it, so it is the sidebar's colour,
// opaque. A plain pane keeps what it was given.
@(test)
a_glass_pane_takes_the_sidebar_material :: proc(t: ^testing.T) {
	ui: Ui(Sp_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	build :: proc(ui: ^Ui(Sp_Msg), glass: bool, bg: Color = {}) -> (side, main: Node) {
		begin_view(ui)
		split(ui, 200)
		side = pane(ui, glass = glass, bg = bg)
		text(ui, "Places")
		end(ui)
		main = pane(ui, bg = ui.tree.theme.color.bg)
		text(ui, "Files")
		end(ui)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {800, 400})
		return
	}
	th := &ui.tree.theme
	opaque :: proc(c: Color) -> Color { return {c.r, c.g, c.b, 1} }

	// live glass: a see-through window the compositor blurs behind
	th.glass = .Frosted
	tree_glass(&ui.tree, true, true, .Window, true)
	side, main := build(&ui, true)
	sd := node_get(&ui.tree, side)
	testing.expect_value(t, sd.style.material, th.material[.Frosted].sidebar)
	testing.expect(t, sd.style.bg.a == 0, "its glass carries the colour")
	testing.expect(t, node_get(&ui.tree, main).style.material == Material{} && node_get(&ui.tree, main).style.bg == th.color.bg, "the content pane keeps its own background")
	testing.expect(t, sd.style.material.tint.a < th.material[.Frosted].window.tint.a, "a sidebar is thinner than the window's own tint")

	// Frosted, but nothing blurs behind it (a compositor that can't): opaque, not a thin tint over the desktop
	tree_glass(&ui.tree, false, false, .Window, false)
	side, _ = build(&ui, true)
	sd = node_get(&ui.tree, side)
	testing.expect_value(t, sd.style.material, Material{})
	testing.expect_value(t, sd.style.bg, opaque(th.material[.Frosted].sidebar.tint))

	// Solid: the sidebar's colour, opaque, so the desktop does not show through
	th.glass = .Solid
	side, _ = build(&ui, true)
	sd = node_get(&ui.tree, side)
	testing.expect_value(t, sd.style.material, Material{})
	testing.expect_value(t, sd.style.bg, opaque(th.material[.Solid].sidebar.tint))
	painted := false
	for c in draw_list(&ui.tree) do if r, ok := c.(Draw_Rect); ok && r.rect == sd.abs && r.color.a == 1 do painted = true
	testing.expect(t, painted, "and it is painted, whole, over its rect")

	// a colour of its own where there is no glass: kept
	own := Color{0.2, 0.3, 0.4, 1}
	side, _ = build(&ui, true, own)
	testing.expect_value(t, node_get(&ui.tree, side).style.bg, own)

	side, _ = build(&ui, false)
	testing.expect_value(t, node_get(&ui.tree, side).style.material, Material{})
	testing.expect_value(t, node_get(&ui.tree, side).style.bg, Color{})
}

} // when ODIN_TEST