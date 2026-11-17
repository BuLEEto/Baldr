package main

// Print every window the compositor lists, with Baldr's id and
// the compositor's handle, whenever the list changes.

import "core:fmt"
import "baldr:baldr"

Msg :: enum { None, Changed }

main :: proc() {
	baldr.run(baldr.App(int, Msg){
		title = "Handles", app_id = "dev.baldr.handles", size = {320, 120},
		init = proc() -> int { return 0 },
		view = proc(s: ^int, ui: ^baldr.Ui(Msg)) { baldr.text(ui, "listing windows…") },
		update = proc(s: ^int, m: Msg) -> baldr.Cmd(Msg) {
			if m == .Changed {
				for w in baldr.toplevels() do fmt.eprintfln("HANDLE id=%d handle=%d app=%s title=%q", w.id, w.handle, w.app_id, w.title)
				fmt.eprintln("HANDLE --")
			}
			return {}
		},
		subscriptions = proc(s: ^int, out: ^[dynamic]baldr.Sub(Msg)) { append(out, baldr.toplevels_changed(Msg, Msg.Changed)) },
	})
}
