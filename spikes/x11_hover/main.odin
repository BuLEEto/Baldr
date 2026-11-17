// x11_hover — does the pointer reach the app with no button held?
//
// Selecting XI2 motion for the scroll valuators makes the server stop
// sending the core MotionNotify for that window, so a backend that gets this
// wrong delivers no hover, no cursor change and no tooltip — while a *drag*
// still works, because the press's implicit grab brings the core events
// back. It looks like a cursor bug and is an event-delivery bug.
//
// This is the smallest thing that tells the two apart. The card hears
// samples with `hover = true`, as a timeline does, and prints each frame's
// batch; the strips down its sides ask for a resize cursor the way a clip's
// trim edge does, the middle for a grab. So:
//
//   - moves printed with nothing held  → motion is being delivered
//   - moves printed only while dragging → hover motion is lost
//   - one scroll per wheel click       → the valuators are not double-counted
//
// The cursor itself is read from the server, not guessed:
//
//   tools/nested-x.sh start
//   BALDR_X11_DEBUG=1 tools/nested-x.sh run x11_hover
//   DISPLAY=:2 xdotool mousemove <x> <y>    # over a strip
//   DISPLAY=:2 build/x11_cursor             # its size, hotspot and ink
package main

import "core:fmt"
import "core:os"
import "baldr:baldr"

State :: struct {
	moves, enters, leaves, presses, batches, scrolls: int,
	last:  [2]f32,
	note:  string,
}

Msg :: union { Samples, Scrolled, Clicked }
Samples  :: struct { v: baldr.Pointer_Samples }
Scrolled :: struct { v: baldr.Scroll }
Clicked  :: struct {}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "hover", app_id = "baldr.hover", size = {560, 300},
		init = proc() -> State { return {note = "move the pointer over the card, nothing held"} },
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			switch v in m {
			case Samples:
				s.batches += 1
				for smp in v.v.samples {
					switch smp.kind {
					case .Move:    s.moves += 1; s.last = smp.pos
					case .Enter:   s.enters += 1
					case .Leave:   s.leaves += 1
					case .Press:   s.presses += 1
					case .Release:
					}
				}
				held := len(v.v.samples) > 0 && v.v.samples[len(v.v.samples) - 1].buttons != {}
				fmt.printfln("batch %d: %d sample(s), %d move(s) so far, last %.0f,%.0f, held %v",
					s.batches, len(v.v.samples), s.moves, s.last.x, s.last.y, held)
			case Scrolled:
				s.scrolls += 1
				fmt.printfln("scroll %d: delta %.2f,%.2f precise %v", s.scrolls, v.v.delta.x, v.v.delta.y, v.v.precise)
			case Clicked:
				fmt.println("the button was clicked")
			}
			os.flush(os.stdout)
			return {}
		},
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			baldr.column(ui, flex = 1, padding = .lg, gap = .sm); defer baldr.end(ui)
			baldr.text(ui, "hover", role = .Headline)
			baldr.text(ui, s.note, muted = true)
			baldr.text(ui, fmt.tprintf("%d move(s), %d enter(s), %d leave(s), %d press(es), %d scroll(s)",
				s.moves, s.enters, s.leaves, s.presses, s.scrolls), muted = true)
			baldr.button(ui, "a button, to see a hover wash", Msg(Clicked{}))

			// The card hears every sample over it, held or not. Its strips ask
			// for the cursors a trim edge and a clip body would.
			card := baldr.card(ui, flex = 1, padding = .none)
			{
				baldr.row(ui, flex = 1, gap = .none, align = .Stretch); defer baldr.end(ui) // .Stretch, or the strips are 24x0 and nothing can hit them
				left   := baldr.box(ui, width = 24) // a box is a leaf: no end
				middle := baldr.box(ui, flex = 1)
				right  := baldr.box(ui, width = 24)
				baldr.pointer_area(ui, left,   cursor = .Resize_EW)
				baldr.pointer_area(ui, middle, cursor = .Grab)
				baldr.pointer_area(ui, right,  cursor = .Resize_EW)
			}
			baldr.end(ui)
			baldr.pointer_samples(ui, card, proc(e: baldr.Ev(baldr.Pointer_Samples)) -> Msg { return Samples{e.value} }, hover = true)
			baldr.pointer_area(ui, card, on_scroll = proc(e: baldr.Ev(baldr.Scroll)) -> Msg { return Scrolled{e.value} })
		},
	})
}
