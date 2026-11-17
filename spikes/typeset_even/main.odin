// typeset_even: what total-fit breaking does to a page, beside a greedy
// fill.
//
// `Typeset_Style.breaking = .Even` feeds runa's Knuth–Plass `break_lines`.
// This prints both settings over the same prose: every line, how wide the
// words are spaced, how many lines end in a hyphen, the longest run of
// those, and whether the last full line ends in one.
//
// A justified line always measures the full column, so what says whether a
// page looks even is the gap drawn between its words, read back through
// `typeset_caret`: what a reader sees rather than what the breaker believes.
// At a narrow measure a greedy fill's worst line opens its words to about
// four and a half spaces and total fit's to just over two, for about 3 %
// more time a paragraph.
//
// Shrink is the subtle part. Knuth's glue gives a third of a space back to
// pull a long line in, and the overrun column (zero in every configuration)
// checks the three rules that keep it inside the column:
//   - glue carries shrink only where the paragraph is justified, and
//     `typeset` tightens such a line by at most what was offered; offered
//     to every line, a ragged line nothing tightens overruns;
//   - the allowance counts every ordinary space: `Typeset_Shaped.hang`
//     means "may hang at a line end", not "is hanging", so it filters
//     nothing;
//   - a paragraph's last line is never spread, but the breaker counts its
//     shrink like any other line's, so it is tightened when it would
//     otherwise overrun.
//
// The sweeps at the end find the measures at which a greedy fill
// hyphenates the last full line and total fit does not, and a long-word
// paragraph where the hyphen cap holds the page together (unlimited, it
// ladders to thirteen hyphenated lines in a row at 120 px).
//
//   BALDR_FAST=1 ./build.sh spike typeset_even run
package main

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "core:time"
import "baldr:baldr"

// Alice, chapter 1, with soft hyphens where hyphenation patterns put them,
// as a reader's hyphenation dictionary hands them to `typeset`.
PARA :: "Alice was be­gin­ning to get very tired of sit­ting by her sis­ter on the bank, and of hav­ing noth­ing at all to do: once or twice she had peeped into the book her sis­ter was read­ing, but it had no pic­tures or con­ver­sa­tions in it, and what is the use of a book, thought Alice, with­out pic­tures or con­ver­sa­tions?"

// Long words, hyphenated the way hyphenation patterns do, with nothing short
// between them: a greedy fill has no choice but to break line after line.
LADDER :: "Con­ver­sa­tions about pre­dis­po­si­tion and in­com­pre­hen­si­bil­ity con­tin­ued through­out the in­ter­na­tional par­lia­men­tary de­lib­er­a­tions, not­with­stand­ing con­sid­er­able mis­un­der­stand­ing."

WIDTHS :: [?]f32{420, 300, 220}
BODY   :: 18.0

main :: proc() {
	te: baldr.Text_Engine
	if !baldr.text_engine_init(&te) { fmt.println("fonts failed to load"); return }
	defer baldr.text_engine_destroy(&te)
	tr: baldr.Tree
	baldr.tree_init(&tr)
	defer baldr.tree_destroy(&tr)
	baldr.tree_use_text_engine(&tr, &te)

	for w in WIDTHS {
		fmt.printf("\n=== %.0f px, justified, %.0f px body ===\n", w, f32(BODY))
		base := baldr.Typeset_Style{size = BODY, wrap_width = w, justify = true, indent = BODY}
		report("greedy", &tr, base)
		even := base
		even.breaking = .Even
		report("even", &tr, even)
		one := even
		one.hyphen_limit = 1
		report("even, 1 hyphen", &tr, one)
		none := even
		none.hyphen_limit = -1
		report("even, no limit", &tr, none)
	}

	// Ragged right: no justification, so the only thing evening the lines
	// is the breaking itself. This is where the rag should visibly tighten.
	fmt.println("\n=== 300 px, ragged right ===")
	rag := baldr.Typeset_Style{size = BODY, wrap_width = 300}
	report("greedy", &tr, rag)
	rage := rag
	rage.breaking = .Even
	report("even", &tr, rage)

	fmt.println("\n=== 300 px, a dropped letter over three lines ===")
	cap := baldr.Typeset_Style{size = BODY, wrap_width = 300, justify = true, drop_cap_lines = 3}
	report("greedy", &tr, cap)
	cape := cap
	cape.breaking = .Even
	report("even", &tr, cape)

	fmt.println("\n=== 300 px, hanging punctuation ===")
	hangs := baldr.Typeset_Style{size = BODY, wrap_width = 300, justify = true, hanging_punctuation = true}
	report("greedy", &tr, hangs)
	hange := hangs
	hange.breaking = .Even
	report("even", &tr, hange)

	// Where does total fit keep the last full line whole? A sweep, so a test
	// can be written from a measured case rather than a guessed one.
	fmt.println("\n=== a sweep: which measures hyphenate the last full line ===")
	fmt.println("  px   greedy: lines hy run last   even: lines hy run last")
	for w: f32 = 170; w <= 480; w += 10 {
		g := sweep(&tr, PARA, baldr.Typeset_Style{size = BODY, wrap_width = w, justify = true})
		e := sweep(&tr, PARA, baldr.Typeset_Style{size = BODY, wrap_width = w, justify = true, breaking = .Even})
		mark := "  <-- even keeps the word whole" if g.last && !e.last else ""
		fmt.printf("  %3.0f           %2d %2d %2d %-5v        %2d %2d %2d %-5v%s\n",
			w, g.lines, g.hyphens, g.run, g.last, e.lines, e.hyphens, e.run, e.last, mark)
	}

	// And a word-soup that forces a greedy fill into a ladder of hyphens.
	fmt.println("\n=== a ladder of hyphens ===")
	for w: f32 = 110; w <= 200; w += 10 {
		g := sweep(&tr, LADDER, baldr.Typeset_Style{size = BODY, wrap_width = w})
		e := sweep(&tr, LADDER, baldr.Typeset_Style{size = BODY, wrap_width = w, breaking = .Even})
		n := sweep(&tr, LADDER, baldr.Typeset_Style{size = BODY, wrap_width = w, breaking = .Even, hyphen_limit = -1})
		fmt.printf("  %3.0f px  greedy %2d lines %2d hyphens run %d   even run %d   even unlimited run %d\n",
			w, g.lines, g.hyphens, g.run, e.run, n.run)
	}

	// Does the cap ever bite in a greedy fill? It can only give a hyphen up
	// where the line has another break to use, which is the limit of filling
	// one line at a time.
	fmt.println("\n=== the greedy cap ===")
	for text, ti in ([2]string{PARA, LADDER}) {
		for w: f32 = 100; w <= 300; w += 5 {
			two := sweep(&tr, text, baldr.Typeset_Style{size = BODY, wrap_width = w})
			off := sweep(&tr, text, baldr.Typeset_Style{size = BODY, wrap_width = w, hyphen_limit = -1})
			if two.run != off.run || two.hyphens != off.hyphens {
				fmt.printf("  text %d  %3.0f px  capped: %d hyphens run %d   uncapped: %d hyphens run %d\n",
					ti, w, two.hyphens, two.run, off.hyphens, off.run)
			}
		}
	}

	fmt.println("\n=== what it costs ===")
	cost("greedy", &tr, baldr.Typeset_Style{size = BODY, wrap_width = 420, justify = true})
	cost("even", &tr, baldr.Typeset_Style{size = BODY, wrap_width = 420, justify = true, breaking = .Even})

	// The text must come back whole whichever way it is broken.
	fmt.println("\n=== every byte accounted for ===")
	whole("greedy", &tr, baldr.Typeset_Style{size = BODY, wrap_width = 300, justify = true})
	whole("even", &tr, baldr.Typeset_Style{size = BODY, wrap_width = 300, justify = true, breaking = .Even})
}

report :: proc(name: string, tr: ^baldr.Tree, style: baldr.Typeset_Style) {
	ts, ok := baldr.typeset(tr, PARA, style)
	if !ok { fmt.printf("%-16s typeset failed\n", name); return }
	defer baldr.typeset_destroy(&ts)

	full := len(ts.lines) - 1 // the last line is short on purpose
	hyphens, run, worst := 0, 0, 0
	for l in ts.lines {
		if l.hyphen {
			hyphens += 1
			run += 1
			worst = max(worst, run)
		} else {
			run = 0
		}
	}
	last_full := full > 0 && ts.lines[full - 1].hyphen
	over: f32
	for l in ts.lines do over = max(over, l.rect.x + l.rect.w - style.wrap_width)
	wide, tight, typical := gaps(&ts, full)
	fmt.printf("%-16s %2d lines  %d hyphens (longest run %d)  word gap %4.1f typical, %4.1f widest (%.2f×), %4.1f tightest  last full line hyphenated: %-5v  overrun %.2f\n",
		name, len(ts.lines), hyphens, worst, typical, wide, wide / max(typical, 0.001), tight, last_full, over)
	for l, i in ts.lines {
		mark := " -" if l.hyphen else "  "
		fmt.printf("   %2d%s x %6.1f w %6.1f  %q\n", i, mark, l.rect.x, l.rect.w,
			trim(ts.text[l.start:l.end]))
	}
}

// gaps measures the drawn space between words from the caret's own
// geometry, so it is what a reader sees rather than anything the breaker
// believes. Returns the widest gap on a full line, the tightest, and the
// median.
gaps :: proc(ts: ^baldr.Typeset, full: int) -> (wide, tight, typical: f32) {
	all := make([dynamic]f32, 0, 64, context.temp_allocator)
	for l, li in ts.lines {
		if li >= full do break
		for i := l.start; i < l.end; i += 1 {
			if ts.text[i] != ' ' do continue
			a := baldr.typeset_caret(ts, i)
			b := baldr.typeset_caret(ts, i + 1)
			g := b.x - a.x
			if g > 0 do append(&all, g)
		}
	}
	if len(all) == 0 do return
	slice.sort(all[:])
	return all[len(all) - 1], all[0], all[len(all) / 2]
}

Sweep :: struct { lines, hyphens, run: int, last: bool }

sweep :: proc(tr: ^baldr.Tree, text: string, style: baldr.Typeset_Style) -> (out: Sweep) {
	ts, ok := baldr.typeset(tr, text, style)
	if !ok do return
	defer baldr.typeset_destroy(&ts)
	out.lines = len(ts.lines)
	run := 0
	for l in ts.lines {
		if l.hyphen {
			out.hyphens += 1
			run += 1
			out.run = max(out.run, run)
		} else {
			run = 0
		}
	}
	full := len(ts.lines) - 1
	out.last = full > 0 && ts.lines[full - 1].hyphen
	return
}

trim :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, "­", "", context.temp_allocator)
	return out
}

cost :: proc(name: string, tr: ^baldr.Tree, style: baldr.Typeset_Style) {
	N :: 2000
	if ts, ok := baldr.typeset(tr, PARA, style); ok do baldr.typeset_destroy(&ts) // warm the shape cache
	start := time.now()
	for _ in 0 ..< N {
		ts, ok := baldr.typeset(tr, PARA, style)
		if ok do baldr.typeset_destroy(&ts)
	}
	ms := time.duration_milliseconds(time.since(start))
	fmt.printf("  %-10s %6.3f ms a paragraph\n", name, ms / f64(N))
}

// whole checks the lines cover the paragraph once, in order, with nothing
// dropped: a breaker that loses a word is the one bug that matters.
whole :: proc(name: string, tr: ^baldr.Tree, style: baldr.Typeset_Style) {
	ts, ok := baldr.typeset(tr, PARA, style)
	if !ok { fmt.printf("  %-10s typeset failed\n", name); return }
	defer baldr.typeset_destroy(&ts)
	b := strings.builder_make(context.temp_allocator)
	at, gaps := 0, 0
	for l in ts.lines {
		if l.start != at && !(l.start > at && only_spaces(ts.text[at:l.start])) do gaps += 1
		strings.write_string(&b, ts.text[l.start:l.end])
		at = l.end
	}
	got := strings.to_string(b)
	want, _ := strings.remove_all(PARA, " ", context.temp_allocator)
	got_ns, _ := strings.remove_all(got, " ", context.temp_allocator)
	fmt.printf("  %-10s %d lines, %d bytes of %d, out-of-order joins %d, same text without spaces: %v\n",
		name, len(ts.lines), len(got), len(PARA), gaps, got_ns == want)
}

only_spaces :: proc(s: string) -> bool {
	for r in s do if r != ' ' && r != '­' do return false
	return true
}

abs :: proc(x: f32) -> f32 { return math.abs(x) }
