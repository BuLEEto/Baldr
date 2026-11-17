package baldr

// Painting: brush strokes on canvases, as an image editor paints. A
// stroke's dabs lay coverage into a stroke canvas (canvas_dabs: each dab
// over what is there, so a low flow builds up where dabs overlap), and the
// stroke is laid onto the layer in the brush's colour through that
// coverage, at the stroke's opacity and blend mode (canvas_paint), so
// opacity caps the whole stroke however many dabs it has. An eraser is
// canvas_paint with `erase`.
//
// brush_stroke spaces dabs along the pointer's path (pointer_samples, in
// the canvas's texels), their size and strength following the pen's
// pressure. On the GPU dabs are gpu/shaders/dab.frag, one quad each, laid
// on by the pipeline's blending; here is the CPU reference, each dab's
// result stored in the canvas's format as the GPU stores it.

import "core:math"
import "baldr:gpu"

// Dab is one stamp of a brush: its centre in texels, its radius, how hard
// its edge is (1 hard, 0 soft from the centre out), its strength (flow ×
// pressure) and, for a tip, its turn in radians.
Dab :: gpu.Dab

// Brush is how a stroke's dabs are made: `size` their diameter in texels
// at full pressure, `hardness` their edge, `flow` each one's strength,
// `spacing` the distance between them as a part of the size (0.25 is a
// quarter), `angle` a tip's turn. `size_pressure` and `flow_pressure` make
// the pen's pressure scale the size and the strength.
Brush :: struct {
	size:          f32,
	hardness:      f32,
	flow:          f32,
	spacing:       f32,
	angle:         f32,
	size_pressure: bool,
	flow_pressure: bool,
}

// Brush_Path is a stroke's progress along the pointer: where its last dab
// was and how far along the next is due. Zero it for a new stroke.
Brush_Path :: struct {
	last:     [2]f32,
	pressure: f32,
	carry:    f32, // distance walked since the last dab
	started:  bool,
}

// brush_stroke adds the dabs a stroke gets as the pointer moves to `at`
// (in the canvas's texels) with `pressure` (0..1; a mouse is 1): the first
// point a dab, then one every spacing × size along the way, the pressure
// eased between points. The dabs are appended to `out`.
brush_stroke :: proc(b: Brush, path: ^Brush_Path, at: [2]f32, pressure: f32, out: ^[dynamic]Dab) {
	dab :: proc(b: Brush, at: [2]f32, pressure: f32) -> Dab {
		p := clamp(pressure, 0, 1)
		size := b.size * (p if b.size_pressure else 1)
		strength := clamp(b.flow, 0, 1) * (p if b.flow_pressure else 1)
		return {centre = at, radius = max(size / 2, 0.5), hardness = b.hardness, strength = strength, angle = b.angle}
	}
	if !path.started {
		append(out, dab(b, at, pressure))
		path^ = {last = at, pressure = pressure, started = true}
		return
	}
	step := max(b.size * max(b.spacing, 0.01), 0.5)
	d := at - path.last
	length := math.sqrt(d.x * d.x + d.y * d.y)
	if length <= 0 do return
	walked := step - path.carry // to the next dab
	for walked <= length {
		t := walked / length
		append(out, dab(b, path.last + d * t, path.pressure + (pressure - path.pressure) * t))
		walked += step
	}
	path.carry = length - (walked - step)
	path.last, path.pressure = at, pressure
}

// canvas_dabs lays `dabs`' coverage onto `stroke`, in order, each over what
// is there (old + dab × (1 − old), in every channel), with `tip`'s first
// channel as the brush's shape (0 for round). The stroke canvas holds a
// stroke's coverage for canvas_paint; a 16-bit one keeps a low flow's
// build-up smooth. False for no such canvas, or no dabs.
canvas_dabs :: proc(g: Gpu, stroke: Canvas, dabs: []Dab, tip: Canvas = 0) -> bool {
	s := canvas_entry(g, stroke)
	if s == nil || len(dabs) == 0 do return false
	t: ^Canvas_Entry
	if tip != 0 {
		t = canvas_entry(g, tip)
		if t == nil || tip == stroke do return false
	}
	if g.host.r != nil {
		if !gpu.canvas_dabs(g.host.r, s.page, dabs, t.page if t != nil else 0) do return false
	} else {
		for d in dabs do dab_reference(s, d, t)
	}
	s.version += 1
	return true
}

// canvas_paint lays `color` (as stored) onto the rectangle of `dst` by
// `mode` at `opacity`, through `mask`'s first channel (its texels lined up
// with the destination's; 0 for none): a stroke's colour through its
// coverage. With `erase` the destination's alpha is taken away instead,
// its colour kept (an eraser). False for a rectangle outside the canvas, a
// mask not covering it, or no such canvas.
canvas_paint :: proc(g: Gpu, dst: Canvas, x, y, w, h: int, color: [4]f32, mode := Blend_Mode.Normal, opacity: f32 = 1, mask: Canvas = 0, erase := false, linear := false) -> bool {
	d := canvas_entry(g, dst)
	if d == nil || !canvas_rect_ok(d, x, y, w, h) do return false
	m: ^Canvas_Entry
	if mask != 0 {
		m = canvas_entry(g, mask)
		if m == nil || mask == dst || !canvas_rect_ok(m, x, y, w, h) do return false
	}
	if g.host.r != nil {
		if !gpu.canvas_paint(g.host.r, d.page, u32(x), u32(y), u32(w), u32(h), color, mode, opacity, m.page if m != nil else 0, erase, linear) do return false
	} else {
		db := gpu.canvas_bpp(d.format)
		curve := blend_curve(d.space)
		for row in 0 ..< h do for col in 0 ..< w {
			into := d.pixels[((y + row) * d.size.x + x + col) * db:][:db]
			cb := canvas_decode(d.format, into)
			k: f32 = 1
			if m != nil {
				mb := gpu.canvas_bpp(m.format)
				k = canvas_decode(m.format, m.pixels[((y + row) * m.size.x + x + col) * mb:][:mb]).r
			}
			out: [4]f32
			if erase {
				as := clamp(color.a * opacity * k, 0, 1)
				if mode == .Dissolve {
					r := f32(blend_hash(u32(x + col) * 1973 + u32(y + row) * 9277) >> 8) / 16777216
					as = 1 if r < as else 0
				}
				out = {cb.r, cb.g, cb.b, clamp(cb.a, 0, 1) * (1 - as)}
			} else {
				out = blend_texel(mode, cb, color, opacity * k, linear, curve, curve, {x + col, y + row}, 0)
			}
			texel := canvas_encode(d.format, out)
			copy(into, texel[:db])
		}
	}
	d.version += 1
	return true
}

// dab_coverage is one dab's coverage of the texel whose centre is at `p`,
// as dab.frag has it.
@(private)
dab_coverage :: proc(d: Dab, p: [2]f32, tip: ^Canvas_Entry) -> f32 {
	r := d.radius
	hard := clamp(d.hardness, 0, 1)
	o := p - d.centre
	cov: f32
	if tip != nil {
		c, s := math.cos(d.angle), math.sin(d.angle)
		q := [2]f32{c * o.x + s * o.y, -s * o.x + c * o.y} / (2 * r) + 0.5
		if q.x < 0 || q.y < 0 || q.x > 1 || q.y > 1 do return 0
		cov = tip_sample(tip, q)
	} else {
		dist := math.sqrt(o.x * o.x + o.y * o.y)
		if hard >= 1 {
			cov = clamp(r - dist + 0.5, 0, 1)
		} else {
			inner := hard * r
			t := clamp((dist - inner) / max(r - inner, 1e-4), 0, 1)
			cov = 1 - t * t * (3 - 2 * t)
		}
	}
	return clamp(cov * d.strength, 0, 1)
}

// tip_sample is a tip's first channel at `q` (0..1 across it), bilinear
// with its edges clamped, as the GPU's sampler reads it.
@(private)
tip_sample :: proc(t: ^Canvas_Entry, q: [2]f32) -> f32 {
	u := q.x * f32(t.size.x) - 0.5
	v := q.y * f32(t.size.y) - 0.5
	x0, y0 := int(math.floor(u)), int(math.floor(v))
	fx, fy := u - f32(x0), v - f32(y0)
	at :: proc(t: ^Canvas_Entry, x, y: int) -> f32 { return table_texel(t, clamp(x, 0, t.size.x - 1), clamp(y, 0, t.size.y - 1)).r }
	return (at(t, x0, y0) * (1 - fx) + at(t, x0 + 1, y0) * fx) * (1 - fy) + (at(t, x0, y0 + 1) * (1 - fx) + at(t, x0 + 1, y0 + 1) * fx) * fy
}

// dab_reference lays one dab on the reference's stroke canvas.
@(private)
dab_reference :: proc(s: ^Canvas_Entry, d: Dab, tip: ^Canvas_Entry) {
	reach := d.radius * (1.4143 if tip != nil else 1) + 1
	x0, y0 := max(int(math.floor(d.centre.x - reach)), 0), max(int(math.floor(d.centre.y - reach)), 0)
	x1, y1 := min(int(math.ceil(d.centre.x + reach)), s.size.x), min(int(math.ceil(d.centre.y + reach)), s.size.y)
	bpp := gpu.canvas_bpp(s.format)
	for y in y0 ..< y1 do for x in x0 ..< x1 {
		cov := dab_coverage(d, {f32(x) + 0.5, f32(y) + 0.5}, tip)
		if cov <= 0 do continue
		into := s.pixels[(y * s.size.x + x) * bpp:][:bpp]
		old := canvas_decode(s.format, into)
		texel := canvas_encode(s.format, cov + old * (1 - cov))
		copy(into, texel[:bpp])
	}
}
