// watch: does the `watch` subscription report what happens in a folder?
//
// A subscription that never fires looks exactly like a folder that never
// changes, so this prints what arrives, for comparing platforms against the
// same sequence of changes.
//
// It watches the folder named by `BALDR_WATCH_DIR` (or the first argument)
// and prints every change until it has been quiet for three seconds, then
// quits — to stdout and to `BALDR_WATCH_LOG` when that is set, since a
// scheduled task's stdout goes nowhere on Windows.
//
//   mkdir -p /tmp/wd && ./build.sh spike watch run /tmp/wd &
//   sleep 1; touch /tmp/wd/a.txt; echo hi >> /tmp/wd/a.txt; rm /tmp/wd/a.txt
//
// Linux and Windows report the same events in the same order for that:
//
//   a.txt        Created
//   a.txt        Modified
//   a.txt        Modified
//   a.txt        Removed
//
// Watching a single file instead (an edit, then a sibling written, then a
// save-and-rename over it) the sibling is ignored on both, and
// `name` is "" because the caller already knows it. Windows is the more
// granular of the two about the rename:
//
//   Linux    (the path) Modified, (the path) Created
//   Windows  (the path) Modified, Removed, Created, Modified
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "baldr:baldr"

State :: struct {
	dir:   string,
	seen:  int,
	lines: strings.Builder,
	idle:  int,
}

Msg :: union { Changed, Tick }
Changed :: struct { c: baldr.File_Change }
Tick    :: struct {}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "watch", app_id = "baldr.watch", size = {420, 140},
		init = proc() -> State {
			dir := os.get_env("BALDR_WATCH_DIR", context.allocator)
			if dir == "" && len(os.args) > 1 do dir = os.args[1]
			return {dir = dir, lines = strings.builder_make()}
		},
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			switch v in m {
			case Changed:
				s.seen += 1
				s.idle = 0
				fmt.sbprintfln(&s.lines, "%-12s %v", v.c.name if v.c.name != "" else "(the path)", v.c.kind)
			case Tick:
				s.idle += 1
				// Three quiet seconds after something arrived, or twelve with
				// nothing at all, is the end of the run either way.
				if (s.seen > 0 && s.idle >= 3) || s.idle >= 12 {
					report(s)
					return baldr.quit(Msg)
				}
			}
			return {}
		},
		subscriptions = proc(s: ^State, out: ^[dynamic]baldr.Sub(Msg)) {
			append(out, baldr.every(Msg, 1000, Tick{}))
			if s.dir != "" {
				append(out, baldr.watch(Msg, s.dir,
					proc(e: baldr.Ev(baldr.File_Change)) -> Msg { return Changed{e.value} }))
			}
		},
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			baldr.column(ui, flex = 1, padding = .lg, gap = .sm); defer baldr.end(ui)
			baldr.text(ui, "watching", role = .Headline)
			baldr.text(ui, fmt.tprintf("%s — %d change(s)", s.dir, s.seen), muted = true)
		},
	})
}

report :: proc(s: ^State) {
	text := strings.to_string(s.lines)
	if text == "" do text = "nothing arrived\n"
	fmt.printf("watching %s\n%s", s.dir, text)
	os.flush(os.stdout)
	if path := os.get_env("BALDR_WATCH_LOG", context.temp_allocator); path != "" {
		out := fmt.tprintf("watching %s\n%s", s.dir, text)
		_ = os.write_entire_file(path, transmute([]u8)out)
	}
}
