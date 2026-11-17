package baldr

@(require) import "core:fmt"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
list_view :: proc(ui: ^Ui(Test_Msg), n_items: int, height: f32 = 100) -> (sc: Node, items: []Node) {
	items = make([]Node, n_items, context.temp_allocator)
	begin_view(ui)
	sc = scroll(ui, height = height, width = 200)
	for i in 0 ..< n_items do items[i] = box(ui, height = 30, bg = {0.5, 0.5, 0.5, 1})
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 300})
	return
}

@(test)
scroll_content_overflows_and_offset_shifts_children :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sc, items := list_view(&ui, 10)
	st := ui.scrolls[sc]
	testing.expect_value(t, st.content.y, f32(300))
	testing.expect_value(t, st.viewport.y, f32(100))
	testing.expect(t, node_get(&ui.tree, sc).abs.h == 100, "the container keeps its own height")
	testing.expect_value(t, node_get(&ui.tree, items[0]).abs.y, f32(0))
	testing.expect_value(t, node_get(&ui.tree, items[4]).abs.y, f32(120))

	testing.expect(t, scroll_by(&ui.tree, sc, {0, 50}))
	frame(&ui.tree, {400, 300})
	testing.expect_value(t, node_get(&ui.tree, items[0]).abs.y, f32(-50))
	testing.expect_value(t, node_get(&ui.tree, items[4]).abs.y, f32(70))

	scroll_by(&ui.tree, sc, {0, 10_000}) // clamps to content - viewport = 200
	frame(&ui.tree, {400, 300})
	testing.expect_value(t, scroll_offset(&ui.tree, sc).y, f32(200))
	testing.expect_value(t, node_get(&ui.tree, items[9]).abs.y, f32(70))
	testing.expect(t, !scroll_by(&ui.tree, sc, {0, 5}), "already at the end: no move")
	scroll_by(&ui.tree, sc, {0, -10_000})
	testing.expect_value(t, scroll_offset(&ui.tree, sc).y, f32(0))
}

@(test)
scroll_event_targets_innermost_and_bubbles_at_the_edge :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	outer := scroll(&ui, height = 100, width = 300)
	box(&ui, height = 40)
	inner := scroll(&ui, height = 50, width = 300)
	for _ in 0 ..< 5 do box(&ui, height = 30)
	end(&ui)
	box(&ui, height = 200)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 300})

	// pointer over the inner list (y = 40..90): inner scrolls first
	testing.expect(t, scroll_event(&ui, {150, 60}, {0, 20}))
	testing.expect_value(t, scroll_offset(&ui.tree, inner).y, f32(20))
	testing.expect_value(t, scroll_offset(&ui.tree, outer).y, f32(0))
	// inner at its end (content 150, viewport 50 → max 100): the rest bubbles out
	scroll_event(&ui, {150, 60}, {0, 500})
	testing.expect_value(t, scroll_offset(&ui.tree, inner).y, f32(100))
	frame(&ui.tree, {400, 300})
	testing.expect(t, scroll_event(&ui, {150, 60}, {0, 10}), "bubbles to the outer container")
	testing.expect_value(t, scroll_offset(&ui.tree, outer).y, f32(10))
	// nothing scrollable under the pointer
	testing.expect(t, !scroll_event(&ui, {350, 250}, {0, 10}))
}

@(test)
scroll_culls_offscreen_children_and_clips_damage :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sc, items := list_view(&ui, 20)
	take_damage(&ui.tree)
	ui.stats = {}
	scroll_by(&ui.tree, sc, {0, 30})
	frame(&ui.tree, {400, 300})
	// Only the scroll layer rebuilt; damage stays inside the viewport.
	testing.expect_value(t, ui.stats.layers_rebuilt, 1)
	db := damage_bounds(take_damage(&ui.tree))
	vp := node_get(&ui.tree, sc).abs
	testing.expect(t, db.y >= vp.y - 0.01 && db.y + db.h <= vp.y + vp.h + 0.01, "damage clipped to the viewport")
	// Draw list: clip push/pop, visible rows only (rows 1..4 visible for offset 30, viewport 100)
	rects := 0
	for c in draw_list(&ui.tree) {
		if r, ok := c.(Draw_Rect); ok && r.rect.h == 30 do rects += 1
	}
	testing.expect(t, rects >= 4 && rects <= 5, "only visible rows are emitted")
	// A scrolled-out row is not hit; a visible one is.
	testing.expect(t, hit_test(&ui.tree, {100, 10}) != items[0], "row 0 scrolled out")
	testing.expect_value(t, hit_test(&ui.tree, {100, 10}), items[1])
}

@(test)
scrollbar_appears_on_activity_and_drags :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sc, _ := list_view(&ui, 10)
	track, thumb, ok := scrollbar_geometry(&ui.tree, sc)
	testing.expect(t, ok)
	testing.expect_value(t, track.h, f32(100 - 2 * SCROLLBAR_MARGIN))
	testing.expect_value(t, thumb.h, track.h / 3) // viewport/content = 1/3
	testing.expect_value(t, thumb.y, track.y)

	// Idle: no scrollbar drawn. After scrolling: visible.
	count_bars :: proc(t: ^Tree) -> (n: int) {
		for c in draw_list(t) {
			if r, ok := c.(Draw_Rect); ok && r.rect.w == SCROLLBAR_W do n += 1
		}
		return
	}
	anim_tick(&ui.tree, 5000)
	frame(&ui.tree, {400, 300})
	testing.expect_value(t, count_bars(&ui.tree), 0)
	scroll_by(&ui.tree, sc, {0, 100})      // activity at t = 5000
	frame(&ui.tree, {400, 300})            // starts the fade-in tween
	anim_tick(&ui.tree, 5300)              // fade-in (motion.base = 200 ms) complete, still within the linger window
	frame(&ui.tree, {400, 300})
	testing.expect_value(t, count_bars(&ui.tree), 2) // track + thumb
	testing.expect(t, ui.wake_at_ms > 0, "a wake-up is scheduled for the fade-out")
	// Past the linger window the bar fades out again.
	anim_tick(&ui.tree, 5000 + SCROLLBAR_LINGER_MS + 1)
	frame(&ui.tree, {400, 300})            // starts the fade-out
	anim_tick(&ui.tree, 5000 + SCROLLBAR_LINGER_MS + 1000)
	frame(&ui.tree, {400, 300})
	testing.expect_value(t, count_bars(&ui.tree), 0)

	// Drag the thumb down by half the travel: offset moves half the range.
	_, thumb, _ = scrollbar_geometry(&ui.tree, sc)
	start := [2]f32{thumb.x + 2, thumb.y + 2}
	testing.expect(t, pointer_button(&ui, .Left, true, start))
	testing.expect_value(t, ui.pointer.scroll_drag, sc)
	travel := track.h - thumb.h
	pointer_move(&ui, start + {0, travel / 4})
	frame(&ui.tree, {400, 300})
	testing.expect(t, abs(scroll_offset(&ui.tree, sc).y - 150) < 1, "a quarter of the travel = a quarter of the range (offset 100 → 150)")
	pointer_move(&ui, start + {0, travel})
	testing.expect_value(t, scroll_offset(&ui.tree, sc).y, f32(200)) // clamped at the end
	pointer_button(&ui, .Left, false, start + {0, travel})
	testing.expect_value(t, ui.pointer.scroll_drag, NODE_NONE)
	testing.expect(t, len(ui.msgs) == 0, "dragging the bar never clicks anything")
}

// A scroll with no height takes its content's height up to max_height and
// scrolls past it: two rows are exactly as tall as they are,
// a third grows it, and ten stop it at the maximum, where it scrolls and
// focus still brings a row into view. In a popover laid out on a surface of
// its own, with no height to give, it stops at the maximum too.
@(test)
scroll_takes_its_contents_height_up_to_a_maximum :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.motion.reduce = true
	view :: proc(ui: ^Ui(Test_Msg), rows: int) -> (sc, after: Node, items: []Node) {
		items = make([]Node, rows, context.temp_allocator)
		begin_view(ui)
		sc = scroll(ui, max_height = 100)
		for i in 0 ..< rows {
			items[i] = button(ui, fmt.tprintf("Network %d", i), Test_Msg.Inc, key = u64(i + 1))
			set_layout(&ui.tree, items[i], Layout_Props{height = 30})
		}
		end(ui)
		after = box(ui, height = 10)
		end_view(ui)
		frame(&ui.tree, {400, 300})
		return
	}
	sc, after, _ := view(&ui, 2)
	testing.expect_value(t, node_get(&ui.tree, sc).abs.h, 60) // as tall as its two rows
	testing.expect_value(t, node_get(&ui.tree, after).abs.y, 60)
	sc, after, _ = view(&ui, 3)
	testing.expect_value(t, node_get(&ui.tree, sc).abs.h, 90) // a third row grows it
	testing.expect_value(t, node_get(&ui.tree, after).abs.y, 90)

	items: []Node
	sc, after, items = view(&ui, 10)
	st := ui.tree.scrolls[sc]
	testing.expect(t, node_get(&ui.tree, sc).abs.h == 100 && st.content.y == 300 && st.viewport.y == 100, "ten rows: it stops at the maximum")
	testing.expect_value(t, node_get(&ui.tree, after).abs.y, 100)
	testing.expect(t, scroll_by(&ui.tree, sc, {0, 50}), "and scrolls")
	scroll_by(&ui.tree, sc, {0, -50})
	set_focus(&ui.tree, items[9], true)
	for i in 0 ..< 40 {
		ui_tick(&ui, f64(i) * 16)
		frame(&ui.tree, {400, 300})
	}
	rd, sd := node_get(&ui.tree, items[9]), node_get(&ui.tree, sc)
	testing.expect(t, scroll_offset(&ui.tree, sc).y > 0 && rd.abs.y >= sd.abs.y - 0.5 && rd.abs.y + rd.abs.h <= sd.abs.y + sd.abs.h + 0.5, "focus scrolls the last row into view")

	pui: Ui(Test_Msg)
	ui_init(&pui)
	defer ui_destroy(&pui)
	pui.tree.popups_on = true // the popover is laid out free of the window's bounds, as on a popup surface
	begin_view(&pui)
	row(&pui, align = .Center)
	wifi := button(&pui, "Wi-Fi", Test_Msg.Toggle)
	end(&pui)
	list: Node
	if popover(&pui, wifi, true, Test_Msg.Dec) {
		list = scroll(&pui, max_height = 100)
		for i in 0 ..< 12 {
			b := button(&pui, fmt.tprintf("Network %d", i), Test_Msg.Inc, key = u64(i + 1))
			set_layout(&pui.tree, b, Layout_Props{height = 30})
		}
		end(&pui)
		end(&pui)
	}
	end_view(&pui)
	frame(&pui.tree, {400, 60})
	testing.expect_value(t, node_get(&pui.tree, list).abs.h, 100) // twelve rows, and nothing above it to give a height
}

} // when ODIN_TEST