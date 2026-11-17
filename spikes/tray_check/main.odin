package main

// A tray item, live. Declares one, changes it on a timer, and prints every
// event the desktop sends back.
//
// It declares no window until asked, so it also shows that a tray item
// holds the run open on its own.
//
//	./build.sh spike tray_check run          # 40 s, then it quits
//	TRAY_CHECK_QUIT=120 build/tray_check     # longer, for clicking about
//
// What to watch for, in order:
//   - "hosted" — a tray exists and took the item;
//   - the icon appearing in the panel, and changing every 4 s;
//   - the status line changing *without* the menu being rebuilt (that is
//     the property-vs-layout distinction: a label change must not make
//     every host re-read the tree);
//   - "chose 3" when Pause is clicked, and the checkmark following;
//   - "clicked" if this desktop sends the primary action at all; some
//     never do.

import "core:fmt"
import "core:os"
import "core:strconv"
import "baldr:baldr"

State :: struct {
	tick:    int,
	paused:  bool,
	hosted:  bool,
	window:  bool, // the status window is showing
	quit_at: f64,
}

Msg :: union { Tick, Hosted, Gone, Clicked, Pause, Show, Closed, Quit_Now, Again }

Tick     :: struct {}
Hosted   :: struct {}
Gone     :: struct {}
Clicked  :: struct {}
Pause    :: struct {}
Show     :: struct {}
Closed   :: struct {}
Again    :: struct { args: []string }
Quit_Now :: struct {}

ICONS := [?]baldr.Icon{.Cloud, .Refresh_Cw, .Pause, .Circle_Alert}
WORDS := [?]string{"Up to date", "Syncing 3 files…", "Paused", "Sign-in expired"}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch e in m {
	case Tick:
		s.tick += 1
		if f64(s.tick) * 0.5 >= s.quit_at {
			fmt.eprintln("tray: done")
			return baldr.quit(Msg)
		}
		return baldr.delay(Msg, 500, Tick{})
	case Hosted:
		s.hosted = true
		fmt.eprintln("tray: hosted — a tray exists and has the item")
	case Gone:
		s.hosted = false
		fmt.eprintln("tray: gone — no tray; an app would fall back to its window")
	case Clicked:
		fmt.eprintln("tray: clicked — the primary action arrived")
	case Pause:
		s.paused = !s.paused
		fmt.eprintfln("tray: chose Pause (now %v)", s.paused)
	case Show:
		// The tray-resident lifecycle: declaring the surface shows it, and on
		// macOS the app becomes a regular one with a Dock tile; closing it
		// hides the window and the app drops back to the menu bar.
		s.window = !s.window
		fmt.eprintfln("tray: window %s", "shown" if s.window else "hidden")
	case Again:
		// A second launch hands its arguments over and exits; this copy
		// shows its window, which is what launching a running app means.
		fmt.eprintfln("tray: launched again with %d argument(s): %v", len(e.args), e.args)
		s.window = true
	case Closed:
		s.window = false
		fmt.eprintln("tray: the window was closed; the app carries on in the tray")
	case Quit_Now:
		fmt.eprintln("tray: chose Quit")
		return baldr.quit(Msg)
	}
	return {}
}

tray :: proc(s: ^State, out: ^[dynamic]baldr.Tray_Desc(Msg)) {
	phase := (s.tick / 8) % len(ICONS) // a new state every 4 s
	line := WORDS[phase]
	if s.paused do line = "Paused by you"
	items := make([dynamic]baldr.Tray_Item(Msg), context.temp_allocator)
	append(&items, baldr.Tray_Item(Msg){label = line, disabled = true}) // the status line
	append(&items, baldr.Tray_Item(Msg){separator = true})
	append(&items, baldr.Tray_Item(Msg){label = "Pause syncing", checked = s.paused, msg = Msg(Pause{})})
	append(&items, baldr.Tray_Item(Msg){label = "Show window", msg = Msg(Show{})})
	append(&items, baldr.Tray_Item(Msg){label = "Quit", msg = Msg(Quit_Now{})})
	append(out, baldr.Tray_Desc(Msg){
		tag = 1,
		title = "Tray check",
		tooltip = fmt.tprintf("Tray check: %s", line),
		icon = ICONS[phase],
		status = .Attention if phase == 3 else .Normal,
		menu = items[:],
		on_click = Msg(Clicked{}),
		on_hosted = Msg(Hosted{}),
		on_gone = Msg(Gone{}),
	})
}

main :: proc() {
	err := baldr.run(baldr.App(State, Msg){
		title = "Tray check", app_id = "dev.baldr.tray_check",
		init = proc() -> (s: State) {
			s.quit_at, _ = strconv.parse_f64(os.get_env("TRAY_CHECK_QUIT", context.temp_allocator))
			if s.quit_at <= 0 do s.quit_at = 40
			fmt.eprintfln("tray: up for %.0f s", s.quit_at)
			return
		},
		start = proc(s: ^State) -> baldr.Cmd(Msg) { return baldr.delay(Msg, 500, Tick{}) },
		update = update,
		tray = tray,
		single_instance = true,
		on_relaunch = proc(e: baldr.Ev(baldr.Relaunch)) -> Msg { return Again{e.value.args} },
		// No window unless the person asks for one: the tray holds the run
		// open, and closing the window hides it rather than ending anything.
		surfaces = proc(s: ^State, out: ^[dynamic]baldr.Surface_Desc(Msg)) {
			if !s.window do return
			append(out, baldr.Surface_Desc(Msg){
				tag = 1, kind = .Window, title = "Tray check", size = {420, 220},
				on_close = Msg(Closed{}),
			})
		},
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			baldr.column(ui, flex = 1, padding = .lg, gap = .sm, justify = .Center); defer baldr.end(ui)
			baldr.text(ui, "Tray check", role = .Headline)
			baldr.text(ui, "Close this and the app stays in the tray.", muted = true)
		},
	})
	if baldr.run_failed(err) {
		fmt.eprintln("tray_check: exit:", err)
		os.exit(1)
	}
}
