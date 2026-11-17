package liga_cluster

// A runa-only check of glyph clusters after a ligature. Shapes one short
// string with Inter and prints, for each glyph, the byte it says it came
// from: the two listings must name the same bytes, the ligature standing in
// for the two it covers. A glyph after the ligature naming the byte before
// its own puts anything mapping a glyph back to the text (line breaking,
// hit testing, "is this a control byte?") one character out for the rest of
// the paragraph. Run it when runa is re-vendored.

import "core:fmt"
import runa "baldr:third_party/runa"

FONT :: #load("../../assets/fonts/InterVariable.ttf", []u8)

main :: proc() {
	font, err := runa.font_load(FONT)
	if err != nil { fmt.eprintfln("font_load: %v", err); return }
	defer runa.font_destroy(&font)

	text := "a -> b\nc"
	for no_liga in ([]bool{false, true}) {
		glyphs := make([dynamic]runa.Shaped_Glyph)
		defer delete(glyphs)
		feats: bit_set[runa.Feature]
		if no_liga do feats = {.Ligatures, .Contextual_Ligatures, .Contextual_Alternates}
		runa.shape_text(&font, text, 16, &glyphs, disable_features = feats)
		fmt.printfln("--- %s (%d glyphs for %d bytes)", no_liga ? "ligatures off" : "ligatures on", len(glyphs), len(text))
		for g in glyphs {
			c := int(g.cluster)
			b := c < len(text) ? text[c] : '?'
			fmt.printfln("  gid %4d cluster %d -> %q", g.glyph_id, c, rune(b))
		}
	}

	// Which sequences collapse at all, with this font: the shift fires only
	// for these, which is why prose does not show it (Inter has no fi/fl).
	for s in ([]string{"a -> b", "a <- b", "a => b", "a --> b", "a <-> b", "a <= b", "a != b", "a file b", "the office"}) {
		glyphs := make([dynamic]runa.Shaped_Glyph)
		defer delete(glyphs)
		runa.shape_text(&font, s, 16, &glyphs)
		if len(glyphs) != len(s) do fmt.printfln("%q: %d glyphs for %d bytes — %d collapsed into a ligature", s, len(glyphs), len(s), len(s) - len(glyphs) + 1)
	}
}
