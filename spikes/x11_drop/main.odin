// x11_drop — does a drag from another program land in a Baldr window?
//
// A file dragged from another app should land in the window. The gallery
// can show it only on one of its pages, and driving it there is a
// navigation problem rather than a backend one; this is the whole window as
// one drop target, so a drop either arrives or does not.
//
//   tools/nested-x.sh start
//   BALDR_X11_DEBUG=1 tools/nested-x.sh run x11_drop
//   DISPLAY=:2 build/x11_check --drag <window-id> <x> <y> text/uri-list "file:///tmp/a.txt"
//
// It prints what it received, and keeps the last drop on screen.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "baldr:baldr"

State :: struct {
	said:  string,
	over:  bool,
	drops: int,
}

Msg :: union { Dropped, Over }
Dropped :: struct { d: baldr.Drop }
Over    :: struct { on: bool }

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "drop here", app_id = "baldr.drop", size = {520, 360},
		init = proc() -> State { return {said = "drag something onto this window"} },
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			switch v in m {
			case Over:
				s.over = v.on
			case Dropped:
				s.drops += 1
				b := strings.builder_make()
				fmt.sbprintfln(&b, "drop %d: kind %q, %d file(s), at %v", s.drops, v.d.kind, len(v.d.files), v.d.at)
				for f in v.d.files do fmt.sbprintfln(&b, "  %s", f)
				s.said = strings.to_string(b)
				fmt.print(s.said)
				os.flush(os.stdout)
			}
			return {}
		},
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			baldr.column(ui, flex = 1, padding = .lg, gap = .md); defer baldr.end(ui)
			baldr.text(ui, "Drop target", role = .Headline)
			baldr.text(ui, s.said, muted = true)
			zone := baldr.card(ui, flex = 1, gap = .sm); {
				defer baldr.end(ui)
				baldr.text(ui, "over: files welcome here" if s.over else "the whole card takes files", muted = true)
			}
			baldr.drop_target(ui, zone,
				proc(e: baldr.Ev(baldr.Drop)) -> Msg { return Dropped{e.value} },
				accepts = "files",
				on_over = proc(e: baldr.Ev(baldr.Drag_Over)) -> Msg { return Over{true} })
		},
	})
}
