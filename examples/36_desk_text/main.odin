// 36_desk_text — readouts drawn straight on the wallpaper, in an ink that
// follows what is behind them.
//
// A background layer surface with no glass and no input: its own pixels sit
// on the desktop, so nothing about its colours can be settled when it is
// written. `backdrop = .Measure` asks the compositor how bright what is
// behind it is — without asking for a blur, since there is nothing to blur
// behind text — `backdrop_range` reads the answer in the view, and
// `legible_ink` turns it into the ink and the halo to draw with.
//
//   ./build.sh example 36_desk_text run
//   build/36_desk_text --preferred 656667 --contrast 3   # a quiet grey, the contrast large text wants
//   build/36_desk_text --left                            # the other corner
//   build/36_desk_text --bottom                          # …and the other edge
//   BALDR_WAYLAND_DEBUG=1 build/36_desk_text             # whether the compositor measures, and what it reports
//
// Change the wallpaper under it and the corner answers: over a dark one the
// preferred colour is kept exactly as it is, over a pale one it darkens,
// and over a photograph that runs from dark to bright under one line — where
// no single colour can read — it takes a halo.
//
// Without layer shell the surface opens as an undecorated window instead
// (and nothing shows through it, so there is nothing to measure): the
// readouts then draw in the preferred colour with the halo.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "baldr:baldr"

CORNER :: 1

State :: struct {
	preferred: baldr.Color, // the colour the readouts would rather be
	contrast:  f32,         // the ratio it has to reach over the wallpaper
	ticks:     int,
	left:      bool,
	bottom:    bool,
	output:    string,
}

Msg :: enum { Tick, Quit }

subscriptions :: proc(s: ^State, out: ^[dynamic]baldr.Sub(Msg)) {
	append(out, baldr.every(Msg, 1000, Msg.Tick))
}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch m {
	case .Tick: s.ticks += 1
	case .Quit: return baldr.quit(Msg)
	}
	return {}
}

// One surface: the bottom layer, in a corner, taking no pointer and no
// keyboard — a readout is looked at, not used, and a click belongs to the
// desktop behind it. `.Measure` is the whole of the asking; it needs
// `transparent`, because what is measured is what shows through.
surfaces :: proc(s: ^State, out: ^[dynamic]baldr.Surface_Desc(Msg)) {
	append(out, baldr.Surface_Desc(Msg){
		tag = CORNER, kind = .Layer, title = "Desk text", size = {300, 170},
		layer = {
			level = .Background,
			anchor = ({.Bottom} if s.bottom else {.Top}) | ({.Left} if s.left else {.Right}),
			margin = {24, 24, 24, 24},
			keyboard = .None,
			output = s.output,
		},
		transparent = true,
		backdrop = .Measure,
		input = .None,
		on_close = Msg.Quit,
	})
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	bd, measured := baldr.backdrop_range(ui)
	// Until the first report comes — a frame or two after the surface is
	// mapped, and never on a compositor that does not measure — the halo
	// every desktop falls back to. It always reads; it is only heavy.
	ink, glow := s.preferred, baldr.legible_halo(s.preferred)
	if measured do ink, glow = baldr.legible_ink(bd, s.preferred, s.contrast)

	baldr.column(ui, flex = 1, gap = .xs, align = .Start); defer baldr.end(ui)
	line(ui, "Baldr", ink, glow, s.preferred, s.contrast, .Headline)
	line(ui, fmt.tprintf("cpu   %d%%", 7 + s.ticks % 9), ink, glow, s.preferred, s.contrast)
	line(ui, "mem   2.1G of 32G", ink, glow, s.preferred, s.contrast)
	line(ui, fmt.tprintf("up    %d:%02d", s.ticks / 60, s.ticks % 60), ink, glow, s.preferred, s.contrast)
	baldr.spacer(ui)
	// What it is doing, so a run shows its working rather than only its taste.
	if measured {
		line(ui, fmt.tprintf("behind  %.3f / %.3f / %.3f", bd.min, bd.avg, bd.max), ink, glow, s.preferred, s.contrast, .Caption)
	} else {
		line(ui, "behind  not measured", ink, glow, s.preferred, s.contrast, .Caption)
	}
	line(ui, fmt.tprintf("ink  #%s  from #%s  halo %v", hex(ink), hex(s.preferred), glow != baldr.Glow{}), ink, glow, s.preferred, s.contrast, .Caption)
	// Per piece, where the compositor reports the backdrop cell by cell:
	// every line above asked for its own ink, so over a wallpaper that runs
	// light to dark each takes the colour that reads over its own part.
	// Over a plain wallpaper the two answers are the same.
	line(ui, "per piece  yes" if baldr.backdrop_mapped(ui) else "per piece  no (one ink for the surface)",
		ink, glow, s.preferred, s.contrast, .Caption)
}

// line is a readout: text in the chosen ink, wearing the chosen halo. The
// glow goes on the text node itself rather than on the column, so the
// renderer leaves room for it around each glyph.
line :: proc(ui: ^baldr.Ui(Msg), str: string, ink: baldr.Color, glow: baldr.Glow,
             want: baldr.Color, contrast: f32, role := baldr.Text_Role.Body) {
	n := baldr.text(ui, str, role = role, color = ink, mono = role != .Headline, nowrap = true)
	baldr.set_glow(&ui.tree, n, glow)
	// …and, where the backdrop is reported cell by cell, let this line pick
	// its own ink and halo from what is behind it rather than the one the
	// whole surface settled on. With no map this does nothing and the ink
	// set above stands.
	baldr.legible_over(ui, n, want, contrast)
}

// hex writes a colour the way a wallpaper or a theme file names one.
hex :: proc(c: baldr.Color) -> string {
	b := [3]u8{}
	for i in 0 ..< 3 do b[i] = u8(clamp(baldr.linear_to_srgb(c[i]), 0, 1) * 255 + 0.5)
	return fmt.tprintf("%02x%02x%02x", b[0], b[1], b[2])
}

// --preferred RRGGBB is the colour the readouts want to keep; --contrast is
// what it has to reach over the wallpaper (3 for large or quiet text, 4.5
// for anything that has to be read closely).
init :: proc() -> (s: State) {
	s.preferred = srgb(0x65, 0x66, 0x67)
	s.contrast = 3
	args := os.args[1:]
	for a, i in args {
		switch a {
		case "--left": s.left = true
		case "--bottom": s.bottom = true
		case "--output":
			if i + 1 < len(args) do s.output = args[i + 1]
		case "--contrast":
			if i + 1 < len(args) {
				if v, ok := strconv.parse_f64(args[i + 1]); ok do s.contrast = f32(v)
			}
		case "--preferred":
			if i + 1 >= len(args) do continue
			if v, ok := strconv.parse_u64_of_base(args[i + 1], 16); ok {
				s.preferred = srgb(u8(v >> 16), u8(v >> 8), u8(v))
			} else {
				fmt.eprintfln("--preferred wants six hex digits, not %q", args[i + 1])
			}
		}
	}
	return
}

srgb :: proc(r, g, b: u8) -> baldr.Color {
	return {
		baldr.srgb_to_linear(f32(r) / 255),
		baldr.srgb_to_linear(f32(g) / 255),
		baldr.srgb_to_linear(f32(b) / 255),
		1,
	}
}

main :: proc() {
	err := baldr.run(baldr.App(State, Msg){
		app_id   = "dev.baldr.desk_text",
		init     = init,
		update   = update,
		view     = view,
		surfaces = surfaces,
		subscriptions = subscriptions,
	})
	if err != .None do fmt.eprintln("exit:", err)
}
