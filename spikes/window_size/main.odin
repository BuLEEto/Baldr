package main

// window_size — a window sized by its app, which the person can still resize
// afterwards: a video player fits its window to the film it has just opened,
// and from then on the window is the person's again. The trap is an ask that
// holds the window at the app's size for good, so dragging an edge does
// nothing.
//
// Driven, because the proof is a sequence rather than a picture:
// `WINDOW_SIZE_ASK=1280x720` is declared after `WINDOW_SIZE_AFTER` seconds,
// every configure the desktop answers with is printed, and
// `WINDOW_SIZE_QUIT` ends the run. So: run it in the nested harness, drag a
// corner with `compositor-msg seat grab resize` after the ask, and read the
// state lines — the one after the drag must carry the dragged size, not the
// asked one.
//
// `spikes/window_state` is the hand-driven twin: it watches what the desktop
// does to a window without ever asking for a size itself.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "baldr:baldr"

State :: struct {
	floor:   [2]f32, // WINDOW_SIZE_MIN: the smallest the desktop may let it be dragged
	ceiling: [2]f32, // WINDOW_SIZE_MAX: …and the largest
	want:    [2]f32, // what the app declares for its window
	ask:     [2]f32, // …and what it will declare once it "knows the film"
	after:   f64,
	quit_at: f64,
	t0:      time.Tick,
	states:  int,
}

Msg :: union { Tick, baldr.Window_State }

Tick :: struct {}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	secs := time.duration_seconds(time.tick_since(s.t0))
	switch e in m {
	case Tick:
		if s.ask != {} && s.want != s.ask && secs >= s.after {
			s.want = s.ask
			fmt.eprintfln("window_size: asking for %v at %.1f s", s.ask, secs)
		}
		if s.quit_at > 0 && secs >= s.quit_at do return baldr.quit(Msg)
		return baldr.delay(Msg, 100, Tick{})
	case baldr.Window_State:
		s.states += 1
		fmt.eprintfln("window_size: state %d: size %v maximized %v fullscreen %v tiled %v at %.1f s",
			s.states, e.size, e.maximized, e.fullscreen, e.tiled, secs)
	}
	return {}
}

surfaces :: proc(s: ^State, out: ^[dynamic]baldr.Surface_Desc(Msg)) {
	append(out, baldr.Surface_Desc(Msg){
		tag = 1, kind = .Window, title = "Window size", size = s.want,
		min_size = s.floor, max_size = s.ceiling,
		on_state = proc(e: baldr.Ev(baldr.Window_State)) -> Msg { return e.value },
	})
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, flex = 1, padding = .lg, gap = .md, justify = .Center, align = .Center); defer baldr.end(ui)
	baldr.text(ui, "A window sized by its app", role = .Title)
	baldr.text(ui, fmt.tprintf("declared %v, %d configures", s.want, s.states), role = .Caption)
}

main :: proc() {
	env_size :: proc(name: string, fallback: [2]f32) -> [2]f32 {
		text := os.get_env(name, context.temp_allocator)
		i := strings.index_byte(text, 'x')
		if i <= 0 do return fallback
		w, wok := strconv.parse_f64(text[:i])
		h, hok := strconv.parse_f64(text[i + 1:])
		if !wok || !hok || w <= 0 || h <= 0 do return fallback
		return {f32(w), f32(h)}
	}
	err := baldr.run(baldr.App(State, Msg){
		title = "Window size", app_id = "dev.baldr.window_size",
		init = proc() -> (s: State) {
			s.t0 = time.tick_now()
			s.want = env_size("WINDOW_SIZE_START", {960, 600})
			s.ask = env_size("WINDOW_SIZE_ASK", {})
			// The range the desktop is asked to hold the window inside
			// (`Surface_Desc.min_size` / `max_size`): drag an edge past it
			// and the window should stop, and the state lines below say
			// what it actually became.
			s.floor = env_size("WINDOW_SIZE_MIN", {})
			s.ceiling = env_size("WINDOW_SIZE_MAX", {})
			s.after, _ = strconv.parse_f64(os.get_env("WINDOW_SIZE_AFTER", context.temp_allocator))
			s.quit_at, _ = strconv.parse_f64(os.get_env("WINDOW_SIZE_QUIT", context.temp_allocator))
			if s.after <= 0 do s.after = 1
			fmt.eprintfln("window_size: opening at %v, asking for %v after %.1f s (range %v..%v)",
				s.want, s.ask, s.after, s.floor, s.ceiling)
			return
		},
		start = proc(s: ^State) -> baldr.Cmd(Msg) { return baldr.delay(Msg, 100, Tick{}) },
		update = update, view = view, surfaces = surfaces,
	})
	if baldr.run_failed(err) {
		// What `run`'s doc asks of every app: a run that ended for a reason
		// is not a clean close, and a window nothing can draw on is one of
		// those reasons.
		fmt.eprintln("window_size: exit:", err)
		os.exit(1)
	}
}
