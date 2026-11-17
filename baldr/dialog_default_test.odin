package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A dialog's default button: what Enter does when the focused control does
// not use it.


@(private = "file")
DialogDefault_DMsg :: enum { None, Close, Cancel, Skip, Keep, Submit, Toggle }

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
conflict_view :: proc(ui: ^Ui(DialogDefault_DMsg), open: bool, with_default := true) {
	set_viewport(&ui.tree, {800, 600})
	begin_view(ui)
	column(ui, padding = .lg)
	button(ui, "Copy", DialogDefault_DMsg.None)
	if dialog(ui, open, DialogDefault_DMsg.Close, title = "A file with that name exists") {
		row(ui, gap = .sm)
		button(ui, "Cancel", DialogDefault_DMsg.Cancel, variant = .Outline)
		button(ui, "Skip", DialogDefault_DMsg.Skip, variant = .Outline)
		button(ui, "Keep Both", DialogDefault_DMsg.Keep, default = with_default)
		end(ui)
		end(ui)
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {800, 600})
}

@(test)
default_button_takes_focus_and_enter :: proc(t: ^testing.T) {
	ui: Ui(DialogDefault_DMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	conflict_view(&ui, false)
	conflict_view(&ui, true)
	keep := node_named(&ui.tree, ui.tree.overlay, "Keep Both")
	testing.expect(t, keep != NODE_NONE)
	testing.expect_value(t, ui.tree.focus, keep) // not Cancel, built first
	testing.expect(t, .Default in node_get(&ui.tree, keep).access.states, "announced as the default")
	testing.expect(t, strings.contains(access_dump(&ui.tree), "Default"))
	clear(&ui.msgs)
	testing.expect(t, key_event(&ui, .Enter, true, {}))
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0], DialogDefault_DMsg.Keep)

	// a button the user moved to keeps its own Enter
	conflict_view(&ui, true)
	cancel := node_named(&ui.tree, ui.tree.overlay, "Cancel")
	set_focus(&ui.tree, cancel, true)
	clear(&ui.msgs)
	key_event(&ui, .Enter, true, {})
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0], DialogDefault_DMsg.Cancel)
	testing.expect(t, lint(&ui.tree) == 0)
}

@(test)
without_a_default_the_first_control_is_focused :: proc(t: ^testing.T) {
	ui: Ui(DialogDefault_DMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	conflict_view(&ui, false, with_default = false)
	conflict_view(&ui, true, with_default = false)
	testing.expect_value(t, ui.tree.focus, node_named(&ui.tree, ui.tree.overlay, "Cancel"))
	clear(&ui.msgs)
	key_event(&ui, .Enter, true, {})
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0], DialogDefault_DMsg.Cancel)
}

@(private = "file")
rename_view :: proc(ui: ^Ui(DialogDefault_DMsg), open: bool, submit: bool) {
	set_viewport(&ui.tree, {800, 600})
	begin_view(ui)
	column(ui, padding = .lg)
	button(ui, "Rename", DialogDefault_DMsg.None)
	if dialog(ui, open, DialogDefault_DMsg.Close, title = "Rename") {
		if submit {
			text_input(ui, nil, initial = "notes.txt", on_submit = DialogDefault_DMsg.Submit, label = "Name")
		} else {
			text_input(ui, nil, initial = "notes.txt", label = "Name")
		}
		checkbox(ui, false, "Open after renaming", on_change = DialogDefault_DMsg.Toggle)
		row(ui, gap = .sm)
		button(ui, "Cancel", DialogDefault_DMsg.Cancel, variant = .Outline)
		button(ui, "Rename", DialogDefault_DMsg.Keep, default = true, key = 7)
		end(ui)
		end(ui)
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {800, 600})
}

@(test)
a_field_keeps_focus_and_enter_reaches_the_default :: proc(t: ^testing.T) {
	ui: Ui(DialogDefault_DMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	rename_view(&ui, false, false)
	rename_view(&ui, true, false)
	field := node_named(&ui.tree, ui.tree.overlay, "Name")
	testing.expect_value(t, ui.tree.focus, field) // typing is what the dialog is for
	clear(&ui.msgs)
	testing.expect(t, key_event(&ui, .Enter, true, {}))
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0], DialogDefault_DMsg.Keep) // a field without on_submit does not use Enter

	box_n := node_named(&ui.tree, ui.tree.overlay, "Open after renaming")
	set_focus(&ui.tree, box_n, true)
	clear(&ui.msgs)
	key_event(&ui, .Enter, true, {})
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0], DialogDefault_DMsg.Keep) // Enter is the dialog's; Space toggles
	clear(&ui.msgs)
	key_event(&ui, .Space, true, {})
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0], DialogDefault_DMsg.Toggle)
}

@(test)
a_field_that_uses_enter_keeps_it :: proc(t: ^testing.T) {
	ui: Ui(DialogDefault_DMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	rename_view(&ui, false, true)
	rename_view(&ui, true, true)
	clear(&ui.msgs)
	key_event(&ui, .Enter, true, {})
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0], DialogDefault_DMsg.Submit)
}

} // when ODIN_TEST