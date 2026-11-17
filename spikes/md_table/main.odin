// md_table: a wide markdown table in a narrow column.
//
// It shows a file in a `markdown_view` at a chat column's width (760 px),
// so a table with long cells can be looked at: every
// column inside the view, cell text wrapped within its column, rows as tall
// as their tallest cell, and `<br>` inside a cell as a line break.
//
//   ./build.sh spike md_table run
//   BALDR_MD=<file> ./build/md_table
package main

import "core:fmt"
import "core:os"
import "baldr:baldr"

DEFAULT :: "docs/widgets.md" // any markdown file with a table in it

// A hard table for when the file is not there: four columns, one of them
// long prose, and `<br>`s in the second.
FALLBACK :: `# A wide table in a narrow column

| Day | Route(s) | Depot Stops (stops per depot per day) | Notes |
|-----|----------|--------------------------------------|-------|
| Mon | R1: D1→D2→D3<br>R4: D4→D5→D6 | 2–3 each | High-priority stops first on each leg. |
| Tue | R2: D1→D6→D5<br>R3: D2→D3→D4 | 2–3 each | Alternate pairing to spread traffic load. |
| Wed | R1 + R2 | Same as Mon/Tue but with priority reordering based on SLA deadlines. | Use for same-day delivery windows. |
`

State :: struct {
	doc:  baldr.Markdown_Doc,
	wide: bool, // the view at 760 px, or half of it
}

Msg :: union { Width }
Width :: struct { wide: bool }

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Markdown tables", app_id = "baldr.mdtable", size = {820, 1000},
		init = proc() -> State {
			s := State{wide = true}
			path := os.get_env("BALDR_MD", context.temp_allocator)
			if path == "" do path = DEFAULT
			src, rerr := os.read_entire_file(path, context.allocator)
			if rerr == nil && len(src) > 0 {
				baldr.md_set(&s.doc, string(src))
				fmt.printfln("showing %s (%d bytes)", path, len(src))
			} else {
				baldr.md_set(&s.doc, FALLBACK)
				fmt.printfln("no %s: showing the built-in table", path)
			}
			return s
		},
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			switch v in m {
			case Width: s.wide = v.wide
			}
			return {}
		},
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			baldr.column(ui, gap = .md, padding = .lg, flex = 1); {
				defer baldr.end(ui)
				baldr.row(ui, gap = .sm); {
					defer baldr.end(ui)
					baldr.toggle(ui, s.wide, "760 px column", proc(e: baldr.Ev(bool)) -> Msg { return Width{e.value} })
				}
				sc := baldr.scroll(ui, flex = 1); {
					defer baldr.end(ui)
					_ = sc
					baldr.markdown_view(ui, &s.doc, label = "Reply", width = 760 if s.wide else 380)
				}
			}
		},
	})
}
