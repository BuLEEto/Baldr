// 06_panel — a desktop-shell panel on wlr-layer-shell: a 36 px strip
// anchored to the top edge that reserves its space (exclusive zone), and a
// launcher surface it opens and closes. Its Control Centre, Session menu
// (with a submenu) and tooltip open as popups of their own beside the bar,
// reaching past its 36 px. Same State / update / view as a
// window app: `surfaces` declares which surfaces exist for the state and
// view switches on ui.surface.tag. Both ask for frosted glass over the
// desktop (transparent + Blur backdrop), which the reference compositor composites; on a
// compositor without ext-background-effect they are painted with the same
// material made opaque, and without layer shell each becomes an
// undecorated window.
//
//   ./build.sh example 06_panel run [-- --output DP-2]   # default: the compositor picks the output
//   BALDR_WAYLAND_DEBUG=1 build/06_panel                 # shows what the compositor offers
//   build/06_panel --bottom                              # the bar on the bottom edge: popups open upwards
//   build/06_panel --glass clear --dark                  # a glass level (clear, frosted, solid) and a mode (light, dim, dark)
//
// Text on the glass reads over whatever is behind it: where the compositor
// reports how bright that is (the compositor's rikkiti-backdrop-v1), the tint rises
// only as far as the text needs, and on Clear the text turns dark over a
// bright wallpaper and light over a dark one.
package main

import "core:fmt"
import "core:os"
import "baldr:baldr"

PANEL    :: 1
LAUNCHER :: 2
PANEL_H  :: 36

State :: struct {
	download: f32,  // a pretend download, for the progress on the Apps button's icon
	launcher: bool,
	launched: string,
	output:   string, // "" = compositor's choice
	bottom:   bool,
	control:  bool,
	session:  bool,
	apps_menu: bool, // right-clicked Apps
	volume:   int,  // scroll over Control
}

Msg :: enum {
	Toggle_Launcher,
	Close_Launcher,
	Launch_Files,
	Launch_Terminal,
	Launch_Settings,
	Toggle_Control,
	Close_Control,
	Toggle_Session,
	Close_Session,
	Open_Apps_Menu,
	Close_Apps_Menu,
	Volume_Up,
	Volume_Down,
	Nothing,
	Tick,
	Quit,
}

// subscriptions: the pretend download moves on a timer.
subscriptions :: proc(s: ^State, out: ^[dynamic]baldr.Sub(Msg)) {
	append(out, baldr.every(Msg, 250, Msg.Tick))
}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch m {
	case .Toggle_Launcher: s.launcher = !s.launcher
	case .Close_Launcher:  s.launcher = false
	case .Launch_Files:    s.launched = "Files"; s.launcher = false
	case .Launch_Terminal: s.launched = "Terminal"; s.launcher = false
	case .Launch_Settings: s.launched = "Settings"; s.launcher = false
	case .Toggle_Control:  s.control = !s.control; s.session = false
	case .Close_Control:   s.control = false
	case .Toggle_Session:  s.session = !s.session; s.control = false
	case .Close_Session:   s.session = false
	case .Open_Apps_Menu:  s.apps_menu = true; s.control = false; s.session = false
	case .Close_Apps_Menu: s.apps_menu = false
	case .Volume_Up:       s.volume = min(s.volume + 5, 100)
	case .Volume_Down:     s.volume = max(s.volume - 5, 0)
	case .Nothing:
	case .Tick:
		s.download += 0.05 // fills, then goes for a moment, then starts again
		if s.download > 1.4 do s.download = 0
	case .Quit:            return baldr.quit(Msg)
	}
	return {}
}

// surfaces: the panel always; the launcher while it is open. Closing either
// from outside (the compositor) sends on_close. Both take the keyboard on
// demand: a click on the panel focuses its first control (ring showing), Tab
// walks the bar and Escape hands the keyboard back, so someone who came in by
// keyboard has a way out; the launcher has it while open. Only the compositor
// can give a surface the keyboard, so a bar is reachable from the keyboard
// alone only when the compositor has a binding for it.
surfaces :: proc(s: ^State, out: ^[dynamic]baldr.Surface_Desc(Msg)) {
	append(out, baldr.Surface_Desc(Msg){
		tag = PANEL, kind = .Layer, title = "Panel", size = {0, PANEL_H},
		layer = {level = .Top, anchor = {.Bottom, .Left, .Right} if s.bottom else {.Top, .Left, .Right}, exclusive_zone = PANEL_H, keyboard = .On_Demand, output = s.output},
		transparent = true, backdrop = .Blur,
		on_close = Msg.Quit,
	})
	if s.launcher {
		append(out, baldr.Surface_Desc(Msg){
			tag = LAUNCHER, kind = .Layer, title = "Launcher", size = {300, 220},
			layer = {level = .Overlay, anchor = {.Top, .Left}, margin = {PANEL_H + 6, 0, 0, 8}, keyboard = .On_Demand, output = s.output},
			transparent = true, backdrop = .Blur,
			on_close = Msg.Close_Launcher,
		})
	}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	switch ui.surface.tag {
	case LAUNCHER: launcher(s, ui)
	case:          panel(s, ui)
	}
}

panel :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.row(ui, flex = 1, align = .Center, gap = .sm, padding = .xs); defer baldr.end(ui)
	apps := baldr.button(ui, "Apps", Msg.Toggle_Launcher, icon = .Layout_Grid, variant = .Primary if s.launcher else .Ghost, on_context = Msg.Open_Apps_Menu)
	// a count at its icon's corner and a download's progress across its bottom: a negative value takes the bar away
	baldr.button_options(ui, apps, badge = baldr.Button_Badge{text = "3"}, progress = s.download if s.download <= 1 else -1)
	baldr.set_describe(&ui.tree, apps, "3 apps have updates") // a badge is drawn, not announced
	if baldr.context_menu(ui, s.apps_menu, Msg.Close_Apps_Menu) { // right-click Apps (or the Menu key on it)
		defer baldr.end(ui)
		baldr.menu_item(ui, "Open the launcher", Msg.Toggle_Launcher)
		baldr.menu_item(ui, "Launcher settings", Msg.Close_Apps_Menu)
	}
	baldr.text(ui, "Baldr shell", role = .Title)
	baldr.text(ui, fmt.tprintf("%v glass", ui.tree.theme.glass), muted = true)
	baldr.spacer(ui)
	if s.launched != "" do baldr.text(ui, fmt.tprintf("Launched %s", s.launched), muted = true)
	side := baldr.Placement.Above if s.bottom else .Below
	session := baldr.button(ui, "Session", Msg.Toggle_Session, variant = .Primary if s.session else .Ghost)
	if baldr.menu(ui, session, s.session, Msg.Close_Session, placement = side) {
		defer baldr.end(ui)
		baldr.menu_item(ui, "Lock", Msg.Close_Session)
		if baldr.submenu(ui, "Power") {
			defer baldr.end(ui)
			baldr.menu_item(ui, "Suspend", Msg.Close_Session)
			baldr.menu_item(ui, "Restart", Msg.Close_Session)
			baldr.menu_item(ui, "Shut down", Msg.Close_Session)
		}
		baldr.separator(ui)
		baldr.menu_item(ui, "Quit panel", Msg.Quit)
	}
	baldr.text(ui, fmt.tprintf("Volume %d%%", s.volume), muted = true)
	control := baldr.button(ui, "Control", Msg.Toggle_Control, icon = .Settings, variant = .Primary if s.control else .Ghost,
		on_scroll = proc(e: baldr.Ev(baldr.Scroll)) -> Msg { // scroll over it for the volume, as a tray's sound icon does
			switch {
			case e.value.steps.y < 0: return .Volume_Up
			case e.value.steps.y > 0: return .Volume_Down
			}
			return .Nothing
		})
	baldr.tooltip(ui, control, "Wi-Fi, sound and display; scroll for the volume")
	baldr.button_options(ui, control, badge = baldr.Button_Badge{dot = true}) // a dot: something waits, as a bell shows notifications
	baldr.set_describe(&ui.tree, control, "Something is waiting")
	if baldr.popover(ui, control, s.control, Msg.Close_Control, placement = side, min_width = 320) {
		defer baldr.end(ui)
		baldr.text(ui, "Control Centre", role = .Headline)
		for name in ([]string{"Wi-Fi", "Bluetooth", "Do not disturb", "Night light", "Keyboard brightness"}) {
			baldr.button(ui, name, Msg.Close_Control, variant = .Ghost)
		}
		baldr.text(ui, "A popup of its own, reaching past the bar.", muted = true)
	}
	baldr.button(ui, "Quit", Msg.Quit, variant = .Ghost)
}

launcher :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, flex = 1, gap = .sm, padding = .lg, align = .Start); defer baldr.end(ui)
	baldr.text(ui, "Launcher", role = .Headline)
	baldr.button(ui, "Files", Msg.Launch_Files, icon = .Folder, variant = .Ghost)
	baldr.button(ui, "Terminal", Msg.Launch_Terminal, icon = .Terminal, variant = .Ghost)
	baldr.button(ui, "Settings", Msg.Launch_Settings, icon = .Settings, variant = .Ghost)
	baldr.spacer(ui)
	baldr.button(ui, "Close", Msg.Close_Launcher, variant = .Outline)
}

init :: proc() -> (s: State) {
	s.volume = 50
	args := os.args[1:]
	for a, i in args {
		if a == "--output" && i + 1 < len(args) do s.output = args[i + 1]
		if a == "--launcher" do s.launcher = true // start with the launcher open (for testing)
		if a == "--bottom" do s.bottom = true
		if a == "--control" do s.control = true // start with the Control Centre open (for testing)
	}
	return
}

// theme_of_args: --glass and --light / --dim / --dark pick a theme of the
// example's own; without them it follows the desktop (Frosted glass).
theme_of_args :: proc() -> (th: baldr.Theme) {
	args := os.args[1:]
	mode := baldr.Theme_Mode.Dim
	glass := baldr.Glass_Level.Frosted
	chosen := false
	for a, i in args {
		switch a {
		case "--light": mode, chosen = .Light, true
		case "--dim":   mode, chosen = .Dim, true
		case "--dark":  mode, chosen = .Dark, true
		case "--glass":
			if i + 1 >= len(args) do continue
			switch args[i + 1] {
			case "clear":   glass = .Clear
			case "frosted": glass = .Frosted
			case "solid":   glass = .Solid
			case:           fmt.eprintfln("--glass: clear, frosted or solid, not %q", args[i + 1])
			}
			chosen = true
		}
	}
	if !chosen do return
	th = baldr.theme_from_seed(baldr.BALDR_BLUE, mode, name = "Panel")
	th.glass = glass
	return
}

main :: proc() {
	err := baldr.run(baldr.App(State, Msg){
		app_id   = "dev.baldr.panel",
		theme    = theme_of_args(),
		init     = init,
		update   = update,
		view     = view,
		surfaces = surfaces,
		subscriptions = subscriptions,
	})
	if err != .None do fmt.eprintln("exit:", err)
}
