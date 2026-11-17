package baldr

// A press in a scroll bar's zone grabs the bar, even when the thing that
// scrolls is itself a text view that would otherwise take the press and
// drag-select.

@(require) import "core:strings"
@(require) import "core:testing"

when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Bar_Msg :: enum { None }

// bar_editor builds a text area holding more lines than it can show, so it
// really has a bar, and returns the node and the centre of its bar zone.
@(private = "file")
bar_editor :: proc(ui: ^Ui(Bar_Msg), doc: ^Document) -> (ed: Node, in_zone: [2]f32, ok: bool) {
	begin_view(ui)
	ed = text_area(ui, doc, label = "Notes", width = 300, height = 120)
	end_view(ui)
	frame(&ui.tree, {400, 300})
	zone := scrollbar_zone(&ui.tree, ed) or_return
	return ed, {zone.x + zone.w * 0.5, zone.y + zone.h * 0.5}, true
}

@(private = "file")
bar_doc :: proc() -> Document {
	b: strings.Builder
	strings.builder_init(&b)
	defer strings.builder_destroy(&b)
	for _ in 0 ..< 200 do strings.write_string(&b, "a line of text in the document\n")
	return document_make(strings.to_string(b))
}

// The press grabs the bar: it neither places the caret nor starts a
// selection.
@(test)
a_press_in_an_editors_bar_zone_grabs_the_bar :: proc(t: ^testing.T) {
	ui: Ui(Bar_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := bar_doc()
	defer document_destroy(&doc)
	ed, in_zone, ok := bar_editor(&ui, &doc)
	if !testing.expect(t, ok, "200 lines in 120 px: it has a bar") do return

	_, before := editor_area(&ui.tree, ed)
	caret_was := before.caret
	pointer_move(&ui, in_zone)
	pointer_button(&ui, .Left, true, in_zone)

	testing.expect_value(t, ui.pointer.scroll_drag, ed)   // the bar took it
	_, after := editor_area(&ui.tree, ed)
	testing.expect_value(t, after.caret, caret_was)        // …and the caret did not move
	testing.expect_value(t, after.anchor, after.caret)     // …so nothing is selected
}

// Away from the zone the editor still gets its press: the bar takes only
// presses in its own zone.
@(test)
a_press_in_the_text_still_reaches_the_editor :: proc(t: ^testing.T) {
	ui: Ui(Bar_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := bar_doc()
	defer document_destroy(&doc)
	ed, in_zone, ok := bar_editor(&ui, &doc)
	if !testing.expect(t, ok, "it has a bar") do return

	d := node_get(&ui.tree, ed)
	in_text := [2]f32{d.abs.x + 20, in_zone.y} // same height, well left of the zone
	pointer_move(&ui, in_text)
	pointer_button(&ui, .Left, true, in_text)

	testing.expect_value(t, ui.pointer.scroll_drag, Node(NODE_NONE))
	_, s := editor_area(&ui.tree, ed)
	testing.expect(t, s.caret != Pos{}, "the editor placed its caret")
}

// Over the zone the bar is a thing to grab, so the pointer is an arrow
// rather than the I-beam of the text underneath.
@(test)
the_bar_zone_shows_an_arrow_not_an_i_beam :: proc(t: ^testing.T) {
	ui: Ui(Bar_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := bar_doc()
	defer document_destroy(&doc)
	ed, in_zone, ok := bar_editor(&ui, &doc)
	if !testing.expect(t, ok, "it has a bar") do return

	d := node_get(&ui.tree, ed)
	in_text := [2]f32{d.abs.x + 20, in_zone.y}
	pointer_move(&ui, in_text)
	testing.expect_value(t, cursor_for(&ui), Cursor.Text) // the text: an I-beam

	pointer_move(&ui, in_zone)
	testing.expect_value(t, cursor_for(&ui), Cursor.Default) // the bar: an arrow
}

}
