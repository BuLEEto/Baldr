package baldr

@(require) import "core:testing"

// Behind this `when` so a program importing Baldr does not type-check the
// test suite too, which costs gigabytes. ODIN_TEST is set by `odin test`;
// BALDR_TESTS lets ./build.sh check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(test)
easing_curves_end_at_one_and_spring_overshoots :: proc(t: ^testing.T) {
	for e in Easing {
		testing.expect(t, abs(ease(1, e) - 1) < 0.01, "ends at 1")
		testing.expect(t, abs(ease(0, e)) < 0.01, "starts at 0")
	}
	testing.expect(t, ease(0.4, .Spring) > 1.03, "the spring overshoots")
	testing.expect(t, ease(0.5, .Ease_Out) > 0.8, "ease-out is fast early")
	testing.expect(t, abs(ease(0.5, .Ease_In_Out) - 0.5) < 0.01, "in-out is symmetric")
}

@(private = "file")
chips :: proc(ui: ^Ui(Ov_Msg), order: []int) -> (col: Node, items: [3]Node) {
	set_viewport(&ui.tree, {300, 300})
	begin_view(ui)
	col = column(ui, animate = true)
	for i in order {
		items[i] = box(ui, height = 20, key = u64(i + 1))
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {300, 300})
	return
}

@(private = "file")
rect_of :: proc(ui: ^Ui(Ov_Msg), n: Node) -> Rect {
	d := node_get(&ui.tree, n)
	for c in draw_list(&ui.tree) do if r, ok := c.(Draw_Rect); ok && r.rect.w == d.abs.w && r.rect.h == d.abs.h && r.color == d.style.bg do return r.rect
	return {}
}

@(test)
animated_moves_glide_nodes_between_layouts :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui_tick(&ui, 1000)
	_, items := chips(&ui, {0, 1, 2})
	// paint the boxes so they can be found in the draw list
	for it in items do set_style(&ui.tree, it, Style{bg = rgb(0x336699)})
	frame(&ui.tree, {300, 300})
	testing.expect_value(t, node_get(&ui.tree, items[2]).abs.y, 40)
	// reorder: box 2 moves from y = 40 to y = 0
	_, items2 := chips(&ui, {2, 0, 1})
	for it in items2 do set_style(&ui.tree, it, Style{bg = rgb(0x336699)})
	frame(&ui.tree, {300, 300})
	d2 := node_get(&ui.tree, items2[2])
	testing.expect_value(t, d2.abs.y, 0)                 // layout is at the new place at once
	testing.expect_value(t, d2.move_from, [2]f32{0, 40}) // paint starts from the old one
	testing.expect_value(t, anim_value(&ui.tree, items2[2], .Move), 1)
	testing.expect(t, ui.tree.anim_active, "a frame is requested")
	ui_tick(&ui, 1100)
	frame(&ui.tree, {300, 300})
	mid := rect_of(&ui, items2[2])
	testing.expect(t, mid.y > 0 && mid.y < 40, "drawn part way")
	settle(&ui)
	frame(&ui.tree, {300, 300})
	testing.expect_value(t, rect_of(&ui, items2[2]).y, 0)
	testing.expect_value(t, node_get(&ui.tree, items2[2]).move_from, [2]f32{})
	// a window resize never animates
	chips(&ui, {2, 0, 1})
	frame(&ui.tree, {400, 300})
	_, items3 := chips(&ui, {2, 0, 1})
	testing.expect_value(t, node_get(&ui.tree, items3[0]).move_from, [2]f32{})
	// reduce-motion: instant
	th := ui.theme
	th.motion.reduce = true
	set_theme(&ui.tree, th)
	_, items4 := chips(&ui, {0, 1, 2})
	frame(&ui.tree, {400, 300})
	testing.expect_value(t, node_get(&ui.tree, items4[2]).move_from, [2]f32{})
}

@(test)
smooth_scroll_eases_and_input_takes_over :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui_tick(&ui, 1000)
	begin_view(&ui)
	column(&ui)
	sc := scroll(&ui, height = 100)
	for i in 0 ..< 20 {
		b := box(&ui, height = 30, key = u64(i + 1))
		_ = b
	}
	end(&ui)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {300, 300})
	testing.expect(t, scroll_to_smooth(&ui.tree, sc, {0, 300}))
	testing.expect_value(t, scroll_offset(&ui.tree, sc).y, 0) // not yet
	ui_tick(&ui, 1032)
	y1 := scroll_offset(&ui.tree, sc).y
	testing.expect(t, y1 > 0 && y1 < 300, "eased part way")
	ui_tick(&ui, 1064)
	y2 := scroll_offset(&ui.tree, sc).y
	testing.expect(t, y2 > y1, "still moving")
	settle(&ui)
	testing.expect_value(t, scroll_offset(&ui.tree, sc).y, 300)
	testing.expect(t, !ui.tree.scrolls[sc].smooth, "arrived")
	// the wheel cancels a smooth scroll in flight
	scroll_to_smooth(&ui.tree, sc, {0, 0})
	ui_tick(&ui, ui.tree.now_ms + 16)
	sd := node_get(&ui.tree, sc)
	testing.expect(t, scroll_event(&ui, {sd.abs.x + 10, sd.abs.y + 10}, {0, 48}))
	testing.expect(t, !ui.tree.scrolls[sc].smooth, "input took over")
	// reduce-motion: instant
	th := ui.theme
	th.motion.reduce = true
	set_theme(&ui.tree, th)
	scroll_to_smooth(&ui.tree, sc, {0, 0})
	testing.expect_value(t, scroll_offset(&ui.tree, sc).y, 0)
}

@(test)
checkbox_tick_draws_in_and_tab_panels_fade_when_revealed :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui_tick(&ui, 1000)
	build :: proc(ui: ^Ui(Ov_Msg), checked: bool, page: int) -> (cb: Node, panels: [2]Node) {
		set_viewport(&ui.tree, {300, 300})
		begin_view(ui)
		column(ui)
		cb = checkbox(ui, checked, "Tick", nil)
		if tab_panel(ui, page == 0, 1) { panels[0] = ui.scopes[len(ui.scopes) - 1].node; text(ui, "one"); end(ui) }
		if tab_panel(ui, page == 1, 2) { panels[1] = ui.scopes[len(ui.scopes) - 1].node; text(ui, "two"); end(ui) }
		end(ui)
		end_view(ui)
		frame(&ui.tree, {300, 300})
		return
	}
	cb, _ := build(&ui, false, 0)
	ticks :: proc(ui: ^Ui(Ov_Msg)) -> int {
		n := 0
		for c in draw_list(&ui.tree) do if ic, ok := c.(Draw_Icon); ok && ic.icon == .Check do n += 1
		return n
	}
	testing.expect_value(t, ticks(&ui), 0)
	build(&ui, true, 0)
	ui_tick(&ui, 1016)
	frame(&ui.tree, {300, 300})
	ind := node_first(&ui.tree, cb)
	k := anim_value(&ui.tree, ind, .Value)
	testing.expect(t, k > 0 && k < 1, "the tick is drawing in")
	testing.expect_value(t, ticks(&ui), 1)
	settle(&ui)
	testing.expect_value(t, anim_value(&ui.tree, ind, .Value), 1)
	// tab panel: switching back to a parked panel fades it in again
	_, panels := build(&ui, true, 1)
	settle(&ui)
	_, panels = build(&ui, true, 0)
	testing.expect(t, anim_value(&ui.tree, panels[0], .Enter) < 1, "revealed panel starts its fade")
	testing.expect(t, .Revealed not_in node_get(&ui.tree, panels[0]).flags, "the flag is consumed")
	settle(&ui)
	testing.expect_value(t, anim_value(&ui.tree, panels[0], .Enter), 1)
}

// Scrolling is not a move: children of an animating container inside a
// scroll region must not glide after the content when it scrolls, only
// when a rebuild moves them.
@(test)
animated_moves_ignore_scrolling :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {300, 120})
	view :: proc(ui: ^Ui(Test_Msg), order: []int) -> (sc: Node, boxes: [3]Node) {
		begin_view(ui)
		sc = scroll(ui, height = 120)
		column(ui, gap = .sm, animate = true)
		for k, i in order {
			boxes[i] = box(ui, height = 60, key = u64(k + 1))
		}
		end(ui)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {300, 120})
		return
	}
	sc, boxes := view(&ui, {0, 1, 2})
	ui_tick(&ui, 1000)
	frame(&ui.tree, {300, 120})
	scroll_to(&ui.tree, sc, {0, 40})
	frame(&ui.tree, {300, 120})
	for b in boxes {
		testing.expect(t, !anim_running(&ui.tree, b, .Move), "a scroll does not start a glide")
		testing.expect_value(t, node_get(&ui.tree, b).move_from, [2]f32{})
	}
	// a real reorder still glides
	_, boxes2 := view(&ui, {2, 0, 1})
	moved := 0
	for b in boxes2 do if anim_running(&ui.tree, b, .Move) do moved += 1
	testing.expect(t, moved >= 2, "reordered boxes glide")
}

} // when ODIN_TEST