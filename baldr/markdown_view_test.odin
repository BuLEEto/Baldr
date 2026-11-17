package baldr

@(require) import "core:fmt"
@(require) import "core:slice"
@(require) import "core:strings"
@(require) import "core:testing"

// Behind this `when` so a program importing Baldr does not type-check the
// test suite too, which costs gigabytes. ODIN_TEST is set by `odin test`;
// BALDR_TESTS lets ./build.sh check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// The markdown view. A reply is laid out block by block, and appending text
// neither moves nor re-lays the blocks above it, which is what makes a
// streamed reply readable.


@(private = "file")
Mv_Msg :: union { int }

@(private = "file")
mv_build :: proc(ui: ^Ui(Mv_Msg), md: ^Markdown_Doc, w: f32 = 400) -> Node {
	set_viewport(&ui.tree, {w, 600})
	begin_view(ui)
	n := markdown_view(ui, md, label = "Reply", width = w)
	end_view(ui)
	frame(&ui.tree, {w, 600})
	return n
}

@(test)
a_reply_lays_out_block_by_block :: proc(t: ^testing.T) {
	ui: Ui(Mv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, "# Title\n\nA paragraph of the reply.\n\n- one\n- two\n\n> quoted\n\n---\n")

	n := mv_build(&ui, &md)
	s := &ui.tree.md_views[n]
	testing.expect(t, s != nil, "the view kept its state")
	testing.expect_value(t, len(s.blocks), len(md.blocks))
	testing.expect(t, s.content > 0, "it has a height")

	// every block sits below the one before it, and the node is as tall as
	// its content: a reply in a list of messages sizes itself
	for i in 1 ..< len(s.blocks) {
		testing.expectf(t, s.blocks[i].top >= s.blocks[i - 1].top + s.blocks[i - 1].height,
			"block %d overlaps the one above it", i)
	}
	d := node_get(&ui.tree, n)
	testing.expect(t, d.rect.h >= s.content - 0.5, "the node is as tall as its content")

	// a heading is set larger than a paragraph
	head := s.blocks[0].lay.styles[0]
	para := s.blocks[1].lay.styles[0]
	testing.expect(t, head.size > para.size && head.bold, "the heading stands out")
}

@(test)
appending_does_not_relay_the_blocks_above :: proc(t: ^testing.T) {
	ui: Ui(Mv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, "First paragraph.\nSecond paragraph.\n")

	n := mv_build(&ui, &md)
	s := &ui.tree.md_views[n]
	settled := len(s.blocks)
	tops := make([]f32, settled, context.temp_allocator)
	texts := make([]string, settled, context.temp_allocator)
	for i in 0 ..< settled {
		tops[i] = s.blocks[i].top
		texts[i] = s.blocks[i].text // the display text of the layout that was kept
	}

	md_append(&md, "A third, still arriving")
	mv_build(&ui, &md)
	s = &ui.tree.md_views[n]
	testing.expect_value(t, len(s.blocks), settled + 1)
	for i in 0 ..< settled {
		testing.expectf(t, s.blocks[i].top == tops[i], "block %d moved when text was appended", i)
		testing.expectf(t, raw_data(s.blocks[i].text) == raw_data(texts[i]),
			"block %d was laid out again though it had not changed", i)
	}

	// …and the new block really is the appended text
	last := s.blocks[settled]
	testing.expect(t, strings.contains(last.text, "still arriving"), "the new block holds the new text")
}

@(test)
a_reply_reads_as_text_to_a_screen_reader :: proc(t: ^testing.T) {
	ui: Ui(Mv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, "# Heading\n\nSome **bold** words.\n\n- a bullet\n\n1. first step\n2. second step\n")

	n := mv_build(&ui, &md)
	d := node_get(&ui.tree, n)
	testing.expect_value(t, d.access.role, Role.Text)
	testing.expect_value(t, d.access.name, "Reply")
	// the words themselves, not the markup
	testing.expect(t, strings.contains(d.access.value_text, "Heading"), "the heading is readable")
	testing.expect(t, strings.contains(d.access.value_text, "a bullet"), "the list item is readable")
	testing.expect(t, !strings.contains(d.access.value_text, "**"), "no markup is read out")
	// …and a numbered list's numbers, which are its content: a reader hears
	// "2. second step", not a list of steps with the order left out
	testing.expect(t, strings.contains(d.access.value_text, "2. second step"), "the steps are read out numbered")
}

@(test)
a_new_document_in_the_same_slot_starts_over :: proc(t: ^testing.T) {
	// picking another conversation reuses the node: nothing of the old
	// reply's layout may survive into the new one
	ui: Ui(Mv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	a, b: Markdown_Doc
	defer md_destroy(&a)
	defer md_destroy(&b)
	md_set(&a, "The first reply, which is a fair bit longer than the second.\nAnd more.\n")
	md_set(&b, "Short.\n")

	n := mv_build(&ui, &a)
	tall := ui.tree.md_views[n].content

	// the same call site, so it is the same node taking a different document
	m := mv_build(&ui, &b)
	testing.expect_value(t, m, n)
	s := &ui.tree.md_views[n]
	testing.expect(t, s != nil, "the view still has its state")
	testing.expect_value(t, len(s.blocks), len(b.blocks))
	testing.expect(t, s.content < tall, "the shorter reply is shorter")
}

// A document freed and remade often lands at the same address, and one set
// once has the same `version` as the one it replaced, so a widget telling
// them apart by address alone keeps the old text's layout. Both document
// kinds carry an id of their own for this.
@(test)
a_remade_document_is_not_the_one_we_cached :: proc(t: ^testing.T) {
	ui: Ui(Mv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	md: Markdown_Doc
	md_set(&md, "Four lines.\nOf a longer\nanswer than\nthe next one.\n")
	n := mv_build(&ui, &md)
	tall := ui.tree.md_views[n].content
	first_id := md.id

	// the app throws the reply away and makes another in the same variable:
	// the same address, and a document set once either way
	md_destroy(&md)
	md_set(&md, "Two lines.\nOnly.\n")
	defer md_destroy(&md)
	testing.expect(t, md.id != first_id, "the new document has a name of its own")
	testing.expect_value(t, md.rev, u64(2)) // cleared, then appended: as the old one was

	mv_build(&ui, &md)
	s := &ui.tree.md_views[n]
	testing.expect_value(t, len(s.blocks), len(md.blocks))
	testing.expect(t, s.content < tall, "it is the new, shorter reply — not the old layout kept")
}

// …and the same for a Document behind a text area: the area must not keep
// the replaced document's heights.
@(test)
a_remade_document_refits_a_text_area :: proc(t: ^testing.T) {
	ui: Ui(Mv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make("Four lines.\nOf a longer\nanswer than\nthe next one.")
	build :: proc(ui: ^Ui(Mv_Msg), doc: ^Document) -> Node {
		set_viewport(&ui.tree, {400, 600})
		begin_view(ui)
		n := text_area(ui, doc, height = 0)
		end_view(ui)
		frame(&ui.tree, {400, 600})
		return n
	}
	n := build(&ui, &doc)
	tall := node_get(&ui.tree, n).rect.h

	document_destroy(&doc)
	doc = document_make("Two lines.\nOnly.")
	defer document_destroy(&doc)
	build(&ui, &doc)
	testing.expect(t, node_get(&ui.tree, n).rect.h < tall, "the area refits the new document")
}

// Selection and copying. The anchors are source byte offsets, which is what
// lets a selection survive the reply growing under it and a re-layout at
// another width.

@(private = "file")
MV_REPLY :: "# Heading\n\nA paragraph with **bold** in it.\n\n- first item\n- second item\n"

@(private = "file")
mv_press :: proc(ui: ^Ui(Mv_Msg), at: [2]f32, clicks := 1, shift := false) {
	ui.pointer.clicks.count = clicks
	ui.pointer.mods = {.Shift} if shift else {}
	pointer_move(ui, at)
	md_view_pointer_button(ui, true, at)
}

// mv_point is the middle of block `b`'s first line, `frac` across its width.
@(private = "file")
mv_point :: proc(ui: ^Ui(Mv_Msg), n: Node, b: int, frac: f32) -> [2]f32 {
	s := &ui.tree.md_views[n]
	d := node_get(&ui.tree, n)
	c := s.blocks[b]
	return {d.abs.x + c.lay.lines[0].width * frac + 1, d.abs.y + c.top + c.lay.line_h * 0.5}
}

// mv_point_on is the middle of display byte `at` of block `b` — a point
// aimed at a character rather than at a fraction of a width, which is what
// a test about *which word* was picked has to do.
@(private = "file")
mv_point_on :: proc(ui: ^Ui(Mv_Msg), n: Node, b: int, at: int) -> [2]f32 {
	s := &ui.tree.md_views[n]
	d := node_get(&ui.tree, n)
	c := s.blocks[b]
	lay := c.lay
	x0, x1 := rich_x(&lay, 0, at), rich_x(&lay, 0, at + 1)
	return {d.abs.x + c.indent + (x0 + x1) * 0.5, d.abs.y + c.top + c.lay.line_h * 0.5}
}

@(test)
a_drag_selects_across_blocks :: proc(t: ^testing.T) {
	ui: Ui(Mv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, MV_REPLY)
	n := mv_build(&ui, &md)

	// from the middle of the paragraph to the middle of the last list item
	mv_press(&ui, mv_point(&ui, n, 1, 0.4))
	md_view_pointer_move(&ui, mv_point(&ui, n, 3, 0.5))
	md_view_pointer_button(&ui, false, mv_point(&ui, n, 3, 0.5))

	lo, hi := md_view_selection(&ui.tree, n)
	testing.expect(t, lo < hi, "something is selected")
	testing.expect(t, lo > 0 && hi <= len(md.src), "inside the document")
	text := md_view_selected_text(&ui.tree, n)
	testing.expect(t, strings.contains(text, "first item"), "the list item between the ends came along")
	testing.expect(t, !strings.contains(text, "**"), "the marks are not in what is copied")
	testing.expect(t, strings.contains(text, "- first item"), "a list item copies with its marker")

	// and the markdown behind it is the source, exactly
	testing.expect(t, strings.contains(md_markdown(&md, lo, hi), "**bold**"), "copy as markdown keeps the source")
}

@(private = "file")
mv_dump :: proc(ui: ^Ui(Mv_Msg), n: Node, md: ^Markdown_Doc) {
	s := &ui.tree.md_views[n]
	d := node_get(&ui.tree, n)
	fmt.eprintfln("--- view abs %v rect %v, %d blocks", d.abs, d.rect, len(s.blocks))
	for c, i in s.blocks {
		fmt.eprintfln("  block %d src %d..%d top %.1f h %.1f lines %d line_h %.1f %q",
			i, c.from, c.to, c.top, c.height, len(c.lay.lines), c.lay.line_h, c.text)
	}
	for b in 0 ..< len(s.blocks) {
		p := mv_point(ui, n, b, 0.5)
		fmt.eprintfln("  probe block %d at %v -> source %d", b, p, md_view_at(&ui.tree, n, s, p))
	}
}

@(test)
a_double_click_takes_a_word_and_a_triple_takes_the_block :: proc(t: ^testing.T) {
	ui: Ui(Mv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, MV_REPLY)
	n := mv_build(&ui, &md)

	// aimed at the "A" the paragraph opens with, not at a fraction of a width
	mv_press(&ui, mv_point_on(&ui, n, 1, 0), clicks = 2)
	lo, hi := md_view_selection(&ui.tree, n)
	word := md_markdown(&md, lo, hi)
	if word != "A" do mv_dump(&ui, n, &md)
	testing.expect_value(t, word, "A")

	// …and a word in the middle of it
	mv_press(&ui, mv_point_on(&ui, n, 1, 4), clicks = 2) // "A par|agraph"
	lo, hi = md_view_selection(&ui.tree, n)
	testing.expect_value(t, md_markdown(&md, lo, hi), "paragraph")

	mv_press(&ui, mv_point(&ui, n, 1, 0.5), clicks = 3)
	lo, hi = md_view_selection(&ui.tree, n)
	testing.expect_value(t, md_markdown(&md, lo, hi), "A paragraph with **bold** in it.")
}

@(test)
a_selection_survives_the_reply_growing :: proc(t: ^testing.T) {
	// the reason the anchors are source offsets: a person reading and
	// selecting higher up must not have it move while the answer arrives
	ui: Ui(Mv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, MV_REPLY)
	n := mv_build(&ui, &md)

	mv_press(&ui, mv_point(&ui, n, 1, 0.5), clicks = 3)
	lo, hi := md_view_selection(&ui.tree, n)
	before := md_view_selected_text(&ui.tree, n, context.allocator)
	defer delete(before)

	md_append(&md, "\nAnd more of the answer arriving.\n")
	mv_build(&ui, &md)
	lo2, hi2 := md_view_selection(&ui.tree, n)
	testing.expect_value(t, lo2, lo)
	testing.expect_value(t, hi2, hi)
	testing.expect_value(t, md_view_selected_text(&ui.tree, n), before)

	// …and a narrower view re-lays the lines without moving it
	m := mv_build(&ui, &md, 260)
	testing.expect_value(t, m, n) // the same node, a narrower view
	lo3, hi3 := md_view_selection(&ui.tree, n)
	testing.expect_value(t, lo3, lo)
	testing.expect_value(t, hi3, hi)
}

@(test)
ctrl_a_and_ctrl_c :: proc(t: ^testing.T) {
	ui: Ui(Mv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, MV_REPLY)
	n := mv_build(&ui, &md)

	copied: string
	ui.tree.clipboard = {
		user = &copied,
		set = proc(user: rawptr, text: string) -> bool {
			(^string)(user)^ = strings.clone(text)
			return true
		},
	}
	set_focus(&ui.tree, n, false)

	testing.expect(t, md_view_key(&ui, .A, {.Ctrl}), "Ctrl+A is the reply's")
	lo, hi := md_view_selection(&ui.tree, n)
	testing.expect_value(t, lo, 0)
	testing.expect_value(t, hi, len(md.src))

	testing.expect(t, md_view_key(&ui, .C, {.Ctrl}), "Ctrl+C copied")
	defer delete(copied)
	testing.expect(t, strings.contains(copied, "Heading"), "the heading is in it")
	testing.expect(t, strings.contains(copied, "- second item"), "and the list items, with their markers")
	testing.expect(t, !strings.contains(copied, "#"), "but not the markup")

	testing.expect(t, md_view_key(&ui, .Escape, {}), "Escape lets it go")
	lo, hi = md_view_selection(&ui.tree, n)
	testing.expect_value(t, lo, hi)

	// a key the reply does not use stays the window's
	testing.expect(t, !md_view_key(&ui, .F, {.Ctrl}), "Ctrl+F is not ours")
}

@(test)
a_link_goes_to_the_app :: proc(t: ^testing.T) {
	// the view never opens anything itself: it says which link was pressed
	// and the app decides (open_url is strict about its schemes)
	ui: Ui(Mv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, "See [the docs](https://example.com/docs) for more.\n")

	set_viewport(&ui.tree, {400, 600})
	begin_view(&ui)
	n := markdown_view(&ui, &md, label = "Reply", width = 400)
	md_view_options(&ui, n, on_link = proc(e: Ev(string)) -> Mv_Msg { return 7 })
	end_view(&ui)
	frame(&ui.tree, {400, 600})

	// "the docs" is the link text; "See " is not
	s := &ui.tree.md_views[n]
	testing.expect_value(t, s.blocks[0].text, "See the docs for more.")
	on_link := mv_point_on(&ui, n, 0, 6)  // inside "the docs"
	off_link := mv_point_on(&ui, n, 0, 1) // inside "See"
	testing.expect_value(t, md_view_link_at(&ui.tree, n, on_link), "https://example.com/docs")
	testing.expect_value(t, md_view_link_at(&ui.tree, n, off_link), "")

	mv_press(&ui, on_link)
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0].(int), 7)
	lo, hi := md_view_selection(&ui.tree, n)
	testing.expect_value(t, lo, hi) // a press on a link does not start a selection
	clear(&ui.msgs)

	// …and a press on ordinary text still selects, rather than being eaten
	mv_press(&ui, off_link)
	testing.expect_value(t, len(ui.msgs), 0)
	testing.expect(t, !ui.tree.md_views[n].dragging == false, "a drag started on the text")
}

@(test)
a_picture_is_the_apps_to_give_and_to_open :: proc(t: ^testing.T) {
	// the view never fetches: what the app hands over is drawn, what it
	// does not is the alt text. A private conversation's pictures live in
	// the app's memory and never reach the disk through the toolkit.
	ui: Ui(Mv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, "Here it is:\n\n![a chart](sha256-abc)\n\n![missing](https://example.com/x.png)\n")

	img := Image{width = 200, height = 100, id = 1}
	build :: proc(ui: ^Ui(Mv_Msg), md: ^Markdown_Doc, img: ^Image) -> Node {
		set_viewport(&ui.tree, {400, 600})
		begin_view(ui)
		n := markdown_view(ui, md, label = "Reply", width = 400)
		md_view_options(ui, n, on_image = proc(e: Ev(string)) -> Mv_Msg { return 9 })
		if img != nil do md_view_image(ui, n, "sha256-abc", img)
		end_view(ui)
		frame(&ui.tree, {400, 600})
		return n
	}
	n := build(&ui, &md, &img)
	s := &ui.tree.md_views[n]

	// the picture it was given is laid out at its own size (it fits)
	shown, alt := -1, -1
	for c, i in s.blocks {
		if s.md.blocks[i].meta.kind != .Image do continue
		if c.picture != nil { shown = i } else { alt = i }
	}
	testing.expect(t, shown >= 0 && alt >= 0, "one picture drawn, one left as alt text")
	testing.expect_value(t, s.blocks[shown].height, f32(100))
	testing.expect(t, strings.contains(s.blocks[alt].text, "missing"), "the alt text stands in")

	// a click on it is the app's, with the src it was written with
	d := node_get(&ui.tree, n)
	at := [2]f32{d.abs.x + 20, d.abs.y + s.blocks[shown].top + 10}
	mv_press(&ui, at)
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0].(int), 9)

	// and a picture wider than the view is fitted to it, never grown
	wide := Image{width = 800, height = 400, id = 2}
	build(&ui, &md, &wide)
	s = &ui.tree.md_views[n]
	testing.expect_value(t, s.blocks[shown].height, f32(200)) // 400/800 of 400
}

@(test)
a_fenced_block_takes_its_languages_colours :: proc(t: ^testing.T) {
	// the app says which language a fence's name means, so it can fold
	// "sql", "tsql" and "mssql" together without the toolkit knowing
	ui: Ui(Mv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, "```odin\nmain :: proc() { return }\n```\n")

	asked: string
	set_viewport(&ui.tree, {400, 600})
	begin_view(&ui)
	n := markdown_view(&ui, &md, label = "Reply", width = 400)
	md_view_options(&ui, n, language = proc(name: string) -> ^Language {
		if name == "odin" do return &LANG_ODIN
		return nil
	})
	end_view(&ui)
	frame(&ui.tree, {400, 600})
	_ = asked

	s := &ui.tree.md_views[n]
	testing.expect_value(t, len(s.blocks), 1)
	testing.expect_value(t, s.blocks[0].text, "main :: proc() { return }")
	testing.expect_value(t, s.md.blocks[0].meta.kind, Block_Kind.Code)
	testing.expect_value(t, s.md.blocks[0].meta.lang, "odin")

	// the tokenizer the paint uses finds the keyword, which is what makes
	// the colours differ from plain text
	toks := make([dynamic]Token, 0, 16, context.temp_allocator)
	tokenize_line(&LANG_ODIN, s.blocks[0].text, 0, &toks)
	kinds := 0
	for tk in toks do if code_token_color(&ui.tree.theme, tk.kind) != ui.tree.theme.color.on_surface do kinds += 1
	testing.expect(t, kinds > 0, "something in the line is coloured as code")
}

@(test)
a_numbered_list_keeps_its_numbers :: proc(t: ^testing.T) {
	// The numbers are the content in an answer like "1. Pull … 2. Compare
	// … 3. Flag …", so they are drawn, not bullets. A second list starts
	// again at 1.
	ui: Ui(Mv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, "1. pull\n2. compare\n3. flag\n\nthen:\n\n1. again\n2. and again\n")
	n := mv_build(&ui, &md)
	s := &ui.tree.md_views[n]

	got := make([dynamic]int, context.temp_allocator)
	for c, i in s.blocks do if s.md.blocks[i].meta.kind == .Numbered do append(&got, c.number)
	testing.expect_value(t, len(got), 5)
	testing.expect_value(t, got[0], 1)
	testing.expect_value(t, got[1], 2)
	testing.expect_value(t, got[2], 3)
	testing.expect_value(t, got[3], 1) // the paragraph between them ended the first list
	testing.expect_value(t, got[4], 2)

	// a nested list does not restart the one it sits in
	md_set(&md, "1. one\n  1. inner\n  2. inner two\n2. two\n")
	mv_build(&ui, &md)
	s = &ui.tree.md_views[n]
	nested := make([dynamic]int, context.temp_allocator)
	for c, i in s.blocks do if s.md.blocks[i].meta.kind == .Numbered do append(&nested, c.number)
	testing.expect_value(t, len(nested), 4)
	testing.expect_value(t, nested[0], 1)
	testing.expect_value(t, nested[1], 1) // the inner list counts for itself
	testing.expect_value(t, nested[2], 2)
	testing.expect_value(t, nested[3], 2) // …and the outer one carries on
}

@(test)
a_heading_stands_out_from_the_body :: proc(t: ^testing.T) {
	// Heading sizes come from the reply's own body size, not the UI's
	// headline and title roles: an app shrinks those for its chrome, and a
	// heading that matches the paragraph under it is not a heading.
	ui: Ui(Mv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.type.title.size = 14 // an app's chrome, smaller than its body
	ui.tree.theme.type.headline.size = 19
	ui.tree.theme.type.body.size = 13.5
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, "# one\n\n## two\n\n### three\n\nbody text\n")
	n := mv_build(&ui, &md)
	s := &ui.tree.md_views[n]

	size :: proc(c: Md_Line_Cache) -> f32 { return c.lay.styles[0].size if len(c.lay.styles) > 0 else 0 }
	h1, h2, h3, body := size(s.blocks[0]), size(s.blocks[1]), size(s.blocks[2]), size(s.blocks[3])
	testing.expect(t, h1 > h2 && h2 > h3 && h3 > body, "each level is larger than the next, and all larger than body")
	testing.expect(t, h2 >= body * 1.25, "h2 is clearly a heading against this app's body size")
	testing.expect(t, s.blocks[1].lay.styles[0].bold, "and it is bold")
}

@(test)
only_one_reply_holds_a_selection :: proc(t: ^testing.T) {
	// A chat is a column of replies, each with a selection of its own. Two
	// lit at once would make Ctrl+C a guess, so there is one selection at a
	// time, as in a document.
	ui: Ui(Mv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	a, b: Markdown_Doc
	defer md_destroy(&a)
	defer md_destroy(&b)
	md_set(&a, "The first reply, with words to select.\n")
	md_set(&b, "The second reply, also with words.\n")

	two :: proc(ui: ^Ui(Mv_Msg), a, b: ^Markdown_Doc) -> (Node, Node) {
		set_viewport(&ui.tree, {400, 600})
		begin_view(ui)
		x := markdown_view(ui, a, label = "A", width = 400, key = 1)
		y := markdown_view(ui, b, label = "B", width = 400, key = 2)
		end_view(ui)
		frame(&ui.tree, {400, 600})
		return x, y
	}
	na, nb := two(&ui, &a, &b)

	// select the whole of A with the keyboard
	set_focus(&ui.tree, na, false)
	testing.expect(t, md_view_key(&ui, .A, {.Ctrl}), "Ctrl+A in A")
	lo, hi := md_view_selection(&ui.tree, na)
	testing.expect(t, lo < hi, "A has a selection")

	// …then press in B: A must let go, so only one wash is lit
	pb := mv_point(&ui, nb, 0, 0.5)
	mv_press(&ui, pb, clicks = 3)
	lo, hi = md_view_selection(&ui.tree, na)
	testing.expect_value(t, lo, hi) // A is clear
	blo, bhi := md_view_selection(&ui.tree, nb)
	testing.expect(t, blo < bhi, "and B has it now")

	// and the same the other way, by keyboard
	set_focus(&ui.tree, na, false)
	testing.expect(t, md_view_key(&ui, .A, {.Ctrl}), "Ctrl+A in A again")
	blo, bhi = md_view_selection(&ui.tree, nb)
	testing.expect_value(t, blo, bhi) // B let go
}

@(private = "file")
mv_marks :: proc(s: ^Md_View_State, str: string) -> bool { // is this the view's own memory?
	if len(s.marks) == 0 || len(str) == 0 do return false
	base, p := uintptr(raw_data(s.marks[:])), uintptr(raw_data(str))
	return p >= base && p + uintptr(len(str)) <= base + uintptr(len(s.marks))
}

@(test)
a_markers_bytes_belong_to_the_view :: proc(t: ^testing.T) {
	// A layer keeps its commands, so a Draw_Text's `str` has to outlive the
	// wake-up that built it: list markers are formatted into the view's own
	// buffer, not temp memory.
	ui: Ui(Mv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, "### Steps to Reorder Smartly\n\n1. Pull the top 5 parts by quantity.\n2. Compare each part's on-hand.\n3. Flag any that dip below.\n")
	n := mv_build(&ui, &md)
	s := &ui.tree.md_views[n]

	want := [?]string{"1.", "2.", "3."}
	for w in want {
		drawn, owned := false, false
		for _, l in ui.tree.layers do for c in l.cmds {
			dt, ok := c.(Draw_Text)
			if !ok || dt.str != w do continue
			drawn = true
			owned = mv_marks(s, dt.str)
		}
		testing.expectf(t, drawn, "the marker %q is drawn", w)
		testing.expectf(t, owned, "the marker %q is the view's memory, not the frame's", w)
	}
}

@(test)
a_list_shares_one_marker_column :: proc(t: ^testing.T) {
	// A marker one fixed step left of the text runs a two-digit ordinal into
	// its words, so every item in a list shares a column as wide as that
	// list's widest marker, and the marker is set right-aligned in it.
	ui: Ui(Mv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	md: Markdown_Doc
	defer md_destroy(&md)
	b := strings.builder_make(context.temp_allocator)
	for i in 1 ..= 12 do fmt.sbprintf(&b, "%d. item number %d\n", i, i)
	md_set(&md, strings.to_string(b))
	n := mv_build(&ui, &md)
	s := &ui.tree.md_views[n]

	wide := ui.tree.measure_text(&ui.tree, "12.", md_view_style(&ui.tree, .Numbered, 0).size, 0, .Regular, false, 0, false).x
	for c, i in s.blocks {
		testing.expectf(t, c.indent == s.blocks[0].indent, "item %d starts its text on the column the list shares", i + 1)
		testing.expectf(t, c.mark_col >= wide - 0.01, "item %d's column holds the widest ordinal", i + 1)
		testing.expectf(t, c.indent >= c.mark_col + ui.tree.theme.space[.sm] - 0.01,
			"item %d keeps a gap between its marker and its words", i + 1)
	}
	// the markers are right-aligned into that column, so they end together
	ends := make(map[f32]int, context.temp_allocator)
	for _, l in ui.tree.layers do for cmd in l.cmds {
		if dt, ok := cmd.(Draw_Text); ok && mv_marks(s, dt.str) {
			testing.expect(t, dt.align == .End && dt.box_w > 0, "a marker is set right-aligned in its column")
			ends[dt.pos.x + dt.box_w] += 1
		}
	}
	testing.expect_value(t, len(ends), 1) // one right edge for the whole list
	two_digits := s.blocks[0].mark_col // the same slot is rebuilt below: read it now

	// a bullet list under a numbered one is a list of its own: its markers
	// are not set on the ordinals' column, which would push its words in
	// for no reason (a blank line between two lists is not a block)
	md_set(&md, "1. one\n2. two\n\n- a bullet\n- another\n")
	mv_build(&ui, &md)
	s = &ui.tree.md_views[n]
	numbered, bullet := f32(0), f32(0)
	for c, i in s.blocks {
		if s.md.blocks[i].meta.kind == .Numbered do numbered = c.indent
		if s.md.blocks[i].meta.kind == .Bullet do bullet = c.indent
	}
	testing.expect(t, bullet > 0 && bullet < numbered, "the bullets keep their own, narrower column")

	// a short list needs a narrower column than a long one
	md2: Markdown_Doc
	defer md_destroy(&md2)
	md_set(&md2, "1. one\n2. two\n3. three\n")
	n2 := mv_build(&ui, &md2)
	s2 := &ui.tree.md_views[n2]
	testing.expect(t, s2.blocks[0].mark_col < two_digits, "a 1–3 list does not reserve room for two digits")
}

@(test)
a_table_rules_its_rows_the_same :: proc(t: ^testing.T) {
	// Every row gets its rule: a half-pixel hairline snapped to the device
	// grid would be kept or dropped by the fraction its row landed on.
	ui: Ui(Mv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, "| Part | Qty |\n|---|---|\n| P001 | 5 |\n| P002 | 3 |\n| P003 | 0 |\n")
	n := mv_build(&ui, &md)
	s := &ui.tree.md_views[n]

	rows := 0
	for b in md.blocks do if b.meta.kind == .Table do rows += 1
	testing.expect_value(t, rows, 4) // the header and three rows; the separator is no block

	rules := make([dynamic]f32, context.temp_allocator)
	for _, l in ui.tree.layers do for cmd in l.cmds {
		if dr, ok := cmd.(Draw_Rect); ok && dr.rect.h == 1 do append(&rules, dr.rect.y)
	}
	testing.expect_value(t, len(rules), rows - 1) // one between each pair, none under the last row
	for y, i in rules do if i > 0 do testing.expectf(t, y > rules[i - 1], "rule %d sits below the one before it", i)
	testing.expect(t, s.blocks[0].cols != nil, "the rows share the table's columns")
}

@(test)
a_table_header_is_measured_in_the_weight_it_is_drawn_in :: proc(t: ^testing.T) {
	// The header row is drawn at level 1, which is bold and wider, so its
	// columns must be measured bold or a header word breaks mid-word.
	// Real fonts, because rich_layout's no-fonts fallback measures bold and
	// regular the same, which would hide the difference under test.
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)

	ui: Ui(Mv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.text = &te
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, "| Line | Part | Description | Qty |\n|---|---|---|---|\n| 1 | P001 | A very long description that wants all the slack it can get | 5 |\n")
	// Narrow is where it shows: with slack in the table every column is
	// wide enough by accident.
	bold := md_view_style(&ui.tree, .Table, 1)
	testing.expect(t, bold.bold, "the header row is drawn bold")
	header := "| Line | Part | Description | Qty |"
	shown := markdown_render_line(header, false, false, context.temp_allocator)
	lay := rich_layout(&ui.tree, shown.text, shown.runs, bold, 0, context.temp_allocator)

	// From 240 up the table fits and the squeeze lands exactly on the
	// header's own width; below that four columns do not fit at all. Bold
	// is under a pixel wider for "Line" with these fonts, which is enough
	// to break the word.
	reg := md_view_style(&ui.tree, .Table, 0)
	rlay := rich_layout(&ui.tree, shown.text, shown.runs, reg, 0, context.temp_allocator)
	wider := false
	for cell in table_cells(shown.text) {
		if lay.cum[cell[1]] - lay.cum[cell[0]] > rlay.cum[cell[1]] - rlay.cum[cell[0]] + 0.01 do wider = true
	}
	testing.expect(t, wider, "bold is wider than regular here, or this test cannot see the bug")

	widths := []f32{240, 280, 320, 420}
	for w in widths {
		n := mv_build(&ui, &md, w)
		s := &ui.tree.md_views[n]
		cols := s.blocks[0].cols
		if !testing.expectf(t, cols != nil, "the table has columns at %.0f", w) do continue
		for cell, ci in table_cells(shown.text) {
			if ci + 1 >= len(cols) do break
			need := lay.cum[cell[1]] - lay.cum[cell[0]]
			have := cols[ci + 1] - cols[ci] - TABLE_CELL_PAD * 2
			testing.expectf(t, have >= need - 0.5,
				"at %.0f wide, column %d holds its bold heading: needs %.1f, has %.1f", w, ci, need, have)
		}
	}
}

// A column of figures lines its digits up, and a column that says how it
// wants to be set gets that. Models rarely write an alignment row, so the
// automatic case is the common one.
@(test)
a_table_sets_its_columns_where_they_ask_or_where_numbers_want :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)
	ui: Ui(Mv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.text = &te

	// no alignment row at all: Qty is all numbers, Part is not
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, "| Part | Qty |\n|---|---|\n| P001 | 130 |\n| P002 | 35 |\n| P003 | 7 |\n")
	n := mv_build(&ui, &md, 420)
	s := &ui.tree.md_views[n]
	al := md_view_table_align(&ui.tree, s, 0)
	if !testing.expect_value(t, len(al), 2) do return
	testing.expect_value(t, al[0], Table_Align.Default) // part numbers stay put
	testing.expect_value(t, al[1], Table_Align.Right)   // the figures line up

	// the digits really are set to the right: the last row's short "7"
	// starts further in than the three-digit "130" above it
	x_of :: proc(s: ^Md_View_State, row: int, cell: int) -> f32 {
		lay := s.blocks[row].lay
		if len(lay.lines) == 0 do return 0
		segs := lay.lines[0].segs
		return segs[cell].x if cell < len(segs) else 0
	}
	wide_row, narrow_row := x_of(s, 1, 1), x_of(s, 3, 1)
	testing.expectf(t, narrow_row > wide_row,
		"a shorter number starts further right (130 at %.1f, 7 at %.1f)", wide_row, narrow_row)

	// …and a table that says what it wants gets it, numbers or not
	md2: Markdown_Doc
	defer md_destroy(&md2)
	md_set(&md2, "| Name | Note |\n|---:|:---:|\n| Ann | hello |\n")
	n2 := mv_build(&ui, &md2, 420)
	s2 := &ui.tree.md_views[n2]
	al2 := md_view_table_align(&ui.tree, s2, 0)
	if testing.expect_value(t, len(al2), 2) {
		testing.expect_value(t, al2[0], Table_Align.Right)
		testing.expect_value(t, al2[1], Table_Align.Center)
	}
}

@(test)
a_streamed_table_lines_up :: proc(t: ^testing.T) {
	// A table's columns belong to the table. Measured per row as the rows
	// arrived, the first rows would keep the narrow columns they were laid
	// out with, and a streamed table would come out ragged.
	ui: Ui(Mv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, "| Part | Description |\n|---|---|\n")
	n := mv_build(&ui, &md)
	md_append(&md, "| P001 | Bolt |\n")
	mv_build(&ui, &md)
	md_append(&md, "| P002 | A washer with a much longer description |\n")
	mv_build(&ui, &md)
	s := &ui.tree.md_views[n]

	rows := make([dynamic]int, context.temp_allocator)
	for b, i in s.md.blocks do if b.meta.kind == .Table do append(&rows, i)
	testing.expect_value(t, len(rows), 3)
	for r in rows {
		testing.expectf(t, slice.equal(s.blocks[r].cols, s.blocks[rows[0]].cols),
			"row %d is laid out on the table's columns, not the ones it arrived with", r)
	}
	testing.expect(t, s.blocks[rows[0]].cols[1] > 0, "the columns were measured")
}

@(test)
a_wrapped_paragraph_is_one_paragraph :: proc(t: ^testing.T) {
	// Prose wrapped at eighty columns is a paragraph, not a paragraph per
	// line: blocks are one per source line, so without this a wrapped answer
	// read as a list of short paragraphs.
	ui: Ui(Mv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, "one line of prose\nwrapped onto a second\n\nand a new paragraph\n")
	n := mv_build(&ui, &md)
	s := &ui.tree.md_views[n]
	testing.expect_value(t, len(s.blocks), 3)

	joined := s.blocks[1].top - (s.blocks[0].top + s.blocks[0].height)
	apart := s.blocks[2].top - (s.blocks[1].top + s.blocks[1].height)
	testing.expect_value(t, joined, 0) // the wrap is invisible
	testing.expect(t, apart > 0, "a blank line between paragraphs still separates them")
}

@(test)
a_hovered_link_shows_its_target :: proc(t: ^testing.T) {
	// The target shows on hover in a tooltip by the pointer, not in a status
	// strip an app would have to grow for this alone; under the line the link
	// is on, as an editor's mark tooltip sits.
	ui: Ui(Mv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, "see [the overview](https://odin-lang.org/docs/overview/) for more\n")
	n := mv_build(&ui, &md)
	s := &ui.tree.md_views[n]
	d := node_get(&ui.tree, n)

	on_link := mv_point_on(&ui, n, 0, 6) // inside "the overview"
	testing.expect_value(t, md_view_link_at(&ui.tree, n, on_link), "https://odin-lang.org/docs/overview/")
	pointer_move(&ui, on_link)
	ui_after_events(&ui, 100)
	testing.expect_value(t, ui.tip_anchor, NODE_NONE) // not yet: a tooltip waits
	ui_after_events(&ui, 100 + TOOLTIP_DELAY_MS + 1)
	testing.expect_value(t, ui.tip_anchor, n)

	mv_build(&ui, &md)
	tip := node_first(&ui.tree, ui.tree.overlay)
	testing.expect(t, tip != NODE_NONE, "a tooltip is up")
	td := node_get(&ui.tree, tip)
	testing.expect_value(t, td.access.role, Role.Tooltip)
	testing.expect_value(t, td.access.name, "https://odin-lang.org/docs/overview/")
	testing.expect(t, td.abs.y >= d.abs.y + s.blocks[0].lay.line_h, "under the line the link is on")

	// a press hides it (the rule every tooltip follows) and it stays hidden
	// while the pointer rests where it was, even though the app rebuilt
	// around the message the press sent
	pointer_button(&ui, .Left, true, on_link)
	pointer_button(&ui, .Left, false, on_link)
	mv_build(&ui, &md)
	testing.expect_value(t, ui.tip_anchor, NODE_NONE)
	ui_after_events(&ui, 2000)
	mv_build(&ui, &md)
	testing.expect_value(t, ui.tip_anchor, NODE_NONE)

	// off the link, onto plain words: the target goes, and the pointer says
	// what each is for — a hand on the link, an I-beam on the text
	hand, on_it := md_view_cursor(&ui)
	testing.expect(t, on_it && hand == .Pointer, "the hand over a link")
	off := mv_point_on(&ui, n, 0, 1) // "see"
	pointer_move(&ui, off)
	ui_after_events(&ui, 2000)
	testing.expect_value(t, ui.tip_anchor, NODE_NONE)
	beam, on_text := md_view_cursor(&ui)
	testing.expect(t, on_text && beam == .Text, "the I-beam over words that can be selected")
}

@(test)
a_code_block_has_a_copy_button :: proc(t: ^testing.T) {
	// A real button: its own hit target, its own hover, a place in the focus
	// order and the name "Copy code", not a rectangle painted on the block.
	ui: Ui(Mv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, "Try this:\n\n```sql\nSELECT TOP 5 part_number\nFROM parts;\n```\n\nand then read it.\n")
	n := mv_build(&ui, &md)
	s := &ui.tree.md_views[n]

	btn := node_first(&ui.tree, n)
	testing.expect(t, btn != NODE_NONE, "the fenced block has a button of its own")
	bd := node_get(&ui.tree, btn)
	testing.expect_value(t, bd.access.role, Role.Button)
	testing.expect_value(t, bd.access.name, "Copy code")
	testing.expect(t, .Focusable in bd.flags, "and a place in the focus order")

	code := -1
	for b, i in md.blocks do if b.meta.kind == .Code && code < 0 do code = i
	testing.expect(t, code >= 0)
	nd := node_get(&ui.tree, n)
	testing.expect(t, bd.rect.x + bd.rect.w <= nd.rect.w + 0.01, "it sits inside the reply")
	testing.expect(t, bd.rect.y + bd.rect.h <= s.blocks[code].top + 0.01 &&
		bd.rect.y >= s.blocks[code].top - MD_CODE_HEAD - 0.01, "in the band over the block")

	copied: string
	ui.tree.clipboard = {
		user = &copied,
		set = proc(user: rawptr, text: string) -> bool {
			(^string)(user)^ = strings.clone(text)
			return true
		},
	}
	testing.expect(t, click(&ui, btn), "the button copies")
	defer delete(copied)
	testing.expect_value(t, copied, "SELECT TOP 5 part_number\nFROM parts;")
	testing.expect(t, !strings.contains(copied, "```"), "the fences are not code")

	// it says so for a moment, in a way a reader hears too
	mv_build(&ui, &md)
	testing.expect_value(t, node_get(&ui.tree, node_first(&ui.tree, n)).access.describe, "Copied")

	// and the tick goes back to the copy icon when its moment has passed
	ui_after_events(&ui, ui.tree.now_ms + MD_COPIED_MS + 1)
	mv_build(&ui, &md)
	testing.expect_value(t, node_get(&ui.tree, node_first(&ui.tree, n)).access.describe, "")

	// and it works from the keyboard, being a button
	delete(copied)
	copied = ""
	set_focus(&ui.tree, btn, true)
	testing.expect(t, key_event(&ui, .Enter, true, {}), "Enter on the focused button")
	testing.expect(t, strings.contains(copied, "SELECT TOP 5"), "copies the same code")

	// …and from the pointer, which a direct click() would miss: the view is a
	// selection surface and must not swallow the press on its way past
	delete(copied)
	copied = ""
	bd = node_get(&ui.tree, node_first(&ui.tree, n))
	on_btn := [2]f32{bd.abs.x + bd.abs.w / 2, bd.abs.y + bd.abs.h / 2}
	pointer_move(&ui, on_btn)
	pointer_button(&ui, .Left, true, on_btn)
	pointer_button(&ui, .Left, false, on_btn)
	testing.expect(t, strings.contains(copied, "SELECT TOP 5"), "a click on the button copies")
	lo, hi := md_view_selection(&ui.tree, n)
	testing.expect(t, lo == hi, "and does not start selecting the reply")
}

@(test)
a_fenced_block_has_a_band_for_its_chrome :: proc(t: ^testing.T) {
	// A Copy button on the fence's first line would cover the end of a
	// one-line fence, and hiding it until hover would take it from touch and
	// the keyboard, so the block has a band of its own, which is where its
	// language goes too.
	ui: Ui(Mv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, "Run:\n\n```sh\nodin build . -out:build/app -o:speed -vet -collection:baldr=.\n```\n")
	n := mv_build(&ui, &md)
	s := &ui.tree.md_views[n]

	code := -1
	for b, i in md.blocks do if b.meta.kind == .Code && code < 0 do code = i
	testing.expect(t, code >= 0)
	bd := node_get(&ui.tree, node_first(&ui.tree, n))
	testing.expect(t, bd.rect.y + bd.rect.h <= s.blocks[code].top + 0.01,
		"the button sits above the code, not on its first line")
	testing.expect(t, bd.rect.y >= s.blocks[code].top - MD_CODE_HEAD - 0.01, "and inside the band")

	// the language is drawn in that band, from the view's own memory: the
	// document's copy is a slice of source that moves as the reply grows
	label := NODE_NONE
	found := false
	for _, l in ui.tree.layers do for cmd in l.cmds {
		if dt, ok := cmd.(Draw_Text); ok && dt.str == "sh" {
			found = true
			testing.expect(t, mv_marks(s, dt.str), "the label is the view's memory")
			testing.expect(t, dt.pos.y < node_get(&ui.tree, n).abs.y + s.blocks[code].top, "in the band")
		}
	}
	testing.expect(t, found, "the fence's language is shown")
	_ = label
}

@(test)
a_growing_document_keeps_its_aliases :: proc(t: ^testing.T) {
	// A block's language and a picture's source are slices of the document's
	// source, and appending reallocates it, so they are derived again after
	// each parse; otherwise the view would read freed memory on every paint.
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, "```sql\nSELECT 1;\n```\n\n![a picture](shot.png)\n\n")
	for _ in 0 ..< 200 do md_append(&md, "more words to grow the buffer with\n") // forces it to move

	base := uintptr(raw_data(md.src[:]))
	end := base + uintptr(len(md.src))
	langs, srcs := 0, 0
	for b in md.blocks {
		if b.meta.kind == .Code && len(b.meta.lang) > 0 {
			p := uintptr(raw_data(b.meta.lang))
			testing.expect(t, p >= base && p < end, "the language points into the document as it is now")
			testing.expect_value(t, b.meta.lang, "sql")
			langs += 1
		}
		if b.meta.kind == .Image && len(b.meta.src) > 0 {
			p := uintptr(raw_data(b.meta.src))
			testing.expect(t, p >= base && p < end, "and so does the picture's source")
			testing.expect_value(t, b.meta.src, "shot.png")
			srcs += 1
		}
	}
	testing.expect(t, langs > 0 && srcs > 0, "the document still has both to check")
}

@(test)
shift_arrows_select_from_the_keyboard :: proc(t: ^testing.T) {
	// Selecting by keyboard once a reply has focus, with no caret drawn, by
	// the same keys every editor here uses. A plain arrow is not the reply's:
	// it goes on to the window and its scroll.
	ui: Ui(Mv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, "First line of the reply.\nSecond line follows it.\n\nA third block.\n")
	n := mv_build(&ui, &md)
	set_focus(&ui.tree, n, false)

	testing.expect(t, !md_view_key(&ui, .Right, {}), "a plain arrow is the window's, not the reply's")
	testing.expect(t, !md_view_key(&ui, .Down, {}), "…and so is a plain Down")

	testing.expect(t, md_view_key(&ui, .Right, {.Shift}), "Shift+Right extends")
	lo, hi := md_view_selection(&ui.tree, n)
	testing.expect_value(t, lo, 0)
	testing.expect_value(t, hi, 1)

	testing.expect(t, md_view_key(&ui, .End, {.Shift}), "Shift+End takes the rest of the line")
	testing.expect_value(t, md_view_selected_text(&ui.tree, n), "First line of the reply.")

	testing.expect(t, md_view_key(&ui, .Down, {.Shift}), "Shift+Down reaches the line below")
	_, after_down := md_view_selection(&ui.tree, n)
	testing.expect(t, after_down > hi, "the end moved on")
	testing.expect(t, strings.contains(md_view_selected_text(&ui.tree, n), "Second line"), "into the second line")

	testing.expect(t, md_view_key(&ui, .End, {.Ctrl, .Shift}), "Ctrl+Shift+End takes the reply to its end")
	_, to_end := md_view_selection(&ui.tree, n)
	testing.expect_value(t, to_end, len(md.src))

	// a word at a time, back from the end
	was := to_end
	for _ in 0 ..< 3 {
		testing.expect(t, md_view_key(&ui, .Left, {.Ctrl, .Shift}), "Ctrl+Shift+Left steps back a word")
		_, now := md_view_selection(&ui.tree, n)
		testing.expect(t, now < was, "and the end keeps moving back")
		was = now
	}
	testing.expect(t, strings.contains(md_view_selected_text(&ui.tree, n), "First line"), "the anchor has not moved")

	testing.expect(t, md_view_key(&ui, .Home, {.Ctrl, .Shift}), "Ctrl+Shift+Home takes it to the start")
	lo, hi = md_view_selection(&ui.tree, n)
	testing.expect_value(t, lo, 0)
	testing.expect_value(t, hi, 0)

	testing.expect(t, md_view_key(&ui, .Escape, {}) == false, "nothing selected: Escape is not the reply's")
}

@(test)
a_reply_reads_as_one_piece_of_text :: proc(t: ^testing.T) {
	// A reply is static text to a reader, named by the app,
	// with the rendered words as its description — never the markup — and
	// it is reachable by keyboard. Its Copy buttons are named buttons in
	// the focus order, and they say when they have copied.
	ui: Ui(Mv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, "## Steps\n\n1. Pull the top 5 parts.\n2. Compare each one.\n\n```sql\nSELECT 1;\n```\n")
	n := mv_build(&ui, &md)
	d := node_get(&ui.tree, n)

	testing.expect_value(t, d.access.role, Role.Text)
	testing.expect_value(t, d.access.name, "Reply")
	testing.expect(t, .Focusable in d.flags, "a reply can be tabbed to, selected and copied")
	// the reply is the object's *text*, which a reader reads line by line and
	// follows as it grows — not a description, which is a note about it
	testing.expect(t, strings.contains(d.access.value_text, "1. Pull the top 5 parts."), "the steps are read out, numbers and all")
	testing.expect(t, !strings.contains(d.access.value_text, "```"), "the markup is not")
	// (what the accessibility bridge makes of that is a11y_text_test.odin's,
	// which is where the bridge's own tests live)

	dump := access_dump(&ui.tree)
	testing.expect(t, strings.contains(dump, "Copy code"), "the Copy button is in the tree by name")
	testing.expect_value(t, lint(&ui.tree), 0) // nothing unnamed, nothing unreadable

	btn := node_first(&ui.tree, n)
	bd := node_get(&ui.tree, btn)
	testing.expect_value(t, bd.access.role, Role.Button)
	testing.expect(t, .Focusable in bd.flags)
}

} // when ODIN_TEST