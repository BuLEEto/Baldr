package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Behind this `when` so a program importing Baldr does not type-check the
// test suite too, which costs gigabytes. ODIN_TEST is set by `odin test`;
// BALDR_TESTS lets ./build.sh check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

Lc_Kind :: enum { None, Date, Num, Time, Color }
Lc_Msg :: struct {
	kind: Lc_Kind,
	d:    Date,
	v:    f32,
	tm:   Time_Of_Day,
	c:    Color,
}

@(private = "file")
on_d :: proc(e: Ev(Date)) -> Lc_Msg { return {kind = .Date, d = e.value} }
@(private = "file")
on_v :: proc(e: Ev(f32)) -> Lc_Msg { return {kind = .Num, v = e.value} }
@(private = "file")
on_tm :: proc(e: Ev(Time_Of_Day)) -> Lc_Msg { return {kind = .Time, tm = e.value} }
@(private = "file")
on_c :: proc(e: Ev(Color)) -> Lc_Msg { return {kind = .Color, c = e.value} }

// A locale that differs from English in every way the widgets care about.
@(private = "file")
locale_fr_us :: proc() -> Locale {
	l := LOCALE_EN
	l.tag = "test"
	l.months = {"janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre"}
	l.weekdays = {"dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"}
	l.weekdays_short = {"dim.", "lun.", "mar.", "mer.", "jeu.", "ven.", "sam."}
	l.first_weekday = 0 // Sunday first
	l.date_format = "%m/%d/%Y"
	l.time_24h = false
	l.am, l.pm = "AM", "PM"
	l.decimal = ","
	return l
}

// The calendar takes its names, its first weekday and its date order from
// the locale; the number field writes and reads the locale's decimal mark.
@(test)
locale_shapes_dates_and_numbers :: proc(t: ^testing.T) {
	ui: Ui(Lc_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_locale(&ui, locale_fr_us())
	set_viewport(&ui.tree, {500, 500})
	begin_view(&ui)
	column(&ui, padding = .lg, align = .Start, gap = .md)
	cal := date_picker(&ui, {2026, 9, 11}, on_d, label = "Due")
	num := number_input(&ui, 2.5, on_v, step = 0.5, label = "Amount")
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {500, 500})
	cs := &ui.tree.calendars[cal]
	testing.expect_value(t, cs.first, date_ordinal({2026, 8, 30})) // Sunday first: 30 Aug 2026 is a Sunday
	dump := access_dump(&ui.tree)
	testing.expect(t, strings.contains(dump, "vendredi septembre 11 2026") || strings.contains(dump, "vendredi septembre 11 2026"), dump)
	testing.expect_value(t, date_text(&ui.tree, {2026, 9, 11}), "septembre 11 2026")
	testing.expect_value(t, date_short(&ui.tree, {2026, 9, 11}), "09/11/2026")
	hdr := node_first(&ui.tree, cal)
	title := node_get(&ui.tree, node_next(&ui.tree, node_first(&ui.tree, hdr))).kind.(Text_Kind)
	testing.expect_value(t, title.str, "septembre 2026")
	wd := node_next(&ui.tree, hdr)
	first_initial := node_get(&ui.tree, node_first(&ui.tree, wd)).kind.(Text_Kind)
	testing.expect_value(t, first_initial.str, "d") // dimanche
	sp := ui.tree.spins[num]
	testing.expect_value(t, string(sp.text.buf[:]), "2,5")
	set_focus(&ui.tree, sp.field, true)
	text_set(&sp.text, "3,25")
	key_event(&ui, .Enter, true, {})
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1], Lc_Msg{kind = .Num, v = 3.25})
	// English again: the same date reads the English way
	set_locale(&ui, LOCALE_EN)
	testing.expect_value(t, date_text(&ui.tree, {2026, 9, 11}), "11 September 2026")
	testing.expect_value(t, date_short(&ui.tree, {2026, 9, 11}), "11/09/2026")
}

// A time picker in a 12-hour locale shows a 12-hour hour and AM / PM and
// sends 24-hour times; in a 24-hour locale there is no AM / PM segment
// and the hour is two digits; the value reads the locale's way.
@(test)
time_picker_follows_the_clock_style :: proc(t: ^testing.T) {
	ui: Ui(Lc_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_locale(&ui, locale_fr_us())
	view :: proc(ui: ^Ui(Lc_Msg), tm: Time_Of_Day) -> Node {
		set_viewport(&ui.tree, {500, 300})
		begin_view(ui)
		column(ui, padding = .lg, align = .Start)
		p := time_picker(ui, tm, on_tm, label = "Alarm")
		end(ui)
		end_view(ui)
		frame(&ui.tree, {500, 300})
		return p
	}
	p := view(&ui, {hour = 15, minute = 30})
	ts := ui.tree.times[p]
	testing.expect(t, ts.twelve && ts.segs[.Period] != NODE_NONE && ts.segs[.Second] == NODE_NONE)
	testing.expect_value(t, node_get(&ui.tree, p).access.value_text, "3:30 PM")
	testing.expect_value(t, node_get(&ui.tree, ts.segs[.Hour]).access.value, 15)
	dump := access_dump(&ui.tree)
	testing.expect(t, strings.contains(dump, "Group \"Alarm\"") && strings.contains(dump, "Spin_Button \"Hour\"") && strings.contains(dump, "Spin_Button \"AM / PM\""), dump)
	// hour up → 16:30 (the hour segment is picked first)
	set_focus(&ui.tree, p, true)
	key_event(&ui, .Up, true, {})
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1].tm, Time_Of_Day{hour = 16, minute = 30})
	// A picks the morning
	time_type(&ui, "a")
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1].tm, Time_Of_Day{hour = 4, minute = 30})
	set_locale(&ui, LOCALE_EN)
	p = view(&ui, {hour = 15, minute = 30})
	ts = ui.tree.times[p]
	testing.expect(t, !ts.twelve && ts.segs[.Period] == NODE_NONE)
	testing.expect_value(t, node_get(&ui.tree, p).access.value_text, "15:30")
	testing.expect_value(t, time_text(&ui.tree, {hour = 7, minute = 5, second = 9}, seconds = true), "07:05:09")
	testing.expect_value(t, time_text(&ui.tree, {hour = 0, minute = 5}, clock = .H12), "12:05 AM")
}

// The drop-down fields open their picker in a popover; a pick in the date
// popover closes it and hands focus back; the colour popover holds a
// picker; Escape closes either.
@(test)
date_and_color_fields_open_popovers :: proc(t: ^testing.T) {
	ui: Ui(Lc_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	view :: proc(ui: ^Ui(Lc_Msg), d: Date, c: Color) -> (df, cf: Node) {
		set_viewport(&ui.tree, {600, 500})
		begin_view(ui)
		column(ui, padding = .lg, align = .Start, gap = .md)
		df = date_field(ui, d, on_d, label = "Due")
		cf = color_field(ui, c, on_c, label = "Accent")
		end(ui)
		end_view(ui)
		frame(&ui.tree, {600, 500})
		return
	}
	overlays :: proc(ui: ^Ui(Lc_Msg)) -> int { // live ones; a closed popover fades out for a moment
		n := 0
		for c := node_first(&ui.tree, ui.tree.overlay); c != NODE_NONE; c = node_next(&ui.tree, c) do if .Exiting not_in node_get(&ui.tree, c).flags do n += 1
		return n
	}
	df, cf := view(&ui, {2026, 9, 11}, rgb(0x3881F3))
	dump := access_dump(&ui.tree)
	testing.expect(t, strings.contains(dump, "Combo_Box \"Due\"") && strings.contains(dump, "Combo_Box \"Accent\""), dump)
	testing.expect_value(t, overlays(&ui), 0)
	// open the date field with the keyboard
	set_focus(&ui.tree, df, true)
	key_event(&ui, .Enter, true, {})
	testing.expect(t, ui.open[df] && ui.needs_rebuild, "Enter opens")
	ui.needs_rebuild = false
	view(&ui, {2026, 9, 11}, rgb(0x3881F3))
	testing.expect_value(t, overlays(&ui), 1)
	cal := NODE_NONE
	for c, f in ui.tree.field_of_cal do if f == df do cal = c
	testing.expect(t, cal != NODE_NONE, "a calendar sits in the popover")
	testing.expect_value(t, ui.tree.focus, cal)
	key_event(&ui, .Right, true, {})
	key_event(&ui, .Enter, true, {})
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1], Lc_Msg{kind = .Date, d = {2026, 9, 12}})
	testing.expect(t, !ui.open[df], "a pick closes the popover")
	testing.expect_value(t, ui.tree.focus, df)
	ui.needs_rebuild = false
	view(&ui, {2026, 9, 12}, rgb(0x3881F3))
	testing.expect_value(t, overlays(&ui), 0)
	// the colour field
	cr := node_get(&ui.tree, cf).abs
	pointer_button(&ui, .Left, true, {cr.x + 10, cr.y + cr.h / 2})
	pointer_button(&ui, .Left, false, {cr.x + 10, cr.y + cr.h / 2})
	testing.expect(t, ui.open[cf])
	ui.needs_rebuild = false
	view(&ui, {2026, 9, 12}, rgb(0x3881F3))
	testing.expect_value(t, overlays(&ui), 1)
	testing.expect(t, len(ui.tree.pickers) == 1, "a colour picker sits in the popover")
	testing.expect(t, key_event(&ui, .Escape, true, {}), "Escape closes")
	testing.expect(t, !ui.open[cf])
}

} // when ODIN_TEST