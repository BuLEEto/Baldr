package baldr

// Writing PNG: a picture copied to the clipboard goes as
// image/png, and an image editor saves and exports the same way. Odin's
// core reads PNG but does not write it, and the dependency rule keeps zlib
// out, so the deflate compressor is here: LZ77 over a 32 KB window (hash
// chains, one step of lazy matching), each block coded with Huffman codes
// built for it (RFC 1951's dynamic blocks), and a block that would not
// shrink stored as it is. Each row takes the PNG filter that leaves it
// smallest by the usual measure (the sum of its bytes as signed values).

import "core:hash"
import "core:mem/virtual"

// image_encode_png is `img` as a PNG file: 8-bit RGBA, or RGB when every
// pixel is opaque, straight alpha as the Image has it. The bytes are
// `allocator`'s; false for an empty or malformed Image. Safe on any thread
// (it reads only `img`).
image_encode_png :: proc(img: ^Image, allocator := context.allocator) -> (png: []u8, ok: bool) {
	if img == nil do return
	return png_encode(img.width, img.height, img.pixels, allocator)
}

// png_encode is `pixels` (w × h RGBA8, straight alpha) as a PNG file.
@(private)
png_encode :: proc(w, h: int, pixels: []u8, allocator := context.allocator) -> (png: []u8, ok: bool) {
	if w <= 0 || h <= 0 || w > 1 << 24 || h > 1 << 24 || len(pixels) < w * h * 4 do return
	arena: virtual.Arena // scratch of its own: a worker's temp memory is never given back
	if virtual.arena_init_growing(&arena) != nil do return
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	opaque := true
	for i := 3; i < w * h * 4; i += 4 do if pixels[i] != 255 {
		opaque = false
		break
	}
	bpp := 3 if opaque else 4
	stride := w * bpp
	raw := make([]u8, h * (stride + 1), context.temp_allocator) // each row: its filter, then its bytes
	defer delete(raw, context.temp_allocator)
	row := make([]u8, stride, context.temp_allocator)
	prev := make([]u8, stride, context.temp_allocator) // the row above, zeros for the first
	defer delete(row, context.temp_allocator)
	defer delete(prev, context.temp_allocator)
	for y in 0 ..< h {
		src := pixels[y * w * 4:][:w * 4]
		if opaque {
			for x in 0 ..< w do copy(row[x * 3:][:3], src[x * 4:][:3])
		} else {
			copy(row, src)
		}
		out := raw[y * (stride + 1):][:stride + 1]
		png_filter(row, prev, bpp, out)
		row, prev = prev, row
	}
	z := zlib_compress(raw, context.temp_allocator)
	defer delete(z, context.temp_allocator)

	buf := make([dynamic]u8, 0, len(z) + 64, allocator)
	append(&buf, 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n')
	ihdr: [13]u8
	be_put32(ihdr[0:], u32(w))
	be_put32(ihdr[4:], u32(h))
	ihdr[8] = 8                     // bits per channel
	ihdr[9] = 2 if opaque else 6    // RGB, or RGB with alpha
	png_chunk(&buf, "IHDR", ihdr[:])
	png_chunk(&buf, "sRGB", {0})    // the pixels are sRGB (perceptual intent)
	png_chunk(&buf, "IDAT", z)
	png_chunk(&buf, "IEND", nil)
	return buf[:], true
}

@(private)
be_put32 :: proc "contextless" (b: []u8, v: u32) {
	b[0], b[1], b[2], b[3] = u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)
}

@(private)
png_chunk :: proc(buf: ^[dynamic]u8, kind: string, data: []u8) {
	n: [4]u8
	be_put32(n[:], u32(len(data)))
	append(buf, ..n[:])
	start := len(buf)
	append(buf, ..transmute([]u8)kind)
	append(buf, ..data)
	crc: [4]u8
	be_put32(crc[:], hash.crc32(buf[start:]))
	append(buf, ..crc[:])
}

// png_filter writes `row` into `out` as its filter byte and filtered bytes,
// by whichever of PNG's five filters leaves the smallest sum of magnitudes.
@(private)
png_filter :: proc(row, prev: []u8, bpp: int, out: []u8) {
	paeth :: proc "contextless" (a, b, c: u8) -> u8 {
		p := int(a) + int(b) - int(c)
		pa, pb, pc := abs(p - int(a)), abs(p - int(b)), abs(p - int(c))
		if pa <= pb && pa <= pc do return a
		if pb <= pc do return b
		return c
	}
	filtered :: proc "contextless" (kind, i, bpp: int, row, prev: []u8) -> u8 {
		a := row[i - bpp] if i >= bpp else 0
		b := prev[i]
		c := prev[i - bpp] if i >= bpp else 0
		switch kind {
		case 1: return row[i] - a
		case 2: return row[i] - b
		case 3: return row[i] - u8((int(a) + int(b)) / 2)
		case 4: return row[i] - paeth(a, b, c)
		}
		return row[i]
	}
	best, best_cost := 0, max(int)
	for kind in 0 ..< 5 {
		cost := 0
		for i in 0 ..< len(row) {
			v := filtered(kind, i, bpp, row, prev)
			cost += int(v) if v < 128 else 256 - int(v)
			if cost >= best_cost do break
		}
		if cost < best_cost do best, best_cost = kind, cost
	}
	out[0] = u8(best)
	for i in 0 ..< len(row) do out[i + 1] = filtered(best, i, bpp, row, prev)
}

// Deflate (RFC 1950 / 1951)

@(private = "file")
WINDOW :: 1 << 15
@(private = "file")
HASH_BITS :: 15
@(private = "file")
MAX_CHAIN :: 96 // how many earlier places a match is looked for at
@(private = "file")
GOOD_ENOUGH :: 128 // a match this long is taken without looking further
@(private = "file")
MIN_MATCH :: 3
@(private = "file")
MAX_MATCH :: 258
@(private = "file")
BLOCK_TOKENS :: 1 << 15 // tokens per block: codes are built again for each

@(private = "file")
LEN_BASE := [29]u16{3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258}
@(private = "file")
LEN_EXTRA := [29]u8{0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0}
@(private = "file")
DIST_BASE := [30]u16{1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577}
@(private = "file")
DIST_EXTRA := [30]u8{0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13}
@(private = "file")
CL_ORDER := [19]u8{16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15}

// Token is a literal byte (dist 0) or a match of `len` bytes `dist` back.
@(private = "file")
Token :: struct {
	len:  u16, // the literal byte when dist is 0
	dist: u16,
}

@(private = "file")
Bits :: struct {
	out:  [dynamic]u8,
	acc:  u64,
	n:    uint,
}

@(private = "file")
bits_put :: proc(b: ^Bits, v: u32, n: uint) {
	b.acc |= u64(v) << b.n
	b.n += n
	for b.n >= 8 {
		append(&b.out, u8(b.acc))
		b.acc >>= 8
		b.n -= 8
	}
}

@(private = "file")
bits_align :: proc(b: ^Bits) {
	if b.n > 0 do bits_put(b, 0, 8 - b.n)
}

// zlib_compress is `src` as a zlib stream.
@(private)
zlib_compress :: proc(src: []u8, allocator := context.allocator) -> []u8 {
	b := Bits{out = make([dynamic]u8, 0, len(src) / 2 + 64, allocator)}
	append(&b.out, 0x78, 0x9C) // deflate, 32 KB window, default level
	deflate(&b, src)
	bits_align(&b) // the last block's last bits
	a := hash.adler32(src)
	append(&b.out, u8(a >> 24), u8(a >> 16), u8(a >> 8), u8(a))
	return b.out[:]
}

// deflate codes `src` into `b` as blocks of up to BLOCK_TOKENS tokens.
@(private = "file")
deflate :: proc(b: ^Bits, src: []u8) {
	head := make([]i32, 1 << HASH_BITS, context.temp_allocator)
	defer delete(head, context.temp_allocator)
	prev := make([]i32, WINDOW, context.temp_allocator)
	defer delete(prev, context.temp_allocator)
	for &v in head do v = -1
	tokens := make([dynamic]Token, 0, BLOCK_TOKENS, context.temp_allocator)
	defer delete(tokens)
	hash3 :: proc "contextless" (s: []u8, i: int) -> int {
		v := u32(s[i]) | u32(s[i + 1]) << 8 | u32(s[i + 2]) << 16
		return int((v * 2654435761) >> (32 - HASH_BITS))
	}
	insert :: proc "contextless" (s: []u8, i: int, head, prev: []i32) {
		if i + MIN_MATCH > len(s) do return
		h := hash3(s, i)
		prev[i & (WINDOW - 1)] = head[h]
		head[h] = i32(i)
	}
	longest :: proc "contextless" (s: []u8, i: int, head, prev: []i32) -> (best_len, best_dist: int) {
		if i + MIN_MATCH > len(s) do return
		limit := min(MAX_MATCH, len(s) - i)
		cand := int(head[hash3(s, i)])
		for chain := 0; cand >= 0 && i - cand <= WINDOW - 1 && chain < MAX_CHAIN; chain += 1 {
			if cand < i && s[cand + best_len] == s[i + best_len] {
				n := 0
				for n < limit && s[cand + n] == s[i + n] do n += 1
				if n > best_len {
					best_len, best_dist = n, i - cand
					if n >= GOOD_ENOUGH || n == limit do break
				}
			}
			next := int(prev[cand & (WINDOW - 1)])
			if next >= cand do break // the slot was reused by a later place: the chain ends here
			cand = next
		}
		if best_len < MIN_MATCH do return 0, 0
		return
	}
	block_start := 0
	i := 0
	for i < len(src) {
		l, d := longest(src, i, head, prev)
		if l >= MIN_MATCH && l < GOOD_ENOUGH && i + 1 < len(src) { // lazy: a longer match one byte on wins
			insert(src, i, head, prev)
			l2, d2 := longest(src, i + 1, head, prev)
			if l2 > l {
				append(&tokens, Token{len = u16(src[i])})
				i += 1
				l, d = l2, d2
			} else {
				append(&tokens, Token{len = u16(l), dist = u16(d)})
				for k in i + 1 ..< i + l do insert(src, k, head, prev)
				i += l
				l = 0
			}
			if l == 0 {
				if len(tokens) >= BLOCK_TOKENS {
					block_write(b, tokens[:], src[block_start:i], false)
					clear(&tokens)
					block_start = i
				}
				continue
			}
		}
		if l >= MIN_MATCH {
			append(&tokens, Token{len = u16(l), dist = u16(d)})
			for k in i ..< i + l do insert(src, k, head, prev)
			i += l
		} else {
			append(&tokens, Token{len = u16(src[i])})
			insert(src, i, head, prev)
			i += 1
		}
		if len(tokens) >= BLOCK_TOKENS {
			block_write(b, tokens[:], src[block_start:i], false)
			clear(&tokens)
			block_start = i
		}
	}
	block_write(b, tokens[:], src[block_start:], true)
}

@(private = "file")
len_code :: proc "contextless" (n: int) -> int {
	c := 0
	for c + 1 < len(LEN_BASE) && int(LEN_BASE[c + 1]) <= n do c += 1
	return c
}

@(private = "file")
dist_code :: proc "contextless" (d: int) -> int {
	c := 0
	for c + 1 < len(DIST_BASE) && int(DIST_BASE[c + 1]) <= d do c += 1
	return c
}

// block_write codes one block with Huffman codes built for it, or stores
// `raw` (the bytes the tokens stand for) when that is smaller.
@(private = "file")
block_write :: proc(b: ^Bits, tokens: []Token, raw: []u8, last: bool) {
	lit_freq: [286]int
	dist_freq: [30]int
	for t in tokens {
		if t.dist == 0 {
			lit_freq[t.len] += 1
		} else {
			lit_freq[257 + len_code(int(t.len))] += 1
			dist_freq[dist_code(int(t.dist))] += 1
		}
	}
	lit_freq[256] = 1 // end of block
	lit_len: [286]u8
	dist_len: [30]u8
	huff_lengths(lit_freq[:], 15, lit_len[:])
	huff_lengths(dist_freq[:], 15, dist_len[:])
	nlit := 286
	for nlit > 257 && lit_len[nlit - 1] == 0 do nlit -= 1
	ndist := 30
	for ndist > 1 && dist_len[ndist - 1] == 0 do ndist -= 1

	// the code lengths, run-length coded (16: repeat the last 3–6 times;
	// 17, 18: 3–10 and 11–138 zeros)
	all: [286 + 30]u8
	copy(all[:], lit_len[:nlit])
	copy(all[nlit:], dist_len[:ndist])
	lens := all[:nlit + ndist]
	Rl :: struct { sym, extra: u8 }
	rl := make([dynamic]Rl, 0, len(lens), context.temp_allocator)
	defer delete(rl)
	for i := 0; i < len(lens); {
		v := lens[i]
		run := 1
		for i + run < len(lens) && lens[i + run] == v do run += 1
		i += run
		if v == 0 {
			for run >= 11 {
				n := min(run, 138)
				append(&rl, Rl{18, u8(n - 11)})
				run -= n
			}
			if run >= 3 {
				append(&rl, Rl{17, u8(run - 3)})
				run = 0
			}
		} else {
			append(&rl, Rl{v, 0})
			run -= 1
			for run >= 3 {
				n := min(run, 6)
				append(&rl, Rl{16, u8(n - 3)})
				run -= n
			}
		}
		for _ in 0 ..< run do append(&rl, Rl{v, 0})
	}
	cl_freq: [19]int
	for r in rl do cl_freq[r.sym] += 1
	cl_len: [19]u8
	huff_lengths(cl_freq[:], 7, cl_len[:])
	ncl := 19
	for ncl > 4 && cl_len[CL_ORDER[ncl - 1]] == 0 do ncl -= 1

	// its size in bits, against storing
	bits := 3 + 5 + 5 + 4 + 3 * ncl
	for r in rl {
		bits += int(cl_len[r.sym])
		switch r.sym {
		case 16: bits += 2
		case 17: bits += 3
		case 18: bits += 7
		}
	}
	for t in tokens {
		if t.dist == 0 {
			bits += int(lit_len[t.len])
			continue
		}
		lc, dc := len_code(int(t.len)), dist_code(int(t.dist))
		bits += int(lit_len[257 + lc]) + int(LEN_EXTRA[lc]) + int(dist_len[dc]) + int(DIST_EXTRA[dc])
	}
	bits += int(lit_len[256])
	stored := (len(raw) + 5 * max((len(raw) + 65534) / 65535, 1)) * 8 + 8
	if stored < bits {
		for off := 0; true; /**/ {
			n := min(len(raw) - off, 65535)
			end := last && off + n >= len(raw)
			bits_put(b, u32(end), 1)
			bits_put(b, 0, 2)
			bits_align(b)
			append(&b.out, u8(n), u8(n >> 8), u8(~u16(n)), u8(~u16(n) >> 8))
			append(&b.out, ..raw[off:][:n])
			off += n
			if off >= len(raw) do break
		}
		return
	}

	lit_code: [286]u16
	dist_code_bits: [30]u16
	cl_code: [19]u16
	huff_codes(lit_len[:], lit_code[:])
	huff_codes(dist_len[:], dist_code_bits[:])
	huff_codes(cl_len[:], cl_code[:])
	bits_put(b, u32(last), 1)
	bits_put(b, 2, 2) // dynamic Huffman
	bits_put(b, u32(nlit - 257), 5)
	bits_put(b, u32(ndist - 1), 5)
	bits_put(b, u32(ncl - 4), 4)
	for i in 0 ..< ncl do bits_put(b, u32(cl_len[CL_ORDER[i]]), 3)
	for r in rl {
		bits_put(b, u32(cl_code[r.sym]), uint(cl_len[r.sym]))
		switch r.sym {
		case 16: bits_put(b, u32(r.extra), 2)
		case 17: bits_put(b, u32(r.extra), 3)
		case 18: bits_put(b, u32(r.extra), 7)
		}
	}
	for t in tokens {
		if t.dist == 0 {
			bits_put(b, u32(lit_code[t.len]), uint(lit_len[t.len]))
			continue
		}
		lc, dc := len_code(int(t.len)), dist_code(int(t.dist))
		bits_put(b, u32(lit_code[257 + lc]), uint(lit_len[257 + lc]))
		if LEN_EXTRA[lc] > 0 do bits_put(b, u32(int(t.len) - int(LEN_BASE[lc])), uint(LEN_EXTRA[lc]))
		bits_put(b, u32(dist_code_bits[dc]), uint(dist_len[dc]))
		if DIST_EXTRA[dc] > 0 do bits_put(b, u32(int(t.dist) - int(DIST_BASE[dc])), uint(DIST_EXTRA[dc]))
	}
	bits_put(b, u32(lit_code[256]), uint(lit_len[256]))
}

// huff_lengths gives each used symbol a code length of at most `limit`
// bits: Huffman's, then evened out when a code runs longer than the
// limit. A lone symbol gets 1 bit, and so does a second one made
// up beside it, as decoders want two codes.
@(private = "file")
huff_lengths :: proc(freq: []int, limit: int, out: []u8) {
	for &v in out do v = 0
	Node :: struct { freq: int, left, right: int } // leaves are -1 - symbol
	used := make([dynamic]int, 0, len(freq), context.temp_allocator)
	defer delete(used)
	for f, s in freq do if f > 0 do append(&used, s)
	switch len(used) {
	case 0:
		out[0], out[1] = 1, 1
		return
	case 1:
		out[used[0]] = 1
		out[0 if used[0] != 0 else 1] = 1
		return
	}
	// build the tree: repeatedly join the two rarest
	nodes := make([dynamic]Node, 0, 2 * len(used), context.temp_allocator)
	defer delete(nodes)
	live := make([dynamic]int, 0, len(used), context.temp_allocator) // indices into nodes
	defer delete(live)
	for s in used {
		append(&nodes, Node{freq[s], -1 - s, -1 - s})
		append(&live, len(nodes) - 1)
	}
	for len(live) > 1 {
		a, b := -1, -1 // the two rarest
		for n, i in live {
			if a < 0 || nodes[n].freq < nodes[live[a]].freq {
				b = a
				a = i
			} else if b < 0 || nodes[n].freq < nodes[live[b]].freq {
				b = i
			}
		}
		na, nb := live[a], live[b]
		append(&nodes, Node{nodes[na].freq + nodes[nb].freq, na, nb})
		hi, lo := max(a, b), min(a, b)
		unordered_remove(&live, hi)
		unordered_remove(&live, lo)
		append(&live, len(nodes) - 1)
	}
	depth := make([]int, len(freq), context.temp_allocator)
	defer delete(depth, context.temp_allocator)
	Walk :: struct { node, d: int }
	stack := make([dynamic]Walk, context.temp_allocator)
	defer delete(stack)
	append(&stack, Walk{live[0], 0})
	for len(stack) > 0 {
		w := pop(&stack)
		n := nodes[w.node]
		if n.left < 0 {
			depth[-1 - n.left] = w.d
			continue
		}
		append(&stack, Walk{n.left, w.d + 1}, Walk{n.right, w.d + 1})
	}
	// how many codes of each length, the long ones pulled in to the limit
	count := make([]int, max(limit + 1, 64), context.temp_allocator)
	defer delete(count, context.temp_allocator)
	for s in used do count[min(depth[s], limit)] += 1
	total := 0
	for l in 1 ..= limit do total += count[l] << uint(limit - l)
	for total > 1 << uint(limit) { // over-full: lengthen a shorter code to make room
		count[limit] -= 1
		for l := limit - 1; l > 0; l -= 1 do if count[l] > 0 {
			count[l] -= 1
			count[l + 1] += 2
			break
		}
		total -= 1
	}
	// the most frequent symbols take the shortest codes
	order := make([]int, len(used), context.temp_allocator)
	defer delete(order, context.temp_allocator)
	copy(order, used[:])
	for i in 1 ..< len(order) { // insertion sort by depth, then by frequency: stable enough, and few symbols
		v := order[i]
		j := i
		for j > 0 && (depth[order[j - 1]] > depth[v] || (depth[order[j - 1]] == depth[v] && freq[order[j - 1]] < freq[v])) {
			order[j] = order[j - 1]
			j -= 1
		}
		order[j] = v
	}
	k := 0
	for l in 1 ..= limit do for _ in 0 ..< count[l] {
		out[order[k]] = u8(l)
		k += 1
	}
}

// huff_codes gives each length its canonical code (RFC 1951 3.2.2),
// bit-reversed for the least-significant-first writer.
@(private = "file")
huff_codes :: proc(lengths: []u8, out: []u16) {
	bl_count: [16]int
	for l in lengths do if l > 0 do bl_count[l] += 1
	next: [16]int
	code := 0
	for bits in 1 ..< 16 {
		code = (code + bl_count[bits - 1]) << 1
		next[bits] = code
	}
	for l, s in lengths {
		if l == 0 do continue
		c := next[l]
		next[l] += 1
		r := 0
		for i in 0 ..< int(l) do r |= ((c >> uint(i)) & 1) << uint(int(l) - 1 - i)
		out[s] = u16(r)
	}
}
