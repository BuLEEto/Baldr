// typeset_cost: what does a chapter cost to set, and does it need a worker?
//
// A reader lays a whole chapter out when the type size changes and then
// turns pages by drawing, so the question is whether that one layout fits
// in a frame or has to go on a Job. A chapter is typically 300–600
// paragraphs; one-file books reach thousands.
//
// This sets chapters of several sizes in the shape a book has (one
// `typeset` per paragraph, justified, hyphenated at soft hyphens, with a few
// italic runs and a footnote marker) and reports each cold and warm. runa's
// shape cache is per Text_Engine, so the warm pass is what a re-paginate at
// a new width sees. It also prints what `typeset` touches that is shared,
// which is what a Job would need.
//
// Build it optimised: a -debug build is about ten times slower and gives
// the wrong answer. Optimised, a 337-byte paragraph at 420 px costs about
// 0.16 ms, linear in the text (about 0.44 µs a byte, no fixed price a call),
// so the cost is shaping. Four runs instead of one, and justifying, cost
// nothing measurable; soft hyphens about 7 %. A chapter of 600 paragraphs
// is a tenth of a second: a hitch, not a freeze, and laying out in slices
// covers it.
//
//   BALDR_FAST=1 ./build.sh spike typeset_cost run
package main

import "core:fmt"
import "core:strings"
import "core:time"
import "baldr:baldr"

// Prose with the shapes a real chapter has: long sentences, a few italic
// words, a footnote marker, and soft hyphens where hyphenation patterns
// would put them.
PARA :: "Alice was beginning to get very tired of sit­ting by her sis­ter on the bank, and of hav­ing noth­ing at all to do: once or twice she had peeped into the book her sis­ter was read­ing, but it had no pic­tures or con­ver­sa­tions in it, and what is the use of a book, thought Alice, with­out pic­tures or con­ver­sa­tions?*"

SIZES :: [?]int{73, 300, 600}
WIDTH :: 420.0
BODY  :: 18.0

main :: proc() {
	te: baldr.Text_Engine
	if !baldr.text_engine_init(&te) { fmt.println("fonts failed to load"); return }
	defer baldr.text_engine_destroy(&te)
	tr: baldr.Tree
	baldr.tree_init(&tr)
	defer baldr.tree_destroy(&tr)
	baldr.tree_use_text_engine(&tr, &te)

	// one paragraph's runs: two italic words and a small footnote marker
	mark := len(PARA) - 1
	it0 := strings.index(PARA, "thought")
	runs := []baldr.Typeset_Run{
		{end = it0},
		{end = it0 + len("thought Alice"), italic = true},
		{end = mark},
		{end = len(PARA), size = BODY * 0.7},
	}
	style := baldr.Typeset_Style{
		size = BODY, wrap_width = WIDTH, justify = true,
		indent = BODY, runs = runs,
	}
	opening := style
	opening.indent = 0
	opening.drop_cap_lines = 3

	fmt.printf("chapter of %d-byte paragraphs, %.0f px wide, %.0f px body, justified\n\n", len(PARA), f32(WIDTH), f32(BODY))
	fmt.println("paragraphs      cold        warm     per para   lines")
	for n in SIZES {
		cold := set_chapter(&tr, n, style, opening)
		warm := set_chapter(&tr, n, style, opening)
		fmt.printf("%10d  %8.1f ms  %6.1f ms  %7.3f ms  %6d\n",
			n, cold.ms, warm.ms, warm.ms / f64(n), warm.lines)
	}

	// Where the cost is: one run or four, justified or not, hyphens or not.
	fmt.println()
	fmt.println("one paragraph, 2000 times, by what it is asked to do:")
	plain := baldr.Typeset_Style{size = BODY, wrap_width = WIDTH}
	variant("plain, one run", &tr, PARA, plain)
	r4 := plain; r4.runs = runs
	variant("four runs", &tr, PARA, r4)
	j := plain; j.justify = true
	variant("justified, one run", &tr, PARA, j)
	nohy := strings.clone(PARA, context.temp_allocator)
	nohy, _ = strings.replace_all(nohy, "\u00AD", "", context.temp_allocator)
	variant("no soft hyphens", &tr, nohy, plain)
	full := r4; full.justify = true; full.indent = BODY
	variant("all of it", &tr, PARA, full)

	// Flat across everything above: so is it the text, or the call?
	fmt.println()
	fmt.println("by how much text, one run, unjustified:")
	whole := string(PARA)
	for n in ([?]int{1, 10, 40, 120, 337}) {
		variant(fmt.tprintf("%d bytes", n), &tr, whole[:min(n, len(whole))], plain)
	}

	fmt.println()
	fmt.println("What a layout touches that is shared, and so what a Job would need:")
	fmt.println("  - Text_Engine.cache   runa's shape cache, one per engine, not locked")
	fmt.println("  - Text_Engine faces   typeset_face loads a family's face on first use")
	fmt.println("  - Text_Engine.fonts   the fallback stack, read while a scan may replace it")
	fmt.println("  - the glyph atlas     only at draw time, not here")
	fmt.println()
	fmt.println("So a worker needs its own Text_Engine (its own cache and faces), not a")
	fmt.println("lock on this one: the cache is the thing that makes the warm pass fast,")
	fmt.println("and sharing it under a mutex would serialise exactly the work being moved.")
}

// variant times one paragraph set many times over, warm.
variant :: proc(name: string, tr: ^baldr.Tree, text: string, style: baldr.Typeset_Style) {
	N :: 2000
	if ts, ok := baldr.typeset(tr, text, style); ok do baldr.typeset_destroy(&ts) // warm the cache
	start := time.now()
	for _ in 0 ..< N {
		ts, ok := baldr.typeset(tr, text, style)
		if ok do baldr.typeset_destroy(&ts)
	}
	ms := time.duration_milliseconds(time.since(start))
	fmt.printf("  %-22s %6.3f ms each\n", name, ms / f64(N))
}

Chapter :: struct {
	ms:    f64,
	lines: int,
}

// set_chapter lays a chapter out one paragraph at a time, as a reader does,
// and throws each away: keeping 600 Typesets alive would measure the
// allocator rather than the layout.
set_chapter :: proc(tr: ^baldr.Tree, n: int, body, opening: baldr.Typeset_Style) -> (out: Chapter) {
	start := time.now()
	for i in 0 ..< n {
		style := opening if i == 0 else body
		ts, ok := baldr.typeset(tr, PARA, style)
		if !ok do continue
		out.lines += len(ts.lines)
		baldr.typeset_destroy(&ts)
	}
	out.ms = time.duration_milliseconds(time.since(start))
	return
}
