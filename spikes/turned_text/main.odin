// turned_text — labels turned with the painter's `draw_text(angle = …)`,
// the way a chart's axes want them: one reading up its side, a row slanted
// under a crowded axis, and a right-angle and an off-angle pair to compare
// at 1:1 (off a right angle the glyphs come from a bitmap twice the size).
//
//   ./build.sh spike turned_text run
package main

import "core:math"
import "baldr:baldr"

State :: struct {}
Msg :: union { int }

MONTHS := []string{"January", "February", "March", "April", "May", "June"}
RAIN := []f32{78, 52, 61, 44, 39, 28}

chart :: proc(p: ^baldr.Painter) {
	r := p.rect
	ink := p.theme.color.on_surface
	muted := p.theme.color.on_surface_muted
	left, bottom := r.x + 56, r.y + r.h - 70
	baldr.draw_text(p, {r.x + 12, bottom - 30}, "Rainfall (mm)", size = 13, color = muted, angle = -math.PI / 2)
	baldr.draw_line(p, {left, r.y + 16}, {left, bottom}, 1, muted)
	baldr.draw_line(p, {left, bottom}, {r.x + r.w - 16, bottom}, 1, muted)
	step := (r.w - 72 - 16) / f32(len(RAIN))
	for v, i in RAIN {
		x := left + 8 + f32(i) * step
		h := v / 80 * (bottom - r.y - 24)
		baldr.draw_rect(p, {x, bottom - h, step - 14, h}, p.theme.color.primary, radius = 3)
		baldr.draw_text(p, {x + 4, bottom + 10}, MONTHS[i], size = 12, color = ink, angle = math.PI / 4)
	}
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "turned text", app_id = "baldr.turnedtext", size = {520, 380},
		init = proc() -> State { return {} },
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) { return {} },
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			baldr.column(ui, flex = 1, padding = .lg, gap = .md); defer baldr.end(ui)
			baldr.text(ui, "Rainfall by month", role = .Title)
			baldr.custom(ui, chart, flex = 1, label = "Rainfall by month, a bar chart")
		},
	})
}
