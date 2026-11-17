package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: behind this `when`, checking a program costs
// 1.0 GB instead of 9.2 GB. ODIN_TEST is set by `odin test`; BALDR_TESTS
// lets ./build.sh check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A container whose contents draw but take no pointer (a shell's edit mode).


@(private = "file")
In_Msg :: enum { None, Pick, Edit_Menu, Launch, Tray_Menu, Volume, After }

// bar: a button, an applet (clickable: Pick, its menu Edit_Menu) whose content is a button with a menu, a wheel
// handler and a tooltip, and a text field; then another button. The applet's content is inert while `editing`.
@(private = "file")
bar :: proc(ui: ^Ui(In_Msg), editing: bool) -> (before, applet, content, launch, field, after: Node) {
	begin_view(ui)
	row(ui, gap = .sm, padding = .sm, key = 1)
	before = button(ui, "Before", In_Msg.None, key = 2)
	applet = row(ui, padding = .xs, key = 3)
	clickable(ui, applet, In_Msg.Pick, label = "Clock applet", on_context = In_Msg.Edit_Menu)
	content = row(ui, gap = .xs, key = 4)
	set_inert(&ui.tree, content, editing)
	launch = button(ui, "Launch", In_Msg.Launch, on_context = In_Msg.Tray_Menu, on_scroll = In_Msg.Volume, key = 5)
	tooltip(ui, launch, "Opens the calendar")
	field = text_input(ui, nil, label = "Search", width = 120, key = 6)
	end(ui)
	end(ui)
	after = button(ui, "After", In_Msg.After, key = 7)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {800, 200})
	return
}

@(private = "file")
centre_of :: proc(t: ^Tree, n: Node) -> [2]f32 {
	d := node_get(t, n)
	return {d.abs.x + d.abs.w / 2, d.abs.y + d.abs.h / 2}
}

@(private = "file")
press :: proc(ui: ^Ui(In_Msg), button: Mouse_Button, p: [2]f32) {
	clear(&ui.msgs)
	pointer_button(ui, button, true, p)
	pointer_button(ui, button, false, p)
}

// While editing, the applet's button and field draw but the pointer reaches
// the applet: a click picks it up, a right-click gives its edit menu, the
// wheel and the tooltip do nothing. Focus inside moves to the applet, Tab
// skips the contents, and assistive technology doesn't see them. A hover
// resting on the button when editing starts goes to the applet. Editing
// over, the contents take the pointer and Tab again.
@(test)
an_inert_container_draws_but_its_contents_take_no_pointer_or_focus :: proc(t: ^testing.T) {
	ui: Ui(In_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree
	before, applet, _, launch, field, after := bar(&ui, false)
	set_focus(tr, field, true)
	bar(&ui, true)
	testing.expect_value(t, tr.focus, applet) // focus inside moves to the applet

	p := centre_of(tr, launch)
	pointer_move(&ui, p)
	testing.expect_value(t, ui.pointer.hover, applet)
	press(&ui, .Left, p)
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == .Pick, "a click on its button picks the applet up")
	press(&ui, .Right, p)
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == .Edit_Menu, "a right-click gives the applet's menu, not the button's")
	press(&ui, .Left, centre_of(tr, field))
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == .Pick && tr.focus != field, "a click in the field picks the applet up too")
	clear(&ui.msgs)
	scroll_event(&ui, p, {0, 60})
	testing.expect_value(t, len(ui.msgs), 0) // the wheel isn't the button's
	ui_after_events(&ui, 100)
	ui_after_events(&ui, 5000)
	testing.expect(t, ui.tip_anchor != launch, "no tooltip for the button")

	testing.expect(t, !set_focus(tr, launch, true), "its controls can't take focus")
	set_focus(tr, before, true)
	focus_next(tr, false)
	testing.expect_value(t, tr.focus, applet)
	focus_next(tr, false)
	testing.expect_value(t, tr.focus, after) // Tab skips the button and the field
	dump := access_dump(tr)
	testing.expectf(t, strings.contains(dump, "Clock applet") && !strings.contains(dump, "Launch") && !strings.contains(dump, "Search"), "the contents leave the accessibility tree: %s", dump)

	bar(&ui, false)
	pointer_move(&ui, p)
	testing.expect_value(t, ui.pointer.hover, launch)
	bar(&ui, true) // editing starts with the pointer resting on the button
	ui_after_events(&ui, 6000)
	testing.expect_value(t, ui.pointer.hover, applet)

	bar(&ui, false)
	press(&ui, .Left, p)
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == .Launch, "editing over: the button takes its click again")
	set_focus(tr, applet, true)
	focus_next(tr, false)
	testing.expect_value(t, tr.focus, launch)
}

} // when ODIN_TEST