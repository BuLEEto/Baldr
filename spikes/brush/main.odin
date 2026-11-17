package main

// Brush strokes on the GPU against the CPU reference.
// A wavy stroke with the pressure rising and falling is laid three ways — a
// soft round brush into a 16-bit stroke, a low flow into an 8-bit one (its
// build-up in steps), a star tip turning along the way — each painted onto
// a layer in its colour, and an eraser stroke across all three. Every
// canvas is read back and its largest difference from the reference
// logged; the layer shows.

import "core:fmt"
import "core:math"
import "baldr:baldr"

W :: 360
H :: 150

State :: struct {
	g, ref: baldr.Gpu,
	layer:  baldr.Canvas,
	want:   [4][]u8,
	fmts:   [4]baldr.Canvas_Format,
	ready:  bool,
}

Read :: struct { tag: u64, read: baldr.Canvas_Read }
Msg :: union { baldr.Gpu, Read }

// wave is the stroke's path: pointer samples along a sine, pressure rising
// then falling.
wave :: proc(brush: baldr.Brush, y0: f32, angle_turns: bool) -> []baldr.Dab {
	out := make([dynamic]baldr.Dab)
	path: baldr.Brush_Path
	b := brush
	for i in 0 ..= 60 {
		t := f32(i) / 60
		at := [2]f32{20 + t * (W - 40), y0 + 14 * math.sin(t * 9)}
		if angle_turns do b.angle = t * 6
		baldr.brush_stroke(b, &path, at, 0.2 + 0.8 * math.sin(t * math.PI), &out)
	}
	return out[:]
}

paint :: proc(g: baldr.Gpu) -> (layer: baldr.Canvas, strokes: [3]baldr.Canvas) {
	layer, _ = baldr.canvas_create(g, {W, H})
	baldr.canvas_fill(g, layer, 0, 0, W, H, {0.97, 0.96, 0.92, 1})
	star, _ := baldr.canvas_create(g, {32, 32})
	for y in 0 ..< 32 do for x in 0 ..< 32 { // a four-pointed star, drawn by distance
		dx, dy := abs(f32(x) - 15.5), abs(f32(y) - 15.5)
		v := clamp(1 - (dx * dy / 18 + max(dx, dy) / 16), 0, 1)
		baldr.canvas_fill(g, star, x, y, 1, 1, {v, v, v, 1})
	}
	soft := baldr.Brush{size = 22, hardness = 0.3, flow = 0.9, spacing = 0.15, size_pressure = true}
	low := baldr.Brush{size = 18, hardness = 0.8, flow = 0.12, spacing = 0.1}
	tip := baldr.Brush{size = 26, hardness = 1, flow = 1, spacing = 0.35, flow_pressure = true}
	colours := [3][4]f32{{0.1, 0.35, 0.8, 1}, {0.85, 0.2, 0.15, 1}, {0.1, 0.55, 0.3, 1}}
	fmts := [3]baldr.Canvas_Format{.RGBA16, .RGBA8, .RGBA16}
	for i in 0 ..< 3 {
		strokes[i], _ = baldr.canvas_create(g, {W, H}, fmts[i], .Linear)
		brush := soft if i == 0 else low if i == 1 else tip
		baldr.canvas_dabs(g, strokes[i], wave(brush, 30 + f32(i) * 45, i == 2), star if i == 2 else 0)
		baldr.canvas_paint(g, layer, 0, 0, W, H, colours[i], opacity = 0.9, mask = strokes[i])
	}
	eraser, _ := baldr.canvas_create(g, {W, H}, .RGBA16, .Linear)
	path: baldr.Brush_Path
	dabs := make([dynamic]baldr.Dab)
	for i in 0 ..= 20 do baldr.brush_stroke({size = 16, hardness = 0.6, flow = 1, spacing = 0.2}, &path, {W / 2 + 10 * math.sin(f32(i)), 5 + f32(i) * 7}, 1, &dabs)
	baldr.canvas_dabs(g, eraser, dabs[:])
	baldr.canvas_paint(g, layer, 0, 0, W, H, {0, 0, 0, 1}, mask = eraser, erase = true)
	return
}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch v in m {
	case baldr.Gpu:
		s.g = v
		s.ref = baldr.gpu_reference()
		layer, strokes := paint(v)
		rlayer, rstrokes := paint(s.ref)
		s.layer = layer
		gpu_c := [4]baldr.Canvas{layer, strokes[0], strokes[1], strokes[2]}
		ref_c := [4]baldr.Canvas{rlayer, rstrokes[0], rstrokes[1], rstrokes[2]}
		s.fmts = {.RGBA8, .RGBA16, .RGBA8, .RGBA16}
		cmds := make([dynamic]baldr.Cmd(Msg), context.temp_allocator)
		for i in 0 ..< 4 {
			s.want[i], _ = baldr.canvas_read_now(s.ref, ref_c[i], 0, 0, W, H)
			append(&cmds, baldr.canvas_read(Msg, v, gpu_c[i], 0, 0, W, H, proc(e: baldr.Ev(baldr.Canvas_Read)) -> Msg { return Read{e.tag, e.value} }, tag = u64(i)))
		}
		s.ready = true
		return baldr.batch(Msg, ..cmds[:])
	case Read:
		i := int(v.tag)
		wide := s.fmts[i] == .RGBA16
		n := W * H * 4
		worst: f32
		off := 0
		for k in 0 ..< n {
			a, b: f32
			if wide {
				a = f32(u16(v.read.pixels[2 * k]) | u16(v.read.pixels[2 * k + 1]) << 8) / 65535 * 255
				b = f32(u16(s.want[i][2 * k]) | u16(s.want[i][2 * k + 1]) << 8) / 65535 * 255
			} else {
				a, b = f32(v.read.pixels[k]), f32(s.want[i][k])
			}
			worst = max(worst, abs(a - b))
			if abs(a - b) > 1.001 do off += 1
		}
		names := [4]string{"layer (8-bit)", "soft stroke (16)", "low flow (8)", "star tip (16)"}
		fmt.eprintfln("brush: %-18s worst %.2f code values, %d values past 1 (of %d)", names[i], worst, off, n)
	}
	return {}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, flex = 1, padding = .md); defer baldr.end(ui)
	if !s.ready do return
	baldr.canvas(ui, s.g, s.layer, width = W, label = "Painted layer")
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Brush", app_id = "dev.baldr.brush", size = {W + 40, H + 40},
		init = proc() -> (s: State) { return },
		start = proc(s: ^State) -> baldr.Cmd(Msg) { return baldr.gpu_open(Msg, proc(e: baldr.Ev(baldr.Gpu)) -> Msg { return e.value }) },
		update = update,
		view = view,
	})
}
