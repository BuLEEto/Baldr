// 26_reply — a model's answer, rendered and read-only: the
// markdown view showing a Markdown_Doc the app owns. Press Stream to watch
// it arrive a few characters at a time, as a reply does; the blocks above
// the last one are not laid out again while it grows. Drag to select across
// blocks, double-click a word, Ctrl+A then Ctrl+C to copy it as clean text,
// and the buttons under it show what is selected, as text and as markdown.
//
//   ./build.sh example 26_reply run
package main

import "core:fmt"
import "core:strings"
import "baldr:baldr"

REPLY :: `# Odin, briefly

Odin is a systems language with **explicit** allocators, *no* hidden
control flow and a standard library written in Odin itself.

### Reading it in order

1. Start with the overview: an hour, end to end.
2. Then the demo file — every feature, one page.
3. Write something small that allocates.
4. Swap its allocator for an arena.
5. Read the core collections.
6. Read ` + "`core:fmt`" + `, which is plain Odin.
7. Try ` + "`defer`" + ` until it is a habit.
8. Learn the or_return shape for errors.
9. Build with -vet, always.
10. Then read someone else's code.
11. Then write the thing you came for.
12. Keep the overview open beside you.

- procedures are values, and ` + "`proc()`" + ` types are first class
- ` + "`defer`" + ` runs at the end of the scope, not the function
- [the overview](https://odin-lang.org/docs/overview/) is worth an hour

> Errors are values. There are no exceptions to unwind.

| allocator | lifetime | freed by |
|---|---|---|
| context.allocator | yours | you |
| context.temp_allocator | the wake-up | the runtime |
| arena | the scope | one reset |

A table that says nothing about alignment still lines its figures up, because
a column whose cells are all numbers is set to the right:

| part | on hand | unit |
|---|---|---|
| P001 | 130 | £12.50 |
| P002 | 35 | £4.00 |
| P003 | 7 | £119.99 |

` + "```odin" + `
main :: proc() {
	nums := make([]int, 8, context.temp_allocator)
	for &n, i in nums do n = i * i
	fmt.println(nums) // [0, 1, 4, 9, 16, 25, 36, 49]
}
` + "```" + `

Build it with the one line that matters:

` + "```sh" + `
odin build . -collection:baldr=. -out:build/app -o:speed -vet
` + "```" + `

The overview at https://odin-lang.org/docs/overview/ is where to start,
and the mailing list will answer what it does not.[^1]

[^1]: Ask on the Discord too — someone is usually awake.

That is the whole of it — the rest is the standard library.
`

State :: struct {
	doc:      baldr.Markdown_Doc,
	streamed: int,  // bytes handed over so far, while streaming
	link:     string,
}

Msg :: union { Stream, Chunk, Whole, Link }
Stream :: struct {}
Chunk  :: struct {}
Whole  :: struct {}
Link   :: struct { href: string }

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Reply", app_id = "baldr.reply", size = {1100, 760},
		init = proc() -> State {
			s: State
			baldr.md_set(&s.doc, REPLY)
			s.streamed = len(REPLY) // it is all here: nothing left to stream in
			return s
		},
		subscriptions = proc(s: ^State, out: ^[dynamic]baldr.Sub(Msg)) {
			if s.streamed >= len(REPLY) do return
			append(out, baldr.every(Msg, 30, Chunk{})) // 30 ms: a reply's pace
		},
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			switch v in m {
			case Stream:
				baldr.md_clear(&s.doc)
				s.streamed = 0
			case Chunk:
				if s.streamed >= len(REPLY) do break
				src := REPLY
				n := min(s.streamed + 8, len(src))
				baldr.md_append(&s.doc, src[s.streamed:n])
				s.streamed = n
			case Whole:
				baldr.md_set(&s.doc, REPLY)
				s.streamed = len(REPLY)
			case Link:
				// An app decides what a link does; this one says which. The
				// target is the view's own memory, which it lets go of when
				// that block is laid out again — so keeping it is a copy.
				delete(s.link)
				s.link = strings.clone(v.href)
			}
			return {}
		},
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			baldr.column(ui, gap = .md, padding = .lg, flex = 1); {
				defer baldr.end(ui)
				baldr.row(ui, gap = .sm); {
					defer baldr.end(ui)
					baldr.button(ui, "Stream it", Msg(Stream{}))
					baldr.button(ui, "All at once", Msg(Whole{}), variant = .Secondary)
					if len(s.link) > 0 do baldr.text(ui, s.link, muted = true)
				}
				baldr.scroll(ui, flex = 1, follow_end = true); {
					defer baldr.end(ui)
					baldr.card(ui, padding = .lg); {
						defer baldr.end(ui)
						n := baldr.markdown_view(ui, &s.doc, label = "Assistant's reply", flex = 1)
						baldr.md_view_options(ui, n,
							// A window wide enough for a table is too wide for
							// prose, so the paragraphs are held to a reading
							// measure and centred while tables and code keep
							// the whole width. Widen the window past ~720 px
							// to see the two part company.
							prose_width = 640,
							on_link = proc(e: baldr.Ev(string)) -> Msg { return Link{e.value} },
							language = proc(name: string) -> ^baldr.Language {
								switch name {
								case "odin": return &baldr.LANG_ODIN
								case "c":    return &baldr.LANG_C
								case "json": return &baldr.LANG_JSON
								}
								return nil // plain monospace, which is the honest fallback
							})
						lo, hi := baldr.md_view_selection(&ui.tree, n)
						if lo < hi {
							baldr.text(ui, fmt.tprintf("%d bytes selected · Ctrl+C copies the words, the markdown behind them is %d",
								hi - lo, len(baldr.md_markdown(&s.doc, lo, hi))), muted = true, role = .Caption)
						}
					}
				}
			}
		},
	})
}
