package main

// The 27 blend modes on the GPU against the CPU reference. A source (colour ramps, alpha falling across it) is laid on a
// backdrop (other ramps, alpha falling down it) through a soft mask, in
// every mode, on the GPU and on the reference; the GPU's results are read
// back and each mode's largest difference logged (in code values). The 27
// results show in a grid.

import "core:fmt"
import "baldr:baldr"

S :: 64

State :: struct {
	g:       baldr.Gpu,
	ref:     baldr.Gpu,
	out:     [27]baldr.Canvas,
	want:    [3][27][]u8, // the reference's texels, per round (8-bit, 16-bit, 8-bit linear)
	ready:   bool,
	reads:   int,
}

Read :: struct { tag: u64, read: baldr.Canvas_Read }
Msg :: union { baldr.Gpu, Read }

texels :: proc(f: baldr.Canvas_Format, fill: proc(x, y: int) -> [4]f32) -> []u8 {
	bpp := 4 if f == .RGBA8 else 8
	out := make([]u8, S * S * bpp)
	for y in 0 ..< S do for x in 0 ..< S {
		v := fill(x, y)
		for k in 0 ..< 4 {
			if f == .RGBA8 {
				out[(y * S + x) * 4 + k] = u8(clamp(v[k], 0, 1) * 255 + 0.5)
			} else {
				q := u16(clamp(v[k], 0, 1) * 65535 + 0.5)
				out[(y * S + x) * 8 + 2 * k], out[(y * S + x) * 8 + 2 * k + 1] = u8(q), u8(q >> 8)
			}
		}
	}
	return out
}

back :: proc(x, y: int) -> [4]f32 { return {f32(x) / (S - 1), f32(y) / (S - 1), 0.5 + 0.5 * f32((x + y) % 7) / 6, 1 - 0.6 * f32(y) / (S - 1)} }
front :: proc(x, y: int) -> [4]f32 { return {f32(y) / (S - 1), 1 - f32(x) / (S - 1), f32((x * 3 + y) % 11) / 10, 1 - 0.7 * f32(x) / (S - 1)} }
soft :: proc(x, y: int) -> [4]f32 { v := 0.3 + 0.7 * f32(x + y) / (2 * S - 2); return {v, v, v, 1} }

// round runs every mode on `g` in `format` (linear maths or not) into
// fresh canvases, returning them.
round :: proc(g: baldr.Gpu, format: baldr.Canvas_Format, linear: bool) -> (outs: [27]baldr.Canvas) {
	src, _ := baldr.canvas_create(g, {S, S}, format)
	mask, _ := baldr.canvas_create(g, {S, S}, format)
	baldr.canvas_write(g, src, 0, 0, S, S, texels(format, front))
	baldr.canvas_write(g, mask, 0, 0, S, S, texels(format, soft))
	for m in 0 ..< 27 {
		outs[m], _ = baldr.canvas_create(g, {S, S}, format)
		baldr.canvas_write(g, outs[m], 0, 0, S, S, texels(format, back))
		baldr.canvas_blend(g, src, 0, 0, S, S, outs[m], {0, 0}, baldr.Blend_Mode(m), opacity = 0.9, mask = mask, linear = linear, seed = 7)
	}
	return
}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch v in m {
	case baldr.Gpu:
		s.g = v
		s.ref = baldr.gpu_reference()
		cmds := make([dynamic]baldr.Cmd(Msg), context.temp_allocator)
		formats := [3]baldr.Canvas_Format{.RGBA8, .RGBA16, .RGBA8}
		for r in 0 ..< 3 {
			linear := r == 2
			gpu_outs := round(v, formats[r], linear)
			ref_outs := round(s.ref, formats[r], linear)
			for m in 0 ..< 27 {
				bytes := 4 if formats[r] == .RGBA8 else 8
				_ = bytes
				s.want[r][m], _ = baldr.canvas_read_now(s.ref, ref_outs[m], 0, 0, S, S)
				append(&cmds, baldr.canvas_read(Msg, v, gpu_outs[m], 0, 0, S, S, proc(e: baldr.Ev(baldr.Canvas_Read)) -> Msg { return Read{e.tag, e.value} }, tag = u64(r * 100 + m)))
			}
			if r == 0 do s.out = gpu_outs
		}
		s.ready = true
		return baldr.batch(Msg, ..cmds[:])
	case Read:
		r, mode := int(v.tag / 100), int(v.tag % 100)
		want := s.want[r][mode]
		worst, off := 0, 0
		wide := v.read.format == .RGBA16
		n := len(want) / 2 if wide else len(want)
		for i in 0 ..< n {
			a, b: int
			if wide {
				a = int(u16(v.read.pixels[2 * i]) | u16(v.read.pixels[2 * i + 1]) << 8) >> 8 // compared at 8-bit steps
				b = int(u16(want[2 * i]) | u16(want[2 * i + 1]) << 8) >> 8
			} else {
				a, b = int(v.read.pixels[i]), int(want[i])
			}
			d := abs(a - b)
			worst = max(worst, d)
			if d > 1 do off += 1
		}
		names := [3]string{"8-bit", "16-bit", "8-bit linear"}
		fmt.eprintfln("blend: %-12s %-14v worst %d, %d values off by more than 1 (of %d)", names[r], baldr.Blend_Mode(mode), worst, off, n)
		s.reads += 1
	}
	return {}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, flex = 1, padding = .sm, gap = .xs); defer baldr.end(ui)
	if !s.ready do return
	for row in 0 ..< 3 {
		baldr.row(ui, gap = .xs, key = u64(row + 1)); defer baldr.end(ui)
		for col in 0 ..< 9 {
			m := row * 9 + col
			baldr.column(ui, key = u64(m + 1)); defer baldr.end(ui)
			baldr.text(ui, fmt.tprintf("%v", baldr.Blend_Mode(m)), role = .Caption)
			baldr.canvas(ui, s.g, s.out[m], width = 96)
		}
	}
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Blend", app_id = "dev.baldr.blend", size = {9 * 100 + 24, 3 * 120 + 24},
		init = proc() -> (s: State) { return },
		start = proc(s: ^State) -> baldr.Cmd(Msg) { return baldr.gpu_open(Msg, proc(e: baldr.Ev(baldr.Gpu)) -> Msg { return e.value }) },
		update = update,
		view = view,
	})
}
