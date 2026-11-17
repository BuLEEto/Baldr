package baldr

@(require) import "core:testing"
@(require) import "baldr:platform"

// copy_html: a copy that carries formatted text — text/html beside the
// plain text — so what is written in Markdown pastes into a word processor
// or an email as headings, bold and links.
//
// Test files are part of the package, so everything that imports Baldr
// type-checks them too: the bodies stay behind this `when`.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Hc_Msg :: union { string }

// Hc_Board is the stand-in clipboard: what a copy put on it.
@(private = "file")
Hc_Board :: struct {
	items: [dynamic]platform.Clip_Item, // through clipboard_set_data
	sets:  int,                         // …and how many times it was asked
	text:  string,                      // …or through the text-only pair
	texts: int,
}

@(private = "file")
hc_backend :: proc(board: ^Hc_Board, typed := true) -> platform.Backend {
	b := platform.Backend{data = board}
	b.clipboard_set = proc(b: ^platform.Backend, text: string) -> bool {
		board := (^Hc_Board)(b.data)
		board.text, board.texts = text, board.texts + 1
		return true
	}
	if typed {
		b.clipboard_set_data = proc(b: ^platform.Backend, items: []platform.Clip_Item) -> bool {
			board := (^Hc_Board)(b.data)
			board.sets += 1
			for it in items do append(&board.items, it)
			return true
		}
	}
	return b
}

@(private = "file")
hc_destroy :: proc(board: ^Hc_Board, rt: ^Runtime(int, Hc_Msg)) {
	delete(board.items)
	delete(rt.jobs)
	delete(rt.msgs)
	delete(rt.mailbox.mail)
}

// hc_form finds what a form was offered as, "" when it was not offered.
@(private = "file")
hc_form :: proc(board: ^Hc_Board, mime: string) -> string {
	for it in board.items do if it.mime == mime do return string(it.data)
	return ""
}

// The HTML comes first — a source's forms are offered in the order given,
// and a program that takes the richest form it understands reads them that
// way — and the text follows in every form `copy_text` offers, so a paste
// into a terminal or a plain field is the same copy either way.
@(test)
copy_html_offers_the_html_then_every_plain_form :: proc(t: ^testing.T) {
	items := clip_html_items("<b>hi</b>", "**hi**")
	testing.expect_value(t, len(items), 6)
	if len(items) != 6 do return
	testing.expect_value(t, items[0].mime, MIME_HTML)
	testing.expect_value(t, string(items[0].data), "<b>hi</b>")
	want := []string{MIME_TEXT_UTF8, "UTF8_STRING", MIME_TEXT, "TEXT", "STRING"}
	for m, i in want {
		testing.expect_value(t, items[i + 1].mime, m)
		testing.expect_value(t, string(items[i + 1].data), "**hi**")
	}
}

// An empty side is left out rather than offered as a form that yields
// nothing: a paster that asks for a form and is given zero bytes has
// pasted nothing, where one that never saw the form falls through to the
// next.
@(test)
copy_html_leaves_out_a_form_it_has_nothing_for :: proc(t: ^testing.T) {
	only_html := clip_html_items("<p>a</p>", "")
	testing.expect_value(t, len(only_html), 1)
	testing.expect_value(t, only_html[0].mime, MIME_HTML)

	only_text := clip_html_items("", "a")
	testing.expect_value(t, len(only_text), 5)
	testing.expect_value(t, only_text[0].mime, MIME_TEXT_UTF8)

	testing.expect_value(t, len(clip_html_items("", "")), 0)
}

// The command itself: both forms reach the clipboard, and both strings are
// copied at the moment of the copy, so the app may change or free its own
// buffers straight after.
@(test)
copy_html_puts_both_forms_on_the_clipboard :: proc(t: ^testing.T) {
	board: Hc_Board
	rt: Runtime(int, Hc_Msg)
	b := hc_backend(&board)
	rt.backend = &b
	defer hc_destroy(&board, &rt)

	html := make([]u8, 9, context.temp_allocator)
	text := make([]u8, 6, context.temp_allocator)
	copy(html, "<b>hi</b>")
	copy(text, "**hi**")
	cmd := copy_html(Hc_Msg, string(html), string(text))
	html[0], text[0] = 'X', 'Y' // the app goes on with its own buffers
	run_cmd(&rt, cmd)

	testing.expect_value(t, len(board.items), 6)
	testing.expect_value(t, hc_form(&board, MIME_HTML), "<b>hi</b>")
	testing.expect_value(t, hc_form(&board, MIME_TEXT_UTF8), "**hi**")
	testing.expect_value(t, hc_form(&board, "STRING"), "**hi**")
	testing.expect_value(t, board.sets, 1)
	testing.expect_value(t, board.texts, 0) // the typed path, not the text pair
}

// A platform whose clipboard Baldr can only put text on gets the text, not
// nothing: the copy always does something.
@(test)
copy_html_on_a_text_only_clipboard_offers_the_text :: proc(t: ^testing.T) {
	board: Hc_Board
	rt: Runtime(int, Hc_Msg)
	b := hc_backend(&board, typed = false)
	rt.backend = &b
	defer hc_destroy(&board, &rt)

	run_cmd(&rt, copy_html(Hc_Msg, "<b>hi</b>", "**hi**"))
	testing.expect_value(t, board.texts, 1)
	testing.expect_value(t, board.text, "**hi**")

	// …and a copy with no text at all does not clear what is there with an
	// empty string.
	run_cmd(&rt, copy_html(Hc_Msg, "<b>hi</b>", ""))
	testing.expect_value(t, board.texts, 1)
}

// Nothing to copy puts nothing on the clipboard — it does not replace what
// is there with an empty selection.
@(test)
copy_html_with_nothing_in_it_offers_nothing :: proc(t: ^testing.T) {
	board: Hc_Board
	rt: Runtime(int, Hc_Msg)
	b := hc_backend(&board)
	rt.backend = &b
	defer hc_destroy(&board, &rt)

	run_cmd(&rt, copy_html(Hc_Msg, "", ""))
	// The backend is not asked at all — asked with nothing, it would empty
	// the clipboard rather than leave it alone.
	testing.expect_value(t, board.sets, 0)
	testing.expect_value(t, len(board.items), 0)
	testing.expect_value(t, board.texts, 0)
}


// ---------------------------------------------------------------------
// Ctrl+Shift+C has to reach the app that bound it: a text widget that
// ignores Shift would copy plain text and eat the key, so a bound "Copy as
// Formatted Text" could never fire.

@(private = "file")
Hc_Clip :: struct { text: string, sets: int }

@(private = "file")
hc_clip :: proc(rec: ^Hc_Clip) -> Clipboard {
	return Clipboard{user = rec, set = proc(user: rawptr, text: string) -> bool {
		c := (^Hc_Clip)(user)
		c.text, c.sets = text, c.sets + 1
		return true
	}}
}

// hc_area_view builds an editor. With `bind`, the app takes the three
// Ctrl+Shift chords: one it should get (C) and two it should not (Z is the
// editor's Redo, Left selects a word).
@(private = "file")
hc_area_view :: proc(ui: ^Ui(Hc_Msg), doc: ^Document, bind: bool) -> Node {
	set_viewport(&ui.tree, {400, 300})
	begin_view(ui)
	column(ui, padding = .md)
	n := text_area(ui, doc, label = "Notes", width = 300, height = 120, key = 1)
	if bind {
		shortcut(ui, "Ctrl+Shift+C", Hc_Msg("copy as formatted text"))
		shortcut(ui, "Ctrl+Shift+Z", Hc_Msg("the app's Ctrl+Shift+Z"))
		shortcut(ui, "Ctrl+Shift+Left", Hc_Msg("the app's Ctrl+Shift+Left"))
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 300})
	set_focus(&ui.tree, n, true)
	frame(&ui.tree, {400, 300})
	return n
}

@(test)
an_editor_hands_a_bound_ctrl_shift_c_to_its_app :: proc(t: ^testing.T) {
	// Unbound, Shift is ignored and the editor copies.
	{
		ui: Ui(Hc_Msg)
		ui_init(&ui)
		defer ui_destroy(&ui)
		doc := document_make("hello")
		defer document_destroy(&doc)
		rec: Hc_Clip
		ui.tree.clipboard = hc_clip(&rec)
		hc_area_view(&ui, &doc, false)
		key_event(&ui, .A, true, {.Ctrl})
		testing.expect(t, key_event(&ui, .C, true, {.Ctrl, .Shift}), "unbound: still the editor's")
		testing.expect_value(t, rec.sets, 1)
		testing.expect_value(t, rec.text, "hello")
	}
	// Bound, the app gets it — and the editor has not quietly copied the
	// plain text on the way past.
	{
		ui: Ui(Hc_Msg)
		ui_init(&ui)
		defer ui_destroy(&ui)
		doc := document_make("hello")
		defer document_destroy(&doc)
		rec: Hc_Clip
		ui.tree.clipboard = hc_clip(&rec)
		hc_area_view(&ui, &doc, true)
		key_event(&ui, .A, true, {.Ctrl})
		testing.expect(t, !key_event(&ui, .C, true, {.Ctrl, .Shift}), "bound: the editor leaves it")
		testing.expect_value(t, rec.sets, 0)
		clear(&ui.msgs)
		testing.expect(t, shortcut_fire(&ui, .C, true, {.Ctrl, .Shift}), "and the app hears it")
		testing.expect_value(t, len(ui.msgs), 1)
		// Plain Ctrl+C is untouched by any of this.
		testing.expect(t, key_event(&ui, .C, true, {.Ctrl}), "plain Ctrl+C is the editor's")
		testing.expect_value(t, rec.sets, 1)
		testing.expect_value(t, rec.text, "hello")
	}
}

// The other side of the rule: a Ctrl+Shift chord that means something to
// the widget *with Shift held* stays the widget's however the app binds it,
// or binding a command palette would break selecting a word.
@(test)
a_ctrl_shift_chord_the_editor_needs_stays_the_editors :: proc(t: ^testing.T) {
	ui: Ui(Hc_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make("one two three")
	defer document_destroy(&doc)
	rec: Hc_Clip
	ui.tree.clipboard = hc_clip(&rec)
	n := hc_area_view(&ui, &doc, true) // the app has bound Left and Z as well
	s := &ui.tree.areas[n]

	// Ctrl+Shift+Left selects by word.
	key_event(&ui, .End, true, {.Ctrl})
	clear(&ui.msgs)
	testing.expect(t, key_event(&ui, .Left, true, {.Ctrl, .Shift}), "Ctrl+Shift+Left is the editor's")
	lo, hi := pos_order(s.caret, s.anchor)
	testing.expect(t, lo != hi, "it selected a word")
	testing.expect_value(t, len(ui.msgs), 0)

	// Ctrl+Shift+Z is Redo.
	key_event(&ui, .A, true, {.Ctrl})
	key_event(&ui, .Backspace, true, {})
	testing.expect_value(t, document_text(&doc, context.temp_allocator), "")
	key_event(&ui, .Z, true, {.Ctrl})
	testing.expect_value(t, document_text(&doc, context.temp_allocator), "one two three")
	testing.expect(t, key_event(&ui, .Z, true, {.Ctrl, .Shift}), "Ctrl+Shift+Z is the editor's")
	testing.expect_value(t, document_text(&doc, context.temp_allocator), "")
	testing.expect_value(t, len(ui.msgs), 0)
}

// A field does the same, because a chord does the same thing in every
// widget that takes it.
@(test)
a_field_hands_a_bound_ctrl_shift_c_to_its_app :: proc(t: ^testing.T) {
	ui: Ui(Hc_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	rec: Hc_Clip
	ui.tree.clipboard = hc_clip(&rec)
	set_viewport(&ui.tree, {400, 200})
	begin_view(&ui)
	column(&ui, padding = .md)
	f := text_input(&ui, nil, initial = "abc", label = "Name", key = 1)
	shortcut(&ui, "Ctrl+Shift+C", Hc_Msg("copy as formatted text"))
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 200})
	set_focus(&ui.tree, f, true)
	frame(&ui.tree, {400, 200})

	key_event(&ui, .A, true, {.Ctrl})
	testing.expect(t, !key_event(&ui, .C, true, {.Ctrl, .Shift}), "a field leaves a bound Ctrl+Shift+C too")
	testing.expect_value(t, rec.sets, 0)
	testing.expect(t, key_event(&ui, .C, true, {.Ctrl}), "plain Ctrl+C still copies")
	testing.expect_value(t, rec.text, "abc")
}

}
