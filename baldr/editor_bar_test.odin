package baldr

@(require) import "core:testing"

when ODIN_TEST || #config(BALDR_TESTS, false) {

Eb_Msg :: struct { i: int }

Eb_Fx :: struct {
	ui:  Ui(Eb_Msg),
	doc: Document,
	ask: Maybe(Code_Bar), // applied in the view right after the editor, once
}

@(private = "file")
eb_view :: proc(fx: ^Eb_Fx) -> (fr, area: Node) {
	ui := &fx.ui
	set_viewport(&ui.tree, {600, 400})
	begin_view(ui)
	column(ui, padding = .lg)
	fr = code_editor(ui, &fx.doc, &LANG_ODIN, label = "Source", height = 240)
	if bar, has := fx.ask.?; has {
		editor_bar(ui, fr, bar)
		fx.ask = nil
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	area = ui.tree.area_of_frame[fr]
	return
}

// eb_settle builds until the view stops asking, with a cap.
@(private = "file")
eb_settle :: proc(fx: ^Eb_Fx) -> (fr, area: Node) {
	for _ in 0 ..< 8 {
		fx.ui.needs_rebuild = false
		fr, area = eb_view(fx)
		if !fx.ui.needs_rebuild do break
	}
	return
}

// The app opens and closes the bars itself, and reads which is open
// however it was opened: a toolbar toggle stays in step with the keys.
@(test)
the_app_shows_and_hides_a_code_editors_bars :: proc(t: ^testing.T) {
	fx: Eb_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	fx.doc = document_make("alpha beta\nbeta gamma\nbeta\n")
	defer document_destroy(&fx.doc)
	fr, area := eb_settle(&fx)
	tr := &fx.ui.tree
	s := &tr.areas[area]
	set_focus(tr, area, true)
	area_move(tr, area, s, {1, 0}, false)
	testing.expect_value(t, editor_bar_shown(tr, fr), Code_Bar.None)
	editor_bar(&fx.ui, fr, .Find)
	eb_settle(&fx)
	testing.expect_value(t, editor_bar_shown(tr, fr), Code_Bar.Find)
	testing.expect_value(t, tr.focus, s.code.field)
	text_event(&fx.ui, "beta")
	eb_settle(&fx)
	testing.expect_value(t, len(s.code.matches), 3)
	testing.expect(t, s.anchor == Pos{1, 0} && s.caret == Pos{1, 4}, "the first match from the caret is selected")
	// back in the code, the app asks again: the field takes the keyboard with the query selected
	set_focus(tr, area, true)
	editor_bar(&fx.ui, fr, .Find)
	eb_settle(&fx)
	testing.expect_value(t, tr.focus, s.code.field)
	lo, hi := text_input_selection(tr, s.code.field)
	testing.expect(t, lo == 0 && hi == 4, "the query is selected, so typing replaces it")
	// straight to Replace and back
	editor_bar(&fx.ui, fr, .Replace)
	eb_settle(&fx)
	testing.expect_value(t, editor_bar_shown(tr, fr), Code_Bar.Replace)
	testing.expect(t, s.code.field2 != NODE_NONE, "the replace row shows")
	editor_bar(&fx.ui, fr, .Find)
	eb_settle(&fx)
	testing.expect_value(t, s.code.field2, NODE_NONE)
	// closing puts the keyboard back in the code, as Escape does
	editor_bar(&fx.ui, fr, .None)
	eb_settle(&fx)
	testing.expect_value(t, editor_bar_shown(tr, fr), Code_Bar.None)
	testing.expect_value(t, tr.focus, area)
	// the editor's own keys move the same state
	key_event(&fx.ui, .G, true, {.Ctrl})
	eb_settle(&fx)
	testing.expect_value(t, editor_bar_shown(tr, fr), Code_Bar.Goto)
	key_event(&fx.ui, .Escape, true, {})
	eb_settle(&fx)
	testing.expect_value(t, editor_bar_shown(tr, fr), Code_Bar.None)
	// reopened by key, the old query is selected too
	key_event(&fx.ui, .F, true, {.Ctrl})
	eb_settle(&fx)
	lo, hi = text_input_selection(tr, s.code.field)
	testing.expect(t, str(s.code.query) == "beta" && lo == 0 && hi == 4, "Ctrl+F selects the old query")
}

// Asked for in the view, after the editor was built, the bar shows on the
// build that follows, which the call asks for itself.
@(test)
a_bar_asked_for_in_the_view_shows_next_build :: proc(t: ^testing.T) {
	fx: Eb_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	fx.doc = document_make("one\ntwo\n")
	defer document_destroy(&fx.doc)
	fr, area := eb_settle(&fx)
	tr := &fx.ui.tree
	set_focus(tr, area, true)
	fx.ask = .Goto
	fx.ui.needs_rebuild = false
	eb_view(&fx)
	testing.expect(t, fx.ui.needs_rebuild, "the call asks for the build that shows it")
	eb_settle(&fx)
	testing.expect_value(t, editor_bar_shown(tr, fr), Code_Bar.Goto)
	testing.expect_value(t, tr.focus, tr.areas[area].code.field)
	fx.ask = .None
	eb_settle(&fx)
	testing.expect_value(t, editor_bar_shown(tr, fr), Code_Bar.None)
	testing.expect_value(t, tr.focus, area)
}

// With the find bar open, typing in the code stays in the code: the
// keyboard is not taken back to the field, nor the caret moved to a match.
// F3 from the code steps without leaving it.
@(test)
typing_in_the_code_with_find_open_stays_in_the_code :: proc(t: ^testing.T) {
	fx: Eb_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	fx.doc = document_make("foo\nbar\nfoo\n")
	defer document_destroy(&fx.doc)
	fr, area := eb_settle(&fx)
	tr := &fx.ui.tree
	s := &tr.areas[area]
	set_focus(tr, area, true)
	editor_bar(&fx.ui, fr, .Find)
	eb_settle(&fx)
	text_event(&fx.ui, "foo")
	eb_settle(&fx)
	testing.expect_value(t, len(s.code.matches), 2)
	set_focus(tr, area, true)
	area_move(tr, area, s, {1, 1}, false)
	text_area_text(&fx.ui, "x")
	eb_settle(&fx)
	testing.expect_value(t, block_str(&fx.doc, 1), "bxar")
	testing.expect_value(t, tr.focus, area)
	testing.expect(t, s.caret == Pos{1, 2} && s.anchor == s.caret, "the caret stays after what was typed")
	testing.expect_value(t, len(s.code.matches), 2) // the highlights follow the edit
	key_event(&fx.ui, .F3, true, {})
	eb_settle(&fx)
	testing.expect_value(t, tr.focus, area)
	testing.expect(t, s.anchor.block == 2 || s.anchor.block == 0, "F3 selected a match")
}

// On anything but a code editor the calls do nothing.
@(test)
editor_bar_on_another_node_does_nothing :: proc(t: ^testing.T) {
	ui: Ui(Eb_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make("text")
	defer document_destroy(&doc)
	begin_view(&ui)
	ed := text_area(&ui, &doc, label = "Notes")
	b := button(&ui, "Go", Eb_Msg{})
	end_view(&ui)
	frame(&ui.tree, {400, 300})
	editor_bar(&ui, ed, .Find)
	editor_bar(&ui, b, .Find)
	testing.expect(t, !ui.needs_rebuild, "nothing asked")
	testing.expect_value(t, editor_bar_shown(&ui.tree, ed), Code_Bar.None)
	testing.expect_value(t, editor_bar_shown(&ui.tree, b), Code_Bar.None)
}

}
