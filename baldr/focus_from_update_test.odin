package baldr

@(require) import "core:testing"

// After opening a chat, pressing Reply, or an onboarding screen appearing,
// the caret should already be in the field so typing just works. The
// decision is made in `update`, where there is no tree — hence
// the `focus` command, which names the widget by its reconciliation key
// and is satisfied by the build that follows.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Ffu_Msg :: union { int }

@(private = "file")
FFU_COMPOSER :: u64(0x_c0_11)
@(private = "file")
FFU_SEARCH :: u64(0x_5ea2)

@(private = "file")
// `v` belongs to the test, not to this proc: `text_input` keeps the pointer
// it is given in the tree's own state, so a `Text` on this stack would
// dangle in a live tree once the build returned.
ffu_build :: proc(ui: ^Ui(Ffu_Msg), doc: ^Document, v: ^Text, composer := true, focus := false) {
	set_viewport(&ui.tree, {420, 320})
	begin_view(ui)
	column(ui, padding = .md, gap = .sm)
	text_input(ui, v, label = "Search", key = FFU_SEARCH)
	if composer do text_area(ui, doc, label = "Message", focus = focus, key = FFU_COMPOSER)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {420, 320})
}

// The command names a widget that the build after it makes, and the
// keyboard lands there.
@(test)
the_focus_command_gives_the_keyboard_to_the_named_widget :: proc(t: ^testing.T) {
	doc := document_make()
	defer document_destroy(&doc)
	v: Text
	defer text_destroy(&v)
	ui: Ui(Ffu_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	ffu_build(&ui, &doc, &v)
	testing.expect(t, ui.tree.focus == NODE_NONE, "nothing has the keyboard to begin with")

	ui.focus_want, ui.focus_tries = FFU_COMPOSER, 0 // what `focus(Msg, FFU_COMPOSER)` sets
	ffu_build(&ui, &doc, &v)
	testing.expect(t, ui.tree.focus != NODE_NONE, "something took the keyboard")
	testing.expect_value(t, node_get(&ui.tree, ui.tree.focus).key, FFU_COMPOSER)
	testing.expect_value(t, ui.focus_want, u64(0)) // the ask is spent
}

// The command usually causes the screen holding the field to be built, so
// a field that is not there yet still gets it, such as a chat's composer
// that appears with the chat.
@(test)
a_focus_ask_waits_for_the_widget_to_be_built :: proc(t: ^testing.T) {
	doc := document_make()
	defer document_destroy(&doc)
	v: Text
	defer text_destroy(&v)
	ui: Ui(Ffu_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	ffu_build(&ui, &doc, &v, composer = false)
	ui.focus_want, ui.focus_tries = FFU_COMPOSER, 0
	ffu_build(&ui, &doc, &v, composer = false) // still not there
	testing.expect(t, ui.tree.focus == NODE_NONE, "nothing to focus yet")
	testing.expect_value(t, ui.focus_want, FFU_COMPOSER) // …and the ask is still waiting

	ffu_build(&ui, &doc, &v, composer = true) // the chat opened
	testing.expect_value(t, node_get(&ui.tree, ui.tree.focus).key, FFU_COMPOSER)
}

// …but not for ever: a key that never appears must not be claimed much
// later by an unrelated screen that happens to reuse it.
@(test)
a_focus_ask_for_a_widget_that_never_comes_is_dropped :: proc(t: ^testing.T) {
	doc := document_make()
	defer document_destroy(&doc)
	v: Text
	defer text_destroy(&v)
	ui: Ui(Ffu_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	ffu_build(&ui, &doc, &v, composer = false)
	ui.focus_want, ui.focus_tries = FFU_COMPOSER, 0
	for _ in 0 ..< FOCUS_WAIT_BUILDS do ffu_build(&ui, &doc, &v, composer = false)
	testing.expect_value(t, ui.focus_want, u64(0)) // given up on

	ffu_build(&ui, &doc, &v, composer = true) // a later screen reuses the key
	testing.expect(t, ui.tree.focus == NODE_NONE, "and it is not taken retrospectively")
}

// The draft survives. `text_input` selects its whole value when the app
// hands it focus, which suits a path bar; a composer holds something
// half-written, so its caret goes to the end instead, with nothing selected.
@(test)
focusing_a_composer_keeps_the_draft_and_puts_the_caret_at_the_end :: proc(t: ^testing.T) {
	doc := document_make()
	defer document_destroy(&doc)
	document_set_text(&doc, "see you at")
	v: Text
	defer text_destroy(&v)
	ui: Ui(Ffu_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	ffu_build(&ui, &doc, &v, focus = false)
	ffu_build(&ui, &doc, &v, focus = true) // it turned true: Reply was pressed

	n := ui.tree.focus
	testing.expect_value(t, node_get(&ui.tree, n).key, FFU_COMPOSER)
	s := &ui.tree.areas[n]
	testing.expect(t, s != nil, "the composer has state")
	testing.expect_value(t, s.caret, document_end(&doc))
	testing.expect_value(t, s.anchor, s.caret) // nothing selected: typing appends
	testing.expect_value(t, document_text(&doc, context.temp_allocator), "see you at")
}

// A disabled field is not given the keyboard by either route.
@(test)
a_disabled_field_is_not_focused_from_update :: proc(t: ^testing.T) {
	doc := document_make()
	defer document_destroy(&doc)
	ui: Ui(Ffu_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	build :: proc(ui: ^Ui(Ffu_Msg), doc: ^Document) {
		set_viewport(&ui.tree, {420, 320})
		begin_view(ui)
		column(ui, padding = .md)
		text_area(ui, doc, label = "Message", disabled = true, key = FFU_COMPOSER)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {420, 320})
	}
	build(&ui, &doc)
	ui.focus_want, ui.focus_tries = FFU_COMPOSER, 0
	build(&ui, &doc)
	testing.expect(t, ui.tree.focus == NODE_NONE, "a disabled composer does not take the keyboard")
}

}
