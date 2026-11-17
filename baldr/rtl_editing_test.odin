package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Right-to-left text, alone and mixed into a left-to-right line: the caret
// moves leftward through Hebrew, a click finds the character under it, and a
// selection covers what was chosen on screen, in pieces where directions mix.

@(private = "file")
RTL_MIXED :: "abc אבג def" // Hebrew from byte 4 to 10, two bytes a letter

@(private = "file")
rtl_engine :: proc(t: ^testing.T, ui: ^Ui(int), te: ^Text_Engine) -> bool {
	if !text_engine_init(te) {
		testing.fail(t)
		return false
	}
	ui_init(ui)
	tree_use_text_engine(&ui.tree, te)
	return true
}

@(test)
rich_text_places_the_caret_through_right_to_left_text :: proc(t: ^testing.T) {
	te: Text_Engine
	ui: Ui(int)
	if !rtl_engine(t, &ui, &te) do return
	defer text_engine_destroy(&te)
	defer ui_destroy(&ui)

	lay := rich_layout(&ui.tree, RTL_MIXED, nil, Rich_Style{size = 15}, 0)
	testing.expect(t, len(lay.lines) == 1 && lay.lines[0].bidi, "one line, laid out by direction")
	x4, x6, x8, x10 := rich_x(&lay, 0, 4), rich_x(&lay, 0, 6), rich_x(&lay, 0, 8), rich_x(&lay, 0, 10)
	testing.expectf(t, x4 > x6 && x6 > x8, "the caret moves leftward through the Hebrew: %v %v %v", x4, x6, x8)
	testing.expectf(t, rich_x(&lay, 0, 2) < x8, "the Latin before it stays on its left")
	testing.expectf(t, rich_x(&lay, 0, 12) > x4, "and the Latin after it on its right")

	// a click at a character's middle finds the boundary at its nearer edge
	testing.expect_value(t, rich_hit(&lay, RTL_MIXED, 0, x6 + 1), 6)
	testing.expect_value(t, rich_hit(&lay, RTL_MIXED, 0, x8 - 1), 8)

	// the Hebrew alone is one piece; "c " plus its first letter is two, apart on screen
	whole := rich_spans(&lay, 0, 4, 10)
	testing.expect_value(t, len(whole), 1)
	testing.expectf(t, len(whole) == 1 && abs(whole[0][1] - x4) < 0.5 && abs(whole[0][1] - x10) < 0.5, "it ends where the caret before its first letter stands: %v", whole)
	split := rich_spans(&lay, 0, 2, 6)
	testing.expectf(t, len(split) == 2 && split[0][1] < split[1][0], "a selection across the change of direction is two pieces: %v", split)

	// a line that is all Hebrew starts at its right edge
	he := "שלום עולם"
	hl := rich_layout(&ui.tree, he, nil, Rich_Style{size = 15}, 0)
	testing.expectf(t, rich_x(&hl, 0, 0) > rich_x(&hl, 0, len(he)), "its first letter is on the right: %v, its end on the left: %v", rich_x(&hl, 0, 0), rich_x(&hl, 0, len(he)))
	free_all(context.temp_allocator)
}

@(test)
a_field_places_the_caret_through_right_to_left_text :: proc(t: ^testing.T) {
	te: Text_Engine
	ui: Ui(int)
	if !rtl_engine(t, &ui, &te) do return
	defer text_engine_destroy(&te)
	defer ui_destroy(&ui)

	begin_view(&ui)
	n := text_input(&ui, nil, label = "Name", initial = RTL_MIXED, width = 300)
	end_view(&ui)
	frame(&ui.tree, {400, 100})
	s := &ui.tree.inputs[n]
	if !testing.expect(t, s != nil, "the field keeps its state") do return
	x4, x6, x8 := input_caret_x(&ui.tree, s, 4), input_caret_x(&ui.tree, s, 6), input_caret_x(&ui.tree, s, 8)
	testing.expectf(t, x4 > x6 && x6 > x8, "the caret moves leftward through the Hebrew: %v %v %v", x4, x6, x8)
	testing.expect_value(t, input_hit(&ui.tree, s, x6 + 1), 6)
	testing.expect_value(t, input_hit(&ui.tree, s, input_caret_x(&ui.tree, s, 2)), 2)
	free_all(context.temp_allocator)
}

// The editors, plain and rich: the same caret, clicks and selection pieces
// through their own line spans.
@(test)
an_editor_places_the_caret_through_right_to_left_text :: proc(t: ^testing.T) {
	te: Text_Engine
	ui: Ui(int)
	if !rtl_engine(t, &ui, &te) do return
	defer text_engine_destroy(&te)
	defer ui_destroy(&ui)
	for rich in ([]bool{false, true}) {
		doc := document_make(RTL_MIXED)
		defer document_destroy(&doc)
		begin_view(&ui)
		n: Node
		if rich {
			n = rich_text(&ui, &doc, label = "Notes", width = 300)
		} else {
			n = text_area(&ui, &doc, label = "Notes", width = 300)
		}
		end_view(&ui)
		frame(&ui.tree, {400, 300})
		_, s := editor_area(&ui.tree, n) // a rich editor's node is its frame, with the area inside
		if !testing.expectf(t, s != nil, "rich %v: the editor keeps its state", rich) do return
		spans := block_spans(&ui.tree, s, 0)
		if !testing.expect(t, len(spans) == 1, "one line") do return
		sp := spans[0]
		x4, x6, x8 := span_x_disp(&ui.tree, s, 0, sp, 4), span_x_disp(&ui.tree, s, 0, sp, 6), span_x_disp(&ui.tree, s, 0, sp, 8)
		testing.expectf(t, x4 > x6 && x6 > x8, "rich %v: the caret moves leftward through the Hebrew: %v %v %v", rich, x4, x6, x8)
		testing.expectf(t, span_hit_disp(&ui.tree, s, 0, sp, x6 + 1) == 6, "rich %v: a click finds the boundary nearest it", rich)
		split := span_ranges(&ui.tree, s, 0, sp, 2, 6)
		testing.expectf(t, len(split) == 2, "rich %v: a selection across the change of direction is two pieces: %v", rich, split)
	}
	free_all(context.temp_allocator)
}

// When the machine's font list arrives (read off the UI thread in an app),
// text that waited for a fallback font is measured again: a paragraph and a
// reply that keep layouts of their own drop them too, or they would keep the
// widths of the boxes drawn while the font was missing.
@(test)
paragraphs_are_measured_again_when_the_fonts_arrive :: proc(t: ^testing.T) {
	ui: Ui(int)
	ui_init(&ui)
	defer ui_destroy(&ui)
	md: Markdown_Doc
	md_init(&md)
	defer md_destroy(&md)
	md_set(&md, "A reply")
	build :: proc(ui: ^Ui(int), md: ^Markdown_Doc) -> (para, reply: Node) {
		begin_view(ui)
		column(ui)
		para = styled_text(ui, "A paragraph", max_width = 300)
		reply = markdown_view(ui, md, label = "Reply", width = 300)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {400, 300})
		return
	}
	para, reply := build(&ui, &md)
	ps := &ui.tree.styled[para]
	ms := &ui.tree.md_views[reply]
	if !testing.expect(t, ps != nil && ms != nil && len(ps.lay.lines) > 0 && len(ms.blocks) > 0, "both laid out") do return
	ps.lay.lines[0].width = 999 // as if measured while a fallback font was missing
	ms.blocks[0].height = 999
	tree_fonts_changed(&ui.tree)
	build(&ui, &md)
	testing.expect(t, ps.lay.lines[0].width != 999, "the paragraph is measured again")
	testing.expect(t, len(ms.blocks) > 0 && ms.blocks[0].height != 999, "and so is the reply")
}

} // when ODIN_TEST
