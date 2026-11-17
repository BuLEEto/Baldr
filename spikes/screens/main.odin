// screens: what does this platform say about the monitors?
//
// It prints `baldr.outputs()` on whatever platform it is built for, so the
// platforms can be compared: once, to stdout and to `BALDR_SCREENS_LOG` when
// that is set, then quits. The file matters on Windows: a process started
// over SSH lands in session 0 with no desktop, so the real check runs as a
// scheduled task in the interactive session, where stdout goes nowhere.
//
//   ./build.sh spike screens run
//
// A line per screen, then its description on the next, for example:
//
//   DP-1  pos 2560,0  size 2560x1440  mode 2560x1440  scale 1.00  119998 mHz  Normal
//   DP-2  pos 0,0     size 2560x1440  mode 2560x1440  scale 1.00  119998 mHz  Normal  *primary
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "baldr:baldr"

State :: struct { done: bool }
Msg :: union { Go }
Go :: struct {}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "screens", app_id = "baldr.screens", size = {360, 120},
		init = proc() -> State { return {} },
		start = proc(s: ^State) -> baldr.Cmd(Msg) { return baldr.delay(Msg, 300, Go{}) },
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			if s.done do return {}
			s.done = true
			report()
			return baldr.quit(Msg)
		},
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			baldr.column(ui, flex = 1, padding = .lg); defer baldr.end(ui)
			baldr.text(ui, "reading the screens…", role = .Headline)
		},
	})
}

report :: proc() {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	outs := baldr.outputs()
	fmt.sbprintfln(&b, "%d screen(s)", len(outs))
	for o in outs {
		fmt.sbprintfln(&b, "%-14s pos %d,%d  size %dx%d  mode %dx%d  scale %.2f  %d mHz  %v%s",
			o.name, o.pos.x, o.pos.y, o.size.x, o.size.y, o.mode_px.x, o.mode_px.y,
			o.scale, o.refresh, o.transform, "  *primary" if o.primary else "")
		if o.description != "" do fmt.sbprintfln(&b, "%-14s %s", "", o.description)
	}
	text := strings.to_string(b)
	fmt.print(text)
	os.flush(os.stdout)
	if path := os.get_env("BALDR_SCREENS_LOG", context.temp_allocator); path != "" {
		_ = os.write_entire_file(path, transmute([]u8)text)
	}
}
