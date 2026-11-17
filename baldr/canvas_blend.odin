package baldr

// Compositing canvases: a layer laid onto another with one of the 27
// standard layer blend modes, an opacity and a mask. On the GPU it is
// gpu/shaders/blend.frag; this is its CPU reference, formula for formula,
// which the GPU's results match to within a code value (its arithmetic
// rounds a little differently).
//
// Compositing is W3C Compositing and Blending Level 1's source-over with
// blending: where the backdrop is opaque the blended colour B(backdrop,
// source) replaces the source's, laid over the backdrop by the source's
// alpha × opacity × mask. Straight alpha in, straight alpha out. Stored
// values are blended by default, as image editors do; `linear` blends light
// instead (each canvas's curve undone first and the destination's after).

import "core:math"
import "baldr:gpu"

// Blend_Mode is how a layer's colour meets what it is laid over: the 27
// standard layer blend modes, in the usual menu order (Normal, Dissolve; Darken,
// Multiply, Color Burn, Linear Burn, Darker Color; Lighten, Screen, Color
// Dodge, Linear Dodge (Add), Lighter Color; Overlay, Soft Light, Hard
// Light, Vivid Light, Linear Light, Pin Light, Hard Mix; Difference,
// Exclusion, Subtract, Divide; Hue, Saturation, Color, Luminosity).
Blend_Mode :: gpu.Blend_Mode

// canvas_blend lays w × h texels at x, y of `src` onto `to` in `dst` by
// `mode`, at `opacity` (0..1), through `mask` (0 for none): a canvas whose
// first channel, lined up texel for texel with the source, says how much of
// each shows (a grey mask reads the same in R, G and B). `linear` blends in
// light instead of on stored values. `seed` picks Dissolve's pattern. False
// for rectangles outside the canvases, a mask not covering the source's
// rectangle, `src` being `dst`, or no such canvas.
canvas_blend :: proc(g: Gpu, src: Canvas, x, y, w, h: int, dst: Canvas, to: [2]int, mode := Blend_Mode.Normal, opacity: f32 = 1, mask: Canvas = 0, linear := false, seed: u32 = 0) -> bool {
	s, d := canvas_entry(g, src), canvas_entry(g, dst)
	if s == nil || d == nil || src == dst || !canvas_rect_ok(s, x, y, w, h) || !canvas_rect_ok(d, to.x, to.y, w, h) do return false
	m: ^Canvas_Entry
	if mask != 0 {
		m = canvas_entry(g, mask)
		if m == nil || mask == dst || !canvas_rect_ok(m, x, y, w, h) do return false
	}
	if g.host.r != nil {
		mp := m.page if m != nil else 0
		if !gpu.canvas_blend(g.host.r, s.page, u32(x), u32(y), u32(w), u32(h), d.page, u32(to.x), u32(to.y), mode, opacity, mp, linear, seed) do return false
	} else {
		sb, db := gpu.canvas_bpp(s.format), gpu.canvas_bpp(d.format)
		for row in 0 ..< h do for col in 0 ..< w {
			cs := canvas_decode(s.format, s.pixels[((y + row) * s.size.x + x + col) * sb:][:sb])
			into := d.pixels[((to.y + row) * d.size.x + to.x + col) * db:][:db]
			cb := canvas_decode(d.format, into)
			k: f32 = 1
			if m != nil {
				mb := gpu.canvas_bpp(m.format)
				k = canvas_decode(m.format, m.pixels[((y + row) * m.size.x + x + col) * mb:][:mb]).r
			}
			out := blend_texel(mode, cb, cs, opacity * k, linear, blend_curve(d.space), blend_curve(s.space), {to.x + col, to.y + row}, seed)
			texel := canvas_encode(d.format, out)
			copy(into, texel[:db])
		}
	}
	d.version += 1
	return true
}

// blend_curve is the transfer curve linear maths undoes for a space: 0
// sRGB's (sRGB, Display P3), 1 Adobe RGB's, 2 none. As canvas_curve in gpu.
@(private)
blend_curve :: proc "contextless" (space: Color_Space) -> u32 {
	switch space {
	case .sRGB, .Display_P3: return 0
	case .Adobe_RGB:         return 1
	case .Linear:            return 2
	}
	return 0
}

@(private)
curve_decode :: proc(c: f32, curve: u32) -> f32 {
	switch curve {
	case 2: return c
	case 1: return math.pow(max(c, 0), f32(2.19921875))
	}
	return c / 12.92 if c <= 0.04045 else math.pow((c + 0.055) / 1.055, f32(2.4))
}

@(private)
curve_encode :: proc(c: f32, curve: u32) -> f32 {
	switch curve {
	case 2: return c
	case 1: return math.pow(max(c, 0), f32(1) / 2.19921875)
	}
	return c * 12.92 if c <= 0.0031308 else 1.055 * math.pow(c, f32(1) / 2.4) - 0.055
}

@(private)
blend_lum :: proc "contextless" (c: [3]f32) -> f32 { return 0.3 * c.r + 0.59 * c.g + 0.11 * c.b }

@(private)
blend_clip :: proc "contextless" (c_in: [3]f32) -> [3]f32 {
	c := c_in
	l := blend_lum(c)
	n := min(c.r, c.g, c.b)
	x := max(c.r, c.g, c.b)
	if n < 0 do c = l + (c - l) * l / (l - n)
	if x > 1 do c = l + (c - l) * (1 - l) / (x - l)
	return c
}

@(private)
blend_set_lum :: proc "contextless" (c: [3]f32, l: f32) -> [3]f32 { return blend_clip(c + (l - blend_lum(c))) }

@(private)
blend_sat :: proc "contextless" (c: [3]f32) -> f32 { return max(c.r, c.g, c.b) - min(c.r, c.g, c.b) }

@(private)
blend_set_sat :: proc "contextless" (c: [3]f32, s: f32) -> [3]f32 {
	mx, mn := max(c.r, c.g, c.b), min(c.r, c.g, c.b)
	return (c - mn) * s / (mx - mn) if mx > mn else {}
}

@(private)
blend_burn :: proc "contextless" (b, s: f32) -> f32 {
	if b >= 1 do return 1
	if s <= 0 do return 0
	return 1 - min(1, (1 - b) / s)
}

@(private)
blend_dodge :: proc "contextless" (b, s: f32) -> f32 {
	if b <= 0 do return 0
	if s >= 1 do return 1
	return min(1, b / (1 - s))
}

// blend_sep is a separable mode on one channel.
@(private)
blend_sep :: proc(mode: Blend_Mode, b, s: f32) -> f32 {
	#partial switch mode {
	case .Darken:       return min(b, s)
	case .Multiply:     return b * s
	case .Color_Burn:   return blend_burn(b, s)
	case .Linear_Burn:  return max(b + s - 1, 0)
	case .Lighten:      return max(b, s)
	case .Screen:       return b + s - b * s
	case .Color_Dodge:  return blend_dodge(b, s)
	case .Linear_Dodge: return min(b + s, 1)
	case .Overlay:      return 2 * b * s if b <= 0.5 else 1 - 2 * (1 - b) * (1 - s)
	case .Soft_Light:
		if s <= 0.5 do return b - (1 - 2 * s) * b * (1 - b)
		d := ((16 * b - 12) * b + 4) * b if b <= 0.25 else math.sqrt(b)
		return b + (2 * s - 1) * (d - b)
	case .Hard_Light:   return 2 * b * s if s <= 0.5 else 1 - 2 * (1 - b) * (1 - s)
	case .Vivid_Light:  return blend_burn(b, 2 * s) if s <= 0.5 else blend_dodge(b, 2 * (s - 0.5))
	case .Linear_Light: return clamp(b + 2 * s - 1, 0, 1)
	case .Pin_Light:    return min(b, 2 * s) if s <= 0.5 else max(b, 2 * s - 1)
	case .Hard_Mix:     return 1 if b + s >= 1 else 0
	case .Difference:   return abs(b - s)
	case .Exclusion:    return b + s - 2 * b * s
	case .Subtract:     return max(b - s, 0)
	case .Divide:
		if s <= 0 do return 1 if b > 0 else 0
		return min(b / s, 1)
	}
	return s
}

// blend_mix is the blended colour B(backdrop, source).
@(private)
blend_mix :: proc(mode: Blend_Mode, b, s: [3]f32) -> [3]f32 {
	#partial switch mode {
	case .Darker_Color:  return s if s.r + s.g + s.b < b.r + b.g + b.b else b
	case .Lighter_Color: return s if s.r + s.g + s.b > b.r + b.g + b.b else b
	case .Hue:           return blend_set_lum(blend_set_sat(s, blend_sat(b)), blend_lum(b))
	case .Saturation:    return blend_set_lum(blend_set_sat(b, blend_sat(s)), blend_lum(b))
	case .Color:         return blend_set_lum(s, blend_lum(b))
	case .Luminosity:    return blend_set_lum(b, blend_lum(s))
	}
	return {blend_sep(mode, b.r, s.r), blend_sep(mode, b.g, s.g), blend_sep(mode, b.b, s.b)}
}

// blend_hash is Dissolve's pattern: PCG, as blend.frag has it.
@(private)
blend_hash :: proc "contextless" (v: u32) -> u32 {
	state := v * 747796405 + 2891336453
	word := ((state >> ((state >> 28) + 4)) ~ state) * 277803737
	return (word >> 22) ~ word
}

// blend_texel composites one source texel `src` onto backdrop `dst` (as
// stored), `weight` being opacity × mask, at destination pixel `at`.
@(private)
blend_texel :: proc(mode: Blend_Mode, dst, src: [4]f32, weight: f32, linear: bool, dcurve, scurve: u32, at: [2]int, seed: u32) -> [4]f32 {
	as := clamp(src.a * weight, 0, 1)
	ab := clamp(dst.a, 0, 1)
	if mode == .Dissolve {
		r := f32(blend_hash(u32(at.x) * 1973 + u32(at.y) * 9277 + seed) >> 8) / 16777216
		as = 1 if r < as else 0
	}
	cb, cs := dst.rgb, src.rgb
	if linear {
		cb = {curve_decode(cb.r, dcurve), curve_decode(cb.g, dcurve), curve_decode(cb.b, dcurve)}
		cs = {curve_decode(cs.r, scurve), curve_decode(cs.g, scurve), curve_decode(cs.b, scurve)}
	}
	mixed := (1 - ab) * cs + ab * blend_mix(mode, cb, cs)
	ao := as + ab * (1 - as)
	co: [3]f32
	if ao > 0 do co = (as * mixed + ab * (1 - as) * cb) / ao
	if linear do co = {curve_encode(co.r, dcurve), curve_encode(co.g, dcurve), curve_encode(co.b, dcurve)}
	return {co.r, co.g, co.b, ao}
}
