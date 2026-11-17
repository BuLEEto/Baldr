// canvas_queue.odin — the canvas work queue: what an app asks for, checked
// and recorded, with no device in sight.
//
// Every canvas operation is queued rather than done, and `canvas_flush`
// (one per backend) records a batch of them. The *asking* is the same work
// either way: name the canvases, check the rectangles lie inside them,
// refuse the combinations that cannot be drawn (a source that is also its
// destination, a mask that does not cover), and append a Canvas_Op. That
// checking is the API's contract, so it lives here once: two copies of a
// rule like `canvas_inside` would drift apart.
//
// What stays with each backend is the recording: canvas.odin builds a
// VkCommandBuffer, metal_canvas.odin an MTLCommandBuffer. Both reach back
// into this file for `canvas_page`, `canvas_curve`, `filter_region` and the
// op queue itself.
//
// A backend supplies: `Page_State` (with `canvas`, `size`, `canvas_format`,
// `space`), `page_state`, `Buffer` (with `ptr` and `size`), `canvas_buffer`
// and `buffer_destroy`.
package gpu

import "core:fmt"
import "core:math"
import "core:mem"

// Buffer_Use is what a canvas buffer is for, so each backend can ask its
// API for the right kind: bytes on their way to a texture, or the vertices
// of a dab or stroke pass. Both are written by the CPU and read by the GPU;
// the distinction is Vulkan's usage flags, which Metal does not have.
@(private)
Buffer_Use :: enum u8 { Upload, Vertex, Read }

// canvas_transform queues drawing `src`'s rectangle into `dst`'s `area`
// through `inv` (which maps a destination texel to a source texel), sampled
// by `kernel`, then laid on by `mode` at `opacity` through `mask` (lined up
// with the destination). False for rectangles outside the canvases, `src`
// being `dst`, or no such canvas.
canvas_transform :: proc(r: ^Renderer, src: Page, sx, sy, sw, sh: u32, dst: Page, area: [4]u32,
	inv: [9]f32, kernel: u32, mode: Blend_Mode, opacity: f32, mask: Page = 0, linear := false) -> bool {
	s, d := canvas_page(r, src), canvas_page(r, dst)
	if s == nil || d == nil || src == dst do return false
	if !canvas_inside(s, sx, sy, sw, sh) || !canvas_inside(d, area.x, area.y, area.z, area.w) do return false
	if mask != 0 {
		m := canvas_page(r, mask)
		if m == nil || mask == dst || !canvas_inside(m, area.x, area.y, area.z, area.w) do return false
	}
	append(&r.canvas_ops, Canvas_Op{kind = .Transform, page = dst, src = src,
		x = area.x, y = area.y, w = area.z, h = area.w, sx = sx, sy = sy, sw = sw, sh = sh,
		inv = inv, kernel = kernel, mask = mask, mode = mode, opacity = opacity, linear = linear})
	return true
}

// canvas_page is a live canvas's state, nil for anything else, including a
// canvas imported from another process (dmabuf_*.odin): its memory is the
// producer's, it is created for sampling only, and the canvas batch does not
// take it over from the foreign queue the way a frame does. So every
// operation here refuses one by the same path as a handle that is not a
// canvas at all.
@(private)
canvas_page :: proc(r: ^Renderer, p: Page) -> ^Page_State {
	ps := page_state(r, p)
	return ps if ps != nil && ps.canvas && !ps.imported else nil
}

@(private)
canvas_inside :: proc "contextless" (ps: ^Page_State, x, y, w, h: u32) -> bool {
	return w > 0 && h > 0 && u64(x) + u64(w) <= u64(ps.size.x) && u64(y) + u64(h) <= u64(ps.size.y)
}

// canvas_write queues `pixels` (w × h texels of the canvas's format, rows
// tightly packed) into the rectangle at x, y. The bytes are copied now.
// False for a rectangle outside the canvas, too few bytes, or no canvas.
canvas_write :: proc(r: ^Renderer, page: Page, x, y, w, h: u32, pixels: []u8) -> bool {
	ps := canvas_page(r, page)
	if ps == nil || !canvas_inside(ps, x, y, w, h) do return false
	need := int(w) * int(h) * canvas_bpp(ps.canvas_format)
	if len(pixels) < need do return false
	staging, ok := staging_take(r, need, .Upload)
	if !ok do return false
	mem.copy(staging.ptr, raw_data(pixels), need)
	append(&r.canvas_ops, Canvas_Op{kind = .Write, page = page, x = x, y = y, w = w, h = h, staging = staging})
	return true
}

// canvas_write_begin hands back the staging memory for the rectangle at
// x, y — w × h texels of the canvas's format, rows tightly packed — for the
// caller to fill itself, saving the copy `canvas_write` makes (a video frame
// is 8 MB at 1080p, 33 MB at 4K). The write is queued here, not by
// canvas_write_end, so it keeps its place among the other operations; until
// canvas_write_end another begin is refused. The slice is the renderer's,
// valid until canvas_write_end: the next flush hands it to the GPU, so
// writing into it later corrupts a copy in flight. A begin
// never ended is reported once by the next canvas_flush, and the write still
// happens. Nil and false for a rectangle outside the canvas, no such canvas,
// no memory to be had, or a write already open.
canvas_write_begin :: proc(r: ^Renderer, page: Page, x, y, w, h: u32) -> ([]u8, bool) {
	if r.writing do return nil, false
	ps := canvas_page(r, page)
	if ps == nil || !canvas_inside(ps, x, y, w, h) do return nil, false
	need := int(w) * int(h) * canvas_bpp(ps.canvas_format)
	staging, ok := staging_take(r, need, .Upload)
	if !ok do return nil, false
	append(&r.canvas_ops, Canvas_Op{kind = .Write, page = page, x = x, y = y, w = w, h = h, staging = staging})
	r.writing = true
	return ([^]u8)(staging.ptr)[:need], true
}

// canvas_write_end says the memory canvas_write_begin handed over has been
// filled, and the slice is finished with. False when no write was open.
canvas_write_end :: proc(r: ^Renderer) -> bool {
	if !r.writing do return false
	r.writing = false
	return true
}

// writing_closed closes a canvas_write_begin the caller never ended (every
// canvas_flush). The write itself is already queued, so nothing is lost; what
// is wrong is that the caller is still holding a slice into memory this flush
// hands to the GPU, and the next begin would have been refused. Reported once
// a run, not once a frame.
@(private)
writing_closed :: proc(r: ^Renderer) {
	if !r.writing do return
	r.writing = false
	if r.writing_said do return
	r.writing_said = true
	fmt.eprintfln("gpu: canvas_write_begin was not ended before the flush; the write stands, but do not keep the slice")
}

// canvas_fill queues setting the rectangle's texels to `value` (as stored:
// 0..1 for RGBA8 and RGBA16, any float for RGBA32F). False as canvas_write.
canvas_fill :: proc(r: ^Renderer, page: Page, x, y, w, h: u32, value: [4]f32) -> bool {
	ps := canvas_page(r, page)
	if ps == nil || !canvas_inside(ps, x, y, w, h) do return false
	append(&r.canvas_ops, Canvas_Op{kind = .Fill, page = page, x = x, y = y, w = w, h = h, value = value})
	return true
}

// canvas_copy queues copying w × h texels at sx, sy of `src` to dx, dy of
// `dst`. The values go across as they are: between formats they keep their
// meaning (an 8-bit 255 becomes a 16-bit 65535), and colour spaces are not
// converted. Within one canvas the two rectangles must not overlap. False
// for a rectangle outside either canvas, overlapping ones, or no canvas.
canvas_copy :: proc(r: ^Renderer, src: Page, sx, sy, w, h: u32, dst: Page, dx, dy: u32) -> bool {
	s, d := canvas_page(r, src), canvas_page(r, dst)
	if s == nil || d == nil || !canvas_inside(s, sx, sy, w, h) || !canvas_inside(d, dx, dy, w, h) do return false
	if src == dst && sx < dx + w && dx < sx + w && sy < dy + h && dy < sy + h do return false
	append(&r.canvas_ops, Canvas_Op{kind = .Copy, page = dst, src = src, x = dx, y = dy, w = w, h = h, sx = sx, sy = sy})
	return true
}

// canvas_blend queues compositing w × h texels at sx, sy of `src` onto dx,
// dy of `dst` by `mode`, at `opacity`, through `mask`'s first channel (its
// texels lined up with the source's; 0 for none), on the stored values or,
// with `linear`, in linear light (each canvas's curve undone, the result's
// done again). `seed` picks Dissolve's pattern. False for rectangles outside
// the canvases, a mask not covering the source's, the source being the
// destination, or no such canvas.
canvas_blend :: proc(r: ^Renderer, src: Page, sx, sy, w, h: u32, dst: Page, dx, dy: u32, mode: Blend_Mode, opacity: f32, mask: Page = 0, linear := false, seed: u32 = 0) -> bool {
	s, d := canvas_page(r, src), canvas_page(r, dst)
	if s == nil || d == nil || src == dst || !canvas_inside(s, sx, sy, w, h) || !canvas_inside(d, dx, dy, w, h) do return false
	if mask != 0 {
		m := canvas_page(r, mask)
		if m == nil || mask == dst || !canvas_inside(m, sx, sy, w, h) do return false
	}
	append(&r.canvas_ops, Canvas_Op{kind = .Blend, page = dst, src = src, x = dx, y = dy, w = w, h = h, sx = sx, sy = sy, mask = mask, mode = mode, opacity = opacity, linear = linear, seed = seed})
	return true
}

// canvas_paint queues laying `color` (as stored) onto the rectangle of
// `dst` by `mode` at `opacity`, through `mask`'s first channel (its texels
// lined up with the destination's; 0 for none): a brush stroke's colour
// through the stroke's coverage. With `erase` the destination's alpha is
// taken away instead (an eraser), colour kept. False for a rectangle
// outside the canvas, a mask not covering it, or no such canvas.
canvas_paint :: proc(r: ^Renderer, dst: Page, x, y, w, h: u32, color: [4]f32, mode: Blend_Mode, opacity: f32, mask: Page = 0, erase := false, linear := false) -> bool {
	d := canvas_page(r, dst)
	if d == nil || !canvas_inside(d, x, y, w, h) do return false
	if mask != 0 {
		m := canvas_page(r, mask)
		if m == nil || mask == dst || !canvas_inside(m, x, y, w, h) do return false
	}
	append(&r.canvas_ops, Canvas_Op{kind = .Blend, page = dst, x = x, y = y, w = w, h = h, sx = x, sy = y, mask = mask, mode = mode, opacity = opacity, linear = linear, solid = true, erase = erase, value = color})
	return true
}

// canvas_dabs queues stamping `dabs`' coverage onto `stroke`, in order,
// each laid over what is there (old + dab × (1 − old), in every channel):
// the coverage of a stroke being painted, which canvas_paint then lays in
// the brush's colour. `tip` is a canvas whose first channel is the brush's
// shape (0 for round). False for no canvas, or no dabs.
canvas_dabs :: proc(r: ^Renderer, stroke: Page, dabs: []Dab, tip: Page = 0) -> bool {
	ps := canvas_page(r, stroke)
	if ps == nil || len(dabs) == 0 do return false
	if tip != 0 && (canvas_page(r, tip) == nil || tip == stroke) do return false
	verts, ok := staging_take(r, len(dabs) * 6 * size_of(Dab_Vertex), .Vertex)
	if !ok do return false
	out := ([^]Dab_Vertex)(verts.ptr)[:len(dabs) * 6]
	lo := [2]f32{max(f32), max(f32)}
	hi := [2]f32{min(f32), min(f32)}
	for d, i in dabs {
		reach := d.radius * (1.4143 if tip != 0 else 1) + 1 // a turned square tip reaches its corners
		a, b := d.centre - reach, d.centre + reach
		lo, hi = {min(lo.x, a.x), min(lo.y, a.y)}, {max(hi.x, b.x), max(hi.y, b.y)}
		info := [4]f32{d.radius, d.hardness, d.strength, d.angle}
		corners := [6][2]f32{{a.x, a.y}, {b.x, a.y}, {b.x, b.y}, {a.x, a.y}, {b.x, b.y}, {a.x, b.y}}
		for c, k in corners do out[i * 6 + k] = {c, d.centre, info}
	}
	x0, y0 := u32(clamp(lo.x, 0, f32(ps.size.x))), u32(clamp(lo.y, 0, f32(ps.size.y)))
	x1, y1 := u32(clamp(math.ceil(hi.x), 0, f32(ps.size.x))), u32(clamp(math.ceil(hi.y), 0, f32(ps.size.y)))
	if x1 <= x0 || y1 <= y0 { // nothing on the canvas
		staging_give(r, &verts)
		return true
	}
	append(&r.canvas_ops, Canvas_Op{kind = .Dabs, page = stroke, x = x0, y = y0, w = x1 - x0, h = y1 - y0, staging = verts, count = len(dabs), tip = tip})
	return true
}

// canvas_strokes_upload puts the quads for a whole call's segments into one
// device buffer, each segment six vertices at six times its index. One
// buffer a call, not one a stroke: each buffer is a create, allocate and map
// on the window's thread, and a device's allocation count is limited. The
// caller frees it by passing `own` on exactly one of the runs that use it;
// the batch frees it when the work is done.
canvas_strokes_upload :: proc(r: ^Renderer, segs: []Stroke_Seg) -> (buf: Buffer, ok: bool) {
	if len(segs) == 0 do return {}, false
	buf, ok = staging_take(r, len(segs) * 6 * size_of(Stroke_Vertex), .Vertex)
	if !ok do return {}, false
	out := ([^]Stroke_Vertex)(buf.ptr)[:len(segs) * 6]
	for sg, i in segs {
		reach := max(sg.ra, sg.rb) + 1 // the wider end, plus the antialiased texel
		a := [2]f32{min(sg.a.x, sg.b.x) - reach, min(sg.a.y, sg.b.y) - reach}
		b := [2]f32{max(sg.a.x, sg.b.x) + reach, max(sg.a.y, sg.b.y) + reach}
		line := [4]f32{sg.a.x, sg.a.y, sg.b.x, sg.b.y}
		radii := [2]f32{sg.ra, sg.rb}
		corners := [6][2]f32{{a.x, a.y}, {b.x, a.y}, {b.x, b.y}, {a.x, a.y}, {b.x, b.y}, {a.x, b.y}}
		for c, k in corners do out[i * 6 + k] = {c, line, radii}
	}
	return buf, true
}

// canvas_strokes queues one stroke's coverage onto `cover`: the segments
// `segs[first:][:count]` of a buffer from canvas_strokes_upload, a quad
// each, combined by a maximum rather than laid over: segments overlap at
// every join, and laying them over one another would darken the joins and
// any self-crossing, where a maximum keeps the stroke one coverage that
// `canvas_paint` can apply one alpha to. The rectangle is the caller's, not
// worked out from the segments, and is cleared as the pass begins; it must
// be exactly the rectangle the caller then composites through, or coverage
// left by the previous stroke is read as this one's. `own` on exactly one
// run of a call frees the shared buffer with the batch. False for no such
// canvas, a rectangle off it, or no segments.
canvas_strokes :: proc(r: ^Renderer, cover: Page, buf: Buffer, segs: []Stroke_Seg, first, count: int,
	x, y, w, h: u32, own: bool) -> bool {
	give_back := buf // staging_give takes a pointer, and a parameter has no address
	ps := canvas_page(r, cover)
	if ps == nil || count <= 0 || first < 0 || first + count > len(segs) || !canvas_inside(ps, x, y, w, h) {
		if own do staging_give(r, &give_back)
		return false
	}
	if w == 0 || h == 0 { // nothing to draw, but the buffer is still this call's to give back
		if own do staging_give(r, &give_back)
		return true
	}
	x0, y0, x1, y1 := x, y, x + w, y + h
	append(&r.canvas_ops, Canvas_Op{kind = .Strokes, page = cover, x = x0, y = y0, w = x1 - x0, h = y1 - y0,
		staging = buf, first = first, count = count, own = own})
	return true
}

// canvas_filter queues filter `f` from w × h texels at sx, sy of `src`
// into dx, dy of `dst`, which may be the same canvas (the source's
// rectangle is copied first). False for rectangles outside the canvases, a
// Curves or Lut filter without a table canvas (or a table that is also the
// destination), or no such canvas.
canvas_filter :: proc(r: ^Renderer, src: Page, sx, sy, w, h: u32, dst: Page, dx, dy: u32, f: Filter) -> bool {
	s, d := canvas_page(r, src), canvas_page(r, dst)
	if s == nil || d == nil || !canvas_inside(s, sx, sy, w, h) || !canvas_inside(d, dx, dy, w, h) do return false
	if f.kind == .Curves || f.kind == .Lut {
		t := canvas_page(r, f.table)
		if t == nil || f.table == dst do return false
		if f.kind == .Curves && (t.size.x < 2 || t.size.y < 1) do return false
		if f.kind == .Lut && (t.size.y < 2 || t.size.x != t.size.y * t.size.y) do return false
	}
	append(&r.canvas_ops, Canvas_Op{kind = .Filter, page = dst, src = src, x = dx, y = dy, w = w, h = h, sx = sx, sy = sy, filter = f})
	return true
}

// filter_margin is how far past the rectangle a filter reads.
@(private)
filter_margin :: proc "contextless" (f: Filter) -> u32 {
	if f.kind != .Blur && f.kind != .Sharpen do return 0
	return u32(math.ceil(3 * max(f.sigma, 0.01)))
}

// filter_region is the part of the source a filter's input copy holds: the
// rectangle and its margin, within the canvas.
@(private)
filter_region :: proc "contextless" (s: ^Page_State, op: Canvas_Op) -> (x0, y0, x1, y1: u32) {
	m := filter_margin(op.filter)
	x0 = op.sx - min(op.sx, m)
	y0 = op.sy - min(op.sy, m)
	x1 = min(op.sx + op.w + m, s.size.x)
	y1 = min(op.sy + op.h + m, s.size.y)
	return
}

// canvas_read queues reading the rectangle back; its bytes come with the id
// returned, from canvas_reads_take once the batch that carries it is done.
// ok is false as for canvas_write.
canvas_read :: proc(r: ^Renderer, page: Page, x, y, w, h: u32) -> (id: u32, ok: bool) {
	ps := canvas_page(r, page)
	if ps == nil || !canvas_inside(ps, x, y, w, h) do return
	r.canvas_next_read += 1
	id = r.canvas_next_read
	append(&r.canvas_ops, Canvas_Op{kind = .Read, page = page, x = x, y = y, w = w, h = h, id = id})
	return id, true
}

// canvas_pending says whether work is queued for the next flush.
canvas_pending :: proc(r: ^Renderer) -> bool {
	return len(r.canvas_ops) > 0
}

// canvas_curve is the transfer curve blend.frag undoes for a space: 0
// sRGB's (sRGB, Display P3), 1 Adobe RGB's, 2 none.
@(private)
canvas_curve :: proc "contextless" (space: Color_Space) -> u32 {
	switch space {
	case .sRGB, .Display_P3: return 0
	case .Adobe_RGB:         return 1
	case .Linear:            return 2
	}
	return 0
}
