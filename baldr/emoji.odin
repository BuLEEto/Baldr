package baldr

// The emoji table behind `emoji_picker`: the generated blob in
// emoji_data.odin, parsed once, searched by CLDR short name, and skin tones
// applied. Kept apart from the widget so it tests without a window and an
// app can use the lookup alone, say to turn `:joy:` into an emoji as it is
// typed.

import "core:strings"
import "core:sync"
import "core:unicode/utf8"

// Emoji is one entry: the sequence to insert, its CLDR short name (lower
// case, which is what `emoji_search` matches), which of `EMOJI_GROUPS` it
// belongs to, and whether it has skin-tone variants.
//
// Every field aliases the generated blob, which lives for the program —
// nothing here is the caller's to free.
Emoji :: struct {
	seq:   string,
	name:  string,
	group: int,
	skin:  bool,
}

// Skin_Tone is Unicode's five modifiers, and `.None` for the yellow
// default. A person's choice is a preference the **app** keeps, as it keeps
// their recents, so it is passed to the picker rather than hidden in it.
Skin_Tone :: enum u8 { None, Light, Medium_Light, Medium, Medium_Dark, Dark }

@(private)
SKIN_RUNES := [Skin_Tone]rune{
	.None         = 0,
	.Light        = '\U0001F3FB',
	.Medium_Light = '\U0001F3FC',
	.Medium       = '\U0001F3FD',
	.Medium_Dark  = '\U0001F3FE',
	.Dark         = '\U0001F3FF',
}

// Static storage, not an allocation: the table lives for the program, so an
// allocation would never be freed and would show in every leak report. The
// entries point into the string constant.
@(private = "file")
emoji_table_once: sync.Once
@(private = "file")
emoji_storage: [EMOJI_COUNT]Emoji
@(private = "file")
emoji_all: []Emoji
@(private = "file")
emoji_group_storage: [EMOJI_GROUP_COUNT + 1]int
@(private = "file")
emoji_group_at: []int // where each group starts in emoji_all, plus the end

// emoji_table is every emoji the bundled face can draw, in Unicode's own
// order — which groups them, so `emoji_group_range` can slice it.
//
// The slice belongs to the toolkit and lives for the program: parsed once,
// on the first call, from a string constant. Do not free it.
emoji_table :: proc() -> []Emoji {
	sync.once_do(&emoji_table_once, emoji_parse)
	return emoji_all
}

// emoji_group_range is the half-open range of `emoji_table()` holding
// group `g` (an index into EMOJI_GROUPS).
emoji_group_range :: proc(g: int) -> (lo, hi: int) {
	sync.once_do(&emoji_table_once, emoji_parse)
	if g < 0 || g >= len(EMOJI_GROUPS) do return 0, 0
	return emoji_group_at[g], emoji_group_at[g + 1]
}

@(private = "file")
emoji_parse :: proc() {
	out := emoji_storage[:]
	at := 0
	text := EMOJI_DATA
	for line in strings.split_lines_iterator(&text) {
		if len(line) == 0 do continue
		// seq \t group \t skin \t name — no CLDR name holds a tab, and no
		// emoji holds a newline, so splitting cannot go wrong.
		a := strings.index_byte(line, '\t');        if a < 0 do continue
		b := strings.index_byte(line[a + 1:], '\t'); if b < 0 do continue
		b += a + 1
		c := strings.index_byte(line[b + 1:], '\t'); if c < 0 do continue
		c += b + 1
		if at >= len(out) do break // EMOJI_COUNT and the blob disagree: generated together, so this cannot happen
		out[at] = Emoji {
			seq   = line[:a],
			group = int(line[a + 1] - '0'),
			skin  = line[b + 1] == '1',
			name  = line[c + 1:],
		}
		at += 1
	}
	emoji_all = out[:at]

	starts := emoji_group_storage[:]
	g := 0
	for e, i in emoji_all {
		for g <= e.group {
			starts[g] = i
			g += 1
		}
	}
	for g <= len(EMOJI_GROUPS) {
		starts[g] = len(emoji_all)
		g += 1
	}
	emoji_group_at = starts
}

// emoji_search finds emoji whose CLDR name matches `query`, best first, and
// returns how many it wrote into `out`.
//
// Matching is by word prefix, not substring: "ca" finds "cat" and "car" but
// not "scar". A name whose first word matches sorts before one where a later
// word does, so "he" offers "heart" before "blue heart". `query` is matched
// lower case; nothing is allocated — the results alias the table.
emoji_search :: proc(query: string, out: []Emoji) -> int {
	table := emoji_table()
	q := strings.trim_space(query)
	if len(q) == 0 || len(out) == 0 do return 0
	n := 0
	// two passes, so the better matches are first without a sort
	for pass in 0 ..< 2 {
		for e in table {
			if n >= len(out) do return n
			if emoji_rank(e.name, q) != pass do continue
			out[n] = e
			n += 1
		}
	}
	return n
}

// emoji_rank is 0 when the name's first word starts with `q`, 1 when a
// later word does, and 2 when it does not match at all.
@(private)
emoji_rank :: proc(name, q: string) -> int {
	if strings.has_prefix(name, q) do return 0
	rest := name
	for {
		i := strings.index_byte(rest, ' ')
		if i < 0 do return 2
		rest = rest[i + 1:]
		if strings.has_prefix(rest, q) do return 1
	}
}

// emoji_with_tone is `e`'s sequence in skin tone `tone`, written into
// `buf` and returned as a slice of it, so a grid draws without allocating
// (EMOJI_SEQ_MAX bytes is enough). The modifier goes after the first
// codepoint, not at the end: an astronaut is U+1F9D1 U+1F3FD ZWJ U+1F680. A
// U+FE0F after that codepoint is replaced, since a tone already asks for
// emoji presentation. No tones, `.None`, or too small a `buf`: unchanged.
emoji_with_tone :: proc(e: Emoji, tone: Skin_Tone, buf: []u8) -> string {
	if tone == .None || !e.skin do return e.seq
	mod := SKIN_RUNES[tone]
	_, size := utf8.decode_rune_in_string(e.seq)
	if size <= 0 do return e.seq
	rest := e.seq[size:]
	VS16 :: rune(0xFE0F) // emoji presentation; a tone already asks for it
	if r, rs := utf8.decode_rune_in_string(rest); r == VS16 && rs > 0 do rest = rest[rs:]
	mod_bytes, mod_len := utf8.encode_rune(mod)
	if size + mod_len + len(rest) > len(buf) do return e.seq
	n := copy(buf, e.seq[:size])
	n += copy(buf[n:], mod_bytes[:mod_len])
	n += copy(buf[n:], rest)
	return string(buf[:n])
}

// EMOJI_SEQ_MAX is how big a buffer `emoji_with_tone` needs.
EMOJI_SEQ_MAX :: 64
