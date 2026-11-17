// 01_hello — the counter, in a real window. Scoped builders, one message
// enum, state mutated in update, view re-run only after a message.
//
//   ./build.sh example 01_hello run
package main

import "core:fmt"
import "baldr:baldr"

State :: struct {
	count: int,
}

Msg :: enum {
	Inc,
	Dec,
	Reset,
}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch m {
	case .Inc:   s.count += 1
	case .Dec:   s.count -= 1
	case .Reset: s.count = 0
	}
	return {}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, flex = 1, gap = .lg, padding = .xxl, align = .Center, justify = .Center); defer baldr.end(ui)
	baldr.text(ui, "Hello, Baldr", role = .Headline)
	baldr.text(ui, fmt.tprintf("Count: %d", s.count), role = .Title, muted = true)
	baldr.row(ui, gap = .md); {
		defer baldr.end(ui)
		baldr.button(ui, "−", Msg.Dec, variant = .Secondary)
		baldr.button(ui, "Reset", Msg.Reset, variant = .Outline, disabled = s.count == 0)
		baldr.button(ui, "+", Msg.Inc)
	}
}

main :: proc() {
	err := baldr.run(baldr.App(State, Msg){
		title  = "Hello, Baldr",
		app_id = "baldr.hello",
		size   = {480, 320},
		update = update,
		view   = view,
	})
	if err != .None do fmt.eprintln("exit:", err)
}
