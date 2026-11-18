package baldr

// Drawing a terminal's screen (widget_terminal.odin has the widget).
// Paint puts one Draw_Cells in the layer; render_draw turns it
// into GPU commands straight from the app's screen, row by row, keeping
// each row's commands in device pixels relative to the grid so an
// unchanged row costs a copy. Backgrounds of every row go first and text
// after, so a glyph that reaches into the next row is never covered by its
// background; the cursor and a composition are drawn fresh each frame.

import "core:math"
import "core:unicode/utf8"
import "baldr:gpu"
import runa "baldr:third_party/runa"
import norm "baldr:third_party/runa/normalize"

// Draw_Cells draws terminal `node`'s screen with its grid's top left at
// `pos`, at `alpha` (its fade).
Draw_Cells :: struct { node: Node, pos: [2]f32, alpha: f32 }

// TERM_DIM_ALPHA is how much of its colour dim (faint) text keeps.
@(private) TERM_DIM_ALPHA :: f32(0.6)

// Term_State is what a terminal node keeps: the app's screen, the font it
// is drawn in, each row's drawing, and what it last told the app and the
// compositor.
@(private)
Term_State :: struct {
	screen:      ^Term_Screen,
	family:      Family_Id,
	family_name: string,
	size:        f32, // logical px, the desktop's text size in it
	padding:     f32, // the margin round the grid, logical px
	scale:       f32, // the surface's, at the latest build
	px:          Term_Px, // the cell the rows below were drawn for
	rows:        [dynamic]Term_Row,
	glyphs:      map[Term_Glyph_Key]Term_Glyph,
	seen:        []u64, // each row's rev when it was last damage
	cursor_seen: Term_Cursor,
	sent:        Term_Size, // what on_resize last heard
	keyboard:    bool, // its surface has the keyboard (at the latest build)
	blink_from:  f64,  // when the cursor last showed from a key (tree clock)
	preedit:     string,
	preedit_lo, preedit_hi: int,
	text:        string, // the screen as a reader reads it (a11y)
	text_rev:    u64,
	text_cursor: Term_Cursor,
	caret:       int,
}

// Term_Row is one row's drawing, in device px from the grid's top left.
@(private)
Term_Row :: struct {
	rev:   u64,
	cols:  int,
	valid: bool,
	back:  [dynamic]Term_Cmd,
	fore:  [dynamic]Term_Cmd,
}

// Term_Cmd is a solid rect (page < 0) or a glyph from atlas page `page` of
// the colour pages when `rgba`.
@(private)
Term_Cmd :: struct {
	rect:  [4]f32,
	uv:    [4]f32,
	color: Color,
	page:  i32,
	rgba:  bool,
}

@(private)
Term_Glyph_Key :: struct {
	r:     rune,
	style: Term_Styles,
	wide:  bool,
	emoji: bool, // asked for as emoji (U+FE0F after it)
}

// Term_Glyph is where a character's bitmap is and how it sits in its cell.
@(private)
Term_Glyph :: struct {
	slot: runa.Atlas_Slot,
	dx:   f32, // from the cell's left, device px (a narrower fallback glyph is centred)
	ok:   bool,
}

// term_regular_face is the face a terminal's cell is measured on: the
// family's regular, else the toolkit's monospace.
@(private)
term_regular_face :: proc(te: ^Text_Engine, family: Family_Id) -> ^runa.Font {
	fam := family_now(te, family, mono = true) // none of its own: the theme's code face
	if f := family_font(te, fam); f != nil do return f
	return te.fonts[.Mono]
}

// term_faces is what a cell in `style` is drawn with, first choice first:
// the family's face for it (or the toolkit's monospace, bold at the bold
// weight), then the toolkit's UI face and emoji.
@(private)
term_faces :: proc(te: ^Text_Engine, family: Family_Id, style: Term_Styles) -> []^runa.Font {
	fam := family_now(te, family, mono = true) // none of its own: the theme's code face
	bold := .Bold in style
	if fs := family_stack(te, fam, .Semibold if bold else .Regular, .Italic in style); fs != nil do return fs
	out := make([]^runa.Font, 3, context.temp_allocator)
	out[0] = mono_bold(te) if bold else te.fonts[.Mono]
	out[1], out[2] = te.fonts[.UI], te.fonts[.Emoji]
	return out
}

// mono_bold is the toolkit's monospace face at the bold weight, made on
// first use from the same variable font.
@(private)
mono_bold :: proc(te: ^Text_Engine) -> ^runa.Font {
	if te.mono_bold != nil do return te.mono_bold
	loaded, err := runa.font_load(font_data(.Mono), te.allocator)
	if err != .None do return te.fonts[.Mono]
	f := new(runa.Font, te.allocator)
	f^ = loaded
	wght := runa.Axis_Tag(u32('w') << 24 | u32('g') << 16 | u32('h') << 8 | u32('t'))
	_ = runa.font_set_variation(f, wght, 700)
	te.mono_bold = f
	face_id(te, f)
	return f
}

// paint_terminal: the grid (clipped to the node) and nothing else; the
// node's own background is the screen's.
@(private)
paint_terminal :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer) {
	st, ok := &t.terminals[n]
	if !ok || st.screen == nil do return
	g := term_grid_rect(d, st)
	append(&l.cmds, Draw_Clip_Push{d.abs}) // a wide glyph at the last column may reach into the margin, not past the node
	append(&l.cmds, Draw_Cells{node = n, pos = {g.x, g.y}, alpha = t.paint_opacity})
	append(&l.cmds, Draw_Clip_Pop{})
	if term_blinking(t, n, st) { // the next time it turns on or off, and where, for a repaint of the cursor alone
		half, timeout, _ := caret_timing(t)
		k := math.floor((t.now_ms - st.blink_from) / half)
		wake_at(t, min(st.blink_from + (k + 1) * half, st.blink_from + timeout), n, blink = true)
		cur, c := st.screen.cursor, st.px.logical
		cells := term_row(st.screen, cur.row)
		span := 2 if cur.col < len(cells) && cells[cur.col].width == 2 else 1
		caret_painted(t, {g.x + f32(cur.col) * c.advance, g.y + f32(cur.row) * c.line_height, f32(span) * c.advance, c.line_height})
	}
}

// term_has_keyboard: the terminal is focused on a surface that has the
// keyboard, so its cursor is solid.
@(private)
term_has_keyboard :: proc(t: ^Tree, n: Node, st: ^Term_State) -> bool {
	return t.focus == n && st.keyboard
}

// term_blinking: its cursor blinks now (asked for, shown, in the grid,
// focused, a blinking caret wanted here, and a key pressed lately).
@(private)
term_blinking :: proc(t: ^Tree, n: Node, st: ^Term_State) -> bool {
	s := st.screen
	if s == nil || !s.cursor.blink || s.cursor.hidden || !term_has_keyboard(t, n, st) do return false
	if s.cursor.row < 0 || s.cursor.row >= s.rows || s.cursor.col < 0 || s.cursor.col >= s.cols do return false
	_, timeout, blinks := caret_timing(t)
	return blinks && t.now_ms - st.blink_from < timeout
}

// term_blink_restart shows a blinking cursor again from now (a key).
@(private)
term_blink_restart :: proc(t: ^Tree, n: Node, st: ^Term_State) {
	st.blink_from = t.now_ms
	mark_paint_dirty(t, n)
}

// term_render appends the device-px commands of a Draw_Cells: the rows,
// made again where the screen changed or the cell did, then the cursor and
// any composition.
@(private)
term_render :: proc(t: ^Tree, te: ^Text_Engine, v: Draw_Cells, s: f32, sink: ^Atlas_Sink, out: ^[dynamic]gpu.Cmd) {
	st, ok := &t.terminals[v.node]
	if !ok || st.screen == nil || v.alpha <= 0 do return
	scr := st.screen
	p := term_px(t, st.family, st.size, s)
	if st.px != p {
		term_forget_draws(st)
		st.px = p
	}
	d := node_get(t, v.node)
	shown_rows := scr.rows
	if d != nil do shown_rows = min(scr.rows, int(math.ceil(term_grid_rect(d, st).h * s / f32(p.line))) + 1)
	for len(st.rows) < scr.rows do append(&st.rows, Term_Row{back = make([dynamic]Term_Cmd, t.allocator), fore = make([dynamic]Term_Cmd, t.allocator)})
	for r in 0 ..< shown_rows {
		row := &st.rows[r]
		rev := scr.row_rev[r] if r < len(scr.row_rev) else 0
		if row.valid && row.rev == rev && row.cols == scr.cols do continue
		term_build_row(te, st, scr, r, row)
		row.rev, row.cols, row.valid = rev, scr.cols, true
		t.stats.term_rows += 1
	}
	ensure_pages(te, sink)
	origin := [2]f32{math.round(v.pos.x * s), math.round(v.pos.y * s)}
	for r in 0 ..< shown_rows do term_emit(te, st.rows[r].back[:], origin, v.alpha, out)
	for r in 0 ..< shown_rows do term_emit(te, st.rows[r].fore[:], origin, v.alpha, out)
	extra := make([dynamic]Term_Cmd, context.temp_allocator)
	if len(st.preedit) > 0 && term_has_keyboard(t, v.node, st) {
		term_preedit_cmds(te, st, scr, &extra)
	} else {
		term_cursor_cmds(t, te, v.node, st, scr, &extra)
	}
	ensure_pages(te, sink)
	term_emit(te, extra[:], origin, v.alpha, out)
}

// term_emit turns kept commands into GPU ones at `origin`.
@(private)
term_emit :: proc(te: ^Text_Engine, cmds: []Term_Cmd, origin: [2]f32, alpha: f32, out: ^[dynamic]gpu.Cmd) {
	for c in cmds {
		rect := [4]f32{c.rect[0] + origin.x, c.rect[1] + origin.y, c.rect[2], c.rect[3]}
		col := c.color
		col.a *= alpha
		if c.page < 0 {
			append(out, gpu.Quad{rect = rect, color = col})
			continue
		}
		format := runa.Atlas_Format.RGBA8 if c.rgba else runa.Atlas_Format.Alpha8
		pages := te.pages[format]
		if int(c.page) >= len(pages) do continue
		append(out, gpu.Glyph{rect = rect, uv = c.uv, page = pages[c.page].page, color = col})
	}
}

// term_build_row makes row `r`'s drawing: its background runs, then each
// cell's text, underline and strike.
@(private)
term_build_row :: proc(te: ^Text_Engine, st: ^Term_State, scr: ^Term_Screen, r: int, row: ^Term_Row) {
	clear(&row.back)
	clear(&row.fore)
	p := st.px
	cells := term_row(scr, r)
	y := f32(r * p.line)
	for c := 0; c < len(cells); {
		bg := cells[c].bg
		end := c + 1
		for end < len(cells) && cells[end].bg == bg do end += 1
		if bg.a > 0 do append(&row.back, Term_Cmd{rect = {f32(c * p.advance), y, f32((end - c) * p.advance), f32(p.line)}, color = bg, page = -1})
		c = end
	}
	for cell, c in cells {
		if cell.text[0] == 0 do continue
		span := 2 if cell.width == 2 else 1
		fg := cell.fg
		if .Dim in cell.style do fg.a *= TERM_DIM_ALPHA
		x := f32(c * p.advance)
		term_cell_glyphs(te, st, cell, span, x, y, fg, &row.fore)
		term_decorations(te, st, cell, span, x, y, fg, &row.fore)
	}
}

// term_cell_glyphs appends the glyphs of one cell's text drawn in `fg` with
// its cell's top left at (x, y): a shape drawn to fill the cell for box
// drawing, blocks, braille and powerline; else the character from the
// first face that has it, on the cell's origin; else the cluster shaped,
// fitted to its cells.
@(private)
term_cell_glyphs :: proc(te: ^Text_Engine, st: ^Term_State, cell: Term_Cell, span: int, x, y: f32, fg: Color, out: ^[dynamic]Term_Cmd) {
	p := st.px
	w := span * p.advance
	r, emoji, one, str := term_cluster(cell.text)
	if one {
		if r == ' ' do return
		if cell_shape_of(r) != .None && !emoji {
			if slot, ok := cell_shape_slot(te, r, w, p.line); ok {
				append(out, Term_Cmd{rect = {x, y, f32(slot.px_size.x), f32(slot.px_size.y)}, uv = slot.uv_rect, color = fg, page = i32(slot.page_index)})
			}
			return
		}
		key := Term_Glyph_Key{r = r, style = cell.style & {.Bold, .Italic}, wide = span == 2, emoji = emoji}
		g, known := st.glyphs[key]
		if !known {
			g = term_glyph_find(te, st, r, cell.style, w, emoji)
			st.glyphs[key] = g
		}
		if !g.ok do return
		baseline := y + f32(p.ascent)
		append(out, Term_Cmd{rect = {x + g.dx + g.slot.bearing.x, baseline + g.slot.bearing.y, f32(g.slot.px_size.x), f32(g.slot.px_size.y)},
			uv = g.slot.uv_rect, color = fg, page = i32(g.slot.page_index), rgba = g.slot.is_color})
		return
	}
	// a cluster: a character and its marks, or an emoji sequence, shaped
	weight := Font_Weight.Semibold if .Bold in cell.style else .Regular
	lines := text_lines(te, str, p.size, 0, weight, true, 0, false, true, st.family)
	if len(lines) == 0 do return
	k := f32(1)
	if lw := lines[0].width * p.scale; lw > f32(w) + 0.5 do k = f32(w) / lw // wider than its cells: fitted
	px := p.size * p.scale * k
	pen := max((f32(w) - lines[0].width * p.scale * k) / 2, 0)
	baseline := y + f32(p.ascent)
	for gl in lines[0].glyphs {
		gx := x + pen + gl.x_offset * p.scale * k
		fx := math.floor(gx)
		sub := u8(int((gx - fx) * 4)) & 3
		if slot, ok := glyph_slot(te, gl.font, gl.glyph_id, px, sub); ok {
			append(out, Term_Cmd{rect = {fx + slot.bearing.x, math.round(baseline - gl.y_offset * p.scale * k) + slot.bearing.y, f32(slot.px_size.x), f32(slot.px_size.y)},
				uv = slot.uv_rect, color = fg, page = i32(slot.page_index), rgba = slot.is_color})
		}
		pen += gl.x_advance * p.scale * k
	}
}

// term_cluster reads a cell's text: its one character (`one`), composed
// where Unicode composes it (e and a combining acute are é), or else the
// cluster as a string (the frame's temp memory) to shape. Variation
// selectors are taken out; U+FE0F after it asks for the emoji face.
@(private)
term_cluster :: proc(text: [TERM_CELL_RUNES]rune) -> (r: rune, emoji, one: bool, str: string) {
	buf: [TERM_CELL_RUNES * 4]u8
	n, count := 0, 0
	for ch in text {
		if ch == 0 do break
		if ch == 0xfe0f do emoji = true
		if ch == 0xfe0e || ch == 0xfe0f do continue
		bytes, len_ := utf8.encode_rune(ch)
		for i in 0 ..< len_ do buf[n + i] = bytes[i]
		n += len_
		r = ch
		count += 1
	}
	if count <= 1 do return r, emoji, true, ""
	str = norm.to_nfc(string(buf[:n]), context.temp_allocator)
	if utf8.rune_count_in_string(str) == 1 {
		r, _ = utf8.decode_rune_in_string(str)
		return r, emoji, true, ""
	}
	return 0, emoji, false, str
}

// term_glyph_find rasterises `r` from the first face that has it, at the
// cell's size. A face other than the first choice (a fallback) is centred
// in its `w` px and made smaller if it is wider, or taller than a line.
@(private)
term_glyph_find :: proc(te: ^Text_Engine, st: ^Term_State, r: rune, style: Term_Styles, w: int, emoji := false) -> (g: Term_Glyph) {
	p := st.px
	faces := term_faces(te, st.family, style)
	if emoji { // the emoji face first: ❤️ in colour, not the text heart
		with := make([]^runa.Font, len(faces) + 1, context.temp_allocator)
		with[0] = te.fonts[.Emoji]
		copy(with[1:], faces)
		faces = with
	}
	font: ^runa.Font
	gid: runa.Glyph_ID
	first := true
	for f in faces {
		if f == nil do continue
		if id := runa.font_lookup_glyph(f, r); id != 0 {
			font, gid = f, id
			break
		}
		first = false
	}
	if font == nil {
		first = false
		if f := fallback_for(te, r); f != nil {
			if id := runa.font_lookup_glyph(f, r); id != 0 do font, gid = f, id
		}
	}
	if font == nil || font.units_per_em == 0 do return
	px := p.size * p.scale
	if !first {
		per := px / f32(font.units_per_em)
		adv := f32(runa.font_glyph_advance(font, gid)) * per
		tall := (font.ascent - font.descent) * per
		k := f32(1)
		if adv > f32(w) + 0.5 do k = f32(w) / adv
		if tall * k > f32(p.line) + 0.5 do k = f32(p.line) / tall
		px *= k
		g.dx = math.round(max((f32(w) - adv * k) / 2, 0))
	}
	slot, ok := glyph_slot(te, font, gid, px, 0)
	g.slot, g.ok = slot, ok
	return
}

// term_decorations appends a cell's underline and strike, across its span.
@(private)
term_decorations :: proc(te: ^Text_Engine, st: ^Term_State, cell: Term_Cell, span: int, x, y: f32, fg: Color, out: ^[dynamic]Term_Cmd) {
	p := st.px
	w := f32(span * p.advance)
	th := term_line_w(p)
	if cell.underline != .None {
		col := cell.underline_color if cell.underline_color.a > 0 else fg
		uy := term_underline_y(p, th, cell.underline)
		switch cell.underline {
		case .None:
		case .Single:
			append(out, Term_Cmd{rect = {x, y + uy, w, th}, color = col, page = -1})
		case .Double:
			append(out, Term_Cmd{rect = {x, y + uy, w, th}, color = col, page = -1})
			append(out, Term_Cmd{rect = {x, y + uy + 2 * th, w, th}, color = col, page = -1})
		case .Curly: // a wave its cells long, joined cell to cell
			if slot, ok := cell_shape_slot(te, TERM_WAVE, int(w), int(4 * th)); ok {
				append(out, Term_Cmd{rect = {x, y + uy, f32(slot.px_size.x), f32(slot.px_size.y)}, uv = slot.uv_rect, color = col, page = i32(slot.page_index)})
			}
		case .Dotted:
			for dx := f32(0); dx < w; dx += 2 * th do append(out, Term_Cmd{rect = {x + dx, y + uy, min(th, w - dx), th}, color = col, page = -1})
		case .Dashed:
			dash := math.round(w * 0.6)
			append(out, Term_Cmd{rect = {x + math.round((w - dash) / 2), y + uy, dash, th}, color = col, page = -1})
		}
	}
	if .Strike in cell.style {
		sy := f32(p.ascent) - math.round(p.size * p.scale * 0.27) - math.floor(th / 2)
		append(out, Term_Cmd{rect = {x, y + sy, w, th}, color = fg, page = -1})
	}
}

// term_line_w is the width of a text decoration: a pixel at 14 px text,
// thicker as the text grows.
@(private)
term_line_w :: proc(p: Term_Px) -> f32 {
	return max(math.round(p.size * p.scale / 14), 1)
}

// term_underline_y is where an underline's top is from the cell's top:
// below the baseline, the whole of it (all three strokes of a double,
// the wave's height) inside the cell.
@(private)
term_underline_y :: proc(p: Term_Px, th: f32, kind: Term_Underline) -> f32 {
	below := f32(p.line - p.ascent)
	uy := f32(p.ascent) + max(math.round(below * 0.3), 1)
	tall := th
	#partial switch kind {
	case .Double: tall = 3 * th
	case .Curly:  tall = 4 * th
	}
	return max(min(uy, f32(p.line) - tall), 0)
}

// term_cursor_cmds draws the cursor at its cell: a block (the character
// over it in the cell's background), a bar or an underline while the
// terminal has the keyboard; a hollow box when not.
@(private)
term_cursor_cmds :: proc(t: ^Tree, te: ^Text_Engine, n: Node, st: ^Term_State, scr: ^Term_Screen, out: ^[dynamic]Term_Cmd) {
	cur := scr.cursor
	if cur.hidden || cur.row < 0 || cur.row >= scr.rows || cur.col < 0 || cur.col >= scr.cols do return
	p := st.px
	cells := term_row(scr, cur.row)
	cell := cells[cur.col]
	span := 2 if cell.width == 2 else 1
	x, y := f32(cur.col * p.advance), f32(cur.row * p.line)
	w := f32(span * p.advance)
	col := cur.color if cur.color.a > 0 else scr.foreground
	if !term_has_keyboard(t, n, st) {
		b := max(math.round(p.scale), 1)
		append(out, Term_Cmd{rect = {x, y, w, b}, color = col, page = -1})
		append(out, Term_Cmd{rect = {x, y + f32(p.line) - b, w, b}, color = col, page = -1})
		append(out, Term_Cmd{rect = {x, y + b, b, f32(p.line) - 2 * b}, color = col, page = -1})
		append(out, Term_Cmd{rect = {x + w - b, y + b, b, f32(p.line) - 2 * b}, color = col, page = -1})
		return
	}
	if term_blinking(t, n, st) {
		half, _, _ := caret_timing(t)
		if int((t.now_ms - st.blink_from) / half) % 2 == 1 do return
	}
	switch cur.shape {
	case .Block:
		append(out, Term_Cmd{rect = {x, y, w, f32(p.line)}, color = col, page = -1})
		under := cell.bg if cell.bg.a > 0 else scr.background
		under.a = 1
		if cell.text[0] != 0 do term_cell_glyphs(te, st, cell, span, x, y, under, out)
	case .Bar:
		append(out, Term_Cmd{rect = {x, y, max(math.round(p.scale * 1.5), 1), f32(p.line)}, color = col, page = -1})
	case .Underline:
		h := max(math.round(p.scale * 2), 1)
		append(out, Term_Cmd{rect = {x, y + f32(p.line) - h, w, h}, color = col, page = -1})
	}
}

// term_preedit_cmds draws an input method's composition from the cursor's
// cell on, one character a cell (wide ones two), over the screen's
// background made opaque, underlined, with a bar at its own cursor.
@(private)
term_preedit_cmds :: proc(te: ^Text_Engine, st: ^Term_State, scr: ^Term_Screen, out: ^[dynamic]Term_Cmd) {
	p := st.px
	cur := scr.cursor
	x0, y := f32(clamp(cur.col, 0, max(scr.cols - 1, 0)) * p.advance), f32(clamp(cur.row, 0, max(scr.rows - 1, 0)) * p.line)
	bg := scr.background
	bg.a = 1
	w := f32(term_utf8_cells(st.preedit) * p.advance)
	append(out, Term_Cmd{rect = {x0, y, w, f32(p.line)}, color = bg, page = -1})
	x := x0
	bar_x := x0 + w
	for r, i in st.preedit {
		if i == st.preedit_lo do bar_x = x
		span := 2 if term_rune_wide(r) else 1
		cell := Term_Cell{fg = scr.foreground, width = u8(span)}
		cell.text[0] = r
		term_cell_glyphs(te, st, cell, span, x, y, scr.foreground, out)
		x += f32(span * p.advance)
	}
	th := term_line_w(p)
	append(out, Term_Cmd{rect = {x0, y + term_underline_y(p, th, .Single), w, th}, color = scr.foreground, page = -1})
	if st.preedit_lo >= 0 do append(out, Term_Cmd{rect = {bar_x, y, max(math.round(p.scale * 1.5), 1), f32(p.line)}, color = scr.foreground, page = -1})
}

// term_caret_rect is the cursor's cell in the tree, for an input method's
// candidate window.
@(private)
term_caret_rect :: proc(t: ^Tree, n: Node, d: ^Node_Data, st: ^Term_State) -> Rect {
	if st.screen == nil do return {}
	m := term_px(t, st.family, st.size, st.scale).logical
	c := st.screen.cursor
	g := term_grid_rect(d, st)
	return {g.x + f32(c.col) * m.advance, g.y + f32(c.row) * m.line_height, m.advance, m.line_height}
}
