// stroke_parity: does the stroke shader agree with the CPU reference?
//
// The reference is the spec (baldr/canvas_stroke.odin), so the shader is
// only right where it matches it. Both paths exist in one process — the
// window's GPU, and a `gpu_reference()` beside it — so the same calls can
// be made twice and the results compared texel for texel.
//
// The cases are the places the two can drift: a taper (the round cone's
// sloping edge, where treating a segment as a capsule would step), a
// self-crossing (the MAX union, where a build-up would darken), a sharp
// corner (the join), a single tap (a segment of no length), and a curve.
//
// It runs twice, because only the runtime's own canvas host is pumped: a
// `gpu_reference()` the app makes itself never has its reads delivered.
// The second run forces the reference with `BALDR_GPU_REFERENCE=1`; each run
// writes its texels beside the binary and compares against the other run's
// when it finds them.
//
//   ./build.sh spike stroke_parity run          # the shader
//   BALDR_GPU_REFERENCE=1 build/stroke_parity   # the reference, and the verdict
package main

import "core:fmt"
import "core:os"
import "baldr:baldr"

W :: 128
H :: 128

Case :: struct { name: string, stroke: baldr.Stroke_Draw }

State :: struct {
	g:    baldr.Gpu,
	got:  [dynamic]Shot,
	want: int,
	ref:  bool, // this run is the CPU reference
}

Shot :: struct { tag: u64, pixels: []u8 }

Msg :: union { Ready, Read_Back }
Ready     :: struct { gpu: baldr.Gpu }
Read_Back :: struct { read: baldr.Canvas_Read, tag: u64 }

taper  := []baldr.Stroke_Point{{{16, 40}, 26}, {{110, 52}, 3}}
cross  := []baldr.Stroke_Point{{{24, 24}, 9}, {{104, 104}, 9}, {{104, 24}, 9}, {{24, 104}, 9}}
corner := []baldr.Stroke_Point{{{30, 30}, 14}, {{96, 30}, 14}, {{96, 96}, 14}}
tap    := []baldr.Stroke_Point{{{64, 64}, 30}}
curve  := []baldr.Stroke_Point{{{20, 100}, 4}, {{45, 40}, 10}, {{70, 96}, 16}, {{100, 30}, 6}}

// The eraser: a solid stroke laid down, then another drawn through it with
// `erase`, which must cut a hole rather than paint over it — so the hole is
// transparent whatever colour the paper is.
erase_under := []baldr.Stroke_Point{{{20, 64}, 34}, {{108, 64}, 34}}
erase_through := []baldr.Stroke_Point{{{64, 18}, 16}, {{64, 110}, 16}}

cases := []Case{
	{"taper 26 -> 3",     {points = taper,  color = {0.9, 0.3, 0.2, 1}}},
	{"crosses itself",    {points = cross,  color = {0.2, 0.5, 0.9, 0.35}}},
	{"sharp corner",      {points = corner, color = {0.1, 0.7, 0.4, 1}}},
	{"one tap",           {points = tap,    color = {0.8, 0.8, 0.2, 1}}},
	{"curve, width vary", {points = curve,  color = {0.6, 0.2, 0.8, 0.6}}},
	{"erased through",    {points = erase_under, color = {0.15, 0.55, 0.75, 1}}},
}

identity :: matrix[3, 3]f32{1, 0, 0, 0, 1, 0, 0, 0, 1}

// draw runs one case on one Gpu and asks for the result back under `tag`.
draw :: proc(g: baldr.Gpu, c: Case, tag: u64) -> baldr.Cmd(Msg) {
	dst, ok := baldr.canvas_create(g, {W, H}, .RGBA8)
	if !ok { fmt.println("no canvas"); os.exit(1) }
	one := []baldr.Stroke_Draw{c.stroke}
	if !baldr.canvas_strokes(g, dst, one, identity) {
		fmt.printfln("%s: refused", c.name)
		os.exit(2)
	}
	if c.name == "erased through" {
		cut := []baldr.Stroke_Draw{{points = erase_through, color = {1, 1, 1, 1}}}
		if !baldr.canvas_strokes(g, dst, cut, identity, .Normal, erase = true) {
			fmt.println("the eraser was refused")
			os.exit(2)
		}
	}
	return baldr.canvas_read(Msg, g, dst, 0, 0, W, H,
		proc(e: baldr.Ev(baldr.Canvas_Read)) -> Msg { return Read_Back{e.value, e.tag} }, tag = tag)
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "stroke parity", app_id = "baldr.strokeparity", size = {360, 120},
		init = proc() -> State { return {} },
		start = proc(s: ^State) -> baldr.Cmd(Msg) {
			return baldr.gpu_open(Msg, proc(e: baldr.Ev(baldr.Gpu)) -> Msg { return Ready{e.value} })
		},
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			switch v in m {
			case Ready:
				s.g = v.gpu
				if s.g.host == nil { fmt.println("no canvases"); os.exit(1) }
				s.ref = !baldr.gpu_limits(s.g).on_gpu
				fmt.printfln("this run: %s", "the CPU reference" if s.ref else "the shader")
				s.got = make([dynamic]Shot)
				s.want = len(cases)
				cmds := make([dynamic]baldr.Cmd(Msg), context.temp_allocator)
				for c, i in cases do append(&cmds, draw(s.g, c, u64(i)))
				return baldr.batch(Msg, ..cmds[:])
			case Read_Back:
				kept := make([]u8, len(v.read.pixels))
				copy(kept, v.read.pixels)
				append(&s.got, Shot{v.tag, kept})
				if len(s.got) >= s.want do report(s)
			}
			return {}
		},
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			baldr.column(ui, flex = 1, padding = .lg); defer baldr.end(ui)
			baldr.text(ui, "comparing the shader with the reference…")
		},
	})
}

report :: proc(s: ^State) {
	mine := "build/stroke_parity.ref" if s.ref else "build/stroke_parity.gpu"
	other := "build/stroke_parity.gpu" if s.ref else "build/stroke_parity.ref"

	// One file, the cases in order, so the two runs line up byte for byte.
	blob := make([dynamic]u8, context.temp_allocator)
	for i in 0 ..< len(cases) {
		for sh in s.got do if sh.tag == u64(i) do append(&blob, ..sh.pixels)
	}
	if werr := os.write_entire_file(mine, blob[:]); werr != nil {
		fmt.printfln("could not write %s: %v", mine, werr)
		os.exit(1)
	}
	fmt.printfln("wrote %s (%d bytes)", mine, len(blob))

	theirs, rerr := os.read_entire_file_from_path(other, context.temp_allocator)
	if rerr != nil {
		fmt.printfln("\nnow run the other way:\n  %s build/stroke_parity",
			"" if s.ref else "BALDR_GPU_REFERENCE=1")
		os.exit(0)
	}
	if len(theirs) != len(blob) {
		fmt.printfln("the two runs drew different amounts (%d vs %d) — stale file?", len(theirs), len(blob))
		os.exit(3)
	}

	per := W * H * 4
	worst_all := 0
	for c, i in cases {
		worst, off := 0, 0
		for k in i * per ..< min((i + 1) * per, len(blob)) {
			d := abs(int(blob[k]) - int(theirs[k]))
			if d > worst { worst = d }
			if d > 1 do off += 1
		}
		worst_all = max(worst_all, worst)
		fmt.printfln("%-20s: worst %3d code values, %6d of %d bytes differ by more than 1",
			c.name, worst, off, per)
	}
	// A code value or two is rounding; more is a real disagreement about what
	// a stroke covers, and the reference is the spec.
	fmt.printfln("\nworst across every case: %d — %s", worst_all,
		"the shader agrees with the reference" if worst_all <= 2 else "THEY DISAGREE: the reference is the spec")
	os.exit(0 if worst_all <= 2 else 4)
}
