package baldr

// chip is a pill for a tag or a filter: `selected` shows a check and the
// tonal fill, a click sends on_change with the flipped value (Enter / Space
// too); `on_close` adds a small × that sends it (Backspace / Delete on a
// focused chip too). Accessibility: Toggle_Button named `label`, Pressed
// when selected; the × is a Button "Remove <label>".
//
//	baldr.chip(ui, "Wayland", selected = s.filters[i], on_change = …, tag = u64(i))
//	baldr.chip(ui, tag, on_close = Msg(Remove_Tag{i}))

import "core:fmt"

chip :: proc(ui: ^Ui($Msg), label: string, selected := false, on_change: Handler(Msg, bool) = nil, on_close: Maybe(Msg) = nil,
	icon: Icon = .None, disabled := false, tag: u64 = 0, key: u64 = 0, loc := #caller_location) -> Node {
	t := &ui.tree
	th := &t.theme
	n, created := reconcile_child(ui, .Box, key, loc)
	d := node_get(t, n)
	if created {
		d.access.role = .Toggle_Button
		d.flags += {.Focusable}
	}
	d.tag = tag
	set_name(t, n, label)
	set_disabled(t, n, disabled)
	if was := .Pressed in d.access.states; was != selected {
		if selected { d.access.states += {.Pressed} } else { d.access.states -= {.Pressed} }
		mark_paint_dirty(t, n)
	}
	if handler_live(on_change) { ui.on_bool[n] = on_change } else { delete_key(&ui.on_bool, n) }
	lk := chip_look(th)
	set_layout(t, n, Layout_Props{axis = .Row, align = .Center, gap = lk.gap, padding = lk.padding})
	st := d.style
	st.radius = lk.radius
	st.border_w = 0 if selected else lk.border_width
	st.border = lk.border
	st.bg = lk.selected_fill if selected else lk.fill
	set_style(t, n, st)
	fg := lk.selected_ink if selected else lk.ink
	open_scope(ui, n, loc)
	if selected {
		baldr_icon(ui, .Check, lk.icon_size, fg, loc)
	} else if icon != .None {
		baldr_icon(ui, icon, lk.icon_size, fg, loc)
	}
	lbl := text(ui, label, role = lk.text.role, size = lk.text.size, color = fg, nowrap = true, weight = lk.text.weight, family = look_family(t, lk.text.family), loc = loc)
	set_role(t, lbl, .None)
	if m, has := on_close.?; has {
		x, xcreated := reconcile_child(ui, .Box, 0xC105E, loc)
		xd := node_get(t, x)
		if xcreated {
			xd.access.role = .Button
			xd.flags += {.Focusable}
		}
		set_name(t, x, chip_remove_name(label))
		set_layout(t, x, Layout_Props{axis = .Row, align = .Center, justify = .Center, width = lk.close_size, height = lk.close_size})
		xs := xd.style
		xs.radius = lk.close_radius
		set_style(t, x, xs)
		ui.clicks[x] = m
		open_scope(ui, x, loc)
		baldr_icon(ui, .X, lk.close_icon_size, fg, loc)
		close_scope(ui)
		ui.chip_close[n] = m
	} else {
		delete_key(&ui.chip_close, n)
	}
	close_scope(ui)
	return n
}

@(private)
chip_remove_name :: proc(label: string) -> string { return fmt.tprintf("Remove %s", label) }

// chip_key: Backspace / Delete on a focused removable chip removes it.
chip_key :: proc(ui: ^Ui($Msg), key: Key) -> bool {
	if key != .Backspace && key != .Delete do return false
	if m, has := ui.chip_close[ui.tree.focus]; has {
		append(&ui.msgs, m)
		return true
	}
	return false
}
