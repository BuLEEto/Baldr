package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: behind this `when`, checking a program costs
// 1.0 GB instead of 9.2 GB. ODIN_TEST is set by `odin test`; BALDR_TESTS
// lets ./build.sh check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Full-width rows for a popover's pages (a shell's control centre).


@(private = "file")
ListRow_RMsg :: struct { kind: int, i: int }

@(private = "file")
rows_view :: proc(ui: ^Ui(ListRow_RMsg), disabled := false) -> (speakers, headphones, more, tunnel, lock: Node) {
	begin_view(ui)
	column(ui, width = 352, padding = .sm)
	speakers = list_row(ui, "Speakers", ListRow_RMsg{1, 0}, icon = .Volume_2, detail = "Built-in audio", end = .Check, on = true, key = 1)
	headphones = list_row(ui, "Headphones", ListRow_RMsg{1, 1}, icon = .Volume_1, detail = "Bluetooth", value = "80 %", end = .Check, key = 2)
	more = list_row(ui, "Sound settings", ListRow_RMsg{2, 0}, end = .Chevron, key = 3)
	tunnel = list_row(ui, "Office", ListRow_RMsg{3, 0}, icon = .Shield, value = "Connected", end = .Switch, on = true, key = 4)
	lock = list_row(ui, "Lock", ListRow_RMsg{4, 0}, icon = .Settings, disabled = disabled, key = 5)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 400})
	return
}

@(private = "file")
children_of :: proc(t: ^Tree, n: Node) -> [dynamic]Node {
	out := make([dynamic]Node, context.temp_allocator)
	for c := node_get(t, n).first; c != NODE_NONE; c = node_get(t, c).next do append(&out, c)
	return out
}

// A row spans its list, at least 38 px tall: its icon, then the label with
// its detail under it, then its value and its end. The end is a check only
// while on, a switch track, or a chevron.
@(test)
list_rows_lay_out_start_to_end :: proc(t: ^testing.T) {
	ui: Ui(ListRow_RMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	speakers, headphones, more, tunnel, _ := rows_view(&ui)
	th := &ui.tree.theme
	sd := node_get(&ui.tree, speakers)
	testing.expect_value(t, sd.abs.w, 352 - 2 * th.space[.sm]) // the list's width
	testing.expect(t, sd.abs.h >= LIST_ROW_MIN_H, "at least 38 px tall")

	parts := children_of(&ui.tree, speakers)
	testing.expect_value(t, len(parts), 3) // icon, words, check (on)
	if len(parts) == 3 {
		icon, words, check := parts[0], parts[1], parts[2]
		testing.expect(t, node_get(&ui.tree, icon).abs.x < node_get(&ui.tree, words).abs.x, "the icon first")
		testing.expect(t, node_get(&ui.tree, check).abs.x > node_get(&ui.tree, words).abs.x, "the check at the end")
		testing.expect_value(t, Icon(node_get(&ui.tree, check).tag), Icon.Check)
		testing.expect_value(t, node_get(&ui.tree, check).style.fg, th.color.primary)
		lines := children_of(&ui.tree, words)
		testing.expect_value(t, len(lines), 2)
		if len(lines) == 2 do testing.expect(t, node_get(&ui.tree, lines[1]).abs.y > node_get(&ui.tree, lines[0]).abs.y, "the detail under the label")
	}
	hp := children_of(&ui.tree, headphones)
	testing.expect_value(t, len(hp), 3) // icon, words, value; no check while off
	if len(hp) == 3 do testing.expect_value(t, node_get(&ui.tree, hp[2]).kind.(Text_Kind).str, "80 %")

	mp := children_of(&ui.tree, more)
	testing.expect(t, len(mp) == 2 && Icon(node_get(&ui.tree, mp[1]).tag) == .Chevron_Right, "a chevron at the end")
	tp := children_of(&ui.tree, tunnel)
	testing.expect_value(t, len(tp), 4) // icon, words, value, switch
	if len(tp) == 4 {
		ck, is_custom := node_get(&ui.tree, tp[3]).kind.(Custom_Kind)
		testing.expect(t, is_custom && ck.paint == paint_toggle, "a switch track at the end")
	}
}

// The whole row is one control: a click, Enter or Space sends its message,
// a disabled row sends nothing. Its role says what it is (Radio or Switch
// with Checked, else Button), named by its label and described by its
// detail and value; what is inside it isn't announced on its own.
@(test)
list_rows_act_and_announce :: proc(t: ^testing.T) {
	ui: Ui(ListRow_RMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	speakers, headphones, more, tunnel, lock := rows_view(&ui)
	hd := node_get(&ui.tree, headphones)
	pointer_button(&ui, .Left, true, {hd.abs.x + 40, hd.abs.y + 10})
	pointer_button(&ui, .Left, false, {hd.abs.x + 40, hd.abs.y + 10})
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == ListRow_RMsg{1, 1}, "a click picks the headphones")
	clear(&ui.msgs)
	set_focus(&ui.tree, more, true)
	testing.expect(t, key_event(&ui, .Enter, true, {}))
	set_focus(&ui.tree, tunnel, true)
	testing.expect(t, key_event(&ui, .Space, true, {}))
	testing.expect(t, len(ui.msgs) == 2 && ui.msgs[0] == ListRow_RMsg{2, 0} && ui.msgs[1] == ListRow_RMsg{3, 0}, "Enter and Space act on the focused row")
	clear(&ui.msgs)

	sd := node_get(&ui.tree, speakers)
	testing.expect(t, sd.access.role == .Radio && .Checked in sd.access.states, "the output in use: a checked Radio")
	testing.expect(t, hd.access.role == .Radio && .Checked not_in hd.access.states, "another output: an unchecked Radio")
	testing.expect_value(t, hd.access.name, "Headphones")
	testing.expect_value(t, hd.access.describe, "Bluetooth, 80 %")
	td := node_get(&ui.tree, tunnel)
	testing.expect(t, td.access.role == .Switch && .Checked in td.access.states, "a tunnel: a Switch, on")
	testing.expect_value(t, td.access.describe, "Connected")
	testing.expect_value(t, node_get(&ui.tree, more).access.role, Role.Button)
	for c in children_of(&ui.tree, headphones) do testing.expect_value(t, node_get(&ui.tree, c).access.role, Role.None)
	testing.expect(t, lint(&ui.tree) == 0)

	_, _, _, _, lock = rows_view(&ui, disabled = true)
	ld := node_get(&ui.tree, lock)
	pointer_button(&ui, .Left, true, {ld.abs.x + 40, ld.abs.y + 10})
	pointer_button(&ui, .Left, false, {ld.abs.x + 40, ld.abs.y + 10})
	testing.expect_value(t, len(ui.msgs), 0) // disabled: nothing
	testing.expect(t, .Disabled in ld.access.states)
}

} // when ODIN_TEST