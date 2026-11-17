package main

// Hand a link to the desktop and say what came back. OPEN_URL is
// the link; it prints "asked", then "opened" or "not opened", and quits.
// Used against a private bus with a fake portal, and with a stub xdg-open,
// so a test never opens anything on the person's own desktop.

import "core:fmt"
import "core:os"
import "baldr:baldr"

Msg :: union { Opened, Quit }
Opened :: struct { ok: bool }
Quit :: struct {}

main :: proc() {
	baldr.run(baldr.App(int, Msg){
		title = "Open URL", app_id = "dev.baldr.open_url", size = {420, 160},
		init = proc() -> int { return 0 },
		start = proc(s: ^int) -> baldr.Cmd(Msg) {
			url := os.get_env("OPEN_URL", context.allocator)
			say("asked")
			return baldr.open_url(Msg, url, proc(e: baldr.Ev(baldr.Url_Opened)) -> Msg { return Opened{e.value.ok} })
		},
		update = proc(s: ^int, m: Msg) -> baldr.Cmd(Msg) {
			switch v in m {
			case Opened:
				say("opened" if v.ok else "not opened")
				return baldr.quit(Msg)
			case Quit:
				return baldr.quit(Msg)
			}
			return {}
		},
		view = proc(s: ^int, ui: ^baldr.Ui(Msg)) {
			baldr.column(ui, padding = .lg); defer baldr.end(ui)
			baldr.text(ui, "Asking the desktop to open a link…")
		},
	})
}

say :: proc(line: string) {
	fmt.println(line)
	os.flush(os.stdout)
}
