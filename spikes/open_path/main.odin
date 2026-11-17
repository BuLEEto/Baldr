// open_path, against the desktop's own portal: open a file this app made
// with the person's app for it, and show it in its folder.
//
// It writes a small CSV into build/ and offers the two buttons. The portal
// is handed an open *descriptor*, not a path, so this is the only way to
// know the fd actually crosses the socket.
//
//   ./build.sh spike open_path run
//   BALDR_OPEN=<path> ./build/open_path   (use a file of your own)
package main

import "core:fmt"
import "core:os"
import "baldr:baldr"

State :: struct {
	path: string,
	said: string,
}

Msg :: union { Open, Reveal, Done }
Open   :: struct {}
Reveal :: struct {}
Done   :: struct { it: baldr.Path_Opened, reveal: bool }

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "open_path", app_id = "baldr.openpath", size = {520, 220},
		init = proc() -> State {
			path := os.get_env("BALDR_OPEN", context.allocator)
			if path == "" {
				_ = os.make_directory("build")
				path = "build/open_path_probe.csv"
				_ = os.write_entire_file(path, transmute([]u8)string("depot,stops\nD1,3\nD2,2\n"))
			}
			fmt.printfln("path: %s (openable: %v)", path, baldr.path_openable(path))
			return {path = path, said = "waiting"}
		},
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			switch v in m {
			case Open:
				s.said = "asking the desktop to open it…"
				return baldr.open_path(Msg, s.path, proc(e: baldr.Ev(baldr.Path_Opened)) -> Msg {
					return Done{e.value, false}
				})
			case Reveal:
				s.said = "asking the desktop to show it…"
				return baldr.reveal_path(Msg, s.path, proc(e: baldr.Ev(baldr.Path_Opened)) -> Msg {
					return Done{e.value, true}
				})
			case Done:
				what := "show" if v.reveal else "open"
				s.said = fmt.aprintf("%s: %s", what, "the desktop took it" if v.it.ok else "refused")
				fmt.printfln("%s %q → %v", what, v.it.path, v.it.ok)
			}
			return {}
		},
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			baldr.column(ui, gap = .md, padding = .lg, flex = 1); {
				defer baldr.end(ui)
				baldr.text(ui, "Open a file this app made", role = .Headline)
				baldr.text(ui, s.path, muted = true)
				baldr.row(ui, gap = .sm); {
					defer baldr.end(ui)
					baldr.button(ui, "Open", Msg(Open{}), icon = .File)
					baldr.button(ui, "Show in folder", Msg(Reveal{}), variant = .Outline, icon = .Folder_Open)
				}
				baldr.text(ui, s.said, muted = true)
			}
		},
	})
}
