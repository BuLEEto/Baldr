package main

// 18_dock — a dock along the bottom of the screen: a layer surface that hides at its edge and reveals
// itself when the pointer reaches the screen's edge, its icons growing with the pointer's distance along the shelf,
// one of them showing a download's progress and the running ones a mark under them.
// The icons are `quiet`: growing is how the dock answers the pointer, so no wash is drawn behind them.
//
//   ./build.sh example 18_dock run
//   build/18_dock --always   # autohide: hidden until the pointer reaches the screen's edge
//   build/18_dock --always --float  # …and floating: a 6 px gap it keeps while it shows
//   build/18_dock --light
//
// The surface sits on the edge with no margin, so the strip that reveals it is the screen's own edge; the dock's
// floating look is drawn inside it instead (the shelf's padding). With `--float` it asks for a margin as well: a
// hiding surface keeps its margin while it shows and sits at the screen's edge only while hidden, so the reveal
// strip stays where the pointer can find it.

import "core:fmt"
import "core:math"
import "core:os"
import "baldr:baldr"

APPS := [?]struct{ name, icon: string, running: bool }{
	{"Files", "system-file-manager", true},
	{"Terminal", "utilities-terminal", true},
	{"Browser", "web-browser", false},
	{"Mail", "internet-mail", true},
	{"Music", "multimedia-audio-player", false},
	{"Settings", "preferences-system", false},
}

ICON    :: f32(40)  // an icon at rest
GROW    :: f32(1.5) // the nearest icon's size, times ICON
REACH   :: f32(2.5) // how many cells away the growing reaches
CELL    :: f32(64)  // each app's place on the shelf: fixed, so the icons grow without moving each other
GAP     :: f32(8)
PADDING :: f32(10)

State :: struct {
	at:       f32,  // where the pointer is along the shelf, logical px from its middle (see Point)
	over:     bool, // …and whether it is over it at all
	ease:     f32,  // 0…1 as the growing comes and goes
	download: f32,
	hide:     bool,
	floating: bool,
	light:    bool,
	note:     string,
}

// Point carries where the pointer is from the shelf's middle, not from its left: the shelf grows and re-centres as
// the icons do, so a distance from its left edge would move as they grow and feed the growing back into itself.
Point :: struct { at: f32, over: bool }
Launch :: struct { i: int }
Tick :: struct {}
Msg :: union { Point, Launch, Tick }

surfaces :: proc(s: ^State, out: ^[dynamic]baldr.Surface_Desc(Msg)) {
	append(out, baldr.Surface_Desc(Msg){
		tag = 1, kind = .Layer, title = "Dock", size = {baldr.FIT, shelf_height(s) + PADDING},
		layer = {level = .Top, anchor = {.Bottom}, keyboard = .On_Demand, margin = {6, 6, 6, 6} if s.floating else {}},
		transparent = true, backdrop = .Blur, radius = 18,
		hide = {mode = .Always, delay_ms = 700} if s.hide else {},
	})
}

subscriptions :: proc(s: ^State, out: ^[dynamic]baldr.Sub(Msg)) {
	append(out, baldr.every(Msg, 33, Msg(Tick{}))) // the growing eases in and out, and the download moves
}

// shelf_height: the tallest an icon gets, plus the room around it, so the surface doesn't resize as they grow.
shelf_height :: proc(s: ^State) -> f32 { return ICON * GROW + 2 * PADDING }

// shelf_width: the shelf at rest, which is also its width while they grow — a cell keeps its place.
shelf_width :: proc() -> f32 { return f32(len(APPS)) * CELL + f32(len(APPS) - 1) * GAP + 2 * PADDING }

// scale_at is how much the icon in cell `i` grows: a cosine falloff over REACH cells from the pointer, eased in and
// out by `ease`. Both are measured from the shelf's middle in the layout at rest, so the growing can't feed back
// into itself.
scale_at :: proc(s: ^State, i: int) -> f32 {
	if s.ease <= 0.001 do return 1
	pitch := CELL + GAP
	centre := PADDING + f32(i) * pitch + CELL / 2 - shelf_width() / 2
	d := abs(s.at - centre)
	r := REACH * pitch
	if d >= r do return 1
	f := (math.cos(d * math.PI / r) + 1) / 2
	return 1 + (GROW - 1) * f * s.ease
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.row(ui, flex = 1, align = .End, justify = .Center); defer baldr.end(ui)
	shelf := baldr.row(ui, gap = GAP, padding = PADDING, align = .End, key = 1); {
		defer baldr.end(ui)
		baldr.pointer_track(ui, shelf, proc(e: baldr.Ev(baldr.Pointer_At)) -> Msg { return Point{e.value.pos.x - e.value.size.x / 2, e.value.inside} })
		for app, i in APPS {
			baldr.row(ui, width = CELL, align = .End, justify = .Center, key = u64(i + 100)); { // its place, whatever it grows to
				defer baldr.end(ui)
				b := baldr.button(ui, app.name, Msg(Launch{i}), variant = .Ghost, theme_icon = app.icon, icon_only = true, key = u64(i + 2))
				size := ICON * scale_at(s, i)
				baldr.button_options(ui, b, icon_size = size, quiet = true, // the icon growing says what the pointer is on; a wash behind it would say it twice
					mark = baldr.Button_Mark{side = .Bottom, length = 14 if app.running else 0},
					badge = baldr.Button_Badge{text = "2"} if app.name == "Mail" else baldr.Button_Badge{},
					progress = s.download if app.name == "Browser" && s.download <= 1 else -1)
			}
		}
	}
}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch v in m {
	case Point:
		s.at, s.over = v.at, v.over
	case Launch:
		fmt.printfln("dock: %s", APPS[v.i].name)
	case Tick:
		want: f32 = 1 if s.over else 0 // the growing eases over about 150 ms
		step := f32(33) / 150
		s.ease += clamp(want - s.ease, -step, step)
		s.download += 0.02
		if s.download > 1.5 do s.download = 0
	}
	return {}
}

main :: proc() {
	s: State
	for a in os.args[1:] {
		switch a {
		case "--always": s.hide = true
		case "--float":  s.floating = true
		case "--light":  s.light = true
		}
	}
	dock_start = s
	err := baldr.run(baldr.App(State, Msg){
		app_id = "dev.baldr.dock", theme = baldr.theme_light() if s.light else baldr.theme_dark(),
		init = proc() -> State { return dock_start },
		update = update, view = view, surfaces = surfaces, subscriptions = subscriptions,
	})
	if err != .None do fmt.eprintln("exit:", err)
}

dock_start: State
