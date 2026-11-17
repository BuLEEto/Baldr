package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: behind this `when`, checking a program costs
// 1.0 GB instead of 9.2 GB. ODIN_TEST is set by `odin test`; BALDR_TESTS
// lets ./build.sh check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Typing through an input method.
// The focused field says what it is, what is around its caret and where the
// caret is; the method answers with a composition shown at the caret, text
// to commit and text to delete — and the composition never reaches the
// Document or the undo history.


@(private = "file")
Im_Msg :: union { int }

@(private = "file")
Spy :: struct {
	info:  Ime_Info,
	text:  string, // info.surrounding, ours
	calls: int,
}

@(private = "file")
spy_install :: proc(ui: ^Ui(Im_Msg), spy: ^Spy) {
	ui.tree.ime.hook = {
		user = spy,
		surface = 1,
		set = proc(user: rawptr, surface: u32, info: Ime_Info) {
			s := (^Spy)(user)
			delete(s.text)
			s.text = strings.clone(info.surrounding)
			s.info = info
			s.info.surrounding = s.text
			s.calls += 1
		},
	}
}

@(private = "file")
Fields :: struct {
	field, secret, area, code: Node,
}

@(private = "file")
build :: proc(ui: ^Ui(Im_Msg), value, secret: ^Text, doc, src: ^Document, readonly := false) -> (f: Fields) {
	begin_view(ui)
	column(ui, padding = .lg, gap = .md)
	f.field = text_input(ui, value, label = "Name", width = 240)
	f.secret = text_input(ui, secret, label = "Password", width = 240, password = true)
	f.area = text_area(ui, doc, label = "Notes", width = 320, height = 120)
	editor_options(ui, f.area, readonly = readonly)
	f.code = code_editor(ui, src, nil, label = "Code", width = 320, height = 120)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 600})
	return
}

// what the input method is told after focus or the text moved
@(private = "file")
settle_ime :: proc(ui: ^Ui(Im_Msg)) {
	ui_after_events(ui, ui.tree.now_ms)
}

@(private = "file")
area_of :: proc(ui: ^Ui(Im_Msg), n: Node) -> (Node, ^Text_Area_State) {
	return editor_area(&ui.tree, n)
}

@(test)
a_field_tells_an_input_method_what_it_is :: proc(t: ^testing.T) {
	ui: Ui(Im_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	spy: Spy
	defer delete(spy.text)
	spy_install(&ui, &spy)
	value := text_make("Ada", context.allocator)
	defer text_destroy(&value)
	secret := text_make("hunter2", context.allocator)
	defer text_destroy(&secret)
	doc := document_make("first line\nsecond line")
	defer document_destroy(&doc)
	src := document_make("x := 1")
	defer document_destroy(&src)
	f := build(&ui, &value, &secret, &doc, &src)

	settle_ime(&ui)
	testing.expect(t, !spy.info.on, "nothing focused: no input method")

	set_focus(&ui.tree, f.field, false)
	settle_ime(&ui)
	testing.expect(t, spy.info.on, "a focused field takes one")
	testing.expect_value(t, spy.info.surrounding, "Ada")
	testing.expect(t, spy.info.cursor == spy.info.anchor, "no selection")
	d := node_get(&ui.tree, f.field)
	testing.expect(t, rect_contains(d.abs, {spy.info.caret.x, spy.info.caret.y + 1}), "the caret rectangle is in the field")
	testing.expect_value(t, spy.info.purpose, Ime_Purpose.Normal)

	set_focus(&ui.tree, f.secret, false)
	settle_ime(&ui)
	testing.expect(t, !spy.info.on, "a password takes none")
	testing.expect_value(t, spy.info.purpose, Ime_Purpose.Password)
	testing.expect(t, spy.info.hints == {.Sensitive_Data, .Hidden_Text}, "and says so")

	set_focus(&ui.tree, f.area, false)
	editor_select(&ui, f.area, Pos{1, 3}, Pos{1, 6})
	settle_ime(&ui)
	testing.expect(t, spy.info.on && spy.info.surrounding == "second line", "an editor sends the caret's line")
	testing.expect(t, spy.info.cursor == 6 && spy.info.anchor == 3, "with the caret and the anchor in it")
	testing.expect(t, spy.info.hints == {.Multiline, .Spellcheck}, "a prose editor asks for spelling")

	code_area, _ := area_of(&ui, f.code)
	set_focus(&ui.tree, code_area, false)
	settle_ime(&ui)
	testing.expect(t, spy.info.on && spy.info.hints == {.Multiline}, "a code editor does not")

	// readonly and disabled take nothing
	build(&ui, &value, &secret, &doc, &src, readonly = true)
	set_focus(&ui.tree, f.area, false)
	settle_ime(&ui)
	testing.expect(t, !spy.info.on, "a readonly editor takes no input method")

	calls := spy.calls
	settle_ime(&ui)
	testing.expect_value(t, spy.calls, calls) // nothing moved: nothing said
}

@(test)
a_composition_shows_at_the_caret_and_stays_out_of_the_document :: proc(t: ^testing.T) {
	ui: Ui(Im_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	value := text_make("Ada", context.allocator)
	defer text_destroy(&value)
	secret := text_make("", context.allocator)
	defer text_destroy(&secret)
	doc := document_make("hello\nworld")
	defer document_destroy(&doc)
	src := document_make("x := 1")
	defer document_destroy(&src)
	f := build(&ui, &value, &secret, &doc, &src)
	area, s := area_of(&ui, f.area)
	set_focus(&ui.tree, area, false)
	editor_select(&ui, f.area, Pos{0, 5}, Pos{0, 5})

	testing.expect(t, ime_apply(&ui, Ime_Event{preedit = "ni", cursor_begin = 2, cursor_end = 2}), "the composition arrives")
	build(&ui, &value, &secret, &doc, &src)
	testing.expect_value(t, area_text(&ui.tree, s, 0), "helloni") // drawn
	testing.expect_value(t, document_text(&doc, context.temp_allocator), "hello\nworld") // not in the Document
	testing.expect_value(t, len(doc.undo), 0)
	testing.expect_value(t, s.caret, Pos{0, 5})

	// the caret sits where the method put its cursor: after "ni", not before it
	_, _, x_at_end := caret_line(&ui.tree, s, s.caret)
	ime_apply(&ui, Ime_Event{preedit = "ni", cursor_begin = 0, cursor_end = 0})
	build(&ui, &value, &secret, &doc, &src)
	_, _, x_at_start := caret_line(&ui.tree, s, s.caret)
	testing.expect(t, x_at_end > x_at_start, "the caret follows the method's cursor")

	// a longer composition is longer on screen, and the line's hit test skips over it
	p := area_hit(&ui.tree, area, node_get(&ui.tree, area), s, {node_get(&ui.tree, area).abs.x + 1000, node_get(&ui.tree, area).abs.y + 8})
	testing.expect_value(t, p, Pos{0, 5}) // past the end of the line: the source ends there, composition and all

	// committing replaces it and lands in the Document, once
	testing.expect(t, ime_apply(&ui, Ime_Event{commit = "你好"}), "committed")
	build(&ui, &value, &secret, &doc, &src)
	testing.expect_value(t, document_text(&doc, context.temp_allocator), "hello你好\nworld")
	testing.expect_value(t, area_text(&ui.tree, s, 0), "hello你好")
	testing.expect(t, len(doc.undo) > 0, "the commit is undoable")
	testing.expect_value(t, len(s.pre), 0)
	document_undo(&doc)
	testing.expect_value(t, document_text(&doc, context.temp_allocator), "hello\nworld")
	testing.expect_value(t, len(doc.undo), 0) // one step for the whole commit
}

@(test)
a_composition_is_underlined_where_it_sits :: proc(t: ^testing.T) {
	ui: Ui(Im_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	value := text_make("Ada", context.allocator)
	defer text_destroy(&value)
	secret := text_make("", context.allocator)
	defer text_destroy(&secret)
	doc := document_make("hello")
	defer document_destroy(&doc)
	src := document_make("x := 1")
	defer document_destroy(&src)
	f := build(&ui, &value, &secret, &doc, &src)
	rules :: proc(ui: ^Ui(Im_Msg), n: Node) -> (count: int) {
		d := node_get(&ui.tree, n)
		for _, l in ui.tree.layers do for c in l.cmds {
			if r, ok := c.(Draw_Rect); ok && r.rect.h <= 2 && r.rect.w > 1 && rect_contains(d.abs, {r.rect.x + 1, r.rect.y}) do count += 1
		}
		return
	}
	area, _ := area_of(&ui, f.area)
	set_focus(&ui.tree, area, false)
	editor_select(&ui, f.area, Pos{0, 5}, Pos{0, 5})
	build(&ui, &value, &secret, &doc, &src)
	before := rules(&ui, area)
	ime_apply(&ui, Ime_Event{preedit = "nihao", cursor_begin = 2, cursor_end = 4})
	build(&ui, &value, &secret, &doc, &src)
	testing.expect(t, rules(&ui, area) == before + 2, "the composition is underlined, its cursor range more strongly")

	// and in a single-line field
	set_focus(&ui.tree, f.field, false)
	fs0 := &ui.tree.inputs[f.field]
	fs0.caret, fs0.anchor = len(str(value)), len(str(value))
	settle_ime(&ui)
	build(&ui, &value, &secret, &doc, &src)
	testing.expect_value(t, len(ui.tree.areas[area].pre), 0) // the editor's went with the focus
	was := rules(&ui, f.field)
	ime_apply(&ui, Ime_Event{preedit = "ni", cursor_begin = -1, cursor_end = -1})
	build(&ui, &value, &secret, &doc, &src)
	testing.expect_value(t, rules(&ui, f.field), was + 1) // no cursor of its own: one line
	s := &ui.tree.inputs[f.field]
	testing.expect_value(t, s.display, "Adani")
	testing.expect_value(t, str(value), "Ada") // the buffer is untouched
}

@(test)
an_input_method_deletes_around_the_caret_and_commits_as_typing :: proc(t: ^testing.T) {
	ui: Ui(Im_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	value := text_make("abcdef", context.allocator)
	defer text_destroy(&value)
	secret := text_make("", context.allocator)
	defer text_destroy(&secret)
	doc := document_make("abcdef")
	defer document_destroy(&doc)
	src := document_make("x := 1")
	defer document_destroy(&src)
	f := build(&ui, &value, &secret, &doc, &src)
	area, s := area_of(&ui, f.area)

	// an editor: one byte before the caret and two after go, then the commit lands
	set_focus(&ui.tree, area, false)
	editor_select(&ui, f.area, Pos{0, 3}, Pos{0, 3})
	ime_apply(&ui, Ime_Event{delete_before = 1, delete_after = 2, commit = "X"})
	build(&ui, &value, &secret, &doc, &src)
	testing.expect_value(t, document_text(&doc, context.temp_allocator), "abXf")
	testing.expect_value(t, s.caret, Pos{0, 3})

	// a commit is typing: it joins the typing around it, which groups until a pause
	text_area_text(&ui, "y")
	ime_apply(&ui, Ime_Event{commit = "z"})
	build(&ui, &value, &secret, &doc, &src)
	testing.expect_value(t, document_text(&doc, context.temp_allocator), "abXyzf")
	document_undo(&doc)
	testing.expect_value(t, document_text(&doc, context.temp_allocator), "abcdef") // one step: the round and the typing around it
	document_redo(&doc)
	testing.expect_value(t, document_text(&doc, context.temp_allocator), "abXyzf")
	area_break_typing(s) // after a pause, the next commit stands alone
	ime_apply(&ui, Ime_Event{commit = "!"})
	build(&ui, &value, &secret, &doc, &src)
	testing.expect_value(t, document_text(&doc, context.temp_allocator), "abXyz!f") // at the caret, where the undo left it
	document_undo(&doc)
	testing.expect_value(t, document_text(&doc, context.temp_allocator), "abXyzf")

	// a field: the same, in bytes
	set_focus(&ui.tree, f.field, false)
	fs := &ui.tree.inputs[f.field]
	fs.caret, fs.anchor = 3, 3
	ime_apply(&ui, Ime_Event{delete_before = 1, delete_after = 2, commit = "X"})
	build(&ui, &value, &secret, &doc, &src)
	testing.expect_value(t, str(value), "abXf")
	testing.expect_value(t, fs.caret, 3)
}

@(test)
a_composition_goes_when_the_field_loses_focus :: proc(t: ^testing.T) {
	ui: Ui(Im_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	spy: Spy
	defer delete(spy.text)
	spy_install(&ui, &spy)
	value := text_make("Ada", context.allocator)
	defer text_destroy(&value)
	secret := text_make("", context.allocator)
	defer text_destroy(&secret)
	doc := document_make("hello")
	defer document_destroy(&doc)
	src := document_make("x := 1")
	defer document_destroy(&src)
	f := build(&ui, &value, &secret, &doc, &src)
	area, s := area_of(&ui, f.area)
	set_focus(&ui.tree, area, false)
	editor_select(&ui, f.area, Pos{0, 5}, Pos{0, 5})
	ime_apply(&ui, Ime_Event{preedit = "ni", cursor_begin = 2, cursor_end = 2})
	build(&ui, &value, &secret, &doc, &src)
	testing.expect_value(t, area_text(&ui.tree, s, 0), "helloni")

	set_focus(&ui.tree, f.field, false)
	settle_ime(&ui)
	build(&ui, &value, &secret, &doc, &src)
	testing.expect_value(t, area_text(&ui.tree, s, 0), "hello")
	testing.expect_value(t, ui.tree.ime.node, NODE_NONE)
	testing.expect_value(t, document_text(&doc, context.temp_allocator), "hello") // nothing of it was kept
	testing.expect(t, spy.info.on && spy.info.surrounding == "Ada", "the field that took focus is what the method hears about")
}

@(test)
input_methods_are_inert_without_a_platform_hook :: proc(t: ^testing.T) {
	ui: Ui(Im_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	value := text_make("Ada", context.allocator)
	defer text_destroy(&value)
	secret := text_make("", context.allocator)
	defer text_destroy(&secret)
	doc := document_make("hello")
	defer document_destroy(&doc)
	src := document_make("x := 1")
	defer document_destroy(&src)
	build(&ui, &value, &secret, &doc, &src)
	settle_ime(&ui) // no hook: nothing to tell, nothing to crash
	testing.expect(t, !ime_apply(&ui, Ime_Event{preedit = "ni"}), "with nothing focused there is nothing to compose in")
	testing.expect_value(t, ui.tree.ime.node, NODE_NONE)
}

@(test)
the_text_after_a_composition_keeps_its_own_offsets :: proc(t: ^testing.T) {
	ui: Ui(Im_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	value := text_make("Ada", context.allocator)
	defer text_destroy(&value)
	secret := text_make("", context.allocator)
	defer text_destroy(&secret)
	src := document_make("x := 1")
	defer document_destroy(&src)
	doc := document_make("hello world")
	defer document_destroy(&doc)
	f := build(&ui, &value, &secret, &doc, &src)
	area, s := area_of(&ui, f.area)
	set_focus(&ui.tree, area, false)
	editor_select(&ui, f.area, Pos{0, 5}, Pos{0, 5})
	ime_apply(&ui, Ime_Event{preedit = "ni", cursor_begin = 2, cursor_end = 2})
	build(&ui, &value, &secret, &doc, &src)
	testing.expect_value(t, area_text(&ui.tree, s, 0), "helloni world")
	testing.expect_value(t, to_disp(&ui.tree, s, 0, 6), 8)  // the "w" is two bytes further along the drawn line
	testing.expect_value(t, to_src(&ui.tree, s, 0, 8), 6)   // …and back
	testing.expect_value(t, to_src(&ui.tree, s, 0, 6), 5)   // inside the composition: the caret's own offset
	d := node_get(&ui.tree, area)
	w_at := span_x_disp(&ui.tree, s, 0, block_spans(&ui.tree, s, 0)[0], 8)
	click := area_hit(&ui.tree, area, d, s, {input_inner(d).x + area_text_x(s) + w_at + 1, d.abs.y + 8})
	testing.expect_value(t, click, Pos{0, 6}) // a click past the composition lands in the source after it

	// a single-line field maps the same way around its composition
	set_focus(&ui.tree, f.field, false)
	fs := &ui.tree.inputs[f.field]
	fs.caret, fs.anchor = 1, 1
	ime_apply(&ui, Ime_Event{preedit = "ni", cursor_begin = -1, cursor_end = -1})
	build(&ui, &value, &secret, &doc, &src)
	testing.expect_value(t, fs.display, "Anida")
	testing.expect_value(t, input_display_off(fs, str(value), 2), 4)
	testing.expect_value(t, input_src_off(fs, str(value), 4), 2)
	testing.expect_value(t, input_src_off(fs, str(value), 2), 1) // inside it: the caret's own offset
	testing.expect_value(t, str(value), "Ada")
}

} // when ODIN_TEST