package baldr

@(require) import "core:math"
@(require) import "core:slice"
@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// `Typeset_Breaking.Even` chooses every break in a paragraph together
// (runa's Knuth–Plass `break_lines`) instead of filling one line at a time,
// which is what lets a page keep to "at most two hyphens in a row" and "no
// hyphen on the last full line" — a greedy fill cannot, because it never
// trades one line against another.
//
// The numbers here come from spikes/typeset_even, at the widths where the
// two settings actually differ.

@(private = "file")
even_fixture :: proc(t: ^testing.T, te: ^Text_Engine, tr: ^Tree) {
	if !text_engine_init(te) do testing.fail_now(t, "text_engine_init: embedded fonts failed to load")
	tree_init(tr)
	tree_use_text_engine(tr, te)
}

// Alice, chapter 1, hyphenated where Liang's patterns put the points —
// which is the shape a reader hands `typeset`.
@(private = "file")
EVEN_PROSE :: "Alice was be­gin­ning to get very tired of sit­ting by her sis­ter on the bank, and of hav­ing noth­ing at all to do: once or twice she had peeped into the book her sis­ter was read­ing, but it had no pic­tures or con­ver­sa­tions in it, and what is the use of a book, thought Alice, with­out pic­tures or con­ver­sa­tions?"

// Long words with nothing short between them: a line has nowhere to break
// but inside a word, which is how a page ends up with a ladder of hyphens
// down its margin.
@(private = "file")
EVEN_LADDER :: "Con­ver­sa­tions about pre­dis­po­si­tion and in­com­pre­hen­si­bil­ity con­tin­ued through­out the in­ter­na­tional par­lia­men­tary de­lib­er­a­tions, not­with­stand­ing con­sid­er­able mis­un­der­stand­ing."

// even_hyphen_run is the longest run of lines in a row ending in a hyphen.
@(private = "file")
even_hyphen_run :: proc(ts: ^Typeset) -> (worst: int) {
	run := 0
	for l in ts.lines {
		run = run + 1 if l.hyphen else 0
		worst = max(worst, run)
	}
	return
}

// even_last_full_line_hyphenated: does the paragraph's last full line end
// in a hyphen, leaving a reader half a word to finish on?
@(private = "file")
even_last_full_line_hyphenated :: proc(ts: ^Typeset) -> bool {
	full := len(ts.lines) - 1
	return full > 0 && ts.lines[full - 1].hyphen
}

// even_shortfall is how far each line stops short of the measure, worst
// first — the rag, which is what "even" means.
@(private = "file")
even_shortfall :: proc(ts: ^Typeset, measure: f32) -> (worst, sd: f32) {
	full := len(ts.lines) - 1
	if full <= 0 do return
	mean: f32
	for l, i in ts.lines do if i < full {
		s := measure - (l.rect.x + l.rect.w)
		worst = max(worst, s)
		mean += s
	}
	mean /= f32(full)
	for l, i in ts.lines do if i < full {
		d := (measure - (l.rect.x + l.rect.w)) - mean
		sd += d * d
	}
	sd = math.sqrt(sd / f32(full))
	return
}

// No line may be wider than the room it was given, whatever else the
// breaking is weighing up — and the room is not the same on every line once
// there is a first-line indent or a dropped letter. This sweeps the
// measures a reader's column passes through as a window is resized, in
// every combination that changes a line's width.
@(test)
even_lines_never_overrun_their_measure :: proc(t: ^testing.T) {
	te: Text_Engine; tr: Tree
	even_fixture(t, &te, &tr)
	defer { tree_destroy(&tr); text_engine_destroy(&te) }

	for w: f32 = 170; w <= 480; w += 10 {
		for variant in 0 ..< 5 {
			style := Typeset_Style{size = 18, wrap_width = w, breaking = .Even}
			switch variant {
			case 0: style.justify = true
			case 1: // ragged right
			case 2: style.justify = true; style.indent = 18
			case 3: style.justify = true; style.drop_cap_lines = 3
			case 4: style.justify = true; style.hanging_punctuation = true
			}
			ts, ok := typeset(&tr, EVEN_PROSE, style)
			testing.expectf(t, ok, "typeset at %v px", w)
			if !ok do continue
			for l, i in ts.lines {
				testing.expectf(t, l.rect.x + l.rect.w <= w + 0.01,
					"variant %d, %v px: line %d reaches %v", variant, w, i, l.rect.x + l.rect.w)
			}
			if variant == 3 {
				testing.expectf(t, ts.lines[0].rect.x > 10, "the dropped letter still pushes line 0 in: %v", ts.lines[0].rect.x)
			}
			typeset_destroy(&ts)
		}
	}
}

// A breaker that loses a word is the one fault that matters, so: the lines
// come back in order, they start at the first byte and end at the last, and
// together they are the paragraph (its spaces at the breaks aside).
@(test)
even_breaking_sets_the_whole_paragraph :: proc(t: ^testing.T) {
	te: Text_Engine; tr: Tree
	even_fixture(t, &te, &tr)
	defer { tree_destroy(&tr); text_engine_destroy(&te) }

	bare :: proc(s: string) -> string {
		out, _ := strings.remove_all(s, " ", context.temp_allocator)
		return out
	}
	prose := string(EVEN_PROSE) // a constant cannot be sliced by a line's bytes
	want := bare(prose)

	for w: f32 = 170; w <= 480; w += 10 {
		ts, ok := typeset(&tr, EVEN_PROSE, Typeset_Style{size = 18, wrap_width = w, justify = true, breaking = .Even})
		testing.expectf(t, ok, "typeset at %v px", w)
		if !ok do continue
		b := strings.builder_make(context.temp_allocator)
		at := 0
		for l, i in ts.lines {
			testing.expectf(t, l.start >= at, "%v px: line %d starts at %d, after %d", w, i, l.start, at)
			testing.expectf(t, l.end >= l.start, "%v px: line %d ends before it starts", w, i)
			strings.write_string(&b, prose[l.start:l.end])
			at = l.end
		}
		testing.expectf(t, ts.lines[0].start == 0, "%v px: the first line starts at the first byte", w)
		testing.expectf(t, ts.lines[len(ts.lines) - 1].end == len(prose), "%v px: the last line ends at the last byte", w)
		testing.expectf(t, bare(strings.to_string(b)) == want, "%v px: the lines are the paragraph", w)
		typeset_destroy(&ts)
	}
}

// What total fit is for: the rag. At 300 px this paragraph's worst line
// stops 58 px short under a greedy fill and 46 px short when the breaks are
// chosen together, and the spread of the lines narrows with it.
@(test)
even_lines_are_more_even_than_a_greedy_fill :: proc(t: ^testing.T) {
	te: Text_Engine; tr: Tree
	even_fixture(t, &te, &tr)
	defer { tree_destroy(&tr); text_engine_destroy(&te) }

	greedy, ok0 := typeset(&tr, EVEN_PROSE, Typeset_Style{size = 18, wrap_width = 300})
	testing.expect(t, ok0, "typeset")
	defer typeset_destroy(&greedy)
	even, ok := typeset(&tr, EVEN_PROSE, Typeset_Style{size = 18, wrap_width = 300, breaking = .Even})
	testing.expect(t, ok, "typeset")
	defer typeset_destroy(&even)

	gw, gsd := even_shortfall(&greedy, 300)
	ew, esd := even_shortfall(&even, 300)
	testing.expectf(t, ew < gw - 1, "the worst line is nearer the margin: %.1f px short against %.1f", ew, gw)
	testing.expectf(t, esd < gsd, "and the lines are closer to each other: sd %.1f against %.1f", esd, gsd)
	testing.expect_value(t, len(even.lines), len(greedy.lines)) // not by setting the paragraph longer
}

// The default is two, and it is a cap on the optimiser
// rather than a preference: unlimited, this paragraph ladders to five
// hyphens in a row at 110 px (thirteen at 120 px), which is what a page
// looks like when nothing is holding the breaker back.
@(test)
no_more_than_two_lines_in_a_row_end_in_a_hyphen :: proc(t: ^testing.T) {
	te: Text_Engine; tr: Tree
	even_fixture(t, &te, &tr)
	defer { tree_destroy(&tr); text_engine_destroy(&te) }

	worst_unlimited := 0
	for w: f32 = 110; w <= 200; w += 10 {
		two, ok0 := typeset(&tr, EVEN_LADDER, Typeset_Style{size = 18, wrap_width = w, breaking = .Even})
		testing.expectf(t, ok0, "typeset at %v px", w)
		if ok0 {
			testing.expectf(t, even_hyphen_run(&two) <= 2, "%v px: %d hyphenated lines in a row", w, even_hyphen_run(&two))
			typeset_destroy(&two)
		}

		one, ok1 := typeset(&tr, EVEN_LADDER, Typeset_Style{size = 18, wrap_width = w, breaking = .Even, hyphen_limit = 1})
		testing.expectf(t, ok1, "typeset at %v px", w)
		if ok1 {
			testing.expectf(t, even_hyphen_run(&one) <= 1, "%v px, asked for one: %d in a row", w, even_hyphen_run(&one))
			typeset_destroy(&one)
		}

		off, ok2 := typeset(&tr, EVEN_LADDER, Typeset_Style{size = 18, wrap_width = w, breaking = .Even, hyphen_limit = -1})
		if ok2 {
			worst_unlimited = max(worst_unlimited, even_hyphen_run(&off))
			typeset_destroy(&off)
		}
	}
	testing.expectf(t, worst_unlimited > 2, "and the cap is what stops it: unlimited reaches %d in a row", worst_unlimited)
}

// A greedy fill honours the cap as far as it can — it gives the hyphen up
// where the line has another break to use. Where it has none it cannot:
// that half needs total fit, and this pins both sides of it rather than
// claiming the greedy fill is enough.
@(test)
a_greedy_fill_gives_up_a_hyphen_where_it_has_another_break :: proc(t: ^testing.T) {
	te: Text_Engine; tr: Tree
	even_fixture(t, &te, &tr)
	defer { tree_destroy(&tr); text_engine_destroy(&te) }

	capped, ok0 := typeset(&tr, EVEN_LADDER, Typeset_Style{size = 18, wrap_width = 270})
	testing.expect(t, ok0, "typeset")
	defer typeset_destroy(&capped)
	loose, ok := typeset(&tr, EVEN_LADDER, Typeset_Style{size = 18, wrap_width = 270, hyphen_limit = -1})
	testing.expect(t, ok, "typeset")
	defer typeset_destroy(&loose)

	testing.expect_value(t, even_hyphen_run(&capped), 2)
	testing.expectf(t, even_hyphen_run(&loose) > 2, "uncapped it ladders: %d in a row", even_hyphen_run(&loose))

	// …and where every break is inside a word, a greedy fill has nothing to
	// fall back to and goes over the cap. Total fit does not.
	narrow, ok1 := typeset(&tr, EVEN_LADDER, Typeset_Style{size = 18, wrap_width = 110})
	testing.expect(t, ok1, "typeset")
	defer typeset_destroy(&narrow)
	even, ok2 := typeset(&tr, EVEN_LADDER, Typeset_Style{size = 18, wrap_width = 110, breaking = .Even})
	testing.expect(t, ok2, "typeset")
	defer typeset_destroy(&even)
	testing.expectf(t, even_hyphen_run(&narrow) > 2, "a greedy fill cannot hold the line here: %d in a row", even_hyphen_run(&narrow))
	testing.expectf(t, even_hyphen_run(&even) <= 2, "total fit can: %d in a row", even_hyphen_run(&even))
}

// A reader should not be left finishing a paragraph on
// half a word. At 420 px and at 240 px a greedy fill hyphenates this
// paragraph's last full line and total fit does not — and it is the
// demerits doing it, not luck, so the rest of the page is unchanged.
@(test)
the_last_full_line_keeps_its_word_whole :: proc(t: ^testing.T) {
	te: Text_Engine; tr: Tree
	even_fixture(t, &te, &tr)
	defer { tree_destroy(&tr); text_engine_destroy(&te) }

	for w in ([?]f32{420, 240}) {
		greedy, ok0 := typeset(&tr, EVEN_PROSE, Typeset_Style{size = 18, wrap_width = w, justify = true})
		testing.expectf(t, ok0, "typeset at %v px", w)
		even, ok := typeset(&tr, EVEN_PROSE, Typeset_Style{size = 18, wrap_width = w, justify = true, breaking = .Even})
		testing.expectf(t, ok, "typeset at %v px", w)
		if !ok0 || !ok do continue
		testing.expectf(t, even_last_full_line_hyphenated(&greedy), "%v px: a greedy fill breaks the last word", w)
		testing.expectf(t, !even_last_full_line_hyphenated(&even), "%v px: total fit keeps it whole", w)
		testing.expectf(t, len(even.lines) <= len(greedy.lines), "%v px: and not by adding a line", w)
		typeset_destroy(&greedy)
		typeset_destroy(&even)
	}
}

// A tab's advance depends on where its line starts, which is what the
// breaking is still deciding — so a paragraph holding one is filled
// greedily whatever it asked for, rather than measured wrongly. The lines
// come out identical to a greedy fill's, down to the tab stops.
@(test)
a_tabbed_paragraph_falls_back_to_a_greedy_fill :: proc(t: ^testing.T) {
	te: Text_Engine; tr: Tree
	even_fixture(t, &te, &tr)
	defer { tree_destroy(&tr); text_engine_destroy(&te) }

	text := "Name\tQuantity\tPrice\nA much longer row of words that has to wrap somewhere\tand\there"
	greedy, ok0 := typeset(&tr, text, Typeset_Style{size = 16, wrap_width = 260})
	testing.expect(t, ok0, "typeset")
	defer typeset_destroy(&greedy)
	even, ok := typeset(&tr, text, Typeset_Style{size = 16, wrap_width = 260, breaking = .Even})
	testing.expect(t, ok, "typeset")
	defer typeset_destroy(&even)

	testing.expect_value(t, len(even.lines), len(greedy.lines))
	for l, i in even.lines {
		testing.expectf(t, l.start == greedy.lines[i].start && l.end == greedy.lines[i].end,
			"line %d holds the same text: %d..%d against %d..%d", i, l.start, l.end, greedy.lines[i].start, greedy.lines[i].end)
		testing.expectf(t, abs(l.rect.w - greedy.lines[i].rect.w) < 0.01, "and measures the same: %v against %v", l.rect.w, greedy.lines[i].rect.w)
	}
}

// An empty paragraph, a paragraph of one word, and a word longer than its
// column: the edges a breaker falls over. Nothing is lost, and the long
// word overhangs rather than disappearing (as it does in a greedy fill).
@(test)
even_breaking_holds_up_at_the_edges :: proc(t: ^testing.T) {
	te: Text_Engine; tr: Tree
	even_fixture(t, &te, &tr)
	defer { tree_destroy(&tr); text_engine_destroy(&te) }

	style := Typeset_Style{size = 18, wrap_width = 120, justify = true, breaking = .Even}

	empty, ok0 := typeset(&tr, "", style)
	testing.expect(t, ok0, "typeset of nothing")
	testing.expect_value(t, len(empty.lines), 1)
	typeset_destroy(&empty)

	blank, ok1 := typeset(&tr, "\n\n", style)
	testing.expect(t, ok1, "typeset of blank lines")
	testing.expect_value(t, len(blank.lines), 3)
	typeset_destroy(&blank)

	one, ok2 := typeset(&tr, "Alice", style)
	testing.expect(t, ok2, "typeset of one word")
	testing.expect_value(t, len(one.lines), 1)
	testing.expect_value(t, one.lines[0].start, 0)
	testing.expect_value(t, one.lines[0].end, len("Alice"))
	typeset_destroy(&one)

	long := "Pneumonoultramicroscopicsilicovolcanoconiosis and more"
	over, ok3 := typeset(&tr, long, style)
	testing.expect(t, ok3, "typeset of an unbreakable word")
	testing.expect(t, len(over.lines) >= 2, "the rest of the text still wrapped")
	testing.expect_value(t, over.lines[0].start, 0)
	testing.expect_value(t, over.lines[len(over.lines) - 1].end, len(long))
	testing.expect(t, over.lines[0].rect.w > 120, "and the long word overhangs rather than vanishing")
	typeset_destroy(&over)
}

// even_word_gaps measures the space drawn between words on the full lines,
// through the public caret — so it is the gap a reader sees and not
// anything the breaker believes. Widest, tightest, and the median.
@(private = "file")
even_word_gaps :: proc(ts: ^Typeset) -> (wide, tight, typical: f32) {
	all := make([dynamic]f32, 0, 64, context.temp_allocator)
	for l, li in ts.lines {
		if li >= len(ts.lines) - 1 do break // the last line is short on purpose
		for i := l.start; i < l.end; i += 1 {
			if ts.text[i] != ' ' do continue
			g := typeset_caret(ts, i + 1).x - typeset_caret(ts, i).x
			if g > 0 do append(&all, g)
		}
	}
	if len(all) == 0 do return
	slice.sort(all[:])
	return all[len(all) - 1], all[0], all[len(all) / 2]
}

// A justified line is **tightened** as well as spread: the total fit counts
// on a space giving back a third of itself (Knuth's figure), and this is
// where it does. Without it a narrow column's worst line has word gaps near
// three spaces wide.
@(test)
a_justified_line_is_tightened_as_well_as_spread :: proc(t: ^testing.T) {
	te: Text_Engine; tr: Tree
	even_fixture(t, &te, &tr)
	defer { tree_destroy(&tr); text_engine_destroy(&te) }

	// the natural space, from a ragged setting where nothing is adjusted
	plain, okp := typeset(&tr, EVEN_PROSE, Typeset_Style{size = 18, wrap_width = 300})
	testing.expect(t, okp, "typeset")
	defer typeset_destroy(&plain)
	_, natural, _ := even_word_gaps(&plain)
	testing.expect(t, natural > 0, "there are spaces to measure")

	greedy, ok0 := typeset(&tr, EVEN_PROSE, Typeset_Style{size = 18, wrap_width = 300, justify = true})
	testing.expect(t, ok0, "typeset")
	defer typeset_destroy(&greedy)
	even, ok := typeset(&tr, EVEN_PROSE, Typeset_Style{size = 18, wrap_width = 300, justify = true, breaking = .Even})
	testing.expect(t, ok, "typeset")
	defer typeset_destroy(&even)

	gw, _, _ := even_word_gaps(&greedy)
	ew, et, _ := even_word_gaps(&even)
	testing.expectf(t, ew < gw - 1, "the widest word gap is narrower: %.1f px against %.1f", ew, gw)
	testing.expectf(t, et < natural - 0.1, "some line was pulled in, not only spread: tightest %.1f, natural %.1f", et, natural)
	testing.expectf(t, et > natural * 0.6, "and never by more than a third of a space: %.1f", et)
}

// …but a **ragged** line is never tightened, so the breaker is offered no
// shrink there at all. Offered shrink it cannot spend, it picks lines that
// overrun the column.
@(test)
a_ragged_paragraph_is_never_tightened :: proc(t: ^testing.T) {
	te: Text_Engine; tr: Tree
	even_fixture(t, &te, &tr)
	defer { tree_destroy(&tr); text_engine_destroy(&te) }

	for w: f32 = 200; w <= 400; w += 20 {
		ts, ok := typeset(&tr, EVEN_PROSE, Typeset_Style{size = 18, wrap_width = w, breaking = .Even})
		testing.expectf(t, ok, "typeset at %v px", w)
		if !ok do continue
		wide, tight, _ := even_word_gaps(&ts)
		testing.expectf(t, abs(wide - tight) < 0.01, "%v px: every word gap is the font's own space: %.2f..%.2f", w, tight, wide)
		typeset_destroy(&ts)
	}
}

}
