package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

Dp_Msg :: struct { d: Date }

@(private = "file")
on_date_msg :: proc(e: Ev(Date)) -> Dp_Msg { return {e.value} }

@(private = "file")
cal_view :: proc(ui: ^Ui(Dp_Msg), date: Date, min: Date = {}, max: Date = {}) -> Node {
	set_viewport(&ui.tree, {400, 400})
	begin_view(ui)
	column(ui, padding = .lg, align = .Start)
	cal := date_picker(ui, date, on_date_msg, label = "Due", min = min, max = max)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 400})
	return cal
}

@(private = "file")
click_cell :: proc(ui: ^Ui(Dp_Msg), cell: Node) {
	r := node_get(&ui.tree, cell).abs
	p := [2]f32{r.x + r.w / 2, r.y + r.h / 2}
	pointer_button(ui, .Left, true, p)
	pointer_button(ui, .Left, false, p)
}

// The grid starts on the week's first day before the 1st, names every day
// in full, marks the picked one, and a click picks.
@(test)
date_picker_lays_out_the_month_and_picks_by_click :: proc(t: ^testing.T) {
	ui: Ui(Dp_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	cal := cal_view(&ui, {2026, 9, 11})
	cs := &ui.tree.calendars[cal]
	testing.expect_value(t, cs.first, date_ordinal({2026, 8, 31})) // 1 Sep 2026 is a Tuesday; Monday first
	testing.expect_value(t, len(cs.cells), 42)
	dump := access_dump(&ui.tree)
	testing.expect(t, strings.contains(dump, "Group \"Due\"") && strings.contains(dump, "Button \"Friday 11 September 2026\"") && strings.contains(dump, "Button \"Monday 31 August 2026\""), dump)
	c11 := calendar_cell(cs, {2026, 9, 11})
	testing.expect(t, .Selected in node_get(&ui.tree, c11).access.states, "the picked day is Selected")
	testing.expect(t, .Focusable in node_get(&ui.tree, cal).flags && .Focusable not_in node_get(&ui.tree, c11).flags, "one Tab stop")
	click_cell(&ui, calendar_cell(cs, {2026, 9, 23}))
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1], Dp_Msg{{2026, 9, 23}})
	testing.expect_value(t, ui.tree.focus, cal)
	// a click on a trailing day of the next month turns the page
	click_cell(&ui, calendar_cell(cs, {2026, 10, 3}))
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1], Dp_Msg{{2026, 10, 3}})
	testing.expect(t, ui.needs_rebuild && cs.view_month == 10, "the page turned to October")
}

// Keys move the cursor (no message), turn the page at the edges, and
// Enter picks; Home / End go to the week's ends.
@(test)
date_picker_keyboard_cursor_and_pages :: proc(t: ^testing.T) {
	ui: Ui(Dp_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	cal := cal_view(&ui, {2026, 9, 11})
	cs := &ui.tree.calendars[cal]
	set_focus(&ui.tree, cal, true)
	testing.expect(t, key_event(&ui, .Right, true, {}))
	testing.expect_value(t, cs.cursor, Date{2026, 9, 12})
	key_event(&ui, .Down, true, {})
	testing.expect_value(t, cs.cursor, Date{2026, 9, 19})
	testing.expect_value(t, len(ui.msgs), 0)
	key_event(&ui, .Page_Down, true, {})
	testing.expect_value(t, cs.cursor, Date{2026, 10, 19})
	testing.expect(t, ui.needs_rebuild && cs.view_month == 10, "Page Down turned the page")
	ui.needs_rebuild = false
	cal_view(&ui, {2026, 9, 11})
	testing.expect(t, strings.contains(access_dump(&ui.tree), "Button \"Monday 19 October 2026\""), "October is built")
	key_event(&ui, .Enter, true, {})
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1], Dp_Msg{{2026, 10, 19}})
	key_event(&ui, .End, true, {}) // 19 Oct 2026 is a Monday
	testing.expect_value(t, cs.cursor, Date{2026, 10, 25})
	key_event(&ui, .Home, true, {})
	testing.expect_value(t, cs.cursor, Date{2026, 10, 19})
	key_event(&ui, .Up, true, {})
	key_event(&ui, .Up, true, {})
	key_event(&ui, .Up, true, {})
	testing.expect_value(t, cs.cursor, Date{2026, 9, 28})
	testing.expect_value(t, cs.view_month, i8(9))
	// the ring is painted on the cursor cell
	ui.needs_rebuild = false
	cal_view(&ui, {2026, 9, 11})
	frame(&ui.tree, {400, 400})
	cell := calendar_cell(cs, {2026, 9, 28})
	cr := node_get(&ui.tree, cell).abs
	ring := false
	for _, l in ui.tree.layers do for c in l.cmds {
		if r, ok := c.(Draw_Rect); ok && r.border_w == 2 && abs(r.rect.x - (cr.x - 2)) < 0.5 && abs(r.rect.y - (cr.y - 2)) < 0.5 do ring = true
	}
	testing.expect(t, ring, "the focus ring sits on the cursor day")
}

// Days outside min / max are disabled: a click or Enter on them sends
// nothing. February 2028 has 29 days.
@(test)
date_picker_bounds_and_leap_years :: proc(t: ^testing.T) {
	ui: Ui(Dp_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	cal := cal_view(&ui, {2026, 9, 11}, min = {2026, 9, 5}, max = {2026, 9, 20})
	cs := &ui.tree.calendars[cal]
	c3 := calendar_cell(cs, {2026, 9, 3})
	testing.expect(t, .Disabled in node_get(&ui.tree, c3).flags && .Disabled not_in node_get(&ui.tree, calendar_cell(cs, {2026, 9, 5})).flags)
	click_cell(&ui, c3)
	testing.expect_value(t, len(ui.msgs), 0)
	set_focus(&ui.tree, cal, true)
	cs.cursor = {2026, 9, 25}
	key_event(&ui, .Enter, true, {})
	testing.expect_value(t, len(ui.msgs), 0)
	cal = cal_view(&ui, {2028, 2, 10})
	cs = &ui.tree.calendars[cal]
	c29 := calendar_cell(cs, {2028, 2, 29})
	testing.expect(t, c29 != NODE_NONE && node_get(&ui.tree, c29).access.name == "Tuesday 29 February 2028", "a leap day")
	testing.expect_value(t, date_add_months({2028, 1, 31}, 1), Date{2028, 2, 29}) // clamps to the month's end
	testing.expect_value(t, date_add_months({2026, 12, 15}, 1), Date{2027, 1, 15})
	testing.expect_value(t, date_add_months({2026, 1, 15}, -1), Date{2025, 12, 15})
}

} // when ODIN_TEST