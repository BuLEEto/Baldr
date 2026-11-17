package baldr

@(require) import "core:testing"
@(require) import "core:fmt"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
touch_view :: proc(ui: ^Ui(Ov_Msg)) -> (btn, sc, sl: Node) {
	begin_view(ui)
	column(ui, padding = .lg, gap = .md)
	btn = button(ui, "Tap me", Ov_Msg{kind = .Delete})
	sl = slider(ui, 0.5, label = "Volume", on_change = proc(e: Ev(f32)) -> Ov_Msg { return {kind = .Pick, i = int(e.value * 100)} }, width = 200)
	sc = scroll(ui, height = 100, key = 9)
	for i in 0 ..< 20 {
		b := button(ui, fmt.tprintf("row %d", i), Ov_Msg{}, key = u64(i + 1))
		set_layout(&ui.tree, b, Layout_Props{height = 30})
	}
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 500})
	return
}

@(test)
touch_tap_clicks_and_leaves_no_hover :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	btn, _, _ := touch_view(&ui)
	r := node_get(&ui.tree, btn).abs
	p := [2]f32{r.x + 5, r.y + 5}
	touch_down(&ui, 0, p, 1000)
	touch_move(&ui, 0, p + {3, 2}, 1020) // jitter under the slop
	testing.expect_value(t, len(ui.msgs), 0)
	touch_up(&ui, 0, 1100)
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0].kind, Ov_Kind.Delete)
	testing.expect_value(t, ui.pointer.hover, NODE_NONE)
	testing.expect(t, .Hovered not_in node_get(&ui.tree, btn).flags, "no sticky hover after a tap")
}

@(test)
touch_pan_scrolls_and_flings :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	_, sc, _ := touch_view(&ui)
	r := node_get(&ui.tree, sc).abs
	p := [2]f32{r.x + 50, r.y + 80}
	ui_tick(&ui, 1000)
	touch_down(&ui, 0, p, 1000)
	touch_move(&ui, 0, p - {0, 20}, 1016) // past the slop: pan by the full offset
	testing.expect_value(t, scroll_offset(&ui.tree, sc).y, 20)
	touch_move(&ui, 0, p - {0, 40}, 1032)
	testing.expect_value(t, scroll_offset(&ui.tree, sc).y, 40)
	testing.expect_value(t, len(ui.msgs), 0) // no row was tapped
	touch_up(&ui, 0, 1040)
	st := ui.tree.scrolls[sc]
	testing.expect(t, st.fling && st.velocity.y > 0, "fling continues downward")
	off := scroll_offset(&ui.tree, sc).y
	ui_tick(&ui, 1100)
	testing.expect(t, scroll_offset(&ui.tree, sc).y > off, "fling moved the content")
	for ms := 1116.0; ms < 4000; ms += 16 do ui_tick(&ui, ms) // frames at 60 Hz
	testing.expect(t, !ui.tree.scrolls[sc].fling, "fling stopped")
	testing.expect(t, scroll_offset(&ui.tree, sc).y <= 20 * 30 - 100 + 0.5, "clamped to the content")
}

@(test)
touch_horizontal_drag_drives_a_slider :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	_, _, sl := touch_view(&ui)
	r := node_get(&ui.tree, sl).abs
	p := [2]f32{r.x + r.w / 2, r.y + r.h / 2}
	touch_down(&ui, 0, p, 1000)
	touch_move(&ui, 0, p + {40, 2}, 1016)
	testing.expect(t, len(ui.msgs) >= 1, "slider sent a value")
	testing.expect(t, ui.msgs[len(ui.msgs) - 1].i > 50, "moved right")
	touch_up(&ui, 0, 1100)
	testing.expect(t, !ui.tree.sliders[sl].dragging)
	testing.expect_value(t, ui.pointer.slider_drag, NODE_NONE)
}

@(test)
touch_targets_grow_when_a_touchscreen_is_present :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	btn, _, _ := touch_view(&ui)
	small := node_get(&ui.tree, btn).abs.h
	testing.expect(t, small < TOUCH_TARGET, "desktop button is compact")
	set_touch(&ui.tree, true)
	frame(&ui.tree, {400, 500})
	testing.expect_value(t, node_get(&ui.tree, btn).abs.h, TOUCH_TARGET)
	txt := node_first(&ui.tree, btn)
	testing.expect(t, node_get(&ui.tree, txt).abs.h < TOUCH_TARGET, "only interactive nodes grow")
}

@(test)
tab_bar_scrolls_itself_and_reveals_the_selection :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	labels := []string{"Overview", "Controls", "Inputs", "Overlays", "Lists", "Motion", "Settings", "About"}
	build :: proc(ui: ^Ui(Ov_Msg), labels: []string, sel: int) -> Node {
		begin_view(ui)
		column(ui)
		bar := tab_bar(ui, sel, labels, proc(e: Ev(int)) -> Ov_Msg { return {kind = .Pick, i = e.value} })
		end(ui)
		end_view(ui)
		frame(&ui.tree, {300, 200})
		return bar
	}
	bar := build(&ui, labels, 0)
	bd := node_get(&ui.tree, bar)
	testing.expect(t, .Scroll_H in bd.flags)
	testing.expect_value(t, bd.abs.w, 300)
	st := ui.tree.scrolls[bar]
	testing.expect(t, st.content.x > 300, "tabs overflow the bar")
	testing.expect_value(t, scroll_offset(&ui.tree, bar).x, 0)
	// A wheel over the strip scrolls it sideways; the right edge fades.
	fades := 0
	for c in draw_list(&ui.tree) do if r, ok := c.(Draw_Rect); ok && r.horizontal do fades += 1
	testing.expect_value(t, fades, 1)
	testing.expect(t, scroll_event(&ui, {150, bd.abs.y + 10}, {0, 48}))
	testing.expect_value(t, scroll_offset(&ui.tree, bar).x, 48)
	frame(&ui.tree, {300, 200})
	fades = 0
	for c in draw_list(&ui.tree) do if r, ok := c.(Draw_Rect); ok && r.horizontal do fades += 1
	testing.expect_value(t, fades, 2)
	// Selecting the last tab (say, by keyboard) brings it into view after layout.
	build(&ui, labels, 7)
	settle(&ui) // the reveal eases into place
	frame(&ui.tree, {300, 200})
	last := node_get(&ui.tree, bar).last
	ld := node_get(&ui.tree, last)
	testing.expect(t, ld.abs.x + ld.abs.w <= bd.abs.x + bd.abs.w + 0.5, "selected tab fully visible")
	testing.expect(t, scroll_offset(&ui.tree, bar).x > 48)
	// A touch pan across the strip scrolls it too.
	p := [2]f32{bd.abs.x + 150, bd.abs.y + 10}
	before := scroll_offset(&ui.tree, bar).x
	touch_down(&ui, 0, p, 2000)
	touch_move(&ui, 0, p + {60, 1}, 2016)
	testing.expect_value(t, scroll_offset(&ui.tree, bar).x, before - 60)
	touch_up(&ui, 0, 2100)
	testing.expect_value(t, len(ui.msgs), 0) // a pan never selects a tab
}

} // when ODIN_TEST