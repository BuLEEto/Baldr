package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
toast_view :: proc(ui: ^Ui(Test_Msg), show: bool) -> Node {
	begin_view(ui)
	column(ui)
	text(ui, "content")
	n: Node
	if show {
		n = card(ui, key = 99)
		transition(ui, n, .Fade_Up, .Fade)
		text(ui, "Saved")
		end(ui)
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {300, 300})
	return n
}

@(private = "file")
card_alpha :: proc(t: ^Tree, n: Node) -> (a: f32, found: bool) {
	d := node_get(t, n)
	if d == nil do return 0, false
	for c in draw_list(t) {
		if r, ok := c.(Draw_Rect); ok && r.rect.w == d.abs.w && r.rect.h == d.abs.h && r.color.a > 0 do return r.color.a, true
	}
	return 0, false
}

@(test)
transition_enter_fades_in :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui_tick(&ui, 1000)
	n := toast_view(&ui, true)
	a0, found := card_alpha(&ui.tree, n)
	testing.expect(t, !found || a0 < 0.05, "first frame: (almost) invisible")
	testing.expect(t, ui.anim_active)
	ui_tick(&ui, 1000 + f64(ui.theme.motion.base) / 2)
	frame(&ui.tree, {300, 300})
	mid, _ := card_alpha(&ui.tree, n)
	testing.expect(t, mid > 0.2 && mid < 0.99, "half way through the fade")
	ui_tick(&ui, 5000)
	frame(&ui.tree, {300, 300})
	full, _ := card_alpha(&ui.tree, n)
	testing.expect_value(t, full, ui.theme.color.surface.a)
}

@(test)
transition_exit_keeps_node_until_faded_then_destroys :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui_tick(&ui, 1000)
	n := toast_view(&ui, true)
	ui_tick(&ui, 5000)
	frame(&ui.tree, {300, 300})

	toast_view(&ui, false) // not emitted → starts exiting, still in the tree
	testing.expect(t, node_valid(&ui.tree, n), "still alive while fading")
	testing.expect(t, .Exiting in node_get(&ui.tree, n).flags)
	testing.expect_value(t, len(ui.exiting), 1)
	testing.expect(t, hit_test(&ui.tree, {node_get(&ui.tree, n).abs.x + 2, node_get(&ui.tree, n).abs.y + 2}) != n, "exiting node is not hit-testable")
	ui_tick(&ui, 5000 + f64(ui.theme.motion.base) / 2)
	frame(&ui.tree, {300, 300})
	mid, found := card_alpha(&ui.tree, n)
	testing.expect(t, found && mid < ui.theme.color.surface.a, "fading out")

	ui_tick(&ui, 9000) // fade done → swept
	testing.expect(t, !node_valid(&ui.tree, n), "destroyed after the exit")
	testing.expect_value(t, len(ui.exiting), 0)
	frame(&ui.tree, {300, 300})
	testing.expect_value(t, node_child_count(&ui.tree, node_first(&ui.tree, ui.root)), 1)
}

@(test)
transition_reappearing_node_is_resurrected :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui_tick(&ui, 1000)
	n := toast_view(&ui, true)
	ui_tick(&ui, 5000)
	toast_view(&ui, false)
	testing.expect(t, .Exiting in node_get(&ui.tree, n).flags)
	n2 := toast_view(&ui, true)
	testing.expect_value(t, n2, n)
	testing.expect(t, .Exiting not_in node_get(&ui.tree, n).flags)
	ui_tick(&ui, 9000)
	testing.expect(t, node_valid(&ui.tree, n))
}

@(test)
transition_reduce_motion_is_instant :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.theme.motion.reduce = true
	n := toast_view(&ui, true)
	a, _ := card_alpha(&ui.tree, n)
	testing.expect_value(t, a, ui.theme.color.surface.a)
	toast_view(&ui, false)
	testing.expect(t, !node_valid(&ui.tree, n), "removed immediately")
}

} // when ODIN_TEST
// --- Fade_Scale: a popover grows out of what opened it (menus/popovers).

@(private = "file")
Pop_Msg :: union { int }

// pop_text_size is the size of the first item's glyphs as drawn.
@(private = "file")
pop_text_size :: proc(tr: ^Tree) -> (size: f32, found: bool) {
	for c in draw_list(tr) {
		if v, ok := c.(Draw_Text); ok && v.str == "Item one" do return v.size, true
	}
	return
}

// pop_card_rect is the rect a popover's own fill or glass is drawn at, which
// is what its Fade_Scale transforms — not its layout rect, which never moves.
@(private = "file")
pop_card_rect :: proc(tr: ^Tree, want: Rect) -> (out: Rect, found: bool) {
	near :: proc(a, r: Rect) -> bool {
		return abs((a.x + a.w / 2) - (r.x + r.w / 2)) < 16 && abs((a.y + a.h / 2) - (r.y + r.h / 2)) < 16 &&
			a.w > r.w * 0.8 && a.w <= r.w + 0.5
	}
	for c in draw_list(tr) {
		#partial switch v in c {
		case Draw_Rect:     if v.radius > 0 && near(v.rect, want) { out, found = v.rect, true }
		case Draw_Backdrop: if near(v.rect, want) { out, found = v.rect, true }
		}
	}
	return
}

@(private = "file")
pop_build :: proc(ui: ^Ui(Pop_Msg), open: bool) -> (card: Node) {
	begin_view(ui)
	column(ui, padding = .lg)
	anchor := button(ui, "Open", Pop_Msg(1))
	end(ui)
	if popover(ui, anchor, open, Pop_Msg(2)) {
		card = ui.scopes[len(ui.scopes) - 1].node
		for label in ([6]string{"Item one", "Item two", "Item three", "Item four", "Item five", "Item six"}) {
			text(ui, label)
		}
		end(ui)
	}
	end_view(ui)
	frame(&ui.tree, {600, 400})
	return
}

// A popover is drawn smaller than its layout rect while it is arriving, and
// exactly at it once it has settled — the "pop" of macOS's menus. The
// *layout* rect never moves: a scale that changed layout
// would reflow the items it holds as it grew.
@(test)
a_popover_grows_into_place_and_settles_exactly :: proc(t: ^testing.T) {
	ui: Ui(Pop_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	card := pop_build(&ui, true)
	laid := node_get(&ui.tree, card).abs

	// Part-way in, not on the first frame: at progress 0 the card is still
	// fully transparent, so there is nothing drawn to measure.
	ui_tick(&ui, f64(POPOVER_ENTER_MS) * 0.2)
	_ = pop_build(&ui, true)
	early, got_early := pop_card_rect(&ui.tree, laid)
	testing.expect(t, got_early, "the popover's card is drawn as it arrives")
	// Measured as ratios, not in px: a menu is a few tens of px tall and 4%
	// of that is under half a pixel, so an absolute tolerance would say
	// "not scaling" for a card that plainly is.
	sw, sh := early.w / laid.w, early.h / laid.h
	testing.expectf(t, sw < 0.999 && sh < 0.999, "arriving: drawn smaller than its layout rect (%v vs %v)", early, laid)
	testing.expectf(t, sw > TRANSITION_SCALE - 0.001, "arriving: a pop, not a zoom (×%.4f)", sw)
	testing.expectf(t, abs(sw - sh) < 0.005, "arriving: scaled evenly (w ×%.4f, h ×%.4f)", sw, sh)

	// It grows out of the point nearest its anchor. Below a button that is
	// its own top edge, so the top stays put and the whole of the shrinkage
	// is taken off the bottom — which is what makes it read as coming *out
	// of* the button rather than swelling in mid-air. Asserted on both
	// edges: with only the top checked, growing from the centre passes,
	// because on a short menu that is a third of a pixel.
	testing.expectf(t, abs(early.y - laid.y) < 0.5,
		"arriving: its top edge is the origin, so it stays put (%v vs %v)", early.y, laid.y)
	lost := laid.h - early.h
	testing.expectf(t, abs((laid.y + laid.h) - (early.y + early.h) - lost) < 0.5,
		"arriving: all of the shrinkage is off the bottom (%.3f of %.3f)",
		(laid.y + laid.h) - (early.y + early.h), lost)
	testing.expectf(t, lost > 1, "arriving: tall enough for the origin to be measurable (%.3f px)", lost)

	// The glyphs keep their resting size the whole way, on purpose: scaling
	// `size` would rasterise every glyph afresh at each intermediate size —
	// a menu's worth of atlas entries per frame, and visible snapping as
	// hinting rounds differently — to correct 0.6 px on 15 px text that is
	// gone by the last frame.
	early_size, got_size := pop_text_size(&ui.tree)
	testing.expect(t, got_size, "arriving: its items are drawn")

	ui_tick(&ui, f64(POPOVER_ENTER_MS) + 50)
	_ = pop_build(&ui, true)
	settled_size, _ := pop_text_size(&ui.tree)
	testing.expectf(t, early_size == settled_size,
		"the glyphs are never rasterised at an in-between size (%.3f arriving vs %.3f settled)",
		early_size, settled_size)
	
	settled, got := pop_card_rect(&ui.tree, laid)
	testing.expect(t, got, "the popover's card is drawn once settled")
	// Exactly, not nearly: the host layer carries the scale and `paint`
	// walks layers in map order, so a host painted before its child must
	// still not keep a 0.96 scale once at rest.
	testing.expectf(t, settled == laid, "settled: drawn exactly at its layout rect (%v vs %v)", settled, laid)
}

// Reduce-motion means no scale at any point, not a faster one: a popover is
// simply there, at its real size, on the first frame.
@(test)
a_popover_does_not_scale_under_reduce_motion :: proc(t: ^testing.T) {
	ui: Ui(Pop_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.motion.reduce = true
	card := pop_build(&ui, true)
	laid := node_get(&ui.tree, card).abs
	first, got := pop_card_rect(&ui.tree, laid)
	testing.expect(t, got, "the popover's card is drawn")
	testing.expectf(t, first == laid, "reduce-motion: at its real size from the first frame (%v vs %v)", first, laid)
}
