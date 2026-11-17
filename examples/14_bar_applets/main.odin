// 14_bar_applets — a bar holding another program's applet: a
// bottom layer-shell bar with its own title and Quit button, and an
// `applet_slot` that the compositor fills with 12_applet's clock, running in
// a process of its own. The bar starts the clock with the slot's token (in
// RIKKITI_APPLET_TOKEN) in a job that waits for it; when the clock goes, a
// new token comes and the bar starts it again, a few times at most. The slot
// takes the length the clock asks for. Needs the compositor's rikkiti-applet-v1;
// elsewhere the slot is an empty place.
//
//   ./build.sh example 12_applet && ./build.sh example 14_bar_applets run
//   build/14_bar_applets --left                   # a side bar: the slot runs down it
//   build/14_bar_applets --fit                    # a floating bar in the middle of the edge, as long as its content
//   BALDR_WAYLAND_DEBUG=1 build/14_bar_applets    # the slot, its tokens, attach and size hints
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "baldr:baldr"

CLOCK      :: 1 // the slot's key: one clock across rebuilds
MAX_STARTS :: 5

State :: struct {
	clock_len: f32,
	clock_min: f32,
	attached:  bool,
	starts:    int,
	left:      bool,
	fit:       bool,
}

Slot_Report :: struct {
	ev: baldr.Slot_Event,
}
Clock_Ended :: struct {}
Quit :: struct {}
Msg :: union { Slot_Report, Clock_Ended, Quit }

// run_clock starts 12_applet, next to this program, with the slot's token
// in its environment, and waits for it to end.
run_clock :: proc(j: ^baldr.Job(Msg)) {
	token := (^string)(j.data)
	defer {
		delete(token^)
		free(token)
	}
	env := make([dynamic]string, context.temp_allocator)
	current, _ := os.environ(context.temp_allocator)
	for kv in current do if !strings.has_prefix(kv, "RIKKITI_APPLET_TOKEN=") do append(&env, kv)
	append(&env, fmt.tprintf("RIKKITI_APPLET_TOKEN=%s", token^))
	path, _ := filepath.join({filepath.dir(os.args[0]), "12_applet"}, context.temp_allocator)
	p, err := os.process_start({command = {path}, env = env[:], stdout = os.stdout, stderr = os.stderr})
	if err != nil {
		fmt.eprintfln("14_bar_applets: could not start %s: %v", path, err)
		return
	}
	_, _ = os.process_wait(p)
}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch v in m {
	case Quit:
		return baldr.quit(Msg)
	case Clock_Ended:
		s.attached = false
	case Slot_Report:
		switch e in v.ev {
		case baldr.Slot_Token:
			if s.starts >= MAX_STARTS do return {} // it keeps ending: leave the place empty
			s.starts += 1
			token := new(string)
			token^ = strings.clone(e.token) // the report's string lives only while it is handled
			return baldr.job(Msg, run_clock, token, Msg(Clock_Ended{}))
		case baldr.Slot_Attached:
			s.attached = true
		case baldr.Slot_Detached:
			s.attached = false
		case baldr.Slot_Size_Hint:
			if e.preferred > 0 do s.clock_len = e.preferred
			if e.min > 0 do s.clock_min = e.min
		}
	}
	return {}
}

surfaces :: proc(s: ^State, out: ^[dynamic]baldr.Surface_Desc(Msg)) {
	bar := baldr.Surface_Desc(Msg){
		tag = 1, kind = .Layer, title = "Bar", size = {0, 40},
		layer = {level = .Top, anchor = {.Bottom, .Left, .Right}, exclusive_zone = 40, keyboard = .On_Demand},
		transparent = true, backdrop = .Blur, on_close = Msg(Quit{}),
	}
	if s.left {
		bar.size = {48, 0}
		bar.layer.anchor, bar.layer.exclusive_zone = {.Left, .Top, .Bottom}, 48
	}
	if s.fit { // anchored to the bottom alone: centred, as long as what it holds, and floating: round all four corners
		bar.size = {baldr.FIT, 40}
		bar.layer.anchor, bar.layer.margin, bar.layer.exclusive_zone = {.Bottom}, {0, 0, 8, 0}, 48
		bar.radius = 14
	}
	append(out, bar)
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	// The container depends on the edge, so it is opened in a branch and the
	// single defer below closes whichever it was; the children after it
	// belong to it, which the indentation cannot show.
	if s.left {
		baldr.column(ui, flex = 1, align = .Center, gap = .sm, padding = .xs)
	} else {
		baldr.row(ui, flex = 1, align = .Center, gap = .sm, padding = .xs)
		baldr.text(ui, "Bar with an applet", role = .Title)
		baldr.spacer(ui)
		if !s.attached do baldr.text(ui, "the clock is starting…" if s.starts < MAX_STARTS else "the clock keeps ending", muted = true)
	}
	defer baldr.end(ui)
	baldr.applet_slot(ui, proc(e: baldr.Ev(baldr.Slot_Event)) -> Msg { return Slot_Report{e.value} },
		s.clock_min, s.clock_len, label = "Clock applet", key = CLOCK)
	baldr.button(ui, "Quit", Msg(Quit{}), variant = .Ghost)
}

main :: proc() {
	err := baldr.run(baldr.App(State, Msg){
		app_id   = "dev.baldr.bar",
		init     = proc() -> State { return {clock_len = 160, clock_min = 80, left = slice.contains(os.args, "--left"), fit = slice.contains(os.args, "--fit")} },
		update   = update,
		view     = view,
		surfaces = surfaces,
	})
	if err != .None do fmt.eprintln("exit:", err)
}
