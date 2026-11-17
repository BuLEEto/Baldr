package baldr

@(require) import "core:strings"
@(require) import "core:testing"
@(require) import "core:unicode/utf8"

when ODIN_TEST || #config(BALDR_TESTS, false) {

// The code editor's completion list on a plain text area, opened by a
// trigger character: a message box offering a project's files when `@` is
// typed. While it is open Enter accepts and must not reach the app's
// Enter-to-send, and Escape closes the list and nothing else.

@(private = "file")
Tac_Msg :: union { Tac_Sent }
@(private = "file")
Tac_Sent :: struct {}

@(private = "file")
Tac_Fx :: struct {
	ui:   Ui(Tac_Msg),
	doc:  Document,
	area: Node,
}

// tac_files is the app's completer: three files, filtered by the query.
@(private = "file")
tac_files :: proc(doc: ^Document, at: Pos, prefix: string, lang: ^Language, out: ^[dynamic]Completion) {
	Row :: struct { label, insert, detail: string }
	rows := []Row{
		{"Stock check.xlsx", "@\"Stock check.xlsx\" ", "reports/ · 2 days ago"},
		{"stock-notes.md", "@stock-notes.md ", "notes/ · today"},
		{"Readme.md", "@Readme.md ", "· last week"},
	}
	for r in rows {
		if prefix != "" && !strings.contains(strings.to_lower(r.label, context.temp_allocator), strings.to_lower(prefix, context.temp_allocator)) do continue
		append(out, Completion{label = r.label, insert = r.insert, detail = r.detail})
	}
}

@(private = "file")
tac_view :: proc(fx: ^Tac_Fx, trigger: rune = '@') {
	ui := &fx.ui
	begin_view(ui)
	column(ui, flex = 1)
	fx.area = text_area(ui, &fx.doc, label = "Message", flex = 1, on_submit = Tac_Msg(Tac_Sent{}))
	editor_options(ui, fx.area, submit = .Enter) // a composer: plain Enter sends
	editor_complete(ui, fx.area, tac_files, trigger = trigger)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
}

@(private = "file")
tac_open :: proc(fx: ^Tac_Fx) -> ^Text_Area_State {
	ui_init(&fx.ui)
	fx.doc = document_make("")
	tac_view(fx)
	set_focus(&fx.ui.tree, fx.area, true)
	return &fx.ui.tree.areas[fx.area]
}

// tac_type commits `str` a character at a time, as a keyboard does.
@(private = "file")
tac_type :: proc(fx: ^Tac_Fx, str: string) {
	for ch in str {
		bytes, n := utf8.encode_rune(ch)
		text_area_text(&fx.ui, strings.clone(string(bytes[:n]), context.temp_allocator))
	}
}

@(test)
a_trigger_opens_a_completion_list_in_a_text_area :: proc(t: ^testing.T) {
	fx: Tac_Fx
	s := tac_open(&fx)
	defer ui_destroy(&fx.ui)
	defer document_destroy(&fx.doc)

	tac_type(&fx, "see ")
	testing.expect(t, !s.complete.open, "prose does not open it")
	tac_type(&fx, "@")
	testing.expect(t, s.complete.open, "the trigger at a word start opens it")
	testing.expect_value(t, len(s.complete.items), 3)
	tac_type(&fx, "stock")
	testing.expect_value(t, len(s.complete.items), 2) // the query filters, each keystroke asking again
	testing.expect_value(t, s.complete.items[0].label, "Stock check.xlsx")

	// it is a list for a screen reader, named, with the candidates in it
	fx.ui.needs_rebuild = false
	tac_view(&fx)
	dump := access_dump(&fx.ui.tree)
	testing.expect(t, strings.contains(dump, "List \"Completions\""), dump)
	testing.expect(t, strings.contains(dump, "List_Item \"Stock check.xlsx\""), dump)
}

@(test)
a_trigger_inside_a_word_is_just_a_character :: proc(t: ^testing.T) {
	fx: Tac_Fx
	s := tac_open(&fx)
	defer ui_destroy(&fx.ui)
	defer document_destroy(&fx.doc)
	tac_type(&fx, "ada@")
	testing.expect(t, !s.complete.open, "an email address is not a mention")
	tac_type(&fx, "example")
	testing.expect(t, !s.complete.open, "…nor is what follows it a query")
	testing.expect_value(t, block_str(&fx.doc, 0), "ada@example")
}

@(test)
enter_accepts_a_candidate_instead_of_sending :: proc(t: ^testing.T) {
	fx: Tac_Fx
	s := tac_open(&fx)
	defer ui_destroy(&fx.ui)
	defer document_destroy(&fx.doc)

	tac_type(&fx, "see @stock")
	clear(&fx.ui.msgs)
	testing.expect(t, key_event(&fx.ui, .Enter, true, {}), "the list takes Enter")
	testing.expect_value(t, len(fx.ui.msgs), 0) // …and the message is not sent
	testing.expect(t, !s.complete.open)
	testing.expect_value(t, block_str(&fx.doc, 0), "see @\"Stock check.xlsx\" ") // the trigger and the query both replaced

	// Enter again, with no list open, is the app's own send
	testing.expect(t, key_event(&fx.ui, .Enter, true, {}), "the editor takes it now")
	testing.expect_value(t, len(fx.ui.msgs), 1)
	_, sent := fx.ui.msgs[0].(Tac_Sent)
	testing.expect(t, sent, "on_submit")
}

@(test)
tab_accepts_and_escape_closes_only_the_list :: proc(t: ^testing.T) {
	fx: Tac_Fx
	s := tac_open(&fx)
	defer ui_destroy(&fx.ui)
	defer document_destroy(&fx.doc)

	tac_type(&fx, "@read")
	clear(&fx.ui.msgs)
	testing.expect(t, key_event(&fx.ui, .Escape, true, {}), "the list takes the first Escape")
	testing.expect(t, !s.complete.open)
	testing.expect_value(t, len(fx.ui.msgs), 0) // the app's own Escape is not spent
	testing.expect_value(t, block_str(&fx.doc, 0), "@read") // and nothing is undone

	// …and the second goes on to the window: a text area with no selection
	// declines Escape, so the app's own Escape is one key later.
	testing.expect(t, !key_event(&fx.ui, .Escape, true, {}), "the second is the window's")

	// Typing on does not bring it back: a list dismissed stays dismissed
	// until the trigger is typed again, as in every editor.
	tac_type(&fx, "me")
	testing.expect(t, !s.complete.open, "dismissed stays dismissed")
	tac_type(&fx, " @read")
	testing.expect(t, s.complete.open, "the trigger again opens it")
	testing.expect(t, key_event(&fx.ui, .Tab, true, {}), "Tab accepts")
	testing.expect_value(t, block_str(&fx.doc, 0), "@readme @Readme.md ")
}

@(test)
the_arrows_move_in_the_list_not_the_text :: proc(t: ^testing.T) {
	fx: Tac_Fx
	s := tac_open(&fx)
	defer ui_destroy(&fx.ui)
	defer document_destroy(&fx.doc)

	tac_type(&fx, "@stock")
	caret := s.caret
	testing.expect(t, key_event(&fx.ui, .Down, true, {}), "Down picks the next candidate")
	testing.expect_value(t, s.complete.sel, 1)
	testing.expect_value(t, s.caret, caret) // the caret stayed where it was
	key_event(&fx.ui, .Up, true, {})
	testing.expect_value(t, s.complete.sel, 0)
	key_event(&fx.ui, .Up, true, {})
	testing.expect_value(t, s.complete.sel, 1) // …and it wraps, as a menu does
	key_event(&fx.ui, .Enter, true, {})
	testing.expect_value(t, block_str(&fx.doc, 0), "@stock-notes.md ")
}

@(test)
a_space_the_caret_leaving_and_the_keyboard_leaving_close_it :: proc(t: ^testing.T) {
	fx: Tac_Fx
	s := tac_open(&fx)
	defer ui_destroy(&fx.ui)
	defer document_destroy(&fx.doc)

	tac_type(&fx, "@stock")
	tac_type(&fx, " ")
	testing.expect(t, !s.complete.open, "a space with nothing picked closes it")
	testing.expect_value(t, block_str(&fx.doc, 0), "@stock ")

	tac_type(&fx, "@read")
	testing.expect(t, s.complete.open)
	key_event(&fx.ui, .Left, true, {})
	testing.expect(t, !s.complete.open, "the caret leaving the word closes it")

	tac_type(&fx, " @me") // a word start again: mid-word it is just a character
	testing.expect(t, s.complete.open)
	set_focus(&fx.ui.tree, NODE_NONE, false)
	complete_tick(&fx.ui)
	testing.expect(t, !s.complete.open, "the keyboard leaving closes it")
}

// A composer at the foot of a window: the list has no room below and flips
// above the caret, and must clear the caret's own line, or it covers the
// trigger and the query being typed.
@(test)
a_list_that_flips_above_does_not_cover_the_line :: proc(t: ^testing.T) {
	fx: Tac_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	fx.doc = document_make("")
	defer document_destroy(&fx.doc)

	// the composer at the bottom of a short window, as a chat app has it
	bottom_view :: proc(fx: ^Tac_Fx) {
		ui := &fx.ui
		begin_view(ui)
		column(ui, flex = 1)
		box(ui, flex = 1) // the conversation above it
		end(ui)
		fx.area = text_area(ui, &fx.doc, label = "Message", height = 56, key = 1)
		editor_options(ui, fx.area, submit = .Enter)
		editor_complete(ui, fx.area, tac_files, trigger = '@')
		end(ui)
		end_view(ui)
		frame(&ui.tree, {600, 220})
	}
	bottom_view(&fx)
	set_focus(&fx.ui.tree, fx.area, true)
	tac_type(&fx, "@")
	bottom_view(&fx)

	tr := &fx.ui.tree
	s := &tr.areas[fx.area]
	testing.expect(t, s.complete.open, "the list is open")
	pop := node_first(tr, tr.overlay)
	pd, ad := node_get(tr, pop), node_get(tr, fx.area)
	testing.expect(t, pd != nil && ad != nil && pd.access.role == .List, "its card is in the overlay")
	if pd == nil || ad == nil do return
	caret := area_caret_rect(tr, fx.area, ad, s)
	testing.expect(t, pd.abs.y + pd.abs.h < ad.abs.y + ad.abs.h, "there was no room below: it flipped above")
	testing.expectf(t, pd.abs.y + pd.abs.h <= caret.y + 0.5,
		"its bottom (%.1f) is above the caret's line (%.1f)", pd.abs.y + pd.abs.h, caret.y)
	testing.expect(t, !rect_intersects(pd.abs, caret), "and nothing of it is over the words being typed")
	testing.expect(t, pd.abs.y >= 0, "…while staying inside the window")
}

@(test)
a_click_accepts_a_candidate :: proc(t: ^testing.T) {
	fx: Tac_Fx
	s := tac_open(&fx)
	defer ui_destroy(&fx.ui)
	defer document_destroy(&fx.doc)

	tac_type(&fx, "@stock")
	tac_view(&fx) // the list is built: its rows are nodes
	tr := &fx.ui.tree
	row := NODE_NONE
	for pop := node_first(tr, tr.overlay); pop != NODE_NONE; pop = node_next(tr, pop) {
		for it := node_first(tr, pop); it != NODE_NONE; it = node_next(tr, it) {
			if d := node_get(tr, it); d != nil && d.access.role == .List_Item && d.access.name == "stock-notes.md" do row = it
		}
	}
	testing.expect(t, row != NODE_NONE, "the candidate is in the tree")
	if row == NODE_NONE do return
	rd := node_get(tr, row)
	pointer_move(&fx.ui, {rd.abs.x + 4, rd.abs.y + 4})
	pointer_button(&fx.ui, .Left, true, {rd.abs.x + 4, rd.abs.y + 4})
	pointer_button(&fx.ui, .Left, false, {rd.abs.x + 4, rd.abs.y + 4})
	testing.expect(t, !s.complete.open, "the click accepted it")
	testing.expect_value(t, block_str(&fx.doc, 0), "@stock-notes.md ")
}

}
