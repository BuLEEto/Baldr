package baldr

@(require) import "core:testing"

// Behind this `when` so a program importing Baldr does not type-check the
// test suite too, which costs gigabytes. ODIN_TEST is set by `odin test`;
// BALDR_TESTS lets ./build.sh check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Pages inside a popover, as a desktop shell's control centre uses them.


@(private = "file")
Pages_PMsg :: union { int }

// cc_view: a 300 px wide pages container: page 0 the grid (two openers over a
// tall box), page 1 a tile's page (Back, a field-sized box).
@(private = "file")
cc_view :: proc(ui: ^Ui(Pages_PMsg), page: u64, depth: int) -> (container, wifi, back: Node) {
	begin_view(ui)
	column(ui, width = 300)
	pages(ui, page, depth, label = "Control Centre", key = 7)
	switch page {
	case 0:
		wifi = button(ui, "Wi-Fi settings", Pages_PMsg(1), key = 1)
		button(ui, "Sound settings", Pages_PMsg(2), key = 2)
		box(ui, height = 200, key = 3)
	case 1:
		back = button(ui, "Back", Pages_PMsg(0), key = 1)
		box(ui, height = 60, key = 2)
	}
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 600})
	container = find_role_named(&ui.tree, ui.tree.root, .Group, "Control Centre")
	return
}

@(private = "file")
find_role_named :: proc(t: ^Tree, n: Node, role: Role, name: string) -> Node {
	d := node_get(t, n)
	if d == nil do return NODE_NONE
	if d.access.role == role && d.access.name == name do return n
	for c := d.first; c != NODE_NONE; c = node_get(t, c).next do if f := find_role_named(t, c, role, name); f != NODE_NONE do return f
	return NODE_NONE
}

@(private = "file")
page_child :: proc(t: ^Tree, container: Node, page: u64) -> Node {
	for c := node_get(t, container).first; c != NODE_NONE; c = node_get(t, c).next do if node_get(t, c).key == pages_key(page) do return c
	return NODE_NONE
}

// Going deeper, the tile's page slides in from the end while the grid slides
// out to the start, focus goes to the page's first control (with its ring
// from the keyboard), and the container eases from the grid's height to the
// page's, its width kept; the leaving grid takes no pointer. Coming back is
// the other way round: the grid, with the same nodes, slides in from the
// start, and focus returns to the control that opened the page.
@(test)
pages_slide_ease_their_height_and_keep_focus :: proc(t: ^testing.T) {
	ui: Ui(Pages_PMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	base := f64(ui.tree.theme.motion.base)
	container, wifi, _ := cc_view(&ui, 0, 0)
	testing.expect(t, container != NODE_NONE, "a Group named Control Centre")
	if container == NODE_NONE do return
	grid_h := node_get(&ui.tree, container).abs.h
	testing.expect_value(t, node_get(&ui.tree, container).abs.w, 300)
	testing.expect(t, grid_h > 200, "as tall as the grid")
	grid := page_child(&ui.tree, container, 0)

	ui_tick(&ui, 1000)
	set_focus(&ui.tree, wifi, true) // reached from the keyboard, activated
	_, _, back := cc_view(&ui, 1, 1)
	page := page_child(&ui.tree, container, 1)
	gd, pd := node_get(&ui.tree, grid), node_get(&ui.tree, page)
	testing.expect(t, .Exiting in gd.flags && gd.style.exit.kind == .Slide_Start, "the grid slides out to the start")
	testing.expect_value(t, pd.style.enter.kind, Transition_Kind.Slide_End) // the page comes in from the end
	testing.expect_value(t, ui.tree.focus, back)
	testing.expect(t, ui.tree.focus_visible, "the ring shows where focus went")
	testing.expect_value(t, node_get(&ui.tree, container).abs.h, grid_h) // the height starts where it was
	bd := node_get(&ui.tree, back)
	testing.expect(t, hit_test(&ui.tree, {bd.abs.x + 4, bd.abs.y + 4}) != wifi, "the leaving grid takes no pointer")

	ui_tick(&ui, 1000 + base / 2)
	frame(&ui.tree, {400, 600})
	mid := node_get(&ui.tree, container).abs.h
	ui_tick(&ui, 1000 + base + 20)
	frame(&ui.tree, {400, 600})
	page_h := node_get(&ui.tree, container).abs.h
	testing.expectf(t, page_h < 100 && mid < grid_h && mid > page_h, "eased from the grid's height to the page's: %v → %v → %v", grid_h, mid, page_h)
	testing.expect_value(t, node_get(&ui.tree, container).abs.w, 300)

	ui_tick(&ui, 3000)
	container, wifi, _ = cc_view(&ui, 0, 0) // Back
	testing.expect_value(t, page_child(&ui.tree, container, 0), grid) // the same nodes: its state kept
	gd, pd = node_get(&ui.tree, grid), node_get(&ui.tree, page)
	testing.expect(t, .Exiting not_in gd.flags && gd.style.enter.kind == .Slide_Start, "the grid comes back from the start")
	testing.expect(t, .Exiting in pd.flags && pd.style.exit.kind == .Slide_End, "the page leaves to the end")
	testing.expect_value(t, ui.tree.focus, wifi) // the control that opened the page
	testing.expect(t, ui.tree.focus_visible, "with its ring")
	testing.expect(t, lint(&ui.tree) == 0)
}

// Under reduce motion the height changes at once.
@(test)
pages_change_at_once_under_reduce_motion :: proc(t: ^testing.T) {
	ui: Ui(Pages_PMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.motion.reduce = true
	container, _, _ := cc_view(&ui, 0, 0)
	grid_h := node_get(&ui.tree, container).abs.h
	container, _, _ = cc_view(&ui, 1, 1)
	h := node_get(&ui.tree, container).abs.h
	testing.expectf(t, h < 100 && h < grid_h, "the page's height at once: %v", h)
}

// Pages clip their slides but not the focus ring of a control at a page's
// edge: the clip reaches the ring's overhang beyond the container.
@(test)
pages_keep_focus_rings_at_their_edges :: proc(t: ^testing.T) {
	ui: Ui(Pages_PMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	container, wifi, _ := cc_view(&ui, 0, 0)
	if container == NODE_NONE {
		testing.expect(t, false, "fixture: the pages container")
		return
	}
	set_focus(&ui.tree, wifi, true)
	frame(&ui.tree, {400, 600})
	ui_tick(&ui, 10_000) // the ring has faded in
	frame(&ui.tree, {400, 600})
	cd, wd := node_get(&ui.tree, container), node_get(&ui.tree, wifi)
	testing.expect(t, wd.abs.x == cd.abs.x && wd.abs.y == cd.abs.y, "fixture: the button sits at the page's top-left edge")
	g := FOCUS_RING_OVERHANG
	want := Rect{cd.abs.x - g, cd.abs.y - g, cd.abs.w + 2 * g, cd.abs.h + 2 * g}
	clip: Maybe(Rect)
	ring: Maybe(Rect)
	for c in draw_list(&ui.tree) {
		#partial switch v in c {
		case Draw_Clip_Push: if v.rect == want do clip = v.rect
		case Draw_Rect:      if v.border_w == 2 && v.rect.x == wd.abs.x - 3 && v.rect.y == wd.abs.y - 3 do ring = v.rect
		}
	}
	cr, has_clip := clip.?
	rr, has_ring := ring.?
	testing.expect(t, has_clip, "the clip reaches past the container by the ring's overhang")
	testing.expect(t, has_ring, "the focused button's ring is drawn")
	if has_clip && has_ring {
		testing.expect(t, rr.x >= cr.x && rr.y >= cr.y && rr.x + rr.w <= cr.x + cr.w, "the whole ring is inside the clip")
	}
}

} // when ODIN_TEST