package baldr

// Tabs: a tab bar whose selected indicator glides between tabs, and
// keep-alive panels that stay in the tree (parked, hidden) while another tab
// is showing, so scroll positions, carets, and expanded rows survive a switch
// at zero rebuild cost.
//
//   baldr.tab_bar(ui, int(s.tab), {"Files", "Search", "Settings"}, on_change = Msg.Tab_Changed)
//   if baldr.tab_panel(ui, s.tab == .Files,    key = 1) { defer baldr.end(ui); files(ui, s) }
//   if baldr.tab_panel(ui, s.tab == .Search,   key = 2) { defer baldr.end(ui); search(ui, s) }

TAB_INDICATOR_H :: f32(2)

// tab_bar draws one button per label; clicking sends the tab's index through
// `on_change`.
//
// `tones` is a tone per tab, for a tab that asks to be noticed (requests
// waiting, a failed sync). A tab with a tone other than `.Neutral` is drawn
// in that tone while it is not selected, and as an ordinary selected tab
// once it is, when the colour would only be noise. Shorter than `labels`,
// or nil, is `.Neutral` throughout.
//
// Accessible as a Tab_List of Tabs with the selected state; a tab asking
// for attention is also described as doing so, since colour alone is not
// something everyone can see.
tab_bar :: proc(ui: ^Ui($Msg), selected: int, labels: []string, on_change: Handler(Msg, int) = nil,
	tones: []Tone = nil,
	key: u64 = 0, loc := #caller_location) -> Node {
	bar, created := reconcile_child(ui, .Box, key, loc)
	t := &ui.tree
	th := &t.theme
	lk := tab_look(th)
	if created {
		d := node_get(t, bar)
		d.access.role = .Tab_List
		d.layout = {axis = .Row, gap = lk.gap, align = .End}
		d.style.border_w = 0
		// The bar scrolls sideways when the tabs do not fit: wheel, drag or
		// swipe move it, the selected and focused tabs are kept in view, and
		// the clipped ends fade.
		d.flags += {.Scroll_H, .Clips, .Relayout_Boundary}
		set_layer(t, bar, true)
		t.scrolls[bar] = scroll_state_new()
		mark_layout_dirty(t, bar)
	}
	// Only the gap, every build, so a theme change reaches a bar that exists
	// and whatever else the app set on the bar's layout stays.
	if bd := node_get(t, bar); bd.layout.gap != lk.gap {
		bd.layout.gap = lk.gap
		mark_layout_dirty(t, bar)
	}
	open_scope(ui, bar, loc)
	for label, i in labels {
		tab, tcreated := reconcile_child(ui, .Custom, u64(i + 1), loc)
		d := node_get(t, tab)
		if tcreated {
			d.access.role = .Tab
			d.flags += {.Focusable}
			d.kind = Custom_Kind{paint = paint_tab_indicator}
		}
		// Every build, not only on create, so a density or style change
		// reaches a bar that already exists.
		set_layout(t, tab, Layout_Props{axis = .Row, align = .Center, padding = lk.padding, min_h = lk.min_height})
		if d.style.radius != lk.radius {
			d.style.radius = lk.radius
			mark_paint_dirty(t, tab)
		}
		d.tag = u64(i)
		set_name(t, tab, label)
		is_sel := i == selected
		if was := .Selected in d.access.states; was != is_sel {
			if is_sel { d.access.states += {.Selected} } else { d.access.states -= {.Selected} }
			mark_paint_dirty(t, tab)
			if is_sel do t.reveal = tab // scrolled into view once laid out
		}
		ui.on_int[tab] = on_change
		// A tab asking for attention takes its tone only while not selected.
		tone := tones[i] if i < len(tones) else Tone.Neutral
		ink := lk.selected_ink if is_sel else lk.ink
		if tone != .Neutral && !is_sel {
			_, fg := tone_colors(th, tone)
			ink = ensure_contrast(fg, th.color.surface, 4.5)
		}
		// Colour must not be the only way to know, so the state is said too.
		if tone != .Neutral && !is_sel {
			set_describe(t, tab, "needs attention")
		} else {
			set_describe(t, tab, "")
		}
		open_scope(ui, tab, loc)
		lbl := text(ui, label, role = lk.text.role, size = lk.text.size, color = ink, weight = lk.text.weight,
			family = look_family(t, lk.text.family), loc = loc)
		set_role(t, lbl, .None)
		close_scope(ui)
	}
	close_scope(ui)
	return bar
}

// paint_tab_indicator draws the selected tab's underline, sliding via the
// tab's Value anim (0 → 1 when it becomes selected).
@(private)
paint_tab_indicator :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer) {
	th := &t.theme
	k := anim_target(t, n, .Value, 1 if .Selected in d.access.states else 0, th.motion.base)
	if k <= 0.01 do return
	r := d.abs
	w := r.w * (0.6 + 0.4 * k)
	x := r.x + (r.w - w) / 2
	// Resolved here, not at build: paint swaps in the glass theme for glass nodes.
	lk := tab_look(th)
	c := lk.indicator
	c.a *= k * t.paint_opacity
	append(&l.cmds, Draw_Rect{rect = {x, r.y + r.h - lk.indicator_height, w, lk.indicator_height}, color = c, radius = lk.indicator_radius})
}

// tab_bars_reveal_selected scrolls every tab bar so its selected tab is in
// view, instantly — called after a resize, when a bar that fit before may
// now clip the current tab. Returns true if any bar moved.
tab_bars_reveal_selected :: proc(t: ^Tree) -> (moved: bool) {
	bars := make([dynamic]Node, context.temp_allocator)
	for n in t.scrolls do if d := node_get(t, n); d != nil && d.access.role == .Tab_List do append(&bars, n)
	for bar in bars {
		bd := node_get(t, bar)
		for c := bd.first; c != NODE_NONE; c = node_get(t, c).next {
			if .Selected in node_get(t, c).access.states {
				if scroll_into_view(t, c, instant = true) do moved = true
				break
			}
		}
	}
	return
}

// tab_panel opens the content scope for one tab when `active`; when not, its
// node is parked hidden (Keep) so its state survives. Returns whether the
// scope is open — close it with end only then. `key` must be unique among
// sibling panels (it identifies the parked node). `scroll` makes the panel
// itself a vertical scroll region (wheel, keys, overlay bar at the panel's
// edge, focus revealed) for pages taller than the window; its offset
// survives switching away. Leave it off for a page whose content fills the
// panel (a list or table with `flex = 1`), which scrolls on its own.
tab_panel :: proc(ui: ^Ui($Msg), active: bool, key: u64, flex: f32 = 1, gap: Space = Space_Token.none,
	padding: Space = Space_Token.none, scroll: bool = false, loc := #caller_location) -> bool {
	if !active do return false // not emitted → close_scope parks it (Keep)
	n, created := reconcile_child(ui, .Box, key, loc)
	t := &ui.tree
	th := &t.theme
	d := node_get(t, n)
	if created {
		d.flags += {.Keep, .Relayout_Boundary}
		d.access.role = .Tab_Panel
		d.style.enter = {kind = .Fade, duration = th.motion.fast}
	}
	if scroll && .Scroll_V not_in d.flags {
		d.flags += {.Clips, .Scroll_V}
		set_layer(t, n, true)
		t.scrolls[n] = scroll_state_new()
	}
	if .Revealed in d.flags { // switched back to: fade in again
		d.flags -= {.Revealed}
		anim_restart(t, n, .Enter, 0, 1, th.motion.fast)
	}
	set_layout(t, n, Layout_Props{axis = .Column, flex = flex, gap = space_px(th, gap), padding = pad4(space_px(th, padding)), align = .Stretch})
	open_scope(ui, n, loc)
	return true
}
