// long_select: a select with more options than fit under it (27 blend
// modes in a short window). The list must fit and scroll to its last item.
package main

import "baldr:baldr"

MODES := []string{
	"Normal", "Dissolve", "Darken", "Multiply", "Colour Burn", "Linear Burn", "Darker Colour",
	"Lighten", "Screen", "Colour Dodge", "Linear Dodge", "Lighter Colour", "Overlay", "Soft Light",
	"Hard Light", "Vivid Light", "Linear Light", "Pin Light", "Hard Mix", "Difference", "Exclusion",
	"Subtract", "Divide", "Hue", "Saturation", "Colour", "Luminosity",
}

State :: struct { mode: int }
Msg :: union { Pick }
Pick :: struct { i: int }

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Blend mode", app_id = "baldr.longselect", size = {360, 320},
		init = proc() -> State { return {mode = 0} },
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			switch v in m { case Pick: s.mode = v.i }
			return {}
		},
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			baldr.column(ui, gap = .md, padding = .lg, flex = 1); {
				defer baldr.end(ui)
				baldr.text(ui, "27 blend modes in a short window — the list must fit and scroll.", muted = true)
				baldr.spacer(ui)
				baldr.select(ui, s.mode, MODES, proc(e: baldr.Ev(int)) -> Msg { return Pick{e.value} },
					label = "Blend mode", width = 220)
				baldr.text(ui, MODES[s.mode], role = .Caption, muted = true)
			}
		},
	})
}
