// 29_styled_text — chat bubbles whose bodies the app styled itself.
// The messaging subset is not CommonMark, so the app parses its
// own `*bold*`, `_italic_`, `~strike~`, `` `code` `` and bare URLs, and
// hands Baldr the runs.
//
// The parser here is deliberately tiny — it is the app's job, not the
// toolkit's, and this is the shape of the thing rather than a good one.
package main

import "core:fmt"
import "core:strings"
import "baldr:baldr"

Msg :: union {
	Link,
}
Link :: struct { href: string }

State :: struct {
	last: string,
}

LINES := []string{
	"Morning — the *build is green* again.",
	"I pushed the fix to `widget_styled_text.odin`, see https://example.invalid/commit/4f21",
	"~Ignore the last one~ — that was _the wrong branch_.",
	"`rich_layout` already did the hard part, so it was mostly plumbing.",
	// A message with hard newlines, as a chat body has: every line counts
	// toward the bubble's width, not only the first.
	"Two things, in *one* message:\n- the bubble is only as wide as its text\n- and a line long enough to wrap still wraps inside it, rather than running off the side of the window the way it used to.\n\nThanks!",
	// Right to left, inside a left-to-right line and on its own: each piece
	// is set the way it reads, and a selection follows what is on screen.
	"She wrote *שלום* and he answered _مرحبا_, then they both went back to work.",
	"זהו משפט ארוך בעברית, ארוך מספיק כדי להישבר לשורות בתוך הבועה.",
}

// parse is the app's own markdown: one pass, a run per change of style. It
// handles *bold*, _italic_, ~strike~, `code` and bare http links.
parse :: proc(src: string, allocator := context.temp_allocator) -> (text: string, runs: []baldr.Run) {
	b := strings.builder_make(allocator)
	out := make([dynamic]baldr.Run, allocator)
	cur: baldr.Attrs
	href_at := -1

	flush :: proc(b: ^strings.Builder, out: ^[dynamic]baldr.Run, attrs: baldr.Attrs, href: string) {
		if len(out) > 0 && out[len(out) - 1].end == strings.builder_len(b^) do return
		append(out, baldr.Run{end = strings.builder_len(b^), attrs = attrs, href = href})
	}

	i := 0
	for i < len(src) {
		// a bare link runs to the next space
		if href_at < 0 && (strings.has_prefix(src[i:], "http://") || strings.has_prefix(src[i:], "https://")) {
			flush(&b, &out, cur, "")
			href_at = strings.builder_len(b)
			j := i
			for j < len(src) && src[j] != ' ' do j += 1
			strings.write_string(&b, src[i:j])
			append(&out, baldr.Run{end = strings.builder_len(b), attrs = cur + {.Link},
				href = strings.clone(src[i:j], allocator)})
			href_at, i = -1, j
			continue
		}
		// Inside `code`, nothing else is a marker, or the underscores in an
		// identifier would open and close italics.
		mark: baldr.Attr
		if .Code in cur && src[i] != '`' {
			strings.write_byte(&b, src[i])
			i += 1
			continue
		}
		switch src[i] {
		case '*':  mark = .Bold
		case '~':  mark = .Strike
		case '`':  mark = .Code
		case '_':
			// only at a word boundary, so `a_b` is a name and not italics
			before_ok := i == 0 || src[i - 1] == ' '
			after_ok := i + 1 >= len(src) || src[i + 1] == ' ' || src[i + 1] == '.' || src[i + 1] == ','
			if !((.Italic not_in cur && before_ok) || (.Italic in cur && after_ok)) {
				strings.write_byte(&b, src[i])
				i += 1
				continue
			}
			mark = .Italic
		case:
			strings.write_byte(&b, src[i])
			i += 1
			continue
		}
		flush(&b, &out, cur, "")
		if mark in cur { cur -= {mark} } else { cur += {mark} }
		i += 1
	}
	flush(&b, &out, cur, "")
	return strings.to_string(b), out[:]
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, padding = .lg, gap = .md); defer baldr.end(ui)
	baldr.text(ui, "Styled text", role = .Title)
	baldr.text(ui, "The app parses its own markdown and hands Baldr the runs. Drag to select across the styles; the copy is plain text.", role = .Caption, muted = true)

	{
		// A scroll, because one of these messages is as long as a real one
		// and the window is meant to be resizable down to a phone's width.
		baldr.scroll(ui, .Column, gap = .md, flex = 1, gutter = true); {
			defer baldr.end(ui)
			for line, i in LINES {
				baldr.card(ui, padding = .md, max_width = 420, key = u64(i) + 1); {
					defer baldr.end(ui)
					text, runs := parse(line)
					baldr.styled_text(ui, text, runs,
						on_link = proc(e: baldr.Ev(string)) -> Msg { return Link{e.value} }, key = u64(i) + 1)
				}
			}
		}
	}

	if s.last != "" do baldr.text(ui, fmt.tprintf("last link: %s", s.last), role = .Caption, muted = true)
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Styled text", app_id = "baldr.styled_text", size = {520, 560},
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			switch v in m {
			case Link:
				s.last = v.href
				// An app decides what a link means. A chat would check the
				// scheme first; this one opens it and says what it saw.
				return baldr.open_url(Msg, v.href)
			}
			return {}
		},
		view = view,
	})
}
