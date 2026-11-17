// 28_lines — lines drawn over a node: the overlays an image
// editor draws on top of a picture, none of which can be a box.
//
// Marching ants round a selection with a hole in it, a free transform box
// rotated with its layer, a crop frame with its rule-of-thirds lines,
// guides, and the pixel grid at high zoom. All of them are `lines` nodes in
// a `stack` over the picture, placed with `offset`, and the ants move by
// nothing more than a rising `dash_offset`.
//
//   ./build.sh example 28_lines run
package main

import "core:math"
import "baldr:baldr"

PIC :: [2]f32{520, 360} // the "picture" everything is drawn over

State :: struct {
	ants:  f32,  // how far the dash pattern has slid along the path
	angle: f32,  // the transform box's rotation
	grid:  bool, // the pixel grid, as at high zoom
	crop:  bool,
}

Msg :: union { Tick, Grid, Crop }
Tick :: struct {}
Grid :: struct { on: bool }
Crop :: struct { on: bool }

// selection is a rounded-ish blob with a hole in it: two closed loops that
// share the node's dash phase, so the ants march round both together.
selection :: proc(allocator := context.temp_allocator) -> []baldr.Polyline {
	outer := make([][2]f32, 24, allocator)
	for i in 0 ..< 24 {
		a := f32(i) / 24 * math.TAU
		r := 96 + 26 * math.sin(a * 3) // lumpy, the way a real selection is
		outer[i] = {150 + r * math.cos(a), 170 + r * math.sin(a) * 0.8}
	}
	hole := make([][2]f32, 12, allocator)
	for i in 0 ..< 12 {
		a := f32(i) / 12 * math.TAU
		hole[i] = {150 + 32 * math.cos(a), 160 + 26 * math.sin(a)}
	}
	runs := make([]baldr.Polyline, 2, allocator)
	runs[0] = {outer, true}
	runs[1] = {hole, true}
	return runs
}

// transform_box is the free transform frame: a rectangle rotated about its
// middle, with a line to the rotation handle above it.
transform_box :: proc(angle: f32, allocator := context.temp_allocator) -> []baldr.Polyline {
	mid := [2]f32{390, 130}
	half := [2]f32{78, 54}
	turn :: proc(mid, half: [2]f32, sx, sy, a: f32) -> [2]f32 {
		x, y := half.x * sx, half.y * sy
		return {mid.x + x * math.cos(a) - y * math.sin(a), mid.y + x * math.sin(a) + y * math.cos(a)}
	}
	frame := make([][2]f32, 4, allocator)
	frame[0] = turn(mid, half, -1, -1, angle)
	frame[1] = turn(mid, half, 1, -1, angle)
	frame[2] = turn(mid, half, 1, 1, angle)
	frame[3] = turn(mid, half, -1, 1, angle)
	stem := make([][2]f32, 2, allocator)
	stem[0] = turn(mid, half, 0, -1, angle)
	stem[1] = turn(mid, {half.x, half.y + 28}, 0, -1, angle)
	runs := make([]baldr.Polyline, 2, allocator)
	runs[0] = {frame, true}
	runs[1] = {stem, false}
	return runs
}

// thirds is the crop frame and the two lines each way that divide it in
// three — every one of them axis-aligned, which is what `crisp` is for.
thirds :: proc(allocator := context.temp_allocator) -> []baldr.Polyline {
	r := [4]f32{40, 40, 440, 280} // x, y, w, h
	runs := make([]baldr.Polyline, 5, allocator)
	rect := make([][2]f32, 4, allocator)
	rect[0] = {r.x, r.y}
	rect[1] = {r.x + r.z, r.y}
	rect[2] = {r.x + r.z, r.y + r.w}
	rect[3] = {r.x, r.y + r.w}
	runs[0] = {rect, true}
	for i in 1 ..= 2 {
		v := make([][2]f32, 2, allocator)
		v[0] = {r.x + r.z * f32(i) / 3, r.y}
		v[1] = {r.x + r.z * f32(i) / 3, r.y + r.w}
		runs[i] = {v, false}
		h := make([][2]f32, 2, allocator)
		h[0] = {r.x, r.y + r.w * f32(i) / 3}
		h[1] = {r.x + r.z, r.y + r.w * f32(i) / 3}
		runs[2 + i] = {h, false}
	}
	return runs
}

// pixel_grid is what an editor draws past about 800% zoom: one line a texel.
pixel_grid :: proc(step: f32, allocator := context.temp_allocator) -> []baldr.Polyline {
	nx, ny := int(PIC.x / step), int(PIC.y / step)
	runs := make([]baldr.Polyline, nx + ny, allocator)
	for i in 0 ..< nx {
		v := make([][2]f32, 2, allocator)
		v[0] = {f32(i) * step, 0}
		v[1] = {f32(i) * step, PIC.y}
		runs[i] = {v, false}
	}
	for i in 0 ..< ny {
		h := make([][2]f32, 2, allocator)
		h[0] = {0, f32(i) * step}
		h[1] = {PIC.x, f32(i) * step}
		runs[nx + i] = {h, false}
	}
	return runs
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Lines over a picture", app_id = "baldr.lines", size = {600, 560},
		init = proc() -> State { return {crop = true} },
		subscriptions = proc(s: ^State, out: ^[dynamic]baldr.Sub(Msg)) {
			append(out, baldr.every(Msg, 33, Tick{}))
		},
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			switch v in m {
			case Tick: s.ants += 0.8; s.angle += 0.004 // the ants march; the box turns
			case Grid: s.grid = v.on
			case Crop: s.crop = v.on
			}
			return {}
		},
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			baldr.column(ui, gap = .md, padding = .lg, flex = 1); {
				defer baldr.end(ui)
				baldr.text(ui, "Lines over a picture", role = .Headline)

				baldr.row(ui, gap = .lg); {
					defer baldr.end(ui)
					baldr.toggle(ui, s.crop, "Crop frame", proc(e: baldr.Ev(bool)) -> Msg { return Crop{e.value} })
					baldr.toggle(ui, s.grid, "Pixel grid", proc(e: baldr.Ev(bool)) -> Msg { return Grid{e.value} })
				}

				baldr.stack(ui, width = PIC.x, height = PIC.y); {
					defer baldr.end(ui)
					baldr.box(ui, width = PIC.x, height = PIC.y, bg = {0.16, 0.20, 0.26, 1}, radius = 4)

					if s.grid {
						// Faint, and one device pixel wide whatever the display
						// scale: `crisp` puts it on whole pixels, so the grid is
						// even instead of shimmering.
						baldr.lines(ui, pixel_grid(16), color = {1, 1, 1, 0.14},
							width = PIC.x, height = PIC.y)
					}
					if s.crop {
						baldr.lines(ui, thirds(), color = {1, 1, 1, 0.45},
							width = PIC.x, height = PIC.y, label = "Crop frame")
					}
					// Marching ants: white underneath, black dashes over, so
					// they read on any picture. Only dash_offset moves.
					baldr.lines(ui, selection(), color = {0, 0, 0, 1}, outline = {1, 1, 1, 1},
						dashes = {4, 4}, dash_offset = s.ants,
						width = PIC.x, height = PIC.y, label = "Selection")
					baldr.lines(ui, transform_box(s.angle), thickness = 1.5, color = {1, 1, 1, 0.9},
						width = PIC.x, height = PIC.y, label = "Free transform")
				}

				baldr.text(ui, "Two closed loops, one dash phase: the ants march round the hole with the outside.", muted = true)
				baldr.text(ui, "The crop frame and the grid are axis-aligned, so they land on whole pixels. The transform box is not, so it is never moved.", muted = true)
			}
		},
	})
}
