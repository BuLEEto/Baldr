package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A first line that starts in (or hangs out), and a dropped first letter
// spanning several lines. Nearly every paragraph of a book is indented and
// its openings carry a drop cap, so these two are what a page is made of.

@(private = "file")
fixture :: proc(t: ^testing.T, te: ^Text_Engine, tr: ^Tree) {
	if !text_engine_init(te) do testing.fail_now(t, "text_engine_init: embedded fonts failed to load")
	tree_init(tr)
	tree_use_text_engine(tr, te)
}

@(private = "file")
PROSE :: "Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing at all to do with it: once or twice she had peeped into the book her sister was reading, but it had no pictures or conversations in it at all."

// A first-line indent starts the first line in by that much and leaves it
// that much less room, so a word moves down to the second line rather than
// overhanging.
@(test)
a_first_line_indent_starts_the_line_in :: proc(t: ^testing.T) {
	te: Text_Engine; tr: Tree
	fixture(t, &te, &tr)
	defer { tree_destroy(&tr); text_engine_destroy(&te) }

	flat, ok0 := typeset(&tr, PROSE, Typeset_Style{size = 14, wrap_width = 200})
	testing.expect(t, ok0, "typeset")
	defer typeset_destroy(&flat)

	ind, ok := typeset(&tr, PROSE, Typeset_Style{size = 14, wrap_width = 200, indent = 24})
	testing.expect(t, ok, "typeset")
	defer typeset_destroy(&ind)

	testing.expectf(t, abs(ind.lines[0].rect.x - 24) < 0.01, "the first line starts at the indent: %v", ind.lines[0].rect.x)
	testing.expectf(t, abs(ind.lines[1].rect.x) < 0.01, "the second does not: %v", ind.lines[1].rect.x)
	testing.expect(t, ind.lines[0].rect.w <= 200 - 24 + 0.01, "and it has that much less room")
	testing.expect(t, ind.lines[0].end <= flat.lines[0].end, "so it carries no more text than the unindented one")
}

// A negative indent is a hanging indent: the first line starts out to the
// left of the others and has *more* room, which is how a list marker or a
// quotation's opening sits in the margin.
@(test)
a_negative_indent_hangs_the_first_line_out :: proc(t: ^testing.T) {
	te: Text_Engine; tr: Tree
	fixture(t, &te, &tr)
	defer { tree_destroy(&tr); text_engine_destroy(&te) }

	hang, ok := typeset(&tr, PROSE, Typeset_Style{size = 14, wrap_width = 200, indent = -20})
	testing.expect(t, ok, "typeset")
	defer typeset_destroy(&hang)

	testing.expectf(t, hang.lines[0].rect.x < -19.9, "the first line hangs out to the left: %v", hang.lines[0].rect.x)
	testing.expect(t, len(hang.lines) > 1 && abs(hang.lines[1].rect.x) < 0.01, "the rest sit at the margin")
	testing.expect(t, hang.lines[0].rect.w > 200, "and the hanging line has more room, not less")
}

// A dropped first letter: the lines it spans start past it, the ones below
// do not, and the letter is set much larger than the body.
@(test)
a_drop_cap_indents_the_lines_it_spans :: proc(t: ^testing.T) {
	te: Text_Engine; tr: Tree
	fixture(t, &te, &tr)
	defer { tree_destroy(&tr); text_engine_destroy(&te) }

	ts, ok := typeset(&tr, PROSE, Typeset_Style{size = 14, wrap_width = 220, drop_cap_lines = 3})
	testing.expect(t, ok, "typeset")
	defer typeset_destroy(&ts)
	testing.expect(t, len(ts.lines) > 4, "it wrapped past the dropped letter")

	x0 := ts.lines[0].rect.x
	testing.expectf(t, x0 > 10, "the first line starts past the letter: %v", x0)
	for i in 0 ..< 3 do testing.expectf(t, abs(ts.lines[i].rect.x - x0) < 0.01,
		"line %d starts past it too: %v", i, ts.lines[i].rect.x)
	testing.expectf(t, abs(ts.lines[3].rect.x) < 0.01, "and the fourth is back at the margin: %v", ts.lines[3].rect.x)

	testing.expect(t, ts.drop_cap_run >= 0, "the letter has a run of its own")
	big, body := false, false
	for g in ts.glyphs {
		if g.blank do continue
		if int(g.run) == ts.drop_cap_run { big = true; testing.expect(t, g.scale > 0, "the letter is set") }
		else do body = true
	}
	testing.expect(t, big && body, "both the letter and the prose were set")
	testing.expect(t, ts.runs[ts.drop_cap_run].size > 14 * 2, "the letter is much bigger than the body")
}

// The dropped letter is out of the flow, so it never becomes the first
// line's height — which is the whole point of dropping it.
@(test)
a_drop_cap_is_not_the_first_lines_height :: proc(t: ^testing.T) {
	te: Text_Engine; tr: Tree
	fixture(t, &te, &tr)
	defer { tree_destroy(&tr); text_engine_destroy(&te) }

	flat, ok0 := typeset(&tr, PROSE, Typeset_Style{size = 14, wrap_width = 220})
	testing.expect(t, ok0, "typeset")
	defer typeset_destroy(&flat)

	ts, ok := typeset(&tr, PROSE, Typeset_Style{size = 14, wrap_width = 220, drop_cap_lines = 3})
	testing.expect(t, ok, "typeset")
	defer typeset_destroy(&ts)

	testing.expectf(t, abs(ts.lines[0].rect.h - flat.lines[0].rect.h) < 0.01,
		"the dropped letter leaves the leading alone: %v vs %v", ts.lines[0].rect.h, flat.lines[0].rect.h)
	testing.expectf(t, abs(ts.lines[1].rect.h - flat.lines[1].rect.h) < 0.01, "and so does the line under it")
}

// A reader must still hear the first letter: the dropped one is drawn with
// the first line and belongs to its byte range, so a page does not begin at
// the second character.
@(test)
a_drop_cap_still_belongs_to_the_first_line :: proc(t: ^testing.T) {
	te: Text_Engine; tr: Tree
	fixture(t, &te, &tr)
	defer { tree_destroy(&tr); text_engine_destroy(&te) }

	ts, ok := typeset(&tr, PROSE, Typeset_Style{size = 14, wrap_width = 220, drop_cap_lines = 3})
	testing.expect(t, ok, "typeset")
	defer typeset_destroy(&ts)

	testing.expect_value(t, ts.lines[0].start, 0)
	read := typeset_view_text(&ts, 0, 1)
	testing.expectf(t, len(read) > 0 && read[0] == 'A', "the reader starts at the A: %q", read)
	testing.expect_value(t, ts.spans[0][0], 0) // the letter's glyphs are drawn with line 0
}

// An opening quotation mark goes with the letter it opens, as a typesetter
// sets it: a paragraph beginning “The drops the quote and the T together.
@(test)
a_drop_cap_takes_an_opening_quote_with_it :: proc(t: ^testing.T) {
	testing.expect_value(t, typeset_cap_span("Alice was"), 1)
	testing.expect_value(t, typeset_cap_span("“The door”"), len("“T"))
	testing.expect_value(t, typeset_cap_span("\"Quoted"), 2)
	testing.expect_value(t, typeset_cap_span(""), 0)
	testing.expect_value(t, typeset_cap_span("“"), len("“")) // a quote and nothing after it
}

// A drop cap of one line is not a drop cap, and neither is a paragraph with
// no text: both leave the paragraph exactly as it was.
@(test)
a_drop_cap_of_one_line_is_none :: proc(t: ^testing.T) {
	te: Text_Engine; tr: Tree
	fixture(t, &te, &tr)
	defer { tree_destroy(&tr); text_engine_destroy(&te) }

	flat, ok0 := typeset(&tr, PROSE, Typeset_Style{size = 14, wrap_width = 220})
	testing.expect(t, ok0, "typeset")
	defer typeset_destroy(&flat)

	one, ok := typeset(&tr, PROSE, Typeset_Style{size = 14, wrap_width = 220, drop_cap_lines = 1})
	testing.expect(t, ok, "typeset")
	defer typeset_destroy(&one)

	testing.expect_value(t, one.drop_cap_run, -1)
	testing.expect_value(t, len(one.lines), len(flat.lines))
	testing.expectf(t, abs(one.lines[0].rect.x) < 0.01, "nothing is indented: %v", one.lines[0].rect.x)
}

}
