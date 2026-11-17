package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Overlays inside a dialog, in a window with no popup surfaces: a select's
// list is anchored inside a backdrop that layout places, so it must wait
// for that placement and then paint above the card, not under it. The
// tooltip of the button that opened the dialog must go as the scrim comes
// up, not when the pointer next moves.


@(private = "file")
Dg_Msg :: struct {
	kind: enum { None, Close, Pick },
	i:    int,
}

@(private = "file")
Dg_State :: struct {
	open:  bool,
	hours: int,
}

@(private = "file")
dg_view :: proc(ui: ^Ui(Dg_Msg), s: ^Dg_State) -> (opener, inside: Node) {
	begin_view(ui)
	column(ui, padding = .lg, gap = .md)
	opener = button(ui, "Clock settings", Dg_Msg{})
	tooltip(ui, opener, "Clock settings")
	if dialog(ui, s.open, Dg_Msg{kind = .Close}, title = "Clock on this panel") {
		text(ui, "Shows the time on this panel.")
		select(ui, s.hours, {"12 hour", "24 hour"}, proc(e: Ev(int)) -> Dg_Msg { return {kind = .Pick, i = e.value} }, label = "Hours")
		inside = button(ui, "Done", Dg_Msg{kind = .Close})
		tooltip(ui, inside, "Close the clock's settings")
		end(ui)
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {800, 600})
	return
}

// role_in: the first node with `role` in `root`'s subtree, root included.
@(private = "file")
role_in :: proc(t: ^Tree, root: Node, role: Role) -> Node {
	d := node_get(t, root)
	if d == nil do return NODE_NONE
	if d.access.role == role do return root
	for c := d.first; c != NODE_NONE; c = node_get(t, c).next {
		if found := role_in(t, c, role); found != NODE_NONE do return found
	}
	return NODE_NONE
}

@(test)
a_select_inside_a_dialog_opens_under_it_and_over_the_card :: proc(t: ^testing.T) {
	ui: Ui(Dg_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.motion.reduce = true
	s := Dg_State{open = true}
	dg_view(&ui, &s)
	sel := role_in(&ui.tree, ui.tree.overlay, .Combo_Box)
	testing.expect(t, sel != NODE_NONE, "fixture: the select is in the dialog")
	sd := node_get(&ui.tree, sel)
	p := [2]f32{sd.abs.x + 5, sd.abs.y + sd.abs.h / 2}
	pointer_button(&ui, .Left, true, p)
	pointer_button(&ui, .Left, false, p)
	testing.expect(t, ui.open[sel], "fixture: its list is open")
	for _ in 0 ..< 2 {
		ui.needs_rebuild = false
		dg_view(&ui, &s)
	}

	backdrop, list: Node = NODE_NONE, NODE_NONE
	backdrop_i, list_i := -1, -1
	i := 0
	for c := node_first(&ui.tree, ui.tree.overlay); c != NODE_NONE; c, i = node_next(&ui.tree, c), i + 1 {
		d := node_get(&ui.tree, c)
		if node_within(&ui.tree, ui.tree.modal, c) do backdrop, backdrop_i = c, i
		if d.access.role == .Menu do list, list_i = c, i
	}
	testing.expect(t, backdrop != NODE_NONE && list != NODE_NONE, "fixture: the dialog and the list")
	if list == NODE_NONE do return
	sd = node_get(&ui.tree, sel)
	ld := node_get(&ui.tree, list)
	testing.expectf(t, ld.abs.y >= sd.abs.y + sd.abs.h - 1 && abs(ld.abs.x - sd.abs.x) < 1, "the list opens under its select (%v), not at the window's corner (%v)", sd.abs, ld.abs)
	testing.expectf(t, list_i > backdrop_i, "opened from inside the dialog, it is above it (%d over %d)", list_i, backdrop_i)

	card := node_get(&ui.tree, ui.tree.modal)
	over := [2]f32{ld.abs.x + ld.abs.w / 2, ld.abs.y + 4} // on the list, where it lies over the card
	testing.expect(t, rect_contains(card.abs, over), "fixture: that point is over the card")
	testing.expect(t, node_within(&ui.tree, hit_test(&ui.tree, over), list), "and it takes the pointer there, not the card")
}

@(test)
no_tooltip_stays_behind_a_dialog :: proc(t: ^testing.T) {
	ui: Ui(Dg_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	s: Dg_State
	opener, _ := dg_view(&ui, &s)
	od := node_get(&ui.tree, opener)
	pointer_move(&ui, {od.abs.x + od.abs.w / 2, od.abs.y + od.abs.h / 2})
	ui_tick(&ui, 1)
	ui_tick(&ui, 1 + TOOLTIP_DELAY_MS + 1)
	testing.expect_value(t, ui.tip_anchor, opener) // fixture: its tooltip shows

	s.open = true // the click opens the dialog; the pointer stays on the button, now behind the scrim
	_, inside := dg_view(&ui, &s)
	ui_tick(&ui, 1000)
	testing.expect_value(t, ui.tip_anchor, NODE_NONE)

	id := node_get(&ui.tree, inside)
	pointer_move(&ui, {id.abs.x + id.abs.w / 2, id.abs.y + id.abs.h / 2})
	ui_tick(&ui, 1100)
	ui_tick(&ui, 1100 + TOOLTIP_DELAY_MS + 1)
	testing.expect_value(t, ui.tip_anchor, inside) // a control in the dialog keeps its tooltip
}

} // when ODIN_TEST