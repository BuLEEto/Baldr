package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A page is a range of a laid-out paragraph's lines. A book reader lays a
// chapter out once, decides where the pages break, and draws the lines that
// fall on each one — so turning a page costs drawing and never layout.

@(private = "file")
TV_Msg :: union { int }

@(private = "file")
tv_fixture :: proc(t: ^testing.T, te: ^Text_Engine, ui: ^Ui(TV_Msg)) {
	if !text_engine_init(te) do testing.fail_now(t, "text_engine_init: embedded fonts failed to load")
	ui_init(ui)
	tree_use_text_engine(&ui.tree, te)
}

// A paragraph long enough to wrap into several lines, laid out once.
@(private = "file")
tv_para :: proc(t: ^testing.T, tr: ^Tree, wrap: f32 = 120) -> Typeset {
	text := "Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do."
	ts, ok := typeset(tr, text, Typeset_Style{size = 14, wrap_width = wrap})
	testing.expect(t, ok, "typeset")
	testing.expect(t, len(ts.lines) >= 5, "it wrapped into several lines")
	return ts
}

@(private = "file")
tv_drawn :: proc(ui: ^Ui(TV_Msg)) -> (d: Draw_Typeset, ok: bool) {
	for c in draw_list(&ui.tree) {
		if v, is := c.(Draw_Typeset); is do return v, true
	}
	return {}, false
}

// A setting freed and the next laid out can land at the **same address**, so
// `^Typeset` alone cannot tell them apart: same pointer, same key, same first
// and count would keep drawing the old words and give a screen reader the old
// text. One `slot` here makes that case deterministic: the second setting
// lives exactly where the first one did.
@(test)
a_new_typeset_at_a_freed_ones_address_is_not_the_old_one :: proc(t: ^testing.T) {
	te: Text_Engine; ui: Ui(TV_Msg)
	tv_fixture(t, &te, &ui)
	defer { ui_destroy(&ui); text_engine_destroy(&te) }

	build :: proc(ui: ^Ui(TV_Msg), ts: ^Typeset) -> Node {
		begin_view(ui)
		column(ui)
		n := typeset_view(ui, ts, label = "Page", key = 4)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {400, 300})
		return n
	}

	slot: Typeset
	ok: bool
	slot, ok = typeset(&ui.tree, "The first chapter's opening words.", Typeset_Style{size = 14, wrap_width = 300})
	testing.expect(t, ok, "the first setting")
	first_serial := slot.serial
	n := build(&ui, &slot)
	st := &ui.tree.typesets[n]
	testing.expect(t, strings.contains(st.read, "first chapter"), "the reader is given the first chapter")

	// The chapter changes: the old setting is freed and the next is laid out
	// into the very same storage.
	typeset_destroy(&slot)
	slot, ok = typeset(&ui.tree, "The second chapter says something else.", Typeset_Style{size = 14, wrap_width = 300})
	testing.expect(t, ok, "the second setting")
	testing.expect(t, slot.serial != first_serial, "a fresh setting never repeats a serial")

	n2 := build(&ui, &slot)
	testing.expect_value(t, n2, n) // same key, same node: the reconciler is not what saves us
	st = &ui.tree.typesets[n2]
	testing.expect_value(t, st.ts, &slot) // and the same address, which is the whole point
	testing.expect(t, strings.contains(st.read, "second chapter"), "the new words reached the reader")
	testing.expect(t, !strings.contains(st.read, "first chapter"), "…and the old ones are gone")
	if d, drawn := tv_drawn(&ui); drawn {
		testing.expect_value(t, d.ts, &slot)
		testing.expect(t, strings.contains(d.ts.text, "second chapter"), "and the page draws the new setting")
	} else {
		testing.fail_now(t, "nothing was drawn")
	}
	typeset_destroy(&slot)
}

// The node draws the lines it was given and no others, and is as tall as
// exactly those lines.
@(test)
a_typeset_view_draws_the_lines_it_was_given :: proc(t: ^testing.T) {
	te: Text_Engine; ui: Ui(TV_Msg)
	tv_fixture(t, &te, &ui)
	defer { ui_destroy(&ui); text_engine_destroy(&te) }
	ts := tv_para(t, &ui.tree)
	defer typeset_destroy(&ts)

	begin_view(&ui)
	column(&ui)
	n := typeset_view(&ui, &ts, first = 1, count = 3)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 300})

	v, ok := tv_drawn(&ui)
	testing.expect(t, ok, "a Draw_Typeset reached the layer")
	testing.expect_value(t, v.first, 1)
	testing.expect_value(t, v.count, 3)
	testing.expect_value(t, v.ts, &ts)
	testing.expect(t, v.scale == 1, "drawn as laid out")

	want: f32
	for i in 1 ..< 4 do want += ts.lines[i].rect.h
	d := node_get(&ui.tree, n)
	testing.expectf(t, abs(d.abs.h - want) < 0.01, "as tall as its three lines: %v vs %v", d.abs.h, want)
}

// A count of -1 is the rest of the paragraph, and a range past the end
// draws fewer lines rather than reading past it.
@(test)
a_typeset_view_clamps_the_range_it_is_asked_for :: proc(t: ^testing.T) {
	te: Text_Engine; ui: Ui(TV_Msg)
	tv_fixture(t, &te, &ui)
	defer { ui_destroy(&ui); text_engine_destroy(&te) }
	ts := tv_para(t, &ui.tree)
	defer typeset_destroy(&ts)

	lo, hi := typeset_view_range(&ts, 2, -1)
	testing.expect_value(t, lo, 2)
	testing.expect_value(t, hi, len(ts.lines))

	lo2, hi2 := typeset_view_range(&ts, len(ts.lines) - 1, 50)
	testing.expect_value(t, lo2, len(ts.lines) - 1)
	testing.expect_value(t, hi2, len(ts.lines))

	lo3, hi3 := typeset_view_range(&ts, 900, 3)
	testing.expect(t, lo3 == hi3, "a range past the end draws nothing at all")

	lo4, hi4 := typeset_view_range(nil, 0, 3)
	testing.expect(t, lo4 == 0 && hi4 == 0, "and nil is not a crash")
}

// What a screen reader gets is the paragraph's own source over those
// lines — so a word broken across a line boundary is still one word, and
// the hyphen the page draws is not in what is read out.
@(test)
a_typeset_view_reads_out_the_source_not_the_lines :: proc(t: ^testing.T) {
	te: Text_Engine; ui: Ui(TV_Msg)
	tv_fixture(t, &te, &ui)
	defer { ui_destroy(&ui); text_engine_destroy(&te) }

	wide, ok0 := typeset(&ui.tree, "hyphen", Typeset_Style{size = 20})
	testing.expect(t, ok0, "typeset")
	w := wide.lines[0].rect.w + 6
	typeset_destroy(&wide)

	ts, ok := typeset(&ui.tree, "hyphen­ation follows after", Typeset_Style{size = 20, wrap_width = w})
	testing.expect(t, ok, "typeset")
	defer typeset_destroy(&ts)
	testing.expect(t, ts.lines[0].hyphen, "the first line broke at the soft hyphen")

	begin_view(&ui)
	column(&ui)
	n := typeset_view(&ui, &ts, label = "Page")
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 300})

	d := node_get(&ui.tree, n)
	testing.expect_value(t, d.access.role, Role.Text)
	testing.expect_value(t, d.access.name, "Page")
	read := d.access.value_text
	// The word is whole — the hyphen the page drew is not in it — and the
	// soft hyphens the book carries are not either: they are invisible by
	// design, and a reader should no more hear them than see them.
	testing.expectf(t, strings.contains(read, "hyphenation"),
		"the reader hears the whole word: %q", read)
	testing.expect(t, !strings.contains(read, "hyphen-"), "never the drawn hyphen")
	testing.expectf(t, !strings.contains_rune(read, 0x00AD), "and no soft hyphens in it: %q", read)
	testing.expectf(t, !strings.contains_rune(read, 0x200B), "nor a zero-width space: %q", read)
}

// The accessible text covers only the lines drawn: a page does not read out
// the pages around it.
@(test)
a_typeset_view_reads_out_only_its_own_lines :: proc(t: ^testing.T) {
	te: Text_Engine; ui: Ui(TV_Msg)
	tv_fixture(t, &te, &ui)
	defer { ui_destroy(&ui); text_engine_destroy(&te) }
	ts := tv_para(t, &ui.tree)
	defer typeset_destroy(&ts)

	whole := typeset_view_text(&ts, 0, len(ts.lines))
	part := typeset_view_text(&ts, 1, 3)
	testing.expect(t, len(part) < len(whole), "fewer lines, less text")
	testing.expect(t, strings.contains(whole, part), "and it is a stretch of the paragraph")
	testing.expect(t, !strings.has_prefix(part, "Alice"), "not from the start, since it began at line 1")
	testing.expect_value(t, typeset_view_text(&ts, 2, 2), "")
}

// A click on a page turns into a line: the y is measured from the top of
// the range drawn, not from the paragraph's own first line.
@(test)
a_typeset_view_finds_the_line_under_a_point :: proc(t: ^testing.T) {
	te: Text_Engine; ui: Ui(TV_Msg)
	tv_fixture(t, &te, &ui)
	defer { ui_destroy(&ui); text_engine_destroy(&te) }
	ts := tv_para(t, &ui.tree)
	defer typeset_destroy(&ts)

	h := ts.lines[2].rect.h
	testing.expect_value(t, typeset_view_line_at(&ts, 2, 3, 1), 2)
	testing.expect_value(t, typeset_view_line_at(&ts, 2, 3, h + 1), 3)
	testing.expect_value(t, typeset_view_line_at(&ts, 2, 3, h * 2 + 1), 4)
	testing.expect_value(t, typeset_view_line_at(&ts, 2, 3, h * 9), -1)
}

// A page laid out again with taller lines must take the new height, or the
// column stacks the next paragraph where the old one ended and the two
// overlap. The node survives between the two builds — same key, same
// parent — so writing the size into the node and marking only paint dirty
// is not enough: layout has to hear of it.
@(test)
a_typeset_view_takes_a_new_height_when_its_lines_grow :: proc(t: ^testing.T) {
	te: Text_Engine; ui: Ui(TV_Msg)
	tv_fixture(t, &te, &ui)
	defer { ui_destroy(&ui); text_engine_destroy(&te) }

	text := "Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do."
	tight, ok0 := typeset(&ui.tree, text, Typeset_Style{size = 14, wrap_width = 120, line_height = 14 * 1.45})
	testing.expect(t, ok0, "typeset")
	defer typeset_destroy(&tight)
	loose, ok1 := typeset(&ui.tree, text, Typeset_Style{size = 14, wrap_width = 120, line_height = 14 * 1.65})
	testing.expect(t, ok1, "typeset")
	defer typeset_destroy(&loose)
	testing.expect(t, loose.size.y > tight.size.y + 1, "the looser setting is taller")

	// a page: the paragraph, and something under it
	page :: proc(ui: ^Ui(TV_Msg), ts: ^Typeset) -> (para, below: Node) {
		begin_view(ui)
		column(ui)
		para = typeset_view(ui, ts, key = 7)
		below = text(ui, "the next paragraph", key = 8)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {400, 600})
		return
	}

	para, below := page(&ui, &tight)
	d0 := node_get(&ui.tree, para)
	b0 := node_get(&ui.tree, below)
	first_h, first_below := d0.abs.h, b0.abs.y
	testing.expectf(t, abs(first_h - tight.size.y) < 0.5, "it starts as tall as its lines: %v vs %v", first_h, tight.size.y)

	para2, below2 := page(&ui, &loose)
	testing.expect_value(t, para2, para) // the same node, reconciled
	testing.expect_value(t, below2, below)
	d1 := node_get(&ui.tree, para)
	b1 := node_get(&ui.tree, below)
	testing.expectf(t, abs(d1.abs.h - loose.size.y) < 0.5,
		"and takes the new height: %v vs %v", d1.abs.h, loose.size.y)
	testing.expectf(t, b1.abs.y > first_below + 1,
		"so what follows moves down with it: %v was %v", b1.abs.y, first_below)
	// …and the test for the overlap itself is against the height of the
	// lines being *drawn*, not the node's: a stale node is exactly as tall
	// as the column thinks it is, so comparing the two can never catch it.
	testing.expectf(t, b1.abs.y >= d1.abs.y + loose.size.y - 0.5,
		"and nothing overlaps the drawn lines: the next paragraph starts at %v, the lines end at %v",
		b1.abs.y, d1.abs.y + loose.size.y)
}

// What a page *draws* reaches outside its box — hanging punctuation sits
// beyond the margin on purpose, a dropped letter and an opening quote sit in
// it — so the node's paint bounds have to cover the ink and not only the
// measure. A node that keeps its place across a relayout repaints only its
// own bounds, so ink outside them would be left as a sliver.
@(test)
a_typeset_view_reaches_past_its_box_for_its_ink :: proc(t: ^testing.T) {
	te: Text_Engine; ui: Ui(TV_Msg)
	tv_fixture(t, &te, &ui)
	defer { ui_destroy(&ui); text_engine_destroy(&te) }

	text := "a sentence, and more."
	plain, ok0 := typeset(&ui.tree, text, Typeset_Style{size = 16})
	testing.expect(t, ok0, "typeset")
	defer typeset_destroy(&plain)
	hung, ok1 := typeset(&ui.tree, text, Typeset_Style{size = 16, hanging_punctuation = true})
	testing.expect(t, ok1, "typeset")
	defer typeset_destroy(&hung)

	build :: proc(ui: ^Ui(TV_Msg), ts: ^Typeset) -> Node {
		begin_view(ui)
		column(ui)
		n := typeset_view(ui, ts, key = 1)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {400, 300})
		return n
	}

	n := build(&ui, &plain)
	flat_over: f32
	if ck, ok := node_get(&ui.tree, n).kind.(Custom_Kind); ok do flat_over = ck.overhang
	testing.expectf(t, flat_over < 0.01, "nothing hangs, so nothing is claimed: %v", flat_over)

	n2 := build(&ui, &hung)
	testing.expect_value(t, n2, n) // the same node, as a reader's page keeps its own
	d := node_get(&ui.tree, n2)
	over: f32
	if ck, ok := d.kind.(Custom_Kind); ok do over = ck.overhang
	testing.expectf(t, over >= 1, "the hanging stop is claimed: %v px", over)

	// and the bounds that damage and culling use really do cover it
	reach: f32
	for g in hung.glyphs do if !g.blank do reach = max(reach, g.x1)
	b := paint_bounds(d)
	testing.expectf(t, b.x + b.w >= d.abs.x + reach - 0.01,
		"the painted bounds reach the ink: %v against %v", b.x + b.w, d.abs.x + reach)
	testing.expect(t, b.x <= d.abs.x + 0.01 && b.y <= d.abs.y + 0.01, "and are not narrower on the other sides")
}

// A dropped first letter descends three lines below the top of the page,
// so a view that draws only the first line must still claim the room its
// letter needs.
@(test)
a_typeset_view_claims_the_room_a_drop_cap_needs :: proc(t: ^testing.T) {
	te: Text_Engine; ui: Ui(TV_Msg)
	tv_fixture(t, &te, &ui)
	defer { ui_destroy(&ui); text_engine_destroy(&te) }

	cap, ok := typeset(&ui.tree, "Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing at all to do with it.", Typeset_Style{size = 14, wrap_width = 220, drop_cap_lines = 3})
	testing.expect(t, ok, "typeset")
	defer typeset_destroy(&cap)

	begin_view(&ui)
	column(&ui)
	n := typeset_view(&ui, &cap, first = 0, count = 1) // only the first line
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 300})

	d := node_get(&ui.tree, n)
	over: f32
	if ck, ok2 := d.kind.(Custom_Kind); ok2 do over = ck.overhang
	testing.expectf(t, over > d.abs.h, "the letter reaches below the line it is drawn with: %v px against a %v px line", over, d.abs.h)
}

}
