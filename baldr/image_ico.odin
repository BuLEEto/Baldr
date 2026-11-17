package baldr

// ICO and CUR: Windows icons and cursors, and a website's favicon. One file
// holds the same picture at several sizes; the largest is decoded. Each is
// a PNG, or a BMP without its file header whose rows are followed by a
// 1-bit mask, which is all the transparency the older kinds have.

import "base:runtime"

@(private)
ico_load :: proc(d: []u8, allocator: runtime.Allocator, max_pixels: int) -> (img: Image, ok: bool) {
	le16 :: proc(d: []u8, i: int) -> int { return int(d[i]) | int(d[i + 1]) << 8 }
	le32 :: proc(d: []u8, i: int) -> int { return int(u32(d[i]) | u32(d[i + 1]) << 8 | u32(d[i + 2]) << 16 | u32(d[i + 3]) << 24) }
	if len(d) < 6 || le16(d, 0) != 0 || (le16(d, 2) != 1 && le16(d, 2) != 2) do return
	n := le16(d, 4)
	if n == 0 || 6 + n * 16 > len(d) do return
	best, best_area, best_bpp := -1, 0, 0
	for i in 0 ..< n {
		e := 6 + i * 16
		w := int(d[e]) if d[e] != 0 else 256 // 0 means 256
		h := int(d[e + 1]) if d[e + 1] != 0 else 256
		bpp := le16(d, e + 6)
		size, off := le32(d, e + 8), le32(d, e + 12)
		if size <= 0 || off < 6 || off + size > len(d) do continue
		if w * h > best_area || (w * h == best_area && bpp > best_bpp) {
			best, best_area, best_bpp = i, w * h, bpp
		}
	}
	if best < 0 do return
	e := 6 + best * 16
	blob := d[le32(d, e + 12):][:le32(d, e + 8)]
	if len(blob) >= 8 && string(blob[:8]) == "\x89PNG\r\n\x1a\n" do return picture_decode("image/png", blob, allocator, max_pixels)
	return ico_dib(blob, allocator, max_pixels)
}

// ico_dib decodes an icon's BMP: 32 bits with alpha, or 24, 8, 4 or 1 bits
// with the mask after them saying which pixels are see-through.
@(private = "file")
ico_dib :: proc(b: []u8, allocator: runtime.Allocator, max_pixels: int) -> (img: Image, ok: bool) {
	le16 :: proc(d: []u8, i: int) -> int { return int(d[i]) | int(d[i + 1]) << 8 }
	le32 :: proc(d: []u8, i: int) -> int { return int(i32(u32(d[i]) | u32(d[i + 1]) << 8 | u32(d[i + 2]) << 16 | u32(d[i + 3]) << 24)) }
	if len(b) < 40 do return
	hsize := le32(b, 0)
	if hsize < 40 || hsize > len(b) do return
	w, h2 := le32(b, 4), le32(b, 8)
	h := abs(h2) / 2 // the rows and the mask together
	top_down := h2 < 0
	bpp, compression := le16(b, 14), le32(b, 16)
	if w <= 0 || h <= 0 || w > IMAGE_MAX_SIDE || h > IMAGE_MAX_SIDE || w * h > max_pixels do return
	if compression != 0 && !(compression == 3 && bpp == 32) do return // plain rows only (32-bit masks are the usual BGRA)
	pal_off := hsize
	colors := 0
	switch bpp {
	case 1, 4, 8:
		colors = le32(b, 32)
		if colors <= 0 || colors > 1 << uint(bpp) do colors = 1 << uint(bpp)
	case 24, 32:
	case:
		return
	}
	if compression == 3 do pal_off += 12 // the three channel masks after a plain header
	stride := (w * bpp + 31) / 32 * 4
	rows := pal_off + colors * 4
	mask := rows + stride * h
	mstride := (w + 31) / 32 * 4
	if mask > len(b) do return
	has_mask := mask + mstride * h <= len(b)
	out := make([]u8, w * h * 4, allocator)
	any_alpha := false
	for y in 0 ..< h {
		src := b[rows + (y if top_down else h - 1 - y) * stride:] // bottom row first, as a BMP is
		dst := out[y * w * 4:]
		for x in 0 ..< w {
			r, g, bl, a: u8 = 0, 0, 0, 255
			switch bpp {
			case 32:
				bl, g, r, a = src[x * 4], src[x * 4 + 1], src[x * 4 + 2], src[x * 4 + 3]
				if a != 0 do any_alpha = true
			case 24:
				bl, g, r = src[x * 3], src[x * 3 + 1], src[x * 3 + 2]
			case:
				per := 8 / bpp
				packed := src[x / per]
				shift := uint(8 - bpp - (x % per) * bpp)
				i := int(packed >> shift) & (1 << uint(bpp) - 1)
				if i < colors {
					p := b[pal_off + i * 4:]
					bl, g, r = p[0], p[1], p[2]
				}
			}
			dst[x * 4], dst[x * 4 + 1], dst[x * 4 + 2], dst[x * 4 + 3] = r, g, bl, a
		}
	}
	// A 32-bit icon carries its own alpha; anything else, or one whose alpha
	// is all zero (an old writer's), takes it from the mask.
	if (bpp != 32 || !any_alpha) && has_mask {
		for y in 0 ..< h {
			m := b[mask + (y if top_down else h - 1 - y) * mstride:]
			for x in 0 ..< w do out[(y * w + x) * 4 + 3] = 0 if m[x / 8] & (0x80 >> uint(x % 8)) != 0 else 255
		}
	}
	return Image{width = w, height = h, pixels = out, version = 1, allocator = allocator}, true
}
