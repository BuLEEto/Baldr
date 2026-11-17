// 11_theme_icons — icons from the desktop's icon theme, by name: app icons
// in their own colours, symbolic ones in the text colour or whatever colour
// they are given, and a tray item's ARGB32 pixmap. They load off the UI
// thread and appear when ready; a new icon theme shows without a restart.
//
//   ./build.sh example 11_theme_icons run
package main

import "core:fmt"
import "baldr:baldr"

State :: struct {
	tint:   int, // the colour the symbolic icons take: the text's, the accent, danger
	big:    bool,
	pixmap: baldr.Image,
}

Msg :: enum {
	Tint,
	Size,
}

APPS :: [?]string{"org.gnome.Nautilus", "firefox-esr", "utilities-terminal", "org.gnome.Settings", "python3.13", "xterm"}
SYMBOLIC :: [?]string{
	"network-wireless-signal-good-symbolic", "audio-volume-high-symbolic", "battery-level-80-charging-symbolic",
	"bluetooth-active-symbolic", "dialog-warning-symbolic", "no-such-icon-symbolic",
}

init :: proc() -> State {
	s: State
	// what a StatusNotifierItem sends: ARGB32 in network byte order, a disc
	// shaded left to right
	N :: 22
	px: [N * N * 4]u8
	for y in 0 ..< N {
		for x in 0 ..< N {
			i := (y * N + x) * 4
			if (x - 11) * (x - 11) + (y - 11) * (y - 11) > 81 do continue
			px[i], px[i + 1], px[i + 2], px[i + 3] = 255, u8(40 + x * 9), 160, u8(240 - y * 8)
		}
	}
	s.pixmap, _ = baldr.image_from_argb32_be(N, N, px[:])
	return s
}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch m {
	case .Tint: s.tint = (s.tint + 1) % 3
	case .Size: s.big = !s.big
	}
	return {}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	size: f32 = 48 if s.big else 24
	tints := [3]baldr.Color{{}, ui.theme.color.primary, ui.theme.color.danger}
	baldr.column(ui, flex = 1, gap = .lg, padding = .xl); defer baldr.end(ui)
	baldr.text(ui, "Applications", role = .Title)
	baldr.row(ui, gap = .md, align = .Center); {
		defer baldr.end(ui)
		apps := APPS
		for name in apps do baldr.theme_icon(ui, name, size = size, label = name)
	}
	baldr.text(ui, "Symbolic", role = .Title)
	baldr.row(ui, gap = .md, align = .Center); {
		defer baldr.end(ui)
		symbolic := SYMBOLIC
		for name in symbolic do baldr.theme_icon(ui, name, size = size, color = tints[s.tint], label = name)
	}
	baldr.text(ui, "Tray pixmap (ARGB32)", role = .Title)
	baldr.image(ui, &s.pixmap, width = size, label = "Pixmap")
	baldr.row(ui, gap = .md); {
		defer baldr.end(ui)
		baldr.button(ui, "Tint", Msg.Tint, variant = .Secondary)
		baldr.button(ui, "Smaller" if s.big else "Larger", Msg.Size, variant = .Outline)
	}
}

main :: proc() {
	err := baldr.run(baldr.App(State, Msg){
		title  = "Theme icons",
		app_id = "baldr.theme_icons",
		size   = {520, 380},
		init   = init,
		update = update,
		view   = view,
	})
	if err != .None do fmt.eprintln("exit:", err)
}
