package baldr

// Text: the app-owned editable buffer behind text_input, plus the pure
// editing primitives the widget is built from — byte-range insert/delete and
// UAX #29 grapheme / word boundary movement through runa's iterators.
//
// Everything here is independent of the tree: offsets are byte offsets into
// UTF-8, every proc clamps to the buffer, and invalid UTF-8 is tolerated
// (runa's iterators decode a bad byte as one U+FFFD of width 1), so nothing
// in this file can panic on user input.
//
// Boundary procs walk from a nearby place a walk may safely restart
// (grapheme_restart, word_restart), so a keystroke costs the distance to it,
// not the whole string, and rules that depend on history (regional
// indicator pairs, emoji sequences) stay exact.

import "core:mem"
import "core:unicode"
import "core:unicode/utf8"
import runa "baldr:third_party/runa"

// Text is an editable UTF-8 buffer owned by the app. The zero value is
// usable: the first edit allocates with context.allocator (or the allocator
// given to text_make). The widget edits it in place through the ^Text passed
// to text_input, so the app's field is always current — there is nothing to
// copy back in `update`.
//
// A `secret` Text (a passphrase; text_input sets it for `password`) never
// leaves its bytes behind: it grows by moving into a new block and zeroing
// the old one, and zeroes what it deletes, replaces or frees. text_scrub
// clears it once the secret has been used.
Text :: struct {
	buf:    [dynamic]u8,
	secret: bool,
}

// text_make returns a Text holding `initial`, allocating with `allocator`.
text_make :: proc(initial := "", allocator := context.allocator) -> Text {
	t := Text{buf = make([dynamic]u8, 0, len(initial), allocator)}
	append(&t.buf, ..transmute([]u8)initial)
	return t
}

// text_destroy frees the buffer. Safe on the zero value and after a
// previous destroy.
text_destroy :: proc(t: ^Text) {
	if t.secret && cap(t.buf) > 0 do mem.zero(raw_data(t.buf), cap(t.buf))
	delete(t.buf)
	t.buf = {}
}

// text_reserve makes room for `capacity` bytes up front.
text_reserve :: proc(t: ^Text, capacity: int) {
	if capacity > cap(t.buf) do text_grow(t, capacity)
}

// text_scrub zeroes the buffer, room past its end included, and empties it:
// for a passphrase once it has been read.
text_scrub :: proc(t: ^Text) {
	if cap(t.buf) > 0 do mem.zero(raw_data(t.buf), cap(t.buf))
	clear(&t.buf)
}

// text_grow moves the contents to a block of at least `need` bytes; a
// secret's old block is zeroed before it is freed.
@(private)
text_grow :: proc(t: ^Text, need: int) -> bool {
	alloc := t.buf.allocator if t.buf.allocator.procedure != nil else context.allocator
	nb, err := make([dynamic]u8, len(t.buf), max(need, 2 * cap(t.buf), 16), alloc)
	if err != nil do return false
	copy(nb[:], t.buf[:])
	if t.secret && cap(t.buf) > 0 do mem.zero(raw_data(t.buf), cap(t.buf))
	delete(t.buf)
	t.buf = nb
	return true
}

// text_set replaces the whole contents with `s`. `s` may alias the buffer.
text_set :: proc(t: ^Text, s: string) {
	sp, bp := uintptr(raw_data(s)), uintptr(raw_data(t.buf))
	if len(s) > 0 && len(t.buf) > 0 && sp >= bp && sp < bp + uintptr(len(t.buf)) {
		// s is a view into our own storage: move it to the front, then trim.
		off := int(sp - bp)
		n := min(len(s), len(t.buf) - off)
		old := len(t.buf)
		copy(t.buf[:n], t.buf[off:off + n])
		resize(&t.buf, n)
		if t.secret && old > n do mem.zero(rawptr(&raw_data(t.buf)[n]), old - n)
		return
	}
	if t.secret {
		if len(t.buf) > 0 do mem.zero(raw_data(t.buf), len(t.buf))
		if len(s) > cap(t.buf) && !text_grow(t, len(s)) do return
	}
	clear(&t.buf)
	append(&t.buf, ..transmute([]u8)s)
}

// str is a view of the buffer's current contents. Valid until the next edit.
str :: proc(t: Text) -> string {
	return string(t.buf[:])
}

// text_insert inserts `s` at byte offset `at` (clamped to the buffer) and
// returns the offset just after the inserted bytes. `s` must not alias the
// buffer.
text_insert :: proc(t: ^Text, at: int, s: string) -> int {
	if len(s) == 0 do return clamp(at, 0, len(t.buf))
	pos := clamp(at, 0, len(t.buf))
	old := len(t.buf)
	if t.secret && old + len(s) > cap(t.buf) && !text_grow(t, old + len(s)) do return pos // allocation failed: buffer unchanged
	resize(&t.buf, old + len(s))
	if len(t.buf) != old + len(s) do return pos // allocation failed: buffer unchanged
	copy(t.buf[pos + len(s):], t.buf[pos:old])
	copy(t.buf[pos:], transmute([]u8)s)
	return pos + len(s)
}

// text_delete removes the bytes in [lo, hi) (clamped and ordered) and
// returns the number removed.
text_delete :: proc(t: ^Text, lo, hi: int) -> int {
	a := clamp(min(lo, hi), 0, len(t.buf))
	b := clamp(max(lo, hi), 0, len(t.buf))
	if a == b do return 0
	copy(t.buf[a:], t.buf[b:])
	if t.secret do mem.zero(rawptr(&raw_data(t.buf)[len(t.buf) - (b - a)]), b - a) // the tail the shift left behind
	resize(&t.buf, len(t.buf) - (b - a))
	return b - a
}

// ---------------------------------------------------------------- boundaries

// grapheme_restart is a grapheme boundary at or before byte `i` to start a
// walk from, close to `i`: an ASCII character whose byte before is ASCII
// too, within GRAPHEME_BACK bytes, else 0.
//
// Such a character always begins a cluster. In UAX #29 nothing joins onto
// the front of a character except an Extend, a ZWJ or a SpacingMark (none
// of them ASCII), a Prepend before it (none ASCII either, hence the byte
// before) and CR before LF. Regional-indicator pairs and emoji sequences
// are all non-ASCII, so a run of them starts after the restart and pairs
// up from there exactly as it would from the start of the text. Text with
// no ASCII for a stretch (a long run of CJK) walks from the start, and is
// still right.
@(private)
grapheme_restart :: proc(s: string, i: int) -> int {
	GRAPHEME_BACK :: 1024
	hi := min(i, len(s) - 1)
	lo := max(hi - GRAPHEME_BACK, 1)
	for j := hi; j >= lo; j -= 1 {
		c, before := s[j], s[j - 1]
		if c < 0x80 && before < 0x80 && !(c == '\n' && before == '\r') do return j
	}
	return 0
}

// grapheme_next returns the first grapheme boundary after byte offset `i`
// (len(s) at the end).
grapheme_next :: proc(s: string, i: int) -> int {
	if i >= len(s) do return len(s)
	r := grapheme_restart(s, max(i, 0))
	it := runa.grapheme_iter_make(s[r:])
	for {
		_, hi, ok := runa.grapheme_iter_next(&it)
		if !ok do break
		if r + hi > i do return r + hi
	}
	return len(s)
}

// grapheme_prev returns the last grapheme boundary before byte offset `i`
// (0 at the start).
grapheme_prev :: proc(s: string, i: int) -> (prev: int) {
	if i <= 0 do return 0
	r := grapheme_restart(s, min(i, len(s)) - 1) // a boundary no later than the cluster holding byte i-1
	prev = r
	it := runa.grapheme_iter_make(s[r:])
	for {
		lo, _, ok := runa.grapheme_iter_next(&it)
		if !ok || r + lo >= i do break
		prev = r + lo
	}
	return
}

// grapheme_snap returns the nearest grapheme boundary at or before `i`, so
// an offset the app left inside a cluster (or past the end) becomes a valid
// caret position.
grapheme_snap :: proc(s: string, i: int) -> int {
	if i <= 0 do return 0
	if i >= len(s) do return len(s)
	return grapheme_prev(s, i + 1)
}

// grapheme_singles is the end of the run from `p` (which must be a place a
// walk may start, as grapheme_restart describes) in which every byte is a
// cluster of its own: ASCII followed by ASCII, CR before LF aside. It is
// also such a place itself, so a walk goes on from it. The counting procs
// below take a run like this in one step and leave only what lies between
// two such places to runa, so a long line of base64 or minified script
// costs a byte compare a character rather than the full cluster rules.
@(private)
grapheme_singles :: proc(s: string, p: int) -> int {
	q := p
	for q < len(s) {
		c := s[q]
		if c >= 0x80 do break
		if q + 1 < len(s) {
			d := s[q + 1]
			if d >= 0x80 || (c == '\r' && d == '\n') do break
		}
		q += 1
	}
	return q
}

// grapheme_restart_after is the first place after `p` a walk may start
// afresh (len(s) if none): the end of a stretch that needs runa's rules.
@(private)
grapheme_restart_after :: proc(s: string, p: int) -> int {
	for e in p + 1 ..< len(s) {
		c, before := s[e], s[e - 1]
		if c < 0x80 && before < 0x80 && !(c == '\n' && before == '\r') do return e
	}
	return len(s)
}

// grapheme_count is the number of grapheme clusters in `s`.
grapheme_count :: proc(s: string) -> (n: int) {
	p := 0
	for p < len(s) {
		if q := grapheme_singles(s, p); q > p {
			n += q - p
			p = q
			continue
		}
		e := grapheme_restart_after(s, p)
		it := runa.grapheme_iter_make(s[p:e])
		for {
			_, _, ok := runa.grapheme_iter_next(&it)
			if !ok do break
			n += 1
		}
		p = e
	}
	return
}

// grapheme_index is the number of grapheme boundaries before byte offset `i`
// — the caret's position counted in clusters.
grapheme_index :: proc(s: string, i: int) -> (n: int) {
	p := 0
	for p < len(s) && p < i {
		if q := grapheme_singles(s, p); q > p {
			n += min(q, i) - p // the clusters [k, k+1) that end by i
			p = q
			continue
		}
		e := grapheme_restart_after(s, p)
		it := runa.grapheme_iter_make(s[p:e])
		for {
			_, hi, ok := runa.grapheme_iter_next(&it)
			if !ok do break
			if p + hi > i do return
			n += 1
		}
		p = e
	}
	return
}

// grapheme_offset is the byte offset of the `idx`-th grapheme boundary
// (0 → 0; past the end → len(s)). The inverse of grapheme_index.
grapheme_offset :: proc(s: string, idx: int) -> int {
	if idx <= 0 do return 0
	n, p := 0, 0
	for p < len(s) {
		if q := grapheme_singles(s, p); q > p {
			if idx <= n + (q - p) do return p + (idx - n)
			n += q - p
			p = q
			continue
		}
		e := grapheme_restart_after(s, p)
		it := runa.grapheme_iter_make(s[p:e])
		for {
			_, hi, ok := runa.grapheme_iter_next(&it)
			if !ok do break
			n += 1
			if n == idx do return p + hi
		}
		p = e
	}
	return len(s)
}

// word_restart is a word boundary at or before byte `i` to start a walk
// from, close to `i`, as grapheme_restart is for clusters: an ASCII
// character after one that no word rule joins onto — punctuation such as
// `+ / - ( ) =`, a tab, or a space not followed by another — within
// WORD_BACK bytes, else 0.
//
// In UAX #29 such a character takes part in no rule but the default break,
// so a boundary always falls after it when an ASCII character follows (none
// is an Extend, a Format or a ZWJ, the only things that hold on). And runa's
// iterator starts each word with its state fresh, so a walk from any
// boundary finds the same words after it as one from the start. Base64 has
// a `+` or `/` every thirty-odd characters and prose a space every few, so
// Ctrl+Left on a very long line looks at a few dozen characters.
@(private)
word_restart :: proc(s: string, i: int) -> int {
	WORD_BACK :: 1024
	hi := min(i, len(s) - 1)
	lo := max(hi - WORD_BACK, 1)
	for j := hi; j >= lo; j -= 1 {
		c, before := s[j], s[j - 1]
		if c < 0x80 && word_rule_free(before) && !(before == ' ' && c == ' ') do return j
	}
	return 0
}

// word_rule_free: an ASCII byte whose word-break class is Other or
// WSegSpace — not a letter, digit, `_`, quote, `. : , ;`, or a line break.
@(private)
word_rule_free :: proc(b: u8) -> bool {
	switch b {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', '\'', '"', '.', ':', ',', ';', '\r', '\n', 0x0B, 0x0C:
		return false
	}
	return b < 0x80
}

// word_next returns the end of the word at or after byte offset `i`:
// whitespace after the caret is skipped, then the caret lands after the next
// run of non-space characters (the Ctrl+Right convention).
word_next :: proc(s: string, i: int) -> int {
	if i >= len(s) do return len(s)
	r := word_restart(s, max(i, 0))
	it := runa.word_iter_make(s[r:])
	for {
		lo, hi, ok := runa.word_iter_next(&it)
		if !ok do break
		if r + hi <= i || segment_is_space(s[r + lo:r + hi]) do continue
		return r + hi
	}
	return len(s)
}

// word_prev returns the start of the word before byte offset `i`: the start
// of the last run of non-space characters that begins before the caret (the
// Ctrl+Left convention).
word_prev :: proc(s: string, i: int) -> int {
	if i <= 0 do return 0
	before := min(i, len(s)) // the word sought begins before this
	for {
		r := word_restart(s, before - 1)
		prev := -1
		it := runa.word_iter_make(s[r:])
		for {
			lo, hi, ok := runa.word_iter_next(&it)
			if !ok || r + lo >= before do break
			if !segment_is_space(s[r + lo:r + hi]) do prev = r + lo
		}
		if prev >= 0 do return prev
		if r == 0 do return 0
		before = r // only space since the restart: the word is further back
	}
}

// word_at returns the word segment containing byte offset `i` (a run of
// whitespace counts as a segment, so double-clicking a gap selects the gap).
// At the very end it returns the last segment; an empty string gives (0, 0).
word_at :: proc(s: string, i: int) -> (lo, hi: int) {
	r := word_restart(s, max(i, 0))
	it := runa.word_iter_make(s[r:])
	for {
		a, b, ok := runa.word_iter_next(&it)
		if !ok do break
		lo, hi = r + a, r + b
		if i < r + b do break
	}
	return
}

@(private)
segment_is_space :: proc(seg: string) -> bool {
	for r in seg {
		if !unicode.is_space(r) do return false
	}
	return true
}

// sanitize_input drops the characters a single-line field cannot hold — C0
// and C1 control characters, including newlines and tabs — keeping every
// other byte (invalid UTF-8 included; the buffer and iterators tolerate it).
// Returns `s` itself when nothing had to go; otherwise a copy in
// `allocator` (temp memory by default).
sanitize_input :: proc(s: string, allocator := context.temp_allocator) -> string {
	clean := true
	for r in s {
		if is_control(r) {
			clean = false
			break
		}
	}
	if clean do return s
	out := make([dynamic]u8, 0, len(s), allocator)
	for i := 0; i < len(s); {
		r, n := utf8.decode_rune_in_string(s[i:])
		if n <= 0 do n = 1
		if !is_control(r) do append(&out, ..transmute([]u8)s[i:i + n])
		i += n
	}
	return string(out[:])
}

@(private)
is_control :: proc "contextless" (r: rune) -> bool {
	return r < 0x20 || r == 0x7f || (r >= 0x80 && r < 0xa0)
}
