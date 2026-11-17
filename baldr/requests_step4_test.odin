package baldr

@(require) import "base:runtime"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them. ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh
// check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Type-ahead, a field focused on request with its Escape and arrows, and
// sidebar rows.


@(private = "file")
RequestsStep4_TMsg :: struct { kind: enum { None, Pick, Select, Cancel, Key, Context, Middle, Drop, Submit }, i: int, tag: u64, key: Key }

@(private = "file")
NAMES := []string{"alpha", "beta", "Bravo", "charlie", "delta", "Beetle"}

@(private = "file")
name_of :: proc(user: rawptr, index: int) -> string { return NAMES[index] }

@(private = "file")
node_named :: proc(t: ^Tree, root: Node, name: string) -> Node {
	d := node_get(t, root)
	if d == nil do return NODE_NONE
	if d.access.name == name do return root
	for c := d.first; c != NODE_NONE; c = node_get(t, c).next {
		if found := node_named(t, c, name); found != NODE_NONE do return found
	}
	return NODE_NONE
}

@(private = "file")
names_table :: proc(ui: ^Ui(RequestsStep4_TMsg), sel: ^Selection, labels: bool, count := 6, reveal := -1) -> Node {
	// The ask is the `reveal_index` command (reveal_cmd.odin), made before
	// the build that should act on it, as an app makes it from `update`.
	if reveal >= 0 do reveal_put(ui, Reveal_Ask{view = 3, index = reveal, at = 0.33, by_index = true})
	set_viewport(&ui.tree, {600, 400})
	begin_view(ui)
	column(ui, flex = 1)
	cols := []Column{{title = "Name"}}
	label_of: Label_Of = name_of if labels else nil
	first, last := table(ui, cols, count, sel, on_select = proc(e: Ev(int)) -> RequestsStep4_TMsg { return {kind = .Select, i = e.value} },
		label_of = label_of, label = "Files", key = 3)
	for i in first ..< last {
		table_row(ui, i)
		cell_text(ui, NAMES[i % len(NAMES)])
		end(ui)
	}
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	return node_first(&ui.tree, node_first(&ui.tree, ui.root))
}

@(test)
type_ahead_selects_by_prefix_and_cycles :: proc(t: ^testing.T) {
	ui: Ui(RequestsStep4_TMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	tbl := names_table(&ui, &sel, false)
	set_focus(&ui.tree, tbl, true)
	testing.expect(t, !type_ahead_text(&ui, "b"), "no labels: nothing to match")
	tbl = names_table(&ui, &sel, true)
	ui.tree.now_ms = 1000
	testing.expect(t, type_ahead_text(&ui, "b"))
	testing.expect_value(t, sel.cursor, 1) // beta
	ui.tree.now_ms = 1200
	type_ahead_text(&ui, "R")
	testing.expect_value(t, sel.cursor, 2) // "br", case-insensitive: Bravo
	testing.expect(t, len(ui.msgs) >= 2 && ui.msgs[len(ui.msgs) - 1].kind == .Select && ui.msgs[len(ui.msgs) - 1].i == 2, "the selection change is reported")
	ui.tree.now_ms = 3000 // a pause: a new prefix
	type_ahead_text(&ui, "d")
	testing.expect_value(t, sel.cursor, 4) // delta
	ui.tree.now_ms = 5000
	type_ahead_text(&ui, "b")
	testing.expect_value(t, sel.cursor, 1)
	ui.tree.now_ms = 5100
	type_ahead_text(&ui, "b") // the same letter again: the next b
	testing.expect_value(t, sel.cursor, 2)
	ui.tree.now_ms = 5200
	type_ahead_text(&ui, "b")
	testing.expect_value(t, sel.cursor, 5) // Beetle
	ui.tree.now_ms = 5300
	type_ahead_text(&ui, "b")
	testing.expect_value(t, sel.cursor, 1) // wrapped
	ui.tree.now_ms = 9000
	testing.expect(t, type_ahead_text(&ui, "z"), "no match is still the view's typing")
	testing.expect_value(t, sel.cursor, 1)
	testing.expect(t, !type_ahead_text(&ui, " "), "a blank never starts a prefix")
}

@(test)
reveal_scrolls_a_row_into_view_once :: proc(t: ^testing.T) {
	ui: Ui(RequestsStep4_TMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	tbl := names_table(&ui, &sel, true, count = 200)
	names_table(&ui, &sel, true, count = 200, reveal = 150)
	ui_after_events(&ui, 0)
	ts := ui.tree.tables[tbl]
	st := ui.tree.scrolls[ts.list]
	target := st.target.y if st.smooth else st.offset.y
	testing.expect(t, target > 0, "scrolled towards row 150")
	row_y := f32(150) * ts.row_height
	testing.expect(t, row_y >= target - 0.5 && row_y + ts.row_height <= target + st.viewport.y + 0.5, "row 150 lands in view")
	scroll_to(&ui.tree, ts.list, {0, 0})
	names_table(&ui, &sel, true, count = 200) // nothing asked this time: it stays where it is
	ui_after_events(&ui, 0)
	testing.expect_value(t, ui.tree.scrolls[ts.list].offset.y, 0)
}

@(private = "file")
path_bar :: proc(ui: ^Ui(RequestsStep4_TMsg), focus: bool, keys: bool) -> Node {
	set_viewport(&ui.tree, {600, 400})
	begin_view(ui)
	column(ui, gap = .sm)
	button(ui, "Back", RequestsStep4_TMsg{})
	f: Node
	if keys {
		f = text_input(ui, nil, initial = "/home/user", label = "Location", focus = focus,
			on_cancel = RequestsStep4_TMsg{kind = .Cancel}, on_key = proc(e: Ev(Key_Press)) -> RequestsStep4_TMsg { return {kind = .Key, key = e.value.key} })
	} else {
		f = text_input(ui, nil, initial = "/home/user", label = "Location", focus = focus)
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	return f
}

@(test)
field_takes_focus_when_asked_and_reports_escape_and_arrows :: proc(t: ^testing.T) {
	ui: Ui(RequestsStep4_TMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	f := path_bar(&ui, false, true)
	testing.expect(t, ui.tree.focus != f)
	f = path_bar(&ui, true, true) // Ctrl+L
	testing.expect_value(t, ui.tree.focus, f)
	lo, hi := text_input_selection(&ui.tree, f)
	// the app handed the field over, so its value is selected and the first
	// thing typed replaces it
	testing.expect(t, lo == 0 && hi == len("/home/user"), "the value is selected")
	back := node_named(&ui.tree, ui.root, "Back")
	set_focus(&ui.tree, back, true)
	path_bar(&ui, true, true) // still true: focus is not pulled back
	testing.expect_value(t, ui.tree.focus, back)
	set_focus(&ui.tree, f, true)
	key_event(&ui, .A, true, {.Ctrl}) // a selection does not keep Escape from the app
	clear(&ui.msgs)
	testing.expect(t, key_event(&ui, .Escape, true, {}))
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0].kind == .Cancel)
	clear(&ui.msgs)
	testing.expect(t, key_event(&ui, .Down, true, {}))
	testing.expect(t, key_event(&ui, .Page_Up, true, {}))
	testing.expect_value(t, len(ui.msgs), 2)
	testing.expect(t, ui.msgs[0].kind == .Key && ui.msgs[0].key == .Down && ui.msgs[1].key == .Page_Up, "the arrows reach the app")

	path_bar(&ui, false, false)
	f = path_bar(&ui, true, false)
	clear(&ui.msgs)
	testing.expect(t, !key_event(&ui, .Up, true, {}), "without on_key Up is not the field's")
	testing.expect(t, !key_event(&ui, .Escape, true, {}), "without on_cancel, and with only the selection focus made, Escape goes on")
	testing.expect_value(t, len(ui.msgs), 0)
}

@(private = "file")
places :: proc(ui: ^Ui(RequestsStep4_TMsg)) -> (tree: Node) {
	set_viewport(&ui.tree, {600, 400})
	begin_view(ui)
	column(ui, gap = .sm)
	tree = tree_view(ui, label = "Places", key = 6)
	tree_item(ui, "Home", RequestsStep4_TMsg{kind = .Pick}, tag = 1,
		on_context = proc(e: Ev(int)) -> RequestsStep4_TMsg { return {kind = .Context, i = e.value, tag = e.tag} },
		on_middle_click = RequestsStep4_TMsg{kind = .Middle, i = 1},
		on_drop = proc(e: Ev(Drop)) -> RequestsStep4_TMsg { return {kind = .Drop, tag = e.tag} }, accepts = "files", drop_positions = {.On})
	tree_item(ui, "Music", RequestsStep4_TMsg{kind = .Pick}, tag = 2,
		on_drop = proc(e: Ev(Drop)) -> RequestsStep4_TMsg { return {kind = .Drop, tag = e.tag} }, accepts = "files")
	end(ui)
	button(ui, "New window", RequestsStep4_TMsg{}, on_middle_click = RequestsStep4_TMsg{kind = .Middle, i = 9})
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	return
}

@(test)
sidebar_rows_menu_middle_click_and_drops_on :: proc(t: ^testing.T) {
	ui: Ui(RequestsStep4_TMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tree := places(&ui)
	home := node_named(&ui.tree, tree, "Home")
	music := node_named(&ui.tree, tree, "Music")
	hd := node_get(&ui.tree, home)
	at := [2]f32{hd.abs.x + 30, hd.abs.y + hd.abs.h / 2}

	testing.expect(t, pointer_button(&ui, .Right, true, at))
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0].kind == .Context && ui.msgs[0].i == 1 && ui.msgs[0].tag == 1, "on_context with the item's tag")
	testing.expect_value(t, ui.context_pos, at)
	testing.expect_value(t, ui.tree.tree_views[tree].cursor, home)
	pointer_button(&ui, .Right, false, at)

	clear(&ui.msgs)
	pointer_button(&ui, .Middle, true, at)
	pointer_button(&ui, .Middle, false, at)
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0].kind == .Middle && ui.msgs[0].i == 1, "a middle-click on the place")
	clear(&ui.msgs)
	md := node_get(&ui.tree, music)
	pointer_button(&ui, .Middle, true, at)
	pointer_button(&ui, .Middle, false, {md.abs.x + 30, md.abs.y + md.abs.h / 2}) // released elsewhere
	testing.expect_value(t, len(ui.msgs), 0)
	bn := node_named(&ui.tree, ui.root, "New window")
	bd := node_get(&ui.tree, bn)
	pointer_button(&ui, .Middle, true, {bd.abs.x + 4, bd.abs.y + 4})
	pointer_button(&ui, .Middle, false, {bd.abs.x + 4, bd.abs.y + 4})
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0].i == 9, "and on a button")

	testing.expect_value(t, ui.tree.drops[home].positions, Drop_Positions{.On})
	testing.expect_value(t, ui.tree.drops[music].positions, Drop_Positions{.Before, .After}) // a leaf's default stays

	clear(&ui.msgs)
	set_focus(&ui.tree, tree, true)
	tree_set_cursor(&ui.tree, tree, home)
	testing.expect(t, key_event(&ui, .Menu, true, {}))
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0].kind == .Context && ui.msgs[0].i == 1, "the Menu key on the cursor item")
	_ = runtime.Allocator{}
}

} // when ODIN_TEST