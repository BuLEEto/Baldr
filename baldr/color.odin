package baldr

// Colour science for themes: OKLab / OKLCH (a perceptual space, where equal
// steps look equal and hue stays put while lightness and chroma change),
// WCAG 2 relative luminance and contrast ratio, and gamut mapping. Colours
// in Baldr are linear sRGB; these convert to and from that directly (no sRGB
// transfer involved).

import "core:math"

// oklch makes a colour from perceptual lightness L (0..1), chroma C (0 = grey,
// ~0.3 = vivid) and hue h in degrees, mapped into the sRGB gamut by reducing
// chroma when needed (lightness and hue are kept).
oklch :: proc "contextless" (L, C, h: f32, alpha: f32 = 1) -> Color {
	c := C
	rgb := oklab_to_linear(oklab_from_lch(L, c, h))
	for _ in 0 ..< 24 {
		if in_gamut(rgb) do break
		c *= 0.85
		rgb = oklab_to_linear(oklab_from_lch(L, c, h))
	}
	return {clamp(rgb.x, 0, 1), clamp(rgb.y, 0, 1), clamp(rgb.z, 0, 1), alpha}
}

// oklch_of returns the OKLCH coordinates of a linear colour.
oklch_of :: proc "contextless" (c: Color) -> (L, C, h: f32) {
	lab := linear_to_oklab({c.r, c.g, c.b})
	L = lab.x
	C = math.sqrt(lab.y * lab.y + lab.z * lab.z)
	h = math.atan2(lab.z, lab.y) * 180 / math.PI
	if h < 0 do h += 360
	return
}

// with_alpha copies a colour with a different alpha.
with_alpha :: proc "contextless" (c: Color, a: f32) -> Color {
	return {c.r, c.g, c.b, a}
}

// luminance is WCAG 2 relative luminance (Y) of a linear colour.
luminance :: proc "contextless" (c: Color) -> f32 {
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
}

// contrast_ratio is the WCAG 2 ratio between two colours (1 = same, 21 =
// black on white). Text wants ≥ 4.5, large text and UI edges ≥ 3.
contrast_ratio :: proc "contextless" (a, b: Color) -> f32 {
	la, lb := luminance(a), luminance(b)
	hi, lo := max(la, lb), min(la, lb)
	return (hi + 0.05) / (lo + 0.05)
}

// ensure_contrast moves `fg`'s lightness away from `bg` until the ratio is
// at least `min`, keeping its hue and chroma (chroma shrinks only if the
// gamut forces it). Returns fg unchanged when it already passes.
ensure_contrast :: proc "contextless" (fg, bg: Color, min: f32) -> Color {
	if contrast_ratio(fg, bg) >= min do return fg
	L, C, h := oklch_of(fg)
	bgL, _, _ := oklch_of(bg)
	dir: f32 = 1 if L >= bgL else -1
	lo := L
	hi: f32 = 1 if dir > 0 else 0
	best := fg
	for _ in 0 ..< 20 {
		mid := (lo + hi) / 2
		cand := oklch(mid, C, h, fg.a)
		if contrast_ratio(cand, bg) >= min {
			best = cand
			hi = mid
		} else {
			lo = mid
		}
		if abs(hi - lo) < 0.002 do break
	}
	if contrast_ratio(best, bg) < min do best = oklch(1 if dir > 0 else 0.0, 0, h, fg.a)
	return best
}

@(private)
in_gamut :: proc "contextless" (c: [3]f32) -> bool {
	e :: f32(0.0005)
	return c.x >= -e && c.x <= 1 + e && c.y >= -e && c.y <= 1 + e && c.z >= -e && c.z <= 1 + e
}

@(private)
oklab_from_lch :: proc "contextless" (L, C, h: f32) -> [3]f32 {
	r := h * math.PI / 180
	return {L, C * math.cos(r), C * math.sin(r)}
}

@(private)
linear_to_oklab :: proc "contextless" (c: [3]f32) -> [3]f32 {
	l := 0.4122214708 * c.x + 0.5363325363 * c.y + 0.0514459929 * c.z
	m := 0.2119034982 * c.x + 0.6806995451 * c.y + 0.1073969566 * c.z
	s := 0.0883024619 * c.x + 0.2817188376 * c.y + 0.6299787005 * c.z
	l_ := cbrt(l)
	m_ := cbrt(m)
	s_ := cbrt(s)
	return {
		0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
		1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
		0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_,
	}
}

@(private)
oklab_to_linear :: proc "contextless" (lab: [3]f32) -> [3]f32 {
	l_ := lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z
	m_ := lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z
	s_ := lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z
	l := l_ * l_ * l_
	m := m_ * m_ * m_
	s := s_ * s_ * s_
	return {
		4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
		-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
		-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
	}
}

@(private)
cbrt :: proc "contextless" (x: f32) -> f32 {
	if x < 0 do return -math.pow(-x, 1.0 / 3.0)
	return math.pow(x, 1.0 / 3.0)
}
