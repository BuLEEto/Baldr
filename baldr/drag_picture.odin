package baldr

// The picture a drag carries once the desktop has it.
//
// Inside the window the ghost is a node in the overlay, drawn by the
// renderer. Outside, the compositor draws the drag's picture from a surface
// we hand over, so it needs pixels made before the drag leaves, and there is
// no GPU pass to make them with, nor a way to read one back. This file draws
// the chip on the CPU from the same pieces as the ghost's chip: the theme's
// surface colours, the source's icon, its name, and the count for a
// selection.
//
// It is the chip, not the mirror: the in-window ghost's faded copy of the
// source (`paint_drag_mirror`) is an arbitrary subtree and cannot be drawn
// here. For a row that is an icon and a name the two look nearly the same.
//
// Everything is in device pixels: a 2× window hands over a picture twice
// the size with `scale` 2, so it is sharp at its logical size.

@(require) import "core:math"
import "base:runtime"
import runa "baldr:third_party/runa"

// DRAG_PICTURE_MAX_W is the widest the chip is drawn, in logical pixels —
// the same ceiling the ghost's chip has, so a long file name is cut in the
// same place inside the window and out of it.
DRAG_PICTURE_MAX_W :: f32(280)

// DRAG_PICTURE_MAX_PX is the most device pixels a side may have. A picture
// is small by nature; this is here so a silly scale cannot ask for a
// hundred megabytes of shared memory.
DRAG_PICTURE_MAX_PX :: i32(2048)

// DRAG_PICTURE_PIC_MAX is the largest a source's own picture is drawn on
// the chip, in logical pixels: big enough to recognise a thumbnail, small
// enough that the chip stays a label beside the pointer.
DRAG_PICTURE_PIC_MAX :: f32(48)

// drag_picture_make draws the picture for a drag leaving the window, as
// straight-alpha RGBA8 in `allocator`'s memory, with the offset that puts
// it where the in-window ghost sat. Not ok (and nothing allocated) without
// a text engine, for a drag with no name or icon to show, or when the
// picture would be bigger than DRAG_PICTURE_MAX_PX a side.
//
// The pixels are the caller's to free. The backend copies what it keeps
// (`Drag_Icon`), so they can go as soon as the hand-over returns.
@(private)
drag_picture_make :: proc(t: ^Tree, dg: ^Drag_State, scale: f32, allocator: runtime.Allocator) -> (pic: Drag_Icon, ok: bool) {
	te := t.text
	if te == nil || !te.ok do return {}, false
	s := scale if scale > 0 else 1
	th := &t.theme
	have_icon := dg.icon != .None || dg.theme_icon != "" || dg.picture != nil
	if len(dg.name) == 0 && !have_icon do return {}, false

	lab := text_style(th, .Label)
	cap := text_style(th, .Caption)
	pad_x, pad_y := th.space[.md] * s, th.space[.xs] * s
	gap := th.space[.xs] * s
	// The source's own picture where it has one, at its in-window size
	// capped at DRAG_PICTURE_PIC_MAX: a row's icon stays small, a tile's
	// comes over nearly whole.
	icon_side := ICON_SIZE * s if have_icon else 0
	if dg.picture != nil {
		icon_side = clamp(dg.picture_box, ICON_SIZE, DRAG_PICTURE_PIC_MAX) * s
	}

	// The name, shaped once at the size it is drawn at, and the room left
	// for it after the padding, the icon and the badge.
	lab_family := role_family(th, .Label) // the in-window chip is a Label text, in the theme's family for those
	name_lines := text_lines(te, dg.name, lab.size * s, 0, lab.weight, family = lab_family) if len(dg.name) > 0 else nil
	name_w := name_lines[0].width if len(name_lines) > 0 else 0
	text_h := text_line_height(te, lab.size * s, family = lab_family) if len(name_lines) > 0 else 0

	badge_w, badge_h: f32
	badge_lines: []runa.Line
	if dg.count > 1 {
		badge_lines = text_lines(te, drag_count_text(dg.count), cap.size * s, 0, cap.weight)
		if len(badge_lines) > 0 {
			pad := th.space[.xxs] * s
			badge_h = math.ceil(text_line_height(te, cap.size * s) + pad * 2)
			badge_w = math.ceil(max(badge_lines[0].width + 8 * s + pad * 2, badge_h))
		}
	}

	// Width: everything it would like, cut to the ceiling, which the name
	// gives way to — the icon, the count and the padding are all fixed.
	fixed := pad_x * 2 + icon_side + badge_w + (gap if badge_w > 0 else 0)
	room := max(DRAG_PICTURE_MAX_W * s - fixed - (gap if icon_side > 0 else 0), 0)
	draw_w := min(name_w, room)
	if draw_w > 0 && icon_side > 0 do fixed += gap // …and only then is there a gap to leave
	size := [2]i32{
		i32(math.ceil(fixed + draw_w)),
		i32(math.ceil(max(icon_side, text_h, badge_h) + pad_y * 2)),
	}
	if size.x <= 0 || size.y <= 0 do return {}, false
	if size.x > DRAG_PICTURE_MAX_PX || size.y > DRAG_PICTURE_MAX_PX do return {}, false

	dc := drag_canvas_make(size, allocator)
	defer delete(dc.px, allocator)

	// The chip itself: the ghost's own surface colour, border and radius,
	// at the ghost's opacity. A rounded rectangle rather than a shadow —
	// the compositor's icon has no backdrop to cast one on.
	body := Rect{0, 0, f32(size.x), f32(size.y)}
	bg := th.color.surface_high
	bg.a *= 0.94
	drag_rrect(&dc, body, th.radius.md * s, bg, {}, 0)
	drag_rrect(&dc, body, th.radius.md * s, {}, th.color.outline_variant, max(math.round(s), 1))

	x := pad_x
	if icon_side > 0 {
		drag_icon_into(&dc, t, dg, {x, (f32(size.y) - icon_side) / 2}, icon_side, th.color.accent_text)
		x += icon_side
		if draw_w > 0 do x += gap
	}
	if draw_w > 0 && len(name_lines) > 0 {
		base := math.round((f32(size.y) - text_h) / 2 + text_ascent(te, lab.size * s, family = lab_family))
		drag_text_into(&dc, te, name_lines[0], {x, base}, draw_w, lab.size * s, th.color.on_surface, lab.weight, lab_family)
		x += draw_w
	}
	if badge_w > 0 {
		x += gap
		bx, by := x, (f32(size.y) - badge_h) / 2
		drag_rrect(&dc, {bx, by, badge_w, badge_h}, badge_h / 2, th.color.primary, {}, 0)
		bl := badge_lines[0]
		base := math.round(by + (badge_h - text_line_height(te, cap.size * s)) / 2 + text_ascent(te, cap.size * s))
		drag_text_into(&dc, te, bl, {bx + (badge_w - bl.width) / 2, base}, bl.width, cap.size * s, th.color.on_primary)
	}

	pixels := drag_canvas_rgba(&dc, allocator)
	off := DRAG_GHOST_OFFSET * s
	return Drag_Icon{
		pixels = pixels,
		size   = size,
		offset = {i32(math.round(off.x)), i32(math.round(off.y))},
		scale  = s,
	}, true
}

// ------------------------------------------------------------- the canvas

// Drag_Canvas is a small RGBA surface held as **premultiplied linear**
// f32: premultiplied so src-over is one multiply and one add, linear
// because `Color` is, and f32 because a chip is a few thousand pixels and
// the clarity is worth more than the bytes. `drag_canvas_rgba` encodes it
// to the straight sRGB bytes a backend wants.
@(private)
Drag_Canvas :: struct {
	px:   []f32,
	size: [2]i32,
}

@(private)
drag_canvas_make :: proc(size: [2]i32, allocator: runtime.Allocator) -> Drag_Canvas {
	return {px = make([]f32, int(size.x) * int(size.y) * 4, allocator), size = size}
}

// drag_blend puts `c` over the pixel at (x, y) with coverage `cov`.
@(private)
drag_blend :: proc(dc: ^Drag_Canvas, x, y: int, c: Color, cov: f32) {
	if x < 0 || y < 0 || x >= int(dc.size.x) || y >= int(dc.size.y) do return
	a := c.a * clamp(cov, 0, 1)
	if a <= 0 do return
	i := (y * int(dc.size.x) + x) * 4
	keep := 1 - a
	dc.px[i + 0] = c.r * a + dc.px[i + 0] * keep
	dc.px[i + 1] = c.g * a + dc.px[i + 1] * keep
	dc.px[i + 2] = c.b * a + dc.px[i + 2] * keep
	dc.px[i + 3] = a + dc.px[i + 3] * keep
}

// drag_canvas_rgba un-premultiplies, encodes to sRGB and returns the bytes
// a `Drag_Icon` carries: RGBA8, straight alpha, row-major.
@(private)
drag_canvas_rgba :: proc(dc: ^Drag_Canvas, allocator: runtime.Allocator) -> []u8 {
	out := make([]u8, int(dc.size.x) * int(dc.size.y) * 4, allocator)
	for i in 0 ..< int(dc.size.x) * int(dc.size.y) {
		a := dc.px[i * 4 + 3]
		if a <= 0 do continue
		inv := 1 / a
		for k in 0 ..< 3 {
			out[i * 4 + k] = u8(clamp(linear_to_srgb(clamp(dc.px[i * 4 + k] * inv, 0, 1)), 0, 1) * 255 + 0.5)
		}
		out[i * 4 + 3] = u8(clamp(a, 0, 1) * 255 + 0.5)
	}
	return out
}

// drag_rrect fills a rounded rectangle, or strokes one of width `bw`
// inside its edge. Coverage comes from the distance to the shape, which
// gives the same antialiased corner the renderer's quad does without
// needing the renderer.
@(private)
drag_rrect :: proc(dc: ^Drag_Canvas, r: Rect, radius: f32, fill: Color, border: Color, bw: f32) {
	if r.w <= 0 || r.h <= 0 do return
	rad := clamp(radius, 0, min(r.w, r.h) / 2)
	x0, y0 := int(math.floor(r.x)), int(math.floor(r.y))
	x1, y1 := int(math.ceil(r.x + r.w)), int(math.ceil(r.y + r.h))
	for y in y0 ..< y1 {
		for x in x0 ..< x1 {
			d := drag_rrect_sd([2]f32{f32(x) + 0.5, f32(y) + 0.5}, r, rad)
			if fill.a > 0 do drag_blend(dc, x, y, fill, clamp(0.5 - d, 0, 1))
			if border.a > 0 && bw > 0 {
				// a ring of width bw just inside the edge
				ring := clamp(0.5 - d, 0, 1) - clamp(0.5 - (d + bw), 0, 1)
				drag_blend(dc, x, y, border, ring)
			}
		}
	}
}

// drag_rrect_sd is the signed distance from `p` to a rounded rectangle:
// negative inside, in pixels, so a coverage of 0.5 - d antialiases an edge
// over one pixel.
@(private)
drag_rrect_sd :: proc(p: [2]f32, r: Rect, rad: f32) -> f32 {
	half := [2]f32{r.w / 2, r.h / 2}
	c := [2]f32{r.x + half.x, r.y + half.y}
	q := [2]f32{abs(p.x - c.x) - (half.x - rad), abs(p.y - c.y) - (half.y - rad)}
	outside := [2]f32{max(q.x, 0), max(q.y, 0)}
	return math.sqrt(outside.x * outside.x + outside.y * outside.y) + min(max(q.x, q.y), 0) - rad
}

// ---------------------------------------------------------------- the ink

// drag_text_into draws one shaped line at `pen` (x, and y at the
// baseline), stopping at `room` and ending in an ellipsis where the line
// does not fit — the chip's own `ellipsis = .End`. Glyphs are cut from the
// end of the shaped line, which for a right-to-left name is its beginning;
// the in-window chip's clip does the same, so the two at least agree.
@(private)
drag_text_into :: proc(dc: ^Drag_Canvas, te: ^Text_Engine, line: runa.Line, pen: [2]f32, room: f32, px: f32, ink: Color, weight := Font_Weight.Regular, family: Family_Id = 0) {
	cut := line.width > room + 0.5
	ell := text_lines(te, "…", px, 0, weight, family = family) if cut else nil
	ell_w := ell[0].width if len(ell) > 0 else 0
	limit := room - ell_w if cut else room

	x := pen.x
	for g in line.glyphs {
		if x + g.x_advance > pen.x + limit + 0.01 do break
		drag_glyph_into(dc, te, g, {x, pen.y}, px, ink)
		x += g.x_advance
	}
	if cut && len(ell) > 0 {
		for g in ell[0].glyphs {
			drag_glyph_into(dc, te, g, {x, pen.y}, px, ink)
			x += g.x_advance
		}
	}
}

// drag_glyph_into blits one glyph's coverage from the atlas, placed the
// way `render_text` places it: the pen plus the glyph's own offsets, the
// bearing from its slot, and the subpixel phase the slot was rasterised
// for.
@(private)
drag_glyph_into :: proc(dc: ^Drag_Canvas, te: ^Text_Engine, g: runa.Paragraph_Glyph, pen: [2]f32, px: f32, ink: Color) {
	gx := pen.x + g.x_offset
	gy := pen.y - g.y_offset
	fx := math.floor(gx)
	subpx := u8(int((gx - fx) * 4)) & 3
	slot, ok := glyph_slot(te, g.font, g.glyph_id, px, subpx)
	if !ok do return
	drag_slot_into(dc, te, slot, {fx + slot.bearing.x, math.round(gy) + slot.bearing.y}, ink)
}

// drag_icon_into draws whichever icon the drag has: the desktop theme's
// (as it is drawn in the window, colour or mask), else the Lucide one.
@(private)
drag_icon_into :: proc(dc: ^Drag_Canvas, t: ^Tree, dg: ^Drag_State, at: [2]f32, side: f32, ink: Color) {
	te := t.text
	px := int(math.round(side))
	if px <= 0 do return
	if dg.picture != nil && image_adds_up(dg.picture) {
		drag_image_into(dc, dg.picture, at, side)
		return
	}
	if dg.theme_icon != "" {
		v := Draw_Theme_Icon{rect = {at.x, at.y, side, side}, name = dg.theme_icon, dir = dg.theme_icon_dir, color = ink, fallback = dg.icon}
		if slot, format, ok, _ := theme_icon_slot(te, t, v, px, 1, px); ok {
			drag_slot_into(dc, te, slot, at, ink, colour = format == .RGBA8)
			return
		}
	}
	if dg.icon == .None do return
	if slot, ok := icon_slot(te, dg.icon, icon_raster_px(px)); ok {
		// the ladder may have rasterised it larger: scale down as the
		// renderer does rather than drawing it oversized
		drag_slot_into(dc, te, slot, at, ink, box = side)
	}
}

// drag_image_into blits an app's `Image` into a square of side `side`,
// scaled to fit and centred, sampled nearest-neighbour. Frame 0 of an
// animation, which is also the frame that stands under reduce-motion.
//
// A crop (`Picture.source`) is not honoured: a cropped tile comes over
// whole and a little smaller, which loses nothing and saves carrying the
// crop through the drag.
@(private)
drag_image_into :: proc(dc: ^Drag_Canvas, img: ^Image, at: [2]f32, side: f32) {
	sw, sh := img.width, img.height
	if img.frames > 1 && img.cols > 0 { // the grid's first cell
		sw = img.width / img.cols
		sh = img.height / ((img.frames + img.cols - 1) / img.cols)
	}
	if sw <= 0 || sh <= 0 do return
	k := min(side / f32(sw), side / f32(sh)) // fit, never distort
	dw, dh := int(math.round(f32(sw) * k)), int(math.round(f32(sh) * k))
	if dw <= 0 || dh <= 0 do return
	ox := int(math.round(at.x + (side - f32(dw)) / 2))
	oy := int(math.round(at.y + (side - f32(dh)) / 2))
	for dy in 0 ..< dh {
		sy := (dy * sh) / dh
		for dx in 0 ..< dw {
			sx := (dx * sw) / dw
			i := (sy * img.width + sx) * 4
			if i + 3 >= len(img.pixels) do continue
			a := f32(img.pixels[i + 3]) / 255
			if a <= 0 do continue
			c := Color{
				srgb_to_linear(f32(img.pixels[i + 0]) / 255),
				srgb_to_linear(f32(img.pixels[i + 1]) / 255),
				srgb_to_linear(f32(img.pixels[i + 2]) / 255),
				a,
			}
			drag_blend(dc, ox + dx, oy + dy, c, 1)
		}
	}
}

// drag_slot_into blits one atlas slot at `at`. `colour` reads the slot's
// own RGBA (a colour emoji, a themed icon with colour of its own) and
// `ink` is the colour an alpha slot is drawn in. `box`, when given, is the
// side the slot is scaled to fit, sampled nearest-neighbour — the renderer
// scales the same slots the same way.
@(private)
drag_slot_into :: proc(dc: ^Drag_Canvas, te: ^Text_Engine, slot: runa.Atlas_Slot, at: [2]f32, ink: Color, colour := false, box: f32 = 0) {
	format := runa.Atlas_Format.RGBA8 if colour || slot.is_color else runa.Atlas_Format.Alpha8
	pages := atlas_pages(te, format)
	if int(slot.page_index) >= len(pages) do return
	p := &pages[slot.page_index]
	if len(p.pixels) == 0 || p.width == 0 || p.height == 0 do return
	sw, sh := int(slot.px_size.x), int(slot.px_size.y)
	if sw <= 0 || sh <= 0 do return
	ox := int(slot.uv_rect[0] * f32(p.width) + 0.5)
	oy := int(slot.uv_rect[1] * f32(p.height) + 0.5)
	bpp := 4 if format == .RGBA8 else 1
	stride := int(p.width) * bpp

	dw, dh := sw, sh
	if box > 0 {
		dw, dh = int(math.round(box)), int(math.round(box))
	}
	if dw <= 0 || dh <= 0 do return
	for dy in 0 ..< dh {
		sy := oy + (dy * sh) / dh
		if sy < 0 || sy >= int(p.height) do continue
		for dx in 0 ..< dw {
			sx := ox + (dx * sw) / dw
			if sx < 0 || sx >= int(p.width) do continue
			i := sy * stride + sx * bpp
			if i + bpp > len(p.pixels) do continue
			x, y := int(math.round(at.x)) + dx, int(math.round(at.y)) + dy
			if format == .Alpha8 {
				drag_blend(dc, x, y, ink, f32(p.pixels[i]) / 255)
			} else {
				a := f32(p.pixels[i + 3]) / 255
				if a <= 0 do continue
				// the atlas holds colour slots premultiplied in sRGB:
				// un-premultiply, decode, and blend with the ink's alpha
				c := Color{
					srgb_to_linear(clamp(f32(p.pixels[i + 0]) / 255 / a, 0, 1)),
					srgb_to_linear(clamp(f32(p.pixels[i + 1]) / 255 / a, 0, 1)),
					srgb_to_linear(clamp(f32(p.pixels[i + 2]) / 255 / a, 0, 1)),
					a * ink.a,
				}
				drag_blend(dc, x, y, c, 1)
			}
		}
	}
}

// drag_count_text is a small whole number as text in the frame's memory:
// the badge's count, which fmt would otherwise be imported for.
@(private)
drag_count_text :: proc(n: int) -> string {
	if n <= 0 do return "0"
	buf: [20]u8
	i := len(buf)
	v := n
	for v > 0 {
		i -= 1
		buf[i] = u8('0' + v % 10)
		v /= 10
	}
	out := make([]u8, len(buf) - i, context.temp_allocator)
	copy(out, buf[i:])
	return string(out)
}
