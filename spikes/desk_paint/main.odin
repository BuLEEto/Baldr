package main

// A placed icon_view must draw on a surface cleared to transparent. The 2×2
// in one binary — a full-screen layer surface at the bottom level, as a
// desktop is:
//
//   build/desk_paint              placed, transparent
//   SPIKE_FLOW=1   build/desk_paint   flow, transparent
//   SPIKE_OPAQUE=1 build/desk_paint   placed, opaque
//   SPIKE_FLOW=1 SPIKE_OPAQUE=1 …     flow, opaque

import "core:fmt"
import "core:os"
import "baldr:baldr"

NAMES := [6]string{"Notes.md", "Budget.ods", "Plan.pdf", "Today", "Screenshots", "holiday.jpg"}

State :: struct {
	sel:  baldr.Selection,
	menu: bool,
	flow: bool,
	over: bool, // SPIKE_OVER: the labels say they are over something the app does not control
}

Msg :: enum { None, Open_Menu, Close_Menu }

place_of :: proc(user: rawptr, index: int) -> [2]int { return {-1, -1} } // all unplaced

// pale_or_dark: SPIKE_PALE stands in for a light wallpaper.
pale_or_dark :: proc(opaque, pale: bool) -> baldr.Color {
	if pale do return {0.965, 0.965, 0.949, 1}
	return baldr.Color{0.1, 0.2, 0.1, 1} if opaque else baldr.Color{0, 0, 0, 0}
}

surfaces :: proc(s: ^State, out: ^[dynamic]baldr.Surface_Desc(Msg)) {
	append(out, baldr.Surface_Desc(Msg){
		tag = 1, kind = .Layer, title = "Desk", size = {0, 0},
		layer = {level = .Bottom, anchor = {.Top, .Bottom, .Left, .Right}, keyboard = .On_Demand},
		transparent = true, backdrop = .None, input = .All,
	})
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, flex = 1, padding = .md); defer baldr.end(ui)
	// a menu opened from a surface that asks for no blur of its own (a
	// desktop is the wallpaper) must still be glass
	if baldr.context_menu(ui, s.menu, Msg.Close_Menu) {
		defer baldr.end(ui)
		baldr.menu_item(ui, "New folder", Msg.None)
		if baldr.submenu(ui, "Icon size") {
			defer baldr.end(ui)
			baldr.menu_item(ui, "Small", Msg.None)
			baldr.menu_item(ui, "Medium", Msg.None)
			baldr.menu_item(ui, "Large", Msg.None)
		}
		baldr.menu_item(ui, "Change wallpaper…", Msg.None)
	}
	first, last := baldr.icon_view(ui, len(NAMES), &s.sel,
		place_of = nil if s.flow else place_of,
		on_context = proc(e: baldr.Ev(int)) -> Msg { return .Open_Menu },
		drag = "files", // so the ghost has something to carry
		label_over = .Anything if s.over else .Surface, label = "Desktop")
	defer baldr.end(ui)
	for i in first ..< last do baldr.icon_item(ui, i, .File, NAMES[i])
}

main :: proc() {
	flow := os.get_env("SPIKE_FLOW", context.temp_allocator) != ""
	opaque := os.get_env("SPIKE_OPAQUE", context.temp_allocator) != ""
	pale := os.get_env("SPIKE_PALE", context.temp_allocator) != ""
	fmt.eprintfln("desk_paint: %s, %s surface", "flow" if flow else "placed", "opaque" if opaque else "transparent")
	baldr.run(baldr.App(State, Msg){
		title = "Desk", app_id = "dev.baldr.desk_paint", size = {1280, 720},
		clear = pale_or_dark(opaque, pale),
		theme = baldr.theme_dark(), // near-white label ink: the hard case over SPIKE_PALE's wallpaper
		init = proc() -> State {
			return {
				sel = baldr.selection_make(multi = true),
				flow = os.get_env("SPIKE_FLOW", context.temp_allocator) != "",
				over = os.get_env("SPIKE_OVER", context.temp_allocator) != "",
			}
		},
		surfaces = surfaces, view = view,
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			#partial switch m {
			case .Open_Menu:  s.menu = true
			case .Close_Menu: s.menu = false
			}
			return {}
		},
	})
}
