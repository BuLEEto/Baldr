package baldr

// GIF pictures, still and animated, in Odin. Each frame is drawn onto the
// picture's canvas as a browser draws it (its rectangle, its transparent
// colour, interlaced rows, then what its disposal says to leave for the next
// frame), and the frames kept go straight into the animation's grid.
//
// A GIF can claim far more than it holds: a frame of 65,535 pixels square,
// tens of thousands of frames, or a few bytes that expand a thousandfold. So
// the canvas is held to `max_pixels`, a frame to its canvas's size, and the
// frames together to GIF_MAX_WORK pixels drawn; an animation past that is
// cut short there rather than refused.

import "base:runtime"
import "core:slice"

// GIF_MAX_WORK is how many pixels all of a GIF's frames may draw: a quarter
// of a billion, 130 frames at full HD or 2,000 at 480 by 270, and about half
// a second for the worst file that can be made (measured optimised, with
// every code expanding to 4,000 pixels).
@(private)
GIF_MAX_WORK :: 1 << 28

// GIF_MAX_FRAMES is how many frames are read before the rest are left off.
@(private)
GIF_MAX_FRAMES :: 20_000

@(private)
Gif_Frame :: struct {
	x, y, w, h:  int,
	delay_ms:    int,
	disposal:    int, // 2: cleared to transparent afterwards; 3: put back as it was
	transparent: int, // the palette index not drawn, or -1
	interlaced:  bool,
	palette:     []u8, // RGB triples: its own, or the picture's
	min_code:    int,
	data:        int,  // where its first data sub-block starts
}

// gif_load decodes a GIF: a still picture, or an animation the toolkit
// plays (see image_from_rgba_frames for how frames are kept and timed).
@(private)
gif_load :: proc(d: []u8, allocator: runtime.Allocator, max_pixels: int) -> (img: Image, ok: bool) {
	if len(d) < 13 || (string(d[:6]) != "GIF87a" && string(d[:6]) != "GIF89a") do return
	le16 :: proc(d: []u8, i: int) -> int { return int(d[i]) | int(d[i + 1]) << 8 }
	cw, ch := le16(d, 6), le16(d, 8)
	if cw <= 0 || ch <= 0 || cw * ch > max_pixels do return
	pos := 13
	global: []u8
	if d[10] & 0x80 != 0 {
		n := int(3) << uint(d[10] & 7 + 1)
		if pos + n > len(d) do return
		global = d[pos:pos + n]
		pos += n
	}

	// The frames, read without decoding: how many there are, and so how
	// many the grid keeps, is known before anything is drawn.
	frames := make([dynamic]Gif_Frame, context.temp_allocator)
	pending := Gif_Frame{transparent = -1}
	work := 0
	read: for pos < len(d) && len(frames) < GIF_MAX_FRAMES {
		switch d[pos] {
		case 0x3B: // the trailer
			break read
		case 0x21: // an extension
			if pos + 2 > len(d) do break read
			label := d[pos + 1]
			pos += 2
			if label == 0xF9 && pos + 6 <= len(d) && d[pos] == 4 { // graphic control: this frame's timing and transparency
				packed := d[pos + 1]
				pending.disposal = int(packed >> 2 & 7)
				pending.delay_ms = le16(d, pos + 2) * 10
				pending.transparent = int(d[pos + 4]) if packed & 1 != 0 else -1
			}
			end, sok := gif_skip_blocks(d, pos)
			if !sok do break read
			pos = end
		case 0x2C: // a frame
			if pos + 10 > len(d) do break read
			f := pending
			pending = Gif_Frame{transparent = -1}
			f.x, f.y, f.w, f.h = le16(d, pos + 1), le16(d, pos + 3), le16(d, pos + 5), le16(d, pos + 7)
			packed := d[pos + 9]
			f.interlaced = packed & 0x40 != 0
			pos += 10
			f.palette = global
			if packed & 0x80 != 0 {
				n := int(3) << uint(packed & 7 + 1)
				if pos + n > len(d) do break read
				f.palette = d[pos:pos + n]
				pos += n
			}
			if pos >= len(d) do break read
			f.min_code = int(d[pos])
			f.data = pos + 1
			end, sok := gif_skip_blocks(d, pos + 1)
			if f.w <= 0 || f.h <= 0 || f.w * f.h > cw * ch || f.min_code < 1 || f.min_code > 11 do break read
			work += f.w * f.h
			if work > GIF_MAX_WORK do break read
			append(&frames, f)
			if !sok do break read // its data was cut short: drawn as far as it goes, and the last
			pos = end
		case:
			break read // not a block: what came before it stands
		}
	}
	n := len(frames)
	if n == 0 do return

	grid: Anim_Grid
	animated := n > 1 && anim_grid_begin(&grid, cw, ch, n, allocator)
	if !animated do n = 1 // a still picture, or frames too big for any grid: the first, honestly
	canvas := make([]u8, cw * ch * 4, allocator)
	largest := 0
	for f in frames[:n] do largest = max(largest, f.w * f.h)
	idx := make([]u8, largest, allocator) // a frame's colour indices, before they are drawn
	defer delete(idx, allocator)
	saved: []u8 // what a frame that puts things back puts back
	for f in frames[:n] do if f.disposal == 3 {
		saved = make([]u8, cw * ch * 4, context.temp_allocator)
		break
	}
	for &f, i in frames[:n] {
		if f.disposal == 3 && saved != nil do copy(saved, canvas)
		gif_draw(d, &f, canvas, cw, ch, idx)
		if !animated do break
		anim_grid_frame(&grid, i, canvas, f.delay_ms)
		switch f.disposal {
		case 2: gif_fill(canvas, cw, ch, &f, nil)
		case 3: if saved != nil do gif_fill(canvas, cw, ch, &f, saved)
		}
	}
	if !animated do return Image{width = cw, height = ch, pixels = canvas, version = 1, allocator = allocator}, true
	delete(canvas, allocator)
	return anim_grid_end(&grid), true
}

// gif_skip_blocks steps over a run of data sub-blocks to just past its
// terminator; false when the data ends first.
@(private = "file")
gif_skip_blocks :: proc(d: []u8, start: int) -> (end: int, ok: bool) {
	pos := start
	for pos < len(d) {
		n := int(d[pos])
		pos += 1 + n
		if n == 0 do return pos, true
	}
	return len(d), false
}

// gif_fill clears a frame's rectangle to transparent, or puts back what
// `from` held there.
@(private = "file")
gif_fill :: proc(canvas: []u8, cw, ch: int, f: ^Gif_Frame, from: []u8) {
	x0, y0 := clamp(f.x, 0, cw), clamp(f.y, 0, ch)
	x1, y1 := clamp(f.x + f.w, 0, cw), clamp(f.y + f.h, 0, ch)
	for y in y0 ..< y1 {
		row := canvas[(y * cw + x0) * 4:(y * cw + x1) * 4]
		if from == nil {
			for &b in row do b = 0
		} else {
			copy(row, from[(y * cw + x0) * 4:(y * cw + x1) * 4])
		}
	}
}

// Gif_Bits reads LZW codes, least significant bit first, across the data
// sub-blocks without copying them together.
@(private = "file")
Gif_Bits :: struct {
	d:    []u8,
	pos:  int,
	left: int, // bytes left in the sub-block being read
	acc:  u32,
	n:    uint,
	done: bool,
}

@(private = "file")
gif_code :: proc(b: ^Gif_Bits, size: uint) -> int {
	for b.n < size {
		if b.left == 0 {
			if b.done || b.pos >= len(b.d) || b.d[b.pos] == 0 {
				b.done = true
				return -1
			}
			b.left = int(b.d[b.pos])
			b.pos += 1
		}
		if b.pos >= len(b.d) {
			b.done = true
			return -1
		}
		b.acc |= u32(b.d[b.pos]) << b.n
		b.pos += 1
		b.left -= 1
		b.n += 8
	}
	code := int(b.acc & (1 << size - 1))
	b.acc >>= size
	b.n -= size
	return code
}

// gif_row_y is the canvas row the frame's `r`-th arriving row lands on:
// in order, or in a GIF's four interlaced passes.
@(private = "file")
gif_row_y :: proc(f: ^Gif_Frame, r: int) -> int {
	if !f.interlaced do return f.y + r
	h := f.h
	c1 := (h + 7) / 8
	if r < c1 do return f.y + r * 8
	c2 := (h + 3) / 8
	if r < c1 + c2 do return f.y + 4 + (r - c1) * 8
	c3 := (h + 1) / 4
	if r < c1 + c2 + c3 do return f.y + 2 + (r - c1 - c2) * 4
	return f.y + 1 + (r - c1 - c2 - c3) * 2
}

// gif_draw decodes one frame's LZW data onto the canvas. Data cut short
// leaves the rest of the frame as it was.
//
// The colour indices are decoded first, each code's string written in place
// back to front (one step a pixel, where a stack would take two), then the
// rows are drawn through a table of the palette's pixels.
@(private = "file")
gif_draw :: proc(d: []u8, f: ^Gif_Frame, canvas: []u8, cw, ch: int, idx: []u8) {
	prefix: [4096]u16
	suffix: [4096]u8
	first:  [4096]u8  // the colour each code's string starts with
	length: [4096]int // and how long it is
	total := f.w * f.h
	out := idx[:total]
	bits := Gif_Bits{d = d, pos = f.data}
	clear := 1 << uint(f.min_code)
	for c in 0 ..< clear {
		first[c] = u8(c)
		length[c] = 1
	}
	size := uint(f.min_code + 1)
	next := clear + 2
	old := -1
	p := 0
	for p < total {
		code := gif_code(&bits, size)
		if code < 0 do break
		if code == clear {
			size = uint(f.min_code + 1)
			next = clear + 2
			old = -1
			continue
		}
		if code == clear + 1 do break // the end
		if old < 0 {
			if code >= clear do break // a frame must start with a colour
			out[p] = u8(code)
			p += 1
			old = code
			continue
		}
		if code > next || (code == next && next >= 4096) do break // a code not made yet: the data is broken
		// the string: a known code's own, or (the one being made) the last
		// one's with its own first colour after it
		n := length[old] + 1 if code == next else length[code]
		lead := first[old] if code == next else first[code]
		at := p + n - 1
		k := code
		if code == next {
			if at < total do out[at] = lead
			at -= 1
			k = old
		}
		for k >= clear {
			if at < total do out[at] = suffix[k]
			at -= 1
			k = int(prefix[k])
		}
		if at < total do out[at] = u8(k)
		p += n
		if next < 4096 {
			prefix[next] = u16(old)
			suffix[next] = lead
			first[next] = first[old]
			length[next] = length[old] + 1
			next += 1
			if next == 1 << size && size < 12 do size += 1
		}
		old = code
	}
	done := min(p, total)

	lut: [256]u32
	for i in 0 ..< 256 {
		px := [4]u8{0, 0, 0, 255} // past its palette: opaque black, as browsers draw it
		if i * 3 + 2 < len(f.palette) do px = {f.palette[i * 3], f.palette[i * 3 + 1], f.palette[i * 3 + 2], 255}
		lut[i] = transmute(u32)px
	}
	px := slice.reinterpret([]u32, canvas)
	lo, hi := clamp(-f.x, 0, f.w), clamp(cw - f.x, 0, f.w) // the columns that land on the canvas
	if lo >= hi do return
	for r := 0; r * f.w < done; r += 1 {
		y := gif_row_y(f, r)
		if y < 0 || y >= ch do continue
		row := out[r * f.w:min((r + 1) * f.w, done)]
		at := y * cw + f.x
		for c in lo ..< min(hi, len(row)) {
			i := row[c]
			if int(i) != f.transparent do px[at + c] = lut[i]
		}
	}
}
