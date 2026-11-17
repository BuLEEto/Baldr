package baldr

@(require) import "core:testing"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A choice's pick carries the control's tag, from a click as from the keys,
// so one handler can serve a segmented control per screen.


@(private = "file")
Pick :: struct { tag: u64, value: int }

@(private = "file")
ChoiceTag_CMsg :: union { Pick }

// A click on a segmented control's item and the arrow keys on the control
// both send the control's tag, with the picked index as the value; two
// controls sharing one handler are told apart.
@(test)
a_choices_pick_carries_its_tag_from_a_click_and_the_keys :: proc(t: ^testing.T) {
	ui: Ui(ChoiceTag_CMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	on_pick :: proc(e: Ev(int)) -> ChoiceTag_CMsg { return Pick{e.tag, e.value} }
	begin_view(&ui)
	column(&ui, gap = .md)
	hdmi := segmented(&ui, 1, {"Mirror", "Extend", "Off"}, on_pick, label = "HDMI-A-1", tag = 0xBEEF, key = 1)
	dp := segmented(&ui, 1, {"Mirror", "Extend", "Off"}, on_pick, label = "DP-2", tag = 0xCAFE, key = 2)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {500, 300})
	tr := &ui.tree

	mirror := tr.choices[hdmi].items[0]
	md := node_get(tr, mirror)
	p := [2]f32{md.abs.x + md.abs.w / 2, md.abs.y + md.abs.h / 2}
	pointer_button(&ui, .Left, true, p)
	pointer_button(&ui, .Left, false, p)
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == ChoiceTag_CMsg(Pick{0xBEEF, 0}), "a click on HDMI's Mirror: its tag, index 0")
	clear(&ui.msgs)

	click(&ui, tr.choices[dp].items[2])
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == ChoiceTag_CMsg(Pick{0xCAFE, 2}), "a click on DP's Off: its own tag")
	clear(&ui.msgs)

	set_focus(tr, dp, true)
	choice_key(&ui, .Right, {})
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == ChoiceTag_CMsg(Pick{0xCAFE, 2}), "the arrow keys: the same tag and index a click sends")
	clear(&ui.msgs)

	begin_view(&ui)
	column(&ui, gap = .md)
	side := radio(&ui, 0, {"Left", "Right"}, on_pick, label = "Side", tag = 0xF00D, key = 3)
	end(&ui)
	end_view(&ui)
	frame(tr, {500, 300})
	click(&ui, tr.choices[side].items[1])
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == ChoiceTag_CMsg(Pick{0xF00D, 1}), "a radio group's click: its tag too")
}

@(private = "file")
named_item :: proc(t: ^Tree, n: Node, name: string) -> Node {
	d := node_get(t, n)
	if d == nil do return NODE_NONE
	if d.access.role == .Menu_Item && d.access.name == name do return n
	for c := d.first; c != NODE_NONE; c = node_get(t, c).next {
		if found := named_item(t, c, name); found != NODE_NONE do return found
	}
	return NODE_NONE
}

// A select's option, picked by a click or Enter on it, sends the select's
// tag with the option's index, as a segmented control's segment does.
@(test)
a_selects_pick_carries_its_tag :: proc(t: ^testing.T) {
	ui: Ui(ChoiceTag_CMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	on_pick :: proc(e: Ev(int)) -> ChoiceTag_CMsg { return Pick{e.tag, e.value} }
	build :: proc(ui: ^Ui(ChoiceTag_CMsg)) -> Node {
		begin_view(ui)
		column(ui, padding = .md)
		s := select(ui, 0, {"Mirror", "Extend", "Off"}, on_pick, label = "HDMI-A-1", tag = 0xBEEF, key = 1)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {500, 400})
		return s
	}
	s := build(&ui)
	ui.open[s] = true // its list open
	s = build(&ui)
	off := named_item(&ui.tree, ui.tree.overlay, "Off")
	testing.expect(t, off != NODE_NONE, "fixture: the list is open")
	click(&ui, off)
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == ChoiceTag_CMsg(Pick{0xBEEF, 2}), "the select's tag, index 2")
}

} // when ODIN_TEST