package baldr

// Markdown in and out of the Document, and a tokenizer for markdown source
// in the code editor. The dialect is CommonMark's everyday subset: ATX
// headings, bullet (- / *) and numbered (1.) lists nested by indentation,
// task items (- [ ] / - [x]), block quotes (>), fenced code blocks (```
// with a language), thematic breaks (---), and inline **bold**, *italic*,
// ~~strike~~, `code` and [links](url). Everything else stays text.

import "base:runtime"
import "core:strings"

// document_markdown prints the document as markdown. The string is the
// caller's to free (allocated with `allocator`, the context's by default).
document_markdown :: proc(doc: ^Document, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	in_code := false
	for &b, i in doc.blocks {
		if in_code && b.kind != .Code {
			strings.write_string(&sb, "```\n")
			in_code = false
		}
		switch b.kind {
		case .Paragraph:
			markdown_inline(&sb, &b)
		case .Heading:
			for _ in 0 ..< clamp(int(b.level), 1, 6) do strings.write_byte(&sb, '#')
			strings.write_byte(&sb, ' ')
			markdown_inline(&sb, &b)
		case .Bullet, .Numbered, .Task:
			for _ in 0 ..< int(b.depth) do strings.write_string(&sb, "  ")
			switch b.kind {
			case .Bullet:   strings.write_string(&sb, "- ")
			case .Numbered:
				strings.write_int(&sb, numbered_index(doc, i))
				strings.write_string(&sb, ". ")
			case .Task:     strings.write_string(&sb, "- [x] " if b.checked else "- [ ] ")
			case .Paragraph, .Heading, .Quote, .Code, .Rule, .Image, .Table, .Table_Sep:
			}
			markdown_inline(&sb, &b)
		case .Quote:
			strings.write_string(&sb, "> ")
			markdown_inline(&sb, &b)
		case .Code:
			if !in_code {
				strings.write_string(&sb, "```")
				strings.write_string(&sb, b.lang)
				strings.write_byte(&sb, '\n')
				in_code = true
			}
			strings.write_string(&sb, string(b.text[:]))
		case .Rule:
			strings.write_string(&sb, "---")
		case .Image:
			strings.write_string(&sb, "![")
			markdown_escape(&sb, string(b.text[:]), false)
			strings.write_string(&sb, "](")
			strings.write_string(&sb, b.src)
			strings.write_byte(&sb, ')')
		case .Table:
			markdown_inline(&sb, &b)
			if b.level == 1 { // a header row: the separator line follows
				strings.write_byte(&sb, '\n')
				for _, ci in table_cells(string(b.text[:])) {
					switch table_align_get(b.align, ci) {
					case .Left:    strings.write_string(&sb, "|:---")
					case .Right:   strings.write_string(&sb, "|---:")
					case .Center:  strings.write_string(&sb, "|:--:")
					case .Default: strings.write_string(&sb, "|---")
					}
				}
				strings.write_byte(&sb, '|')
			}
		case .Table_Sep:
			strings.write_string(&sb, string(b.text[:]))
		}
		strings.write_byte(&sb, '\n')
		// a blank line between groups: list items, quote lines and code lines stay together
		if i + 1 < len(doc.blocks) && !markdown_same_group(b.kind, doc.blocks[i + 1].kind) {
			if b.kind == .Code do strings.write_string(&sb, "```\n")
			in_code = false
			strings.write_byte(&sb, '\n')
		}
	}
	if in_code do strings.write_string(&sb, "```\n")
	return strings.to_string(sb)
}

@(private)
markdown_same_group :: proc(a, b: Block_Kind) -> bool {
	listy :: proc(k: Block_Kind) -> bool { return k == .Bullet || k == .Numbered || k == .Task }
	if listy(a) && listy(b) do return true
	return a == b && (a == .Code || a == .Quote || a == .Table)
}

// markdown_inline writes a block's text with its runs as markdown marks.
// Plain text is escaped where it would read as a mark or a block prefix,
// and a styled run's leading / trailing spaces go outside its marks (a
// mark next to a space is not a mark).
@(private)
markdown_inline :: proc(sb: ^strings.Builder, b: ^Block) {
	text := string(b.text[:])
	if len(b.runs) == 0 {
		markdown_escape(sb, text, true)
		return
	}
	start := 0
	for r, ri in b.runs {
		seg := text[start:min(r.end, len(text))]
		start = r.end
		if len(seg) == 0 do continue
		if r.attrs == {} {
			markdown_escape(sb, seg, ri == 0)
			continue
		}
		lead := 0
		for lead < len(seg) && seg[lead] == ' ' do lead += 1
		trail := len(seg)
		for trail > lead && seg[trail - 1] == ' ' do trail -= 1
		strings.write_string(sb, seg[:lead])
		body := seg[lead:trail]
		open, close := "", ""
		if .Code in r.attrs {
			open, close = "`", "`"
		} else {
			if .Bold in r.attrs { open = strings.concatenate({open, "**"}, context.temp_allocator); close = strings.concatenate({"**", close}, context.temp_allocator) }
			if .Italic in r.attrs { open = strings.concatenate({open, "*"}, context.temp_allocator); close = strings.concatenate({"*", close}, context.temp_allocator) }
			if .Strike in r.attrs { open = strings.concatenate({open, "~~"}, context.temp_allocator); close = strings.concatenate({"~~", close}, context.temp_allocator) }
			if .Highlight in r.attrs { open = strings.concatenate({open, "=="}, context.temp_allocator); close = strings.concatenate({"==", close}, context.temp_allocator) }
			if .Underline in r.attrs { open = strings.concatenate({open, "<u>"}, context.temp_allocator); close = strings.concatenate({"</u>", close}, context.temp_allocator) }
		}
		// An address that links to itself is written back as itself: a reply
		// or a document that said "see https://odin-lang.org" reads the same
		// after a round trip, rather than growing "[…](…)" around it.
		if .Link in r.attrs && r.attrs - {.Link} == {} && md_links_to_itself(body, r.href) {
			strings.write_string(sb, body)
			strings.write_string(sb, seg[trail:])
			continue
		}
		if .Link in r.attrs {
			strings.write_byte(sb, '[')
			strings.write_string(sb, open)
			if .Code in r.attrs { strings.write_string(sb, body) } else { markdown_escape(sb, body, false) }
			strings.write_string(sb, close)
			strings.write_string(sb, "](")
			strings.write_string(sb, r.href)
			strings.write_byte(sb, ')')
		} else {
			strings.write_string(sb, open)
			if .Code in r.attrs { strings.write_string(sb, body) } else { markdown_escape(sb, body, false) }
			strings.write_string(sb, close)
		}
		strings.write_string(sb, seg[trail:])
	}
}

// md_links_to_itself: the text *is* the address the run points at, so the
// markdown for it is the text (GFM reads it back as the same link).
@(private)
md_links_to_itself :: proc(text, href: string) -> bool {
	if text == href do return md_autolink_len(text, 0) == len(text)
	if strings.has_prefix(href, "https://") && href[8:] == text do return md_autolink_len(text, 0) == len(text)
	if strings.has_prefix(href, "mailto:") && href[7:] == text {
		_, n := md_email_at(text, strings.index_byte(text, '@'), 0)
		return n == len(text)
	}
	return false
}

// markdown_escape writes plain text so the parser reads it back as text:
// a backslash before the mark characters, and before a block prefix at
// the start of a line.
@(private)
markdown_escape :: proc(sb: ^strings.Builder, s: string, at_line_start: bool) {
	s := s
	if at_line_start {
		t := strings.trim_left(s, " ")
		n := markdown_numbered(t)
		if strings.has_prefix(t, "#") || strings.has_prefix(t, "- ") || strings.has_prefix(t, "* ") || strings.has_prefix(t, "+ ") ||
			strings.has_prefix(t, "> ") || t == ">" || strings.has_prefix(t, "```") || t == "---" || t == "***" || t == "___" {
			strings.write_string(sb, s[:len(s) - len(t)])
			strings.write_byte(sb, '\\')
			s = t
		} else if n > 0 { // "12. " → "12\. "
			strings.write_string(sb, s[:len(s) - len(t)])
			strings.write_string(sb, t[:n - 2])
			strings.write_string(sb, "\\.")
			s = t[n - 1:]
		}
	}
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		switch {
		case c == '\\' || c == '*' || c == '_' || c == '`' || c == '[' || c == ']':
			strings.write_byte(sb, '\\')
		case c == '~' && i + 1 < len(s) && s[i + 1] == '~':
			strings.write_byte(sb, '\\')
		case c == '<' && (strings.has_prefix(s[i:], "<u>") || strings.has_prefix(s[i:], "</u>")):
			strings.write_byte(sb, '\\')
		}
		strings.write_byte(sb, c)
	}
}

// document_set_markdown replaces the document with the blocks `md`
// describes (no undo entry).
document_set_markdown :: proc(doc: ^Document, md: string) {
	document_ensure(doc)
	for &b in doc.blocks do block_free(doc, &b)
	clear(&doc.blocks)
	edits_clear(doc, &doc.undo)
	edits_clear(doc, &doc.redo)
	in_code := false
	code_lang := ""
	rest := md
	for len(rest) > 0 || in_code {
		i := strings.index_byte(rest, '\n')
		line := rest if i < 0 else rest[:i]
		done := i < 0
		rest = rest[i + 1:] if !done else ""
		if len(line) > 0 && line[len(line) - 1] == '\r' do line = line[:len(line) - 1]
		if in_code {
			if strings.has_prefix(strings.trim_left_space(line), "```") {
				in_code = false
			} else {
				b := Block{text = make([dynamic]u8, doc.allocator), kind = .Code}
				append(&b.text, ..transmute([]u8)line)
				if len(code_lang) > 0 do b.lang = strings.clone(code_lang, doc.allocator)
				append(&doc.blocks, b)
			}
			if done do break
			continue
		}
		ml := markdown_line(line)
		switch {
		case ml.fence:
			in_code = true
			code_lang = ml.lang
		case ml.rule:
			append(&doc.blocks, Block{text = make([dynamic]u8, doc.allocator), kind = .Rule})
		case ml.meta.kind == .Image:
			markdown_block(doc, ml.alt, ml.meta)
		case ml.meta.kind == .Table_Sep:
			// The line under a header row keeps no block, but its column
			// alignment is kept on the header, so document_markdown writes it
			// back.
			if n := len(doc.blocks); n > 0 && doc.blocks[n - 1].kind == .Table {
				doc.blocks[n - 1].level = 1
				doc.blocks[n - 1].align = table_align_pack(table_sep_align(line))
			}
		case ml.meta.kind == .Table:
			markdown_block(doc, line, ml.meta)
		case len(strings.trim_space(line)) == 0:
			// a blank line between paragraphs is not a block of its own — unless the document is one
			if len(doc.blocks) == 0 || done do markdown_block(doc, "", {kind = .Paragraph})
		case:
			markdown_block(doc, line[ml.body:], ml.meta)
		}
		if done do break
	}
	if len(doc.blocks) == 0 do append(&doc.blocks, Block{text = make([dynamic]u8, doc.allocator)})
	doc.version += 1
}

// markdown_numbered returns the length of a "12. " prefix, 0 when none.
@(private)
markdown_numbered :: proc(s: string) -> int {
	i := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' do i += 1
	if i == 0 || i + 1 >= len(s) || s[i] != '.' || s[i + 1] != ' ' do return 0
	return i + 2
}

// Markdown_Line is what one source line means: its block meta, where the
// body starts (after "# ", "- ", "> " …), and whether it is a fence or a rule.
Markdown_Line :: struct {
	meta:  Block_Meta,
	body:  int,  // byte where the inline text starts
	fence: bool, // a ``` line (opens or closes a code block)
	rule:  bool,
	lang:  string, // a fence's language, borrowed from the line
	alt:   string, // an image's alt text, borrowed from the line
}

// markdown_line reads a line's block prefix (outside a fence).
markdown_line :: proc(line: string) -> (out: Markdown_Line) {
	trimmed := strings.trim_left(line, " ")
	indent := len(line) - len(trimmed)
	out.meta.kind = .Paragraph
	if strings.has_prefix(trimmed, "![") { // an image on a line of its own: ![alt](src) and nothing after it
		close := strings.index(trimmed, "](")
		if close > 1 {
			end := strings.index_byte(trimmed[close + 2:], ')')
			if end >= 0 && len(strings.trim_right_space(trimmed[close + 2 + end + 1:])) == 0 {
				out.meta = {kind = .Image, src = trimmed[close + 2:close + 2 + end]}
				out.alt = trimmed[2:close]
				out.body = len(line)
				return
			}
		}
	}
	switch {
	case table_sep_line(trimmed):
		out.meta.kind = .Table_Sep
		out.body = len(line)
	case strings.has_prefix(trimmed, "|"):
		out.meta.kind = .Table
		out.body = indent
	case strings.has_prefix(trimmed, "```"):
		out.fence = true
		out.lang = strings.trim_space(trimmed[3:])
		out.body = len(line)
	case trimmed == "---" || trimmed == "***" || trimmed == "___":
		out.rule = true
		out.meta.kind = .Rule
		out.body = len(line)
	case strings.has_prefix(trimmed, "#"):
		level := 0
		for level < len(trimmed) && trimmed[level] == '#' do level += 1
		if level <= 6 && level < len(trimmed) && trimmed[level] == ' ' {
			out.meta = {kind = .Heading, level = u8(level)}
			out.body = indent + level + 1
		}
	case strings.has_prefix(trimmed, "> "):
		out.meta.kind = .Quote
		out.body = indent + 2
	case trimmed == ">":
		out.meta.kind = .Quote
		out.body = len(line)
	case strings.has_prefix(trimmed, "- [ ] ") || strings.has_prefix(trimmed, "- [x] ") || strings.has_prefix(trimmed, "- [X] "):
		out.meta = {kind = .Task, depth = u8(indent / 2), checked = trimmed[3] != ' '}
		out.body = indent + 6
	case strings.has_prefix(trimmed, "- ") || strings.has_prefix(trimmed, "* ") || strings.has_prefix(trimmed, "+ "):
		out.meta = {kind = .Bullet, depth = u8(indent / 2)}
		out.body = indent + 2
	case markdown_numbered(trimmed) > 0:
		out.meta = {kind = .Numbered, depth = u8(indent / 2)}
		out.body = indent + markdown_numbered(trimmed)
	}
	return
}

// markdown_block appends a block, parsing the inline marks of `src`.
@(private)
markdown_block :: proc(doc: ^Document, src: string, meta: Block_Meta) {
	b := Block{text = make([dynamic]u8, doc.allocator), kind = meta.kind, level = meta.level, depth = meta.depth, checked = meta.checked}
	if len(meta.lang) > 0 do b.lang = strings.clone(meta.lang, doc.allocator)
	if len(meta.src) > 0 do b.src = strings.clone(meta.src, doc.allocator)
	b.runs = make([dynamic]Run, doc.allocator)
	run_start := 0
	ctx := Md_Doc_Ctx{doc = doc, b = &b, run_start = &run_start}
	markdown_scan(src, {}, "", &ctx, md_doc_emit)
	if len(b.text) > run_start do append(&b.runs, Run{end = len(b.text), attrs = ctx.cur_attrs, href = strings.clone(ctx.cur_href, doc.allocator) if len(ctx.cur_href) > 0 else ""})
	runs_normalize(doc, &b)
	append(&doc.blocks, b)
}

@(private)
Md_Doc_Ctx :: struct {
	doc:       ^Document,
	b:         ^Block,
	run_start: ^int,
	cur_attrs: Attrs,
	cur_href:  string,
	cur_valid: bool,
}

// md_doc_emit: the document parser drops the marks and cuts runs at style changes.
@(private)
md_doc_emit :: proc(ctx: rawptr, piece: string, attrs: Attrs, href: string, is_mark: bool) {
	c := (^Md_Doc_Ctx)(ctx)
	if is_mark do return
	if c.cur_valid && (c.cur_attrs != attrs || c.cur_href != href) && len(c.b.text) > c.run_start^ {
		append(&c.b.runs, Run{end = len(c.b.text), attrs = c.cur_attrs, href = strings.clone(c.cur_href, c.doc.allocator) if len(c.cur_href) > 0 else ""})
		c.run_start^ = len(c.b.text)
	}
	c.cur_attrs, c.cur_href, c.cur_valid = attrs, href, true
	append(&c.b.text, ..transmute([]u8)piece)
}

// md_word_byte: a byte that can sit inside a word, so an address that
// follows one ("ahttps://x") is not an address at all.
@(private)
md_word_byte :: proc(b: u8) -> bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '_'
}

// md_mail_byte: a byte an email address is made of, either side of the @.
@(private)
md_mail_byte :: proc(b: u8) -> bool {
	return md_word_byte(b) || b == '.' || b == '-' || b == '+' || b == '%'
}

// md_has_scheme says whether `s` already names how to reach it.
@(private)
md_has_scheme :: proc(s: string) -> bool {
	return strings.has_prefix(s, "https://") || strings.has_prefix(s, "http://") || strings.has_prefix(s, "mailto:")
}

// md_autolink_len is how many bytes of a bare address start at `i` — GFM's
// extended autolinks: "https://…", "http://…" and "www.…". 0 when there is
// none. The address must start at a word boundary, must have a dot in its
// host, and gives back the punctuation that ends the sentence rather than
// the address: "see https://odin-lang.org/docs." links without the stop.
@(private)
md_autolink_len :: proc(src: string, i: int) -> int {
	if i > 0 && (md_word_byte(src[i - 1]) || src[i - 1] == '/' || src[i - 1] == '@') do return 0
	rest := src[i:]
	scheme := 0
	switch {
	case strings.has_prefix(rest, "https://"): scheme = 8
	case strings.has_prefix(rest, "http://"):  scheme = 7
	case strings.has_prefix(rest, "www."):     scheme = 4
	case: return 0
	}
	j := scheme
	for j < len(rest) && rest[j] > ' ' && rest[j] != '<' && rest[j] != '>' && rest[j] != '"' do j += 1
	for j > scheme && strings.contains_rune(".,;:!?'", rune(rest[j - 1])) do j -= 1
	for j > scheme && rest[j - 1] == ')' && strings.count(rest[:j], "(") < strings.count(rest[:j], ")") do j -= 1
	if j <= scheme || !strings.contains(rest[scheme:j], ".") do return 0
	return j
}

// md_email_at reads the address around the '@' at `at`, no further back
// than `floor` (the text not yet emitted). `n` is 0 when it is not one.
@(private)
md_email_at :: proc(src: string, at, floor: int) -> (lo, n: int) {
	lo = at
	for lo > floor && md_mail_byte(src[lo - 1]) do lo -= 1
	if lo == at || !md_word_byte(src[lo]) do return at, 0
	j := at + 1
	for j < len(src) && md_mail_byte(src[j]) do j += 1
	for j > at + 1 && strings.contains_rune(".,;:!?'", rune(src[j - 1])) do j -= 1
	host := src[at + 1:j]
	if len(host) < 3 || !strings.contains(host, ".") || strings.has_suffix(host, ".") do return at, 0
	return lo, j - lo
}

// md_footnote_len is the length of a footnote's marker at `i` — "[^1]",
// "[^note]" — or 0. Anything else beginning "[^" is a link label and is
// left to the link case, markup and all.
@(private)
md_footnote_len :: proc(src: string, i: int) -> int {
	if i + 4 > len(src) || src[i] != '[' || src[i + 1] != '^' do return 0
	close := strings.index_byte(src[i:], ']')
	if close < 3 || strings.index_byte(src[i:i + close], ' ') >= 0 do return 0
	return close + 1
}

// md_angle_link reads what a "<…>" holds: an address, or nothing.
@(private)
md_angle_link :: proc(inner: string) -> (url: string, ok: bool) {
	if len(inner) == 0 || strings.contains_any(inner, " \t") do return "", false
	if md_has_scheme(inner) do return inner, true
	if at := strings.index_byte(inner, '@'); at > 0 {
		if _, n := md_email_at(inner, at, 0); n == len(inner) {
			return strings.concatenate({"mailto:", inner}, context.temp_allocator), true
		}
	}
	return "", false
}

// Markdown_Emit receives the pieces of a line in order: text with its
// style, or a mark (`**`, a link's "](url)" …) with `is_mark`.
Markdown_Emit :: #type proc(ctx: rawptr, piece: string, attrs: Attrs, href: string, is_mark: bool)

// markdown_scan walks the inline marks of `src` (one line, its block
// prefix already removed) and reports every piece. An emphasis mark
// opens when the next character is not a space and closes when the
// previous one is not (so snake_case and 2 * 3 stay text); a link's label
// is scanned with the link on.
markdown_scan :: proc(src: string, base: Attrs, base_href: string, ctx: rawptr, emit: Markdown_Emit) {
	attrs := base
	href := base_href
	opens :: proc(src: string, i, n: int) -> bool { return i + n < len(src) && src[i + n] != ' ' }
	closes :: proc(src: string, i: int) -> bool { return i > 0 && src[i - 1] != ' ' }
	i := 0
	text_start := 0
	flush :: proc(src: string, text_start: ^int, upto: int, attrs: Attrs, href: string, ctx: rawptr, emit: Markdown_Emit) {
		if upto > text_start^ do emit(ctx, src[text_start^:upto], attrs, href, false)
		text_start^ = upto
	}
	for i < len(src) {
		c := src[i]
		switch {
		case c == '\\' && i + 1 < len(src): // an escaped mark: the backslash is a mark, the character text
			flush(src, &text_start, i, attrs, href, ctx, emit)
			emit(ctx, src[i:i + 1], attrs, href, true)
			emit(ctx, src[i + 1:i + 2], attrs, href, false)
			i += 2
			text_start = i
		case c == '`':
			j := strings.index_byte(src[i + 1:], '`')
			if j < 0 {
				i += 1
				continue
			}
			flush(src, &text_start, i, attrs, href, ctx, emit)
			emit(ctx, src[i:i + 1], attrs + {.Code}, href, true)
			emit(ctx, src[i + 1:i + 1 + j], attrs + {.Code}, href, false)
			emit(ctx, src[i + 1 + j:i + 2 + j], attrs + {.Code}, href, true)
			i += j + 2
			text_start = i
		case strings.has_prefix(src[i:], "**") && ((.Bold not_in attrs && opens(src, i, 2)) || (.Bold in attrs && closes(src, i))):
			flush(src, &text_start, i, attrs, href, ctx, emit)
			if .Bold in attrs { attrs -= {.Bold} } else { attrs += {.Bold} }
			emit(ctx, src[i:i + 2], attrs, href, true)
			i += 2
			text_start = i
		case strings.has_prefix(src[i:], "~~") && ((.Strike not_in attrs && opens(src, i, 2)) || (.Strike in attrs && closes(src, i))):
			flush(src, &text_start, i, attrs, href, ctx, emit)
			if .Strike in attrs { attrs -= {.Strike} } else { attrs += {.Strike} }
			emit(ctx, src[i:i + 2], attrs, href, true)
			i += 2
			text_start = i
		case strings.has_prefix(src[i:], "==") && ((.Highlight not_in attrs && opens(src, i, 2)) || (.Highlight in attrs && closes(src, i))):
			flush(src, &text_start, i, attrs, href, ctx, emit)
			if .Highlight in attrs { attrs -= {.Highlight} } else { attrs += {.Highlight} }
			emit(ctx, src[i:i + 2], attrs, href, true)
			i += 2
			text_start = i
		case strings.has_prefix(src[i:], "<u>"):
			flush(src, &text_start, i, attrs, href, ctx, emit)
			attrs += {.Underline}
			emit(ctx, src[i:i + 3], attrs, href, true)
			i += 3
			text_start = i
		case strings.has_prefix(src[i:], "</u>"):
			flush(src, &text_start, i, attrs, href, ctx, emit)
			attrs -= {.Underline}
			emit(ctx, src[i:i + 4], attrs, href, true)
			i += 4
			text_start = i
		case c == '<': // <https://odin-lang.org> — the brackets are markup
			if end := strings.index_byte(src[i:], '>'); end > 1 {
				if url, is := md_angle_link(src[i + 1:i + end]); is {
					flush(src, &text_start, i, attrs, href, ctx, emit)
					emit(ctx, src[i:i + 1], attrs + {.Link}, url, true)
					emit(ctx, src[i + 1:i + end], attrs + {.Link}, url, false)
					emit(ctx, src[i + end:i + end + 1], attrs + {.Link}, url, true)
					i += end + 1
					text_start = i
					continue
				}
			}
			i += 1
		case (c == '*' || c == '_') && ((.Italic not_in attrs && opens(src, i, 1) && (c == '*' || !closes(src, i))) || (.Italic in attrs && closes(src, i) && (c == '*' || !opens(src, i, 1)))):
			flush(src, &text_start, i, attrs, href, ctx, emit)
			if .Italic in attrs { attrs -= {.Italic} } else { attrs += {.Italic} }
			emit(ctx, src[i:i + 1], attrs, href, true)
			i += 1
			text_start = i
		case md_footnote_len(src, i) > 0: // a footnote: "[^1]" reads "[1]"
			n := md_footnote_len(src, i)
			flush(src, &text_start, i, attrs, href, ctx, emit)
			emit(ctx, src[i:i + 1], attrs, href, false)              // "["
			emit(ctx, src[i + 1:i + 2], attrs, href, true)           // the caret is the markup
			emit(ctx, src[i + 2:i + n - 1], attrs, href, false)      // its name
			emit(ctx, src[i + n - 1:i + n], attrs, href, false)      // "]"
			i += n
			text_start = i
		case c == '[':
			close := strings.index_byte(src[i:], ']')
			if close > 0 && close + 1 < len(src[i:]) && src[i + close + 1] == '(' {
				end := strings.index_byte(src[i + close + 1:], ')')
				if end > 0 {
					url := src[i + close + 2:i + close + 1 + end]
					label := src[i + 1:i + close]
					flush(src, &text_start, i, attrs, href, ctx, emit)
					emit(ctx, src[i:i + 1], attrs + {.Link}, url, true)
					markdown_scan(label, attrs + {.Link}, url, ctx, emit) // the label's own marks
					emit(ctx, src[i + close:i + close + 2 + end], attrs + {.Link}, url, true) // "](url)"
					i += close + 2 + end
					text_start = i
					continue
				}
			}
			i += 1
		case .Link not_in attrs && md_autolink_len(src, i) > 0: // a bare address, GFM's tier
			n := md_autolink_len(src, i)
			flush(src, &text_start, i, attrs, href, ctx, emit)
			addr := src[i:i + n]
			url := addr if md_has_scheme(addr) else strings.concatenate({"https://", addr}, context.temp_allocator)
			emit(ctx, addr, attrs + {.Link}, url, false)
			i += n
			text_start = i
		case .Link not_in attrs && c == '@': // an address to write to
			lo, n := md_email_at(src, i, text_start)
			if n > 0 {
				flush(src, &text_start, lo, attrs, href, ctx, emit)
				addr := src[lo:lo + n]
				emit(ctx, addr, attrs + {.Link}, strings.concatenate({"mailto:", addr}, context.temp_allocator), false)
				i = lo + n
				text_start = i
				continue
			}
			i += 1
		case:
			i += 1
		}
	}
	flush(src, &text_start, len(src), attrs, href, ctx, emit)
}

// Live_Line is one source line as the live-preview editor shows it: the
// text on screen, its style runs, and for every display byte the source
// byte it came from (`src[len(text)]` is the source length).
Live_Line :: struct {
	meta: Block_Meta,
	text: string,
	runs: []Run,
	src:  []int, // display byte → source byte; src[len(text)] is the source length
	in_fence: bool, // the line sits inside a code block
	fence:    bool, // the line is a fence: the opening one, or (in_fence) the closing one
}

// markdown_render_line lays a source line out for display: block prefix
// and marks dropped (`keep_marks = false`, the block not being edited) or
// kept and styled as marks (`keep_marks = true`, the caret's block). Lines
// inside a fence are code. Everything is allocated with `allocator`.
markdown_render_line :: proc(line: string, in_fence: bool, keep_marks: bool, allocator := context.temp_allocator) -> (out: Live_Line) {
	ctx := Md_Live_Ctx{keep = keep_marks, allocator = allocator}
	ctx.text = make([dynamic]u8, 0, len(line) + 1, allocator)
	ctx.src = make([dynamic]int, 0, len(line) + 2, allocator)
	ctx.runs = make([dynamic]Run, allocator)
	if in_fence {
		ml := markdown_line(line)
		if ml.fence { // the closing fence: shown dimmed either way
			ctx.keep = true
			md_live_piece(&ctx, line, 0, {.Mark}, "", true)
			out.meta.kind = .Code
			out.fence = true
		} else {
			md_live_piece(&ctx, line, 0, {}, "", false)
			out.meta.kind = .Code
		}
		out.in_fence = true
	} else {
		ml := markdown_line(line)
		out.meta = ml.meta
		if ml.fence { // the opening fence: shown dimmed either way
			ctx.keep = true
			md_live_piece(&ctx, line, 0, {.Mark}, "", true)
			out.meta.kind = .Code
			out.fence = true
		} else if ml.rule {
			md_live_piece(&ctx, line, 0, {.Mark}, "", true)
		} else if ml.meta.kind == .Table_Sep {
			ctx.keep = true
			md_live_piece(&ctx, line, 0, {.Mark}, "", true)
		} else if ml.meta.kind == .Table { // the pipes stay (as marks) so the cells can be found; each cell's marks are scanned
			ctx.keep_pipes = true
			at := 0
			for c := 0; c < len(line); {
				if line[c] == '|' {
					ctx.keep = true
					md_live_piece(&ctx, line[c:c + 1], c, {.Mark}, "", true)
					ctx.keep = keep_marks
					c += 1
					at = c
					continue
				}
				end := strings.index_byte(line[c:], '|')
				cell := line[c:] if end < 0 else line[c:c + end]
				// `<br>` is the only line break GFM gives a cell, and the one
				// piece of HTML honoured here, only inside a cell: it becomes a
				// newline in the display text, which layout and a copy carry.
				for p := 0; p < len(cell); {
					br := md_br_at(cell, p)
					if br == 0 {
						p += 1
						continue
					}
					if p > 0 {
						ctx.src_off = c
						ctx.scan_base = raw_data(cell)
						markdown_scan(cell[:p], {}, "", &ctx, md_live_emit)
					}
					md_live_piece(&ctx, "\n", c + p, {}, "", false)
					cell = cell[p + br:]
					c += p + br
					p = 0
				}
				ctx.src_off = c
				ctx.scan_base = raw_data(cell)
				markdown_scan(cell, {}, "", &ctx, md_live_emit)
				c += len(cell)
				_ = at
			}
		} else if ml.meta.kind == .Image { // rendered: the alt text as a caption; raw: the source
			if keep_marks {
				md_live_piece(&ctx, line, 0, {.Mark}, "", true)
			} else {
				alt_at := strings.index(line, "![") + 2 // the alt starts right after "!["
				md_live_piece(&ctx, ml.alt, alt_at, {}, "", false)
			}
		} else {
			if ml.body > 0 do md_live_piece(&ctx, line[:ml.body], 0, {.Mark}, "", true) // the block prefix
			ctx.src_off = ml.body
			ctx.scan_base = raw_data(line[ml.body:])
			markdown_scan(line[ml.body:], {}, "", &ctx, md_live_emit)
		}
	}
	md_live_close(&ctx)
	append(&ctx.src, len(line))
	out.text = string(ctx.text[:])
	out.runs = ctx.runs[:]
	out.src = ctx.src[:]
	return
}

@(private)
Md_Live_Ctx :: struct {
	keep:      bool,
	allocator: runtime.Allocator,
	text:      [dynamic]u8,
	src:       [dynamic]int,
	runs:      [dynamic]Run,
	src_off:   int, // where the scanned text sits in the line
	scan_base: [^]u8, // the scanned text's first byte, to recover a slice's offset
	keep_pipes: bool,
	run_start: int,
	cur_attrs: Attrs,
	cur_href:  string,
	cur_valid: bool,
}

@(private)
md_live_emit :: proc(ctx: rawptr, piece: string, attrs: Attrs, href: string, is_mark: bool) {
	c := (^Md_Live_Ctx)(ctx)
	// the piece's source offset: the scanner hands slices of the line, so pointer arithmetic gives it
	base := raw_data(piece)
	_ = base
	md_live_piece(c, piece, -1, attrs, href, is_mark)
}

// md_br_at is how many bytes of `<br>` start at `p` — `<br>`, `<br/>` or
// `<br />`, in any case — and 0 for anything else. Only a table cell asks:
// everywhere else in markdown a line break is a line, and HTML is text.
@(private)
md_br_at :: proc(s: string, p: int) -> int {
	if p + 4 > len(s) || s[p] != '<' do return 0
	if s[p + 1] != 'b' && s[p + 1] != 'B' do return 0
	if s[p + 2] != 'r' && s[p + 2] != 'R' do return 0
	q := p + 3
	for q < len(s) && s[q] == ' ' do q += 1
	if q < len(s) && s[q] == '/' do q += 1
	if q < len(s) && s[q] == '>' do return q + 1 - p
	return 0
}

// md_live_piece appends a piece to the display (marks only when kept),
// keeping the source map and cutting runs at style changes. `src` < 0 means
// the piece is a slice of the scanned text (its offset is recovered from it).
@(private)
md_live_piece :: proc(c: ^Md_Live_Ctx, piece: string, src: int, attrs: Attrs, href: string, is_mark: bool) {
	if is_mark && !c.keep do return
	a := attrs
	if is_mark do a += {.Mark}
	if c.cur_valid && (c.cur_attrs != a || c.cur_href != href) && len(c.text) > c.run_start {
		append(&c.runs, Run{end = len(c.text), attrs = c.cur_attrs, href = strings.clone(c.cur_href, c.allocator) if len(c.cur_href) > 0 else ""})
		c.run_start = len(c.text)
	}
	c.cur_attrs, c.cur_href, c.cur_valid = a, href, true
	off := src
	if off < 0 do off = c.src_off + int(uintptr(raw_data(piece)) - uintptr(c.scan_base))
	for i in 0 ..< len(piece) do append(&c.src, off + i)
	append(&c.text, ..transmute([]u8)piece)
}

@(private)
md_live_close :: proc(c: ^Md_Live_Ctx) {
	if c.cur_valid && len(c.text) > c.run_start {
		append(&c.runs, Run{end = len(c.text), attrs = c.cur_attrs, href = strings.clone(c.cur_href, c.allocator) if len(c.cur_href) > 0 else ""})
	}
}

// LANG_MARKDOWN colours markdown source: headings, list markers and
// quotes as keywords, code as strings, emphasis marks as operators, links
// as attributes.
LANG_MARKDOWN := Language{name = "Markdown", brackets = "()[]", tokenize = markdown_tokenize}

@(private)
markdown_tokenize :: proc(lang: ^Language, line: string, state: u32, out: ^[dynamic]Token) -> u32 {
	trimmed := strings.trim_left(line, " ")
	indent := len(line) - len(trimmed)
	if state == LINE_IN_COMMENT { // inside a fence
		if strings.has_prefix(trimmed, "```") {
			append(out, Token{start = indent, end = len(line), kind = .Keyword})
			return 0
		}
		if len(line) > 0 do append(out, Token{start = 0, end = len(line), kind = .String})
		return state
	}
	body := indent
	switch {
	case strings.has_prefix(trimmed, "```"):
		append(out, Token{start = indent, end = len(line), kind = .Keyword})
		return LINE_IN_COMMENT
	case strings.has_prefix(trimmed, "#"):
		n := 0
		for n < len(trimmed) && trimmed[n] == '#' do n += 1
		append(out, Token{start = indent, end = len(line), kind = .Keyword})
		return 0
	case strings.has_prefix(trimmed, "> "):
		append(out, Token{start = indent, end = indent + 1, kind = .Keyword})
		body = indent + 2
	case strings.has_prefix(trimmed, "- [ ] ") || strings.has_prefix(trimmed, "- [x] "):
		append(out, Token{start = indent, end = indent + 5, kind = .Keyword})
		body = indent + 6
	case strings.has_prefix(trimmed, "- ") || strings.has_prefix(trimmed, "* "):
		append(out, Token{start = indent, end = indent + 1, kind = .Keyword})
		body = indent + 2
	case markdown_numbered(trimmed) > 0:
		n := markdown_numbered(trimmed)
		append(out, Token{start = indent, end = indent + n - 1, kind = .Keyword})
		body = indent + n
	case trimmed == "---":
		append(out, Token{start = indent, end = len(line), kind = .Keyword})
		return 0
	}
	// inline marks
	i := body
	for i < len(line) {
		switch {
		case line[i] == '`':
			j := strings.index_byte(line[i + 1:], '`')
			if j < 0 {
				i += 1
				continue
			}
			append(out, Token{start = i, end = i + j + 2, kind = .String})
			i += j + 2
		case strings.has_prefix(line[i:], "**") || strings.has_prefix(line[i:], "~~"):
			append(out, Token{start = i, end = i + 2, kind = .Operator})
			i += 2
		case line[i] == '*' || line[i] == '_':
			append(out, Token{start = i, end = i + 1, kind = .Operator})
			i += 1
		case line[i] == '[':
			close := strings.index_byte(line[i:], ']')
			if close > 0 && close + 1 < len(line[i:]) && line[i + close + 1] == '(' {
				end := strings.index_byte(line[i + close + 1:], ')')
				if end > 0 {
					append(out, Token{start = i, end = i + close + 1, kind = .Attribute})
					append(out, Token{start = i + close + 1, end = i + close + 2 + end, kind = .Comment})
					i += close + 2 + end
					continue
				}
			}
			i += 1
		case:
			i += 1
		}
	}
	_ = lang
	return 0
}
