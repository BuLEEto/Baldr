package main

// A player's seek bar. The position moves on 4 times a
// second; a seek (on_commit) lands 300 ms later, as a player's does. The
// thumb must stay under the pointer while dragged and not flick back to the
// old position after letting go. Chapters are marked; the time under the
// pointer shows above it. Each report and commit is logged.

import "core:fmt"
import "baldr:baldr"

LENGTH :: f32(600)

State :: struct {
	pos:  f32,
	seen: f32, // the slider's last on_change, to log
}

Msg :: union { Tick, Scrub, Seek, Landed }
Tick :: struct {}
Scrub :: struct { v: f32 }
Seek :: struct { v: f32 }
Landed :: struct { v: f32 }

clock :: proc(v: f32) -> string {
	s := int(v)
	return fmt.tprintf("%d:%02d", s / 60, s % 60)
}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch v in m {
	case Tick:   s.pos = min(s.pos + 0.25, LENGTH)
	case Scrub:  s.seen = v.v
	case Seek:
		fmt.eprintfln("seek_bar: commit %.1f (player at %.1f)", v.v, s.pos)
		return baldr.delay(Msg, 300, Msg(Landed{v.v})) // the player takes a moment
	case Landed:
		s.pos = v.v
		fmt.eprintfln("seek_bar: landed at %.1f", v.v)
	}
	return {}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, flex = 1, padding = f32(40), gap = .md); defer baldr.end(ui)
	baldr.text(ui, fmt.tprintf("Player at %s", clock(s.pos)))
	n := baldr.slider(ui, s.pos, 0, LENGTH, width = 500, label = "Position",
		on_change = proc(e: baldr.Ev(f32)) -> Msg { return Scrub{e.value} },
		on_commit = proc(e: baldr.Ev(f32)) -> Msg { return Seek{e.value} })
	baldr.slider_options(ui, n, marks = []f32{120, 300, 480}, format = clock)
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Seek", app_id = "dev.baldr.seek_bar", size = {600, 160},
		init = proc() -> (s: State) { s.pos = 30; return },
		update = update, view = view,
		subscriptions = proc(s: ^State, out: ^[dynamic]baldr.Sub(Msg)) { append(out, baldr.every(Msg, 250, Msg(Tick{}))) },
	})
}
