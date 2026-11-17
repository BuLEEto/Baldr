package baldr

// radio + segmented: one pick among a few. Both are a single Tab stop —
// the arrow keys move the pick (Home / End to the ends, wrapping) and send
// on_change; a click picks; the picked item shows the ring. radio lists
// options with a dot, down the page (or `horizontal`); segmented is a
// pill row whose picked segment glides. The pick is the app's state.
// Accessibility: a Radio_Group named `label` of Radios with the Checked state.
//
//	baldr.radio(ui, s.fruit, FRUITS, proc(e: baldr.Ev(int)) -> Msg { return Set_Fruit{e.value} }, label = "Fruit")
//	baldr.segmented(ui, s.density, {"Compact", "Comfortable", "Spacious"}, on_change = …, label = "Density")

import "base:runtime"


Choice_State :: struct {
	items:     [dynamic]Node, // in order, this build
	selected:  int,
	count:     int,
	segmented: bool,
	hug:       bool, // a segmented control sized to its labels: the track is painted under its segments only
}

radio :: proc(ui: ^Ui($Msg), selected: int, options: []string, on_change: Handler(Msg, int) = nil, label: string = "",
	horizontal := false, disabled := false, tag: u64 = 0, key: u64 = 0, loc := #caller_location) -> Node {
	t := &ui.tree
	th := &t.theme
	lk := check_look(th)
	n := choice_group(ui, selected, len(options), false, label, disabled, tag, key, loc)
	set_layout(t, n, Layout_Props{axis = .Row if horizontal else .Column, gap = lk.radio_gap_horizontal if horizontal else lk.radio_gap, align = .Start})
	ui.on_int[n] = on_change
	family := look_family(t, lk.text.family)
	dot_size := [2]f32{lk.indicator_size, lk.indicator_size}
	open_scope(ui, n, loc)
	for opt, i in options {
		item := choice_item(ui, n, i, selected == i, on_change, loc)
		set_name(t, item, opt)
		set_layout(t, item, Layout_Props{axis = .Row, align = .Center, gap = lk.gap, padding = lk.radio_padding})
		st := node_get(t, item).style
		st.radius = lk.radius
		st.bg = {}
		set_style(t, item, st)
		open_scope(ui, item, loc)
		dot, dcreated := reconcile_child(ui, .Custom, 0, loc)
		dd := node_get(t, dot)
		if ck, ok := dd.kind.(Custom_Kind); !ok || dcreated || ck.size != dot_size { // every build, so a theme change reaches it
			dd.kind = Custom_Kind{size = dot_size, paint = paint_radio_dot}
			mark_layout_dirty(t, dot)
		}
		lbl := text(ui, opt, role = lk.text.role, size = lk.text.size, color = lk.ink, weight = lk.text.weight, family = family, loc = loc)
		set_role(t, lbl, .None)
		close_scope(ui)
	}
	close_scope(ui)
	return n
}

// segmented is a pill row of segments, one picked. It sizes to its labels;
// give it a `width` (or `flex` in a row) to spread the segments across it:
// equal while each fits an equal share; else the ones that need more keep
// their width and the rest share what is left alike; then their padding
// tightens alike; only then are the widest labels cut to one width, ending
// in "…" (the whole label stays the segment's name). `icons`, one per
// segment (.None to skip one), go before the labels in the labels' colour
// (a power mode's leaf, gauge and bolt).
segmented :: proc(ui: ^Ui($Msg), selected: int, labels: []string, on_change: Handler(Msg, int) = nil, icons: []Icon = nil, label: string = "",
	width: f32 = 0, flex: f32 = 0, disabled := false, tag: u64 = 0, key: u64 = 0, loc := #caller_location) -> Node {
	t := &ui.tree
	th := &t.theme
	lk := segmented_look(th)
	n := choice_group(ui, selected, len(labels), true, label, disabled, tag, key, loc)
	set_layout(t, n, Layout_Props{axis = .Row, align = .Center, padding = lk.track_padding, width = width, flex = flex})
	spread: f32 = 1 if width > 0 || flex > 0 else 0
	cs := &t.choices[n]
	if cs.hug != (spread == 0) {
		cs.hug = spread == 0
		mark_paint_dirty(t, n)
	}
	st := node_get(t, n).style
	st.bg = {} if cs.hug else lk.track // stretched by its parent, a hugging track stays under the segments (paint_choice_under)
	st.radius = lk.radius
	set_style(t, n, st)
	ui.on_int[n] = on_change
	family := look_family(t, lk.text.family)
	open_scope(ui, n, loc)
	for lab, i in labels {
		item := choice_item(ui, n, i, selected == i, on_change, loc)
		set_name(t, item, lab)
		set_layout(t, item, Layout_Props{axis = .Row, align = .Center, justify = .Center, gap = lk.gap,
			padding = {lk.padding_y, lk.min_padding_x, lk.padding_y, lk.min_padding_x}}) // segmented_measure gives each its width, up to padding_x either side
		ist := node_get(t, item).style
		ist.radius = lk.segment_radius
		ist.bg = {}
		set_style(t, item, ist)
		open_scope(ui, item, loc)
		fg := lk.selected_ink if selected == i else lk.ink
		if i < len(icons) && icons[i] != .None do baldr_icon(ui, icons[i], lk.icon_size, fg, loc, key = u64(Control_Part.Icon)) // decorative: the segment is named by its label
		lbl := text(ui, lab, role = lk.text.role, size = lk.text.size, color = fg, nowrap = true, ellipsis = .End, weight = lk.text.weight, family = family, key = u64(Control_Part.Label), loc = loc)
		set_role(t, lbl, .None)
		close_scope(ui)
	}
	close_scope(ui)
	return n
}

// segmented_measure lays a segmented control's segments side by side at
// the widths segment_widths shares out: across the width it is given, or
// as wide as its segments want when it hugs (down to what its parent
// allows). Every segment is as tall as the tallest.
@(private)
segmented_measure :: proc(t: ^Tree, n: Node, d: ^Node_Data, cc: Constraints) -> [2]f32 {
	pad := d.layout.padding
	lk := segmented_look(&t.theme)
	slack := 2 * (lk.padding_x - lk.min_padding_x) // the padding a segment gives up before its label is cut
	items := make([dynamic]Node, context.temp_allocator)
	content := make([dynamic]f32, context.temp_allocator)
	tallest: f32
	for c := d.first; c != NODE_NONE; c = node_get(t, c).next {
		if .Hidden in node_get(t, c).flags {
			layout_node(t, c, constraints_loose({0, 0}))
			continue
		}
		size := layout_node(t, c, constraints_loose({UNBOUNDED, UNBOUNDED}))
		append(&items, c)
		append(&content, size.x)
		tallest = max(tallest, size.y)
	}
	want: f32
	for w in content do want += w + slack
	inner := want
	if is_bounded(cc.max.x) {
		room := max(cc.max.x - pad[1] - pad[3], 0)
		cs, ok := t.choices[n]
		inner = min(want, room) if ok && cs.hug else room
	}
	widths := make([]f32, len(items), context.temp_allocator)
	segment_widths(content[:], slack, inner, widths)
	size := constrain(cc, {pad[3] + inner + pad[1], pad[0] + tallest + pad[2]})
	x := pad[3]
	y := pad[0] + max(size.y - pad[0] - pad[2] - tallest, 0) / 2
	for c, i in items {
		layout_node(t, c, constraints_tight({widths[i], tallest}))
		cd := node_get(t, c)
		cd.rect.x, cd.rect.y = x, y
		x += widths[i]
	}
	return size
}

// segment_widths shares `inner` px among segments whose content, at their
// tightest padding, is `content` wide, each taking up to `slack` more as
// padding. Equal while every one fits an equal share with its padding;
// else the ones that need more keep their width and the rest share what is
// left alike; then all give up padding alike; then the widest are cut to
// one width, the rest keeping their content's.
@(private)
segment_widths :: proc(content: []f32, slack, inner: f32, out: []f32) {
	count := len(content)
	if count == 0 do return
	most, total: f32
	for c in content {
		most = max(most, c)
		total += c
	}
	share := inner / f32(count)
	switch {
	case share >= most + slack:
		for &w in out do w = share
	case total + f32(count) * slack <= inner:
		// widest first: one that needs more than an equal share of what is left keeps its width
		for &w in out do w = -1
		left, rest := inner, count
		for rest > 0 {
			widest := -1
			for c, i in content do if out[i] < 0 && (widest < 0 || c > content[widest]) do widest = i
			if content[widest] + slack <= left / f32(rest) do break
			out[widest] = content[widest] + slack
			left -= out[widest]
			rest -= 1
		}
		for &w in out do if w < 0 do w = left / f32(rest)
	case total <= inner:
		give := (total + f32(count) * slack - inner) / f32(count)
		for c, i in content do out[i] = c + slack - give
	case:
		// narrowest first: one that fits an equal share of what is left keeps its content's width
		for &w in out do w = -1
		left, rest := max(inner, 0), count
		for rest > 0 {
			narrowest := -1
			for c, i in content do if out[i] < 0 && (narrowest < 0 || c < content[narrowest]) do narrowest = i
			if content[narrowest] > left / f32(rest) do break
			out[narrowest] = content[narrowest]
			left -= out[narrowest]
			rest -= 1
		}
		for &w in out do if w < 0 do w = left / f32(rest)
	}
}

// choice_group is the shared container: a focusable Group that paints the
// pill (segmented) under its items and the ring around the picked one.
@(private)
choice_group :: proc(ui: ^Ui($Msg), selected, count: int, seg: bool, label: string, disabled: bool, tag, key: u64, loc: runtime.Source_Code_Location) -> Node {
	t := &ui.tree
	n, created := reconcile_child(ui, .Custom, key, loc)
	d := node_get(t, n)
	if created {
		d.access.role = .Radio_Group // a radio list and a segmented control are both "one pick among a few"
		d.flags += {.Focusable, .Ring_Inside}
		d.kind = Custom_Kind{paint = paint_choice_under, paint_over = paint_choice_over}
		if seg do d.kind = Custom_Kind{paint = paint_choice_under, paint_over = paint_choice_over, measure = segmented_measure, overhang = 4} // the pill's shadow
		t.choices[n] = {items = make([dynamic]Node, t.allocator)}
	}
	d.tag = tag
	set_name(t, n, label)
	set_disabled(t, n, disabled)
	cs := &t.choices[n]
	clear(&cs.items)
	if cs.selected != selected do mark_paint_dirty(t, n)
	cs.selected, cs.count, cs.segmented = selected, count, seg
	return n
}

@(private)
choice_item :: proc(ui: ^Ui($Msg), group: Node, i: int, picked: bool, on_change: Handler(Msg, int), loc: runtime.Source_Code_Location) -> Node {
	t := &ui.tree
	item, created := reconcile_child(ui, .Box, u64(i + 1), loc)
	d := node_get(t, item)
	if created {
		d.access.role = .Radio // not Focusable: the group is the Tab stop
		t.choice_of[item] = group
	}
	d.tag = u64(i)
	set_checked(t, item, picked)
	// The group keeps the focus, so the arrows change nothing a screen reader
	// would announce; naming the picked option as the group's active
	// descendant (as a table, tree and icon view do) is what makes it speak.
	if picked do set_active_item(t, group, item)
	ui.on_int[item] = on_change
	cs := &t.choices[group]
	append(&cs.items, item)
	return item
}

// choice_key moves a focused group's pick with the arrows, Home and End.
choice_key :: proc(ui: ^Ui($Msg), key: Key, mods: Mods) -> bool {
	t := &ui.tree
	cs, ok := t.choices[t.focus]
	if !ok || cs.count == 0 || .Disabled in node_get(t, t.focus).flags do return false
	next := cs.selected
	#partial switch key {
	case .Down, .Right: next = (cs.selected + 1) % cs.count
	case .Up, .Left:    next = (cs.selected - 1 + cs.count) % cs.count
	case .Home:         next = 0
	case .End:          next = cs.count - 1
	case: return false
	}
	if next == cs.selected do return true
	if h, has := ui.on_int[t.focus]; has do handler_send(ui, h, next, t.focus)
	return true
}

// paint_radio_dot: a ring that fills with the accent, the dot growing in.
@(private)
paint_radio_dot :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer) {
	th := &t.theme
	item := node_get(t, d.parent)
	if item == nil do return
	on := .Checked in item.access.states
	k := anim_target(t, n, .Value, 1 if on else 0, th.motion.fast)
	lk := check_look(th)
	r := d.abs
	border := mix(lk.border, lk.selected_fill, k)
	border.a *= t.paint_opacity
	if .Disabled in item.flags || (node_get(t, item.parent) != nil && .Disabled in node_get(t, item.parent).flags) do border.a *= th.state.disabled_alpha
	append(&l.cmds, Draw_Rect{rect = r, radius = r.w / 2, border_w = lk.radio_border_width, border = border})
	if k > 0.01 {
		c := lk.selected_fill
		c.a *= t.paint_opacity * border.a / max(lk.selected_fill.a, 0.001)
		dr := r.w * 0.5 * k
		append(&l.cmds, Draw_Rect{rect = {r.x + (r.w - dr) / 2, r.y + (r.h - dr) / 2, dr, dr}, radius = dr / 2, color = c})
	}
}

// paint_choice_under draws a segmented control's pill gliding between the
// items (the group's Value anim is the picked index, interpolated).
@(private)
paint_choice_under :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer) {
	cs, ok := t.choices[n]
	if !ok || !cs.segmented || len(cs.items) == 0 do return
	th := &t.theme
	lk := segmented_look(th)
	if cs.hug {
		first, last := node_get(t, cs.items[0]), node_get(t, cs.items[len(cs.items) - 1])
		if first != nil && last != nil {
			x0, x1 := first.abs.x - d.layout.padding[3], last.abs.x + last.abs.w + d.layout.padding[1]
			track := lk.track
			track.a *= t.paint_opacity
			if .Disabled in d.flags do track.a *= th.state.disabled_alpha
			append(&l.cmds, Draw_Rect{rect = {x0, d.abs.y, x1 - x0, d.abs.h}, radius = min(lk.radius, d.abs.h / 2), color = track})
		}
	}
	k := anim_target(t, n, .Value, f32(clamp(cs.selected, 0, len(cs.items) - 1)), th.motion.base)
	i0 := clamp(int(k), 0, len(cs.items) - 1)
	i1 := clamp(i0 + 1, 0, len(cs.items) - 1)
	f := clamp(k - f32(i0), 0, 1)
	a, b := node_get(t, cs.items[i0]), node_get(t, cs.items[i1])
	if a == nil || b == nil do return
	r := Rect{a.abs.x + (b.abs.x - a.abs.x) * f, a.abs.y, a.abs.w + (b.abs.w - a.abs.w) * f, a.abs.h}
	whole := r
	r = rect_clip(r, d.abs) // squeezed shorter or narrower than its segments, the pill stays inside the control
	if r.w <= 0 || r.h <= 0 do return
	squeezed := r != whole
	bg := lk.selected_fill
	bg.a *= t.paint_opacity
	sh := lk.selected_shadow
	sc := sh.color
	sc.a *= t.paint_opacity
	if .Disabled in d.flags {
		bg.a *= th.state.disabled_alpha
		sc.a *= th.state.disabled_alpha
	}
	rad := min(lk.segment_radius, r.h / 2)
	if !squeezed do append(&l.cmds, Draw_Shadow{rect = {r.x + sh.offset.x, r.y + sh.offset.y, r.w, r.h}, radius = rad, blur = sh.blur, color = sc}) // its shadow would reach past the control
	append(&l.cmds, Draw_Rect{rect = r, radius = rad, color = bg})
}

// choice_track is the groove a segmented control's picked segment sits in.
// It is `surface_variant`, which is also a card's colour, and in a light
// theme the two jobs pull opposite ways; when the track is too close to the
// segment to tell apart, it steps away from it. The widget reads it through
// segmented_look, which steps away from whatever the picked segment is filled with.
@(private)
choice_track :: proc(th: ^Theme) -> Color {
	return choice_track_from(th, th.color.surface_high)
}

// CHOICE_TRACK_SEPARATION: how far the picked segment stands off its track.
// Dim's ladder gives 1.23:1 and reads well; this is the floor under it.
@(private)
CHOICE_TRACK_SEPARATION :: f32(1.18)

// paint_choice_over draws the focus ring around the picked item.
@(private)
paint_choice_over :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer) {
	cs, ok := t.choices[n]
	if !ok || t.focus != n || !ring_shown(t) do return
	focus_t := anim_target(t, n, .Focus, 1, t.theme.motion.fast)
	if cs.selected < 0 || cs.selected >= len(cs.items) do return
	id := node_get(t, cs.items[cs.selected])
	if id == nil do return
	ring := focus_ring_look(&t.theme)
	col := ring.color
	col.a *= focus_t * t.paint_opacity
	rad := id.style.radius
	if cs.segmented do rad = min(segmented_look(&t.theme).segment_radius, id.abs.h / 2)
	o := ring.outset
	append(&l.cmds, Draw_Rect{rect = {id.abs.x - o, id.abs.y - o, id.abs.w + 2 * o, id.abs.h + 2 * o}, radius = rad + o, border_w = ring.width, border = col})
}
