package main

// A reading mode that takes the screen: F11 asks, and what
// the window shows is what the desktop actually did — never what was asked.

import "baldr:baldr"

State :: struct { want: bool }
Toggle :: struct {}
Msg :: union { Toggle }

surfaces :: proc(s: ^State, out: ^[dynamic]baldr.Surface_Desc(Msg)) {
	append(out, baldr.Surface_Desc(Msg){
		tag = 1, kind = .Window, title = "Reading", size = {720, 520},
		fullscreen = s.want,
	})
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.shortcut(ui, "F11", Msg(Toggle{}))
	baldr.column(ui, padding = .xl, gap = .lg); defer baldr.end(ui)
	if !ui.surface.fullscreen {
		baldr.text(ui, "Reading", role = .Title)
		baldr.button(ui, "Full screen (F11)", Msg(Toggle{}))
	} else {
		baldr.text(ui, "The whole screen", role = .Display)
		baldr.button(ui, "Give it back (F11)", Msg(Toggle{}), variant = .Outline)
	}
	baldr.text(ui, "asked: yes" if s.want else "asked: no", muted = true)
	baldr.text(ui, "granted: yes" if ui.surface.fullscreen else "granted: no", muted = true)
}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	s.want = !s.want
	return {}
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Reading", app_id = "baldr.reading", size = {720, 520},
		init = proc() -> State { return {} },
		surfaces = surfaces, view = view, update = update,
	})
}
