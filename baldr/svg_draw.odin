package baldr

// SVG geometry: path data and basic shapes flattened to polylines in user
// space (curves within SVG_TOLERANCE device pixels), strokes built as
// outlines (joins, caps, dashes), and a scanline rasteriser giving each
// pixel its exact horizontal coverage over SVG_SUBROWS rows of samples,
// under the nonzero or evenodd rule. See svg_doc.odin.

import "core:math"
import "core:slice"
import "core:encoding/xml"

SVG_TOLERANCE :: 0.05 // how far a flattened curve may stray from the true one, in device pixels
SVG_SUBROWS :: 16 // coverage samples per pixel row

@(private)
Svg_Poly :: struct {
	pts:    [dynamic][2]f32,
	smooth: [dynamic]bool, // the point lies inside a flattened curve rather than at a corner
	closed: bool,
}

@(private)
Svg_Path :: struct {
	polys:      [dynamic]Svg_Poly,
	tol:        f32, // in user units
	start, pos: [2]f32,
	open:       bool, // the last poly still takes points
}

@(private)
svg_path_make :: proc(xf: Svg_Xf) -> Svg_Path {
	return {polys = make([dynamic]Svg_Poly), tol = SVG_TOLERANCE / max(svg_xf_scale(xf), 1e-6)}
}

@(private)
svg_path_poly :: proc(p: ^Svg_Path) -> ^Svg_Poly {
	if !p.open {
		append(&p.polys, Svg_Poly{pts = make([dynamic][2]f32), smooth = make([dynamic]bool)})
		poly := &p.polys[len(p.polys) - 1]
		append(&poly.pts, p.pos)
		append(&poly.smooth, false)
		p.start = p.pos
		p.open = true
	}
	return &p.polys[len(p.polys) - 1]
}

@(private)
svg_path_move :: proc(p: ^Svg_Path, to: [2]f32) {
	p.open = false
	p.pos = to
	_ = svg_path_poly(p)
}

@(private)
svg_path_line :: proc(p: ^Svg_Path, to: [2]f32) {
	poly := svg_path_poly(p)
	append(&poly.pts, to)
	append(&poly.smooth, false)
	p.pos = to
}

// svg_path_cubic flattens with Wang's bound: n segments keep the chords
// within `tol` of the curve.
@(private)
svg_path_cubic :: proc(p: ^Svg_Path, c1, c2, to: [2]f32) {
	poly := svg_path_poly(p)
	p0 := p.pos
	dd := max(linalg_len(p0 - 2 * c1 + c2), linalg_len(c1 - 2 * c2 + to))
	n := 1
	if dd > 0 && p.tol > 0 do n = clamp(int(math.ceil(math.sqrt(0.75 * dd / p.tol))), 1, 1000)
	for i in 1 ..= n {
		t := f32(i) / f32(n)
		u := 1 - t
		pt := p0 * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + to * (t * t * t)
		if i == n do pt = to
		append(&poly.pts, pt)
		append(&poly.smooth, i < n)
	}
	p.pos = to
}

@(private)
svg_path_quad :: proc(p: ^Svg_Path, c, to: [2]f32) {
	p0 := p.pos
	svg_path_cubic(p, p0 + (c - p0) * (2.0 / 3), to + (c - to) * (2.0 / 3), to)
}

// svg_path_arc converts an endpoint arc to its centre form, then to cubics
// of at most a quarter turn each.
@(private)
svg_path_arc :: proc(p: ^Svg_Path, rx_in, ry_in, rot_deg: f32, large, sweep: bool, to: [2]f32) {
	from := p.pos
	if from == to do return
	rx, ry := abs(rx_in), abs(ry_in)
	if rx == 0 || ry == 0 {
		svg_path_line(p, to)
		return
	}
	phi := rot_deg * math.PI / 180
	cp, sp := math.cos(phi), math.sin(phi)
	h := (from - to) / 2
	x1 := cp * h.x + sp * h.y
	y1 := -sp * h.x + cp * h.y
	lambda := x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
	if lambda > 1 {
		s := math.sqrt(lambda)
		rx *= s
		ry *= s
	}
	num := rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
	den := rx * rx * y1 * y1 + ry * ry * x1 * x1
	coef: f32 = 0
	if den > 0 do coef = math.sqrt(max(num / den, 0))
	if large == sweep do coef = -coef
	cx1 := coef * rx * y1 / ry
	cy1 := -coef * ry * x1 / rx
	centre := [2]f32{cp * cx1 - sp * cy1, sp * cx1 + cp * cy1} + (from + to) / 2
	angle :: proc(u, v: [2]f32) -> f32 {
		return math.atan2(u.x * v.y - u.y * v.x, u.x * v.x + u.y * v.y)
	}
	v1 := [2]f32{(x1 - cx1) / rx, (y1 - cy1) / ry}
	v2 := [2]f32{(-x1 - cx1) / rx, (-y1 - cy1) / ry}
	theta := angle({1, 0}, v1)
	delta := angle(v1, v2)
	if !sweep && delta > 0 do delta -= 2 * math.PI
	if sweep && delta < 0 do delta += 2 * math.PI
	segs := max(int(math.ceil(abs(delta) / (math.PI / 2) - 0.001)), 1)
	step := delta / f32(segs)
	k := f32(4.0 / 3.0) * math.tan(step / 4)
	on :: proc(centre: [2]f32, rx, ry, cp, sp, x, y: f32) -> [2]f32 {
		ex, ey := rx * x, ry * y
		return [2]f32{cp * ex - sp * ey, sp * ex + cp * ey} + centre
	}
	a := theta
	for i in 0 ..< segs {
		b := a + step
		ca, sa, cb, sb := math.cos(a), math.sin(a), math.cos(b), math.sin(b)
		c1 := on(centre, rx, ry, cp, sp, ca - k * sa, sa + k * ca)
		c2 := on(centre, rx, ry, cp, sp, cb + k * sb, sb - k * cb)
		end := to if i == segs - 1 else on(centre, rx, ry, cp, sp, cb, sb)
		svg_path_cubic(p, c1, c2, end)
		if i < segs - 1 {
			poly := &p.polys[len(p.polys) - 1]
			poly.smooth[len(poly.smooth) - 1] = true
		}
		a = b
	}
}

@(private)
svg_path_close :: proc(p: ^Svg_Path) {
	if !p.open do return
	p.polys[len(p.polys) - 1].closed = true
	p.open = false
	p.pos = p.start
}

// svg_path_data follows a `d` attribute, drawing what comes before the
// first error (as the spec asks); false when there was one.
@(private)
svg_path_data :: proc(p: ^Svg_Path, s: string) -> (clean: bool) {
	i := 0
	cmd: u8
	prev: u8 // the previous command, upper case
	ctrl: [2]f32 // its last control point, for S and T
	for {
		svg_skip_separators(s, &i)
		if i >= len(s) do return true
		ch := s[i]
		if (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') {
			cmd = ch
			i += 1
		} else if cmd == 0 {
			return
		}
		rel := cmd >= 'a'
		up := cmd - 32 if rel else cmd
		base := p.pos if rel else [2]f32{}
		switch up {
		case 'Z':
			svg_path_close(p)
			cmd = 0 // numbers after Z are an error
		case 'M':
			v, ok := svg_read_numbers(s, &i, 2)
			if !ok do return
			svg_path_move(p, base + {v[0], v[1]})
			cmd = 'l' if rel else 'L' // more pairs are lines
		case 'L':
			v, ok := svg_read_numbers(s, &i, 2)
			if !ok do return
			svg_path_line(p, base + {v[0], v[1]})
		case 'H':
			v, ok := svg_read_numbers(s, &i, 1)
			if !ok do return
			svg_path_line(p, {base.x + v[0], p.pos.y})
		case 'V':
			v, ok := svg_read_numbers(s, &i, 1)
			if !ok do return
			svg_path_line(p, {p.pos.x, base.y + v[0]})
		case 'C':
			v, ok := svg_read_numbers(s, &i, 6)
			if !ok do return
			c2 := base + {v[2], v[3]}
			svg_path_cubic(p, base + {v[0], v[1]}, c2, base + {v[4], v[5]})
			ctrl = c2
		case 'S':
			v, ok := svg_read_numbers(s, &i, 4)
			if !ok do return
			c1 := 2 * p.pos - ctrl if prev == 'C' || prev == 'S' else p.pos
			c2 := base + {v[0], v[1]}
			svg_path_cubic(p, c1, c2, base + {v[2], v[3]})
			ctrl = c2
		case 'Q':
			v, ok := svg_read_numbers(s, &i, 4)
			if !ok do return
			c := base + {v[0], v[1]}
			svg_path_quad(p, c, base + {v[2], v[3]})
			ctrl = c
		case 'T':
			v, ok := svg_read_numbers(s, &i, 2)
			if !ok do return
			c := 2 * p.pos - ctrl if prev == 'Q' || prev == 'T' else p.pos
			svg_path_quad(p, c, base + {v[0], v[1]})
			ctrl = c
		case 'A':
			r, ok := svg_read_numbers(s, &i, 3)
			if !ok do return
			large, ok_l := svg_scan_flag(s, &i)
			sweep, ok_s := svg_scan_flag(s, &i)
			if !ok_l || !ok_s do return
			v, ok_v := svg_read_numbers(s, &i, 2)
			if !ok_v do return
			svg_path_arc(p, r[0], r[1], r[2], large, sweep, base + {v[0], v[1]})
		case:
			return
		}
		prev = up
	}
}

@(private)
svg_read_numbers :: proc(s: string, i: ^int, n: int) -> (v: [6]f32, ok: bool) {
	for k in 0 ..< n {
		v[k] = svg_scan_number(s, i) or_return
	}
	return v, true
}

@(private)
svg_scan_flag :: proc(s: string, i: ^int) -> (flag: bool, ok: bool) {
	svg_skip_separators(s, i)
	if i^ >= len(s) || (s[i^] != '0' && s[i^] != '1') do return false, false
	flag = s[i^] == '1'
	i^ += 1
	return flag, true
}

// svg_shape_path is a basic shape's outline in its user space.
@(private)
svg_shape_path :: proc(d: ^Svg_Doc, e: ^xml.Element, kind: Svg_Kind, s: ^Svg_Style, xf: Svg_Xf) -> (p: Svg_Path, ok: bool) {
	p = svg_path_make(xf)
	fs := s.font_size
	#partial switch kind {
	case .Path:
		svg_path_data(&p, svg_attr(e, "d"))
	case .Rect:
		x, y := svg_attr_len(d, e, "x", .X, fs), svg_attr_len(d, e, "y", .Y, fs)
		w, h := svg_attr_len(d, e, "width", .X, fs), svg_attr_len(d, e, "height", .Y, fs)
		if w <= 0 || h <= 0 do return
		rx, ry := svg_attr_len(d, e, "rx", .X, fs, -1), svg_attr_len(d, e, "ry", .Y, fs, -1)
		if rx < 0 && ry < 0 {
			rx, ry = 0, 0
		} else if rx < 0 {
			rx = ry
		} else if ry < 0 {
			ry = rx
		}
		rx, ry = min(rx, w / 2), min(ry, h / 2)
		if rx <= 0 || ry <= 0 {
			svg_path_move(&p, {x, y})
			svg_path_line(&p, {x + w, y})
			svg_path_line(&p, {x + w, y + h})
			svg_path_line(&p, {x, y + h})
		} else {
			svg_path_move(&p, {x + rx, y})
			svg_path_line(&p, {x + w - rx, y})
			svg_path_arc(&p, rx, ry, 0, false, true, {x + w, y + ry})
			svg_path_line(&p, {x + w, y + h - ry})
			svg_path_arc(&p, rx, ry, 0, false, true, {x + w - rx, y + h})
			svg_path_line(&p, {x + rx, y + h})
			svg_path_arc(&p, rx, ry, 0, false, true, {x, y + h - ry})
			svg_path_line(&p, {x, y + ry})
			svg_path_arc(&p, rx, ry, 0, false, true, {x + rx, y})
		}
		svg_path_close(&p)
	case .Circle, .Ellipse:
		cx, cy := svg_attr_len(d, e, "cx", .X, fs), svg_attr_len(d, e, "cy", .Y, fs)
		rx, ry: f32
		if kind == .Circle {
			rx = svg_attr_len(d, e, "r", .Diag, fs)
			ry = rx
		} else {
			rx, ry = svg_attr_len(d, e, "rx", .X, fs, -1), svg_attr_len(d, e, "ry", .Y, fs, -1)
			if rx < 0 do rx = ry
			if ry < 0 do ry = rx
		}
		if rx <= 0 || ry <= 0 do return
		svg_path_move(&p, {cx + rx, cy})
		svg_path_arc(&p, rx, ry, 0, false, true, {cx, cy + ry})
		svg_path_arc(&p, rx, ry, 0, false, true, {cx - rx, cy})
		svg_path_arc(&p, rx, ry, 0, false, true, {cx, cy - ry})
		svg_path_arc(&p, rx, ry, 0, false, true, {cx + rx, cy})
		svg_path_close(&p)
	case .Line:
		svg_path_move(&p, {svg_attr_len(d, e, "x1", .X, fs), svg_attr_len(d, e, "y1", .Y, fs)})
		svg_path_line(&p, {svg_attr_len(d, e, "x2", .X, fs), svg_attr_len(d, e, "y2", .Y, fs)})
	case .Polyline, .Polygon:
		pts := svg_attr(e, "points")
		i, n := 0, 0
		for {
			x := svg_scan_number(pts, &i) or_break
			y := svg_scan_number(pts, &i) or_break
			if n == 0 {
				svg_path_move(&p, {x, y})
			} else {
				svg_path_line(&p, {x, y})
			}
			n += 1
		}
		if n < 2 do return
		if kind == .Polygon do svg_path_close(&p)
	}
	return p, len(p.polys) > 0
}

@(private)
svg_path_box :: proc(p: ^Svg_Path, xf: Svg_Xf, box: ^Svg_Box) {
	for &poly in p.polys do for pt in poly.pts do svg_box_add(box, svg_xf_apply(xf, pt))
}

// Strokes

@(private)
Svg_Stroker :: struct {
	r:         ^Svg_Raster,
	xf:        Svg_Xf,
	hw, limit: f32, // half the width, the miter limit
	step:      f32, // the angle between points on a round join or cap
	join:      Svg_Join,
	cap:       Svg_Cap,
}

// svg_stroke adds a stroke's outline to `r` as pieces (a quad per segment,
// the joins and caps) all wound the same way, so the nonzero rule fills
// their union.
@(private)
svg_stroke :: proc(r: ^Svg_Raster, p: ^Svg_Path, s: ^Svg_Style, width: f32, xf: Svg_Xf, dashes: []f32, dash_offset: f32) {
	st := Svg_Stroker{r = r, xf = xf, hw = width / 2, limit = s.miter_limit, join = s.join, cap = s.cap}
	dev_r := st.hw * svg_xf_scale(xf)
	st.step = math.PI / 2
	if dev_r > SVG_TOLERANCE do st.step = min(2 * math.acos(1 - SVG_TOLERANCE / dev_r), math.PI / 2)
	polys := p.polys[:]
	if len(dashes) > 0 do polys = svg_dash(polys, dashes, dash_offset)
	for &poly in polys do svg_stroke_poly(&st, &poly)
}

@(private)
svg_stroke_poly :: proc(st: ^Svg_Stroker, poly: ^Svg_Poly) {
	pts := make([dynamic][2]f32, 0, len(poly.pts))
	smooth := make([dynamic]bool, 0, len(poly.pts))
	for pt, i in poly.pts {
		if len(pts) > 0 && svg_near(pts[len(pts) - 1], pt) {
			if !poly.smooth[i] do smooth[len(smooth) - 1] = false
			continue
		}
		append(&pts, pt)
		append(&smooth, poly.smooth[i])
	}
	closed := poly.closed
	if closed && len(pts) > 1 && svg_near(pts[0], pts[len(pts) - 1]) {
		pop(&pts)
		pop(&smooth)
	}
	n := len(pts)
	if n == 0 do return
	if n == 1 { // a zero-length subpath: a dot, when its caps have area
		if len(poly.pts) < 2 && !closed do return // a lone moveto draws nothing
		c := pts[0]
		hw := st.hw
		switch st.cap {
		case .Round:  svg_stroke_wedge(st, c, 0, 2 * math.PI)
		case .Square: svg_stroke_piece(st, {c + {-hw, -hw}, c + {hw, -hw}, c + {hw, hw}, c + {-hw, hw}})
		case .Butt:
		}
		return
	}
	segs := n if closed else n - 1
	dirs := make([][2]f32, segs)
	for i in 0 ..< segs {
		a, b := pts[i], pts[(i + 1) % n]
		dir := (b - a) / linalg_len(b - a)
		dirs[i] = dir
		nrm := [2]f32{-dir.y, dir.x} * st.hw
		svg_stroke_piece(st, {a + nrm, b + nrm, b - nrm, a - nrm})
	}
	if closed {
		for i in 0 ..< n do svg_stroke_join(st, pts[i], dirs[(i + n - 1) % n], dirs[i], smooth[i])
		return
	}
	for i in 1 ..< n - 1 do svg_stroke_join(st, pts[i], dirs[i - 1], dirs[i], smooth[i])
	svg_stroke_cap(st, pts[0], dirs[0], true)
	svg_stroke_cap(st, pts[n - 1], dirs[segs - 1], false)
}

@(private)
svg_stroke_join :: proc(st: ^Svg_Stroker, p, d0, d1: [2]f32, smooth: bool) {
	cross := d0.x * d1.y - d0.y * d1.x
	dot := d0.x * d1.x + d0.y * d1.y
	if abs(cross) < 1e-6 && dot > 0 do return // straight on
	n0 := [2]f32{-d0.y, d0.x} * st.hw
	n1 := [2]f32{-d1.y, d1.x} * st.hw
	side: f32 = -1 if cross > 0 else 1 // the outside of the turn
	o0, o1 := p + n0 * side, p + n1 * side
	join := Svg_Join.Round if smooth else st.join
	switch join {
	case .Bevel:
		svg_stroke_piece(st, {p, o0, o1})
	case .Round:
		if abs(cross) < 1e-6 { // a U-turn: the half disc beyond the point
			svg_stroke_wedge(st, p, 0, 2 * math.PI)
			return
		}
		a0 := math.atan2(o0.y - p.y, o0.x - p.x)
		a1 := math.atan2(o1.y - p.y, o1.x - p.x)
		sweep := a1 - a0
		for sweep > math.PI do sweep -= 2 * math.PI
		for sweep < -math.PI do sweep += 2 * math.PI
		svg_stroke_wedge(st, p, a0, sweep)
	case .Miter:
		cos_half := math.sqrt(max((1 + dot) / 2, 0))
		if cos_half < 1e-6 || 1 / cos_half > st.limit {
			svg_stroke_piece(st, {p, o0, o1})
			return
		}
		mid := (n0 + n1) * side
		mid = mid / linalg_len(mid) * (st.hw / cos_half)
		svg_stroke_piece(st, {p, o0, p + mid, o1})
	}
}

@(private)
svg_stroke_cap :: proc(st: ^Svg_Stroker, p, dir: [2]f32, start: bool) {
	nrm := [2]f32{-dir.y, dir.x} * st.hw
	out := -dir if start else dir
	switch st.cap {
	case .Butt:
	case .Square:
		ext := out * st.hw
		svg_stroke_piece(st, {p + nrm, p + nrm + ext, p - nrm + ext, p - nrm})
	case .Round:
		a := math.atan2(nrm.y, nrm.x)
		svg_stroke_wedge(st, p, a, math.PI if start else -math.PI)
	}
}

// svg_stroke_wedge adds the sector of the stroke's circle about `c` from
// angle `a0` through `sweep` (a whole disc at 2π).
@(private)
svg_stroke_wedge :: proc(st: ^Svg_Stroker, c: [2]f32, a0, sweep: f32) {
	n := max(int(math.ceil(abs(sweep) / st.step)), 1)
	full := abs(sweep) >= 2 * math.PI - 1e-4
	pts := make([dynamic][2]f32, 0, n + 2)
	if !full do append(&pts, c)
	for i in 0 ..= n {
		if full && i == n do break
		a := a0 + sweep * f32(i) / f32(n)
		append(&pts, c + [2]f32{math.cos(a), math.sin(a)} * st.hw)
	}
	svg_stroke_piece(st, pts[:])
}

@(private)
svg_stroke_piece :: proc(st: ^Svg_Stroker, pts: [][2]f32) {
	svg_raster_piece(st.r, st.xf, pts)
}

@(private)
svg_near :: proc "contextless" (a, b: [2]f32) -> bool {
	dx, dy := a.x - b.x, a.y - b.y
	return dx * dx + dy * dy < 1e-12
}

// svg_dash cuts polylines into the dashes of `pattern` (even length, a
// positive sum), starting `offset` along it.
@(private)
svg_dash :: proc(polys: []Svg_Poly, pattern: []f32, offset: f32) -> []Svg_Poly {
	total: f32
	for v in pattern do total += v
	length: f32
	for &poly in polys {
		n := len(poly.pts)
		for i in 0 ..< n - 1 do length += linalg_len(poly.pts[i + 1] - poly.pts[i])
		if poly.closed && n > 1 do length += linalg_len(poly.pts[0] - poly.pts[n - 1])
	}
	if total <= 0 || length / total > 10000 do return polys // too fine to see: solid
	out := make([dynamic]Svg_Poly)
	begin :: proc(out: ^[dynamic]Svg_Poly, at: [2]f32) {
		append(out, Svg_Poly{pts = make([dynamic][2]f32), smooth = make([dynamic]bool)})
		append(&out[len(out) - 1].pts, at)
		append(&out[len(out) - 1].smooth, false)
	}
	for &poly in polys {
		n := len(poly.pts)
		if n < 2 do continue
		off := offset - total * math.floor(offset / total)
		idx := 0
		for off >= pattern[idx] {
			off -= pattern[idx]
			idx = (idx + 1) % len(pattern)
		}
		rem := pattern[idx] - off
		on := idx % 2 == 0
		if on do begin(&out, poly.pts[0])
		segs := n if poly.closed else n - 1
		for i in 0 ..< segs {
			a, b := poly.pts[i], poly.pts[(i + 1) % n]
			l := linalg_len(b - a)
			pos: f32
			for l - pos > rem {
				pos += rem
				q := a + (b - a) * (pos / l)
				if on {
					append(&out[len(out) - 1].pts, q)
					append(&out[len(out) - 1].smooth, false)
				} else {
					begin(&out, q)
				}
				idx = (idx + 1) % len(pattern)
				rem = pattern[idx]
				on = !on
			}
			rem -= l - pos
			if on {
				append(&out[len(out) - 1].pts, b)
				append(&out[len(out) - 1].smooth, poly.smooth[(i + 1) % n])
			}
		}
	}
	return out[:]
}

// The rasteriser

@(private)
Svg_Edge :: struct {
	x0, y0, x1, y1: f32, // y0 < y1
	dir:            i32, // +1 drawn downwards, -1 upwards
}

@(private)
Svg_Cross :: struct {
	x:   f32,
	dir: i32,
}

@(private)
Svg_Raster :: struct {
	w, h:           int,
	edges:          [dynamic]Svg_Edge,
	cov:            []f32, // w × h, valid inside x0..<x1, y0..<y1 (nil when the rows go into a mask)
	area, diff:     []f32, // per row: partial coverage, and a difference array for whole pixels
	crosses:        [dynamic]Svg_Cross,
	active:         [dynamic]int,
	x0, y0, x1, y1: int,
	mask:           ^Mask,   // path.odin: each row is combined into this, by `op`, instead of kept
	op:             Mask_Op,
	aliased:        bool,    // one sample at each pixel's centre: covered or not
}

@(private)
svg_raster_make :: proc(w, h: int) -> ^Svg_Raster {
	r := new(Svg_Raster)
	r^ = {
		w = w, h = h,
		edges = make([dynamic]Svg_Edge), crosses = make([dynamic]Svg_Cross), active = make([dynamic]int),
		cov = make([]f32, w * h), area = make([]f32, w + 2), diff = make([]f32, w + 2),
	}
	return r
}

@(private)
svg_raster_edge :: proc(r: ^Svg_Raster, a, b: [2]f32) {
	if a.y == b.y do return
	if !svg_finite(a) || !svg_finite(b) do return
	if a.y < b.y {
		append(&r.edges, Svg_Edge{a.x, a.y, b.x, b.y, 1})
	} else {
		append(&r.edges, Svg_Edge{b.x, b.y, a.x, a.y, -1})
	}
}

@(private)
svg_finite :: proc "contextless" (p: [2]f32) -> bool {
	return abs(p.x) < 1e7 && abs(p.y) < 1e7 // false for NaN too
}

// svg_raster_path adds every poly of `p`, each closed, through `xf`.
@(private)
svg_raster_path :: proc(r: ^Svg_Raster, p: ^Svg_Path, xf: Svg_Xf) {
	for &poly in p.polys {
		n := len(poly.pts)
		if n < 2 do continue
		prev := svg_xf_apply(xf, poly.pts[n - 1])
		for pt in poly.pts {
			q := svg_xf_apply(xf, pt)
			svg_raster_edge(r, prev, q)
			prev = q
		}
	}
}

// svg_raster_piece adds a convex polygon wound one fixed way in device
// space, whatever its winding was, so pieces of one stroke never cancel.
@(private)
svg_raster_piece :: proc(r: ^Svg_Raster, xf: Svg_Xf, pts: [][2]f32) {
	n := len(pts)
	if n < 3 do return
	buf: [64][2]f32
	dev := buf[:n] if n <= len(buf) else make([][2]f32, n)
	area: f32
	for pt, i in pts do dev[i] = svg_xf_apply(xf, pt)
	for i in 0 ..< n {
		a, b := dev[i], dev[(i + 1) % n]
		area += a.x * b.y - b.x * a.y
	}
	for i in 0 ..< n {
		a, b := dev[i], dev[(i + 1) % n]
		if area >= 0 {
			svg_raster_edge(r, a, b)
		} else {
			svg_raster_edge(r, b, a)
		}
	}
}

// svg_raster_fill turns the edges into coverage and clears them. Each
// pixel row is sampled on SVG_SUBROWS lines; on each line the spans the
// fill rule puts inside add their exact overlap with every pixel. An
// aliased raster samples one line through the pixels' centres and takes the
// pixels whose centres the spans hold. With a mask, each row is combined
// into it as it is made (mask_row), so no w × h buffer is needed.
@(private)
svg_raster_fill :: proc(r: ^Svg_Raster, evenodd: bool) {
	defer clear(&r.edges)
	r.x0, r.y0, r.x1, r.y1 = 0, 0, 0, 0
	defer if r.mask != nil do mask_outside(r)
	if len(r.edges) == 0 do return
	lo := [2]f32{max(f32), max(f32)}
	hi := [2]f32{min(f32), min(f32)}
	for e in r.edges {
		lo = {min(lo.x, e.x0, e.x1), min(lo.y, e.y0)}
		hi = {max(hi.x, e.x0, e.x1), max(hi.y, e.y1)}
	}
	y0 := clamp(int(math.floor(lo.y)), 0, r.h)
	y1 := clamp(int(math.ceil(hi.y)), 0, r.h)
	x0 := clamp(int(math.floor(lo.x)), 0, r.w)
	x1 := clamp(int(math.ceil(hi.x)), 0, r.w)
	if y0 >= y1 || x0 >= x1 do return
	r.x0, r.y0, r.x1, r.y1 = x0, y0, x1, y1
	slice.sort_by(r.edges[:], proc(a, b: Svg_Edge) -> bool { return a.y0 < b.y0 })
	clear(&r.active)
	next := 0
	subrows := 1 if r.aliased else SVG_SUBROWS
	weight := f32(1) / f32(subrows)
	w := f32(r.w)
	for py in y0 ..< y1 {
		for x in x0 ..= x1 {
			r.area[x] = 0
			r.diff[x] = 0
		}
		for sub in 0 ..< subrows {
			sy := f32(py) + (f32(sub) + 0.5) / f32(subrows)
			for next < len(r.edges) && r.edges[next].y0 <= sy {
				append(&r.active, next)
				next += 1
			}
			clear(&r.crosses)
			for i := 0; i < len(r.active); {
				e := &r.edges[r.active[i]]
				if e.y1 <= sy {
					unordered_remove(&r.active, i)
					continue
				}
				t := (sy - e.y0) / (e.y1 - e.y0)
				append(&r.crosses, Svg_Cross{e.x0 + t * (e.x1 - e.x0), e.dir})
				i += 1
			}
			cs := r.crosses[:]
			if len(cs) < 2 do continue
			if len(cs) <= 24 {
				for i in 1 ..< len(cs) {
					c := cs[i]
					j := i
					for j > 0 && cs[j - 1].x > c.x {
						cs[j] = cs[j - 1]
						j -= 1
					}
					cs[j] = c
				}
			} else {
				slice.sort_by(cs, proc(a, b: Svg_Cross) -> bool { return a.x < b.x })
			}
			wind: i32
			for i in 0 ..< len(cs) - 1 {
				wind += cs[i].dir
				inside := (wind & 1) != 0 if evenodd else wind != 0
				if !inside do continue
				xa, xb := clamp(cs[i].x, 0, w), clamp(cs[i + 1].x, 0, w)
				if xb <= xa do continue
				if r.aliased { // the pixels whose centres are in [xa, xb)
					ca, cb := clamp(int(math.ceil(xa - 0.5)), 0, r.w), clamp(int(math.ceil(xb - 0.5)), 0, r.w)
					if cb > ca {
						r.diff[ca] += 1
						r.diff[cb] -= 1
					}
					continue
				}
				ia, ib := int(xa), int(xb)
				if ia == ib {
					r.area[ia] += (xb - xa) * weight
					continue
				}
				r.area[ia] += (f32(ia + 1) - xa) * weight
				r.diff[ia + 1] += weight
				r.diff[ib] -= weight
				r.area[ib] += (xb - f32(ib)) * weight
			}
		}
		if r.mask != nil {
			mask_row(r, py)
			continue
		}
		run: f32
		row := r.cov[py * r.w:]
		for x in x0 ..< x1 {
			run += r.diff[x]
			row[x] = clamp(run + r.area[x], 0, 1)
		}
	}
}
