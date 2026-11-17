package baldr

// WebP lossless (VP8L) decoding, as RFC 9649 section 3 sets it out: the
// four transforms, the colour cache, spatially varying prefix codes and
// LZ77 copies, in Odin with no C.
//
// The bytes come from strangers, so nothing they say is trusted: the
// picture is held to `max_pixels` before anything is allocated, every
// prefix code must be complete, every copy must stay inside the image,
// and the prefix-code tables may hold only a fixed 2 MB plus half the
// picture's RGBA size. Each decoding step consumes input or advances the
// output, and a stream can declare at most 65536 groups of codes, so the
// work is bounded by the pixel count and the input length.

import "core:encoding/endian"
import "core:mem"
import "core:slice"

@(private)
VP8L_ROOT_BITS :: 8

@(private)
VP8L_MAX_CACHE_BITS :: 11

// The green alphabet with the largest colour cache.
@(private)
VP8L_MAX_ALPHABET :: 256 + 24 + (1 << VP8L_MAX_CACHE_BITS)

// The largest table one code can need is 2704 entries (zlib's `enough`
// for 2328 symbols, an 8-bit root and 15-bit codes), so a second-level
// table's offset always fits the 12 bits an entry has for it.
@(private)
VP8L_MAX_TABLE :: 4096

// The prefix-code tables of one image may hold this many u16 entries plus
// one per pixel. libwebp's encoder needs a small fraction of that at every
// setting; a stream asking for more is refused rather than allowed to
// allocate tens of times the picture's size.
@(private)
VP8L_TABLE_FLOOR :: 1 << 20

@(private)
VP8L_PREDICTOR :: 0
@(private)
VP8L_CROSS_COLOR :: 1
@(private)
VP8L_SUBTRACT_GREEN :: 2
@(private)
VP8L_COLOR_INDEXING :: 3

// Alphabet sizes of a group's five codes: green with length prefixes (the
// colour cache adds to it), red, blue, alpha, distance.
@(private, rodata)
VP8L_ALPHABETS := [5]int{256 + 24, 256, 256, 256, 40}

@(private, rodata)
VP8L_CODE_LENGTH_ORDER := [19]u8{17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}

// Distance codes 1..120 as (xi, yi) pairs; the distance is xi + yi*width.
@(private, rodata)
VP8L_DISTANCE_MAP := [240]i8{
	0, 1, 1, 0, 1, 1, -1, 1, 0, 2, 2, 0, 1, 2, -1, 2,
	2, 1, -2, 1, 2, 2, -2, 2, 0, 3, 3, 0, 1, 3, -1, 3,
	3, 1, -3, 1, 2, 3, -2, 3, 3, 2, -3, 2, 0, 4, 4, 0,
	1, 4, -1, 4, 4, 1, -4, 1, 3, 3, -3, 3, 2, 4, -2, 4,
	4, 2, -4, 2, 0, 5, 3, 4, -3, 4, 4, 3, -4, 3, 5, 0,
	1, 5, -1, 5, 5, 1, -5, 1, 2, 5, -2, 5, 5, 2, -5, 2,
	4, 4, -4, 4, 3, 5, -3, 5, 5, 3, -5, 3, 0, 6, 6, 0,
	1, 6, -1, 6, 6, 1, -6, 1, 2, 6, -2, 6, 6, 2, -6, 2,
	4, 5, -4, 5, 5, 4, -5, 4, 3, 6, -3, 6, 6, 3, -6, 3,
	0, 7, 7, 0, 1, 7, -1, 7, 5, 5, -5, 5, 7, 1, -7, 1,
	4, 6, -4, 6, 6, 4, -6, 4, 2, 7, -2, 7, 7, 2, -7, 2,
	3, 7, -3, 7, 7, 3, -7, 3, 5, 6, -5, 6, 6, 5, -6, 5,
	8, 0, 4, 7, -4, 7, 7, 4, -7, 4, 8, 1, 8, 2, 6, 6,
	-6, 6, 8, 3, 5, 7, -5, 7, 7, 5, -7, 5, 8, 4, 6, 7,
	-6, 7, 7, 6, -7, 6, 8, 5, 7, 7, -7, 7, 8, 6, 8, 7,
}

// Vp8l_Bits reads the stream least significant bit first. Past the end
// of the data it reads zeros and counts them, so a decode never runs off
// the slice and a stream that was too short is caught afterwards.
@(private)
Vp8l_Bits :: struct {
	data:    []u8,
	pos:     int,  // next byte to load
	val:     u64,  // loaded bits, the next one lowest
	nbits:   uint, // how many bits of val are loaded
	overrun: int,  // zero bytes loaded after the end of data
}

// Vp8l_Code is one prefix code's table inside its image's table storage.
// A code with a single symbol has a one-entry table and a zero mask.
@(private)
Vp8l_Code :: struct {
	off:  i32,
	mask: u32, // the root table's index mask
}

@(private)
Vp8l_Group :: struct {
	codes:           [5]Vp8l_Code,
	literal:         u32,  // alpha, red and blue when each code has one symbol
	trivial_literal: bool, // a literal reads only its green
	trivial_pixel:   bool, // every pixel is `literal`, read without a bit
}

// Vp8l_Huff is everything one entropy-coded image decodes with.
@(private)
Vp8l_Huff :: struct {
	tables:     [dynamic]u16,
	groups:     []Vp8l_Group,
	meta:       []u32, // group index per block, or nil for a single group
	meta_bits:  uint,
	meta_w:     int,
	cache_bits: uint,
}

@(private)
Vp8l_Transform :: struct {
	kind:  int,
	bits:  uint,
	xsize: int,   // the image width this transform undoes into
	data:  []u32, // its sub-image, or the colour table
}

@(private)
Vp8l_Decoder :: struct {
	br:             Vp8l_Bits,
	allocator:      mem.Allocator,
	budget:         int, // prefix-table entries still allowed
	transforms:     [4]Vp8l_Transform,
	num_transforms: int,
	lengths:        [VP8L_MAX_ALPHABET]u8,
	dirty:          int, // lengths past this are all zero
	scratch:        [VP8L_MAX_TABLE]u16,
}

// vp8l_decode decodes a VP8L chunk's payload, from its 0x2f signature on,
// into non-premultiplied RGBA8 rows allocated in `allocator`.
@(private)
vp8l_decode :: proc(data: []u8, max_pixels: int, allocator := context.allocator) -> (w, h: int, rgba: []u8, ok: bool) {
	if len(data) < 5 || data[0] != 0x2f do return
	d: Vp8l_Decoder
	d.br.data = data[1:]
	d.allocator = allocator
	iw := int(vp8l_read_bits(&d.br, 14)) + 1
	ih := int(vp8l_read_bits(&d.br, 14)) + 1
	_ = vp8l_read_bits(&d.br, 1) // alpha_is_used, a hint only
	if vp8l_read_bits(&d.br, 3) != 0 do return
	if max_pixels <= 0 || iw > max_pixels / ih do return
	d.budget = VP8L_TABLE_FLOOR + iw * ih
	defer vp8l_free_transforms(&d)

	px, dok := vp8l_decode_main(&d, iw, ih)
	if !dok do return
	when ODIN_ENDIAN == .Little {
		for &v in px {
			v = (v & 0xff00ff00) | ((v >> 16) & 0xff) | ((v & 0xff) << 16)
		}
	} else {
		b := slice.to_bytes(px)
		for v, i in px {
			b[4 * i + 0] = u8(v >> 16)
			b[4 * i + 1] = u8(v >> 8)
			b[4 * i + 2] = u8(v)
			b[4 * i + 3] = u8(v >> 24)
		}
	}
	return iw, ih, slice.to_bytes(px), true
}

// vp8l_decode_alpha decodes an ALPH chunk's lossless stream (the bytes
// after its one-byte header): an image of the implied w×h with no header
// of its own, whose green channel is the alpha. Any filtering the ALPH
// header names is left to the caller.
@(private)
vp8l_decode_alpha :: proc(data: []u8, w, h: int, max_pixels: int, allocator := context.allocator) -> (alpha: []u8, ok: bool) {
	if w <= 0 || h <= 0 || max_pixels <= 0 || w > max_pixels / h do return
	d: Vp8l_Decoder
	d.br.data = data
	d.allocator = allocator
	d.budget = VP8L_TABLE_FLOOR + w * h
	defer vp8l_free_transforms(&d)

	px, dok := vp8l_decode_main(&d, w, h)
	if !dok do return
	defer vp8l_free_pixels(px, allocator)
	out, err := mem.alloc_bytes_non_zeroed(w * h, 1, allocator)
	if err != nil do return
	for v, i in px do out[i] = u8(v >> 8)
	return out, true
}

// vp8l_decode_main reads the transforms and the main image, then undoes
// the transforms in place, last read first. The returned ARGB pixels are
// width×height.
@(private)
vp8l_decode_main :: proc(d: ^Vp8l_Decoder, width, height: int) -> (px: []u32, ok: bool) {
	br := &d.br
	xsize := width
	seen: u32
	for vp8l_read_bits(br, 1) == 1 {
		kind := int(vp8l_read_bits(br, 2))
		if seen & (1 << uint(kind)) != 0 do return
		seen |= 1 << uint(kind)
		t := &d.transforms[d.num_transforms]
		d.num_transforms += 1
		t.kind = kind
		t.xsize = xsize
		switch kind {
		case VP8L_PREDICTOR, VP8L_CROSS_COLOR:
			t.bits = uint(vp8l_read_bits(br, 3)) + 2
			t.data = vp8l_decode_sub_image(d, vp8l_subsample(xsize, t.bits), vp8l_subsample(height, t.bits)) or_return
		case VP8L_COLOR_INDEXING:
			n := int(vp8l_read_bits(br, 8)) + 1
			t.bits = 0 if n > 16 else 1 if n > 4 else 2 if n > 2 else 3
			t.data = vp8l_decode_sub_image(d, n, 1) or_return
			xsize = vp8l_subsample(xsize, t.bits)
		}
	}

	hf: Vp8l_Huff
	defer vp8l_free_huff(d, &hf)
	if !vp8l_read_cache_bits(d, &hf) || !vp8l_read_codes(d, &hf, xsize, height, true) do return
	// Colour indexing widens the image last, so the buffer is sized for the
	// full width and every inverse transform works inside it.
	buf, aok := vp8l_alloc_pixels(width * height, d.allocator)
	if !aok do return
	if !vp8l_decode_pixels(d, &hf, buf[:xsize * height], xsize, height) {
		vp8l_free_pixels(buf, d.allocator)
		return
	}
	vp8l_free_huff(d, &hf)

	for i := d.num_transforms - 1; i >= 0; i -= 1 {
		t := &d.transforms[i]
		switch t.kind {
		case VP8L_PREDICTOR:      vp8l_inverse_predictor(t, buf, height)
		case VP8L_CROSS_COLOR:    vp8l_inverse_cross_color(t, buf, height)
		case VP8L_SUBTRACT_GREEN: vp8l_inverse_subtract_green(buf[:t.xsize * height])
		case VP8L_COLOR_INDEXING: vp8l_inverse_color_indexing(t, buf, height)
		}
	}
	return buf, true
}

// vp8l_decode_sub_image decodes a transform's or the entropy image's
// pixels: no transforms and a single prefix-code group.
@(private)
vp8l_decode_sub_image :: proc(d: ^Vp8l_Decoder, width, height: int) -> (px: []u32, ok: bool) {
	hf: Vp8l_Huff
	defer vp8l_free_huff(d, &hf)
	if !vp8l_read_cache_bits(d, &hf) || !vp8l_read_codes(d, &hf, width, height, false) do return
	buf, aok := vp8l_alloc_pixels(width * height, d.allocator)
	if !aok do return
	if !vp8l_decode_pixels(d, &hf, buf, width, height) {
		vp8l_free_pixels(buf, d.allocator)
		return
	}
	return buf, true
}

@(private)
vp8l_read_cache_bits :: proc(d: ^Vp8l_Decoder, hf: ^Vp8l_Huff) -> bool {
	if vp8l_read_bits(&d.br, 1) == 1 {
		bits := vp8l_read_bits(&d.br, 4)
		if bits < 1 || bits > VP8L_MAX_CACHE_BITS do return false
		hf.cache_bits = uint(bits)
	}
	return true
}

// vp8l_read_codes reads the entropy image, when there is one, then every
// prefix-code group. Only the groups the entropy image uses are kept;
// the others are read and checked, as the stream has to be, and dropped.
@(private)
vp8l_read_codes :: proc(d: ^Vp8l_Decoder, hf: ^Vp8l_Huff, width, height: int, allow_meta: bool) -> bool {
	br := &d.br
	hf.tables.allocator = d.allocator
	num_groups, used := 1, 1
	mapping: []i32
	defer delete(mapping, d.allocator)
	if allow_meta && vp8l_read_bits(br, 1) == 1 {
		hf.meta_bits = uint(vp8l_read_bits(br, 3)) + 2
		hf.meta_w = vp8l_subsample(width, hf.meta_bits)
		meta, ok := vp8l_decode_sub_image(d, hf.meta_w, vp8l_subsample(height, hf.meta_bits))
		if !ok do return false
		hf.meta = meta
		top := 0
		for p in meta do top = max(top, int(p >> 8) & 0xffff)
		num_groups = top + 1
		// A group's five codes take at least 4 bits each, so a count the
		// rest of the stream cannot hold is refused before it costs memory.
		if num_groups * 20 > vp8l_bits_left(br) do return false
		err: mem.Allocator_Error
		mapping, err = make([]i32, num_groups, d.allocator)
		if err != nil do return false
		slice.fill(mapping, -1)
		used = 0
		for &p in meta {
			g := int(p >> 8) & 0xffff
			if mapping[g] < 0 {
				mapping[g] = i32(used)
				used += 1
			}
			p = u32(mapping[g])
		}
	}
	groups, gerr := make([]Vp8l_Group, used, d.allocator)
	if gerr != nil do return false
	hf.groups = groups
	cache_size := 0 if hf.cache_bits == 0 else 1 << hf.cache_bits
	for i in 0 ..< num_groups {
		slot := i if mapping == nil else int(mapping[i])
		for j in 0 ..< 5 {
			alphabet := VP8L_ALPHABETS[j]
			if j == 0 do alphabet += cache_size
			code, ok := vp8l_read_code(d, hf, alphabet, slot >= 0)
			if !ok do return false
			if slot >= 0 do groups[slot].codes[j] = code
		}
		if slot >= 0 do vp8l_setup_group(hf, &groups[slot])
	}
	return true
}

// vp8l_setup_group notes the shortcuts a group allows: red, blue and
// alpha codes of one symbol each take no bits, so a literal is its green
// read and those three as constants.
@(private)
vp8l_setup_group :: proc(hf: ^Vp8l_Huff, g: ^Vp8l_Group) {
	single :: proc(hf: ^Vp8l_Huff, c: Vp8l_Code) -> (u32, bool) {
		if c.mask != 0 do return 0, false
		return u32(hf.tables[c.off] & 0xfff), true
	}
	r, rok := single(hf, g.codes[1])
	b, bok := single(hf, g.codes[2])
	a, aok := single(hf, g.codes[3])
	if !rok || !bok || !aok do return
	g.trivial_literal = true
	g.literal = a << 24 | r << 16 | b
	if green, gok := single(hf, g.codes[0]); gok && green < 256 {
		g.trivial_pixel = true
		g.literal |= green << 8
	}
}

// vp8l_read_code reads one prefix code's lengths, simple or normal, and
// builds its table; `store` false only checks it.
@(private)
vp8l_read_code :: proc(d: ^Vp8l_Decoder, hf: ^Vp8l_Huff, alphabet: int, store: bool) -> (code: Vp8l_Code, ok: bool) {
	br := &d.br
	// Only what the last code wrote needs clearing, and only lengths[:extent]
	// can be non-zero afterwards: a code's cost follows what it wrote, not
	// its alphabet.
	slice.zero(d.lengths[:d.dirty])
	d.dirty = alphabet
	lengths := d.lengths[:alphabet]
	extent := 0
	if vp8l_read_bits(br, 1) == 1 {
		// Simple: one or two symbols of length 1. A symbol past the
		// alphabet is not part of the code.
		two := vp8l_read_bits(br, 1) == 1
		first_bits: uint = 8 if vp8l_read_bits(br, 1) == 1 else 1
		s0 := int(vp8l_read_bits(br, first_bits))
		if s0 < alphabet {
			lengths[s0] = 1
			extent = s0 + 1
		}
		if two {
			s1 := int(vp8l_read_bits(br, 8))
			if s1 < alphabet {
				lengths[s1] = 1
				extent = max(extent, s1 + 1)
			}
		}
	} else {
		clc: [19]u8
		n := int(vp8l_read_bits(br, 4)) + 4
		for i in 0 ..< n do clc[VP8L_CODE_LENGTH_ORDER[i]] = u8(vp8l_read_bits(br, 3))
		ctab: [128]u16
		_, croot, cok := vp8l_build_table(clc[:], ctab[:])
		if !cok do return
		cmask := u32(1 << croot) - 1

		// max_symbol counts the code-length symbols read, repeats included,
		// as libwebp's encoder writes it.
		max_symbol := alphabet
		if vp8l_read_bits(br, 1) == 1 {
			nbits := 2 + 2 * uint(vp8l_read_bits(br, 3))
			max_symbol = 2 + int(vp8l_read_bits(br, nbits))
			if max_symbol > alphabet do return
		}
		prev: u8 = 8
		sym := 0
		if croot == 0 && ctab[0] < 16 {
			// A code-length code of one literal costs no bits a length: every
			// length read is that literal.
			sym = min(max_symbol, alphabet)
			slice.fill(lengths[:sym], u8(ctab[0]))
			max_symbol = 0
		}
		for sym < alphabet && max_symbol > 0 {
			max_symbol -= 1
			vp8l_refill(br)
			e := ctab[u32(br.val) & cmask]
			vp8l_skip(br, uint(e >> 12))
			v := e & 0xfff
			if v < 16 {
				lengths[sym] = u8(v)
				sym += 1
				if v != 0 do prev = u8(v)
				continue
			}
			repeat: int
			fill: u8
			switch v {
			case 16:
				repeat = 3 + int(vp8l_read_bits(br, 2))
				fill = prev
			case 17:
				repeat = 3 + int(vp8l_read_bits(br, 3))
			case:
				repeat = 11 + int(vp8l_read_bits(br, 7))
			}
			if sym + repeat > alphabet do return
			slice.fill(lengths[sym:sym + repeat], fill)
			sym += repeat
		}
		extent = sym
	}
	d.dirty = extent
	if vp8l_eos(br) do return
	size, root, bok := vp8l_build_table(lengths[:extent], d.scratch[:] if store else nil)
	if !bok do return
	if store {
		if size > d.budget do return
		off := len(hf.tables)
		if off + size > cap(hf.tables) {
			// Grow by doubling, but never past what the budget still allows.
			want := min(max(2 * cap(hf.tables), off + size, 4096), off + d.budget)
			if reserve(&hf.tables, want) != nil do return
		}
		if _, err := append(&hf.tables, ..d.scratch[:size]); err != nil do return
		d.budget -= size
		code.off = i32(off)
		code.mask = u32(1 << root) - 1
	}
	return code, true
}

// vp8l_build_table checks that lengths make a complete prefix code, or a
// single symbol that takes no bits, and writes its lookup table to out
// (a nil out only checks).
// The root table is indexed by the next root_bits bits, at most 8; longer
// codes continue in second-level tables placed after it. An entry holds a
// symbol in its low 12 bits and how many bits it takes in its top 4. A
// root entry claiming more than 8 bits instead points at its second-level
// table, which is indexed by the next (claimed - 8) bits and whose
// entries count only the bits past the root.
@(private)
vp8l_build_table :: proc(lengths: []u8, out: []u16) -> (size: int, root_bits: uint, ok: bool) {
	count: [16]int
	for l in lengths do count[l] += 1
	nsym := len(lengths) - count[0]
	if nsym == 0 do return
	if nsym == 1 {
		if out != nil {
			for l, s in lengths {
				if l != 0 {
					out[0] = u16(s)
					break
				}
			}
		}
		return 1, 0, true
	}
	// Kraft's sum, in units of a 15-bit code: anything but exactly full is
	// over-subscribed or incomplete.
	space := 0
	for l in 1 ..= 15 do space += count[l] << uint(15 - l)
	if space != 1 << 15 do return
	if out == nil do return 0, 0, true
	max_len := 15
	for count[max_len] == 0 do max_len -= 1
	root := min(max_len, VP8L_ROOT_BITS)

	// Canonical order: by length, then by symbol.
	offs: [16]int
	for l in 1 ..< 15 do offs[l + 1] = offs[l] + count[l]
	sorted: [VP8L_MAX_ALPHABET]u16 = ---
	for l, s in lengths {
		if l != 0 {
			sorted[offs[l]] = u16(s)
			offs[l] += 1
		}
	}

	// Codes are read first bit lowest, so tables are indexed by the code
	// bit-reversed; key is the next code so reversed.
	root_size := 1 << uint(root)
	total := root_size
	key, sym := 0, 0
	for l in 1 ..= root {
		step := 1 << uint(l)
		for _ in 0 ..< count[l] {
			e := u16(l) << 12 | sorted[sym]
			for i := key; i < root_size; i += step do out[i] = e
			sym += 1
			key = vp8l_next_key(key, l)
		}
	}
	left := count
	low := -1
	sub, sub_size := 0, 0
	for l in root + 1 ..= 15 {
		step := 1 << uint(l - root)
		for left[l] > 0 {
			if key & (root_size - 1) != low {
				low = key & (root_size - 1)
				bits := vp8l_sub_table_bits(&left, l, root)
				sub = total
				sub_size = 1 << uint(bits)
				total += sub_size
				if total > len(out) do return
				out[low] = u16(root + bits) << 12 | u16(sub)
			}
			e := u16(l - root) << 12 | sorted[sym]
			for i := key >> uint(root); i < sub_size; i += step do out[sub + i] = e
			sym += 1
			key = vp8l_next_key(key, l)
			left[l] -= 1
		}
	}
	return total, uint(root), true
}

// vp8l_next_key steps a bit-reversed code of length l to the next code.
@(private)
vp8l_next_key :: proc(key, l: int) -> int {
	step := 1 << uint(l - 1)
	for key & step != 0 do step >>= 1
	return (key & (step - 1)) + step if step != 0 else key
}

// vp8l_sub_table_bits is how many bits the second-level table starting
// with a code of length l needs to hold every code that shares its root.
@(private)
vp8l_sub_table_bits :: proc(left: ^[16]int, l, root: int) -> int {
	n := l
	room := 1 << uint(l - root)
	for n < 15 {
		room -= left[n]
		if room <= 0 do break
		n += 1
		room <<= 1
	}
	return n - root
}

// vp8l_decode_pixels decodes width×height pixels into out: literals,
// copies and colour-cache references.
@(private)
vp8l_decode_pixels :: proc(d: ^Vp8l_Decoder, hf: ^Vp8l_Huff, out: []u32, width, height: int) -> bool {
	br := &d.br
	tabs := hf.tables[:]
	total := width * height
	cache: [1 << VP8L_MAX_CACHE_BITS]u32
	use_cache := hf.cache_bits > 0
	cache_size := 1 << hf.cache_bits if use_cache else 0
	cache_shift := 32 - hf.cache_bits
	cached := 0 // pixels before this one are in the cache
	// With one group, the mask only matches at the start of a row.
	mask := -1 if hf.meta == nil else (1 << hf.meta_bits) - 1
	pos, x, y := 0, 0, 0
	g := &hf.groups[0]
	for pos < total {
		if x & mask == 0 do g = vp8l_group_at(hf, x, y)
		vp8l_refill(br)
		sym: int
		if g.trivial_pixel {
			out[pos] = g.literal
		} else if sym = vp8l_read_symbol(br, tabs, g.codes[0]); sym < 256 {
			if g.trivial_literal {
				out[pos] = g.literal | u32(sym) << 8
			} else {
				r := vp8l_read_symbol(br, tabs, g.codes[1])
				vp8l_refill(br)
				b := vp8l_read_symbol(br, tabs, g.codes[2])
				a := vp8l_read_symbol(br, tabs, g.codes[3])
				out[pos] = u32(a) << 24 | u32(r) << 16 | u32(sym) << 8 | u32(b)
			}
		} else if sym < 256 + 24 {
			length := vp8l_prefix_value(br, sym - 256)
			vp8l_refill(br)
			dist := vp8l_plane_distance(width, vp8l_prefix_value(br, vp8l_read_symbol(br, tabs, g.codes[4])))
			if dist > pos || length > total - pos do return false
			src := pos - dist
			if dist >= length {
				copy(out[pos:pos + length], out[src:src + length])
			} else {
				for i in 0 ..< length do out[pos + i] = out[src + i]
			}
			pos += length
			x += length
			if x >= width {
				y += x / width
				x %= width
				if vp8l_eos(br) do return false
			}
			if pos < total && x & mask != 0 do g = vp8l_group_at(hf, x, y)
			if use_cache {
				for ; cached < pos; cached += 1 {
					c := out[cached]
					cache[(c * 0x1e35a7bd) >> cache_shift] = c
				}
			}
			continue
		} else {
			key := sym - (256 + 24)
			if key >= cache_size do return false
			for ; cached < pos; cached += 1 {
				c := out[cached]
				cache[(c * 0x1e35a7bd) >> cache_shift] = c
			}
			out[pos] = cache[key]
		}
		pos += 1
		x += 1
		if x >= width {
			x = 0
			y += 1
			if vp8l_eos(br) do return false
			if use_cache {
				for ; cached < pos; cached += 1 {
					c := out[cached]
					cache[(c * 0x1e35a7bd) >> cache_shift] = c
				}
			}
		}
	}
	return !vp8l_eos(br)
}

@(private)
vp8l_group_at :: #force_inline proc(hf: ^Vp8l_Huff, x, y: int) -> ^Vp8l_Group {
	if hf.meta == nil do return &hf.groups[0]
	return &hf.groups[hf.meta[(y >> hf.meta_bits) * hf.meta_w + (x >> hf.meta_bits)]]
}

// vp8l_prefix_value turns a length or distance prefix code and its extra
// bits into the value, 1..4096 for lengths and 1..1048576 for distances.
@(private)
vp8l_prefix_value :: #force_inline proc(br: ^Vp8l_Bits, code: int) -> int {
	if code < 4 do return code + 1
	extra := uint(code - 2) >> 1
	offset := (2 + (code & 1)) << extra
	return offset + int(vp8l_read_bits(br, extra)) + 1
}

// vp8l_plane_distance maps a distance code to a distance in pixels: the
// first 120 name nearby pixels, the rest count back in scan order.
@(private)
vp8l_plane_distance :: #force_inline proc(width, code: int) -> int {
	if code > 120 do return code - 120
	xi := int(VP8L_DISTANCE_MAP[2 * (code - 1)])
	yi := int(VP8L_DISTANCE_MAP[2 * (code - 1) + 1])
	dist := xi + yi * width
	return dist if dist >= 1 else 1
}

@(private)
vp8l_subsample :: #force_inline proc(size: int, bits: uint) -> int {
	return (size + (1 << bits) - 1) >> bits
}

// vp8l_refill tops the bit buffer up to at least 56 bits.
@(private)
vp8l_refill :: #force_inline proc(br: ^Vp8l_Bits) {
	if br.pos + 8 <= len(br.data) {
		br.val |= endian.unchecked_get_u64le(br.data[br.pos:]) << br.nbits
		n := (63 - br.nbits) >> 3
		br.pos += int(n)
		br.nbits += n << 3
		return
	}
	for br.nbits <= 55 {
		if br.pos < len(br.data) {
			br.val |= u64(br.data[br.pos]) << br.nbits
			br.pos += 1
		} else {
			br.overrun += 1
		}
		br.nbits += 8
	}
}

@(private)
vp8l_skip :: #force_inline proc(br: ^Vp8l_Bits, n: uint) {
	br.val >>= n
	br.nbits -= n
}

// vp8l_read_bits reads n bits, n at most 32.
@(private)
vp8l_read_bits :: #force_inline proc(br: ^Vp8l_Bits, n: uint) -> u32 {
	if br.nbits < n do vp8l_refill(br)
	v := u32(br.val & ((u64(1) << n) - 1))
	vp8l_skip(br, n)
	return v
}

// vp8l_read_symbol decodes one symbol; the buffer must hold 15 bits.
@(private)
vp8l_read_symbol :: #force_inline proc(br: ^Vp8l_Bits, tabs: []u16, c: Vp8l_Code) -> int {
	e := tabs[int(c.off) + int(u32(br.val) & c.mask)]
	n := uint(e >> 12)
	if n > VP8L_ROOT_BITS {
		sub := u32(br.val >> VP8L_ROOT_BITS) & ((1 << (n - VP8L_ROOT_BITS)) - 1)
		e = tabs[int(c.off) + int(e & 0xfff) + int(sub)]
		n = VP8L_ROOT_BITS + uint(e >> 12)
	}
	vp8l_skip(br, n)
	return int(e & 0xfff)
}

// vp8l_eos says whether bits past the end of the data have been read.
@(private)
vp8l_eos :: #force_inline proc(br: ^Vp8l_Bits) -> bool {
	return br.overrun * 8 > int(br.nbits)
}

@(private)
vp8l_bits_left :: proc(br: ^Vp8l_Bits) -> int {
	return (len(br.data) - br.pos) * 8 + int(br.nbits) - br.overrun * 8
}

// Per-channel arithmetic on packed ARGB, each byte wrapping on its own.

@(private)
vp8l_add :: #force_inline proc "contextless" (a, b: u32) -> u32 {
	// The low seven bits of each byte add without reaching the next byte;
	// the top bit is their carry exclusive-or the two top bits.
	return ((a & 0x7f7f7f7f) + (b & 0x7f7f7f7f)) ~ ((a ~ b) & 0x80808080)
}

@(private)
vp8l_average2 :: #force_inline proc "contextless" (a, b: u32) -> u32 {
	return (((a ~ b) & 0xfefefefe) >> 1) + (a & b)
}

// vp8l_select picks L or T, whichever is nearer the estimate L + T - TL
// over the four channels; T on a tie.
@(private)
vp8l_select :: #force_inline proc "contextless" (l, t, tl: u32) -> u32 {
	// |estimate - L| is |T - TL| per channel, and |estimate - T| is |L - TL|.
	diff :: #force_inline proc "contextless" (a, b: u32, s: uint) -> int {
		return abs(int((a >> s) & 0xff) - int((b >> s) & 0xff))
	}
	pl := diff(t, tl, 0) + diff(t, tl, 8) + diff(t, tl, 16) + diff(t, tl, 24)
	pt := diff(l, tl, 0) + diff(l, tl, 8) + diff(l, tl, 16) + diff(l, tl, 24)
	return l if pl < pt else t
}

@(private)
vp8l_clamp255 :: #force_inline proc "contextless" (v: int) -> u32 {
	return 0 if v < 0 else 255 if v > 255 else u32(v)
}

@(private)
vp8l_clamp_add_subtract_full :: #force_inline proc "contextless" (a, b, c: u32) -> u32 {
	ch :: #force_inline proc "contextless" (a, b, c: u32, s: uint) -> u32 {
		v := int((a >> s) & 0xff) + int((b >> s) & 0xff) - int((c >> s) & 0xff)
		return vp8l_clamp255(v) << s
	}
	return ch(a, b, c, 24) | ch(a, b, c, 16) | ch(a, b, c, 8) | ch(a, b, c, 0)
}

@(private)
vp8l_clamp_add_subtract_half :: #force_inline proc "contextless" (a, b: u32) -> u32 {
	// Division truncates toward zero, as the spec's C does.
	ch :: #force_inline proc "contextless" (a, b: u32, s: uint) -> u32 {
		x := int((a >> s) & 0xff)
		y := int((b >> s) & 0xff)
		return vp8l_clamp255(x + (x - y) / 2) << s
	}
	return ch(a, b, 24) | ch(a, b, 16) | ch(a, b, 8) | ch(a, b, 0)
}

// vp8l_inverse_predictor adds each pixel's prediction from its already
// restored neighbours. The top row predicts from the left, the left
// column from above; a block's mode is its sub-image pixel's green.
@(private)
vp8l_inverse_predictor :: proc(t: ^Vp8l_Transform, px: []u32, height: int) {
	w := t.xsize
	px[0] = vp8l_add(px[0], 0xff000000)
	for i in 1 ..< w do px[i] = vp8l_add(px[i], px[i - 1])
	tile := 1 << t.bits
	tiles_w := vp8l_subsample(w, t.bits)
	for y in 1 ..< height {
		row := y * w
		modes := t.data[(y >> t.bits) * tiles_w:][:tiles_w]
		px[row] = vp8l_add(px[row], px[row - w])
		x := 1
		for x < w {
			// Modes 14 and 15 do not exist; libwebp predicts black for them.
			mode := (modes[x >> t.bits] >> 8) & 0xf
			end := min((x &~ (tile - 1)) + tile, w)
			// The span with its left neighbour, and the row above it from the
			// top-left of its first pixel to the top-right of its last. The
			// last pixel's top-right is this row's first pixel, which comes
			// straight after the row above.
			vp8l_predict_span(px[row + x - 1:row + end], px[row + x - 1 - w:row + end - w + 1], mode)
			x = end
		}
	}
}

// vp8l_predict_span restores cur[1:] with one mode. For cur[k], cur[k-1]
// is L, and above[k-1], above[k] and above[k+1] are TL, T and TR.
@(private)
vp8l_predict_span :: proc(cur, above: []u32, mode: u32) {
	n := len(cur) - 1
	// Always true; checked once so the loops below need no per-pixel checks.
	if n < 1 || len(above) != n + 2 do return
	#no_bounds_check switch mode {
	case 1:
		for k in 1 ..= n do cur[k] = vp8l_add(cur[k], cur[k - 1])
	case 2:
		for k in 1 ..= n do cur[k] = vp8l_add(cur[k], above[k])
	case 3:
		for k in 1 ..= n do cur[k] = vp8l_add(cur[k], above[k + 1])
	case 4:
		for k in 1 ..= n do cur[k] = vp8l_add(cur[k], above[k - 1])
	case 5:
		for k in 1 ..= n do cur[k] = vp8l_add(cur[k], vp8l_average2(vp8l_average2(cur[k - 1], above[k + 1]), above[k]))
	case 6:
		for k in 1 ..= n do cur[k] = vp8l_add(cur[k], vp8l_average2(cur[k - 1], above[k - 1]))
	case 7:
		for k in 1 ..= n do cur[k] = vp8l_add(cur[k], vp8l_average2(cur[k - 1], above[k]))
	case 8:
		for k in 1 ..= n do cur[k] = vp8l_add(cur[k], vp8l_average2(above[k - 1], above[k]))
	case 9:
		for k in 1 ..= n do cur[k] = vp8l_add(cur[k], vp8l_average2(above[k], above[k + 1]))
	case 10:
		for k in 1 ..= n {
			p := vp8l_average2(vp8l_average2(cur[k - 1], above[k - 1]), vp8l_average2(above[k], above[k + 1]))
			cur[k] = vp8l_add(cur[k], p)
		}
	case 11:
		for k in 1 ..= n do cur[k] = vp8l_add(cur[k], vp8l_select(cur[k - 1], above[k], above[k - 1]))
	case 12:
		for k in 1 ..= n do cur[k] = vp8l_add(cur[k], vp8l_clamp_add_subtract_full(cur[k - 1], above[k], above[k - 1]))
	case 13:
		for k in 1 ..= n do cur[k] = vp8l_add(cur[k], vp8l_clamp_add_subtract_half(vp8l_average2(cur[k - 1], above[k]), above[k - 1]))
	case:
		for k in 1 ..= n do cur[k] = vp8l_add(cur[k], 0xff000000)
	}
}

// vp8l_inverse_cross_color adds back the red and blue each block's
// multipliers took away: green to red, green to blue, red to blue, each a
// signed 3.5 fixed-point factor on a signed channel.
@(private)
vp8l_inverse_cross_color :: proc(t: ^Vp8l_Transform, px: []u32, height: int) {
	w := t.xsize
	tile := 1 << t.bits
	tiles_w := vp8l_subsample(w, t.bits)
	for y in 0 ..< height {
		row := y * w
		elems := t.data[(y >> t.bits) * tiles_w:][:tiles_w]
		for m, tx in elems {
			g2r := i32(i8(u8(m)))
			g2b := i32(i8(u8(m >> 8)))
			r2b := i32(i8(u8(m >> 16)))
			x0 := tx << t.bits
			x1 := min(x0 + tile, w)
			for &v in px[row + x0:row + x1] {
				green := i32(i8(u8(v >> 8)))
				red := (i32((v >> 16) & 0xff) + ((g2r * green) >> 5)) & 0xff
				blue := i32(v & 0xff) + ((g2b * green) >> 5)
				blue = (blue + ((r2b * i32(i8(u8(red)))) >> 5)) & 0xff
				v = (v & 0xff00ff00) | u32(red) << 16 | u32(blue)
			}
		}
	}
}

@(private)
vp8l_inverse_subtract_green :: proc(px: []u32) {
	for &v in px {
		g := (v >> 8) & 0xff
		v = (v & 0xff00ff00) | ((v & 0x00ff00ff) + (g << 16 | g)) & 0x00ff00ff
	}
}

// vp8l_inverse_color_indexing looks each index up in the colour table,
// whose entries are stored as differences from the one before. Indices
// past the table give transparent black. With 16 colours or fewer several
// indices share a pixel, so the image widens back to t.xsize; it is
// rebuilt from the end so no packed pixel is overwritten before it is read.
@(private)
vp8l_inverse_color_indexing :: proc(t: ^Vp8l_Transform, px: []u32, height: int) {
	w := t.xsize
	palette: [256]u32
	palette[0] = t.data[0]
	for i in 1 ..< len(t.data) do palette[i] = vp8l_add(t.data[i], palette[i - 1])
	if t.bits == 0 {
		for &v in px[:w * height] do v = palette[(v >> 8) & 0xff]
		return
	}
	packed_w := vp8l_subsample(w, t.bits)
	bpp := uint(8) >> t.bits
	index_mask := u32(1 << bpp) - 1
	xmask := (1 << t.bits) - 1
	for y := height - 1; y >= 0; y -= 1 {
		for x := w - 1; x >= 0; x -= 1 {
			packed := (px[y * packed_w + (x >> t.bits)] >> 8) & 0xff
			px[y * w + x] = palette[(packed >> (uint(x & xmask) * bpp)) & index_mask]
		}
	}
}

@(private)
vp8l_alloc_pixels :: proc(n: int, allocator: mem.Allocator) -> ([]u32, bool) {
	b, err := mem.alloc_bytes_non_zeroed(n * size_of(u32), align_of(u32), allocator)
	if err != nil do return nil, false
	return slice.reinterpret([]u32, b), true
}

@(private)
vp8l_free_pixels :: proc(px: []u32, allocator: mem.Allocator) {
	if px != nil do mem.free_bytes(slice.to_bytes(px), allocator)
}

@(private)
vp8l_free_huff :: proc(d: ^Vp8l_Decoder, hf: ^Vp8l_Huff) {
	d.budget += len(hf.tables)
	delete(hf.tables)
	delete(hf.groups, d.allocator)
	vp8l_free_pixels(hf.meta, d.allocator)
	hf^ = {}
}

@(private)
vp8l_free_transforms :: proc(d: ^Vp8l_Decoder) {
	for &t in d.transforms[:d.num_transforms] {
		vp8l_free_pixels(t.data, d.allocator)
		t.data = nil
	}
	d.num_transforms = 0
}
