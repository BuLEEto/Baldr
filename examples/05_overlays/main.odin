// 05_overlays — select, menu, tooltips, a card that takes a click and a modal dialog. Open state lives
// in the app for menu/dialog (a dismiss message closes them); select and
// tooltips keep their own.
//
//   ./build.sh example 05_overlays run
package main

import "core:fmt"
import "baldr:baldr"

FRUIT := []string{"Apple", "Banana", "Cherry", "Dragon fruit", "Elderberry"}

State :: struct {
	fruit:    int,
	menu:     bool,
	confirm:  bool,
	deleted:  int,
	last:     string,
}

Msg :: union {
	Pick,
	Menu,
	Confirm,
	Delete,
	Act,
}
Pick    :: struct { i: int }
Menu    :: struct { open: bool }
Confirm :: struct { open: bool }
Delete  :: struct {}
Act     :: struct { what: string }

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch v in m {
	case Pick:    s.fruit = v.i
	case Menu:    s.menu = v.open
	case Confirm: s.confirm = v.open; s.menu = false
	case Delete:  s.deleted += 1; s.confirm = false
	case Act:     s.last = v.what; s.menu = false
	}
	return {}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, flex = 1, padding = .xl, gap = .lg); defer baldr.end(ui)
	baldr.text(ui, "Overlays", role = .Headline)

	baldr.card(ui, gap = .md); {
		defer baldr.end(ui)
		baldr.text(ui, "Select", role = .Title)
		baldr.row(ui, align = .Center, gap = .md); {
			defer baldr.end(ui)
			baldr.text(ui, "Favourite fruit", muted = true)
			baldr.select(ui, s.fruit, FRUIT, proc(e: baldr.Ev(int)) -> Msg { return Pick{e.value} }, label = "Favourite fruit", width = 220)
		}
		baldr.text(ui, fmt.tprintf("You picked %s.", FRUIT[s.fruit]), role = .Label, muted = true)
	}

	baldr.card(ui, gap = .md); {
		defer baldr.end(ui)
		baldr.text(ui, "Popover menu", role = .Title)
		baldr.row(ui, align = .Center, gap = .md); {
			defer baldr.end(ui)
			more := baldr.button(ui, "Actions…", Msg(Menu{true}), variant = .Outline)
			baldr.tooltip(ui, more, "Rename, duplicate or delete the file")
			baldr.text(ui, s.last == "" ? "Nothing chosen yet." : fmt.tprintf("Last: %s", s.last), muted = true)
			if baldr.menu(ui, more, s.menu, Msg(Menu{false})) {
				defer baldr.end(ui)
				baldr.menu_item(ui, "Rename", Msg(Act{"Rename"}), shortcut = "F2")
				baldr.menu_item(ui, "Duplicate", Msg(Act{"Duplicate"}), shortcut = "Ctrl+D")
				baldr.separator(ui)
				baldr.menu_item(ui, "Delete…", Msg(Confirm{true}), shortcut = "Del")
			}
		}
	}

	baldr.card(ui, gap = .md); {
		defer baldr.end(ui)
		baldr.text(ui, "Dialog", role = .Title)
		baldr.row(ui, align = .Center, gap = .md); {
			defer baldr.end(ui)
			del := baldr.button(ui, "Delete file…", Msg(Confirm{true}), variant = .Danger)
			baldr.tooltip(ui, del, "Asks first — nothing is deleted without confirming")
			baldr.text(ui, fmt.tprintf("Deleted %d file(s).", s.deleted), muted = true)
		}
	}

	baldr.card(ui, gap = .md); {
		defer baldr.end(ui)
		baldr.text(ui, "Clickable card", role = .Title)
		note := baldr.card(ui, gap = .xs, padding = .md, elevation = .Low); { // the note
			defer baldr.end(ui)
			baldr.clickable(ui, note, Msg(Act{"Opened the message"}), label = "Ada: Lunch at one?") // the whole card takes a click
			baldr.row(ui, align = .Center, gap = .sm); {
				defer baldr.end(ui)
				baldr.column(ui, flex = 1, gap = .xxs); {
					defer baldr.end(ui)
					baldr.text(ui, "Ada", role = .Label)
					baldr.text(ui, "Lunch at one?", muted = true)
				}
				baldr.button(ui, "Dismiss", Msg(Act{"Dismissed the message"}), variant = .Ghost, icon = .X, icon_only = true) // keeps its own click
			}
		}
	}

	if baldr.dialog(ui, s.confirm, Msg(Confirm{false}), title = "Delete this file?") {
		defer baldr.end(ui)
		baldr.text(ui, "The file is moved to the bin. You can restore it from there for 30 days.")
		baldr.row(ui, gap = .sm, justify = .End); {
			defer baldr.end(ui)
			baldr.button(ui, "Cancel", Msg(Confirm{false}), variant = .Outline)
			baldr.button(ui, "Delete", Msg(Delete{}), variant = .Danger)
		}
	}
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title  = "Baldr — overlays",
		app_id = "dev.baldr.overlays",
		size   = {640, 520},
		init   = proc() -> State { return {fruit = 2} },
		update = update,
		view   = view,
	})
}
