// canvas_parity — does the transform shader agree with the CPU
// reference? The reference is the spec, so the shader is only right if it
// matches. Runs the same transforms both ways and prints the worst
// difference per case.
//
//   ./build.sh spike canvas_parity run
package main

import "core:fmt"
import "core:math"
import "core:os"
import "baldr:baldr"

W :: 64
H :: 64

State :: struct { g: baldr.Gpu, gpu_ready: bool, pending: int, worst: f32, cases: int }

Msg :: union { Ready, Read_Back }
Ready     :: struct { gpu: baldr.Gpu }
Read_Back :: struct { read: baldr.Canvas_Read, which: u64 }

Case :: struct { name: string, m: matrix[3, 3]f32, filter: baldr.Resample }

cases := []Case{
	{"move by 3, 1",      {1, 0, 3, 0, 1, 1, 0, 0, 1},                       .Bilinear},
	{"scale ×2",          {2, 0, 0, 0, 2, 0, 0, 0, 1},                       .Bilinear},
	{"scale ×0.25",       {0.25, 0, 0, 0, 0.25, 0, 0, 0, 1},                 .Bilinear},
	{"rotate 30°",        {0.8660254, -0.5, 20, 0.5, 0.8660254, 4, 0, 0, 1}, .Bilinear},
	{"rotate 30°, cubic", {0.8660254, -0.5, 20, 0.5, 0.8660254, 4, 0, 0, 1}, .Bicubic},
	{"nearest ×0.5",      {0.5, 0, 0, 0, 0.5, 0, 0, 0, 1},                   .Nearest},
	{"skew + lanczos",    {1, 0.35, 2, 0, 1, 2, 0, 0, 1},                    .Lanczos3},
}

// paint_source fills a canvas with something a resampler can get wrong: a
// checkerboard under a gradient, with a transparent corner.
paint_source :: proc(g: baldr.Gpu, c: baldr.Canvas) {
	for y in 0 ..< H do for x in 0 ..< W {
		check: f32 = 1 if ((x / 4) + (y / 4)) % 2 == 0 else 0.2
		a: f32 = 0 if x < 8 && y < 8 else 1
		baldr.canvas_fill(g, c, x, y, 1, 1, {check, f32(x) / W, f32(y) / H, a})
	}
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "canvas parity", app_id = "baldr.parity", size = {320, 120},
		init = proc() -> State { return {} },
		start = proc(s: ^State) -> baldr.Cmd(Msg) {
			return baldr.gpu_open(Msg, proc(e: baldr.Ev(baldr.Gpu)) -> Msg { return Ready{e.value} })
		},
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			switch v in m {
			case Ready:
				s.g = v.gpu
				if s.g.host == nil {
					fmt.println("no GPU")
					os.exit(1)
				}
				cmds := make([dynamic]baldr.Cmd(Msg), context.temp_allocator)
				for c, i in cases {
					src, _ := baldr.canvas_create(s.g, {W, H}, .RGBA8)
					dst, _ := baldr.canvas_create(s.g, {W * 2, H * 2}, .RGBA8)
					paint_source(s.g, src)
					if !baldr.canvas_transform(s.g, src, 0, 0, W, H, dst, c.m, c.filter) {
						fmt.printfln("%s: refused", c.name)
						os.exit(2)
					}
					append(&cmds, baldr.canvas_read(Msg, s.g, dst, 0, 0, W * 2, H * 2,
						proc(e: baldr.Ev(baldr.Canvas_Read)) -> Msg { return Read_Back{e.value, e.tag} }, tag = u64(i)))
					s.pending += 1
				}
				return baldr.batch(Msg, ..cmds[:])
			case Read_Back:
				c := cases[v.which]
				// the same case on the CPU reference, texel for texel
				ref := baldr.gpu_reference()
				defer baldr.gpu_close(&ref)
				rsrc, _ := baldr.canvas_create(ref, {W, H}, .RGBA8)
				rdst, _ := baldr.canvas_create(ref, {W * 2, H * 2}, .RGBA8)
				paint_source(ref, rsrc)
				baldr.canvas_transform(ref, rsrc, 0, 0, W, H, rdst, c.m, c.filter)
				want, _ := baldr.canvas_read_now(ref, rdst, 0, 0, W * 2, H * 2, context.temp_allocator)
				got := v.read.pixels
				worst: f32
				at: [2]int
				for i in 0 ..< min(len(got), len(want)) {
					d := abs(f32(got[i]) - f32(want[i])) / 255
					if d > worst {
						worst = d
						at = {(i / 4) % (W * 2), (i / 4) / (W * 2)}
					}
				}
				fmt.printfln("%-20s worst %.4f at %v", c.name, worst, at)
				s.worst = max(s.worst, worst)
				s.cases += 1
				s.pending -= 1
				if s.pending == 0 {
					fmt.printfln("--- %d cases, worst difference %.4f", s.cases, s.worst)
					os.exit(0 if s.worst < 0.02 else 3) // 5/255: rounding, not a different algorithm
				}
			}
			return {}
		},
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			baldr.column(ui, padding = .lg); {
				defer baldr.end(ui)
				baldr.text(ui, "comparing the shader with the reference…")
			}
		},
	})
}
