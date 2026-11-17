// enter_chord — does a real Alt+Enter reach the app rather than opening a row?
//
// The table's side is tested headlessly through `key_event`, the same entry
// point the backend calls, so what is left to check is the layer below it:
// that a keyboard's Alt actually arrives in `mods` on a live compositor, so
// `shortcut_bound` has something to match. Run it in the nested harness,
// press Alt+Enter, then Enter, and read which line it prints.
//
//	./build.sh spike enter_chord
package main

import "core:fmt"
import "baldr:baldr"

State :: struct {
	sel:  baldr.Selection,
	last: string,
}

Msg :: union {
	Open,
	Props,
}

Open  :: struct { row: int }
Props :: struct {}

COLS := []baldr.Column{
	{title = "Name"},
	{title = "Size", width = 80, numeric = true},
}

init :: proc() -> (s: State) {
	s.sel = baldr.selection_make(multi = true)
	s.last = "nothing yet"
	return
}

update :: proc(s: ^State, msg: Msg) -> baldr.Cmd(Msg) {
	switch m in msg {
	case Open:
		s.last = "the row was opened"
		fmt.println("ACTION: OPEN row", m.row)
	case Props:
		s.last = "properties"
		fmt.println("ACTION: PROPERTIES")
	}
	return {}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.shortcut(ui, "Alt+Enter", Msg(Props{}))
	baldr.column(ui, flex = 1, padding = .md, gap = .sm); defer baldr.end(ui)
	baldr.text(ui, s.last, role = .Title)
	first, last := baldr.table(ui, COLS, 20, &s.sel,
		on_activate = proc(e: baldr.Ev(int)) -> Msg { return Open{e.value} },
		label = "Files", flex = 1)
	for i in first ..< last {
		baldr.table_row(ui, i)
		baldr.cell_text(ui, fmt.tprintf("file-%02d", i))
		baldr.cell_text(ui, fmt.tprintf("%d KB", i * 7))
		baldr.end(ui)
	}
	baldr.end(ui)
}

main :: proc() {
	err := baldr.run(baldr.App(State, Msg){
		title = "Enter and a chord", app_id = "dev.baldr.enterchord", size = {700, 480},
		init = init, update = update, view = view,
	})
	if err != .None do fmt.eprintln("exit:", err)
}
