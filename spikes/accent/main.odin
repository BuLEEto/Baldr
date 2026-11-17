package accent_spike

// An app that gives only its accent, drawn in whichever
// light/dark the desktop asks for. Run it twice —
//   BALDR_THEME=light build/accent   BALDR_THEME=dark build/accent
// — and the two should differ in light/dark while both stay rose.

import "core:fmt"
import "baldr:baldr"

ROSE :: 0xc9527f

State :: struct {}
Msg :: union { int }

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "accent", app_id = "baldr.accent", size = {560, 360},
		accent = baldr.rgb(ROSE), // …and no `theme`: the desktop says light or dark
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			th := &ui.tree.theme
			baldr.column(ui, gap = .lg, padding = .xl, flex = 1); {
				defer baldr.end(ui)
				baldr.text(ui, fmt.tprintf("%s, %v, contrast %v", th.name, th.mode, th.contrast), role = .Title)
				baldr.text(ui, "An app's own colour, the desktop's light and dark.")
				baldr.row(ui, gap = .md); {
					defer baldr.end(ui)
					baldr.button(ui, "Primary", Msg(0))
					baldr.button(ui, "Secondary", Msg(1), variant = .Secondary)
					baldr.button(ui, "Ghost", Msg(2), variant = .Ghost)
					baldr.badge(ui, "Accent")
				}
				baldr.card(ui, padding = .lg); {
					defer baldr.end(ui)
					baldr.text(ui, "A card, for the surface colours.", muted = true)
				}
			}
		},
	})
}
