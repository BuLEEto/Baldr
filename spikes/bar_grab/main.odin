package main

// Can an editor's scroll bar be grabbed?
//
// A 400-line document in a small text area. Drag the bar along the right
// edge: the document should scroll and nothing should be selected. A text
// area is itself the `.Scroll_V` node, so a press in its bar zone must grab
// the bar rather than place the caret.
//
//   ./build.sh spike bar_grab run
//   …then drag from <x>,<y> to <x>,<y2> over `baldr.bar_grab` with whatever
//   synthetic-input tool the compositor offers

import "core:fmt"
import "core:strings"
import "baldr:baldr"

State :: struct { doc: baldr.Document }
Msg :: enum { None }

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Bar grab", app_id = "baldr.bar_grab", size = {560, 420},
		init = proc() -> (s: State) {
			b: strings.Builder
			strings.builder_init(&b)
			defer strings.builder_destroy(&b)
			for i in 1 ..= 400 do fmt.sbprintf(&b, "line %d — the quick brown fox jumps over the lazy dog\n", i)
			s.doc = baldr.document_make(strings.to_string(b))
			return
		},
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			baldr.column(ui, flex = 1, padding = .md); defer baldr.end(ui)
			baldr.text_area(ui, &s.doc, label = "Lines", flex = 1)
		},
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) { return {} },
	})
}
