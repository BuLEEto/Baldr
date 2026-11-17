#+build linux
package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: about 9 GB without this `when`, 1 GB with it.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A field handed over by the app (Ctrl+L for a path bar, Ctrl+F for a
// filter) arrives with its value selected, so the first thing typed replaces
// it. With the caret at the end, typing a path would append to one whose
// beginning had scrolled out of sight.


@(private = "file")
Fs_Msg :: enum { None, Changed }

@(private = "file")
fs_view :: proc(ui: ^Ui(Fs_Msg), value: ^Text, focus: bool) -> Node {
	set_viewport(&ui.tree, {420, 160})
	begin_view(ui)
	column(ui, flex = 1, padding = .lg)
	n := text_input(ui, value, label = "Folder path", width = 300, focus = focus,
		on_change = Fs_Msg.Changed, key = 2)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {420, 160})
	return n
}

@(test)
a_field_focused_by_the_app_hands_over_its_value_selected :: proc(t: ^testing.T) {
	ui: Ui(Fs_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	value := text_make("/tmp/orca-pass2/from")
	defer text_destroy(&value)

	n := fs_view(&ui, &value, false)
	lo, hi := text_input_selection(&ui.tree, n)
	testing.expect(t, lo == hi, "nothing is selected before it is focused")

	n = fs_view(&ui, &value, true) // the shortcut fires: focus turns true
	testing.expect_value(t, ui.tree.focus, n)
	lo, hi = text_input_selection(&ui.tree, n)
	testing.expect_value(t, lo, 0)
	testing.expect_value(t, hi, len("/tmp/orca-pass2/from"))

	// …so the first thing typed replaces the lot rather than appending
	text_event(&ui, "/home/user/landing")
	testing.expect_value(t, str(value), "/home/user/landing")

	// and the value is still there to edit: End puts the caret after it
	fs_view(&ui, &value, true)
	testing.expect(t, key_event(&ui, .End, true, {}))
	lo, hi = text_input_selection(&ui.tree, n)
	testing.expect(t, lo == hi && lo == len("/home/user/landing"), "End keeps the text and goes to its end")
}

} // when ODIN_TEST