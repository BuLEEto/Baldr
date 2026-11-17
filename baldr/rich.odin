package baldr

// Rich paragraph layout: one block of text whose runs differ in face
// (bold, italic, code), wrapped at UAX #14 break opportunities. runa lays
// out one style per paragraph, so each run is shaped on its own (through
// the engine's paragraph cache) and the lines are filled here, greedily,
// from the runs' advances. The result answers everything an editor asks:
// the wrapped lines with their byte ranges and widths, the x of any byte
// offset, the offset nearest an x, and the segments to draw (one
// Draw_Text per run per line). Without a text engine the headless rule
// applies: half the size per rune.

import "core:slice"
import "baldr:third_party/runa"
import "baldr:third_party/runa/bidi"
import "baldr:third_party/runa/linebreak"
import "core:strings"
import "core:unicode/utf8"

// Rich_Style is what a run is drawn with.
Rich_Style :: struct {
	size:   f32,
	bold:   bool,
	italic: bool,
	mono:   bool, // inline code
	attrs:  Attrs,
	href:   string,
	family: Family_Id, // the family an editor was set to (0: the theme's fonts)
}

// Rich_Seg is one run's part of one line.
Rich_Seg :: struct {
	start, end: int, // bytes of the block
	x, width:   f32, // from the line's start
	run:        int, // index into the layout's styles
	level:      u8,  // bidi embedding level: odd runs right to left, so its first byte is at its right edge
}

Rich_Line :: struct {
	start, end: int,
	width:      f32,
	x:          f32, // from the block's left: 0 in flowing text, the column's text edge in a table row
	y:          f32, // from the block's top: `line_h` apart in flowing text, and a cell's own stack in a table row
	segs:       []Rich_Seg, // in visual order, left to right
	bidi:       bool,       // holds right-to-left text: its segments are reordered and split by direction
}

// Rich_Layout is a block's wrapped layout: lines, the cumulative x of every
// byte (cum[len(text)] is the total width), and the style of every run.
//
// A line's `y` is what stacks it, not its index: in flowing text the two say
// the same thing, but a table row's cells each wrap within their own column,
// so the row holds one line per cell line and they are not one stack.
Rich_Layout :: struct {
	lines:  []Rich_Line,
	cum:    []f32,
	styles: []Rich_Style,
	runs:   []Run, // the block's runs the layout was built for (plain: one run)
	line_h: f32,
	ascent: f32,
	height: f32, // the whole block's: `line_h` a line, or the tallest cell in a table row
}

// rich_layout lays `text` out with `runs` (empty = one plain run) at the
// block's base `style`, wrapped at `wrap_w` (0 = one line). Everything is
// allocated with `allocator`.
rich_layout :: proc(t: ^Tree, text: string, runs: []Run, base: Rich_Style, wrap_w: f32, allocator := context.temp_allocator) -> Rich_Layout {
	out: Rich_Layout
	n := len(text)
	// runs → styles
	plain := [1]Run{{end = n}}
	rs := runs if len(runs) > 0 else plain[:]
	out.runs = make([]Run, len(rs), allocator)
	copy(out.runs, rs)
	out.styles = make([]Rich_Style, len(rs), allocator)
	for r, i in rs do out.styles[i] = run_style(base, r)
	// cumulative x per byte, from each run's own shaping
	out.cum = make([]f32, n + 1, allocator)
	levels := rich_levels(text) // nil unless something runs right to left
	te := t.text
	engine := te != nil && te.ok
	x: f32
	start := 0
	line_h, ascent: f32
	for r, i in rs {
		st := out.styles[i]
		seg := text[start:min(r.end, n)]
		if engine {
			// Each glyph's advance goes to the cluster it came from, then the
			// clusters are laid end to end in the text's own order: a
			// right-to-left run's glyphs come back in visual order. Every line
			// the shaper returns counts, as a run may hold hard breaks. Bytes
			// inside a cluster take its end, so a cut lands after it.
			//
			// Text that runs both ways is shaped a piece per direction, the
			// pieces it is drawn in: shaped whole, its fallback fonts can be
			// other than a piece's own, and the measure would not be the drawing.
			pen := x
			end := start + len(seg)
			for p := start; p < end; {
				q := end
				if levels != nil {
					q = p + 1
					for q < end && levels[q] == levels[p] do q += 1
				}
				piece := text[p:q]
				lines := text_lines(te, piece, st.size, 0, .Semibold if st.bold else .Regular, st.mono, 0, st.italic, family = st.family)
				adv := make([]f32, len(piece) + 1, context.temp_allocator)
				for line in lines {
					for g in line.glyphs {
						c := int(g.cluster)
						if c >= 0 && c <= len(piece) do adv[c] += g.x_advance
					}
				}
				for b in 0 ..< len(piece) {
					out.cum[p + b] = pen
					pen += adv[b]
				}
				pen += adv[len(piece)]
				p = q
			}
			x = pen
			lh := text_line_height(te, st.size, st.mono, st.family)
			as := text_ascent(te, st.size, st.mono, st.family)
			if lh > line_h do line_h = lh
			if as > ascent do ascent = as
		} else {
			adv := st.size * 0.5
			for b := start; b < start + len(seg); {
				_, w := utf8.decode_rune_in_string(text[b:])
				out.cum[b] = x
				for k := 1; k < w; k += 1 do out.cum[b + k] = x + adv
				x += adv
				b += w
			}
			if st.size * 1.25 > line_h do line_h = st.size * 1.25
			if st.size > ascent do ascent = st.size
		}
		start = min(r.end, n)
	}
	out.cum[n] = x
	out.line_h = line_h
	out.ascent = ascent
	// break opportunities (byte positions where a line may start)
	allowed := rich_breaks(text)
	// greedy fill
	lines := make([dynamic]Rich_Line, allocator)
	ls := 0
	for ls < n {
		le := n
		if wrap_w > 0 {
			last := -1
			for b := ls + 1; b <= n; b += 1 {
				if b < n && !allowed[b] do continue
				// width up to `b`, trailing spaces forgiven
				w := out.cum[trim_end(text, b)] - out.cum[ls]
				if w <= wrap_w {
					last = b
					if b == n do break
					continue
				}
				break
			}
			if last > ls {
				le = last
			} else {
				// No opportunity fits: cut at the last grapheme that does, at
				// least one. One walk from the line's start: `grapheme_next`
				// walks from the start of the text each call, which would make
				// an unbreakable word quadratic. A line starts on a grapheme
				// boundary, so walking `text[ls:]` from 0 is exact.
				le = ls
				it := runa.grapheme_iter_make(text[ls:])
				for {
					_, hi, ok := runa.grapheme_iter_next(&it)
					if !ok do break
					b := ls + hi
					if out.cum[b] - out.cum[ls] > wrap_w && le > ls do break
					le = b
					if b == n do break
				}
				if le <= ls do le = grapheme_next(text, ls)
			}
		}
		// A hard break ends the line wherever it falls. Nothing else in a
		// block holds one — markdown splits on newlines — but a table cell
		// does, because `<br>` is the only line break GFM gives a cell.
		if nl := strings.index_byte(text[ls:le], '\n'); nl >= 0 do le = ls + nl + 1
		append(&lines, Rich_Line{start = ls, end = le, width = out.cum[trim_end(text, le)] - out.cum[ls]})
		ls = le
	}
	if len(lines) == 0 do append(&lines, Rich_Line{})
	for &l, li in lines do l.y = f32(li) * line_h
	out.height = f32(len(lines)) * line_h
	// segments per line, split where the direction changes and set out in
	// visual order when the text holds anything right to left
	for &l in lines {
		segs := make([dynamic]Rich_Seg, allocator)
		rstart := 0
		shown := trim_end(text, l.end) // the break itself is not drawn
		for r, i in rs {
			a, z := max(rstart, l.start), min(r.end, shown)
			rstart = r.end
			if z <= a do continue
			if levels == nil {
				append(&segs, Rich_Seg{start = a, end = z, x = out.cum[a] - out.cum[l.start], width = out.cum[z] - out.cum[a], run = i})
				continue
			}
			for p := a; p < z; {
				q := p + 1
				for q < z && levels[q] == levels[p] do q += 1
				append(&segs, Rich_Seg{start = p, end = q, width = out.cum[q] - out.cum[p], run = i, level = levels[p]})
				p = q
			}
		}
		if levels != nil {
			rich_reorder(segs[:])
			left: f32
			for &sg in segs {
				sg.x = left
				left += sg.width
			}
			l.bidi = true
		}
		l.segs = segs[:]
	}
	out.lines = lines[:]
	return out
}

// trim_end steps back over trailing spaces and the hard break before `b`:
// neither counts against the wrap width, and neither is drawn.
@(private)
trim_end :: proc(text: string, b: int) -> int {
	e := b
	for e > 0 && (text[e - 1] == ' ' || text[e - 1] == '\n') do e -= 1
	return e
}

// rich_breaks marks the byte offsets a line may start at (UAX #14 through
// runa's engine, plus Thai breaks: grapheme clusters by default, dictionary
// words when runa is built with -define:RUNA_THAI_DICT=true).
@(private)
rich_breaks :: proc(text: string) -> []bool {
	allowed := make([]bool, len(text) + 1, context.temp_allocator) // scratch for the fill, never kept
	if len(text) == 0 do return allowed
	runes := make([dynamic]rune, 0, len(text), context.temp_allocator)
	offsets := make([dynamic]int, 0, len(text), context.temp_allocator)
	for off := 0; off < len(text); {
		r, w := utf8.decode_rune_in_string(text[off:])
		append(&runes, r)
		append(&offsets, off)
		off += w
	}
	per_rune := make([]bool, len(runes), context.temp_allocator)
	i := 0
	for i < len(runes) {
		next_i, _ := linebreak.next_break(runes[:], i)
		if next_i > 0 && next_i < len(runes) do per_rune[next_i] = true
		if next_i <= i { i += 1 } else { i = next_i }
	}
	linebreak.thai_segment_breaks(runes[:], per_rune)
	for ok, ri in per_rune do if ok do allowed[offsets[ri]] = true
	allowed[len(text)] = true
	return allowed
}

// run_style derives a run's face from the block's base style and its attributes.
@(private)
run_style :: proc(base: Rich_Style, r: Run) -> Rich_Style {
	st := base
	st.attrs = r.attrs
	st.href = r.href
	if .Bold in r.attrs do st.bold = true
	if .Italic in r.attrs do st.italic = true
	if .Code in r.attrs {
		st.mono = true
		st.italic = false
		st.family = 0 // inline code keeps the code face, whatever family the prose is in
	}
	return st
}

// rich_levels is the bidi embedding level of every byte of `text`, in the
// frame's temp memory; nil when nothing in it runs right to left, which
// leaves the layout exactly as plain left-to-right text.
@(private)
rich_levels :: proc(text: string) -> []u8 {
	rtl := false
	for r in text {
		#partial switch bidi.bidi_class(r) {
		case .R, .AL, .AN, .RLE, .RLO, .RLI: rtl = true
		}
		if rtl do break
	}
	if !rtl do return nil
	base := bidi.Direction.RTL if bidi.paragraph_direction(text) == .RTL else bidi.Direction.LTR
	levels, at := bidi.resolve_levels(text, base, context.temp_allocator)
	out := make([]u8, len(text) + 1, context.temp_allocator)
	for k in 0 ..< len(levels) {
		end := at[k + 1] if k + 1 < len(at) else len(text)
		for b in at[k] ..< min(end, len(text)) do out[b] = levels[k]
	}
	return out
}

// rich_reorder puts one line's segments in visual order (UAX #9 L2): from
// the highest level down to the lowest odd one, every run of segments at
// that level or above is reversed.
@(private)
rich_reorder :: proc(segs: []Rich_Seg) {
	hi, lo_odd: u8 = 0, 255
	for sg in segs {
		hi = max(hi, sg.level)
		if sg.level % 2 == 1 do lo_odd = min(lo_odd, sg.level)
	}
	if lo_odd == 255 do return
	for lvl := hi; lvl >= lo_odd && lvl > 0; lvl -= 1 {
		for i := 0; i < len(segs); {
			if segs[i].level < lvl {
				i += 1
				continue
			}
			j := i
			for j < len(segs) && segs[j].level >= lvl do j += 1
			slice.reverse(segs[i:j])
			i = j
		}
	}
}

// rich_seg_x is where the caret before byte `off` of segment `sg` stands:
// measured from the left of a left-to-right piece and from the right of a
// right-to-left one, whose first character is drawn at its right edge.
@(private)
rich_seg_x :: proc(lay: ^Rich_Layout, sg: Rich_Seg, off: int) -> f32 {
	d := lay.cum[off] - lay.cum[sg.start]
	return sg.x + sg.width - d if sg.level % 2 == 1 else sg.x + d
}

// rich_spans is where bytes [a, b) of `line` are drawn: one x range per
// piece they touch, several where directions mix, in the frame's temp memory.
rich_spans :: proc(lay: ^Rich_Layout, line: int, a, b: int) -> [][2]f32 {
	out := make([dynamic][2]f32, context.temp_allocator)
	if line < 0 || line >= len(lay.lines) || b <= a do return out[:]
	l := lay.lines[line]
	if !l.bidi {
		append(&out, [2]f32{rich_x(lay, line, a), rich_x(lay, line, b)})
		return out[:]
	}
	for sg in l.segs {
		lo, hi := max(a, sg.start), min(b, sg.end)
		if hi <= lo do continue
		x0, x1 := rich_seg_x(lay, sg, lo), rich_seg_x(lay, sg, hi)
		append(&out, [2]f32{min(x0, x1), max(x0, x1)})
	}
	return out[:]
}

// rich_x is the x of byte `off` from the start of its line.
rich_x :: proc(lay: ^Rich_Layout, line: int, off: int) -> f32 {
	if line < 0 || line >= len(lay.lines) do return 0
	l := lay.lines[line]
	if l.bidi {
		// the piece holding the character the caret stands before, else the
		// one it ends (the caret after a line's last character)
		for sg in l.segs do if off >= sg.start && off < sg.end do return rich_seg_x(lay, sg, off)
		for sg in l.segs do if off == sg.end do return rich_seg_x(lay, sg, off)
		last: Rich_Seg
		for sg in l.segs do if sg.end >= last.end do last = sg
		return rich_seg_x(lay, last, last.end) if len(l.segs) > 0 else l.x
	}
	// Through the segments, not the line's own range: a table row's line is
	// made of pieces of several cells, each at its own column, and only a
	// segment knows where its bytes actually sit.
	for sg in l.segs {
		if off < sg.start do break
		if off <= sg.end do return sg.x + lay.cum[off] - lay.cum[sg.start]
	}
	if len(l.segs) > 0 {
		last := l.segs[len(l.segs) - 1]
		if off > last.end do return last.x + last.width
		return l.segs[0].x
	}
	return l.x
}

// rich_hit is the grapheme boundary of `line` nearest to `x`.
rich_hit :: proc(lay: ^Rich_Layout, text: string, line: int, x: f32) -> int {
	if line < 0 || line >= len(lay.lines) do return 0
	l := lay.lines[line]
	if len(l.segs) == 0 do return l.start
	best := l.segs[0].start
	best_d := max(f32)
	// One grapheme iterator per segment, started at the segment:
	// `grapheme_next` walks from the start of the block each call, which
	// would make a hit quadratic in the paragraph. Starting at `sg.start` is
	// safe because it is already a grapheme boundary, and nothing before a
	// boundary changes how the text after it divides up.
	for sg in l.segs { // each segment carries where its own bytes sit
		end := min(sg.end, len(text))
		if sg.start > end do continue
		it := runa.grapheme_iter_make(text[sg.start:end])
		b := sg.start
		for {
			d := abs(x - rich_seg_x(lay, sg, b))
			if d < best_d {
				best_d = d
				best = b
			}
			if b >= end do break
			_, hi, ok := runa.grapheme_iter_next(&it)
			next := sg.start + hi if ok else end
			b = clamp(next, b + 1, end) // always forward, never past the segment
		}
	}
	return best
}

// rich_line_at is the line a point falls on, `x` and `y` from the block's
// top-left. Flowing text has one line at each height, so `y` decides it; a
// table row has one line per cell at the same height, so `x` decides which
// cell, and a point past every cell's text takes the nearest.
rich_line_at :: proc(lay: ^Rich_Layout, x, y: f32) -> int {
	if len(lay.lines) == 0 do return 0
	best, best_d := -1, max(f32)
	for l, i in lay.lines {
		if y < l.y || y >= l.y + lay.line_h do continue
		if x >= l.x && x <= l.x + l.width do return i // inside this one
		d := l.x - x if x < l.x else x - (l.x + l.width)
		if d < best_d { best, best_d = i, d }
	}
	if best >= 0 do return best
	// above the first line or below the last: the nearest by height
	if y < lay.lines[0].y do return 0
	last := 0
	for l, i in lay.lines do if l.y >= lay.lines[last].y do last = i
	return last
}

// rich_line_of finds the wrapped line holding `off` (an offset at a wrap
// boundary belongs to the line it ends, except at the block's end).
rich_line_of :: proc(lay: ^Rich_Layout, off: int, text_len: int) -> int {
	for l, i in lay.lines {
		if off < l.end || i == len(lay.lines) - 1 || (off == l.end && off == text_len) do return i
	}
	return 0
}

TABLE_CELL_PAD :: f32(8) // inside a cell, left and right
TABLE_ROW_PAD  :: f32(4) // above and below a row's text

// table_cell_min is the narrowest a cell can be without its text sticking
// out: its longest run between break opportunities, measured from a flow
// layout of the row. Spaces and hard breaks separate; anything else is one
// piece, so a long word decides a column's minimum.
table_cell_min :: proc(lay: ^Rich_Layout, text: string, cell: [2]int) -> f32 {
	widest: f32
	at := cell[0]
	for b := cell[0]; b <= cell[1]; b += 1 {
		if b < cell[1] && text[b] != ' ' && text[b] != '\n' do continue
		widest = max(widest, lay.cum[b] - lay.cum[at])
		at = b + 1
	}
	return widest
}

// table_fit_cols brings a table's columns inside `wrap_w`.
//
// Scaling them all down in proportion is fine until a column is squeezed
// below its own longest word, which then sticks out of it — and a cell that
// sticks out of its column runs on under the next one. So every column keeps
// at least its minimum, and what is left over is shared out in proportion to
// how much each one asked for beyond that: the column with the long prose
// gives up the most, which is the one that had the most to give.
//
// If even the minimums do not fit, they are scaled down together. There is
// nothing else to be done at that point, and the cells break mid-word.
table_fit_cols :: proc(widths: []f32, mins: []f32, wrap_w: f32) {
	if wrap_w <= 0 || len(widths) == 0 do return
	total: f32
	for w in widths do total += w
	if total <= wrap_w do return
	min_total: f32
	for w, i in widths do min_total += min(mins[i], w)
	if min_total >= wrap_w {
		k := wrap_w / max(total, 1e-6)
		for &w in widths do w *= k
		return
	}
	want: f32
	for w, i in widths do want += max(w - min(mins[i], w), 0)
	slack := wrap_w - min_total
	for &w, i in widths {
		m := min(mins[i], w)
		w = m + (slack * max(w - m, 0) / want if want > 0 else 0)
	}
}

// table_row_layout lays a table row out: every cell wrapped inside its own
// column, the row as tall as its tallest cell, so a long cell grows the row
// downwards rather than running under the next column. The row's lines are
// one per cell line, each carrying its own `y`, because a row's cells are not
// one stack (two cells' second lines share a height but not a run of bytes);
// they come out in byte order, so anything walking them by offset still
// walks them in order.
table_row_layout :: proc(t: ^Tree, text: string, runs: []Run, base: Rich_Style, cols: []f32, raw: bool, allocator := context.temp_allocator, align: []Table_Align = nil) -> Rich_Layout {
	out: Rich_Layout
	n := len(text)
	plain := [1]Run{{end = n}}
	rs := runs if len(runs) > 0 else plain[:]
	out.runs = make([]Run, len(rs), allocator)
	copy(out.runs, rs)
	out.styles = make([]Rich_Style, len(rs), allocator)
	for r, i in rs do out.styles[i] = run_style(base, r)
	out.cum = make([]f32, n + 1, allocator)
	for b := 0; b <= n; b += 1 do out.cum[b] = -1

	// A measure of the row in flow, for the line height and for the bytes
	// outside any cell (the pipes, and the spaces beside them).
	flow := rich_layout(t, text, runs, base, 0, context.temp_allocator)
	out.line_h = flow.line_h + TABLE_ROW_PAD * 2
	out.ascent = flow.ascent + TABLE_ROW_PAD

	cells := table_cells(text)
	// One entry a cell: its wrapped lines, and where its text starts.
	Cell_Lay :: struct { lay: Rich_Layout, at: int, x0: f32 }
	laid := make([dynamic]Cell_Lay, context.temp_allocator)
	tall := 1 // lines in the tallest cell
	last_x: f32
	for cell, ci in cells {
		if ci + 1 >= len(cols) do break
		x0 := cols[ci] + TABLE_CELL_PAD
		last_x = cols[ci + 1]
		// A row shown as source is the one being edited: it keeps its pipes
		// and does not wrap, because text moving under the caret as it is
		// typed is worse than a row that is too wide for a moment.
		inner := f32(0) if raw else max(cols[ci + 1] - cols[ci] - TABLE_CELL_PAD * 2, base.size)
		a, z := cell[0], cell[1]
		sub := text[a:z]
		// the row's runs, cut to this cell and moved to its own offsets; the
		// row's run index comes back with each one so the segments keep their
		// style without the styles being built twice
		cuts := make([dynamic]Run, context.temp_allocator)
		back := make([dynamic]int, context.temp_allocator)
		rstart := 0
		for r, i in rs {
			ra, rz := max(rstart, a), min(r.end, z)
			rstart = r.end
			if rz <= ra do continue
			append(&cuts, Run{end = rz - a, attrs = r.attrs, href = r.href})
			append(&back, i)
		}
		lay := rich_layout(t, sub, cuts[:], base, inner, context.temp_allocator)
		// Set the cell where its column asks. A row shown as source keeps
		// its literal layout: the pipes are visible and the caret is in it,
		// so nothing may move under the person's hands.
		if !raw && ci < len(align) && align[ci] != .Left && align[ci] != .Default {
			wide := f32(0)
			for l in lay.lines do wide = max(wide, l.width)
			if slack := inner - wide; slack > 0 {
				x0 += slack if align[ci] == .Right else slack / 2
			}
		}
		if len(lay.lines) > tall do tall = len(lay.lines)
		for l in lay.lines {
			for b := a + l.start; b <= a + l.end && b <= n; b += 1 {
				out.cum[b] = x0 + lay.cum[b - a] - lay.cum[l.start]
			}
		}
		// the cell layout's run indices are its own: put the row's back
		for &l in lay.lines do for &sg in l.segs do sg.run = back[sg.run] if sg.run < len(back) else 0
		append(&laid, Cell_Lay{lay = lay, at = a, x0 = x0})
	}

	// The row's lines are *visual*: line i holds the i'th line of every cell
	// that has one, each at its own column. A line's byte range is therefore
	// not contiguous — which is why `rich_x` and `rich_hit` go through the
	// segments rather than the range.
	lines := make([dynamic]Rich_Line, allocator)
	for li in 0 ..< tall {
		segs := make([dynamic]Rich_Seg, allocator)
		lo, hi := n, 0
		x_lo, x_hi := max(f32), f32(0)
		for cl in laid {
			if li >= len(cl.lay.lines) do continue
			l := cl.lay.lines[li]
			lo, hi = min(lo, cl.at + l.start), max(hi, cl.at + l.end)
			for sg in l.segs {
				append(&segs, Rich_Seg{
					start = cl.at + sg.start, end = cl.at + sg.end,
					x = cl.x0 + sg.x, width = sg.width, run = sg.run,
				})
				x_lo, x_hi = min(x_lo, cl.x0 + sg.x), max(x_hi, cl.x0 + sg.x + sg.width)
			}
			if len(l.segs) == 0 do x_lo = min(x_lo, cl.x0)
		}
		if lo > hi { lo, hi = 0, 0 }
		if x_lo > x_hi { x_lo, x_hi = 0, 0 }
		append(&lines, Rich_Line{
			start = lo, end = hi, width = x_hi - x_lo, x = x_lo,
			y = TABLE_ROW_PAD + f32(li) * flow.line_h,
			segs = segs[:],
		})
	}
	// the pipes and the spaces around them sit on the column boundaries
	col := 0
	for b := 0; b <= n; b += 1 {
		if out.cum[b] >= 0 do continue
		if b < n && text[b] == '|' && col < len(cols) {
			out.cum[b] = cols[col]
			col += 1
		} else if b > 0 {
			out.cum[b] = out.cum[b - 1]
		} else {
			out.cum[b] = 0
		}
	}
	if len(cells) > 0 && len(cols) > len(cells) do last_x = cols[len(cells)]
	out.cum[n] = max(out.cum[n], last_x)
	out.height = f32(tall) * flow.line_h + TABLE_ROW_PAD * 2

	if raw {
		// One line spanning the whole row, pipes and all, so the caret can sit
		// anywhere in the source it is editing. Nothing wrapped, so there is
		// only ever one line's worth to gather.
		segs := make([dynamic]Rich_Seg, allocator)
		for l in lines do for sg in l.segs do append(&segs, sg)
		// the visual lines were the way to reach those segments, and the copy
		// above is the last read of them: `out` does not point at them, so
		// they are freed here or never
		for l in lines do delete(l.segs, allocator)
		delete(lines)
		for b in 0 ..< n do if text[b] == '|' {
			w := out.cum[b + 1] - out.cum[b]
			append(&segs, Rich_Seg{start = b, end = b + 1, x = out.cum[b], width = w if w > 0 else base.size * 0.3, run = 0})
		}
		one := make([]Rich_Line, 1, allocator)
		one[0] = Rich_Line{start = 0, end = n, width = out.cum[n], segs = segs[:], y = TABLE_ROW_PAD}
		out.lines = one
		out.height = flow.line_h + TABLE_ROW_PAD * 2
		return out
	}
	if len(lines) == 0 do append(&lines, Rich_Line{y = TABLE_ROW_PAD})
	out.lines = lines[:]
	return out
}
