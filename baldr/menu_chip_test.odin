package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Behind this `when` so a program importing Baldr does not type-check the
// test suite too, which costs gigabytes. ODIN_TEST is set by `odin test`;
// BALDR_TESTS lets ./build.sh check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A menu chip: a pill that shows a choice and opens a menu of the others.


@(private = "file")
MCMsg :: enum { None, Toggle, Close, Speakers, Headphones }

// A menu chip is a Button with a popup, named by its label, Collapsed until
// its menu opens and Expanded while it is; a click, Enter or Space sends its
// message. It is a pill in fill_strong holding a 12 px label then a 14 px
// chevron, padded 4 / 6 / 4 / 10, and the menu the app opens hangs below it.
@(test)
menu_chip_opens_its_menu :: proc(t: ^testing.T) {
	ui: Ui(MCMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.motion.reduce = true
	view :: proc(ui: ^Ui(MCMsg), open: bool) -> (chip: Node) {
		set_viewport(&ui.tree, {400, 300})
		begin_view(ui)
		row(ui, padding = .lg)
		chip = menu_chip(ui, "Speakers", open, MCMsg.Toggle)
		end(ui)
		if menu(ui, chip, open, MCMsg.Close) {
			menu_item(ui, "Speakers", MCMsg.Speakers)
			menu_item(ui, "Headphones", MCMsg.Headphones)
			end(ui)
		}
		end_view(ui)
		frame(&ui.tree, {400, 300})
		return
	}
	chip := view(&ui, false)
	th := &ui.tree.theme
	d := node_get(&ui.tree, chip)
	testing.expect(t, d.access.role == .Button && d.access.name == "Speakers", "a Button named by its label")
	testing.expect(t, .Has_Popup in d.access.states && .Collapsed in d.access.states && .Expanded not_in d.access.states, "with a popup, collapsed")
	testing.expect(t, d.style.bg == th.color.fill_strong && d.style.radius == th.radius.full, "a pill in fill_strong")
	testing.expect_value(t, d.layout.padding, [4]f32{4, 6, 4, 10})
	ld, cv := node_get(&ui.tree, d.first), node_get(&ui.tree, d.last)
	tk, is_text := ld.kind.(Text_Kind)
	testing.expect(t, is_text && tk.str == "Speakers" && tk.size == 12, "a 12 px label")
	testing.expect(t, d.first != d.last && cv.abs.x >= ld.abs.x + ld.abs.w && cv.abs.w == 14, "then a 14 px chevron")

	p := [2]f32{d.abs.x + d.abs.w / 2, d.abs.y + d.abs.h / 2}
	pointer_button(&ui, .Left, true, p)
	pointer_button(&ui, .Left, false, p)
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == .Toggle, "a click sends its message")
	for key in ([]Key{.Enter, .Space}) {
		clear(&ui.msgs)
		set_focus(&ui.tree, chip, true)
		key_event(&ui, key, true, {})
		key_event(&ui, key, false, {})
		testing.expectf(t, len(ui.msgs) == 1 && ui.msgs[0] == .Toggle, "%v sends it once: %v", key, ui.msgs[:])
	}

	chip = view(&ui, true)
	d = node_get(&ui.tree, chip)
	testing.expect(t, .Expanded in d.access.states && .Collapsed not_in d.access.states && .Has_Popup in d.access.states, "open: expanded")
	pop := node_first(&ui.tree, ui.tree.overlay)
	testing.expect(t, pop != NODE_NONE && node_get(&ui.tree, pop).access.role == .Menu && node_get(&ui.tree, pop).abs.y >= d.abs.y + d.abs.h, "its menu hangs below it")
	testing.expect(t, strings.contains(access_dump(&ui.tree), "Menu_Item \"Headphones\""))
	testing.expect(t, lint(&ui.tree) == 0)
}

// Every control that opens a popup says so to assistive technology: a
// select, the date, time and colour fields, a submenu row and a menu chip.
@(test)
popup_triggers_report_has_popup :: proc(t: ^testing.T) {
	ui: Ui(MCMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {600, 600})
	begin_view(&ui)
	column(&ui, padding = .lg, gap = .sm)
	select(&ui, 0, {"Name", "Size"}, label = "Sort")
	date_field(&ui, Date{2026, 9, 13}, label = "Date")
	time_field(&ui, Time_Of_Day{9, 30, 0, 0}, label = "Time")
	color_field(&ui, rgb(0x3366cc), label = "Accent")
	menu_chip(&ui, "Speakers", false, MCMsg.Toggle)
	end(&ui)
	if context_menu(&ui, true, MCMsg.None) {
		if submenu(&ui, "Sort by") do end(&ui)
		end(&ui)
	}
	end_view(&ui)
	frame(&ui.tree, {600, 600})
	dump := access_dump(&ui.tree)
	testing.expectf(t, strings.count(dump, "Has_Popup") == 6, "six controls open popups:\n%s", dump)
}

} // when ODIN_TEST