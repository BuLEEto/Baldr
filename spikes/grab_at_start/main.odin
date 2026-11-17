package main

// A grabbing popup opened before the app has had any input.
// A bar on the top edge whose start menu — a popover with a search field —
// opens at start, as a shell's does when the compositor's Super key asks for
// it right after login. What is typed into the field is logged.
// SPIKE_WINDOW=1: the same field in an ordinary window instead (a control
// for what typing into the nested session delivers).

import "core:fmt"
import "core:os"
import "baldr:baldr"

State :: struct {
	window: bool,
	open:  bool,
	query: baldr.Text,
}

Msg :: union { Typed, Close, Toggle }
Typed :: struct { text: string }
Close :: struct {}
Toggle :: struct {}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch v in m {
	case Typed:  fmt.eprintfln("grab_at_start: typed %q", v.text)
	case Close:  s.open = false; fmt.eprintln("grab_at_start: closed")
	case Toggle: s.open = !s.open
	}
	return {}
}

surfaces :: proc(s: ^State, out: ^[dynamic]baldr.Surface_Desc(Msg)) {
	if s.window {
		append(out, baldr.Surface_Desc(Msg){tag = 2, title = "Field", size = {400, 120}})
		return
	}
	append(out, baldr.Surface_Desc(Msg){
		tag = 1, kind = .Layer, title = "Bar", size = {0, 36},
		layer = {level = .Top, anchor = {.Top, .Left, .Right}, exclusive_zone = 36, keyboard = .On_Demand},
	})
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	if s.window {
		baldr.column(ui, flex = 1, padding = .lg); defer baldr.end(ui)
		baldr.text_input(ui, &s.query, placeholder = "Search apps", label = "Search", focus = true,
			on_change = proc(e: baldr.Ev(string)) -> Msg { return Typed{e.value} })
		return
	}
	baldr.row(ui, flex = 1, align = .Center, padding = .xs); defer baldr.end(ui)
	apps := baldr.button(ui, "Apps", Msg(Toggle{}))
	if baldr.popover(ui, apps, s.open, Msg(Close{}), min_width = 320) {
		defer baldr.end(ui)
		baldr.text_input(ui, &s.query, placeholder = "Search apps", label = "Search", focus = true,
			on_change = proc(e: baldr.Ev(string)) -> Msg { return Typed{e.value} })
	}
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		app_id = "dev.baldr.grab_at_start",
		init = proc() -> (s: State) {
			s.open = true // opened before any input
			s.window = os.get_env("SPIKE_WINDOW", context.temp_allocator) != ""
			return
		},
		update = update, view = view, surfaces = surfaces,
	})
}
