package main

// A window drawing its own title bar, following title-bar
// choices given in the environment as an app reading its desktop's
// settings would: TITLEBAR_LAYOUT (GNOME's button-layout), TITLEBAR_DOUBLE
// and TITLEBAR_WHEEL (compositor.conf's words: maximize, minimize, roll_up,
// nothing). Unset, it follows the desktop's own (GNOME's, through the
// portal). The body's field says on stdout what is typed into it
// ("typed TEXT"), so a test can see where the keyboard went.

import "core:fmt"
import "core:os"
import "baldr:baldr"

Msg :: union { Typed, Quit }
Typed :: struct { text: string }
Quit :: struct {}

main :: proc() {
	app := baldr.App(int, Msg){
		title = "Titlebar", app_id = "dev.baldr.titlebar", size = {640, 420},
		init = proc() -> int { return 0 },
		update = proc(s: ^int, m: Msg) -> baldr.Cmd(Msg) {
			switch v in m {
			case Typed:
				fmt.println("typed", v.text)
				os.flush(os.stdout)
			case Quit: return baldr.quit(Msg)
			}
			return {}
		},
		view = proc(s: ^int, ui: ^baldr.Ui(Msg)) {
			baldr.column(ui); defer baldr.end(ui)
			baldr.window_chrome(ui, "Titlebar")
			baldr.window_buttons(ui, on_close = Msg(Quit{}))
			baldr.end(ui)
			baldr.column(ui, padding = .lg, gap = .md, flex = 1); defer baldr.end(ui)
			baldr.text(ui, "Double-click or wheel over the bar to roll the window up.")
			baldr.text_input(ui, nil, label = "Body", placeholder = "Type here", width = 320,
				on_change = proc(e: baldr.Ev(string)) -> Msg { return Typed{e.value} })
		},
		surfaces = proc(s: ^int, out: ^[dynamic]baldr.Surface_Desc(Msg)) {
			append(out, baldr.Surface_Desc(Msg){title = "Titlebar", size = {640, 420}, undecorated = true, on_close = Msg(Quit{})})
		},
	}
	layout, double, wheel := os.get_env("TITLEBAR_LAYOUT", context.temp_allocator), os.get_env("TITLEBAR_DOUBLE", context.temp_allocator), os.get_env("TITLEBAR_WHEEL", context.temp_allocator)
	if layout != "" || double != "" || wheel != "" {
		p := baldr.Titlebar_Prefs{button_layout = layout, wheel = .Roll_Up if wheel == "roll_up" else .None}
		p.double_click, _ = baldr.titlebar_action_of(double)
		app.titlebar = p
	}
	baldr.run(app)
}
