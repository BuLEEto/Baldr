// batch.odin — draw commands to vertices and batches.
//
// The backend-agnostic half of the renderer: it touches no device state
// (gpu/render_test.odin calls build_batches on a zero Renderer), so the Metal
// renderer and the Vulkan one consume the same vertices and batches.
//
// Batching: consecutive commands sharing (atlas page, scissor) become one
// draw. Quads do not sample, so they join any page's batch; a batch that only
// has quads adopts the first glyph page that follows it.
package gpu

import "core:math"

// The kind word's low byte: which fragment path a vertex takes. Shared,
// because it is the contract between the batcher and *either* backend's
// shader — ui.frag on Vulkan, its MSL port on Metal.
KIND_QUAD        :: u32(0)
KIND_ALPHA_GLYPH :: u32(1)
KIND_RGBA_GLYPH  :: u32(2)
KIND_SHADOW      :: u32(3)
KIND_IMAGE       :: u32(5) // textured, rounded
KIND_BACKDROP    :: u32(4)
KIND_GLOW        :: u32(6) // a glyph's coverage, blurred
KIND_HIGHLIGHT   :: u32(7) // a line along a rounded rect's top edge
KIND_LINE        :: u32(8) // a capsule between two points: the only primitive that is not axis-aligned

// Vertex is the one vertex format. 6 per Cmd (two triangles), 80 bytes.
// `kind` selects the fragment path: 0 = SDF quad, 1 = alpha glyph tinted by
// color, 2 = RGBA glyph modulated by color.a.
Vertex :: struct {
	pos:      [2]f32, // device px
	uv:       [2]f32, // normalised atlas coords (glyphs)
	color:    [4]f32, // linear RGBA, straight alpha
	rect:     [4]f32, // x, y, w, h of the quad the SDF is evaluated against
	radius:   f32,
	border_w: f32,
	border:   [4]f32,
	kind:     u32,
	_pad:     u32,
}
#assert(size_of(Vertex) == 80)

// Batch is one draw: `count` vertices starting at `first`, one scissor, one page.
Batch :: struct {
	kind:    Batch_Kind,
	page:    Page, // 0 = quads only so far (bound to WHITE_PAGE at draw time)
	scissor: Scissor,
	first:   u32,
	count:   u32,
	blur:    f32, // .Blur: radius in px
}

// Batch_Kind: .Draw is a vkCmdDraw range; .Blur is a break where the scene
// so far is blurred into the target's blur images (see blur.odin).
Batch_Kind :: enum u8 { Draw, Blur }
// ------------------------------------------------------------- batching

// build_batches fills r.verts / r.batches from cmds, tracking the clip stack.
// It touches no device state, so both backends share it, which is also why
// its extent is a plain `[2]u32` and not a `vk.Extent2D`.
build_batches :: proc(r: ^Renderer, cmds: []Cmd, extent: [2]u32) {
	clear_dynamic_array(&r.verts)
	clear_dynamic_array(&r.batches)
	clear_dynamic_array(&r.clips)
	full := [4]f32{0, 0, f32(extent.x), f32(extent.y)}
	append(&r.clips, full)
	scissor, visible := scissor_of(full, extent)

	for c in cmds {
		switch v in c {
		case Clip_Push:
			top := r.clips[len(r.clips) - 1]
			append(&r.clips, rect_intersect(top, v.rect))
			scissor, visible = scissor_of(r.clips[len(r.clips) - 1], extent)
		case Clip_Pop:
			if len(r.clips) > 1 { pop(&r.clips) } // unbalanced pops are ignored
			scissor, visible = scissor_of(r.clips[len(r.clips) - 1], extent)
		case Quad:
			if !visible || v.rect.z <= 0 || v.rect.w <= 0 { continue }
			if v.color.a <= 0 && v.color2.a <= 0 && (v.border_w <= 0 || v.border.a <= 0) { continue }
			b := batch_for(r, 0, scissor)
			emit_quad(&r.verts, v)
			b.count += 6
		case Line:
			if !visible || v.width <= 0 || v.color.a <= 0 { continue }
			b := batch_for(r, 0, scissor)
			emit_line(&r.verts, v)
			b.count += 6
		case Shadow:
			if !visible || v.rect.z <= 0 || v.rect.w <= 0 || v.color.a <= 0 || v.blur <= 0 { continue }
			b := batch_for(r, 0, scissor)
			emit_shadow(&r.verts, v)
			b.count += 6
		case Image:
			if !visible || v.rect.z <= 0 || v.rect.w <= 0 || v.color.a <= 0 { continue }
			page := v.page
			ps := page_state(r, page)
			if ps == nil { page = WHITE_PAGE }
			b := batch_for(r, page, scissor)
			sampling: u32
			switch v.pixels {
			case .Hard:   sampling = KIND_PIXELATED
			case .Smooth: sampling = KIND_SMOOTH
			case .Auto: // the shader decides, by how magnified the fragment is
			}
			if v.pixel_grid do sampling |= KIND_PIXEL_GRID
			vert := Vertex{color = v.color, rect = v.rect, radius = v.radius, kind = kind_square(KIND_IMAGE, v.square) | sampling}
			if ps != nil && ps.canvas do vert.kind |= KIND_CANVAS | u32(ps.space) << 14 // its values decoded from its colour space in the shader
			emit_rect(&r.verts, vert, {v.rect.x, v.rect.y}, {v.rect.x + v.rect.z, v.rect.y + v.rect.w}, {v.uv[0], v.uv[1]}, {v.uv[2], v.uv[3]})
			b.count += 6
		case Backdrop:
			if !visible || v.rect.z <= 0 || v.rect.w <= 0 { continue }
			append(&r.batches, Batch{kind = .Blur, blur = max(v.blur, 1), scissor = scissor})
			b := batch_for(r, BLUR_PAGE, scissor)
			emit_backdrop(&r.verts, v, extent)
			b.count += 6
		case Glow:
			if !visible || v.rect.z <= 0 || v.rect.w <= 0 || v.color.a <= 0 || v.radius <= 0 { continue }
			ps := page_state(r, v.page)
			if ps == nil { continue } // no coverage to blur
			b := batch_for(r, v.page, scissor)
			emit_glow(&r.verts, v, ps.format == .RGBA8)
			b.count += 6
		case Highlight:
			if !visible || v.rect.z <= 0 || v.rect.w <= 0 || v.color.a <= 0 || v.width <= 0 { continue }
			b := batch_for(r, 0, scissor)
			emit_highlight(&r.verts, v)
			b.count += 6
		case Glyph:
			if !visible || v.rect.z <= 0 || v.rect.w <= 0 || v.color.a <= 0 { continue }
			page := v.page
			kind := KIND_ALPHA_GLYPH
			if ps := page_state(r, page); ps != nil {
				if ps.format == .RGBA8 { kind = KIND_RGBA_GLYPH }
			} else {
				page = WHITE_PAGE
			}
			b := batch_for(r, page, scissor)
			emit_glyph(&r.verts, v, kind)
			b.count += 6
		}
	}
}

// batch_for returns the batch new vertices should go into: the last one if it
// has the same scissor and a compatible page, else a fresh one.
@(private)
batch_for :: proc(r: ^Renderer, page: Page, scissor: Scissor) -> ^Batch {
	if n := len(r.batches); n > 0 {
		b := &r.batches[n - 1]
		if b.kind == .Draw && b.scissor == scissor && (page == 0 || b.page == 0 || b.page == page) {
			if b.page == 0 { b.page = page }
			return b
		}
	}
	append(&r.batches, Batch{page = page, scissor = scissor, first = u32(len(r.verts))})
	return &r.batches[len(r.batches) - 1]
}

@(private)
rect_intersect :: proc(a, b: [4]f32) -> [4]f32 {
	x0 := max(a.x, b.x)
	y0 := max(a.y, b.y)
	x1 := min(a.x + a.z, b.x + b.z)
	y1 := min(a.y + a.w, b.y + b.w)
	return {x0, y0, max(x1 - x0, 0), max(y1 - y0, 0)}
}

// scissor_of rounds a clip rect outward to whole pixels and clamps it to the
// surface. visible = false when the result is empty (draws are skipped).
@(private)
scissor_of :: proc(clip: [4]f32, extent: [2]u32) -> (scissor: Scissor, visible: bool) {
	x0 := clamp(i32(math.floor(clip.x)), 0, i32(extent.x))
	y0 := clamp(i32(math.floor(clip.y)), 0, i32(extent.y))
	x1 := clamp(i32(math.ceil(clip.x + clip.z)), 0, i32(extent.x))
	y1 := clamp(i32(math.ceil(clip.y + clip.w)), 0, i32(extent.y))
	if x1 <= x0 || y1 <= y0 { return {}, false }
	return {x = x0, y = y0, w = u32(x1 - x0), h = u32(y1 - y0)}, true
}

// kind_square packs the corners a rounded shape keeps square into its
// vertex kind, above the kind's own byte (bit 8 top-left … bit 11
// bottom-left); the fragment shader takes radius 0 at those corners.
@(private)
kind_square :: proc "contextless" (kind: u32, square: Corners) -> u32 {
	return kind | u32(transmute(u8)square) << 8
}

// How a magnified picture is sampled, in the kind word. KIND_PIXELATED (bit
// 12) is one hard-edged square a texel; KIND_SMOOTH (bit 16) is the linear
// filter however far in. Neither set is Pixels.Auto, which the shader
// blends from one to the other between 2 and 4 device pixels a texel.
// KIND_PIXEL_GRID (bit 17) asks for a line between the texels, far enough in.
@(private)
KIND_PIXELATED :: u32(1) << 12
@(private)
KIND_SMOOTH :: u32(1) << 16
@(private)
KIND_PIXEL_GRID :: u32(1) << 17

// emit_quad appends the two triangles of an SDF quad. The geometry is grown by
// 1 px on every side so the anti-aliasing fringe outside the rect edge is
// shaded; the shader's SDF, not the geometry, defines the visible shape.
@(private)
emit_quad :: proc(verts: ^[dynamic]Vertex, q: Quad) {
	x0 := q.rect.x - 1
	y0 := q.rect.y - 1
	x1 := q.rect.x + q.rect.z + 1
	y1 := q.rect.y + q.rect.w + 1
	v := Vertex{
		color    = q.color,
		rect     = q.rect,
		radius   = q.radius,
		border_w = q.border_w,
		border   = q.border,
		kind     = kind_square(KIND_QUAD, q.square),
	}
	if q.color2 != {} { // a far colour is set (it may be fully transparent: a fade)
		far := v
		far.color = q.color2
		if q.horizontal {
			emit_rect_grad_h(verts, v, far, {x0, y0}, {x1, y1})
		} else {
			emit_rect_grad(verts, v, far, {x0, y0}, {x1, y1})
		}
		return
	}
	emit_rect(verts, v, {x0, y0}, {x1, y1}, {0, 0}, {0, 0})
}

// emit_line appends the two triangles covering a segment's capsule: the
// bounding box of both ends, grown by half the width and one pixel for the
// anti-aliasing fringe. The shader shapes it; the geometry only has to cover
// it, which is why a diagonal line needs no rotated geometry.
@(private)
emit_line :: proc(verts: ^[dynamic]Vertex, l: Line) {
	g := l.width * 0.5 + 1
	x0 := min(l.a.x, l.b.x) - g
	y0 := min(l.a.y, l.b.y) - g
	x1 := max(l.a.x, l.b.x) + g
	y1 := max(l.a.y, l.b.y) + g
	v := Vertex{
		color  = l.color,
		rect   = {l.a.x, l.a.y, l.b.x, l.b.y}, // the segment itself, not a box
		radius = l.width * 0.5,                // half width, read as params.x
		border = {1 if l.flat else 0, 0, 0, 0},
		kind   = KIND_LINE,
	}
	emit_rect(verts, v, {x0, y0}, {x1, y1}, {0, 0}, {0, 0})
}

// emit_shadow appends a KIND_SHADOW quad grown by the blur radius so the whole
// falloff is shaded; the shader evaluates the rounded-rect SDF of `rect`.
@(private)
emit_shadow :: proc(verts: ^[dynamic]Vertex, s: Shadow) {
	g := s.blur * 1.5 + 1 // three sigmas of its Gaussian (blur / 2): faded to nothing
	v := Vertex{
		color    = s.color,
		rect     = s.rect,
		radius   = s.radius,
		border_w = s.blur, // reused as the blur distance for KIND_SHADOW
		border   = s.hole, // …and the border for the hole it leaves clear
		kind     = kind_square(KIND_SHADOW, s.square),
	}
	emit_rect(verts, v, {s.rect.x - g, s.rect.y - g}, {s.rect.x + s.rect.z + g, s.rect.y + s.rect.w + g}, {0, 0}, {0, 0})
}

// emit_rect_grad_h is the horizontal counterpart: left and right colours.
@(private)
emit_rect_grad_h :: proc(verts: ^[dynamic]Vertex, left, right: Vertex, p0, p1: [2]f32) {
	a, b, c, d := left, right, right, left
	a.pos = {p0.x, p0.y}; b.pos = {p1.x, p0.y}; c.pos = {p1.x, p1.y}; d.pos = {p0.x, p1.y}
	append(verts, a, b, c, a, c, d)
}

// emit_rect_grad is emit_rect with different top and bottom vertex colours;
// the rasteriser interpolates them into a vertical gradient for free.
@(private)
emit_rect_grad :: proc(verts: ^[dynamic]Vertex, top, bottom: Vertex, p0, p1: [2]f32) {
	a, b, c, d := top, top, bottom, bottom
	a.pos = {p0.x, p0.y}
	b.pos = {p1.x, p0.y}
	c.pos = {p1.x, p1.y}
	d.pos = {p0.x, p1.y}
	append(verts, a, b, c, a, c, d)
}

// emit_backdrop appends a KIND_BACKDROP quad whose uv is its screen position,
// so the fragment shader samples the blurred scene at the same place.
@(private)
emit_backdrop :: proc(verts: ^[dynamic]Vertex, b: Backdrop, extent: [2]u32) {
	x0 := b.rect.x - 1
	y0 := b.rect.y - 1
	x1 := b.rect.x + b.rect.z + 1
	y1 := b.rect.y + b.rect.w + 1
	w, h := f32(extent.x), f32(extent.y)
	sat := b.saturation if b.saturation > 0 else 1
	v := Vertex{color = b.tint, rect = b.rect, radius = b.radius, border = {sat, b.noise, clamp(b.fade, 0, 1), 0}, kind = kind_square(KIND_BACKDROP, b.square)}
	emit_rect(verts, v, {x0, y0}, {x1, y1}, {x0 / w, y0 / h}, {x1 / w, y1 / h})
}

// emit_glow appends a KIND_GLOW quad: the glyph's box grown by 1.5 × the
// radius (three sigmas) with its uv grown alike; `rect` carries the glyph's
// own uv box (the atlas holds other glyphs outside it) and `border` the uv
// per device px, the radius and whether the page is RGBA.
@(private)
emit_glow :: proc(verts: ^[dynamic]Vertex, g: Glow, rgba: bool) {
	upp := [2]f32{(g.uv[2] - g.uv[0]) / g.rect.z, (g.uv[3] - g.uv[1]) / g.rect.w}
	e := g.radius * 1.5
	v := Vertex{color = g.color, rect = g.uv, border = {upp.x, upp.y, g.radius, 1 if rgba else 0}, kind = KIND_GLOW}
	emit_rect(verts, v,
		{g.rect.x - e, g.rect.y - e}, {g.rect.x + g.rect.z + e, g.rect.y + g.rect.w + e},
		{g.uv[0] - e * upp.x, g.uv[1] - e * upp.y}, {g.uv[2] + e * upp.x, g.uv[3] + e * upp.y}, g.pivot, g.angle)
}

// emit_highlight appends a KIND_HIGHLIGHT quad over the top of the rect, as
// far down as its corners reach.
@(private)
emit_highlight :: proc(verts: ^[dynamic]Vertex, h: Highlight) {
	v := Vertex{color = h.color, rect = h.rect, radius = h.radius, border_w = h.width, kind = kind_square(KIND_HIGHLIGHT, h.square)}
	bottom := h.rect.y + min(max(h.radius, h.width) + 2, h.rect.w + 1)
	emit_rect(verts, v, {h.rect.x - 1, h.rect.y - 1}, {h.rect.x + h.rect.z + 1, bottom}, {0, 0}, {0, 0})
}

@(private)
emit_glyph :: proc(verts: ^[dynamic]Vertex, g: Glyph, kind: u32) {
	v := Vertex{color = g.color, rect = g.rect, kind = kind}
	emit_rect(verts, v,
		{g.rect.x, g.rect.y}, {g.rect.x + g.rect.z, g.rect.y + g.rect.w},
		{g.uv[0], g.uv[1]}, {g.uv[2], g.uv[3]}, g.pivot, g.angle)
}

@(private)
emit_rect :: proc(verts: ^[dynamic]Vertex, v: Vertex, p0, p1, uv0, uv1: [2]f32, pivot: [2]f32 = {}, angle: f32 = 0) {
	a, b, c, d := v, v, v, v
	a.pos = {p0.x, p0.y}; a.uv = {uv0.x, uv0.y}
	b.pos = {p1.x, p0.y}; b.uv = {uv1.x, uv0.y}
	c.pos = {p1.x, p1.y}; c.uv = {uv1.x, uv1.y}
	d.pos = {p0.x, p1.y}; d.uv = {uv0.x, uv1.y}
	if angle != 0 { // the corners turn; the atlas is sampled as it was, which only a glyph or its glow may rely on
		a.pos = turn_point(a.pos, pivot, angle)
		b.pos = turn_point(b.pos, pivot, angle)
		c.pos = turn_point(c.pos, pivot, angle)
		d.pos = turn_point(d.pos, pivot, angle)
	}
	append(verts, a, b, c, a, c, d)
}

// turn_point turns `p` about `pivot` by `angle` radians, clockwise on a
// y-down screen.
@(private)
turn_point :: proc "contextless" (p, pivot: [2]f32, angle: f32) -> [2]f32 {
	cs, sn := math.cos(angle), math.sin(angle)
	q := p - pivot
	return pivot + {q.x * cs - q.y * sn, q.x * sn + q.y * cs}
}

