package baldr

@(require) import "core:strings"
@(require) import "core:testing"
@(require) import runa "baldr:third_party/runa"

// See canvas_test.odin for why test files sit behind this `when`.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// The grapheme boundary procs start a walk from a nearby restart point, not
// the start of the string, so an arrow key at the end of a very long line
// does not walk all of it; the counting procs take a run of plain ASCII in
// one step. These check them all against the full walk at every byte
// offset, over text built to hit each rule that joins characters. (The two
// runs longer than the look-back window take every 13th: a walk there falls
// back to the start, so every offset is the full square, and 13 still meets
// every alignment of their repeating patterns.)
//
// The escapes are the long \U form on purpose: a short one can arrive in a
// file as the character itself, and a joiner or a mark is invisible.

@(private = "file")
boundaries_by_full_walk :: proc(s: string) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	append(&out, 0)
	it := runa.grapheme_iter_make(s)
	for {
		_, hi, ok := runa.grapheme_iter_next(&it)
		if !ok do break
		append(&out, hi)
	}
	return out[:]
}

@(private = "file")
check_every_offset :: proc(t: ^testing.T, name, s: string, step := 1) {
	bs := boundaries_by_full_walk(s)
	for i := 0; i <= len(s); i += step {
		want_next := len(s)
		for b in bs do if b > i { want_next = b; break }
		want_prev := 0
		for b in bs do if b < i do want_prev = b
		if got := grapheme_next(s, i); got != want_next {
			testing.expectf(t, false, "%s: grapheme_next(%d) = %d, want %d", name, i, got, want_next)
			return
		}
		if got := grapheme_prev(s, i); got != want_prev {
			testing.expectf(t, false, "%s: grapheme_prev(%d) = %d, want %d", name, i, got, want_prev)
			return
		}
		want_index := 0
		for b in bs[1:] do if b <= i do want_index += 1
		if got := grapheme_index(s, i); got != want_index {
			testing.expectf(t, false, "%s: grapheme_index(%d) = %d, want %d", name, i, got, want_index)
			return
		}
	}
	// The counting procs take a run of ASCII in one step; the same answers.
	testing.expectf(t, grapheme_count(s) == len(bs) - 1, "%s: grapheme_count = %d, want %d", name, grapheme_count(s), len(bs) - 1)
	for k in 0 ..= len(bs) {
		want := bs[k] if k < len(bs) else len(s)
		if got := grapheme_offset(s, k); got != want {
			testing.expectf(t, false, "%s: grapheme_offset(%d) = %d, want %d", name, k, got, want)
			return
		}
	}
}

@(test)
grapheme_boundaries_match_the_full_walk_everywhere :: proc(t: ^testing.T) {
	check_every_offset(t, "ascii", "the quick brown fox")
	// e + combining acute, and three marks stacked on one letter
	check_every_offset(t, "combining", "cafe\U00000301 nai\U00000308ve e\U00000301\U00000301\U00000301x")
	// a family joined by ZWJs, then thumbs up with a skin tone
	check_every_offset(t, "emoji zwj", "a\U0001F469\U0000200D\U0001F469\U0000200D\U0001F467b \U0001F44D\U0001F3FDc")
	// GB, FR, and a lone regional indicator
	check_every_offset(t, "flags", "x\U0001F1EC\U0001F1E7\U0001F1EB\U0001F1F7\U0001F1E9y")
	check_every_offset(t, "crlf", "one\r\ntwo\r\n\r\nthree\rfour\n")
	check_every_offset(t, "crlf at the ends", "\r\nx\r\n")
	check_every_offset(t, "a mark at the start", "\U00000301ab\U00000301")
	// Arabic number signs, which join onto what follows them
	check_every_offset(t, "prepend", "ab\U00000600123 \U00000601x")
	// conjoining jamo (L V T) and a precomposed syllable
	check_every_offset(t, "hangul", "a\U00001100\U00001161\U000011A8b\U0000AC00c")
	check_every_offset(t, "cjk", "漢字かな交じり文、そして English 混在")
	// A run with no ASCII longer than the look-back window, so a restart
	// has to fall back to the start of the text and still be right.
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "start ")
	for _ in 0 ..< 180 do strings.write_string(&b, "漢e\U00000301") // 1,080 bytes
	strings.write_string(&b, " end")
	check_every_offset(t, "long non-ascii run", strings.to_string(b), step = 13) // every alignment of the pattern, without the full square
}

// The reference for the word procs: a walk from the start every time, read
// off one walk's segments so the reference is not itself quadratic.
@(private = "file")
check_words_everywhere :: proc(t: ^testing.T, name, s: string, step := 1) {
	segs := make([dynamic][2]int, context.temp_allocator)
	it := runa.word_iter_make(s)
	for {
		lo, hi, ok := runa.word_iter_next(&it)
		if !ok do break
		append(&segs, [2]int{lo, hi})
	}
	for i := 0; i <= len(s) + 1; i += step {
		want_next := len(s)
		if i < len(s) do for g in segs do if g[1] > i && !segment_is_space(s[g[0]:g[1]]) { want_next = g[1]; break }
		want_prev := 0
		if i > 0 do for g in segs do if g[0] < i && !segment_is_space(s[g[0]:g[1]]) do want_prev = g[0]
		want_at: [2]int
		for g in segs { want_at = g; if i < g[1] do break }

		if got := word_next(s, i); got != want_next {
			testing.expectf(t, false, "%s: word_next(%d) = %d, want %d", name, i, got, want_next)
			return
		}
		if got := word_prev(s, i); got != want_prev {
			testing.expectf(t, false, "%s: word_prev(%d) = %d, want %d", name, i, got, want_prev)
			return
		}
		if lo, hi := word_at(s, i); lo != want_at[0] || hi != want_at[1] {
			testing.expectf(t, false, "%s: word_at(%d) = %d..%d, want %v", name, i, lo, hi, want_at)
			return
		}
	}
}

// Ctrl+Left, Ctrl+Right and a double click start their walk from a nearby
// boundary too; checked the same way, over text that hits the rules which
// look back past one character.
@(test)
word_boundaries_match_the_full_walk_everywhere :: proc(t: ^testing.T) {
	check_words_everywhere(t, "empty", "")
	check_words_everywhere(t, "prose", "  The cat's  hat, e.g. 3.14 or 1,000;\tdone.  ")
	check_words_everywhere(t, "code", "x+=f(a_b, \"s\")/2-c[i]; // ok:yes")
	check_words_everywhere(t, "base64", "data:image/png;base64,iVBORw0KGgo+AAAANSUhEUgAA/ABCD+/+/xyz==")
	// Hebrew letters with a quote and a double quote between them
	check_words_everywhere(t, "hebrew", "a \U000005D0\"\U000005D1 \U000005D2'x")
	// three regional indicators: a flag, then a lone one
	check_words_everywhere(t, "flags", "go \U0001F1EC\U0001F1E7\U0001F1EB !")
	check_words_everywhere(t, "emoji zwj", "hi \U0001F469\U0000200D\U0001F4BB+\U0001F44D\U0001F3FD ok")
	// a space, then a mark on it, then more space: WB3d no longer holds
	check_words_everywhere(t, "space mark space", "a \U00000301 b  \U00000301  c")
	check_words_everywhere(t, "cjk", "漢字、かな。English+混在 です")
	// Longer than the look-back window with no place to restart: a run of
	// letters, and a run of spaces Ctrl+Left has to look past.
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "first ")
	for _ in 0 ..< 1100 do strings.write_byte(&b, 'q')
	for _ in 0 ..< 1100 do strings.write_byte(&b, ' ')
	strings.write_string(&b, "last")
	check_words_everywhere(t, "past the window", strings.to_string(b), step = 13)
}

}
