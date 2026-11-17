package baldr

// date_picker: a month grid to pick a day. The picked date is the app's
// state (on_change carries the new one); the month shown and the keyboard
// cursor are the widget's. One Tab stop: the arrows move the cursor by a
// day or a week (crossing into the next month turns the page), Page Up /
// Down turn the page, Home / End go to the week's ends, Enter / Space pick
// the cursor day, a click picks a day; ‹ › turn the page. Days outside
// `min` / `max` are disabled. Put it in a popover for a drop-down field.
// Accessibility: a Group named `label` of Buttons named in full
// ("11 September 2026"), the picked day Selected, today described.
//
//	baldr.date_picker(ui, s.date, proc(e: baldr.Ev(baldr.Date)) -> Msg { return Set_Date{e.value} })

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import dt "core:time/datetime"

Date    :: dt.Date    // year, month (1..12), day
// Weekday is a day of the week, Sunday = 0. Which day a calendar starts on
// comes from the desktop's locale, not from this.
Weekday :: dt.Weekday // Sunday = 0

DATE_CELL_W :: f32(36)
DATE_CELL_H :: f32(32)

// Week_Start: whose week the grid starts on — the locale's, or a fixed day.
Week_Start :: enum u8 { Locale, Sunday, Monday, Saturday }

Calendar_State :: struct {
	view_year:  i64,
	view_month: i8,
	cursor:     Date,
	week_start: Weekday,
	first:      i64,           // ordinal of the grid's first cell
	cells:      [dynamic]Node, // 42 cells in grid order, this build
	shown:      bool,          // view month chosen (else it follows the date)
	last_date:  Date,          // the date the app passed last build: a change moves the cursor and the page
}

// Cal_Nav is a press on a calendar's back or forward control, and how many
// months it moves.
Cal_Nav :: struct {
	cal:   Node,
	delta: int, // months
}

// today is the local date.
today :: proc() -> Date {
	y, m, d := time.date(time.now())
	return {i64(y), i8(m), i8(d)}
}

date_valid :: proc "contextless" (d: Date) -> bool {
	return d.year != 0 && d.month >= 1 && d.month <= 12 && d.day >= 1 && d.day <= 31
}

// date_ordinal counts days since the epoch the calendar uses (0 for an invalid date).
date_ordinal :: proc "contextless" (d: Date) -> i64 {
	o, err := dt.date_to_ordinal(d)
	if err != .None do return 0
	return i64(o)
}

date_from_ordinal :: proc "contextless" (o: i64) -> Date {
	d, err := dt.ordinal_to_date(dt.Ordinal(o))
	if err != .None do return {}
	return d
}

date_add_days :: proc "contextless" (d: Date, days: int) -> Date {
	return date_from_ordinal(date_ordinal(d) + i64(days))
}

// date_add_months keeps the day where the month allows and clamps otherwise.
date_add_months :: proc "contextless" (d: Date, months: int) -> Date {
	m := int(d.month) - 1 + months
	y := d.year + i64(m / 12)
	m = m % 12
	if m < 0 { m += 12; y -= 1 }
	last, _ := dt.last_day_of_month(y, i8(m + 1))
	return {y, i8(m + 1), min(d.day, last)}
}

date_before :: proc "contextless" (a, b: Date) -> bool { return date_ordinal(a) < date_ordinal(b) }

// date_text writes a date in full the way the locale orders it: "11
// September 2026" (en_GB), "September 11 2026" (en_US), following the
// locale's date format with the month spelled out. Temp allocated.
date_text :: proc(t: ^Tree, d: Date) -> string {
	if !date_valid(d) do return ""
	return date_format(t, d, long = true)
}

// date_short writes a date in the locale's short order — "11/09/2026",
// "09/11/2026", "2026-09-11" — always with a four-digit year, even where
// the locale's own short form has two (a form field must not be
// ambiguous). Temp allocated.
date_short :: proc(t: ^Tree, d: Date) -> string {
	if !date_valid(d) do return ""
	return date_format(t, d, long = false)
}

// date_format follows the locale's strftime-style date format. `long`
// spells the month out and joins the parts with spaces (or the locale's
// own separators when they are not slashes). The text is in the frame's temp
// memory.
date_format :: proc(t: ^Tree, d: Date, long: bool) -> string {
	l := &t.locale
	f := l.date_format if len(l.date_format) > 0 else "%d/%m/%Y"
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(f) {
		c := f[i]
		if c == '%' && i + 1 < len(f) {
			switch f[i + 1] {
			case 'd': fmt.sbprintf(&b, "%d" if long else "%02d", d.day)
			case 'e': fmt.sbprintf(&b, "%d", d.day)
			case 'm': if long { fmt.sbprint(&b, l.months[d.month - 1]) } else { fmt.sbprintf(&b, "%02d", d.month) }
			case 'b': fmt.sbprint(&b, l.months_short[d.month - 1])
			case 'B': fmt.sbprint(&b, l.months[d.month - 1])
			case 'y': fmt.sbprintf(&b, "%d", d.year) // never a two-digit year: it reads wrong in a field
			case 'Y': fmt.sbprintf(&b, "%d", d.year)
			case '%': fmt.sbprint(&b, "%")
			case: fmt.sbprint(&b, f[i:i + 2])
			}
			i += 2
			continue
		}
		if long && (c == '/' || c == '-' || c == '.') {
			fmt.sbprint(&b, " ")
		} else {
			strings.write_byte(&b, c)
		}
		i += 1
	}
	return strings.to_string(b)
}

// date_weekday_initial is the locale's one-letter day (Sunday = 0). It
// aliases the tree's locale, which changes only when the desktop's does.
date_weekday_initial :: proc(t: ^Tree, wd: int) -> string {
	s := t.locale.weekdays_short[wd % 7]
	if len(s) == 0 do s = t.locale.weekdays[wd % 7]
	if len(s) == 0 do return ""
	_, w := utf8.decode_rune_in_string(s)
	return s[:w]
}

date_picker :: proc(ui: ^Ui($Msg), date: Date, on_change: Handler(Msg, Date) = nil, label: string = "Date",
	min: Date = {}, max: Date = {}, week_start: Week_Start = .Locale, key: u64 = 0, loc := #caller_location) -> Node {
	t := &ui.tree
	th := &t.theme
	ws: Weekday
	switch week_start {
	case .Locale:   ws = Weekday(t.locale.first_weekday % 7)
	case .Sunday:   ws = .Sunday
	case .Monday:   ws = .Monday
	case .Saturday: ws = .Saturday
	}
	n, created := reconcile_child(ui, .Custom, key, loc)
	d := node_get(t, n)
	if created {
		d.access.role = .Group
		d.flags += {.Focusable, .Ring_Inside}
		d.kind = Custom_Kind{paint_over = paint_calendar_over}
		t.calendars[n] = {cells = make([dynamic]Node, t.allocator)}
	}
	set_name(t, n, label)
	set_layout(t, n, Layout_Props{axis = .Column, align = .Start, gap = th.space[.xxs]})
	cs := &t.calendars[n]
	cs.week_start = ws
	anchor := date if date_valid(date) else today()
	if !cs.shown {
		cs.view_year, cs.view_month = anchor.year, anchor.month
		cs.cursor = anchor
		cs.shown = true
	} else if date_ordinal(date) != date_ordinal(cs.last_date) && date_valid(date) {
		// the app changed the date (a pick, or another control): the cursor and the page follow it
		cs.cursor = date
		cs.view_year, cs.view_month = date.year, date.month
	}
	cs.last_date = date
	ui.on_date[n] = on_change
	clear(&cs.cells)
	first_of_month := Date{cs.view_year, cs.view_month, 1}
	first_ord := date_ordinal(first_of_month)
	lead := (int(dt.day_of_week(dt.Ordinal(first_ord))) - int(ws) + 7) % 7
	cs.first = first_ord - i64(lead)
	tdy := today()
	tdy_ord := date_ordinal(tdy)
	sel_ord := date_ordinal(date) if date_valid(date) else -1
	min_ord := date_ordinal(min) if date_valid(min) else 0
	max_ord := date_ordinal(max) if date_valid(max) else 1 << 62

	open_scope(ui, n, loc)
	// header: ‹ Month Year ›
	hdr := row(ui, align = .Center, gap = .xs, key = 1, loc = loc)
	set_layout(t, hdr, Layout_Props{axis = .Row, align = .Center, gap = th.space[.xs], width = 7 * DATE_CELL_W})
	cal_nav_button(ui, n, -1, .Chevron_Left, "Previous month", 2, loc)
	title := text(ui, fmt.tprintf("%s %d", t.locale.months[cs.view_month - 1], cs.view_year), role = .Label, align = .Center, key = 3, loc = loc)
	set_layout(t, title, Layout_Props{flex = 1})
	set_role(t, title, .None)
	cal_nav_button(ui, n, +1, .Chevron_Right, "Next month", 4, loc)
	end(ui)
	// weekday initials
	row(ui, key = 2, loc = loc)
	for i in 0 ..< 7 {
		w := (int(ws) + i) % 7
		c := text(ui, date_weekday_initial(t, w), role = .Caption, muted = true, align = .Center, key = u64(i + 1), loc = loc)
		set_layout(t, c, Layout_Props{width = DATE_CELL_W})
		set_role(t, c, .None)
	}
	end(ui)
	// six weeks of days
	for r in 0 ..< 6 {
		rw := row(ui, key = u64(10 + r), loc = loc)
		_ = rw
		for c in 0 ..< 7 {
			ord := cs.first + i64(r * 7 + c)
			day := date_from_ordinal(ord)
			cell, ccreated := reconcile_child(ui, .Box, u64(c + 1), loc)
			cd := node_get(t, cell)
			if ccreated {
				cd.access.role = .Button
				t.cal_day_of[cell] = n
			}
			cd.tag = u64(ord)
			set_name(t, cell, fmt.tprintf("%s %s", t.locale.weekdays[int(dt.day_of_week(dt.Ordinal(ord)))], date_text(t, day)))
			in_month := day.month == cs.view_month
			selected := ord == sel_ord
			is_today := ord == tdy_ord
			disabled := ord < min_ord || ord > max_ord
			set_disabled(t, cell, disabled)
			if was := .Selected in cd.access.states; was != selected {
				if selected { cd.access.states += {.Selected} } else { cd.access.states -= {.Selected} }
				mark_paint_dirty(t, cell)
			}
			if is_today && cd.access.describe != "Today" do set_describe(t, cell, "Today")
			set_layout(t, cell, Layout_Props{axis = .Row, align = .Center, justify = .Center, width = DATE_CELL_W, height = DATE_CELL_H})
			st := cd.style
			st.radius = th.radius.sm
			st.bg = th.color.primary if selected else Color{}
			st.border_w = 1 if is_today && !selected else 0
			st.border = th.color.primary
			set_style(t, cell, st)
			fg := th.color.on_primary if selected else (th.color.on_surface if in_month else th.color.on_surface_muted)
			open_scope(ui, cell, loc)
			lbl := text(ui, fmt.tprintf("%d", day.day), role = .Label, color = fg, loc = loc)
			set_role(t, lbl, .None)
			close_scope(ui)
			append(&cs.cells, cell)
		}
		end(ui)
	}
	close_scope(ui)
	return n
}

@(private)
cal_nav_button :: proc(ui: ^Ui($Msg), cal: Node, delta: int, ic: Icon, name: string, key: u64, loc: runtime.Source_Code_Location) {
	t := &ui.tree
	th := &t.theme
	b, created := reconcile_child(ui, .Box, key, loc)
	d := node_get(t, b)
	if created {
		d.access.role = .Button
		d.flags += {.Focusable}
	}
	set_name(t, b, name)
	ui.cal_nav[b] = {cal = cal, delta = delta}
	set_layout(t, b, Layout_Props{axis = .Row, align = .Center, justify = .Center, width = 28, height = 28})
	st := d.style
	st.radius = th.radius.sm
	set_style(t, b, st)
	open_scope(ui, b, loc)
	baldr_icon(ui, ic, ICON_SIZE, th.color.on_surface, loc)
	close_scope(ui)
}

// calendar_nav turns the page by `delta` months (the ‹ › buttons).
@(private)
calendar_nav :: proc(ui: ^Ui($Msg), cal: Node, delta: int) -> bool {
	t := &ui.tree
	cs, ok := &t.calendars[cal]
	if !ok do return false
	v := date_add_months({cs.view_year, cs.view_month, 1}, delta)
	cs.view_year, cs.view_month = v.year, v.month
	if cs.cursor.year != v.year || cs.cursor.month != v.month do cs.cursor = date_add_months(cs.cursor, delta)
	ask_rebuild(ui)
	return true
}

// calendar_pick: a click on a day picks it (the app hears on_change).
@(private)
calendar_pick :: proc(ui: ^Ui($Msg), cal: Node, ord: i64) -> bool {
	t := &ui.tree
	cs, ok := &t.calendars[cal]
	if !ok do return false
	set_focus(t, cal, false)
	day := date_from_ordinal(ord)
	cs.cursor = day
	if day.month != cs.view_month || day.year != cs.view_year {
		cs.view_year, cs.view_month = day.year, day.month
		ask_rebuild(ui)
	}
	mark_paint_dirty(t, cal)
	if h, has := ui.on_date[cal]; has do handler_send(ui, h, day, cal)
	date_field_picked(ui, cal)
	return true
}

// date_field_picked closes the field's popover after a pick and hands
// focus back to the field.
@(private)
date_field_picked :: proc(ui: ^Ui($Msg), cal: Node) {
	t := &ui.tree
	field, ok := t.field_of_cal[cal]
	if !ok do return
	ui.open[field] = false
	ask_rebuild(ui)
	set_focus(t, field, false)
}

// calendar_key moves the cursor and picks it with Enter / Space.
calendar_key :: proc(ui: ^Ui($Msg), key: Key, mods: Mods) -> bool {
	t := &ui.tree
	cal := t.focus
	cs, ok := &t.calendars[cal]
	if !ok do return false
	next := cs.cursor
	#partial switch key {
	case .Left:      next = date_add_days(cs.cursor, -1)
	case .Right:     next = date_add_days(cs.cursor, +1)
	case .Up:        next = date_add_days(cs.cursor, -7)
	case .Down:      next = date_add_days(cs.cursor, +7)
	case .Page_Up:   next = date_add_months(cs.cursor, -1)
	case .Page_Down: next = date_add_months(cs.cursor, +1)
	case .Home, .End:
		wd := (int(dt.day_of_week(dt.Ordinal(date_ordinal(cs.cursor)))) - int(cs.week_start) + 7) % 7
		next = date_add_days(cs.cursor, -wd if key == .Home else 6 - wd)
	case .Enter, .Space:
		cell := calendar_cell(cs, cs.cursor)
		if cd := node_get(t, cell); cd != nil && .Disabled in cd.flags do return true
		if h, has := ui.on_date[cal]; has do handler_send(ui, h, cs.cursor, cal)
		date_field_picked(ui, cal)
		return true
	case: return false
	}
	cs.cursor = next
	if next.month != cs.view_month || next.year != cs.view_year {
		cs.view_year, cs.view_month = next.year, next.month
		ask_rebuild(ui)
	}
	mark_paint_dirty(t, cal)
	return true
}

@(private)
calendar_cell :: proc(cs: ^Calendar_State, d: Date) -> Node {
	i := int(date_ordinal(d) - cs.first)
	if i < 0 || i >= len(cs.cells) do return NODE_NONE
	return cs.cells[i]
}

// paint_calendar_over draws the ring around the cursor day while focused.
@(private)
paint_calendar_over :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer) {
	cs, ok := &t.calendars[n]
	if !ok || t.focus != n || !ring_shown(t) do return
	cell := calendar_cell(cs, cs.cursor)
	cd := node_get(t, cell)
	if cd == nil do return
	focus_t := anim_target(t, n, .Focus, 1, t.theme.motion.fast)
	lk := focus_ring_look(&t.theme)
	col := lk.color
	col.a *= focus_t * t.paint_opacity
	w := lk.width // just outside the cell, with no gap
	append(&l.cmds, Draw_Rect{rect = {cd.abs.x - w, cd.abs.y - w, cd.abs.w + 2 * w, cd.abs.h + 2 * w}, radius = cd.style.radius + w, border_w = w, border = col})
}

// date_field is the drop-down form: a field showing the date the way the
// locale writes it, with a calendar icon; a click, Enter or Space opens a
// date_picker in a popover, a pick closes it, Escape or a press elsewhere
// dismisses it. Accessibility: Combo_Box named `label` with the date as
// its value, with a popup, Expanded while open.
//
//	baldr.date_field(ui, s.date, proc(e: baldr.Ev(baldr.Date)) -> Msg { return Set_Date{e.value} }, label = "Due")
date_field :: proc(ui: ^Ui($Msg), date: Date, on_change: Handler(Msg, Date) = nil, label: string = "Date",
	min: Date = {}, max: Date = {}, week_start: Week_Start = .Locale, width: f32 = 170, disabled := false,
	tag: u64 = 0, key: u64 = 0, loc := #caller_location) -> Node {
	t := &ui.tree
	th := &t.theme
	lk := field_look(th)
	n, created := reconcile_child(ui, .Box, key, loc)
	d := node_get(t, n)
	if created {
		d.access.role = .Combo_Box
		d.flags += {.Focusable, .Clips}
		ui.open[n] = false
	}
	d.tag = tag
	set_name(t, n, label)
	set_disabled(t, n, disabled)
	shown := date_short(t, date) if date_valid(date) else ""
	if full := date_text(t, date); d.access.describe != full do set_describe(t, n, full)
	is_open := ui.open[n]
	popup_states(d, is_open) // it opens a popup: Has_Popup, Expanded while open
	set_layout(t, n, Layout_Props{axis = .Row, align = .Center, justify = .Space_Between, width = width, min_h = lk.min_height,
		padding = lk.dropdown_padding, gap = lk.gap})
	st := d.style
	st.bg = lk.fill
	st.radius = lk.radius
	st.border_w = lk.focus_border_width if is_open else lk.border_width
	st.border = lk.focus_border if is_open else lk.border
	set_style(t, n, st)
	open_scope(ui, n, loc)
	vsize, vfam := field_value_size(t, lk), field_value_family(t, lk)
	lbl := text(ui, shown if shown != "" else "Pick a date", size = vsize, color = lk.placeholder if shown == "" else lk.ink,
		nowrap = true, weight = lk.value_weight, family = vfam, loc = loc)
	set_role(t, lbl, .None)
	baldr_icon(ui, .Calendar, lk.icon_size, lk.icon, loc)
	close_scope(ui)
	if is_open && !disabled {
		k := (u64(n) * 0x9E37_79B9_7F4A_7C15) | 1
		pop, pcreated := overlay_begin(ui, k, loc)
		popover_style(ui, pop, pcreated, n, .Below, 0, true)
		set_rule(ui, pop, Dismiss_Rule(Msg){owner = n, anchor = n, inside = pop, restore = n})
		cal := date_picker(ui, date, on_change, label = label, min = min, max = max, week_start = week_start, loc = loc)
		t.field_of_cal[cal] = n
		if pcreated do ui.pending_focus = pop
		end(ui)
	}
	return n
}
