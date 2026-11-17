package baldr

// SVG text: `text` and `tspan` set on a line in Baldr's own typefaces.
// runa shapes each run and its glyph outlines become paths, painted like
// any shape. A family naming a monospace face gets JetBrains Mono, any
// other Inter, at the weight and slant asked. x and y start a chunk, which
// text-anchor aligns; dx and dy nudge; letter- and word-spacing apply;
// white space collapses unless xml:space="preserve" (core's XML parser
// drops the white space an element's text starts with, so only spaces
// inside the text are kept). Text on a path, per-glyph position lists,
// rotation, vertical text and decoration are not drawn.

import "core:encoding/xml"
import "core:math"
import "core:strings"
import runa "baldr:third_party/runa"

@(private)
Svg_Text_Run :: struct {
	path:  Svg_Path,
	style: Svg_Style,
	chunk: int,
}

@(private)
Svg_Chunk :: struct {
	start, end: f32, // the pen's x where the chunk began and where it got to
	anchor:     Svg_Anchor,
}

@(private)
Svg_Text :: struct {
	d:                ^Svg_Doc,
	xf:               Svg_Xf,
	pen:              [2]f32,
	runs:             [dynamic]Svg_Text_Run,
	chunks:           [dynamic]Svg_Chunk,
	started, pending: bool, // some text is set; a collapsed space waits for what follows it
	glyphs:           [dynamic]runa.Shaped_Glyph,
}

@(private)
Svg_Font_Key :: struct {
	slot:   Font_Slot,
	weight: i32,
}

@(private)
svg_draw_text :: proc(d: ^Svg_Doc, e: ^xml.Element, s: ^Svg_Style, xf: Svg_Xf, c: ^Svg_Canvas, clip: bool) {
	runs := svg_text_layout(d, e, s, xf)
	box: Svg_Box
	for &run in runs do svg_path_box(&run.path, SVG_XF_ID, &box)
	for &run in runs {
		if run.style.visible do svg_paint_path(d, &run.path, &run.style, xf, c, clip, 1, box)
	}
}

@(private)
svg_text_box :: proc(d: ^Svg_Doc, e: ^xml.Element, s: ^Svg_Style, xf: Svg_Xf, box: ^Svg_Box) {
	for &run in svg_text_layout(d, e, s, xf) do svg_path_box(&run.path, xf, box)
}

@(private)
svg_text_layout :: proc(d: ^Svg_Doc, e: ^xml.Element, s: ^Svg_Style, xf: Svg_Xf) -> []Svg_Text_Run {
	tx := Svg_Text{d = d, xf = xf}
	svg_text_element(&tx, e, s, true)
	for &run in tx.runs {
		ch := tx.chunks[run.chunk]
		shift: f32
		switch ch.anchor {
		case .Start:
		case .Middle: shift = -(ch.end - ch.start) / 2
		case .End:    shift = -(ch.end - ch.start)
		}
		if shift != 0 do for &poly in run.path.polys do for &pt in poly.pts do pt.x += shift
	}
	return tx.runs[:]
}

@(private)
svg_text_element :: proc(tx: ^Svg_Text, e: ^xml.Element, s: ^Svg_Style, top: bool) {
	d := tx.d
	fs := s.font_size
	x, has_x := svg_text_coord(d, e, "x", .X, fs)
	y, has_y := svg_text_coord(d, e, "y", .Y, fs)
	dx, _ := svg_text_coord(d, e, "dx", .X, fs)
	dy, _ := svg_text_coord(d, e, "dy", .Y, fs)
	if top || has_x || has_y {
		if has_x do tx.pen.x = x
		if has_y do tx.pen.y = y
		append(&tx.chunks, Svg_Chunk{start = tx.pen.x, end = tx.pen.x, anchor = s.anchor})
	}
	tx.pen += {dx, dy}
	tx.chunks[len(tx.chunks) - 1].end = tx.pen.x
	for v in e.value {
		switch item in v {
		case string:
			svg_text_string(tx, item, s)
		case xml.Element_ID:
			ce := &d.x.elements[item]
			if ce.kind != .Element || svg_name(d, item) != "tspan" do continue
			cs := svg_style(d, item, s)
			if cs.display do svg_text_element(tx, ce, &cs, false)
		}
	}
}

// svg_text_coord is the first entry of a position list (the rest, per
// glyph, are not followed).
@(private)
svg_text_coord :: proc(d: ^Svg_Doc, e: ^xml.Element, name: string, axis: Svg_Axis, font_size: f32) -> (f32, bool) {
	v := strings.trim_space(svg_attr(e, name))
	if v == "" do return 0, false
	if end := strings.index_any(v, " ,\t\r\n"); end >= 0 do v = v[:end]
	l, ok := svg_parse_length(v)
	if !ok do return 0, false
	return svg_len(d, l, axis, font_size), true
}

@(private)
svg_text_string :: proc(tx: ^Svg_Text, text: string, s: ^Svg_Style) {
	b := strings.builder_make()
	for r in text {
		switch {
		case s.preserve_space:
			strings.write_rune(&b, ' ' if r == '\n' || r == '\r' || r == '\t' else r)
			tx.started = true
		case r == '\n' || r == '\r': // SVG 1.1: newlines go, tabs become spaces, runs of spaces collapse, and the ends are trimmed
		case r == ' ' || r == '\t':
			if tx.started do tx.pending = true
		case:
			if tx.pending do strings.write_byte(&b, ' ')
			tx.pending = false
			tx.started = true
			strings.write_rune(&b, r)
		}
	}
	str := strings.to_string(b)
	size := s.font_size
	if str == "" || size <= 0 do return
	font := svg_font(tx.d, s)
	if font == nil do return
	clear(&tx.glyphs)
	runa.shape_text(font, str, size, &tx.glyphs)
	run := Svg_Text_Run{path = svg_path_make(tx.xf), style = s^, chunk = len(tx.chunks) - 1}
	k := size / f32(font.units_per_em)
	letter := svg_len(tx.d, s.letter_spacing, .X, size)
	word := svg_len(tx.d, s.word_spacing, .X, size)
	outline: runa.Outline
	for g in tx.glyphs {
		clear(&outline.points)
		clear(&outline.contour_ends)
		if runa.font_glyph_outline(font, g.glyph_id, &outline) == .None {
			svg_glyph_path(&run.path, &outline, tx.pen + {g.x_offset, -g.y_offset}, k)
		}
		tx.pen += {g.x_advance + letter, -g.y_advance}
		if int(g.cluster) < len(str) && str[g.cluster] == ' ' do tx.pen.x += word
	}
	tx.chunks[run.chunk].end = tx.pen.x
	append(&tx.runs, run)
}

// svg_glyph_path adds a TrueType outline (quadratic, with implied on-curve
// points between two off-curve ones) with its origin at `origin`, `k`
// pixels to the font unit, y flipped.
@(private)
svg_glyph_path :: proc(p: ^Svg_Path, o: ^runa.Outline, origin: [2]f32, k: f32) {
	at :: proc(x, y: i32, origin: [2]f32, k: f32) -> [2]f32 {
		return {origin.x + f32(x) * k, origin.y - f32(y) * k}
	}
	start := 0
	for end16 in o.contour_ends {
		end := int(end16)
		if end < start || end >= len(o.points) do break
		pts := o.points[start:end + 1]
		start = end + 1
		n := len(pts)
		if n < 2 do continue
		first := -1
		for pt, i in pts {
			if pt.on_curve {
				first = i
				break
			}
		}
		begin: [2]f32
		if first >= 0 {
			begin = at(pts[first].x, pts[first].y, origin, k)
		} else { // all off-curve: start between the last and the first
			begin = (at(pts[n - 1].x, pts[n - 1].y, origin, k) + at(pts[0].x, pts[0].y, origin, k)) / 2
			first = n - 1
		}
		svg_path_move(p, begin)
		ctrl: [2]f32
		has_ctrl := false
		for step in 1 ..= n {
			pt := pts[(first + step) % n]
			q := at(pt.x, pt.y, origin, k)
			if pt.on_curve {
				if has_ctrl {
					svg_path_quad(p, ctrl, q)
				} else {
					svg_path_line(p, q)
				}
				has_ctrl = false
			} else {
				if has_ctrl do svg_path_quad(p, ctrl, (ctrl + q) / 2)
				ctrl = q
				has_ctrl = true
			}
		}
		if has_ctrl do svg_path_quad(p, ctrl, begin)
		svg_path_close(p)
	}
}

// svg_font is the face for a style, loaded once per document and weight.
@(private)
svg_font :: proc(d: ^Svg_Doc, s: ^Svg_Style) -> ^runa.Font {
	slot := Font_Slot.Italic if s.font_italic else Font_Slot.UI
	families := s.font_family
	for family in strings.split_iterator(&families, ",") { // the first family decides
		name := strings.to_lower(strings.trim(strings.trim_space(family), "'\""))
		if name == "monospace" || strings.contains(name, "mono") || strings.contains(name, "courier") || strings.contains(name, "consol") do slot = .Mono
		break
	}
	weight := math.round(clamp(s.font_weight, 100, 900))
	key := Svg_Font_Key{slot, i32(weight)}
	if f, seen := d.fonts[key]; seen do return f
	f: ^runa.Font
	if loaded, err := runa.font_load(font_data(slot)); err == .None {
		f = new(runa.Font)
		f^ = loaded
		wght := runa.Axis_Tag(u32('w') << 24 | u32('g') << 16 | u32('h') << 8 | u32('t'))
		if weight != 400 do _ = runa.font_set_variation(f, wght, weight) // a face without the axis stays as it is
	}
	d.fonts[key] = f
	return f
}
