package baldr

// Clickable: a container that takes a click as a whole.

import "core:fmt"
import "core:strings"

// clickable makes container `n` (a card, a column) one control that takes a
// click as a whole: a click on it, or Enter or Space while it has focus,
// sends `on_click`, while the controls inside it keep their own clicks (a
// notification card taking its default action, its buttons their own). It
// is one Tab stop and shows the hover and press a list row does.
// `on_context` is what a right-click on it, or the Menu key while it has
// focus, sends (a pinned tile's Unpin). For assistive technology it is a
// Button named `label` (the card's title). nil makes it plain again.
// `on_scroll` is a wheel or touchpad scroll over it, the leftover part of a
// step kept between scrolls as a button's is — for a control too small to be
// a button that still steps with the wheel. `tag` is echoed back in
// `Ev.tag` (0 leaves the node's own tag as it is). `on_double_click` is the
// second of two clicks close in time and place, arriving after that click's
// `on_click`; a third click starts a new pair. `on_double_click`,
// `on_context` and `on_scroll` hang off the click, so `on_click = nil` drops
// them too (passing one without an `on_click` is a diagnostic); a node that
// should answer those but not a plain click wants a `pointer_area`, or an
// `on_click` the app ignores. A control needs its double-click here: a
// `pointer_area` on a control never pairs presses, because its press stops at
// the hovered node, which is the area itself.
//
//	c := baldr.card(ui, key = n.id)
//	baldr.clickable(ui, c, Msg(Open{n.id}), label = n.summary)
clickable :: proc(ui: ^Ui($Msg), n: Node, on_click: Maybe(Msg), label := "", on_context: Maybe(Msg) = nil,
	on_scroll: Handler(Msg, Scroll) = nil, on_double_click: Maybe(Msg) = nil, focus_on_click := true, tag: u64 = 0,
	loc := #caller_location) {
	t := &ui.tree
	d := node_get(t, n)
	if d == nil do return
	focus_on_click_set(t, d, focus_on_click)
	m, on := on_click.?
	if !on {
		// No on_click drops the other answers too: right when removing a click,
		// a silent trap when one was never given, so say what went.
		_, wants_double := on_double_click.?
		_, wants_context := on_context.?
		if wants_double || wants_context || handler_live(on_scroll) {
			names := make([dynamic]string, 0, 3, context.temp_allocator)
			if wants_double  do append(&names, "on_double_click")
			if wants_context do append(&names, "on_context")
			if handler_live(on_scroll) do append(&names, "on_scroll")
			diag(&ui.tree, loc, fmt.tprintf(
				"clickable was given %s but no on_click, so %s dropped: a clickable's other answers hang off its click. Pass an on_click (a message the app ignores will do), or put them on a pointer_area.",
				strings.join(names[:], " and ", context.temp_allocator),
				"it was" if len(names) == 1 else "they were"))
		}
		if _, was := ui.clicks[n]; was {
			delete_key(&ui.clicks, n)
			delete_key(&ui.context_clicks, n) // its menu went with it; a context_area's stays
			delete_key(&ui.on_scroll, n)      // …and its wheel
			delete_key(&ui.double_clicks, n)  // …and its double
			delete_key(&ui.click_pairs, n)
			d.flags -= {.Focusable}
			if d.access.role == .Button do d.access.role = .None // its builder gives it its own role again
			mark_paint_dirty(t, n)
			mark_layout_dirty(t, n) // no longer a target: back to its own size (target_min)
		}
		return
	}
	if tag != 0 do d.tag = tag
	ui.clicks[n] = m
	if menu, has := on_context.?; has { ui.context_clicks[n] = menu } else { delete_key(&ui.context_clicks, n) }
	if dbl, has := on_double_click.?; has {
		ui.double_clicks[n] = dbl
	} else {
		delete_key(&ui.double_clicks, n)
		delete_key(&ui.click_pairs, n)
	}
	if handler_live(on_scroll) {
		use := ui.on_scroll[n] // the part of a step left over stays across builds, as a button's does
		use.handler = on_scroll
		ui.on_scroll[n] = use
	} else {
		delete_key(&ui.on_scroll, n)
	}
	// A button, unless it is a custom widget that named its own role (a
	// rating that is a slider): that role is what a reader should hear.
	own_role := n in t.customs && d.access.role != .None && d.access.role != .Group
	if .Focusable not_in d.flags || (d.access.role != .Button && !own_role) {
		d.flags += {.Focusable}
		if !own_role do d.access.role = .Button
		mark_paint_dirty(t, n)
		mark_layout_dirty(t, n) // a target now: it grows to a finger or the theme's min_target
	}
	if label != "" do set_name(t, n, label)
}
