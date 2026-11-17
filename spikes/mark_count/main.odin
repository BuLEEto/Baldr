package main

// A running-app mark that says how many windows. Three dock
// buttons with one, two and three windows, marks on the bottom edge, and a
// side-bar column with the marks on the left edge.

import "baldr:baldr"

Msg :: enum { None }

view :: proc(s: ^int, ui: ^baldr.Ui(Msg)) {
	baldr.row(ui, gap = .xl, padding = .xl, align = .Center); defer baldr.end(ui)
	icons := [3]baldr.Icon{.Folder, .File_Text, .Terminal}
	{
		baldr.row(ui, gap = .sm, padding = .sm, bg = ui.theme.color.surface_high, radius = 14, key = 1); defer baldr.end(ui)
		for ic, i in icons {
			b := baldr.button(ui, "App", Msg.None, icon = ic, icon_only = true, variant = .Ghost, key = u64(i + 1))
			baldr.button_options(ui, b, mark = baldr.Button_Mark{side = .Bottom, length = 14, count = i + 1})
		}
	}
	{
		baldr.column(ui, gap = .sm, padding = .sm, bg = ui.theme.color.surface_high, radius = 14, key = 2); defer baldr.end(ui)
		for ic, i in icons {
			b := baldr.button(ui, "App", Msg.None, icon = ic, icon_only = true, variant = .Ghost, key = u64(i + 10))
			baldr.button_options(ui, b, mark = baldr.Button_Mark{side = .Left, length = 14, count = i + 1})
		}
	}
}

main :: proc() {
	baldr.run(baldr.App(int, Msg){
		title = "Marks", app_id = "dev.baldr.mark_count", size = {420, 260},
		init = proc() -> int { return 0 }, view = view,
		update = proc(s: ^int, m: Msg) -> baldr.Cmd(Msg) { return {} },
	})
}
