package baldr

@(require) import "core:testing"

// Undo in a single-line field, and a paste that prefers the picture over
// the URL a browser put beside it.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Iu_Msg :: union { string }

@(private = "file")
iu_build :: proc(ui: ^Ui(Iu_Msg), v: ^Text, password := false) -> (n: Node, d: ^Node_Data, s: ^Text_Input_State) {
	set_viewport(&ui.tree, {400, 120})
	begin_view(ui)
	column(ui, padding = .sm)
	n = text_input(ui, v, label = "Server", password = password, key = 1)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 120})
	return n, node_get(&ui.tree, n), &ui.tree.inputs[n]
}

// A run of typed characters is one step, so Ctrl+Z takes back a word
// rather than a letter, and a second one keeps going back.
@(test)
typing_undoes_in_word_sized_steps :: proc(t: ^testing.T) {
	v: Text
	text_set(&v, "")
	defer text_destroy(&v)
	ui: Ui(Iu_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n, d, s := iu_build(&ui, &v)

	type_run :: proc(ui: ^Ui(Iu_Msg), n: Node, d: ^Node_Data, s: ^Text_Input_State, word: string) {
		for i in 0 ..< len(word) {
			input_replace(ui, n, d, s, len(str(s.value^)), len(str(s.value^)), word[i:i + 1])
		}
	}
	type_run(&ui, n, d, s, "wss")
	ui.tree.now_ms += INPUT_UNDO_PAUSE_MS * 2 // a pause ends the step
	type_run(&ui, n, d, s, "://server")
	testing.expect_value(t, str(v), "wss://server")

	testing.expect(t, input_undo_apply(&ui, n, d, s, &s.undo, &s.redo), "Ctrl+Z")
	testing.expect_value(t, str(v), "wss") // the whole second run, not one letter
	testing.expect(t, input_undo_apply(&ui, n, d, s, &s.undo, &s.redo))
	testing.expect_value(t, str(v), "")

	// nothing left to undo
	testing.expect(t, !input_undo_apply(&ui, n, d, s, &s.undo, &s.redo))

	// …and redo comes forward again
	testing.expect(t, input_undo_apply(&ui, n, d, s, &s.redo, &s.undo))
	testing.expect_value(t, str(v), "wss")
	testing.expect(t, input_undo_apply(&ui, n, d, s, &s.redo, &s.undo))
	testing.expect_value(t, str(v), "wss://server")
}

// A new edit throws the redo away: you cannot come forward into a future
// that no longer happened.
@(test)
an_edit_after_an_undo_clears_the_redo :: proc(t: ^testing.T) {
	v: Text
	text_set(&v, "")
	defer text_destroy(&v)
	ui: Ui(Iu_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n, d, s := iu_build(&ui, &v)

	input_replace(&ui, n, d, s, 0, 0, "one")
	ui.tree.now_ms += INPUT_UNDO_PAUSE_MS * 2
	input_replace(&ui, n, d, s, 3, 3, "two")
	input_undo_apply(&ui, n, d, s, &s.undo, &s.redo)
	testing.expect(t, len(s.redo) > 0)

	ui.tree.now_ms += INPUT_UNDO_PAUSE_MS * 2
	input_replace(&ui, n, d, s, len(str(v)), len(str(v)), "three")
	testing.expect_value(t, len(s.redo), 0)
}

// A password field keeps no journal: a history of a secret is a copy of
// it, sitting in the tree for as long as the field lives.
@(test)
a_password_field_keeps_no_undo_history :: proc(t: ^testing.T) {
	v: Text
	text_set(&v, "")
	defer text_destroy(&v)
	ui: Ui(Iu_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n, d, s := iu_build(&ui, &v, password = true)

	for ch in ([]string{"h", "u", "n", "t", "e", "r"}) {
		input_replace(&ui, n, d, s, len(str(v)), len(str(v)), ch)
	}
	testing.expect_value(t, str(v), "hunter")
	testing.expect_value(t, len(s.undo), 0)
	testing.expect(t, !input_undo_apply(&ui, n, d, s, &s.undo, &s.redo), "and Ctrl+Z does nothing")
	testing.expect_value(t, str(v), "hunter")
}

// The journal is bounded, so a long edit session cannot grow without end.
@(test)
the_undo_journal_is_bounded :: proc(t: ^testing.T) {
	v: Text
	text_set(&v, "")
	defer text_destroy(&v)
	ui: Ui(Iu_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n, d, s := iu_build(&ui, &v)

	for _ in 0 ..< INPUT_UNDO_MAX * 2 {
		ui.tree.now_ms += INPUT_UNDO_PAUSE_MS * 2 // each its own step
		input_replace(&ui, n, d, s, len(str(v)), len(str(v)), "x")
	}
	testing.expect_value(t, len(s.undo), INPUT_UNDO_MAX)
}

// A field told to prefer a picture takes one even when the clipboard also
// offers text, and inserts nothing.
@(test)
a_field_can_prefer_the_picture_over_the_text :: proc(t: ^testing.T) {
	v: Text
	text_set(&v, "")
	defer text_destroy(&v)
	ui: Ui(Iu_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	set_viewport(&ui.tree, {400, 120})
	begin_view(&ui)
	column(&ui, padding = .sm)
	n := text_input(&ui, &v, label = "Compose", paste_prefer = .Picture, key = 1)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 120})

	s := &ui.tree.inputs[n]
	testing.expect_value(t, s.paste_prefer, Paste_Prefer.Picture)

	// and a plain field is unchanged
	set_viewport(&ui.tree, {400, 120})
	begin_view(&ui)
	column(&ui, padding = .sm)
	n2 := text_input(&ui, &v, label = "Plain", key = 2)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 120})
	testing.expect_value(t, ui.tree.inputs[n2].paste_prefer, Paste_Prefer.Text)
}

}
