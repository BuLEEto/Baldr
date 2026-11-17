// typeset_indent_loose: why a paragraph's first line, the indented one, can
// be the only loose line on a narrow page.
//
// The indent is taken off that line once, not twice; the line is forced. At
// a 27 em measure (513 px, Noto Serif 19 px):
//
//   indent   line 0                                     gaps
//   1.5 em   "…aware of the prob-"                      1.00× (the space)
//   2 em     "…aware of the "                           2.16×
//   none     "…aware of the problem "                   1.10×
//
// The hyphenation points are there in all three. At 2 em the line has
// 475 px, and "prob-" plus the hyphen it would draw no longer fits. A
// hyphenation point only helps while there is room for the hyphen; the line
// then has nowhere left to break and can only stretch. The first line is
// the narrowest in the paragraph, by exactly the indent, so it is where this
// bites first. So check the indent before blaming the hyphenation data: at
// 1.5 em the loose line appears only with the soft hyphens stripped out.
//
// Greedy sets the same line at 2.17×, and gives a hyphen up the same way
// when it will not fit (`typeset_fill`'s `brk_w + hyph_adv > room`), so
// neither filler is worse than the other. It is what a narrow measure
// costs, not a bug.
//
//   BALDR_FAST=1 ./build.sh spike typeset_indent_loose run
package main

import "core:fmt"
import "core:slice"
import "core:strings"
import "baldr:baldr"

// A novel's opening, hyphenated the way a hyphenation dictionary does.
PARA :: "But peo­ple have al­ways been dimly aware of the prob­lem with the start of things. They won­der aloud how the snow­plow driver gets to work, or how the mak­ers of dic­tio­nar­ies look up the spell­ings of the words. Yet there is the con­stant de­sire to find some point in the twist­ing, knot­ting, rav­el­ing nets of space-time on which a meta­phor­i­cal fin­ger can be put to in­di­cate that here, here, is the point where it all be­gan..."

FAMILY :: "Noto Serif"
SIZE   :: 19.0
MEASURE :: 513.0
INDENT :: SIZE * 1.5

main :: proc() {
	te: baldr.Text_Engine
	if !baldr.text_engine_init(&te) { fmt.println("fonts failed to load"); return }
	defer baldr.text_engine_destroy(&te)
	tr: baldr.Tree
	baldr.tree_init(&tr)
	defer baldr.tree_destroy(&tr)
	baldr.tree_use_text_engine(&tr, &te)

	base := baldr.Typeset_Style{
		family = FAMILY, size = SIZE, wrap_width = MEASURE, justify = true,
		indent = INDENT, hanging_punctuation = true, breaking = .Even,
	}
	show("as the reader has it", &tr, base)

	no_hang := base
	no_hang.hanging_punctuation = false
	show("without hanging punctuation", &tr, no_hang)

	// 2 em, a common book indent: the first line's hyphen no longer fits.
	em2 := base
	em2.indent = SIZE * 2
	show("a 2 em indent, as the book sets it", &tr, em2)

	no_ind := base
	no_ind.indent = 0
	show("without the indent", &tr, no_ind)

	greedy := base
	greedy.breaking = .Greedy
	show("greedy, for comparison", &tr, greedy)

	// …and the same paragraph with no hyphenation points at all.
	flat, _ := strings.replace_all(PARA, "\u00AD", "", context.temp_allocator)
	show_text("no hyphenation points, total fit", &tr, base, flat)
	g2 := base
	g2.breaking = .Greedy
	show_text("no hyphenation points, greedy", &tr, g2, flat)
}

show :: proc(name: string, tr: ^baldr.Tree, style: baldr.Typeset_Style) {
	show_text(name, tr, style, PARA)
}

show_text :: proc(name: string, tr: ^baldr.Tree, style: baldr.Typeset_Style, text: string) {
	ts, ok := baldr.typeset(tr, text, style)
	if !ok { fmt.printf("%s: typeset failed (is %q installed?)\n", name, style.family); return }
	defer baldr.typeset_destroy(&ts)
	fmt.printf("\n=== %s\n", name)
	natural := gap_natural(&ts)
	for l, i in ts.lines {
		wide, tight := gaps(&ts, i)
		mark := "-" if l.hyphen else " "
		fmt.printf("  %2d%s x %5.1f w %6.1f  reaches %6.1f  gaps %4.1f..%4.1f (%.2f×)  %q\n",
			i, mark, l.rect.x, l.rect.w, l.rect.x + l.rect.w, tight, wide, wide / max(natural, 0.001),
			trim(ts.text[l.start:l.end]))
		_ = text
	}
	fmt.printf("  the font's own space is %.1f px\n", natural)
}

// gaps: the drawn space between words on one line, through the public caret.
gaps :: proc(ts: ^baldr.Typeset, li: int) -> (wide, tight: f32) {
	l := ts.lines[li]
	tight = 1e9
	n := 0
	for i := l.start; i < l.end; i += 1 {
		if ts.text[i] != ' ' do continue
		g := baldr.typeset_caret(ts, i + 1).x - baldr.typeset_caret(ts, i).x
		if g <= 0 do continue
		wide, tight, n = max(wide, g), min(tight, g), n + 1
	}
	if n == 0 do tight = 0
	return
}

// gap_natural: the font's own space, from the median gap of an unjustified
// setting of the same text.
gap_natural :: proc(ts: ^baldr.Typeset) -> f32 {
	all := make([dynamic]f32, 0, 64, context.temp_allocator)
	for l in ts.lines {
		for i := l.start; i < l.end; i += 1 {
			if ts.text[i] != ' ' do continue
			g := baldr.typeset_caret(ts, i + 1).x - baldr.typeset_caret(ts, i).x
			if g > 0 do append(&all, g)
		}
	}
	if len(all) == 0 do return 0
	slice.sort(all[:])
	return all[0] // the tightest gap on the page: the floor the shrink allows
}

trim :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, "­", "", context.temp_allocator)
	return out
}
