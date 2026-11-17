package baldr

@(require) import "core:testing"

// Behind this `when` so a program importing Baldr does not type-check the
// test suite too, which costs gigabytes. ODIN_TEST is set by `odin test`;
// BALDR_TESTS lets ./build.sh check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

Ov_Kind :: enum { None, Close_Pop, Close_Dialog, Pick, Delete }
Ov_Msg :: struct {
	kind: Ov_Kind,
	i:    int,
}

Ov_State :: struct {
	pop_open:    bool,
	dialog_open: bool,
	picked:      int,
}

@(private = "file")
on_pick :: proc(e: Ev(int)) -> Ov_Msg { return {kind = .Pick, i = e.value} }

@(private = "file")
ov_view :: proc(ui: ^Ui(Ov_Msg), s: ^Ov_State) -> (anchor, popbtn: Node) {
	begin_view(ui)
	column(ui, padding = .lg, gap = .md)
	anchor = button(ui, "More", Ov_Msg{kind = .None})
	select(ui, s.picked, {"Red", "Green", "Blue"}, on_pick, label = "Colour")
	popbtn = button(ui, "Plain", Ov_Msg{kind = .None})
	if popover(ui, anchor, s.pop_open, Ov_Msg{kind = .Close_Pop}) {
		button(ui, "Rename", Ov_Msg{kind = .None})
		button(ui, "Delete", Ov_Msg{kind = .Delete})
		end(ui)
	}
	if dialog(ui, s.dialog_open, Ov_Msg{kind = .Close_Dialog}, title = "Delete file?") {
		text(ui, "This cannot be undone.")
		row(ui, gap = .sm)
		button(ui, "Cancel", Ov_Msg{kind = .Close_Dialog})
		button(ui, "Delete", Ov_Msg{kind = .Delete}, variant = .Danger)
		end(ui)
		end(ui)
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	return
}

@(private = "file")
overlay_count :: proc(ui: ^Ui(Ov_Msg)) -> int { return node_child_count(&ui.tree, ui.tree.overlay) }

@(private = "file")
find_role :: proc(t: ^Tree, root: Node, role: Role) -> Node {
	d := node_get(t, root)
	if d == nil do return NODE_NONE
	if d.access.role == role do return root
	for c := d.first; c != NODE_NONE; c = node_get(t, c).next {
		if f := find_role(t, c, role); f != NODE_NONE do return f
	}
	return NODE_NONE
}

@(test)
overlay_popover_anchors_dismisses_and_paints_on_top :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	s: Ov_State
	anchor, _ := ov_view(&ui, &s)
	testing.expect_value(t, overlay_count(&ui), 0)
	testing.expect_value(t, len(ui.dismiss), 0)

	s.pop_open = true
	ov_view(&ui, &s)
	testing.expect_value(t, overlay_count(&ui), 1)
	pop := node_first(&ui.tree, ui.tree.overlay)
	frame(&ui.tree, {600, 400}) // second frame: placed with its real size
	pd := node_get(&ui.tree, pop)
	ad := node_get(&ui.tree, anchor)
	testing.expect(t, pd.abs.w > 0 && pd.abs.h > 0, "popover has a size")
	testing.expect_value(t, pd.abs.x, ad.abs.x)
	testing.expect_value(t, pd.abs.y, ad.abs.y + ad.abs.h + POPOVER_GAP)
	testing.expect(t, node_child_count(&ui.tree, ui.root) == 1, "page tree is untouched by the overlay")

	// The popover wins hit-testing over whatever it covers, and is drawn last.
	inside := [2]f32{pd.abs.x + 4, pd.abs.y + 4}
	hit := hit_test(&ui.tree, inside)
	testing.expect(t, hit == pop || node_get(&ui.tree, hit).parent == pop, "hit lands in the popover")
	cmds := draw_list(&ui.tree)
	last_page, first_pop := -1, len(cmds)
	for c, i in cmds {
		if r, ok := c.(Draw_Rect); ok {
			if r.rect == pd.abs && i < first_pop do first_pop = i
			if r.rect == ad.abs do last_page = i
		}
	}
	testing.expect(t, first_pop > last_page, "popover paints after the page")

	// A press inside does not dismiss; on the anchor does not dismiss (the
	// anchor toggles itself); outside both queues the dismiss message once.
	testing.expect(t, !dismiss_outside(&ui, inside))
	testing.expect(t, !dismiss_outside(&ui, {ad.abs.x + 2, ad.abs.y + 2}))
	testing.expect_value(t, len(ui.msgs), 0)
	pointer_button(&ui, .Left, true, {590, 390})
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0].kind, Ov_Kind.Close_Pop)
	pointer_button(&ui, .Left, true, {590, 390})
	testing.expect(t, len(ui.msgs) == 1, "fires once")
	pointer_button(&ui, .Left, false, {590, 390})
	clear(&ui.msgs)

	// The app closes it: the node fades out, then leaves the overlay.
	s.pop_open = false
	ov_view(&ui, &s)
	testing.expect(t, .Exiting in node_get(&ui.tree, pop).flags, "exit transition")
	ui_tick(&ui, 10_000)
	testing.expect(t, !node_valid(&ui.tree, pop))
	testing.expect_value(t, overlay_count(&ui), 0)

	// Escape while open.
	s.pop_open = true
	ov_view(&ui, &s)
	testing.expect(t, key_event(&ui, .Escape, true, {}))
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0].kind, Ov_Kind.Close_Pop)
}

@(test)
overlay_popover_flips_above_at_the_bottom_edge :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	column(&ui, padding = .lg)
	box(&ui, flex = 1) // spacer pushes the anchor to the bottom
	a := button(&ui, "Menu", Ov_Msg{})
	if popover(&ui, a, true, Ov_Msg{}) {
		text(&ui, "one"); text(&ui, "two"); text(&ui, "three")
		end(&ui)
	}
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 200})
	frame(&ui.tree, {400, 200})
	pop := node_first(&ui.tree, ui.tree.overlay)
	pd := node_get(&ui.tree, pop)
	ad := node_get(&ui.tree, a)
	testing.expect(t, pd.abs.y + pd.abs.h <= ad.abs.y, "placed above the anchor")
	testing.expect(t, pd.abs.y >= 0)
}

@(test)
overlay_select_opens_picks_and_closes :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	s: Ov_State
	ov_view(&ui, &s)
	sel := find_role(&ui.tree, ui.root, .Combo_Box)
	testing.expect(t, sel != NODE_NONE)
	sd := node_get(&ui.tree, sel)
	testing.expect_value(t, sd.access.name, "Colour")
	testing.expect(t, .Collapsed in sd.access.states)
	testing.expect_value(t, overlay_count(&ui), 0)

	// Click the trigger: internal state flips and asks for a rebuild.
	p := [2]f32{sd.abs.x + 5, sd.abs.y + 5}
	pointer_button(&ui, .Left, true, p)
	pointer_button(&ui, .Left, false, p)
	testing.expect(t, ui.open[sel], "open after click")
	testing.expect(t, ui.needs_rebuild)
	testing.expect_value(t, len(ui.msgs), 0)
	ui.needs_rebuild = false
	ov_view(&ui, &s)
	frame(&ui.tree, {600, 400})
	testing.expect(t, .Expanded in node_get(&ui.tree, sel).access.states)
	testing.expect_value(t, overlay_count(&ui), 1)
	menu := node_first(&ui.tree, ui.tree.overlay)
	testing.expect_value(t, node_get(&ui.tree, menu).access.role, Role.Menu)
	testing.expect_value(t, node_child_count(&ui.tree, menu), 3)
	first := node_first(&ui.tree, menu)
	testing.expect_value(t, node_get(&ui.tree, first).access.role, Role.Menu_Item)
	testing.expect(t, .Selected in node_get(&ui.tree, first).access.states, "current option is marked selected")
	testing.expect_value(t, ui.tree.focus, first) // keyboard users land on the list
	testing.expect(t, lint(&ui.tree) == 0, "options have names")

	// Arrow keys walk the options; Enter picks and closes.
	testing.expect(t, key_event(&ui, .Down, true, {}))
	testing.expect_value(t, ui.tree.focus, node_next(&ui.tree, first))
	testing.expect(t, key_event(&ui, .Down, true, {}))
	testing.expect(t, key_event(&ui, .Enter, true, {}))
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0].kind, Ov_Kind.Pick)
	testing.expect_value(t, ui.msgs[0].i, 2)
	testing.expect(t, !ui.open[sel], "closed after picking")
	s.picked = ui.msgs[0].i
	clear(&ui.msgs)
	ov_view(&ui, &s)
	testing.expect(t, .Exiting in node_get(&ui.tree, menu).flags)
	ui_tick(&ui, 10_000)
	testing.expect_value(t, overlay_count(&ui), 0)

	// Reopen with the keyboard; an outside press closes without a message.
	set_focus(&ui.tree, sel, true)
	testing.expect(t, key_event(&ui, .Space, true, {}))
	ov_view(&ui, &s)
	frame(&ui.tree, {600, 400})
	testing.expect_value(t, overlay_count(&ui), 1)
	pointer_button(&ui, .Left, true, {590, 390})
	pointer_button(&ui, .Left, false, {590, 390})
	testing.expect(t, !ui.open[sel])
	testing.expect_value(t, len(ui.msgs), 0)
	ov_view(&ui, &s)
	ui_tick(&ui, 20_000)
	testing.expect_value(t, overlay_count(&ui), 0)

	// Escape closes too.
	set_focus(&ui.tree, sel, true)
	key_event(&ui, .Enter, true, {})
	ov_view(&ui, &s)
	testing.expect(t, key_event(&ui, .Escape, true, {}))
	testing.expect(t, !ui.open[sel])
}

@(test)
overlay_dialog_traps_focus_and_restores_it :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	s: Ov_State
	anchor, _ := ov_view(&ui, &s)
	set_focus(&ui.tree, anchor, true)

	s.dialog_open = true
	ov_view(&ui, &s)
	frame(&ui.tree, {600, 400})
	testing.expect_value(t, overlay_count(&ui), 1)
	back := node_first(&ui.tree, ui.tree.overlay)
	card := node_first(&ui.tree, back)
	testing.expect_value(t, ui.tree.modal, card)
	cd := node_get(&ui.tree, card)
	testing.expect_value(t, cd.access.role, Role.Dialog)
	testing.expect(t, .Modal in cd.access.states)
	testing.expect_value(t, cd.access.name, "Delete file?")
	bd := node_get(&ui.tree, back)
	testing.expect(t, bd.abs == Rect{0, 0, 600, 400}, "scrim covers the viewport")
	testing.expect(t, cd.abs.x > 0 && cd.abs.x + cd.abs.w < 600, "card is centred")

	// Focus went to the first button in the card and Tab stays inside.
	inside := make([dynamic]Node, context.temp_allocator)
	collect_focusable(&ui.tree, card, &inside)
	testing.expect_value(t, len(inside), 2)
	testing.expect_value(t, ui.tree.focus, inside[0])
	for _ in 0 ..< 5 {
		focus_next(&ui.tree)
		testing.expect(t, ui.tree.focus == inside[0] || ui.tree.focus == inside[1], "focus trapped in the dialog")
	}
	testing.expect(t, hit_test(&ui.tree, {5, 5}) == back, "the scrim eats presses on the page")

	// A card press does nothing, and neither does a scrim press: a dialog
	// holds typed work, and a stray click beside it must not throw it away.
	// Escape is what closes it.
	pointer_button(&ui, .Left, true, {cd.abs.x + 5, cd.abs.y + 5})
	pointer_button(&ui, .Left, false, {cd.abs.x + 5, cd.abs.y + 5})
	testing.expect_value(t, len(ui.msgs), 0)
	pointer_button(&ui, .Left, true, {5, 5})
	pointer_button(&ui, .Left, false, {5, 5})
	testing.expect_value(t, len(ui.msgs), 0)
	key_event(&ui, .Escape, true, {})
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0].kind, Ov_Kind.Close_Dialog)
	clear(&ui.msgs)

	// Close: focus trap lifts and focus returns to the opener.
	s.dialog_open = false
	ov_view(&ui, &s)
	testing.expect_value(t, ui.tree.modal, NODE_NONE)
	testing.expect_value(t, ui.tree.focus, anchor)
	ui_tick(&ui, 10_000)
	testing.expect_value(t, overlay_count(&ui), 0)
	testing.expect(t, lint(&ui.tree) == 0)
}

@(test)
overlay_end_view_reports_only_user_scopes :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	a := button(&ui, "x", Ov_Msg{})
	popover(&ui, a, true, Ov_Msg{}) // forgot end(ui)
	err := end_view(&ui)
	testing.expect_value(t, err, Error.Unbalanced_Scope)
	testing.expect_value(t, len(ui.tree.diags), 1)
}

@(private = "file")
menu_view :: proc(ui: ^Ui(Ov_Msg), open: bool) -> (anchor: Node) {
	begin_view(ui)
	column(ui, padding = .lg, gap = .md)
	anchor = button(ui, "Actions", Ov_Msg{kind = .None})
	tooltip(ui, anchor, "More actions for this file")
	if menu(ui, anchor, open, Ov_Msg{kind = .Close_Pop}) {
		menu_item(ui, "Rename", Ov_Msg{kind = .None}, shortcut = "F2")
		separator(ui)
		menu_item(ui, "Delete", Ov_Msg{kind = .Delete}, shortcut = "Del")
		end(ui)
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	return
}

@(test)
overlay_menu_items_close_the_menu_and_focus_returns :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	anchor := menu_view(&ui, false)
	set_focus(&ui.tree, anchor, true)
	key_event(&ui, .Enter, true, {}) // opens via the app message in a real app
	clear(&ui.msgs)
	menu_view(&ui, true)
	frame(&ui.tree, {600, 400})
	m := node_first(&ui.tree, ui.tree.overlay)
	md := node_get(&ui.tree, m)
	testing.expect_value(t, md.access.role, Role.Menu)
	testing.expect_value(t, node_child_count(&ui.tree, m), 3)
	first := node_first(&ui.tree, m)
	testing.expect_value(t, node_get(&ui.tree, first).access.role, Role.Menu_Item)
	testing.expect_value(t, node_get(&ui.tree, node_next(&ui.tree, first)).access.role, Role.Separator)
	testing.expect_value(t, ui.tree.focus, first) // focus moved into the menu
	testing.expect(t, lint(&ui.tree) == 0)

	// Down skips the separator; Enter activates and closes.
	testing.expect(t, key_event(&ui, .Down, true, {}))
	last := node_get(&ui.tree, m).last
	testing.expect_value(t, ui.tree.focus, last)
	testing.expect(t, key_event(&ui, .Enter, true, {}))
	testing.expect_value(t, len(ui.msgs), 2)
	testing.expect_value(t, ui.msgs[0].kind, Ov_Kind.Delete)
	testing.expect_value(t, ui.msgs[1].kind, Ov_Kind.Close_Pop)
	clear(&ui.msgs)
	menu_view(&ui, false)
	testing.expect(t, .Exiting in node_get(&ui.tree, m).flags)
	testing.expect_value(t, ui.tree.focus, anchor) // focus returned to the opener
	testing.expect(t, ui.tree.focus_visible, "keyboard user keeps a visible ring")

	// Pointer path: click an item.
	menu_view(&ui, true)
	ui_tick(&ui, 20_000)
	frame(&ui.tree, {600, 400})
	m = node_first(&ui.tree, ui.tree.overlay)
	for c := node_first(&ui.tree, m); c != NODE_NONE; c = node_next(&ui.tree, c) {
		if node_get(&ui.tree, c).access.role == .Menu_Item {
			r := node_get(&ui.tree, c).abs
			pointer_button(&ui, .Left, true, {r.x + 4, r.y + 4})
			pointer_button(&ui, .Left, false, {r.x + 4, r.y + 4})
			break
		}
	}
	testing.expect_value(t, len(ui.msgs), 2)
	testing.expect_value(t, ui.msgs[1].kind, Ov_Kind.Close_Pop)
}

@(test)
overlay_tooltip_shows_after_hover_delay_and_on_keyboard_focus :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {600, 400}) // as the run loop does before the first view
	anchor := menu_view(&ui, false)
	ad := node_get(&ui.tree, anchor)
	testing.expect_value(t, ad.access.describe, "More actions for this file")
	testing.expect_value(t, overlay_count(&ui), 0)

	// Hover: nothing before the delay, a rebuild request after it.
	ui_tick(&ui, 1000)
	pointer_move(&ui, {ad.abs.x + 3, ad.abs.y + 3})
	ui_tick(&ui, 1000)
	testing.expect(t, !ui.needs_rebuild)
	testing.expect(t, ui.tree.wake_at_ms >= 1000 + TOOLTIP_DELAY_MS, "a wake-up is scheduled for the delay")
	ui_tick(&ui, 1300)
	testing.expect(t, !ui.needs_rebuild)
	ui_tick(&ui, 1700)
	testing.expect(t, ui.needs_rebuild)
	testing.expect_value(t, ui.tip_anchor, anchor)
	ui.needs_rebuild = false
	menu_view(&ui, false)
	frame(&ui.tree, {600, 400})
	testing.expect_value(t, overlay_count(&ui), 1)
	tip := node_first(&ui.tree, ui.tree.overlay)
	td := node_get(&ui.tree, tip)
	testing.expect_value(t, td.access.role, Role.Tooltip)
	testing.expect(t, td.abs.y + td.abs.h <= ad.abs.y || td.abs.y >= ad.abs.y + ad.abs.h, "above or (no room) below the anchor, never over it")
	testing.expect(t, td.abs.x >= 0 && td.abs.y >= 0, "inside the viewport")
	testing.expect(t, hit_test(&ui.tree, {ad.abs.x + 3, ad.abs.y + 3}) == anchor, "the tooltip never covers its anchor")

	// A press hides it and keeps it hidden while still hovering.
	pointer_button(&ui, .Left, true, {ad.abs.x + 3, ad.abs.y + 3})
	pointer_button(&ui, .Left, false, {ad.abs.x + 3, ad.abs.y + 3})
	testing.expect_value(t, ui.tip_anchor, NODE_NONE)
	ui_tick(&ui, 5000)
	testing.expect_value(t, ui.tip_anchor, NODE_NONE)
	ui.needs_rebuild = false
	menu_view(&ui, false)
	testing.expect(t, .Exiting in node_get(&ui.tree, tip).flags)
	ui_tick(&ui, 9000)
	testing.expect_value(t, overlay_count(&ui), 0)

	// Leave, then keyboard focus shows it without any delay.
	pointer_leave(&ui)
	ui_tick(&ui, 9100)
	testing.expect_value(t, ui.tip_anchor, NODE_NONE)
	set_focus(&ui.tree, anchor, true)
	ui_tick(&ui, 9200)
	testing.expect_value(t, ui.tip_anchor, anchor)
	set_focus(&ui.tree, anchor, false) // pointer focus: no tooltip
	ui_tick(&ui, 9300)
	testing.expect_value(t, ui.tip_anchor, NODE_NONE)
	set_focus(&ui.tree, anchor, true)
	ui_tick(&ui, 9400)
	testing.expect_value(t, ui.tip_anchor, anchor)
	testing.expect(t, key_event(&ui, .Escape, true, {}), "Escape hides the tooltip")
	testing.expect_value(t, ui.tip_anchor, NODE_NONE)
}

@(test)
theme_switch_recolours_all_text :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	build :: proc(ui: ^Ui(Ov_Msg)) {
		begin_view(ui)
		column(ui, padding = .lg, gap = .md)
		text(ui, "Headline", role = .Headline)
		text(ui, "Body", muted = true)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {400, 300})
	}
	build(&ui)
	set_theme(&ui.tree, theme_light())
	build(&ui)
	light := theme_light()
	seen := 0
	for c in draw_list(&ui.tree) {
		if dt, ok := c.(Draw_Text); ok {
			seen += 1
			want := light.color.on_surface if dt.str == "Headline" else light.color.on_surface_muted
			testing.expect(t, dt.color == want, dt.str)
		}
	}
	testing.expect_value(t, seen, 2)
}

// A text the layout cut with "…" tells the whole of it in a tooltip when
// the pointer rests on it; nothing is registered by the app.
@(test)
overlay_tooltip_shows_the_full_text_of_a_trimmed_text :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {600, 400})
	long := "A message subject far too long for the room it was given today"
	view :: proc(ui: ^Ui(Ov_Msg), long: string) -> Node {
		begin_view(ui)
		column(ui, width = 160)
		n := text(ui, long, nowrap = true, ellipsis = .End)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {600, 400})
		return n
	}
	n := view(&ui, long)
	testing.expect(t, text_trimmed(&ui.tree, n), "fixture: the text was cut")
	nd := node_get(&ui.tree, n)
	ui_tick(&ui, 1000)
	pointer_move(&ui, {nd.abs.x + 5, nd.abs.y + 5})
	ui_tick(&ui, 1000)
	testing.expect(t, ui.tree.wake_at_ms >= 1000 + TOOLTIP_DELAY_MS, "a wake-up is scheduled for the delay")
	ui_tick(&ui, 1700)
	testing.expect(t, ui.needs_rebuild)
	testing.expect_value(t, ui.tip_anchor, n)
	ui.needs_rebuild = false
	view(&ui, long)
	frame(&ui.tree, {600, 400})
	testing.expect_value(t, overlay_count(&ui), 1)
	tip := node_first(&ui.tree, ui.tree.overlay)
	testing.expect_value(t, node_get(&ui.tree, tip).access.role, Role.Tooltip)
	shown := node_get(&ui.tree, node_first(&ui.tree, tip)).kind.(Text_Kind)
	testing.expect_value(t, shown.str, long)
	testing.expect(t, len(shown.display) == 0, "the tooltip shows it whole")
	// an untrimmed text gets no tooltip
	begin_view(&ui)
	column(&ui, width = 600)
	short := text(&ui, "fits", nowrap = true, ellipsis = .End)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 400})
	sd := node_get(&ui.tree, short)
	pointer_move(&ui, {sd.abs.x + 2, sd.abs.y + 2})
	ui_tick(&ui, 3000)
	ui_tick(&ui, 3800)
	testing.expect_value(t, ui.tip_anchor, NODE_NONE)
}

// Nothing beneath an overlay ever gets the press that dismisses it: a
// button under a popover receives no click when the press closes the
// popover, and a button under a dialog's scrim gets nothing at all — the
// scrim press only queues the dialog's dismiss. Apps never guard against
// click-through themselves.
@(test)
overlay_press_never_reaches_what_is_beneath :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	view :: proc(ui: ^Ui(Ov_Msg), pop, dlg: bool) -> (anchor, under: Node) {
		set_viewport(&ui.tree, {600, 400})
		begin_view(ui)
		row(ui, padding = .lg, gap = .md, justify = .Space_Between)
		anchor = button(ui, "More", Ov_Msg{kind = .None})
		under = button(ui, "Under", Ov_Msg{kind = .Pick, i = 42})
		if popover(ui, anchor, pop, Ov_Msg{kind = .Close_Pop}) {
			button(ui, "Rename", Ov_Msg{kind = .None})
			end(ui)
		}
		if dialog(ui, dlg, Ov_Msg{kind = .Close_Dialog}, title = "Sure?") {
			button(ui, "Cancel", Ov_Msg{kind = .Close_Dialog})
			end(ui)
		}
		end(ui)
		end_view(ui)
		frame(&ui.tree, {600, 400})
		return
	}
	// popover open, press on the button beneath and outside it
	_, under := view(&ui, true, false)
	ur := node_get(&ui.tree, under).abs
	up := [2]f32{ur.x + ur.w / 2, ur.y + ur.h / 2}
	pop := node_first(&ui.tree, ui.tree.overlay)
	testing.expect(t, pop != NODE_NONE && !rect_contains(node_get(&ui.tree, pop).abs, up), "the button is outside the popover")
	pointer_button(&ui, .Left, true, up)
	pointer_button(&ui, .Left, false, up)
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0].kind, Ov_Kind.Close_Pop) // the press closed the popover…
	testing.expect(t, ui.pointer.pressed == NODE_NONE, "…and was swallowed: no press reached the button")
	clear(&ui.msgs)
	// dialog open: the scrim covers the button, and a press there reaches
	// nothing: not the button beneath, and not the dialog's own dismissal.
	view(&ui, false, true)
	testing.expect(t, hit_test(&ui.tree, up) != under, "the scrim covers the button")
	pointer_button(&ui, .Left, true, up)
	pointer_button(&ui, .Left, false, up)
	testing.expect_value(t, len(ui.msgs), 0)
	testing.expect(t, ui.pointer.pressed == NODE_NONE, "the press was swallowed by the scrim")
	pointer_move(&ui, up)
	testing.expect(t, ui.pointer.hover != under, "no hover beneath the scrim either")
}

// A menu closed and opened again while its exit transition still runs (the
// same key brings the leaving node back) takes the keyboard again: focus
// moves onto its first item instead of staying on the button that opened
// it, so Down and Enter work the menu (a taskbar entry's menu picked from,
// then opened again at once).
@(test)
overlay_menu_opened_again_while_leaving_takes_focus :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	anchor := menu_view(&ui, false)
	set_focus(&ui.tree, anchor, true)
	menu_view(&ui, true)
	m := node_first(&ui.tree, ui.tree.overlay)
	first := node_first(&ui.tree, m)
	testing.expect_value(t, ui.tree.focus, first)
	menu_view(&ui, false) // an item was picked: the menu leaves and focus goes back to the button
	testing.expect(t, .Exiting in node_get(&ui.tree, m).flags, "fixture: its exit transition runs")
	testing.expect_value(t, ui.tree.focus, anchor)

	menu_view(&ui, true) // opened again at once
	testing.expect_value(t, node_first(&ui.tree, ui.tree.overlay), m) // the leaving node, brought back
	testing.expect(t, .Exiting not_in node_get(&ui.tree, m).flags)
	testing.expect_value(t, ui.tree.focus, first)
	testing.expect(t, key_event(&ui, .Down, true, {}))
	testing.expect_value(t, ui.tree.focus, node_get(&ui.tree, m).last) // the keys work the menu, not the button
}

// A menu opened with the pointer highlights nothing, as desktop menus do:
// Enter activates nothing no one can see, the first Down highlights its
// first item and Up from nothing its last, Home and End go to the ends, and
// a row the pointer rests on is where the keys start. Opened from the
// keyboard, its first item shows at once.
@(test)
overlay_menu_keys_start_from_what_shows :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	anchor := menu_view(&ui, false)
	ad := node_get(&ui.tree, anchor)
	at := [2]f32{ad.abs.x + 4, ad.abs.y + 4}
	now := f64(10_000)
	open_with_pointer :: proc(ui: ^Ui(Ov_Msg), at: [2]f32, now: ^f64) -> (first, last: Node) {
		menu_view(ui, false)
		now^ += 10_000
		ui_tick(ui, now^) // any earlier menu has gone
		pointer_button(ui, .Left, true, at)
		pointer_button(ui, .Left, false, at)
		clear(&ui.msgs)
		menu_view(ui, true)
		m := node_first(&ui.tree, ui.tree.overlay)
		return node_first(&ui.tree, m), node_get(&ui.tree, m).last
	}

	first, last := open_with_pointer(&ui, at, &now)
	testing.expect(t, !ui.tree.focus_visible, "opened with the pointer: nothing highlighted")
	testing.expect(t, key_event(&ui, .Enter, true, {}), "Enter is the menu's")
	testing.expect_value(t, len(ui.msgs), 0) // and activates nothing
	testing.expect(t, key_event(&ui, .Down, true, {}))
	testing.expect(t, ui.tree.focus == first && ui.tree.focus_visible, "the first Down highlights the first item")
	testing.expect(t, key_event(&ui, .Down, true, {}))
	testing.expect_value(t, ui.tree.focus, last)
	testing.expect(t, key_event(&ui, .Home, true, {}))
	testing.expect_value(t, ui.tree.focus, first)
	testing.expect(t, key_event(&ui, .End, true, {}))
	testing.expect_value(t, ui.tree.focus, last)

	first, last = open_with_pointer(&ui, at, &now)
	testing.expect(t, key_event(&ui, .Up, true, {}))
	testing.expect(t, ui.tree.focus == last && ui.tree.focus_visible, "Up from nothing highlights the last item")

	first, last = open_with_pointer(&ui, at, &now)
	fr := node_get(&ui.tree, first).abs
	pointer_move(&ui, {fr.x + 4, fr.y + 4})
	testing.expect(t, key_event(&ui, .Down, true, {}))
	testing.expect_value(t, ui.tree.focus, last) // on from the row the pointer rests on

	first, last = open_with_pointer(&ui, at, &now)
	lr := node_get(&ui.tree, last).abs
	pointer_move(&ui, {lr.x + 4, lr.y + 4})
	testing.expect(t, key_event(&ui, .Enter, true, {}))
	testing.expect_value(t, len(ui.msgs), 2) // the row it points at: Delete, and the menu closes
	if len(ui.msgs) == 2 do testing.expect(t, ui.msgs[0].kind == .Delete && ui.msgs[1].kind == .Close_Pop, "Delete, then the close")

	menu_view(&ui, false)
	now += 10_000
	ui_tick(&ui, now)
	pointer_move(&ui, at)
	set_focus(&ui.tree, anchor, true) // reached with Tab, opened with Enter
	menu_view(&ui, true)
	m := node_first(&ui.tree, ui.tree.overlay)
	testing.expect(t, ui.tree.focus == node_first(&ui.tree, m) && ui.tree.focus_visible, "opened from the keyboard: the first item shows at once")
	testing.expect(t, key_event(&ui, .Down, true, {}))
	testing.expect_value(t, ui.tree.focus, node_get(&ui.tree, m).last)
}

// A select's list opened with the pointer starts at its selected option,
// and Down goes on from it.
@(test)
overlay_select_keys_start_from_the_selected_option :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	s := Ov_State{picked = 1}
	ov_view(&ui, &s)
	sel := find_role(&ui.tree, ui.root, .Combo_Box)
	sd := node_get(&ui.tree, sel)
	p := [2]f32{sd.abs.x + 5, sd.abs.y + 5}
	pointer_button(&ui, .Left, true, p)
	pointer_button(&ui, .Left, false, p)
	ui.needs_rebuild = false
	ov_view(&ui, &s)
	frame(&ui.tree, {600, 400})
	menu := node_first(&ui.tree, ui.tree.overlay)
	second := node_next(&ui.tree, node_first(&ui.tree, menu))
	testing.expect(t, .Selected in node_get(&ui.tree, second).access.states, "fixture: the second option is selected")
	testing.expect_value(t, ui.tree.focus, second)
	testing.expect(t, !ui.tree.focus_visible)
	testing.expect(t, key_event(&ui, .Down, true, {}))
	testing.expect_value(t, ui.tree.focus, node_get(&ui.tree, menu).last)
}

// A menu opened from a chip inside a popover is inside the popover: a press
// on its item picks it and leaves the popover open, Escape closes the menu
// first and the popover next, and a press outside both closes both.
@(test)
overlay_menu_inside_a_popover_is_inside_it :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	view :: proc(ui: ^Ui(Ov_Msg), pop_open, menu_open: bool) -> (chip: Node) {
		begin_view(ui)
		column(ui, padding = .lg)
		opener := button(ui, "Control Centre", Ov_Msg{kind = .None})
		if popover(ui, opener, pop_open, Ov_Msg{kind = .Close_Pop}) {
			chip = button(ui, "Speakers", Ov_Msg{kind = .None})
			if menu(ui, chip, menu_open, Ov_Msg{kind = .Close_Dialog}) {
				menu_item(ui, "Headphones", Ov_Msg{kind = .Pick, i = 1})
				end(ui)
			}
			end(ui)
		}
		end(ui)
		end_view(ui)
		frame(&ui.tree, {600, 400})
		return
	}
	got :: proc(ui: ^Ui(Ov_Msg), kind: Ov_Kind) -> bool {
		for m in ui.msgs do if m.kind == kind do return true
		return false
	}
	chip := view(&ui, true, true)
	ui_tick(&ui, 10_000) // the opening fades are over
	chip = view(&ui, true, true)
	item := find_role(&ui.tree, ui.tree.overlay, .Menu_Item)
	testing.expect(t, item != NODE_NONE, "fixture: the menu is open")
	if item == NODE_NONE do return
	ir := node_get(&ui.tree, item).abs
	at := [2]f32{ir.x + 4, ir.y + 4}
	pop := overlay_child_of(&ui.tree, chip)
	testing.expect(t, !rect_contains(node_get(&ui.tree, pop).abs, at), "fixture: the menu lies outside the popover's own rect")

	pointer_button(&ui, .Left, true, at)
	pointer_button(&ui, .Left, false, at)
	testing.expect(t, got(&ui, .Pick) && got(&ui, .Close_Dialog), "the item is picked and its menu closes")
	testing.expect(t, !got(&ui, .Close_Pop), "the popover stays open")
	clear(&ui.msgs)

	view(&ui, true, true)
	testing.expect(t, key_event(&ui, .Escape, true, {}))
	testing.expect(t, got(&ui, .Close_Dialog) && !got(&ui, .Close_Pop), "Escape closes the menu first")
	clear(&ui.msgs)
	view(&ui, true, false)
	ui_tick(&ui, 20_000)
	view(&ui, true, false)
	testing.expect(t, key_event(&ui, .Escape, true, {}))
	testing.expect(t, got(&ui, .Close_Pop), "and then the popover")
	clear(&ui.msgs)

	view(&ui, true, true)
	ui_tick(&ui, 30_000)
	view(&ui, true, true)
	pointer_button(&ui, .Left, true, {590, 390})
	pointer_button(&ui, .Left, false, {590, 390})
	testing.expect(t, got(&ui, .Close_Pop) && got(&ui, .Close_Dialog), "a press outside both closes both")
}

// A popover sits along its anchor by `align`: above or below,
// its start, middle or end lined up with the anchor's across; beside it,
// the same down. Near the viewport's edge a centred one slides in rather
// than hanging off, and one that flips keeps its alignment.
@(test)
overlay_popover_aligns_along_its_anchor :: proc(t: ^testing.T) {
	place :: proc(ui: ^Ui(Ov_Msg), placement: Placement, align: Align, at: [2]f32) -> (pop, anchor: [4]f32) {
		begin_view(ui)
		column(ui)
		spacer(ui, at.y)
		row(ui)
		spacer(ui, at.x)
		a := box(ui, width = 48, height = 48)
		end(ui)
		end(ui)
		if popover(ui, a, true, Ov_Msg{}, placement = placement, align = align) {
			box(ui, width = 300, height = 120)
			end(ui)
		}
		end_view(ui)
		frame(&ui.tree, {1000, 800})
		frame(&ui.tree, {1000, 800})
		pd := node_get(&ui.tree, node_first(&ui.tree, ui.tree.overlay))
		ad := node_get(&ui.tree, a)
		return {pd.abs.x, pd.abs.y, pd.abs.w, pd.abs.h}, {ad.abs.x, ad.abs.y, ad.abs.w, ad.abs.h}
	}
	mid :: proc(r: [4]f32, axis: int) -> f32 { return r[axis] + r[axis + 2] / 2 }
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.motion.reduce = true

	for placement in ([]Placement{.Below, .Above}) {
		p, a := place(&ui, placement, .Start, {400, 400})
		testing.expectf(t, p[0] == a[0], "%v Start: its start at the anchor's (%v, %v)", placement, p[0], a[0])
		p, a = place(&ui, placement, .Center, {400, 400})
		testing.expectf(t, abs(mid(p, 0) - mid(a, 0)) < 0.5, "%v Center: its middle over the anchor's (%v, %v)", placement, mid(p, 0), mid(a, 0))
		testing.expect(t, (p[1] >= a[1] + a[3]) == (placement == .Below), "still on its side of the anchor")
		p, a = place(&ui, placement, .End, {400, 400})
		testing.expectf(t, abs(p[0] + p[2] - (a[0] + a[2])) < 0.5, "%v End: its end at the anchor's", placement)
	}
	for placement in ([]Placement{.Right, .Left}) {
		p, a := place(&ui, placement, .Start, {400, 300})
		testing.expectf(t, p[1] == a[1], "%v Start: its top at the anchor's", placement)
		p, a = place(&ui, placement, .Center, {400, 300})
		testing.expectf(t, abs(mid(p, 1) - mid(a, 1)) < 0.5, "%v Center: its middle beside the anchor's (%v, %v)", placement, mid(p, 1), mid(a, 1))
		testing.expect(t, (p[0] >= a[0] + a[2]) == (placement == .Right), "still on its side of the anchor")
		p, a = place(&ui, placement, .End, {400, 300})
		testing.expectf(t, abs(p[1] + p[3] - (a[1] + a[3])) < 0.5, "%v End: its bottom at the anchor's", placement)
	}

	p, a := place(&ui, .Above, .Center, {10, 400}) // a dock button near the left edge
	testing.expect(t, p[0] == 0 && p[1] + p[3] <= a[1], "a centred popover near the edge slides in, still above")
	p, a = place(&ui, .Above, .Center, {1000 - 58, 400})
	testing.expect_value(t, p[0] + p[2], f32(1000)) // and at the right edge
	p, a = place(&ui, .Above, .Center, {400, 20}) // no room above: it flips below, still centred
	testing.expect(t, p[1] >= a[1] + a[3] && abs(mid(p, 0) - mid(a, 0)) < 0.5, "flipped below, centred")
	testing.expect_value(t, len(ui.tree.diags), 0) // every build balanced
}

// A keyed overlay that leaves and comes back is the same node, and there is
// never more than one node holding its key. A popup is found by its node, so
// an overlay that changed node would be a popup closed and opened again, a
// surface and a swapchain target each time: a drag ghost (DRAG_GHOST_KEY)
// rebuilt every frame would run into MAX_TARGETS.
@(test)
a_keyed_overlay_that_comes_back_is_the_same_node :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {400, 300})

	// Build it with an exit transition, as the drag ghost has.
	build :: proc(ui: ^Ui(Ov_Msg), with_ghost: bool, loc := #caller_location) -> Node {
		begin_view(ui)
		column(ui)
		text(ui, "under")
		end(ui)
		ghost := NODE_NONE
		if with_ghost {
			n, created := overlay_begin(ui, 0xD5A6_0000_0000_0001, loc)
			if created do transition(ui, n, .Fade_Scale, .Fade, 120)
			text(ui, "ghost")
			end(ui)
			ghost = n
		}
		end_view(ui)
		frame(&ui.tree, {400, 300})
		return ghost
	}

	keyed :: proc(t: ^Tree) -> (n: int) {
		for c := node_first(t, t.overlay); c != NODE_NONE; c = node_next(t, c) {
			if node_get(t, c).key == 0xD5A6_0000_0000_0001 do n += 1
		}
		return
	}

	first := build(&ui, true)
	testing.expect(t, first != NODE_NONE, "the ghost is there")
	testing.expect_value(t, keyed(&ui.tree), 1)

	// One build without it — a frame where the drag's ghost was not added —
	// starts its exit; it is still in the tree, fading.
	build(&ui, false)
	testing.expect_value(t, keyed(&ui.tree), 1)

	// And back: the same node, and still only one holding the key.
	again := build(&ui, true)
	testing.expect_value(t, keyed(&ui.tree), 1)
	testing.expect_value(t, again, first)
}

}
