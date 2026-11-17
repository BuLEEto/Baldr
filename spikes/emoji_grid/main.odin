package main

// The emoji picker filling a window, so the pointer and the
// keyboard can actually reach it. In the example it lives in a popover,
// which is a surface of its own — injected input does not reach those, so
// this is where the picker is driven by hand.
//
//	./build.sh spike emoji_grid run

import "core:fmt"
import "baldr:baldr"

Msg :: union { Picked, Tone }
Picked :: struct { seq: string }
Tone   :: struct { tone: baldr.Skin_Tone }

State :: struct {
	last:    string,
	count:   int,
	tone:    baldr.Skin_Tone,
	recents: [dynamic]string,
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Emoji grid", app_id = "baldr.emoji_grid", size = {400, 560},
		init = proc() -> State { return State{recents = make([dynamic]string)} },
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			switch v in m {
			case Picked:
				s.last = v.seq // the picker's until the next pick; printed at once
				s.count += 1
				fmt.printfln("picked %q (%d bytes)", v.seq, len(v.seq))
			case Tone:
				s.tone = v.tone
				fmt.printfln("tone %v", v.tone)
			}
			return {}
		},
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			baldr.column(ui, padding = .md, gap = .sm); defer baldr.end(ui)
			baldr.emoji_picker(ui,
				proc(e: baldr.Ev(string)) -> Msg { return Picked{e.value} },
				skin = s.tone,
				on_skin = proc(e: baldr.Ev(baldr.Skin_Tone)) -> Msg { return Tone{e.value} },
				height = 440, key = 1)
			baldr.text(ui, fmt.tprintf("%d picked, last %s", s.count, s.last))
		},
	})
}
