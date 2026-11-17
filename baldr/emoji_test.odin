package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// The table behind the emoji picker. All of it runs without a
// window, which is the point of keeping it apart from the widget.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// The generated blob parses into what the generator counted, and every
// entry is whole.
@(test)
the_emoji_table_parses :: proc(t: ^testing.T) {
	es := emoji_table()
	testing.expectf(t, len(es) > 1500, "the table has most of Unicode's emoji in it (%d)", len(es))
	for e, i in es {
		testing.expectf(t, len(e.seq) > 0, "entry %d has a sequence", i)
		testing.expectf(t, len(e.name) > 0, "entry %d (%s) has a name", i, e.seq)
		testing.expectf(t, e.group >= 0 && e.group < len(EMOJI_GROUPS), "entry %d is in a group (%d)", i, e.group)
		testing.expectf(t, strings.to_lower(e.name, context.temp_allocator) == e.name,
			"names are lower case for searching (%q)", e.name)
	}
	// it is the same slice every time: parsed once, never freed
	testing.expect(t, raw_data(emoji_table()) == raw_data(es), "the table is parsed once")
}

// Groups are contiguous, so a picker can slice them instead of filtering.
@(test)
emoji_groups_are_contiguous_ranges :: proc(t: ^testing.T) {
	es := emoji_table()
	total := 0
	for _, g in EMOJI_GROUPS {
		lo, hi := emoji_group_range(g)
		testing.expectf(t, lo <= hi, "group %d is a range", g)
		for i in lo ..< hi do testing.expectf(t, es[i].group == g, "entry %d is in group %d", i, g)
		total += hi - lo
	}
	testing.expect_value(t, total, len(es)) // every entry is in exactly one group
	lo, hi := emoji_group_range(999)
	testing.expect(t, lo == 0 && hi == 0, "a group that does not exist is empty, not a crash")
}

// Search is by word, so a short query can be aimed. "ca" finds cat and car
// and not "scar"; a first-word match comes before a later-word one.
@(test)
emoji_search_matches_words_best_first :: proc(t: ^testing.T) {
	out: [64]Emoji
	n := emoji_search("heart", out[:])
	testing.expect(t, n > 5, "plenty of hearts")
	testing.expect(t, strings.has_prefix(out[0].name, "heart"), "a first-word match leads")
	later := false
	for e in out[:n] do if !strings.has_prefix(e.name, "heart") do later = true
	testing.expect(t, later, "and later-word matches follow (blue heart)")
	// the first-word ones all come before the later-word ones
	seen_later := false
	for e in out[:n] {
		if !strings.has_prefix(e.name, "heart") do seen_later = true
		else do testing.expect(t, !seen_later, "no first-word match after a later-word one")
	}

	n2 := emoji_search("ca", out[:])
	testing.expect(t, n2 > 0, "ca finds something")
	for e in out[:n2] {
		ok := strings.has_prefix(e.name, "ca") || strings.contains(e.name, " ca")
		testing.expectf(t, ok, "%q starts a word with \"ca\"", e.name)
	}

	testing.expect_value(t, emoji_search("", out[:]), 0)
	testing.expect_value(t, emoji_search("   ", out[:]), 0)
	testing.expect_value(t, emoji_search("zzzzqqq", out[:]), 0)
	testing.expect_value(t, emoji_search("heart", out[:0]), 0) // nowhere to put them
}

// The modifier goes after the first codepoint, not at the end: an
// astronaut is U+1F9D1 U+1F3FD ZWJ U+1F680, and appending would give a tone
// swatch floating after a rocket.
@(test)
a_skin_tone_goes_after_the_first_codepoint :: proc(t: ^testing.T) {
	buf: [EMOJI_SEQ_MAX]u8
	find :: proc(name: string) -> (Emoji, bool) {
		for e in emoji_table() do if e.name == name do return e, true
		return {}, false
	}

	wave, ok := find("waving hand")
	testing.expect(t, ok, "waving hand is in the table")
	testing.expect(t, wave.skin, "and has skin tones")
	testing.expect_value(t, emoji_with_tone(wave, .Medium, buf[:]), "\U0001F44B\U0001F3FD")

	astro, ok2 := find("astronaut")
	testing.expect(t, ok2, "astronaut is in the table")
	if ok2 && astro.skin {
		// U+1F9D1 U+1F3FD ZWJ U+1F680, exactly as emoji-test.txt has it
		testing.expect_value(t, emoji_with_tone(astro, .Medium, buf[:]),
			"\U0001F9D1\U0001F3FD‍\U0001F680")
	}

	// a variation selector is replaced, not kept: U+1F590 U+FE0F -> U+1F590 U+1F3FB
	splayed, ok3 := find("hand with fingers splayed")
	if ok3 && splayed.skin {
		testing.expect_value(t, emoji_with_tone(splayed, .Light, buf[:]), "\U0001F590\U0001F3FB")
	}
}

// Emoji with no tones, and .None, come back untouched — and the original is
// returned, not a copy, so nothing is spent on the common case.
@(test)
an_emoji_without_tones_is_returned_unchanged :: proc(t: ^testing.T) {
	buf: [EMOJI_SEQ_MAX]u8
	for e in emoji_table() {
		if e.skin do continue
		got := emoji_with_tone(e, .Dark, buf[:])
		testing.expectf(t, raw_data(got) == raw_data(e.seq), "%q is not toned", e.name)
		break
	}
	for e in emoji_table() {
		if !e.skin do continue
		testing.expect(t, raw_data(emoji_with_tone(e, .None, buf[:])) == raw_data(e.seq))
		break
	}
	// a buffer too small is answered, not overrun
	tiny: [2]u8
	for e in emoji_table() {
		if !e.skin do continue
		testing.expect_value(t, emoji_with_tone(e, .Dark, tiny[:]), e.seq)
		break
	}
}

// Every toned form fits the buffer the API promises.
@(test)
every_toned_emoji_fits_the_documented_buffer :: proc(t: ^testing.T) {
	buf: [EMOJI_SEQ_MAX]u8
	worst := 0
	for e in emoji_table() {
		if !e.skin do continue
		got := emoji_with_tone(e, .Dark, buf[:])
		testing.expectf(t, len(got) > len(e.seq), "%q grew by a modifier", e.name)
		worst = max(worst, len(got))
	}
	testing.expectf(t, worst <= EMOJI_SEQ_MAX, "the longest toned sequence is %d bytes", worst)
}

}
