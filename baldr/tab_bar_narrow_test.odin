package baldr

// A tab bar too narrow for its tabs scrolls sideways, and a press on a tab
// in that state must still select it rather than scroll the bar.
//
// A press is offered to a scroll bar before the content under it (so a bar
// over a text area can be grabbed). The horizontal bar's grab zone is a
// strip along the bottom edge as tall as the vertical one is wide, and a
// tab bar is short, so uncapped the strip would cover much of every tab.

@(require) import "core:fmt"
@(require) import "core:testing"

when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Tbn_Msg :: struct { idx: int }

@(private = "file")
on_tbn :: proc(e: Ev(int)) -> Tbn_Msg { return {idx = e.value} }

@(private = "file")
TBN_LABELS := []string{"Overview", "Controls", "Inputs", "Overlays", "Lists", "Table", "Motion", "Explorer"}

@(private = "file")
tbn_view :: proc(ui: ^Ui(Tbn_Msg), sel: int, w: f32) -> (bar: Node) {
	begin_view(ui)
	column(ui)
	bar = tab_bar(ui, sel, TBN_LABELS, on_tbn)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {w, 200})
	return
}

// tbn_tab is the first tab lying wholly inside the bar, so a press on it is
// a press a person could actually make.
@(private = "file")
tbn_tab :: proc(t: ^Tree, bar: Node) -> Node {
	b := node_get(t, bar).abs
	for c := node_get(t, bar).first; c != NODE_NONE; c = node_get(t, c).next {
		d := node_get(t, c).abs
		if d.x >= b.x && d.x + d.w <= b.x + b.w && d.w > 0 do return c
	}
	return NODE_NONE
}

@(test)
every_part_of_a_tab_selects_it_when_the_bar_scrolls :: proc(t: ^testing.T) {
	ui: Ui(Tbn_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {360, 200})

	bar := tbn_view(&ui, 0, 360)
	st, has := ui.tree.scrolls[bar]
	if !testing.expect(t, has && st.content.x > st.viewport.x, "360 px is too narrow for eight tabs, so the bar scrolls") do return

	tab := tbn_tab(&ui.tree, bar)
	if !testing.expect(t, tab != NODE_NONE, "at least one tab is wholly on screen") do return
	r := node_get(&ui.tree, tab).abs

	// a press anywhere on the tab is a press on the tab: the middle, and
	// then the bottom edge, which is where a pointer lands on a short bar
	for _, i in ([]int{0, 1}) {
		at := [2]f32{r.x + r.w / 2, r.y + r.h / 2} if i == 0 else [2]f32{r.x + r.w / 2, r.y + r.h - 2}
		where_ := "the middle of the tab" if i == 0 else "the bottom edge of the tab"
		clear(&ui.msgs)
		pointer_move(&ui, at, moved = true)
		pointer_button(&ui, .Left, true, at)
		pointer_button(&ui, .Left, false, at)
		frame(&ui.tree, {360, 200})
		testing.expectf(t, len(ui.msgs) == 1,
			"a press at %s (%.0f,%.0f in a tab %.0fx%.0f at %.0f,%.0f) selects it — got %d messages",
			where_, at.x, at.y, r.w, r.h, r.x, r.y, len(ui.msgs))
		testing.expectf(t, ui.tree.scrolls[bar].offset.x == st.offset.x,
			"…and does not scroll the bar instead (offset %.1f -> %.1f)",
			st.offset.x, ui.tree.scrolls[bar].offset.x)
	}
	_ = fmt.tprintf("") // keep the fmt import honest on a passing build
}


// The other half of the rule: a container with room to spare keeps a
// grabbable bar, since a list's thumb is the fastest way through many rows.
@(test)
a_container_with_room_keeps_its_grabbable_bar :: proc(t: ^testing.T) {
	ui: Ui(Tbn_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {360, 600})
	begin_view(&ui)
	col := scroll(&ui, .Column, flex = 1)
	for i in 0 ..< 60 do text(&ui, "a row that makes the column overflow", key = u64(i + 1))
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {360, 600})

	_, _, has_bar := scrollbar_geometry(&ui.tree, col, 1)
	if !testing.expect(t, has_bar, "60 rows in 600 px overflows") do return
	zone, ok := scrollbar_zone(&ui.tree, col, 1)
	d := node_get(&ui.tree, col).abs
	testing.expectf(t, ok, "a %.0f px wide column still offers its bar to a press", d.w)
	testing.expectf(t, zone.w == SCROLLBAR_ZONE,
		"…at the full %.0f px of slop, because it has the room (got %.0f)", f32(SCROLLBAR_ZONE), zone.w)
}

// And the rule itself, at the two sizes that matter.
@(test)
a_grab_zone_never_takes_more_than_a_third :: proc(t: ^testing.T) {
	thick, ok := scrollbar_grab(36) // a tab bar
	testing.expect(t, !ok, "a 36 px strip has no room for a grabbable bar")
	thick, ok = scrollbar_grab(400) // a list
	testing.expect(t, ok, "a 400 px list has")
	testing.expect_value(t, thick, f32(SCROLLBAR_ZONE))
	thick, ok = scrollbar_grab(45) // in between: capped, still grabbable
	testing.expect(t, ok, "45 px is enough")
	testing.expectf(t, thick <= 45.0 / 3, "…but only a third of it (got %.0f)", thick)
}

}
