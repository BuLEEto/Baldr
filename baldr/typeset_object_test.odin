package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A picture in a line: the app gives a box (width, height, how far it hangs
// below the baseline) at a U+FFFC in the text; typesetting makes room for it
// and says where it ended up, and the app draws its own picture there — a
// book that sets rare name glyphs as small images mid-sentence, say.

@(private = "file")
OBJ :: "￼" // OBJECT REPLACEMENT CHARACTER

@(private = "file")
to_fixture :: proc(t: ^testing.T) -> (tr: ^Tree, te: ^Text_Engine, ok: bool) {
	tr = new(Tree)
	te = new(Text_Engine)
	if !text_engine_init(te) {
		free(tr); free(te)
		return nil, nil, false
	}
	tree_init(tr)
	tree_use_text_engine(tr, te)
	return tr, te, true
}

@(private = "file")
to_destroy :: proc(tr: ^Tree, te: ^Text_Engine) {
	tree_destroy(tr)
	text_engine_destroy(te)
	free(tr)
	free(te)
}

// The box takes its room on the line, and the line says where it is.
@(test)
a_picture_in_a_line_takes_its_room_and_says_where_it_is :: proc(t: ^testing.T) {
	tr, te, ok := to_fixture(t)
	if !ok do return
	defer to_destroy(tr, te)

	text := strings.concatenate({"The name ", OBJ, " appears twice."}, context.temp_allocator)
	at := strings.index(text, OBJ)
	style := Typeset_Style{size = 16, wrap_width = 400}
	plain, pok := typeset(tr, text, style)
	testing.expect(t, pok, "typeset without an object")
	defer typeset_destroy(&plain)

	style.objects = []Typeset_Object{{at = at, size = {24, 20}, baseline = 4, label = "Li"}}
	ts, ok2 := typeset(tr, text, style)
	testing.expect(t, ok2, "typeset with one")
	defer typeset_destroy(&ts)

	testing.expect_value(t, len(ts.objects), 1)
	o := ts.objects[0]
	testing.expect_value(t, o.index, 0)
	testing.expect_value(t, o.at, at)
	testing.expect_value(t, o.line, 0)
	testing.expect_value(t, o.rect.w, 24)
	testing.expect_value(t, o.rect.h, 20)

	// it sits where it asked to: 4 px of it below the baseline
	bl := ts.lines[0].baseline
	testing.expectf(t, abs((o.rect.y + o.rect.h) - (bl + 4)) < 0.01,
		"its bottom edge is 4 px under the baseline: %.2f against %.2f", o.rect.y + o.rect.h, bl + 4)

	// the line is 24 px wider than the same text with no box in it, and the
	// words after the box moved over by exactly that much
	testing.expectf(t, abs((ts.lines[0].rect.w - plain.lines[0].rect.w) - 24) < 0.5,
		"the line grew by the box's width: %.1f against %.1f", ts.lines[0].rect.w, plain.lines[0].rect.w)
	after_x := func_glyph_x(&ts, at + len(OBJ))
	plain_x := func_glyph_x(&plain, at + len(OBJ))
	testing.expectf(t, abs((after_x - plain_x) - 24) < 0.5,
		"the text after it moved over by the box's width: %.1f against %.1f", after_x, plain_x)
}

// func_glyph_x is where the glyph for byte `at` starts.
@(private = "file")
func_glyph_x :: proc(ts: ^Typeset, at: int) -> f32 {
	for g in ts.glyphs do if g.start == at do return g.x0
	return -1
}

// A box taller than the text makes its line taller, instead of drawing
// over the lines around it.
@(test)
a_tall_picture_opens_its_own_line :: proc(t: ^testing.T) {
	tr, te, ok := to_fixture(t)
	if !ok do return
	defer to_destroy(tr, te)

	text := strings.concatenate({"One line.\nTwo ", OBJ, " line.\nThree line."}, context.temp_allocator)
	at := strings.index(text, OBJ)
	style := Typeset_Style{size = 16, wrap_width = 400}
	plain, _ := typeset(tr, text, style)
	defer typeset_destroy(&plain)
	style.objects = []Typeset_Object{{at = at, size = {18, 60}, baseline = 6}}
	ts, _ := typeset(tr, text, style)
	defer typeset_destroy(&ts)

	testing.expect_value(t, len(ts.lines), 3)
	testing.expectf(t, ts.lines[1].rect.h >= 60, "the line holding a 60 px box is at least that tall: %.1f", ts.lines[1].rect.h)
	testing.expect_value(t, ts.lines[0].rect.h, plain.lines[0].rect.h) // the others are as they were
	testing.expect_value(t, ts.lines[2].rect.h, plain.lines[2].rect.h)
	// …and the lines below it were pushed down, not drawn over
	testing.expect(t, ts.lines[2].rect.y >= ts.lines[1].rect.y + 60, "the line after it starts below it")
	// the box is inside its line
	o := ts.objects[0]
	testing.expect_value(t, o.line, 1)
	testing.expect(t, o.rect.y >= ts.lines[1].rect.y - 0.01 && o.rect.y + o.rect.h <= ts.lines[1].rect.y + ts.lines[1].rect.h + 0.01,
		"the box is within the line it made room on")
}

// A box wraps with the words: too near the margin and it goes to the next
// line, taking its room with it.
@(test)
a_picture_wraps_with_the_words_around_it :: proc(t: ^testing.T) {
	tr, te, ok := to_fixture(t)
	if !ok do return
	defer to_destroy(tr, te)

	text := strings.concatenate({"aaa bbb ccc ddd ", OBJ, " eee fff"}, context.temp_allocator)
	at := strings.index(text, OBJ)
	wide := Typeset_Style{size = 16, wrap_width = 400}
	wide.objects = []Typeset_Object{{at = at, size = {40, 16}}}
	one, _ := typeset(tr, text, wide)
	defer typeset_destroy(&one)
	testing.expect_value(t, len(one.lines), 1)
	testing.expect_value(t, one.objects[0].line, 0)

	narrow := wide
	narrow.wrap_width = 120
	ts, _ := typeset(tr, text, narrow)
	defer typeset_destroy(&ts)
	testing.expect(t, len(ts.lines) > 1, "it wraps at 120 px")
	o := ts.objects[0]
	testing.expect(t, o.rect.x + o.rect.w <= 120 + 0.5, "the box stayed inside the column")
	line := ts.lines[o.line]
	testing.expect(t, o.rect.y >= line.rect.y - 0.01, "and on the line it belongs to")
}

// Every box is placed, in reading order, and one the style forgot takes
// no room at all rather than the empty box a font would draw.
@(test)
several_pictures_are_placed_in_order_and_a_forgotten_one_is_nothing :: proc(t: ^testing.T) {
	tr, te, ok := to_fixture(t)
	if !ok do return
	defer to_destroy(tr, te)

	text := strings.concatenate({"a ", OBJ, " b ", OBJ, " c ", OBJ, " d"}, context.temp_allocator)
	ats: [3]int
	from := 0
	for i in 0 ..< 3 {
		ats[i] = strings.index(text[from:], OBJ) + from
		from = ats[i] + len(OBJ)
	}
	style := Typeset_Style{size = 16, wrap_width = 600}
	// the middle one is left out on purpose
	style.objects = []Typeset_Object{{at = ats[0], size = {20, 16}}, {at = ats[2], size = {30, 16}}}
	ts, _ := typeset(tr, text, style)
	defer typeset_destroy(&ts)

	testing.expect_value(t, len(ts.objects), 2)
	testing.expect_value(t, ts.objects[0].at, ats[0])
	testing.expect_value(t, ts.objects[1].at, ats[2])
	testing.expect(t, ts.objects[0].rect.x < ts.objects[1].rect.x, "in reading order")

	// the one with no object of its own draws nothing and takes no room:
	// the glyph for it is blank and as wide as nothing
	for g in ts.glyphs do if g.start == ats[1] {
		testing.expect(t, g.blank, "a U+FFFC with no box draws nothing")
		testing.expect_value(t, g.x1 - g.x0, 0)
	}
}

// Total fit sees a box as material like any other, since a book's pages
// are set with .Even.
@(test)
a_picture_is_material_to_the_total_fit_breaker :: proc(t: ^testing.T) {
	tr, te, ok := to_fixture(t)
	if !ok do return
	defer to_destroy(tr, te)

	b := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< 12 do strings.write_string(&b, "word ")
	strings.write_string(&b, OBJ)
	for _ in 0 ..< 12 do strings.write_string(&b, " word")
	text := strings.to_string(b)
	at := strings.index(text, OBJ)
	style := Typeset_Style{size = 16, wrap_width = 200, breaking = .Even, justify = true}
	style.objects = []Typeset_Object{{at = at, size = {56, 16}}}
	ts, ok2 := typeset(tr, text, style)
	testing.expect(t, ok2, "total fit with a box in it")
	defer typeset_destroy(&ts)

	testing.expect_value(t, len(ts.objects), 1)
	o := ts.objects[0]
	testing.expect(t, o.rect.x + o.rect.w <= 200 + 0.5, "the box is inside the column the breaker was given")
	for l in ts.lines do testing.expectf(t, l.rect.w <= 200 + 0.5, "and no line overran it: %.1f", l.rect.w)
}


// Accessibility is half of this feature: a name set as a picture would
// otherwise go missing from the sentence a screen reader is given. The
// label stands in for the box, and a box with nothing to say is dropped
// rather than read out as an unknown character.
@(test)
a_picture_reads_as_its_label :: proc(t: ^testing.T) {
	tr, te, ok := to_fixture(t)
	if !ok do return
	defer to_destroy(tr, te)
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tree_use_text_engine(&ui.tree, te)

	text := strings.concatenate({"The scholar ", OBJ, " wrote it, and ", OBJ, " copied it."}, context.temp_allocator)
	first := strings.index(text, OBJ)
	second := strings.index(text[first + len(OBJ):], OBJ) + first + len(OBJ)
	style := Typeset_Style{size = 16, wrap_width = 600}
	style.objects = []Typeset_Object{
		{at = first, size = {16, 16}, label = "Li Bai"},
		{at = second, size = {16, 16}}, // no label: nothing to say
	}
	ts, ok2 := typeset(&ui.tree, text, style)
	testing.expect(t, ok2)
	defer typeset_destroy(&ts)

	begin_view(&ui)
	column(&ui)
	n := typeset_view(&ui, &ts, key = 1)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {700, 300})

	read := node_get(&ui.tree, n).access.value_text
	testing.expect_value(t, read, "The scholar Li Bai wrote it, and  copied it.")
	testing.expect(t, !strings.contains_rune(read, 0xFFFC), "no object replacement character reaches a reader")
}


// A reader selects across its pages, so the box has to behave like a
// character to the things that answer "what is under this point" and
// "where is this byte": a click on the picture lands on it, and a
// selection that covers it covers its room on the line.
@(test)
a_picture_answers_hit_testing_like_a_character :: proc(t: ^testing.T) {
	tr, te, ok := to_fixture(t)
	if !ok do return
	defer to_destroy(tr, te)

	text := strings.concatenate({"before ", OBJ, " after"}, context.temp_allocator)
	at := strings.index(text, OBJ)
	style := Typeset_Style{size = 16, wrap_width = 400}
	style.objects = []Typeset_Object{{at = at, size = {40, 18}, baseline = 3}}
	ts, _ := typeset(tr, text, style)
	defer typeset_destroy(&ts)
	o := ts.objects[0]

	// a click in the middle of the picture is a click on it
	hit := typeset_hit(&ts, {o.rect.x + o.rect.w / 2, o.rect.y + o.rect.h / 2})
	testing.expect_value(t, hit, at)
	// …and one just past it is the text after it
	after := typeset_hit(&ts, {o.rect.x + o.rect.w + 2, o.rect.y + o.rect.h / 2})
	testing.expect(t, after > at, "past the picture is past it")

	// the caret before the picture sits at its left edge
	caret := typeset_caret(&ts, at)
	testing.expectf(t, abs(caret.x - o.rect.x) < 0.5, "the caret before it is at its edge: %.1f against %.1f", caret.x, o.rect.x)

	// a selection over it is as wide as the room it takes
	rects := typeset_rects(&ts, at, at + len(OBJ), context.temp_allocator)
	testing.expect_value(t, len(rects), 1)
	testing.expectf(t, abs(rects[0].w - o.rect.w) < 0.5, "the selection covers the box: %.1f against %.1f", rects[0].w, o.rect.w)
}

}
