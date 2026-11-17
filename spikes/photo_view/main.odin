package main

// A photo at its own resolution. Shows a raw RGBA8 picture
// (SPIKE_RAW, SPIKE_W × SPIKE_H) filling the window:
//   SPIKE_MODE=fit   all of it, fitted (drawn smaller: its mip levels)
//   SPIKE_MODE=zoom  100 %: one picture pixel to one screen pixel, from
//                    SPIKE_X, SPIKE_Y — a `source` the window's size in
//                    device pixels (device_scale), in a window-sized node
//   SPIKE_MODE=cycle eight copies, a new one every 300 ms (a viewer going
//                    through photos), then the last one stays, repainted
//                    each tick: the ones left behind go past the budget
//                    (BALDR_DEBUG_FRAMES counts what stays)

import "core:fmt"
import "core:os"
import "core:strconv"
import "baldr:baldr"

Msg :: enum { None, Next }

State :: struct {
	img:   baldr.Image,
	zoom:  bool,
	at:    [2]f32,
	cycle: bool,
	all:   [8]baldr.Image,
	shown: int,
}

env_int :: proc(name: string, fallback: int) -> int {
	v, ok := strconv.parse_int(os.get_env(name, context.temp_allocator))
	return v if ok else fallback
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	vp := baldr.viewport(ui)
	baldr.column(ui, flex = 1); defer baldr.end(ui)
	if s.cycle {
		baldr.image(ui, &s.all[min(s.shown, len(s.all) - 1)], width = vp.x, height = vp.y, fit = .Contain, label = "Test picture",
			radius = f32(s.shown % 2)) // past the last: a repaint a tick
		return
	}
	if !s.zoom {
		baldr.image(ui, &s.img, width = vp.x, height = vp.y, fit = .Contain, label = "Test picture")
		return
	}
	ds := baldr.device_scale(ui)
	baldr.image(ui, &s.img, width = vp.x, height = vp.y, fit = .Stretch, label = "Test picture at 100 %",
		source = {s.at.x, s.at.y, vp.x * ds, vp.y * ds})
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Photo", app_id = "dev.baldr.photo_view", size = {1200, 900},
		init = proc() -> (s: State) {
			w, h := env_int("SPIKE_W", 4096), env_int("SPIKE_H", 3072)
			data, err := os.read_entire_file_from_path(os.get_env("SPIKE_RAW", context.temp_allocator), context.allocator)
			if err != nil {
				fmt.eprintln("photo_view: SPIKE_RAW:", err)
				return
			}
			ok: bool
			s.img, ok = baldr.image_from_rgba(w, h, data)
			delete(data)
			if !ok do fmt.eprintln("photo_view: not", w, "×", h, "RGBA8")
			s.zoom = os.get_env("SPIKE_MODE", context.temp_allocator) == "zoom"
			s.cycle = os.get_env("SPIKE_MODE", context.temp_allocator) == "cycle"
			if s.cycle do for &c in s.all do c, _ = baldr.image_from_rgba(w, h, s.img.pixels) // each its own picture
			s.at = {f32(env_int("SPIKE_X", 0)), f32(env_int("SPIKE_Y", 0))}
			return
		},
		view = view,
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			if m == .Next do s.shown += 1
			return {}
		},
		subscriptions = proc(s: ^State, out: ^[dynamic]baldr.Sub(Msg)) {
			if s.cycle do append(out, baldr.every(Msg, 300, Msg.Next))
		},
	})
}
