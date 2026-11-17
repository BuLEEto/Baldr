package baldr

// A canvas drawn into another through a transform: moved, scaled, rotated,
// skewed. `canvas_copy` and `canvas_blend` take whole-texel offsets, enough
// for layers that only move; free transform, resizing, straightening and
// placing at a size need the general case, and need it to look right — a
// photo scaled to a quarter must not sparkle, and a rotated layer must have
// a clean edge rather than a smear of its last row.
//
// This walks the destination, maps each texel's centre through the inverse,
// and gathers the source around that point with a kernel whose width follows
// the scale. Shrinking widens the kernel, so every source texel inside the
// destination texel is counted (which stops the sparkle); growing keeps it
// at the filter's own width.
//
// The maths here is the reference the tests check, and the shader's twin:
// change one, change both.

import "baldr:gpu"
import "core:math"
import "core:math/linalg"

// Resample is how a transformed canvas is sampled. Nearest for pixel art
// and quarter turns; Bilinear while a transform is being dragged; Bicubic
// (Catmull-Rom) and Lanczos3 for committing one, where the extra width is
// worth its cost.
Resample :: enum u8 { Nearest, Bilinear, Bicubic, Lanczos3 }

// canvas_transform draws w × h texels at x, y of `src` into `dst` through
// `m`, which maps source texel space to destination texel space (texel
// centres at +0.5, as every other canvas op counts them). Affine matrices
// are the case that matters; a projective one works, its third row dividing.
//
// Each destination texel it covers is sampled from the source through m⁻¹
// with `filter`, then laid on by `mode` at `opacity` through `mask` (whose
// texels line up with the *destination*), exactly as canvas_blend lays a
// source on. With .Normal and opacity 1 it is a transformed copy.
//
// Texels outside the source rectangle are transparent, so a rotated layer
// keeps a clean edge instead of smearing its border. False for a rectangle
// outside `src`, a mask not covering what is drawn, `src` being `dst`, a
// matrix that cannot be inverted, or no such canvas.
canvas_transform :: proc(g: Gpu, src: Canvas, x, y, w, h: int, dst: Canvas, m: matrix[3, 3]f32,
	filter := Resample.Bilinear, mode := Blend_Mode.Normal, opacity: f32 = 1, mask: Canvas = 0, linear := false) -> bool {
	s, d := canvas_entry(g, src), canvas_entry(g, dst)
	if s == nil || d == nil || src == dst || !canvas_rect_ok(s, x, y, w, h) do return false
	inv, ok := transform_inverse(m)
	if !ok do return false
	area := transform_bounds(m, x, y, w, h, d.size)
	if area.z <= area.x || area.w <= area.y do return true // it lands entirely off the canvas: nothing to do
	mk: ^Canvas_Entry
	if mask != 0 {
		mk = canvas_entry(g, mask)
		if mk == nil || mask == dst do return false
		if !canvas_rect_ok(mk, int(area.x), int(area.y), int(area.z - area.x), int(area.w - area.y)) do return false
	}
	if g.host.r != nil {
		mp := mk.page if mk != nil else 0
		return gpu.canvas_transform(g.host.r, s.page, u32(x), u32(y), u32(w), u32(h), d.page,
			{u32(area.x), u32(area.y), u32(area.z - area.x), u32(area.w - area.y)},
			transform_cols(inv), u32(filter), mode, opacity, mp, linear)
	}
	transform_cpu(s, d, mk, x, y, w, h, area, inv, filter, mode, opacity, linear)
	d.version += 1
	return true
}

// transform_inverse inverts `m`, or says it cannot be inverted (a scale of
// zero, a degenerate skew): a transform nothing can be sampled through is
// not a transform, and answering false beats drawing nonsense.
@(private)
transform_inverse :: proc(m: matrix[3, 3]f32) -> (matrix[3, 3]f32, bool) {
	det := linalg.determinant(m)
	if abs(det) < 1e-9 do return {}, false
	return linalg.inverse(m), true
}

// transform_bounds is the destination rectangle the source's corners land
// in, clipped to the canvas: x0, y0, x1, y1.
@(private)
transform_bounds :: proc(m: matrix[3, 3]f32, x, y, w, h: int, size: [2]int) -> [4]f32 {
	lo := [2]f32{max(f32), max(f32)}
	hi := [2]f32{min(f32), min(f32)}
	corners := [4][2]f32{
		{f32(x), f32(y)}, {f32(x + w), f32(y)}, {f32(x + w), f32(y + h)}, {f32(x), f32(y + h)},
	}
	for c in corners {
		p := transform_point(m, c)
		lo = {min(lo.x, p.x), min(lo.y, p.y)}
		hi = {max(hi.x, p.x), max(hi.y, p.y)}
	}
	x0 := clamp(math.floor(lo.x), 0, f32(size.x))
	y0 := clamp(math.floor(lo.y), 0, f32(size.y))
	x1 := clamp(math.ceil(hi.x), 0, f32(size.x))
	y1 := clamp(math.ceil(hi.y), 0, f32(size.y))
	return {x0, y0, x1, y1}
}

// transform_point maps a point through `m`, dividing by w so a projective
// matrix works as well as an affine one.
@(private)
transform_point :: proc "contextless" (m: matrix[3, 3]f32, p: [2]f32) -> [2]f32 {
	v := m * [3]f32{p.x, p.y, 1}
	if abs(v.z) > 1e-9 do return {v.x / v.z, v.y / v.z}
	return {v.x, v.y}
}

// transform_cols flattens a matrix for the shader's push constant, column
// by column as GLSL reads a mat3.
@(private)
transform_cols :: proc "contextless" (m: matrix[3, 3]f32) -> [9]f32 {
	out: [9]f32
	for c in 0 ..< 3 do for r in 0 ..< 3 do out[c * 3 + r] = m[r, c]
	return out
}

// transform_scale is how much of the source one destination texel covers,
// per axis: the length of the inverse's columns. A shrink to a quarter
// gives 4, and the kernel widens by that much so every source texel inside
// the destination texel is counted.
@(private)
transform_scale :: proc "contextless" (inv: matrix[3, 3]f32, filter: Resample) -> [2]f32 {
	// Not for Nearest, which takes one texel whole: pixel art scaled down
	// keeps its hard edges, where a widened kernel would be a box filter.
	if filter == .Nearest do return {1, 1}
	sx := math.sqrt(inv[0, 0] * inv[0, 0] + inv[1, 0] * inv[1, 0])
	sy := math.sqrt(inv[0, 1] * inv[0, 1] + inv[1, 1] * inv[1, 1])
	return {max(sx, 1), max(sy, 1)}
}

// TRANSFORM_MAX_TAPS bounds the kernel in each direction. A shrink of 60×
// would otherwise gather thousands of texels per destination texel; past
// this the kernel steps rather than widening.
@(private)
TRANSFORM_MAX_TAPS :: 16

// transform_weight is the filter's weight at distance `t` (in source
// texels, already divided by the kernel's width).
@(private)
transform_weight :: proc "contextless" (filter: Resample, t: f32) -> f32 {
	x := abs(t)
	switch filter {
	case .Nearest:
		return 1 if x <= 0.5 else 0
	case .Bilinear:
		return max(1 - x, 0)
	case .Bicubic: // Catmull-Rom
		if x < 1 do return 1.5 * x * x * x - 2.5 * x * x + 1
		if x < 2 do return -0.5 * x * x * x + 2.5 * x * x - 4 * x + 2
		return 0
	case .Lanczos3:
		if x < 1e-6 do return 1
		if x >= 3 do return 0
		pix := math.PI * x
		return 3 * math.sin(pix) * math.sin(pix / 3) / (pix * pix)
	}
	return 0
}

// transform_radius is how far the filter reaches, in its own units.
@(private)
transform_radius :: proc "contextless" (filter: Resample) -> f32 {
	switch filter {
	case .Nearest:  return 0.5
	case .Bilinear: return 1
	case .Bicubic:  return 2
	case .Lanczos3: return 3
	}
	return 1
}

// transform_cpu is the reference: for every destination texel in `area`,
// map its centre back into the source, gather with the filter, and lay the
// result on as canvas_blend would.
@(private)
transform_cpu :: proc(s, d, mk: ^Canvas_Entry, x, y, w, h: int, area: [4]f32, inv: matrix[3, 3]f32,
	filter: Resample, mode: Blend_Mode, opacity: f32, linear: bool) {
	sb, db := gpu.canvas_bpp(s.format), gpu.canvas_bpp(d.format)
	scale := transform_scale(inv, filter)
	reach := transform_radius(filter)
	// how far the gather runs in source texels, and how big a step it takes:
	// past TRANSFORM_MAX_TAPS the kernel keeps its width but samples sparsely
	rx, ry := reach * scale.x, reach * scale.y
	step := [2]f32{max(2 * rx / TRANSFORM_MAX_TAPS, 1), max(2 * ry / TRANSFORM_MAX_TAPS, 1)}
	for py in int(area.y) ..< int(area.w) do for px in int(area.x) ..< int(area.z) {
		p := transform_point(inv, {f32(px) + 0.5, f32(py) + 0.5})
		sum: [4]f32
		weight, full_sum: f32
		if filter == .Nearest { // one texel, whole: no kernel to run
			sx, sy := int(math.floor(p.x)), int(math.floor(p.y))
			if sx < x || sy < y || sx >= x + w || sy >= y + h do continue
			c := canvas_decode(s.format, s.pixels[(sy * s.size.x + sx) * sb:][:sb])
			sum = {c.r * c.a, c.g * c.a, c.b * c.a, c.a} // premultiplied, as the gather is
			weight = 1
		} else {
			// Counted, not accumulated, so the shader can walk the same taps:
			// a float loop condition is fragile there, and the two must agree
			// texel for texel.
			tx, ty := transform_taps(rx, step.x), transform_taps(ry, step.y)
			u0 := math.floor((p.x - rx) / step.x) * step.x + step.x * 0.5
			v0 := math.floor((p.y - ry) / step.y) * step.y + step.y * 0.5
			for i in 0 ..< tx {
				u := u0 + f32(i) * step.x
				wx := transform_weight(filter, (u - p.x) / scale.x)
				if wx == 0 do continue
				for j in 0 ..< ty {
					v := v0 + f32(j) * step.y
					k := wx * transform_weight(filter, (v - p.y) / scale.y)
					if k == 0 do continue
					full_sum += k
					sx, sy := int(math.floor(u)), int(math.floor(v))
					if sx < x || sy < y || sx >= x + w || sy >= y + h do continue // outside the source: transparent
					c := canvas_decode(s.format, s.pixels[(sy * s.size.x + sx) * sb:][:sb])
					// Premultiplied: averaging straight colours lets a clear
					// neighbour (black at zero alpha) pull the colour towards
					// black, a dark fringe wherever the layer is transparent.
					sum += [4]f32{c.r * c.a, c.g * c.a, c.b * c.a, c.a} * k
					weight += k
				}
			}
		}
		if weight <= 0 do continue // nothing of the source reaches this texel
		// The weights of the texels inside are normalised and the rest of the
		// kernel's weight fades the alpha: a clean edge rather than a hard cut
		// or a smear. The colour comes out of the premultiplied sum, so a texel
		// beside a clear one keeps its colour at a lower alpha.
		full := f32(1) if filter == .Nearest else full_sum
		src: [4]f32
		if sum.a > 1e-6 do src = {sum.r / sum.a, sum.g / sum.a, sum.b / sum.a, 0}
		src.a = max(sum.a / weight, 0) * clamp(weight / max(full, 1e-6), 0, 1)
		into := d.pixels[(py * d.size.x + px) * db:][:db]
		cb := canvas_decode(d.format, into)
		k: f32 = 1
		if mk != nil {
			mb := gpu.canvas_bpp(mk.format)
			k = canvas_decode(mk.format, mk.pixels[(py * mk.size.x + px) * mb:][:mb]).r
		}
		out := blend_texel(mode, cb, src, opacity * k, linear, blend_curve(d.space), blend_curve(s.space), {px, py}, 0)
		texel := canvas_encode(d.format, out)
		copy(into, texel[:db])
	}
}

// transform_taps is how many taps the gather takes along one axis.
@(private)
transform_taps :: proc "contextless" (reach, step: f32) -> int {
	return clamp(int(math.ceil(2 * reach / step)), 1, TRANSFORM_MAX_TAPS)
}
