package baldr

// Paths into pixels: the SVG renderer's filling and stroking,
// for an app to call — an image editor's lasso into a selection mask, a
// shape layer, a stroke around a selection.
//
// A Path holds moves, lines and curves in pixels, flattened as they are
// added (curves within SVG_TOLERANCE of a pixel). path_fill and path_stroke
// turn it into coverage in a Mask, the same scanline rasteriser svg_render
// uses (svg_draw.odin): each pixel's exact covered area, or with
// `antialias = false` whether its centre is inside. A mask sits anywhere in
// the path's space (its `origin`), so a document of any size is drawn a
// piece at a time, and only the rows and columns the path reaches are
// visited. image_paint lays a colour through a mask into a picture.
//
// Nothing here uses the tree or a window: every proc is safe on any thread,
// with its working memory its own.

import "base:runtime"
import "core:mem/virtual"

// Mask is a coverage buffer: how much of each pixel a shape covers, 0
// (outside) to 255 (covered), over the rectangle `size` whose top-left
// pixel is at `origin` in the space paths are drawn in. `alpha` is
// size.x × size.y bytes, a row after another, the mask's own (mask_destroy).
Mask :: struct {
	origin:    [2]int,
	size:      [2]int,
	alpha:     []u8,
	allocator: runtime.Allocator,
}

// Mask_Op says how a shape's coverage `c` goes into what a mask holds `m`:
// Add keeps the greater (a union: adding a shape twice changes nothing),
// Subtract takes it away (min(m, 255 − c)), Intersect keeps the lesser and
// clears everything outside the shape, Replace makes the mask the shape
// alone. They are an image editor's selection modes. Two shapes meeting
// edge to edge join without a seam when they are one path, filled once.
Mask_Op :: enum u8 { Add, Subtract, Intersect, Replace }

// Fill_Rule says which parts of a path that crosses itself are inside:
// Nonzero, any part the outline winds around; Evenodd, a part inside an
// odd number of its loops (a ring from two circles either way round).
Fill_Rule :: enum u8 { Nonzero, Evenodd }

// Line_Join is how a stroke turns a corner; Line_Cap how an open end ends.
Line_Join :: enum u8 { Miter, Round, Bevel }
Line_Cap :: enum u8 { Butt, Round, Square }

// mask_make is a clear mask of `size` pixels whose top-left pixel is at
// `origin`. False, with nothing allocated, when a side is not positive or
// the memory cannot be had. The mask is the caller's: mask_destroy.
mask_make :: proc(origin, size: [2]int, allocator := context.allocator) -> (m: Mask, ok: bool) {
	if size.x <= 0 || size.y <= 0 || size.x > max(int) / size.y do return
	alpha, err := make([]u8, size.x * size.y, allocator)
	if err != nil do return
	return Mask{origin = origin, size = size, alpha = alpha, allocator = allocator}, true
}

// mask_destroy frees a mask's pixels. Safe on the zero value and twice.
mask_destroy :: proc(m: ^Mask) {
	if m.alpha != nil do delete(m.alpha, m.allocator)
	m.alpha = nil
	m.size = {}
}

// mask_at is the coverage at `p` in the paths' space: 0 outside the mask.
mask_at :: proc(m: ^Mask, p: [2]int) -> u8 {
	x, y := p.x - m.origin.x, p.y - m.origin.y
	if x < 0 || y < 0 || x >= m.size.x || y >= m.size.y || len(m.alpha) < m.size.x * m.size.y do return 0
	return m.alpha[y * m.size.x + x]
}

// Path is a shape to fill or stroke: subpaths of lines and curves, in
// pixels, built with path_move, path_line, path_quad, path_cubic, path_arc
// and path_close (or path_rect, path_ellipse, path_svg). Its memory is the
// allocator's it was made with (path_make); path_destroy frees it. Its
// fields are Baldr's.
Path :: struct {
	svg:       Svg_Path,
	allocator: runtime.Allocator,
}

// path_make is an empty path whose memory comes from `allocator`.
path_make :: proc(allocator := context.allocator) -> Path {
	context.allocator = allocator
	return Path{svg = svg_path_make(SVG_XF_ID), allocator = allocator}
}

// path_destroy frees a path. Safe on the zero value and twice.
path_destroy :: proc(p: ^Path) {
	path_clear(p)
	delete(p.svg.polys)
	p.svg.polys = nil
}

// path_clear empties a path to be built again, keeping its allocator.
path_clear :: proc(p: ^Path) {
	for &poly in p.svg.polys {
		delete(poly.pts)
		delete(poly.smooth)
	}
	clear(&p.svg.polys)
	p.svg.open = false
	p.svg.pos, p.svg.start = {}, {}
}

// path_move starts a subpath at `to`.
path_move :: proc(p: ^Path, to: [2]f32) {
	path_ready(p)
	context.allocator = p.allocator
	svg_path_move(&p.svg, to)
}

// path_line draws a straight line to `to`.
path_line :: proc(p: ^Path, to: [2]f32) {
	path_ready(p)
	context.allocator = p.allocator
	svg_path_line(&p.svg, to)
}

// path_quad draws a quadratic curve to `to`, pulled towards `ctrl`.
path_quad :: proc(p: ^Path, ctrl, to: [2]f32) {
	path_ready(p)
	context.allocator = p.allocator
	svg_path_quad(&p.svg, ctrl, to)
}

// path_cubic draws a cubic curve to `to`, leaving towards `c1` and
// arriving from `c2`.
path_cubic :: proc(p: ^Path, c1, c2, to: [2]f32) {
	path_ready(p)
	context.allocator = p.allocator
	svg_path_cubic(&p.svg, c1, c2, to)
}

// path_arc draws part of an ellipse to `to`, as SVG's `A` does: `radius`
// its radii, `rotation` its x axis's turn in degrees, and of the four arcs
// that fit, the `large` one or not, going clockwise (`sweep`) or not. Radii
// too small to reach are grown until they do; a zero radius draws a line.
path_arc :: proc(p: ^Path, radius: [2]f32, rotation: f32, large, sweep: bool, to: [2]f32) {
	path_ready(p)
	context.allocator = p.allocator
	svg_path_arc(&p.svg, radius.x, radius.y, rotation, large, sweep, to)
}

// path_close joins the subpath back to where it started, so a stroke turns
// that corner rather than capping two ends. A fill closes every subpath
// anyway.
path_close :: proc(p: ^Path) {
	svg_path_close(&p.svg)
}

// path_rect adds a closed rectangle.
path_rect :: proc(p: ^Path, r: Rect) {
	path_move(p, {r.x, r.y})
	path_line(p, {r.x + r.w, r.y})
	path_line(p, {r.x + r.w, r.y + r.h})
	path_line(p, {r.x, r.y + r.h})
	path_close(p)
}

// path_ellipse adds a closed ellipse about `centre` with `radius`.
path_ellipse :: proc(p: ^Path, centre, radius: [2]f32) {
	if radius.x <= 0 || radius.y <= 0 do return
	path_move(p, centre + {radius.x, 0})
	path_arc(p, radius, 0, false, true, centre - {radius.x, 0})
	path_arc(p, radius, 0, false, true, centre + {radius.x, 0})
	path_close(p)
}

// path_svg adds SVG path data ("M 10 10 h 20 v 20 z"), in pixels. As SVG
// asks, what comes before the first error is kept; false says there was
// one.
path_svg :: proc(p: ^Path, d: string) -> bool {
	path_ready(p)
	context.allocator = p.allocator
	return svg_path_data(&p.svg, d)
}

// path_bounds is the box around every point of the path (its curves as
// drawn), false when it has none. A stroke reaches half its width (more at
// a miter) beyond it.
path_bounds :: proc(p: ^Path) -> (r: Rect, ok: bool) {
	box: Svg_Box
	svg_path_box(&p.svg, SVG_XF_ID, &box)
	if !box.ok do return
	return Rect{box.lo.x, box.lo.y, box.hi.x - box.lo.x, box.hi.y - box.lo.y}, true
}

// path_ready makes a zero-value Path usable, with the context's allocator.
@(private)
path_ready :: proc(p: ^Path) {
	if p.svg.tol == 0 {
		if p.allocator.procedure == nil do p.allocator = context.allocator
		p.svg.tol = SVG_TOLERANCE
	}
}

// path_fill fills `p` into `m` by `rule`, combining its coverage by `op`.
// With `antialias` false each pixel is covered or not by whether its
// centre is inside. Only the part of the path over the mask is drawn.
path_fill :: proc(p: ^Path, m: ^Mask, rule := Fill_Rule.Nonzero, op := Mask_Op.Add, antialias := true) {
	arena: virtual.Arena
	r, ok := path_raster(&arena, m, op, antialias)
	if !ok do return
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	svg_raster_path(r, &p.svg, mask_xf(m))
	svg_raster_fill(r, rule == .Evenodd)
}

// path_stroke strokes `p` into `m`, `width` pixels wide, combining its
// coverage by `op`: corners turned by `join` (a miter longer than
// `miter_limit` times the width is bevelled), open ends by `cap`. With
// `dashes`, lengths on and off in turn (an odd list goes round twice, as in
// SVG), the stroke is dashed from `dash_offset` along it.
path_stroke :: proc(p: ^Path, m: ^Mask, width: f32, join := Line_Join.Miter, cap := Line_Cap.Butt, miter_limit: f32 = 4, dashes: []f32 = nil, dash_offset: f32 = 0, op := Mask_Op.Add, antialias := true) {
	if !(width > 0) {
		if op == .Intersect || op == .Replace do path_fill(&Path{}, m, op = op) // nothing drawn: the mask follows the op
		return
	}
	arena: virtual.Arena
	r, ok := path_raster(&arena, m, op, antialias)
	if !ok do return
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	style := Svg_Style{miter_limit = max(miter_limit, 1), join = Svg_Join(u8(join)), cap = Svg_Cap(u8(cap))}
	pattern := dashes
	total: f32
	for v in dashes {
		if !(v >= 0) {
			pattern = nil // a negative length: solid, as SVG says
			break
		}
		total += v
	}
	if !(total > 0) do pattern = nil
	if len(pattern) % 2 == 1 {
		twice := make([]f32, 2 * len(pattern))
		copy(twice, pattern)
		copy(twice[len(pattern):], pattern)
		pattern = twice
	}
	svg_stroke(r, &p.svg, &style, width, mask_xf(m), pattern, dash_offset)
	svg_raster_fill(r, false)
}

// path_raster is a raster writing rows into `m`, its working memory in
// `arena` (which the caller destroys once it is done with it).
@(private)
path_raster :: proc(arena: ^virtual.Arena, m: ^Mask, op: Mask_Op, antialias: bool) -> (r: ^Svg_Raster, ok: bool) {
	if m == nil || m.size.x <= 0 || m.size.y <= 0 || len(m.alpha) < m.size.x * m.size.y do return
	if virtual.arena_init_growing(arena) != nil do return
	context.allocator = virtual.arena_allocator(arena)
	return mask_raster_make(m, op, antialias), true
}

// mask_raster_make is a raster writing its rows into `m`, in the context's
// memory.
@(private)
mask_raster_make :: proc(m: ^Mask, op: Mask_Op, antialias: bool) -> (r: ^Svg_Raster) {
	r = new(Svg_Raster)
	r^ = {
		w = m.size.x, h = m.size.y,
		edges = make([dynamic]Svg_Edge), crosses = make([dynamic]Svg_Cross), active = make([dynamic]int),
		area = make([]f32, m.size.x + 2), diff = make([]f32, m.size.x + 2),
		mask = m, op = op, aliased = !antialias,
	}
	return r
}

// mask_xf moves the paths' space so the mask's origin is at 0, 0.
@(private)
mask_xf :: proc "contextless" (m: ^Mask) -> Svg_Xf {
	return {1, 0, 0, 1, -f32(m.origin.x), -f32(m.origin.y)}
}

// mask_row combines raster row `py` (its x0..<x1) into the mask by its op.
@(private)
mask_row :: proc(r: ^Svg_Raster, py: int) {
	row := r.mask.alpha[py * r.w:][:r.w]
	run: f32
	for x in r.x0 ..< r.x1 {
		run += r.diff[x]
		c := u8(clamp(run + r.area[x], 0, 1) * 255 + 0.5)
		switch r.op {
		case .Add:       row[x] = max(row[x], c)
		case .Subtract:  row[x] = min(row[x], 255 - c)
		case .Intersect: row[x] = min(row[x], c)
		case .Replace:   row[x] = c
		}
	}
}

// mask_outside clears what lies outside the rows and columns just drawn,
// for the ops that make the shape the whole of what is kept.
@(private)
mask_outside :: proc(r: ^Svg_Raster) {
	if r.op != .Intersect && r.op != .Replace do return
	w := r.w
	for y in 0 ..< r.h {
		row := r.mask.alpha[y * w:][:w]
		if y < r.y0 || y >= r.y1 || r.x1 <= r.x0 {
			for &v in row do v = 0
			continue
		}
		for x in 0 ..< r.x0 do row[x] = 0
		for x in r.x1 ..< w do row[x] = 0
	}
}

// image_paint lays `color` into `img` through `m` (placed at its origin in
// the picture's pixels): each pixel takes the colour at the colour's alpha
// times the mask's coverage, over what is there. The blend is on the
// stored sRGB values, as svg_render's and an image editor's normal layer
// blend are, and the picture keeps straight alpha. The part painted is
// touched (image_touch), so a picture on show is uploaded again in part.
image_paint :: proc(img: ^Image, m: ^Mask, color: Color) {
	if img == nil || m == nil || len(img.pixels) < img.width * img.height * 4 || len(m.alpha) < m.size.x * m.size.y do return
	x0, y0 := max(m.origin.x, 0), max(m.origin.y, 0)
	x1, y1 := min(m.origin.x + m.size.x, img.width), min(m.origin.y + m.size.y, img.height)
	if x1 <= x0 || y1 <= y0 do return
	src := [3]f32{linear_to_srgb(clamp(color.r, 0, 1)), linear_to_srgb(clamp(color.g, 0, 1)), linear_to_srgb(clamp(color.b, 0, 1))}
	alpha := clamp(color.a, 0, 1)
	for y in y0 ..< y1 {
		cov := m.alpha[(y - m.origin.y) * m.size.x:]
		px := img.pixels[y * img.width * 4:]
		for x in x0 ..< x1 {
			c := cov[x - m.origin.x]
			if c == 0 do continue
			sa := alpha * f32(c) / 255
			d := px[x * 4:][:4]
			da := f32(d[3]) / 255
			oa := sa + da * (1 - sa)
			if oa <= 0 do continue
			for k in 0 ..< 3 {
				v := (src[k] * sa + f32(d[k]) / 255 * da * (1 - sa)) / oa
				d[k] = u8(clamp(v, 0, 1) * 255 + 0.5)
			}
			d[3] = u8(clamp(oa, 0, 1) * 255 + 0.5)
		}
	}
	image_touch(img, x0, y0, x1 - x0, y1 - y0)
}
