// emoji_vs — is U+FE0F drawn as a missing character?
//
// An emoji written the usual way carries a variation selector: ❤️ is
// U+2764 U+FE0F, and so are ✌️, ☀️, ❄️ and ✈️. Unicode calls FE00..FE0F
// Default_Ignorable_Code_Point: a renderer must draw nothing for them
// rather than a box, and they must take no room.
//
// Width cannot tell: a box drawn for the selector has a *zero* advance and
// is painted on top of the emoji, so neither the string's width nor
// typeset's measure changes. Only the drawn pixels show it.
//
// The glyph ids say whose bug it is: .notdef (id 0) for U+FE0F comes from
// runa, since neither Inter nor Twemoji covers it. The vendored copy is
// not patched; a fix comes in with the next runa tag.
//
//   ./build.sh spike emoji_vs run
package main

import "core:fmt"
import "baldr:baldr"
import "baldr:third_party/runa"

main :: proc() {
	te: baldr.Text_Engine
	if !baldr.text_engine_init(&te) { fmt.println("fonts failed to load"); return }
	defer baldr.text_engine_destroy(&te)
	t: baldr.Tree
	baldr.tree_init(&t)
	defer baldr.tree_destroy(&t)
	t.text = &te

	base := baldr.Rich_Style{size = 20}
	w :: proc(t: ^baldr.Tree, base: baldr.Rich_Style, s: string) -> f32 {
		lay := baldr.rich_layout(t, s, nil, base, 0, context.temp_allocator)
		out := f32(0)
		for l in lay.lines do out = max(out, l.width)
		return out
	}

	fmt.println("                       bare    +selector   difference")
	cases := []struct{ name, bare, sel: string }{
		{"heart      U+2764", "❤", "❤️"},
		{"victory    U+270C", "✌", "✌️"},
		{"snowflake  U+2744", "❄", "❄️"},
		{"aeroplane  U+2708", "✈", "✈️"},
		{"digit one  (VS15)", "1",      "1︎"},
	}
	bad := 0
	for c in cases {
		a, b := w(&t, base, c.bare), w(&t, base, c.sel)
		flag := ""
		if b > a + 0.01 { flag = "  <-- the selector took room"; bad += 1 }
		fmt.printfln("%s   %7.2f   %7.2f   %+7.2f%s", c.name, a, b, b - a, flag)
	}
	// …and the same question of `typeset`: it is its own layout path, not
	// rich_layout's.
	fmt.println()
	fmt.println("typeset:               bare    +selector   difference")
	tw :: proc(t: ^baldr.Tree, s: string) -> f32 {
		ts, ok := baldr.typeset(t, s, baldr.Typeset_Style{size = 20}, context.temp_allocator)
		if !ok do return -1
		return ts.size.x
	}
	for c in cases {
		a, b := tw(&t, c.bare), tw(&t, c.sel)
		if a < 0 || b < 0 { fmt.printfln("%s   typeset failed", c.name); continue }
		flag := ""
		if b > a + 0.01 { flag = "  <-- the selector took room"; bad += 1 }
		fmt.printfln("%s   %7.2f   %7.2f   %+7.2f%s", c.name, a, b, b - a, flag)
	}

	// Width alone would miss a box drawn with no advance, so the last word
	// is pixels: draw each pair and compare them byte for byte.
	fmt.println()
	fmt.println("drawn pixels:")
	px :: proc(t: ^baldr.Tree, s: string) -> []u8 {
		ts, ok := baldr.typeset(t, s, baldr.Typeset_Style{size = 28}, context.temp_allocator)
		if !ok do return nil
		img := baldr.Image{width = 96, height = 48, allocator = context.temp_allocator}
		img.pixels = make([]u8, 96 * 48 * 4, context.temp_allocator)
		baldr.typeset_draw(&ts, &img, {4, 4}, baldr.Color{1, 1, 1, 1})
		return img.pixels
	}
	for c in cases {
		a, b := px(&t, c.bare), px(&t, c.sel)
		if a == nil || b == nil { fmt.printfln("%s   could not draw", c.name); continue }
		diff, ink_a, ink_b := 0, 0, 0
		for i in 0 ..< len(a) {
			if a[i] != b[i] do diff += 1
			if i % 4 == 3 {
				if a[i] != 0 do ink_a += 1
				if b[i] != 0 do ink_b += 1
			}
		}
		flag := "  identical"
		if diff > 0 { flag = fmt.tprintf("  <-- %d bytes differ", diff); bad += 1 }
		fmt.printfln("%s   ink %d vs %d%s", c.name, ink_a, ink_b, flag)
	}

	// And what the shaper actually returns, which decides whose bug it is.
	fmt.println()
	fmt.println("glyphs from runa (id 0 is .notdef, the missing-character box):")
	for c in cases {
		lines, err := runa.layout_paragraph(c.sel,
			runa.Paragraph_Opts{fonts = runa.Font_Stack(te.stack[:]), size = 28}, nil, context.temp_allocator)
		if err != .None { fmt.printfln("%s   shaping failed: %v", c.name, err); continue }
		out := ""
		for l in lines {
			for g in l.glyphs {
				out = fmt.tprintf("%s  id=%d adv=%.1f", out, g.glyph_id, g.x_advance)
			}
		}
		fmt.printfln("%s %s", c.name, out)
	}

	fmt.println()
	if bad > 0 {
		fmt.printfln("%d of %d draw something for a character that must draw nothing.", bad, len(cases))
	} else {
		fmt.println("every selector is invisible and takes no room, as Unicode requires.")
	}
}
