package main

// Toasts on one layer surface: separate glass cards at the top right of the screen, the desktop
// blurred behind each card only and clear between them. A click on a card dismisses it; the last one closes the
// app. --all blurs and tints the whole surface instead, for comparison; --light for the light theme.

import "core:fmt"
import "core:os"
import "baldr:baldr"

TOASTS := [3]string{"Build finished", "Ada: Lunch at one?", "Backup complete"}

State :: struct {
	shown: [3]bool,
	all:   bool,
}

Dismiss :: struct { i: int }
Msg :: union { Dismiss }

surfaces :: proc(s: ^State, out: ^[dynamic]baldr.Surface_Desc(Msg)) {
	append(out, baldr.Surface_Desc(Msg){
		tag = 1, kind = .Layer, title = "Toasts", size = {386, baldr.FIT},
		layer = {level = .Overlay, anchor = {.Top, .Right}, margin = {8, 8, 0, 0}},
		transparent = true, backdrop = .Blur,
		backdrop_region = .All if s.all else .Marked, // behind the cards only: clear between them
		input = .All if s.all else .Marked,
	})
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, gap = 8, padding = 8); defer baldr.end(ui)
	for title, i in TOASTS {
		if !s.shown[i] do continue
		c := baldr.card(ui, glass = true, gap = .xxs, padding = .md, height = 72, key = u64(i + 1)); {
			defer baldr.end(ui)
			baldr.backdrop_area(ui, c) // blurred behind this card
			baldr.input_area(ui, c)    // and it takes the pointer
			baldr.clickable(ui, c, Msg(Dismiss{i}), label = title)
			baldr.text(ui, title, weight = .Semibold)
			baldr.text(ui, "Click to dismiss", muted = true)
		}
	}
}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch v in m {
	case Dismiss:
		s.shown[v.i] = false
		if s.shown == {} do return baldr.quit(Msg)
	}
	return {}
}

main :: proc() {
	light, all := false, false
	for a in os.args[1:] {
		if a == "--light" do light = true
		if a == "--all" do all = true
	}
	baldr_all = all
	err := baldr.run(baldr.App(State, Msg){
		app_id = "dev.baldr.toasts", theme = baldr.theme_light() if light else baldr.theme_dark(),
		init = proc() -> State { return {shown = {true, true, true}, all = baldr_all} },
		update = update, view = view, surfaces = surfaces,
	})
	if err != .None do fmt.eprintln("exit:", err)
}

baldr_all: bool // --all, for init
