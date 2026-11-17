package baldr

@(require) import "core:testing"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// The running-app mark a button draws inside its edge.


@(private = "file")
MMsg :: union { int }

// dock_button: a 48 px dock's row holding one icon-only button, with `mark` set on it.
@(private = "file")
dock_button :: proc(ui: ^Ui(MMsg), mark: Maybe(Button_Mark), disabled := false) -> Node {
	begin_view(ui)
	row(ui, height = 48, padding = .xs, align = .Center)
	b := button(ui, "Files", MMsg(1), variant = .Ghost, icon = .Check, icon_only = true, disabled = disabled)
	if m, ok := mark.?; ok do button_options(ui, b, mark = m)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {200, 48})
	return b
}

// mark_drawn: the rounded bar `thick` px across drawn inside button `b`, if any.
@(private = "file")
mark_drawn :: proc(ui: ^Ui(MMsg), b: Node, thick: f32 = BUTTON_MARK_THICKNESS) -> (rect: Rect, color: Color, ok: bool) {
	bd := node_get(&ui.tree, b)
	for c in draw_list(&ui.tree) {
		r, is_rect := c.(Draw_Rect)
		if !is_rect || r.radius != thick / 2 || (r.rect.h != thick && r.rect.w != thick) do continue
		if r.rect.x >= bd.abs.x && r.rect.y >= bd.abs.y && r.rect.x + r.rect.w <= bd.abs.x + bd.abs.w && r.rect.y + r.rect.h <= bd.abs.y + bd.abs.h {
			return r.rect, r.color, true
		}
	}
	return
}

// A mark takes no room: the button lays out as it did, and the mark sits
// inside its bottom edge, centred, in the button's content colour, shown as
// it is on its first paint.
@(test)
a_button_mark_takes_no_room :: proc(t: ^testing.T) {
	ui: Ui(MMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	b := dock_button(&ui, nil)
	before := node_get(&ui.tree, b).abs
	_, _, drawn := mark_drawn(&ui, b)
	testing.expect(t, !drawn, "no mark until one is set")

	b = dock_button(&ui, Button_Mark{side = .Bottom, length = 6})
	bd := node_get(&ui.tree, b)
	testing.expect_value(t, bd.abs, before) // no room taken
	r, c, ok := mark_drawn(&ui, b)
	testing.expect(t, ok, "the running dot is drawn")
	testing.expect_value(t, r, Rect{before.x + (before.w - 6) / 2, before.y + before.h - BUTTON_MARK_THICKNESS, 6, BUTTON_MARK_THICKNESS})
	testing.expect_value(t, c, bd.style.fg) // the content colour: Ghost's primary
	testing.expect_value(t, c, ui.tree.theme.color.primary)
}

// A change of length or colour eases over motion.fast (the app came to the
// front: a longer bar in another colour); under reduce motion it is at once.
// Down a side bar the mark runs along the edge, and length 0 shrinks it away.
@(test)
a_button_mark_changes_smoothly :: proc(t: ^testing.T) {
	ui: Ui(MMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	b := dock_button(&ui, Button_Mark{side = .Bottom, length = 6})
	bd := node_get(&ui.tree, b)
	fast := f64(ui.tree.theme.motion.fast)
	accent := Color{0.9, 0.3, 0.1, 1}

	ui_tick(&ui, 1000)
	b = dock_button(&ui, Button_Mark{side = .Bottom, length = 16, color = accent})
	r, _, _ := mark_drawn(&ui, b)
	testing.expect_value(t, r.w, 6) // the change starts from where it was
	ui_tick(&ui, 1000 + fast / 2)
	frame(&ui.tree, {200, 48})
	r, _, _ = mark_drawn(&ui, b)
	testing.expectf(t, r.w > 6 && r.w < 16, "half way, between the dot and the bar: %v", r.w)
	ui_tick(&ui, 1000 + fast + 20)
	frame(&ui.tree, {200, 48})
	c: Color
	r, c, _ = mark_drawn(&ui, b)
	testing.expect_value(t, r, Rect{bd.abs.x + (bd.abs.w - 16) / 2, bd.abs.y + bd.abs.h - BUTTON_MARK_THICKNESS, 16, BUTTON_MARK_THICKNESS})
	testing.expect_value(t, c, accent)

	ui.tree.theme.motion.reduce = true
	b = dock_button(&ui, Button_Mark{side = .Left, length = 10, thickness = 2})
	r, _, _ = mark_drawn(&ui, b, 2)
	testing.expect_value(t, r, Rect{bd.abs.x, bd.abs.y + (bd.abs.h - 10) / 2, 2, 10}) // reduce motion: at once, down the left edge
	b = dock_button(&ui, Button_Mark{side = .Right, length = 0, thickness = 2})
	_, _, drawn := mark_drawn(&ui, b, 2)
	testing.expect(t, !drawn, "length 0: no mark (a pinned app that isn't running)")
}

// A disabled button dims its mark with the rest of it.
@(test)
a_disabled_buttons_mark_dims :: proc(t: ^testing.T) {
	ui: Ui(MMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	b := dock_button(&ui, Button_Mark{side = .Bottom, length = 6, color = {0, 0, 0, 1}}, disabled = true)
	_, c, ok := mark_drawn(&ui, b)
	testing.expect(t, ok)
	testing.expect_value(t, c.a, ui.tree.theme.state.disabled_alpha)
}

// A mark that counts, so two windows of one app do not look like one:
// `count` splits the mark into that many short marks in the same place.
@(test)
a_mark_counts :: proc(t: ^testing.T) {
	ui: Ui(MMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	marks :: proc(ui: ^Ui(MMsg), b: Node) -> [dynamic]Rect {
		out := make([dynamic]Rect, context.temp_allocator)
		bd := node_get(&ui.tree, b)
		for c in draw_list(&ui.tree) {
			r, is_rect := c.(Draw_Rect)
			if !is_rect || r.radius != BUTTON_MARK_THICKNESS / 2 || r.rect.h != BUTTON_MARK_THICKNESS do continue
			if r.rect.x >= bd.abs.x && r.rect.x + r.rect.w <= bd.abs.x + bd.abs.w do append(&out, r.rect)
		}
		return out
	}

	b := dock_button(&ui, Button_Mark{side = .Bottom, length = 16})
	one := marks(&ui, b)
	testing.expect_value(t, len(one), 1) // the single mark: count 0 is one

	b = dock_button(&ui, Button_Mark{side = .Bottom, length = 16, count = 3})
	three := marks(&ui, b)
	testing.expect_value(t, len(three), 3)
	if len(three) == 3 {
		// in a row along the bottom edge, one gap apart, each shorter than the one mark was
		for i in 1 ..< 3 do testing.expect(t, three[i].x > three[i - 1].x + three[i - 1].w, "a gap between them")
		testing.expect(t, three[0].w < one[0].w, "each is short")
		testing.expect(t, three[0].y == one[0].y, "on the same edge as the single mark")
		// centred where the single mark was
		mid_one := one[0].x + one[0].w / 2
		mid_three := (three[0].x + three[2].x + three[2].w) / 2
		testing.expect(t, abs(mid_one - mid_three) < 0.5, "centred where it was")
	}

	// a mark too short to split still shows each as a dot rather than nothing
	b = dock_button(&ui, Button_Mark{side = .Bottom, length = 4, count = 3})
	dots := marks(&ui, b)
	testing.expect_value(t, len(dots), 3)
	for d in dots do testing.expect(t, d.w >= BUTTON_MARK_THICKNESS, "no pip thinner than it is thick")
}

} // when ODIN_TEST