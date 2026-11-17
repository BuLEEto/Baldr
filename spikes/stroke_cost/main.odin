// stroke_cost: are a few small passes per stroke affordable?
//
// Each variable-width stroke gets its own coverage, because a translucent
// stroke that crosses itself must not darken at the crossing. So the passes
// cannot all merge, and a sketch layer of a couple of thousand strokes is
// several thousand small passes on every pan and zoom frame. This times
// `canvas_strokes` with strokes of a realistic length, drawn as a layer
// redraw draws them, against a 16.6 ms frame.
//
// Timed to *completion*, not to queueing: a `canvas_read` of one texel after
// the batch is what makes the GPU finish before the clock stops.
//
//   ./build.sh spike stroke_cost run
package main

import "core:fmt"
import "core:os"
import "core:math"
import "core:time"
import "baldr:baldr"

SIDE   :: 96   // a stroke's bounding box, texels
CANVAS :: 2048
POINTS :: 100  // samples in a stroke, as a pen gives them

identity :: matrix[3, 3]f32{1, 0, 0, 0, 1, 0, 0, 0, 1}

counts := []int{0, 128, 512, 2048, 8192}

State :: struct {
	g:      baldr.Gpu,
	layer:  baldr.Canvas,
	cover:  baldr.Canvas, // unused: canvas_strokes keeps its own coverage
	at:     int, // which count is being measured
	start:  time.Tick,
	floor:  f64, // what an empty batch costs: read-back latency and frame pacing
}

Msg :: union { Ready, Done }
Ready :: struct { gpu: baldr.Gpu }
Done  :: struct { read: baldr.Canvas_Read }

// make_strokes builds `n` strokes of POINTS samples each, spread over the
// canvas as a drawing's are, with a width that follows a pressure curve.
make_strokes :: proc(n: int) -> []baldr.Stroke_Draw {
	out := make([]baldr.Stroke_Draw, n, context.temp_allocator)
	per := max(CANVAS / SIDE, 1)
	for i in 0 ..< n {
		ox := f32((i % per) * SIDE)
		oy := f32(((i / per) % per) * SIDE)
		pts := make([]baldr.Stroke_Point, POINTS, context.temp_allocator)
		for k in 0 ..< POINTS {
			t := f32(k) / f32(POINTS - 1)
			press := 0.3 + 0.7 * math.sin(t * math.PI) // thin, fat, thin
			pts[k] = {at = {ox + t * SIDE, oy + SIDE * 0.5 + math.sin(t * 6) * SIDE * 0.3}, width = 2 + 10 * press}
		}
		out[i] = {points = pts, color = {0.2, 0.4, 0.9, 1}}
	}
	return out
}

batch :: proc(s: ^State) -> baldr.Cmd(Msg) {
	strokes := make_strokes(counts[s.at])
	s.start = time.tick_now()
	if len(strokes) > 0 && !baldr.canvas_strokes(s.g, s.layer, strokes, identity) {
		fmt.println("canvas_strokes was refused")
		os.exit(2)
	}
	return baldr.canvas_read(Msg, s.g, s.layer, 0, 0, 1, 1,
		proc(e: baldr.Ev(baldr.Canvas_Read)) -> Msg { return Done{e.value} })
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "stroke cost", app_id = "baldr.strokecost", size = {360, 120},
		init = proc() -> State { return {} },
		start = proc(s: ^State) -> baldr.Cmd(Msg) {
			return baldr.gpu_open(Msg, proc(e: baldr.Ev(baldr.Gpu)) -> Msg { return Ready{e.value} })
		},
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			switch v in m {
			case Ready:
				s.g = v.gpu
				if s.g.host == nil { fmt.println("no GPU"); os.exit(1) }
				ok1, ok2: bool
				s.layer, ok1 = baldr.canvas_create(s.g, {CANVAS, CANVAS}, .RGBA8)
				_ = ok2
				if !ok1 { fmt.println("no canvases"); os.exit(1) }
				warm := make_strokes(8)
				baldr.canvas_strokes(s.g, s.layer, warm, identity) // warm the pipelines
				return batch(s)
			case Done:
				ms := time.duration_milliseconds(time.tick_since(s.start))
				n := counts[s.at]
				if n == 0 {
					s.floor = ms
					fmt.printfln("floor (no strokes, just the read-back): %.2f ms — subtracted below", ms)
				} else {
					net := max(ms - s.floor, 0)
					fmt.printfln("%5d strokes of %d points: %8.2f ms net — %6.1f us a stroke, %s in a 16.6 ms frame",
						n, POINTS, net, net * 1000 / f64(max(n, 1)), "fits" if net <= 16.6 else "does NOT fit")
				}
				os.flush(os.stdout)
				s.at += 1
				if s.at >= len(counts) {
					fmt.printfln("\n(%dx%d canvas, %d px boxes; one device buffer a call, two passes a stroke)",
						CANVAS, CANVAS, SIDE)
					os.exit(0)
				}
				return batch(s)
			}
			return {}
		},
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			baldr.column(ui, flex = 1, padding = .lg); defer baldr.end(ui)
			baldr.text(ui, "measuring stroke pass cost…")
		},
	})
}
