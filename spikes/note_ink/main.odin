package main

// A sticky note is a page of its own colour with its own ink,
// whatever the desktop's theme is. Two notes, the theme dark.

import "baldr:baldr"

PAPERS := [2]baldr.Color{{0.99, 0.87, 0.35, 1}, {0.99, 0.66, 0.72, 1}} // yellow, pink
INK    :: baldr.Color{0.10, 0.08, 0.04, 1}

State :: struct { notes: [2]baldr.Document }
Msg   :: enum { None }

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.row(ui, flex = 1, gap = .lg, padding = .lg); defer baldr.end(ui)
	for &doc, i in s.notes {
		card := baldr.column(ui, flex = 1, bg = PAPERS[i], radius = 12, key = u64(i + 1))
		// a note's title bar is part of its paper
		baldr.window_chrome(ui, "Shopping" if i == 0 else "Birthday", ink = INK, key = u64(i + 1))
		baldr.window_buttons(ui, ink = INK)
		baldr.end(ui)
		baldr.column(ui, flex = 1, padding = .md, key = u64(i + 10))
		ed := baldr.markdown_editor(ui, &doc, placeholder = "Write a note…", flex = 1, key = u64(i + 1)) // what a sticky note is
		baldr.editor_options(ui, ed, ink = INK, frame = false)
		baldr.end(ui)
		baldr.end(ui)
		_ = card
	}
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Notes", app_id = "dev.baldr.note_ink", size = {720, 360},
		theme = baldr.theme_dark(),
		init = proc() -> State {
			return {notes = {
				baldr.document_make("Milk, bread, jam\n- the plumber\n1. Tuesday"),
				baldr.document_make(""), // a note opens empty: the placeholder is the first thing anybody sees
			}}
		},
		view = view,
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) { return {} },
	})
}
