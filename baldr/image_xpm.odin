package baldr

// XPM pictures (X PixMap 3, the C-source text format old applications
// still install in /usr/share/pixmaps), and ARGB32 pixels in network byte
// order (what a StatusNotifierItem sends as its IconPixmap).

import "core:strings"

// image_load_xpm decodes an XPM 3 file: its colour table (the `c` colour
// of each key, else its `g`, `g4` or `m` one; `#` hex of one to four digits
// a channel, CSS and X11 grey names, or None) and its rows. Fails on a
// malformed or absurdly large picture.
image_load_xpm :: proc(data: []u8, allocator := context.allocator) -> (img: Image, ok: bool) {
	strs := make([dynamic]string, context.temp_allocator)
	s := string(data)
	for i := 0; i < len(s); { // the C string literals, in order, outside comments
		switch {
		case i + 1 < len(s) && s[i] == '/' && s[i + 1] == '*':
			end := strings.index(s[i + 2:], "*/")
			if end < 0 do return
			i += end + 4
		case s[i] == '"':
			start := i + 1
			j := start
			for j < len(s) && s[j] != '"' do j += 2 if s[j] == '\\' else 1
			if j >= len(s) do return
			append(&strs, s[start:j])
			i = j + 1
		case:
			i += 1
		}
	}
	if len(strs) == 0 do return
	header := strs[0]
	nums: [4]int
	n := 0
	for field in strings.fields_iterator(&header) {
		if n == 4 do break
		v, is_int := strconv_atoi(field)
		if !is_int do return
		nums[n] = v
		n += 1
	}
	w, h, ncolors, cpp := nums[0], nums[1], nums[2], nums[3]
	if n < 4 || w <= 0 || h <= 0 || w > 16384 || h > 16384 || ncolors <= 0 || ncolors > 1 << 20 || cpp < 1 || cpp > 8 do return
	if len(strs) < 1 + ncolors + h do return
	// every row holds w keys of cpp characters, so a file shorter than that
	// is refused before its picture is allocated, not after
	if len(data) < w * h * cpp || w * h > IMAGE_LOAD_MAX_PIXELS do return
	colors := make(map[string][4]u8, ncolors, context.temp_allocator)
	for line in strs[1:1 + ncolors] {
		if len(line) < cpp do return
		colors[line[:cpp]] = xpm_color(line[cpp:])
	}
	pixels := make([]u8, w * h * 4, allocator)
	for row, y in strs[1 + ncolors:1 + ncolors + h] {
		if len(row) < w * cpp {
			delete(pixels, allocator)
			return
		}
		for x in 0 ..< w {
			c := colors[row[x * cpp:(x + 1) * cpp]] // an unknown key is transparent
			copy(pixels[(y * w + x) * 4:], c[:])
		}
	}
	return Image{width = w, height = h, pixels = pixels, version = 1, allocator = allocator}, true
}

// image_from_argb32_be converts `w` × `h` ARGB32 pixels in network byte
// order, alpha not premultiplied (a StatusNotifierItem's IconPixmap).
image_from_argb32_be :: proc(w, h: int, bytes: []u8, allocator := context.allocator) -> (img: Image, ok: bool) {
	if w <= 0 || h <= 0 || w > 16384 || h > 16384 || len(bytes) < w * h * 4 do return
	out := make([]u8, w * h * 4, allocator)
	for i in 0 ..< w * h {
		p := bytes[i * 4:]
		out[i * 4], out[i * 4 + 1], out[i * 4 + 2], out[i * 4 + 3] = p[1], p[2], p[3], p[0]
	}
	return Image{width = w, height = h, pixels = out, version = 1, allocator = allocator}, true
}

// xpm_color reads a colour entry after its key: the value for `c`, else
// `g`, `g4` or `m` (a value may be several words, up to the next key).
@(private)
xpm_color :: proc(entry: string) -> [4]u8 {
	KEYS :: [?]string{"c", "g", "g4", "m"}
	words := make([dynamic]string, context.temp_allocator)
	rest := entry
	for word in strings.fields_iterator(&rest) do append(&words, word)
	is_key :: proc(w: string) -> bool { return w == "c" || w == "g" || w == "g4" || w == "m" || w == "s" }
	for want in KEYS {
		for i := 0; i < len(words); i += 1 {
			if words[i] != want do continue
			j := i + 1
			for j < len(words) && !is_key(words[j]) do j += 1
			if j == i + 1 do continue
			return xpm_value(strings.join(words[i + 1:j], " ", context.temp_allocator))
		}
	}
	return {}
}

@(private)
xpm_value :: proc(value: string) -> [4]u8 {
	lower := strings.to_lower(value, context.temp_allocator)
	if lower == "none" do return {}
	if lower[0] == '#' {
		hex := lower[1:]
		if len(hex) % 3 != 0 || len(hex) == 0 || len(hex) > 12 do return {0, 0, 0, 255}
		per := len(hex) / 3
		out: [4]u8 = {0, 0, 0, 255}
		for c in 0 ..< 3 {
			v: u32
			for ch in transmute([]u8)hex[c * per:(c + 1) * per] {
				d: u32
				switch ch {
				case '0' ..= '9': d = u32(ch - '0')
				case 'a' ..= 'f': d = u32(ch - 'a' + 10)
				case:             return {0, 0, 0, 255}
				}
				v = v << 4 | d
			}
			top := u32(1) << u32(per * 4) - 1
			out[c] = u8((v * 255 + top / 2) / top)
		}
		return out
	}
	compact, _ := strings.remove_all(lower, " ", context.temp_allocator)
	for prefix in ([2]string{"gray", "grey"}) { // X11's gray0 … gray100
		if strings.has_prefix(compact, prefix) && len(compact) > len(prefix) {
			if pct, is_int := strconv_atoi(compact[len(prefix):]); is_int && pct >= 0 && pct <= 100 {
				g := u8((pct * 255 + 50) / 100)
				return {g, g, g, 255}
			}
		}
	}
	if hex, known := svg_color_name(compact); known do return {u8(hex >> 16), u8(hex >> 8), u8(hex), 255}
	return {0, 0, 0, 255} // an unknown name: black, as X does for a colour it can't find
}

// strconv_atoi reads a whole non-negative decimal.
@(private)
strconv_atoi :: proc(s: string) -> (v: int, ok: bool) {
	if s == "" || len(s) > 9 do return
	for ch in transmute([]u8)s {
		if ch < '0' || ch > '9' do return 0, false
		v = v * 10 + int(ch - '0')
	}
	return v, true
}
