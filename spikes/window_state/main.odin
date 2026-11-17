package main

// window_state — does `on_state` actually fire in a real window? The headless test
// calls window_state_sync directly, which proves the comparison and not the
// wiring — so this prints every Window_State the runtime delivers while the
// window is resized, maximised and focused by hand.
//
//	./build.sh spike window_state run
//	# then: maximise it, unmaximise it, click another window and back

import "core:fmt"
import "core:os"
import "baldr:baldr"

Msg :: union { baldr.Window_State }

State :: struct {
	last:  baldr.Window_State,
	count: int,
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Window state", app_id = "baldr.window_state", size = {520, 300},
		// BALDR_SPIKE_MAXIMIZED=1 opens it maximised: the other half of
		// coming back the way it was left.
		maximized = os.get_env("BALDR_SPIKE_MAXIMIZED", context.temp_allocator) != "",
		on_state = proc(e: baldr.Ev(baldr.Window_State)) -> Msg { return e.value },
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			switch v in m {
			case baldr.Window_State:
				s.last, s.count = v, s.count + 1
				// `position` is nil where the platform will not say (Wayland
				// by design), so it is printed as what it is rather than as
				// a number that would be a guess.
				at := "unknown" // `where` is a keyword in Odin (generic constraints)
				if p, ok := v.position.?; ok do at = fmt.tprintf("%d,%d", p.x, p.y)
				fmt.printfln("[%2d] size %.0fx%.0f  at %s  keyboard %v  maximized %v  fullscreen %v  tiled %v  scale %.2f",
					s.count, v.size.x, v.size.y, at, v.keyboard, v.maximized, v.fullscreen, v.tiled, v.scale)
			}
			return {}
		},
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			baldr.column(ui, padding = .lg, gap = .sm); defer baldr.end(ui)
			baldr.text(ui, "Window state", role = .Title)
			baldr.text(ui, fmt.tprintf("%d reports", s.count))
			baldr.text(ui, fmt.tprintf("size %.0f x %.0f", s.last.size.x, s.last.size.y))
			baldr.text(ui, fmt.tprintf("keyboard %v, maximized %v, tiled %v", s.last.keyboard, s.last.maximized, s.last.tiled))
			if p, ok := s.last.position.?; ok {
				baldr.text(ui, fmt.tprintf("at %d, %d", p.x, p.y))
			} else {
				baldr.text(ui, "the desktop does not say where it is")
			}
		},
	})
}
