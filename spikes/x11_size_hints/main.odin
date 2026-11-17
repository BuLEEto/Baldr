package main

// x11_size_hints — does a window's declared size range reach the X server,
// and does a window manager obey it?
//
// The proof is in two halves and only the first is ours:
//
//   1. the hints are on the window, in the right fields. `xprop -id <id>
//      WM_NORMAL_HINTS` prints "program specified minimum size: W by H",
//      which is a direct read of what the backend wrote — and the field
//      offsets and flag bits are exactly where a mistake would hide.
//   2. a manager obeys them while someone drags an edge. That is the
//      manager's to do, not ours, and openbox under Xephyr is a real one.
//
// Run it with BALDR_BACKEND=x11 under Xephyr; it prints its window id and
// every size the desktop gives it, then quits after SIZE_HINTS_QUIT seconds.

import "core:fmt"
import "core:os"
import "core:strconv"
import "baldr:baldr"

Msg :: enum { None, Quit }

State :: struct { seen: int }

main :: proc() {
	if v, ok := strconv.parse_int(os.get_env("SIZE_HINTS_QUIT", context.temp_allocator)); ok && v > 0 {
		QUIT_MS = i64(v) * 1000
	}
	baldr.run(baldr.App(State, Msg){
		title = "Size hints",
		update = update,
		view   = view,
		surfaces = surfaces,
		subscriptions = subs,
	})
}

// The run ends on its own so a driver script never has to kill it.
QUIT_MS := i64(20000)

subs :: proc(s: ^State, out: ^[dynamic]baldr.Sub(Msg)) {
	append(out, baldr.every(Msg, QUIT_MS, Msg.Quit))
}

surfaces :: proc(s: ^State, out: ^[dynamic]baldr.Surface_Desc(Msg)) {
	append(out, baldr.Surface_Desc(Msg){
		tag = 1, kind = .Window, title = "Size hints",
		size       = {480, 360},
		fixed_size = true, // the one an app can ask for; min_size/max_size are platform-level

		on_state = proc(e: baldr.Ev(baldr.Window_State)) -> Msg {
			fmt.printfln("state: size %.0fx%.0f", e.value.size.x, e.value.size.y)
			return .None
		},
		on_close = Msg.Quit,
	})
}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	if m == .Quit do return baldr.quit(Msg)
	return {}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, flex = 1, padding = .xl, gap = .md, justify = .Center, align = .Center); defer baldr.end(ui)
	baldr.text(ui, "fixed at 480x360", role = .Title)
	baldr.text(ui, "drag an edge: a manager that reads the hints should refuse", role = .Body, muted = true)
}
