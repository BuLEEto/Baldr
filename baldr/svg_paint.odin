package baldr

// SVG paint: canvases (premultiplied sRGB floats), what fills and strokes
// are painted with (colours, gradients, patterns, pictures), and the filter
// primitives. See svg_doc.odin.

import "core:encoding/base64"
import "core:encoding/xml"
import "core:image"
import "core:image/jpeg"
import "core:image/png"
import "core:math"
import "core:mem"
import "core:slice"
import "core:strings"

@(private)
Svg_Canvas :: struct {
	px:   []f32, // premultiplied RGBA, sRGB
	w, h: int,
}

@(private)
svg_canvas_make :: proc(w, h: int) -> ^Svg_Canvas {
	c := new(Svg_Canvas)
	c^ = {px = make([]f32, w * h * 4), w = w, h = h}
	return c
}

// svg_layer is a clear canvas for a group to draw into before it is
// composited with its opacity, clip, mask or filter.
@(private)
svg_layer :: proc(d: ^Svg_Doc, w, h: int) -> ^Svg_Canvas {
	#reverse for c, i in d.pool {
		if c.w == w && c.h == h {
			unordered_remove(&d.pool, i)
			mem.zero_slice(c.px)
			return c
		}
	}
	return svg_canvas_make(w, h)
}

@(private)
svg_layer_release :: proc(d: ^Svg_Doc, c: ^Svg_Canvas) {
	append(&d.pool, c)
}

@(private)
svg_canvas_clear :: proc(c: ^Svg_Canvas) {
	mem.zero_slice(c.px)
}

@(private)
svg_canvas_over :: proc(dst, src: ^Svg_Canvas, opacity: f32) {
	for i := 0; i < len(src.px); i += 4 {
		a := src.px[i + 3] * opacity
		if a <= 0 do continue
		k := 1 - a
		dst.px[i] = src.px[i] * opacity + dst.px[i] * k
		dst.px[i + 1] = src.px[i + 1] * opacity + dst.px[i + 1] * k
		dst.px[i + 2] = src.px[i + 2] * opacity + dst.px[i + 2] * k
		dst.px[i + 3] = a + dst.px[i + 3] * k
	}
}

@(private)
svg_raster_for :: proc(d: ^Svg_Doc, c: ^Svg_Canvas) -> ^Svg_Raster {
	for r in d.rasters do if r.w == c.w && r.h == c.h do return r
	r := svg_raster_make(c.w, c.h)
	append(&d.rasters, r)
	return r
}

// svg_clip_rect keeps what of `c` lies inside `rect` (user space, through `xf`).
@(private)
svg_clip_rect :: proc(d: ^Svg_Doc, c: ^Svg_Canvas, xf: Svg_Xf, rect: [4]f32) {
	r := svg_raster_for(d, c)
	x, y, w, h := rect[0], rect[1], rect[2], rect[3]
	svg_raster_piece(r, xf, {{x, y}, {x + w, y}, {x + w, y + h}, {x, y + h}})
	svg_raster_fill(r, false)
	for py in 0 ..< c.h {
		for px in 0 ..< c.w {
			k: f32
			if px >= r.x0 && px < r.x1 && py >= r.y0 && py < r.y1 do k = r.cov[py * r.w + px]
			if k >= 1 do continue
			i := (py * c.w + px) * 4
			c.px[i] *= k
			c.px[i + 1] *= k
			c.px[i + 2] *= k
			c.px[i + 3] *= k
		}
	}
}

// svg_composite paints the raster's coverage with `sh`, source over.
@(private)
svg_composite :: proc(c: ^Svg_Canvas, r: ^Svg_Raster, sh: ^Svg_Shader, opacity: f32) {
	if opacity <= 0 do return
	for y in r.y0 ..< r.y1 {
		for x in r.x0 ..< r.x1 {
			k := r.cov[y * r.w + x] * opacity
			if k <= 0 do continue
			col := sh.color if sh.kind == .Solid else svg_shade(sh, x, y)
			a := col.a * k
			if a <= 0 do continue
			i := (y * c.w + x) * 4
			inv := 1 - a
			c.px[i] = col.r * k + c.px[i] * inv
			c.px[i + 1] = col.g * k + c.px[i + 1] * inv
			c.px[i + 2] = col.b * k + c.px[i + 2] * inv
			c.px[i + 3] = a + c.px[i + 3] * inv
		}
	}
}

// Paint servers

@(private)
Svg_Shader_Kind :: enum u8 { Solid, Linear, Radial, Pattern, Image }

@(private)
Svg_Spread :: enum u8 { Pad, Reflect, Repeat }

@(private)
Svg_Shader :: struct {
	kind:   Svg_Shader_Kind,
	color:  [4]f32, // Solid, premultiplied
	inv:    Svg_Xf, // device pixels to the paint's own space
	a, b:   [2]f32, // Linear: the ends; Radial: the centre and the focus; Pattern: the tile's origin and size
	r, fr:  f32, // Radial: the radius and the focal radius
	spread: Svg_Spread,
	lut:    ^[256][4]f32, // gradient colours, premultiplied
	tile:   ^Svg_Canvas,
	img:    ^Image,
}

@(private)
svg_solid :: proc "contextless" (c: [4]f32) -> Svg_Shader {
	return {kind = .Solid, color = {c.r * c.a, c.g * c.a, c.b * c.a, c.a}}
}

// svg_shader is what `paint` paints with; false paints nothing. `box` is
// the shape's bounding box, for objectBoundingBox units.
@(private)
svg_shader :: proc(d: ^Svg_Doc, paint: ^Svg_Paint, s: ^Svg_Style, xf: Svg_Xf, box: Svg_Box) -> (sh: Svg_Shader, ok: bool) {
	switch paint.kind {
	case .None:
		return
	case .Color:
		return svg_solid(paint.color), paint.color.a > 0
	case .Current:
		return svg_solid(s.color), s.color.a > 0
	case .Url:
		if id, found := d.ids[paint.url]; found {
			switch svg_name(d, id) {
			case "linearGradient", "radialGradient": return svg_gradient(d, id, xf, box)
			case "pattern":                          return svg_pattern(d, id, xf, box)
			}
		}
		switch paint.fallback {
		case .Color:      return svg_solid(paint.fallback_color), true
		case .Current:    return svg_solid(s.color), true
		case .None, .Url: return
		}
	}
	return
}

@(private)
Svg_Stop :: struct {
	offset: f32,
	color:  [4]f32, // straight alpha
}

@(private)
svg_gradient :: proc(d: ^Svg_Doc, id: xml.Element_ID, xf: Svg_Xf, box: Svg_Box) -> (sh: Svg_Shader, ok: bool) {
	chain := svg_href_chain(d, id, {"linearGradient", "radialGradient"})
	stops := make([dynamic]Svg_Stop, 0, 4)
	for g in chain { // the stops of the first gradient in the chain that has any
		for v in d.x.elements[g].value {
			sid, is := v.(xml.Element_ID)
			if !is || d.x.elements[sid].kind != .Element || svg_name(d, sid) != "stop" do continue
			ss := svg_style_chain(d, sid)
			col := ss.color if ss.stop_color.kind == .Current else ss.stop_color.color
			col.a *= ss.stop_opacity
			off := clamp(svg_fraction(svg_attr(&d.x.elements[sid], "offset")), 0, 1)
			if len(stops) > 0 do off = max(off, stops[len(stops) - 1].offset)
			append(&stops, Svg_Stop{off, col})
		}
		if len(stops) > 0 do break
	}
	if len(stops) == 0 do return // no stops paint as none
	last := svg_solid(stops[len(stops) - 1].color)
	if len(stops) == 1 do return last, true
	obb := svg_chain_attr(d, chain, "gradientUnits") != "userSpaceOnUse"
	m := xf
	if obb {
		if !svg_box_has_area(box) do return
		m = svg_xf_mul(m, svg_box_xf(box))
	}
	m = svg_xf_mul(m, svg_transform(svg_chain_attr(d, chain, "gradientTransform")))
	sh.inv = svg_xf_inverse(m) or_return
	switch svg_chain_attr(d, chain, "spreadMethod") {
	case "reflect": sh.spread = .Reflect
	case "repeat":  sh.spread = .Repeat
	}
	sh.lut = svg_gradient_lut(stops[:])
	if svg_name(d, id) == "radialGradient" {
		sh.kind = .Radial
		sh.a = {svg_paint_coord(d, chain, "cx", "50%", .X, obb), svg_paint_coord(d, chain, "cy", "50%", .Y, obb)}
		sh.r = svg_paint_coord(d, chain, "r", "50%", .Diag, obb)
		sh.b = sh.a
		if svg_chain_attr(d, chain, "fx") != "" do sh.b.x = svg_paint_coord(d, chain, "fx", "50%", .X, obb)
		if svg_chain_attr(d, chain, "fy") != "" do sh.b.y = svg_paint_coord(d, chain, "fy", "50%", .Y, obb)
		sh.fr = max(svg_paint_coord(d, chain, "fr", "0%", .Diag, obb), 0)
		if sh.r <= 0 do return last, true
		if off := sh.b - sh.a; sh.fr == 0 && linalg_len(off) > sh.r * 0.999 {
			sh.b = sh.a + off * (sh.r * 0.999 / linalg_len(off)) // SVG 1.1: a focus outside the circle comes in to its edge
		}
	} else {
		sh.kind = .Linear
		sh.a = {svg_paint_coord(d, chain, "x1", "0%", .X, obb), svg_paint_coord(d, chain, "y1", "0%", .Y, obb)}
		sh.b = {svg_paint_coord(d, chain, "x2", "100%", .X, obb), svg_paint_coord(d, chain, "y2", "0%", .Y, obb)}
		if sh.a == sh.b do return last, true
	}
	return sh, true
}

// svg_gradient_lut samples the stops 256 times, interpolating premultiplied.
@(private)
svg_gradient_lut :: proc(stops: []Svg_Stop) -> ^[256][4]f32 {
	pre :: proc(c: [4]f32) -> [4]f32 { return {c.r * c.a, c.g * c.a, c.b * c.a, c.a} }
	lut := new([256][4]f32)
	k := 0
	for i in 0 ..< 256 {
		t := f32(i) / 255
		for k < len(stops) - 2 && t > stops[k + 1].offset do k += 1
		a, b := stops[k], stops[k + 1]
		switch {
		case t <= a.offset: lut[i] = pre(a.color)
		case t >= b.offset: lut[i] = pre(b.color)
		case:
			f := (t - a.offset) / (b.offset - a.offset)
			lut[i] = pre(a.color) * (1 - f) + pre(b.color) * f
		}
	}
	return lut
}

// svg_href_chain is a paint server and the ones it inherits from by href.
@(private)
svg_href_chain :: proc(d: ^Svg_Doc, id: xml.Element_ID, names: []string) -> []xml.Element_ID {
	chain := make([dynamic]xml.Element_ID, 0, 2)
	cur := id
	for len(chain) < 16 {
		append(&chain, cur)
		next, found := svg_ref(d, svg_href(&d.x.elements[cur]))
		if !found || slice.contains(chain[:], next) || !slice.contains(names, svg_name(d, next)) do break
		cur = next
	}
	return chain[:]
}

@(private)
svg_chain_attr :: proc(d: ^Svg_Doc, chain: []xml.Element_ID, name: string) -> string {
	for id in chain do if v := svg_attr(&d.x.elements[id], name); v != "" do return v
	return ""
}

// svg_paint_coord reads a gradient's or pattern's coordinate: a fraction of
// the box in objectBoundingBox units, else a length.
@(private)
svg_paint_coord :: proc(d: ^Svg_Doc, chain: []xml.Element_ID, name, fallback: string, axis: Svg_Axis, obb: bool) -> f32 {
	l, ok := svg_parse_length(svg_chain_attr(d, chain, name))
	if !ok do l, _ = svg_parse_length(fallback)
	if obb do return l.v / 100 if l.unit == .Percent else l.v
	return svg_len(d, l, axis, 16)
}

@(private)
svg_fraction :: proc(v: string) -> f32 {
	l, ok := svg_parse_length(v)
	if !ok do return 0
	return l.v / 100 if l.unit == .Percent else l.v
}

// svg_pattern draws one tile at the device resolution, to be repeated.
@(private)
svg_pattern :: proc(d: ^Svg_Doc, id: xml.Element_ID, xf: Svg_Xf, box: Svg_Box) -> (sh: Svg_Shader, ok: bool) {
	if slice.contains(d.busy[:], id) do return // a pattern painted inside itself
	chain := svg_href_chain(d, id, {"pattern"})
	obb := svg_chain_attr(d, chain, "patternUnits") != "userSpaceOnUse"
	content_obb := svg_chain_attr(d, chain, "patternContentUnits") == "objectBoundingBox"
	if (obb || content_obb) && !svg_box_has_area(box) do return
	size := box.hi - box.lo
	rect := [4]f32{
		svg_paint_coord(d, chain, "x", "0", .X, obb), svg_paint_coord(d, chain, "y", "0", .Y, obb),
		svg_paint_coord(d, chain, "width", "0", .X, obb), svg_paint_coord(d, chain, "height", "0", .Y, obb),
	}
	if obb do rect = {box.lo.x + rect[0] * size.x, box.lo.y + rect[1] * size.y, rect[2] * size.x, rect[3] * size.y}
	if rect[2] <= 0 || rect[3] <= 0 do return
	content: xml.Element_ID
	found := false
	search: for p in chain { // the first pattern in the chain with children draws
		for v in d.x.elements[p].value {
			if _, is := v.(xml.Element_ID); is {
				content = p
				found = true
				break search
			}
		}
	}
	if !found do return
	m := svg_xf_mul(xf, svg_transform(svg_chain_attr(d, chain, "patternTransform")))
	sh.inv = svg_xf_inverse(m) or_return
	tw := clamp(int(math.ceil(rect[2] * linalg_len({m[0], m[1]}))), 1, 1024)
	th := clamp(int(math.ceil(rect[3] * linalg_len({m[2], m[3]}))), 1, 1024)
	tile := svg_canvas_make(tw, th)
	inner := Svg_Xf{f32(tw) / rect[2], 0, 0, f32(th) / rect[3], 0, 0}
	saved := d.view
	defer d.view = saved
	has_vb := false
	for p in chain {
		if vb, has := svg_viewbox(&d.x.elements[p]); has {
			inner = svg_xf_mul(inner, svg_fit(vb, {0, 0, rect[2], rect[3]}, svg_aspect(svg_chain_attr(d, chain, "preserveAspectRatio"))))
			d.view = {vb[2], vb[3]}
			has_vb = true
			break
		}
	}
	if !has_vb && content_obb do inner = svg_xf_mul(inner, {size.x, 0, 0, size.y, 0, 0})
	append(&d.busy, id)
	ps := svg_style_chain(d, content)
	svg_children(d, &d.x.elements[content], &ps, inner, tile, false)
	pop(&d.busy)
	sh.kind = .Pattern
	sh.a = {rect[0], rect[1]}
	sh.b = {rect[2], rect[3]}
	sh.tile = tile
	return sh, true
}

// svg_shade is the paint's premultiplied colour at a pixel's centre.
@(private)
svg_shade :: proc(sh: ^Svg_Shader, x, y: int) -> [4]f32 {
	p := svg_xf_apply(sh.inv, {f32(x) + 0.5, f32(y) + 0.5})
	switch sh.kind {
	case .Solid:
		return sh.color
	case .Linear:
		dir := sh.b - sh.a
		return svg_lut(sh, ((p.x - sh.a.x) * dir.x + (p.y - sh.a.y) * dir.y) / (dir.x * dir.x + dir.y * dir.y))
	case .Radial:
		// the largest t whose circle (centre focus→centre, radius fr→r) passes through p
		cd := sh.a - sh.b
		pd := p - sh.b
		dr := sh.r - sh.fr
		qa := cd.x * cd.x + cd.y * cd.y - dr * dr
		qb := pd.x * cd.x + pd.y * cd.y + sh.fr * dr
		qc := pd.x * pd.x + pd.y * pd.y - sh.fr * sh.fr
		t: f32
		if abs(qa) < 1e-6 {
			if abs(qb) < 1e-9 do return {}
			t = qc / (2 * qb)
		} else {
			disc := qb * qb - qa * qc
			if disc < 0 do return {}
			sq := math.sqrt(disc)
			t1, t2 := (qb + sq) / qa, (qb - sq) / qa
			t = max(t1, t2)
			if sh.fr + t * dr < 0 {
				t = min(t1, t2)
				if sh.fr + t * dr < 0 do return {}
			}
		}
		return svg_lut(sh, t)
	case .Pattern:
		u := (p.x - sh.a.x) / sh.b.x
		v := (p.y - sh.a.y) / sh.b.y
		return svg_sample_canvas(sh.tile, (u - math.floor(u)) * f32(sh.tile.w), (v - math.floor(v)) * f32(sh.tile.h))
	case .Image:
		return svg_sample_image(sh.img, p.x, p.y)
	}
	return {}
}

@(private)
svg_lut :: proc(sh: ^Svg_Shader, t_in: f32) -> [4]f32 {
	t := t_in
	switch sh.spread {
	case .Pad:
	case .Repeat:
		t -= math.floor(t)
	case .Reflect:
		t = abs(t)
		t -= 2 * math.floor(t / 2)
		if t > 1 do t = 2 - t
	}
	if !(t >= 0) do t = 0 // NaN too
	if t > 1 do t = 1
	return sh.lut[int(t * 255 + 0.5)]
}

// svg_sample_canvas reads a tile bilinearly, wrapping at its edges.
@(private)
svg_sample_canvas :: proc(c: ^Svg_Canvas, u, v: f32) -> [4]f32 {
	fx, fy := u - 0.5, v - 0.5
	if !(abs(fx) < 1e7 && abs(fy) < 1e7) do return {}
	x0, y0 := int(math.floor(fx)), int(math.floor(fy))
	tx, ty := fx - f32(x0), fy - f32(y0)
	at :: proc(c: ^Svg_Canvas, x, y: int) -> [4]f32 {
		i := ((y % c.h + c.h) % c.h * c.w + (x % c.w + c.w) % c.w) * 4
		return {c.px[i], c.px[i + 1], c.px[i + 2], c.px[i + 3]}
	}
	top := at(c, x0, y0) * (1 - tx) + at(c, x0 + 1, y0) * tx
	bottom := at(c, x0, y0 + 1) * (1 - tx) + at(c, x0 + 1, y0 + 1) * tx
	return top * (1 - ty) + bottom * ty
}

// svg_sample_image reads a picture bilinearly, its edges extended, premultiplied.
@(private)
svg_sample_image :: proc(img: ^Image, u, v: f32) -> [4]f32 {
	fx, fy := u - 0.5, v - 0.5
	if !(abs(fx) < 1e7 && abs(fy) < 1e7) do return {}
	x0, y0 := int(math.floor(fx)), int(math.floor(fy))
	tx, ty := fx - f32(x0), fy - f32(y0)
	at :: proc(img: ^Image, x, y: int) -> [4]f32 {
		i := (clamp(y, 0, img.height - 1) * img.width + clamp(x, 0, img.width - 1)) * 4
		a := f32(img.pixels[i + 3]) / 255
		return {f32(img.pixels[i]) / 255 * a, f32(img.pixels[i + 1]) / 255 * a, f32(img.pixels[i + 2]) / 255 * a, a}
	}
	top := at(img, x0, y0) * (1 - tx) + at(img, x0 + 1, y0) * tx
	bottom := at(img, x0, y0 + 1) * (1 - tx) + at(img, x0 + 1, y0 + 1) * tx
	return top * (1 - ty) + bottom * ty
}

// Pictures

@(private)
svg_draw_image :: proc(d: ^Svg_Doc, e: ^xml.Element, s: ^Svg_Style, xf: Svg_Xf, c: ^Svg_Canvas, opacity: f32) {
	if !s.visible do return
	pic := svg_picture(d, svg_href(e))
	if pic == nil do return
	if d.mask_depth == 0 do d.other_paint = true
	fs := s.font_size
	x, y := svg_attr_len(d, e, "x", .X, fs), svg_attr_len(d, e, "y", .Y, fs)
	w, h := svg_attr_len(d, e, "width", .X, fs, -1), svg_attr_len(d, e, "height", .Y, fs, -1)
	iw, ih := f32(pic.levels[0].width), f32(pic.levels[0].height)
	switch {
	case w < 0 && h < 0: w, h = iw, ih
	case w < 0:          w = h * iw / ih
	case h < 0:          h = w * ih / iw
	}
	if w <= 0 || h <= 0 do return
	a := svg_aspect(svg_attr(e, "preserveAspectRatio"))
	m := svg_xf_mul(xf, svg_fit({0, 0, iw, ih}, {x, y, w, h}, a))
	// drawn much smaller, a picture reads from a halved copy so it doesn't
	// alias; squeezed on one axis, that axis chooses (as mipmapping does)
	img := svg_picture_level(pic, min(linalg_len({m[0], m[1]}), linalg_len({m[2], m[3]})))
	inv, inv_ok := svg_xf_inverse(svg_xf_mul(m, {iw / f32(img.width), 0, 0, ih / f32(img.height), 0, 0}))
	if !inv_ok do return
	r := svg_raster_for(d, c)
	if a.slice { // the picture overflows its rectangle, which clips it
		svg_raster_piece(r, xf, {{x, y}, {x + w, y}, {x + w, y + h}, {x, y + h}})
	} else {
		svg_raster_piece(r, m, {{0, 0}, {iw, 0}, {iw, ih}, {0, ih}})
	}
	svg_raster_fill(r, false)
	sh := Svg_Shader{kind = .Image, inv = inv, img = img}
	svg_composite(c, r, &sh, opacity)
}

@(private)
Svg_Picture :: struct {
	levels: [dynamic]Image, // as decoded, then each half the size of the one before
}

// svg_picture decodes a data URI once per document (icons repeat theirs);
// nil when it doesn't decode.
@(private)
svg_picture :: proc(d: ^Svg_Doc, href: string) -> ^Svg_Picture {
	if pic, seen := d.pictures[href]; seen do return pic
	pic: ^Svg_Picture
	if img, ok := svg_data_image(href); ok {
		pic = new(Svg_Picture)
		append(&pic.levels, img)
	}
	d.pictures[href] = pic
	return pic
}

// svg_picture_level is the smallest copy still drawn at least half size.
@(private)
svg_picture_level :: proc(pic: ^Svg_Picture, scale: f32) -> ^Image {
	k := 0
	for s := scale; s < 0.5; s *= 2 {
		if k + 1 == len(pic.levels) {
			last := &pic.levels[k]
			if last.width == 1 && last.height == 1 do break
			append(&pic.levels, svg_image_halve(last))
		}
		k += 1
	}
	return &pic.levels[k]
}

// svg_image_halve averages each 2 × 2 block, colour weighted by alpha.
@(private)
svg_image_halve :: proc(src: ^Image) -> Image {
	w, h := (src.width + 1) / 2, (src.height + 1) / 2
	px := make([]u8, w * h * 4)
	for y in 0 ..< h {
		for x in 0 ..< w {
			sum: [4]f32
			for dy in 0 ..< 2 {
				for dx in 0 ..< 2 {
					i := (min(y * 2 + dy, src.height - 1) * src.width + min(x * 2 + dx, src.width - 1)) * 4
					a := f32(src.pixels[i + 3])
					sum += {f32(src.pixels[i]) * a, f32(src.pixels[i + 1]) * a, f32(src.pixels[i + 2]) * a, a}
				}
			}
			i := (y * w + x) * 4
			if sum.a > 0 do px[i], px[i + 1], px[i + 2] = u8(sum.r / sum.a + 0.5), u8(sum.g / sum.a + 0.5), u8(sum.b / sum.a + 0.5)
			px[i + 3] = u8(sum.a / 4 + 0.5)
		}
	}
	return Image{width = w, height = h, pixels = px, version = 1, allocator = context.allocator}
}

// svg_data_image decodes a base64 PNG or JPEG data URI; other references
// (files, the network) are not followed.
@(private)
svg_data_image :: proc(href: string) -> (img: Image, ok: bool) {
	if !strings.has_prefix(href, "data:") do return
	comma := strings.index_byte(href, ',')
	if comma < 0 do return
	meta := href[5:comma]
	if !strings.has_suffix(meta, ";base64") do return
	b := strings.builder_make()
	for ch in transmute([]u8)href[comma + 1:] {
		if ch != ' ' && ch != '\n' && ch != '\r' && ch != '\t' do strings.write_byte(&b, ch)
	}
	bytes, err := base64.decode(strings.to_string(b))
	if err != nil do return
	src: ^image.Image
	switch {
	case strings.has_prefix(meta, "image/png"):
		if png_sound(bytes) do src, _ = png.load_from_bytes(bytes, {.alpha_add_if_missing})
	case strings.has_prefix(meta, "image/jpeg"), strings.has_prefix(meta, "image/jpg"):
		src, _ = jpeg.load_from_bytes(bytes, {.alpha_add_if_missing})
	}
	if src == nil do return
	return image_from_decoded(src, context.allocator)
}

// Filters

@(private)
Svg_Fbuf :: struct {
	px:     []f32, // w × h premultiplied RGBA, clear outside the filter region
	linear: bool, // linearRGB rather than sRGB
}

@(private)
Svg_Filter :: struct {
	d:              ^Svg_Doc,
	w, h:           int,
	x0, y0, x1, y1: int, // the filter region, device pixels
	xf:             Svg_Xf, // the element's user space to device pixels
	scale:          [2]f32, // primitive units to device pixels, per axis
	src, alpha:     Svg_Fbuf, // SourceGraphic, and SourceAlpha once asked for
	results:        map[string]Svg_Fbuf,
}

// svg_filter_apply runs the filter's primitives over what the element drew.
// Primitives it doesn't know pass their input through.
@(private)
svg_filter_apply :: proc(d: ^Svg_Doc, ref: string, el: xml.Element_ID, xf: Svg_Xf, c: ^Svg_Canvas) {
	fid, found := d.ids[ref]
	if !found || svg_name(d, fid) != "filter" || slice.contains(d.busy[:], fid) do return
	if d.mask_depth == 0 do d.other_paint = true // a filter may colour what it draws
	append(&d.busy, fid)
	defer pop(&d.busy)
	fe := &d.x.elements[fid]
	fs := svg_style_chain(d, fid)
	obb := svg_attr(fe, "filterUnits") != "userSpaceOnUse"
	prim_obb := svg_attr(fe, "primitiveUnits") == "objectBoundingBox"
	box: Svg_Box
	if obb || prim_obb {
		box = svg_bbox(d, el)
		if !svg_box_has_area(box) {
			svg_canvas_clear(c)
			return
		}
	}
	region := svg_region(d, fe, obb, box)
	dev: Svg_Box
	rx, ry, rw, rh := region[0], region[1], region[2], region[3]
	for corner in ([4][2]f32{{rx, ry}, {rx + rw, ry}, {rx, ry + rh}, {rx + rw, ry + rh}}) do svg_box_add(&dev, svg_xf_apply(xf, corner))
	f := Svg_Filter{
		d = d, w = c.w, h = c.h, xf = xf,
		x0 = clamp(int(math.floor(dev.lo.x)), 0, c.w), y0 = clamp(int(math.floor(dev.lo.y)), 0, c.h),
		x1 = clamp(int(math.ceil(dev.hi.x)), 0, c.w), y1 = clamp(int(math.ceil(dev.hi.y)), 0, c.h),
		scale = {linalg_len({xf[0], xf[1]}), linalg_len({xf[2], xf[3]})},
		results = make(map[string]Svg_Fbuf),
	}
	if prim_obb do f.scale *= box.hi - box.lo
	f.src = svg_fbuf(&f, false)
	svg_fbuf_copy(&f, f.src.px, c.px)
	last := f.src
	for v in fe.value {
		pid, is := v.(xml.Element_ID)
		if !is || d.x.elements[pid].kind != .Element do continue
		name := svg_name(d, pid)
		if !strings.has_prefix(name, "fe") do continue
		pe := &d.x.elements[pid]
		ps := svg_style(d, pid, &fs)
		in1 := svg_filter_input(&f, svg_attr(pe, "in"), last, ps.linear_filters)
		out := in1
		switch name {
		case "feGaussianBlur": out = svg_fe_blur(&f, pe, in1)
		case "feOffset":       out = svg_fe_offset(&f, pe, in1)
		case "feFlood":        out = svg_fe_flood(&f, &ps)
		case "feColorMatrix":  out = svg_fe_color_matrix(&f, pe, in1)
		case "feComposite":    out = svg_fe_composite(&f, pe, in1, svg_filter_input(&f, svg_attr(pe, "in2"), last, ps.linear_filters))
		case "feBlend":        out = svg_fe_blend(&f, pe, in1, svg_filter_input(&f, svg_attr(pe, "in2"), last, ps.linear_filters))
		case "feMerge":        out = svg_fe_merge(&f, pe, last, ps.linear_filters)
		case "feMorphology":   out = svg_fe_morphology(&f, pe, in1)
		case "feDiffuseLighting":  out = svg_fe_lighting(&f, pe, in1, &ps, false)
		case "feSpecularLighting": out = svg_fe_lighting(&f, pe, in1, &ps, true)
		}
		if result := svg_attr(pe, "result"); result != "" do f.results[result] = out
		last = out
	}
	final := svg_fbuf_space(&f, last, false)
	svg_canvas_clear(c)
	svg_fbuf_copy(&f, c.px, final.px)
}

@(private)
svg_fbuf :: proc(f: ^Svg_Filter, linear: bool) -> Svg_Fbuf {
	return {px = make([]f32, f.w * f.h * 4), linear = linear}
}

// svg_fbuf_copy copies the filter region of `src` into `dst`.
@(private)
svg_fbuf_copy :: proc(f: ^Svg_Filter, dst, src: []f32) {
	for y in f.y0 ..< f.y1 {
		a, b := (y * f.w + f.x0) * 4, (y * f.w + f.x1) * 4
		copy(dst[a:b], src[a:b])
	}
}

@(private)
svg_fbuf_space :: proc(f: ^Svg_Filter, b: Svg_Fbuf, linear: bool) -> Svg_Fbuf {
	if b.linear == linear do return b
	out := svg_fbuf(f, linear)
	for y in f.y0 ..< f.y1 {
		for x in f.x0 ..< f.x1 {
			i := (y * f.w + x) * 4
			a := b.px[i + 3]
			if a <= 0 do continue
			for k in 0 ..< 3 {
				c := clamp(b.px[i + k] / a, 0, 1)
				out.px[i + k] = (srgb_to_linear(c) if linear else linear_to_srgb(c)) * a
			}
			out.px[i + 3] = a
		}
	}
	return out
}

@(private)
svg_filter_input :: proc(f: ^Svg_Filter, name: string, last: Svg_Fbuf, linear: bool) -> Svg_Fbuf {
	b := last
	switch name {
	case "":
	case "SourceGraphic":
		b = f.src
	case "SourceAlpha":
		if f.alpha.px == nil {
			f.alpha = svg_fbuf(f, false)
			for i := 3; i < len(f.src.px); i += 4 do f.alpha.px[i] = f.src.px[i]
		}
		b = {f.alpha.px, linear} // black has no colour space
	case "BackgroundImage", "BackgroundAlpha", "FillPaint", "StrokePaint":
		b = svg_fbuf(f, linear)
	case:
		if r, has := f.results[name]; has do b = r
	}
	return svg_fbuf_space(f, b, linear)
}

@(private)
svg_numbers :: proc(v: string) -> []f32 {
	out := make([dynamic]f32, 0, 4)
	i := 0
	for {
		n := svg_scan_number(v, &i) or_break
		append(&out, n)
	}
	return out[:]
}

@(private)
svg_attr_number :: proc(e: ^xml.Element, name: string, fallback: f32) -> f32 {
	i := 0
	n, ok := svg_scan_number(svg_attr(e, name), &i)
	return n if ok else fallback
}

@(private)
svg_fe_blur :: proc(f: ^Svg_Filter, e: ^xml.Element, in1: Svg_Fbuf) -> Svg_Fbuf {
	sd := svg_numbers(svg_attr(e, "stdDeviation"))
	sx: f32 = sd[0] if len(sd) > 0 else 0
	sy: f32 = sd[1] if len(sd) > 1 else sx
	out := svg_fbuf(f, in1.linear)
	if sx < 0 || sy < 0 do return out // an error: transparent
	svg_fbuf_copy(f, out.px, in1.px)
	if sx > 0 do svg_blur_pass(f, out.px, sx * f.scale.x, true)
	if sy > 0 do svg_blur_pass(f, out.px, sy * f.scale.y, false)
	return out
}

// svg_blur_pass convolves the region with a Gaussian along one axis;
// beyond the region is transparent.
@(private)
svg_blur_pass :: proc(f: ^Svg_Filter, px: []f32, sigma: f32, horizontal: bool) {
	if sigma < 0.05 do return
	radius := clamp(int(math.ceil(sigma * 3)), 1, 512)
	kernel := make([]f32, 2 * radius + 1)
	sum: f32
	for i in -radius ..= radius {
		w := math.exp(-f32(i * i) / (2 * sigma * sigma))
		kernel[i + radius] = w
		sum += w
	}
	for &k in kernel do k /= sum
	lines := f.y1 - f.y0 if horizontal else f.x1 - f.x0
	span := f.x1 - f.x0 if horizontal else f.y1 - f.y0
	buf := make([]f32, span * 4)
	index :: proc "contextless" (f: ^Svg_Filter, horizontal: bool, line, s: int) -> int {
		if horizontal do return ((f.y0 + line) * f.w + f.x0 + s) * 4
		return ((f.y0 + s) * f.w + f.x0 + line) * 4
	}
	for line in 0 ..< lines {
		for s in 0 ..< span {
			acc: [4]f32
			for k in max(-radius, -s) ..= min(radius, span - 1 - s) {
				i := index(f, horizontal, line, s + k)
				acc += [4]f32{px[i], px[i + 1], px[i + 2], px[i + 3]} * kernel[k + radius]
			}
			buf[s * 4], buf[s * 4 + 1], buf[s * 4 + 2], buf[s * 4 + 3] = acc[0], acc[1], acc[2], acc[3]
		}
		for s in 0 ..< span {
			i := index(f, horizontal, line, s)
			copy(px[i:i + 4], buf[s * 4:s * 4 + 4])
		}
	}
}

@(private)
svg_fe_offset :: proc(f: ^Svg_Filter, e: ^xml.Element, in1: Svg_Fbuf) -> Svg_Fbuf {
	ox := int(math.round(svg_attr_number(e, "dx", 0) * f.scale.x))
	oy := int(math.round(svg_attr_number(e, "dy", 0) * f.scale.y))
	out := svg_fbuf(f, in1.linear)
	for y in f.y0 ..< f.y1 {
		for x in f.x0 ..< f.x1 {
			sx, sy := x - ox, y - oy
			if sx < f.x0 || sx >= f.x1 || sy < f.y0 || sy >= f.y1 do continue
			i, j := (y * f.w + x) * 4, (sy * f.w + sx) * 4
			copy(out.px[i:i + 4], in1.px[j:j + 4])
		}
	}
	return out
}

@(private)
svg_fe_flood :: proc(f: ^Svg_Filter, s: ^Svg_Style) -> Svg_Fbuf {
	col := s.color if s.flood_color.kind == .Current else s.flood_color.color
	a := col.a * s.flood_opacity
	rgb := col.rgb
	if s.linear_filters do rgb = {srgb_to_linear(rgb.r), srgb_to_linear(rgb.g), srgb_to_linear(rgb.b)}
	out := svg_fbuf(f, s.linear_filters)
	for y in f.y0 ..< f.y1 {
		for x in f.x0 ..< f.x1 {
			i := (y * f.w + x) * 4
			out.px[i], out.px[i + 1], out.px[i + 2], out.px[i + 3] = rgb.r * a, rgb.g * a, rgb.b * a, a
		}
	}
	return out
}

@(private)
svg_fe_color_matrix :: proc(f: ^Svg_Filter, e: ^xml.Element, in1: Svg_Fbuf) -> Svg_Fbuf {
	m := [20]f32{1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0}
	vals := svg_numbers(svg_attr(e, "values"))
	switch svg_attr(e, "type") {
	case "", "matrix":
		if len(vals) == 20 do copy(m[:], vals)
	case "saturate":
		s: f32 = vals[0] if len(vals) > 0 else 1
		m = {
			0.213 + 0.787 * s, 0.715 - 0.715 * s, 0.072 - 0.072 * s, 0, 0,
			0.213 - 0.213 * s, 0.715 + 0.285 * s, 0.072 - 0.072 * s, 0, 0,
			0.213 - 0.213 * s, 0.715 - 0.715 * s, 0.072 + 0.928 * s, 0, 0,
			0, 0, 0, 1, 0,
		}
	case "hueRotate":
		a := (vals[0] if len(vals) > 0 else 0) * math.PI / 180
		cs, sn := math.cos(a), math.sin(a)
		m = {
			0.213 + cs * 0.787 - sn * 0.213, 0.715 - cs * 0.715 - sn * 0.715, 0.072 - cs * 0.072 + sn * 0.928, 0, 0,
			0.213 - cs * 0.213 + sn * 0.143, 0.715 + cs * 0.285 + sn * 0.140, 0.072 - cs * 0.072 - sn * 0.283, 0, 0,
			0.213 - cs * 0.213 - sn * 0.787, 0.715 - cs * 0.715 + sn * 0.715, 0.072 + cs * 0.928 + sn * 0.072, 0, 0,
			0, 0, 0, 1, 0,
		}
	case "luminanceToAlpha":
		m = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.2125, 0.7154, 0.0721, 0, 0}
	}
	out := svg_fbuf(f, in1.linear)
	for y in f.y0 ..< f.y1 {
		for x in f.x0 ..< f.x1 {
			i := (y * f.w + x) * 4
			a := in1.px[i + 3]
			r, g, b: f32
			if a > 0 do r, g, b = in1.px[i] / a, in1.px[i + 1] / a, in1.px[i + 2] / a
			na := clamp(m[15] * r + m[16] * g + m[17] * b + m[18] * a + m[19], 0, 1)
			out.px[i] = clamp(m[0] * r + m[1] * g + m[2] * b + m[3] * a + m[4], 0, 1) * na
			out.px[i + 1] = clamp(m[5] * r + m[6] * g + m[7] * b + m[8] * a + m[9], 0, 1) * na
			out.px[i + 2] = clamp(m[10] * r + m[11] * g + m[12] * b + m[13] * a + m[14], 0, 1) * na
			out.px[i + 3] = na
		}
	}
	return out
}

@(private)
svg_fe_composite :: proc(f: ^Svg_Filter, e: ^xml.Element, top, bottom: Svg_Fbuf) -> Svg_Fbuf {
	op := svg_attr(e, "operator")
	k := [4]f32{svg_attr_number(e, "k1", 0), svg_attr_number(e, "k2", 0), svg_attr_number(e, "k3", 0), svg_attr_number(e, "k4", 0)}
	out := svg_fbuf(f, top.linear)
	for y in f.y0 ..< f.y1 {
		for x in f.x0 ..< f.x1 {
			i := (y * f.w + x) * 4
			a := [4]f32{top.px[i], top.px[i + 1], top.px[i + 2], top.px[i + 3]}
			b := [4]f32{bottom.px[i], bottom.px[i + 1], bottom.px[i + 2], bottom.px[i + 3]}
			r: [4]f32
			switch op {
			case "in":      r = a * b.a
			case "out":     r = a * (1 - b.a)
			case "atop":    r = a * b.a + b * (1 - a.a)
			case "xor":     r = a * (1 - b.a) + b * (1 - a.a)
			case "lighter": r = a + b
			case "arithmetic":
				r = k[0] * a * b + k[1] * a + k[2] * b + k[3]
			case:           r = a + b * (1 - a.a) // over
			}
			r.a = clamp(r.a, 0, 1)
			for c in 0 ..< 3 do r[c] = clamp(r[c], 0, r.a)
			out.px[i], out.px[i + 1], out.px[i + 2], out.px[i + 3] = r[0], r[1], r[2], r[3]
		}
	}
	return out
}

@(private)
svg_fe_blend :: proc(f: ^Svg_Filter, e: ^xml.Element, top, bottom: Svg_Fbuf) -> Svg_Fbuf {
	mode := svg_attr(e, "mode")
	out := svg_fbuf(f, top.linear)
	for y in f.y0 ..< f.y1 {
		for x in f.x0 ..< f.x1 {
			i := (y * f.w + x) * 4
			ca, qa := [3]f32{top.px[i], top.px[i + 1], top.px[i + 2]}, top.px[i + 3]
			cb, qb := [3]f32{bottom.px[i], bottom.px[i + 1], bottom.px[i + 2]}, bottom.px[i + 3]
			c: [3]f32
			switch mode {
			case "multiply": c = ca * (1 - qb) + cb * (1 - qa) + ca * cb
			case "screen":   c = ca + cb - ca * cb
			case "darken":   for n in 0 ..< 3 do c[n] = min(ca[n] * (1 - qb) + cb[n], cb[n] * (1 - qa) + ca[n])
			case "lighten":  for n in 0 ..< 3 do c[n] = max(ca[n] * (1 - qb) + cb[n], cb[n] * (1 - qa) + ca[n])
			case:            c = ca + cb * (1 - qa) // normal
			}
			out.px[i], out.px[i + 1], out.px[i + 2], out.px[i + 3] = c[0], c[1], c[2], qa + qb - qa * qb
		}
	}
	return out
}

@(private)
svg_fe_merge :: proc(f: ^Svg_Filter, e: ^xml.Element, last: Svg_Fbuf, linear: bool) -> Svg_Fbuf {
	out := svg_fbuf(f, linear)
	for v in e.value {
		nid, is := v.(xml.Element_ID)
		if !is || svg_name(f.d, nid) != "feMergeNode" do continue
		src := svg_filter_input(f, svg_attr(&f.d.x.elements[nid], "in"), last, linear)
		for y in f.y0 ..< f.y1 {
			for x in f.x0 ..< f.x1 {
				i := (y * f.w + x) * 4
				k := 1 - src.px[i + 3]
				for c in 0 ..< 4 do out.px[i + c] = src.px[i + c] + out.px[i + c] * k
			}
		}
	}
	return out
}

// svg_fe_lighting lights the input's alpha as a height map (Sobel normals)
// with its distant, point or spot light: diffuse gives opaque shading,
// specular a highlight whose alpha is its brightest channel.
@(private)
svg_fe_lighting :: proc(f: ^Svg_Filter, e: ^xml.Element, in1: Svg_Fbuf, s: ^Svg_Style, specular: bool) -> Svg_Fbuf {
	out := svg_fbuf(f, s.linear_filters)
	Light :: enum u8 { None, Distant, Point, Spot }
	light: Light
	dir, pos, at: [3]f32
	spot_exp, cone_cos: f32 = 1, -2
	for v in e.value {
		lid, is := v.(xml.Element_ID)
		if !is do continue
		le := &f.d.x.elements[lid]
		num :: proc(le: ^xml.Element, name: string) -> f32 { return svg_attr_number(le, name, 0) }
		switch svg_name(f.d, lid) {
		case "feDistantLight":
			az, el := num(le, "azimuth") * math.PI / 180, num(le, "elevation") * math.PI / 180
			dir = {math.cos(az) * math.cos(el), math.sin(az) * math.cos(el), math.sin(el)}
			light = .Distant
		case "fePointLight", "feSpotLight":
			z_scale := (f.scale.x + f.scale.y) / 2
			p := svg_xf_apply(f.xf, {num(le, "x"), num(le, "y")})
			pos = {p.x, p.y, num(le, "z") * z_scale}
			light = .Point
			if svg_name(f.d, lid) == "feSpotLight" {
				q := svg_xf_apply(f.xf, {num(le, "pointsAtX"), num(le, "pointsAtY")})
				at = {q.x, q.y, num(le, "pointsAtZ") * z_scale}
				spot_exp = svg_attr_number(le, "specularExponent", 1)
				if svg_attr(le, "limitingConeAngle") != "" do cone_cos = math.cos(abs(num(le, "limitingConeAngle")) * math.PI / 180)
				light = .Spot
			}
		case:
			continue
		}
		break
	}
	if light == .None do return out
	surface := svg_attr_number(e, "surfaceScale", 1)
	kd, ks := svg_attr_number(e, "diffuseConstant", 1), svg_attr_number(e, "specularConstant", 1)
	exponent := clamp(svg_attr_number(e, "specularExponent", 1), 1, 128)
	col := s.color if s.lighting_color.kind == .Current else s.lighting_color.color
	lc := col.rgb
	if s.linear_filters do lc = {srgb_to_linear(lc.r), srgb_to_linear(lc.g), srgb_to_linear(lc.b)}
	alpha :: proc(f: ^Svg_Filter, px: []f32, x, y: int) -> f32 {
		return px[(clamp(y, f.y0, f.y1 - 1) * f.w + clamp(x, f.x0, f.x1 - 1)) * 4 + 3]
	}
	norm :: proc(v: [3]f32) -> [3]f32 {
		l := math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
		return v / l if l > 0 else v
	}
	for y in f.y0 ..< f.y1 {
		for x in f.x0 ..< f.x1 {
			a := in1.px
			gx := (alpha(f, a, x + 1, y - 1) + 2 * alpha(f, a, x + 1, y) + alpha(f, a, x + 1, y + 1)) - (alpha(f, a, x - 1, y - 1) + 2 * alpha(f, a, x - 1, y) + alpha(f, a, x - 1, y + 1))
			gy := (alpha(f, a, x - 1, y + 1) + 2 * alpha(f, a, x, y + 1) + alpha(f, a, x + 1, y + 1)) - (alpha(f, a, x - 1, y - 1) + 2 * alpha(f, a, x, y - 1) + alpha(f, a, x + 1, y - 1))
			n := norm({-surface * gx / 4, -surface * gy / 4, 1})
			l := dir
			c := lc
			if light != .Distant {
				l = norm(pos - {f32(x), f32(y), surface * alpha(f, a, x, y)})
				if light == .Spot {
					aim := norm(at - pos)
					facing := -(l.x * aim.x + l.y * aim.y + l.z * aim.z)
					c = {} if facing <= 0 || facing < cone_cos else c * math.pow(facing, spot_exp)
				}
			}
			i := (y * f.w + x) * 4
			if specular {
				h := norm(l + {0, 0, 1})
				k := ks * math.pow(max(n.x * h.x + n.y * h.y + n.z * h.z, 0), exponent)
				rgb := [3]f32{clamp(c.r * k, 0, 1), clamp(c.g * k, 0, 1), clamp(c.b * k, 0, 1)}
				out.px[i], out.px[i + 1], out.px[i + 2], out.px[i + 3] = rgb.r, rgb.g, rgb.b, max(rgb.r, rgb.g, rgb.b)
			} else {
				k := kd * max(n.x * l.x + n.y * l.y + n.z * l.z, 0)
				out.px[i], out.px[i + 1], out.px[i + 2], out.px[i + 3] = clamp(c.r * k, 0, 1), clamp(c.g * k, 0, 1), clamp(c.b * k, 0, 1), 1
			}
		}
	}
	return out
}

@(private)
svg_fe_morphology :: proc(f: ^Svg_Filter, e: ^xml.Element, in1: Svg_Fbuf) -> Svg_Fbuf {
	radius := svg_numbers(svg_attr(e, "radius"))
	rx: f32 = radius[0] if len(radius) > 0 else 0
	ry: f32 = radius[1] if len(radius) > 1 else rx
	if rx <= 0 || ry <= 0 do return in1 // a zero radius turns the primitive off
	dilate := svg_attr(e, "operator") == "dilate"
	ix, iy := int(math.round(rx * f.scale.x)), int(math.round(ry * f.scale.y))
	tmp, out := svg_fbuf(f, in1.linear), svg_fbuf(f, in1.linear)
	for pass in 0 ..< 2 {
		src, dst := (in1.px if pass == 0 else tmp.px), (tmp.px if pass == 0 else out.px)
		r := ix if pass == 0 else iy
		for y in f.y0 ..< f.y1 {
			for x in f.x0 ..< f.x1 {
				i := (y * f.w + x) * 4
				for c in 0 ..< 4 {
					best := src[i + c]
					for k in -r ..= r {
						sx, sy := x + k, y
						if pass == 1 do sx, sy = x, y + k
						if sx < f.x0 || sx >= f.x1 || sy < f.y0 || sy >= f.y1 do continue
						v := src[(sy * f.w + sx) * 4 + c]
						best = max(best, v) if dilate else min(best, v)
					}
					dst[i + c] = best
				}
			}
		}
	}
	return out
}
