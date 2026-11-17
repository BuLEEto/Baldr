package main

// The filters on the GPU against the CPU reference.
// Each filter runs on both from the same inputs (a picture of ramps with
// alpha, in several formats and spaces), the GPU's results are read back
// and the largest difference logged, in 8-bit code values. The results show
// in a row.

import "core:fmt"
import "baldr:baldr"

S :: 48

Case :: struct {
	name:    string,
	format:  baldr.Canvas_Format,
	space:   baldr.Color_Space,
	out_fmt: baldr.Canvas_Format,
	out_sp:  baldr.Color_Space,
	in_place: bool,
}

CASES := [?]Case{
	{"invert",          .RGBA8, .sRGB, .RGBA8, .sRGB, true},
	{"saturate 0.3",    .RGBA16, .sRGB, .RGBA16, .sRGB, false},
	{"matrix linear",   .RGBA8, .sRGB, .RGBA8, .sRGB, false},
	{"curves",          .RGBA8, .sRGB, .RGBA8, .sRGB, true},
	{"convert P3→sRGB", .RGBA8, .Display_P3, .RGBA8, .sRGB, false},
	{"convert →linear", .RGBA8, .sRGB, .RGBA16, .Linear, false},
	{"convert Adobe→P3", .RGBA16, .Adobe_RGB, .RGBA8, .Display_P3, false},
	{"lut",             .RGBA8, .sRGB, .RGBA8, .sRGB, false},
	{"blur 3",          .RGBA8, .sRGB, .RGBA8, .sRGB, true},
	{"blur 2 linear",   .RGBA16, .sRGB, .RGBA16, .sRGB, false},
	{"blur 1.2 float",  .RGBA32F, .Linear, .RGBA32F, .Linear, false},
	{"sharpen",         .RGBA8, .sRGB, .RGBA8, .sRGB, false},
}

State :: struct {
	g, ref: baldr.Gpu,
	shown:  [len(CASES)]baldr.Canvas,
	want:   [len(CASES)][]u8,
	ready:  bool,
}

Read :: struct { tag: u64, read: baldr.Canvas_Read }
Msg :: union { baldr.Gpu, Read }

picture :: proc(x, y: int) -> [4]f32 {
	return {f32(x) / (S - 1), f32(y) / (S - 1), 0.5 + 0.5 * f32((x * 7 + y * 3) % 13) / 12, 1 if x > 10 else 0.25 + 0.07 * f32(x)}
}

texels :: proc(f: baldr.Canvas_Format) -> []u8 {
	bpp := 4 if f == .RGBA8 else 8 if f == .RGBA16 else 16
	out := make([]u8, S * S * bpp)
	for y in 0 ..< S do for x in 0 ..< S {
		v := picture(x, y)
		for k in 0 ..< 4 {
			#partial switch f { // the colour formats: a coverage canvas is not what this checks
			case .RGBA8: out[(y * S + x) * 4 + k] = u8(clamp(v[k], 0, 1) * 255 + 0.5)
			case .RGBA16:
				q := u16(clamp(v[k], 0, 1) * 65535 + 0.5)
				out[(y * S + x) * 8 + 2 * k], out[(y * S + x) * 8 + 2 * k + 1] = u8(q), u8(q >> 8)
			case .RGBA32F:
				b := transmute([4]u8)v[k]
				copy(out[(y * S + x) * 16 + 4 * k:][:4], b[:])
			}
		}
	}
	return out
}

run :: proc(g: baldr.Gpu, i: int) -> baldr.Canvas {
	c := CASES[i]
	src, _ := baldr.canvas_create(g, {S, S}, c.format, c.space)
	baldr.canvas_write(g, src, 0, 0, S, S, texels(c.format))
	dst := src
	if !c.in_place do dst, _ = baldr.canvas_create(g, {S, S}, c.out_fmt, c.out_sp)
	switch i {
	case 0: baldr.canvas_matrix(g, src, 0, 0, S, S, dst, {0, 0}, baldr.COLOR_MATRIX_INVERT)
	case 1: baldr.canvas_matrix(g, src, 0, 0, S, S, dst, {0, 0}, baldr.color_matrix_saturate(0.3))
	case 2: baldr.canvas_matrix(g, src, 0, 0, S, S, dst, {0, 0}, baldr.color_matrix_saturate(1.8), linear = true)
	case 3:
		curve, _ := baldr.canvas_curve_make(g, {{0, 0.1, 0.2, 0}, {0.6, 0.3, 0.2, 0.5}, {0.7, 0.5, 0.9, 1}, {1, 1, 0.3, 1}})
		baldr.canvas_curves(g, src, 0, 0, S, S, dst, {0, 0}, curve)
	case 4, 5, 6: baldr.canvas_convert(g, src, 0, 0, S, S, dst, {0, 0})
	case 7:
		N :: 5
		rgb: [N * N * N][3]f32
		for b in 0 ..< N do for gg in 0 ..< N do for r in 0 ..< N {
			v := [3]f32{f32(r), f32(gg), f32(b)} / (N - 1)
			rgb[(b * N + gg) * N + r] = {v.g * v.g, 1 - v.r, (v.r + v.b) / 2}
		}
		lut, _ := baldr.canvas_lut_make(g, N, rgb[:])
		baldr.canvas_lut(g, src, 0, 0, S, S, dst, {0, 0}, lut)
	case 8:  baldr.canvas_blur(g, src, 0, 0, S, S, dst, {0, 0}, 3)
	case 9:  baldr.canvas_blur(g, src, 0, 0, S, S, dst, {0, 0}, 2, linear = true)
	case 10: baldr.canvas_blur(g, src, 0, 0, S, S, dst, {0, 0}, 1.2)
	case 11: baldr.canvas_sharpen(g, src, 0, 0, S, S, dst, {0, 0}, 1.5, 1.5, threshold = 0.02)
	}
	return dst
}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch v in m {
	case baldr.Gpu:
		s.g = v
		s.ref = baldr.gpu_reference()
		cmds := make([dynamic]baldr.Cmd(Msg), context.temp_allocator)
		for _, i in CASES {
			s.shown[i] = run(v, i)
			s.want[i], _ = baldr.canvas_read_now(s.ref, run(s.ref, i), 0, 0, S, S)
			append(&cmds, baldr.canvas_read(Msg, v, s.shown[i], 0, 0, S, S, proc(e: baldr.Ev(baldr.Canvas_Read)) -> Msg { return Read{e.tag, e.value} }, tag = u64(i)))
		}
		s.ready = true
		return baldr.batch(Msg, ..cmds[:])
	case Read:
		i := int(v.tag)
		c := CASES[i]
		f := c.format if c.in_place else c.out_fmt
		bpp := 4 if f == .RGBA8 else 8 if f == .RGBA16 else 16
		worst: f32
		for t in 0 ..< S * S {
			for k in 0 ..< 4 {
				a := value(f, v.read.pixels[t * bpp:], k)
				b := value(f, s.want[i][t * bpp:], k)
				worst = max(worst, abs(a - b) * 255)
			}
		}
		fmt.eprintfln("filters: %-18s worst %.2f code values (of 255)", c.name, worst)
	}
	return {}
}

value :: proc(f: baldr.Canvas_Format, p: []u8, k: int) -> f32 {
	#partial switch f { // as texels(): the colour formats only

	case .RGBA8:  return f32(p[k]) / 255
	case .RGBA16: return f32(u16(p[2 * k]) | u16(p[2 * k + 1]) << 8) / 65535
	case .RGBA32F: return transmute(f32)[4]u8{p[4 * k], p[4 * k + 1], p[4 * k + 2], p[4 * k + 3]}
	}
	return 0
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, flex = 1, padding = .sm, gap = .xs); defer baldr.end(ui)
	if !s.ready do return
	for line in 0 ..< 2 {
		baldr.row(ui, gap = .xs, key = u64(line + 1)); defer baldr.end(ui)
		for i in line * 6 ..< line * 6 + 6 {
			baldr.column(ui, key = u64(i + 1)); defer baldr.end(ui)
			baldr.text(ui, CASES[i].name, role = .Caption)
			baldr.canvas(ui, s.g, s.shown[i], width = 96)
		}
	}
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Filters", app_id = "dev.baldr.filters", size = {6 * 104 + 24, 2 * 124 + 24},
		init = proc() -> (s: State) { return },
		start = proc(s: ^State) -> baldr.Cmd(Msg) { return baldr.gpu_open(Msg, proc(e: baldr.Ev(baldr.Gpu)) -> Msg { return e.value }) },
		update = update,
		view = view,
	})
}
