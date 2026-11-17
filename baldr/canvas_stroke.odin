package baldr

// Strokes whose width varies along them: the pen strokes an infinite canvas
// is made of, drawn into a canvas through a transform and redrawn crisp at
// any zoom.
//
// This file is the coverage: what part of each texel a stroke covers. A
// stroke's coverage goes into a canvas of its own and `canvas_paint` then
// lays one colour through it at one alpha (or `erase` takes the
// destination's alpha away), as a brush stroke does (canvas_brush.odin). So
// a translucent stroke that crosses itself is no darker at the crossing:
// its alpha is applied once, to the whole coverage.
//
// Coverage is a union, not a build-up, unlike the brush. Dabs lay
// `old + dab × (1 − old)`; consecutive segments of a stroke always overlap,
// so under that rule every join would darken. The rule here is `max`, which
// is idempotent under overlap: a join, a self-crossing and a doubled-back
// stroke all come out exactly as opaque as the stroke is. The GPU path does the same maximum through
// the pipeline's blending (`VK_BLEND_OP_MAX`).

import "core:math"
import "baldr:gpu"

// Stroke_Point is one sample along a stroke: where it is, and how wide the
// stroke is there. The width is a diameter, in the stroke's own units — the
// transform given to the drawing call scales it, unless the stroke holds
// its width on screen.
Stroke_Point :: struct {
	at:    [2]f32,
	width: f32,
}

// Stroke_Draw is one stroke: its points, and the one colour and alpha the
// whole of it is drawn in. `screen_width` holds the width at a size on
// screen rather than letting the transform scale it (a pen app's "Lock
// thickness"), so a hairline stays a hairline however far the view is
// zoomed out.
//
// The points are the caller's and are only read during the call.
Stroke_Draw :: struct {
	points:       []Stroke_Point,
	color:        [4]f32,
	screen_width: bool,
}

// stroke_segment_distance is the signed distance from `p` to the segment
// `a`–`b` whose radius runs from `ra` to `rb`: negative inside, zero on the
// edge, positive outside, in texels.
//
// A segment of a variable-width stroke is a round cone — two circles and
// their outer tangents — not a capsule: where the width changes the edge
// slopes, and a capsule would leave a visible step at every point of a
// tapering stroke.
//
// The three cases are the two end caps and the tangent between them. Written
// to match the fragment shader, so the two can be compared texel for texel.
@(private)
stroke_segment_distance :: proc(p, a, b: [2]f32, ra, rb: f32) -> f32 {
	dot2 :: proc(v: [2]f32) -> f32 { return v.x * v.x + v.y * v.y }
	ba := b - a
	l2 := dot2(ba)
	rr := ra - rb
	if l2 <= 1e-12 { // the two ends are the same point: a disc of the larger radius
		return math.sqrt(dot2(p - a)) - max(ra, rb)
	}
	a2 := l2 - rr * rr
	il2 := 1 / l2
	pa := p - a
	y := pa.x * ba.x + pa.y * ba.y
	z := y - l2
	x2 := dot2(pa * l2 - ba * y)
	y2 := y * y * l2
	z2 := z * z * l2
	k := math.sign(rr) * rr * rr * x2
	if math.sign(z) * a2 * z2 > k do return math.sqrt(x2 + z2) * il2 - rb
	if math.sign(y) * a2 * y2 < k do return math.sqrt(x2 + y2) * il2 - ra
	return (math.sqrt(max(x2 * a2 * il2, 0)) + y * rr) * il2 - ra
}

// stroke_coverage is how much of the texel centred at `p` a stroke covers:
// the largest coverage of any of its segments, antialiased over one texel.
//
// The maximum, not a build-up: see the top of the file. A single point with
// a width is a round dot, so a pen tapped once draws rather than vanishing.
@(private)
stroke_coverage :: proc(pts: []Stroke_Point, p: [2]f32, scale: f32) -> f32 {
	if len(pts) == 0 do return 0
	if len(pts) == 1 {
		d := math.sqrt((p.x - pts[0].at.x) * (p.x - pts[0].at.x) + (p.y - pts[0].at.y) * (p.y - pts[0].at.y))
		return clamp(max(pts[0].width, 0) * 0.5 * scale - d + 0.5, 0, 1)
	}
	cov: f32 = 0
	for i in 0 ..< len(pts) - 1 {
		ra := max(pts[i].width, 0) * 0.5 * scale
		rb := max(pts[i + 1].width, 0) * 0.5 * scale
		d := stroke_segment_distance(p, pts[i].at, pts[i + 1].at, ra, rb)
		c := clamp(0.5 - d, 0, 1) // the edge is soft over one texel, as a hard dab's is
		if c > cov do cov = c
		if cov >= 1 do return 1 // nothing can beat full coverage; stop looking
	}
	return cov
}

// stroke_bounds is the rectangle a stroke can touch, in texels, clipped to a
// canvas of `size`. Empty (w or h of 0) when the stroke is off it.
@(private)
stroke_bounds :: proc(pts: []Stroke_Point, scale: f32, size: [2]int) -> (x, y, w, h: int) {
	if len(pts) == 0 do return
	lo, hi := pts[0].at, pts[0].at
	widest: f32 = 0
	for pt in pts {
		lo = {min(lo.x, pt.at.x), min(lo.y, pt.at.y)}
		hi = {max(hi.x, pt.at.x), max(hi.y, pt.at.y)}
		widest = max(widest, max(pt.width, 0))
	}
	reach := widest * 0.5 * scale + 1 // the half-width, plus the antialiased texel
	x0 := max(int(math.floor(lo.x - reach)), 0)
	y0 := max(int(math.floor(lo.y - reach)), 0)
	x1 := min(int(math.ceil(hi.x + reach)), size.x)
	y1 := min(int(math.ceil(hi.y + reach)), size.y)
	if x1 <= x0 || y1 <= y0 do return
	return x0, y0, x1 - x0, y1 - y0
}

// stroke_cover_for is the coverage canvas strokes are laid into before they
// are composited, at least `size`, kept on the host and reused.
//
// Not made per call: GPU work is queued rather than done, so a scratch
// created and destroyed inside the call would be freed before the batch runs
// and the strokes would draw into a page handed to something else.
//
// Remade when it is too small, and when a GPU reset has taken it.
@(private)
stroke_cover_for :: proc(g: Gpu, size: [2]int) -> Canvas {
	h := g.host
	if h == nil do return 0
	if h.stroke_cover != 0 && canvas_valid(g, h.stroke_cover) {
		have, _, _, ok := canvas_info(g, h.stroke_cover)
		// Big enough, and not so much bigger it is worth keeping: an export can
		// be 16384 a side, and a coverage canvas that size is a gigabyte held
		// for the life of the program. Remade once the room it keeps is four
		// times the room in use.
		room := have.x * have.y
		want := size.x * size.y
		if ok && have.x >= size.x && have.y >= size.y && room <= want * 4 do return h.stroke_cover
		canvas_destroy(g, h.stroke_cover)
	}
	h.stroke_cover = 0
	// Linear, not sRGB: this holds coverage, which is a fraction and not a
	// colour, and a transfer function applied to it would bend the edges.
	c, made := canvas_create(g, size, .RGBA8, .Linear, mips = false)
	if !made do return 0
	h.stroke_cover = c
	return c
}

// canvas_strokes draws `strokes` into `dst` through `transform` (the
// stroke's units → the canvas's texels), each in its own colour at its own
// alpha, by `mode`, and with `erase` taking the destination's alpha away
// instead so an eraser cuts through the canvas rather than painting over it.
//
// Every stroke is one coverage: its alpha is applied once to the whole of
// it, so a translucent stroke is no darker where it crosses itself or at a
// join. Separate strokes still build up, as ink does.
//
// `screen_width` on a stroke holds its width at a size on the canvas rather
// than letting the transform scale it ("Lock thickness").
//
// Each stroke costs small passes over its own rectangle: a few hundred
// strokes in a frame, not thousands, so an app that redraws a large drawing
// should do it when something settles rather than on every frame.
//
// False for no such canvas, or if the scratch coverage cannot be made.
// Strokes entirely off the canvas are skipped, which is not a failure.
canvas_strokes :: proc(g: Gpu, dst: Canvas, strokes: []Stroke_Draw, transform: matrix[3, 3]f32,
	mode := Blend_Mode.Normal, erase := false, linear := false) -> bool {
	d := canvas_entry(g, dst)
	if d == nil do return false
	if len(strokes) == 0 do return true

	// The transform's scale, for the widths: the length of a unit step, which
	// for a rotation or a uniform zoom is the zoom and for a squash is the
	// average of the two axes — a stroke has one width, so it has one scale.
	sx := math.sqrt(transform[0, 0] * transform[0, 0] + transform[1, 0] * transform[1, 0])
	sy := math.sqrt(transform[0, 1] * transform[0, 1] + transform[1, 1] * transform[1, 1])
	scale := (sx + sy) * 0.5
	if scale <= 0 do return true // a degenerate transform draws nothing

	cover := stroke_cover_for(g, d.size)
	if cover == 0 do return false

	// The transformed strokes are worked out first so their quads go to the
	// device in one buffer: a buffer per stroke would be a device allocation
	// each, and a device's allocation count is limited.
	Run :: struct { first, count, x, y, w, h: int, color: [4]f32 }
	runs := make([dynamic]Run, 0, len(strokes), context.temp_allocator)
	segs := make([dynamic]gpu.Stroke_Seg, 0, 256, context.temp_allocator)
	pts := make([dynamic]Stroke_Point, 0, 64, context.temp_allocator)
	defer { delete(runs); delete(segs); delete(pts) }

	for st in strokes {
		if len(st.points) == 0 do continue
		clear(&pts)
		w_scale := scale if !st.screen_width else 1 // "Lock thickness": the transform moves it, not its width
		for pt in st.points {
			p := [3]f32{pt.at.x, pt.at.y, 1}
			q := transform * p
			w := q.z if q.z != 0 else 1
			append(&pts, Stroke_Point{at = {q.x / w, q.y / w}, width = pt.width * w_scale})
		}
		// The widths are already in texels above, so the coverage runs at 1.
		x, y, bw, bh := stroke_bounds(pts[:], 1, d.size)
		if bw == 0 || bh == 0 do continue // off the canvas

		first := len(segs)
		if len(pts) == 1 { // a tap: a segment of no length is a disc of its radius
			r := max(pts[0].width, 0) * 0.5
			append(&segs, gpu.Stroke_Seg{a = pts[0].at, b = pts[0].at, ra = r, rb = r})
		} else {
			for i in 0 ..< len(pts) - 1 {
				append(&segs, gpu.Stroke_Seg{
					a = pts[i].at, b = pts[i + 1].at,
					ra = max(pts[i].width, 0) * 0.5, rb = max(pts[i + 1].width, 0) * 0.5,
				})
			}
		}
		append(&runs, Run{first, len(segs) - first, x, y, bw, bh, st.color})
	}
	if len(runs) == 0 do return true

	buf: gpu.Buffer
	if g.host.r != nil {
		up_ok: bool
		buf, up_ok = gpu.canvas_strokes_upload(g.host.r, segs[:])
		if !up_ok do return false
	}

	cov := canvas_entry(g, cover)
	if cov == nil do return false
	for run, i in runs {
		// No clear here: the GPU pass clears its own rectangle as it begins
		// (loadOp CLEAR), and the reference clears as it writes.
		if g.host.r != nil {
			// The last run hands the shared buffer back, whatever happens above.
			own := i == len(runs) - 1
			laid := gpu.canvas_strokes(g.host.r, cov.page, buf, segs[:], run.first, run.count,
				u32(run.x), u32(run.y), u32(run.w), u32(run.h), own)
			if !laid do continue
		} else {
			stroke_coverage_reference(cov, segs[:], run.first, run.count, run.x, run.y, run.w, run.h)
		}
		cov.version += 1
		// The colour carries the stroke's alpha, so the opacity is 1: passing
		// the alpha again here would apply it twice.
		if !canvas_paint(g, dst, run.x, run.y, run.w, run.h, run.color, mode, 1, cover, erase, linear) do continue
	}
	return true
}

// stroke_coverage_reference lays one stroke's coverage into `cover` over the
// rectangle given, taking the maximum across its segments — the CPU path,
// and the spec the shader is checked against (spikes/stroke_parity).
@(private)
stroke_coverage_reference :: proc(cov: ^Canvas_Entry, segs: []gpu.Stroke_Seg, first, count, x, y, w, h: int) {
	bpp := gpu.canvas_bpp(cov.format)
	mine := segs[first:][:count]
	for ty in y ..< y + h do for tx in x ..< x + w {
		p := [2]f32{f32(tx) + 0.5, f32(ty) + 0.5}
		c: f32 = 0
		for sg in mine {
			d := stroke_segment_distance(p, sg.a, sg.b, sg.ra, sg.rb)
			v := clamp(0.5 - d, 0, 1)
			if v > c do c = v
			if c >= 1 do break
		}
		// Written whether it is covered or not: this rectangle starts from
		// nothing, as the GPU pass's CLEAR makes it, or one stroke's coverage
		// would smear into the next.
		into := cov.pixels[(ty * cov.size.x + tx) * bpp:][:bpp]
		texel := canvas_encode(cov.format, c)
		copy(into, texel[:bpp])
	}
}
