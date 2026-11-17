package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Text set into a picture, with the geometry to edit it.


@(private = "file")
fixture :: proc(t: ^testing.T, te: ^Text_Engine, tr: ^Tree) {
	if !text_engine_init(te) do testing.fail_now(t, "text_engine_init: embedded fonts failed to load")
	tree_init(tr)
	tree_use_text_engine(tr, te)
}

@(private = "file")
set :: proc(t: ^testing.T, tr: ^Tree, text: string, style: Typeset_Style) -> Typeset {
	ts, ok := typeset(tr, text, style)
	testing.expect(t, ok, "typeset")
	return ts
}

@(private = "file")
near :: proc(a, b: f32, eps: f32 = 0.01) -> bool { return abs(a - b) <= eps }

@(private = "file")
line_text :: proc(ts: ^Typeset, i: int) -> string { return ts.text[ts.lines[i].start:ts.lines[i].end] }

// One line in the theme's typeface: the box is its advance by the face's
// line height, the baseline at its ascent, and the caret walks left to
// right, a hit on each caret place giving it back.
@(test)
typeset_sets_a_line_and_places_the_caret :: proc(t: ^testing.T) {
	te: Text_Engine
	tr: Tree
	fixture(t, &te, &tr)
	defer text_engine_destroy(&te)
	defer tree_destroy(&tr)

	ts := set(t, &tr, "Hello", {size = 100})
	defer typeset_destroy(&ts)
	testing.expect(t, ts.family == "" && ts.weight == 400, "the theme's typeface, regular")
	testing.expect_value(t, len(ts.lines), 1)
	testing.expect(t, near(ts.size.y, 100 * 2478.0 / 2048), "Inter's line height") // upem 2048, ascent 1984, descent -494
	testing.expect(t, near(ts.lines[0].baseline, 100 * 1984.0 / 2048), "the baseline at the ascent")
	testing.expect(t, ts.size.x > 200 && ts.size.x < 300, "five letters at 100 px")
	bottom := ts.ink.y + ts.ink.h - ts.lines[0].baseline
	testing.expectf(t, near(bottom, 100 * 24.0 / 2048, 0.05), "the ink ends at the 'o's overshoot below the baseline: %v px", bottom) // Inter: 'o' reaches -24, 'H' and 'l' 1490
	testing.expect(t, near(ts.ink.y, ts.lines[0].baseline - 100 * 1490.0 / 2048, 0.05), "and starts at the capitals' height")

	prev: f32 = -1
	for o in 0 ..= 5 {
		c := typeset_caret(&ts, o)
		testing.expect(t, c.x > prev, "the caret walks right")
		testing.expect(t, c.w == 0 && c.y == 0 && near(c.h, ts.size.y), "as tall as its line")
		testing.expect_value(t, typeset_hit(&ts, {c.x + 0.4, 10}), o)
		prev = c.x
	}
	testing.expect_value(t, typeset_caret(&ts, 0).x, 0)
	testing.expect(t, near(typeset_caret(&ts, 5).x, ts.size.x), "the end at the box's edge")
	testing.expect_value(t, typeset_hit(&ts, {-50, -50}), 0)
	testing.expect_value(t, typeset_hit(&ts, {1000, 1000}), 5)

	_, bad := typeset(&tr, "x", {size = 0})
	testing.expect(t, !bad, "no size, no text")
	none: Tree
	tree_init(&none)
	defer tree_destroy(&none)
	_, headless := typeset(&none, "x", {size = 10})
	testing.expect(t, !headless, "no text engine, no text")
}

// A wrap breaks between words; a space where a line wraps hangs past the
// edge rather than pushing the word before it down, and does not count in
// the line's width. A word longer than the line breaks between letters.
@(test)
a_typeset_wraps_and_spaces_hang :: proc(t: ^testing.T) {
	te: Text_Engine
	tr: Tree
	fixture(t, &te, &tr)
	defer text_engine_destroy(&te)
	defer tree_destroy(&tr)

	pair := set(t, &tr, "one two", {size = 40})
	defer typeset_destroy(&pair)
	w := pair.size.x
	ts := set(t, &tr, "one two three four", {size = 40, wrap_width = w + 0.5})
	defer typeset_destroy(&ts)
	testing.expect_value(t, len(ts.lines), 3)
	testing.expect_value(t, line_text(&ts, 0), "one two ") // its space hangs: "two" did not go down
	testing.expect_value(t, line_text(&ts, 1), "three ")
	testing.expect_value(t, line_text(&ts, 2), "four")
	testing.expect(t, near(ts.lines[0].rect.w, w), "the hanging space is not in its width")
	testing.expect(t, near(ts.size.x, w + 0.5), "the box is the wrap width")
	testing.expect(t, near(ts.lines[1].rect.y, ts.lines[0].rect.h), "lines stack")
	testing.expect_value(t, typeset_line_of(&ts, 8), 1) // where the wrap splits the text: the next line
	testing.expect_value(t, typeset_caret(&ts, 8).x, 0)
	testing.expect_value(t, typeset_hit(&ts, {w + 200, 5}), 7) // past a wrapped line's end: before its space

	long := set(t, &tr, "abcdefghijklmnop", {size = 40, wrap_width = 100})
	defer typeset_destroy(&long)
	testing.expect(t, len(long.lines) > 2, "broken between letters")
	for l in long.lines do testing.expect(t, l.rect.w <= 100 + 0.01, "each within the width")
}

// Tracking goes between characters, not after the last, in thousandths of
// an em, and counts when a line is filled.
@(test)
tracking_spreads_characters_and_counts_in_the_wrap :: proc(t: ^testing.T) {
	te: Text_Engine
	tr: Tree
	fixture(t, &te, &tr)
	defer text_engine_destroy(&te)
	defer tree_destroy(&tr)

	plain := set(t, &tr, "abcde", {size = 50})
	defer typeset_destroy(&plain)
	wide := set(t, &tr, "abcde", {size = 50, tracking = 100})
	defer typeset_destroy(&wide)
	testing.expectf(t, near(wide.size.x - plain.size.x, 4 * 5), "four gaps of a tenth of 50 px: %v", wide.size.x - plain.size.x)
	testing.expect(t, near(typeset_caret(&wide, 1).x - typeset_caret(&plain, 1).x, 5), "after the first character")
	tight := set(t, &tr, "abcde", {size = 50, tracking = -50})
	defer typeset_destroy(&tight)
	testing.expect(t, near(plain.size.x - tight.size.x, 4 * 2.5), "negative tightens")

	words := set(t, &tr, "aaaa bbbb", {size = 50})
	defer typeset_destroy(&words)
	fits := set(t, &tr, "aaaa bbbb", {size = 50, wrap_width = words.size.x + 1})
	defer typeset_destroy(&fits)
	testing.expect_value(t, len(fits.lines), 1)
	tracked := set(t, &tr, "aaaa bbbb", {size = 50, wrap_width = words.size.x + 1, tracking = 50})
	defer typeset_destroy(&tracked)
	testing.expect_value(t, len(tracked.lines), 2) // the tracking pushes it over
}

// Lines sit by `align` in the box; a justified line but the paragraph's
// last reaches both edges, its spaces taking the room.
@(test)
typeset_aligns_and_justifies :: proc(t: ^testing.T) {
	te: Text_Engine
	tr: Tree
	fixture(t, &te, &tr)
	defer text_engine_destroy(&te)
	defer tree_destroy(&tr)

	text :: "a line of words to wrap in a box"
	for align in Text_Align {
		ts := set(t, &tr, text, {size = 30, wrap_width = 260, align = align})
		defer typeset_destroy(&ts)
		for l in ts.lines {
			x: f32
			switch align {
			case .Start:  x = 0
			case .Center: x = (260 - l.rect.w) / 2
			case .End:    x = 260 - l.rect.w
			}
			testing.expectf(t, near(l.rect.x, x), "%v: line at %v, want %v", align, l.rect.x, x)
		}
	}
	ts := set(t, &tr, text, {size = 30, wrap_width = 260, justify = true, align = .Center})
	defer typeset_destroy(&ts)
	testing.expect(t, len(ts.lines) >= 2, "it wraps")
	for l, i in ts.lines {
		if i == len(ts.lines) - 1 {
			testing.expect(t, near(l.rect.x, (260 - l.rect.w) / 2), "the last line keeps its alignment")
			continue
		}
		testing.expect(t, l.rect.x == 0 && near(l.rect.w, 260), "a justified line spans the box")
		last := l.end
		for last > l.start && ts.text[last - 1] == ' ' do last -= 1
		testing.expectf(t, near(typeset_caret(&ts, last).x, 260, 0.05), "its last letter at the edge: %v", typeset_caret(&ts, last).x)
	}
}

// Line breaks end paragraphs ("\r\n" is one), a text ending in one has an
// empty last line for the caret, and the line height is baseline to
// baseline.
@(test)
typeset_paragraphs_and_line_height :: proc(t: ^testing.T) {
	te: Text_Engine
	tr: Tree
	fixture(t, &te, &tr)
	defer text_engine_destroy(&te)
	defer tree_destroy(&tr)

	ts := set(t, &tr, "ab\r\ncd\n", {size = 40, line_height = 60})
	defer typeset_destroy(&ts)
	testing.expect_value(t, len(ts.lines), 3)
	testing.expect_value(t, line_text(&ts, 0), "ab")
	testing.expect_value(t, line_text(&ts, 1), "cd")
	testing.expect(t, ts.lines[2].start == 7 && ts.lines[2].end == 7, "an empty last line")
	testing.expect(t, near(ts.lines[1].baseline - ts.lines[0].baseline, 60), "baseline to baseline")
	testing.expect(t, near(ts.size.y, 180), "three lines of 60")
	testing.expect_value(t, typeset_line_of(&ts, 2), 0) // before the break: the end of its line
	testing.expect_value(t, typeset_line_of(&ts, 3), 0) // inside "\r\n"
	testing.expect_value(t, typeset_line_of(&ts, 4), 1)
	c := typeset_caret(&ts, 7)
	testing.expect(t, c.x == 0 && near(c.y, 120), "the caret after the last break: the empty line")
	testing.expect_value(t, typeset_hit(&ts, {5, 170}), 7)

	empty := set(t, &tr, "", {size = 40})
	defer typeset_destroy(&empty)
	testing.expect(t, len(empty.lines) == 1 && empty.size.x == 0 && empty.size.y > 0, "one empty line")
	testing.expect_value(t, typeset_caret(&empty, 0), Rect{0, 0, 0, empty.size.y})
}

// A selection's rectangles: one per line it touches, each over just its
// characters; one character's bytes give where that character is.
@(test)
typeset_rects_cover_a_selection :: proc(t: ^testing.T) {
	te: Text_Engine
	tr: Tree
	fixture(t, &te, &tr)
	defer text_engine_destroy(&te)
	defer tree_destroy(&tr)

	pair := set(t, &tr, "one two", {size = 40})
	defer typeset_destroy(&pair)
	ts := set(t, &tr, "one two three", {size = 40, wrap_width = pair.size.x + 1})
	defer typeset_destroy(&ts)
	testing.expect_value(t, len(ts.lines), 2)
	rs := typeset_rects(&ts, 4, 10, context.temp_allocator) // "two " and "th"
	testing.expect_value(t, len(rs), 2)
	if len(rs) == 2 {
		testing.expect(t, near(rs[0].x, typeset_caret(&ts, 4).x) && rs[0].y == 0, "from 't' on the first line")
		testing.expect(t, rs[1].x == 0 && near(rs[1].w, typeset_caret(&ts, 10).x) && near(rs[1].y, ts.lines[1].rect.y), "to 'h' on the second")
	}
	one := typeset_rects(&ts, 1, 2, context.temp_allocator) // the 'n'
	testing.expect(t, len(one) == 1 && near(one[0].x, typeset_caret(&ts, 1).x) && near(one[0].x + one[0].w, typeset_caret(&ts, 2).x), "where one character is")
	testing.expect_value(t, len(typeset_rects(&ts, 5, 5, context.temp_allocator)), 0)
	testing.expect_value(t, len(typeset_rects(&ts, 10, 4, context.temp_allocator)), 2) // either way round
}

// Right-to-left text is read from the right: its first character's caret
// is at the right edge, Start aligns right, a wrapped paragraph's first
// words are on its first line, and a hanging space is on the left. A
// left-to-right word inside keeps its own order.
@(test)
typeset_sets_right_to_left_text :: proc(t: ^testing.T) {
	te: Text_Engine
	tr: Tree
	fixture(t, &te, &tr)
	defer text_engine_destroy(&te)
	defer tree_destroy(&tr)

	HEBREW :: "שלום עולם" // "shalom olam": 4 letters, a space, 4 letters, two bytes each
	ts := set(t, &tr, HEBREW, {size = 40})
	defer typeset_destroy(&ts)
	testing.expect(t, near(typeset_caret(&ts, 0).x, ts.size.x), "read from the right")
	testing.expect(t, near(typeset_caret(&ts, len(HEBREW)).x, 0), "ending on the left")
	testing.expect(t, typeset_caret(&ts, 2).x < typeset_caret(&ts, 0).x, "the second letter left of the first")
	testing.expect_value(t, typeset_hit(&ts, {ts.size.x - 0.2, 5}), 0)

	first := set(t, &tr, "שלום", {size = 40})
	defer typeset_destroy(&first)
	wrapped := set(t, &tr, HEBREW, {size = 40, wrap_width = first.size.x + 30})
	defer typeset_destroy(&wrapped)
	testing.expect_value(t, len(wrapped.lines), 2)
	testing.expect_value(t, line_text(&wrapped, 0), "שלום ")
	l := wrapped.lines[0]
	testing.expect(t, near(l.rect.x + l.rect.w, first.size.x + 30), "Start is the right edge")
	testing.expect(t, near(typeset_caret(&wrapped, 0).x, first.size.x + 30), "its first letter at the right")
	testing.expect(t, typeset_caret(&wrapped, 8).x < l.rect.x + 0.01, "its space hangs on the left")

	mixed := set(t, &tr, "שלום abc עולם", {size = 40})
	defer typeset_destroy(&mixed)
	a, b, c := typeset_caret(&mixed, 9).x, typeset_caret(&mixed, 10).x, typeset_caret(&mixed, 11).x
	testing.expect(t, a < b && b < c, "the Latin word reads left to right inside")
	testing.expect(t, typeset_caret(&mixed, 0).x > c, "after the right-to-left start")
}

// Drawn into a picture: the glyphs' pixels in the colour, nothing outside
// the ink touched, only the part drawn marked changed. Into a mask: the
// same coverage, by its op. An emoji keeps its colours.
@(test)
typeset_draws_into_a_picture_and_a_mask :: proc(t: ^testing.T) {
	te: Text_Engine
	tr: Tree
	fixture(t, &te, &tr)
	defer text_engine_destroy(&te)
	defer tree_destroy(&tr)

	ts := set(t, &tr, "Hi", {size = 60})
	defer typeset_destroy(&ts)
	px := make([]u8, 200 * 120 * 4, context.temp_allocator)
	for &v in px do v = 255
	img, _ := image_from_rgba(200, 120, px)
	defer image_destroy(&img)
	at := [2]f32{20.5, 10}
	typeset_draw(&ts, &img, at, rgb(0x000000))
	dark, touched_outside := 0, false
	for y in 0 ..< 120 do for x in 0 ..< 200 {
		p := img.pixels[(y * 200 + x) * 4:][:4]
		inside := f32(x) >= at.x + ts.ink.x - 1 && f32(x) < at.x + ts.ink.x + ts.ink.w + 1 && f32(y) >= at.y + ts.ink.y - 1 && f32(y) < at.y + ts.ink.y + ts.ink.h + 1
		if p[0] < 40 do dark += 1
		if !inside && p[0] != 255 do touched_outside = true
	}
	testing.expect(t, dark > 300, "the letters' stems are black")
	testing.expect(t, !touched_outside, "nothing outside the ink")
	d := img.dirty
	testing.expect(t, d[2] > d[0] && f32(d[0]) >= at.x + ts.ink.x - 2 && f32(d[2]) <= at.x + ts.ink.x + ts.ink.w + 2, "only the part drawn is marked")

	m, _ := mask_make({0, 0}, {200, 120})
	defer mask_destroy(&m)
	typeset_mask(&ts, &m, at)
	covered := 0
	for v in m.alpha do if v > 215 do covered += 1
	testing.expect(t, abs(covered - dark) < dark / 10, "the mask covers what was drawn")
	full, _ := mask_make({0, 0}, {200, 120})
	defer mask_destroy(&full)
	for &v in full.alpha do v = 255
	typeset_mask(&ts, &full, at, .Intersect)
	testing.expect_value(t, mask_at(&full, {5, 5}), 0) // outside the text: gone
	testing.expect(t, string(full.alpha) == string(m.alpha), "intersected with everything: the text")

	emoji := set(t, &tr, "😀", {size = 64})
	defer typeset_destroy(&emoji)
	epx := make([]u8, 100 * 100 * 4, context.temp_allocator)
	eimg, _ := image_from_rgba(100, 100, epx)
	defer image_destroy(&eimg)
	typeset_draw(&emoji, &eimg, {10, 10}, rgb(0x000000))
	colourful := false
	for i in 0 ..< 100 * 100 {
		p := eimg.pixels[i * 4:][:4]
		if p[3] > 200 && int(p[0]) - int(p[2]) > 60 do colourful = true // a yellow face: red well over blue
	}
	testing.expect(t, colourful, "the emoji in its own colours")
}

// Weight and family: the theme's typeface is set to any weight its axis
// has (clamped at its ends); a family the machine does not have is set in
// the theme's typeface and says so.
@(test)
typeset_takes_a_weight_and_a_family :: proc(t: ^testing.T) {
	te: Text_Engine
	tr: Tree
	fixture(t, &te, &tr)
	defer text_engine_destroy(&te)
	defer tree_destroy(&tr)

	regular := set(t, &tr, "Weight", {size = 50})
	defer typeset_destroy(&regular)
	bold := set(t, &tr, "Weight", {size = 50, weight = 700})
	defer typeset_destroy(&bold)
	testing.expect_value(t, bold.weight, 700)
	testing.expect(t, bold.size.x > regular.size.x, "bold is wider")
	heavy := set(t, &tr, "Weight", {size = 50, weight = 1000})
	defer typeset_destroy(&heavy)
	testing.expect(t, heavy.weight <= 1000 && heavy.weight >= 800, "as heavy as the axis goes")
	missing := set(t, &tr, "Weight", {size = 50, family = "No Such Family 128"})
	defer typeset_destroy(&missing)
	testing.expect_value(t, missing.family, "")
	testing.expect(t, near(missing.size.x, regular.size.x), "set in the theme's typeface")

	faces, ok := font_faces(&tr, "No Such Family 128", context.temp_allocator)
	testing.expect(t, ok && len(faces) == 0, "a family the machine lacks has no faces")
	fonts, _ := installed_fonts(&tr, context.temp_allocator)
	for f in fonts {
		list, _ := font_faces(&tr, f.family, context.temp_allocator)
		if len(list) == 0 do continue
		for face in list do testing.expect(t, face.weights[0] <= face.weight && face.weight <= face.weights[1], "a face's weight is in its range")
		ts := set(t, &tr, "Aa", {size = 30, family = f.family, weight = list[0].weight})
		defer typeset_destroy(&ts)
		testing.expectf(t, ts.family == f.family, "set in %v, not %q", f.family, ts.family)
		break
	}
}

} // when ODIN_TEST