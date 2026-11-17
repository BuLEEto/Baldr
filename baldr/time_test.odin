package baldr

@(require) import "core:strings"
@(require) import "core:testing"
@(require) import "core:time"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

Tm_Msg :: struct { tm: Time_Of_Day, set: bool }

@(private = "file")
on_tm :: proc(e: Ev(Time_Of_Day)) -> Tm_Msg { return {tm = e.value, set = true} }

@(private = "file")
time_view :: proc(ui: ^Ui(Tm_Msg), tm: Time_Of_Day, clock: Clock = .H24, seconds := false) -> Node {
	set_viewport(&ui.tree, {500, 300})
	begin_view(ui)
	column(ui, padding = .lg, align = .Start)
	p := time_picker(ui, tm, on_tm, label = "Alarm", clock = clock, seconds = seconds)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {500, 300})
	return p
}

@(private = "file")
last_time :: proc(ui: ^Ui(Tm_Msg)) -> Time_Of_Day {
	if len(ui.msgs) == 0 do return {}
	return ui.msgs[len(ui.msgs) - 1].tm
}

@(private = "file")
seg_center :: proc(ui: ^Ui(Tm_Msg), p: Node, seg: Time_Seg) -> [2]f32 {
	r := node_get(&ui.tree, ui.tree.times[p].segs[seg]).abs
	return {r.x + r.w / 2, r.y + r.h / 2}
}

// One Tab stop: Left / Right move between the segments, Up / Down step
// the picked one (Shift: ten), Home / End go to the ends, and the ring
// follows the picked segment; the seconds segment appears on request.
@(test)
time_picker_keys_edit_the_picked_segment :: proc(t: ^testing.T) {
	ui: Ui(Tm_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	p := time_view(&ui, {hour = 9, minute = 5}, seconds = true)
	ts := &ui.tree.times[p]
	testing.expect(t, ts.segs[.Second] != NODE_NONE && ts.segs[.Period] == NODE_NONE)
	testing.expect(t, strings.contains(access_dump(&ui.tree), "Spin_Button \"Second\""))
	set_focus(&ui.tree, p, true)
	testing.expect_value(t, ts.cursor, Time_Seg.Hour)
	key_event(&ui, .Down, true, {})
	testing.expect_value(t, last_time(&ui), Time_Of_Day{hour = 8, minute = 5})
	key_event(&ui, .Right, true, {})
	testing.expect_value(t, ts.cursor, Time_Seg.Minute)
	key_event(&ui, .Up, true, {.Shift})
	testing.expect_value(t, last_time(&ui), Time_Of_Day{hour = 8, minute = 15})
	key_event(&ui, .Down, true, {})
	key_event(&ui, .Down, true, {})
	testing.expect_value(t, last_time(&ui), Time_Of_Day{hour = 8, minute = 13})
	key_event(&ui, .Right, true, {})
	testing.expect_value(t, ts.cursor, Time_Seg.Second)
	key_event(&ui, .Down, true, {}) // wraps
	testing.expect_value(t, last_time(&ui), Time_Of_Day{hour = 8, minute = 13, second = 59})
	key_event(&ui, .Right, true, {}) // wraps around to the hour
	testing.expect_value(t, ts.cursor, Time_Seg.Hour)
	key_event(&ui, .End, true, {})
	testing.expect_value(t, last_time(&ui), Time_Of_Day{hour = 23, minute = 13, second = 59})
	key_event(&ui, .Home, true, {})
	testing.expect_value(t, last_time(&ui), Time_Of_Day{hour = 0, minute = 13, second = 59})
	// the field is the only Tab stop
	stops := 0
	for d in ui.tree.nodes do if .Alive in d.flags && .Focusable in d.flags do stops += 1
	testing.expect_value(t, stops, 1)
	// the ring is drawn around the picked segment while focus is visible
	ui.needs_rebuild = false
	time_view(&ui, last_time(&ui), seconds = true)
	frame(&ui.tree, {500, 300})
	sd := node_get(&ui.tree, ts.segs[.Hour])
	ringed := false
	for _, l in ui.tree.layers do for c in l.cmds {
		if r, ok := c.(Draw_Rect); ok && r.border_w == 2 && abs(r.rect.x - (sd.abs.x - 2)) < 0.5 && abs(r.rect.y - (sd.abs.y - 2)) < 0.5 do ringed = true
	}
	testing.expect(t, ringed, "the picked segment carries the focus ring")
	// seconds off: the segment goes and the cursor leaves it
	ts.cursor = .Second
	time_view(&ui, last_time(&ui), seconds = false)
	testing.expect(t, ts.segs[.Second] == NODE_NONE && ts.cursor == .Minute)
}

// Typing digits fills the picked segment and moves on: "0" "9" → 09 and
// on to the minutes; a first digit that cannot start a two-digit value
// ("7" for an hour) is taken as the whole value; in 12-hour mode the
// hour keeps its half of the day and A / P change it.
@(test)
time_picker_takes_typed_digits :: proc(t: ^testing.T) {
	ui: Ui(Tm_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	p := time_view(&ui, {hour = 9, minute = 5})
	ts := &ui.tree.times[p]
	set_focus(&ui.tree, p, true)
	testing.expect(t, time_type(&ui, "1"))
	testing.expect_value(t, last_time(&ui), Time_Of_Day{hour = 1, minute = 5})
	testing.expect_value(t, ts.cursor, Time_Seg.Hour) // waiting for a second digit
	time_type(&ui, "7")
	testing.expect_value(t, last_time(&ui), Time_Of_Day{hour = 17, minute = 5})
	testing.expect_value(t, ts.cursor, Time_Seg.Minute) // moved on
	time_type(&ui, "4")
	time_type(&ui, "2")
	testing.expect_value(t, last_time(&ui), Time_Of_Day{hour = 17, minute = 42})
	testing.expect_value(t, ts.cursor, Time_Seg.Minute) // the last segment stays picked
	key_event(&ui, .Left, true, {})
	time_type(&ui, "7") // no hour starts with 7 in a 24-hour clock: taken whole
	testing.expect_value(t, last_time(&ui), Time_Of_Day{hour = 7, minute = 42})
	testing.expect_value(t, ts.cursor, Time_Seg.Minute)
	testing.expect(t, !time_type(&ui, "x"), "other text is not a time")
	// 12-hour: "1" "1" → 11 in the current half; P moves it to the afternoon
	p = time_view(&ui, {hour = 7, minute = 42}, clock = .H12)
	ts = &ui.tree.times[p]
	set_focus(&ui.tree, p, true)
	ts.cursor = .Hour
	time_type(&ui, "1")
	time_type(&ui, "1")
	testing.expect_value(t, last_time(&ui), Time_Of_Day{hour = 11, minute = 42})
	time_type(&ui, "p")
	testing.expect_value(t, last_time(&ui), Time_Of_Day{hour = 23, minute = 42})
	ts.cursor = .Hour
	time_type(&ui, "1")
	time_type(&ui, "2") // 12 PM is noon
	testing.expect_value(t, last_time(&ui), Time_Of_Day{hour = 12, minute = 42})
	time_view(&ui, last_time(&ui), clock = .H12)
	testing.expect_value(t, node_get(&ui.tree, p).access.value_text, "12:42 PM")
}

// The pointer: a click picks a segment and focuses the field, the wheel
// over a segment steps it, and dragging up on one scrubs through values
// without counting as a click.
@(test)
time_picker_clicks_wheels_and_scrubs :: proc(t: ^testing.T) {
	ui: Ui(Tm_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	p := time_view(&ui, {hour = 9, minute = 5})
	ts := &ui.tree.times[p]
	m := seg_center(&ui, p, .Minute)
	pointer_button(&ui, .Left, true, m)
	pointer_button(&ui, .Left, false, m)
	testing.expect(t, ui.tree.focus == p && ts.cursor == .Minute, "a click picks the minute segment")
	testing.expect(t, len(ui.msgs) == 0, "a click alone changes nothing")
	testing.expect(t, scroll_event(&ui, m, {0, -1}), "the wheel is taken by the segment")
	testing.expect_value(t, last_time(&ui), Time_Of_Day{hour = 9, minute = 6})
	scroll_event(&ui, m, {0, 1})
	testing.expect_value(t, last_time(&ui), Time_Of_Day{hour = 9, minute = 5})
	// the wheel over the hour picks it too
	h := seg_center(&ui, p, .Hour)
	scroll_event(&ui, h, {0, -1})
	testing.expect_value(t, last_time(&ui), Time_Of_Day{hour = 10, minute = 5})
	testing.expect_value(t, ts.cursor, Time_Seg.Hour)
	// scrub the minutes: 30 px up is three steps, and the release is not a click
	before := len(ui.msgs)
	pointer_button(&ui, .Left, true, m)
	pointer_move(&ui, {m.x, m.y - 5})
	testing.expect(t, len(ui.msgs) == before, "no step inside the threshold")
	pointer_move(&ui, {m.x, m.y - 30})
	testing.expect_value(t, last_time(&ui), Time_Of_Day{hour = 10, minute = 8})
	pointer_move(&ui, {m.x, m.y + 20}) // back past the start: below it
	testing.expect_value(t, last_time(&ui), Time_Of_Day{hour = 10, minute = 3})
	pointer_button(&ui, .Left, false, {m.x, m.y + 20})
	testing.expect_value(t, ui.time_scrub.picker, NODE_NONE)
	testing.expect_value(t, ts.cursor, Time_Seg.Minute)
	// a click on the period segment picks it and flips it
	p12 := time_view(&ui, last_time(&ui), clock = .H12)
	ts = &ui.tree.times[p12]
	ap := seg_center(&ui, p12, .Period)
	pointer_button(&ui, .Left, true, ap)
	pointer_button(&ui, .Left, false, ap)
	testing.expect_value(t, last_time(&ui), Time_Of_Day{hour = 22, minute = 3})
	testing.expect_value(t, ts.cursor, Time_Seg.Period)
	pointer_button(&ui, .Left, true, ap)
	pointer_button(&ui, .Left, false, ap)
	testing.expect_value(t, last_time(&ui), Time_Of_Day{hour = 10, minute = 3})
	ts.cursor = .Minute // back to the minutes for the touch check
	// touch: ▲ ▼ appear and nudge the picked segment
	set_touch(&ui.tree, true)
	time_view(&ui, last_time(&ui))
	testing.expect(t, ts.touch_nudge[0] != NODE_NONE, "▲ ▼ show on touch")
	testing.expect(t, strings.contains(access_dump(&ui.tree), "Button \"Up\""))
	up := node_get(&ui.tree, ts.touch_nudge[0]).abs
	click(&ui, ts.touch_nudge[0])
	testing.expect_value(t, last_time(&ui), Time_Of_Day{hour = 10, minute = 4})
	_ = up
}

// The app owns the time: a new value from the app replaces what the
// field shows; disabled fields ignore keys; a forced clock overrides the
// locale.
@(test)
time_picker_follows_the_app_and_the_clock_override :: proc(t: ^testing.T) {
	ui: Ui(Tm_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	p := time_view(&ui, {hour = 9, minute = 5})
	testing.expect_value(t, node_get(&ui.tree, p).access.value_text, "09:05")
	time_view(&ui, {hour = 21, minute = 45})
	testing.expect_value(t, node_get(&ui.tree, p).access.value_text, "21:45")
	testing.expect_value(t, ui.tree.times[p].value, Time_Of_Day{hour = 21, minute = 45})
	// the locale keeps a 24-hour clock; .H12 forces the 12-hour one anyway
	testing.expect(t, ui.tree.locale.time_24h)
	time_view(&ui, {hour = 21, minute = 45}, clock = .H12)
	testing.expect(t, ui.tree.times[p].twelve && ui.tree.times[p].segs[.Period] != NODE_NONE)
	testing.expect_value(t, node_get(&ui.tree, p).access.value_text, "9:45 PM")
	// disabled: nothing moves
	set_viewport(&ui.tree, {500, 300})
	begin_view(&ui)
	column(&ui, padding = .lg, align = .Start)
	time_picker(&ui, {hour = 21, minute = 45}, on_tm, label = "Alarm", disabled = true)
	end(&ui)
	end_view(&ui)
	set_focus(&ui.tree, p, true)
	n := len(ui.msgs)
	key_event(&ui, .Up, true, {})
	testing.expect_value(t, len(ui.msgs), n)
}

// time_field opens its picker in a popover on click; Enter inside the
// picker (done editing) or Escape closes it and returns focus.
@(test)
time_field_opens_a_popover :: proc(t: ^testing.T) {
	ui: Ui(Tm_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	view :: proc(ui: ^Ui(Tm_Msg), tm: Time_Of_Day) -> Node {
		set_viewport(&ui.tree, {500, 400})
		begin_view(ui)
		column(ui, padding = .lg, align = .Start)
		f := time_field(ui, tm, on_tm, label = "Alarm", clock = .H24)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {500, 400})
		return f
	}
	f := view(&ui, {hour = 9, minute = 5})
	dump := access_dump(&ui.tree)
	testing.expect(t, strings.contains(dump, "Combo_Box \"Alarm\"") && strings.contains(dump, "09:05"), dump)
	r := node_get(&ui.tree, f).abs
	pointer_button(&ui, .Left, true, {r.x + 10, r.y + r.h / 2})
	pointer_button(&ui, .Left, false, {r.x + 10, r.y + r.h / 2})
	testing.expect(t, ui.open[f], "a click opens the field")
	view(&ui, {hour = 9, minute = 5})
	picker := NODE_NONE
	for k in ui.tree.times do picker = k
	testing.expect(t, picker != NODE_NONE && ui.tree.focus == picker, "the popover holds the picker and focuses it")
	testing.expect(t, strings.contains(access_dump(&ui.tree), "Expanded"))
	key_event(&ui, .Up, true, {})
	testing.expect_value(t, last_time(&ui), Time_Of_Day{hour = 10, minute = 5})
	key_event(&ui, .Enter, true, {})
	testing.expect(t, !ui.open[f] && ui.tree.focus == f, "Enter closes the popover and restores focus")
	view(&ui, last_time(&ui))
	testing.expect(t, strings.contains(access_dump(&ui.tree), "10:05"))
	// Escape too
	key_event(&ui, .Enter, true, {})
	view(&ui, last_time(&ui))
	testing.expect(t, ui.open[f])
	key_event(&ui, .Escape, true, {})
	testing.expect(t, !ui.open[f], "Escape closes it")
}

// Instants become clock readings: in UTC exactly, locally through the
// desktop's zone (whatever it is, the result is a valid time of day).
@(test)
time_of_day_reads_an_instant :: proc(t: ^testing.T) {
	testing.expect_value(t, time_of_day(time.unix(0, 0)), Time_Of_Day{})
	testing.expect_value(t, time_of_day(time.unix(13 * 3600 + 5 * 60 + 9, 0)), Time_Of_Day{hour = 13, minute = 5, second = 9})
	l := now_local()
	testing.expect(t, l.hour >= 0 && l.hour < 24 && l.minute >= 0 && l.minute < 60 && l.second >= 0 && l.second < 60)
	u := now_utc()
	testing.expect(t, u.hour >= 0 && u.hour < 24)
}

} // when ODIN_TEST