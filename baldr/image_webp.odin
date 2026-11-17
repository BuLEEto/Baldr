package baldr

// WebP pictures, still and animated, lossy and lossless, in Odin. This file
// is the container (RFC 9649): the RIFF chunks, the alpha a lossy picture
// carries beside its colour, and an animation's frames drawn onto its
// canvas. The two codecs are image_webp_vp8.odin (lossy) and
// image_webp_vp8l.odin (lossless).
//
// An animation is composed as libwebp composes it, to the bit, which is
// what browsers and Android show: a transparent canvas (the file's
// background colour is a hint the format lets viewers ignore, and they do),
// each frame blended over what is there or written over it, and its
// rectangle cleared afterwards when it says so. Two of libwebp's rules
// change the rounding, so they are kept: a frame that starts afresh (the
// first, one covering the canvas with nothing to blend, or one after the
// whole canvas was cleared) is drawn onto an empty canvas without blending,
// and where the frame before was cleared the new pixels are copied as they
// are rather than blended over nothing.

import "base:runtime"

// WEBP_MAX_WORK is how many pixels all of an animation's frames may decode:
// half GIF_MAX_WORK, since a lossy pixel costs more. Frames that claim much
// and hold little (the cheap way to make a lot of work) then take about a
// quarter of a second; past that, time follows the bytes actually sent. An
// animation past it is cut short there rather than refused.
@(private)
WEBP_MAX_WORK :: 1 << 27

@(private = "file")
Webp_Chunk :: struct {
	tag:    string,
	data:   []u8,
	padded: []u8, // with the pad byte after an odd size, where the file has it
}

@(private = "file")
webp_le24 :: proc(d: []u8, i: int) -> int { return int(d[i]) | int(d[i + 1]) << 8 | int(d[i + 2]) << 16 }

// webp_chunk reads the chunk at `pos^` and steps past it and its padding;
// false at the end, or when the chunk runs past the data.
@(private = "file")
webp_chunk :: proc(d: []u8, pos: ^int) -> (c: Webp_Chunk, ok: bool) {
	p := pos^
	if p + 8 > len(d) do return
	size := int(u32(d[p + 4]) | u32(d[p + 5]) << 8 | u32(d[p + 6]) << 16 | u32(d[p + 7]) << 24)
	if size > len(d) - p - 8 do return
	c = {tag = string(d[p:p + 4]), data = d[p + 8:p + 8 + size], padded = d[p + 8:min(p + 8 + size + (size & 1), len(d))]}
	pos^ = p + 8 + size + (size & 1)
	return c, true
}

@(private)
webp_load :: proc(d: []u8, allocator: runtime.Allocator, max_pixels: int) -> (img: Image, ok: bool) {
	if len(d) < 20 || string(d[:4]) != "RIFF" || string(d[8:12]) != "WEBP" do return
	riff := int(u32(d[4]) | u32(d[5]) << 8 | u32(d[6]) << 16 | u32(d[7]) << 24)
	body := d[12:min(len(d), 8 + max(riff, 4))]
	pos := 0
	first := webp_chunk(body, &pos) or_return
	switch first.tag {
	case "VP8 ", "VP8L":
		w, h, rgba := webp_frame(nil, first, max_pixels, allocator) or_return
		return Image{width = w, height = h, pixels = rgba, version = 1, allocator = allocator}, true
	case "VP8X":
		if len(first.data) < 10 do return
		cw, ch := webp_le24(first.data, 4) + 1, webp_le24(first.data, 7) + 1
		if cw * ch > max_pixels do return
		if first.data[0] & 0x02 != 0 do return webp_animation(body, pos, cw, ch, allocator, max_pixels)
		// a still picture: its alpha, if any, then its bitstream; the rest (a
		// colour profile, EXIF, XMP, anything unknown) is not needed to draw it
		alph: []u8
		for {
			c := webp_chunk(body, &pos) or_return
			switch c.tag {
			case "ALPH":
				alph = c.data
			case "VP8 ", "VP8L":
				w, h, rgba := webp_frame(alph, c, max_pixels, allocator) or_return
				if w != cw || h != ch { // the canvas and the picture must agree
					delete(rgba, allocator)
					return
				}
				return Image{width = w, height = h, pixels = rgba, version = 1, allocator = allocator}, true
			}
		}
	}
	return
}

// webp_frame decodes one bitstream to RGBA8, with a lossy one's alpha
// applied from its ALPH chunk.
@(private = "file")
webp_frame :: proc(alph: []u8, bits: Webp_Chunk, max_pixels: int, allocator: runtime.Allocator) -> (w, h: int, rgba: []u8, ok: bool) {
	if bits.tag == "VP8L" do return vp8l_decode(bits.data, max_pixels, allocator)
	// libwebp lets a lossy picture's last partition run on into the pad
	// byte, so a file cut short there still shows, as it does in browsers
	w, h, rgba = vp8_decode(bits.padded, max_pixels, allocator) or_return
	if alph != nil && !webp_alpha(alph, w, h, rgba, max_pixels) {
		delete(rgba, allocator)
		return 0, 0, nil, false
	}
	return w, h, rgba, true
}

// webp_alpha fills a lossy picture's alpha from its ALPH chunk: raw or
// losslessly coded values, then the filter they were stored through undone.
@(private = "file")
webp_alpha :: proc(a: []u8, w, h: int, rgba: []u8, max_pixels: int) -> bool {
	if len(a) < 1 do return false
	method := a[0] & 3
	filter := a[0] >> 2 & 3
	vals: []u8
	switch method {
	case 0:
		if len(a) - 1 < w * h do return false
		vals = a[1:1 + w * h]
	case 1:
		ok: bool
		vals, ok = vp8l_decode_alpha(a[1:], w, h, max_pixels, context.temp_allocator)
		if !ok || len(vals) < w * h do return false
	case:
		return false
	}
	// Each value was stored as its difference from a guess made from the
	// values already undone: left, above, or the gradient of the two.
	out := rgba
	at :: #force_inline proc(out: []u8, w, x, y: int) -> int { return int(out[(y * w + x) * 4 + 3]) }
	for y in 0 ..< h {
		for x in 0 ..< w {
			guess := 0
			switch {
			case x == 0 && y == 0:
			case filter == 0:
			case filter == 1: guess = at(out, w, x - 1, y) if x > 0 else at(out, w, x, y - 1)
			case filter == 2: guess = at(out, w, x, y - 1) if y > 0 else at(out, w, x - 1, y)
			case y == 0:      guess = at(out, w, x - 1, y)
			case x == 0:      guess = at(out, w, x, y - 1)
			case:             guess = clamp(at(out, w, x - 1, y) + at(out, w, x, y - 1) - at(out, w, x - 1, y - 1), 0, 255)
			}
			out[(y * w + x) * 4 + 3] = u8((guess + int(vals[y * w + x])) & 255)
		}
	}
	return true
}

@(private = "file")
Webp_Frame :: struct {
	x, y, w, h:  int,
	duration_ms: int,
	no_blend:    bool, // written over the canvas rather than blended onto it
	dispose:     bool, // its rectangle cleared once it has been shown
	alpha:       bool, // its bitstream says it has alpha
	data:        []u8, // its own chunks: an ALPH, then VP8 or VP8L
}

// webp_animation draws an animated WebP's frames onto its canvas, keeping
// what fits the grid (see GIF's twin, gif_load).
@(private = "file")
webp_animation :: proc(body: []u8, start, cw, ch: int, allocator: runtime.Allocator, max_pixels: int) -> (img: Image, ok: bool) {
	frames := make([dynamic]Webp_Frame, context.temp_allocator)
	pos := start
	work := 0
	for len(frames) < GIF_MAX_FRAMES {
		c := webp_chunk(body, &pos) or_break
		if c.tag != "ANMF" do continue // ANIM, metadata, unknown chunks
		if len(c.data) < 16 do break
		f := Webp_Frame{
			x = webp_le24(c.data, 0) * 2, y = webp_le24(c.data, 3) * 2,
			w = webp_le24(c.data, 6) + 1, h = webp_le24(c.data, 9) + 1,
			duration_ms = webp_le24(c.data, 12),
			no_blend = c.data[15] & 0x02 != 0, dispose = c.data[15] & 0x01 != 0,
			data = c.data[16:],
		}
		if f.x + f.w > cw || f.y + f.h > ch do break // a frame must lie on its canvas
		work += f.w * f.h
		if work > WEBP_MAX_WORK do break
		append(&frames, f)
	}
	n := len(frames)
	if n == 0 do return

	grid: Anim_Grid
	animated := n > 1 && anim_grid_begin(&grid, cw, ch, n, allocator)
	if !animated do n = 1 // one frame, or frames too big for any grid: the first, honestly
	canvas := make([]u8, cw * ch * 4, allocator)
	shown := 0
	was_fresh := false
	for &f, i in frames[:n] {
		alph: []u8
		bits: Webp_Chunk
		p := 0
		for bits.tag == "" {
			c := webp_chunk(f.data, &p) or_break
			switch c.tag {
			case "ALPH":         alph = c.data
			case "VP8 ", "VP8L": bits = c
			}
		}
		if bits.tag == "" do break
		// a lossless frame's header says whether it has alpha; a lossy one
		// has it when an ALPH chunk comes with it
		f.alpha = alph != nil if bits.tag == "VP8 " else len(bits.data) >= 5 && bits.data[4] & 0x10 != 0
		whole :: proc(f: ^Webp_Frame, cw, ch: int) -> bool { return f.w == cw && f.h == ch }
		prev := &frames[i - 1] if i > 0 else nil
		fresh := i == 0 || ((!f.alpha || f.no_blend) && whole(&f, cw, ch)) || (prev.dispose && (whole(prev, cw, ch) || was_fresh))
		w, h, rgba, fok := webp_frame(alph, bits, max_pixels, allocator)
		if !fok do break
		if w != f.w || h != f.h {
			delete(rgba, allocator)
			break
		}
		if fresh {
			for &b in canvas do b = 0
		} else if prev.dispose {
			webp_clear(canvas, cw, prev)
		}
		webp_put(canvas, cw, &f, rgba, nil if fresh || !prev.dispose else prev, fresh)
		delete(rgba, allocator)
		was_fresh = fresh
		shown += 1
		if animated do anim_grid_frame(&grid, i, canvas, f.duration_ms)
	}
	if shown == 0 {
		delete(canvas, allocator)
		if animated do anim_grid_free(&grid)
		return
	}
	if !animated do return Image{width = cw, height = ch, pixels = canvas, version = 1, allocator = allocator}, true
	delete(canvas, allocator)
	if shown < n do anim_grid_cut(&grid) // a frame that would not decode ends the animation there
	return anim_grid_end(&grid), true
}

// webp_clear makes a frame's rectangle transparent again.
@(private = "file")
webp_clear :: proc(canvas: []u8, cw: int, f: ^Webp_Frame) {
	for y in f.y ..< f.y + f.h {
		row := canvas[(y * cw + f.x) * 4:][:f.w * 4]
		for &b in row do b = 0
	}
}

// webp_put draws a decoded frame onto the canvas: written over it, or
// blended onto it with libwebp's integer arithmetic for the format's
// non-premultiplied "over", so a frame comes out as browsers show it.
// Inside `cleared` (the frame before's rectangle, when it was cleared) the
// pixels are copied as they are, as libwebp does.
@(private = "file")
webp_put :: proc(canvas: []u8, cw: int, f: ^Webp_Frame, rgba: []u8, cleared: ^Webp_Frame, fresh: bool) {
	for y in 0 ..< f.h {
		src := rgba[y * f.w * 4:][:f.w * 4]
		dst := canvas[((f.y + y) * cw + f.x) * 4:][:f.w * 4]
		if f.no_blend || fresh {
			copy(dst, src)
			continue
		}
		cy := f.y + y
		for x in 0 ..< f.w {
			s, d := src[x * 4:][:4], dst[x * 4:][:4]
			if cleared != nil && cy >= cleared.y && cy < cleared.y + cleared.h && f.x + x >= cleared.x && f.x + x < cleared.x + cleared.w {
				copy(d, s)
				continue
			}
			sa := u32(s[3])
			if sa == 0 do continue
			if sa == 255 {
				copy(d, s)
				continue
			}
			da := (u32(d[3]) * (256 - sa)) >> 8
			ba := sa + da
			scale := (u32(1) << 24) / ba
			for c in 0 ..< 3 do d[c] = u8(((u32(s[c]) * sa + u32(d[c]) * da) * scale) >> 24)
			d[3] = u8(ba)
		}
	}
}
