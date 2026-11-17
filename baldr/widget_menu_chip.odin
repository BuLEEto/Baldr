package baldr

// menu_chip: a pill that shows a choice and opens a menu of the others.

// menu_chip is a compact pill for choosing in place among a few things: it
// shows the current one (a sound output's "Speakers", a screen's name) and a
// chevron, and a click, Enter or Space sends `on_click`, which the app
// answers by opening a `menu` anchored to the node it returns; `open` is
// that menu's state. It sits in the theme's fill_strong, so it reads on a
// tile or on glass; a label too long for its room ends in "…" and shows
// whole on hover. Accessibility: a Button named `label`, with a popup,
// Expanded while its menu is open.
//
//	output := baldr.menu_chip(ui, s.output_name, s.outputs_open, Msg.Toggle_Outputs)
//	if baldr.menu(ui, output, s.outputs_open, Msg.Close_Outputs) { … }
menu_chip :: proc(ui: ^Ui($Msg), label: string, open: bool, on_click: Msg, disabled := false,
	tag: u64 = 0, key: u64 = 0, loc := #caller_location) -> Node {
	t := &ui.tree
	th := &t.theme
	n, created := reconcile_child(ui, .Box, key, loc)
	d := node_get(t, n)
	if created {
		d.access.role = .Button
		d.flags += {.Focusable}
	}
	d.tag = tag
	set_name(t, n, label)
	set_disabled(t, n, disabled)
	was := d.access.states
	popup_states(d, open)
	if d.access.states != was do mark_paint_dirty(t, n)
	ui.clicks[n] = on_click
	lk := menu_chip_look(th)
	set_layout(t, n, Layout_Props{axis = .Row, align = .Center, gap = lk.gap, padding = lk.padding})
	st := d.style
	st.radius = lk.radius
	st.bg = lk.fill
	st.border_w = 0
	set_style(t, n, st)
	fg := lk.ink
	open_scope(ui, n, loc)
	lbl := text(ui, label, role = lk.text.role, size = lk.text.size, color = fg, nowrap = true, ellipsis = .End, weight = lk.text.weight, family = look_family(t, lk.text.family), key = u64(Control_Part.Label), loc = loc)
	set_role(t, lbl, .None) // the chip carries the name
	baldr_icon(ui, .Chevron_Down, lk.icon_size, fg, loc, key = u64(Control_Part.Icon)) // decorative
	close_scope(ui)
	return n
}

// The design's chip: padding top, right, bottom, left; its label's size; its chevron's.
MENU_CHIP_PADDING :: [4]f32{4, 6, 4, 10}
MENU_CHIP_TEXT    :: f32(12)
MENU_CHIP_CHEVRON :: f32(14)
