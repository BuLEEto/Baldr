package baldr

// WebP's lossy pictures: one VP8 key frame (RFC 6386), turned into RGBA the
// way libwebp does it by default (bilinear "fancy" chroma upsampling and its
// fixed-point YUV to RGB), so a picture comes out byte for byte as libwebp,
// and so a browser, shows it. Where libwebp reads an unusual stream
// differently from the RFC's reference decoder, libwebp's reading is kept,
// and the place says so.
//
// The bytes come from strangers. The size is checked against max_pixels
// before anything is allocated; a partition that runs dry reads zeros and is
// marked spent, and a spent partition refuses the picture, as libwebp refuses
// it; every loop is bounded by the macroblock count.

import "base:intrinsics"
import "base:runtime"

// The working macroblock, laid out as libwebp lays it out: a row of
// samples above each plane and a column to its left, at a 32-byte stride.
@(private)
VP8_BPS :: 32
@(private)
VP8_Y_OFF :: VP8_BPS * 1 + 8
@(private)
VP8_U_OFF :: VP8_Y_OFF + VP8_BPS * 16 + VP8_BPS
@(private)
VP8_V_OFF :: VP8_U_OFF + 16
@(private)
VP8_WS_SIZE :: VP8_BPS * 17 + VP8_BPS * 9

// Macroblock luma modes, in the RFC's order.
@(private)
VP8_DC_PRED :: 0
@(private)
VP8_V_PRED :: 1
@(private)
VP8_H_PRED :: 2
@(private)
VP8_TM_PRED :: 3
@(private)
VP8_B_PRED :: 4

// Sub-block modes, in the RFC's order.
@(private)
VP8_B_DC_PRED :: 0
@(private)
VP8_B_TM_PRED :: 1
@(private)
VP8_B_VE_PRED :: 2
@(private)
VP8_B_HE_PRED :: 3
@(private)
VP8_B_LD_PRED :: 4
@(private)
VP8_B_RD_PRED :: 5
@(private)
VP8_B_VR_PRED :: 6
@(private)
VP8_B_VL_PRED :: 7
@(private)
VP8_B_HD_PRED :: 8
@(private)
VP8_B_HU_PRED :: 9

// The boolean decoder (RFC 6386 section 7), reading several bytes at a time
// as libwebp does. It ends in the same place libwebp's does: eof is set when
// the 8-bit window first needs a bit past the end, and zeros are read there.
@(private)
Vp8_Bits :: struct {
	data:  []u8,
	pos:   int, // the next byte to load
	value: u64, // loaded bits; the window is value >> bits
	bits:  int, // where the window sits; below 0 means load more
	range: u32, // the range minus one, 127..254 between reads
	eof:   bool,
}

@(private)
Vp8_Quant :: struct {
	y1, y2, uv: [2]i32, // DC and AC factors
}

@(private)
Vp8_Filter :: struct {
	limit:  int, // 2 * level + ilevel; 0 leaves the macroblock unfiltered
	ilevel: int,
	hev:    int,
	inner:  bool,
}

@(private)
VP8_MB :: struct {
	imodes:  [16]u8, // sub-block modes, or the 16x16 mode in [0]
	uvmode:  u8,
	segment: u8,
	is_i4x4: bool,
	skip:    bool,
}

@(private)
Vp8_Decoder :: struct {
	width, height:  int,
	mb_w, mb_h:     int,
	br:             Vp8_Bits,
	parts:          [8]Vp8_Bits,
	num_parts:      int,
	use_segment:    bool,
	update_map:     bool,
	seg_absolute:   bool,
	seg_quant:      [4]int,
	seg_filter:     [4]int,
	seg_probs:      [3]u8,
	filter_type:    int, // 0 none, 1 simple, 2 normal
	filter_level:   int,
	sharpness:      int,
	use_lf_delta:   bool,
	ref_lf_delta:   [4]int,
	mode_lf_delta:  [4]int,
	fstrengths:     [4][2]Vp8_Filter,
	dqm:            [4]Vp8_Quant,
	probs:          [4][8][3][11]u8,
	use_skip_proba: bool,
	skip_p:         u32,

	intra_t:        []u8, // 4 per macroblock: the sub-block modes along the bottom of the row above
	intra_l:        [4]u8,
	nz_t:           []u8, // per macroblock: bits 0-3 luma columns, 4-5 U, 6-7 V
	nz_dc_t:        []u8,
	nz_l, nz_dc_l:  u8,
	mbs:            []VP8_MB, // the current row
	finfo:          []Vp8_Filter, // the current row
	top_y:          []u8, // the bottom row of the row above, before filtering
	top_u, top_v:   []u8,
	y, u, v:        []u8, // the planes, a whole number of macroblocks
	ys, uvs:        int,

	ws:             [VP8_WS_SIZE]u8,
	coeffs:         [384]i16,
	nz:             [24]u8, // per block: one past the last coefficient read
}

@(private)
vp8_bits_init :: proc(br: ^Vp8_Bits, data: []u8) {
	br^ = {data = data, range = 255 - 1, bits = -8}
	vp8_bits_load(br)
}

@(private)
vp8_get_bit :: #force_inline proc "contextless" (br: ^Vp8_Bits, prob: u32) -> int {
	range := br.range
	if br.bits < 0 {
		vp8_bits_load(br)
	}
	pos := uint(br.bits)
	split := (range * prob) >> 8
	value := u32(br.value >> pos)
	bit := 0
	if value > split {
		range -= split
		br.value -= u64(split + 1) << pos
		bit = 1
	} else {
		range = split + 1
	}
	// Renormalise so the range is back in 128..255.
	shift := 7 ~ (31 - intrinsics.count_leading_zeros(range))
	range <<= shift
	br.bits -= int(shift)
	br.range = range - 1
	return bit
}

@(private)
vp8_bits_load :: proc "contextless" (br: ^Vp8_Bits) {
	if br.pos + 7 <= len(br.data) {
		d := br.data[br.pos:][:7]
		v := u64(d[0]) << 48 | u64(d[1]) << 40 | u64(d[2]) << 32 | u64(d[3]) << 24 | u64(d[4]) << 16 | u64(d[5]) << 8 | u64(d[6])
		br.value = br.value << 56 | v
		br.bits += 56
		br.pos += 7
	} else if br.pos < len(br.data) {
		br.value = br.value << 8 | u64(br.data[br.pos])
		br.bits += 8
		br.pos += 1
	} else {
		br.value <<= 8
		br.bits += 8
		br.eof = true
	}
}

@(private)
vp8_get_value :: proc(br: ^Vp8_Bits, n: int) -> int {
	v := 0
	for _ in 0 ..< n {
		v = v << 1 | vp8_get_bit(br, 0x80)
	}
	return v
}

@(private)
vp8_get_signed_value :: proc(br: ^Vp8_Bits, n: int) -> int {
	v := vp8_get_value(br, n)
	return -v if vp8_get_bit(br, 0x80) != 0 else v
}

@(private)
vp8_read_tree :: proc(br: ^Vp8_Bits, tree: []i8, probs: []u8) -> u8 {
	i := 0
	for {
		i = int(tree[i + vp8_get_bit(br, u32(probs[i >> 1]))])
		if i <= 0 do break
	}
	return u8(-i)
}

@(private)
vp8_clip :: #force_inline proc "contextless" (v, m: int) -> int {
	return 0 if v < 0 else (m if v > m else v)
}

// vp8_decode decodes a "VP8 " chunk's payload to RGBA8, alpha 255, in
// allocator; on failure nothing is left allocated. A picture of more than
// max_pixels is refused before anything is allocated.
//
// libwebp lets the last partition run on into the RIFF pad byte of an
// odd-sized chunk, so pass the payload with that byte, when the file has it,
// to refuse exactly what libwebp refuses. It decides only truncated streams.
@(private)
vp8_decode :: proc(data: []u8, max_pixels: int, allocator := context.allocator) -> (w, h: int, rgba: []u8, ok: bool) {
	if len(data) < 10 do return
	tag := u32(data[0]) | u32(data[1]) << 8 | u32(data[2]) << 16
	key_frame := tag & 1 == 0
	profile := (tag >> 1) & 7
	show := (tag >> 4) & 1
	part0_len := int(tag >> 5)
	if !key_frame || profile > 3 || show == 0 do return
	if data[3] != 0x9d || data[4] != 0x01 || data[5] != 0x2a do return
	// The top two bits of each size are an upscaling hint, which libwebp ignores.
	width := int(u32(data[6]) | u32(data[7]) << 8) & 0x3fff
	height := int(u32(data[8]) | u32(data[9]) << 8) & 0x3fff
	if width == 0 || height == 0 || width * height > max_pixels do return
	rest := data[10:]
	if part0_len > len(rest) do return

	dec: Vp8_Decoder
	dec.width, dec.height = width, height
	dec.mb_w, dec.mb_h = (width + 15) >> 4, (height + 15) >> 4
	if !vp8_parse_header(&dec, rest[:part0_len], rest[part0_len:]) do return

	if !vp8_alloc(&dec, allocator) {
		vp8_free(&dec, allocator)
		return
	}
	defer vp8_free(&dec, allocator)

	if !vp8_decode_frame(&dec) do return

	// Every byte is written, so the buffer need not be cleared first.
	out, err := runtime.mem_alloc_non_zeroed(width * height * 4, 16, allocator)
	if err != nil do return
	vp8_emit_rgba(&dec, out)
	return width, height, out, true
}

@(private)
vp8_parse_header :: proc(d: ^Vp8_Decoder, part0: []u8, after: []u8) -> bool {
	br := &d.br
	vp8_bits_init(br, part0)
	vp8_get_value(br, 1) // colour space: only one is defined
	vp8_get_value(br, 1) // clamping type: libwebp always clamps

	// A key frame starts with absolute segment values of zero, as libwebp
	// resets them (libvpx starts in delta mode; it matters only when
	// segments are on and carry no values).
	d.seg_absolute = true
	d.use_segment = vp8_get_value(br, 1) != 0
	if d.use_segment {
		d.update_map = vp8_get_value(br, 1) != 0
		if vp8_get_value(br, 1) != 0 {
			d.seg_absolute = vp8_get_value(br, 1) != 0
			for s in 0 ..< 4 {
				if vp8_get_value(br, 1) != 0 do d.seg_quant[s] = vp8_get_signed_value(br, 7)
			}
			for s in 0 ..< 4 {
				if vp8_get_value(br, 1) != 0 do d.seg_filter[s] = vp8_get_signed_value(br, 6)
			}
		}
		if d.update_map {
			for s in 0 ..< 3 {
				d.seg_probs[s] = 255
				if vp8_get_value(br, 1) != 0 do d.seg_probs[s] = u8(vp8_get_value(br, 8))
			}
		}
	}
	if br.eof do return false

	simple := vp8_get_value(br, 1) != 0
	d.filter_level = vp8_get_value(br, 6)
	d.sharpness = vp8_get_value(br, 3)
	d.use_lf_delta = vp8_get_value(br, 1) != 0
	if d.use_lf_delta && vp8_get_value(br, 1) != 0 {
		for i in 0 ..< 4 {
			if vp8_get_value(br, 1) != 0 do d.ref_lf_delta[i] = vp8_get_signed_value(br, 6)
		}
		for i in 0 ..< 4 {
			if vp8_get_value(br, 1) != 0 do d.mode_lf_delta[i] = vp8_get_signed_value(br, 6)
		}
	}
	d.filter_type = 0 if d.filter_level == 0 else (1 if simple else 2)
	if br.eof do return false

	// The token partitions. A size past the end is cut to what is there, as
	// libwebp cuts it; the last partition must hold at least a byte.
	d.num_parts = 1 << uint(vp8_get_value(br, 2))
	last := d.num_parts - 1
	if len(after) < 3 * last do return false
	start := 3 * last
	left := len(after) - start
	for p in 0 ..< last {
		size := int(after[3 * p]) | int(after[3 * p + 1]) << 8 | int(after[3 * p + 2]) << 16
		size = min(size, left)
		vp8_bits_init(&d.parts[p], after[start:][:size])
		start += size
		left -= size
	}
	vp8_bits_init(&d.parts[last], after[start:])
	if start >= len(after) {
		return false
	}

	vp8_parse_quant(d)

	vp8_get_value(br, 1) // refresh_entropy_probs: there is no next frame

	// Token probabilities: the defaults, with this frame's updates.
	updates := 0
	for t in 0 ..< 4 {
		for b in 0 ..< 8 {
			for c in 0 ..< 3 {
				for p in 0 ..< 11 {
					i := ((t * 8 + b) * 3 + c) * 11 + p
					if vp8_get_bit(br, u32(vp8_coeff_update_probs[i])) != 0 {
						d.probs[t][b][c][p] = u8(vp8_get_value(br, 8))
						updates += 1
					} else {
						d.probs[t][b][c][p] = vp8_default_coeff_probs[i]
					}
				}
			}
		}
	}
	d.use_skip_proba = vp8_get_value(br, 1) != 0
	if d.use_skip_proba do d.skip_p = u32(vp8_get_value(br, 8))

	vp8_filter_strengths(d)

	return true
}

@(private)
vp8_parse_quant :: proc(d: ^Vp8_Decoder) {
	br := &d.br
	base_q := vp8_get_value(br, 7)
	deltas: [5]int // y1 dc, y2 dc, y2 ac, uv dc, uv ac
	for i in 0 ..< 5 {
		if vp8_get_value(br, 1) != 0 do deltas[i] = vp8_get_signed_value(br, 4)
	}
	for s in 0 ..< 4 {
		// libwebp adds the deltas to the segment's index before clamping it;
		// libvpx clamps first. Only out-of-range indices tell them apart.
		q: int
		if d.use_segment {
			q = d.seg_quant[s]
			if !d.seg_absolute do q += base_q
		} else if s > 0 {
			d.dqm[s] = d.dqm[0]
			continue
		} else {
			q = base_q
		}
		m := &d.dqm[s]
		m.y1[0] = vp8_dc_qlookup[vp8_clip(q + deltas[0], 127)]
		m.y1[1] = vp8_ac_qlookup[vp8_clip(q, 127)]
		m.y2[0] = vp8_dc_qlookup[vp8_clip(q + deltas[1], 127)] * 2
		m.y2[1] = max(vp8_ac_qlookup[vp8_clip(q + deltas[2], 127)] * 155 / 100, 8)
		m.uv[0] = min(vp8_dc_qlookup[vp8_clip(q + deltas[3], 127)], 132)
		m.uv[1] = vp8_ac_qlookup[vp8_clip(q + deltas[4], 127)]
	}
}

@(private)
vp8_filter_strengths :: proc(d: ^Vp8_Decoder) {
	if d.filter_type == 0 do return
	for s in 0 ..< 4 {
		base := d.filter_level
		if d.use_segment {
			base = d.seg_filter[s]
			if !d.seg_absolute do base += d.filter_level
		}
		for i4 in 0 ..< 2 {
			// libwebp clamps once, after every delta; libvpx also clamps the
			// segment's level on its own first.
			level := base
			if d.use_lf_delta {
				level += d.ref_lf_delta[0]
				if i4 == 1 do level += d.mode_lf_delta[0]
			}
			level = vp8_clip(level, 63)
			f := &d.fstrengths[s][i4]
			f^ = {}
			if level > 0 {
				ilevel := level
				if d.sharpness > 0 {
					ilevel >>= uint(2 if d.sharpness > 4 else 1)
					ilevel = min(ilevel, 9 - d.sharpness)
				}
				ilevel = max(ilevel, 1)
				f.ilevel = ilevel
				f.limit = 2 * level + ilevel
				f.hev = 2 if level >= 40 else (1 if level >= 15 else 0)
			}
			f.inner = i4 == 1
		}
	}
}

@(private)
vp8_alloc :: proc(d: ^Vp8_Decoder, allocator: runtime.Allocator) -> bool {
	err: runtime.Allocator_Error
	d.ys = d.mb_w * 16
	d.uvs = d.mb_w * 8
	// Every macroblock writes its whole area of the planes before anything
	// reads it, so they need not be cleared first.
	if d.y, err = runtime.mem_alloc_non_zeroed(d.ys * d.mb_h * 16, 16, allocator); err != nil do return false
	if d.u, err = runtime.mem_alloc_non_zeroed(d.uvs * d.mb_h * 8, 16, allocator); err != nil do return false
	if d.v, err = runtime.mem_alloc_non_zeroed(d.uvs * d.mb_h * 8, 16, allocator); err != nil do return false
	if d.intra_t, err = make([]u8, 4 * d.mb_w, allocator); err != nil do return false
	if d.nz_t, err = make([]u8, d.mb_w, allocator); err != nil do return false
	if d.nz_dc_t, err = make([]u8, d.mb_w, allocator); err != nil do return false
	if d.mbs, err = make([]VP8_MB, d.mb_w, allocator); err != nil do return false
	if d.finfo, err = make([]Vp8_Filter, d.mb_w, allocator); err != nil do return false
	if d.top_y, err = make([]u8, d.ys, allocator); err != nil do return false
	if d.top_u, err = make([]u8, d.uvs, allocator); err != nil do return false
	if d.top_v, err = make([]u8, d.uvs, allocator); err != nil do return false
	return true
}

@(private)
vp8_free :: proc(d: ^Vp8_Decoder, allocator: runtime.Allocator) {
	delete(d.y, allocator)
	delete(d.u, allocator)
	delete(d.v, allocator)
	delete(d.intra_t, allocator)
	delete(d.nz_t, allocator)
	delete(d.nz_dc_t, allocator)
	delete(d.mbs, allocator)
	delete(d.finfo, allocator)
	delete(d.top_y, allocator)
	delete(d.top_u, allocator)
	delete(d.top_v, allocator)
	d.y, d.u, d.v = nil, nil, nil
}

@(private)
vp8_decode_frame :: proc(d: ^Vp8_Decoder) -> bool {
	for mb_y in 0 ..< d.mb_h {
		token_br := &d.parts[mb_y & (d.num_parts - 1)]
		d.intra_l = {}
		for mb_x in 0 ..< d.mb_w {
			vp8_parse_modes(d, mb_x)
		}
		if d.br.eof {
			return false
		}

		d.nz_l, d.nz_dc_l = 0, 0
		for mb_x in 0 ..< d.mb_w {
			mb := &d.mbs[mb_x]
			skip := d.use_skip_proba && mb.skip
			if !skip {
				skip = vp8_parse_residuals(d, mb_x, mb, token_br)
			} else {
				d.nz_l, d.nz_t[mb_x] = 0, 0
				if !mb.is_i4x4 {
					d.nz_dc_l, d.nz_dc_t[mb_x] = 0, 0
				}
			}
			if token_br.eof {
				return false
			}
			if d.filter_type > 0 {
				f := d.fstrengths[mb.segment][1 if mb.is_i4x4 else 0]
				f.inner = f.inner || !skip
				d.finfo[mb_x] = f
			}
			vp8_reconstruct(d, mb_x, mb_y, mb, skip)
		}

		// Keep the row's unfiltered bottom samples for the next row's
		// prediction; the loop filter is about to change them.
		copy(d.top_y, d.y[(mb_y * 16 + 15) * d.ys:][:d.ys])
		copy(d.top_u, d.u[(mb_y * 8 + 7) * d.uvs:][:d.uvs])
		copy(d.top_v, d.v[(mb_y * 8 + 7) * d.uvs:][:d.uvs])

		if d.filter_type > 0 do vp8_filter_row(d, mb_y)
	}
	return true
}

@(private)
vp8_parse_modes :: proc(d: ^Vp8_Decoder, mb_x: int) {
	br := &d.br
	mb := &d.mbs[mb_x]
	if d.update_map {
		if vp8_get_bit(br, u32(d.seg_probs[0])) == 0 {
			mb.segment = u8(vp8_get_bit(br, u32(d.seg_probs[1])))
		} else {
			mb.segment = u8(vp8_get_bit(br, u32(d.seg_probs[2])) + 2)
		}
	} else {
		mb.segment = 0
	}
	mb.skip = d.use_skip_proba && vp8_get_bit(br, d.skip_p) != 0

	top := d.intra_t[4 * mb_x:][:4]
	ymode := vp8_read_tree(br, vp8_kf_ymode_tree[:], vp8_kf_ymode_prob[:])
	if ymode == VP8_B_PRED {
		mb.is_i4x4 = true
		for y in 0 ..< 4 {
			m := d.intra_l[y]
			for x in 0 ..< 4 {
				probs := vp8_kf_bmode_prob[(int(top[x]) * 10 + int(m)) * 9:][:9]
				m = vp8_read_tree(br, vp8_bmode_tree[:], probs)
				top[x] = m
				mb.imodes[y * 4 + x] = m
			}
			d.intra_l[y] = m
		}
	} else {
		mb.is_i4x4 = false
		mb.imodes[0] = ymode
		// Later sub-blocks take their context from the 16x16 mode's twin.
		ctx: u8
		switch ymode {
		case VP8_DC_PRED: ctx = VP8_B_DC_PRED
		case VP8_V_PRED:  ctx = VP8_B_VE_PRED
		case VP8_H_PRED:  ctx = VP8_B_HE_PRED
		case:             ctx = VP8_B_TM_PRED
		}
		top[0], top[1], top[2], top[3] = ctx, ctx, ctx, ctx
		d.intra_l = {ctx, ctx, ctx, ctx}
	}
	mb.uvmode = vp8_read_tree(br, vp8_uv_mode_tree[:], vp8_kf_uv_mode_prob[:])
}

// vp8_get_coeffs reads one block's tokens from position first (RFC 6386
// section 13), dequantised into out in raster order. It returns where the
// end-of-block token came, or 16; like libwebp and libvpx, the neighbours'
// context is whether that is past first, so a run of zeros to the end counts.
@(private)
vp8_get_coeffs :: proc "contextless" (br: ^Vp8_Bits, probs: ^[8][3][11]u8, ctx: int, dq: [2]i32, first: int, out: []i16) -> int {
	n := first
	p := &probs[vp8_coeff_bands[n]][ctx]
	for n < 16 {
		if vp8_get_bit(br, u32(p[0])) == 0 do return n // end of block
		for vp8_get_bit(br, u32(p[1])) == 0 { 	// a zero; no end of block can follow one
			n += 1
			if n == 16 do return 16
			p = &probs[vp8_coeff_bands[n]][0]
		}
		v: int
		next: int
		if vp8_get_bit(br, u32(p[2])) == 0 {
			v = 1
			next = 1
		} else {
			v = vp8_large_value(br, p)
			next = 2
		}
		if vp8_get_bit(br, 0x80) != 0 do v = -v
		// Stored as 16 bits, as libwebp stores it.
		out[vp8_zigzag[n]] = i16(i32(v) * dq[1 if n > 0 else 0])
		n += 1
		if n < 16 do p = &probs[vp8_coeff_bands[n]][next]
	}
	return 16
}

// vp8_large_value reads a token of 2 or more and its extra bits.
@(private)
vp8_large_value :: proc "contextless" (br: ^Vp8_Bits, p: ^[11]u8) -> int {
	if vp8_get_bit(br, u32(p[3])) == 0 {
		if vp8_get_bit(br, u32(p[4])) == 0 do return 2
		return 3 + vp8_get_bit(br, u32(p[5]))
	}
	if vp8_get_bit(br, u32(p[6])) == 0 {
		if vp8_get_bit(br, u32(p[7])) == 0 {
			return 5 + vp8_get_bit(br, u32(vp8_pcat1[0]))
		}
		v := 7 + 2 * vp8_get_bit(br, u32(vp8_pcat2[0]))
		return v + vp8_get_bit(br, u32(vp8_pcat2[1]))
	}
	bit1 := vp8_get_bit(br, u32(p[8]))
	bit0 := vp8_get_bit(br, u32(p[9 + bit1]))
	cat := 2 * bit1 + bit0
	tab: []u8
	switch cat {
	case 0: tab = vp8_pcat3[:]
	case 1: tab = vp8_pcat4[:]
	case 2: tab = vp8_pcat5[:]
	case:   tab = vp8_pcat6[:]
	}
	v := 0
	for prob in tab {
		v = v + v + vp8_get_bit(br, u32(prob))
	}
	return v + 3 + (8 << uint(cat))
}

// vp8_parse_residuals reads a macroblock's coefficients, keeping the
// neighbours' non-zero contexts as libwebp keeps them. It returns whether
// the macroblock turned out to have nothing to add, which also spares its
// inner edges from the loop filter.
@(private)
vp8_parse_residuals :: proc(d: ^Vp8_Decoder, mb_x: int, mb: ^VP8_MB, br: ^Vp8_Bits) -> bool {
	q := d.dqm[mb.segment]
	d.coeffs = {}
	any_nz := false

	first: int
	ac_probs: ^[8][3][11]u8
	if !mb.is_i4x4 {
		// The luma DCs come in their own block, through the WHT.
		dc: [16]i16
		ctx := int(d.nz_dc_t[mb_x] + d.nz_dc_l)
		n := vp8_get_coeffs(br, &d.probs[1], ctx, q.y2, 0, dc[:])
		flag := u8(1 if n > 0 else 0)
		d.nz_dc_t[mb_x], d.nz_dc_l = flag, flag
		if n > 1 {
			vp8_inverse_wht(&dc, d.coeffs[:])
		} else {
			dc0 := i16((i32(dc[0]) + 3) >> 3)
			for i in 0 ..< 16 do d.coeffs[i * 16] = dc0
		}
		first = 1
		ac_probs = &d.probs[0]
	} else {
		first = 0
		ac_probs = &d.probs[3]
	}

	tnz := d.nz_t[mb_x] & 0x0f
	lnz := d.nz_l & 0x0f
	for y in 0 ..< 4 {
		l := lnz & 1
		for x in 0 ..< 4 {
			i := y * 4 + x
			ctx := int(l + (tnz & 1))
			blk := d.coeffs[i * 16:][:16]
			n := vp8_get_coeffs(br, ac_probs, ctx, q.y1, first, blk)
			l = u8(1 if n > first else 0)
			tnz = (tnz >> 1) | (l << 7)
			d.nz[i] = u8(n)
			if n > 1 || blk[0] != 0 do any_nz = true
		}
		tnz >>= 4
		lnz = (lnz >> 1) | (l << 7)
	}
	out_t := tnz
	out_l := lnz >> 4

	for ch := 0; ch < 4; ch += 2 {
		tnz = d.nz_t[mb_x] >> uint(4 + ch)
		lnz = d.nz_l >> uint(4 + ch)
		for y in 0 ..< 2 {
			l := lnz & 1
			for x in 0 ..< 2 {
				i := 16 + ch * 2 + y * 2 + x
				ctx := int(l + (tnz & 1))
				blk := d.coeffs[i * 16:][:16]
				n := vp8_get_coeffs(br, &d.probs[2], ctx, q.uv, 0, blk)
				l = u8(1 if n > 0 else 0)
				tnz = (tnz >> 1) | (l << 3)
				d.nz[i] = u8(n)
				if n > 1 || blk[0] != 0 do any_nz = true
			}
			tnz >>= 2
			lnz = (lnz >> 1) | (l << 5)
		}
		out_t |= (tnz << 4) << uint(ch)
		out_l |= (lnz & 0xf0) << uint(ch)
	}
	d.nz_t[mb_x] = out_t
	d.nz_l = out_l
	return !any_nz
}

@(private)
vp8_inverse_wht :: proc "contextless" (src: ^[16]i16, out: []i16) {
	tmp: [16]i32
	for i in 0 ..< 4 {
		a0 := i32(src[i]) + i32(src[12 + i])
		a1 := i32(src[4 + i]) + i32(src[8 + i])
		a2 := i32(src[4 + i]) - i32(src[8 + i])
		a3 := i32(src[i]) - i32(src[12 + i])
		tmp[i] = a0 + a1
		tmp[8 + i] = a0 - a1
		tmp[4 + i] = a3 + a2
		tmp[12 + i] = a3 - a2
	}
	for i in 0 ..< 4 {
		dc := tmp[i * 4] + 3
		a0 := dc + tmp[i * 4 + 3]
		a1 := tmp[i * 4 + 1] + tmp[i * 4 + 2]
		a2 := tmp[i * 4 + 1] - tmp[i * 4 + 2]
		a3 := dc - tmp[i * 4 + 3]
		base := i * 64
		out[base + 0] = i16((a0 + a1) >> 3)
		out[base + 16] = i16((a3 + a2) >> 3)
		out[base + 32] = i16((a0 - a1) >> 3)
		out[base + 48] = i16((a3 - a2) >> 3)
	}
}

@(private)
vp8_mul1 :: #force_inline proc "contextless" (a: i32) -> i32 { return ((a * 20091) >> 16) + a }
@(private)
vp8_mul2 :: #force_inline proc "contextless" (a: i32) -> i32 { return (a * 35468) >> 16 }

@(private)
vp8_clip255 :: #force_inline proc "contextless" (v: i32) -> u8 {
	return u8(v) if u32(v) <= 255 else (0 if v < 0 else 255)
}

// vp8_add_residual adds one block's inverse DCT to the prediction at off.
// A block with only its DC set takes the short way, which gives the same
// result. The arithmetic is libwebp's C, in 32 bits: a hostile coefficient
// can overflow the 16-bit lanes of libwebp's SIMD transforms, which then
// disagree with its own C, and there is no one answer to match.
@(private)
vp8_add_residual :: proc "contextless" (ws: []u8, off: int, c: []i16, nz: u8) {
	BPS :: VP8_BPS
	if nz > 1 {
		tmp: [16]i32
		for i in 0 ..< 4 {
			a := i32(c[i]) + i32(c[8 + i])
			b := i32(c[i]) - i32(c[8 + i])
			cc := vp8_mul2(i32(c[4 + i])) - vp8_mul1(i32(c[12 + i]))
			dd := vp8_mul1(i32(c[4 + i])) + vp8_mul2(i32(c[12 + i]))
			tmp[4 * i + 0] = a + dd
			tmp[4 * i + 1] = b + cc
			tmp[4 * i + 2] = b - cc
			tmp[4 * i + 3] = a - dd
		}
		for i in 0 ..< 4 {
			dc := tmp[i] + 4
			a := dc + tmp[8 + i]
			b := dc - tmp[8 + i]
			cc := vp8_mul2(tmp[4 + i]) - vp8_mul1(tmp[12 + i])
			dd := vp8_mul1(tmp[4 + i]) + vp8_mul2(tmp[12 + i])
			row := ws[off + i * BPS:][:4]
			row[0] = vp8_clip255(i32(row[0]) + ((a + dd) >> 3))
			row[1] = vp8_clip255(i32(row[1]) + ((b + cc) >> 3))
			row[2] = vp8_clip255(i32(row[2]) + ((b - cc) >> 3))
			row[3] = vp8_clip255(i32(row[3]) + ((a - dd) >> 3))
		}
	} else if c[0] != 0 {
		dc := (i32(c[0]) + 4) >> 3
		for i in 0 ..< 4 {
			row := ws[off + i * BPS:][:4]
			for &p in row do p = vp8_clip255(i32(p) + dc)
		}
	}
}

@(private)
vp8_reconstruct :: proc(d: ^Vp8_Decoder, mb_x, mb_y: int, mb: ^VP8_MB, skip: bool) {
	BPS :: VP8_BPS
	Y :: VP8_Y_OFF
	U :: VP8_U_OFF
	V :: VP8_V_OFF
	ws := d.ws[:]

	// The edges outside the picture: 127 above, 129 to the left.
	if mb_x == 0 {
		for j in 0 ..< 16 do ws[Y - 1 + j * BPS] = 129
		for j in 0 ..< 8 {
			ws[U - 1 + j * BPS] = 129
			ws[V - 1 + j * BPS] = 129
		}
		if mb_y > 0 {
			ws[Y - 1 - BPS], ws[U - 1 - BPS], ws[V - 1 - BPS] = 129, 129, 129
		} else {
			for i in -1 ..< 20 do ws[Y - BPS + i] = 127
			for i in -1 ..< 8 {
				ws[U - BPS + i] = 127
				ws[V - BPS + i] = 127
			}
		}
	} else {
		// The previous macroblock's right columns become the left ones, the
		// row above included, which brings in the above-left sample.
		for j in -1 ..< 16 {
			r := Y + j * BPS
			copy(ws[r - 4:][:4], ws[r + 12:][:4])
		}
		for j in -1 ..< 8 {
			r := U + j * BPS
			copy(ws[r - 4:][:4], ws[r + 4:][:4])
			r = V + j * BPS
			copy(ws[r - 4:][:4], ws[r + 4:][:4])
		}
	}
	if mb_y > 0 {
		copy(ws[Y - BPS:][:16], d.top_y[mb_x * 16:][:16])
		copy(ws[U - BPS:][:8], d.top_u[mb_x * 8:][:8])
		copy(ws[V - BPS:][:8], d.top_v[mb_x * 8:][:8])
	}

	if mb.is_i4x4 {
		// Above-right of the macroblock: the next one's bottom row, or the
		// last sample repeated at the right edge. Sub-blocks down the right
		// column use the same four samples.
		tr := Y - BPS + 16
		if mb_y > 0 {
			if mb_x >= d.mb_w - 1 {
				s := d.top_y[mb_x * 16 + 15]
				ws[tr], ws[tr + 1], ws[tr + 2], ws[tr + 3] = s, s, s, s
			} else {
				copy(ws[tr:][:4], d.top_y[(mb_x + 1) * 16:][:4])
			}
		}
		for k in 1 ..= 3 do copy(ws[tr + 4 * k * BPS:][:4], ws[tr:][:4])
		for n in 0 ..< 16 {
			off := Y + (n & 3) * 4 + (n >> 2) * 4 * BPS
			vp8_predict4(ws, off, mb.imodes[n])
			if !skip do vp8_add_residual(ws, off, d.coeffs[n * 16:][:16], d.nz[n])
		}
	} else {
		vp8_predict_block(ws, Y, 16, mb.imodes[0], mb_x, mb_y)
		if !skip {
			for n in 0 ..< 16 {
				off := Y + (n & 3) * 4 + (n >> 2) * 4 * BPS
				vp8_add_residual(ws, off, d.coeffs[n * 16:][:16], d.nz[n])
			}
		}
	}
	vp8_predict_block(ws, U, 8, mb.uvmode, mb_x, mb_y)
	vp8_predict_block(ws, V, 8, mb.uvmode, mb_x, mb_y)
	for n in 0 ..< 4 {
		if skip do break
		o := (n & 1) * 4 + (n >> 1) * 4 * BPS
		vp8_add_residual(ws, U + o, d.coeffs[(16 + n) * 16:][:16], d.nz[16 + n])
		vp8_add_residual(ws, V + o, d.coeffs[(20 + n) * 16:][:16], d.nz[20 + n])
	}

	yo := mb_y * 16 * d.ys + mb_x * 16
	for j in 0 ..< 16 do copy(d.y[yo + j * d.ys:][:16], ws[Y + j * BPS:][:16])
	uo := mb_y * 8 * d.uvs + mb_x * 8
	for j in 0 ..< 8 {
		copy(d.u[uo + j * d.uvs:][:8], ws[U + j * BPS:][:8])
		copy(d.v[uo + j * d.uvs:][:8], ws[V + j * BPS:][:8])
	}
}

// vp8_predict_block predicts a 16x16 luma or 8x8 chroma block. DC uses only
// the edges inside the picture (128 with none); the other modes use the
// 127/129 edges outside it.
@(private)
vp8_predict_block :: proc "contextless" (ws: []u8, off, size: int, mode: u8, mb_x, mb_y: int) {
	BPS :: VP8_BPS
	switch mode {
	case VP8_DC_PRED:
		sum, count := 0, 0
		if mb_y > 0 {
			for i in 0 ..< size do sum += int(ws[off - BPS + i])
			count += size
		}
		if mb_x > 0 {
			for j in 0 ..< size do sum += int(ws[off - 1 + j * BPS])
			count += size
		}
		dc := u8(128)
		if count > 0 {
			dc = u8((sum + count / 2) >> uint(intrinsics.count_trailing_zeros(count)))
		}
		for j in 0 ..< size {
			row := ws[off + j * BPS:][:size]
			for &p in row do p = dc
		}
	case VP8_V_PRED:
		for j in 0 ..< size do copy(ws[off + j * BPS:][:size], ws[off - BPS:][:size])
	case VP8_H_PRED:
		for j in 0 ..< size {
			row := ws[off + j * BPS - 1:][:size + 1]
			l := row[0]
			for i in 1 ..= size do row[i] = l
		}
	case:
		vp8_true_motion(ws, off, size)
	}
}

@(private)
vp8_true_motion :: proc "contextless" (ws: []u8, off, size: int) {
	BPS :: VP8_BPS
	top := ws[off - BPS - 1:][:size + 1]
	tl := i32(top[0])
	for j in 0 ..< size {
		row := ws[off + j * BPS - 1:][:size + 1]
		l := i32(row[0]) - tl
		for i in 1 ..= size do row[i] = vp8_clip255(i32(top[i]) + l)
	}
}

@(private)
vp8_avg3 :: #force_inline proc "contextless" (a, b, c: int) -> u8 { return u8((a + 2 * b + c + 2) >> 2) }
@(private)
vp8_avg2 :: #force_inline proc "contextless" (a, b: int) -> u8 { return u8((a + b + 1) >> 1) }

// vp8_predict4 predicts a 4x4 luma sub-block (RFC 6386 section 12.3).
@(private)
vp8_predict4 :: proc "contextless" (ws: []u8, off: int, mode: u8) {
	BPS :: VP8_BPS
	t := ws[off - BPS - 1:][:9]
	X, A, B, C, D := int(t[0]), int(t[1]), int(t[2]), int(t[3]), int(t[4])
	E, F, G, H := int(t[5]), int(t[6]), int(t[7]), int(t[8])
	I := int(ws[off - 1])
	J := int(ws[off - 1 + BPS])
	K := int(ws[off - 1 + 2 * BPS])
	L := int(ws[off - 1 + 3 * BPS])
	b: [4][4]u8 // [row][column]
	switch mode {
	case VP8_B_DC_PRED:
		dc := u8((A + B + C + D + I + J + K + L + 4) >> 3)
		for r in 0 ..< 4 do b[r] = {dc, dc, dc, dc}
	case VP8_B_TM_PRED:
		vp8_true_motion(ws, off, 4)
		return
	case VP8_B_VE_PRED:
		row := [4]u8{vp8_avg3(X, A, B), vp8_avg3(A, B, C), vp8_avg3(B, C, D), vp8_avg3(C, D, E)}
		for r in 0 ..< 4 do b[r] = row
	case VP8_B_HE_PRED:
		v0, v1, v2, v3 := vp8_avg3(X, I, J), vp8_avg3(I, J, K), vp8_avg3(J, K, L), vp8_avg3(K, L, L)
		b[0] = {v0, v0, v0, v0}
		b[1] = {v1, v1, v1, v1}
		b[2] = {v2, v2, v2, v2}
		b[3] = {v3, v3, v3, v3}
	case VP8_B_LD_PRED:
		b[0][0] = vp8_avg3(A, B, C)
		b[0][1] = vp8_avg3(B, C, D); b[1][0] = b[0][1]
		b[0][2] = vp8_avg3(C, D, E); b[1][1] = b[0][2]; b[2][0] = b[0][2]
		b[0][3] = vp8_avg3(D, E, F); b[1][2] = b[0][3]; b[2][1] = b[0][3]; b[3][0] = b[0][3]
		b[1][3] = vp8_avg3(E, F, G); b[2][2] = b[1][3]; b[3][1] = b[1][3]
		b[2][3] = vp8_avg3(F, G, H); b[3][2] = b[2][3]
		b[3][3] = vp8_avg3(G, H, H)
	case VP8_B_RD_PRED:
		b[3][0] = vp8_avg3(J, K, L)
		b[3][1] = vp8_avg3(I, J, K); b[2][0] = b[3][1]
		b[3][2] = vp8_avg3(X, I, J); b[2][1] = b[3][2]; b[1][0] = b[3][2]
		b[3][3] = vp8_avg3(A, X, I); b[2][2] = b[3][3]; b[1][1] = b[3][3]; b[0][0] = b[3][3]
		b[2][3] = vp8_avg3(B, A, X); b[1][2] = b[2][3]; b[0][1] = b[2][3]
		b[1][3] = vp8_avg3(C, B, A); b[0][2] = b[1][3]
		b[0][3] = vp8_avg3(D, C, B)
	case VP8_B_VR_PRED:
		b[0][0] = vp8_avg2(X, A); b[2][1] = b[0][0]
		b[0][1] = vp8_avg2(A, B); b[2][2] = b[0][1]
		b[0][2] = vp8_avg2(B, C); b[2][3] = b[0][2]
		b[0][3] = vp8_avg2(C, D)
		b[3][0] = vp8_avg3(K, J, I)
		b[2][0] = vp8_avg3(J, I, X)
		b[1][0] = vp8_avg3(I, X, A); b[3][1] = b[1][0]
		b[1][1] = vp8_avg3(X, A, B); b[3][2] = b[1][1]
		b[1][2] = vp8_avg3(A, B, C); b[3][3] = b[1][2]
		b[1][3] = vp8_avg3(B, C, D)
	case VP8_B_VL_PRED:
		b[0][0] = vp8_avg2(A, B)
		b[0][1] = vp8_avg2(B, C); b[2][0] = b[0][1]
		b[0][2] = vp8_avg2(C, D); b[2][1] = b[0][2]
		b[0][3] = vp8_avg2(D, E); b[2][2] = b[0][3]
		b[1][0] = vp8_avg3(A, B, C)
		b[1][1] = vp8_avg3(B, C, D); b[3][0] = b[1][1]
		b[1][2] = vp8_avg3(C, D, E); b[3][1] = b[1][2]
		b[1][3] = vp8_avg3(D, E, F); b[3][2] = b[1][3]
		b[2][3] = vp8_avg3(E, F, G)
		b[3][3] = vp8_avg3(F, G, H)
	case VP8_B_HD_PRED:
		b[0][0] = vp8_avg2(I, X); b[1][2] = b[0][0]
		b[1][0] = vp8_avg2(J, I); b[2][2] = b[1][0]
		b[2][0] = vp8_avg2(K, J); b[3][2] = b[2][0]
		b[3][0] = vp8_avg2(L, K)
		b[0][3] = vp8_avg3(A, B, C)
		b[0][2] = vp8_avg3(X, A, B)
		b[0][1] = vp8_avg3(I, X, A); b[1][3] = b[0][1]
		b[1][1] = vp8_avg3(J, I, X); b[2][3] = b[1][1]
		b[2][1] = vp8_avg3(K, J, I); b[3][3] = b[2][1]
		b[3][1] = vp8_avg3(L, K, J)
	case:
		// B_HU_PRED
		b[0][0] = vp8_avg2(I, J)
		b[0][2] = vp8_avg2(J, K); b[1][0] = b[0][2]
		b[1][2] = vp8_avg2(K, L); b[2][0] = b[1][2]
		b[0][1] = vp8_avg3(I, J, K)
		b[0][3] = vp8_avg3(J, K, L); b[1][1] = b[0][3]
		b[1][3] = vp8_avg3(K, L, L); b[2][1] = b[1][3]
		l := u8(L)
		b[2][2], b[2][3] = l, l
		b[3] = {l, l, l, l}
	}
	for r in 0 ..< 4 {
		row := ws[off + r * BPS:][:4]
		row[0], row[1], row[2], row[3] = b[r][0], b[r][1], b[r][2], b[r][3]
	}
}

@(private)
vp8_abs :: #force_inline proc "contextless" (v: int) -> int { return -v if v < 0 else v }

@(private)
vp8_sclip1 :: #force_inline proc "contextless" (v: int) -> int { return -128 if v < -128 else (127 if v > 127 else v) }
@(private)
vp8_sclip2 :: #force_inline proc "contextless" (v: int) -> int { return -16 if v < -16 else (15 if v > 15 else v) }
@(private)
vp8_clip1 :: #force_inline proc "contextless" (v: int) -> u8 { return 0 if v < 0 else (255 if v > 255 else u8(v)) }

// vp8_filter2 is the simple filter's adjustment, and the normal filter's
// at an edge of high variance: p0 and q0 move toward each other.
@(private)
vp8_filter2 :: #force_inline proc "contextless" (buf: []u8, i, s: int) {
	p1, p0, q0, q1 := int(buf[i - 2 * s]), int(buf[i - s]), int(buf[i]), int(buf[i + s])
	a := 3 * (q0 - p0) + vp8_sclip1(p1 - q1)
	a1 := vp8_sclip2((a + 4) >> 3)
	a2 := vp8_sclip2((a + 3) >> 3)
	buf[i - s] = vp8_clip1(p0 + a2)
	buf[i] = vp8_clip1(q0 - a1)
}

// vp8_filter_simple filters count segments across one edge: s steps across
// the edge, step along it.
@(private)
vp8_filter_simple :: proc "contextless" (buf: []u8, at, s, step, count, thresh: int) {
	thresh2 := 2 * thresh + 1
	for k in 0 ..< count {
		i := at + k * step
		p1, p0, q0, q1 := int(buf[i - 2 * s]), int(buf[i - s]), int(buf[i]), int(buf[i + s])
		if 4 * vp8_abs(p0 - q0) + vp8_abs(p1 - q1) <= thresh2 {
			vp8_filter2(buf, i, s)
		}
	}
}

// vp8_filter_normal is the normal filter across one edge; mb_edge selects
// the macroblock-edge variant, which reaches three samples to each side. It
// is a constant so each variant compiles without the choice in its loop.
@(private)
vp8_filter_normal :: proc "contextless" (buf: []u8, at, s, step, count, thresh, ithresh, hev_thresh: int, $mb_edge: bool) {
	thresh2 := 2 * thresh + 1
	for k in 0 ..< count {
		i := at + k * step
		p3, p2 := int(buf[i - 4 * s]), int(buf[i - 3 * s])
		p1, p0 := int(buf[i - 2 * s]), int(buf[i - s])
		q0, q1 := int(buf[i]), int(buf[i + s])
		q2, q3 := int(buf[i + 2 * s]), int(buf[i + 3 * s])
		if 4 * vp8_abs(p0 - q0) + vp8_abs(p1 - q1) > thresh2 do continue
		if vp8_abs(p3 - p2) > ithresh || vp8_abs(p2 - p1) > ithresh || vp8_abs(p1 - p0) > ithresh ||
		   vp8_abs(q3 - q2) > ithresh || vp8_abs(q2 - q1) > ithresh || vp8_abs(q1 - q0) > ithresh {
			continue
		}
		if vp8_abs(p1 - p0) > hev_thresh || vp8_abs(q1 - q0) > hev_thresh {
			vp8_filter2(buf, i, s)
		} else {
			when mb_edge {
				a := vp8_sclip1(3 * (q0 - p0) + vp8_sclip1(p1 - q1))
				a1 := (27 * a + 63) >> 7
				a2 := (18 * a + 63) >> 7
				a3 := (9 * a + 63) >> 7
				buf[i - 3 * s] = vp8_clip1(p2 + a3)
				buf[i - 2 * s] = vp8_clip1(p1 + a2)
				buf[i - s] = vp8_clip1(p0 + a1)
				buf[i] = vp8_clip1(q0 - a1)
				buf[i + s] = vp8_clip1(q1 - a2)
				buf[i + 2 * s] = vp8_clip1(q2 - a3)
			} else {
				a := 3 * (q0 - p0)
				a1 := vp8_sclip2((a + 4) >> 3)
				a2 := vp8_sclip2((a + 3) >> 3)
				a3 := (a1 + 1) >> 1
				buf[i - 2 * s] = vp8_clip1(p1 + a3)
				buf[i - s] = vp8_clip1(p0 + a2)
				buf[i] = vp8_clip1(q0 - a1)
				buf[i + s] = vp8_clip1(q1 - a3)
			}
		}
	}
}

// vp8_filter_row runs the loop filter over a reconstructed row of
// macroblocks, in the RFC's order: left edge, inner vertical edges, top
// edge, inner horizontal edges.
@(private)
vp8_filter_row :: proc(d: ^Vp8_Decoder, mb_y: int) {
	ys, uvs := d.ys, d.uvs
	for mb_x in 0 ..< d.mb_w {
		f := d.finfo[mb_x]
		limit := f.limit
		if limit == 0 do continue
		yi := mb_y * 16 * ys + mb_x * 16
		if d.filter_type == 1 {
			if mb_x > 0 do vp8_filter_simple(d.y, yi, 1, ys, 16, limit + 4)
			if f.inner {
				for k in 1 ..= 3 do vp8_filter_simple(d.y, yi + 4 * k, 1, ys, 16, limit)
			}
			if mb_y > 0 do vp8_filter_simple(d.y, yi, ys, 1, 16, limit + 4)
			if f.inner {
				for k in 1 ..= 3 do vp8_filter_simple(d.y, yi + 4 * k * ys, ys, 1, 16, limit)
			}
		} else {
			ui := mb_y * 8 * uvs + mb_x * 8
			il, hev := f.ilevel, f.hev
			if mb_x > 0 {
				vp8_filter_normal(d.y, yi, 1, ys, 16, limit + 4, il, hev, true)
				vp8_filter_normal(d.u, ui, 1, uvs, 8, limit + 4, il, hev, true)
				vp8_filter_normal(d.v, ui, 1, uvs, 8, limit + 4, il, hev, true)
			}
			if f.inner {
				for k in 1 ..= 3 do vp8_filter_normal(d.y, yi + 4 * k, 1, ys, 16, limit, il, hev, false)
				vp8_filter_normal(d.u, ui + 4, 1, uvs, 8, limit, il, hev, false)
				vp8_filter_normal(d.v, ui + 4, 1, uvs, 8, limit, il, hev, false)
			}
			if mb_y > 0 {
				vp8_filter_normal(d.y, yi, ys, 1, 16, limit + 4, il, hev, true)
				vp8_filter_normal(d.u, ui, uvs, 1, 8, limit + 4, il, hev, true)
				vp8_filter_normal(d.v, ui, uvs, 1, 8, limit + 4, il, hev, true)
			}
			if f.inner {
				for k in 1 ..= 3 do vp8_filter_normal(d.y, yi + 4 * k * ys, ys, 1, 16, limit, il, hev, false)
				vp8_filter_normal(d.u, ui + 4 * uvs, uvs, 1, 8, limit, il, hev, false)
				vp8_filter_normal(d.v, ui + 4 * uvs, uvs, 1, 8, limit, il, hev, false)
			}
		}
	}
}

// libwebp's YUV to RGB (dsp/yuv.h): BT.601 limited range, each product
// truncated to 14 bits of precision and the sum to 8.
@(private)
vp8_mult_hi :: #force_inline proc "contextless" (v, coeff: i32) -> i32 { return (v * coeff) >> 8 }

@(private)
vp8_clip8 :: #force_inline proc "contextless" (v: i32) -> u8 {
	YUV_MASK2 :: (256 << 6) - 1
	return u8(v >> 6) if v & ~i32(YUV_MASK2) == 0 else (0 if v < 0 else 255)
}

@(private)
vp8_put_rgba :: #force_inline proc "contextless" (dst: []u8, y, u, v: i32) {
	yy := vp8_mult_hi(y, 19077)
	dst[0] = vp8_clip8(yy + vp8_mult_hi(v, 26149) - 14234)
	dst[1] = vp8_clip8(yy - vp8_mult_hi(u, 6419) - vp8_mult_hi(v, 13320) + 8708)
	dst[2] = vp8_clip8(yy + vp8_mult_hi(u, 33050) - 17685)
	dst[3] = 255
}

// vp8_upsample_line converts one row of luma, with chroma interpolated from
// the nearer chroma row (weight 3) and the farther one (weight 1), as
// libwebp's UpsampleRgbaLinePair does (dsp/upsampling.c): horizontally,
// each output sample sits a quarter of the way between two chroma columns.
//
// Bounds checks are off inside: with them the loop does not vectorise and
// costs three times as much. Every index follows from w, checked here.
@(private)
vp8_upsample_line :: proc "contextless" (ys: []u8, nu, nv, fu, fv: []u8, dst: []u8, w: int) #no_bounds_check {
	uv_w := (w + 1) / 2
	if w <= 0 || len(ys) < w || len(dst) < 4 * w do return
	if len(nu) < uv_w || len(nv) < uv_w || len(fu) < uv_w || len(fv) < uv_w do return
	// The first sample: the nearest chroma column alone.
	{
		u := (3 * i32(nu[0]) + i32(fu[0]) + 2) >> 2
		v := (3 * i32(nv[0]) + i32(fv[0]) + 2) >> 2
		vp8_put_rgba(dst[0:][:4], i32(ys[0]), u, v)
	}
	last_pair := (w - 1) >> 1
	for x in 1 ..= last_pair {
		// a, b: the near row at columns x-1 and x; c, e: the far row.
		au, bu, cu, eu := i32(nu[x - 1]), i32(nu[x]), i32(fu[x - 1]), i32(fu[x])
		av, bv, cv, ev := i32(nv[x - 1]), i32(nv[x]), i32(fv[x - 1]), i32(fv[x])
		// libwebp's two diagonals, each a rounded eighth, then averaged.
		d12u := (au + 3 * bu + 3 * cu + eu + 8) >> 3
		d03u := (3 * au + bu + cu + 3 * eu + 8) >> 3
		d12v := (av + 3 * bv + 3 * cv + ev + 8) >> 3
		d03v := (3 * av + bv + cv + 3 * ev + 8) >> 3
		vp8_put_rgba(dst[(2 * x - 1) * 4:][:4], i32(ys[2 * x - 1]), (d12u + au) >> 1, (d12v + av) >> 1)
		vp8_put_rgba(dst[2 * x * 4:][:4], i32(ys[2 * x]), (d03u + bu) >> 1, (d03v + bv) >> 1)
	}
	if w & 1 == 0 {
		u := (3 * i32(nu[last_pair]) + i32(fu[last_pair]) + 2) >> 2
		v := (3 * i32(nv[last_pair]) + i32(fv[last_pair]) + 2) >> 2
		vp8_put_rgba(dst[(w - 1) * 4:][:4], i32(ys[w - 1]), u, v)
	}
}

// vp8_emit_rgba converts the visible picture. Row 0, and the last row of a
// picture of even height, use their one chroma row alone; every other row
// sits between two chroma rows, nearer the one it shares.
@(private)
vp8_emit_rgba :: proc(d: ^Vp8_Decoder, out: []u8) {
	w, h := d.width, d.height
	uv_w := (w + 1) / 2
	uv_h := (h + 1) / 2
	for row in 0 ..< h {
		near, far: int
		if row == 0 {
			near, far = 0, 0
		} else if row & 1 == 1 {
			near = row >> 1
			far = min(near + 1, uv_h - 1)
		} else {
			near = row >> 1
			far = near - 1
		}
		vp8_upsample_line(
			d.y[row * d.ys:][:w],
			d.u[near * d.uvs:][:uv_w], d.v[near * d.uvs:][:uv_w],
			d.u[far * d.uvs:][:uv_w], d.v[far * d.uvs:][:uv_w],
			out[row * w * 4:][:w * 4], w,
		)
	}
}
