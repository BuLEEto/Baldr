package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private="file")
SK :: enum { None, Rename, Remove, New_Folder, Zoom_In, Go_Up, Filter }

@(private="file")
files_view :: proc(ui: ^Ui(SK), doc: ^Document, modal := false) -> (list: Node, field: Node) {
	begin_view(ui)
	column(ui, gap = .sm)
	shortcut(ui, "F2", SK.Rename)
	shortcut(ui, "Delete", SK.Remove)
	shortcut(ui, "Ctrl+Shift+N", SK.New_Folder)
	shortcut(ui, "Ctrl++", SK.Zoom_In)
	shortcut(ui, "Alt+Up", SK.Go_Up)
	list = button(ui, "Files", SK.None)
	if doc != nil do field = text_area(ui, doc, label = "Name")
	if dialog(ui, modal, SK.None, title = "Sure?") {
		button(ui, "OK", SK.None)
		end(ui)
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 300})
	return
}

@(test)
shortcut_parses_the_usual_spellings :: proc(t: ^testing.T) {
	Case :: struct { s: string, key: Key, mods: Mods, ok: bool }
	cases := []Case{
		{"F2", .F2, {}, true},
		{"Ctrl+N", .N, {.Ctrl}, true},
		{"ctrl+shift+n", .N, {.Ctrl, .Shift}, true},
		{"Alt+Left", .Left, {.Alt}, true},
		{"Cmd+,", .Comma, {.Super}, true},
		{"Ctrl++", .Equal, {.Ctrl}, true},
		{"Ctrl+-", .Minus, {.Ctrl}, true},
		{"Page Up", .Page_Up, {}, true},
		{"Shift+Del", .Delete, {.Shift}, true},
		{"Ctrl+1", .N1, {.Ctrl}, true},
		{"Ctrl", .Unknown, {}, false},   // no key
		{"A+B", .Unknown, {}, false},    // two keys
		{"Ctrl+Bogus", .Unknown, {}, false},
		{"", .Unknown, {}, false},
	}
	for c in cases {
		key, mods, ok := parse_shortcut(c.s)
		testing.expectf(t, ok == c.ok && key == c.key && mods == c.mods, "%q → %v %v %v, want %v %v %v", c.s, key, mods, ok, c.key, c.mods, c.ok)
	}
}

@(test)
shortcut_fires_when_no_widget_takes_the_key :: proc(t: ^testing.T) {
	ui: Ui(SK)
	ui_init(&ui)
	defer ui_destroy(&ui)
	list, _ := files_view(&ui, nil)
	set_focus(&ui.tree, list, true)
	testing.expect(t, !key_event(&ui, .F2, true, {}), "a button does not use F2")
	testing.expect(t, shortcut_fire(&ui, .F2, true, {}), "so the view's binding fires")
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0], SK.Rename)
	testing.expect(t, !shortcut_fire(&ui, .F2, false, {}), "not on release")
	testing.expect(t, !shortcut_fire(&ui, .N, true, {.Ctrl}), "Ctrl+N is not bound")
	testing.expect(t, shortcut_fire(&ui, .N, true, {.Ctrl, .Shift}), "Ctrl+Shift+N is")
	testing.expect(t, shortcut_fire(&ui, .Equal, true, {.Ctrl}), "Ctrl++")
	testing.expect(t, shortcut_fire(&ui, .Up, true, {.Alt}), "Alt+Up")
	testing.expect_value(t, len(ui.msgs), 4)
	testing.expect_value(t, ui.msgs[3], SK.Go_Up)
	testing.expect_value(t, len(ui.tree.diags), 0)
}

@(test)
shortcut_yields_to_the_focused_field_and_to_a_modal :: proc(t: ^testing.T) {
	ui: Ui(SK)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make("name")
	defer document_destroy(&doc)
	_, field := files_view(&ui, &doc)
	set_focus(&ui.tree, field, true)
	testing.expect(t, key_event(&ui, .Delete, true, {}), "the field uses Delete")
	testing.expect_value(t, len(ui.msgs), 0)
	testing.expect(t, !key_event(&ui, .F2, true, {}), "but not F2")
	testing.expect(t, shortcut_fire(&ui, .F2, true, {}))
	testing.expect_value(t, len(ui.msgs), 1)
	files_view(&ui, &doc, modal = true)
	testing.expect(t, ui.tree.modal != NODE_NONE)
	testing.expect(t, !shortcut_fire(&ui, .F2, true, {}), "nothing fires under a modal dialog")
	testing.expect_value(t, len(ui.msgs), 1)
}

@(test)
shortcut_that_does_not_parse_is_a_diagnostic :: proc(t: ^testing.T) {
	ui: Ui(SK)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	shortcut(&ui, "Ctrl+Bogus", SK.Rename)
	end_view(&ui)
	testing.expect_value(t, len(ui.tree.diags), 1)
	testing.expect_value(t, len(ui.shortcuts), 0)
	for d in ui.tree.diags do delete(d.msg, ui.allocator)
	clear(&ui.tree.diags)
}

@(private="file")
typing_label :: proc(user: rawptr, index: int) -> string { return "readme" }

@(private="file")
typing_view :: proc(ui: ^Ui(SK), doc: ^Document, sel: ^Selection, labels: bool) -> (btn, field, area, clock: Node) {
	set_viewport(&ui.tree, {500, 400})
	begin_view(ui)
	column(ui, gap = .sm, flex = 1)
	shortcut(ui, "/", SK.Filter)
	shortcut(ui, "Shift+/", SK.Rename)
	shortcut(ui, "Ctrl+/", SK.Go_Up)
	shortcut(ui, "R", SK.Remove)
	shortcut(ui, "1", SK.Zoom_In)
	btn = button(ui, "Files", SK.None)
	field = text_input(ui, nil, label = "Location")
	area = text_area(ui, doc, label = "Notes")
	clock = time_picker(ui, Time_Of_Day{}, label = "Start", clock = .H24)
	cols := []Column{{title = "Name"}}
	label_of: Label_Of = typing_label if labels else nil
	first, last := table(ui, cols, 3, sel, label_of = label_of, label = "Files", flex = 1, key = 9)
	for i in first ..< last {
		table_row(ui, i)
		cell_text(ui, "readme")
		end(ui)
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {500, 400})
	return
}

// A printable key bound for the window ("/") is typed into a focused path
// field rather than fired.
@(test)
shortcut_on_a_printable_key_yields_to_typing :: proc(t: ^testing.T) {
	ui: Ui(SK)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make("")
	defer document_destroy(&doc)
	sel := selection_make()
	defer selection_destroy(&sel)
	press :: proc(ui: ^Ui(SK), key: Key, mods: Mods) -> bool {
		return key_event(ui, key, true, mods) || shortcut_fire(ui, key, true, mods) // the run loop's order
	}
	btn, field, area, clock := typing_view(&ui, &doc, &sel, true)
	tbl: Node
	for n in ui.tree.tables do tbl = n

	set_focus(&ui.tree, field, true)
	testing.expect(t, !press(&ui, .Slash, {}), "the field is typing /")
	text_event(&ui, "/")
	testing.expect(t, !press(&ui, .Slash, {.Shift}), "and ? (Shift alone still types)")
	text_event(&ui, "?")
	testing.expect(t, !press(&ui, .R, {}))
	text_event(&ui, "r")
	testing.expect_value(t, len(ui.msgs), 0)
	testing.expect_value(t, ui.tree.focus, field)
	lo, hi := text_input_selection(&ui.tree, field)
	testing.expect(t, lo == 3 && hi == 3, "all three characters went into the field")
	testing.expect(t, press(&ui, .Slash, {.Ctrl}), "Ctrl+/ is not typing: it fires")
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == .Go_Up)
	clear(&ui.msgs)

	set_focus(&ui.tree, area, true)
	testing.expect(t, !press(&ui, .R, {}), "an editable text area is typing r")
	editor_options(&ui, area, readonly = true)
	testing.expect(t, press(&ui, .R, {}), "a read-only one types nothing, so R fires")
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == .Remove)
	clear(&ui.msgs)

	set_focus(&ui.tree, tbl, true)
	testing.expect(t, !press(&ui, .R, {}), "a view with type-ahead keeps letters")
	testing.expect_value(t, len(ui.msgs), 0)
	typing_view(&ui, &doc, &sel, false)
	testing.expect_value(t, ui.tree.focus, tbl)
	testing.expect(t, press(&ui, .R, {}), "without labels a letter is the window's")
	set_focus(&ui.tree, btn, true)
	testing.expect(t, press(&ui, .Slash, {}), "and with a button focused / fires")
	testing.expect(t, len(ui.msgs) == 2 && ui.msgs[0] == .Remove && ui.msgs[1] == .Filter)
	clear(&ui.msgs)

	set_focus(&ui.tree, clock, true)
	press(&ui, .N1, {})
	testing.expect_value(t, len(ui.msgs), 0) // a 24-hour time picker is typing the digit
	testing.expect(t, press(&ui, .Slash, {}), "but not /")
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == .Filter)
}

@(test)
image_contain_rect_letterboxes :: proc(t: ^testing.T) {
	box := Rect{10, 10, 100, 100}
	wide := image_contain_rect(box, 200, 100)
	testing.expect_value(t, wide, Rect{10, 35, 100, 50})
	tall := image_contain_rect(box, 50, 100)
	testing.expect_value(t, tall, Rect{35, 10, 50, 100})
	square := image_contain_rect(box, 7, 7)
	testing.expect_value(t, square, box)
}

} // when ODIN_TEST