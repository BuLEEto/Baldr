package baldr

// A camera keeps a photo as its sensor saw it and records how to turn it
// for showing (EXIF orientation): a phone held upright saves a landscape
// picture marked "turn a quarter clockwise". Shown as stored, every
// portrait photo lies on its side, so a JPEG is turned on loading, as
// browsers and photo viewers do.

import "core:slice"

// jpeg_orientation is the EXIF orientation a JPEG records, 1 to 8, or 1 (as
// stored) when it records none or the record cannot be read. Only the
// headers before the first scan are read.
@(private)
jpeg_orientation :: proc(d: []u8) -> int {
	for i := 2; i + 4 <= len(d); {
		if d[i] != 0xFF do return 1
		m := d[i + 1]
		switch {
		case m == 0xFF:                                        i += 1 // fill
		case m == 0xD8 || m == 0x01 || (m >= 0xD0 && m <= 0xD7): i += 2 // no length
		case m == 0xDA || m == 0xD9:                           return 1 // the scan: no headers after it
		case:
			n := int(d[i + 2]) << 8 | int(d[i + 3])
			if n < 2 || i + 2 + n > len(d) do return 1
			seg := d[i + 4:i + 2 + n]
			if m == 0xE1 && len(seg) >= 6 && string(seg[:6]) == "Exif\x00\x00" {
				if o := exif_orientation(seg[6:]); o != 0 do return o
			}
			i += 2 + n
		}
	}
	return 1
}

// exif_orientation reads tag 0x0112 from the first directory of an EXIF
// block (a TIFF header and what follows): 1 to 8, or 0 when it is not there.
@(private)
exif_orientation :: proc(t: []u8) -> int {
	if len(t) < 8 do return 0
	le: bool
	switch string(t[:2]) {
	case "II": le = true
	case "MM": le = false
	case:      return 0
	}
	at16 :: proc(t: []u8, i: int, le: bool) -> int {
		if le do return int(t[i]) | int(t[i + 1]) << 8
		return int(t[i]) << 8 | int(t[i + 1])
	}
	at32 :: proc(t: []u8, i: int, le: bool) -> int {
		if le do return int(t[i]) | int(t[i + 1]) << 8 | int(t[i + 2]) << 16 | int(t[i + 3]) << 24
		return int(t[i]) << 24 | int(t[i + 1]) << 16 | int(t[i + 2]) << 8 | int(t[i + 3])
	}
	if at16(t, 2, le) != 42 do return 0
	ifd := at32(t, 4, le)
	if ifd < 8 || ifd + 2 > len(t) do return 0
	for k in 0 ..< at16(t, ifd, le) {
		e := ifd + 2 + k * 12
		if e + 12 > len(t) do return 0
		if at16(t, e, le) != 0x0112 do continue
		// a SHORT, whose value sits in the first two bytes of its field
		if at16(t, e + 2, le) != 3 do return 0
		v := at16(t, e + 8, le)
		return v if v >= 1 && v <= 8 else 0
	}
	return 0
}

// image_orient turns a still picture from how it was stored to how it is
// shown, by its EXIF orientation: 2 mirrors it, 3 turns it half round, 4
// flips it, 5 to 8 turn it a quarter (and mirror it, for 5 and 7), which
// swaps its sides.
@(private)
image_orient :: proc(img: ^Image, o: int) {
	if o <= 1 || o > 8 || img.frames > 1 do return
	w, h := img.width, img.height
	if len(img.pixels) < w * h * 4 do return
	ow, oh := w, h
	if o >= 5 do ow, oh = h, w
	out := make([]u8, w * h * 4, img.allocator)
	src := slice.reinterpret([]u32, img.pixels[:w * h * 4])
	dst := slice.reinterpret([]u32, out)
	for y in 0 ..< oh {
		for x in 0 ..< ow {
			sx, sy: int
			switch o {
			case 2: sx, sy = w - 1 - x, y
			case 3: sx, sy = w - 1 - x, h - 1 - y
			case 4: sx, sy = x, h - 1 - y
			case 5: sx, sy = y, x
			case 6: sx, sy = y, h - 1 - x
			case 7: sx, sy = w - 1 - y, h - 1 - x
			case 8: sx, sy = w - 1 - y, x
			}
			dst[y * ow + x] = src[sy * w + sx]
		}
	}
	if img.secret do secret_scrub_bytes(img.pixels)
	delete(img.pixels, img.allocator)
	img.pixels, img.width, img.height = out, ow, oh
}
