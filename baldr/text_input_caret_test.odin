package baldr

@(require) import "core:testing"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// An app moves a field's caret and puts text in at it: a calculator's keypad
// beside a one-line sum, where a key goes in at the caret, as typing would,
// and the caret ends up after it.

@(private = "file")
Caret_Msg :: union { string }

@(private = "file")
caretfx_build :: proc(ui: ^Ui(Caret_Msg), v: ^Text, disabled := false) -> Node {
	set_viewport(&ui.tree, {400, 120})
	begin_view(ui)
	column(ui, padding = .sm)
	n := text_input(ui, v, label = "Sum", width = 240, disabled = disabled,
		on_change = proc(e: Ev(string)) -> Caret_Msg { return e.value }, key = 1)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 120})
	return n
}

@(private = "file")
caretfx_sel :: proc(ui: ^Ui(Caret_Msg), n: Node) -> [2]int {
	lo, hi := text_input_selection(&ui.tree, n)
	return {lo, hi}
}

// The caret and the anchor go where the app puts them, and come back
// sorted — so what `text_input_selection` reported can be handed straight
// back to restore it.
@(test)
an_app_puts_a_fields_caret_where_it_likes :: proc(t: ^testing.T) {
	v: Text
	text_set(&v, "12+34")
	defer text_destroy(&v)
	ui: Ui(Caret_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := caretfx_build(&ui, &v)
	s := text_input_state(&ui.tree, n)

	text_input_set_selection(&ui.tree, n, 2, 2)
	testing.expect_value(t, s.caret, 2)
	testing.expect_value(t, s.anchor, 2)
	testing.expect_value(t, caretfx_sel(&ui, n), [2]int{2, 2})

	text_input_set_selection(&ui.tree, n, 1, 4) // a selection, caret at its end
	testing.expect_value(t, s.caret, 4)
	testing.expect_value(t, caretfx_sel(&ui, n), [2]int{1, 4})

	text_input_set_selection(&ui.tree, n, 4, 1) // …and backwards: the caret leads
	testing.expect_value(t, s.caret, 1)
	testing.expect_value(t, s.anchor, 4)
	testing.expect(t, caretfx_sel(&ui, n) == [2]int{1, 4}, "reported sorted either way")

	text_input_set_selection(&ui.tree, n, -5, 999) // clamped into the value
	testing.expect_value(t, caretfx_sel(&ui, n), [2]int{0, 5})
}

// An offset inside a character is snapped to its boundary, as every other
// caret move is: an app counting bytes cannot split a cluster.
@(test)
a_caret_an_app_set_lands_on_a_character_boundary :: proc(t: ^testing.T) {
	v: Text
	text_set(&v, "éx") // e + combining acute, then x: one grapheme of 3 bytes, then one
	defer text_destroy(&v)
	ui: Ui(Caret_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := caretfx_build(&ui, &v)

	text_input_set_selection(&ui.tree, n, 1, 1) // between the e and its accent
	lo, hi := text_input_selection(&ui.tree, n)
	testing.expect_value(t, lo, 0)
	testing.expect_value(t, hi, 0)

	text_input_set_selection(&ui.tree, n, 3, 3) // after the accented e: a real boundary
	lo2, _ := text_input_selection(&ui.tree, n)
	testing.expect_value(t, lo2, 3)
}

// "2" typed, "+" from the keypad, "3" typed gives "2+3": the keypad's key
// moves the caret as typing does, so the next typed key follows it.
@(test)
a_keypad_key_goes_in_at_the_caret_and_typing_follows_it :: proc(t: ^testing.T) {
	v: Text
	text_set(&v, "")
	defer text_destroy(&v)
	ui: Ui(Caret_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := caretfx_build(&ui, &v)
	set_focus(&ui.tree, n, true)
	frame(&ui.tree, {400, 120})

	testing.expect(t, text_event(&ui, "2"))
	testing.expect(t, text_input_insert(&ui, n, "+"), "the keypad's key")
	testing.expect(t, text_event(&ui, "3"))
	testing.expect_value(t, str(v), "2+3")
	testing.expect(t, caretfx_sel(&ui, n) == [2]int{3, 3}, "the caret is after the 3")

	// …and the caret the app chooses afterwards is where the next key lands:
	// "sin(" put in with the caret between its brackets.
	text_input_insert(&ui, n, "sin()")
	text_input_set_selection(&ui.tree, n, len(str(v)) - 1, len(str(v)) - 1)
	testing.expect(t, text_input_insert(&ui, n, "9"))
	testing.expect_value(t, str(v), "2+3sin(9)")
}

// What is selected is replaced, as typing over a selection does, and the
// app's on_change hears the new value.
@(test)
an_apps_insert_replaces_the_selection_and_is_heard :: proc(t: ^testing.T) {
	v: Text
	text_set(&v, "12+34")
	defer text_destroy(&v)
	ui: Ui(Caret_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := caretfx_build(&ui, &v)

	text_input_set_selection(&ui.tree, n, 3, 5) // the "34"
	testing.expect(t, text_input_insert(&ui, n, "7"))
	testing.expect_value(t, str(v), "12+7")
	testing.expect_value(t, caretfx_sel(&ui, n), [2]int{4, 4})
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0].(string), "12+7")
}

// The keypad's edits are in the field's own journal, which is the reason
// to come through the field rather than edit the Text behind its back: an
// edit the journal never saw makes Ctrl+Z restore a state that never was.
@(test)
a_keypad_key_joins_the_fields_undo :: proc(t: ^testing.T) {
	v: Text
	text_set(&v, "")
	defer text_destroy(&v)
	ui: Ui(Caret_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := caretfx_build(&ui, &v)
	d := node_get(&ui.tree, n)
	s := text_input_state(&ui.tree, n)

	text_input_insert(&ui, n, "12")
	ui.tree.now_ms += INPUT_UNDO_PAUSE_MS * 2 // a pause ends the step
	text_input_insert(&ui, n, "+")
	testing.expect_value(t, str(v), "12+")

	testing.expect(t, input_undo_apply(&ui, n, d, s, &s.undo, &s.redo), "Ctrl+Z takes back the keypad's key")
	testing.expect_value(t, str(v), "12")
	testing.expect(t, input_undo_apply(&ui, n, d, s, &s.undo, &s.redo))
	testing.expect_value(t, str(v), "")
}

// A press of a button is one deliberate act, so it is one undo step: three
// keys in a row go back one at a time, where three *typed* characters are
// one word-sized step. Typing around a press is split by it: the run before
// ends at the press, and the run after begins there.
@(test)
each_key_an_app_puts_in_is_its_own_undo_step :: proc(t: ^testing.T) {
	v: Text
	text_set(&v, "")
	defer text_destroy(&v)
	ui: Ui(Caret_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := caretfx_build(&ui, &v)
	d := node_get(&ui.tree, n)
	s := text_input_state(&ui.tree, n)
	set_focus(&ui.tree, n, true)
	frame(&ui.tree, {400, 120})

	text_input_insert(&ui, n, "7") // three presses, as fast as a hand can go
	text_input_insert(&ui, n, "+")
	text_input_insert(&ui, n, "8")
	testing.expect_value(t, str(v), "7+8")

	input_undo_apply(&ui, n, d, s, &s.undo, &s.redo)
	testing.expect_value(t, str(v), "7+")
	input_undo_apply(&ui, n, d, s, &s.undo, &s.redo)
	testing.expect_value(t, str(v), "7")
	input_undo_apply(&ui, n, d, s, &s.undo, &s.redo)
	testing.expect_value(t, str(v), "")

	// …now typing round a press: "12" typed, "+" pressed, "3" typed
	testing.expect(t, text_event(&ui, "1"))
	testing.expect(t, text_event(&ui, "2"))
	text_input_insert(&ui, n, "+")
	testing.expect(t, text_event(&ui, "3"))
	testing.expect_value(t, str(v), "12+3")

	input_undo_apply(&ui, n, d, s, &s.undo, &s.redo)
	testing.expect(t, str(v) == "12+", "the typing after the key is its own step")
	input_undo_apply(&ui, n, d, s, &s.undo, &s.redo)
	testing.expect(t, str(v) == "12", "and so is the key")
	input_undo_apply(&ui, n, d, s, &s.undo, &s.redo)
	testing.expect(t, str(v) == "", "the run before it goes back as one word")
}

// A keypad's Backspace: select the grapheme before the caret and put
// nothing over it. (The same empty string from an input method means
// "nothing to commit" and must leave the selection alone.)
@(test)
an_empty_insert_takes_out_what_is_selected :: proc(t: ^testing.T) {
	v: Text
	text_set(&v, "12+34")
	defer text_destroy(&v)
	ui: Ui(Caret_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := caretfx_build(&ui, &v)

	end := len(str(v))
	text_input_set_selection(&ui.tree, n, end, end) // as typing would have left it
	text_input_set_selection(&ui.tree, n, grapheme_prev(str(v), end), end)
	testing.expect(t, text_input_insert(&ui, n, ""))
	testing.expect_value(t, str(v), "12+3")
	testing.expect_value(t, caretfx_sel(&ui, n), [2]int{4, 4})

	// …and an input method committing nothing leaves the selection alone
	text_input_set_selection(&ui.tree, n, 0, 4)
	testing.expect(t, input_put(&ui, n, ""))
	testing.expect_value(t, str(v), "12+3")
	testing.expect_value(t, caretfx_sel(&ui, n), [2]int{0, 4})
}

// Moving the caret is not editing, so a disabled field takes the one and
// refuses the other — it draws no caret either way, and its value is not
// the app's to change through a control nobody can press.
@(test)
a_disabled_field_moves_its_caret_but_takes_no_text :: proc(t: ^testing.T) {
	v: Text
	text_set(&v, "12+34")
	defer text_destroy(&v)
	ui: Ui(Caret_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := caretfx_build(&ui, &v, disabled = true)

	text_input_set_selection(&ui.tree, n, 2, 2)
	testing.expect_value(t, caretfx_sel(&ui, n), [2]int{2, 2})
	testing.expect(t, !text_input_insert(&ui, n, "9"), "a disabled field is not written to")
	testing.expect_value(t, str(v), "12+34")
}

// caretfx_caret_x finds the drawn caret: a 1 px wide on_surface rect.
@(private = "file")
caretfx_caret_x :: proc(ui: ^Ui(Caret_Msg)) -> (x: f32, ok: bool) {
	for c in draw_list(&ui.tree) {
		if d, is := c.(Draw_Rect); is && d.rect.w == 1 && d.border_w == 0 && d.color == ui.theme.color.on_surface {
			return d.rect.x, true
		}
	}
	return
}

// And it is drawn where it was put: the caret an app sets is painted
// between the right glyphs, which is the whole point of moving it — the
// person has to see where the next key will land.
@(test)
the_caret_an_app_set_is_drawn_where_it_put_it :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init: embedded fonts failed to load")
	defer text_engine_destroy(&te)
	v: Text
	text_set(&v, "12+34")
	defer text_destroy(&v)
	ui: Ui(Caret_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tree_use_text_engine(&ui.tree, &te)
	n := caretfx_build(&ui, &v)
	set_focus(&ui.tree, n, true)
	frame(&ui.tree, {400, 120})

	text_input_set_selection(&ui.tree, n, 0, 0)
	frame(&ui.tree, {400, 120})
	x0, ok0 := caretfx_caret_x(&ui)
	testing.expect(t, ok0, "the caret is drawn in a focused field")

	text_input_set_selection(&ui.tree, n, 2, 2)
	frame(&ui.tree, {400, 120})
	x2, _ := caretfx_caret_x(&ui)

	text_input_set_selection(&ui.tree, n, 5, 5)
	frame(&ui.tree, {400, 120})
	x5, _ := caretfx_caret_x(&ui)

	// With something selected the caret is drawn at the *caret* end, not the
	// anchor, so a keypad typing over a range shows where the next key lands.
	// Only this case tells the two apart: elsewhere they coincide.
	text_input_set_selection(&ui.tree, n, 0, 2)
	frame(&ui.tree, {400, 120})
	xsel, oksel := caretfx_caret_x(&ui)
	testing.expect(t, oksel, "a field with a selection still draws its caret")
	testing.expect(t, xsel == x2, "at the caret end of the selection, not its anchor")

	text_input_set_selection(&ui.tree, n, 5, 2) // …and the other way round
	frame(&ui.tree, {400, 120})
	xback, _ := caretfx_caret_x(&ui)
	testing.expect(t, xback == x2, "wherever the anchor is")

	testing.expect(t, x0 < x2 && x2 < x5, "after two glyphs, the caret is between the ends")
	// …and the glyphs say where that is: "12" wide from the start of the text
	st := text_input_state(&ui.tree, n)
	w12 := text_measure(&ui.tree, "12", st.size, 0, .Regular).x
	gap := (x2 - x0) - w12
	testing.expect(t, gap > -1 && gap < 1, "it stands exactly after the 12")
}

// Neither one is a node the app has to check first.
@(test)
the_caret_calls_pass_over_anything_that_is_not_a_field :: proc(t: ^testing.T) {
	v: Text
	text_set(&v, "12")
	defer text_destroy(&v)
	ui: Ui(Caret_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	caretfx_build(&ui, &v)
	other := Node(9999)

	text_input_set_selection(&ui.tree, other, 0, 1) // no crash, nothing to set
	testing.expect(t, !text_input_insert(&ui, other, "9"))
	testing.expect_value(t, str(v), "12")
}

}
