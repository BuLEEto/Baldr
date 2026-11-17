package baldr

// Reading what a font file says it is: its family, its face,
// whether it is fixed-width and whether one file covers several weights.
// Just enough of the sfnt tables for that — `name`, `OS/2`, `post`, `fvar` —
// so the font scan needs no library.

import "core:os"
import "core:strings"
import "core:unicode/utf16"
import "core:unicode/utf8"

// Font_Face_Info is what one font file says about itself.
@(private)
Font_Face_Info :: struct {
	family:    string, // the typographic family (name id 16), else the family (id 1)
	subfamily: string, // "Regular", "Bold Italic", …
	file:      Font_Face_File,
}

@(private)
be16 :: proc "contextless" (b: []u8, at: int) -> u16 {
	if at < 0 || at + 2 > len(b) do return 0
	return u16(b[at]) << 8 | u16(b[at + 1])
}

@(private)
be32 :: proc "contextless" (b: []u8, at: int) -> u32 {
	if at < 0 || at + 4 > len(b) do return 0
	return u32(b[at]) << 24 | u32(b[at + 1]) << 16 | u32(b[at + 2]) << 8 | u32(b[at + 3])
}

@(private)
sfnt_tag :: proc "contextless" (b: []u8, at: int) -> string {
	if at < 0 || at + 4 > len(b) do return ""
	return string(b[at:at + 4])
}

// font_at reads `n` bytes at `off` from an open font file (nil when it
// cannot), so a scan touches the tables it needs and not the outlines.
@(private)
font_at :: proc(fd: ^os.File, off, n: int, allocator := context.temp_allocator) -> []u8 {
	if n <= 0 || n > 1 << 20 do return nil
	buf := make([]u8, n, allocator)
	read, err := os.read_at(fd, buf, i64(off))
	if err != nil || read < n do return nil
	return buf
}

// font_face_read reads what an open font file says it is, table by table.
@(private)
font_face_read :: proc(fd: ^os.File, face := 0, allocator := context.temp_allocator) -> (out: Font_Face_Info, ok: bool) {
	head := font_at(fd, 0, 12)
	if head == nil do return
	base := 0
	if sfnt_tag(head, 0) == "ttcf" { // a collection: face `face` of it
		off := font_at(fd, 12 + 4 * face, 4)
		if off == nil do return
		base = int(be32(off, 0))
		head = font_at(fd, base, 12)
		if head == nil do return
	}
	switch sfnt_tag(head, 0) {
	case "\x00\x01\x00\x00", "OTTO", "true", "typ1":
	case:
		return
	}
	count := int(be16(head, 4))
	if count <= 0 || count > 512 do return
	dir := font_at(fd, base + 12, count * 16)
	if dir == nil do return
	name, os2, post, fvar, maxp: []u8
	for i in 0 ..< count {
		rec := i * 16
		tag := sfnt_tag(dir, rec)
		off, size := int(be32(dir, rec + 8)), int(be32(dir, rec + 12))
		switch tag {
		case "name": name = font_at(fd, off, size)
		case "OS/2": os2 = font_at(fd, off, size)
		case "post": post = font_at(fd, off, min(size, 32))
		case "fvar": fvar = font_at(fd, off, size)
		case "maxp": maxp = font_at(fd, off, 6) // numGlyphs: how big a face really is, which is what the fallback ranks on
		}
	}
	out, ok = font_face_tables(name, os2, post, fvar, allocator)
	if ok && maxp != nil && len(maxp) >= 6 do out.file.glyphs = int(be16(maxp, 4))
	return
}

// font_face_count is how many faces a font file holds: a collection's count,
// else 1 (0 for what is not a font).
@(private)
font_face_count :: proc(fd: ^os.File) -> int {
	head := font_at(fd, 0, 12)
	if head == nil do return 0
	if sfnt_tag(head, 0) != "ttcf" do return 1
	return clamp(int(be32(head, 8)), 0, 64)
}

// sfnt_face_extract makes face `face` of a collection (.ttc) a font file of
// its own, which is what the shaper loads: its table directory with every
// table copied after it, 4-byte aligned, and the offsets rewritten (a
// collection's tables are shared, their offsets from the file's start). A
// file that is not a collection comes back as it is (`copied` false: still
// the caller's). The copy is `allocator`'s.
@(private)
sfnt_face_extract :: proc(data: []u8, face: int, allocator := context.allocator) -> (out: []u8, copied, ok: bool) {
	if sfnt_tag(data, 0) != "ttcf" do return data, false, len(data) >= 12
	if face < 0 || face >= int(be32(data, 8)) || 12 + 4 * face + 4 > len(data) do return
	base := int(be32(data, 12 + 4 * face))
	if base + 12 > len(data) do return
	count := int(be16(data, base + 4))
	if count <= 0 || count > 512 || base + 12 + count * 16 > len(data) do return
	size := 12 + count * 16
	for i in 0 ..< count {
		rec := base + 12 + i * 16
		off, n := int(be32(data, rec + 8)), int(be32(data, rec + 12))
		if off < 0 || n < 0 || off + n > len(data) do return
		size += (n + 3) &~ 3
	}
	out = make([]u8, size, allocator)
	copy(out[:12 + count * 16], data[base:base + 12 + count * 16])
	put32 :: proc(b: []u8, at: int, v: u32) {
		b[at], b[at + 1], b[at + 2], b[at + 3] = u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)
	}
	at := 12 + count * 16
	for i in 0 ..< count {
		rec := base + 12 + i * 16
		off, n := int(be32(data, rec + 8)), int(be32(data, rec + 12))
		copy(out[at:at + n], data[off:off + n])
		put32(out, 12 + i * 16 + 8, u32(at))
		at += (n + 3) &~ 3
	}
	return out, true, true
}

// font_face_of reads a font file held in memory. False for anything that is
// not an sfnt this can make sense of. Strings are `allocator`'s, temp by
// default: clone what you keep.
@(private)
font_face_of :: proc(data: []u8, allocator := context.temp_allocator) -> (out: Font_Face_Info, ok: bool) {
	base := 0
	if sfnt_tag(data, 0) == "ttcf" do base = int(be32(data, 12)) // a collection: its first face
	if base + 12 > len(data) do return
	switch sfnt_tag(data, base) {
	case "\x00\x01\x00\x00", "OTTO", "true", "typ1":
	case:
		return
	}
	count := int(be16(data, base + 4))
	if count <= 0 || count > 512 do return
	name, os2, post, fvar: []u8
	for i in 0 ..< count {
		rec := base + 12 + i * 16
		if rec + 16 > len(data) do return
		tag := sfnt_tag(data, rec)
		off, size := int(be32(data, rec + 8)), int(be32(data, rec + 12))
		if off < 0 || size < 0 || off + size > len(data) do continue
		switch tag {
		case "name": name = data[off:off + size]
		case "OS/2": os2 = data[off:off + size]
		case "post": post = data[off:off + size]
		case "fvar": fvar = data[off:off + size]
		}
	}
	return font_face_tables(name, os2, post, fvar, allocator)
}

// font_face_tables reads the family and face out of the tables that say so.
@(private)
font_face_tables :: proc(name, os2, post, fvar: []u8, allocator := context.temp_allocator) -> (out: Font_Face_Info, ok: bool) {
	if name == nil do return
	family := sfnt_name(name, 16, allocator)
	if len(family) == 0 do family = sfnt_name(name, 1, allocator)
	if len(family) == 0 do return
	sub := sfnt_name(name, 17, allocator)
	if len(sub) == 0 do sub = sfnt_name(name, 2, allocator)
	out.family = family
	out.subfamily = sub
	out.file.weight = int(be16(os2, 4)) if len(os2) >= 6 else 0
	if len(os2) >= 58 do for i in 0 ..< 4 do out.file.ranges[i] = be32(os2, 42 + 4 * i) // ulUnicodeRange1–4
	out.file.width = int(be16(os2, 6)) if len(os2) >= 8 else 0
	if len(os2) >= 64 && be16(os2, 62) & 1 != 0 do out.file.italic = true
	if len(os2) >= 42 && os2[32 + 3] == 9 do out.file.fixed = true // panose: monospaced
	if len(post) >= 16 && be32(post, 12) != 0 do out.file.fixed = true
	if out.file.weight == 0 || !out.file.italic { // fall back on what the face calls itself
		low := strings.to_lower(sub, allocator)
		if strings.contains(low, "italic") || strings.contains(low, "oblique") do out.file.italic = true
		if out.file.weight == 0 {
			out.file.weight = 400
			if strings.contains(low, "bold") do out.file.weight = 700
			if strings.contains(low, "light") do out.file.weight = 300
			if strings.contains(low, "medium") do out.file.weight = 500
		}
	}
	if fvar != nil { // fvar: axesArrayOffset at 4, axisCount at 8, axisSize at 10
		start := int(be16(fvar, 4))
		axes := int(be16(fvar, 8))
		size := int(be16(fvar, 10))
		for i in 0 ..< axes { // a wght axis: one file covers the weights
			at := start + i * size
			if at + 4 > len(fvar) do break
			if sfnt_tag(fvar, at) != "wght" do continue
			out.file.variable = true
			if at + 16 <= len(fvar) do out.file.weights = {int(i32(be32(fvar, at + 4)) >> 16), int(i32(be32(fvar, at + 12)) >> 16)} // min and max, 16.16
		}
	}
	if out.file.weights == {} do out.file.weights = {out.file.weight, out.file.weight}
	return out, true
}

// sfnt_name reads one name from the `name` table, preferring the Windows
// Unicode English record, then any Unicode one, then Mac Roman.
@(private)
sfnt_name :: proc(name: []u8, id: u16, allocator := context.temp_allocator) -> string {
	if len(name) < 6 do return ""
	count := int(be16(name, 2))
	strs := int(be16(name, 4))
	best, best_score := -1, -1
	for i in 0 ..< count {
		rec := 6 + i * 12
		if rec + 12 > len(name) do break
		if be16(name, rec + 6) != id do continue
		platform, encoding, lang := be16(name, rec), be16(name, rec + 2), be16(name, rec + 4)
		score := 0
		switch {
		case platform == 3 && encoding == 1 && lang == 0x409: score = 4 // Windows, Unicode BMP, English
		case platform == 3 && encoding == 1:                  score = 3
		case platform == 0:                                   score = 2 // Unicode
		case platform == 1 && encoding == 0:                  score = 1 // Mac Roman
		}
		if score > best_score {
			best, best_score = rec, score
		}
	}
	if best < 0 do return ""
	length, off := int(be16(name, best + 8)), strs + int(be16(name, best + 10))
	if off < 0 || length <= 0 || off + length > len(name) do return ""
	raw := name[off:off + length]
	if best_score == 1 { // Mac Roman: ASCII for the names we care about
		b := strings.builder_make(allocator)
		for c in raw do if c >= 0x20 && c < 0x7f do strings.write_byte(&b, c)
		return strings.trim_space(strings.to_string(b))
	}
	units := make([]u16, length / 2, context.temp_allocator)
	for i in 0 ..< len(units) do units[i] = be16(raw, i * 2)
	runes := make([]rune, len(units), context.temp_allocator)
	n := utf16.decode(runes, units)
	b := strings.builder_make(allocator)
	for r in runes[:n] do if r >= 0x20 do utf8_write(&b, r)
	return strings.trim_space(strings.to_string(b))
}

@(private)
utf8_write :: proc(b: ^strings.Builder, r: rune) {
	buf, n := utf8.encode_rune(r)
	strings.write_bytes(b, buf[:n])
}
