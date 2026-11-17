package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// context_area: a right-click on a container that isn't a control, as on a
// panel's bar.


@(private = "file")
CA_Msg :: enum { None, Open, Bar_Menu, Tray_Menu }

// bar: a bar holding a button without a menu, one with its own, and a clock's text; the bar's menu unless `menu` is false.
@(private = "file")
bar :: proc(ui: ^Ui(CA_Msg), menu := true) -> (b, plain, tray, label: Node) {
	begin_view(ui)
	b = row(ui, padding = .sm, gap = .sm, height = 40, key = 1)
	on_context: Maybe(CA_Msg) = CA_Msg.Bar_Menu
	if !menu do on_context = nil
	context_area(ui, b, on_context)
	clickable(ui, b, nil) // plain: that takes no menu away
	plain = button(ui, "Files", CA_Msg.Open, key = 2)
	tray = button(ui, "Tray", CA_Msg.Open, on_context = CA_Msg.Tray_Menu, key = 3)
	label = text(ui, "14:05", key = 4)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 200})
	return
}

@(private = "file")
right_click :: proc(ui: ^Ui(CA_Msg), n: Node) -> [2]f32 {
	d := node_get(&ui.tree, n)
	p := [2]f32{d.abs.x + d.abs.w / 2, d.abs.y + d.abs.h / 2}
	clear(&ui.msgs)
	pointer_button(ui, .Right, true, p)
	pointer_button(ui, .Right, false, p)
	return p
}

// A right-click on the bar's text or on a button without a menu asks for the
// bar's menu where it happened, and focus stays put; a button with its own
// keeps it. The Menu key on a focused control does the same, placing the
// menu below the control. The bar takes no hover, focus or role; nil
// removes its menu.
@(test)
a_context_area_gives_a_container_a_menu_without_making_it_a_control :: proc(t: ^testing.T) {
	ui: Ui(CA_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	b, plain, tray, label := bar(&ui)
	tr := &ui.tree

	p := right_click(&ui, label)
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == .Bar_Menu, "a right-click on its text: the bar's menu")
	testing.expect_value(t, ui.context_pos, p)
	testing.expect_value(t, tr.focus, NODE_NONE) // not a control: nothing takes focus
	testing.expect(t, ui.pointer.hover != b, "no hover of its own")
	bd := node_get(tr, b)
	testing.expect(t, .Focusable not_in bd.flags && bd.access.role == .None, "no Tab stop, no role")
	right_click(&ui, plain)
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == .Bar_Menu, "on a button without a menu: the bar's")
	right_click(&ui, tray)
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == .Tray_Menu, "on a button with its own: its own")

	set_focus(tr, plain, true)
	clear(&ui.msgs)
	testing.expect(t, key_event(&ui, .Menu, true, {}), "the Menu key on a button without a menu")
	pd := node_get(tr, plain)
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == .Bar_Menu, "asks for the bar's menu")
	testing.expect_value(t, ui.context_pos, [2]f32{pd.abs.x, pd.abs.y + pd.abs.h})
	set_focus(tr, tray, true)
	clear(&ui.msgs)
	key_event(&ui, .Menu, true, {})
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == .Tray_Menu, "the Menu key on one with its own: its own")

	bar(&ui, menu = false)
	right_click(&ui, label)
	testing.expect_value(t, len(ui.msgs), 0)
}

} // when ODIN_TEST