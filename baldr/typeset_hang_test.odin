package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Hanging punctuation, which is optical margin
// alignment. A line ending in a comma is optically short where a line
// ending in "n" is not, because a comma is a speck in a wide box. Letting
// it sit outside the margin is what makes a justified page look straight
// rather than merely measure straight.

@(private = "file")
fixture :: proc(t: ^testing.T, te: ^Text_Engine, tr: ^Tree) {
	if !text_engine_init(te) do testing.fail_now(t, "text_engine_init: embedded fonts failed to load")
	tree_init(tr)
	tree_use_text_engine(tr, te)
}

// The last glyph's right edge, from the Typeset's own origin.
@(private = "file")
ink_right :: proc(ts: ^Typeset) -> f32 {
	r := min(f32)
	for g in ts.glyphs do if !g.blank do r = max(r, g.x1)
	return r
}

// It is off unless asked for, so a paragraph that does not ask measures
// exactly to its ink.
@(test)
hanging_punctuation_is_off_unless_asked_for :: proc(t: ^testing.T) {
	te: Text_Engine; tr: Tree
	fixture(t, &te, &tr)
	defer { tree_destroy(&tr); text_engine_destroy(&te) }

	ts, ok := typeset(&tr, "a sentence, and more.", Typeset_Style{size = 16})
	testing.expect(t, ok, "typeset")
	defer typeset_destroy(&ts)

	testing.expectf(t, abs(ink_right(&ts) - ts.lines[0].rect.w) < 0.01,
		"nothing sits outside the margin: ink %v vs width %v", ink_right(&ts), ts.lines[0].rect.w)
}

// Asked for, a line ending in a full stop measures narrower than its glyphs
// reach — the stop is outside the margin.
@(test)
a_line_ending_in_a_stop_hangs_it_out :: proc(t: ^testing.T) {
	te: Text_Engine; tr: Tree
	fixture(t, &te, &tr)
	defer { tree_destroy(&tr); text_engine_destroy(&te) }

	text := "a sentence, and more."
	plain, ok0 := typeset(&tr, text, Typeset_Style{size = 16})
	testing.expect(t, ok0, "typeset")
	defer typeset_destroy(&plain)

	hung, ok := typeset(&tr, text, Typeset_Style{size = 16, hanging_punctuation = true})
	testing.expect(t, ok, "typeset")
	defer typeset_destroy(&hung)

	testing.expectf(t, hung.lines[0].rect.w < plain.lines[0].rect.w - 0.5,
		"the line measures narrower than it draws: %v vs %v", hung.lines[0].rect.w, plain.lines[0].rect.w)
	testing.expectf(t, abs(ink_right(&hung) - ink_right(&plain)) < 0.01,
		"but nothing moved — the glyphs are where they were")
	over := ink_right(&hung) - hung.lines[0].rect.w
	testing.expectf(t, over > 0.5, "so the stop reaches past the margin by %v", over)
}

// A line ending in a letter hangs nothing, which is the control: the rule
// is about what punctuation looks like, not about shortening every line.
@(test)
a_line_ending_in_a_letter_hangs_nothing :: proc(t: ^testing.T) {
	te: Text_Engine; tr: Tree
	fixture(t, &te, &tr)
	defer { tree_destroy(&tr); text_engine_destroy(&te) }

	plain, ok0 := typeset(&tr, "a sentence and more", Typeset_Style{size = 16})
	testing.expect(t, ok0, "typeset")
	defer typeset_destroy(&plain)

	hung, ok := typeset(&tr, "a sentence and more", Typeset_Style{size = 16, hanging_punctuation = true})
	testing.expect(t, ok, "typeset")
	defer typeset_destroy(&hung)

	testing.expectf(t, abs(hung.lines[0].rect.w - plain.lines[0].rect.w) < 0.01,
		"a letter is a letter: %v vs %v", hung.lines[0].rect.w, plain.lines[0].rect.w)
}

// An opening quotation mark goes the other way: the line starts out in the
// margin, so the first letter under it lines up with the paragraph below.
@(test)
an_opening_quote_starts_out_in_the_margin :: proc(t: ^testing.T) {
	te: Text_Engine; tr: Tree
	fixture(t, &te, &tr)
	defer { tree_destroy(&tr); text_engine_destroy(&te) }

	text := "“Well!” thought Alice."
	plain, ok0 := typeset(&tr, text, Typeset_Style{size = 16})
	testing.expect(t, ok0, "typeset")
	defer typeset_destroy(&plain)
	testing.expectf(t, abs(plain.lines[0].rect.x) < 0.01, "without it the quote is at the margin: %v", plain.lines[0].rect.x)

	hung, ok := typeset(&tr, text, Typeset_Style{size = 16, hanging_punctuation = true})
	testing.expect(t, ok, "typeset")
	defer typeset_destroy(&hung)
	testing.expectf(t, hung.lines[0].rect.x < -0.5, "with it the line starts left of the margin: %v", hung.lines[0].rect.x)
}

// The table itself, so the shape of the rule is pinned rather than only its
// effect: quotes and hyphens hang most, stops and commas half, the heavier
// marks a little, and letters and brackets not at all.
@(test)
what_hangs_and_how_far :: proc(t: ^testing.T) {
	testing.expect_value(t, typeset_hang_out('.', false), f32(0.5))
	testing.expect_value(t, typeset_hang_out(',', false), f32(0.5))
	testing.expect_value(t, typeset_hang_out('-', false), f32(0.6))
	testing.expect_value(t, typeset_hang_out(0x00AD, false), f32(0.6)) // a drawn soft hyphen
	testing.expect_value(t, typeset_hang_out(0x2019, false), f32(0.7)) // a closing quote
	testing.expect_value(t, typeset_hang_out(':', false), f32(0.2))

	testing.expect_value(t, typeset_hang_out(0x201C, true), f32(0.7)) // an opening quote
	testing.expect_value(t, typeset_hang_out(0x201C, false), f32(0))  // …which does not hang at the end
	testing.expect_value(t, typeset_hang_out('.', true), f32(0))      // nor a stop at the start

	testing.expect_value(t, typeset_hang_out('n', false), f32(0))
	testing.expect_value(t, typeset_hang_out('(', true), f32(0)) // a bracket is too heavy: hanging it reads as a mistake
	testing.expect_value(t, typeset_hang_out(')', false), f32(0))
}

// A justified line ending in a comma gets the room the comma gave up, so
// its words reach the margin and the comma sits beyond it. Without that,
// hanging would only make justified lines short.
@(test)
a_justified_line_spreads_into_what_hangs :: proc(t: ^testing.T) {
	te: Text_Engine; tr: Tree
	fixture(t, &te, &tr)
	defer { tree_destroy(&tr); text_engine_destroy(&te) }

	text := "Alice was beginning to get very tired of sitting by her sister, and of having nothing at all to do with it."
	plain, ok0 := typeset(&tr, text, Typeset_Style{size = 14, wrap_width = 200, justify = true})
	testing.expect(t, ok0, "typeset")
	defer typeset_destroy(&plain)

	hung, ok := typeset(&tr, text, Typeset_Style{size = 14, wrap_width = 200, justify = true, hanging_punctuation = true})
	testing.expect(t, ok, "typeset")
	defer typeset_destroy(&hung)

	// every full line is still justified to the measure
	for l, i in hung.lines[:len(hung.lines) - 1] {
		testing.expectf(t, abs(l.rect.w - 200) < 0.01, "line %d still fills the measure: %v", i, l.rect.w)
	}
	// and at least one line now reaches past it, which is the punctuation
	reach: f32
	for i in 0 ..< len(hung.lines) - 1 {
		span := hung.spans[i]
		for gi in span[0] ..< span[0] + span[1] {
			g := hung.glyphs[gi]
			if !g.blank do reach = max(reach, g.x1 - (hung.lines[i].rect.x + hung.lines[i].rect.w))
		}
	}
	testing.expectf(t, reach > 0.5, "something hangs past the measure: %v", reach)
}

}
