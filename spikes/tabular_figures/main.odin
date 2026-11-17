package main

// Figures of one width, so a number that changes does not change width
// with it.
//
// A stopwatch's "0:21.4" is a Display text centred in its column. Inter's
// figures are proportional — a 1 is narrower than a 0 — so as the tenths
// tick the text changes width and the whole thing shuffles sideways ten
// times a second.
//
// Driven, because the proof is a *measurement* and then a picture: the
// value steps through a fixed list rather than a real clock, and each tick
// prints the node's own x and width. With `tabular` they never move; with
// `TABULAR=0` they move on nearly every tick, which is the fault.
//
//	TABULAR=0 build/tabular_figures      # the fault
//	build/tabular_figures                # …and the fix
//	TABULAR_HOLD=0:21.1 build/tabular_figures   # stop on one tick, to capture it
//
// Two captures held at "0:21.0" and "0:21.1" are the other half: with the
// figures lined up, every pixel left of the last digit is identical.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "baldr:baldr"

ticks := []string{"0:21.0", "0:21.1", "0:21.2", "0:21.3", "0:21.4", "0:21.5", "0:21.6", "0:21.7", "0:21.8", "0:21.9", "0:22.0", "0:22.1"}

State :: struct {
	at:       int,
	tabular:  bool,
	hold:     string, // stop on this tick and sit there (for a capture)
	stopped:  bool,
	last:     baldr.Rect,
	moves:    int,
	t0:       time.Tick,
	quit_at:  f64,
}

Msg :: union { Tick }

Tick :: struct {}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch _ in m {
	case Tick:
		if s.quit_at > 0 && time.duration_seconds(time.tick_since(s.t0)) >= s.quit_at do return baldr.quit(Msg)
		if !s.stopped {
			if s.hold != "" && ticks[s.at] == s.hold {
				s.stopped = true
				fmt.eprintfln("tabular_figures: STOPPED on %s", s.hold)
			} else {
				s.at = (s.at + 1) % len(ticks)
			}
		}
		return baldr.delay(Msg, 150, Tick{})
	}
	return {}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, flex = 1, padding = .lg, gap = .md, justify = .Center, align = .Center); defer baldr.end(ui)
	baldr.text(ui, "Stopwatch", role = .Caption, muted = true)
	n := baldr.text(ui, ticks[s.at], role = .Display, tabular = s.tabular, key = 1)
	baldr.text(ui, "tabular" if s.tabular else "proportional (the fault)", role = .Caption, muted = true)

	// The node's own box is what moved the text about, so that is what is
	// worth printing: a still width in a centred column is a still number.
	if d := baldr.node_get(&ui.tree, n); d != nil {
		if s.last.w != 0 && (d.abs.x != s.last.x || d.abs.w != s.last.w) do s.moves += 1
		if d.abs != s.last {
			fmt.eprintfln("tabular_figures: %s at x %.2f, %.2f wide%s", ticks[s.at], d.abs.x, d.abs.w,
				"" if s.last.w == 0 else fmt.tprintf("  (moved %d of %d ticks so far)", s.moves, len(ticks)))
		}
		s.last = d.abs
	}
}

main :: proc() {
	err := baldr.run(baldr.App(State, Msg){
		title = "Stopwatch", app_id = "dev.baldr.tabular", size = {420, 240},
		init = proc() -> (s: State) {
			s.t0 = time.tick_now()
			s.tabular = os.get_env("TABULAR", context.temp_allocator) != "0"
			// Cloned: `init` runs in a frame whose temp memory is freed under
			// it, so a string kept in State must be the app's own.
			s.hold = strings.clone(os.get_env("TABULAR_HOLD", context.temp_allocator))
			s.quit_at, _ = strconv.parse_f64(os.get_env("TABULAR_QUIT", context.temp_allocator))
			fmt.eprintfln("tabular_figures: %s figures%s", "tabular" if s.tabular else "proportional",
				fmt.tprintf(", will stop on %s", s.hold) if s.hold != "" else "")
			return
		},
		start = proc(s: ^State) -> baldr.Cmd(Msg) { return baldr.delay(Msg, 150, Tick{}) },
		update = update, view = view,
	})
	if baldr.run_failed(err) {
		fmt.eprintln("tabular_figures: exit:", err)
		os.exit(1)
	}
}
