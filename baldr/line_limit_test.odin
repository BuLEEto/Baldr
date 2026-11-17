package baldr

@(require) import "core:fmt"
@(require) import "core:strings"
@(require) import "core:testing"

// See canvas_test.odin for why test files sit behind this `when`.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Layout costs about 650 bytes a character, so one line of millions of
// characters (minified web source) would take gigabytes. Past
// AREA_LINE_LIMIT a line is neither laid out nor drawn; a marker says how
// much more there is, and the document keeps it all.

@(private = "file")
Ll_Msg :: union { int }

@(private = "file")
ll_doc :: proc(long: int) -> Document {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "first\n")
	for i in 0 ..< long do strings.write_byte(&b, u8('a' + i % 26))
	strings.write_string(&b, "\nlast")
	return document_make(strings.to_string(b))
}

@(private = "file")
ll_build :: proc(ui: ^Ui(Ll_Msg), doc: ^Document, code := false, limit: Maybe(int) = nil) -> Node {
	begin_view(ui)
	column(ui)
	ed := code_editor(ui, doc, &LANG_C, label = "Code", width = 600, height = 300, key = 1) if code else text_area(ui, doc, label = "Text", width = 600, height = 300, key = 1)
	if l, ok := limit.?; ok do editor_options(ui, ed, line_limit = l)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {700, 400})
	return ed
}

// What is laid out is the line up to the limit and a marker saying how much
// more there is, in the desktop's grouping; the document is untouched.
@(test)
a_line_past_the_limit_is_shown_up_to_it_with_a_marker :: proc(t: ^testing.T) {
	ui: Ui(Ll_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := ll_doc(250_000)
	defer document_destroy(&doc)
	ed := ll_build(&ui, &doc)
	_, s := editor_area(&ui.tree, ed)

	shown := area_text(&ui.tree, s, 1)
	testing.expectf(t, len(shown) < AREA_LINE_LIMIT + 80, "only the limit's worth is laid out (%d bytes shown)", len(shown))
	testing.expect(t, strings.has_prefix(shown, block_str(&doc, 1)[:AREA_LINE_LIMIT]), "and it is the start of the line")
	testing.expectf(t, strings.contains(shown, "240,000 more characters not shown"), "the marker says how much more, grouped: %q", shown[AREA_LINE_LIMIT:])
	testing.expect_value(t, len(block_str(&doc, 1)), 250_000) // the document has all of it
	testing.expect_value(t, area_text(&ui.tree, s, 0), "first")   // a short line is as it was

	// A place past the limit is shown after the marker; the marker stands
	// for the end of the line.
	testing.expect_value(t, to_disp(&ui.tree, s, 1, 250_000), len(shown))
	testing.expect_value(t, to_disp(&ui.tree, s, 1, 200), 200)
	testing.expect_value(t, to_src(&ui.tree, s, 1, len(shown) - 3), 250_000)
}

// The editor still edits and copies the whole line: End (in a code editor,
// whose lines do not wrap) goes to the line's real end past the marker, a
// character typed there lands in the document, and copying a selection
// across the line takes every character, not what was shown.
@(test)
the_whole_line_is_still_edited_and_copied :: proc(t: ^testing.T) {
	ui: Ui(Ll_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := ll_doc(50_000)
	defer document_destroy(&doc)
	ed := ll_build(&ui, &doc, code = true)
	area, s := editor_area(&ui.tree, ed) // the code editor's frame holds the area that takes the keys
	set_focus(&ui.tree, area, false)
	editor_select(&ui, ed, {1, 0}, {1, 0})
	key_event(&ui, .End, true, {})
	testing.expect_value(t, s.caret, Pos{1, 50_000})
	text_area_text(&ui, "Z") // the run loop's own entry for typed text into an editor
	testing.expect_value(t, len(block_str(&doc, 1)), 50_001)
	testing.expect(t, strings.has_suffix(block_str(&doc, 1), "Z"), "typed at the line's real end")

	copied: string
	ui.tree.clipboard = {
		user = &copied,
		set = proc(user: rawptr, text: string) -> bool {
			c := (^string)(user)
			delete(c^)
			c^ = strings.clone(text)
			return true
		},
	}
	defer delete(copied)
	editor_select(&ui, ed, {1, 0}, {1, 50_001})
	key_event(&ui, .C, true, {.Ctrl})
	testing.expect_value(t, len(copied), 50_001)
}

// An app can lift the limit, or set its own.
@(test)
an_app_sets_or_lifts_the_line_limit :: proc(t: ^testing.T) {
	ui: Ui(Ll_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := ll_doc(30_000)
	defer document_destroy(&doc)
	ed := ll_build(&ui, &doc, limit = 0)
	_, s := editor_area(&ui.tree, ed)
	testing.expect_value(t, len(area_text(&ui.tree, s, 1)), 30_000) // 0 lifts it: all of it is laid out
	ll_build(&ui, &doc, limit = 1_000)
	shown := area_text(&ui.tree, s, 1)
	testing.expectf(t, len(shown) < 1_000 + 80 && strings.contains(shown, "29,000 more"), "its own limit: %d bytes, %q", len(shown), shown[min(1000, len(shown)):])
}

// In a code editor the marker is coloured as a comment, not as code, and
// what comes before it keeps its syntax colours.
@(test)
a_code_editors_marker_reads_as_a_comment :: proc(t: ^testing.T) {
	ui: Ui(Ll_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := ll_doc(40_000)
	defer document_destroy(&doc)
	ll_build(&ui, &doc, code = true)
	found := false
	for c in draw_list(&ui.tree) {
		v, is_text := c.(Draw_Text)
		if !is_text || !strings.contains(v.str, "more characters not shown") do continue
		found = true
		testing.expect_value(t, v.color.rgb, ui.tree.theme.color.code.comment.rgb)
	}
	testing.expect(t, found, "the marker is drawn")
}


// A code editor tells a screen reader the caret's line and column, counting
// on from where it last counted rather than from the start of the line on
// every move. Whatever the keys and the typing, the column it says is the
// one a count from the start gives, including after a mark typed at the
// caret, which joins onto the character before it.
@(test)
a_code_editors_column_stays_right_as_it_counts_on :: proc(t: ^testing.T) {
	ui: Ui(Ll_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "first\nab e\U00000301 \U0001F469\U0000200D\U0001F469 cd ")
	for i in 0 ..< 1500 do strings.write_byte(&b, u8('a' + i % 26) if i % 40 != 39 else '+')
	strings.write_string(&b, "\U00000301\U00000301 mid ")
	for _ in 0 ..< 1500 do strings.write_byte(&b, 'y')
	strings.write_string(&b, "\nlast")
	doc := document_make(strings.to_string(b))
	defer document_destroy(&doc)
	ed := ll_build(&ui, &doc, code = true)
	area, s := editor_area(&ui.tree, ed)
	set_focus(&ui.tree, area, false)
	editor_select(&ui, ed, {1, 0}, {1, 0})

	step := 0
	said_right :: proc(t: ^testing.T, ui: ^Ui(Ll_Msg), area: Node, s: ^Text_Area_State, step: ^int, what: string) -> bool {
		step^ += 1
		want := fmt.tprintf("Line %d, column %d", s.caret.block + 1, grapheme_index(block_str(s.doc, s.caret.block), s.caret.off) + 1)
		got := node_get(&ui.tree, area).access.describe
		if got != want do testing.expectf(t, false, "step %d (%s, caret %v): says %q, want %q", step^, what, s.caret, got, want)
		return got == want
	}
	for _ in 0 ..< 12 do key_event(&ui, .Right, true, {})
	if !said_right(t, &ui, area, s, &step, "right through the marks and the emoji") do return
	key_event(&ui, .End, true, {})
	if !said_right(t, &ui, area, s, &step, "end") do return
	for _ in 0 ..< 1600 {
		key_event(&ui, .Left, true, {})
		if !said_right(t, &ui, area, s, &step, "left, back across the run") do return
	}
	for _ in 0 ..< 30 do key_event(&ui, .Left, true, {.Ctrl})
	if !said_right(t, &ui, area, s, &step, "ctrl+left") do return
	key_event(&ui, .Home, true, {})
	if !said_right(t, &ui, area, s, &step, "home") do return
	for _ in 0 ..< 40 do key_event(&ui, .Right, true, {.Ctrl})
	if !said_right(t, &ui, area, s, &step, "ctrl+right") do return
	text_area_text(&ui, "\U00000301") // a mark typed in the middle of a plain run: it joins the letter before
	if !said_right(t, &ui, area, s, &step, "a mark typed") do return
	text_area_text(&ui, "z")
	if !said_right(t, &ui, area, s, &step, "a letter typed after it") do return
	for _ in 0 ..< 3 do key_event(&ui, .Backspace, true, {})
	if !said_right(t, &ui, area, s, &step, "backspace") do return
	key_event(&ui, .End, true, {})
	text_area_text(&ui, "q")
	if !said_right(t, &ui, area, s, &step, "typed at the end") do return
	// An edit that starts exactly where the count was kept: a mark there
	// joins the letter before it, so the count before that place is one
	// fewer and cannot be kept. (Far along the line, where counting on from
	// the kept place is cheaper than counting from the start.)
	kept := s.code.column.at
	testing.expect(t, kept > 0 && kept < s.caret.off, "the count is kept a little behind the caret")
	editor_select(&ui, ed, {1, kept}, s.caret)
	text_area_text(&ui, "\U00000301")
	if !said_right(t, &ui, area, s, &step, "a selection from the kept place replaced by a mark") do return
	key_event(&ui, .Up, true, {})
	key_event(&ui, .Down, true, {})
	said_right(t, &ui, area, s, &step, "to another line and back")
}


// The live markdown editor and the rich editor are capped too. In the
// markdown editor a capped line shows as its source with the marker (a
// `data:` picture's markup, never the picture, which would mean decoding
// all of it), and the heading above it is rendered as ever. In the rich
// editor a style that runs across the cut stops at it, and the marker is
// dimmed.
@(test)
the_markdown_and_rich_editors_cap_a_long_line_too :: proc(t: ^testing.T) {
	ui: Ui(Ll_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "# Title\n![holiday](data:image/png;base64,")
	for i in 0 ..< 60_000 do strings.write_byte(&b, u8('A' + i % 26))
	strings.write_string(&b, ")\nend")
	doc := document_make(strings.to_string(b))
	defer document_destroy(&doc)

	md_build :: proc(ui: ^Ui(Ll_Msg), doc: ^Document, limit: Maybe(int) = nil) -> Node {
		begin_view(ui)
		column(ui)
		ed := markdown_editor(ui, doc, label = "Note", width = 600, height = 300, key = 1)
		if l, ok := limit.?; ok do editor_options(ui, ed, line_limit = l)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {700, 400})
		return ed
	}
	ed := md_build(&ui, &doc)
	_, s := editor_area(&ui.tree, ed)
	testing.expect(t, s.live, "the markdown editor renders as it goes")
	shown := area_text(&ui.tree, s, 1)
	testing.expectf(t, strings.has_prefix(shown, "![holiday](data:image/png"), "a capped line shows its source: %q", shown[:min(40, len(shown))])
	testing.expectf(t, len(shown) < AREA_LINE_LIMIT + 80 && strings.contains(shown, "more characters not shown"), "up to the limit, then the marker (%d bytes)", len(shown))
	testing.expect_value(t, area_meta(&ui.tree, s, 1).kind, Block_Kind.Paragraph) // shown as a paragraph of source, not a picture
	testing.expect_value(t, area_meta(&ui.tree, s, 0).kind, Block_Kind.Heading)   // the line above is rendered
	runs := area_runs_plain(&ui.tree, s, 1)
	testing.expect(t, len(runs) >= 2 && runs[len(runs) - 1].attrs == {.Mark, .Italic}, "the marker is dimmed")
	// Lifted, the same line is the picture it says it is: it was the cap.
	md_build(&ui, &doc, limit = 0)
	testing.expect_value(t, area_meta(&ui.tree, s, 1).kind, Block_Kind.Image)

	// The rich editor: bold from the start of the long line to past the cut.
	rdoc := document_make(strings.to_string(b))
	defer document_destroy(&rdoc)
	document_set_attrs(&rdoc, {1, 0}, {1, AREA_LINE_LIMIT + 500}, {.Bold}, {})
	begin_view(&ui)
	column(&ui)
	red := rich_text(&ui, &rdoc, label = "Text", width = 600, height = 300, key = 2)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {700, 400})
	_, rs := editor_area(&ui.tree, red)
	testing.expect(t, rs.rich && !rs.live, "a rich editor")
	rshown := area_text(&ui.tree, rs, 1)
	rruns := area_runs_plain(&ui.tree, rs, 1)
	testing.expectf(t, len(rruns) == 2, "the bold up to the cut, then the marker: %v", rruns)
	if len(rruns) == 2 {
		testing.expect(t, .Bold in rruns[0].attrs && rruns[0].end == AREA_LINE_LIMIT, "the bold stops at the cut")
		testing.expect(t, rruns[1].attrs == {.Mark, .Italic} && rruns[1].end == len(rshown), "the marker is dimmed, to the end of what is shown")
	}
	testing.expect_value(t, len(block_str(&rdoc, 1)), len("![holiday](data:image/png;base64,") + 60_001) // the document keeps it all
}

}
