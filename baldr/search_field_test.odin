package baldr

@(require) import "core:testing"

// A search field: a magnifier, a placeholder, a cross once there is
// something to clear, Escape to clear, Enter to run the search at once
// whatever the app's debounce was waiting for.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Sfield_Msg :: union { Sfield_Changed, Sfield_Submitted, Sfield_Cancelled }
@(private = "file")
Sfield_Changed :: struct { text: string }
@(private = "file")
Sfield_Submitted :: struct { text: string }
@(private = "file")
Sfield_Cancelled :: struct {}

@(private = "file")
sfield_changed :: proc(e: Ev(string)) -> Sfield_Msg { return Sfield_Changed{e.value} }
@(private = "file")
sfield_submitted :: proc(e: Ev(string)) -> Sfield_Msg { return Sfield_Submitted{e.value} }

@(private = "file")
sfield_build :: proc(ui: ^Ui(Sfield_Msg), v: ^Text, cancels := false) -> (outer: Node, field: Node, cross: Node) {
	set_viewport(&ui.tree, {400, 200})
	begin_view(ui)
	column(ui, padding = .md)
	if cancels {
		outer = search_field(ui, v, on_change = sfield_changed, on_submit = sfield_submitted,
			on_cancel = Sfield_Msg(Sfield_Cancelled{}), width = 260, key = 1)
	} else {
		outer = search_field(ui, v, on_change = sfield_changed, on_submit = sfield_submitted, width = 260, key = 1)
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 200})
	for c := node_first(&ui.tree, outer); c != NODE_NONE; c = node_next(&ui.tree, c) {
		if _, is_field := ui.tree.inputs[c]; is_field do field = c
		if _, is_clear := ui.search_clears[c]; is_clear do cross = c
	}
	return
}

// It reads as a search box, the field is inside the frame, and the
// magnifier is decoration rather than something a screen reader announces.
@(test)
a_search_field_reads_as_a_search_box :: proc(t: ^testing.T) {
	v: Text
	text_set(&v, "")
	defer text_destroy(&v)
	ui: Ui(Sfield_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	outer, field, _ := sfield_build(&ui, &v)

	testing.expect(t, field != NODE_NONE, "there is a field inside")
	testing.expect_value(t, node_get(&ui.tree, field).access.role, Role.Search_Box)
	testing.expect_value(t, node_get(&ui.tree, field).access.name, "Search")
	testing.expect(t, focusable(&ui.tree, field), "the field is the Tab stop")

	// the frame is the outer row's, so the field draws none of its own
	s := &ui.tree.inputs[field]
	testing.expect(t, s.quiet, "the field is quiet: whatever holds it draws the chrome")
	testing.expect(t, node_get(&ui.tree, outer).style.border_w > 0, "and the frame is the row's")

	// the magnifier says nothing to a screen reader
	for c := node_first(&ui.tree, outer); c != NODE_NONE; c = node_next(&ui.tree, c) {
		if c == field do continue
		testing.expect(t, node_get(&ui.tree, c).access.role != .Image, "the magnifier is decoration")
	}
}

// The cross appears only when there is something to clear — an always-there
// one invites a click that does nothing — and clearing it keeps the
// keyboard in the field so the next query can just be typed.
@(test)
the_cross_appears_with_the_text_and_clearing_keeps_the_keyboard :: proc(t: ^testing.T) {
	v: Text
	text_set(&v, "")
	defer text_destroy(&v)
	ui: Ui(Sfield_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	_, field, cross := sfield_build(&ui, &v)
	testing.expect_value(t, cross, NODE_NONE) // nothing typed: no cross

	text_set(&v, "ada")
	_, field2, cross2 := sfield_build(&ui, &v)
	testing.expect(t, cross2 != NODE_NONE, "with text there is a cross")
	testing.expect_value(t, node_get(&ui.tree, cross2).access.name, "Clear search")
	testing.expect(t, focusable(&ui.tree, cross2), "and it can be reached without the pointer")
	testing.expect_value(t, field2, field) // the same field node throughout

	clear(&ui.msgs)
	testing.expect(t, click(&ui, cross2), "the cross takes a click")
	testing.expect_value(t, str(v), "")
	testing.expect_value(t, ui.tree.focus, field) // the keyboard stayed in the field
	got := false
	for m in ui.msgs do if c, ok := m.(Sfield_Changed); ok { got = true; testing.expect_value(t, c.text, "") }
	testing.expect(t, got, "and the app was told it changed")

	// …and the cross goes away again
	_, _, cross3 := sfield_build(&ui, &v)
	testing.expect_value(t, cross3, NODE_NONE)
}

// Escape clears it, and stops there, but only while there is something
// to clear. An empty one lets Escape go on to close the sidebar or dialog
// around it: a dismissal is never the destructive choice.
@(test)
escape_clears_a_search_field_then_passes_on_when_it_is_empty :: proc(t: ^testing.T) {
	v: Text
	text_set(&v, "ada lovelace")
	defer text_destroy(&v)
	ui: Ui(Sfield_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	_, field, _ := sfield_build(&ui, &v, cancels = true)
	set_focus(&ui.tree, field, true)

	clear(&ui.msgs)
	testing.expect(t, text_input_key(&ui, .Escape, {}), "Escape is the field's while it holds text")
	testing.expect_value(t, str(v), "")
	changed := false
	cancelled := false
	for m in ui.msgs {
		if _, ok := m.(Sfield_Changed); ok do changed = true
		if _, ok := m.(Sfield_Cancelled); ok do cancelled = true
	}
	testing.expect(t, changed, "the app heard the change")
	testing.expect(t, !cancelled, "and was NOT told to close: Escape cleared, it did not dismiss")

	// now it is empty: Escape is no longer the field's to eat
	sfield_build(&ui, &v, cancels = true)
	set_focus(&ui.tree, field, true)
	clear(&ui.msgs)
	text_input_key(&ui, .Escape, {})
	cancelled2 := false
	for m in ui.msgs do if _, ok := m.(Sfield_Cancelled); ok do cancelled2 = true
	testing.expect(t, cancelled2, "an empty field lets Escape close what is around it")
}

// Enter runs the search at once, whatever the app's debounce was waiting
// for; that is why it is separate from on_change.
@(test)
enter_submits_the_query_at_once :: proc(t: ^testing.T) {
	v: Text
	text_set(&v, "rocket")
	defer text_destroy(&v)
	ui: Ui(Sfield_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	_, field, _ := sfield_build(&ui, &v)
	set_focus(&ui.tree, field, true)

	clear(&ui.msgs)
	testing.expect(t, text_input_key(&ui, .Enter, {}), "Enter is the field's")
	testing.expect_value(t, len(ui.msgs), 1)
	sub, ok := ui.msgs[0].(Sfield_Submitted)
	testing.expect(t, ok, "it submitted")
	testing.expect_value(t, sub.text, "rocket")
	testing.expect_value(t, str(v), "rocket") // and the text is untouched
}

// Typing reaches the app on every keystroke; the app debounces, because
// only it knows what its search costs.
@(test)
typing_in_a_search_field_reports_every_keystroke :: proc(t: ^testing.T) {
	v: Text
	text_set(&v, "")
	defer text_destroy(&v)
	ui: Ui(Sfield_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	_, field, _ := sfield_build(&ui, &v)
	set_focus(&ui.tree, field, true)

	clear(&ui.msgs)
	keys := []string{"c", "a", "t"}
	for ch in keys do text_event(&ui, ch)
	testing.expect_value(t, str(v), "cat")
	n := 0
	for m in ui.msgs do if _, ok := m.(Sfield_Changed); ok do n += 1
	testing.expect_value(t, n, 3) // one per keystroke, not one at the end
}

// A disabled search field offers no cross: there would be nothing to do
// with it, and a dimmed control that still reacts is worse than none.
@(test)
a_disabled_search_field_offers_no_cross :: proc(t: ^testing.T) {
	v: Text
	text_set(&v, "ada")
	defer text_destroy(&v)
	ui: Ui(Sfield_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	set_viewport(&ui.tree, {400, 200})
	begin_view(&ui)
	column(&ui, padding = .md)
	outer := search_field(&ui, &v, disabled = true, width = 260, key = 1)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 200})

	for c := node_first(&ui.tree, outer); c != NODE_NONE; c = node_next(&ui.tree, c) {
		_, is_clear := ui.search_clears[c]
		testing.expect(t, !is_clear, "no cross on a disabled field")
	}
}

}
