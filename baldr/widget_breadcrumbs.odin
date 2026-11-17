package baldr

// breadcrumbs: where you are, as a trail of links — Home › Pictures ›
// Wallpaper. Every part but the last is a button that sends on_change with
// its index; the last is the current place. When the trail does not fit
// the width it is given, the leading parts fold into a "…" link (to the
// nearest folded one) and as many of the nearest parts as fit stay
// readable, the parent and the current place always; at phone width a long
// trail folds to "… › parent › current". In a row, give it `flex` so it
// knows the room it has.
// Accessibility: a Group named `label` of Buttons; the current part is
// Text with Selected.
//
//	baldr.breadcrumbs(ui, parts, proc(e: baldr.Ev(int)) -> Msg { return Go_To{e.value} })

import "base:runtime"

breadcrumbs :: proc(ui: ^Ui($Msg), parts: []string, on_change: Handler(Msg, int) = nil, label: string = "Location",
	on_rest: Handler(Msg, Drag_Rest) = nil, flex: f32 = 0, key: u64 = 0, loc := #caller_location) -> Node {
	t := &ui.tree
	th := &t.theme
	n, created := reconcile_child(ui, .Box, key, loc)
	d := node_get(t, n)
	if created do d.access.role = .Group
	set_name(t, n, label)
	set_layout(t, n, Layout_Props{axis = .Row, align = .Center, gap = th.space[.xxs], flex = flex})
	open_scope(ui, n, loc)
	count := len(parts)
	room := crumbs_room(node_get(t, n))
	ui.crumbs[n] = room
	first_shown := crumbs_first_shown(t, parts, room, size_class(ui) == .Compact)
	if first_shown > 0 {
		crumb(ui, "…", first_shown - 1, on_change, on_rest, 0xB4EAD_0001, loc)
		crumb_sep(ui, 0xB4EAD_0002, loc)
	}
	for i in first_shown ..< count {
		if i == count - 1 {
			cur := text(ui, parts[i], role = .Label, nowrap = true, ellipsis = .End, key = u64(i + 1), loc = loc)
			cd := node_get(t, cur)
			cd.access.states += {.Selected}
			continue
		}
		crumb(ui, parts[i], i, on_change, on_rest, u64(i + 1), loc)
		crumb_sep(ui, u64(i + 1) | 0x5E00_0000, loc)
	}
	close_scope(ui)
	return n
}

CRUMB_SEP :: f32(14) // the chevron between parts

// crumbs_room is the width a trail may take: what its parent offers, or
// its own width when that is unbounded (0 before the first layout).
@(private)
crumbs_room :: proc(d: ^Node_Data) -> f32 {
	if d == nil do return 0
	if is_bounded(d.cached_c.max.x) && d.cached_c.max.x > 0 do return d.cached_c.max.x
	return d.rect.w
}

// crumbs_first_shown is the first part left readable: 0 when the trail
// fits `room` (or no room is known yet), else the nearest parts that fit
// after a "…", never fewer than the parent and the current place. At
// phone width a trail of more than three parts keeps only those two.
crumbs_first_shown :: proc(t: ^Tree, parts: []string, room: f32, compact: bool) -> int {
	count := len(parts)
	if count <= 2 do return 0
	if compact && count > 3 do return count - 2
	if room <= 0 || crumbs_width(t, parts, 0) <= room do return 0
	first := count - 2
	used := crumbs_width(t, parts, first)
	gap := t.theme.space[.xxs]
	for i := first - 1; i >= 1; i -= 1 {
		w := crumb_width(t, parts[i]) + CRUMB_SEP + 2 * gap
		if used + w > room do break
		used += w
		first = i
	}
	return first
}

// crumbs_width is the natural width of the trail from part `from` (with the
// "…" in front when `from` > 0).
@(private)
crumbs_width :: proc(t: ^Tree, parts: []string, from: int) -> f32 {
	count := len(parts)
	if count == 0 do return 0
	gap := t.theme.space[.xxs]
	w: f32
	if from > 0 do w += crumb_width(t, "…") + CRUMB_SEP + 2 * gap
	for i in from ..< count - 1 do w += crumb_width(t, parts[i]) + CRUMB_SEP + 2 * gap
	st := t.theme.type.label
	return w + text_measure(t, parts[count - 1], st.size, 0, st.weight, family = role_family(&t.theme, .Label)).x
}

@(private)
crumb_width :: proc(t: ^Tree, label: string) -> f32 {
	st := t.theme.type.label
	return text_measure(t, label, st.size, 0, st.weight, family = role_family(&t.theme, .Label)).x + 2 * t.theme.space[.xs] // measured in the family the crumbs are drawn in
}

// breadcrumbs_tick rebuilds when a trail's room changed (a resize, a
// sidebar dragged), so it folds or unfolds.
@(private)
breadcrumbs_tick :: proc(ui: ^Ui($Msg)) {
	t := &ui.tree
	for n, built in ui.crumbs {
		d := node_get(t, n)
		if d == nil do continue
		if abs(crumbs_room(d) - built) > 0.5 {
			ask_rebuild(ui)
			return
		}
	}
}

@(private)
crumb :: proc(ui: ^Ui($Msg), label: string, index: int, on_change: Handler(Msg, int), on_rest: Handler(Msg, Drag_Rest), key: u64, loc: runtime.Source_Code_Location) {
	t := &ui.tree
	th := &t.theme
	b, created := reconcile_child(ui, .Box, key, loc)
	d := node_get(t, b)
	if created {
		d.access.role = .Button
		d.flags += {.Focusable}
	}
	d.tag = u64(index)
	set_name(t, b, label)
	ui.on_int[b] = on_change
	// A drag resting on a part of the path goes up to it, as desktop path
	// bars do.
	drag_rest(ui, b, on_rest, repeat = false) // going up one level is the ask; the bar reflows under the pointer
	set_layout(t, b, Layout_Props{axis = .Row, align = .Center, padding = {th.space[.xxs], th.space[.xs], th.space[.xxs], th.space[.xs]}})
	st := d.style
	st.radius = th.radius.sm
	set_style(t, b, st)
	open_scope(ui, b, loc)
	lbl := text(ui, label, role = .Label, color = th.color.accent_text, nowrap = true, ellipsis = .End, loc = loc)
	set_role(t, lbl, .None)
	close_scope(ui)
}

@(private)
crumb_sep :: proc(ui: ^Ui($Msg), key: u64, loc: runtime.Source_Code_Location) {
	th := &ui.tree.theme
	c := th.color.on_surface_muted
	sep := icon(ui, .Chevron_Right, CRUMB_SEP, c, key = key, loc = loc)
	set_role(&ui.tree, sep, .None)
}
