package baldr

// A terminal's screen: rows × columns of cells the app fills from its
// terminal state (libvterm, a scrollback it keeps), drawn the way a
// terminal draws them, and every key and typed character given back to it
// while it has the keyboard.
//
// It is not a text area in a monospace font: the program has already laid
// the text out, cell by cell, and every glyph sits on its cell and nowhere
// else. The cell's width is a whole number of device pixels, each glyph is
// placed at its cell's origin rather than advanced by the font,
// backgrounds are runs of one colour with edges on device pixels (no seams),
// and box drawing, block elements, braille and powerline separators fill
// the cell exactly so lines join and graphs are solid. What the family
// lacks comes from the toolkit's fonts and the system's, and an emoji over
// two cells is fitted to them.
//
// Nor is it rebuilt as a whole: the app says which rows it changed
// (term_touch); each row's drawing is kept in device pixels, only a
// changed row is made again, and only changed rows are damage for the
// compositor.
//
// The keyboard: while the terminal has focus every key goes to the
// program — Tab, Shift+Tab, Escape, F10, Alt and Super with the arrows —
// after the app's own shortcut() calls have had their turn (so a terminal
// keeps Ctrl+Shift+C for itself). Ctrl+Tab and Ctrl+Shift+Tab, when the
// app has not bound them, move focus out, so the keyboard is never
// trapped. An input method composes at the cursor (Ime_Purpose.Terminal),
// and what it commits arrives as text.
//
// Accessibility: the node is a Terminal; a reader gets the screen as text,
// one line per row, with the caret at the cursor, and hears what changes
// on it as the text it inserts. The cursor is the focus indicator, as in
// every terminal: solid while it has the keyboard, hollow when not.

import "base:runtime"
import "core:math"
import "core:strings"
import runa "baldr:third_party/runa"

// TERM_CELL_RUNES is how many code points one cell holds: a character and
// the marks combined with it (libvterm's VTERM_MAX_CHARS_PER_CELL).
TERM_CELL_RUNES :: 6

// Term_Style is how a cell's text is set, beyond its colours.
Term_Style :: enum u8 { Bold, Italic, Dim, Strike }
Term_Styles :: bit_set[Term_Style; u8]

// Term_Underline is how a cell's text is underlined.
Term_Underline :: enum u8 { None, Single, Double, Curly, Dotted, Dashed }

// Term_Cell is one cell of the screen. `text` is one grapheme cluster, its
// code points in order and the rest zero; all zero is an empty cell, and
// the right half of a wide character. `width` is 2 on a wide character's
// left half (the next cell is its right half), else 1. `bg` with alpha 0
// is none: the screen's background shows. `underline_color` with alpha 0
// is the text's own colour.
Term_Cell :: struct {
	text:            [TERM_CELL_RUNES]rune,
	fg, bg:          Color,
	underline_color: Color,
	style:           Term_Styles,
	underline:       Term_Underline,
	width:           u8,
}

// Term_Cursor_Shape is how the cursor is drawn at its cell.
Term_Cursor_Shape :: enum u8 { Block, Bar, Underline }

// Term_Cursor is where the cursor is and how it looks. `color` with alpha
// 0 is the screen's foreground. It is drawn hollow while the terminal
// hasn't the keyboard; `blink` blinks it while it has (never with reduced
// motion), and a key press shows it again.
Term_Cursor :: struct {
	col, row: int,
	shape:    Term_Cursor_Shape,
	hidden:   bool,
	blink:    bool,
	color:    Color,
}

// Term_Screen is what a terminal shows, owned by the app and edited in
// place, like a Document: fill its cells, then term_touch the rows you
// changed so the view draws them again. `foreground` is the default text
// colour (the cursor's, and an input method's composition); `background`
// is behind every cell whose own is none, and may be translucent (a window
// with `transparent` and a clear `clear` shows the desktop through it
// while the cells' own backgrounds stay opaque).
Term_Screen :: struct {
	cols, rows: int,
	cells:      []Term_Cell, // rows × cols, row after row
	row_rev:    []u64,       // when each row last changed (term_touch)
	rev:        u64,
	cursor:     Term_Cursor,
	foreground: Color,
	background: Color,
	allocator:  runtime.Allocator,
}

// term_screen_resize makes the screen `want_cols` × `want_rows`, keeping what fits
// of what it held (top left), with new cells empty. Every row counts as
// changed. The cells are allocated with `allocator` (the first call's, if
// later calls pass another); term_screen_destroy frees them.
term_screen_resize :: proc(s: ^Term_Screen, want_cols, want_rows: int, allocator := context.allocator) {
	cols, rows := max(want_cols, 0), max(want_rows, 0)
	if s.allocator.procedure == nil do s.allocator = allocator
	if cols == s.cols && rows == s.rows && len(s.cells) == cols * rows {
		term_touch_all(s)
		return
	}
	cells := make([]Term_Cell, cols * rows, s.allocator)
	for &c in cells do c = {fg = s.foreground, width = 1}
	for r in 0 ..< min(rows, s.rows) {
		n := min(cols, s.cols)
		copy(cells[r * cols:r * cols + n], s.cells[r * s.cols:r * s.cols + n])
	}
	delete(s.cells, s.allocator)
	delete(s.row_rev, s.allocator)
	s.cells = cells
	s.row_rev = make([]u64, rows, s.allocator)
	s.cols, s.rows = cols, rows
	s.cursor.col = clamp(s.cursor.col, 0, max(cols - 1, 0))
	s.cursor.row = clamp(s.cursor.row, 0, max(rows - 1, 0))
	term_touch_all(s)
}

// term_screen_destroy frees the screen's cells.
term_screen_destroy :: proc(s: ^Term_Screen) {
	if s.allocator.procedure != nil {
		delete(s.cells, s.allocator)
		delete(s.row_rev, s.allocator)
	}
	s.cells, s.row_rev = nil, nil
	s.cols, s.rows = 0, 0
}

// term_row is row `row`'s cells, an alias into the screen that the next
// term_screen_resize invalidates; nil for a row it hasn't.
term_row :: proc(s: ^Term_Screen, row: int) -> []Term_Cell {
	if row < 0 || row >= s.rows || len(s.cells) < (row + 1) * s.cols do return nil
	return s.cells[row * s.cols:(row + 1) * s.cols]
}

// term_cell_set puts `text` (one grapheme cluster: at most
// TERM_CELL_RUNES code points are kept) into a cell's `text`.
term_cell_set :: proc(c: ^Term_Cell, text: string) {
	c.text = {}
	i := 0
	for r in text {
		if i == TERM_CELL_RUNES do break
		c.text[i] = r
		i += 1
	}
}

// term_touch says row `row` changed: the view draws it again, and it is
// the compositor's damage.
term_touch :: proc(s: ^Term_Screen, row: int) {
	if row < 0 || row >= len(s.row_rev) do return
	s.rev += 1
	s.row_rev[row] = s.rev
}

// term_touch_all says every row changed (the screen scrolled, the app
// showed its scrollback).
term_touch_all :: proc(s: ^Term_Screen) {
	s.rev += 1
	for &r in s.row_rev do r = s.rev
}

// Cell_Metrics is the size of a cell in logical px, already on device
// pixels: `advance` wide, `line_height` tall, the baseline `ascent` below
// its top. The grid's columns are multiples of `advance` from its left.
Cell_Metrics :: struct {
	advance, line_height, ascent: f32,
}

// Term_Size is the grid a terminal's node holds, sent to `on_resize` when
// it changes (the pty is resized to match): `cols` × `rows` whole cells,
// the cell's metrics, and `px`, the grid in device pixels (a pty's
// ws_xpixel, ws_ypixel).
Term_Size :: struct {
	cols, rows: int,
	cell:       Cell_Metrics,
	px:         [2]int,
}

// Term_Key is a key pressed (or repeating) while the terminal has the
// keyboard. `key` is the portable key (Unknown for one Baldr has no name
// for); `keysym` is the platform's own code, an xkb keysym on Linux, which
// tells the keypad's keys and dead keys apart; `char` is the character the
// key makes with the layout and Shift, Ctrl and Alt aside (Ctrl+C: 'c',
// Alt+Shift+A: 'A'; 0 for none); `text` is what it types — "" with Ctrl,
// Alt or Super held, for a key that types nothing (an arrow, Enter, a dead
// key), and never a control character. `text` lives while the message is
// handled: clone it to keep it.
Term_Key :: struct {
	key:    Key,
	keysym: u32,
	char:   rune,
	mods:   Mods,
	repeat: bool,
	text:   string,
}

// Term_Handlers is what a terminal reports to, kept on the Ui.
@(private)
Term_Handlers :: struct($Msg: typeid) {
	on_key:    Handler(Msg, Term_Key),
	on_text:   Handler(Msg, string),
	on_resize: Handler(Msg, Term_Size),
}

// Term_Pending is a key held back for a moment, for the text it types,
// which the platform sends as an event of its own just after it.
@(private)
Term_Pending :: struct {
	node: Node,
	key:  Term_Key,
	on:   bool,
}

// terminal shows `screen` in `family` at `size` (logical px, scaled by the
// desktop's text size; 0: the theme's body size). The family is found by
// name among the machine's fonts ("JetBrains Mono"); without it, and for an
// empty name, the toolkit's own monospace face draws. Bold is the family's
// bold face.
//
// While it has the keyboard, `on_key` hears every key the app's shortcuts
// don't take (see Term_Key) and `on_text` what an input method commits.
// `on_resize` hears the grid its node holds, when that changes — at first,
// on a resize, when the scale or the font changes; the app resizes its pty
// and its screen to it (a screen of another size is drawn from the top
// left, clipped). `padding` is a margin in logical px on every side, in the
// screen's background (one fill with the grid's, so a translucent one is
// even): the grid starts inside it and the cells counted are those that fit
// inside it. Pointer samples, the wheel and drops still measure from the
// node's top left, so subtract `padding` to find a cell. It takes `flex` of
// its parent's room (1: all of it) and is at least one cell and its margin.
// `label` names it for a reader (its title).
//
//	baldr.terminal(ui, &s.screen, on_key = key_to_pty, on_text = text_to_pty,
//		on_resize = resize_pty, family = s.conf.font, size = s.conf.size, label = s.title)
terminal :: proc(ui: ^Ui($Msg), screen: ^Term_Screen, on_key: Handler(Msg, Term_Key) = nil, on_text: Handler(Msg, string) = nil,
	on_resize: Handler(Msg, Term_Size) = nil, family: string = "", size: f32 = 0, padding: f32 = 0, width: f32 = 0, height: f32 = 0,
	flex: f32 = 1, label: string = "", disabled := false, tag: u64 = 0, key: u64 = 0, loc := #caller_location) -> Node {
	n, created := reconcile_child(ui, .Custom, key, loc)
	t := &ui.tree
	d := node_get(t, n)
	if created {
		d.access.role = .Terminal
		d.access.states += {.Focusable}
		d.flags += {.Focusable, .Clips, .Ring_Inside}
		d.kind = Custom_Kind{paint = paint_terminal, measure = measure_terminal}
		t.terminals[n] = Term_State{rows = make([dynamic]Term_Row, t.allocator), glyphs = make(map[Term_Glyph_Key]Term_Glyph, t.allocator)}
		mark_layout_dirty(t, n)
	}
	st := &t.terminals[n]
	st.screen = screen
	if st.keyboard != ui.surface.keyboard { // the window gained or lost the keyboard: the cursor turns solid or hollow
		st.keyboard = ui.surface.keyboard
		mark_paint_dirty(t, n)
	}
	if sc := device_scale(ui); st.scale != sc { // another screen's scale: the cell is on other device pixels
		st.scale = sc
		term_forget_draws(st)
		mark_layout_dirty(t, n)
	}
	fam := text_family(t.text, family) if t.text != nil else 0
	if st.family != fam || st.family_name != family {
		st.family = fam
		delete(st.family_name, t.allocator)
		st.family_name = strings.clone(family, t.allocator)
		term_forget_draws(st)
		mark_layout_dirty(t, n)
	}
	if pad := max(padding, 0); st.padding != pad { // the margin: the grid moves in, and holds fewer cells
		st.padding = pad
		mark_layout_dirty(t, n)
		mark_paint_dirty(t, n)
	}
	sz := size * tree_text_scale(t) if size > 0 else t.theme.type.body.size // the body size is scaled already
	if st.size != sz {
		st.size = sz
		term_forget_draws(st)
		mark_layout_dirty(t, n)
	}
	d.tag = tag
	set_name(t, n, label)
	set_disabled(t, n, disabled)
	set_layout(t, n, Layout_Props{width = width, height = height, flex = flex})
	style := d.style
	style.bg = screen.background if screen != nil else {}
	set_style(t, n, style)
	ui.term_handlers[n] = Term_Handlers(Msg){on_key = on_key, on_text = on_text, on_resize = on_resize}
	term_damage_changed(t, n, d, st)
	term_preedit_sync(t, n, st)
	if a11y_on() do term_access_text(t, d, st) // what a reader reads, only while one is listening
	return n
}

// cell_metrics is the cell of `family` at `size` (as `terminal` takes
// them) on this surface: its scale puts the cell on device pixels. An app
// sizes a window in cells with it (80 × 24 before the first on_resize).
cell_metrics :: proc(ui: ^Ui($Msg), family: string = "", size: f32 = 0) -> Cell_Metrics {
	t := &ui.tree
	fam := text_family(t.text, family) if t.text != nil else 0
	sz := size * tree_text_scale(t) if size > 0 else t.theme.type.body.size // the body size is scaled already
	return term_px(t, fam, sz, device_scale(ui)).logical
}

// Term_Px is a cell in device pixels at one scale, and the same in logical
// px: the grid is laid on the device pixels, so the logical metrics are
// those divided by the scale.
@(private)
Term_Px :: struct {
	scale:    f32,
	size:     f32, // the font size, logical px
	advance:  int,
	line:     int,
	ascent:   int,
	logical:  Cell_Metrics,
}

// term_px measures a cell of `family` at `size` for `scale`: the advance of
// "0" and the family's line height, each rounded to whole device pixels
// (never under one).
@(private)
term_px :: proc(t: ^Tree, family: Family_Id, size, scale: f32) -> (p: Term_Px) {
	s := scale if scale > 0 else 1
	adv, lh, asc := size * 0.6, size * 1.25, size * 0.95
	if te := t.text; te != nil && te.ok && text_size_ok(size) {
		f := term_regular_face(te, family)
		if f != nil && f.units_per_em > 0 {
			k := size / f32(f.units_per_em)
			if gid := runa.font_lookup_glyph(f, '0'); gid != 0 do adv = f32(runa.font_glyph_advance(f, gid)) * k
			lh = (f.ascent - f.descent + f.line_gap) * k
			asc = f.ascent * k
		}
	}
	p.scale, p.size = s, size
	p.advance = max(int(math.round(adv * s)), 1)
	p.line = max(int(math.round(lh * s)), 1)
	p.ascent = clamp(int(math.round(asc * s)), 0, p.line)
	p.logical = {advance = f32(p.advance) / s, line_height = f32(p.line) / s, ascent = f32(p.ascent) / s}
	return
}

// measure_terminal: at least one cell, and whatever the node's own size
// and flex give it beyond that.
@(private)
measure_terminal :: proc(t: ^Tree, n: Node, d: ^Node_Data, cc: Constraints) -> [2]f32 {
	st, ok := &t.terminals[n]
	if !ok do return constrain(cc, {})
	m := term_px(t, st.family, st.size, st.scale).logical
	return constrain(cc, {m.advance + 2 * st.padding, m.line_height + 2 * st.padding})
}

// term_grid is how many whole cells a node of `size` holds (at least one
// each way).
@(private)
term_grid :: proc(p: Term_Px, size: [2]f32) -> (cols, rows: int) {
	cols = max(int(math.floor(size.x * p.scale + 0.01)) / p.advance, 1)
	rows = max(int(math.floor(size.y * p.scale + 0.01)) / p.line, 1)
	return
}

// terminal_tick tells each terminal's app what grid its node holds now,
// after the latest layout, when that changed. The run loop calls it after
// the events and after each frame (a resize is laid out in the frame).
@(private)
terminal_tick :: proc(ui: ^Ui($Msg)) {
	t := &ui.tree
	for n, &st in t.terminals {
		d := node_get(t, n)
		h, has := ui.term_handlers[n]
		if d == nil || !has || !handler_live(h.on_resize) || d.abs.w <= 0 || d.abs.h <= 0 do continue
		p := term_px(t, st.family, st.size, st.scale)
		g := term_grid_rect(d, &st)
		cols, rows := term_grid(p, {g.w, g.h})
		size := Term_Size{cols = cols, rows = rows, cell = p.logical, px = {cols * p.advance, rows * p.line}}
		if st.sent == size do continue
		st.sent = size
		handler_send(ui, h.on_resize, size, n)
	}
}

// term_focused is the terminal that has the keyboard, if one does: focused,
// enabled, and not behind a modal dialog.
@(private)
term_focused :: proc(ui: ^Ui($Msg)) -> (Node, bool) {
	t := &ui.tree
	n := t.focus
	if n == NODE_NONE || n not_in t.terminals || !focusable(t, n) do return NODE_NONE, false
	if t.modal != NODE_NONE && !node_within(t, n, t.modal) do return NODE_NONE, false
	return n, true
}

// term_key_event offers a key press to the focused terminal. The app's
// shortcuts go first; then Ctrl+Tab and Ctrl+Shift+Tab leave it; every
// other press is the terminal's, held back until the text it types (if
// any) arrives. True when the key was taken.
@(private)
term_key_event :: proc(ui: ^Ui($Msg), key: Key, native: u32, pressed, repeat: bool, mods: Mods) -> bool {
	if !pressed do return false
	n, ok := term_focused(ui)
	if !ok do return false
	term_flush(ui) // the key before it typed nothing
	if shortcut_fire(ui, key, true, mods) do return true
	if key == .Tab && .Ctrl in mods && mods & {.Alt, .Super} == {} { // the way out, so the keyboard is never trapped
		focus_next(&ui.tree, .Shift in mods)
		return true
	}
	if st, has := &ui.tree.terminals[n]; has do term_blink_restart(&ui.tree, n, st)
	// The keysym first, which knows the layout and the dead keys; then the
	// portable key, which is all there is to go on off Linux (there the
	// native code is not a keysym, so keysym_char gives 0).
	ch := keysym_char(native)
	if ch == 0 do ch = key_char(key, mods)
	ui.term_pending = {node = n, on = true, key = {key = key, keysym = native, char = ch, mods = mods, repeat = repeat}}
	return true
}

// term_text_event is typed text (Ev_Text): the text of the key held back,
// or text of its own. True when a terminal took it.
@(private)
term_text_event :: proc(ui: ^Ui($Msg), text: string) -> bool {
	if ui.term_pending.on {
		p := ui.term_pending
		ui.term_pending = {}
		p.key.text = text
		if h, has := ui.term_handlers[p.node]; has do handler_send(ui, h.on_key, p.key, p.node)
		return true
	}
	return term_commit(ui, ui.tree.focus, text)
}

// term_flush sends the key held back with no text: nothing followed it.
@(private)
term_flush :: proc(ui: ^Ui($Msg)) {
	if !ui.term_pending.on do return
	p := ui.term_pending
	ui.term_pending = {}
	if h, has := ui.term_handlers[p.node]; has do handler_send(ui, h.on_key, p.key, p.node)
}

// term_commit gives text an input method committed to terminal `n`, if `n`
// is one with the keyboard.
@(private)
term_commit :: proc(ui: ^Ui($Msg), n: Node, text: string) -> bool {
	f, ok := term_focused(ui)
	if !ok || f != n || len(text) == 0 do return false
	term_flush(ui)
	if h, has := ui.term_handlers[n]; has do handler_send(ui, h.on_text, text, n)
	return true
}

// KEY_CHARS is the character each portable Key types unshifted, for the
// platforms whose native code is not an xkb keysym. Letters and digits
// only: everything else either types nothing or depends on the layout in a
// way the portable key cannot tell us.
// rodata, not a constant: Odin cannot index a constant with a variable, and
// the same table as a `::` costs a 500-byte copy at every keypress.
@(private, rodata)
KEY_CHARS := #partial [Key]rune{
	.A = 'a', .B = 'b', .C = 'c', .D = 'd', .E = 'e', .F = 'f', .G = 'g',
	.H = 'h', .I = 'i', .J = 'j', .K = 'k', .L = 'l', .M = 'm', .N = 'n',
	.O = 'o', .P = 'p', .Q = 'q', .R = 'r', .S = 's', .T = 't', .U = 'u',
	.V = 'v', .W = 'w', .X = 'x', .Y = 'y', .Z = 'z',
	.N0 = '0', .N1 = '1', .N2 = '2', .N3 = '3', .N4 = '4',
	.N5 = '5', .N6 = '6', .N7 = '7', .N8 = '8', .N9 = '9',
}

// key_char is the character a portable Key makes, for the platforms whose
// native codes are not xkb keysyms (macOS, Windows): letters and digits,
// 0 for anything else. Shift upper-cases a letter, as `Term_Key.char`
// promises (Alt+Shift+A is 'A'); a *shifted digit* returns 0 rather than
// guess, since what it types is the layout's business — Shift+2 is '"' on
// a GB keyboard and '@' on a US one, and the key alone cannot say which.
@(private)
key_char :: proc "contextless" (key: Key, mods: Mods) -> rune {
	c := KEY_CHARS[key]
	if c == 0 do return 0
	if .Shift in mods {
		if c >= 'a' && c <= 'z' do return c - 32
		return 0 // a digit: the layout decides, so say nothing
	}
	return c
}

// keysym_char is the character an xkb keysym stands for (Latin-1 and the
// Unicode keysyms; the keypad's digits and operators), 0 for none. Off
// Linux a native code is not a keysym at all, so this says nothing and
// `key_char` answers from the portable key instead — see term_key_event.
@(private)
keysym_char :: proc "contextless" (sym: u32) -> rune {
	when ODIN_OS == .Linux || ODIN_OS == .FreeBSD || ODIN_OS == .OpenBSD {
		switch sym {
		case 0x20 ..= 0x7e, 0xa0 ..= 0xff: return rune(sym)
		case 0x0100_0100 ..= 0x0110_ffff:  return rune(sym - 0x0100_0000)
		case 0xffb0 ..= 0xffb9:            return rune('0' + (sym - 0xffb0)) // KP_0 … KP_9
		case 0xffaa: return '*'
		case 0xffab: return '+'
		case 0xffad: return '-'
		case 0xffae: return '.'
		case 0xffaf: return '/'
		case 0xffbd: return '='
		}
		return 0
	} else {
		return 0
	}
}

// term_forget_draws drops every row's drawing: the font, the size or the
// scale changed.
@(private)
term_forget_draws :: proc(st: ^Term_State) {
	for &r in st.rows do r.valid = false
	st.px = {}
	clear(&st.glyphs)
}

// term_damage_changed makes the rows the app changed since the last build,
// and the cursor's old and new cells, the compositor's damage (in the
// node's latest place), without repainting the rest of it.
@(private)
term_damage_changed :: proc(t: ^Tree, n: Node, d: ^Node_Data, st: ^Term_State) {
	s := st.screen
	if s == nil do return
	if len(st.seen) != s.rows {
		delete(st.seen)
		st.seen = make([]u64, s.rows, t.allocator)
		copy(st.seen, s.row_rev) // drawn whole now: every row as it is
		mark_paint_dirty(t, n) // another size of screen: all of it
		st.cursor_seen = s.cursor
		return
	}
	if d.abs.w <= 0 || d.abs.h <= 0 do return
	m := term_px(t, st.family, st.size, st.scale).logical
	g := term_grid_rect(d, st)
	for r in 0 ..< min(s.rows, len(s.row_rev)) {
		if st.seen[r] == s.row_rev[r] do continue
		st.seen[r] = s.row_rev[r]
		damage_add(t, rect_clip(Rect{g.x, g.y + f32(r) * m.line_height, g.w, m.line_height}, g))
	}
	if st.cursor_seen != s.cursor {
		for c in ([2]Term_Cursor{st.cursor_seen, s.cursor}) {
			damage_add(t, rect_clip(Rect{g.x + f32(c.col) * m.advance - 1, g.y + f32(c.row) * m.line_height, m.advance * 2 + 2, m.line_height}, d.abs))
		}
		st.cursor_seen = s.cursor
	}
}

// term_preedit_sync keeps a copy of the input method's composition for the
// terminal that shows it, to draw at the cursor.
@(private)
term_preedit_sync :: proc(t: ^Tree, n: Node, st: ^Term_State) {
	if ime_keep(t, n, &st.preedit, &st.preedit_lo, &st.preedit_hi) do mark_paint_dirty(t, n)
}

// term_access_text is the screen as a reader reads it: a line per row, the
// spaces at its end dropped, and where the cursor is in it.
@(private)
term_access_text :: proc(t: ^Tree, d: ^Node_Data, st: ^Term_State) {
	s := st.screen
	if s == nil do return
	if st.text_rev == s.rev && st.text_cursor == s.cursor && len(st.text) > 0 {
		d.access.value_text = st.text
		return
	}
	b := strings.builder_make(context.temp_allocator)
	caret := -1
	for r in 0 ..< s.rows {
		if r > 0 do strings.write_byte(&b, '\n')
		row := term_row(s, r)
		start := strings.builder_len(b)
		for c, col in row {
			if r == s.cursor.row && col == s.cursor.col do caret = strings.builder_len(b)
			if c.text[0] == 0 {
				if c.width != 0 && !term_wide_right(row, col) do strings.write_byte(&b, ' ')
				continue
			}
			for ch in c.text {
				if ch == 0 do break
				strings.write_rune(&b, ch)
			}
		}
		// the row's trailing blanks go, the caret with them to the row's end
		end := strings.builder_len(b)
		for end > start && b.buf[end - 1] == ' ' do end -= 1
		resize(&b.buf, end)
		if caret > end do caret = end
	}
	delete(st.text, t.allocator)
	st.text = strings.clone(strings.to_string(b), t.allocator)
	st.text_rev, st.text_cursor = s.rev, s.cursor
	st.caret = caret
	d.access.value_text = st.text
	d.access.has_value = true
}

// term_grid_rect is where the grid is: the node less its margin.
@(private)
term_grid_rect :: proc(d: ^Node_Data, st: ^Term_State) -> Rect {
	p := st.padding
	return {d.abs.x + p, d.abs.y + p, max(d.abs.w - 2 * p, 0), max(d.abs.h - 2 * p, 0)}
}

// term_wide_right: the cell at `col` is the right half of the wide
// character before it.
@(private)
term_wide_right :: proc(row: []Term_Cell, col: int) -> bool {
	return col > 0 && row[col - 1].width == 2
}

// term_free gives a terminal's kept drawing back when its node goes.
@(private)
term_free :: proc(t: ^Tree, n: Node) {
	st, has := &t.terminals[n]
	if !has do return
	for &r in st.rows {
		delete(r.back)
		delete(r.fore)
	}
	delete(st.rows)
	delete(st.seen)
	delete(st.glyphs)
	delete(st.family_name, t.allocator)
	delete(st.preedit, t.allocator)
	delete(st.text, t.allocator)
	delete_key(&t.terminals, n)
}

// term_rune_wide: a character that takes two cells (East Asian wide and
// full-width, and emoji shown as emoji), for a composition drawn at the
// cursor, which no program has laid out.
@(private)
term_rune_wide :: proc "contextless" (r: rune) -> bool {
	switch r {
	case 0x1100 ..= 0x115f, 0x2e80 ..= 0x303e, 0x3041 ..= 0x33ff, 0x3400 ..= 0x4dbf, 0x4e00 ..= 0x9fff,
	     0xa000 ..= 0xa4cf, 0xac00 ..= 0xd7a3, 0xf900 ..= 0xfaff, 0xfe30 ..= 0xfe4f, 0xff00 ..= 0xff60,
	     0xffe0 ..= 0xffe6, 0x1f300 ..= 0x1f64f, 0x1f900 ..= 0x1f9ff, 0x20000 ..= 0x3fffd:
		return true
	}
	return false
}

// term_utf8_cells is how many cells `s` takes laid one character a cell,
// wide ones two.
@(private)
term_utf8_cells :: proc(s: string) -> (n: int) {
	for r in s do n += 2 if term_rune_wide(r) else 1
	return
}
