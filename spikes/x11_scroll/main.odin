// x11_scroll — is scrolling smooth or notched?
//
// Core X has no scroll axis: the wheel is buttons 4 to 7, so every scroll
// is a whole click and a touchpad's glide arrives as a rattle. XInput2 puts
// it on valuators, where the movement is a fraction of a click and
// `precise` is true.
//
// This prints every scroll it receives with its delta and whether it came
// in precise. A wheel click through XI2 is one step and `precise`; the same
// click through core buttons is one step and not precise; a touchpad glide
// is many small precise ones.
//
//   tools/nested-x.sh run x11_scroll     # or on a real X box
package main

import "core:fmt"
import "core:os"
import "baldr:baldr"

State :: struct { n: int, total: [2]f32, last: string }
Msg :: union { Scrolled }
Scrolled :: struct { s: baldr.Scroll }

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "scroll", app_id = "baldr.scroll", size = {420, 200},
		init = proc() -> State { return {last = "turn the wheel over this window"} },
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			switch v in m {
			case Scrolled:
				s.n += 1
				s.total += v.s.delta
				s.last = fmt.aprintf("delta %.2f,%.2f  steps %v  precise %v  mods %v",
					v.s.delta.x, v.s.delta.y, v.s.steps, v.s.precise, v.s.mods)
				fmt.printfln("scroll %d: %s", s.n, s.last)
				os.flush(os.stdout)
			}
			return {}
		},
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			baldr.column(ui, flex = 1, padding = .lg, gap = .sm); defer baldr.end(ui)
			baldr.text(ui, "scroll", role = .Headline)
			baldr.text(ui, s.last, muted = true)
			baldr.text(ui, fmt.tprintf("%d scroll(s), total %.1f,%.1f", s.n, s.total.x, s.total.y), muted = true)
			panel := baldr.card(ui, flex = 1); baldr.end(ui)
			baldr.pointer_area(ui, panel, on_scroll = proc(e: baldr.Ev(baldr.Scroll)) -> Msg { return Scrolled{e.value} })
		},
	})
}
