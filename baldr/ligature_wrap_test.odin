package baldr

@(require) import "core:fmt"
@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: behind this `when`, checking a program costs
// 1.0 GB instead of 9.2 GB. ODIN_TEST is set by `odin test`; BALDR_TESTS
// lets ./build.sh check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A ligature (Inter draws "->" as one arrow) must not shift the clusters
// of the glyphs after it: a shaped line's clusters point at the bytes that
// line is made of. A shift hides from checks that read the text through
// the clusters (a line starting at "nd" reports the space before it), so
// the two that can see it are asserted at the end: the last glyph names
// the text's last codepoint, and every newline is claimed by the glyph
// shaped from it, the one the renderer skips.


@(private = "file")
LIGA_TEXT :: "25. Odin supports variadic functions with type inference so you can write `func f(x int, y string) -> void {}` and omit parameter types in most cases.\n26. The language includes a built-in benchmarking tool called `bench` that runs performance tests directly from the source file.\n27. Odin's standard library is entirely written in Odin."

@(test)
a_ligature_does_not_shift_the_lines_after_it :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init: the embedded fonts failed to load")
	defer text_engine_destroy(&te)
	text := LIGA_TEXT

	lines := text_lines(&te, text, 16, 750)
	testing.expect(t, len(lines) > 3, "it wraps")

	last := -1
	for l, i in lines {
		if len(l.glyphs) == 0 do continue
		first := int(l.glyphs[0].cluster)
		testing.expectf(t, first > last, "line %d starts after the line before it (at %d, previous ended %d)", i, first, last)
		for g in l.glyphs {
			c := int(g.cluster)
			testing.expectf(t, c >= 0 && c < len(text), "line %d: a glyph points at byte %d of %d", i, c, len(text))
			// A cluster is where a codepoint starts, never inside one. A
			// ligature is one glyph over several bytes, so a line cannot be
			// rebuilt by taking one byte per glyph.
			if c >= 0 && c < len(text) {
				testing.expectf(t, text[c] & 0xC0 != 0x80, "line %d: a glyph names byte %d, inside a codepoint", i, c)
				testing.expectf(t, c >= last, "line %d: clusters went backwards (%d after %d)", i, c, last)
				last = max(last, c)
			}
		}
	}

	// the plainest symptom: no line may start in the middle of a word that
	// the line before it started
	for l, i in lines[1:] {
		if len(l.glyphs) == 0 do continue
		c := int(l.glyphs[0].cluster)
		if c <= 0 || c >= len(text) do continue
		before, here := text[c - 1], text[c]
		testing.expectf(t, !(is_word_byte(before) && is_word_byte(here)),
			"line %d starts mid-word: %q then %q", i + 1, string([]u8{before}), string([]u8{here}))
	}

	// …and the two a uniform shift cannot hide from. `last` is the highest
	// cluster any glyph named, which must be where the final codepoint
	// starts, whatever ligatures came earlier in the paragraph.
	end := len(text) - 1
	for end > 0 && text[end] & 0xC0 == 0x80 do end -= 1 // back over continuation bytes
	testing.expectf(t, last == end, "the last glyph names byte %d; the text's last codepoint starts at %d", last, end)

	for i in 0 ..< len(text) {
		if text[i] != '\n' do continue
		claimed := false
		outer: for l in lines {
			for g in l.glyphs do if int(g.cluster) == i { claimed = true; break outer }
		}
		testing.expectf(t, claimed, "the newline at byte %d has no glyph of its own: the renderer would draw a box for it and skip a real character", i)
	}

	if t.error_count > 0 do liga_dump(&te, text)
}

// is_word_byte: an ASCII letter or digit, enough for this text.
@(private = "file")
is_word_byte :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

// liga_dump prints what the shaper gave back, so a failure names the line.
@(private = "file")
liga_dump :: proc(te: ^Text_Engine, text: string) {
	for on in ([]bool{true, false}) {
		lines := text_lines(te, text, 16, 750, no_liga = !on)
		fmt.eprintfln("--- ligatures %s: %d lines", "on" if on else "off", len(lines))
		for l, i in lines {
			if len(l.glyphs) == 0 do continue
			b := strings.builder_make(context.temp_allocator)
			for g in l.glyphs do if int(g.cluster) < len(text) do strings.write_byte(&b, text[int(g.cluster)])
			fmt.eprintfln("  line %d: clusters %d..%d %q", i, l.glyphs[0].cluster, l.glyphs[len(l.glyphs) - 1].cluster, strings.to_string(b))
		}
	}
}

} // when ODIN_TEST