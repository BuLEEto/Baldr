// 27_conversation — one selection across several messages: a
// column of messages inside a selection_scope. Drag from the middle of one
// message into another and the selection runs through everything between,
// each message drawing its own part; Ctrl+C copies the lot in order, with a
// blank line between messages; Escape lets it go. A selection inside one
// message is still that message's own — double-click a word, triple-click a
// block — and becomes the scope's when the drag leaves.
//
//   ./build.sh example 27_conversation run
package main

import "core:fmt"
import "baldr:baldr"

Kind :: enum { You, Assistant }

Turn :: struct {
	kind: Kind,
	said: baldr.Document,      // what the person typed (read-only here)
	md:   baldr.Markdown_Doc,  // …or what the assistant answered
}

State :: struct {
	turns: [4]Turn,
	copied: int,
}

Msg :: union { Copied, Link }
Copied :: struct { n: int }
Link   :: struct { href: string }

ANSWER_1 :: `An **arena** hands out memory and frees it in one go:

- allocate from it while the work lasts
- reset it when the work is done
- never free anything piece by piece`

ANSWER_2 :: `Use one where the lifetime is obvious — a frame, a request, a
parse — and the ordinary allocator everywhere else. The rule of thumb:

| allocator | freed |
|---|---|
| arena | all at once |
| context.allocator | by you |`

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Conversation", app_id = "baldr.conversation", size = {640, 760},
		init = proc() -> State {
			s: State
			s.turns[0] = {kind = .You, said = baldr.document_make("What is an arena, and when should I reach for one?")}
			s.turns[1] = {kind = .Assistant}
			baldr.md_set(&s.turns[1].md, ANSWER_1)
			s.turns[2] = {kind = .You, said = baldr.document_make("And when is it the wrong tool?")}
			s.turns[3] = {kind = .Assistant}
			baldr.md_set(&s.turns[3].md, ANSWER_2)
			return s
		},
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			switch v in m {
			case Copied: s.copied = v.n
			case Link:   // an app decides what a link does; this one ignores it
			}
			return {}
		},
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			talk: baldr.Node // the conversation's column: the scope the selection runs in
			baldr.column(ui, gap = .sm, padding = .lg, flex = 1); {
				defer baldr.end(ui)
				baldr.text(ui, "Drag from one message into another, then Ctrl+C. Escape lets it go.", muted = true)
				baldr.scroll(ui, flex = 1); {
					defer baldr.end(ui)
					talk = baldr.column(ui, gap = .md, max_width = 560); {
						defer baldr.end(ui)
						baldr.selection_scope(ui, talk) // one selection across everything below
						for &turn, i in s.turns {
							key := u64(i + 1)
							if turn.kind == .You {
								baldr.card(ui, padding = .md, key = key); {
									defer baldr.end(ui)
									q := baldr.text_area(ui, &turn.said, label = "You", flex = 1, key = key)
									baldr.editor_options(ui, q, readonly = true, wrap = true, frame = false)
								}
								continue
							}
							n := baldr.markdown_view(ui, &turn.md, label = "Assistant", flex = 1, key = key)
							baldr.md_view_options(ui, n,
								on_link = proc(e: baldr.Ev(string)) -> Msg { return Link{e.value} })
						}
					}
				}
				sel := baldr.selection_scope_text(&ui.tree, talk)
				if len(sel) > 0 {
					baldr.text(ui, fmt.tprintf("%d bytes selected across the conversation — Ctrl+C copies them in order", len(sel)),
						role = .Caption, muted = true)
				} else {
					baldr.text(ui, "Nothing selected", role = .Caption, muted = true)
				}
			}
		},
	})
}

