package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Behind this `when` so a program importing Baldr does not type-check the
// test suite too, which costs gigabytes. ODIN_TEST is set by `odin test`;
// BALDR_TESTS lets ./build.sh check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// An app's own toolbar formats a markdown editor through rich_apply, which
// edits the source the way the editor's shortcuts do; `==highlight==` is
// one of the marks it knows.


@(private = "file")
Md_Msg :: union { int }

@(private = "file")
Md_Fx :: struct {
	ui:   Ui(Md_Msg),
	doc:  Document,
	area: Node,
}

@(private = "file")
md_view :: proc(fx: ^Md_Fx, readonly := false) -> Node {
	ui := &fx.ui
	begin_view(ui)
	column(ui, padding = .lg)
	n := markdown_editor(ui, &fx.doc, label = "Notes", width = 420, height = 260)
	editor_options(ui, n, readonly = readonly)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 600})
	fx.area, _ = editor_area(&ui.tree, n)
	return n
}

@(private = "file")
md_start :: proc(fx: ^Md_Fx, src: string) -> Node {
	ui_init(&fx.ui)
	fx.doc = document_make(src)
	return md_view(fx)
}

@(private = "file")
md_end :: proc(fx: ^Md_Fx) {
	document_destroy(&fx.doc)
	ui_destroy(&fx.ui)
}

@(private = "file")
src_of :: proc(fx: ^Md_Fx) -> string {
	return document_text(&fx.doc, context.temp_allocator)
}

@(private = "file")
select_in :: proc(fx: ^Md_Fx, n: Node, a, b: Pos) {
	editor_select(&fx.ui, n, a, b)
}

// an action, then what the source and the selection became
@(private = "file")
apply :: proc(fx: ^Md_Fx, n: Node, action: Rich_Action) -> (src: string, lo, hi: Pos) {
	rich_apply(&fx.ui, n, action)
	md_view(fx)
	lo, hi, _ = editor_selection(&fx.ui.tree, n)
	return src_of(fx), lo, hi
}

@(test)
markdown_actions_wrap_the_selection_in_marks :: proc(t: ^testing.T) {
	fx: Md_Fx
	n := md_start(&fx, "some bold words")
	defer md_end(&fx)
	marks := [?]struct { action: Rich_Action, src: string } {
		{.Bold, "some **bold** words"},
		{.Italic, "some *bold* words"},
		{.Code, "some `bold` words"},
		{.Strike, "some ~~bold~~ words"},
		{.Highlight, "some ==bold== words"},
	}
	for m in marks {
		select_in(&fx, n, Pos{0, 5}, Pos{0, 9}) // "bold"
		src, lo, hi := apply(&fx, n, m.action)
		testing.expectf(t, src == m.src, "%v wraps it: %q", m.action, src)
		testing.expectf(t, src[lo.off:hi.off] == "bold", "%v keeps the selection on the text: %q", m.action, src[lo.off:hi.off])
		src, lo, hi = apply(&fx, n, m.action) // again: off
		testing.expectf(t, src == "some bold words", "%v takes it off again: %q", m.action, src)
		testing.expectf(t, src[lo.off:hi.off] == "bold", "%v still selects the text", m.action)
		testing.expectf(t, len(fx.doc.undo) > 0, "%v is undoable", m.action)
		for len(fx.doc.undo) > 0 do document_undo(&fx.doc)
		md_view(&fx)
	}

	// no selection: the word at the caret, and one undo puts the line back
	select_in(&fx, n, Pos{0, 7}, Pos{0, 7})
	src, _, _ := apply(&fx, n, .Bold)
	testing.expect_value(t, src, "some **bold** words")
	testing.expect(t, len(fx.doc.undo) > 0, "the wrap is in the history")
	document_undo(&fx.doc) // one step takes the whole action back
	md_view(&fx)
	testing.expect_value(t, src_of(&fx), "some bold words")
	testing.expect_value(t, len(fx.doc.undo), 0)
	testing.expect_value(t, fx.ui.tree.focus, fx.area) // focus goes back to the text
}

@(test)
markdown_actions_set_the_lines_prefixes :: proc(t: ^testing.T) {
	fx: Md_Fx
	n := md_start(&fx, "one\ntwo\nthree")
	defer md_end(&fx)
	cases := [?]struct { action: Rich_Action, src: string } {
		{.H2, "## one\n## two\n## three"},
		{.H1, "# one\n# two\n# three"},
		{.Bullet, "- one\n- two\n- three"},
		{.Numbered, "1. one\n2. two\n3. three"},
		{.Task, "- [ ] one\n- [ ] two\n- [ ] three"},
		{.Quote, "> one\n> two\n> three"},
	}
	for c in cases {
		select_in(&fx, n, Pos{0, 1}, Pos{2, 2})
		src, lo, hi := apply(&fx, n, c.action)
		testing.expectf(t, src == c.src, "%v: %q", c.action, src)
		testing.expectf(t, block_str(&fx.doc, lo.block)[lo.off:] == "ne" && hi.off > 0, "%v: the selection follows its text (%v, %v)", c.action, lo, hi)
		// asking again clears it (a heading of the same level too)
		src, _, _ = apply(&fx, n, c.action)
		testing.expectf(t, src == "one\ntwo\nthree", "%v again clears it: %q", c.action, src)
	}

	// Paragraph always clears, and a numbered list carries on from the item above
	select_in(&fx, n, Pos{0, 0}, Pos{2, 0})
	apply(&fx, n, .Quote)
	src, _, _ := apply(&fx, n, .Paragraph)
	testing.expect_value(t, src, "one\ntwo\nthree")
	document_set_text(&fx.doc, "3. first\ntwo\nthree")
	md_view(&fx)
	select_in(&fx, n, Pos{1, 0}, Pos{2, 0})
	src, _, _ = apply(&fx, n, .Numbered)
	testing.expect_value(t, src, "3. first\n4. two\n5. three")

	// a line inside a code block keeps its source
	document_set_text(&fx.doc, "text\n```\nx := 1\n```")
	md_view(&fx)
	select_in(&fx, n, Pos{0, 0}, Pos{3, 0})
	src, _, _ = apply(&fx, n, .Bullet)
	testing.expect_value(t, src, "- text\n```\nx := 1\n```")
}

@(test)
markdown_actions_fence_lines_and_add_a_rule :: proc(t: ^testing.T) {
	fx: Md_Fx
	n := md_start(&fx, "before\nx := 1\ny := 2\nafter")
	defer md_end(&fx)

	select_in(&fx, n, Pos{1, 0}, Pos{2, 6})
	src, lo, _ := apply(&fx, n, .Code_Block)
	testing.expect_value(t, src, "before\n```\nx := 1\ny := 2\n```\nafter")
	testing.expect(t, block_str(&fx.doc, lo.block) == "x := 1", "the selection stays on the code")
	src, _, _ = apply(&fx, n, .Code_Block) // again: the fences go
	testing.expect_value(t, src, "before\nx := 1\ny := 2\nafter")

	select_in(&fx, n, Pos{0, 6}, Pos{0, 6})
	src, lo, _ = apply(&fx, n, .Rule)
	testing.expect_value(t, src, "before\n\n---\n\nx := 1\ny := 2\nafter")
	testing.expect(t, lo == Pos{3, 0} && block_str(&fx.doc, 2) == "---", "the caret is on the empty line under the rule")
}

@(test)
markdown_actions_write_links_and_tables :: proc(t: ^testing.T) {
	fx: Md_Fx
	n := md_start(&fx, "see baldr here")
	defer md_end(&fx)

	select_in(&fx, n, Pos{0, 6}, Pos{0, 6}) // in "baldr"
	src, lo, hi := apply(&fx, n, .Link)
	testing.expect_value(t, src, "see [baldr](url) here")
	testing.expect(t, src[lo.off:hi.off] == "url", "the address is selected, so typing replaces it")
	apply(&fx, n, .Undo)

	select_in(&fx, n, Pos{0, 4}, Pos{0, 9})
	src, lo, hi = apply(&fx, n, .Image)
	testing.expect_value(t, src, "see ![baldr](url) here")
	testing.expect(t, src[lo.off:hi.off] == "url", "an image's address too")
	apply(&fx, n, .Undo)

	select_in(&fx, n, Pos{0, 0}, Pos{0, 0})
	src, lo, hi = apply(&fx, n, .Table)
	testing.expect_value(t, src, "see baldr here\n\n| Column | Column |\n|---|---|\n|  |  |")
	testing.expect(t, block_str(&fx.doc, lo.block)[lo.off:hi.off] == "Column", "the first heading cell is selected")

	// the bars' own actions belong to the rich editor; here they do nothing
	before := src_of(&fx)
	for a in ([?]Rich_Action{.Link_Apply, .Link_Remove, .Link_Close, .Image_Apply, .None}) do apply(&fx, n, a)
	testing.expect_value(t, src_of(&fx), before)
}

@(test)
markdown_actions_do_nothing_in_a_readonly_editor :: proc(t: ^testing.T) {
	fx: Md_Fx
	n := md_start(&fx, "some bold words")
	defer md_end(&fx)
	md_view(&fx, readonly = true)
	select_in(&fx, n, Pos{0, 5}, Pos{0, 9})
	for a in ([?]Rich_Action{.Bold, .Highlight, .H1, .Bullet, .Code_Block, .Rule, .Link, .Table}) {
		rich_apply(&fx.ui, n, a)
		md_view(&fx, readonly = true)
	}
	testing.expect_value(t, src_of(&fx), "some bold words")
	testing.expect_value(t, len(fx.doc.undo), 0)
}

@(test)
a_highlight_is_marks_in_markdown_and_a_wash_on_screen :: proc(t: ^testing.T) {
	ui: Ui(Md_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make("")
	defer document_destroy(&doc)
	document_set_markdown(&doc, "a ==hot== word")
	testing.expect_value(t, len(doc.blocks), 1)
	attrs, _ := document_attrs(&doc, Pos{0, 2}, Pos{0, 5})
	testing.expect(t, .Highlight in attrs, "==…== reads as a highlight")
	testing.expect_value(t, strings.trim_space(document_markdown(&doc, context.temp_allocator)), "a ==hot== word")

	// the rich editor: the toolbar's action toggles it, and the text is washed
	begin_view(&ui)
	column(&ui, padding = .lg)
	ed := rich_text(&ui, &doc, label = "Notes", width = 420, height = 200)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 600})
	area, s := editor_area(&ui.tree, ed)
	washes := 0
	pen := ui.tree.theme.color.warning
	for _, l in ui.tree.layers do for c in l.cmds do if r, ok := c.(Draw_Rect); ok && r.color.rgb == pen.rgb do washes += 1
	testing.expect(t, washes >= 1, "the highlighted words are washed")

	editor_select(&ui, ed, Pos{0, 2}, Pos{0, 5})
	rich_apply(&ui, ed, .Highlight)
	attrs, _ = document_attrs(&doc, Pos{0, 2}, Pos{0, 5})
	testing.expect(t, .Highlight not_in attrs, "the action takes it off")
	set_focus(&ui.tree, area, true)
	key_event(&ui, .H, true, {.Ctrl, .Shift})
	attrs, _ = document_attrs(&doc, Pos{0, 2}, Pos{0, 5})
	testing.expect(t, .Highlight in attrs, "Ctrl+Shift+H puts it back")
	testing.expect(t, s != nil, "the editor is there")

	// a markdown editor shows the marks dimmed only while the caret is in the line
	md := document_make("a ==hot== word\n\nnext")
	defer document_destroy(&md)
	begin_view(&ui)
	column(&ui, padding = .lg)
	live := markdown_editor(&ui, &md, label = "Live", width = 420, height = 200)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 600})
	editor_select(&ui, live, Pos{2, 0}, Pos{2, 0})
	_, ls := editor_area(&ui.tree, live)
	testing.expect_value(t, area_text(&ui.tree, ls, 0), "a hot word")
	l := area_live(&ui.tree, ls, 0)
	on := false
	for r in l.runs do if .Highlight in r.attrs do on = true
	testing.expect(t, on, "and it is highlighted")
	editor_select(&ui, live, Pos{0, 3}, Pos{0, 3})
	testing.expect_value(t, area_text(&ui.tree, ls, 0), "a ==hot== word") // edited: the source shows
}

} // when ODIN_TEST