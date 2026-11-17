package main

// What a search_field looks like empty, with text, focused and
// disabled, beside a plain text_input for comparison.
//
//	./build.sh spike search_box run

import "core:fmt"
import "baldr:baldr"

Msg :: union { Changed, Submitted, Cancelled }
Changed   :: struct { text: string }
Submitted :: struct { text: string }
Cancelled :: struct {}

State :: struct {
	empty, filled, disabled: baldr.Text,
	plain:  baldr.Text,
	last:   string,
	events: int,
	made:   bool,
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Search box", app_id = "baldr.search_box", size = {420, 340},
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			switch v in m {
			case Changed:   s.last = "changed"; s.events += 1; fmt.printfln("changed %q", v.text)
			case Submitted: s.last = "submitted"; s.events += 1; fmt.printfln("submitted %q", v.text)
			case Cancelled: s.last = "cancelled"; s.events += 1; fmt.println("cancelled")
			}
			return {}
		},
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			if !s.made {
				baldr.text_set(&s.filled, "ada lovelace")
				baldr.text_set(&s.disabled, "cannot touch this")
				s.made = true
			}
			baldr.column(ui, padding = .lg, gap = .md); defer baldr.end(ui)
			baldr.text(ui, "search_field", role = .Title)

			baldr.text(ui, "empty — no cross", role = .Caption, muted = true)
			baldr.search_field(ui, &s.empty,
				on_change = proc(e: baldr.Ev(string)) -> Msg { return Changed{e.value} },
				on_submit = proc(e: baldr.Ev(string)) -> Msg { return Submitted{e.value} },
				on_cancel = Msg(Cancelled{}), width = 260, key = 1)

			baldr.text(ui, "with text — the cross appears", role = .Caption, muted = true)
			baldr.search_field(ui, &s.filled,
				on_change = proc(e: baldr.Ev(string)) -> Msg { return Changed{e.value} },
				width = 260, key = 2)

			baldr.text(ui, "disabled", role = .Caption, muted = true)
			baldr.search_field(ui, &s.disabled, disabled = true, width = 260, key = 3)

			baldr.text(ui, "a plain text_input, for comparison", role = .Caption, muted = true)
			baldr.text_input(ui, &s.plain, placeholder = "Name", width = 260, key = 4)

			baldr.text(ui, fmt.tprintf("%d events, last: %s", s.events, s.last), role = .Caption, muted = true)
		},
	})
}
