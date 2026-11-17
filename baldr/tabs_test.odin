package baldr

@(require) import "core:testing"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

Tab_Msg :: struct { idx: int }
@(private = "file")
on_tab :: proc(e: Ev(int)) -> Tab_Msg { return {idx = e.value} }

@(private = "file")
tabs_view :: proc(ui: ^Ui(Tab_Msg), sel: int) -> (bar, panel_a, panel_b: Node) {
	begin_view(ui)
	column(ui)
	bar = tab_bar(ui, sel, {"Files", "Search", "Settings"}, on_tab)
	if tab_panel(ui, sel == 0, key = 1) {
		panel_a = ui.scopes[len(ui.scopes) - 1].node
		text(ui, "files here")
		end(ui)
	}
	if tab_panel(ui, sel == 1, key = 2) {
		panel_b = ui.scopes[len(ui.scopes) - 1].node
		text(ui, "search here")
		end(ui)
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 300})
	return
}

@(test)
tabs_click_sends_index_and_indicator_moves :: proc(t: ^testing.T) {
	ui: Ui(Tab_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	bar, _, _ := tabs_view(&ui, 0)
	tabs := make([dynamic]Node, context.temp_allocator)
	for c := node_first(&ui.tree, bar); c != NODE_NONE; c = node_next(&ui.tree, c) do append(&tabs, c)
	testing.expect_value(t, len(tabs), 3)
	testing.expect_value(t, node_get(&ui.tree, bar).access.role, Role.Tab_List)
	testing.expect_value(t, node_get(&ui.tree, tabs[1]).access.role, Role.Tab)
	testing.expect_value(t, node_get(&ui.tree, tabs[1]).access.name, "Search")
	testing.expect(t, .Selected in node_get(&ui.tree, tabs[0]).access.states)

	// Click "Search": message carries index 1.
	r := node_get(&ui.tree, tabs[1]).abs
	p := [2]f32{r.x + r.w / 2, r.y + r.h / 2}
	pointer_button(&ui, .Left, true, p)
	pointer_button(&ui, .Left, false, p)
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0].idx, 1)

	// App applies it: indicator anim moves to the new tab.
	tabs_view(&ui, 1)
	ui_tick(&ui, 5000)
	frame(&ui.tree, {400, 300})
	testing.expect_value(t, anim_value(&ui.tree, tabs[0], .Value), f32(0))
	testing.expect_value(t, anim_value(&ui.tree, tabs[1], .Value), f32(1))
	testing.expect(t, .Selected in node_get(&ui.tree, tabs[1]).access.states)
	testing.expect(t, .Selected not_in node_get(&ui.tree, tabs[0]).access.states)

	// Keyboard: Tab to the third tab, Enter selects it.
	set_focus(&ui.tree, tabs[2], true)
	testing.expect(t, key_event(&ui, .Enter, true, {}))
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1].idx, 2)
}

@(test)
tabs_panels_are_parked_not_destroyed :: proc(t: ^testing.T) {
	ui: Ui(Tab_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	_, a, _ := tabs_view(&ui, 0)
	testing.expect(t, node_valid(&ui.tree, a))
	testing.expect(t, .Hidden not_in node_get(&ui.tree, a).flags)

	_, _, b := tabs_view(&ui, 1)
	testing.expect(t, node_valid(&ui.tree, a), "panel A survives the switch")
	testing.expect(t, .Hidden in node_get(&ui.tree, a).flags, "…parked hidden")
	testing.expect(t, node_valid(&ui.tree, b) && .Hidden not_in node_get(&ui.tree, b).flags)
	testing.expect(t, hit_test(&ui.tree, {50, 100}) != a, "hidden panel is not hit")

	_, a2, _ := tabs_view(&ui, 0)
	testing.expect_value(t, a2, a) // same node comes back
	testing.expect(t, .Hidden not_in node_get(&ui.tree, a).flags)
	testing.expect(t, .Hidden in node_get(&ui.tree, b).flags)
}

// A bar that fit at one width must keep its selected tab in view when the
// window gets narrower: the reveal after a resize is instant.
@(test)
tab_bar_keeps_the_selected_tab_visible_after_a_resize :: proc(t: ^testing.T) {
	ui: Ui(Tab_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {700, 200})
	labels := []string{"Overview", "Controls", "Inputs", "Overlays", "Lists", "Table", "Motion", "Explorer"}
	view :: proc(ui: ^Ui(Tab_Msg), labels: []string, sel: int, w: f32) -> (bar: Node) {
		begin_view(ui)
		column(ui)
		bar = tab_bar(ui, sel, labels, on_tab)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {w, 200})
		return
	}
	bar := view(&ui, labels, 7, 700)
	last := node_get(&ui.tree, bar).last
	visible :: proc(t: ^Tree, bar, tab: Node) -> bool {
		b, d := node_get(t, bar).abs, node_get(t, tab).abs
		return d.x >= b.x && d.x + d.w <= b.x + b.w
	}
	testing.expect(t, visible(&ui.tree, bar, last), "wide enough: every tab fits")
	frame(&ui.tree, {360, 200}) // the window shrinks; no rebuild happens for a plain resize
	testing.expect(t, ui.tree.scrolls[bar].offset.x > 0, "the bar scrolled to keep the selected tab in view")
	testing.expect(t, visible(&ui.tree, bar, last), "the selected tab is fully visible after the resize")
	testing.expect(t, !ui.tree.scrolls[bar].smooth, "…instantly, not eased")
}

// A tall page in a scrolling panel: the panel clips and scrolls its content
// (children move, keyboard End reaches the bottom), and the offset survives
// switching to another tab and back.
@(test)
tab_panel_scrolls_when_asked_and_keeps_its_offset :: proc(t: ^testing.T) {
	ui: Ui(Tab_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {400, 300})
	view :: proc(ui: ^Ui(Tab_Msg), sel: int) -> (panel, last: Node) {
		begin_view(ui)
		column(ui)
		tab_bar(ui, sel, {"Tall", "Short"}, on_tab)
		if tab_panel(ui, sel == 0, key = 1, scroll = true, padding = .lg, gap = .md) {
			panel = ui.scopes[len(ui.scopes) - 1].node
			for i in 0 ..< 40 do last = button(ui, "row", Tab_Msg{i}, key = u64(i + 1))
			end(ui)
		}
		if tab_panel(ui, sel == 1, key = 2) { text(ui, "short"); end(ui) }
		end(ui)
		end_view(ui)
		frame(&ui.tree, {400, 300})
		return
	}
	panel, last := view(&ui, 0)
	pd := node_get(&ui.tree, panel)
	testing.expect(t, .Scroll_V in pd.flags && .Clips in pd.flags && .Layer in pd.flags, "the panel is a vertical scroll layer")
	testing.expectf(t, pd.abs.h <= 300, "panel is bounded by the window, got %g", pd.abs.h)
	st := ui.tree.scrolls[panel]
	testing.expect(t, st.content.y > st.viewport.y, "content overflows the panel")
	before := node_get(&ui.tree, last).abs.y
	testing.expect(t, before > 300, "last row starts below the window")
	// keyboard: focus a row inside, End jumps to the bottom, rows moved up
	set_focus(&ui.tree, last, true)
	settle(&ui)
	frame(&ui.tree, {400, 300})
	after := node_get(&ui.tree, last).abs
	testing.expectf(t, after.y + after.h <= 300 && after.y >= 0, "focusing the last row reveals it, got y %g h %g", after.y, after.h)
	off := ui.tree.scrolls[panel].offset.y
	testing.expect(t, off > 0, "the panel scrolled")
	// switch away and back: same node, same offset
	view(&ui, 1)
	panel2, _ := view(&ui, 0)
	testing.expect_value(t, panel2, panel)
	testing.expect_value(t, ui.tree.scrolls[panel].offset.y, off)
}

} // when ODIN_TEST