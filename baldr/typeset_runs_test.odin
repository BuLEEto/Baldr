package baldr

@(require) import "core:strings"
@(require) import "core:log"
@(require) import "core:testing"
@(require) import runa "baldr:third_party/runa"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A paragraph set in several runs. A book's paragraph is not one style — a
// word in italic, a footnote's small raised number, a name in another face —
// and the shapes here are the ones real chapters have: runs overwhelmingly
// Italic, with Bold, Small_Caps and Underline behind it, and sizes other
// than the body's mostly on footnote markers (0.70em and 0.75em).

@(private = "file")
fixture :: proc(t: ^testing.T, te: ^Text_Engine, tr: ^Tree) {
	if !text_engine_init(te) do testing.fail_now(t, "text_engine_init: embedded fonts failed to load")
	tree_init(tr)
	tree_use_text_engine(tr, te)
}

@(private = "file")
near :: proc(a, b: f32, eps: f32 = 0.01) -> bool { return abs(a - b) <= eps }

// A style with no runs is one run in the style's own face, with the face's
// own line height and glyph scale. Paint sets text this way.
@(test)
a_style_without_runs_is_one_run_in_its_own_face :: proc(t: ^testing.T) {
	te: Text_Engine; tr: Tree
	fixture(t, &te, &tr)
	defer { tree_destroy(&tr); text_engine_destroy(&te) }

	ts, ok := typeset(&tr, "Hello", Typeset_Style{size = 20})
	testing.expect(t, ok, "typeset")
	defer typeset_destroy(&ts)

	testing.expect_value(t, len(ts.runs), 1)
	testing.expect_value(t, ts.runs[0].end, len("Hello"))
	testing.expect_value(t, ts.runs[0].size, f32(20))
	testing.expect_value(t, len(ts.lines), 1)
	for g in ts.glyphs do testing.expect_value(t, g.run, i32(0))
	testing.expect(t, ts.lines[0].rect.h > 0, "the face's own line height")
	testing.expect(t, !ts.lines[0].hyphen, "nothing was hyphenated")
}

// A caller cannot lose its tail by miscounting: runs that stop short of the
// text are followed by one in the style's own face, and a run reaching past
// the end is cut to it.
@(test)
runs_always_cover_the_text :: proc(t: ^testing.T) {
	te: Text_Engine; tr: Tree
	fixture(t, &te, &tr)
	defer { tree_destroy(&tr); text_engine_destroy(&te) }

	text := "one two three"
	short := []Typeset_Run{{end = 3, italic = true}}
	ts, ok := typeset(&tr, text, Typeset_Style{size = 16, runs = short})
	testing.expect(t, ok, "typeset")
	defer typeset_destroy(&ts)
	testing.expect_value(t, len(ts.runs), 2)
	testing.expect_value(t, ts.runs[len(ts.runs) - 1].end, len(text))
	testing.expect(t, ts.runs[0].size == 16 && ts.runs[1].size == 16, "both took the style's size")

	over := []Typeset_Run{{end = len(text) + 500}}
	ts2, ok2 := typeset(&tr, text, Typeset_Style{size = 16, runs = over})
	testing.expect(t, ok2, "typeset")
	defer typeset_destroy(&ts2)
	testing.expect_value(t, len(ts2.runs), 1)
	testing.expect_value(t, ts2.runs[0].end, len(text))
}

// The footnote shape: body
// text with a 0.70em marker in it. The marker's glyphs are set at its own
// size, and — the point of the test — the line is no taller for it, so the
// leading of a page does not jump on the paragraphs that carry a footnote.
@(test)
a_small_run_does_not_change_the_leading :: proc(t: ^testing.T) {
	te: Text_Engine; tr: Tree
	fixture(t, &te, &tr)
	defer { tree_destroy(&tr); text_engine_destroy(&te) }

	plain, ok0 := typeset(&tr, "blood.", Typeset_Style{size = 20})
	testing.expect(t, ok0, "typeset")
	defer typeset_destroy(&plain)

	// "blood." then a 0.7em "*", as a footnote marker arrives
	text := "blood.*"
	runs := []Typeset_Run{{end = 6}, {end = 7, size = 14}}
	ts, ok := typeset(&tr, text, Typeset_Style{size = 20, runs = runs})
	testing.expect(t, ok, "typeset")
	defer typeset_destroy(&ts)

	testing.expect_value(t, len(ts.lines), 1)
	testing.expectf(t, near(ts.lines[0].rect.h, plain.lines[0].rect.h),
		"the small run must not change the line's height: %v vs %v", ts.lines[0].rect.h, plain.lines[0].rect.h)
	testing.expectf(t, near(ts.lines[0].baseline, plain.lines[0].baseline),
		"nor its baseline: %v vs %v", ts.lines[0].baseline, plain.lines[0].baseline)

	marker, body := false, false
	for g in ts.glyphs {
		if g.blank do continue
		if g.run == 1 { marker = true; testing.expect(t, g.scale < 1, "the marker is set small") }
		if g.run == 0 do body = true
	}
	testing.expect(t, marker && body, "both runs reached the glyphs")
}

// A raised run makes room for itself rather than being clipped: shift the
// marker up by more than the face's own gap and the line grows.
@(test)
a_raised_run_makes_room_for_itself :: proc(t: ^testing.T) {
	te: Text_Engine; tr: Tree
	fixture(t, &te, &tr)
	defer { tree_destroy(&tr); text_engine_destroy(&te) }

	flat := []Typeset_Run{{end = 6}, {end = 7, size = 14}}
	lo, ok0 := typeset(&tr, "blood.*", Typeset_Style{size = 20, runs = flat})
	testing.expect(t, ok0, "typeset")
	defer typeset_destroy(&lo)

	high := []Typeset_Run{{end = 6}, {end = 7, size = 14, shift = 40}}
	hi, ok := typeset(&tr, "blood.*", Typeset_Style{size = 20, runs = high})
	testing.expect(t, ok, "typeset")
	defer typeset_destroy(&hi)

	testing.expectf(t, hi.lines[0].rect.h > lo.lines[0].rect.h,
		"a run raised past the leading grows the line: %v vs %v", hi.lines[0].rect.h, lo.lines[0].rect.h)

	// and the raised glyph really is higher above the baseline
	for g in hi.glyphs do if g.run == 1 && !g.blank {
		testing.expect(t, hi.lines[0].baseline - g.pos.y > 30, "the marker sits well above the baseline")
	}
}

// A soft hyphen is a hyphenation point, not a character. Where the line
// does not break there it takes no room and draws nothing — most fonts map
// U+00AD to a real hyphen, which would otherwise print over the next
// letter.
@(test)
an_unused_soft_hyphen_is_invisible :: proc(t: ^testing.T) {
	te: Text_Engine; tr: Tree
	fixture(t, &te, &tr)
	defer { tree_destroy(&tr); text_engine_destroy(&te) }

	plain, ok0 := typeset(&tr, "unbroken", Typeset_Style{size = 20})
	testing.expect(t, ok0, "typeset")
	defer typeset_destroy(&plain)

	soft, ok := typeset(&tr, "un­bro­ken", Typeset_Style{size = 20})
	testing.expect(t, ok, "typeset")
	defer typeset_destroy(&soft)

	testing.expect_value(t, len(soft.lines), 1)
	testing.expectf(t, near(soft.lines[0].rect.w, plain.lines[0].rect.w, 0.05),
		"soft hyphens take no room: %v vs %v", soft.lines[0].rect.w, plain.lines[0].rect.w)
	testing.expect(t, !soft.lines[0].hyphen, "and nothing was hyphenated")
	for g in soft.glyphs {
		if g.start < len(soft.text) && strings.has_prefix(soft.text[g.start:], "­") {
			testing.expect(t, g.blank, "an unused soft hyphen draws nothing")
			testing.expect(t, near(g.x1 - g.x0, 0), "…and takes no width")
		}
	}
}

// Where a line does break at one, the hyphen is drawn, it is counted in the
// line's width, and the line says so — a reader that cuts pages by these
// lines needs to know which of them end in a hyphen.
@(test)
a_line_breaking_at_a_soft_hyphen_draws_it :: proc(t: ^testing.T) {
	te: Text_Engine; tr: Tree
	fixture(t, &te, &tr)
	defer { tree_destroy(&tr); text_engine_destroy(&te) }

	// wide enough for "hyphen" and not for "hyphenation"
	wide, ok0 := typeset(&tr, "hyphen", Typeset_Style{size = 20})
	testing.expect(t, ok0, "typeset")
	wide_w := wide.lines[0].rect.w
	w := wide_w + 16 // room for the hyphen too
	typeset_destroy(&wide)

	text := "hyphen­ation follows"
	ts, ok := typeset(&tr, text, Typeset_Style{size = 20, wrap_width = w})
	testing.expect(t, ok, "typeset")
	defer typeset_destroy(&ts)

	testing.expect(t, len(ts.lines) >= 2, "it wrapped")
	testing.expectf(t, ts.lines[0].hyphen, "the first line broke at the soft hyphen: %q", ts.text[ts.lines[0].start:ts.lines[0].end])
	// It must have ink, not merely stop being blank: the shaper drops U+00AD
	// as a default-ignorable whatever the face maps it to, so a glyph that is
	// not blank can still draw nothing and advance zero.
	drawn := false
	for i in ts.spans[0][0] ..< ts.spans[0][0] + ts.spans[0][1] {
		g := ts.glyphs[i]
		if g.start < len(ts.text) && strings.has_prefix(ts.text[g.start:], "\u00AD") {
			testing.expect(t, !g.blank, "the hyphen is drawn on the line that ends with it")
			testing.expectf(t, g.x1 - g.x0 > 0.5, "…and takes a hyphen's width, not nothing: %v", g.x1 - g.x0)
			testing.expect_value(t, g.id, runa.font_lookup_glyph(g.font, '-')) // the face's own hyphen
			drawn = true
		}
	}
	testing.expect(t, drawn, "the soft hyphen is on the line that ends with it")
	testing.expect(t, ts.lines[0].rect.w <= w + 0.05, "and the drawn hyphen still fits the wrap")

	// Where the hyphen does *not* fit and there is no other break in the
	// word, it is drawn anyway and the line runs over — a reader must be
	// told the word continues, and a few pixels of overhang say less than a
	// missing hyphen would. The same thing a word longer than its line does.
	tight, ok2 := typeset(&tr, text, Typeset_Style{size = 20, wrap_width = wide_w + 1})
	testing.expect(t, ok2, "typeset")
	defer typeset_destroy(&tight)
	testing.expect(t, tight.lines[0].hyphen, "it still breaks at the only point there is")
	testing.expect(t, tight.lines[0].rect.w > wide_w + 1, "and runs over rather than dropping the hyphen")
}

// A run boundary breaks shaping, which is right — the two halves are in
// different faces — and every glyph carries the run it came from, so a
// caller can ink, underline and strike by run.
@(test)
every_glyph_knows_its_run :: proc(t: ^testing.T) {
	te: Text_Engine; tr: Tree
	fixture(t, &te, &tr)
	defer { tree_destroy(&tr); text_engine_destroy(&te) }

	// "There was nothing so very remarkable" — Alice's shape: one italic
	// word inside a paragraph
	text := "nothing so very remarkable"
	at := strings.index(text, "very")
	runs := []Typeset_Run{
		{end = at},
		{end = at + 4, italic = true, ink = Color{1, 0, 0, 1}},
		{end = len(text)},
	}
	ts, ok := typeset(&tr, text, Typeset_Style{size = 18, runs = runs})
	testing.expect(t, ok, "typeset")
	defer typeset_destroy(&ts)

	testing.expect_value(t, len(ts.runs), 3)
	for g in ts.glyphs {
		if g.blank do continue
		want := i32(0)
		switch {
		case g.start >= at + 4: want = 2
		case g.start >= at:     want = 1
		}
		testing.expectf(t, g.run == want, "byte %d belongs to run %d, not %d", g.start, want, g.run)
	}
	testing.expect_value(t, ts.runs[1].ink, Color{1, 0, 0, 1})
	testing.expect(t, ts.runs[1].italic && !ts.runs[0].italic, "only the middle run is italic")
}

// Small capitals are the face's own glyphs or they are nothing. runa
// takes an OpenType feature by tag, so `smcp` is asked for where the face
// has it; where it does not, the run stays in its **ordinary letters**,
// because capitals scaled down carry the wrong stem weight beside the
// roman. This half is the fallback, which is what the embedded faces do
// (neither Inter nor JetBrains Mono carries smcp).
@(test)
small_capitals_are_never_faked :: proc(t: ^testing.T) {
	te: Text_Engine; tr: Tree
	fixture(t, &te, &tr)
	defer { tree_destroy(&tr); text_engine_destroy(&te) }

	testing.expect(t, typeset_small_caps_ready(), "runa takes a feature by tag since 1.5.0")
	testing.expect(t, !typeset_has_small_caps(&tr, ""), "and the theme's own typeface has no small capitals")

	plain, ok0 := typeset(&tr, "Orange Marmalade", Typeset_Style{size = 18})
	testing.expect(t, ok0, "typeset")
	defer typeset_destroy(&plain)

	caps := []Typeset_Run{{end = len("Orange Marmalade"), small_caps = true}}
	ts, ok := typeset(&tr, "Orange Marmalade", Typeset_Style{size = 18, runs = caps})
	testing.expect(t, ok, "typeset")
	defer typeset_destroy(&ts)

	testing.expectf(t, near(ts.lines[0].rect.w, plain.lines[0].rect.w),
		"a face without them sets the ordinary letters: %v vs %v", ts.lines[0].rect.w, plain.lines[0].rect.w)
	for g, i in ts.glyphs do testing.expectf(t, g.id == plain.glyphs[i].id, "glyph %d is the ordinary one", i)
	testing.expect(t, ts.runs[0].small_caps, "but the run still says what it wanted")
}

// small_caps_test_family is an installed family whose regular face carries
// `smcp`, or "" where the machine has none (Debian's fonts-noto-core has
// Noto Serif; Inter and the DejaVus have none), and the test below then
// has nothing to assert rather than a wrong answer.
@(private = "file")
small_caps_test_family :: proc(tr: ^Tree) -> string {
	fonts, ok := installed_fonts(tr, context.temp_allocator)
	if !ok do return ""
	for f in fonts do if typeset_has_small_caps(tr, f.family) do return f.family
	return ""
}

// The other half: where the face has them, the lowercase letters become
// small capitals and **the capitals do not change** — which is what CSS
// `font-variant: small-caps` means, and the reason the run is a flag rather
// than a size.
@(test)
real_small_capitals_come_from_the_face :: proc(t: ^testing.T) {
	te: Text_Engine; tr: Tree
	fixture(t, &te, &tr)
	defer { tree_destroy(&tr); text_engine_destroy(&te) }

	family := small_caps_test_family(&tr)
	if family == "" {
		log.info("no installed face carries smcp on this machine: nothing to check")
		return
	}
	log.infof("small capitals from %q", family)

	text := "Orange"
	plain, ok0 := typeset(&tr, text, Typeset_Style{size = 18, family = family})
	testing.expect(t, ok0, "typeset")
	defer typeset_destroy(&plain)

	runs := []Typeset_Run{{end = len(text), small_caps = true}}
	ts, ok := typeset(&tr, text, Typeset_Style{size = 18, family = family, runs = runs})
	testing.expect(t, ok, "typeset")
	defer typeset_destroy(&ts)

	testing.expect_value(t, len(ts.glyphs), len(plain.glyphs)) // one glyph a letter either way
	testing.expect_value(t, ts.glyphs[0].id, plain.glyphs[0].id) // the O is left alone
	changed := 0
	for i in 1 ..< len(ts.glyphs) do if ts.glyphs[i].id != plain.glyphs[i].id do changed += 1
	testing.expectf(t, changed == len(ts.glyphs) - 1, "every lowercase letter is a small capital: %d of %d", changed, len(ts.glyphs) - 1)

	// And they are the face's small capitals, not its capitals: a small
	// capital is drawn at the x-height with its own stem weight, which is
	// the whole reason for not faking them. (The line's *width* says
	// nothing — the first family found here may be a monospaced one, where
	// every glyph has the same advance.)
	upper, ok2 := typeset(&tr, "ORANGE", Typeset_Style{size = 18, family = family})
	testing.expect(t, ok2, "typeset")
	defer typeset_destroy(&upper)
	testing.expect_value(t, len(upper.glyphs), len(ts.glyphs))
	for i in 1 ..< len(ts.glyphs) {
		testing.expectf(t, ts.glyphs[i].id != upper.glyphs[i].id,
			"glyph %d is a small capital, not the capital itself", i)
	}
}

}
