package main

// A window that brings itself forward. After SPIKE_AFTER_MS
// (2000) the app asks for its own window to be activated, asking the
// desktop for a token itself (SPIKE_TOKEN: use that one instead). On
// some compositors an activation marks the window urgent instead of raising.

import "core:fmt"
import "core:os"
import "baldr:baldr"

Msg :: enum { Now }

main :: proc() {
	baldr.run(baldr.App(int, Msg){
		title = "Activate", app_id = "dev.baldr.activate_self", size = {300, 120},
		init = proc() -> int { return 0 },
		start = proc(s: ^int) -> baldr.Cmd(Msg) { return baldr.delay(Msg, 2000, Msg.Now) },
		update = proc(s: ^int, m: Msg) -> baldr.Cmd(Msg) {
			fmt.eprintln("activate_self: asking to come forward")
			return baldr.activate(Msg, token = os.get_env("SPIKE_TOKEN", context.temp_allocator))
		},
		view = proc(s: ^int, ui: ^baldr.Ui(Msg)) { baldr.text(ui, "I will ask to come forward") },
	})
}
