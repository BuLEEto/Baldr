package baldr

// A small SVG path engine for icons: parses `d` strings (M L H V C S Q T A Z
// and relative forms), flattens curves and arcs to polylines, and rasterises
// strokes (round caps and joins) and fills (non-zero) into an 8-bit coverage
// bitmap by evaluating a signed distance per pixel — against the segments
// near that pixel only, bucketed on a coarse grid, so a 128 px icon costs
// about as little as a 24 px one. Results are cached in the glyph atlas.

import "base:runtime"
import "core:math"
import "core:strconv"

Svg_Subpath :: struct {
	pts:    [dynamic][2]f32,
	closed: bool,
	filled: bool,
}

// svg_flatten parses `d` scaled by `scale`. '|' starts a new shape at the
// origin and '#' marks a filled shape (see icons_data.odin). The subpaths
// are in temp memory by default.
svg_flatten :: proc(d: string, scale: f32, allocator := context.temp_allocator) -> []Svg_Subpath {
	out := make([dynamic]Svg_Subpath, allocator)
	P :: struct {
		s:   string,
		i:   int,
	}
	p := P{s = d}
	skip :: proc(p: ^P) {
		for p.i < len(p.s) {
			c := p.s[p.i]
			if c == ' ' || c == ',' || c == '\t' || c == '\n' || c == '\r' { p.i += 1 } else { break }
		}
	}
	number :: proc(p: ^P) -> (f32, bool) {
		skip(p)
		start := p.i
		if p.i < len(p.s) && (p.s[p.i] == '-' || p.s[p.i] == '+') do p.i += 1
		digits := 0
		dot := false
		for p.i < len(p.s) {
			c := p.s[p.i]
			if c >= '0' && c <= '9' {
				p.i += 1
				digits += 1
			} else if c == '.' && !dot { // a second '.' starts the next number ("1.704.706")
				dot = true
				p.i += 1
			} else {
				break
			}
		}
		if p.i < len(p.s) && (p.s[p.i] == 'e' || p.s[p.i] == 'E') {
			p.i += 1
			if p.i < len(p.s) && (p.s[p.i] == '-' || p.s[p.i] == '+') do p.i += 1
			for p.i < len(p.s) && p.s[p.i] >= '0' && p.s[p.i] <= '9' do p.i += 1
		}
		if digits == 0 {
			p.i = start
			return 0, false
		}
		v, ok := strconv.parse_f32(p.s[start:p.i])
		return v, ok
	}
	flag :: proc(p: ^P) -> (bool, bool) {
		skip(p)
		if p.i >= len(p.s) do return false, false
		c := p.s[p.i]
		if c == '0' || c == '1' {
			p.i += 1
			return c == '1', true
		}
		return false, false
	}
	cur, start, last_ctrl: [2]f32
	last_cmd: u8
	filled := false
	sp: ^Svg_Subpath
	begin :: proc(out: ^[dynamic]Svg_Subpath, at: [2]f32, filled: bool, allocator: runtime.Allocator) -> ^Svg_Subpath {
		append(out, Svg_Subpath{pts = make([dynamic][2]f32, allocator), filled = filled})
		s := &out[len(out) - 1]
		append(&s.pts, at)
		return s
	}
	for {
		skip(&p)
		if p.i >= len(p.s) do break
		c := p.s[p.i]
		if c == '#' {
			filled = true
			p.i += 1
			continue
		}
		if c == '|' { // next shape: back at the origin, no command to repeat
			cur, start, last_ctrl = {}, {}, {}
			last_cmd = 0
			sp = nil
			p.i += 1
			continue
		}
		cmd := c
		if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') {
			p.i += 1
		} else {
			// implicit repeat of the previous command (M → L)
			cmd = last_cmd
			if cmd == 'M' do cmd = 'L'
			if cmd == 'm' do cmd = 'l'
			if cmd == 0 do break
		}
		rel := cmd >= 'a' && cmd <= 'z'
		up := cmd - 32 if rel else cmd
		switch up {
		case 'M':
			x, okx := number(&p)
			y, oky := number(&p)
			if !okx || !oky do return out[:]
			pt := [2]f32{x, y} * scale
			if rel do pt += cur
			cur, start = pt, pt
			sp = begin(&out, pt, filled, allocator)
			filled = false
		case 'L', 'H', 'V':
			pt := cur
			if up == 'L' {
				x, okx := number(&p)
				y, oky := number(&p)
				if !okx || !oky do return out[:]
				pt = [2]f32{x, y} * scale
				if rel do pt += cur
			} else if up == 'H' {
				x, ok := number(&p)
				if !ok do return out[:]
				pt.x = x * scale + (cur.x if rel else 0)
			} else {
				y, ok := number(&p)
				if !ok do return out[:]
				pt.y = y * scale + (cur.y if rel else 0)
			}
			if sp == nil do sp = begin(&out, cur, filled, allocator)
			append(&sp.pts, pt)
			cur = pt
		case 'C', 'S':
			c1: [2]f32
			if up == 'C' {
				x1, o1 := number(&p)
				y1, o2 := number(&p)
				if !o1 || !o2 do return out[:]
				c1 = [2]f32{x1, y1} * scale
				if rel do c1 += cur
			} else {
				c1 = cur * 2 - last_ctrl if last_cmd == 'C' || last_cmd == 'c' || last_cmd == 'S' || last_cmd == 's' else cur
			}
			x2, o3 := number(&p)
			y2, o4 := number(&p)
			x, o5 := number(&p)
			y, o6 := number(&p)
			if !o3 || !o4 || !o5 || !o6 do return out[:]
			c2 := [2]f32{x2, y2} * scale
			pt := [2]f32{x, y} * scale
			if rel {
				c2 += cur
				pt += cur
			}
			if sp == nil do sp = begin(&out, cur, filled, allocator)
			cubic(sp, cur, c1, c2, pt)
			last_ctrl = c2
			cur = pt
		case 'Q', 'T':
			c1: [2]f32
			if up == 'Q' {
				x1, o1 := number(&p)
				y1, o2 := number(&p)
				if !o1 || !o2 do return out[:]
				c1 = [2]f32{x1, y1} * scale
				if rel do c1 += cur
			} else {
				c1 = cur * 2 - last_ctrl if last_cmd == 'Q' || last_cmd == 'q' || last_cmd == 'T' || last_cmd == 't' else cur
			}
			x, o3 := number(&p)
			y, o4 := number(&p)
			if !o3 || !o4 do return out[:]
			pt := [2]f32{x, y} * scale
			if rel do pt += cur
			if sp == nil do sp = begin(&out, cur, filled, allocator)
			quad(sp, cur, c1, pt)
			last_ctrl = c1
			cur = pt
		case 'A':
			rx, o1 := number(&p)
			ry, o2 := number(&p)
			rot, o3 := number(&p)
			large, o4 := flag(&p)
			sweep, o5 := flag(&p)
			x, o6 := number(&p)
			y, o7 := number(&p)
			if !(o1 && o2 && o3 && o4 && o5 && o6 && o7) do return out[:]
			pt := [2]f32{x, y} * scale
			if rel do pt += cur
			if sp == nil do sp = begin(&out, cur, filled, allocator)
			arc(sp, cur, pt, rx * scale, ry * scale, rot, large, sweep)
			cur = pt
		case 'Z':
			if sp != nil {
				sp.closed = true
				if len(sp.pts) > 0 && sp.pts[0] != cur do append(&sp.pts, sp.pts[0])
			}
			cur = start
			sp = nil
		case:
			return out[:]
		}
		last_cmd = cmd
	}
	return out[:]
}

@(private)
cubic :: proc(sp: ^Svg_Subpath, p0, p1, p2, p3: [2]f32) {
	n := curve_steps(linalg_len(p1 - p0) + linalg_len(p2 - p1) + linalg_len(p3 - p2))
	for i in 1 ..= n {
		t := f32(i) / f32(n)
		u := 1 - t
		pt := p0 * (u * u * u) + p1 * (3 * u * u * t) + p2 * (3 * u * t * t) + p3 * (t * t * t)
		append(&sp.pts, pt)
	}
}

@(private)
quad :: proc(sp: ^Svg_Subpath, p0, p1, p2: [2]f32) {
	n := curve_steps(linalg_len(p1 - p0) + linalg_len(p2 - p1))
	for i in 1 ..= n {
		t := f32(i) / f32(n)
		u := 1 - t
		append(&sp.pts, p0 * (u * u) + p1 * (2 * u * t) + p2 * (t * t))
	}
}

// arc converts an SVG endpoint arc to its centre form and samples it.
@(private)
arc :: proc(sp: ^Svg_Subpath, from, to: [2]f32, rx_in, ry_in, rot_deg: f32, large, sweep: bool) {
	rx, ry := abs(rx_in), abs(ry_in)
	if rx == 0 || ry == 0 || from == to {
		append(&sp.pts, to)
		return
	}
	phi := rot_deg * math.PI / 180
	cp, sp_ := math.cos(phi), math.sin(phi)
	d := (from - to) / 2
	x1 := cp * d.x + sp_ * d.y
	y1 := -sp_ * d.x + cp * d.y
	lambda := (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
	if lambda > 1 {
		s := math.sqrt(lambda)
		rx *= s
		ry *= s
	}
	num := rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
	den := rx * rx * y1 * y1 + ry * ry * x1 * x1
	coef := math.sqrt(max(num / den, 0))
	if large == sweep do coef = -coef
	cx1 := coef * (rx * y1 / ry)
	cy1 := coef * -(ry * x1 / rx)
	centre := [2]f32{cp * cx1 - sp_ * cy1, sp_ * cx1 + cp * cy1} + (from + to) / 2
	ang :: proc(u, v: [2]f32) -> f32 {
		a := math.atan2(u.x * v.y - u.y * v.x, u.x * v.x + u.y * v.y)
		return a
	}
	v1 := [2]f32{(x1 - cx1) / rx, (y1 - cy1) / ry}
	v2 := [2]f32{(-x1 - cx1) / rx, (-y1 - cy1) / ry}
	theta := ang({1, 0}, v1)
	delta := ang(v1, v2)
	if !sweep && delta > 0 do delta -= 2 * math.PI
	if sweep && delta < 0 do delta += 2 * math.PI
	n := max(int(math.ceil(abs(delta) * max(rx, ry) / 1.5)), 4)
	for i in 1 ..= n {
		a := theta + delta * f32(i) / f32(n)
		e := [2]f32{rx * math.cos(a), ry * math.sin(a)}
		append(&sp.pts, [2]f32{cp * e.x - sp_ * e.y, sp_ * e.x + cp * e.y} + centre)
	}
	sp.pts[len(sp.pts) - 1] = to
}

@(private)
curve_steps :: proc "contextless" (length: f32) -> int {
	return clamp(int(length / 1.5) + 2, 3, 48)
}

@(private)
linalg_len :: proc "contextless" (v: [2]f32) -> f32 {
	return math.sqrt(v.x * v.x + v.y * v.y)
}

// svg_raster draws `paths` (already scaled to pixels) into a w×h coverage
// bitmap: strokes `stroke_w` wide with round caps and joins, plus non-zero
// fills for filled subpaths. Edges get a 1 px anti-aliasing ramp. The
// bitmap is in temp memory by default.
svg_raster :: proc(paths: []Svg_Subpath, w, h: int, stroke_w: f32, allocator := context.temp_allocator) -> []u8 {
	out := make([]u8, w * h, allocator)
	if w <= 0 || h <= 0 do return out
	half := stroke_w / 2
	reach := half + 1 // a segment farther than this from a pixel's centre cannot touch its coverage
	// Bucket the segments into a coarse grid so each pixel only measures
	// the few near it, not every segment.
	CELL :: 8
	cw, ch := (w + CELL - 1) / CELL, (h + CELL - 1) / CELL
	Seg :: struct { a, b: [2]f32, filled: bool }
	segs := make([dynamic]Seg, context.temp_allocator)
	for sp in paths do for i in 0 ..< len(sp.pts) - 1 do append(&segs, Seg{sp.pts[i], sp.pts[i + 1], sp.filled})
	cells := make([][dynamic]int, cw * ch, context.temp_allocator)
	for &c in cells do c = make([dynamic]int, context.temp_allocator) // a zero [dynamic] would grow on the default allocator
	for sg, si in segs {
		x0 := clamp(int((min(sg.a.x, sg.b.x) - reach) / CELL), 0, cw - 1)
		x1 := clamp(int((max(sg.a.x, sg.b.x) + reach) / CELL), 0, cw - 1)
		y0 := clamp(int((min(sg.a.y, sg.b.y) - reach) / CELL), 0, ch - 1)
		y1 := clamp(int((max(sg.a.y, sg.b.y) + reach) / CELL), 0, ch - 1)
		for cy in y0 ..= y1 do for cx in x0 ..= x1 do append(&cells[cy * cw + cx], si)
	}
	// Winding per row: every filled segment's crossing with the row's
	// centre line, then a right-to-left sweep gives each pixel the count
	// of crossings to its right (the non-zero rule).
	Cross :: struct { x: f32, dir: int }
	crossings := make([dynamic]Cross, context.temp_allocator)
	wind_row := make([]int, w, context.temp_allocator)
	for y in 0 ..< h {
		py := f32(y) + 0.5
		clear(&crossings)
		for sg in segs {
			if !sg.filled do continue
			a, b := sg.a, sg.b
			if (a.y <= py && b.y > py) || (b.y <= py && a.y > py) {
				t := (py - a.y) / (b.y - a.y)
				append(&crossings, Cross{a.x + t * (b.x - a.x), 1 if b.y > a.y else -1})
			}
		}
		// wind_row is a difference array: a crossing counts for every pixel
		// whose centre is left of it, so it adds at 0 and takes back after
		// the last such pixel; a running sum gives each pixel its winding.
		for x in 0 ..< w do wind_row[x] = 0
		for c in crossings {
			last := int(math.ceil(c.x - 0.5)) - 1 // largest x with x + 0.5 < c.x
			if last < 0 do continue
			wind_row[0] += c.dir
			if last + 1 < w do wind_row[last + 1] -= c.dir
		}
		wind := 0
		for x in 0 ..< w {
			wind += wind_row[x]
			p := [2]f32{f32(x) + 0.5, py}
			best := f32(1e9)
			fill_d := f32(1e9)
			for si in cells[(y / CELL) * cw + x / CELL] {
				sg := segs[si]
				d := seg_dist(p, sg.a, sg.b)
				if d < best do best = d
				if sg.filled && d < fill_d do fill_d = d
			}
			cov := clamp(half - best + 0.5, 0, 1)
			if wind != 0 do cov = max(cov, clamp(fill_d + 0.5, 0, 1))
			out[y * w + x] = u8(cov * 255 + 0.5)
		}
	}
	return out
}

// svg_raster_reference is the brute force the fast one must match: every
// pixel against every segment. Kept for the test.
@(private)
svg_raster_reference :: proc(paths: []Svg_Subpath, w, h: int, stroke_w: f32, allocator := context.temp_allocator) -> []u8 {
	out := make([]u8, w * h, allocator)
	half := stroke_w / 2
	for y in 0 ..< h {
		for x in 0 ..< w {
			p := [2]f32{f32(x) + 0.5, f32(y) + 0.5}
			best := f32(1e9)
			wind := 0
			fill_d := f32(1e9)
			for sp in paths {
				n := len(sp.pts)
				for i in 0 ..< n - 1 {
					a, b := sp.pts[i], sp.pts[i + 1]
					d := seg_dist(p, a, b)
					if d < best do best = d
					if sp.filled {
						if d < fill_d do fill_d = d
						// crossing test for the non-zero winding number
						if (a.y <= p.y && b.y > p.y) || (b.y <= p.y && a.y > p.y) {
							t := (p.y - a.y) / (b.y - a.y)
							if a.x + t * (b.x - a.x) > p.x do wind += 1 if b.y > a.y else -1
						}
					}
				}
			}
			cov := clamp(half - best + 0.5, 0, 1)
			if wind != 0 do cov = max(cov, clamp(fill_d + 0.5, 0, 1))
			out[y * w + x] = u8(cov * 255 + 0.5)
		}
	}
	return out
}

@(private)
seg_dist :: proc "contextless" (p, a, b: [2]f32) -> f32 {
	ab := b - a
	l2 := ab.x * ab.x + ab.y * ab.y
	t: f32 = 0
	if l2 > 0 do t = clamp(((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / l2, 0, 1)
	q := a + ab * t
	return linalg_len(p - q)
}
