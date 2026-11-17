package baldr

// time_picker: one field with hour, minute, optional second and AM / PM
// segments. Click a segment (or Left / Right) to pick it, then type the
// digits, press Up / Down (Shift: ten minutes), turn the wheel, or drag up
// and down on it; A and P set the period; Home / End go to the ends. It
// is one Tab stop; the picked segment carries the ring; a click on AM /
// PM flips it. `clock` follows
// the locale unless forced to 12 or 24 hours; `seconds` shows a third
// segment. The time is the app's state and on_change carries the new one
// — a wall-clock Time_Of_Day with no zone: what it means (local, UTC) is
// the app's call, and core:time converts instants either way.
// Accessibility: a Group named `label` of Spin_Buttons "Hour", "Minute",
// "Second" and "AM / PM", each with its value; on touch, ▲ ▼ buttons
// nudge the picked segment.
//
//	baldr.time_picker(ui, s.alarm, proc(e: baldr.Ev(baldr.Time_Of_Day)) -> Msg { return Set_Alarm{e.value} })
//	baldr.time_field(ui, s.alarm, …, label = "Alarm")   // the drop-down form

import "base:runtime"
import "core:fmt"
import "core:time"
import dt "core:time/datetime"
import "core:time/timezone"

// Time_Of_Day is a wall-clock time — hour, minute, second, nanosecond — with
// no date and no zone. It is what `time_field` and `time_picker` read and
// report.
Time_Of_Day :: dt.Time // hour, minute, second, nano

// Clock: how hours are shown — the locale's way, or forced.
Clock :: enum u8 { Locale, H24, H12 }

TIME_SEG_H  :: f32(28)
TIME_SCRUB_PX :: f32(10) // pointer travel per step when dragging a segment

// Time_Seg is one editable part of a time — the hours, the minutes, the
// seconds, or AM/PM — which is also the unit the arrow keys and a scrub move.
Time_Seg :: enum u8 { Hour, Minute, Second, Period }

Time_State :: struct {
	segs:    [Time_Seg]Node, // NONE when not shown
	cursor:  Time_Seg,       // the picked segment
	value:   Time_Of_Day,    // shown; follows the app's `time` when it changes
	last:    Time_Of_Day,    // what the app passed last build
	twelve:  bool,
	seconds: bool,
	typed:   u8,             // digits typed into the picked segment so far (0, 1)
	touch_nudge: [2]Node,    // ▲ ▼ on touch
	built_focused: bool,     // the picked highlight was built for a focused field
}

// Time_Scrub is a drag on one segment of a time picker: where it started and
// what the segment read then, so the gesture is relative to the press.
Time_Scrub :: struct {
	picker:  Node,
	seg:     Time_Seg,
	start_y: f32,
	start:   int, // the segment's value at the press
	moved:   bool,
}

// now_local is the clock here — the desktop's zone, read from the OS (TZ
// or /etc/localtime on Unix, the registry on Windows); now_utc is the
// same instant in UTC. Both are what a form usually starts from.
now_local :: proc() -> Time_Of_Day { return time_of_day(time.now(), local = true) }
now_utc   :: proc() -> Time_Of_Day { return time_of_day(time.now(), local = false) }

// time_of_day is the clock reading of an instant, in UTC or in the
// desktop's zone. The zone data is read on each local call (a few small
// file reads on Unix, temp-allocated), so keep it out of per-frame code;
// an unreadable zone falls back to UTC.
time_of_day :: proc(t: time.Time, local := false) -> Time_Of_Day {
	d, ok := time.time_to_datetime(t)
	if !ok do return {}
	if local {
		if reg, loaded := timezone.region_load("local", context.temp_allocator); loaded {
			if ld, converted := timezone.datetime_to_tz(d, reg); converted do d = ld
		}
	}
	return d.time
}

// time_text writes a time the locale's way: "07:30", "07:30:05", "7:30 PM",
// in the frame's temp memory.
time_text :: proc(t: ^Tree, tm: Time_Of_Day, seconds := false, clock: Clock = .Locale) -> string {
	twelve := clock == .H12 || (clock == .Locale && !t.locale.time_24h)
	h := int(tm.hour)
	if twelve {
		period := t.locale.pm if h >= 12 else t.locale.am
		h = h % 12
		if h == 0 do h = 12
		if seconds do return fmt.tprintf("%d:%02d:%02d %s", h, tm.minute, tm.second, period)
		return fmt.tprintf("%d:%02d %s", h, tm.minute, period)
	}
	if seconds do return fmt.tprintf("%02d:%02d:%02d", h, tm.minute, tm.second)
	return fmt.tprintf("%02d:%02d", h, tm.minute)
}

time_picker :: proc(ui: ^Ui($Msg), time: Time_Of_Day, on_change: Handler(Msg, Time_Of_Day) = nil, label: string = "Time",
	clock: Clock = .Locale, seconds := false, disabled := false, tag: u64 = 0, key: u64 = 0, loc := #caller_location) -> Node {
	t := &ui.tree
	th := &t.theme
	n, created := reconcile_child(ui, .Custom, key, loc)
	d := node_get(t, n)
	if created {
		d.access.role = .Group
		d.flags += {.Focusable, .Ring_Inside}
		d.kind = Custom_Kind{paint_over = paint_time_over}
		t.times[n] = {value = time, last = time}
	}
	d.tag = tag
	set_name(t, n, label)
	set_disabled(t, n, disabled)
	ts := &t.times[n]
	if time != ts.last { // the app changed it: the field follows
		ts.value = time
		ts.last = time
		ts.typed = 0
	}
	ts.twelve = clock == .H12 || (clock == .Locale && !t.locale.time_24h)
	ts.seconds = seconds
	if !seconds && ts.cursor == .Second do ts.cursor = .Minute
	if !ts.twelve && ts.cursor == .Period do ts.cursor = .Hour
	ui.on_time[n] = on_change
	focused := t.focus == n
	ts.built_focused = focused
	set_layout(t, n, Layout_Props{axis = .Row, align = .Center, gap = th.space[.xxs], padding = {th.space[.xxs], th.space[.sm], th.space[.xxs], th.space[.sm]}})
	lk := field_look(th) // the frame is a field's; the segments are the picker's own
	st := d.style
	st.bg = lk.fill
	st.radius = lk.radius
	st.border_w = lk.focus_border_width if focused else lk.border_width
	st.border = lk.focus_border if focused else lk.border
	set_style(t, n, st)
	d.access.value_text = time_text(t, ts.value, seconds, clock)

	open_scope(ui, n, loc)
	h := int(ts.value.hour)
	if ts.twelve {
		h = h % 12
		if h == 0 do h = 12
	}
	ts.segs[.Hour] = time_seg(ui, n, .Hour, "Hour", fmt.tprintf("%d" if ts.twelve else "%02d", h), f32(ts.value.hour), disabled, 1, loc)
	time_colon(ui, 2, loc)
	ts.segs[.Minute] = time_seg(ui, n, .Minute, "Minute", fmt.tprintf("%02d", ts.value.minute), f32(ts.value.minute), disabled, 3, loc)
	if seconds {
		time_colon(ui, 4, loc)
		ts.segs[.Second] = time_seg(ui, n, .Second, "Second", fmt.tprintf("%02d", ts.value.second), f32(ts.value.second), disabled, 5, loc)
	} else {
		ts.segs[.Second] = NODE_NONE
	}
	if ts.twelve {
		sp := text(ui, " ", role = .Label, key = 6, loc = loc)
		set_role(t, sp, .None)
		ts.segs[.Period] = time_seg(ui, n, .Period, "AM / PM", t.locale.pm if ts.value.hour >= 12 else t.locale.am, 1 if ts.value.hour >= 12 else 0, disabled, 7, loc)
	} else {
		ts.segs[.Period] = NODE_NONE
	}
	if t.touch && !disabled {
		// ▲ ▼ for the picked segment: a finger cannot type or scroll a wheel
		col := column(ui, gap = .none, key = 8, loc = loc)
		set_layout(t, col, Layout_Props{axis = .Column, align = .Center, padding = {0, 0, 0, th.space[.xs]}})
		ts.touch_nudge[0] = time_nudge(ui, n, +1, .Chevron_Up, "Up", 1, loc)
		ts.touch_nudge[1] = time_nudge(ui, n, -1, .Chevron_Down, "Down", 2, loc)
		end(ui)
	} else {
		ts.touch_nudge = {NODE_NONE, NODE_NONE}
	}
	close_scope(ui)
	return n
}

@(private)
time_seg :: proc(ui: ^Ui($Msg), picker: Node, seg: Time_Seg, name, shown: string, value: f32, disabled: bool, key: u64, loc: runtime.Source_Code_Location) -> Node {
	t := &ui.tree
	th := &t.theme
	n, created := reconcile_child(ui, .Box, key, loc)
	d := node_get(t, n)
	if created {
		d.access.role = .Spin_Button // picked by click or arrows; the picker is the Tab stop
		t.time_seg_of[n] = picker
	}
	d.tag = u64(seg)
	set_name(t, n, name)
	set_disabled(t, n, disabled)
	d.access.has_value = true
	d.access.value = value
	ts := t.times[picker]
	picked := ts.cursor == seg && t.focus == picker
	set_layout(t, n, Layout_Props{axis = .Row, align = .Center, justify = .Center, padding = {th.space[.xxs], th.space[.xs], th.space[.xxs], th.space[.xs]}, height = TIME_SEG_H})
	st := d.style
	st.radius = th.radius.sm
	st.bg = th.color.primary_container if picked else Color{}
	set_style(t, n, st)
	open_scope(ui, n, loc)
	lbl := text(ui, shown, role = .Label, color = th.color.on_primary_container if picked else th.color.on_surface, nowrap = true, loc = loc)
	set_role(t, lbl, .None)
	close_scope(ui)
	return n
}

@(private)
time_colon :: proc(ui: ^Ui($Msg), key: u64, loc: runtime.Source_Code_Location) {
	c := text(ui, ":", role = .Label, muted = true, key = key, loc = loc)
	set_role(&ui.tree, c, .None)
}

@(private)
time_nudge :: proc(ui: ^Ui($Msg), picker: Node, dir: int, ic: Icon, name: string, key: u64, loc: runtime.Source_Code_Location) -> Node {
	t := &ui.tree
	th := &t.theme
	b, created := reconcile_child(ui, .Box, key, loc)
	d := node_get(t, b)
	if created do d.access.role = .Button // not a Tab stop: the keys do this
	set_name(t, b, name)
	d.tag = u64(dir + 1) // 0 = down, 2 = up
	t.time_seg_of[b] = picker
	set_layout(t, b, Layout_Props{axis = .Row, align = .Center, justify = .Center, width = 28, height = 20})
	open_scope(ui, b, loc)
	baldr_icon(ui, ic, 14, th.color.on_surface_muted, loc)
	close_scope(ui)
	return b
}

// ------------------------------------------------------------ editing

@(private)
time_seg_value :: proc "contextless" (ts: ^Time_State, seg: Time_Seg) -> int {
	switch seg {
	case .Hour:   return int(ts.value.hour)
	case .Minute: return int(ts.value.minute)
	case .Second: return int(ts.value.second)
	case .Period: return 1 if ts.value.hour >= 12 else 0
	}
	return 0
}

// time_set_seg sets one segment (wrapping), and tells the app.
@(private)
time_set_seg :: proc(ui: ^Ui($Msg), picker: Node, seg: Time_Seg, v: int) -> bool {
	t := &ui.tree
	ts, ok := &t.times[picker]
	if !ok do return false
	nv := ts.value
	switch seg {
	case .Hour:   nv.hour = i8(((v % 24) + 24) % 24)
	case .Minute: nv.minute = i8(((v % 60) + 60) % 60)
	case .Second: nv.second = i8(((v % 60) + 60) % 60)
	case .Period:
		pm := v != 0
		h := int(nv.hour) % 12
		nv.hour = i8(h + 12 if pm else h)
	}
	if nv == ts.value do return true
	ts.value = nv
	ts.last = nv
	ask_rebuild(ui)
	if h, has := ui.on_time[picker]; has do handler_send(ui, h, nv, picker)
	return true
}

// time_step nudges the picked segment by `dir` steps; a 12-hour hour
// wraps within its half of the day.
@(private)
time_step :: proc(ui: ^Ui($Msg), picker: Node, dir: int) -> bool {
	t := &ui.tree
	ts, ok := &t.times[picker]
	if !ok do return false
	seg := ts.cursor
	v := time_seg_value(ts, seg)
	switch seg {
	case .Hour:
		if ts.twelve {
			h := v % 12
			h = ((h + dir) % 12 + 12) % 12
			v = h + (12 if v >= 12 else 0)
		} else {
			v += dir
		}
	case .Minute, .Second: v += dir
	case .Period: v = 1 - v
	}
	ts.typed = 0
	return time_set_seg(ui, picker, seg, v)
}

@(private)
time_pick_seg :: proc(ui: ^Ui($Msg), picker: Node, seg: Time_Seg, by_key: bool) {
	t := &ui.tree
	ts, ok := &t.times[picker]
	if !ok do return
	if ts.segs[seg] == NODE_NONE do return
	if ts.cursor != seg {
		ts.cursor = seg
		ts.typed = 0
		ask_rebuild(ui)
	}
	set_focus(t, picker, by_key) // the ring shows after keys, not after a click
	mark_paint_dirty(t, picker)
}

@(private)
time_seg_next :: proc(ts: ^Time_State, from: Time_Seg, dir: int) -> Time_Seg {
	order := [4]Time_Seg{.Hour, .Minute, .Second, .Period}
	i := 0
	for s, k in order do if s == from do i = k
	for _ in 0 ..< 4 {
		i = ((i + dir) % 4 + 4) % 4
		if ts.segs[order[i]] != NODE_NONE do return order[i]
	}
	return from
}

// time_seg_click: a click on a segment picks it, and on the AM / PM
// segment flips the period as well; on a ▲ ▼ it nudges.
@(private)
time_seg_click :: proc(ui: ^Ui($Msg), n: Node) -> bool {
	t := &ui.tree
	picker, ok := t.time_seg_of[n]
	if !ok do return false
	d := node_get(t, n)
	if d == nil do return false
	if d.access.role == .Button { // ▲ / ▼
		set_focus(t, picker, false)
		return time_step(ui, picker, 1 if d.tag == 2 else -1)
	}
	seg := Time_Seg(d.tag)
	time_pick_seg(ui, picker, seg, false)
	if seg == .Period do return time_step(ui, picker, 1) // two values: a click flips it
	return true
}

// time_key: arrows and Home / End on the focused picker.
time_key :: proc(ui: ^Ui($Msg), key: Key, mods: Mods) -> bool {
	t := &ui.tree
	picker := t.focus
	ts, ok := &t.times[picker]
	if !ok do return false
	if d := node_get(t, picker); d == nil || .Disabled in d.flags do return false
	#partial switch key {
	case .Up:    return time_step(ui, picker, 10 if .Shift in mods && ts.cursor != .Hour && ts.cursor != .Period else 1)
	case .Down:  return time_step(ui, picker, -10 if .Shift in mods && ts.cursor != .Hour && ts.cursor != .Period else -1)
	case .Left:  time_pick_seg(ui, picker, time_seg_next(ts, ts.cursor, -1), true); return true
	case .Right: time_pick_seg(ui, picker, time_seg_next(ts, ts.cursor, +1), true); return true
	case .Home:
		ts.typed = 0
		v := 0
		if ts.cursor == .Hour && ts.twelve do v = 12 if ts.value.hour >= 12 else 0
		return time_set_seg(ui, picker, ts.cursor, v)
	case .End:
		ts.typed = 0
		v := 59
		if ts.cursor == .Hour do v = 23 if ts.value.hour >= 12 || !ts.twelve else 11
		if ts.cursor == .Period do v = 1
		return time_set_seg(ui, picker, ts.cursor, v)
	case .Backspace, .Delete:
		ts.typed = 0
		return time_set_seg(ui, picker, ts.cursor, 0 if ts.cursor != .Hour || !ts.twelve else (12 if ts.value.hour >= 12 else 0))
	}
	return false
}

// time_type: digits typed into the picked segment (two per segment, the
// first alone when a second could not fit), A / P for the period. Called
// with committed text.
time_type :: proc(ui: ^Ui($Msg), s: string) -> bool {
	t := &ui.tree
	picker := t.focus
	ts, ok := &t.times[picker]
	if !ok || len(s) == 0 do return false
	if d := node_get(t, picker); d == nil || .Disabled in d.flags do return false
	c := s[0]
	if ts.cursor == .Period || (ts.segs[.Period] != NODE_NONE && (c == 'a' || c == 'A' || c == 'p' || c == 'P')) {
		switch c {
		case 'a', 'A': time_set_seg(ui, picker, .Period, 0); return true
		case 'p', 'P': time_set_seg(ui, picker, .Period, 1); return true
		}
		return ts.cursor == .Period
	}
	if c < '0' || c > '9' do return false
	digit := int(c - '0')
	seg := ts.cursor
	limit := 59
	if seg == .Hour do limit = 12 if ts.twelve else 23
	v: int
	advance := false
	if ts.typed == 0 {
		v = digit
		first_max := limit / 10 // a second digit can still follow when the first is at most this
		if seg == .Hour && ts.twelve { first_max = 1 }
		if digit > first_max { advance = true } else { ts.typed = 1 }
	} else {
		v = ts_first_digit(ts, seg) * 10 + digit
		if v > limit do v = digit
		advance = true
		ts.typed = 0
	}
	if seg == .Hour && ts.twelve {
		if v == 0 do v = 12
		pm := ts.value.hour >= 12
		v = v % 12 + (12 if pm else 0)
	}
	time_set_seg(ui, picker, seg, v)
	if advance {
		ts.typed = 0
		next := time_seg_next(ts, seg, +1)
		if next != seg && (seg != time_seg_last(ts)) do time_pick_seg(ui, picker, next, true)
	}
	return true
}

@(private)
ts_first_digit :: proc "contextless" (ts: ^Time_State, seg: Time_Seg) -> int {
	v := time_seg_value(ts, seg)
	if seg == .Hour && ts.twelve {
		v = v % 12
		if v == 0 do v = 12
	}
	return v % 10 // after one typed digit the segment holds just that digit
}

@(private)
time_seg_last :: proc "contextless" (ts: ^Time_State) -> Time_Seg {
	if ts.segs[.Period] != NODE_NONE do return .Period
	if ts.segs[.Second] != NODE_NONE do return .Second
	return .Minute
}

// time_wheel: the wheel over a segment steps it. Returns true if consumed.
@(private)
time_wheel :: proc(ui: ^Ui($Msg), hit: Node, delta: [2]f32) -> bool {
	t := &ui.tree
	for cur := hit; cur != NODE_NONE; {
		if picker, ok := t.time_seg_of[cur]; ok {
			d := node_get(t, cur)
			if d.access.role != .Spin_Button do return false
			time_pick_seg(ui, picker, Time_Seg(d.tag), false)
			if delta.y == 0 do return true
			return time_step(ui, picker, -1 if delta.y > 0 else 1)
		}
		d := node_get(t, cur)
		if d == nil do break
		cur = d.parent
	}
	return false
}

// time_scrub_press starts a drag on a segment (release without travel is
// the click); time_scrub_move steps it every TIME_SCRUB_PX of travel.
@(private)
time_scrub_press :: proc(ui: ^Ui($Msg), target: Node, pos: [2]f32) {
	t := &ui.tree
	picker, ok := t.time_seg_of[target]
	if !ok do return
	d := node_get(t, target)
	if d == nil || d.access.role != .Spin_Button do return
	ts := &t.times[picker]
	seg := Time_Seg(d.tag)
	ui.time_scrub = {picker = picker, seg = seg, start_y = pos.y, start = time_seg_value(ts, seg)}
}

@(private)
time_scrub_move :: proc(ui: ^Ui($Msg), pos: [2]f32) -> bool {
	sc := &ui.time_scrub
	if sc.picker == NODE_NONE do return false
	t := &ui.tree
	ts, ok := &t.times[sc.picker]
	if !ok {
		sc^ = {}
		return false
	}
	steps := int((sc.start_y - pos.y) / TIME_SCRUB_PX)
	if steps == 0 && !sc.moved do return false
	if !sc.moved {
		sc.moved = true
		time_pick_seg(ui, sc.picker, sc.seg, false)
		if p := node_get(t, ui.pointer.pressed); p != nil { // the press will not click
			p.flags -= {.Pressed}
			mark_paint_dirty(t, ui.pointer.pressed)
		}
		ui.pointer.pressed = NODE_NONE
	}
	v := sc.start + steps
	if sc.seg == .Hour && ts.twelve {
		pm := sc.start >= 12
		v = ((sc.start % 12 + steps) % 12 + 12) % 12 + (12 if pm else 0)
	}
	if sc.seg == .Period do v = 1 if steps > 0 else (0 if steps < 0 else sc.start)
	ts.typed = 0
	time_set_seg(ui, sc.picker, sc.seg, v)
	return true
}

@(private)
time_scrub_release :: proc(ui: ^Ui($Msg)) -> bool {
	if ui.time_scrub.picker == NODE_NONE do return false
	moved := ui.time_scrub.moved
	ui.time_scrub = {}
	return moved
}

// time_tick rebuilds a picker whose focus changed since it was built, so
// the picked segment's highlight follows focus (focus_first after a
// popover opens, a click elsewhere) without the app doing anything.
time_tick :: proc(ui: ^Ui($Msg)) {
	t := &ui.tree
	for n, ts in t.times do if (t.focus == n) != ts.built_focused {
		ask_rebuild(ui)
		return
	}
}

// paint_time_over draws the ring around the picked segment while focused.
@(private)
paint_time_over :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer) {
	ts, ok := &t.times[n]
	if !ok || t.focus != n || !ring_shown(t) do return
	sd := node_get(t, ts.segs[ts.cursor])
	if sd == nil do return
	focus_t := anim_target(t, n, .Focus, 1, t.theme.motion.fast)
	lk := focus_ring_look(&t.theme)
	col := lk.color
	col.a *= focus_t * t.paint_opacity
	w := lk.width // just outside the segment, with no gap
	append(&l.cmds, Draw_Rect{rect = {sd.abs.x - w, sd.abs.y - w, sd.abs.w + 2 * w, sd.abs.h + 2 * w}, radius = sd.style.radius + w, border_w = w, border = col})
}

// time_field is the drop-down form: shows the time the locale's way with
// a clock icon; click, Enter or Space open a time_picker in a popover,
// Enter inside it or Escape closes it. Accessibility: Combo_Box named
// `label` with the time as its value, with a popup, Expanded while open.
time_field :: proc(ui: ^Ui($Msg), time: Time_Of_Day, on_change: Handler(Msg, Time_Of_Day) = nil, label: string = "Time",
	clock: Clock = .Locale, seconds := false, width: f32 = 150, disabled := false, tag: u64 = 0, key: u64 = 0, loc := #caller_location) -> Node {
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
	shown := time_text(t, time, seconds, clock)
	d.access.value_text = shown
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
	lbl := text(ui, shown, size = vsize, color = lk.ink, nowrap = true, weight = lk.value_weight, family = vfam, loc = loc)
	set_role(t, lbl, .None)
	baldr_icon(ui, .Clock, lk.icon_size, lk.icon, loc)
	close_scope(ui)
	if is_open && !disabled {
		k := (u64(n) * 0x9E37_79B9_7F4A_7C15) | 1
		pop, pcreated := overlay_begin(ui, k, loc)
		popover_style(ui, pop, pcreated, n, .Below, 0, true)
		set_rule(ui, pop, Dismiss_Rule(Msg){owner = n, anchor = n, inside = pop, restore = n})
		pk := time_picker(ui, time, on_change, label = label, clock = clock, seconds = seconds, loc = loc)
		t.field_of_time[pk] = n
		if pcreated do ui.pending_focus = pop
		end(ui)
	}
	return n
}

// time_field_enter: Enter on a picker inside a time_field's popover closes it.
@(private)
time_field_enter :: proc(ui: ^Ui($Msg)) -> bool {
	t := &ui.tree
	field, ok := t.field_of_time[t.focus]
	if !ok do return false
	ui.open[field] = false
	ask_rebuild(ui)
	set_focus(t, field, false)
	return true
}
