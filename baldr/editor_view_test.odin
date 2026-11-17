package baldr

@(require) import "core:fmt"
@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: about 9 GB without this `when`, 1 GB with it.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// An app moves an editor's caret and selection, scrolls it to a position
// (an outline jumping to a heading, find showing its match) and saves and
// restores where the view was.


@(private = "file")
Ev_Msg :: union { int }

@(private = "file")
long_text :: proc(lines: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< lines {
		if i > 0 do strings.write_byte(&b, '\n')
		fmt.sbprintf(&b, "line %d of a long document", i)
	}
	return strings.to_string(b)
}

@(private = "file")
editor_ui :: proc(ui: ^Ui(Ev_Msg), doc: ^Document, markdown := false, reveal: Maybe(Pos) = nil) -> Node {
	begin_view(ui)
	column(ui, padding = .lg)
	n := markdown_editor(ui, doc, label = "Notes", width = 320, height = 150) if markdown else text_area(ui, doc, label = "Notes", width = 320, height = 150)
	if p, ok := reveal.?; ok do editor_reveal(ui, n, p, .Top) // straight after building, before any layout
	end(ui)
	end_view(ui)
	frame(&ui.tree, {500, 400})
	return n
}

// where a position's line sits in the editor's content, and how tall it is
@(private = "file")
line_y :: proc(t: ^Tree, n: Node, p: Pos) -> (y, h: f32) {
	area, s := editor_area(t, n)
	_ = area
	line, _, _ := caret_line(t, s, p)
	h = area_line_h(t, s, p.block)
	return block_text_top(t, s, p.block) + f32(line) * h, h
}

@(private = "file")
view_of :: proc(t: ^Tree, n: Node) -> Scroll_State {
	area, _ := editor_area(t, n)
	return t.scrolls[area]
}

@(test)
an_app_selects_and_the_caret_is_kept_in_view :: proc(t: ^testing.T) {
	ui: Ui(Ev_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make(long_text(200))
	defer document_destroy(&doc)
	n := editor_ui(&ui, &doc)
	testing.expect_value(t, view_of(&ui.tree, n).offset.y, 0)

	editor_select(&ui, n, Pos{150, 0}, Pos{150, 4})
	lo, hi, ok := editor_selection(&ui.tree, n)
	testing.expect(t, ok && lo == Pos{150, 0} && hi == Pos{150, 4}, "the selection is what was set")
	_, s := editor_area(&ui.tree, n)
	testing.expect_value(t, s.goal_x, -1) // Up and Down start from the caret, as after a click
	editor_ui(&ui, &doc)
	v := view_of(&ui.tree, n)
	y, h := line_y(&ui.tree, n, Pos{150, 4})
	testing.expectf(t, y >= v.offset.y - 0.5 && y + h <= v.offset.y + v.viewport.y + 0.5, "the caret's line %v is in view %v", y, v)

	editor_select(&ui, n, Pos{999, 999}, Pos{999, 999})
	lo, hi, _ = editor_selection(&ui.tree, n)
	end_pos := Pos{199, len("line 199 of a long document")}
	testing.expect(t, lo == end_pos && hi == end_pos, "clamped to the Document's end")
}

@(test)
editor_reveal_centres_and_puts_a_view_back :: proc(t: ^testing.T) {
	ui: Ui(Ev_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make(long_text(200))
	defer document_destroy(&doc)
	n := editor_ui(&ui, &doc)

	editor_reveal(&ui, n, Pos{100, 0}, .Center)
	editor_ui(&ui, &doc)
	v := view_of(&ui.tree, n)
	y, h := line_y(&ui.tree, n, Pos{100, 0})
	testing.expectf(t, abs((y + h / 2) - (v.offset.y + v.viewport.y / 2)) < 1, "line 100 in the middle (%v in %v)", y, v)

	editor_reveal(&ui, n, Pos{73, 5}, .Top)
	editor_ui(&ui, &doc)
	top, vok := editor_view(&ui.tree, n)
	testing.expect(t, vok && top == Pos{73, 0}, "the top line's first position")

	editor_reveal(&ui, n, Pos{10, 0}, .Top) // somewhere else, then back
	editor_ui(&ui, &doc)
	editor_reveal(&ui, n, top, .Top)
	editor_ui(&ui, &doc)
	back, _ := editor_view(&ui.tree, n)
	testing.expect_value(t, back, top)

	editor_select(&ui, n, Pos{5, 0}, Pos{5, 0}) // the caret put back, then the view: the last one counts
	editor_reveal(&ui, n, top, .Top)
	editor_ui(&ui, &doc)
	again, _ := editor_view(&ui.tree, n)
	testing.expect_value(t, again, top)
}

@(test)
editor_reveal_waits_for_an_editor_not_laid_out :: proc(t: ^testing.T) {
	ui: Ui(Ev_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make(long_text(200))
	defer document_destroy(&doc)
	_, not_yet := editor_view(&ui.tree, 0)
	testing.expect(t, !not_yet, "no editor: not ok")
	n := editor_ui(&ui, &doc, reveal = Pos{50, 0}) // revealed in the build that makes it
	top, ok := editor_view(&ui.tree, n)
	testing.expect(t, ok && top == Pos{50, 0}, "shown once it was laid out")
}

@(test)
editor_reveal_in_a_markdown_editor_with_headings :: proc(t: ^testing.T) {
	ui: Ui(Ev_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 40 do fmt.sbprintf(&b, "# Heading %d\n\nSome text under heading %d, long enough to take a line.\n\n", i, i)
	doc := document_make(strings.to_string(b))
	defer document_destroy(&doc)
	n := editor_ui(&ui, &doc, markdown = true)
	heading := Pos{4 * 30, 0} // "# Heading 30"
	testing.expect(t, strings.has_prefix(block_str(&doc, heading.block), "# Heading 30"), "fixture: the heading's block")

	editor_select(&ui, n, heading, heading) // the outline: select the heading's start, centred
	editor_reveal(&ui, n, heading, .Center)
	editor_ui(&ui, &doc, markdown = true)
	v := view_of(&ui.tree, n)
	y, h := line_y(&ui.tree, n, heading)
	testing.expectf(t, abs((y + h / 2) - (v.offset.y + v.viewport.y / 2)) < 1, "the heading in the middle (%v, %v in %v)", y, h, v)

	editor_reveal(&ui, n, heading, .Top)
	editor_ui(&ui, &doc, markdown = true)
	top, ok := editor_view(&ui.tree, n)
	testing.expect(t, ok && top == heading, "on the top line, and editor_view says so")
}

} // when ODIN_TEST