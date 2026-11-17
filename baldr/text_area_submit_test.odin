package baldr

@(require) import "core:testing"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Which Enter sends. A notes field takes Ctrl+Enter; a chat composer takes
// Enter, with Shift+Enter for a line break, and an input method's Enter
// still only commits its composition.


@(private = "file")
Sub_Msg :: union { int }

@(private = "file")
sub_build :: proc(ui: ^Ui(Sub_Msg), doc: ^Document, submit: Maybe(Submit_Key)) -> Node {
	set_viewport(&ui.tree, {600, 400})
	begin_view(ui)
	column(ui)
	n := text_area(ui, doc, label = "Message", on_submit = Sub_Msg(1))
	if v, ok := submit.?; ok do editor_options(ui, n, submit = v)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	set_focus(&ui.tree, n, true)
	return n
}

@(test)
enter_sends_where_the_app_says_so :: proc(t: ^testing.T) {
	ui: Ui(Sub_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make("hello")
	defer document_destroy(&doc)

	// the default: Enter breaks the line, Ctrl+Enter sends
	n := sub_build(&ui, &doc, nil)
	was := document_text(&doc, context.temp_allocator)
	text_area_key(&ui, .Enter, {})
	testing.expect(t, len(ui.msgs) == 0 && document_text(&doc, context.temp_allocator) != was, "Enter is a line break")
	text_area_key(&ui, .Enter, {.Ctrl})
	testing.expect(t, len(ui.msgs) == 1, "Ctrl+Enter sends")
	clear(&ui.msgs)

	// a composer: Enter sends, Shift+Enter breaks the line
	n = sub_build(&ui, &doc, Submit_Key.Enter)
	before := document_text(&doc, context.temp_allocator)
	text_area_key(&ui, .Enter, {})
	testing.expect(t, len(ui.msgs) == 1 && document_text(&doc, context.temp_allocator) == before, "Enter sends, and types nothing")
	clear(&ui.msgs)
	text_area_key(&ui, .Enter, {.Shift})
	testing.expect(t, len(ui.msgs) == 0 && document_text(&doc, context.temp_allocator) != before, "Shift+Enter breaks the line")
	clear(&ui.msgs)

	// an input method is composing: its Enter commits, and sends nothing
	s := &ui.tree.areas[n]
	s.pre = "にほ"
	text_area_key(&ui, .Enter, {})
	testing.expect_value(t, len(ui.msgs), 0)
	s.pre = ""

	// a reader is told which key sends
	testing.expect_value(t, node_get(&ui.tree, n).access.describe, "Enter to send, Shift+Enter for a new line")
	editor_options(&ui, n, submit = .Ctrl_Enter)
	testing.expect_value(t, node_get(&ui.tree, n).access.describe, "")
}

} // when ODIN_TEST