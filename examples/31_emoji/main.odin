// 31_emoji — the emoji picker, in the shape a messenger uses it:
// a composer with a button that opens the picker in a popover, the chosen
// emoji inserted at the caret, and the app keeping its own recents and
// skin tone (both are preferences that outlive the window, so the toolkit
// does not keep them).
package main

import "core:strings"
import "baldr:baldr"

Msg :: union {
	Open,
	Close,
	Picked,
	Tone,
}
Open   :: struct {}
Close  :: struct {}
Picked :: struct { seq: string }
Tone   :: struct { tone: baldr.Skin_Tone }

RECENTS_MAX :: 16

State :: struct {
	draft:   baldr.Document,
	open:    bool,
	tone:    baldr.Skin_Tone,
	recents: [dynamic]string, // most recent first; owned, so each is cloned
}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch v in m {
	case Open:
		s.open = true
	case Close:
		s.open = false
	case Tone:
		s.tone = v.tone
	case Picked:
		// The sequence is the picker's and valid until the next pick, so
		// anything kept is cloned (baldr/msg_lifetime_test.odin pins this).
		end_ := baldr.document_end(&s.draft)
		baldr.document_replace(&s.draft, end_, end_, v.seq)
		remember(s, v.seq)
		s.open = false
	}
	return {}
}

// remember keeps the app's recents: most recent first, no duplicates, 16.
remember :: proc(s: ^State, seq: string) {
	for r, i in s.recents {
		if r == seq {
			ordered_remove(&s.recents, i)
			inject_at(&s.recents, 0, r)
			return
		}
	}
	inject_at(&s.recents, 0, strings.clone(seq))
	for len(s.recents) > RECENTS_MAX {
		delete(pop(&s.recents))
	}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, padding = .lg, gap = .md); defer baldr.end(ui)
	baldr.text(ui, "Composer", role = .Title)

	baldr.text_area(ui, &s.draft, placeholder = "Say something…", label = "Message", height = 120, key = 1)

	baldr.row(ui, gap = .sm, align = .Center)
	{
		defer baldr.end(ui)
		b := baldr.button(ui, "Emoji", Msg(Open{}), icon = .Smile, key = 2)
		if baldr.popover(ui, b, s.open, Msg(Close{}), min_width = 360, key = 3) {
			defer baldr.end(ui)
			baldr.emoji_picker(ui,
				proc(e: baldr.Ev(string)) -> Msg { return Picked{e.value} },
				recents = s.recents[:],
				skin = s.tone,
				on_skin = proc(e: baldr.Ev(baldr.Skin_Tone)) -> Msg { return Tone{e.value} },
				width = 344, height = 380, key = 1)
		}
		baldr.text(ui, "recents are the app's, and so is the tone", role = .Caption, muted = true)
	}
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Emoji", app_id = "baldr.emoji", size = {520, 640},
		init = proc() -> State {
			return State{draft = baldr.document_make(""), recents = make([dynamic]string)}
		},
		update = update, view = view,
	})
}
