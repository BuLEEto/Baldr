package baldr

// Shapes a terminal draws itself, to fill its cell exactly:
// box drawing (U+2500–257F), block elements (U+2580–259F), braille
// (U+2800–28FF) and the powerline separators (U+E0B0–E0B3). A font's
// versions of these are drawn to its own idea of a cell, so lines leave
// gaps between rows and blocks don't meet; drawn here, at the cell's size
// in device pixels, a line runs edge to edge and a full block is the cell.
// Each is rasterised once per cell size into the glyph atlas.
//
// Line widths: a light line is a pixel at a 18 px line and grows with it;
// heavy is twice that. Double lines are drawn as the outline of a pipe: a
// band three light lines wide, less its middle, so corners and junctions
// of double lines join as the real glyphs do.

import "core:math"
import runa "baldr:third_party/runa"

// Cell_Shape is which of the drawn families a character is in.
@(private)
Cell_Shape :: enum u8 { None, Box, Block, Braille, Powerline, Wave }

// TERM_WAVE is the curly underline, drawn as a shape a cell long (a code
// point no character has).
@(private) TERM_WAVE :: rune(0x110000)

@(private)
Cell_Shape_Key :: struct {
	r:    rune,
	w, h: u16,
}

// cell_shape_of says whether `r` is drawn here rather than from a font.
@(private)
cell_shape_of :: proc "contextless" (r: rune) -> Cell_Shape {
	switch r {
	case 0x2500 ..= 0x257f: return .Box
	case 0x2580 ..= 0x259f: return .Block
	case 0x2800 ..= 0x28ff: return .Braille
	case 0xe0b0 ..= 0xe0b3: return .Powerline
	case TERM_WAVE:         return .Wave
	}
	return .None
}

// cell_shape_slot is `r` drawn to fill a `w` × `h` px cell, from the atlas
// (rasterised on first use). False when it cannot be drawn.
@(private)
cell_shape_slot :: proc(te: ^Text_Engine, r: rune, w, h: int) -> (slot: runa.Atlas_Slot, ok: bool) {
	if w <= 0 || h <= 0 || w > 1024 || h > 1024 do return
	key := Cell_Shape_Key{r = r, w = u16(w), h = u16(h)}
	if e, hit := te.cell_shapes[key]; hit do return e.slot, e.ok
	c := Shape_Canvas{w = w, h = h, px = make([]u8, w * h, context.temp_allocator)}
	switch cell_shape_of(r) {
	case .None:
	case .Box:       shape_box(&c, r)
	case .Block:     shape_block(&c, r)
	case .Braille:   shape_braille(&c, r)
	case .Powerline: shape_powerline(&c, r)
	case .Wave:      shape_wave(&c)
	}
	s, err := runa.atlas_pack_alpha(&te.atlas, c.px, u16(w), u16(h), {0, 0})
	ok = err == .None
	if ok do slot = s
	te.cell_shapes[key] = Glyph_Entry{slot = slot, ok = ok}
	return
}

// Shape_Canvas is an alpha bitmap being drawn.
@(private)
Shape_Canvas :: struct {
	w, h: int,
	px:   []u8,
}

// shape_fill covers [x0, x1) × [y0, y1), clipped, at `a`.
@(private)
shape_fill :: proc(c: ^Shape_Canvas, x0, y0, x1, y1: int, a: u8 = 255) {
	for y in max(y0, 0) ..< min(y1, c.h) do for x in max(x0, 0) ..< min(x1, c.w) do c.px[y * c.w + x] = max(c.px[y * c.w + x], a)
}

// shape_clear takes [x0, x1) × [y0, y1) away.
@(private)
shape_clear :: proc(c: ^Shape_Canvas, x0, y0, x1, y1: int) {
	for y in max(y0, 0) ..< min(y1, c.h) do for x in max(x0, 0) ..< min(x1, c.w) do c.px[y * c.w + x] = 0
}

// shape_light is a light line's width for a cell `h` px tall.
@(private)
shape_light :: proc(h: int) -> int {
	return max(int(math.round(f32(h) / 18)), 1)
}

// BOX_ARMS is each box-drawing character's four arms, left, right, up,
// down: 0 none, 1 light, 2 heavy, 3 double; the dashes, arcs and diagonals
// (all 0 here) are drawn apart.
@(private)
BOX_ARMS := [128]string{
	"1100", "2200", "0011", "0022", "0000", "0000", "0000", "0000", "0000", "0000", "0000", "0000", // ─ ━ │ ┃ and the dashes
	"0101", "0201", "0102", "0202", "1001", "2001", "1002", "2002", // ┌ ┍ ┎ ┏ ┐ ┑ ┒ ┓
	"0110", "0210", "0120", "0220", "1010", "2010", "1020", "2020", // └ ┕ ┖ ┗ ┘ ┙ ┚ ┛
	"0111", "0211", "0121", "0112", "0122", "0221", "0212", "0222", // ├ ┝ ┞ ┟ ┠ ┡ ┢ ┣
	"1011", "2011", "1021", "1012", "1022", "2021", "2012", "2022", // ┤ ┥ ┦ ┧ ┨ ┩ ┪ ┫
	"1101", "2101", "1201", "2201", "1102", "2102", "1202", "2202", // ┬ ┭ ┮ ┯ ┰ ┱ ┲ ┳
	"1110", "2110", "1210", "2210", "1120", "2120", "1220", "2220", // ┴ ┵ ┶ ┷ ┸ ┹ ┺ ┻
	"1111", "2111", "1211", "2211", "1121", "1112", "1122", "2121", // ┼ ┽ ┾ ┿ ╀ ╁ ╂ ╃
	"1221", "2112", "1212", "2221", "2212", "2122", "1222", "2222", // ╄ ╅ ╆ ╇ ╈ ╉ ╊ ╋
	"0000", "0000", "0000", "0000", // the double dashes
	"3300", "0033", "0301", "0103", "0303", "3001", "1003", "3003", // ═ ║ ╒ ╓ ╔ ╕ ╖ ╗
	"0310", "0130", "0330", "3010", "1030", "3030", // ╘ ╙ ╚ ╛ ╜ ╝
	"0311", "0133", "0333", "3011", "1033", "3033", // ╞ ╟ ╠ ╡ ╢ ╣
	"3301", "1103", "3303", "3310", "1130", "3330", // ╤ ╥ ╦ ╧ ╨ ╩
	"3311", "1133", "3333", // ╪ ╫ ╬
	"0000", "0000", "0000", "0000", "0000", "0000", "0000", // the arcs and diagonals
	"1000", "0010", "0100", "0001", "2000", "0020", "0200", "0002", // ╴ ╵ ╶ ╷ ╸ ╹ ╺ ╻
	"1200", "0012", "2100", "0021", // ╼ ╽ ╾ ╿
}

// shape_box draws a box-drawing character.
@(private)
shape_box :: proc(c: ^Shape_Canvas, r: rune) {
	light := shape_light(c.h)
	heavy := light * 2
	switch r {
	case 0x2504, 0x2505: shape_dashes(c, 3, false, light if r == 0x2504 else heavy); return
	case 0x2506, 0x2507: shape_dashes(c, 3, true, light if r == 0x2506 else heavy); return
	case 0x2508, 0x2509: shape_dashes(c, 4, false, light if r == 0x2508 else heavy); return
	case 0x250a, 0x250b: shape_dashes(c, 4, true, light if r == 0x250a else heavy); return
	case 0x254c, 0x254d: shape_dashes(c, 2, false, light if r == 0x254c else heavy); return
	case 0x254e, 0x254f: shape_dashes(c, 2, true, light if r == 0x254e else heavy); return
	case 0x256d ..= 0x2570: shape_arc(c, r, light); return
	case 0x2571 ..= 0x2573:
		if r != 0x2572 do shape_segment(c, {f32(c.w), 0}, {0, f32(c.h)}, f32(light))
		if r != 0x2571 do shape_segment(c, {0, 0}, {f32(c.w), f32(c.h)}, f32(light))
		return
	}
	arms := BOX_ARMS[r - 0x2500]
	if len(arms) != 4 do return
	a := [4]int{int(arms[0] - '0'), int(arms[1] - '0'), int(arms[2] - '0'), int(arms[3] - '0')} // left, right, up, down
	width :: proc(k, light, heavy: int) -> int { return heavy if k == 2 else light if k == 1 else 3 * light if k == 3 else 0 }
	single :: proc(k: int) -> bool { return k == 1 || k == 2 }
	band := 3 * light
	h_double := a[0] == 3 || a[1] == 3
	v_double := a[2] == 3 || a[3] == 3
	h_single := max(width(a[0], light, heavy) if single(a[0]) else 0, width(a[1], light, heavy) if single(a[1]) else 0)
	v_single := max(width(a[2], light, heavy) if single(a[2]) else 0, width(a[3], light, heavy) if single(a[3]) else 0)
	// arm draws side `side`'s arm `t` px wide from its edge to where it
	// meets what crosses the middle: `lo` and `hi` are that crossing's near
	// and far edges along the arm (lo == hi: the middle)
	arm :: proc(c: ^Shape_Canvas, side, t, lo, hi: int, clear := false) {
		mx := (c.w - t) / 2
		my := (c.h - t) / 2
		x0, y0, x1, y1: int
		switch side {
		case 0: x0, y0, x1, y1 = 0, my, hi, my + t      // left: from the left edge to the far edge
		case 1: x0, y0, x1, y1 = lo, my, c.w, my + t    // right: from the near edge on
		case 2: x0, y0, x1, y1 = mx, 0, mx + t, hi
		case 3: x0, y0, x1, y1 = mx, lo, mx + t, c.h
		}
		if clear { shape_clear(c, x0, y0, x1, y1) } else { shape_fill(c, x0, y0, x1, y1) }
	}
	// the span of a line `t` px wide across the middle, along an arm on `side`
	across :: proc(c: ^Shape_Canvas, side, t: int) -> (lo, hi: int) {
		size := c.w if side < 2 else c.h
		lo = (size - t) / 2
		return lo, lo + t
	}
	// double arms: the pipe's band, then its middle taken out
	for side in 0 ..< 4 do if a[side] == 3 {
		perp_double := v_double if side < 2 else h_double
		perp_single := v_single if side < 2 else h_single
		cover := band if perp_double else perp_single // across a double (the pipe's corner), or to a single line's far edge
		lo, hi := across(c, side, cover)
		arm(c, side, band, lo, hi)
	}
	for side in 0 ..< 4 do if a[side] == 3 {
		perp_double := v_double if side < 2 else h_double
		lo, hi := across(c, side, light if perp_double else 0) // on round the pipe's corner, else to the middle
		arm(c, side, light, lo, hi, clear = true)
	}
	// single (light and heavy) arms, over them
	for side in 0 ..< 4 do if single(a[side]) {
		t := width(a[side], light, heavy)
		horizontal := side < 2
		opposite := single(a[side ~ 1])
		perp_double := v_double if horizontal else h_double
		perp_both := (a[2] == 3 && a[3] == 3) if horizontal else (a[0] == 3 && a[1] == 3)
		lo, hi: int
		switch {
		case opposite && perp_double: // straight through the doubles
			lo, hi = across(c, side, 0)
		case perp_both: // a T into the doubles: it meets the near line only
			blo, bhi := across(c, side, band)
			lo, hi = blo + 2 * light, bhi - 2 * light
		case perp_double: // a corner of doubles: on to the far line
			lo, hi = across(c, side, band)
		case:
			perp := v_single if horizontal else h_single
			lo, hi = across(c, side, perp)
		}
		arm(c, side, t, lo, hi)
	}
}

// shape_dashes draws `n` dashes of width `t` along the cell, across or
// down, each with a gap after it so neighbouring cells repeat evenly.
@(private)
shape_dashes :: proc(c: ^Shape_Canvas, n: int, vertical: bool, t: int) {
	length := c.h if vertical else c.w
	seg := f32(length) / f32(n)
	gap := max(int(math.round(seg * 0.35)), 1)
	for i in 0 ..< n {
		a := int(math.round(f32(i) * seg))
		b := int(math.round(f32(i + 1) * seg)) - gap
		if b <= a do b = a + 1
		if vertical {
			x := (c.w - t) / 2
			shape_fill(c, x, a, x + t, b)
		} else {
			y := (c.h - t) / 2
			shape_fill(c, a, y, b, y + t)
		}
	}
}

// shape_arc draws a rounded corner (╭ ╮ ╯ ╰): a quarter circle from the
// middle of one edge to the middle of the next, joined straight to the
// cell's edge where the cell is longer than the circle.
@(private)
shape_arc :: proc(c: ^Shape_Canvas, r: rune, t: int) {
	lx := f32((c.w - t) / 2) + f32(t) / 2 // the centre lines, where the straight lines run
	ly := f32((c.h - t) / 2) + f32(t) / 2
	rad := min(f32(c.w) - lx, lx, f32(c.h) - ly, ly)
	// the circle's centre, and the ends of the straight parts, per corner
	right := r == 0x256d || r == 0x2570 // goes on to the right edge
	down := r == 0x256d || r == 0x256e  // goes on down
	ox := lx + rad if right else lx - rad
	oy := ly + rad if down else ly - rad
	half := f32(t) / 2
	for y in 0 ..< c.h do for x in 0 ..< c.w {
		cov := f32(0)
		for sy in 0 ..< 4 do for sx in 0 ..< 4 {
			px := f32(x) + (f32(sx) + 0.5) / 4
			py := f32(y) + (f32(sy) + 0.5) / 4
			in_q := (px >= ox) == !right && (py >= oy) == !down // the quarter facing the corner
			hit := false
			if in_q {
				d := math.sqrt((px - ox) * (px - ox) + (py - oy) * (py - oy))
				hit = abs(d - rad) <= half
			}
			cov += 1 if hit else 0
		}
		if cov > 0 do c.px[y * c.w + x] = max(c.px[y * c.w + x], u8(cov / 16 * 255))
	}
	// the straight parts from the circle's ends to the edges
	x0 := int(math.round(lx - half))
	y0 := int(math.round(ly - half))
	if right { shape_fill(c, int(math.round(ox)), y0, c.w, y0 + t) } else { shape_fill(c, 0, y0, int(math.round(ox)), y0 + t) }
	if down { shape_fill(c, x0, int(math.round(oy)), x0 + t, c.h) } else { shape_fill(c, x0, 0, x0 + t, int(math.round(oy))) }
}

// shape_segment draws a line `t` px wide from `a` to `b`, antialiased.
@(private)
shape_segment :: proc(c: ^Shape_Canvas, a, b: [2]f32, t: f32) {
	d := b - a
	l2 := d.x * d.x + d.y * d.y
	if l2 <= 0 do return
	half := t / 2 + 0.25 // a diagonal looks thinner than a straight line of the same width
	for y in 0 ..< c.h do for x in 0 ..< c.w {
		cov := f32(0)
		for sy in 0 ..< 4 do for sx in 0 ..< 4 {
			p := [2]f32{f32(x) + (f32(sx) + 0.5) / 4, f32(y) + (f32(sy) + 0.5) / 4}
			k := clamp(((p.x - a.x) * d.x + (p.y - a.y) * d.y) / l2, 0, 1)
			q := a + d * k
			dist := math.sqrt((p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y))
			cov += 1 if dist <= half else 0
		}
		if cov > 0 do c.px[y * c.w + x] = max(c.px[y * c.w + x], u8(cov / 16 * 255))
	}
}

// shape_block draws a block element: eighths, halves, quadrants and the
// three shades (flat, at a quarter, half and three quarters).
@(private)
shape_block :: proc(c: ^Shape_Canvas, r: rune) {
	w, h := c.w, c.h
	eighth_y :: proc(h, k: int) -> int { return int(math.round(f32(h) * f32(k) / 8)) }
	eighth_x :: proc(w, k: int) -> int { return int(math.round(f32(w) * f32(k) / 8)) }
	hx, hy := int(math.round(f32(w) / 2)), int(math.round(f32(h) / 2))
	switch r {
	case 0x2580: shape_fill(c, 0, 0, w, hy)
	case 0x2581 ..= 0x2588: shape_fill(c, 0, h - eighth_y(h, int(r - 0x2580)), w, h) // lower 1/8 … full
	case 0x2589 ..= 0x258f: shape_fill(c, 0, 0, eighth_x(w, int(0x2590 - r)), h)     // left 7/8 … 1/8
	case 0x2590: shape_fill(c, hx, 0, w, h)
	case 0x2591: shape_fill(c, 0, 0, w, h, 64)
	case 0x2592: shape_fill(c, 0, 0, w, h, 128)
	case 0x2593: shape_fill(c, 0, 0, w, h, 191)
	case 0x2594: shape_fill(c, 0, 0, w, eighth_y(h, 1))
	case 0x2595: shape_fill(c, w - eighth_x(w, 1), 0, w, h)
	case 0x2596 ..= 0x259f:
		// quadrants: upper left, upper right, lower left, lower right
		QUADS := [10]u8{0b0100, 0b1000, 0b0001, 0b1101, 0b1001, 0b0111, 0b1011, 0b0010, 0b0110, 0b1110}
		q := QUADS[r - 0x2596]
		if q & 1 != 0 do shape_fill(c, 0, 0, hx, hy)
		if q & 2 != 0 do shape_fill(c, hx, 0, w, hy)
		if q & 4 != 0 do shape_fill(c, 0, hy, hx, h)
		if q & 8 != 0 do shape_fill(c, hx, hy, w, h)
	}
}

// shape_braille draws a braille pattern's dots on a 2 × 4 grid: squares,
// so a graph drawn in them reads as solid bars.
@(private)
shape_braille :: proc(c: ^Shape_Canvas, r: rune) {
	bits := u32(r - 0x2800)
	// dot n (bit n-1) → column, row
	DOTS := [8][2]int{{0, 0}, {0, 1}, {0, 2}, {1, 0}, {1, 1}, {1, 2}, {0, 3}, {1, 3}}
	cw := f32(c.w) / 2
	ch := f32(c.h) / 4
	size := max(int(math.round(min(cw, ch) * 0.6)), 1)
	for dot, i in DOTS {
		if bits & (1 << uint(i)) == 0 do continue
		x := int(math.round(cw * (f32(dot[0]) + 0.5) - f32(size) / 2))
		y := int(math.round(ch * (f32(dot[1]) + 0.5) - f32(size) / 2))
		shape_fill(c, x, y, x + size, y + size)
	}
}

// shape_powerline draws a powerline separator: a solid triangle pointing
// right (U+E0B0) or left (U+E0B2), or its outline (U+E0B1, U+E0B3), the
// cell's full height.
@(private)
shape_powerline :: proc(c: ^Shape_Canvas, r: rune) {
	w, h := f32(c.w), f32(c.h)
	left := r == 0xe0b2 || r == 0xe0b3
	if r == 0xe0b1 || r == 0xe0b3 {
		t := f32(shape_light(c.h))
		tip := [2]f32{0 if left else w, h / 2}
		base := f32(w) if left else 0
		shape_segment(c, {base, 0}, tip, t)
		shape_segment(c, {base, h}, tip, t)
		return
	}
	for y in 0 ..< c.h do for x in 0 ..< c.w {
		cov := f32(0)
		for sy in 0 ..< 4 do for sx in 0 ..< 4 {
			px := f32(x) + (f32(sx) + 0.5) / 4
			py := f32(y) + (f32(sy) + 0.5) / 4
			reach := w * (1 - abs(py - h / 2) / (h / 2)) // how far across the triangle is at this height
			hit := px >= w - reach if left else px <= reach
			cov += 1 if hit else 0
		}
		if cov > 0 do c.px[y * c.w + x] = u8(cov / 16 * 255)
	}
}

// shape_wave draws one period of a curly underline across the cell: a sine
// a quarter of the height thick, whole periods per cell so it joins its
// neighbours.
@(private)
shape_wave :: proc(c: ^Shape_Canvas) {
	t := f32(c.h) / 4
	amp := (f32(c.h) - t) / 2
	mid := f32(c.h) / 2
	period := f32(c.w)
	for y in 0 ..< c.h do for x in 0 ..< c.w {
		cov := f32(0)
		for sy in 0 ..< 4 do for sx in 0 ..< 4 {
			px := f32(x) + (f32(sx) + 0.5) / 4
			py := f32(y) + (f32(sy) + 0.5) / 4
			wy := mid - amp * math.sin(px / period * 2 * math.PI)
			slope := amp * 2 * math.PI / period * math.cos(px / period * 2 * math.PI)
			dist := abs(py - wy) / math.sqrt(1 + slope * slope) // across the curve, not straight down
			cov += 1 if dist <= t / 2 else 0
		}
		if cov > 0 do c.px[y * c.w + x] = u8(cov / 16 * 255)
	}
}
