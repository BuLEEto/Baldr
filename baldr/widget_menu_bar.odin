package baldr

// menu_bar is the classic File / Edit / View strip. It owns which menu is
// open (like select owns its list): a click on a title opens it, hovering
// another title while one is open switches, a press elsewhere or Escape
// closes; keyboard: F10 (or Tab) reaches the titles, Left / Right move
// between them (switching an open menu too), Down / Enter / Space open,
// and inside a menu Up / Down walk the items, Left / Right jump to the
// neighbouring menu, Escape closes and returns focus to the title.
// Accessibility: Menu_Bar of Menu_Item titles (with a popup, Expanded / Collapsed) whose
// dropdowns are Menus of Menu_Items. Mnemonics (Alt+F) come later.
//
//	baldr.menu_bar(ui); {
//		defer baldr.end(ui)
//		if baldr.menu_bar_menu(ui, "File") { defer baldr.end(ui)
//			baldr.menu_item(ui, "New", Msg(New{}), shortcut = "Ctrl+N", icon = .File_Plus)
//			baldr.separator(ui)
//			baldr.menu_item(ui, "Quit", Msg(Quit{}), shortcut = "Ctrl+Q")
//		}
//		if baldr.menu_bar_menu(ui, "Edit") { defer baldr.end(ui); … }
//	}

Menu_Bar_State :: struct {
	titles: [dynamic]Node, // in order, this build
	open:   int,           // index of the open menu, -1 none
	count:  int,           // titles reconciled so far this build
	// One menu is open and another is taking its place, so the arriving
	// dropdown skips its enter transition (the leaving one lost its exit).
	// Moving along an open bar swaps at once; only opening the first and
	// closing the last animate.
	switching: bool,
	// Where the keys were when this bar's first menu opened, so closing gives
	// them back there rather than to the title: a title left holding focus
	// would re-open its menu on the app's next Enter.
	focus_before: Node,
}

menu_bar :: proc(ui: ^Ui($Msg), key: u64 = 0, loc := #caller_location) -> Node {
	n, created := reconcile_child(ui, .Box, key, loc)
	t := &ui.tree
	th := &t.theme
	d := node_get(t, n)
	if created {
		d.access.role = .Menu_Bar
		set_name(t, n, "Menu bar")
		ui.menu_bars[n] = {open = -1}
	}
	lk := menu_bar_look(th)
	set_layout(t, n, Layout_Props{axis = .Row, align = .Center, gap = lk.gap, padding = lk.padding})
	st := d.style
	st.bg = lk.fill
	set_style(t, n, st)
	mb := &ui.menu_bars[n]
	if mb.open < 0 do mb.focus_before = NODE_NONE // nothing open: the next opening remembers afresh
	mb.count = 0
	clear(&mb.titles)
	open_scope(ui, n, loc)
	return n
}

// menu_bar_menu adds a title to the bar being built and, while its menu is
// open, opens the dropdown scope for its items. Returns whether the scope
// is open; close it with end.
menu_bar_menu :: proc(ui: ^Ui($Msg), title: string, loc := #caller_location) -> bool {
	t := &ui.tree
	th := &t.theme
	bar := ui.scopes[len(ui.scopes) - 1].node
	mb, ok := &ui.menu_bars[bar]
	if !ok do return false
	index := mb.count
	mb.count += 1
	n, created := reconcile_child(ui, .Box, u64(index + 1), loc)
	d := node_get(t, n)
	if created {
		d.access.role = .Menu_Item
		// Tab and F10 reach it; a click on it does not take the keys. The
		// menu that opens takes them, and gives them back where they were.
		d.flags += {.Focusable, .Keys_Only_Focus}
		ui.open[n] = false
	}
	append(&mb.titles, n)
	set_name(t, n, title)
	if is_open := ui.open[n]; is_open && mb.open != index {
		// this title was just toggled on: it becomes the open one, others close
		for other, i in mb.titles do if i != index do ui.open[other] = false
		mb.open = index
	}
	if mb.open == index && !ui.open[n] do mb.open = -1
	open := mb.open == index
	popup_states(d, open) // it opens a popup: Has_Popup, Expanded while open
	lk := menu_bar_look(th)
	set_layout(t, n, Layout_Props{axis = .Row, align = .Center, padding = lk.item_padding})
	st := d.style
	st.radius = lk.item_radius
	st.bg = lk.open_fill if open else Color{}
	set_style(t, n, st)
	open_scope(ui, n, loc)
	lbl := text(ui, title, role = lk.text.role, size = lk.text.size, color = lk.open_ink if open else lk.ink,
		weight = lk.text.weight, family = look_family(t, lk.text.family), loc = loc)
	set_role(t, lbl, .None)
	close_scope(ui)
	if !open do return false
	k := (u64(n) * 0x9E37_79B9_7F4A_7C15) | 1
	pop, pcreated := overlay_begin(ui, k, loc)
	popover_style(ui, pop, pcreated, n, .Below, 200, true, menu = true)
	node_get(t, pop).access.role = .Menu
	if pcreated do ui.pending_focus = pop
	if pcreated && mb.switching {
		transition(ui, pop, .None, .Fade) // it takes the place of one already open: no fade in
		mb.switching = false
	}
	// Opened from the keyboard the title has the focus and gets it back;
	// opened with the pointer it never had it, and the keys go back to
	// whatever was using them.
	if pcreated && mb.focus_before == NODE_NONE do mb.focus_before = t.focus
	set_rule(ui, pop, Dismiss_Rule(Msg){owner = n, anchor = n, inside = pop,
		restore = mb.focus_before, restore_key = n}) // Escape goes back to the title, so the bar stays navigable
	return true
}

// ------------------------------------------------------------ behaviour

// menu_bar_of returns the bar and index of a title node (or NONE).
@(private)
menu_bar_of :: proc(ui: ^Ui($Msg), n: Node) -> (bar: Node, index: int) {
	for b, mb in ui.menu_bars do for title, i in mb.titles do if title == n do return b, i
	return NODE_NONE, -1
}

// menu_bar_owner_of returns the bar and title index of an open dropdown.
@(private)
menu_bar_owner_of :: proc(ui: ^Ui($Msg), pop: Node) -> (bar: Node, index: int) {
	rule, ok := ui.dismiss[pop]
	if !ok || rule.owner == NODE_NONE do return NODE_NONE, -1
	return menu_bar_of(ui, rule.owner)
}

// menu_bar_snap takes the exit transition off whatever dropdown of this bar
// is open and marks the bar as switching, so the one arriving skips its
// enter too: moving along an open menu bar swaps at once, as every desktop
// does it.
@(private)
menu_bar_snap :: proc(ui: ^Ui($Msg), bar: Node) {
	t := &ui.tree
	mb := &ui.menu_bars[bar]
	if mb == nil do return
	was_open := false
	for c := node_first(t, t.overlay); c != NODE_NONE; c = node_next(t, c) {
		rule, has := ui.dismiss[c]
		if !has do continue
		for title in mb.titles do if rule.owner == title {
			if d := node_get(t, c); d != nil {
				d.style.exit = {} // gone the moment it is not built again
				was_open = true
			}
		}
	}
	mb.switching = was_open // only a *swap* is instant; opening the first still opens
}

@(private)
menu_bar_switch :: proc(ui: ^Ui($Msg), bar: Node, to: int, focus_title: bool) {
	mb := &ui.menu_bars[bar]
	if mb == nil || len(mb.titles) == 0 do return
	idx := ((to % len(mb.titles)) + len(mb.titles)) % len(mb.titles)
	menu_bar_snap(ui, bar)
	mb = &ui.menu_bars[bar] // snap may have rebuilt the map's storage
	for title, i in mb.titles do ui.open[title] = i == idx
	mb.open = -1 // the next build settles it from the open flags
	ask_rebuild(ui)
	if focus_title do set_focus(&ui.tree, mb.titles[idx], true)
	for title in mb.titles do mark_paint_dirty(&ui.tree, title)
}

// menu_bar_hover_update switches the open menu when the pointer moves over
// another title of the same bar (called from pointer_move).
@(private)
menu_bar_hover_update :: proc(ui: ^Ui($Msg)) -> bool {
	bar, index := menu_bar_of(ui, ui.pointer.hover)
	if bar == NODE_NONE do return false
	mb := &ui.menu_bars[bar]
	if mb.open < 0 || mb.open == index do return false
	menu_bar_switch(ui, bar, index, false)
	return true
}

// menu_bar_key handles keys for a focused title or a focused item of an
// open dropdown. Returns true if consumed.
menu_bar_key :: proc(ui: ^Ui($Msg), key: Key, mods: Mods) -> bool {
	t := &ui.tree
	if key == .F10 && .Shift not_in mods {
		for _, mb in ui.menu_bars do if len(mb.titles) > 0 {
			set_focus(t, mb.titles[0], true)
			return true
		}
		return false
	}
	// a title has focus
	if bar, index := menu_bar_of(ui, t.focus); bar != NODE_NONE {
		mb := &ui.menu_bars[bar]
		#partial switch key {
		case .Left, .Right:
			dir := -1 if key == .Left else 1
			next := index + dir
			if mb.open >= 0 {
				menu_bar_switch(ui, bar, next, true)
			} else {
				n := len(mb.titles)
				set_focus(t, mb.titles[((next % n) + n) % n], true)
			}
			return true
		case .Down:
			if mb.open != index do menu_bar_switch(ui, bar, index, true)
			return true
		}
		return false
	}
	// an item of an open dropdown has focus
	pop := overlay_child_of(t, t.focus)
	if bar, index := menu_bar_owner_of(ui, pop); bar != NODE_NONE {
		#partial switch key {
		case .Left:  menu_bar_switch(ui, bar, index - 1, true); return true
		case .Right: menu_bar_switch(ui, bar, index + 1, true); return true
		}
	}
	return false
}
