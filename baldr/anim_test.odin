package baldr

@(require) import "core:testing"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
button_bg :: proc(t: ^Tree, n: Node) -> (Color, bool) {
	r := node_get(t, n).abs
	for c in draw_list(t) {
		if q, ok := c.(Draw_Rect); ok && q.rect == r do return q.color, true
	}
	return {}, false
}

@(test)
anim_hover_eases_over_motion_fast :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	b := button(&ui, "Go", Test_Msg.Inc)
	end_view(&ui)
	frame(&ui.tree, {200, 100})
	anim_tick(&ui.tree, 1000)
	base, _ := button_bg(&ui.tree, b)
	th := ui.theme
	full := mix(base, th.color.on_surface, th.state.hover)

	r := node_get(&ui.tree, b).abs
	pointer_move(&ui, {r.x + 2, r.y + 2})
	frame(&ui.tree, {200, 100}) // tween starts now (t = 1000)
	c0, _ := button_bg(&ui.tree, b)
	testing.expect_value(t, c0, base) // nothing has moved yet
	testing.expect(t, ui.anim_active, "a tween is running")

	testing.expect(t, anim_tick(&ui.tree, 1000 + f64(th.motion.fast) * 0.5), "still active half way")
	frame(&ui.tree, {200, 100})
	mid, _ := button_bg(&ui.tree, b)
	testing.expect(t, mid != base && mid != full, "half way: between rest and hover")
	testing.expect(t, mid.r > min(base.r, full.r) && mid.r < max(base.r, full.r))

	testing.expect(t, !anim_tick(&ui.tree, 1000 + f64(th.motion.fast) + 1), "done after motion.fast")
	frame(&ui.tree, {200, 100})
	end, _ := button_bg(&ui.tree, b)
	testing.expect_value(t, end, full)

	// Leaving eases back; a second frame at the same instant is not dirty again.
	pointer_leave(&ui)
	frame(&ui.tree, {200, 100})
	testing.expect(t, ui.anim_active)
	anim_tick(&ui.tree, 5000)
	frame(&ui.tree, {200, 100})
	back, _ := button_bg(&ui.tree, b)
	testing.expect_value(t, back, base)
	ui.stats = {}
	anim_tick(&ui.tree, 5001)
	frame(&ui.tree, {200, 100})
	testing.expect_value(t, ui.stats.layers_rebuilt, 0) // at rest: no repaint
}

@(test)
anim_reduce_motion_is_instant :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.theme.motion.reduce = true
	begin_view(&ui)
	b := button(&ui, "Go", Test_Msg.Inc)
	end_view(&ui)
	frame(&ui.tree, {200, 100})
	base, _ := button_bg(&ui.tree, b)
	r := node_get(&ui.tree, b).abs
	pointer_move(&ui, {r.x + 2, r.y + 2})
	frame(&ui.tree, {200, 100})
	now, _ := button_bg(&ui.tree, b)
	testing.expect_value(t, now, mix(base, ui.theme.color.on_surface, ui.theme.state.hover))
	testing.expect(t, !ui.anim_active, "nothing to tick")
}

@(test)
anim_state_is_dropped_with_the_node :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	b := button(&ui, "Go", Test_Msg.Inc)
	end_view(&ui)
	frame(&ui.tree, {200, 100})
	testing.expect(t, b in ui.anims)
	begin_view(&ui)
	end_view(&ui)
	testing.expect(t, b not_in ui.anims)
	anim_tick(&ui.tree, 1) // must not choke on nothing
}

} // when ODIN_TEST