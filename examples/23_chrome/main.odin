package main

// A window that draws its own frame: no
// server-side title bar, so the app draws one — and it has to do everything
// a real one does. Drag it to move the window, double click to maximise,
// right click for the desktop's window menu, drag the window's edges to
// resize, and use the buttons. A shell wants this; so does anything that
// puts tabs or a file name where the title would be.

import "baldr:baldr"

State :: struct { note: string }
Quit :: struct {}
Say  :: struct { what: string }
Msg  :: union { Quit, Say }

surfaces :: proc(s: ^State, out: ^[dynamic]baldr.Surface_Desc(Msg)) {
	append(out, baldr.Surface_Desc(Msg){
		tag = 1, kind = .Window, title = "Chrome", size = {640, 420},
		undecorated = true, // the app draws the frame
		on_close = Msg(Quit{}),
	})
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui); defer baldr.end(ui)

	// the title bar, with one of the app's own controls beside the title
	baldr.window_chrome(ui, "Chrome"); {
		defer baldr.end(ui)
		baldr.button(ui, "Say hello", Msg(Say{"hello"}), variant = .Ghost, size = .Small)
		baldr.window_buttons(ui, on_close = Msg(Quit{}))
	}

	body := baldr.column(ui, padding = .lg, gap = .md, flex = 1); {
		defer baldr.end(ui)
		_ = body
		baldr.text(ui, "This window has no frame of its own from the desktop.", role = .Title)
		baldr.text(ui, "Drag the bar to move it. Double click to maximise. Right click it for the window menu. Drag an edge to resize.", muted = true)
		baldr.text(ui, s.note, muted = true)
	}
}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch v in m {
	case Quit: return baldr.quit(Msg)
	case Say:  s.note = v.what
	}
	return {}
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Chrome", app_id = "baldr.chrome", size = {640, 420},
		init = proc() -> State { return {} },
		surfaces = surfaces, view = view, update = update,
	})
}
