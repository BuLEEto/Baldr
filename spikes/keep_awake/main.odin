package main

// A window asking the desktop not to let the screen dim while it is
// playing something.
//
// By hand: the button toggles it, and `BALDR_WAYLAND_DEBUG=1` says whether
// the compositor offers the protocol and when the inhibitor is made and
// destroyed.
//
// Driven, which is how it is actually proved: with `KEEP_AWAKE_HOLD=5` it
// asks for the first five seconds and lets go after them, and
// `KEEP_AWAKE_QUIT=12` ends the run. Run that under an idle watcher
// (swayidle) in the nested harness and the watcher must stay quiet for the
// first five seconds and fire after them — the compositor's own answer to
// the question, rather than our word for it.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"
import "baldr:baldr"

State :: struct {
	playing: bool,
	hold:    f64, // seconds to hold for, 0: by hand
	quit_at: f64,
	t0:      time.Tick,
	said:    bool,
}

Msg :: union { Toggle, Tick }

Toggle :: struct {}
Tick :: struct {}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch _ in m {
	case Toggle:
		s.playing = !s.playing
		fmt.eprintfln("keep_awake: %s by hand", "holding" if s.playing else "let go")
	case Tick:
		if s.hold <= 0 do return {}
		secs := time.duration_seconds(time.tick_since(s.t0))
		if s.playing && secs >= s.hold {
			s.playing = false
			fmt.eprintfln("keep_awake: let go at %.1f s", secs)
		}
		if s.quit_at > 0 && secs >= s.quit_at do return baldr.quit(Msg)
		return baldr.delay(Msg, 100, Tick{})
	}
	return {}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.keep_awake(ui, s.playing) // the whole of the app's side
	baldr.column(ui, flex = 1, padding = .lg, gap = .md, justify = .Center, align = .Center); defer baldr.end(ui)
	baldr.text(ui, "Keeping the screen awake", role = .Title)
	baldr.text(ui, "the screen is being held on" if s.playing else "the screen may dim", role = .Caption)
	baldr.button(ui, "Pause" if s.playing else "Play", Toggle{}, key = 1)
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Keep awake", app_id = "dev.baldr.keep_awake", size = {380, 220},
		init = proc() -> (s: State) {
			s.t0 = time.tick_now()
			hold, _ := strconv.parse_f64(os.get_env("KEEP_AWAKE_HOLD", context.temp_allocator))
			quit, _ := strconv.parse_f64(os.get_env("KEEP_AWAKE_QUIT", context.temp_allocator))
			s.hold, s.quit_at = hold, quit
			s.playing = hold > 0 // driven: playing from the start
			if hold > 0 do fmt.eprintfln("keep_awake: holding for %.1f s", hold)
			return
		},
		start = proc(s: ^State) -> baldr.Cmd(Msg) { return baldr.delay(Msg, 100, Tick{}) },
		update = update,
		view = view,
	})
}
