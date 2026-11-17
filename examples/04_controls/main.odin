// 04_controls — checkbox, toggle, slider bound to state; every value flows
// back through a message and the view re-renders from state.
//
//   ./build.sh example 04_controls run
package main

import "core:fmt"
import "baldr:baldr"

State :: struct {
	remember: bool,
	dark:     bool,
	notify:   bool,
	volume:   f32,
	size:     f32,
}

Msg :: union {
	Set_Remember,
	Set_Dark,
	Set_Notify,
	Set_Volume,
	Set_Size,
	Reset,
}
Set_Remember :: struct { on: bool }
Set_Dark     :: struct { on: bool }
Set_Notify   :: struct { on: bool }
Set_Volume   :: struct { v: f32 }
Set_Size     :: struct { v: f32 }
Reset        :: struct {}

init :: proc() -> State { return {dark = true, volume = 0.4, size = 15} }

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch v in m {
	case Set_Remember: s.remember = v.on
	case Set_Dark:     s.dark = v.on
	case Set_Notify:   s.notify = v.on
	case Set_Volume:   s.volume = v.v
	case Set_Size:     s.size = v.v
	case Reset:        s^ = init()
	}
	return {}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, flex = 1, padding = .xl, gap = .lg); defer baldr.end(ui)
	baldr.text(ui, "Settings", role = .Headline)
	baldr.card(ui, gap = .md); {
		defer baldr.end(ui)
		baldr.text(ui, "Account", role = .Title)
		baldr.checkbox(ui, s.remember, "Remember me on this device", proc(e: baldr.Ev(bool)) -> Msg { return Set_Remember{e.value} })
		baldr.checkbox(ui, s.notify, "Email me about new releases", proc(e: baldr.Ev(bool)) -> Msg { return Set_Notify{e.value} })
		baldr.checkbox(ui, false, "Two-factor (managed by your organisation)", nil, disabled = true)
	}
	baldr.card(ui, gap = .md); {
		defer baldr.end(ui)
		baldr.text(ui, "Appearance", role = .Title)
		baldr.toggle(ui, s.dark, "Dark theme", proc(e: baldr.Ev(bool)) -> Msg { return Set_Dark{e.value} })
		baldr.row(ui, align = .Center, gap = .md); {
			defer baldr.end(ui)
			baldr.text(ui, "Text size", muted = true)
			baldr.slider(ui, s.size, min = 12, max = 24, step = 1, flex = 1, label = "Text size",
				on_change = proc(e: baldr.Ev(f32)) -> Msg { return Set_Size{e.value} })
			baldr.row(ui, width = 52, justify = .End); { defer baldr.end(ui); baldr.text(ui, fmt.tprintf("%.0f px", s.size), role = .Label) }
		}
		baldr.row(ui, align = .Center, gap = .md); {
			defer baldr.end(ui)
			baldr.text(ui, "Volume", muted = true)
			baldr.slider(ui, s.volume, flex = 1, label = "Volume", on_change = proc(e: baldr.Ev(f32)) -> Msg { return Set_Volume{e.value} })
			baldr.row(ui, width = 52, justify = .End); { defer baldr.end(ui); baldr.text(ui, fmt.tprintf("%d%%", int(s.volume * 100)), role = .Label) }
		}
	}
	baldr.row(ui); {
		defer baldr.end(ui)
		baldr.button(ui, "Reset", Msg(Reset{}), variant = .Outline)
	}
}

main :: proc() {
	err := baldr.run(baldr.App(State, Msg){title = "Controls", app_id = "baldr.controls", size = {520, 480}, init = init, update = update, view = view})
	if err != .None do fmt.eprintln("exit:", err)
}
