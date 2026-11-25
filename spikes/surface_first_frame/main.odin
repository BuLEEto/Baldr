// surface_first_frame — how long a surface opened from `update` takes to
// show its first frame, with nothing else waking the loop.
//
// A window ticks once a second, as a clock in a bar does. 1.7 s in (off the
// tick's phase) a message opens a layer surface the way a notification
// toast does. Run with WAYLAND_DEBUG=1 and compare the layer surface's
// configure with its first attach: they should be milliseconds apart, not
// as far as the next tick. SFF_FIT=1 fits its height to the content,
// SFF_GLASS=1 makes it transparent glass, SFF_TICK=0 drops the clock.
//
//   ./build.sh spike surface_first_frame && WAYLAND_DEBUG=1 build/surface_first_frame
package main

import "core:fmt"
import "core:os"
import "core:time"
import "baldr:baldr"

State :: struct { open: bool, asked: time.Tick, ticks: int, built: bool }

Msg :: union { Open, Tick }
Open :: struct {}
Tick :: struct {}

env_on :: proc(name: string) -> bool { return os.get_env(name, context.temp_allocator) == "1" }

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "first frame", app_id = "baldr.firstframe", size = {360, 120},
		init = proc() -> State { return {} },
		start = proc(s: ^State) -> baldr.Cmd(Msg) { return baldr.delay(Msg, 1700, Msg(Open{})) },
		subscriptions = proc(s: ^State, out: ^[dynamic]baldr.Sub(Msg)) {
			if os.get_env("SFF_TICK", context.temp_allocator) != "0" do append(out, baldr.every(Msg, 1000, Msg(Tick{})))
		},
		surfaces = proc(s: ^State, out: ^[dynamic]baldr.Surface_Desc(Msg)) {
			append(out, baldr.Surface_Desc(Msg){tag = 1, title = "first frame", size = {360, 120}})
			if !s.open do return
			d := baldr.Surface_Desc(Msg){tag = 2, kind = .Layer, title = "toast", size = {418, baldr.FIT if env_on("SFF_FIT") else 96}}
			d.layer.level = .Overlay
			d.layer.anchor = {.Top, .Right}
			d.layer.keyboard = .None
			if env_on("SFF_GLASS") {
				d.transparent, d.backdrop = true, .Blur
			}
			append(out, d)
		},
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			switch _ in m {
			case Open:
				s.open, s.asked = true, time.tick_now()
				fmt.eprintfln("sff: opened from update")
			case Tick:
				s.ticks += 1
			}
			return {}
		},
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			if ui.surface.tag == 2 {
				if !s.built {
					s.built = true
					fmt.eprintfln("sff: toast first built %.1f ms after update", time.duration_milliseconds(time.tick_since(s.asked)))
				}
				baldr.column(ui, padding = .lg, gap = .sm, bg = ui.theme.color.surface, radius = 14); defer baldr.end(ui)
				baldr.text(ui, "A notification", role = .Title)
				baldr.text(ui, "shown as soon as it is opened", muted = true)
				return
			}
			baldr.column(ui, padding = .lg); defer baldr.end(ui)
			baldr.text(ui, fmt.tprintf("ticks: %d", s.ticks))
		},
	})
}
