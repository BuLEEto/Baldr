package baldr

// Filters and adjustments on canvases: a colour matrix, per-channel curves,
// conversion between colour spaces, an app's 3D LUT, a Gaussian blur and an
// unsharp mask. Each reads a rectangle of a source and writes it into a
// destination, which may be the same canvas. On the GPU they are
// gpu/shaders/filter.frag; this is the CPU reference, pass for pass (the
// blur premultiplied and separable, in 32-bit floats, clamped at the
// canvas's edges), which the GPU is compared with.
//
// The usual image-editor adjustments are these with a table or a matrix:
// Levels and Curves are curves; Invert, Channel Mixer, Black & White and a
// saturation change are matrices (color_matrix_saturate,
// COLOR_MATRIX_INVERT); Posterize and Threshold are stepped curves (after a
// greyscale matrix for Threshold). An ICC conversion is a LUT the app
// builds with its colour engine and gives as a canvas (canvas_lut_make).

import "core:math"
import "core:mem"
import "baldr:gpu"

// Color_Matrix takes a texel's values to new ones: each row is an output
// channel (r, g, b, a) as a sum of the input's r, g, b, a and 1.
Color_Matrix :: [4][5]f32

// COLOR_MATRIX_IDENTITY changes nothing; COLOR_MATRIX_INVERT is Invert
// (colour only, alpha kept).
COLOR_MATRIX_IDENTITY :: Color_Matrix{{1, 0, 0, 0, 0}, {0, 1, 0, 0, 0}, {0, 0, 1, 0, 0}, {0, 0, 0, 1, 0}}
COLOR_MATRIX_INVERT :: Color_Matrix{{-1, 0, 0, 0, 1}, {0, -1, 0, 0, 1}, {0, 0, -1, 0, 1}, {0, 0, 0, 1, 0}}

// color_matrix_saturate scales saturation around each texel's luminance
// (Rec. 709 weights): 0 greys it, 1 keeps it, above 1 deepens it.
color_matrix_saturate :: proc(s: f32) -> Color_Matrix {
	lr, lg, lb := f32(0.2126), f32(0.7152), f32(0.0722)
	return {
		{lr + (1 - lr) * s, lg - lg * s, lb - lb * s, 0, 0},
		{lr - lr * s, lg + (1 - lg) * s, lb - lb * s, 0, 0},
		{lr - lr * s, lg - lg * s, lb + (1 - lb) * s, 0, 0},
		{0, 0, 0, 1, 0},
	}
}

// canvas_matrix applies a colour matrix to the rectangle (see Color_Matrix);
// with `linear` to light. False for rectangles outside the canvases or no
// such canvas.
canvas_matrix :: proc(g: Gpu, src: Canvas, x, y, w, h: int, dst: Canvas, to: [2]int, m: Color_Matrix, linear := false) -> bool {
	return canvas_filter_run(g, src, x, y, w, h, dst, to, gpu.Filter{kind = .Matrix, colors = m, linear = linear})
}

// canvas_curves puts each channel through its curve in `curve`, a canvas
// of n × 1 texels (n ≥ 2): texel i holds each channel's output for input
// i / (n - 1), outputs between them interpolated (canvas_curve_make builds
// one). With `linear` the curves apply to light.
canvas_curves :: proc(g: Gpu, src: Canvas, x, y, w, h: int, dst: Canvas, to: [2]int, curve: Canvas, linear := false) -> bool {
	return canvas_filter_run(g, src, x, y, w, h, dst, to, gpu.Filter{kind = .Curves, table = canvas_page_of(g, curve), linear = linear}, curve)
}

// canvas_convert converts the rectangle from `src`'s colour space to
// `dst`'s: the source's curve undone, its primaries mapped to the
// destination's, the destination's curve done. Colours outside the
// destination's gamut are clipped into an unsigned format. Alpha is kept.
canvas_convert :: proc(g: Gpu, src: Canvas, x, y, w, h: int, dst: Canvas, to: [2]int) -> bool {
	return canvas_filter_run(g, src, x, y, w, h, dst, to, gpu.Filter{kind = .Convert})
}

// canvas_lut puts each texel's colour through a 3D LUT, `lut`: a canvas of
// n² × n texels (n ≥ 2) whose texel (r + b × n, g) holds the output for
// input (r, g, b) / (n - 1), outputs between them interpolated trilinearly
// (canvas_lut_make builds one). For a conversion an ICC engine worked out.
// Alpha is kept.
canvas_lut :: proc(g: Gpu, src: Canvas, x, y, w, h: int, dst: Canvas, to: [2]int, lut: Canvas) -> bool {
	return canvas_filter_run(g, src, x, y, w, h, dst, to, gpu.Filter{kind = .Lut, table = canvas_page_of(g, lut)}, lut)
}

// canvas_blur blurs the rectangle with a Gaussian of `sigma` texels (it
// reaches three sigmas; a texel past the canvas's edge is its edge's).
// Colour is blurred premultiplied, so transparent texels lend it none; with
// `linear` light is blurred.
canvas_blur :: proc(g: Gpu, src: Canvas, x, y, w, h: int, dst: Canvas, to: [2]int, sigma: f32, linear := false) -> bool {
	return canvas_filter_run(g, src, x, y, w, h, dst, to, gpu.Filter{kind = .Blur, sigma = sigma, linear = linear})
}

// canvas_sharpen is an unsharp mask: each channel pushed away from its blur
// (a Gaussian of `sigma`) by `amount` (1 doubles the difference) where the
// difference is at least `threshold`. Alpha is kept.
canvas_sharpen :: proc(g: Gpu, src: Canvas, x, y, w, h: int, dst: Canvas, to: [2]int, amount, sigma: f32, threshold: f32 = 0, linear := false) -> bool {
	return canvas_filter_run(g, src, x, y, w, h, dst, to, gpu.Filter{kind = .Sharpen, sigma = sigma, amount = amount, threshold = threshold, linear = linear})
}

// canvas_curve_make is a curves table for canvas_curves: `points` are each
// channel's outputs at even steps of its input, first at 0, last at 1.
// The caller's: canvas_destroy.
canvas_curve_make :: proc(g: Gpu, points: [][4]f32) -> (c: Canvas, ok: bool) {
	if len(points) < 2 do return
	c = canvas_create(g, {len(points), 1}, .RGBA32F, .Linear) or_return
	canvas_write(g, c, 0, 0, len(points), 1, mem.slice_to_bytes(points))
	return c, true
}

// canvas_lut_make is a 3D LUT for canvas_lut from `rgb`: size³ outputs, red
// changing fastest, then green, then blue. The caller's: canvas_destroy.
canvas_lut_make :: proc(g: Gpu, size: int, rgb: [][3]f32) -> (c: Canvas, ok: bool) {
	if size < 2 || len(rgb) < size * size * size do return
	c = canvas_create(g, {size * size, size}, .RGBA32F, .Linear) or_return
	texels := make([][4]f32, size * size * size, context.temp_allocator)
	for b in 0 ..< size do for gg in 0 ..< size do for r in 0 ..< size {
		v := rgb[(b * size + gg) * size + r]
		texels[gg * size * size + b * size + r] = {v.r, v.g, v.b, 1}
	}
	canvas_write(g, c, 0, 0, size * size, size, mem.slice_to_bytes(texels))
	return c, true
}

@(private)
canvas_page_of :: proc(g: Gpu, c: Canvas) -> gpu.Page {
	e := canvas_entry(g, c)
	return e.page if e != nil else 0
}

// canvas_filter_run checks a filter's canvases and runs it: queued on the
// GPU, or now on the reference.
@(private)
canvas_filter_run :: proc(g: Gpu, src: Canvas, x, y, w, h: int, dst: Canvas, to: [2]int, f: gpu.Filter, table: Canvas = 0) -> bool {
	s, d := canvas_entry(g, src), canvas_entry(g, dst)
	if s == nil || d == nil || !canvas_rect_ok(s, x, y, w, h) || !canvas_rect_ok(d, to.x, to.y, w, h) do return false
	t: ^Canvas_Entry
	if f.kind == .Curves || f.kind == .Lut {
		t = canvas_entry(g, table)
		if t == nil || table == dst do return false
		if f.kind == .Curves && t.size.x < 2 do return false
		if f.kind == .Lut && (t.size.y < 2 || t.size.x != t.size.y * t.size.y) do return false
	}
	if g.host.r != nil {
		if !gpu.canvas_filter(g.host.r, s.page, u32(x), u32(y), u32(w), u32(h), d.page, u32(to.x), u32(to.y), f) do return false
	} else {
		filter_reference(s, x, y, w, h, d, to, f, t)
	}
	d.version += 1
	return true
}

// filter_reference is the CPU reference of filter.frag.
@(private)
filter_reference :: proc(s: ^Canvas_Entry, x, y, w, h: int, d: ^Canvas_Entry, to: [2]int, f: gpu.Filter, t: ^Canvas_Entry) {
	// the input, copied: rectangle and margin, within the canvas
	m := 0
	if f.kind == .Blur || f.kind == .Sharpen do m = int(math.ceil(3 * max(f.sigma, 0.01)))
	x0, y0 := max(x - m, 0), max(y - m, 0)
	x1, y1 := min(x + w + m, s.size.x), min(y + h + m, s.size.y)
	cw, ch := x1 - x0, y1 - y0
	sb := gpu.canvas_bpp(s.format)
	input := make([][4]f32, cw * ch, context.temp_allocator)
	for row in 0 ..< ch do for col in 0 ..< cw do input[row * cw + col] = canvas_decode(s.format, s.pixels[((y0 + row) * s.size.x + x0 + col) * sb:][:sb])
	at_in :: proc(input: [][4]f32, cw, ch, col, row: int) -> [4]f32 { return input[clamp(row, 0, ch - 1) * cw + clamp(col, 0, cw - 1)] }
	icurve, ocurve := blend_curve(s.space), blend_curve(d.space)
	dec :: proc(c: [3]f32, curve: u32) -> [3]f32 { return {curve_decode(c.r, curve), curve_decode(c.g, curve), curve_decode(c.b, curve)} }
	enc :: proc(c: [3]f32, curve: u32) -> [3]f32 { return {curve_encode(c.r, curve), curve_encode(c.g, curve), curve_encode(c.b, curve)} }
	ox, oy := x - x0, y - y0
	out := make([][4]f32, w * h, context.temp_allocator)
	switch f.kind {
	case .Blur, .Sharpen:
		sigma := max(f.sigma, 0.01)
		r := int(math.ceil(3 * sigma))
		weights := make([]f32, 2 * r + 1, context.temp_allocator)
		wsum: f32
		for k in -r ..= r {
			weights[k + r] = math.exp(-f32(k * k) / (2 * sigma * sigma))
			wsum += weights[k + r]
		}
		mid := make([][4]f32, w * ch, context.temp_allocator) // across, premultiplied
		for row in 0 ..< ch do for col in 0 ..< w {
			sum: [4]f32
			for k in -r ..= r {
				v := at_in(input, cw, ch, col + ox + k, row)
				if f.linear do v.rgb = dec(v.rgb, icurve)
				v.rgb *= v.a
				sum += weights[k + r] * v
			}
			mid[row * w + col] = sum / wsum
		}
		for row in 0 ..< h do for col in 0 ..< w {
			sum: [4]f32
			for k in -r ..= r do sum += weights[k + r] * mid[clamp(row + oy + k, 0, ch - 1) * w + col]
			v := sum / wsum
			c := v.rgb / v.a if v.a > 0 else [3]f32{}
			if f.kind == .Sharpen {
				o := at_in(input, cw, ch, col + ox, row + oy)
				oc := dec(o.rgb, icurve) if f.linear else o.rgb
				diff := oc - c
				sharp := oc + f.amount * diff
				for k in 0 ..< 3 do c[k] = sharp[k] if abs(diff[k]) >= f.threshold else oc[k]
				v.a = o.a
			}
			if f.linear do c = enc(c, ocurve)
			out[row * w + col] = {c.r, c.g, c.b, v.a}
		}
	case .Matrix, .Curves, .Convert, .Lut:
		conv := gpu.space_matrix(s.space, d.space)
		for row in 0 ..< h do for col in 0 ..< w {
			v := at_in(input, cw, ch, col + ox, row + oy)
			if f.kind == .Convert {
				l := dec(v.rgb, icurve)
				l = {conv[0][0] * l.r + conv[0][1] * l.g + conv[0][2] * l.b, conv[1][0] * l.r + conv[1][1] * l.g + conv[1][2] * l.b, conv[2][0] * l.r + conv[2][1] * l.g + conv[2][2] * l.b}
				c := enc(l, ocurve)
				out[row * w + col] = {c.r, c.g, c.b, v.a}
				continue
			}
			if f.linear do v.rgb = dec(v.rgb, icurve)
			#partial switch f.kind {
			case .Matrix:
				mm := f.colors
				o: [4]f32
				for k in 0 ..< 4 do o[k] = mm[k][0] * v.r + mm[k][1] * v.g + mm[k][2] * v.b + mm[k][3] * v.a + mm[k][4]
				v = o
			case .Curves:
				for k in 0 ..< 4 do v[k] = table_curve(t, v[k], k)
			case .Lut:
				v.rgb = table_lut(t, v.rgb)
			}
			if f.linear do v.rgb = enc(v.rgb, ocurve)
			out[row * w + col] = v
		}
	}
	db := gpu.canvas_bpp(d.format)
	for row in 0 ..< h do for col in 0 ..< w {
		texel := canvas_encode(d.format, out[row * w + col])
		copy(d.pixels[((to.y + row) * d.size.x + to.x + col) * db:][:db], texel[:db])
	}
}

@(private)
table_texel :: proc(t: ^Canvas_Entry, col, row: int) -> [4]f32 {
	b := gpu.canvas_bpp(t.format)
	return canvas_decode(t.format, t.pixels[(row * t.size.x + col) * b:][:b])
}

// table_curve is channel `ch` of `v` through a curves table, as filter.frag's curve1.
@(private)
table_curve :: proc(t: ^Canvas_Entry, v: f32, ch: int) -> f32 {
	n := t.size.x
	x := clamp(v, 0, 1) * f32(n - 1)
	i := min(int(math.floor(x)), n - 2)
	k := x - f32(i)
	a, b := table_texel(t, i, 0)[ch], table_texel(t, i + 1, 0)[ch]
	return a + (b - a) * k
}

// table_lut is a colour through a 3D LUT, as filter.frag's lut3.
@(private)
table_lut :: proc(t: ^Canvas_Entry, v: [3]f32) -> (out: [3]f32) {
	n := t.size.y
	x := [3]f32{clamp(v.r, 0, 1), clamp(v.g, 0, 1), clamp(v.b, 0, 1)} * f32(n - 1)
	i := [3]int{min(int(math.floor(x.r)), n - 2), min(int(math.floor(x.g)), n - 2), min(int(math.floor(x.b)), n - 2)}
	k := x - [3]f32{f32(i.r), f32(i.g), f32(i.b)}
	for c in 0 ..< 8 {
		o := [3]int{c & 1, (c >> 1) & 1, (c >> 2) & 1}
		wt := (k.r if o.r == 1 else 1 - k.r) * (k.g if o.g == 1 else 1 - k.g) * (k.b if o.b == 1 else 1 - k.b)
		p := i + o
		out += wt * table_texel(t, p.r + p.b * n, p.g).rgb
	}
	return
}
