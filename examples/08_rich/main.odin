// 08_rich — the rich text editor: headings, lists, quotes, code blocks,
// links and inline marks on the shared Document, with markdown in and out.
//
//   ./build.sh example 08_rich run
package main

import "core:fmt"
import "baldr:baldr"

State :: struct {
	doc:  baldr.Document,
	link: string, // the link last followed
}
Msg :: union { Edited, Followed, Export }
Edited   :: struct { version: int }
Followed :: struct { href: string }
Export   :: struct {}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch v in m {
	case Edited:
	case Followed: s.link = v.href
	case Export:   fmt.print(baldr.document_markdown(&s.doc, context.temp_allocator))
	}
	return {}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, flex = 1, padding = .lg, gap = .md); defer baldr.end(ui)
	baldr.row(ui, align = .Center, gap = .md); {
		defer baldr.end(ui)
		baldr.text(ui, "Notes", role = .Title)
		if len(s.link) > 0 do baldr.text(ui, fmt.tprintf("followed %s", s.link), role = .Caption, muted = true)
		baldr.spacer(ui)
		baldr.button(ui, "Print markdown", Msg(Export{}), icon = .File_Code, variant = .Secondary)
	}
	baldr.rich_text(ui, &s.doc, proc(e: baldr.Ev(int)) -> Msg { return Edited{e.value} }, label = "Notes", flex = 1,
		on_link = proc(e: baldr.Ev(string)) -> Msg { return Followed{e.value} })
}

init :: proc() -> State {
	s: State
	s.doc = baldr.document_make("")
	baldr.document_set_markdown(&s.doc, "# Shopping\n\n- [ ] Bread\n- [x] Milk\n\nSee the [list](https://example.org).")
	return s
}

main :: proc() {
	err := baldr.run(baldr.App(State, Msg){title = "Rich text", app_id = "baldr.rich", size = {720, 560}, init = init, update = update, view = view})
	if err != .None do fmt.eprintln("exit:", err)
}
