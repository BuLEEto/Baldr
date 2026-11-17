package baldr

@(require) import "core:testing"
@(require) import "baldr:gpu"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A desktop shell's rounded bars and docks, and boxes that keep some corners
// square.


@(private = "file")
RndMsg :: union { int }

// A box keeps the corners it is told square and rounds the others: its fill
// and its focus ring take the shape, down to the GPU's quads.
@(test)
a_box_keeps_the_corners_it_is_told_square :: proc(t: ^testing.T) {
	ui: Ui(RndMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	edge := Corners{.Bottom_Left, .Bottom_Right}
	view :: proc(ui: ^Ui(RndMsg), edge: Corners) -> (bar, b: Node) {
		begin_view(ui)
		bar = row(ui, width = 300, height = 44, padding = .xs, bg = ui.tree.theme.color.surface_high, radius = 16)
		square_corners(ui, bar, edge)
		b = button(ui, "Apps", RndMsg(1), variant = .Ghost)
		square_corners(ui, b, edge)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {400, 100})
		return
	}
	bar, b := view(&ui, edge)
	bd := node_get(&ui.tree, bar)
	fill: Maybe(Draw_Rect)
	for c in draw_list(&ui.tree) do if r, ok := c.(Draw_Rect); ok && r.rect == bd.abs do fill = r
	f, has := fill.?
	testing.expect(t, has && f.radius == 16 && f.square == edge, "the bar's fill: rounded at the top, square at the bottom")
	cmds := make([dynamic]gpu.Cmd, context.temp_allocator)
	render_prepare(&ui.tree, 1, nil, &cmds)
	quad: Maybe(gpu.Quad)
	for c in cmds do if q, ok := c.(gpu.Quad); ok && q.radius == 16 do quad = q
	q, has_quad := quad.?
	testing.expect(t, has_quad && q.square == gpu.Corners{.Bottom_Left, .Bottom_Right}, "and the GPU's quad")

	set_focus(&ui.tree, b, true)
	frame(&ui.tree, {400, 100})
	ui_tick(&ui, 10_000)
	frame(&ui.tree, {400, 100})
	ring: Maybe(Draw_Rect)
	bb := node_get(&ui.tree, b).abs
	for c in draw_list(&ui.tree) do if r, ok := c.(Draw_Rect); ok && r.border_w == 2 && r.rect.x == bb.x - 3 do ring = r
	rr, has_ring := ring.?
	testing.expect(t, has_ring && rr.square == edge, "the focus ring takes the shape")

	bar, _ = view(&ui, {})
	fill = nil
	for c in draw_list(&ui.tree) do if r, ok := c.(Draw_Rect); ok && r.rect == node_get(&ui.tree, bar).abs do fill = r
	f, has = fill.?
	testing.expect(t, has && f.square == {}, "{} rounds all four again")
}

// A transparent glass layer surface with a radius is clear outside its
// shape: its tint is drawn as the shape, first, then the highlight rounded
// alike, scaled to device px; without a radius it clears with its tint. A
// change of shape applies live.
@(test)
a_rounded_glass_bar_is_clear_outside_its_shape :: proc(t: ^testing.T) {
	th := theme_dim()
	bar := Surface_Desc(RndMsg){kind = .Layer, transparent = true, backdrop = .Blur, radius = 16, square = {.Bottom_Left, .Bottom_Right}, size = {0, 44},
		layer = {anchor = {.Bottom}, margin = {0, 0, 8, 0}}}
	tint := th.material[th.glass].panel.tint
	testing.expect_value(t, surface_clear(&th, bar, true), Color{}) // clear outside the shape
	testing.expect_value(t, surface_shape(&th, bar, true), tint)
	square := bar
	square.radius = 0
	testing.expect_value(t, surface_clear(&th, square, true), tint) // a square bar clears with its tint
	testing.expect_value(t, surface_shape(&th, square, true), Color{})
	ch := surface_changes(square, bar)
	testing.expect(t, .Shape in ch && ch <= SURFACE_LIVE_CHANGES, "rounding a bar is a live change")

	fc := Frame_Ctx{size_px = {800, 88}, scale = 2, shape = tint, shape_radius = 16, shape_square = bar.square, highlight = {1, 1, 1, 0.2}}
	defer delete(fc.cmds)
	surface_shape_cmds(&fc)
	testing.expect_value(t, len(fc.cmds), 2)
	if len(fc.cmds) == 2 {
		q := fc.cmds[0].(gpu.Quad)
		testing.expect(t, q.rect == {0, 0, 800, 88} && q.radius == 32 && q.color == tint && q.square == gpu.Corners{.Bottom_Left, .Bottom_Right}, "the tint as the shape, in device px")
		h := fc.cmds[1].(gpu.Highlight)
		testing.expect(t, h.radius == 32 && h.square == q.square, "the highlight follows the shape")
	}
}

// A rounded surface takes no pointer at its clear corners: its input region
// steps around the arcs and keeps the square corners whole.
@(test)
a_rounded_surface_takes_no_pointer_at_its_corners :: proc(t: ^testing.T) {
	rects := make([dynamic][4]f32, context.temp_allocator)
	rounded_region({300, 44}, 16, {.Bottom_Left, .Bottom_Right}, &rects)
	covers :: proc(rects: []([4]f32), p: [2]f32) -> bool {
		for r in rects do if p.x >= r[0] && p.x < r[0] + r[2] && p.y >= r[1] && p.y < r[1] + r[3] do return true
		return false
	}
	testing.expect(t, !covers(rects[:], {1, 1}) && !covers(rects[:], {298, 1}), "the rounded top corners take no pointer")
	testing.expect(t, covers(rects[:], {150, 1}) && covers(rects[:], {10, 10}) && covers(rects[:], {150, 22}), "the rest of the top and the middle do")
	testing.expect(t, covers(rects[:], {1, 43}) && covers(rects[:], {298, 43}), "the square bottom corners are whole")
	for r in rects do testing.expect(t, r[0] >= 0 && r[1] >= 0 && r[0] + r[2] <= 300.01 && r[1] + r[3] <= 44.01, "inside the surface")
}

} // when ODIN_TEST