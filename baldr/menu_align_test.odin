package baldr

@(require) import "core:testing"

when ODIN_TEST || #config(BALDR_TESTS, false) {

Ma_Msg :: struct { i: int }

Ma_Menu :: enum { Mixed, Plain, Small }

// ma_view builds one open menu; the caller lays it out (frame), so a test
// can look at what the build alone dirtied.
@(private = "file")
ma_view :: proc(ui: ^Ui(Ma_Msg), which: Ma_Menu, ticked := false, undo_icon := true) {
	set_viewport(&ui.tree, {600, 500})
	begin_view(ui)
	column(ui, padding = .lg)
	anchor := button(ui, "Edit", Ma_Msg{})
	if menu(ui, anchor, true, Ma_Msg{i = -1}) {
		switch which {
		case .Mixed:
			menu_item(ui, "Undo", Ma_Msg{1}, icon = .Undo_2)
			menu_item(ui, "Paste", Ma_Msg{2})
			menu_item(ui, "Format on Save", Ma_Msg{3}, checked = ticked)
			menu_item(ui, "Search", Ma_Msg{4}, icon = .Search, checked = true, radio = true)
			menu_item(ui, "Files", Ma_Msg{5}, icon = .Folder, checked = false, radio = true)
			if submenu(ui, "Recent") do end(ui)
		case .Plain:
			menu_item(ui, "Paste", Ma_Msg{2})
			if submenu(ui, "Recent") do end(ui)
		case .Small:
			menu_item(ui, "Undo", Ma_Msg{1}, icon = .Undo_2 if undo_icon else .None)
			menu_item(ui, "Paste", Ma_Msg{2})
		}
		end(ui)
	}
	end(ui)
	end_view(ui)
}

@(private = "file")
ma_frame :: proc(ui: ^Ui(Ma_Msg)) { frame(&ui.tree, {600, 500}) }

@(private = "file")
ma_find :: proc(t: ^Tree, n: Node, pred: proc(t: ^Tree, n: Node, d: ^Node_Data, s: string) -> bool, s: string) -> Node {
	d := node_get(t, n)
	if d == nil do return NODE_NONE
	if pred(t, n, d, s) do return n
	for ch := d.first; ch != NODE_NONE; ch = node_get(t, ch).next {
		if found := ma_find(t, ch, pred, s); found != NODE_NONE do return found
	}
	return NODE_NONE
}

@(private = "file")
ma_label :: proc(t: ^Tree, s: string) -> Node {
	return ma_find(t, t.overlay, proc(t: ^Tree, n: Node, d: ^Node_Data, s: string) -> bool {
		tk, ok := d.kind.(Text_Kind)
		return ok && tk.str == s
	}, s)
}

@(private = "file")
ma_item :: proc(t: ^Tree, s: string) -> Node {
	return ma_find(t, t.overlay, proc(t: ^Tree, n: Node, d: ^Node_Data, s: string) -> bool {
		return d.access.role == .Menu_Item && d.access.name == s
	}, s)
}

@(private = "file")
ma_x :: proc(t: ^Tree, s: string) -> f32 { return node_get(t, ma_label(t, s)).abs.x }

// The slot's content: the box of a check item, the dot of a radio item.
@(private = "file")
ma_slot :: proc(t: ^Tree, item: Node) -> Node {
	lead := node_get(t, item).first
	return node_get(t, lead).first
}

@(private = "file")
ma_children :: proc(t: ^Tree, n: Node) -> (count: int) {
	for ch := node_get(t, n).first; ch != NODE_NONE; ch = node_get(t, ch).next do count += 1
	return
}

// Icons, ticks and dots fill one leading slot, and once a row of a menu
// fills it every label starts after it: plain rows, submenu rows and a
// toggle that also has an icon included, never two slots in.
@(test)
a_menus_labels_start_in_one_column :: proc(t: ^testing.T) {
	ui: Ui(Ma_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ma_view(&ui, .Mixed)
	ma_frame(&ui)
	tr := &ui.tree
	lk := menu_look(&tr.theme)
	undo := node_get(tr, ma_item(tr, "Undo"))
	want := undo.abs.x + lk.item_padding[3] + lk.icon_size + lk.icon_gap
	for s in ([]string{"Undo", "Paste", "Format on Save", "Search", "Files", "Recent"}) {
		testing.expectf(t, abs(ma_x(tr, s) - want) < 0.5, "%q starts at %v, want %v", s, ma_x(tr, s), want)
	}
	// a radio item with an icon shows its dot, not the icon beside it
	search := ma_item(tr, "Search")
	testing.expect_value(t, ma_children(tr, node_get(tr, search).first), 2) // the slot and the label
}

// A menu whose rows have nothing leading keeps its labels at the edge.
@(test)
a_menu_with_nothing_leading_keeps_its_labels_at_the_edge :: proc(t: ^testing.T) {
	ui: Ui(Ma_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ma_view(&ui, .Plain)
	ma_frame(&ui)
	tr := &ui.tree
	lk := menu_look(&tr.theme)
	edge := node_get(tr, ma_item(tr, "Paste")).abs.x + lk.item_padding[3]
	testing.expect_value(t, ma_x(tr, "Paste"), edge)
	testing.expect_value(t, ma_x(tr, "Recent"), edge)
}

// The column follows the menu as it changes, from its first build on, and
// a menu that has not changed sets no layout.
@(test)
a_menu_lines_up_again_when_its_last_icon_goes :: proc(t: ^testing.T) {
	ui: Ui(Ma_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree
	ma_view(&ui, .Small)
	ma_frame(&ui)
	testing.expect(t, ma_x(tr, "Paste") == ma_x(tr, "Undo"), "lined up on the menu's first build")
	inset := ma_x(tr, "Paste")
	paste_lead := node_get(tr, ma_item(tr, "Paste")).first
	ma_view(&ui, .Small)
	testing.expect(t, .Dirty_Layout not_in node_get(tr, paste_lead).flags, "a steady menu sets no layout")
	ma_frame(&ui)
	ma_view(&ui, .Small, undo_icon = false)
	ma_frame(&ui)
	testing.expect(t, ma_x(tr, "Paste") < inset, "back at the edge once nothing fills the slot")
	testing.expect_value(t, ma_x(tr, "Paste"), ma_x(tr, "Undo"))
	ma_view(&ui, .Small, undo_icon = false)
	testing.expect(t, .Dirty_Layout not_in node_get(tr, paste_lead).flags, "…and steady again")
	ma_frame(&ui)
	ma_view(&ui, .Small)
	ma_frame(&ui)
	testing.expect_value(t, ma_x(tr, "Paste"), inset)
}

// An unticked check item shows an empty box, so it reads as a toggle that
// is off rather than a row set in by mistake; ticked, the box holds a tick.
// An unpicked radio item shows nothing: its set shows which one is picked.
@(test)
an_unticked_toggle_shows_an_empty_box :: proc(t: ^testing.T) {
	ui: Ui(Ma_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree
	ma_view(&ui, .Mixed)
	ma_frame(&ui)
	anim_tick(tr, 5000) // the menu's fade in, done
	ma_frame(&ui)
	lk := menu_look(&tr.theme)
	item := ma_item(tr, "Format on Save")
	slot := ma_slot(tr, item)
	bx := node_get(tr, slot).first
	testing.expect(t, bx != NODE_NONE, "the slot holds a box")
	bd := node_get(tr, bx)
	testing.expect(t, bd.style.border_w >= 1 && bd.style.border == lk.ink, "outlined in the menu's ink")
	testing.expect_value(t, ma_children(tr, bx), 0)
	drawn := false
	for c in draw_list(tr) {
		if r, ok := c.(Draw_Rect); ok && r.border_w >= 1 && r.border == lk.ink && r.rect == bd.abs do drawn = true
	}
	testing.expect(t, drawn, "the box is painted")
	ma_view(&ui, .Mixed, ticked = true)
	ma_frame(&ui)
	testing.expect_value(t, ma_children(tr, node_get(tr, ma_slot(tr, ma_item(tr, "Format on Save"))).first), 1) // the tick
	testing.expect_value(t, ma_children(tr, ma_slot(tr, ma_item(tr, "Files"))), 0)
	testing.expect_value(t, ma_children(tr, ma_slot(tr, ma_item(tr, "Search"))), 1) // the dot
}

// A reader hears a toggle as one whether or not it is ticked; a plain item
// stays a plain item.
@(test)
a_toggle_menu_item_tells_a_reader_it_ticks :: proc(t: ^testing.T) {
	ui: Ui(Ma_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree
	ma_view(&ui, .Mixed)
	ma_frame(&ui)
	check := ma_item(tr, "Format on Save")
	cd := node_get(tr, check)
	testing.expect_value(t, a11y_role_of(tr, check, cd), A11y_Role.Check_Menu_Item)
	f := a11y_flags(tr, check, cd)
	testing.expect(t, .Checkable in f && .Checked not_in f, "checkable, not ticked")
	radio := ma_item(tr, "Search")
	rd := node_get(tr, radio)
	testing.expect_value(t, a11y_role_of(tr, radio, rd), A11y_Role.Radio_Menu_Item)
	f = a11y_flags(tr, radio, rd)
	testing.expect(t, .Checkable in f && .Checked in f, "checkable and picked")
	plain := ma_item(tr, "Paste")
	pd := node_get(tr, plain)
	testing.expect_value(t, a11y_role_of(tr, plain, pd), A11y_Role.Menu_Item)
	testing.expect(t, .Checkable not_in a11y_flags(tr, plain, pd), "a plain item does not tick")
	ma_view(&ui, .Mixed, ticked = true)
	ma_frame(&ui)
	cd = node_get(tr, check)
	testing.expect(t, .Checked in a11y_flags(tr, check, cd), "ticked")
}

}
