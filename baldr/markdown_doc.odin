package baldr

// The document behind a read-only markdown view: the markdown
// source exactly as it was given, and the blocks parsed out of it — one per
// source line, the same grouping `document_set_markdown` gives the editors,
// so a view and an editor never disagree about what a block is.
//
// It is built for text that arrives a few characters at a time, for minutes.
// `md_append` parses only what the new bytes completed: every block before
// the last is left alone, so a reply streaming at thirty updates a second
// costs its last line rather than the whole reply. The source is kept, which
// is what lets a selection be source byte offsets (bytes added at the end
// cannot move one made earlier) and what makes "copy as markdown" exact.

import "base:runtime"
import "core:strings"
import "core:unicode/utf8"

// Md_Block is one source line's worth of block: what it is, where it is in
// the source, and where its inline text starts (after "# ", "- ", "> ").
// `in_fence` is the state *entering* the line, so a parse may restart here.
// `open` marks the provisional last block — a line whose newline has not
// arrived yet, which the next append may change.
Md_Block :: struct {
	meta:     Block_Meta,
	from, to: int, // source byte range of the line, its newline not included
	body:     int, // source byte where the inline text starts
	// A fence's language and a picture's src as offsets: the strings in
	// `meta` are slices of `src`, which an append reallocates.
	// md_parse_from derives the strings again from these.
	lang_at:  [2]int,
	src_at:   [2]int,
	in_fence: bool,
	open:     bool,
}

// Markdown_Doc is a markdown document an app owns and a `markdown_view`
// shows, as a `Document` is owned and shown by a `text_area`. Give it to
// `md_set` whole, or grow it with `md_append` as a reply streams.
//
// Zero value is usable: the first call allocates with the context's
// allocator, or `md_init`'s. `md_destroy` frees it. Everything it hands
// back (`md_text`, a block's range) is a view into memory it owns and is
// invalidated by the next change — clone what you keep.
Markdown_Doc :: struct {
	src:       [dynamic]u8,
	blocks:    [dynamic]Md_Block,
	rev:       u64, // bumped by every change; a view relays out when it moves
	id:        u64, // names this document for its lifetime, so a view can tell a new one from the one it cached at the same address
	parsed_to: int, // source bytes already parsed into finalised blocks
	in_fence:  bool, // the fence state after those bytes
	fence_lang: string, // …and the language the open fence named (a slice of src, re-derived after every parse)
	fence_at:  [2]int,  // …which is this range of it
	tail:      [4]u8, // an incomplete UTF-8 sequence held back until it completes
	tail_len:  int,
	allocator: runtime.Allocator,
}

// md_init prepares a document with an allocator of its own. Calling it is
// optional: any of the others does the same with the context's allocator.
md_init :: proc(md: ^Markdown_Doc, allocator := context.allocator) {
	md.allocator = allocator
	if md.id == 0 do md.id = doc_new_id() // as a Document is named, and for the same reason
	md.src = make([dynamic]u8, allocator)
	md.blocks = make([dynamic]Md_Block, allocator)
}

// md_destroy frees the document's source and blocks.
md_destroy :: proc(md: ^Markdown_Doc) {
	delete(md.src)
	delete(md.blocks)
	md^ = {}
}

@(private)
md_ensure :: proc(md: ^Markdown_Doc) {
	if md.allocator.procedure == nil do md_init(md, context.allocator)
}

// md_text is the markdown source as it stands: everything given, minus an
// incomplete UTF-8 sequence still waiting for its remaining bytes. It is a
// view into the document — the next change invalidates it.
md_text :: proc(md: ^Markdown_Doc) -> string {
	return string(md.src[:])
}

// md_clear empties the document: a reply being retried, or an alternative
// taking its place.
md_clear :: proc(md: ^Markdown_Doc) {
	md_ensure(md)
	clear(&md.src)
	clear(&md.blocks)
	md.parsed_to, md.in_fence, md.fence_lang, md.fence_at, md.tail_len = 0, false, "", {}, 0 // fence_at too: it indexes the old text
	md.rev += 1
}

// md_set replaces the document with `text` — a stored message, or opening a
// chat. The text is copied. For a reply that is still arriving, set what
// there is (or "") and `md_append` the rest: appending is what stays cheap.
md_set :: proc(md: ^Markdown_Doc, text: string) {
	md_clear(md)
	md_append(md, text)
}

// md_append adds `delta` to the end of the document and parses what it
// completed, leaving every block before the last alone. A delta may split
// anywhere — mid-word, mid-UTF-8 sequence, mid-code-fence, mid-table-row —
// which is what a stream of tokens does:
//
//   - an incomplete UTF-8 sequence at the end is held back until its
//     remaining bytes arrive, so no replacement character is ever shown;
//   - a line whose newline has not arrived is a provisional block, remade by
//     the next append;
//   - an open fence stays open: its lines are code as they arrive.
md_append :: proc(md: ^Markdown_Doc, delta: string) {
	md_ensure(md)
	if len(delta) == 0 do return

	// the bytes held back last time, then the new ones
	if md.tail_len > 0 {
		append(&md.src, ..md.tail[:md.tail_len])
		md.tail_len = 0
	}
	append(&md.src, ..transmute([]u8)delta)

	// hold back a trailing incomplete sequence, so nothing draws half a rune
	if n := md_incomplete_tail(md.src[:]); n > 0 {
		cut := len(md.src) - n
		copy(md.tail[:], md.src[cut:])
		md.tail_len = n
		resize(&md.src, cut)
	}
	md_parse_from(md, md.parsed_to)
	md.rev += 1
}

// md_incomplete_tail is the length of an unfinished UTF-8 sequence at the
// end of `s`, 0 when the last rune is whole (or plainly invalid, which is
// the decoder's business, not something to wait for).
@(private)
md_incomplete_tail :: proc(s: []u8) -> int {
	for back in 1 ..= min(3, len(s)) {
		c := s[len(s) - back]
		if c < 0x80 do return 0 // ASCII: nothing pending
		if c >= 0xC0 { // the lead byte of a sequence: is it all here?
			need := 2 if c < 0xE0 else 3 if c < 0xF0 else 4
			return back if back < need else 0
		}
	}
	return 0 // three continuation bytes and no lead: not ours to wait for
}

// md_parse_from re-reads the source from `at` — a block boundary — and
// rebuilds the blocks from there. Everything before it is untouched.
@(private)
md_parse_from :: proc(md: ^Markdown_Doc, at: int) {
	for len(md.blocks) > 0 && md.blocks[len(md.blocks) - 1].from >= at {
		pop(&md.blocks) // the provisional block, and anything else after the mark
	}
	// The fence state is committed only for a line whose newline has
	// arrived: a provisional fence line would otherwise be re-read by the
	// next append as the closing fence.
	in_fence, lang := md.in_fence, md.fence_lang
	at_lang := md.fence_at
	src := string(md.src[:])
	i := at
	for i <= len(src) {
		nl := strings.index_byte(src[i:], '\n')
		done := nl < 0
		if done && i == len(src) do break // nothing left but the end
		end := len(src) if done else i + nl
		line := src[i:end]
		if len(line) > 0 && line[len(line) - 1] == '\r' do line = line[:len(line) - 1]
		md_parse_line(md, line, i, i + len(line), done, &in_fence, &lang, &at_lang)
		if done do break
		i = end + 1
		md.parsed_to = i // …only complete lines are finalised
		md.in_fence, md.fence_lang, md.fence_at = in_fence, lang, at_lang
	}
	md_derive_aliases(md)
}

// md_span is where `part` — a slice of the document's source — sits in it.
@(private)
md_span :: proc(md: ^Markdown_Doc, part: string) -> [2]int {
	if len(part) == 0 do return {0, 0}
	base := uintptr(raw_data(md.src[:]))
	at := int(uintptr(raw_data(part)) - base)
	if at < 0 || at + len(part) > len(md.src) do return {0, 0}
	return {at, at + len(part)}
}

// md_derive_aliases points every block's language and picture source back
// into the source as it is now: they are slices of it, and an append
// reallocates it, which would leave them naming freed memory.
@(private)
md_derive_aliases :: proc(md: ^Markdown_Doc) {
	for &b in md.blocks {
		if b.lang_at[1] > b.lang_at[0] do b.meta.lang = string(md.src[b.lang_at[0]:b.lang_at[1]])
		if b.src_at[1] > b.src_at[0] do b.meta.src = string(md.src[b.src_at[0]:b.src_at[1]])
	}
	if md.fence_at[1] > md.fence_at[0] do md.fence_lang = string(md.src[md.fence_at[0]:md.fence_at[1]])
}

// md_parse_line turns one source line into a block (or into a change to the
// block before it, which is what a table's separator row is).
@(private)
md_parse_line :: proc(md: ^Markdown_Doc, line: string, from, to: int, open: bool, in_fence: ^bool, lang: ^string, lang_at: ^[2]int) {
	b := Md_Block{from = from, to = to, body = from, in_fence = in_fence^, open = open}

	if in_fence^ {
		if strings.has_prefix(strings.trim_left_space(line), "```") {
			if !open do in_fence^ = false // a closing fence draws nothing itself
			return
		}
		b.meta = Block_Meta{kind = .Code, lang = lang^}
		b.lang_at = lang_at^
		append(&md.blocks, b)
		return
	}

	ml := markdown_line(line)
	switch {
	case ml.fence:
		in_fence^, lang^ = true, ml.lang
		lang_at^ = md_span(md, ml.lang)
	case ml.rule:
		b.meta = Block_Meta{kind = .Rule}
		append(&md.blocks, b)
	case ml.meta.kind == .Image:
		b.meta = ml.meta
		b.src_at = md_span(md, ml.meta.src)
		b.body = from + ml.body
		append(&md.blocks, b)
	case ml.meta.kind == .Table_Sep:
		// The line under a header row makes that row the header — but only
		// once this line is whole: "|--" may yet turn out to be an ordinary
		// row, and the header it marked would have no way back.
		if open do return
		if n := len(md.blocks); n > 0 && md.blocks[n - 1].meta.kind == .Table do md.blocks[n - 1].meta.level = 1
	case ml.meta.kind == .Table:
		b.meta = ml.meta
		append(&md.blocks, b)
	case len(strings.trim_space(line)) == 0:
		// a blank line between paragraphs is spacing, not a block
	case:
		b.meta = ml.meta
		b.body = from + ml.body
		append(&md.blocks, b)
	}
}

// md_block_text is one block's inline source — what a renderer lays out and
// what "copy as text" reads. It is a view into the document.
md_block_text :: proc(md: ^Markdown_Doc, i: int) -> string {
	if i < 0 || i >= len(md.blocks) do return ""
	b := md.blocks[i]
	return string(md.src[b.body:b.to])
}

// md_markdown is the source behind a byte range — what "copy as markdown"
// copies. `from` and `to` are source byte offsets; they are clamped, and a
// range that falls inside a rune is widened to whole runes. It is a view
// into the document.
md_markdown :: proc(md: ^Markdown_Doc, from, to: int) -> string {
	lo := clamp(min(from, to), 0, len(md.src))
	hi := clamp(max(from, to), 0, len(md.src))
	s := string(md.src[:])
	for lo > 0 && !utf8.rune_start(s[lo]) do lo -= 1
	for hi < len(s) && !utf8.rune_start(s[hi]) do hi += 1
	return s[lo:hi]
}
