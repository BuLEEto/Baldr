package baldr

// A PNG is checked before Odin's decoder sees it. core:compress/zlib runs a
// truncated or malformed stream on: reading past the end gives zero bits,
// which keep decoding, and the output grows until it reaches
// COMPRESS_OUTPUT_ALLOCATE_MAX (4 GB). There `grow_buffer` stops growing
// without an error, and `repl_bytes` writes past its buffer with bounds
// checks off. A picture cut short by a download, or pasted by another
// program, must never reach it.
//
// png_sound inflates the pixel data without keeping it (RFC 1951): every
// code valid, every distance within what came before, and the stream ending
// just where the header says the pixels end. It is cheap next to decoding:
// no output is written, only counted.

// PNG_MAX_BYTES is the most pixel data (filter bytes included) a PNG may
// declare: 2 GB, beyond any picture a toolkit shows.
@(private)
PNG_MAX_BYTES :: 1 << 31

// png_sound says whether `data` is a PNG whose pixel data is whole and
// exactly the size its header declares.
@(private)
png_sound :: proc(data: []u8) -> bool {
	SIGNATURE :: [8]u8{0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'}
	if len(data) < 8 do return false
	sig := SIGNATURE
	for i in 0 ..< 8 do if data[i] != sig[i] do return false
	be32 :: proc "contextless" (b: []u8) -> int { return int(b[0]) << 24 | int(b[1]) << 16 | int(b[2]) << 8 | int(b[3]) }
	w, h, depth, kind, interlace := 0, 0, 0, 0, 0
	has_header := false
	idat := make([dynamic]u8, context.temp_allocator)
	defer delete(idat)
	for at := 8; at + 12 <= len(data); {
		n := be32(data[at:])
		if n < 0 || n > len(data) - at - 12 do return false
		tag := string(data[at + 4:][:4])
		body := data[at + 8:][:n]
		switch tag {
		case "IHDR":
			if n < 13 do return false
			w, h = be32(body), be32(body[4:])
			depth, kind, interlace = int(body[8]), int(body[9]), int(body[12])
			has_header = true
		case "IDAT":
			append(&idat, ..body)
		case "IEND":
			at = len(data)
			continue
		}
		at += 12 + n
	}
	if !has_header || w <= 0 || h <= 0 || interlace > 1 do return false
	channels := 0
	switch kind {
	case 0, 3: channels = 1
	case 2:    channels = 3
	case 4:    channels = 2
	case 6:    channels = 4
	case:      return false
	}
	switch depth {
	case 1, 2, 4, 8, 16:
	case: return false
	}
	bits := channels * depth
	expected := 0
	row_bytes :: proc "contextless" (w, bits: int) -> int { return (w * bits + 7) / 8 }
	if interlace == 0 {
		expected = h * (1 + row_bytes(w, bits))
	} else { // Adam7: seven passes, each its own rows with their filter bytes
		passes := [7][4]int{{0, 0, 8, 8}, {4, 0, 8, 8}, {0, 4, 4, 8}, {2, 0, 4, 4}, {0, 2, 2, 4}, {1, 0, 2, 2}, {0, 1, 1, 2}}
		for p in passes {
			pw := (w - p[0] + p[2] - 1) / p[2]
			ph := (h - p[1] + p[3] - 1) / p[3]
			if pw > 0 && ph > 0 do expected += ph * (1 + row_bytes(pw, bits))
		}
	}
	if expected <= 0 || expected > PNG_MAX_BYTES do return false
	return zlib_sound(idat[:], expected)
}

// Inflate_Check is the state of a dry inflate: where it is in the input,
// its bit buffer, and how many bytes it would have written.
@(private = "file")
Inflate_Check :: struct {
	src:    []u8,
	pos:    int,
	buf:    u32,
	count:  u32,
	out:    int,
	limit:  int,
	failed: bool,
}

@(private = "file")
Huff :: struct {
	count:  [16]i16,  // codes of each length
	symbol: [288]i16, // symbols in canonical order
}

@(private = "file")
need :: proc(s: ^Inflate_Check, n: u32) -> int {
	v := s.buf
	for s.count < n {
		if s.pos >= len(s.src) {
			s.failed = true // out of input: the stream was cut short
			return 0
		}
		v |= u32(s.src[s.pos]) << s.count
		s.pos += 1
		s.count += 8
	}
	s.buf = u32(u64(v) >> n)
	s.count -= n
	return int(v & ((1 << n) - 1))
}

// zlib_sound inflates a zlib stream without keeping its output, and says
// whether it is valid and comes to exactly `expected` bytes.
@(private)
zlib_sound :: proc(z: []u8, expected: int) -> bool {
	if len(z) < 6 do return false
	cmf, flg := int(z[0]), int(z[1])
	if cmf & 15 != 8 || cmf >> 4 > 7 || (cmf * 256 + flg) % 31 != 0 || flg & 0x20 != 0 do return false
	s := Inflate_Check{src = z[2:], limit = expected}
	for {
		last := need(&s, 1)
		kind := need(&s, 2)
		if s.failed do return false
		switch kind {
		case 0:
			if !check_stored(&s) do return false
		case 1:
			lit, dist: Huff
			lengths: [288 + 30]u8
			for i in 0 ..< 144 do lengths[i] = 8
			for i in 144 ..< 256 do lengths[i] = 9
			for i in 256 ..< 280 do lengths[i] = 7
			for i in 280 ..< 288 do lengths[i] = 8
			huff_build(&lit, lengths[:288])
			for i in 0 ..< 30 do lengths[i] = 5
			huff_build(&dist, lengths[:30])
			if !check_codes(&s, &lit, &dist) do return false
		case 2:
			if !check_dynamic(&s) do return false
		case:
			return false
		}
		if s.failed || s.out > expected do return false
		if last == 1 do break
	}
	return s.out == expected && s.pos + 4 <= len(s.src) // and its Adler-32 is there
}

@(private = "file")
check_stored :: proc(s: ^Inflate_Check) -> bool {
	s.buf, s.count = 0, 0 // to the byte
	if s.pos + 4 > len(s.src) do return false
	n := int(s.src[s.pos]) | int(s.src[s.pos + 1]) << 8
	nn := int(s.src[s.pos + 2]) | int(s.src[s.pos + 3]) << 8
	s.pos += 4
	if n != ~nn & 0xFFFF || s.pos + n > len(s.src) do return false
	s.pos += n
	s.out += n
	return s.out <= s.limit
}

// huff_build fills `h` from code lengths, and says how the code sits: 0
// complete, above 0 incomplete, below 0 over-subscribed (invalid).
@(private = "file")
huff_build :: proc(h: ^Huff, lengths: []u8) -> int {
	h.count = {}
	for l in lengths do h.count[l] += 1
	if int(h.count[0]) == len(lengths) do return 0 // no codes: complete, and never used
	left := 1
	for l in 1 ..< 16 {
		left <<= 1
		left -= int(h.count[l])
		if left < 0 do return left
	}
	offs: [16]int
	for l in 1 ..< 15 do offs[l + 1] = offs[l] + int(h.count[l])
	for l, sym in lengths do if l != 0 {
		h.symbol[offs[l]] = i16(sym)
		offs[l] += 1
	}
	return left
}

@(private = "file")
huff_decode :: proc(s: ^Inflate_Check, h: ^Huff) -> int {
	code, first, index := 0, 0, 0
	for l in 1 ..< 16 {
		code |= need(s, 1)
		if s.failed do return -1
		n := int(h.count[l])
		if code - n < first do return int(h.symbol[index + (code - first)])
		index += n
		first += n
		first <<= 1
		code <<= 1
	}
	return -1 // ran out of lengths: no such code
}

@(private = "file")
check_codes :: proc(s: ^Inflate_Check, lit, dist: ^Huff) -> bool {
	LEN_BASE := [29]int{3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258}
	LEN_EXTRA := [29]u32{0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0}
	DIST_BASE := [30]int{1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577}
	DIST_EXTRA := [30]u32{0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13}
	for {
		sym := huff_decode(s, lit)
		switch {
		case sym < 0:
			return false
		case sym < 256:
			s.out += 1
		case sym == 256:
			return true
		case:
			sym -= 257
			if sym >= 29 do return false
			n := LEN_BASE[sym] + need(s, LEN_EXTRA[sym])
			d := huff_decode(s, dist)
			if d < 0 || d >= 30 do return false
			back := DIST_BASE[d] + need(s, DIST_EXTRA[d])
			if s.failed || back > s.out do return false // before the start: what core would read out of bounds
			s.out += n
		}
		if s.out > s.limit do return false
	}
}

@(private = "file")
check_dynamic :: proc(s: ^Inflate_Check) -> bool {
	ORDER := [19]int{16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15}
	nlen := need(s, 5) + 257
	ndist := need(s, 5) + 1
	ncode := need(s, 4) + 4
	if s.failed || nlen > 286 || ndist > 30 do return false
	lengths: [320]u8
	for i in 0 ..< ncode do lengths[ORDER[i]] = u8(need(s, 3))
	cl: Huff
	if huff_build(&cl, lengths[:19]) != 0 do return false // the code-length code must be complete
	for &l in lengths[:19] do l = 0
	for i := 0; i < nlen + ndist; {
		sym := huff_decode(s, &cl)
		if sym < 0 do return false
		if sym < 16 {
			lengths[i] = u8(sym)
			i += 1
			continue
		}
		v: u8
		reps := 0
		switch sym {
		case 16:
			if i == 0 do return false
			v = lengths[i - 1]
			reps = 3 + need(s, 2)
		case 17: reps = 3 + need(s, 3)
		case:    reps = 11 + need(s, 7)
		}
		if s.failed || i + reps > nlen + ndist do return false
		for _ in 0 ..< reps {
			lengths[i] = v
			i += 1
		}
	}
	if lengths[256] == 0 do return false // no end of block
	lit, dist: Huff
	left := huff_build(&lit, lengths[:nlen])
	if left < 0 || (left > 0 && nlen - int(lit.count[0]) != 1) do return false
	left = huff_build(&dist, lengths[nlen:][:ndist])
	if left < 0 || (left > 0 && ndist - int(dist.count[0]) != 1) do return false
	return check_codes(s, &lit, &dist)
}
