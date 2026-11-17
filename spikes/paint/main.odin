package main

// A paint canvas. Every pointer (or pen) sample is a round
// dab into a CPU canvas, and only the dab's rect is uploaded (image_touch).
// Beside it the same picture at a quarter of its size, drawn through its mip
// levels: the strokes show there only if the levels over them are rebuilt.
// Each batch of samples is logged.

import "core:fmt"
import "core:math"
import "baldr:baldr"

W :: 1400
H :: 900

State :: struct {
	canvas:  baldr.Image,
	brush:   baldr.Image, // the brush's outline, as the cursor
	last:    [2]f32,
	drawing: bool,
	batches, samples: int,
}

Msg :: union { baldr.Pointer_Samples }

dab :: proc(s: ^State, p: [2]f32, r: f32, pressure: f32) {
	x0, y0 := int(p.x - r), int(p.y - r)
	x1, y1 := int(p.x + r) + 1, int(p.y + r) + 1
	for y in max(y0, 0) ..< min(y1, H) do for x in max(x0, 0) ..< min(x1, W) {
		d := math.sqrt((f32(x) - p.x) * (f32(x) - p.x) + (f32(y) - p.y) * (f32(y) - p.y))
		a := clamp(r - d, 0, 1) * pressure
		if a <= 0 do continue
		px := s.canvas.pixels[(y * W + x) * 4:]
		ink := [3]u8{30, 60, 200}
		for c in 0 ..< 3 do px[c] = u8(f32(px[c]) * (1 - a) + f32(ink[c]) * a)
	}
	baldr.image_touch(&s.canvas, x0, y0, x1 - x0, y1 - y0)
}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	v := m.(baldr.Pointer_Samples)
	s.batches += 1
	s.samples += len(v.samples)
	for smp in v.samples {
		// the canvas node shows the picture at half its size: back to picture pixels
		p := smp.pos * 2
		switch smp.kind {
		case .Press:   s.drawing, s.last = true, p
		case .Release: s.drawing = false
		case .Move, .Enter, .Leave:
			if !s.drawing do continue
			steps := max(int(math.ceil(max(abs(p.x - s.last.x), abs(p.y - s.last.y)) / 3)), 1)
			for i in 1 ..= steps do dab(s, s.last + (p - s.last) * f32(i) / f32(steps), 6, max(smp.pressure, 0.2))
			s.last = p
		}
	}
	if len(v.samples) > 0 {
		fmt.eprintfln("paint: batch %d, %d samples, %.0f..%.0f ms", s.batches, len(v.samples), v.samples[0].time_ms, v.samples[len(v.samples) - 1].time_ms)
	}
	return {}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.row(ui, flex = 1, gap = .md, padding = .md); defer baldr.end(ui)
	c := baldr.image(ui, &s.canvas, width = W / 2, height = H / 2, fit = .Stretch, label = "Canvas", key = 1)
	baldr.pointer_samples(ui, c, proc(e: baldr.Ev(baldr.Pointer_Samples)) -> Msg { return e.value })
	baldr.pointer_area(ui, c, cursor_image = &s.brush, hotspot = {12, 12})
	baldr.image(ui, &s.canvas, width = W / 8, height = H / 8, fit = .Stretch, label = "Preview", key = 2) // through its mip levels
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Paint", app_id = "dev.baldr.paint", size = {940, 480},
		init = proc() -> (s: State) {
			px := make([]u8, W * H * 4, context.temp_allocator)
			for &b in px do b = 245
			s.canvas, _ = baldr.image_from_rgba(W, H, px)
			ring := make([]u8, 25 * 25 * 4, context.temp_allocator) // a 1 px ring, radius 11: the brush's size, drawn
			for y in 0 ..< 25 do for x in 0 ..< 25 {
				d := math.sqrt(f32((x - 12) * (x - 12) + (y - 12) * (y - 12)))
				a := clamp(1 - abs(d - 11), 0, 1)
				ring[(y * 25 + x) * 4 + 3] = u8(a * 255)
			}
			s.brush, _ = baldr.image_from_rgba(25, 25, ring)
			return
		},
		update = update, view = view,
	})
}
