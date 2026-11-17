// 15_control_centre — the tiles of a desktop's Control Centre:
// tiles in the theme's fill, round icon toggles (Wi-Fi with its network and
// an arrow to its page, Do Not Disturb with its name under it), large
// sliders whose icon follows the value (muted at 0), and the power mode as a
// segmented control with icons. A four-column grid of 1-, 2- and 4-wide
// tiles, 10 px apart, as a shell's Control Centre lays them out; above it
// the bar button that opens it (Wi-Fi, sound and battery in one button). The
// Sound tile's arrow opens its page in place (pages): the outputs and a VPN
// tunnel as rows, with Back to the tiles.
//
//   ./build.sh example 15_control_centre run
//   build/15_control_centre --dark     # or --light, --dim
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "baldr:baldr"

GRID :: f32(352) // the popover's 376 px less its padding
GAP  :: f32(10)
UNIT :: (GRID - 3 * GAP) / 4

State :: struct {
	wifi, bluetooth, dnd, night, airplane: bool,
	volume, brightness:                    f32,
	power:                                 int,
	output:                                int,
	tunnel:                                bool,
	outputs_open:                          bool, // the Sound tile's output menu
	muted:                                 bool, // the Sound slider's icon
	page:                                  u64, // 0 the tiles, 1 the Sound page
}

Flip :: struct { which: int, on: bool }
Level :: struct { which: int, value: f32 }
Power :: struct { mode: int }
Output :: struct { index: int }
Tunnel :: struct {}
Open_Page :: struct { page: u64 }
Outputs :: struct { open: bool }
Mute :: struct {}
Msg :: union { Flip, Level, Power, Output, Tunnel, Open_Page, Outputs, Mute }

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch v in m {
	case Flip:
		switch v.which {
		case 0: s.wifi = v.on
		case 1: s.bluetooth = v.on
		case 2: s.dnd = v.on
		case 3: s.night = v.on
		case 4: s.airplane = v.on
		}
	case Level:
		if v.which == 0 { s.volume = v.value } else { s.brightness = v.value }
	case Power:
		s.power = v.mode
	case Output:
		s.output = v.index
		s.outputs_open = false
	case Outputs:
		s.outputs_open = v.open
	case Mute:
		s.muted = !s.muted
	case Tunnel:
		s.tunnel = !s.tunnel
	case Open_Page:
		s.page = v.page
	}
	return {}
}

// wide_tile: a toggle with its title, what it is on (a network, devices), and an arrow to its page.
wide_tile :: proc(ui: ^baldr.Ui(Msg), which: int, icon: baldr.Icon, on: bool, title, detail: string) {
	baldr.row(ui, width = 2 * UNIT + GAP, height = 60, padding = .sm, gap = .sm, align = .Center, bg = ui.tree.theme.color.fill, radius = 16, key = u64(which + 1)); {
		defer baldr.end(ui)
		flip := proc(e: baldr.Ev(bool)) -> Msg { return Flip{int(e.tag), e.value} }
		baldr.icon_toggle(ui, icon, on, title, flip, tag = u64(which))
		baldr.column(ui, flex = 1); {
			defer baldr.end(ui)
			baldr.text(ui, title, role = .Label, nowrap = true, ellipsis = .End)
			baldr.text(ui, detail, muted = true, nowrap = true, ellipsis = .End)
		}
		baldr.button(ui, fmt.tprintf("%s settings", title), Msg(Flip{which, on}), variant = .Ghost, icon = .Chevron_Right, icon_only = true, size = .Small)
	}
}

// square_tile: a toggle with its name under it.
square_tile :: proc(ui: ^baldr.Ui(Msg), which: int, icon: baldr.Icon, on: bool, name: string) {
	baldr.column(ui, width = UNIT, height = 82, gap = .xs, align = .Center, justify = .Center, bg = ui.tree.theme.color.fill, radius = 16, key = u64(which + 1)); {
		defer baldr.end(ui)
		baldr.icon_toggle(ui, icon, on, name, proc(e: baldr.Ev(bool)) -> Msg { return Flip{int(e.tag), e.value} }, tag = u64(which))
		baldr.text(ui, name, align = .Center, max_lines = 2)
	}
}

// level_tile: a large slider under its title, and an arrow to its page when it has one; the Sound
// tile's output as a menu chip (s given) that opens a menu of the outputs.
level_tile :: proc(ui: ^baldr.Ui(Msg), which: int, title: string, value: f32, icon: baldr.Icon, page: u64 = 0, s: ^State = nil) {
	baldr.column(ui, width = GRID, padding = .sm, gap = .sm, bg = ui.tree.theme.color.fill, radius = 16, key = u64(which + 20)); {
		defer baldr.end(ui)
		baldr.row(ui, align = .Center); {
			defer baldr.end(ui)
			baldr.text(ui, title, role = .Label)
			baldr.spacer(ui)
			if s != nil {
				names := [2]string{"Speakers", "Headphones"}
				chip := baldr.menu_chip(ui, names[s.output], s.outputs_open, Msg(Outputs{!s.outputs_open}))
				if baldr.menu(ui, chip, s.outputs_open, Msg(Outputs{false})) {
					defer baldr.end(ui)
					for name, i in names do baldr.menu_item(ui, name, Msg(Output{i}))
				}
			}
			if page != 0 do baldr.button(ui, fmt.tprintf("%s output", title), Msg(Open_Page{page}), variant = .Ghost, icon = .Chevron_Right, icon_only = true)
		}
		inner := GRID - 2 * ui.tree.theme.space[.sm] // the tile's width inside its padding
		mute: Maybe(Msg)
		if s != nil do mute = Msg(Mute{}) // the Sound slider's icon mutes
		baldr.slider(ui, value, 0, 1, proc(e: baldr.Ev(f32)) -> Msg { return Level{int(e.tag), e.value} }, width = inner, size = .Large, icon = icon, label = title,
			on_icon = mute, icon_label = "Mute", icon_pressed = s != nil && s.muted, tag = u64(which))
	}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, flex = 1, padding = .md, align = .Center); defer baldr.end(ui)
	bar := baldr.button(ui, "Control Centre", Msg(Tunnel{}), variant = .Ghost, icons = {.Wifi, .Volume_2, .Battery_Medium}, icon_only = true)
	baldr.set_describe(&ui.tree, bar, "Wi-Fi on, sound 62 %, battery 76 %") // what its icons show
	baldr.column(ui, width = GRID); { // the pages as wide as the grid, centred as it is
		defer baldr.end(ui)
		baldr.pages(ui, s.page, depth = 0 if s.page == 0 else 1, label = "Control Centre"); {
			defer baldr.end(ui)
			if s.page == 1 {
				sound_page(ui, s)
				return
			}
			baldr.wrap(ui, gap = .sm, width = GRID); {
				defer baldr.end(ui)
				wide_tile(ui, 0, .Wifi, s.wifi, "Wi-Fi", "Studio 5G" if s.wifi else "Off")
				wide_tile(ui, 1, .Bluetooth, s.bluetooth, "Bluetooth", "2 connected" if s.bluetooth else "Off")
				square_tile(ui, 2, .Moon_Star, s.dnd, "Do Not Disturb")
				square_tile(ui, 3, .Sun_Moon, s.night, "Night light")
				square_tile(ui, 4, .Plane, s.airplane, "Airplane")
				square_tile(ui, 5, .Circle_Dot, false, "Record")
				volume_icon: baldr.Icon = .Volume_X if s.volume == 0 || s.muted else .Volume_1 if s.volume < 0.5 else .Volume_2
				level_tile(ui, 0, "Sound", s.volume, volume_icon, page = 1, s = s)
				level_tile(ui, 1, "Brightness", s.brightness, .Sun_Dim if s.brightness < 0.5 else .Sun)
				baldr.column(ui, width = GRID, padding = .sm, gap = .sm, bg = ui.tree.theme.color.fill, radius = 16, key = 40); {
					defer baldr.end(ui)
					baldr.text(ui, "76% · 2 h 40 min left", role = .Label)
					baldr.segmented(ui, s.power, {"Saver", "Balanced", "Performance"}, proc(e: baldr.Ev(int)) -> Msg { return Power{e.value} },
						icons = {.Leaf, .Gauge, .Zap}, label = "Power mode", width = GRID - 2 * ui.tree.theme.space[.sm])
				}
			}
		}
	}
}

// sound_page: Back and the page's title, then its rows: the outputs, then a tunnel.
sound_page :: proc(ui: ^baldr.Ui(Msg), s: ^State) {
	baldr.column(ui, width = GRID, gap = .xs); defer baldr.end(ui)
	baldr.row(ui, align = .Center, gap = .xs); {
		defer baldr.end(ui)
		baldr.button(ui, "Back", Msg(Open_Page{0}), variant = .Ghost, icon = .Arrow_Left, icon_only = true)
		baldr.text(ui, "Sound", role = .Title)
	}
	baldr.list_row(ui, "Speakers", Msg(Output{0}), icon = .Volume_2, detail = "Built-in audio", end = .Check, on = s.output == 0, key = 1)
	baldr.list_row(ui, "Headphones", Msg(Output{1}), icon = .Volume_1, detail = "Bluetooth", value = "80 %", end = .Check, on = s.output == 1, key = 2)
	baldr.list_row(ui, "Office", Msg(Tunnel{}), icon = .Shield, value = "Connected" if s.tunnel else "", end = .Switch, on = s.tunnel, key = 3)
	baldr.list_row(ui, "Sound settings", Msg(Output{s.output}), end = .Chevron, key = 4)
}

main :: proc() {
	theme := baldr.theme_dim()
	if slice.contains(os.args, "--light") do theme = baldr.theme_light()
	if slice.contains(os.args, "--dark") do theme = baldr.theme_dark()
	err := baldr.run(baldr.App(State, Msg){
		app_id = "dev.baldr.control_centre",
		title  = "Control Centre",
		size   = {400, 700},
		theme  = theme,
		init   = proc() -> State { return {wifi = true, bluetooth = true, volume = 0.62, brightness = 0.8, power = 1} },
		update = update,
		view   = view,
	})
	if err != .None do fmt.eprintln("exit:", err)
}
