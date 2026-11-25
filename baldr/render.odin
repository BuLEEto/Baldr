package baldr

// Render: turns a Tree's logical-pixel draw list into device-pixel gpu.Cmds.
//
// render_prepare is the only bridge between the retained draw lists and the
// gpu package. It scales and pixel-snaps rects and clips, lays text out
// through the Tree's Text_Engine at the logical size (so line breaks are the
// ones layout measured), rasterises glyphs at the device size, and hands
// atlas pages to the renderer through an Atlas_Sink. Nothing here calls the
// gpu package's procs directly: the run loop supplies a sink that wraps
// gpu.atlas_create / gpu.atlas_upload, and headless tests pass nil.

import "core:fmt"
import "core:math"
import "core:mem"
import "core:slice"
import "core:time"
import "baldr:gpu"
import runa "baldr:third_party/runa"

// Corner names a corner of a rounded shape; Corners are those it keeps
// square, its other corners taking its radius (Style.square, square_corners).
Corner :: gpu.Corner
Corners :: gpu.Corners
// Pixels is how a magnified picture is sampled: `Auto` blends smooth into
// hard-edged squares between 2 and 4 device pixels a picture pixel, and
// `Smooth` / `Hard` force one of them. A builder takes it as `pixelated`
// (nothing said: Auto); it is named in a `Draw_Image` or `Draw_Canvas`.
Pixels :: gpu.Pixels

// pixels_of reads a builder's `pixelated`: nothing said is Auto, `true` is
// hard squares however far in, `false` is the smooth filter however far in.
@(private)
pixels_of :: proc(pixelated: Maybe(bool)) -> Pixels {
	v, said := pixelated.?
	if !said do return .Auto
	return .Hard if v else .Smooth
}

// Atlas_Sink is how render_prepare gives glyph atlas pages to the renderer.
// `create` makes a texture of `format` and `size` and returns its handle;
// `upload` copies a tightly packed `w × h` block of pixels (1 byte/px for
// Alpha8, 4 for RGBA8) to `(x, y)` of `page`; `picture` and `destroy` make
// and free a big (or much reduced) picture's texture of its own. Uploads are
// staged by the renderer and land before the next render, which is after
// render_prepare returns, so emitting a Glyph before its page's upload call
// is fine.
Atlas_Sink :: struct {
	user:    rawptr,
	create:  proc(user: rawptr, format: gpu.Page_Format, size: [2]u32) -> gpu.Page,
	upload:  proc(user: rawptr, page: gpu.Page, x, y, w, h: u32, pixels: []u8),
	picture: proc(user: rawptr, size: [2]u32) -> gpu.Page, // one picture's own RGBA8 texture with mip levels (gpu.picture_create); nil: pictures stay in the atlas
	destroy: proc(user: rawptr, page: gpu.Page),            // a picture's texture that is no longer wanted
}

// Page_State is the GPU side of one runa atlas page. `real` is false while
// the page only has a headless placeholder id (no sink has seen it yet);
// the first render with a sink creates it and uploads the whole page.
@(private)
Page_State :: struct {
	page: gpu.Page,
	real: bool,
}

// render_prepare appends the device-pixel commands for the whole tree to
// `out`, in z-order. `scale` is device px per logical px (<= 0 is treated as
// 1). Rect and clip edges are rounded to device pixels; radius and border
// width are scaled. Text is drawn only when the tree has a Text_Engine
// (tree_use_text_engine); atlas pages are created and their dirty regions
// uploaded through `sink`, or merely numbered when `sink` is nil. Per-frame
// scratch goes to context.temp_allocator.
render_prepare :: proc(t: ^Tree, scale: f32, sink: ^Atlas_Sink, out: ^[dynamic]gpu.Cmd, offset: [2]f32 = {}) {
	render_draw(t, draw_list(t), -offset, scale, sink, out) // `offset`: a surface sliding off its edge draws its tree moved
}

// render_popup appends the device-pixel commands of popup `n`'s surface: its
// card, with tree point `origin` at the surface's top-left.
render_popup :: proc(t: ^Tree, n: Node, origin: [2]f32, scale: f32, sink: ^Atlas_Sink, out: ^[dynamic]gpu.Cmd) {
	render_draw(t, popup_draw_list(t, n), origin, scale, sink, out)
}

@(private)
render_draw :: proc(t: ^Tree, cmds: []Draw_Cmd, origin: [2]f32, scale: f32, sink: ^Atlas_Sink, out: ^[dynamic]gpu.Cmd) {
	s := scale if scale > 0 else 1
	te := t.text
	if te != nil && !te.ok do te = nil
	if te != nil do images_begin_frame(te, sink)
	glow: Glow // behind the text and icons being drawn (Draw_Glow_Push)
	glows := make([dynamic]Glow, context.temp_allocator)
	// What can be seen, in device px: the clips pushed so far, intersected
	// as the GPU intersects them. Text uses it to skip what lies outside
	// (render_text), which a long line in an editor mostly does.
	vis := NO_CLIP
	clips := make([dynamic][4]f32, context.temp_allocator)
	for c0 in cmds {
		c := c0 if origin == {} else shifted(c0, -origin)
		switch v in c {
		case Draw_Rect:
			append(out, gpu.Quad{rect = snap_rect(v.rect, s), color = v.color, color2 = v.color2, radius = v.radius * s, border_w = v.border_w * s, border = v.border, horizontal = v.horizontal, square = v.square})
		case Draw_Shadow:
			append(out, gpu.Shadow{rect = snap_rect(v.rect, s), radius = v.radius * s, blur = v.blur * s, color = v.color, square = v.square, hole = snap_rect(v.hole, s) if v.hole.w > 0 else {}})
		case Draw_Backdrop:
			m := v.material
			append(out, gpu.Backdrop{rect = snap_rect(v.rect, s), radius = v.radius * s, blur = m.blur * s, tint = m.tint, saturation = m.saturation, noise = m.noise, square = v.square, fade = v.fade})
			if edge := m.edge; edge.a > 0 { // a 1 px line inside its outline, under the rim, fading alike
				edge.a *= 1 - clamp(v.fade, 0, 1)
				append(out, gpu.Quad{rect = snap_rect(v.rect, s), radius = v.radius * s, border_w = max(math.round(s), 1), border = edge, square = v.square})
			}
			rim := m.highlight
			rim.a *= 1 - clamp(v.fade, 0, 1) // the rim fades with the glass
			if rim.a > 0 do append(out, gpu.Highlight{rect = snap_rect(v.rect, s), radius = v.radius * s, color = rim, width = max(math.round(s), 1), square = v.square})
		case Draw_Clip_Push:
			r := snap_rect(v.rect, s)
			append(out, gpu.Clip_Push{rect = r})
			append(&clips, vis)
			vis = rect4_meet(vis, r)
		case Draw_Clip_Pop:
			append(out, gpu.Clip_Pop{})
			if len(clips) > 0 do vis = pop(&clips)
		case Draw_Glow_Push:
			append(&glows, glow)
			glow = v.glow
		case Draw_Glow_Pop:
			if len(glows) > 0 do glow = pop(&glows)
		case Draw_Text:
			if te != nil do render_text(te, v, s, sink, out, glow, vis)
		case Draw_Icon:
			if te != nil do render_icon(te, v, s, sink, out, glow)
		case Draw_Wave:
			if te != nil do render_wave(te, v, s, sink, out)
		case Draw_Line:
			// Not snapped to the pixel grid by default: a line at an angle has
			// no grid to snap to, and rounding its ends would make a series
			// wobble. `snap` is for the ones that do have a grid — a guide, a
			// crop frame's edge, the pixel grid itself — where a horizontal or
			// vertical line landing between two rows of pixels is two half-lit
			// ones instead of one hard one. Only the constant axis moves, and
			// only when the line is exactly horizontal or vertical.
			a, b := v.a * s, v.b * s
			w := max(v.width * s, 1)
			if v.snap {
				if a.y == b.y do a.y, b.y = snap_line(a.y, w), snap_line(a.y, w)
				if a.x == b.x do a.x, b.x = snap_line(a.x, w), snap_line(a.x, w)
			}
			append(out, gpu.Line{a = a, b = b, width = w, color = v.color, flat = v.flat})
		case Draw_Canvas:
			render_canvas(v, s, out)
		case Draw_Image:
			if te != nil do render_image(te, v, s, sink, out)
		case Draw_Theme_Icon:
			if te != nil do render_theme_icon(te, t, v, s, sink, out, glow)
		case Draw_Cells:
			if te != nil do term_render(t, te, v, s, sink, out)
		case Draw_Typeset:
			if te != nil do render_typeset(te, v, s, sink, out, glow)
		case Draw_Layer:
			// draw_list inlines nested layers; nothing to emit.
		}
	}
	if te != nil do atlas_flush(te, sink)
}

// NO_CLIP is "everything can be seen": a rect far larger than any surface.
@(private)
NO_CLIP :: [4]f32{-1e9, -1e9, 2e9, 2e9}

// rect4_meet is where two device-px rects (x, y, w, h) overlap, empty when
// they do not.
@(private)
rect4_meet :: proc "contextless" (a, b: [4]f32) -> [4]f32 {
	x0, y0 := max(a.x, b.x), max(a.y, b.y)
	x1, y1 := min(a.x + a.z, b.x + b.z), min(a.y + a.w, b.y + b.w)
	return {x0, y0, max(x1 - x0, 0), max(y1 - y0, 0)}
}

// snap_rect scales a logical rect and rounds its edges (not its size) to
// device pixels, so neighbouring rects stay seamless.
@(private)
snap_rect :: proc(r: Rect, s: f32) -> [4]f32 {
	x0 := math.round(r.x * s)
	y0 := math.round(r.y * s)
	x1 := math.round((r.x + r.w) * s)
	y1 := math.round((r.y + r.h) * s)
	return {x0, y0, x1 - x0, y1 - y0}
}

// snap_line puts the centre of a `w`-wide device-pixel line where its edges
// land on whole pixels: a 1 px line at 10.3 covers 9.8 to 10.8 — two rows
// lit four fifths and one fifth — and at 10.5 covers 10 to 11, which is one
// hard line. Stable under repeats: a centre already snapped stays put.
@(private)
snap_line :: proc(centre, w: f32) -> f32 {
	return math.round(centre - w * 0.5) + w * 0.5
}

// render_text lays `v` out at its logical size and wrap width (the same
// call layout measured with), then emits one Glyph per visible glyph. Pen
// positions accumulate in logical px and are scaled at use, so device
// positions are exactly the measured layout × scale. Baselines are snapped
// to device rows; x keeps quarter-pixel precision through the subpixel
// bucket the glyph was rasterised with. Only what `vis` (device px, the
// clips around it) can show is emitted: a line outside it is skipped whole,
// and within a line the glyphs left of it are walked past and the walk ends
// at its right edge (a line's pen only moves right), so a very long row
// costs what shows of it.
@(private)
render_text :: proc(te: ^Text_Engine, v: Draw_Text, s: f32, sink: ^Atlas_Sink, out: ^[dynamic]gpu.Cmd, glow := Glow{}, vis := NO_CLIP) {
	lines := text_lines(te, v.str, v.size, v.wrap_w, v.weight, v.mono, v.tab, v.italic, v.no_ligatures, v.family, v.tabular)
	if len(lines) == 0 do return
	start := len(out)
	defer glow_under(out, start, glow, s)
	px := v.size * s
	lh := text_line_height(te, v.size, v.mono, v.family)
	asc := text_ascent(te, v.size, v.mono, v.family)
	reach := px * 2 // how far a glyph's ink may stand off its pen position: an italic overhang, a wide mark
	// Turned text is laid out upright and its glyphs turned about `pos`. Off
	// a right angle a glyph is sampled between texels, so it is rasterised at
	// twice the size and drawn at half, which keeps its edges crisp.
	pivot := v.pos * s
	k := f32(1)
	vis := vis
	if v.angle != 0 {
		vis = NO_CLIP // what shows is worked out upright, and a turned line reaches elsewhere
		if r := math.mod(abs(v.angle), math.PI / 2); r > 1e-4 && math.PI / 2 - r > 1e-4 do k = 2
	}
	for line, i in lines {
		top := (v.pos.y + f32(i) * lh) * s
		if top > vis.y + vis.w || top + lh * s < vis.y do continue // the whole line is above or below what shows
		baseline := math.round((v.pos.y + asc + f32(i) * lh) * s)
		pen: f32
		switch v.align { // centre / right-align each line within the node
		case .Start:
		case .Center: pen = max((v.box_w - line.width) / 2, 0)
		case .End:    pen = max(v.box_w - line.width, 0)
		}
		for g in line.glyphs {
			if is_control_at(v.str, int(g.cluster)) { // a line break, a tab stop, a separator: nothing to draw
				pen += g.x_advance
				continue
			}
			gx := (v.pos.x + pen + g.x_offset) * s
			if gx - reach > vis.x + vis.z do break // past the right edge, and so is the rest of the line
			if gx + g.x_advance * s + reach < vis.x { // left of what shows: walked past, not looked up
				pen += g.x_advance
				continue
			}
			gy := baseline - g.y_offset * s // GPOS y placement is up-positive
			fx := math.floor(gx)
			subpx := u8(int((gx - fx) * 4)) & 3
			if slot, ok := glyph_slot(te, g.font, g.glyph_id, px * k, subpx); ok {
				ensure_pages(te, sink)
				format := runa.Atlas_Format.RGBA8 if slot.is_color else runa.Atlas_Format.Alpha8
				append(out, gpu.Glyph{
					rect  = {fx + slot.bearing.x / k, math.round(gy) + slot.bearing.y / k, f32(slot.px_size.x) / k, f32(slot.px_size.y) / k},
					uv    = slot.uv_rect,
					page  = te.pages[format][slot.page_index].page,
					color = v.color,
					angle = v.angle,
					pivot = pivot,
				})
			}
			pen += g.x_advance
		}
	}
}

// render_typeset draws a range of a Typeset's lines: a book
// page is the end of one paragraph, some whole ones and the start of
// another, so the app lays a paragraph out once and draws the lines that
// fall on this page.
//
// Unlike render_text nothing is shaped here — typeset already placed every
// glyph, in several runs at several sizes — so this is the same atlas walk
// without the layout. Each glyph is rasterised at its own run's size,
// which is what keeps a 0.70em footnote marker crisp beside 1em body text
// at any scale: the atlas slot is picked from device pixels, so a zoom
// re-rasterises rather than magnifying.
@(private)
render_typeset :: proc(te: ^Text_Engine, v: Draw_Typeset, s: f32, sink: ^Atlas_Sink, out: ^[dynamic]gpu.Cmd, glow := Glow{}) {
	ts := v.ts
	if ts == nil || len(ts.lines) == 0 do return
	lo := clamp(v.first, 0, len(ts.lines))
	hi := clamp(v.first + v.count, lo, len(ts.lines))
	if lo >= hi do return
	start := len(out)
	defer glow_under(out, start, glow, s)
	off := [2]f32{0, ts.lines[lo].rect.y} // the first line drawn sits at v.pos
	k := v.scale if v.scale > 0 else 1   // a scaling layer above us: the geometry is laid out, so it scales here
	for li in lo ..< hi {
		l := ts.lines[li]
		span := ts.spans[li]
		baseline := math.round((v.pos.y + (l.baseline - off.y) * k) * s)
		// underline and strike first, so a glyph is never drawn under its
		// own rule; each run's stretch of the line is one quad
		typeset_rules(v, ts, li, s, k, baseline, off, out)
		for gi in span[0] ..< span[0] + span[1] {
			g := ts.glyphs[gi]
			if g.blank do continue
			px := g.scale * f32(g.font.units_per_em) * k * s
			if !(px > 0) do continue
			gx := (v.pos.x + (g.pos.x - off.x) * k) * s
			gy := baseline + (g.pos.y - l.baseline) * k * s // the run's shift and the glyph's own GPOS offset
			fx := math.floor(gx)
			subpx := u8(int((gx - fx) * 4)) & 3
			if slot, ok := glyph_slot(te, g.font, g.id, px, subpx); ok {
				ensure_pages(te, sink)
				format := runa.Atlas_Format.RGBA8 if slot.is_color else runa.Atlas_Format.Alpha8
				ink := v.color
				if int(g.run) < len(ts.runs) && ts.runs[g.run].ink.a > 0 do ink = ts.runs[g.run].ink
				append(out, gpu.Glyph{
					rect  = {fx + slot.bearing.x, math.round(gy) + slot.bearing.y, f32(slot.px_size.x), f32(slot.px_size.y)},
					uv    = slot.uv_rect,
					page  = te.pages[format][slot.page_index].page,
					color = ink,
				})
			}
		}
	}
}

// typeset_rules draws one line's underlines and strikes: each run's stretch
// of the line becomes a quad, so a rule runs unbroken under a whole phrase
// rather than per glyph, and stops where the run does.
@(private)
typeset_rules :: proc(v: Draw_Typeset, ts: ^Typeset, li: int, s, k, baseline: f32, off: [2]f32, out: ^[dynamic]gpu.Cmd) {
	span := ts.spans[li]
	for gi := span[0]; gi < span[0] + span[1]; {
		run := ts.glyphs[gi].run
		r := ts.runs[run] if int(run) < len(ts.runs) else Typeset_Run{}
		x0, x1 := max(f32), min(f32)
		for gi < span[0] + span[1] && ts.glyphs[gi].run == run {
			g := ts.glyphs[gi]
			if !g.blank {
				x0, x1 = min(x0, g.x0), max(x1, g.x1)
			}
			gi += 1
		}
		if !(r.underline || r.strike) || x1 <= x0 do continue
		w := max(math.round(r.size / 14 * k * s), 1) // the face's own is not exposed; a 14 px em gives a 1 px rule
		ink := v.color
		if r.ink.a > 0 do ink = r.ink
		ax0 := math.round((v.pos.x + (x0 - off.x) * k) * s)
		ax1 := math.round((v.pos.x + (x1 - off.x) * k) * s)
		if r.underline {
			y := math.round(baseline + max(r.size * 0.12, 1) * k * s)
			append(out, gpu.Quad{rect = {ax0, y, ax1 - ax0, w}, color = ink})
		}
		if r.strike {
			y := math.round(baseline - r.size * 0.26 * k * s)
			append(out, gpu.Quad{rect = {ax0, y, ax1 - ax0, w}, color = ink})
		}
	}
}

// render_icon draws an icon from the atlas, rasterising it on first use at
// this device size (Lucide's 24-unit box, 2-unit stroke, scaled).
@(private)
render_icon :: proc(te: ^Text_Engine, v: Draw_Icon, s: f32, sink: ^Atlas_Sink, out: ^[dynamic]gpu.Cmd, glow := Glow{}) {
	px := int(math.round(v.size * s))
	if px <= 0 || v.icon == .None || v.color.a <= 0 do return
	slot, ok := icon_slot(te, v.icon, icon_raster_px(px)) // a nearby size from the ladder, scaled on the way down
	if !ok do return
	ensure_pages(te, sink)
	append(out, gpu.Glyph{
		rect  = {math.round(v.pos.x * s), math.round(v.pos.y * s), f32(px), f32(px)},
		uv    = slot.uv_rect,
		page  = te.pages[runa.Atlas_Format.Alpha8][slot.page_index].page,
		color = v.color,
	})
	glow_under(out, len(out) - 1, glow, s)
}

// glow_under puts a glow behind the glyphs appended since `start`, every
// glow before the first glyph so no halo lies over a neighbouring glyph. A
// glow fades with its glyph.
@(private)
glow_under :: proc(out: ^[dynamic]gpu.Cmd, start: int, glow: Glow, s: f32) {
	n := len(out) - start
	if n <= 0 || glow.radius <= 0 || glow.color.a <= 0 do return
	passes := max(glow.passes, 1) // one blurred copy is thin: an outline that carries text over a wallpaper is laid down several times
	resize(out, len(out) + n * passes)
	copy(out[start + n * passes:], out[start:start + n]) // the glyphs go last, over their halo
	radius := min(glow.radius, GLOW_MAX_RADIUS) * s
	for i in 0 ..< n {
		g, is_glyph := out[start + n * passes + i].(gpu.Glyph)
		if !is_glyph {
			for p in 0 ..< passes do out[start + p * n + i] = gpu.Clip_Pop{} // never: text and icons append glyphs only
			continue
		}
		c := glow.color
		c.a *= g.color.a
		for p in 0 ..< passes {
			out[start + p * n + i] = gpu.Glow{rect = g.rect, uv = g.uv, page = g.page, color = c, radius = radius, angle = g.angle, pivot = g.pivot}
		}
	}
}

// render_image draws a picture, uploading it on first use: from a texture of
// its own when it is bigger than an atlas page or drawn at more than
// PICTURE_MINIFY of its pixels to a screen pixel (full resolution, and
// smooth when drawn smaller through its mip levels), else from the RGBA
// atlas. `source` picks the part of it drawn — a change of it
// is a repaint, never an upload.
@(private)
render_image :: proc(te: ^Text_Engine, v: Draw_Image, s: f32, sink: ^Atlas_Sink, out: ^[dynamic]gpu.Cmd) {
	if v.color.a <= 0 do return
	img := v.img // read through a local: it is dropped below if the Image went away, and nothing after reads the command's copy
	if img != nil && !image_adds_up(img) {
		// The app freed the Image between the paint and now: draw the copy
		// the atlas kept, by the identity the paint wrote down, and read
		// nothing through the pointer.
		if !te.picture_said {
			te.picture_said = true
			fmt.eprintfln("baldr: a picture went away between the paint and the frame (read %d x %d, %#x x %#x): call image_forget(ui, img) before freeing an Image.", img.width, img.height, u64(img.width), u64(img.height))
		}
		img = nil
	}
	size := v.size
	if img != nil do size = {img.width, img.height}
	src, shown := image_source(v.source, size)
	if !shown do return
	rect := v.rect
	switch v.fit {
	case .Contain: rect = image_contain_rect_f(rect, src.w, src.h)
	case .Cover:   src = image_cover_source(src, rect)
	case .Stretch:
	}
	if rect.w <= 0 || rect.h <= 0 do return
	id := img.id if img != nil else v.id
	if img != nil && id == 0 {
		img.id = image_new_id()
		id = img.id
	}
	page: gpu.Page
	uv := [4]f32{0, 0, 1, 1} // the whole picture, in whatever holds it
	ok: bool
	limit := ATLAS_PAGE_SIZE - 2
	reduced := max(src.w / (rect.w * s), src.h / (rect.h * s)) // picture pixels to a screen pixel
	if p, has := te.pictures[id]; has && !p.failed {
		page, ok = picture_page(te, id, img, sink)
	} else if !has && img != nil && (size.x > limit || size.y > limit || reduced > PICTURE_MINIFY || img.touched > 0) { // a touched one is patched in place
		page, ok = picture_page(te, id, img, sink)
	}
	if !ok {
		slot: runa.Atlas_Slot
		if img != nil {
			slot, ok = image_slot(te, img)
		} else if e, hit := te.images[Image_Key{id = v.id, version = v.version}]; hit && e.ok { // a leaving node's picture: the copy the atlas kept
			slot, ok = e.slot, true
			te.image_frame_px += int(e.slot.px_size.x) * int(e.slot.px_size.y)
		}
		if !ok do return
		ensure_pages(te, sink)
		page = te.image_pages[slot.page_index].page
		uv = slot.uv_rect
	}
	// the source's part of what holds the picture
	uw, uh := uv[2] - uv[0], uv[3] - uv[1]
	fw, fh := f32(size.x), f32(size.y)
	append(out, gpu.Image{
		rect   = snap_rect(rect, s),
		uv     = {uv[0] + uw * src.x / fw, uv[1] + uh * src.y / fh, uv[0] + uw * (src.x + src.w) / fw, uv[1] + uh * (src.y + src.h) / fh},
		page   = page,
		radius = v.radius * s,
		square = v.square,
		color  = v.color,
		pixels = v.pixels,
		pixel_grid = v.pixel_grid,
	})
}

// PICTURE_MINIFY: a picture drawn at more of its pixels than this to a screen
// pixel gets a texture of its own with mip levels; bilinear sampling from the
// atlas skips texels past two and shimmers.
PICTURE_MINIFY :: 2

// PICTURE_IDLE_BYTES is how much of the pictures with textures of their own
// that have not been drawn for PICTURE_IDLE_MS stays on the GPU (a viewer's
// last few photos, to go back to) before the oldest go.
PICTURE_IDLE_BYTES :: 192 * 1024 * 1024
PICTURE_IDLE_MS :: 2000

// Picture_Page is a picture's texture of its own. A new version of the
// picture is uploaded into it again (or into a new one when its size
// changed), so a picture that changes keeps one texture, not one a version.
@(private)
Picture_Page :: struct {
	page:    gpu.Page,
	version: u64,
	size:    [2]int,
	bytes:   int,       // with its mip levels
	drawn:   time.Tick, // last drawn
	real:    bool,      // made through a sink (false: a headless placeholder id)
	touched: u64,       // the Image's `touched` as last uploaded (image_touch)
	failed:  bool,      // the renderer could not make it: the atlas draws the picture
}

// picture_page returns the texture of its own that picture `id` draws from,
// making or refreshing it from `img` (nil: a leaving node's picture, drawn
// as it was). False sends the picture to the atlas: no sink that makes
// pictures, or the renderer refused this one (remembered, so it is not asked
// every frame).
@(private)
picture_page :: proc(te: ^Text_Engine, id: u64, img: ^Image, sink: ^Atlas_Sink) -> (gpu.Page, bool) {
	p, has := &te.pictures[id]
	if !has {
		if !image_adds_up(img) do return 0, false
		te.pictures[id] = {}
		p = &te.pictures[id]
	}
	stale := img != nil && (!p.real || p.version != img.version || p.page == 0)
	if !stale && img != nil && p.touched != img.touched { // the same version changed in part: that part again (image_touch)
		d := img.dirty
		if p.real && sink != nil && sink.upload != nil && d[2] > d[0] && d[3] > d[1] && image_adds_up(img) {
			w, h := d[2] - d[0], d[3] - d[1]
			rows := make([]u8, w * h * 4, context.temp_allocator)
			for y in 0 ..< h do copy(rows[y * w * 4:][:w * 4], img.pixels[((d[1] + y) * img.width + d[0]) * 4:][:w * 4])
			sink.upload(sink.user, p.page, u32(d[0]), u32(d[1]), u32(w), u32(h), rows)
		}
		p.touched = img.touched
		img.dirty = {}
	}
	if stale && !(p.page != 0 && !p.real && sink == nil) { // a headless placeholder stays one until a sink comes
		if !image_adds_up(img) do return 0, false // an Image that does not add up is never read past
		w, h := img.width, img.height
		if p.real && p.size != {w, h} { // a new size: a new texture
			if sink != nil && sink.destroy != nil do sink.destroy(sink.user, p.page)
			p.page, p.real = 0, false
		}
		switch {
		case sink == nil:
			te.next_page += 1
			p.page = gpu.Page(te.next_page)
		case sink.picture == nil || sink.upload == nil:
			delete_key(&te.pictures, id)
			return 0, false
		case:
			if !p.real do p.page = sink.picture(sink.user, {u32(w), u32(h)})
			if p.page == 0 {
				// Say so: the picture falls back to the atlas, which scales
				// anything over a page down by a whole factor, and a soft
				// picture would otherwise come with nothing to say why.
				// Once per picture, because `failed` is remembered.
				if !p.failed {
					fmt.eprintfln(
						"baldr: picture %dx%d is larger than this device allows, so it is being scaled down to fit the atlas and will look soft.%s",
						w, h,
						" An animation packs its frames into one texture: give image_from_rgba_frames a smaller max_side, or fewer frames." if img.frames > 1 else "",
					)
				}
				p.failed = true
				return 0, false
			}
			p.real = true
			sink.upload(sink.user, p.page, 0, 0, u32(w), u32(h), img.pixels[:w * h * 4])
		}
		p.version, p.size = img.version, {w, h}
		p.touched = img.touched // a whole upload covers any part touched too
		img.dirty = {}
		p.bytes = w * h * 4 * 4 / 3
	}
	p.drawn = time.tick_now()
	return p.page, p.page != 0
}

// pictures_evict lets the textures of pictures not drawn for PICTURE_IDLE_MS
// go, the longest-idle first, until what is left of them fits the budget.
@(private)
pictures_evict :: proc(te: ^Text_Engine, sink: ^Atlas_Sink) {
	Idle :: struct { id: u64, drawn: time.Tick, bytes: int }
	idle := make([dynamic]Idle, context.temp_allocator)
	total := 0
	now := time.tick_now()
	for id, p in te.pictures {
		if p.failed || time.duration_milliseconds(time.tick_diff(p.drawn, now)) < PICTURE_IDLE_MS do continue
		append(&idle, Idle{id, p.drawn, p.bytes})
		total += p.bytes
	}
	if total <= te.picture_budget do return
	slice.sort_by(idle[:], proc(a, b: Idle) -> bool { return a.drawn._nsec < b.drawn._nsec })
	for e in idle {
		if total <= te.picture_budget do break
		p := te.pictures[e.id]
		if p.real && sink != nil && sink.destroy != nil do sink.destroy(sink.user, p.page)
		delete_key(&te.pictures, e.id)
		total -= e.bytes
	}
}

// image_source is the part of a `size` picture `source` names, clamped to
// it: all of it for {}, nothing (false) when it lies outside.
@(private)
image_source :: proc(source: Rect, size: [2]int) -> (Rect, bool) {
	if size.x <= 0 || size.y <= 0 do return {}, false
	full := Rect{0, 0, f32(size.x), f32(size.y)}
	if source == {} do return full, true
	x0, y0 := max(source.x, 0), max(source.y, 0)
	x1, y1 := min(source.x + source.w, full.w), min(source.y + source.h, full.h)
	if x1 <= x0 || y1 <= y0 do return {}, false
	return {x0, y0, x1 - x0, y1 - y0}, true
}

// image_cover_source trims `src` centrally to the box's aspect (the Cover fit).
@(private)
image_cover_source :: proc(src, box: Rect) -> Rect {
	if box.w <= 0 || box.h <= 0 || src.w <= 0 || src.h <= 0 do return src
	r := src
	want := box.w / box.h
	if src.w / src.h > want { // wider than the box: trim the sides
		r.w = src.h * want
		r.x += (src.w - r.w) / 2
	} else {
		r.h = src.w / want
		r.y += (src.h - r.h) / 2
	}
	return r
}

// image_slot uploads `img` (downscaled by an integer factor when it does
// not fit an atlas page) once per version and returns its slot.
image_slot :: proc(te: ^Text_Engine, img: ^Image) -> (slot: runa.Atlas_Slot, ok: bool) {
	if !image_adds_up(img) do return // an Image that does not add up is skipped, never read past (the sides are checked before the multiply, which a freed one overflows)
	if img.id == 0 do img.id = image_new_id()
	key := Image_Key{id = img.id, version = img.version}
	if e, hit := te.images[key]; hit {
		te.image_frame_px += int(e.slot.px_size.x) * int(e.slot.px_size.y)
		return e.slot, e.ok
	}
	w, h := img.width, img.height
	pixels := img.pixels
	limit := ATLAS_PAGE_SIZE - 2
	if w > limit || h > limit {
		f := (max(w, h) + limit - 1) / limit
		nw, nh := max(w / f, 1), max(h / f, 1)
		small := make([]u8, nw * nh * 4, context.temp_allocator)
		for y in 0 ..< nh do for x in 0 ..< nw {
			acc: [4]int
			count := 0
			for yy in y * f ..< min((y + 1) * f, h) do for xx in x * f ..< min((x + 1) * f, w) {
				p := pixels[(yy * w + xx) * 4:]
				acc += {int(p[0]), int(p[1]), int(p[2]), int(p[3])}
				count += 1
			}
			for c in 0 ..< 4 do small[(y * nw + x) * 4 + c] = u8(acc[c] / max(count, 1))
		}
		w, h, pixels = nw, nh, small
	}
	sl, err := runa.atlas_pack_rgba(&te.image_atlas, pixels, u16(w), u16(h), {0, 0})
	if err != .None {
		te.images_full = true // not remembered as a failure: once the atlas starts over it packs
		return
	}
	if len(te.image_atlas.pages_color) > IMAGE_ATLAS_PAGES do te.images_full = true
	te.images[key] = Glyph_Entry{slot = sl, ok = true}
	te.image_frame_px += w * h
	return sl, true
}

// IMAGE_ATLAS_PAGES is how many pages (4 MB each) pictures fill before the
// ones not drawn lately make way.
IMAGE_ATLAS_PAGES :: 4

// images_begin_frame starts a frame's pictures: textures of their own not
// drawn lately go past their budget, and a picture atlas that filled last
// frame starts over, unless the pictures on screen alone need most of the
// room (then it grows instead of re-uploading every frame).
@(private)
images_begin_frame :: proc(te: ^Text_Engine, sink: ^Atlas_Sink) {
	pictures_evict(te, sink)
	drawn := te.image_frame_px
	te.image_frame_px = 0
	if !te.images_full do return
	te.images_full = false
	if drawn > IMAGE_ATLAS_PAGES * ATLAS_PAGE_SIZE * ATLAS_PAGE_SIZE * 3 / 4 do return
	images_start_over(te)
}

// images_start_over empties the picture atlas: every page is cleared and
// re-uploaded blank (no old picture bleeds into a new neighbour), and the
// pictures drawn from here on pack again, the ones on screen first.
@(private)
images_start_over :: proc(te: ^Text_Engine) {
	clear(&te.images)
	for &p in te.image_atlas.pages_color {
		clear(&p.shelves)
		mem.zero_slice(p.pixels)
		p.is_dirty = true
		p.dirty_min = {}
		p.dirty_max = {p.width, p.height}
	}
}

// render_wave tiles the squiggle bitmap (one WAVE_PERIOD cycle, rasterised
// at this device scale) along `v.width`, trimming the last tile's uv.
@(private)
render_wave :: proc(te: ^Text_Engine, v: Draw_Wave, s: f32, sink: ^Atlas_Sink, out: ^[dynamic]gpu.Cmd) {
	if v.width <= 0 || v.color.a <= 0 do return
	slot, ok := wave_slot(te, s)
	if !ok do return
	ensure_pages(te, sink)
	page := te.pages[runa.Atlas_Format.Alpha8][slot.page_index].page
	tw := f32(slot.px_size.x)
	th := f32(slot.px_size.y)
	x := math.round(v.pos.x * s)
	y := math.round(v.pos.y * s)
	end := x + v.width * s
	for x < end {
		w := min(tw, end - x)
		uv := slot.uv_rect
		if w < tw do uv[2] = uv[0] + (uv[2] - uv[0]) * (w / tw)
		append(out, gpu.Glyph{rect = {x, y, w, th}, uv = uv, page = page, color = v.color})
		x += tw
	}
}

// wave_slot rasterises one cycle of the squiggle at device scale `s`
// (cached per scale): a quadratic-bezier sine, 1 logical px thick, that
// tiles seamlessly because the path runs a cycle past each edge.
@(private)
wave_slot :: proc(te: ^Text_Engine, s: f32) -> (slot: runa.Atlas_Slot, ok: bool) {
	px := int(math.round(WAVE_PERIOD * s))
	if px <= 0 || px > 256 do return
	key := Icon_Key{icon = .None, px = u16(px)} // .None is never an icon: it is the wave
	if e, hit := te.icons[key]; hit do return e.slot, e.ok
	h := int(math.round(WAVE_H * s))
	mid := WAVE_H / 2
	// centreline 0.5..2.5 (a quadratic's peak is 0.75·end + 0.5·control)
	up := f32(-0.5)
	zero := f32(0) // every argument must be a float: an int prints as %!g and truncates the path
	path := fmt.tprintf("M%g %g Q%g %g %g %g T%g %g T%g %g T%g %g T%g %g T%g %g",
		-WAVE_PERIOD, mid, -WAVE_PERIOD * 0.75, up, -WAVE_PERIOD / 2, mid,
		zero, mid, WAVE_PERIOD / 2, mid, WAVE_PERIOD, mid, WAVE_PERIOD * 1.5, mid, WAVE_PERIOD * 2, mid)
	paths := svg_flatten(path, s, context.temp_allocator)
	bitmap := svg_raster(paths, px, max(h, 1), max(s, 1), context.temp_allocator)
	sl, err := runa.atlas_pack_alpha(&te.atlas, bitmap, u16(px), u16(max(h, 1)), {0, 0})
	ok = err == .None
	if ok do slot = sl
	te.icons[key] = Glyph_Entry{slot = slot, ok = ok}
	return
}

// icon_raster_px is the size an icon is rasterised at for a wanted size:
// exact up to 32 px, then the next rung of a ladder that grows by a
// quarter each step (40, 48, 64, 80, 96, 128, 160, 192, 256), so a
// continuous zoom rasterises a handful of sizes instead of every one on
// the way and the atlas holds a ladder rather than a staircase. The
// bitmap is scaled down by up to a fifth on draw, which line art does
// not show.
@(private)
icon_raster_px :: proc(px: int) -> int {
	if px <= 32 do return px
	for rung in ICON_LADDER do if px <= rung do return rung
	return 256
}

@(private)
ICON_LADDER := [?]int{40, 48, 64, 80, 96, 128, 160, 192, 256}

// icon_slot returns the atlas slot of `which` at `px` device pixels,
// rasterising and packing it on first use.
icon_slot :: proc(te: ^Text_Engine, which: Icon, px: int) -> (slot: runa.Atlas_Slot, ok: bool) {
	if px <= 0 || px > 256 do return
	key := Icon_Key{icon = which, px = u16(px)}
	if e, hit := te.icons[key]; hit do return e.slot, e.ok
	t0 := time.tick_now()
	scale := f32(px) / 24
	paths := svg_flatten(ICON_PATHS[which], scale, context.temp_allocator)
	bitmap := svg_raster(paths, px, px, 2 * scale, context.temp_allocator)
	s, err := runa.atlas_pack_alpha(&te.atlas, bitmap, u16(px), u16(px), {0, 0})
	ok = err == .None
	if ok do slot = s
	te.icons[key] = Glyph_Entry{slot = slot, ok = ok}
	te.icons_made += 1
	te.icon_ms += time.duration_milliseconds(time.tick_since(t0))
	return
}

// ensure_pages gives every runa atlas page a gpu.Page. With a sink, pages
// that are new (or only had a placeholder id) are created and marked wholly
// dirty so the next flush uploads their full contents; without one they get
// sequential placeholder ids, exactly as tests expect.
@(private)
ensure_pages :: proc(te: ^Text_Engine, sink: ^Atlas_Sink) {
	for format in runa.Atlas_Format do ensure_page_states(te, atlas_pages(te, format), &te.pages[format], format, sink)
	ensure_page_states(te, te.image_atlas.pages_color[:], &te.image_pages, .RGBA8, sink)
}

@(private)
ensure_page_states :: proc(te: ^Text_Engine, src: []runa.Atlas_Page, states: ^[dynamic]Page_State, format: runa.Atlas_Format, sink: ^Atlas_Sink) {
	for len(states) < len(src) do append(states, Page_State{})
	for &st, i in states {
		if st.real do continue
		if sink != nil && sink.create != nil {
			p := &src[i]
			st.page = sink.create(sink.user, gpu_format(format), {u32(p.width), u32(p.height)})
			st.real = true
			p.is_dirty = true
			p.dirty_min = {}
			p.dirty_max = {p.width, p.height}
		} else if st.page == 0 {
			te.next_page += 1
			st.page = gpu.Page(te.next_page)
		}
	}
}

// atlas_flush uploads every page's dirty rectangle through the sink as a
// tightly packed block and clears runa's dirty tracking. Without a sink the
// dirty state is just cleared: the whole page is re-marked when a sink
// first creates it, so nothing is lost.
@(private)
atlas_flush :: proc(te: ^Text_Engine, sink: ^Atlas_Sink) {
	t0 := time.tick_now()
	defer te.flush_ms += time.duration_milliseconds(time.tick_since(t0))
	ensure_pages(te, sink)
	for format in runa.Atlas_Format do flush_page_states(atlas_pages(te, format), te.pages[format][:], 4 if format == .RGBA8 else 1, sink)
	flush_page_states(te.image_atlas.pages_color[:], te.image_pages[:], 4, sink)
}

@(private)
flush_page_states :: proc(pages: []runa.Atlas_Page, states: []Page_State, bpp: int, sink: ^Atlas_Sink) {
	for &p, i in pages {
		if !p.is_dirty do continue
		st := states[i]
		x, y := u32(p.dirty_min.x), u32(p.dirty_min.y)
		w := u32(p.dirty_max.x) - x if p.dirty_max.x > p.dirty_min.x else 0
		h := u32(p.dirty_max.y) - y if p.dirty_max.y > p.dirty_min.y else 0
		if sink != nil && sink.upload != nil && st.real && w > 0 && h > 0 {
			row := int(w) * bpp
			stride := int(p.width) * bpp
			if x == 0 && int(w) == int(p.width) {
				// whole rows (a new page is one): the page's own bytes are
				// already packed that way, and the upload copies them at once
				sink.upload(sink.user, st.page, x, y, w, h, p.pixels[int(y) * stride:][:int(h) * stride])
			} else {
				buf := make([]u8, int(h) * row, context.temp_allocator)
				for r in 0 ..< int(h) {
					src := (int(y) + r) * stride + int(x) * bpp
					copy(buf[r * row:][:row], p.pixels[src:][:row])
				}
				sink.upload(sink.user, st.page, x, y, w, h, buf)
			}
		}
		p.is_dirty = false
		p.dirty_min = {}
		p.dirty_max = {}
	}
}

@(private)
atlas_pages :: proc(te: ^Text_Engine, format: runa.Atlas_Format) -> []runa.Atlas_Page {
	return te.atlas.pages_color[:] if format == .RGBA8 else te.atlas.pages_alpha[:]
}

@(private)
gpu_format :: proc "contextless" (f: runa.Atlas_Format) -> gpu.Page_Format {
	return .RGBA8 if f == .RGBA8 else .Alpha8
}
