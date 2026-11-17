package main

// A popover centred on its anchor. A dock on the screen's
// bottom edge (SPIKE_EDGE=left: its left edge) with a launcher button in
// the middle, one at its start and one at its end. The launcher's 620 px
// menu opens centred over its button; the start button's centred menu
// slides in from the screen's edge; the end button's lines up with its
// end. SPIKE_OPEN=middle|start|end opens one at start.

import "core:os"
import "baldr:baldr"

DOCK :: 64

Which :: enum { None, Start, Middle, End }
State :: struct {
	open: Which,
	left: bool,
}
Msg :: union { Which }

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	w := m.(Which)
	s.open = .None if s.open == w else w
	return {}
}

surfaces :: proc(s: ^State, out: ^[dynamic]baldr.Surface_Desc(Msg)) {
	append(out, baldr.Surface_Desc(Msg){
		tag = 1, kind = .Layer, title = "Dock", size = {DOCK, 0} if s.left else {0, DOCK},
		layer = {level = .Top, anchor = {.Left, .Top, .Bottom} if s.left else {.Bottom, .Left, .Right}, exclusive_zone = DOCK, keyboard = .On_Demand},
		transparent = true, backdrop = .Blur,
	})
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	if s.left do baldr.column(ui, flex = 1, align = .Center, padding = .sm)
	else do baldr.row(ui, flex = 1, align = .Center, padding = .sm)
	defer baldr.end(ui)
	dock_button(s, ui, .Start, .Layout_Grid, .Center, 480)
	baldr.spacer(ui)
	dock_button(s, ui, .Middle, .Search, .Center, 620)
	baldr.spacer(ui)
	dock_button(s, ui, .End, .Settings, .End, 320)
}

dock_button :: proc(s: ^State, ui: ^baldr.Ui(Msg), w: Which, icon: baldr.Icon, align: baldr.Align, width: f32) {
	b := baldr.button(ui, "Open", Msg(w), icon = icon, icon_only = true, variant = .Primary if s.open == w else .Ghost, key = u64(w))
	if baldr.popover(ui, b, s.open == w, Msg(w), align = align, min_width = width, key = u64(w) + 100) {
		defer baldr.end(ui)
		baldr.text(ui, "Launcher", role = .Headline)
		baldr.text(ui, "Its middle over the button's middle." if align == .Center else "Its end at the button's end.", muted = true)
		baldr.box(ui, height = 200)
	}
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		app_id = "dev.baldr.dock_centre",
		init = proc() -> (s: State) {
			s.left = os.get_env("SPIKE_EDGE", context.temp_allocator) == "left"
			switch os.get_env("SPIKE_OPEN", context.temp_allocator) {
			case "start":  s.open = .Start
			case "middle": s.open = .Middle
			case "end":    s.open = .End
			}
			return
		},
		update = update, view = view, surfaces = surfaces,
	})
}
