package main

// A picture you can handle. A 4096 × 3072 raw picture
// (SPIKE_RAW) fitted in the window: the wheel zooms about the pointer,
// a double-click goes fit ↔ 100 %, a drag pans it (pointer_track, from
// where the press was), and the pointer is a hand over a picture that
// pans, a closed one while it does. Each thing it does is logged.

import "core:fmt"
import "core:math"
import "core:os"
import "baldr:baldr"

W :: 4096
H :: 3072

State :: struct {
	img:     baldr.Image,
	zoom:    f32,     // 1: fitted
	centre:  [2]f32,  // in picture px
	panning: bool,
	from:    [2]f32,  // centre when the drag's press was
	vp:      [2]f32,
	ds:      f32,
}

Msg :: union { baldr.Scroll, baldr.Pointer_At, Double }
Double :: struct {}

fit :: proc(s: ^State) -> f32 { return min(s.vp.x / W, s.vp.y / H) } // logical px per picture px, fitted
scale :: proc(s: ^State) -> f32 { return fit(s) * s.zoom }

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch v in m {
	case baldr.Scroll:
		if v.steps.y == 0 do break
		before := scale(s)
		p := s.centre + (v.pos - s.vp / 2) / before // the picture point under the pointer
		s.zoom = clamp(s.zoom * math.pow(f32(1.25), f32(-v.steps.y)), 1, 32)
		s.centre = p - (v.pos - s.vp / 2) / scale(s) // …stays under it
		fmt.eprintfln("picture: wheel %d at %v: zoom %.3f, point under the pointer %.1f", v.steps.y, v.pos, s.zoom, p)
	case Double:
		actual := 1 / (fit(s) * s.ds) // one picture px to one screen px
		s.zoom = actual if s.zoom < actual * 0.99 else 1
		if s.zoom == 1 do s.centre = {W / 2, H / 2}
		fmt.eprintfln("picture: double-click: zoom %.3f (100 %% is %.3f)", s.zoom, actual)
	case baldr.Pointer_At:
		if v.held && !s.panning {
			s.panning, s.from = true, s.centre
			fmt.eprintfln("picture: pan starts, pressed at %v, first report at %v", v.press, v.pos)
		}
		if s.panning {
			s.centre = s.from - (v.pos - v.press) / scale(s)
			if !v.held {
				s.panning = false
				fmt.eprintfln("picture: pan ends, moved %v, centre %.1f", v.pos - v.press, s.centre)
			}
		}
	}
	return {}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	s.vp, s.ds = baldr.viewport(ui), baldr.device_scale(ui)
	baldr.column(ui, flex = 1); defer baldr.end(ui)
	sc := scale(s)
	size := s.vp / sc
	src := baldr.Rect{s.centre.x - size.x / 2, s.centre.y - size.y / 2, size.x, size.y}
	if s.zoom == 1 do src = {}
	pic := baldr.image(ui, &s.img, width = s.vp.x, height = s.vp.y, fit = .Contain, source = src, label = "Test picture")
	baldr.pointer_area(ui, pic, on_scroll = proc(e: baldr.Ev(baldr.Scroll)) -> Msg { return e.value },
		on_double_click = Msg(Double{}),
		cursor = .Grabbing if s.panning else .Grab if s.zoom > 1 else .Default)
	baldr.pointer_track(ui, pic, proc(e: baldr.Ev(baldr.Pointer_At)) -> Msg { return e.value })
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Handle", app_id = "dev.baldr.picture_handle", size = {1200, 690},
		init = proc() -> (s: State) {
			data, err := os.read_entire_file_from_path(os.get_env("SPIKE_RAW", context.temp_allocator), context.allocator)
			if err == nil {
				s.img, _ = baldr.image_from_rgba(W, H, data)
				delete(data)
			}
			s.zoom, s.centre, s.ds = 1, {W / 2, H / 2}, 1
			return
		},
		update = update, view = view,
	})
}
