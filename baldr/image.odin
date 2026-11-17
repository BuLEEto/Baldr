package baldr

// Image is an app-owned raster picture (RGBA8, sRGB) decoded once and drawn
// by `image` nodes or inside buttons. It is uploaded the first time it is
// drawn at any size and stays valid until image_destroy: into the picture
// atlas, or, when it is bigger than an atlas page (1022 px an edge) or drawn
// at under half its size, into a texture of its own with mip levels, up to
// the device's limit (16384 px on most). Change the pixels and bump
// `version` to have it re-uploaded. Pictures come and go freely: the
// renderer knows each by an identity given on its first draw (not its
// address, so a new picture where an old one was freed is never mistaken for
// it), and the pictures not drawn lately make way for new ones.

import "core:fmt"
import "core:sync"
import "base:runtime"
import "core:image"
import "core:image/png"

// Image_Fit says what happens when the box's aspect differs from the
// picture's (or its `source`'s): Cover crops the picture centrally to fill
// the box (avatars, thumbnails); Stretch distorts it to fit; Contain shows
// all of it, letterboxed.
Image_Fit :: enum u8 { Cover, Stretch, Contain }

Image :: struct {
	width, height: int,
	pixels:        []u8, // RGBA8, row-major, owned
	// An animation: `frames` laid out in a grid of `cols` columns inside
	// `pixels`, so a frame is a source rectangle of one texture uploaded
	// once. 1 (or 0) frames is a still picture. A grid, not a column,
	// because a column overflows the GPU's texture limit (70 frames of
	// 480x270 stacked are 18,900 px tall; as a grid, 3,360 x 2,700).
	frames:        int,
	cols:          int,   // frames across; rows is ceil(frames / cols)
	delays:        []u16, // ms per frame, len == frames; owned with the pixels
	// The pixels are a secret: a QR code of a key, a picture decrypted in
	// memory. `image_destroy` overwrites them before freeing.
	secret:        bool,
	version:       u64,
	allocator:     runtime.Allocator,
	id:            u64,  // the atlas's name for it, given on its first draw (0 = not drawn yet); image_destroy clears it
	dirty:         [4]int, // image_touch: x0, y0, x1, y1 changed since it was last drawn (empty: x1 <= x0)
	touched:       u64,  // image_touch: how many times; a touched picture is drawn from a texture of its own
}

// IMAGE_MAX_SIDE is the largest side a picture can have: a million pixels,
// far past any camera and far short of where the arithmetic goes wrong. It
// is checked before the multiply, because `width * height * 4` of two
// pointer-sized sides overflows and an overflowed comparison passes.
@(private)
IMAGE_MAX_SIDE :: 1 << 20

// image_sides_ok is the weaker question layout asks: could these be a
// picture's sides? It reads nothing else, so a picture sized but not decoded
// yet still reserves its room.
@(private)
image_sides_ok :: proc(img: ^Image) -> bool {
	if img == nil || img.width <= 0 || img.height <= 0 do return false
	return img.width <= IMAGE_MAX_SIDE && img.height <= IMAGE_MAX_SIDE
}

// image_adds_up says `img` is a picture whose sides and pixels agree: sides
// that could be true, and room for width x height RGBA8 pixels. Everything
// that reads an app-owned Image asks this first, because the app may have
// freed it and a freed Image's fields are whatever the allocator wrote. It
// is a net, not a guarantee: freed memory that still looks like a picture
// passes. `image_forget` is what makes freeing in `update` correct.
@(private)
image_adds_up :: proc(img: ^Image) -> bool {
	if img == nil || img.pixels == nil do return false
	if img.width <= 0 || img.height <= 0 do return false
	if img.width > IMAGE_MAX_SIDE || img.height > IMAGE_MAX_SIDE do return false
	return len(img.pixels) >= img.width * img.height * 4
}

// image_touch says pixels `x, y, w, h` of `img` changed, where bumping
// `version` says all of them did: only that part is uploaded again and only
// the mip levels over it rebuilt, so a brush dab on a 4K canvas costs its
// few thousand pixels, not the whole picture. Touches add up
// until the picture is next drawn; an image node showing it paints again
// when the view is next built. A touched picture is drawn from a texture of
// its own from then on.
image_touch :: proc(img: ^Image, x, y, w, h: int) {
	if img == nil || w <= 0 || h <= 0 do return
	x0, y0 := clamp(x, 0, img.width), clamp(y, 0, img.height)
	x1, y1 := clamp(x + w, 0, img.width), clamp(y + h, 0, img.height)
	if x1 <= x0 || y1 <= y0 do return
	d := &img.dirty
	if d[2] <= d[0] || d[3] <= d[1] {
		d^ = {x0, y0, x1, y1}
	} else {
		d^ = {min(d[0], x0), min(d[1], y0), max(d[2], x1), max(d[3], y1)}
	}
	img.touched += 1
}

// image_load decodes a PNG, JPEG, GIF, WebP, BMP, ICO, QOI, TGA, netpbm or SVG file's bytes,
// telling which from the bytes themselves, into an Image in `allocator` (the
// caller's: image_destroy it). Any channel count and 8- or 16-bit depth are
// converted to RGBA8; a JPEG is turned the way its camera recorded it
// should be shown (EXIF orientation); an animated GIF or WebP becomes an
// animation the toolkit plays; an SVG is drawn at its own size. Unknown or malformed
// bytes give false, and so does a picture whose header declares more than
// `max_pixels`, refused before anything is allocated for it: a few kilobytes
// can claim gigabytes, which is how a received picture takes an app down.
// Odin's core decoders do the work: pure Odin, no C.
image_load :: proc(data: []u8, allocator := context.allocator, max_pixels := IMAGE_LOAD_MAX_PIXELS) -> (img: Image, ok: bool) {
	return picture_decode(image_kind(data), data, allocator, max_pixels)
}

// IMAGE_LOAD_MAX_PIXELS is how many pixels image_load and a pasted picture
// accept by default: 128 million, a 100-megapixel camera's photo and some
// room, 512 MB once decoded. Pass `max_pixels` to image_load for more, or
// for less where pictures come from strangers.
IMAGE_LOAD_MAX_PIXELS :: 128 * 1024 * 1024

// image_declared_size reads the width and height a picture's header claims,
// without decoding it; `ok` is false when the header says nothing readable
// (the decoder then refuses the bytes itself).
@(private)
image_declared_size :: proc(mime: string, d: []u8) -> (w, h: int, ok: bool) {
	be16 :: proc(d: []u8, i: int) -> int { return int(d[i]) << 8 | int(d[i + 1]) }
	be32 :: proc(d: []u8, i: int) -> int { return int(d[i]) << 24 | int(d[i + 1]) << 16 | int(d[i + 2]) << 8 | int(d[i + 3]) }
	le16 :: proc(d: []u8, i: int) -> int { return int(d[i]) | int(d[i + 1]) << 8 }
	le32 :: proc(d: []u8, i: int) -> int { return int(i32(u32(d[i]) | u32(d[i + 1]) << 8 | u32(d[i + 2]) << 16 | u32(d[i + 3]) << 24)) }
	switch mime {
	case "image/png":
		if len(d) >= 24 do return be32(d, 16), be32(d, 20), true
	case "image/qoi", "image/x-qoi":
		if len(d) >= 12 do return be32(d, 4), be32(d, 8), true
	case "image/gif":
		if len(d) >= 10 do return le16(d, 6), le16(d, 8), true
	case "image/webp":
		// the extended header's canvas, else the one bitstream's own size
		if len(d) < 30 do return
		switch string(d[12:16]) {
		case "VP8X": return 1 + (int(d[24]) | int(d[25]) << 8 | int(d[26]) << 16), 1 + (int(d[27]) | int(d[28]) << 8 | int(d[29]) << 16), true
		case "VP8 ": return le16(d, 26) & 0x3fff, le16(d, 28) & 0x3fff, true
		case "VP8L":
			v := le32(d, 21)
			return 1 + v & 0x3fff, 1 + (v >> 14) & 0x3fff, true
		}
	case "image/tga", "image/x-tga", "image/x-targa":
		if len(d) >= 16 do return le16(d, 12), le16(d, 14), true
	case "image/bmp", "image/x-bmp", "image/x-ms-bmp":
		if len(d) < 26 do return
		if le32(d, 14) == 12 do return le16(d, 18), le16(d, 20), true // the old core header
		return abs(le32(d, 18)), abs(le32(d, 22)), true // negative height: rows top down
	case "image/jpeg", "image/jpg", "image/pjpeg":
		// the frame header (SOF0–SOF15 but DHT, JPG and DAC) holds the size
		for i := 2; i + 9 <= len(d); {
			if d[i] != 0xFF {
				i += 1
				continue
			}
			m := d[i + 1]
			if m == 0xFF || m == 0x01 || (m >= 0xD0 && m <= 0xD9) {
				i += 2
				continue
			}
			if m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC do return be16(d, i + 7), be16(d, i + 5), true
			i += 2 + be16(d, i + 2)
		}
	case "image/x-portable-anymap", "image/x-portable-pixmap", "image/x-portable-graymap", "image/x-portable-bitmap":
		// "P6 <w> <h> …", whitespace and # comments between
		nums: [2]int
		got := 0
		for i := 2; i < len(d) && got < 2; {
			c := d[i]
			if c == '#' {
				for i < len(d) && d[i] != '\n' do i += 1
			} else if c >= '0' && c <= '9' {
				v := 0
				for i < len(d) && d[i] >= '0' && d[i] <= '9' {
					v = v * 10 + int(d[i] - '0')
					if v > IMAGE_MAX_SIDE do v = IMAGE_MAX_SIDE + 1 // enough to refuse, never an overflow
					i += 1
				}
				nums[got] = v
				got += 1
			} else {
				i += 1
			}
		}
		if got == 2 do return nums[0], nums[1], true
	}
	return
}

// image_kind is the MIME type a picture file's bytes say they are, "" when
// they say none Baldr reads. TGA has no signature at its start, so only a
// TGA 2.0 file (the footer it ends with) is recognised.
@(private)
image_kind :: proc(data: []u8) -> string {
	starts :: proc(d: []u8, s: string) -> bool { return len(d) >= len(s) && string(d[:len(s)]) == s }
	switch {
	case starts(data, "\x89PNG\r\n\x1a\n"): return "image/png"
	case starts(data, "\xff\xd8\xff"):        return "image/jpeg"
	case starts(data, "qoif"):                return "image/qoi"
	case starts(data, "GIF87a"), starts(data, "GIF89a"): return "image/gif"
	case len(data) >= 16 && starts(data, "RIFF") && string(data[8:12]) == "WEBP": return "image/webp"
	case starts(data, "BM"):                  return "image/bmp"
	case len(data) >= 3 && data[0] == 'P' && data[1] >= '1' && data[1] <= '6' && (data[2] == ' ' || data[2] == '\n' || data[2] == '\r' || data[2] == '\t'):
		return "image/x-portable-anymap"
	case len(data) >= 18 && string(data[len(data) - 18:]) == "TRUEVISION-XFILE.\x00":
		return "image/tga"
	case len(data) >= 22 && (starts(data, "\x00\x00\x01\x00") || starts(data, "\x00\x00\x02\x00")) && (data[4] != 0 || data[5] != 0) && data[9] == 0:
		return "image/vnd.microsoft.icon" // no magic of its own: a header of zeros and a count, and an entry's zero byte; after TGA, which can start the same way
	}
	head := data[:min(len(data), 1024)]
	i := 0
	if starts(head, "\xef\xbb\xbf") do i = 3 // a UTF-8 byte-order mark
	for i < len(head) && (head[i] == ' ' || head[i] == '\t' || head[i] == '\n' || head[i] == '\r') do i += 1
	if starts(head[i:], "<svg") do return "image/svg+xml"
	if starts(head[i:], "<?xml") || starts(head[i:], "<!--") || starts(head[i:], "<!DOCTYPE") {
		for j in i ..< len(head) - 3 do if string(head[j:j + 4]) == "<svg" do return "image/svg+xml"
	}
	return ""
}

// image_load_png decodes a PNG, refusing one cut short or malformed before
// core's decoder sees it (png_check.odin).
@(private)
image_load_png :: proc(data: []u8, allocator := context.allocator) -> (img: Image, ok: bool) {
	if !png_sound(data) do return
	src, err := png.load_from_bytes(data, {.alpha_add_if_missing}, context.temp_allocator)
	if err != nil || src == nil do return
	defer image.destroy(src, context.temp_allocator)
	return image_from_decoded(src, allocator)
}

// image_from_decoded converts what one of core's decoders gave (any channel
// count, 8 or 16 bits) to RGBA8.
@(private)
image_from_decoded :: proc(src: ^image.Image, allocator: runtime.Allocator) -> (img: Image, ok: bool) {
	w, h := src.width, src.height
	if w <= 0 || h <= 0 do return
	out := make([]u8, w * h * 4, allocator)
	// `core:image`'s Image.pixels is a `[dynamic]byte` from dev-2026-11 on
	// (a `bytes.Buffer` before), so this line needs that compiler or newer.
	buf := src.pixels[:]
	ch := src.channels
	bps := 2 if src.depth == 16 else 1
	if len(buf) < w * h * ch * bps {
		delete(out, allocator)
		return
	}
	for i in 0 ..< w * h {
		px := buf[i * ch * bps:]
		sample :: proc(px: []u8, c, bps: int) -> u8 { return px[c * bps] } // 16-bit: the high byte
		r, g, b, a: u8 = 0, 0, 0, 255
		switch ch {
		case 1: r = sample(px, 0, bps); g, b = r, r
		case 2: r = sample(px, 0, bps); g, b = r, r; a = sample(px, 1, bps)
		case 3: r, g, b = sample(px, 0, bps), sample(px, 1, bps), sample(px, 2, bps)
		case: r, g, b, a = sample(px, 0, bps), sample(px, 1, bps), sample(px, 2, bps), sample(px, 3, bps)
		}
		out[i * 4 + 0], out[i * 4 + 1], out[i * 4 + 2], out[i * 4 + 3] = r, g, b, a
	}
	return Image{width = w, height = h, pixels = out, version = 1, allocator = allocator}, true
}

// image_from_rgba wraps a copy of `pixels` (RGBA8, w × h).
image_from_rgba :: proc(w, h: int, pixels: []u8, allocator := context.allocator, secret := false) -> (img: Image, ok: bool) {
	if w <= 0 || h <= 0 || w > IMAGE_MAX_SIDE || h > IMAGE_MAX_SIDE do return // the sides before the multiply: w * h * 4 of a huge pair overflows
	if len(pixels) < w * h * 4 do return
	out := make([]u8, w * h * 4, allocator)
	copy(out, pixels[:w * h * 4])
	return Image{width = w, height = h, pixels = out, version = 1, allocator = allocator, secret = secret}, true
}

// image_destroy frees a picture. A `secret` one has its pixels overwritten
// first, so the bytes are not left in freed memory.
image_destroy :: proc(img: ^Image) {
	if img.secret do secret_scrub_bytes(img.pixels)
	if img.pixels != nil do delete(img.pixels, img.allocator)
	if img.delays != nil do delete(img.delays, img.allocator)
	img^ = {}
}

// image_secret marks a picture's pixels a secret: a QR code of a key, an
// attachment decrypted in memory. `image_destroy` then overwrites them
// before freeing, as `secret_scrub` does for a keychain value. It covers the
// CPU copy only: once drawn, the renderer's copy lives in GPU memory the
// toolkit cannot overwrite, so treat being on screen as disclosure.
image_secret :: proc(img: ^Image, on := true) {
	if img == nil do return
	img.secret = on
}

// IMAGE_GRID_MAX_SIDE is how big a side an animation's texture may have
// when the caller names no limit: 4,096, which **every** conformant Vulkan
// device allows (it is the floor the specification promises). Most desktop
// cards allow 16,384, so an app that knows its device — `gpu_limits(g)
// .max_side` — can say so and keep more frames.
IMAGE_GRID_MAX_SIDE :: 4096

// image_from_rgba_frames makes an animation from `frames` pictures of
// `w` x `h` RGBA8 and a delay in milliseconds for each, which the app
// decoded itself (image_load returns GIF and WebP animations this way
// already).
// The toolkit animates it while it is on screen, with no message
// and no view rebuilt per frame, and shows the first frame under
// reduce-motion. The frames are copied into one texture as a square-ish
// grid, so they may be freed afterwards; the Image is the caller's, freed
// with `image_destroy`.
//
// `max_side` caps each side of that texture (default `IMAGE_GRID_MAX_SIDE`:
// 120 frames of 480x270). If the frames cannot all fit, every k-th one is
// kept and the dropped ones' delays go to the one before, so the animation
// still runs to time: it loses smoothness, not sharpness. Compare
// `img.frames` with `len(frames)` to tell. A delay of 0 (older GIFs' "as
// fast as possible") is read as 100 ms, as every decoder does, and anything
// under 20 ms is raised to 20, so a GIF cannot spin the frame clock.
image_from_rgba_frames :: proc(w, h: int, frames: [][]u8, delays_ms: []int, max_side := IMAGE_GRID_MAX_SIDE, allocator := context.allocator) -> (img: Image, ok: bool) {
	n := len(frames)
	if w <= 0 || h <= 0 || n == 0 || len(delays_ms) != n do return
	for f in frames do if len(f) < w * h * 4 do return
	if n == 1 {
		return image_from_rgba(w, h, frames[0], allocator)
	}
	cols, rows, keep := image_grid_fit(w, h, n, max_side)
	if keep <= 0 do return
	if keep == 1 {
		return image_from_rgba(w, h, frames[0], allocator) // only one fits: a still picture, honestly
	}

	tw, th := cols * w, rows * h
	out, err := make([]u8, tw * th * 4, allocator)
	if err != nil do return
	delays, derr := make([]u16, keep, allocator)
	if derr != nil {
		delete(out, allocator)
		return
	}

	// Keeping every k-th frame and adding what the dropped ones were owed
	// to the one before keeps the animation's total length right, so a
	// three-second GIF still takes three seconds.
	for i in 0 ..< keep {
		from := i * n / keep
		upto := (i + 1) * n / keep
		ms := 0
		for j in from ..< max(upto, from + 1) {
			d := delays_ms[j]
			if d <= 0 do d = 100
			ms += d
		}
		delays[i] = u16(clamp(ms, 20, 65535))
		// the frame's place in the grid
		cx, cy := (i % cols) * w, (i / cols) * h
		src := frames[from]
		for y in 0 ..< h {
			dst := ((cy + y) * tw + cx) * 4
			copy(out[dst:dst + w * 4], src[y * w * 4:(y + 1) * w * 4])
		}
	}
	return Image{
		width = tw, height = th, pixels = out, version = 1, allocator = allocator,
		frames = keep, cols = cols, delays = delays,
	}, true
}

// Anim_Grid builds an animation straight into its grid, for a decoder that
// composes each frame on a canvas (a GIF's, a WebP's): only the frames kept
// are copied, so a long animation is never held whole. The grid, the frames
// kept and their delays are exactly image_from_rgba_frames's.
@(private)
Anim_Grid :: struct {
	w, h, n:   int,
	cols, keep: int,
	tw, th:    int,
	group:     int, // the kept frame the frames now arriving belong to
	next:      int, // the first frame of the group after it
	ms:        int, // the current group's delay so far
	pixels:    []u8,
	delays:    []u16,
	allocator: runtime.Allocator,
}

// anim_grid_begin sizes the grid for `n` frames of `w` x `h`; false when
// fewer than two fit, which the caller shows as a still picture.
@(private)
anim_grid_begin :: proc(g: ^Anim_Grid, w, h, n: int, allocator: runtime.Allocator) -> bool {
	cols, rows, keep := image_grid_fit(w, h, n, IMAGE_GRID_MAX_SIDE)
	if keep < 2 do return false
	g^ = {w = w, h = h, n = n, cols = cols, keep = keep, tw = cols * w, th = rows * h, next = n / keep, allocator = allocator}
	g.pixels = make([]u8, g.tw * g.th * 4, allocator)
	g.delays = make([]u16, keep, allocator)
	return true
}

// anim_grid_frame takes frame `i`, in order, as it is shown, and how long
// it is shown for.
@(private)
anim_grid_frame :: proc(g: ^Anim_Grid, i: int, canvas: []u8, delay_ms: int) {
	first := i == 0
	if i > 0 && i == g.next && g.group + 1 < g.keep {
		g.delays[g.group] = u16(clamp(g.ms, 20, 65535))
		g.group += 1
		g.ms = 0
		g.next = (g.group + 1) * g.n / g.keep
		first = true
	}
	if first {
		cx, cy := (g.group % g.cols) * g.w, (g.group / g.cols) * g.h
		for y in 0 ..< g.h {
			at := ((cy + y) * g.tw + cx) * 4
			copy(g.pixels[at:at + g.w * 4], canvas[y * g.w * 4:(y + 1) * g.w * 4])
		}
	}
	g.ms += 100 if delay_ms <= 0 else delay_ms // an older GIF's "as fast as possible", as every decoder reads it
}

// anim_grid_cut ends an animation at the frames already taken: one that
// would not decode stops it there.
@(private)
anim_grid_cut :: proc(g: ^Anim_Grid) {
	g.keep = g.group + 1
	g.delays = g.delays[:g.keep]
}

@(private)
anim_grid_free :: proc(g: ^Anim_Grid) {
	delete(g.pixels, g.allocator)
	delete(g.delays, g.allocator)
	g^ = {}
}

// anim_grid_end is the finished animation, the caller's to image_destroy.
// Cut down to one frame, it is a still picture of that frame's size.
@(private)
anim_grid_end :: proc(g: ^Anim_Grid) -> Image {
	if g.keep <= 1 {
		still := make([]u8, g.w * g.h * 4, g.allocator)
		for y in 0 ..< g.h do copy(still[y * g.w * 4:(y + 1) * g.w * 4], g.pixels[y * g.tw * 4:][:g.w * 4])
		w, h, a := g.w, g.h, g.allocator
		anim_grid_free(g)
		return Image{width = w, height = h, pixels = still, version = 1, allocator = a}
	}
	g.delays[g.group] = u16(clamp(g.ms, 20, 65535))
	return Image{
		width = g.tw, height = g.th, pixels = g.pixels, version = 1, allocator = g.allocator,
		frames = g.keep, cols = g.cols, delays = g.delays,
	}
}

// image_grid_fit picks a square-ish grid for `n` frames of `w` x `h` with
// no side past `max_side`, and says how many frames fit. Square-ish keeps
// the longer side smallest: 100 frames of 480x270 are 3,840 x 3,510 this
// way and 48,000 px tall in one column.
@(private)
image_grid_fit :: proc(w, h, n, max_side: int) -> (cols, rows, keep: int) {
	s := max_side if max_side > 0 else IMAGE_GRID_MAX_SIDE
	cmax, rmax := s / w, s / h
	if cmax < 1 || rmax < 1 do return 0, 0, 0 // one frame is already too big for the device
	keep = min(n, cmax * rmax)
	cols = clamp(isqrt_ceil(keep * h / max(w, 1)), 1, cmax)
	rows = (keep + cols - 1) / cols
	if rows > rmax { // too tall: widen it instead
		rows = rmax
		cols = clamp((keep + rows - 1) / rows, 1, cmax)
	}
	return
}

// isqrt_ceil is the smallest integer whose square is at least `v`.
@(private)
isqrt_ceil :: proc(v: int) -> int {
	if v <= 1 do return 1
	r := 1
	for r * r < v do r += 1
	return r
}

// image_frame_size is one frame's size in pixels — what an animation is to
// be laid out at, since `width` and `height` are the whole grid (so
// `height / frames` is wrong). A still picture answers its own size.
image_frame_size :: proc(img: ^Image) -> [2]int {
	if img == nil do return {}
	if img.frames <= 1 do return {img.width, img.height}
	c := max(img.cols, 1)
	rows := (img.frames + c - 1) / c
	return {img.width / c, img.height / max(rows, 1)}
}

// image_frame_rows is how many rows of frames the grid has, for an app
// drawing one frame itself with `source`.
image_frame_rows :: proc(img: ^Image) -> int {
	if img == nil || img.frames <= 1 do return 1
	c := max(img.cols, 1)
	return (img.frames + c - 1) / c
}

// image_frame_rect is the source rectangle of frame `i` in the grid — for
// an app that wants one frame of an animation rather than the animation: a
// still poster for a GIF that only plays when the pointer is on it, or a
// thumbnail. Pass it as `image`'s `source`, which also stops the toolkit
// animating it.
image_frame_rect :: proc(img: ^Image, i: int) -> Rect {
	if img == nil || img.frames <= 1 do return {}
	return image_frame_rect_of(img.width, img.height, img.frames, img.cols, i)
}

// image_frame_rect_of is the same from the numbers alone, so paint can work
// it out from what a Picture remembers without holding the Image.
@(private)
image_frame_rect_of :: proc(tw, th, frames, cols, i: int) -> Rect {
	c := max(cols, 1)
	rows := (frames + c - 1) / c
	fw := f32(tw) / f32(c)
	fh := f32(th) / f32(max(rows, 1))
	return {f32(i % c) * fw, f32(i / c) * fh, fw, fh}
}

// image_frame_at is which frame an animation is showing at `now_ms`, having
// started at `started_ms`, and how long until the next one.
@(private)
image_frame_at :: proc(delays: []u16, started_ms, now_ms: f64) -> (frame: int, next_ms: f64) {
	total := f64(0)
	for d in delays do total += f64(d)
	if total <= 0 do return 0, now_ms + 1000
	into := now_ms - started_ms
	if into < 0 do into = 0
	into -= total * f64(int(into / total)) // the loop, without a modulo on a float that may be huge
	at := f64(0)
	for d, i in delays {
		if into < at + f64(d) do return i, now_ms + (at + f64(d) - into)
		at += f64(d)
	}
	return len(delays) - 1, now_ms + 1
}

// image draws `img` scaled into `width` × `height` (give one to keep the
// aspect ratio; neither → the pixel size), with `radius` corners. Decorative
// unless `label` names it (then role Image). `source` is the part of the
// picture shown, in its own pixels ({}: all of it): clamped to the picture,
// it is what `fit` and the missing side follow, and changing it every frame
// (a viewer's pan or zoom) is a repaint, never another upload. Drawn smaller
// than it is, it is sampled through mip levels.
//
// Magnified, by default it goes crisp on its own: smooth up to 2 device
// pixels a picture pixel, hard-edged squares from 4, crossfaded between,
// so a zoom sharpens as it goes in instead of popping at a threshold each
// app would pick. `pixelated = true` forces the hard squares (a pixel
// editor's document), `pixelated = false` the smooth filter; drawn smaller
// than it is, it is smooth either way. `pixel_grid` draws a 1-pixel line
// between the picture's pixels, fading in from 8 device pixels each and
// fully there from 24.
image :: proc(ui: ^Ui($Msg), img: ^Image, width: f32 = 0, height: f32 = 0, radius: f32 = 0, label: string = "",
	fit: Image_Fit = .Cover, source: Rect = {}, pixelated: Maybe(bool) = nil, pixel_grid := false, key: u64 = 0, loc := #caller_location) -> Node {
	px := pixels_of(pixelated)
	n, created := reconcile_child(ui, .Custom, key, loc)
	t := &ui.tree
	d := node_get(t, n)
	w, h := width, height
	// An Image freed while a node was showing it does not add up any more:
	// it is drawn as nothing, said once, and not remembered, so the node
	// holds no pointer it would read again.
	live := image_adds_up(img)
	if img != nil && img.pixels != nil && !live && !t.picture_said {
		t.picture_said = true
		// In hex as well as decimal: hex shows what the numbers are (a freed
		// chunk's allocator links, or 0xAAAA… from a scrubbing allocator).
		diag(t, loc, fmt.tprintf("the picture given to image() does not add up: %d x %d (%#x x %#x) with %d bytes of pixels, so it is not drawn. An Image freed while the toolkit was still showing it reads like this — image_forget(ui, img) before freeing one, and never hand over a freed Image.",
			img.width, img.height, u64(img.width), u64(img.height), len(img.pixels)))
	}
	// An animation is a strip of frames, so its natural size is **one
	// frame**, not the whole strip — and the part shown is that frame.
	src_asked := source
	if live && img.frames > 1 && source == {} do src_asked = image_frame_rect(img, 0)
	if image_sides_ok(img) { // the room it takes is its sides' doing, pixels or no pixels yet
		src, shown := image_source(src_asked, {img.width, img.height})
		if !shown do src = {0, 0, 0, 0}
		aspect := src.w / src.h if src.h > 0 else 1
		switch {
		case w <= 0 && h <= 0: w, h = src.w, src.h
		case w <= 0:           w = h * aspect
		case h <= 0:           h = w / aspect
		}
	}
	// `live` decides both of the next two: an image node holds the app's
	// pointer exactly while `t.pictures[n]` holds what it last showed, so
	// `pictures_release` and `image_forget` — which find a node through that
	// entry — can always reach the pointer to clear it.
	if live {
		if img.id == 0 do img.id = image_new_id()
		old, had := t.pictures[n]
		if had && (old.source != src_asked || old.touched != img.touched || old.pixels != px || old.pixel_grid != pixel_grid) do mark_paint_dirty(t, n) // a new part, new pixels in part, or sampled differently
		pic := Picture{id = img.id, version = img.version, size = {img.width, img.height}, source = src_asked, touched = img.touched, pixels = px, pixel_grid = pixel_grid}
		// An animation keeps running across builds: the start time is set
		// once, so scrolling the view or typing in a field beside it does
		// not restart the GIF from frame 0.
		if img.frames > 1 && source == {} {
			pic.frames, pic.cols, pic.delays = img.frames, img.cols, img.delays
			// `old.frames` matching is the test, not `started_ms > 0`: an
			// animation built at time 0 would restart on every build.
			pic.started_ms = old.started_ms if had && old.frames == img.frames else t.now_ms
			pic.frame = old.frame if had && old.frames == img.frames else 0
			pic.source = image_frame_rect(img, pic.frame)
		}
		t.pictures[n] = pic
	} else {
		delete_key(&t.pictures, n)
	}
	holds := rawptr(img) if live else nil
	if ck, ok := d.kind.(Custom_Kind); !ok || created || ck.size != {w, h} || ck.user != holds {
		d.kind = Custom_Kind{size = {w, h}, paint = paint_image, user = holds}
		mark_layout_dirty(t, n)
	}
	if d.style.radius != radius || d.tag != u64(fit) {
		d.style.radius = radius
		d.tag = u64(fit)
		mark_paint_dirty(t, n)
	}
	if label != "" {
		d.access.role = .Image
		set_name(t, n, label)
	} else {
		d.access.role = .None
	}
	return n
}

@(private)
paint_image :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer) {
	ck, ok := d.kind.(Custom_Kind)
	if !ok do return
	c := Color{1, 1, 1, t.paint_opacity}
	if disabled_within(t, n) do c.a *= t.theme.state.disabled_alpha
	if ck.user == nil { // leaving: the app may have let its Image go; the fade draws the atlas's copy
		if p, has := t.pictures[n]; has && p.released {
			append(&l.cmds, Draw_Image{rect = d.abs, radius = d.style.radius, square = d.style.square, color = c, fit = Image_Fit(d.tag), id = p.id, version = p.version, size = p.size, source = p.source, pixels = p.pixels, pixel_grid = p.pixel_grid})
		}
		return
	}
	img := (^Image)(ck.user)
	if !image_adds_up(img) {
		// It was a picture when the build handed it over and is not one
		// now: the app freed it while this node was still showing it. Let
		// go of the pointer (nothing reads it again), draw the copy the
		// atlas kept if there is one, and say so once.
		if !t.picture_said {
			t.picture_said = true
			fmt.eprintfln("baldr: a picture went away while a node was still showing it (%s at %s:%d read %d x %d, %#x x %#x): call image_forget(ui, img) before freeing an Image, or free it only after the build that stops showing it.",
				d.builder, d.loc.file_path, d.loc.line, img.width, img.height, u64(img.width), u64(img.height))
		}
		if live, is_custom := &d.kind.(Custom_Kind); is_custom do live.user = nil // in place: `ck` above is a copy
		if p, has := &t.pictures[n]; has {
			p.released = true
			p.frames, p.cols, p.delays = 0, 0, nil // the delays were the Image's
			append(&l.cmds, Draw_Image{rect = d.abs, radius = d.style.radius, square = d.style.square, color = c, fit = Image_Fit(d.tag), id = p.id, version = p.version, size = p.size, source = p.source, pixels = p.pixels, pixel_grid = p.pixel_grid})
		}
		return
	}
	append(&l.cmds, Draw_Image{rect = d.abs, img = img, radius = d.style.radius, square = d.style.square, color = c, fit = Image_Fit(d.tag), id = img.id, version = img.version, size = {img.width, img.height}, source = t.pictures[n].source, pixels = t.pictures[n].pixels, pixel_grid = t.pictures[n].pixel_grid})
}

// Picture is what an image node last showed of an app's Image, so the node
// can fade out after the app has let the Image go without reading it again.
@(private)
Picture :: struct {
	id, version: u64,
	size:        [2]int,
	source:      Rect, // the part of it shown ({}: all)
	touched:     u64,  // the Image's `touched` as last built: a new touch is a repaint
	// An animation's own state. `delays` aliases the Image, so it is dropped
	// the moment the node is `released`.
	frames:      int,
	cols:        int,
	delays:      []u16,
	started_ms:  f64,
	frame:       int,
	pixels:      Pixels, // how it is sampled where magnified
	pixel_grid:  bool,   // a line between its pixels, far enough in
	released:    bool,   // the node is leaving: it holds no Image any more
}


@(private)
image_ids: u64

// image_new_id names a picture for the atlas.
@(private)
image_new_id :: proc() -> u64 {
	return sync.atomic_add(&image_ids, 1) + 1
}

// pictures_release: a leaving subtree lets go of the app's Images (the app
// may free them as soon as its view stops showing them); its pictures fade
// from the copies the atlas kept.
@(private)
pictures_release :: proc(t: ^Tree, n: Node) {
	d := node_get(t, n)
	if d == nil do return
	if p, has := &t.pictures[n]; has {
		p.released = true
		if ck, is_custom := &d.kind.(Custom_Kind); is_custom do ck.user = nil
		mark_paint_dirty(t, n)
	}
	for c := d.first; c != NODE_NONE; c = node_get(t, c).next do pictures_release(t, c)
}

// image_forget tells the toolkit that `img` is about to be freed, so every
// node still showing it lets go at once and draws the copy the atlas kept
// until the next build replaces it.
//
// Otherwise an Image may be freed once the view stops showing it: the build
// that drops it releases the node, and a message always rebuilds every view
// before anything paints. Freeing in `update`, before that build, needs
// this: a `component` whose revision did not change is not rebuilt and
// keeps pointing at the Image. The Image must also be gone from wherever
// the view reads it, or the build hands the freed pointer straight back.
// It costs a walk of the image nodes, not the tree; an Image nothing shows
// is a no-op.
//
//	audio_of_the_cache_entry_went_away(s)
//	baldr.image_forget(ui, img)   // or from `update`, through the Ui you hold
//	baldr.image_destroy(img)
//	free(img)
image_forget :: proc(ui: ^Ui($Msg), img: ^Image) {
	if img == nil do return
	t := &ui.tree
	for n, &p in t.pictures {
		d := node_get(t, n)
		if d == nil do continue
		ck, is_custom := &d.kind.(Custom_Kind)
		if !is_custom || ck.user != rawptr(img) do continue
		ck.user = nil
		p.released = true
		p.frames, p.cols, p.delays = 0, 0, nil // it owned the delays too
		mark_paint_dirty(t, n)
	}
	// A markdown view keeps the app's pictures in its own state (by `src`,
	// and on each laid-out block), where no `Tree.pictures` entry points at
	// them, so the loop above cannot see them.
	for n, &mv in t.md_views {
		dropped := false
		for _, &pic in mv.images do if pic == img { pic = nil; dropped = true }
		for &c in mv.blocks do if c.picture == img { c.picture = nil; dropped = true }
		if dropped {
			mv.rev = 0 // the picture's height was part of the layout: lay the blocks out again
			mark_layout_dirty(t, n)
		}
	}
}

// forget_image is `image_forget` as a command, for the usual case: an app
// that frees pictures in `update`, where there is no `^Ui` to hand and
// where several surfaces may each be showing the same one.
//
//	case Cache_Cleared:
//		cmds := make([dynamic]Cmd(Msg), context.temp_allocator)
//		for img in s.dropped do append(&cmds, baldr.forget_image(Msg, img))
//		return baldr.batch(Msg, cmds[:])
//
// It lets every live surface go of the picture and then destroys it, so the
// app does not call `image_destroy` itself. It runs during message
// dispatch, before any view is built.
//
// The `^Image` box is still the app's to free, but not in the `update` that
// returns this command: the Cmd holds the pointer until dispatch runs it.
// Free it on a later turn (keep a list, free it at the top of the next
// sync), or not at all: the struct is small and `image_destroy` has freed
// everything it pointed at.
forget_image :: proc($Msg: typeid, img: ^Image) -> Cmd(Msg) {
	return {kind = .Forget_Image, picture_img = img}
}

// image_contain_rect is the largest rect of the picture's aspect that
// fits centred in `box` (the Contain fit).
image_contain_rect :: proc(box: Rect, img_w, img_h: int) -> Rect {
	return image_contain_rect_f(box, f32(img_w), f32(img_h))
}

@(private)
image_contain_rect_f :: proc(box: Rect, img_w, img_h: f32) -> Rect {
	if box.w <= 0 || box.h <= 0 || img_w <= 0 || img_h <= 0 do return box
	pic := img_w / img_h
	r := box
	if pic > box.w / box.h { // wider than the box: full width, letterboxed
		r.h = box.w / pic
		r.y += (box.h - r.h) / 2
	} else {
		r.w = box.h * pic
		r.x += (box.w - r.w) / 2
	}
	return r
}
