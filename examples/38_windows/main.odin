package main

// Two windows from one state: the main window, and a Preferences window that
// belongs to it. `surfaces` declares which windows exist for the state, by
// tag; the view builds whichever one `ui.surface.tag` names. `parent` keeps
// Preferences above the main window and minimises it with it (macOS keeps
// windows independent, as Mac apps do), and closing it is a message like
// any other.
//
//	./build.sh example 38_windows run

import "core:fmt"
import "baldr:baldr"

MAIN :: u64(1)
PREFS :: u64(2)

State :: struct {
	prefs_open: bool,
	dark:       bool,
	autosave:   bool,
}

Msg :: enum { Open_Prefs, Close_Prefs, Quit, Toggle_Dark, Toggle_Autosave }

surfaces :: proc(s: ^State, out: ^[dynamic]baldr.Surface_Desc(Msg)) {
	append(out, baldr.Surface_Desc(Msg){tag = MAIN, title = "Windows", size = {420, 260}, on_close = Msg.Quit})
	if s.prefs_open {
		append(out, baldr.Surface_Desc(Msg){tag = PREFS, title = "Preferences", size = {320, 200}, parent = MAIN, on_close = Msg.Close_Prefs})
	}
}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch m {
	case .Open_Prefs:      s.prefs_open = true
	case .Close_Prefs:     s.prefs_open = false
	case .Quit:            return baldr.quit(Msg)
	case .Toggle_Dark:     s.dark = !s.dark
	case .Toggle_Autosave: s.autosave = !s.autosave
	}
	return {}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, padding = .lg, gap = .md)
	defer baldr.end(ui)
	switch ui.surface.tag {
	case MAIN:
		baldr.text(ui, "A document", role = .Title)
		baldr.text(ui, fmt.tprintf("Dark: %v · Autosave: %v", s.dark, s.autosave), muted = true)
		baldr.button(ui, "Preferences…", Msg.Open_Prefs, disabled = s.prefs_open)
	case PREFS:
		baldr.text(ui, "Preferences", role = .Title)
		baldr.toggle(ui, s.dark, "Dark", Msg.Toggle_Dark)
		baldr.toggle(ui, s.autosave, "Save as I type", Msg.Toggle_Autosave)
		baldr.button(ui, "Done", Msg.Close_Prefs, default = true)
	}
}

main :: proc() {
	err := baldr.run(baldr.App(State, Msg){update = update, view = view, surfaces = surfaces})
	if err != .None do fmt.eprintln("exit:", err)
}
