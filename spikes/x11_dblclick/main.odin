// x11_dblclick — does the first double-click of an app's life count?
//
// The claim to test: the first double-click after an app starts never sends
// `on_double_click`, and every one after does. One `clickable` with both
// handlers, printing each click and each double with the toolkit's own
// clock, so a pair that was refused can be told apart from a click that
// never arrived.
//
//   tools/nested-x.sh run x11_dblclick
//   DISPLAY=:2 xdotool mousemove <x> <y>
//   DISPLAY=:2 xdotool click --repeat 2 --delay 100 1
package main

import "core:fmt"
import "core:os"
import "baldr:baldr"

State :: struct { clicks, doubles: int, log: string }
Msg :: union { Clicked, Doubled }
Clicked :: struct { at_ms: f64, pos: [2]f32 }
Doubled :: struct {}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "dblclick", app_id = "baldr.dblclick", size = {420, 220},
		init = proc() -> State { return {log = "click twice, quickly"} },
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			switch v in m {
			case Clicked:
				s.clicks += 1
				fmt.printfln("click %d: tree clock %.1f ms, pointer %.1f,%.1f", s.clicks, v.at_ms, v.pos.x, v.pos.y)
			case Doubled:
				s.doubles += 1
				fmt.printfln("DOUBLE %d (after click %d)", s.doubles, s.clicks)
			}
			os.flush(os.stdout)
			return {}
		},
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			baldr.column(ui, flex = 1, padding = .lg, gap = .sm); defer baldr.end(ui)
			baldr.text(ui, "dblclick", role = .Headline)
			baldr.text(ui, fmt.tprintf("%d click(s), %d double(s)", s.clicks, s.doubles), muted = true)
			// The clock and the pointer as the toolkit has them *now*, captured
			// into the message: the two things the pairing is decided on.
			now, pos := ui.tree.now_ms, ui.pointer.pos
			// After the first click a line appears *above* the card, as an
			// app's first click usually changes something. If that shifted the
			// card's node handle, the pair stored under the old handle would be
			// lost and the second click could not find it.
			if s.clicks > 0 do baldr.text(ui, fmt.tprintf("first click seen (%d)", s.clicks), muted = true)
			card := baldr.card(ui, flex = 1)
			baldr.text(ui, "click me twice")
			baldr.end(ui)
			baldr.clickable(ui, card, Msg(Clicked{now, pos}), on_double_click = Msg(Doubled{}))
		},
	})
}
