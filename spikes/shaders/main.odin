package main

// An app's own shaders on canvases. A fragment shader
// reading an input with uniforms (channels swapped, scaled), one reading
// the backdrop (a blend of its own), and a compute shader writing a pattern
// into part of a canvas; each result read back and checked against what the
// spike works out itself, including texels outside the rectangle left as
// they were.

import "core:fmt"
import "core:mem"
import "baldr:baldr"

S :: 32

// Both backends' code for each shader, which is what an app ships: the
// Vulkan backend takes the SPIR-V, the Metal one the MSL, and
// shader_create picks without being told which it is on.
SWAP_SPV    := #load("swap.frag.spv", []u32)
DIFF_SPV    := #load("diff.frag.spv", []u32)
PATTERN_SPV := #load("pattern.comp.spv", []u32)
SWAP_MSL    :: #load("swap.metal", string)
DIFF_MSL    :: #load("diff.metal", string)
PATTERN_MSL :: #load("pattern.metal", string)

State :: struct {
	g:       baldr.Gpu,
	src, a, b, c: baldr.Canvas,
	ready:   bool,
}

Read :: struct { tag: u64, read: baldr.Canvas_Read }
Msg :: union { baldr.Gpu, Read }

colour :: proc(x, y: int) -> [4]u8 { return {u8(x * 8), u8(y * 8), u8((x + y) * 4), 255} }

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch v in m {
	case baldr.Gpu:
		g := v
		s.g = g
		fmt.eprintfln("shaders: storage formats %v", baldr.gpu_limits(g).storage)
		swap_code    := baldr.Shader_Code{spirv = SWAP_SPV, msl = SWAP_MSL}
		diff_code    := baldr.Shader_Code{spirv = DIFF_SPV, msl = DIFF_MSL}
		pattern_code := baldr.Shader_Code{spirv = PATTERN_SPV, msl = PATTERN_MSL}
		swap, ok1 := baldr.shader_create(g, .Fragment, swap_code, inputs = 1)
		diff, ok2 := baldr.shader_create(g, .Fragment, diff_code, inputs = 1, backdrop = true)
		pattern, ok3 := baldr.shader_create(g, .Compute, pattern_code, inputs = 0)
		_, bad := baldr.shader_create(g, .Compute, swap_code, inputs = 1) // a fragment shader called compute
		fmt.eprintfln("shaders: made %v %v %v; the wrong stage refused: %v", ok1, ok2, ok3, !bad)
		px := make([]u8, S * S * 4, context.temp_allocator)
		for y in 0 ..< S do for x in 0 ..< S { c := colour(x, y); copy(px[(y * S + x) * 4:], c[:]) }
		s.src, _ = baldr.canvas_create(g, {S, S})
		baldr.canvas_write(g, s.src, 0, 0, S, S, px)
		s.a, _ = baldr.canvas_create(g, {S, S})
		scale := f32(0.5)
		baldr.canvas_shader(g, swap, s.a, 0, 0, S, S, {s.src}, mem.ptr_to_bytes(&scale))
		s.b, _ = baldr.canvas_create(g, {S, S})
		baldr.canvas_fill(g, s.b, 0, 0, S, S, {0.25, 0.5, 0.75, 1})
		baldr.canvas_shader(g, diff, s.b, 4, 4, 24, 24, {s.src})
		s.c, _ = baldr.canvas_create(g, {S, S})
		baldr.canvas_fill(g, s.c, 0, 0, S, S, {0, 0, 0, 1})
		level := f32(0.6)
		baldr.canvas_shader(g, pattern, s.c, 8, 8, 20, 12, nil, mem.ptr_to_bytes(&level))
		s.ready = true
		on :: proc(e: baldr.Ev(baldr.Canvas_Read)) -> Msg { return Read{e.tag, e.value} }
		return baldr.batch(Msg, baldr.canvas_read(Msg, g, s.a, 0, 0, S, S, on, tag = 1), baldr.canvas_read(Msg, g, s.b, 0, 0, S, S, on, tag = 2), baldr.canvas_read(Msg, g, s.c, 0, 0, S, S, on, tag = 3))
	case Read:
		worst, n := 0, 0
		for y in 0 ..< S do for x in 0 ..< S {
			got := v.read.pixels[(y * S + x) * 4:][:4]
			c := colour(x, y)
			want: [4]u8
			switch v.tag {
			case 1: want = {u8(f32(c.b) * 0.5 + 0.5), u8(f32(c.g) * 0.5 + 0.5), u8(f32(c.r) * 0.5 + 0.5), 255}
			case 2:
				back := [3]f32{0.25, 0.5, 0.75}
				inside := x >= 4 && x < 28 && y >= 4 && y < 28
				want = {64, 128, 191, 255}
				if inside {
					for k in 0 ..< 3 {
						d := f32(c[k]) / 255 - f32(u8(back[k] * 255 + 0.5)) / 255
						want[k] = u8(d * d * 255 + 0.5)
					}
				}
			case 3:
				inside := x >= 8 && x < 28 && y >= 8 && y < 20
				want = {u8(x - 8), u8(y - 8), 153, 255} if inside else [4]u8{0, 0, 0, 255}
			}
			for k in 0 ..< 4 {
				d := abs(int(got[k]) - int(want[k]))
				worst = max(worst, d)
				if d > 1 do n += 1
			}
		}
		names := [4]string{"", "fragment + uniforms", "fragment + backdrop", "compute"}
		fmt.eprintfln("shaders: %-20s worst %d, %d values off by more than 1", names[v.tag], worst, n)
	}
	return {}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.row(ui, flex = 1, padding = .md, gap = .md); defer baldr.end(ui)
	if !s.ready do return
	for c, i in ([]baldr.Canvas{s.a, s.b, s.c}) do baldr.canvas(ui, s.g, c, width = 128, pixelated = true, key = u64(i + 1))
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Shaders", app_id = "dev.baldr.shaders", size = {3 * 144 + 32, 170},
		init = proc() -> (s: State) { return },
		start = proc(s: ^State) -> baldr.Cmd(Msg) { return baldr.gpu_open(Msg, proc(e: baldr.Ev(baldr.Gpu)) -> Msg { return e.value }) },
		update = update,
		view = view,
	})
}
