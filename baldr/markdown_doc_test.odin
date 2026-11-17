package baldr

@(require) import "core:fmt"
@(require) import "core:strings"
@(require) import "core:testing"
@(require) import "core:unicode/utf8"

// Behind this `when` so a program importing Baldr does not type-check the
// test suite too, which costs gigabytes. ODIN_TEST is set by `odin test`;
// BALDR_TESTS lets ./build.sh check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// The document behind the markdown view: a reply delivered a few bytes at a
// time ends up identical to the same reply set whole, appending costs only
// the end, and a delta splitting anywhere (mid-word, mid-rune, mid-fence,
// mid-table) never leaves the document in a state a reader would see as
// broken.


@(private = "file")
REPLY :: `# Odin

Some **bold** text with a ` + "`code span`" + ` and a [link](https://example.com).

- a bullet
- another, with ~~strike~~
- [ ] a task
- [x] a done task

> a quote

| a | b |
|---|---|
| 1 | 2 |

` + "```odin" + `
main :: proc() {
	fmt.println("hi")
}
` + "```" + `

The end — after an em dash, and an arrow -> too.
`

// md_blocks_equal: the two documents parsed to the same blocks.
@(private = "file")
md_blocks_equal :: proc(t: ^testing.T, a, b: ^Markdown_Doc, what: string) {
	testing.expectf(t, len(a.blocks) == len(b.blocks), "%s: %d blocks vs %d", what, len(a.blocks), len(b.blocks))
	if len(a.blocks) != len(b.blocks) do return
	for i in 0 ..< len(a.blocks) {
		x, y := a.blocks[i], b.blocks[i]
		testing.expectf(t, x.meta.kind == y.meta.kind && x.from == y.from && x.to == y.to && x.body == y.body &&
			x.meta.level == y.meta.level && x.meta.depth == y.meta.depth && x.meta.checked == y.meta.checked,
			"%s: block %d is %v %d..%d (body %d, level %d) vs %v %d..%d (body %d, level %d)",
			what, i, x.meta.kind, x.from, x.to, x.body, x.meta.level, y.meta.kind, y.from, y.to, y.body, y.meta.level)
	}
}

@(test)
a_streamed_reply_ends_up_the_same_as_one_set_whole :: proc(t: ^testing.T) {
	whole: Markdown_Doc
	md_set(&whole, REPLY)
	defer md_destroy(&whole)
	testing.expect(t, len(whole.blocks) > 10, "the reply parsed into blocks")
	testing.expect_value(t, md_text(&whole), REPLY)

	// the deltas a stream really gives: every chunk size, splitting words,
	// fences, table rows and the em dash's bytes alike
	for chunk in ([]int{1, 2, 3, 5, 8, 64}) {
		streamed: Markdown_Doc
		defer md_destroy(&streamed)
		md_set(&streamed, "")
		src := REPLY // a constant cannot be sliced by a variable
		for i := 0; i < len(src); i += chunk {
			md_append(&streamed, src[i:min(i + chunk, len(src))])
		}
		testing.expectf(t, md_text(&streamed) == src, "%d-byte chunks: the source came out whole", chunk)
		md_blocks_equal(t, &whole, &streamed, fmt.tprintf("%d-byte chunks", chunk))
	}
}

@(test)
appending_leaves_the_blocks_above_alone :: proc(t: ^testing.T) {
	// a reply at thirty updates a second must not re-lay what is being read
	// further up
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, "# Title\n\nA first paragraph.\nA second one.\n")
	settled := len(md.blocks)
	testing.expect(t, settled >= 3, "three blocks so far")
	before := make([]Md_Block, settled, context.temp_allocator)
	copy(before, md.blocks[:])

	md_append(&md, "And a third, arriving")
	testing.expect(t, len(md.blocks) == settled + 1, "one new block")
	for i in 0 ..< settled {
		testing.expectf(t, md.blocks[i] == before[i], "block %d moved while text was appended", i)
	}
	testing.expect(t, md.blocks[settled].open, "the growing line is the provisional one")

	// …and the provisional block is remade, not duplicated, as it grows
	md_append(&md, " in pieces.")
	testing.expect_value(t, len(md.blocks), settled + 1)
	for i in 0 ..< settled do testing.expectf(t, md.blocks[i] == before[i], "block %d moved on the second append", i)
	testing.expect_value(t, md_block_text(&md, settled), "And a third, arriving in pieces.")
}

@(test)
a_delta_may_split_a_codepoint :: proc(t: ^testing.T) {
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, "")
	// an em dash, one byte at a time: never a partial rune on show
	for b in transmute([]u8)string("a — b") {
		md_append(&md, string([]u8{b}))
		s := md_text(&md)
		testing.expect(t, utf8.valid_string(s), "the text is always valid UTF-8")
	}
	testing.expect_value(t, md_text(&md), "a — b")

	// the same for a four-byte rune (an emoji a model may well send)
	md2: Markdown_Doc
	defer md_destroy(&md2)
	md_set(&md2, "")
	for b in transmute([]u8)string("ok 🎉") {
		md_append(&md2, string([]u8{b}))
		testing.expect(t, utf8.valid_string(md_text(&md2)), "still valid")
	}
	testing.expect_value(t, md_text(&md2), "ok 🎉")
}

@(test)
an_open_fence_and_a_half_table_read_sensibly :: proc(t: ^testing.T) {
	md: Markdown_Doc
	defer md_destroy(&md)

	// a fence that has opened but not closed: its lines are code as they come
	md_set(&md, "before\n```odin\nx := 1\n")
	last := md.blocks[len(md.blocks) - 1]
	testing.expect_value(t, last.meta.kind, Block_Kind.Code)
	testing.expect_value(t, last.meta.lang, "odin")
	md_append(&md, "y := 2\n```\nafter\n")
	tail := md.blocks[len(md.blocks) - 1]
	testing.expect_value(t, tail.meta.kind, Block_Kind.Paragraph) // the fence closed
	testing.expect_value(t, md_block_text(&md, len(md.blocks) - 1), "after")

	// the fence marker arriving in pieces must not be read as a closing one
	md2: Markdown_Doc
	defer md_destroy(&md2)
	md_set(&md2, "x\n")
	fence := "```odin"
	for i in 0 ..< len(fence) do md_append(&md2, fence[i:i + 1])
	md_append(&md2, "\ncode line\n")
	code := md2.blocks[len(md2.blocks) - 1]
	testing.expect_value(t, code.meta.kind, Block_Kind.Code)

	// a table's header only becomes one when its separator row is whole
	md3: Markdown_Doc
	defer md_destroy(&md3)
	md_set(&md3, "| a | b |\n")
	head := len(md3.blocks) - 1
	testing.expect_value(t, md3.blocks[head].meta.kind, Block_Kind.Table)
	testing.expect_value(t, md3.blocks[head].meta.level, u8(0)) // not yet a header
	md_append(&md3, "|---|")
	testing.expect_value(t, md3.blocks[head].meta.level, u8(0)) // still not: the line is unfinished
	md_append(&md3, "---|\n")
	testing.expect_value(t, md3.blocks[head].meta.level, u8(1)) // now
}

@(test)
the_source_is_kept_exactly :: proc(t: ^testing.T) {
	// "copy as markdown" is a slice of what the app sent, and a range that
	// lands inside a rune widens rather than splitting it
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, "a — b")            // seven bytes: the em dash is three of them
	testing.expect_value(t, md_markdown(&md, 0, 5), "a —")      // up to the byte after the dash
	testing.expect_value(t, md_markdown(&md, 3, 3), "—")        // inside it: widened to the rune
	testing.expect_value(t, md_markdown(&md, 4, 6), "— ")       // straddling it: widened at the front
	testing.expect_value(t, md_markdown(&md, -5, 999), "a — b") // clamped to the text
	testing.expect_value(t, md_markdown(&md, 5, 0), md_markdown(&md, 0, 5)) // either way round

	// clearing really clears, and a document is reusable after it
	md_clear(&md)
	testing.expect_value(t, md_text(&md), "")
	testing.expect_value(t, len(md.blocks), 0)
	md_set(&md, "# again\n")
	testing.expect_value(t, md.blocks[0].meta.kind, Block_Kind.Heading)
	testing.expect_value(t, md_block_text(&md, 0), "again")
}

// GFM autolinks: a bare address is a link, with a hover and on_link, not
// dead text.
@(test)
markdown_reads_bare_addresses_as_links :: proc(t: ^testing.T) {
	href_of :: proc(l: Live_Line, at: int) -> string {
		for r, i in l.runs {
			start := 0 if i == 0 else l.runs[i - 1].end
			if at >= start && at < r.end do return r.href
		}
		return ""
	}
	// a bare address, with the sentence's full stop left out of it
	l := markdown_render_line("see https://odin-lang.org/docs. yes", false, false)
	testing.expect_value(t, l.text, "see https://odin-lang.org/docs. yes")
	testing.expect_value(t, href_of(l, 6), "https://odin-lang.org/docs")
	testing.expect_value(t, href_of(l, 31), "") // the stop and what follows are text

	// www., which needs a scheme to be opened
	w := markdown_render_line("at www.example.com today", false, false)
	testing.expect_value(t, href_of(w, 4), "https://www.example.com")

	// an angle autolink: the brackets are markup and are dropped
	a := markdown_render_line("see <https://odin-lang.org> now", false, false)
	testing.expect_value(t, a.text, "see https://odin-lang.org now")
	testing.expect_value(t, href_of(a, 5), "https://odin-lang.org")

	// an email address is written to, not browsed to
	m := markdown_render_line("write to someone@example.com, please", false, false)
	testing.expect_value(t, m.text, "write to someone@example.com, please")
	testing.expect_value(t, href_of(m, 10), "mailto:someone@example.com")

	// not inside code, and not inside a link that already has a target
	c := markdown_render_line("`https://x.dev` is code", false, false)
	testing.expect_value(t, href_of(c, 1), "")
	k := markdown_render_line("[see https://x.dev](https://y.dev)", false, false)
	testing.expect_value(t, href_of(k, 5), "https://y.dev")

	// a word it grew out of is not an address
	n := markdown_render_line("nothttps://x.dev", false, false)
	testing.expect_value(t, href_of(n, 5), "")
}

@(test)
markdown_reads_a_footnote_as_its_number :: proc(t: ^testing.T) {
	// The markup does not leak: the caret is markup, so "[^1]" reads "[1]",
	// the conventional marker, and the note itself reads the same way.
	ref := markdown_render_line("a claim[^1] and more", false, false)
	testing.expect_value(t, ref.text, "a claim[1] and more")
	note := markdown_render_line("[^1]: the note itself", false, false)
	testing.expect_value(t, note.text, "[1]: the note itself")
	// the source map still points at the source it came from
	at := strings.index(ref.text, "[1]")
	testing.expect_value(t, ref.src[at], strings.index("a claim[^1] and more", "[^1]"))
	// a link label is not a footnote
	link := markdown_render_line("[^ up](https://x.dev)", false, false)
	testing.expect_value(t, link.text, "^ up")
}

@(test)
markdown_writes_a_bare_address_back_as_itself :: proc(t: ^testing.T) {
	// A document that said "see https://odin-lang.org" must read the same
	// after a round trip, not grow "[…](…)" around what the person typed.
	doc := document_make()
	defer document_destroy(&doc)
	src := "see https://odin-lang.org and write to someone@example.com\n"
	document_set_markdown(&doc, src)
	out := document_markdown(&doc, context.temp_allocator)
	testing.expect_value(t, strings.trim_right(out, "\n"), strings.trim_right(src, "\n"))
}

} // when ODIN_TEST