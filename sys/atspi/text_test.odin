#+build linux
package atspi

// The counting and the boundaries — the half of the Text interface that is
// easy to get subtly wrong, and that a reader leans on for every word it
// speaks. AT-SPI counts characters; these check that a multi-byte character
// counts as one, and that "the word at this offset" means what AT-SPI says
// it means.

@(require) import "core:strings"
@(require) import "core:testing"
@(require) import "core:time"

// Test files are part of the package, so everything that imports it would
// type-check them too: they sit behind this `when` (see baldr/canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
SAMPLE :: "The café is open.\nSecond line here."

@(test)
atspi_counts_characters_not_bytes :: proc(t: ^testing.T) {
	testing.expect_value(t, runes_len("naïve café"), 10)
	testing.expect_value(t, byte_at("naïve café", 10), 12) // two of them take two bytes
	testing.expect_value(t, char_at("naïve café", 12), 10)
	testing.expect_value(t, slice_chars("naïve café", 6, 10), "café")
	// past either end is the end, not a crash
	testing.expect_value(t, byte_at("abc", 99), 3)
	testing.expect_value(t, slice_chars("abc", 2, 99), "c")
	testing.expect_value(t, char_at("", 5), 0)
}

@(test)
atspi_finds_the_word_at_an_offset :: proc(t: ^testing.T) {
	// granularity: the word itself
	text, start, end := piece(SAMPLE, 5, .Word)
	testing.expect_value(t, text, "café")
	testing.expect_value(t, start, 4)
	testing.expect_value(t, end, 8)

	// the older question, which takes the space on one side or the other
	text, _, _ = piece_bounded(SAMPLE, 5, .Word_Start)
	testing.expect_value(t, text, "café ") // …to the start of the next word
	text, _, _ = piece_bounded(SAMPLE, 5, .Word_End)
	testing.expect_value(t, text, " café") // …from the end of the last one

	// a character, and a whole line
	text, _, _ = piece(SAMPLE, 0, .Char)
	testing.expect_value(t, text, "T")
	text, start, end = piece(SAMPLE, 5, .Line)
	testing.expect_value(t, text, "The café is open.")
	testing.expect_value(t, start, 0)
	testing.expect_value(t, end, 17)
	text, _, _ = piece(SAMPLE, 20, .Line)
	testing.expect_value(t, text, "Second line here.")

	// LINE_END takes the newline with it, LINE_START does not
	text, _, _ = piece_bounded(SAMPLE, 5, .Line_End)
	testing.expect_value(t, text, "The café is open.\n")
	text, _, _ = piece_bounded(SAMPLE, 5, .Line_Start)
	testing.expect_value(t, text, "The café is open.")

	// a sentence stops at its full stop
	text, _, _ = piece(SAMPLE, 2, .Sentence)
	testing.expect_value(t, text, "The café is open.")
}

@(test)
atspi_says_something_sensible_at_the_ends :: proc(t: ^testing.T) {
	// the offset one past the last character is where a caret sits: asking
	// there must not run off the end
	n := runes_len(SAMPLE)
	text, start, end := piece(SAMPLE, n, .Char)
	testing.expect_value(t, text, "")
	testing.expect_value(t, start, n)
	testing.expect_value(t, end, n)
	text, _, _ = piece(SAMPLE, n, .Word)
	testing.expect_value(t, text, ".")
	text, _, _ = piece("", 0, .Line)
	testing.expect_value(t, text, "")
	text, _, _ = piece(SAMPLE, -5, .Word)
	testing.expect_value(t, text, "The")
}

// A reader asks for the line, word or sentence at an offset for every move,
// and any program on the accessibility bus may ask too: on one line of
// 80,000 characters each answer still comes at once.
@(test)
atspi_boundaries_on_a_long_line_are_quick :: proc(t: ^testing.T) {
	s := strings.repeat("word é ", 80_000 / 7, context.temp_allocator)
	n := runes_len(s)
	start := time.tick_now()
	for g in Granularity do _, _, _ = piece(s, n - 3, g)
	ls, le := line_bounds(s, n / 2, true)
	ws, we := word_bounds(s, n - 3)
	ms := time.duration_milliseconds(time.tick_since(start))
	testing.expect_value(t, ls, 0)
	testing.expect_value(t, le, n)
	testing.expect(t, we - ws == 1 || we - ws == 4, "a word or the run beside it")
	testing.expectf(t, ms < 100, "every boundary at once: %.1f ms", ms)
}

} // when ODIN_TEST
