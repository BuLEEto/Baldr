package baldr

@(require) import "core:strings"
@(require) import "core:testing"
@(require) import "baldr:gpu"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A terminal's screen: its grid and the size it reports, the keys and text
// it takes, what a reader gets, the rows drawn again, the shapes drawn to
// fill a cell, and the click count and primary selection it relies on.


@(private = "file")
Tty_Msg :: union { Term_Key, string, Term_Size, Tm_Copy }
@(private = "file")
Tm_Copy :: struct {}

@(private = "file")
tm_key :: proc(e: Ev(Term_Key)) -> Tty_Msg {
	k := e.value
	k.text = strings.clone(k.text, context.temp_allocator)
	return k
}
@(private = "file")
tm_text :: proc(e: Ev(string)) -> Tty_Msg { return strings.clone(e.value, context.temp_allocator) }
@(private = "file")
tm_size :: proc(e: Ev(Term_Size)) -> Tty_Msg { return e.value }

// a window with a terminal and a button after it
@(private = "file")
tm_view :: proc(ui: ^Ui(Tty_Msg), s: ^Term_Screen, viewport := [2]f32{500, 300}) -> (term, after: Node) {
	begin_view(ui)
	column(ui)
	shortcut(ui, "Ctrl+Shift+C", Tty_Msg(Tm_Copy{}))
	term = terminal(ui, s, on_key = tm_key, on_text = tm_text, on_resize = tm_size, size = 14, label = "shell")
	after = button(ui, "After", Tty_Msg(Tm_Copy{}))
	end(ui)
	end_view(ui)
	frame(&ui.tree, viewport)
	return
}

@(private = "file")
tm_screen :: proc(cols, rows: int) -> (s: Term_Screen) {
	s.foreground = {0.9, 0.9, 0.9, 1}
	s.background = {0.1, 0.1, 0.1, 1}
	term_screen_resize(&s, cols, rows)
	return
}

@(private = "file")
tm_write :: proc(s: ^Term_Screen, row: int, text: string) {
	cells := term_row(s, row)
	i := 0
	for r in text {
		if i >= len(cells) do break
		cells[i].text = {}
		cells[i].text[0] = r
		cells[i].fg = s.foreground
		i += 1
	}
	term_touch(s, row)
}

// The grid is whole cells of the family at its size, on device pixels, and
// the app hears it at first and whenever it changes (a resize, the scale).
@(test)
a_terminal_reports_the_grid_its_node_holds :: proc(t: ^testing.T) {
	ui: Ui(Tty_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	te: Text_Engine
	if !text_engine_init(&te) {
		testing.fail_now(t, "text engine")
	}
	defer text_engine_destroy(&te)
	ui.tree.text = &te
	s := tm_screen(10, 4)
	defer term_screen_destroy(&s)

	n, _ := tm_view(&ui, &s)
	clear(&ui.msgs)
	terminal_tick(&ui)
	testing.expect_value(t, len(ui.msgs), 1)
	size, ok := ui.msgs[0].(Term_Size)
	testing.expect(t, ok, "a size came")
	m := size.cell
	testing.expect(t, m.advance > 5 && m.advance < 12, "a monospace cell at 14 px")
	testing.expect_value(t, m.advance, f32(int(m.advance))) // whole device pixels at scale 1
	d := node_get(&ui.tree, n)
	testing.expect_value(t, size.cols, int(d.abs.w / m.advance))
	testing.expect_value(t, size.rows, int(d.abs.h / m.line_height))
	testing.expect_value(t, size.px, [2]int{size.cols * int(m.advance), size.rows * int(m.line_height)})
	testing.expect_value(t, cell_metrics(&ui, size = 14), m) // what the app can ask for before the first one

	clear(&ui.msgs)
	terminal_tick(&ui)
	testing.expect_value(t, len(ui.msgs), 0) // nothing changed: nothing said

	tm_view(&ui, &s, {800, 300}) // wider
	clear(&ui.msgs)
	terminal_tick(&ui)
	testing.expect_value(t, len(ui.msgs), 1)
	if len(ui.msgs) == 1 do testing.expect(t, ui.msgs[0].(Term_Size).cols > size.cols, "more columns")

	ui.surface.scale = 1.5 // another screen: the cell is on its device pixels
	tm_view(&ui, &s, {800, 300})
	clear(&ui.msgs)
	terminal_tick(&ui)
	testing.expect_value(t, len(ui.msgs), 1)
	if len(ui.msgs) == 1 {
		m2 := ui.msgs[0].(Term_Size).cell
		px := m2.advance * 1.5
		testing.expect(t, abs(px - f32(int(px + 0.5))) < 0.001, "the advance is whole device pixels")
	}
}

// While it has the keyboard, every key is the terminal's — Tab, Alt+Left,
// Escape — after the app's shortcuts; Ctrl+Tab leaves it. A key's text comes
// with it; a key that types nothing comes alone.
@(test)
a_focused_terminal_takes_every_key :: proc(t: ^testing.T) {
	ui: Ui(Tty_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	s := tm_screen(10, 4)
	defer term_screen_destroy(&s)
	n, after := tm_view(&ui, &s)
	set_focus(&ui.tree, n, true)
	clear(&ui.msgs)

	keys := [?]struct{ key: Key, sym: u32, mods: Mods }{
		{.Tab, 0xff09, {}},
		{.Tab, 0xfe20, {.Shift}}, // ISO_Left_Tab
		{.Left, 0xff51, {.Alt}},  // the window's Back anywhere else
		{.Escape, 0xff1b, {}},
		{.F10, 0xffc7, {}},       // a menu bar's anywhere else
	}
	for k in keys {
		testing.expect(t, term_key_event(&ui, k.key, k.sym, true, false, k.mods), "taken")
		term_flush(&ui)
	}
	testing.expect_value(t, len(ui.msgs), len(keys))
	for k, i in keys {
		got, ok := ui.msgs[i].(Term_Key)
		testing.expect(t, ok && got.key == k.key && got.keysym == k.sym && got.mods == k.mods && got.text == "", "the key as pressed")
	}
	testing.expect_value(t, ui.tree.focus, n) // Tab moved nothing

	clear(&ui.msgs)
	testing.expect(t, term_key_event(&ui, .A, 0x61, true, false, {}), "taken")
	testing.expect(t, term_text_event(&ui, "a"), "its text")
	testing.expect_value(t, len(ui.msgs), 1)
	if k, ok := ui.msgs[0].(Term_Key); ok {
		testing.expect_value(t, k.text, "a")
		testing.expect_value(t, k.char, 'a')
	}

	clear(&ui.msgs)
	term_key_event(&ui, .C, 0x63, true, true, {.Ctrl}) // Ctrl+C, repeating: no text
	term_flush(&ui)
	if k, ok := ui.msgs[0].(Term_Key); ok {
		testing.expect_value(t, k.char, 'c')
		testing.expect(t, k.repeat, "repeat")
	}

	clear(&ui.msgs)
	testing.expect(t, term_key_event(&ui, .C, 0x43, true, false, {.Ctrl, .Shift}), "taken")
	term_flush(&ui)
	testing.expect_value(t, len(ui.msgs), 1)
	_, copied := ui.msgs[0].(Tm_Copy)
	testing.expect(t, copied, "the app's shortcut first")

	clear(&ui.msgs)
	testing.expect(t, !term_key_event(&ui, .A, 0x61, false, false, {}), "a release is not the terminal's")
	testing.expect(t, term_key_event(&ui, .Tab, 0xff09, true, false, {.Ctrl}), "Ctrl+Tab")
	testing.expect_value(t, ui.tree.focus, after) // the way out
	testing.expect_value(t, len(ui.msgs), 0)
	testing.expect(t, !term_key_event(&ui, .Tab, 0xff09, true, false, {}), "not focused: not the terminal's")
}

// Off Linux a native key code is not an xkb keysym, so `char` comes from the
// portable Key instead; read as a keysym, every key would report char = 0.
@(test)
a_terminal_names_the_character_off_linux :: proc(t: ^testing.T) {
	// key_char is the portable half on its own, so this holds on every
	// platform rather than only where keysym_char says nothing.
	testing.expect_value(t, key_char(.A, {}), 'a')
	testing.expect_value(t, key_char(.Z, {}), 'z')
	testing.expect_value(t, key_char(.N7, {}), '7')
	testing.expect_value(t, key_char(.A, {.Shift}), 'A')          // char keeps Shift
	testing.expect_value(t, key_char(.C, {.Ctrl}), 'c')           // and ignores Ctrl
	testing.expect_value(t, key_char(.A, {.Ctrl, .Alt, .Shift}), 'A')
	testing.expect_value(t, key_char(.N7, {.Shift}), rune(0))     // the layout's, not ours
	testing.expect_value(t, key_char(.Tab, {}), rune(0))          // types nothing
	testing.expect_value(t, key_char(.F10, {}), rune(0))
	testing.expect_value(t, key_char(.Unknown, {}), rune(0))

	// and the whole path, with a native code that is not a keysym — which is
	// what a macOS or Windows backend passes (kVK_ANSI_C is 8, not 0x63).
	ui: Ui(Tty_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	s := tm_screen(10, 4)
	defer term_screen_destroy(&s)
	n, _ := tm_view(&ui, &s)
	set_focus(&ui.tree, n, true)
	clear(&ui.msgs)

	testing.expect(t, term_key_event(&ui, .C, 8, true, false, {}), "taken")
	term_flush(&ui)
	if k, ok := ui.msgs[0].(Term_Key); ok {
		testing.expect_value(t, k.char, 'c')
		testing.expect_value(t, k.keysym, u32(8)) // the native code is still reported as given
	} else {
		testing.fail_now(t, "no Term_Key")
	}
}

// A reader gets a Terminal whose text is the screen, a line a row, with
// the caret at the cursor; an input method composes there, and what it
// commits is typed.
@(test)
a_terminal_reads_as_its_screen_and_composes_at_its_cursor :: proc(t: ^testing.T) {
	ui: Ui(Tty_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	s := tm_screen(8, 3)
	defer term_screen_destroy(&s)
	tm_write(&s, 0, "$ ls")
	tm_write(&s, 1, "a  b")
	s.cursor = {col = 2, row = 1}
	n, _ := tm_view(&ui, &s)
	testing.expect(t, strings.contains(access_dump(&ui.tree), "Terminal \"shell\""), "a named terminal")

	st := &ui.tree.terminals[n]
	term_access_text(&ui.tree, node_get(&ui.tree, n), st)
	testing.expect_value(t, st.text, "$ ls\na  b\n")
	testing.expect_value(t, st.caret, len("$ ls\na "))

	set_focus(&ui.tree, n, true)
	info := ime_info(&ui.tree)
	testing.expect(t, info.on, "an input method may compose")
	testing.expect_value(t, info.purpose, Ime_Purpose.Terminal)
	d := node_get(&ui.tree, n)
	testing.expect(t, info.caret.x > d.abs.x && info.caret.y > d.abs.y, "at the cursor's cell")

	clear(&ui.msgs)
	ime_apply(&ui, {preedit = "ni", cursor_begin = 2, cursor_end = 2})
	tm_view(&ui, &s)
	testing.expect_value(t, ui.tree.terminals[n].preedit, "ni")
	ime_apply(&ui, {commit = "你"})
	testing.expect_value(t, len(ui.msgs), 1)
	if len(ui.msgs) == 1 do testing.expect_value(t, ui.msgs[0].(string), "你")
}

// Drawing keeps each row: drawn again, only a row the app touched is made
// again, and only it is damage.
@(test)
only_the_rows_that_changed_are_drawn_again :: proc(t: ^testing.T) {
	ui: Ui(Tty_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text engine")
	defer text_engine_destroy(&te)
	ui.tree.text = &te
	s := tm_screen(20, 5)
	defer term_screen_destroy(&s)
	for r in 0 ..< 5 do tm_write(&s, r, "hello ─┼═ ⣿█")
	n, _ := tm_view(&ui, &s)

	out := make([dynamic]gpu.Cmd, context.temp_allocator)
	render_prepare(&ui.tree, 1, nil, &out)
	testing.expect_value(t, ui.tree.stats.term_rows, 5)
	glyphs := 0
	for c in out do if _, g := c.(gpu.Glyph); g do glyphs += 1
	testing.expect(t, glyphs >= 5 * 11, "every character drawn")

	clear(&out)
	render_prepare(&ui.tree, 1, nil, &out)
	testing.expect_value(t, ui.tree.stats.term_rows, 5) // kept

	take_damage(&ui.tree)
	tm_write(&s, 3, "world")
	tm_view(&ui, &s)
	damage := take_damage(&ui.tree)
	d := node_get(&ui.tree, n)
	m := cell_metrics(&ui, size = 14)
	testing.expect_value(t, len(damage), 1)
	if len(damage) == 1 do testing.expect_value(t, damage[0], Rect{d.abs.x, d.abs.y + 3 * m.line_height, d.abs.w, m.line_height})
	clear(&out)
	render_prepare(&ui.tree, 1, nil, &out)
	testing.expect_value(t, ui.tree.stats.term_rows, 6) // just the one
}

// Box drawing, blocks and braille fill their cell: lines run edge to edge
// and join, doubles meet as a pipe's outline, a full block is the cell.
@(test)
shapes_fill_their_cell :: proc(t: ^testing.T) {
	W, H :: 10, 20
	draw :: proc(r: rune) -> Shape_Canvas {
		c := Shape_Canvas{w = W, h = H, px = make([]u8, W * H, context.temp_allocator)}
		switch cell_shape_of(r) {
		case .Box:       shape_box(&c, r)
		case .Block:     shape_block(&c, r)
		case .Braille:   shape_braille(&c, r)
		case .Powerline: shape_powerline(&c, r)
		case .Wave:      shape_wave(&c)
		case .None:
		}
		return c
	}
	at :: proc(c: Shape_Canvas, x, y: int) -> u8 { return c.px[y * c.w + x] }
	row_full :: proc(c: Shape_Canvas, y: int) -> bool {
		for x in 0 ..< c.w do if c.px[y * c.w + x] != 255 do return false
		return true
	}
	col_full :: proc(c: Shape_Canvas, x: int) -> bool {
		for y in 0 ..< c.h do if c.px[y * c.w + x] != 255 do return false
		return true
	}
	h := draw('─')
	testing.expect(t, row_full(h, (H - 1) / 2), "─ runs edge to edge")
	testing.expect_value(t, at(h, 0, 0), 0)
	v := draw('│')
	testing.expect(t, col_full(v, (W - 1) / 2), "│ runs top to bottom")
	x := draw('┼')
	testing.expect(t, row_full(x, (H - 1) / 2) && col_full(x, (W - 1) / 2), "┼ crosses whole")
	corner := draw('┌')
	testing.expect_value(t, at(corner, W - 1, (H - 1) / 2), 255)
	testing.expect_value(t, at(corner, (W - 1) / 2, H - 1), 255)
	testing.expect_value(t, at(corner, 0, (H - 1) / 2), 0) // nothing to its left
	testing.expect_value(t, at(corner, (W - 1) / 2, 0), 0) // …or above

	dbl := draw('═')
	lines := 0
	for y in 0 ..< H do if row_full(dbl, y) do lines += 1
	testing.expect_value(t, lines, 2) // two light lines, a gap between
	// ╔: the outer line turns the corner with no stub past it, the inner one too
	tl := draw('╔')
	top, left := -1, -1
	for y in 0 ..< H do if at(tl, W - 1, y) == 255 { top = y; break }
	for x2 in 0 ..< W do if at(tl, x2, H - 1) == 255 { left = x2; break }
	testing.expect(t, top >= 0 && left >= 0, "both lines reach their edges")
	if top >= 0 && left >= 0 {
		testing.expect_value(t, at(tl, left, top), 255)       // the outer corner
		testing.expect_value(t, at(tl, left - 1, top), 0)     // no stub left of it
		testing.expect_value(t, at(tl, left, top - 1), 0)     // …or above
		for x2 in left ..< W do testing.expect_value(t, at(tl, x2, top), 255)
		testing.expect_value(t, at(tl, left + 1, top + 1), 0) // the pipe's middle is open
	}
	// ╪: the single line crosses both doubles
	cross := draw('╪')
	testing.expect(t, col_full(cross, (W - 1) / 2), "╪'s vertical runs through")

	full := draw('█')
	for p in full.px do testing.expect_value(t, p, 255)
	half := draw('▀')
	testing.expect(t, row_full(half, 0) && !row_full(half, H - 1), "▀ is the top half")
	shade := draw('▒')
	testing.expect_value(t, shade.px[0], 128)

	dots := draw('⣿')
	on := 0
	for p in dots.px do if p == 255 do on += 1
	testing.expect(t, on >= 8, "eight dots")
	one := draw('⠁') // dot 1 alone: top left
	for y in 0 ..< H do for x2 in 0 ..< W do if at(one, x2, y) != 0 {
		testing.expect(t, x2 < W / 2 && y < H / 4, "dot 1 is in the top left quarter")
	}
}

// A press is the first, second or third of a run: the same button, soon
// after the last and near it.
@(test)
a_press_counts_its_clicks :: proc(t: ^testing.T) {
	c: Click_Count
	testing.expect_value(t, click_count(&c, .Left, 1000, {10, 10}), 1)
	testing.expect_value(t, click_count(&c, .Left, 1200, {11, 10}), 2)
	testing.expect_value(t, click_count(&c, .Left, 1400, {11, 11}), 3) // a line, in a terminal
	testing.expect_value(t, click_count(&c, .Left, 2400, {11, 11}), 1) // too late: a new run
	testing.expect_value(t, click_count(&c, .Left, 2500, {40, 11}), 1) // too far
	testing.expect_value(t, click_count(&c, .Right, 2600, {40, 11}), 1) // another button

	ui: Ui(Tty_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	copy := copy_text(Tty_Msg, "sel", primary = true)
	testing.expect(t, copy.primary && copy.kind == .Copy_Text, "a copy to the primary selection")
	p := paste(Tty_Msg, tm_text_pasted, primary = true)
	testing.expect(t, p.primary && p.kind == .Paste, "a paste from it")
}

@(private = "file")
tm_text_pasted :: proc(e: Ev(Pasted)) -> Tty_Msg { return strings.clone(e.value.text, context.temp_allocator) }

// A block cursor over a character draws the character again in the cell's
// background, inside the block; without the keyboard it is a hollow box.
@(test)
a_block_cursor_shows_its_character_inverted :: proc(t: ^testing.T) {
	ui: Ui(Tty_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text engine")
	defer text_engine_destroy(&te)
	ui.tree.text = &te
	s := tm_screen(10, 2)
	defer term_screen_destroy(&s)
	tm_write(&s, 0, "x")
	s.cursor = {col = 0, row = 0, shape = .Block}
	ui.surface.keyboard = true
	n, _ := tm_view(&ui, &s)
	set_focus(&ui.tree, n, false)

	out := make([dynamic]gpu.Cmd, context.temp_allocator)
	render_prepare(&ui.tree, 1, nil, &out)
	inverted, block := false, false
	for c in out {
		if g, ok := c.(gpu.Glyph); ok && g.color == s.background do inverted = true
		if q, ok := c.(gpu.Quad); ok && q.color == s.foreground && q.rect[2] > 3 && q.rect[3] > 10 do block = true
	}
	testing.expect(t, block, "a block in the cursor's colour")
	testing.expect(t, inverted, "the character over it in the background's")

	ui.surface.keyboard = false // another window has the keyboard
	tm_view(&ui, &s)
	clear(&out)
	render_prepare(&ui.tree, 1, nil, &out)
	inverted, block = false, false
	for c in out {
		if g, ok := c.(gpu.Glyph); ok && g.color == s.background do inverted = true
		if q, ok := c.(gpu.Quad); ok && q.color == s.foreground && q.rect[2] > 3 && q.rect[3] > 10 do block = true
	}
	testing.expect(t, !block && !inverted, "hollow: its edges only")
}

// A margin in the screen's background: the grid starts inside it, the cells
// counted fit inside it, and the cursor's cell moves with it.
@(test)
a_terminal_margin_holds_no_cells :: proc(t: ^testing.T) {
	ui: Ui(Tty_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	s := tm_screen(10, 4)
	defer term_screen_destroy(&s)
	build :: proc(ui: ^Ui(Tty_Msg), s: ^Term_Screen, padding: f32) -> Node {
		begin_view(ui)
		column(ui)
		n := terminal(ui, s, on_resize = tm_size, size = 14, padding = padding, label = "shell")
		end(ui)
		end_view(ui)
		frame(&ui.tree, {500, 300})
		return n
	}
	build(&ui, &s, 0)
	clear(&ui.msgs)
	terminal_tick(&ui)
	bare := ui.msgs[0].(Term_Size)
	n := build(&ui, &s, 20)
	clear(&ui.msgs)
	terminal_tick(&ui)
	testing.expect_value(t, len(ui.msgs), 1)
	padded := ui.msgs[0].(Term_Size)
	m := padded.cell
	testing.expect_value(t, padded.cols, int((500 - 40) / m.advance))
	testing.expect_value(t, padded.rows, int((300 - 40) / m.line_height))
	testing.expect(t, padded.cols < bare.cols, "fewer columns")

	set_focus(&ui.tree, n, true)
	info := ime_info(&ui.tree)
	testing.expect_value(t, info.caret.x, f32(20)) // the cursor's cell, inside the margin
	testing.expect_value(t, info.caret.y, f32(20))
	d := node_get(&ui.tree, n)
	testing.expect_value(t, d.style.bg, s.background) // the margin in the screen's background, one fill with the grid
}

} // when ODIN_TEST