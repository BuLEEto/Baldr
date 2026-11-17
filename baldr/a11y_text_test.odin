package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// What a reader is told about text: the characters an entry or an editor
// holds, where the caret is in them, and — when it moves or the text
// changes — what changed. AT-SPI counts characters, the widgets count
// bytes, so the counting is half of what these check.


@(private = "file")
with_window :: proc(ui: ^Ui(Test_Msg)) {
	a11y_test_window(&ui.tree)
}

@(test)
a11y_reads_an_entrys_text_and_caret :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	value := text_make("naïve café")
	defer text_destroy(&value)
	begin_view(&ui)
	field := text_input(&ui, &value, label = "Name")
	end_view(&ui)
	frame(&ui.tree, {400, 200})
	with_window(&ui)
	defer a11y_test_reset()

	id, _ := a11y_id(0, field)
	n, ok := a11y_obj(id)
	testing.expect(t, ok)
	testing.expect(t, n.has_text, "an entry holds text a reader can read")
	testing.expect(t, !n.has_value, "and does not pretend to be a slider")

	info, has := a11y_obj_text(id)
	testing.expect(t, has, "it answers what it holds")
	testing.expect_value(t, info.text, "naïve café")
	testing.expect(t, info.editable, "and that it can be typed in")

	// the caret at the end of a string with two multi-byte characters is
	// at character 10, not byte 12
	set_focus(&ui.tree, field, true)
	if s, is := &ui.tree.inputs[field]; is {
		s.caret, s.anchor = len("naïve café"), len("naïve café")
	}
	info, _ = a11y_obj_text(id)
	testing.expect_value(t, a11y_char_off(info.text, info.caret), 10)
	testing.expect_value(t, a11y_byte_off(info.text, 10), 12)
	testing.expect_value(t, a11y_char_off(info.text, a11y_byte_off(info.text, 4)), 4)
}

@(test)
a11y_reads_an_editors_text_across_its_lines :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make("first line\nsecond line")
	defer document_destroy(&doc)
	begin_view(&ui)
	ed := text_area(&ui, &doc, label = "Notes", width = 300, height = 200)
	end_view(&ui)
	frame(&ui.tree, {400, 300})
	with_window(&ui)
	defer a11y_test_reset()

	id, _ := a11y_id(0, ed)
	info, has := a11y_obj_text(id)
	testing.expect(t, has)
	testing.expect_value(t, info.text, "first line\nsecond line")

	// a caret on the second line counts from the start of the document,
	// newlines included
	_, s := editor_area(&ui.tree, ed)
	s.caret = Pos{block = 1, off = 3}
	s.anchor = s.caret
	info, _ = a11y_obj_text(id)
	testing.expect_value(t, info.caret, len("first line\n") + 3)
}

@(test)
a11y_says_what_changed_in_the_text :: proc(t: ^testing.T) {
	// the diff behind object:text-changed — the common prefix and suffix,
	// counted in characters
	at, removed, added := a11y_text_delta("hello", "hello world")
	testing.expect_value(t, at, 5)
	testing.expect_value(t, removed, 0)
	testing.expect_value(t, added, 6)

	at, removed, added = a11y_text_delta("hello world", "hello")
	testing.expect_value(t, at, 5)
	testing.expect_value(t, removed, 6)
	testing.expect_value(t, added, 0)

	at, removed, added = a11y_text_delta("caff", "café")
	testing.expect_value(t, at, 3)
	testing.expect_value(t, removed, 1)
	testing.expect_value(t, added, 1) // one character, two bytes

	at, removed, added = a11y_text_delta("same", "same")
	testing.expect_value(t, removed, 0)
	testing.expect_value(t, added, 0)
}

@(test)
a11y_serves_a_sliders_value :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	sl := slider(&ui, 40, min = 0, max = 100, step = 5, label = "Volume")
	end_view(&ui)
	frame(&ui.tree, {400, 200})
	with_window(&ui)
	defer a11y_test_reset()

	id, _ := a11y_id(0, sl)
	n, ok := a11y_obj(id)
	testing.expect(t, ok)
	testing.expect_value(t, n.role, A11y_Role.Slider)
	testing.expect(t, n.has_value, "a slider says what it is worth")
	testing.expect_value(t, n.value, 40)
	testing.expect_value(t, n.value_min, 0)
	testing.expect_value(t, n.value_max, 100)
	testing.expect_value(t, n.value_step, 5) // the slider's own step, which its arrow keys use
}

@(test)
a11y_serves_a_number_inputs_own_step :: proc(t: ^testing.T) {
	// A number input keeps its own step and a reader should offer that one,
	// not a hundredth of the range (0.99 for 0 to 99).
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	num := number_input(&ui, 3, min = 0, max = 99, step = 1, label = "Copies")
	end_view(&ui)
	frame(&ui.tree, {400, 200})
	with_window(&ui)
	defer a11y_test_reset()

	// the outer node is transparent; the field is what a reader is given
	field := ui.tree.spins[num].field
	id, _ := a11y_id(0, field)
	n, ok := a11y_obj(id)
	testing.expect(t, ok)
	testing.expect_value(t, n.role, A11y_Role.Spin_Button)
	testing.expect_value(t, n.value_step, 1)
}

@(test)
a11y_asks_an_editor_when_it_changed_rather_than_comparing :: proc(t: ^testing.T) {
	// A document nobody is typing in should not be compared character by
	// character every wake-up: the editor keeps a version, and that is what
	// the watch looks at.
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make("one")
	defer document_destroy(&doc)
	begin_view(&ui)
	ed := text_area(&ui, &doc, label = "Notes", width = 300, height = 200)
	field := text_input(&ui, nil, label = "Name")
	end_view(&ui)
	frame(&ui.tree, {400, 300})

	was := a11y_text_version(&ui.tree, ed)
	testing.expect(t, was != 0, "an editor says when it changed")
	end := document_end(&doc)
	document_replace(&doc, end, end, " more")
	testing.expect(t, a11y_text_version(&ui.tree, ed) != was, "and says so after an edit")
	testing.expect_value(t, a11y_text_version(&ui.tree, field), 0) // a field has no counter: its text is short enough to compare
}

@(test)
a11y_moves_the_caret_where_a_reader_asks :: proc(t: ^testing.T) {
	// A reader moving the caret is the one write we honour on text: the
	// offsets come in as characters, are converted to bytes by the bridge,
	// and land on a position the editor understands.
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make("first line\nsecond line")
	defer document_destroy(&doc)
	begin_view(&ui)
	ed := text_area(&ui, &doc, label = "Notes", width = 300, height = 200)
	end_view(&ui)
	frame(&ui.tree, {400, 300})
	with_window(&ui)
	defer a11y_test_reset()

	// a byte offset and the position it names, both ways
	p := document_pos_at(&doc, len("first line\n") + 3)
	testing.expect_value(t, p.block, 1)
	testing.expect_value(t, p.off, 3)
	testing.expect_value(t, document_flat_off(&doc, p), len("first line\n") + 3)
	testing.expect_value(t, document_pos_at(&doc, 0), document_start())
	testing.expect_value(t, document_pos_at(&doc, 9999), document_end(&doc))

	// with no way back into the run loop (a test), the move is refused
	// rather than half done
	id, _ := a11y_id(0, ed)
	testing.expect(t, !a11y_set_caret(id, 3), "nothing to act through")
	_, s := editor_area(&ui.tree, ed)
	testing.expect_value(t, s.caret, document_start())
}

// ------------------------------------------------------------ editing

// A reader typing on someone's behalf must land in the same place a keyboard
// would: the same edit, the same undo step, the same change the app hears.
// These drive the provider the bridge calls, with the run loop's own act
// callback standing in for the loop.

@(private = "file")
Edit_Ctx :: struct {
	ui:   ^Ui(Test_Msg),
	acts: int,
}

@(private = "file", thread_local)
edit_ctx: Edit_Ctx

@(private = "file")
with_acting_window :: proc(ui: ^Ui(Test_Msg)) {
	a11y_test_window(&ui.tree)
	edit_ctx = {ui = (^Ui(Test_Msg))(rawptr(ui))} // kept until a11y_test_reset; said so for the escape analysis
	a11y.windows[0].user = &edit_ctx
	a11y.windows[0].act = proc(user: rawptr, n: Node, what: A11y_Act) -> bool {
		c := (^Edit_Ctx)(user)
		c.acts += 1
		switch what {
		case .Click: return click(c.ui, n)
		case .Focus: return set_focus(&c.ui.tree, n, true)
		case .Edit:  return a11y_apply_edit(c.ui, n)
		case .Clip:  return a11y_apply_clip(c.ui, n)
		case .Wake:  return true
		}
		return false
	}
}

// A reader acts only on what it is shown. Behind an open dialog the window
// is inert, and any program on the accessibility bus asking to press a button
// or type into a field there is refused, as a click there would be.
@(test)
a_reader_cannot_act_behind_an_open_dialog :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	value := text_make("Hello")
	defer text_destroy(&value)
	build :: proc(ui: ^Ui(Test_Msg), value: ^Text, open: bool) -> (field, btn: Node) {
		begin_view(ui)
		column(ui)
		field = text_input(ui, value, label = "Name")
		btn = button(ui, "Delete everything", Test_Msg.Dec)
		end(ui)
		if dialog(ui, open, Test_Msg.Toggle, title = "Confirm") {
			text(ui, "Sure?")
			end(ui)
		}
		end_view(ui)
		frame(&ui.tree, {400, 300})
		return
	}
	field, btn := build(&ui, &value, true)
	with_acting_window(&ui)
	defer a11y_test_reset()
	fid, _ := a11y_id(0, field)
	bid, _ := a11y_id(0, btn)
	testing.expect(t, !a11y_edit(fid, 0, 5, "Gone"), "no typing behind the dialog")
	testing.expect_value(t, str(value), "Hello")
	testing.expect(t, !a11y_do_action(bid), "no pressing behind it")
	testing.expect(t, !a11y_set_caret(fid, 2), "nor moving its caret")
	testing.expect(t, !a11y_clip(fid, .Copy), "nor copying from it")

	// with the dialog closed, the same requests go through
	field, btn = build(&ui, &value, false)
	fid, _ = a11y_id(0, field)
	testing.expect(t, a11y_edit(fid, 0, 5, "Hi"), "typing once it is closed")
	testing.expect_value(t, str(value), "Hi")
}

@(test)
a_reader_can_type_into_a_field :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	value := text_make("Hello")
	defer text_destroy(&value)
	begin_view(&ui)
	field := text_input(&ui, &value, label = "Name")
	end_view(&ui)
	frame(&ui.tree, {400, 200})
	with_acting_window(&ui)
	defer a11y_test_reset()

	id, _ := a11y_id(0, field)
	n, _ := a11y_obj(id)
	testing.expect(t, n.has_text && n.editable, "a live field can be typed into")

	// insert at the end, as InsertText does
	testing.expect(t, a11y_edit(id, 5, 5, ", world"))
	testing.expect_value(t, str(value), "Hello, world")

	// replace a range, as DeleteText plus InsertText does
	testing.expect(t, a11y_edit(id, 0, 5, "Goodbye"))
	testing.expect_value(t, str(value), "Goodbye, world")

	// and the app was told each time, exactly as if someone had typed
	testing.expect(t, edit_ctx.acts >= 2)
}

@(test)
a_reader_typing_into_an_editor_goes_through_its_undo :: proc(t: ^testing.T) {
	// The reason this is not a "set the text" call: an edit made this way
	// has to be one an undo takes back.
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make("one two")
	defer document_destroy(&doc)
	begin_view(&ui)
	ed := text_area(&ui, &doc, label = "Notes", width = 300, height = 200)
	end_view(&ui)
	frame(&ui.tree, {400, 300})
	with_acting_window(&ui)
	defer a11y_test_reset()

	id, _ := a11y_id(0, ed)
	testing.expect(t, a11y_edit(id, 7, 7, " three"))
	testing.expect_value(t, document_text(&doc, context.temp_allocator), "one two three")

	_, undone := document_undo(&doc)
	testing.expect(t, undone, "a reader's typing is an undo step like any other")
	testing.expect_value(t, document_text(&doc, context.temp_allocator), "one two")
}

@(test)
a_reader_cannot_type_where_a_keyboard_cannot :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make("read only")
	defer document_destroy(&doc)
	begin_view(&ui)
	ed := text_area(&ui, &doc, label = "Notes", width = 300, height = 200)
	editor_options(&ui, ed, readonly = true)
	end_view(&ui)
	frame(&ui.tree, {400, 300})
	with_acting_window(&ui)
	defer a11y_test_reset()

	id, _ := a11y_id(0, ed)
	n, _ := a11y_obj(id)
	testing.expect(t, n.has_text, "it still holds text a reader can read")
	testing.expect(t, !n.editable, "…and says plainly that it cannot be typed into")
	testing.expect(t, !a11y_edit(id, 0, 4, "write"), "and refuses")
	testing.expect_value(t, document_text(&doc, context.temp_allocator), "read only")
}

@(test)
a_reader_can_put_the_selection_where_it_means_to_cut :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	value := text_make("alpha beta")
	defer text_destroy(&value)
	begin_view(&ui)
	field := text_input(&ui, &value, label = "Name")
	end_view(&ui)
	frame(&ui.tree, {400, 200})
	with_acting_window(&ui)
	defer a11y_test_reset()

	id, _ := a11y_id(0, field)
	testing.expect(t, a11y_select_range(id, 0, 5))
	info, _ := a11y_obj_text(id)
	testing.expect_value(t, info.sel_lo, 0)
	testing.expect_value(t, info.sel_hi, 5)
}

@(test)
a11y_reads_a_reply_as_text_and_follows_it_growing :: proc(t: ^testing.T) {
	// A rendered reply is a *static* that holds a body of text. It offers
	// the Text interface, not a long description, so a reader can read it
	// line by line or word by word and follow it as it streams in.
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, "## Steps\n\n1. Pull the top 5 parts.\n")
	// one builder for both passes: a second call from another line is
	// another node, and the reader would be holding the one that went
	build :: proc(ui: ^Ui(Test_Msg), md: ^Markdown_Doc) -> Node {
		begin_view(ui)
		n := markdown_view(ui, md, label = "Assistant's reply", width = 400)
		end_view(ui)
		frame(&ui.tree, {400, 300})
		return n
	}
	reply := build(&ui, &md)
	with_window(&ui)
	defer a11y_test_reset()

	id, _ := a11y_id(0, reply)
	n, ok := a11y_obj(id)
	testing.expect(t, ok)
	testing.expect_value(t, n.name, "Assistant's reply")
	testing.expect(t, n.has_text, "a reply holds text a reader can read")
	info, has := a11y_obj_text(id)
	testing.expect(t, has, "and answers what it holds")
	testing.expect(t, !info.editable, "read-only: a reply is not typed in")
	testing.expect_value(t, info.text, "Steps\n1. Pull the top 5 parts.")

	// it streams: what a reader is told is what arrived, not the whole reply
	events := make([dynamic]A11y_Said, context.temp_allocator)
	a11y_test_watch(&events)
	set_focus(&ui.tree, reply, true) // a reader holds the focused object's text
	a11y_events()                    // …which this pass takes a picture of
	clear(&events)
	md_append(&md, "2. Compare each one.\n")
	build(&ui, &md)
	a11y_events()
	inserted := ""
	for e in events do if v, is_edit := e.(Said_Text_Edit); is_edit && v.inserted do inserted = v.text
	testing.expect(t, strings.contains(inserted, "Compare each one."), "the new words are the insertion")
	testing.expect(t, !strings.contains(inserted, "Pull the top 5"), "and the reply is not read out again")
}

} // when ODIN_TEST