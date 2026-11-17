package baldr

@(require) import "core:mem"
@(require) import "core:testing"
@(require) import "core:strings"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
runs_of :: proc(doc: ^Document, b: int) -> []Run { return doc.blocks[b].runs[:] }

// Attributes are runs over the text: applying one splits at the edges and
// keeps the others; typing at a run's end continues it; reporting says
// what every and any character has.
@(test)
document_runs_apply_split_and_report :: proc(t: ^testing.T) {
	doc := document_make("hello world")
	defer document_destroy(&doc)
	document_set_attrs(&doc, {0, 0}, {0, 5}, {.Bold}, {}, group = 1)
	r := runs_of(&doc, 0)
	testing.expect_value(t, len(r), 2)
	testing.expect(t, r[0].end == 5 && r[0].attrs == {.Bold} && r[1].end == 11 && r[1].attrs == {})
	document_set_attrs(&doc, {0, 3}, {0, 8}, {.Italic}, {}, group = 2)
	r = runs_of(&doc, 0)
	testing.expect_value(t, len(r), 4)
	testing.expect(t, r[0].end == 3 && r[0].attrs == {.Bold})
	testing.expect(t, r[1].end == 5 && r[1].attrs == {.Bold, .Italic})
	testing.expect(t, r[2].end == 8 && r[2].attrs == {.Italic})
	testing.expect(t, r[3].end == 11 && r[3].attrs == {})
	all, any := document_attrs(&doc, {0, 0}, {0, 5})
	testing.expect(t, all == {.Bold} && any == {.Bold, .Italic})
	all, any = document_attrs(&doc, {0, 6}, {0, 6}) // a caret inside the italic run
	testing.expect(t, all == {.Italic})
	// typing at the end of the bold run continues it; at the very start, the first run
	document_replace(&doc, {0, 3}, {0, 3}, "!", group = 3)
	r = runs_of(&doc, 0)
	testing.expect(t, r[0].end == 4 && r[0].attrs == {.Bold}, "the bold run grew")
	testing.expect_value(t, block_str(&doc, 0), "hel!lo world")
	// an explicit style cuts its own run
	document_replace(&doc, {0, 12}, {0, 12}, "?", group = 4, style = Run{attrs = {.Strike}})
	r = runs_of(&doc, 0)
	testing.expect(t, r[len(r) - 1].attrs == {.Strike} && r[len(r) - 1].end == 13)
	// removing bold everywhere keeps italic; a link carries its href
	document_set_attrs(&doc, {0, 0}, {0, 13}, {}, {.Bold}, group = 5)
	all, any = document_attrs(&doc, {0, 0}, {0, 13})
	testing.expect(t, .Bold not_in any && .Italic in any)
	document_set_attrs(&doc, {0, 0}, {0, 3}, {.Link}, {}, href = "https://odin-lang.org", group = 6)
	testing.expect_value(t, href_at(&doc, {0, 1}), "https://odin-lang.org")
	testing.expect_value(t, href_at(&doc, {0, 9}), "")
}

// Splitting and joining blocks moves runs along; undo restores the text,
// its runs and the block kinds together; redo brings them back.
@(test)
document_runs_survive_splits_joins_and_undo :: proc(t: ^testing.T) {
	doc := document_make("bold plain")
	defer document_destroy(&doc)
	document_set_attrs(&doc, {0, 0}, {0, 4}, {.Bold}, {}, group = 1)
	document_set_meta(&doc, 0, {kind = .Bullet, depth = 1}, group = 2)
	testing.expect_value(t, block_meta(&doc, 0).kind, Block_Kind.Bullet)
	// Enter inside the bold word: both halves keep bold; the new item keeps the list kind
	document_replace(&doc, {0, 2}, {0, 2}, "\n", group = 3)
	testing.expect_value(t, block_count(&doc), 2)
	testing.expect(t, runs_of(&doc, 0)[0].attrs == {.Bold} && runs_of(&doc, 0)[0].end == 2)
	r := runs_of(&doc, 1)
	testing.expect(t, r[0].end == 2 && r[0].attrs == {.Bold} && r[1].end == 8 && r[1].attrs == {})
	testing.expect(t, block_meta(&doc, 1).kind == .Bullet && block_meta(&doc, 1).depth == 1)
	// Backspace at the start of the second joins them: the runs join too
	document_replace(&doc, {0, 2}, {1, 0}, "", group = 4)
	testing.expect_value(t, block_str(&doc, 0), "bold plain")
	r = runs_of(&doc, 0)
	testing.expect(t, len(r) == 2 && r[0].end == 4 && r[0].attrs == {.Bold})
	// delete across the styled text and undo: the formatting comes back
	document_replace(&doc, {0, 1}, {0, 7}, "", group = 5)
	testing.expect_value(t, block_str(&doc, 0), "bain")
	_, ok := document_undo(&doc)
	testing.expect(t, ok)
	testing.expect_value(t, block_str(&doc, 0), "bold plain")
	r = runs_of(&doc, 0)
	testing.expect(t, len(r) == 2 && r[0].end == 4 && r[0].attrs == {.Bold}, "undo restored the bold run")
	// undo the join, the split, the kind, the bold
	document_undo(&doc)
	testing.expect_value(t, block_count(&doc), 2)
	testing.expect_value(t, block_meta(&doc, 1).kind, Block_Kind.Bullet)
	document_undo(&doc)
	testing.expect_value(t, block_count(&doc), 1)
	document_undo(&doc)
	testing.expect_value(t, block_meta(&doc, 0).kind, Block_Kind.Paragraph)
	document_undo(&doc)
	testing.expect_value(t, len(runs_of(&doc, 0)), 0)
	// redo the bold, the kind and the split: the new block is a bullet again with its bold half
	for _ in 0 ..< 3 do document_redo(&doc)
	testing.expect_value(t, block_count(&doc), 2)
	testing.expect(t, block_meta(&doc, 1).kind == .Bullet && runs_of(&doc, 1)[0].attrs == {.Bold})
	document_redo(&doc) // the join
	testing.expect_value(t, block_count(&doc), 1)
	// a heading's Enter makes a paragraph
	document_set_meta(&doc, 0, {kind = .Heading, level = 2}, group = 9)
	document_replace(&doc, {0, 2}, {0, 2}, "\n", group = 10)
	testing.expect_value(t, block_meta(&doc, 1).kind, Block_Kind.Paragraph)
}

// The rich layout wraps mixed-style text at word boundaries, keeps every
// byte's x, answers hits, and splits each line into one segment per run.
@(test)
rich_layout_wraps_runs_and_measures :: proc(t: ^testing.T) {
	ui: Ui(Cd_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	text := "bold text and plain words here"
	runs := []Run{{end = 9, attrs = {.Bold}}, {end = len(text)}}
	base := Rich_Style{size = 10} // headless: 5 px per rune
	lay := rich_layout(&ui.tree, text, runs, base, 0)
	testing.expect_value(t, len(lay.lines), 1)
	testing.expect_value(t, lay.cum[len(text)], f32(len(text)) * 5)
	testing.expect_value(t, len(lay.lines[0].segs), 2)
	testing.expect(t, lay.lines[0].segs[0].end == 9 && lay.lines[0].segs[1].start == 9 && lay.lines[0].segs[1].x == 45)
	testing.expect(t, lay.styles[0].bold && !lay.styles[1].bold)
	// 80 px wide: "bold text and " (14 runes = 70) fits, "plain" would not
	lay = rich_layout(&ui.tree, text, runs, base, 80)
	testing.expect_value(t, len(lay.lines), 2)
	testing.expect_value(t, lay.lines[0].end, 14)
	testing.expect_value(t, lay.lines[0].width, f32(13) * 5) // the trailing space is forgiven
	testing.expect_value(t, lay.lines[1].start, 14)
	testing.expect_value(t, rich_line_of(&lay, 14, len(text)), 1)
	testing.expect_value(t, rich_line_of(&lay, 13, len(text)), 0)
	testing.expect_value(t, rich_x(&lay, 1, 19), f32(25))
	testing.expect_value(t, rich_hit(&lay, text, 1, 27), 19) // 27 px is nearest the 5th boundary
	// a word wider than the line is cut at a grapheme
	lay = rich_layout(&ui.tree, "abcdefghijklmnop", nil, base, 30)
	testing.expect(t, len(lay.lines) >= 3 && lay.lines[0].end == 6)
	// mono runs take the code face
	lay = rich_layout(&ui.tree, "x code y", []Run{{end = 2}, {end = 6, attrs = {.Code}}, {end = 8}}, base, 0)
	testing.expect(t, lay.styles[1].mono && !lay.styles[0].mono)
}


Rt_Msg :: struct { version: int, href: string }

@(private = "file")
on_rt :: proc(e: Ev(int)) -> Rt_Msg { return {version = e.value} }
@(private = "file")
on_href :: proc(e: Ev(string)) -> Rt_Msg { return {href = e.value} }

@(private = "file")
Rt_Fx :: struct {
	ui:  Ui(Rt_Msg),
	doc: Document,
}

@(private = "file")
rt_view :: proc(fx: ^Rt_Fx) -> (fr, area: Node) {
	ui := &fx.ui
	set_viewport(&ui.tree, {600, 500})
	begin_view(ui)
	column(ui, padding = .lg)
	fr = rich_text(ui, &fx.doc, on_rt, label = "Notes", height = 300, on_link = on_href)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 500})
	area = ui.tree.area_of_frame[fr]
	return
}

// The rich editor is a Text_Input under a Toolbar of named toggle
// buttons that reflect the selection; Ctrl+B over a selection bolds it,
// at a caret it pends for the next typing; a toolbar button does the same
// through a click.
@(test)
rich_text_formats_by_key_and_toolbar :: proc(t: ^testing.T) {
	fx: Rt_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	fx.doc = document_make("hello world")
	defer document_destroy(&fx.doc)
	_, area := rt_view(&fx)
	dump := access_dump(&fx.ui.tree)
	testing.expect(t, strings.contains(dump, "Toolbar \"Formatting\"") && strings.contains(dump, "Button \"Bold\"") && strings.contains(dump, "Button \"Heading 1\"") && strings.contains(dump, "Text_Input \"Notes\""), dump)
	testing.expect_value(t, lint(&fx.ui.tree), 0)
	s := &fx.ui.tree.areas[area]
	set_focus(&fx.ui.tree, area, true)
	s.anchor, s.caret = {0, 0}, {0, 5}
	testing.expect(t, key_event(&fx.ui, .B, true, {.Ctrl}))
	all, _ := document_attrs(&fx.doc, {0, 0}, {0, 5})
	testing.expect(t, all == {.Bold})
	testing.expect(t, len(fx.ui.msgs) > 0, "on_change fired")
	fx.ui.needs_rebuild = false
	rt_view(&fx)
	// the Bold button shows pressed while the selection is bold
	pressed := false
	for n, a in fx.ui.tree.editor_ctl_of {
		if a != area do continue
		d := node_get(&fx.ui.tree, n)
		if d != nil && d.access.name == "Bold" && .Pressed in d.access.states do pressed = true
	}
	testing.expect(t, pressed, "the Bold toggle reflects the selection")
	// pending: a caret, Ctrl+I, then typing
	s.anchor, s.caret = {0, 11}, {0, 11}
	key_event(&fx.ui, .I, true, {.Ctrl})
	testing.expect(t, s.rich_state.pending_valid && .Italic in s.rich_state.pending)
	text_area_text(&fx.ui, "!")
	testing.expect_value(t, attrs_at(&fx.doc, {0, 12}), Attrs{.Italic})
	testing.expect(t, !s.rich_state.pending_valid, "spent")
	// a toolbar click: Heading 1 on the caret's block
	h1 := NODE_NONE
	for n, a in fx.ui.tree.editor_ctl_of {
		if a != area do continue
		if d := node_get(&fx.ui.tree, n); d != nil && d.access.name == "Heading 1" do h1 = n
	}
	testing.expect(t, h1 != NODE_NONE)
	click(&fx.ui, h1)
	testing.expect(t, block_meta(&fx.doc, 0).kind == .Heading && block_meta(&fx.doc, 0).level == 1)
	// the heading paints in the headline size, bold; the italic run in the italic face
	rt_view(&fx)
	saw_big, saw_italic := false, false
	for _, l in fx.ui.tree.layers do for c in l.cmds {
		if dt, ok := c.(Draw_Text); ok {
			if (dt.weight == .Semibold) && dt.size == fx.ui.tree.theme.type.headline.size do saw_big = true
			if dt.italic && dt.str == "!" do saw_italic = true
		}
	}
	testing.expect(t, saw_big && saw_italic)
}

// Lists: "- " at the start of a line makes a bullet, Enter continues the
// list, Enter on an empty item leaves it, Tab nests, Backspace at the
// start turns an item back into a paragraph; a task's box toggles on a
// click; a link applied through the bar is followed with Ctrl+click.
@(test)
rich_text_lists_tasks_and_links :: proc(t: ^testing.T) {
	fx: Rt_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	fx.doc = document_make("")
	defer document_destroy(&fx.doc)
	_, area := rt_view(&fx)
	s := &fx.ui.tree.areas[area]
	set_focus(&fx.ui.tree, area, true)
	text_area_text(&fx.ui, "-")
	text_area_text(&fx.ui, " ")
	testing.expect_value(t, block_meta(&fx.doc, 0).kind, Block_Kind.Bullet)
	testing.expect_value(t, block_str(&fx.doc, 0), "")
	text_area_text(&fx.ui, "one")
	key_event(&fx.ui, .Enter, true, {})
	testing.expect_value(t, block_meta(&fx.doc, 1).kind, Block_Kind.Bullet)
	key_event(&fx.ui, .Tab, true, {})
	testing.expect_value(t, block_meta(&fx.doc, 1).depth, u8(1))
	text_area_text(&fx.ui, "two")
	key_event(&fx.ui, .Enter, true, {})
	key_event(&fx.ui, .Enter, true, {}) // empty item: leaves the list
	testing.expect_value(t, block_meta(&fx.doc, 2).kind, Block_Kind.Paragraph)
	area_move(&fx.ui.tree, area, s, {1, 0}, false)
	key_event(&fx.ui, .Backspace, true, {})
	testing.expect_value(t, block_meta(&fx.doc, 1).kind, Block_Kind.Paragraph)
	// a task list from the toolbar, ticked by a click in its margin
	rich_act(&fx.ui, area, s, .Task)
	testing.expect_value(t, block_meta(&fx.doc, 1).kind, Block_Kind.Task)
	fx.ui.needs_rebuild = false
	rt_view(&fx)
	d := node_get(&fx.ui.tree, area)
	inner := input_inner(d)
	y := inner.y + block_text_top(&fx.ui.tree, s, 1) + area_line_h(&fx.ui.tree, s, 1) / 2
	pointer_button(&fx.ui, .Left, true, {inner.x + 6, y})
	pointer_button(&fx.ui, .Left, false, {inner.x + 6, y})
	testing.expect(t, block_meta(&fx.doc, 1).checked, "the box is ticked")
	// a link on "two" through the bar, then Ctrl+click follows it
	s.anchor, s.caret = {1, 0}, {1, 3}
	key_event(&fx.ui, .K, true, {.Ctrl})
	testing.expect(t, s.rich_state.link_open)
	rt_view(&fx)
	testing.expect(t, strings.contains(access_dump(&fx.ui.tree), "Text_Input \"Link address\""))
	set_focus(&fx.ui.tree, s.rich_state.link_field, true)
	text_event(&fx.ui, "https://example.org")
	key_event(&fx.ui, .Enter, true, {})
	testing.expect_value(t, href_at(&fx.doc, {1, 1}), "https://example.org")
	testing.expect(t, !s.rich_state.link_open && fx.ui.tree.focus == area)
	rt_view(&fx)
	x := inner.x + block_indent(&fx.ui.tree, s, 1) + 4
	fx.ui.pointer.mods = {.Ctrl}
	pointer_button(&fx.ui, .Left, true, {x, y})
	pointer_button(&fx.ui, .Left, false, {x, y})
	fx.ui.pointer.mods = {}
	testing.expect_value(t, fx.ui.msgs[len(fx.ui.msgs) - 1].href, "https://example.org")
}

// Markdown round-trips: headings, lists (nested, tasks), quotes, fenced
// code, rules and inline marks come in as blocks and runs and go out the
// same; the markdown tokenizer colours the source.
@(test)
markdown_round_trips :: proc(t: ^testing.T) {
	md := "# Title\n\nSome **bold** and *italic* with `code` and a [link](https://x.y).\n\n- one\n  - nested\n- [x] done\n1. first\n\n> quoted\n\n```odin\nx := 1\n```\n\n---\n"
	doc := document_make("")
	defer document_destroy(&doc)
	document_set_markdown(&doc, md)
	testing.expect_value(t, block_meta(&doc, 0).kind, Block_Kind.Heading)
	testing.expect_value(t, block_str(&doc, 0), "Title")
	testing.expect_value(t, block_str(&doc, 1), "Some bold and italic with code and a link.")
	all, _ := document_attrs(&doc, {1, 5}, {1, 9})
	testing.expect(t, all == {.Bold})
	all, _ = document_attrs(&doc, {1, 14}, {1, 20})
	testing.expect(t, all == {.Italic})
	all, _ = document_attrs(&doc, {1, 26}, {1, 30})
	testing.expect(t, all == {.Code})
	testing.expect_value(t, href_at(&doc, {1, 38}), "https://x.y")
	testing.expect(t, block_meta(&doc, 2).kind == .Bullet && block_meta(&doc, 3).kind == .Bullet && block_meta(&doc, 3).depth == 1)
	testing.expect(t, block_meta(&doc, 4).kind == .Task && block_meta(&doc, 4).checked)
	testing.expect_value(t, block_meta(&doc, 5).kind, Block_Kind.Numbered)
	testing.expect_value(t, block_meta(&doc, 6).kind, Block_Kind.Quote)
	testing.expect(t, block_meta(&doc, 7).kind == .Code && block_meta(&doc, 7).lang == "odin" && block_str(&doc, 7) == "x := 1")
	testing.expect_value(t, block_meta(&doc, 8).kind, Block_Kind.Rule)
	out := document_markdown(&doc, context.temp_allocator)
	testing.expect_value(t, out, md)
	toks := make([dynamic]Token, context.temp_allocator)
	st := tokenize_line(&LANG_MARKDOWN, "- **bold** and `x`", 0, &toks)
	testing.expect(t, st == 0 && toks[0].kind == .Keyword && toks[1].kind == .Operator && toks[len(toks) - 1].kind == .String)
	st = tokenize_line(&LANG_MARKDOWN, "```odin", 0, &toks)
	testing.expect_value(t, st, LINE_IN_COMMENT)
}

// Marks obey flanking: an underscore inside a word and a star between
// spaces are text; a link's label keeps its own marks; the toolbar
// follows a caret move without a rebuild being asked for; typing into a
// rule makes it a paragraph.
@(test)
rich_text_edges :: proc(t: ^testing.T) {
	doc := document_make("")
	defer document_destroy(&doc)
	document_set_markdown(&doc, "snake_case and 2 * 3 stay, *this* is italic, [**bold link**](https://l.ink) here")
	testing.expect_value(t, block_str(&doc, 0), "snake_case and 2 * 3 stay, this is italic, bold link here")
	all, any := document_attrs(&doc, {0, 0}, {0, 25})
	testing.expect(t, any == {}, "no marks in the plain part")
	all, _ = document_attrs(&doc, {0, 27}, {0, 31})
	testing.expect(t, all == {.Italic})
	all, _ = document_attrs(&doc, {0, 43}, {0, 52})
	testing.expect(t, all == {.Bold, .Link})
	testing.expect_value(t, href_at(&doc, {0, 45}), "https://l.ink")
	testing.expect_value(t, document_markdown(&doc, context.temp_allocator), "snake\\_case and 2 \\* 3 stay, *this* is italic, [**bold link**](https://l.ink) here\n")
	// escaped text reads back as itself, block prefixes included
	document_set_text(&doc, "- not a list\n2. step\nuse *args and `ls`")
	md := document_markdown(&doc, context.temp_allocator)
	back := document_make("")
	defer document_destroy(&back)
	document_set_markdown(&back, md)
	testing.expect_value(t, document_text(&back, context.temp_allocator), "- not a list\n2. step\nuse *args and `ls`")
	testing.expect(t, block_meta(&back, 0).kind == .Paragraph && block_meta(&back, 1).kind == .Paragraph && len(back.blocks[2].runs) == 0)
	// a styled run with a trailing space keeps the space outside the marks
	document_set_text(&doc, "bold rest")
	document_set_attrs(&doc, {0, 0}, {0, 5}, {.Bold}, {}, group = 1)
	testing.expect_value(t, document_markdown(&doc, context.temp_allocator), "**bold** rest\n")
	document_set_markdown(&back, "**bold** rest")
	all2, _ := document_attrs(&back, {0, 0}, {0, 4})
	testing.expect(t, all2 == {.Bold})
	all2, _ = document_attrs(&back, {0, 5}, {0, 9})
	testing.expect(t, all2 == {})
	// the toolbar follows the caret
	fx: Rt_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	fx.doc = document_make("bold plain\n")
	defer document_destroy(&fx.doc)
	document_set_attrs(&fx.doc, {0, 0}, {0, 4}, {.Bold}, {}, group = 1)
	document_set_meta(&fx.doc, 1, {kind = .Rule}, group = 2)
	_, area := rt_view(&fx)
	s := &fx.ui.tree.areas[area]
	set_focus(&fx.ui.tree, area, true)
	area_move(&fx.ui.tree, area, s, {0, 2}, false)
	fx.ui.needs_rebuild = false
	ui_after_events(&fx.ui, 10)
	testing.expect(t, fx.ui.needs_rebuild, "a caret move asks for the toolbar to follow")
	// typing into the rule turns it into a paragraph holding the text
	area_move(&fx.ui.tree, area, s, {1, 0}, false)
	text_area_text(&fx.ui, "x")
	testing.expect_value(t, block_meta(&fx.doc, 1).kind, Block_Kind.Paragraph)
	testing.expect_value(t, block_str(&fx.doc, 1), "x")
}

// Text never lands in a rule (join, delete, paste turn it
// into the joined block's shape); plain text re-inserted by undo stays
// plain next to a bold run; a nested bullet does not restart numbering;
// typing after a toolbar action is its own undo step; the toolbar works
// on the first frame after a rebuild; a readonly editor ignores shortcuts.
@(test)
rich_text_review_fixes :: proc(t: ^testing.T) {
	doc := document_make("a\n\nhello")
	defer document_destroy(&doc)
	document_set_meta(&doc, 1, {kind = .Rule}, group = 1)
	document_replace(&doc, {1, 0}, {2, 0}, "", group = 2) // Backspace at the start of "hello": the rule goes, hello stays
	testing.expect_value(t, block_count(&doc), 2)
	testing.expect(t, block_meta(&doc, 1).kind == .Paragraph && block_str(&doc, 1) == "hello")
	document_set_text(&doc, "a\n")
	document_set_meta(&doc, 1, {kind = .Rule}, group = 3)
	document_replace(&doc, {1, 0}, {1, 0}, "typed", group = 4) // paste / typing onto a rule
	testing.expect(t, block_meta(&doc, 1).kind == .Paragraph && block_str(&doc, 1) == "typed")
	_, ok := document_undo(&doc)
	testing.expect(t, ok && block_meta(&doc, 1).kind == .Rule && block_str(&doc, 1) == "", "one undo restores the rule")
	// plain text next to bold comes back plain
	document_set_text(&doc, "hello world")
	document_set_attrs(&doc, {0, 0}, {0, 5}, {.Bold}, {}, group = 5)
	document_replace(&doc, {0, 5}, {0, 11}, "", group = 6)
	document_undo(&doc)
	all, _ := document_attrs(&doc, {0, 5}, {0, 11})
	testing.expect(t, all == {}, "the re-inserted text is plain")
	// numbering across a nested bullet
	document_set_markdown(&doc, "1. a\n  - b\n2. c")
	testing.expect_value(t, numbered_index(&doc, 2), 2)
	testing.expect_value(t, document_markdown(&doc, context.temp_allocator), "1. a\n  - b\n2. c\n")
	// the editor: an action, then typing, then one undo takes back only the typing
	fx: Rt_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	fx.doc = document_make("word here")
	defer document_destroy(&fx.doc)
	_, area := rt_view(&fx)
	s := &fx.ui.tree.areas[area]
	// the toolbar is wired on the first frame: the builder asks for the rebuild itself
	testing.expect(t, fx.ui.needs_rebuild, "first build asks for a rebuild to wire the toolbar")
	fx.ui.needs_rebuild = false
	rt_view(&fx)
	wired := 0
	for _, a in fx.ui.tree.editor_ctl_of do if a == area do wired += 1
	testing.expect(t, wired >= 18, "every toolbar button reaches the editor")
	set_focus(&fx.ui.tree, area, true)
	s.anchor, s.caret = {0, 0}, {0, 4}
	key_event(&fx.ui, .B, true, {.Ctrl})
	s.anchor, s.caret = {0, 4}, {0, 4}
	text_area_text(&fx.ui, "s")
	key_event(&fx.ui, .Z, true, {.Ctrl})
	testing.expect_value(t, block_str(&fx.doc, 0), "word here")
	all, _ = document_attrs(&fx.doc, {0, 0}, {0, 4})
	testing.expect(t, all == {.Bold}, "the bold survived the undo of the typing")
	// the tick asks once for a stale toolbar, not every wake-up
	fx.ui.needs_rebuild = false
	area_move(&fx.ui.tree, area, s, {0, 7}, false)
	ui_after_events(&fx.ui, 10)
	testing.expect(t, fx.ui.needs_rebuild)
	fx.ui.needs_rebuild = false
	ui_after_events(&fx.ui, 20) // no builder ran: the same request is not repeated
	testing.expect(t, !fx.ui.needs_rebuild, "a skipped rebuild does not spin")
}

// A toolbar click keeps the selection: it stays painted while the button
// has focus, and focus returns to the text afterwards so the next action
// or keystroke applies to the same range.
@(test)
rich_text_toolbar_keeps_the_selection :: proc(t: ^testing.T) {
	fx: Rt_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	fx.doc = document_make("select me please")
	defer document_destroy(&fx.doc)
	rt_view(&fx)
	fx.ui.needs_rebuild = false
	_, area := rt_view(&fx)
	s := &fx.ui.tree.areas[area]
	set_focus(&fx.ui.tree, area, true)
	s.anchor, s.caret = {0, 0}, {0, 6}
	bold := NODE_NONE
	for n, a in fx.ui.tree.editor_ctl_of {
		if a != area do continue
		if d := node_get(&fx.ui.tree, n); d != nil && d.access.name == "Bold" do bold = n
	}
	testing.expect(t, bold != NODE_NONE)
	// with focus on the button (a press moves it there), the selection is still painted
	set_focus(&fx.ui.tree, bold, false)
	frame(&fx.ui.tree, {600, 500})
	sel, _ := selection_pair(&fx.ui.tree.theme) // the band a selection draws (selection_paint.odin)
	painted := false
	for _, l in fx.ui.tree.layers do for c in l.cmds do if r, ok := c.(Draw_Rect); ok && r.color == sel do painted = true
	testing.expect(t, painted, "the selection stays visible while a toolbar button has focus")
	// the click applies bold, keeps the range, and hands focus back to the text
	click(&fx.ui, bold)
	all, _ := document_attrs(&fx.doc, {0, 0}, {0, 6})
	testing.expect(t, all == {.Bold})
	testing.expect(t, s.anchor == Pos{0, 0} && s.caret == Pos{0, 6}, "the selection is unchanged")
	testing.expect_value(t, fx.ui.tree.focus, area)
	// a second action lands on the same range
	key_event(&fx.ui, .I, true, {.Ctrl})
	all, _ = document_attrs(&fx.doc, {0, 0}, {0, 6})
	testing.expect(t, all == {.Bold, .Italic})
}

// The live renderer drops marks and keeps a map back to the source, or
// keeps them dimmed for the block being edited; fences make code lines.
@(test)
markdown_render_line_maps_display_to_source :: proc(t: ^testing.T) {
	l := markdown_render_line("## Big **bold** [x](https://u)", false, false)
	testing.expect_value(t, l.text, "Big bold x")
	testing.expect(t, l.meta.kind == .Heading && l.meta.level == 2)
	testing.expect_value(t, l.src[0], 3)   // "B" came from after "## "
	testing.expect_value(t, l.src[4], 9)   // "b" of bold, after "**"
	testing.expect_value(t, l.src[9], 17)  // "x" inside the brackets
	testing.expect_value(t, l.src[len(l.text)], len("## Big **bold** [x](https://u)"))
	testing.expect_value(t, len(l.runs), 4) // "Big ", "bold", " ", "x"
	testing.expect(t, l.runs[1].attrs == {.Bold} && .Link in l.runs[3].attrs && l.runs[3].href == "https://u")
	raw := markdown_render_line("## Big **bold**", false, true)
	testing.expect_value(t, raw.text, "## Big **bold**")
	testing.expect(t, .Mark in raw.runs[0].attrs, "the prefix is a mark")
	testing.expect_value(t, raw.src[3], 3) // identity
	code := markdown_render_line("x := 1", true, false)
	testing.expect(t, code.meta.kind == .Code && code.in_fence && code.text == "x := 1")
	fence := markdown_render_line("```odin", false, false)
	testing.expect(t, fence.meta.kind == .Code && .Mark in fence.runs[0].attrs)
}

@(private = "file")
live_view :: proc(fx: ^Rt_Fx) -> Node {
	ui := &fx.ui
	set_viewport(&ui.tree, {600, 500})
	begin_view(ui)
	column(ui, padding = .lg)
	a := markdown_editor(ui, &fx.doc, on_rt, label = "Notes", height = 300, on_link = on_href)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 500})
	return a
}

// The live editor renders every block but the caret's: a heading line
// shows without its "# ", the caret's block shows its source; a click on
// a rendered word lands the caret at the right source byte; Enter after
// a list item continues the list and on an empty item ends it; Ctrl+B
// wraps and unwraps; a click on a task's box flips it in the source;
// Ctrl+click on a rendered link follows it.
@(test)
markdown_editor_live_preview :: proc(t: ^testing.T) {
	fx: Rt_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	fx.doc = document_make("# Title\nplain **bold** text\n- item\n- [ ] task\n[go](https://l.ink)")
	defer document_destroy(&fx.doc)
	area := live_view(&fx)
	s := &fx.ui.tree.areas[area]
	testing.expect(t, s.live && s.rich)
	testing.expect_value(t, node_get(&fx.ui.tree, area).access.role, Role.Text_Input)
	set_focus(&fx.ui.tree, area, true)
	// the caret is in block 0: it shows raw; block 1 renders without marks
	testing.expect_value(t, area_text(&fx.ui.tree, s, 0), "# Title")
	testing.expect_value(t, area_text(&fx.ui.tree, s, 1), "plain bold text")
	testing.expect_value(t, area_meta(&fx.ui.tree, s, 0).kind, Block_Kind.Heading)
	area_move(&fx.ui.tree, area, s, {1, 0}, false)
	testing.expect_value(t, area_text(&fx.ui.tree, s, 0), "Title")
	testing.expect_value(t, area_text(&fx.ui.tree, s, 1), "plain **bold** text")
	// a click on the rendered "bold" of block 1 (from another block) lands inside the source's **
	area_move(&fx.ui.tree, area, s, {0, 0}, false)
	frame(&fx.ui.tree, {600, 500})
	d := node_get(&fx.ui.tree, area)
	inner := input_inner(d)
	y := inner.y + block_text_top(&fx.ui.tree, s, 1) + area_line_h(&fx.ui.tree, s, 1) / 2
	x := inner.x + span_x_disp(&fx.ui.tree, s, 1, block_spans(&fx.ui.tree, s, 1)[0], 7) // after "plain b" in display
	testing.expect_value(t, to_src(&fx.ui.tree, s, 1, 7), 9)
	pointer_button(&fx.ui, .Left, true, {x, y})
	pointer_button(&fx.ui, .Left, false, {x, y})
	testing.expect_value(t, s.caret, Pos{1, 9}) // "plain **b" in the source
	// Enter after the list item continues it; on the empty item, ends it
	area_move(&fx.ui.tree, area, s, {2, 6}, false)
	key_event(&fx.ui, .Enter, true, {})
	testing.expect_value(t, block_str(&fx.doc, 3), "- ")
	key_event(&fx.ui, .Enter, true, {})
	testing.expect_value(t, block_str(&fx.doc, 3), "")
	// Ctrl+B wraps the word, again unwraps
	area_move(&fx.ui.tree, area, s, {1, 1}, false)
	key_event(&fx.ui, .B, true, {.Ctrl})
	testing.expect_value(t, block_str(&fx.doc, 1), "**plain** **bold** text")
	key_event(&fx.ui, .B, true, {.Ctrl})
	testing.expect_value(t, block_str(&fx.doc, 1), "plain **bold** text")
	// the task's box (block 4 now) flips in the source on a click in its margin
	area_move(&fx.ui.tree, area, s, {0, 0}, false)
	frame(&fx.ui.tree, {600, 500})
	ty := inner.y + block_text_top(&fx.ui.tree, s, 4) + area_line_h(&fx.ui.tree, s, 4) / 2
	pointer_button(&fx.ui, .Left, true, {inner.x + 6, ty})
	pointer_button(&fx.ui, .Left, false, {inner.x + 6, ty})
	testing.expect_value(t, block_str(&fx.doc, 4), "- [x] task")
	// Ctrl+click on the rendered link (block 5)
	area_move(&fx.ui.tree, area, s, {0, 0}, false)
	frame(&fx.ui.tree, {600, 500})
	ly := inner.y + block_text_top(&fx.ui.tree, s, 5) + area_line_h(&fx.ui.tree, s, 5) / 2
	fx.ui.pointer.mods = {.Ctrl}
	pointer_button(&fx.ui, .Left, true, {inner.x + 4, ly})
	pointer_button(&fx.ui, .Left, false, {inner.x + 4, ly})
	fx.ui.pointer.mods = {}
	testing.expect_value(t, fx.ui.msgs[len(fx.ui.msgs) - 1].href, "https://l.ink")
	testing.expect_value(t, lint(&fx.ui.tree), 0)
}

// Image blocks: "![alt](src)" parses to an Image block with its source and
// alt text and prints back; the rich editor draws the picture the app
// resolves (or a placeholder with the source's name) with the alt as a
// caption; the live view renders it too, and shows the source line when
// the caret is on it; blank source lines take half a line.
@(test)
rich_text_images_and_live_gaps :: proc(t: ^testing.T) {
	doc := document_make("")
	defer document_destroy(&doc)
	document_set_markdown(&doc, "# Title\n\n![A cat](cat.png)\n\ntext")
	testing.expect_value(t, block_count(&doc), 3) // blank lines are gaps, not blocks
	testing.expect(t, block_meta(&doc, 1).kind == .Image && block_meta(&doc, 1).src == "cat.png" && block_str(&doc, 1) == "A cat")
	testing.expect_value(t, document_markdown(&doc, context.temp_allocator), "# Title\n\n![A cat](cat.png)\n\ntext\n")
	// the rich editor with a resolver
	fx: Rt_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	fx.doc = document_make("")
	defer document_destroy(&fx.doc)
	document_set_markdown(&fx.doc, "before\n![A cat](cat.png)\nafter")
	pixels := make([]u8, 200 * 100 * 4, context.temp_allocator)
	cat, okimg := image_from_rgba(200, 100, pixels)
	testing.expect(t, okimg)
	defer image_destroy(&cat)
	@(static) the_cat: ^Image
	the_cat = &cat
	defer the_cat = nil // a static outlives `cat`: cleared before it goes
	resolve :: proc(src: string) -> ^Image { return the_cat if src == "cat.png" else nil }
	fr, area := rt_view(&fx)
	editor_images(&fx.ui, fr, resolve)
	fx.ui.needs_rebuild = false
	rt_view(&fx)
	s := &fx.ui.tree.areas[area]
	drew := false
	for _, l in fx.ui.tree.layers do for c in l.cmds do if di, ok := c.(Draw_Image); ok && di.img == &cat do drew = true
	testing.expect(t, drew, "the resolved picture is drawn")
	testing.expect(t, block_height(&fx.ui.tree, s, 1) > area_line_h(&fx.ui.tree, s, 1) * 2, "the image block is taller than a line")
	// without a resolver: a placeholder carrying the source
	editor_images(&fx.ui, fr, nil)
	rt_view(&fx)
	named := false
	for _, l in fx.ui.tree.layers do for c in l.cmds do if dt, ok := c.(Draw_Text); ok && dt.str == "cat.png" do named = true
	testing.expect(t, named, "the placeholder names the source")
	// live view: blank lines are half a line, the image renders, the raw line shows under the caret
	lv: Rt_Fx
	ui_init(&lv.ui)
	defer ui_destroy(&lv.ui)
	lv.doc = document_make("a\n\n![A cat](cat.png)\nb")
	defer document_destroy(&lv.doc)
	larea := live_view(&lv)
	ls := &lv.ui.tree.areas[larea]
	set_focus(&lv.ui.tree, larea, true)
	testing.expect_value(t, area_meta(&lv.ui.tree, ls, 2).kind, Block_Kind.Image)
	testing.expect_value(t, area_text(&lv.ui.tree, ls, 2), "A cat")
	testing.expect(t, block_height(&lv.ui.tree, ls, 1) < area_line_h(&lv.ui.tree, ls, 1), "a blank line is a gap")
	area_move(&lv.ui.tree, larea, ls, {2, 0}, false)
	testing.expect_value(t, area_text(&lv.ui.tree, ls, 2), "![A cat](cat.png)")
}


// Undo brings an image back with its source; an image
// line must stand alone; alt text with "]" round-trips; Ctrl+click only
// fires for the run under the pointer; list keys do nothing inside a
// fence; inserting an image or a rule after a rule keeps the rule.
@(test)
rich_text_review_fixes_2 :: proc(t: ^testing.T) {
	doc := document_make("")
	defer document_destroy(&doc)
	document_set_markdown(&doc, "a\n![pic](p.png)\nb")
	document_replace(&doc, {0, 1}, {2, 0}, "", group = 1)
	testing.expect_value(t, block_count(&doc), 1)
	document_undo(&doc)
	testing.expect(t, block_meta(&doc, 1).kind == .Image && block_meta(&doc, 1).src == "p.png", "undo restores the source")
	ml := markdown_line("![logo](logo.png) (see fig. 1)")
	testing.expect(t, ml.meta.kind == .Paragraph, "text after an image is not an image block")
	ml = markdown_line("![a](b.png)")
	testing.expect(t, ml.meta.kind == .Image && ml.meta.src == "b.png" && ml.alt == "a")
	document_set_text(&doc, "x")
	document_set_meta(&doc, 0, {kind = .Image, src = "x.png"}, group = 2)
	document_replace(&doc, {0, 0}, {0, 1}, "a]b", group = 3)
	md := document_markdown(&doc, context.temp_allocator)
	back := document_make("")
	defer document_destroy(&back)
	document_set_markdown(&back, md)
	testing.expect(t, block_meta(&back, 0).kind == .Image && block_str(&back, 0) == "a]b", md)
	// a rule stays when an image or another rule is inserted after it
	document_set_text(&doc, "a\n")
	document_set_meta(&doc, 1, {kind = .Rule}, group = 4)
	document_replace(&doc, {1, 0}, {1, 0}, "\n\n", group = 5)
	testing.expect(t, block_meta(&doc, 1).kind == .Rule && block_count(&doc) == 4)
	// the live editor: Ctrl+click on plain text before a link does nothing; Enter in a fence is plain
	fx: Rt_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	fx.doc = document_make("plain text then [a link](http://x)\n```\n- foo\n```")
	defer document_destroy(&fx.doc)
	area := live_view(&fx)
	s := &fx.ui.tree.areas[area]
	set_focus(&fx.ui.tree, area, true)
	area_move(&fx.ui.tree, area, s, {3, 0}, false)
	d := node_get(&fx.ui.tree, area)
	inner := input_inner(d)
	y := inner.y + block_text_top(&fx.ui.tree, s, 0) + area_line_h(&fx.ui.tree, s, 0) / 2
	fx.ui.pointer.mods = {.Ctrl}
	pointer_button(&fx.ui, .Left, true, {inner.x + 4, y})
	pointer_button(&fx.ui, .Left, false, {inner.x + 4, y})
	fx.ui.pointer.mods = {}
	testing.expect(t, len(fx.ui.msgs) == 0 || fx.ui.msgs[len(fx.ui.msgs) - 1].href == "", "no link under the click")
	area_move(&fx.ui.tree, area, s, {2, 5}, false)
	key_event(&fx.ui, .Enter, true, {})
	testing.expect_value(t, block_str(&fx.doc, 3), "") // a plain new line, no "- " marker
	testing.expect_value(t, block_str(&fx.doc, 4), "```")
}

// Tables in markdown: rows are Table blocks, the separator marks the
// header row, cells split on pipes with their marks, and it prints back.
@(test)
markdown_tables_round_trip :: proc(t: ^testing.T) {
	md := "| Name | **Age** |\n|---|---|\n| Ann | 41 |\n| Bo | 7 |\n"
	doc := document_make("")
	defer document_destroy(&doc)
	document_set_markdown(&doc, md)
	testing.expect_value(t, block_count(&doc), 3)
	testing.expect(t, block_meta(&doc, 0).kind == .Table && block_meta(&doc, 0).level == 1)
	testing.expect(t, block_meta(&doc, 1).kind == .Table && block_meta(&doc, 1).level == 0)
	testing.expect_value(t, block_str(&doc, 0), "| Name | Age |")
	all, _ := document_attrs(&doc, {0, 9}, {0, 12})
	testing.expect(t, all == {.Bold})
	cells := table_cells(block_str(&doc, 2))
	testing.expect_value(t, len(cells), 2)
	testing.expect(t, block_str(&doc, 2)[cells[0][0]:cells[0][1]] == "Bo" && block_str(&doc, 2)[cells[1][0]:cells[1][1]] == "7")
	testing.expect_value(t, document_markdown(&doc, context.temp_allocator), md)
	testing.expect(t, table_sep_line("|:---|---:|") && !table_sep_line("| a |"))
	// the live renderer keeps the pipes as marks and reads the cells' marks
	l := markdown_render_line("| **b** | c |", false, false)
	testing.expect_value(t, l.text, "| b | c |")
	testing.expect_value(t, l.meta.kind, Block_Kind.Table)
	testing.expect(t, .Mark in l.runs[0].attrs && l.runs[0].end == 1)
	testing.expect(t, .Bold in l.runs[2].attrs || .Bold in l.runs[1].attrs)
}

// Tables in the editors: cells sit on shared columns (a header row
// tinted, borders drawn), the pipes are hidden in the rich view and
// dimmed in the raw live row, Tab steps between cells and adds a row
// past the last, Enter adds a row, the toolbar inserts a table.
@(test)
rich_text_tables :: proc(t: ^testing.T) {
	fx: Rt_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	fx.doc = document_make("")
	defer document_destroy(&fx.doc)
	document_set_markdown(&fx.doc, "| Name | Age |\n|---|---|\n| Ann | 41 |\nafter")
	fr, area := rt_view(&fx)
	s := &fx.ui.tree.areas[area]
	set_focus(&fx.ui.tree, area, true)
	cols := area_table_cols(&fx.ui.tree, s, 0)
	testing.expect_value(t, len(cols), 3)
	testing.expect(t, cols[1] > cols[0] && cols[2] > cols[1])
	lay := area_rich(&fx.ui.tree, s, 1)
	testing.expect_value(t, len(lay.lines), 1)
	testing.expect_value(t, lay.cum[2], cols[0] + TABLE_CELL_PAD) // "Ann" starts at the first column, padded
	// "41" is a column of figures, so it is set to the right of its column:
	// its last digit lands on the column's right edge, and it therefore
	// starts *after* the column does.
	testing.expect(t, lay.cum[10] <= cols[2] - TABLE_CELL_PAD + 0.5 && lay.cum[10] >= cols[2] - TABLE_CELL_PAD - 0.5,
		"41 ends at the right edge of the second column")
	testing.expect(t, lay.cum[8] > cols[1] + TABLE_CELL_PAD, "…so it does not start at its left edge")
	for seg in lay.lines[0].segs do testing.expect(t, block_str(&fx.doc, 1)[seg.start] != '|', "no pipe is drawn in the rich view")
	testing.expect(t, area_line_h(&fx.ui.tree, s, 1) > s.line_h, "rows are padded")
	// the header row is tinted and borders are drawn
	frame(&fx.ui.tree, {600, 500})
	tints := 0
	for _, l in fx.ui.tree.layers do for c in l.cmds do if r, ok := c.(Draw_Rect); ok && r.color == fx.ui.tree.theme.color.surface_high && r.rect.h == area_line_h(&fx.ui.tree, s, 0) do tints += 1
	testing.expect(t, tints >= 1, "the header row is tinted")
	// Tab steps cells and rows, then adds a row
	area_move(&fx.ui.tree, area, s, {0, 2}, false)
	key_event(&fx.ui, .Tab, true, {})
	testing.expect(t, s.caret.block == 0 && s.caret.off == 9, "second cell of the header")
	key_event(&fx.ui, .Tab, true, {})
	testing.expect_value(t, s.caret.block, 1)
	key_event(&fx.ui, .Tab, true, {})
	key_event(&fx.ui, .Tab, true, {})
	testing.expect_value(t, block_count(&fx.doc), 4)
	testing.expect(t, block_meta(&fx.doc, 2).kind == .Table && block_str(&fx.doc, 2) == "|  |  |")
	key_event(&fx.ui, .Tab, true, {.Shift})
	testing.expect_value(t, s.caret.block, 1)
	// Enter adds a row under the current one; typing goes into its first cell
	key_event(&fx.ui, .Enter, true, {})
	testing.expect_value(t, block_count(&fx.doc), 5)
	text_area_text(&fx.ui, "Cy")
	testing.expect_value(t, block_str(&fx.doc, 2), "| Cy |  |")
	// the toolbar inserts a table after the caret's block
	area_move(&fx.ui.tree, area, s, {4, 0}, false)
	rich_apply(&fx.ui, fr, .Table)
	testing.expect(t, block_meta(&fx.doc, 5).kind == .Table && block_meta(&fx.doc, 5).level == 1 && block_meta(&fx.doc, 6).kind == .Table)
	// the live editor: the raw row shows its pipes dimmed, rendered rows hide them; Tab steps cells
	lv: Rt_Fx
	ui_init(&lv.ui)
	defer ui_destroy(&lv.ui)
	lv.doc = document_make("| a | b |\n|---|---|\n| c | d |")
	defer document_destroy(&lv.doc)
	larea := live_view(&lv)
	ls := &lv.ui.tree.areas[larea]
	set_focus(&lv.ui.tree, larea, true)
	raw := area_rich(&lv.ui.tree, ls, 0)
	pipes := 0
	for seg in raw.lines[0].segs do if block_str(&lv.doc, 0)[seg.start] == '|' do pipes += 1
	testing.expect_value(t, pipes, 3)
	testing.expect(t, block_height(&lv.ui.tree, ls, 1) < area_line_h(&lv.ui.tree, ls, 0), "the separator is only a line when rendered")
	key_event(&lv.ui, .Tab, true, {})
	testing.expect(t, ls.caret.block == 0 && ls.anchor.off == 6 && ls.caret.off == 7, "the second cell selected")
}

// A row laid out must hand back everything it allocated, because `rich_free`
// can only reach what the layout points at. The raw path builds the visual
// lines to gather their segments and then returns a single line of its own,
// so the lines it built must be freed there, or a source table row leaks a
// `[]Rich_Line` and a `[]Rich_Seg` per line at keystroke rate.
@(test)
a_table_row_layout_hands_back_everything_it_took :: proc(t: ^testing.T) {
	fx: Rt_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	a := mem.tracking_allocator(&track)

	base := Rich_Style{size = 14}
	cols := []f32{0, 100, 200}
	raws := []bool{true, false}
	for raw in raws {
		lay := table_row_layout(&fx.ui.tree, "| Ann | 41 |", nil, base, cols, raw, a)
		testing.expect(t, len(lay.lines) > 0, "it laid the row out")
		rich_free(&lay, a)
		testing.expectf(t, len(track.allocation_map) == 0,
			"raw = %v: %d allocations outlived rich_free", raw, len(track.allocation_map))
		testing.expectf(t, len(track.bad_free_array) == 0, "raw = %v: freed something twice", raw)
	}
}

// Leaving a table: Shift+Enter in any row starts a paragraph after the
// table; Enter on an empty last row turns that row into the paragraph.
// The live editor does the same on source rows.
@(test)
rich_text_leaves_tables :: proc(t: ^testing.T) {
	fx: Rt_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	fx.doc = document_make("")
	defer document_destroy(&fx.doc)
	document_set_markdown(&fx.doc, "| a | b |\n|---|---|\n| c | d |")
	_, area := rt_view(&fx)
	s := &fx.ui.tree.areas[area]
	set_focus(&fx.ui.tree, area, true)
	area_move(&fx.ui.tree, area, s, {0, 2}, false)
	key_event(&fx.ui, .Enter, true, {.Shift})
	testing.expect_value(t, block_count(&fx.doc), 3)
	testing.expect(t, block_meta(&fx.doc, 2).kind == .Paragraph && s.caret == Pos{2, 0}, "a paragraph after the table")
	area_move(&fx.ui.tree, area, s, {1, 2}, false)
	key_event(&fx.ui, .Enter, true, {}) // a new empty row
	testing.expect(t, block_meta(&fx.doc, 2).kind == .Table && table_row_empty(block_str(&fx.doc, 2)))
	key_event(&fx.ui, .Enter, true, {}) // Enter on the empty last row: it becomes the paragraph
	testing.expect(t, block_meta(&fx.doc, 2).kind == .Paragraph && block_str(&fx.doc, 2) == "" && s.caret == Pos{2, 0})
	testing.expect_value(t, block_count(&fx.doc), 4)
	// live
	lv: Rt_Fx
	ui_init(&lv.ui)
	defer ui_destroy(&lv.ui)
	lv.doc = document_make("| a | b |\n|---|---|\n| c | d |")
	defer document_destroy(&lv.doc)
	larea := live_view(&lv)
	ls := &lv.ui.tree.areas[larea]
	set_focus(&lv.ui.tree, larea, true)
	area_move(&lv.ui.tree, larea, ls, {2, 9}, false)
	key_event(&lv.ui, .Enter, true, {})
	testing.expect_value(t, block_str(&lv.doc, 3), "|  |  |")
	key_event(&lv.ui, .Enter, true, {})
	testing.expect_value(t, block_str(&lv.doc, 3), "")
	area_move(&lv.ui.tree, larea, ls, {2, 9}, false)
	key_event(&lv.ui, .Enter, true, {.Shift})
	testing.expect_value(t, block_str(&lv.doc, 3), "")
	testing.expect_value(t, block_count(&lv.doc), 5)
}

} // when ODIN_TEST