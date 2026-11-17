// menu_on_paper: does a glass menu read over the app's own white page?
//
// Glass raises its tint as far as its text needs over what the compositor
// reports behind the window, but a menu opened inside the window sits over
// the app's page, which no report describes. Such a popup is solved for the
// worst case; this is the live check, on a Dim theme at Frosted glass.
//
//	./build.sh spike menu_on_paper            # then, in the nested harness:
//	compositor-msg seat click 3 <x> <y>          # right click the page
//	compositor-msg capture region <x,y wxh>      # composited: what a person sees
package main

import "core:fmt"
import "baldr:baldr"

State :: struct {
	menu: bool,
}

Msg :: union {
	Open_Menu,
	Close_Menu,
	Pick,
}

Open_Menu  :: struct {}
Close_Menu :: struct {}
Pick       :: struct { what: string }

update :: proc(s: ^State, msg: Msg) -> baldr.Cmd(Msg) {
	switch m in msg {
	case Open_Menu:
		s.menu = true
	case Close_Menu:
		s.menu = false
	case Pick:
		fmt.println("PICKED:", m.what)
		s.menu = false
	}
	return {}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	th := ui.tree.theme
	baldr.row(ui, flex = 1); defer baldr.end(ui)

	// A sidebar, left to the window's own glass: the wallpaper shows here.
	baldr.column(ui, width = 170, padding = .md, gap = .sm)
	baldr.text(ui, "Pages", role = .Title)
	baldr.text(ui, fmt.tprintf("window tint %.2f", th.material[th.glass].popover.tint.a), muted = true)
	baldr.end(ui)

	// The page: the app's own white paper, as a document viewer draws it.
	page := baldr.column(ui, flex = 1, padding = .lg, gap = .md, bg = baldr.Color{1, 1, 1, 1})
	baldr.context_area(ui, page, Msg(Open_Menu{}))
	baldr.text(ui, "A page of a document", role = .Title, color = baldr.Color{0.05, 0.05, 0.06, 1})
	baldr.text(ui, "Right click anywhere on the paper.", color = baldr.Color{0.12, 0.12, 0.14, 1})
	baldr.end(ui)

	if baldr.context_menu(ui, s.menu, Msg(Close_Menu{})) {
		defer baldr.end(ui)
		baldr.menu_item(ui, "Copy", Msg(Pick{"Copy"}), shortcut = "Ctrl+C")
		baldr.menu_item(ui, "Select All", Msg(Pick{"Select All"}), shortcut = "Ctrl+A")
		baldr.separator(ui)
		baldr.menu_item(ui, "Add Note", Msg(Pick{"Add Note"}))
		baldr.menu_item(ui, "Rotate", Msg(Pick{"Rotate"}), disabled = true)
	}
}

surfaces :: proc(s: ^State, out: ^[dynamic]baldr.Surface_Desc(Msg)) {
	append(out, baldr.Surface_Desc(Msg){
		tag = 1, kind = .Window, title = "A document", size = {900, 620},
		transparent = true, backdrop = .Blur, // glass: the desktop shows through the window
		clear = baldr.Color{0, 0, 0, 0},
	})
}

main :: proc() {
	err := baldr.run(baldr.App(State, Msg){
		app_id   = "dev.baldr.menu_on_paper",
		title    = "A document",
		theme    = baldr.theme_dim(),
		update   = update,
		view     = view,
		surfaces = surfaces,
	})
	if err != .None do fmt.eprintln("exit:", err)
}
