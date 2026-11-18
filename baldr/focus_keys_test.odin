package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Where the keyboard goes when a dialog closes, what set_focus does with
// the node an editor's builder returns, and which keys an editor leaves to
// the window it is in.

@(private = "file")
Fk_Msg :: enum { None, Close, Search, Back, Bold }

@(private = "file")
fk_view :: proc(ui: ^Ui(Fk_Msg), doc: ^Document, open: bool, give: bool) -> (tree_btn, editor: Node) {
	begin_view(ui)
	column(ui)
	tree_btn = button(ui, "a.txt", Fk_Msg.None, key = 1)
	editor = code_editor(ui, doc, nil, label = "Source", height = 200, key = 2)
	if give do set_focus(&ui.tree, editor, false) // the app gives the file the keyboard in the build that closes the dialog
	end(ui)
	if dialog(ui, open, Fk_Msg.Close, title = "Go to File") {
		button(ui, "b.txt", Fk_Msg.None, key = 3)
		end(ui)
	}
	end_view(ui)
	frame(&ui.tree, {600, 400})
	return
}

@(test)
a_closing_dialog_leaves_the_keyboard_where_the_app_put_it :: proc(t: ^testing.T) {
	ui: Ui(Fk_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {600, 400})
	doc := document_make("package main")
	defer document_destroy(&doc)
	tree_btn, editor := fk_view(&ui, &doc, false, false)
	area := ui.tree.area_of_frame[editor]

	// the node code_editor returns stands for its text
	testing.expect(t, set_focus(&ui.tree, editor, false), "set_focus on an editor's frame")
	testing.expect_value(t, ui.tree.focus, area)
	testing.expect(t, !set_focus(&ui.tree, node_get(&ui.tree, editor).parent, false), "a container is refused")
	testing.expect_value(t, ui.tree.focus, area)

	// a dialog opened from the tree row, closed by a build that focuses the editor
	set_focus(&ui.tree, tree_btn, false)
	fk_view(&ui, &doc, true, false)
	testing.expect(t, ui.tree.modal != NODE_NONE, "the dialog is modal")
	fk_view(&ui, &doc, false, true)
	testing.expect_value(t, ui.tree.focus, area)

	// closed by a build that says nothing: back to the row it came from
	set_focus(&ui.tree, tree_btn, false)
	fk_view(&ui, &doc, true, false)
	fk_view(&ui, &doc, false, false)
	testing.expect_value(t, ui.tree.focus, tree_btn)
}

@(private = "file")
fk_editor :: proc(ui: ^Ui(Fk_Msg), doc, md: ^Document, field: ^Text) -> (code, mark, input: Node) {
	begin_view(ui)
	column(ui)
	shortcut(ui, "Ctrl+Shift+F", Fk_Msg.Search)
	shortcut(ui, "Alt+Left", Fk_Msg.Back)
	shortcut(ui, "Ctrl+Shift+B", Fk_Msg.Bold)
	code = code_editor(ui, doc, nil, label = "Source", height = 150, key = 1)
	mark = markdown_editor(ui, md, label = "Notes", key = 2)
	input = text_input(ui, field, label = "Name", key = 3)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 600})
	return
}

// fk_press is what a person pressing the key gets: the focused widget's
// say first, then the window's shortcuts for what it declined.
@(private = "file")
fk_press :: proc(ui: ^Ui(Fk_Msg), key: Key, mods: Mods) -> (taken_by_widget: bool, msg: Fk_Msg) {
	clear(&ui.msgs)
	taken_by_widget = key_event(ui, key, true, mods)
	if !taken_by_widget do shortcut_fire(ui, key, true, mods)
	if len(ui.msgs) > 0 do msg = ui.msgs[len(ui.msgs) - 1]
	clear(&ui.msgs)
	return
}

@(test)
an_editor_leaves_the_windows_keys_to_the_window :: proc(t: ^testing.T) {
	ui: Ui(Fk_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {600, 600})
	doc := document_make("first\nsecond\nthird")
	defer document_destroy(&doc)
	md := document_make("some notes")
	defer document_destroy(&md)
	field := text_make("abc")
	defer text_destroy(&field)
	code, mark, input := fk_editor(&ui, &doc, &md, &field)
	area := ui.tree.area_of_frame[code]
	s := &ui.tree.areas[area]

	set_focus(&ui.tree, code, false)
	s.caret, s.anchor = {1, 3}, {1, 3}
	taken, msg := fk_press(&ui, .F, {.Ctrl, .Shift})
	testing.expect(t, !taken && msg == .Search, "Ctrl+Shift+F is the window's search, not the file's find bar")
	testing.expect_value(t, s.code.bar, Code_Bar.None)
	taken, _ = fk_press(&ui, .H, {.Ctrl, .Shift})
	testing.expect(t, !taken && s.code.bar == .None, "nor is Ctrl+Shift+H its replace bar")
	taken, _ = fk_press(&ui, .F, {.Ctrl})
	testing.expect(t, taken && s.code.bar == .Find, "Ctrl+F still is")
	fk_editor(&ui, &doc, &md, &field)
	fk_press(&ui, .Escape, {})
	set_focus(&ui.tree, code, false)
	s = &ui.tree.areas[area] // the build may have moved the table

	s.caret, s.anchor = {1, 3}, {1, 3}
	taken, msg = fk_press(&ui, .Left, {.Alt})
	when ODIN_OS != .Darwin {
		testing.expect(t, !taken && msg == .Back, "Alt+Left is the window's Back")
		testing.expect_value(t, s.caret, Pos{1, 3})
	}
	taken, _ = fk_press(&ui, .Up, {.Alt})
	testing.expect(t, taken, "a code editor's Alt+Up moves the line, as before")
	testing.expect_value(t, document_text(&doc, context.temp_allocator), "second\nfirst\nthird")

	// the markdown editor's formatting chords are Ctrl alone
	set_focus(&ui.tree, mark, false)
	taken, msg = fk_press(&ui, .B, {.Ctrl, .Shift})
	testing.expect(t, !taken && msg == .Bold, "Ctrl+Shift+B is the window's")

	// and a field leaves Alt+Left to the window too
	set_focus(&ui.tree, input, false)
	when ODIN_OS != .Darwin {
		taken, msg = fk_press(&ui, .Left, {.Alt})
		testing.expect(t, !taken && msg == .Back, "a field's Alt+Left is the window's Back")
	}
}

} // when ODIN_TEST
