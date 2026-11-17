package main

// A terminal's screen, without a pty. The screen shows what a
// terminal draws — colours, the text styles, underlines, box drawing,
// blocks, braille, emoji, CJK, a combining mark, powerline — and a prompt
// that takes what is typed. Every key, text, size, click and paste is
// logged. Triple-click a row: it becomes the primary selection; a middle
// click types it at the prompt. Ctrl+Shift+C is the app's own shortcut.

import "core:fmt"
import "core:strings"
import "baldr:baldr"

FG :: 0xCDD6F4
BG :: 0x1E1E2E

State :: struct {
	screen: baldr.Term_Screen,
	typed:  [dynamic]u8,
	shape:  baldr.Term_Cursor_Shape,
	cell:   baldr.Cell_Metrics,
}

Copy :: struct {}
Msg :: union { baldr.Term_Key, string, baldr.Term_Size, baldr.Pointer_Samples, baldr.Pasted, Copy }

PALETTE := [8]u32{0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE}

// put writes `text` from (col, row), each character a cell, wide ones two.
put :: proc(s: ^baldr.Term_Screen, col, row: int, text: string, fg: u32 = FG, bg: u32 = 0, style: baldr.Term_Styles = {}, under := baldr.Term_Underline.None, ul: u32 = 0) -> int {
	cells := baldr.term_row(s, row)
	c := col
	for g in graphemes(text) {
		if c >= len(cells) do break
		wide := is_wide(g)
		cell := &cells[c]
		baldr.term_cell_set(cell, g)
		cell.fg = baldr.rgb(fg)
		cell.bg = baldr.rgb(bg) if bg != 0 else {}
		cell.style, cell.underline = style, under
		cell.underline_color = baldr.rgb(ul) if ul != 0 else {}
		cell.width = 2 if wide else 1
		if wide && c + 1 < len(cells) {
			cells[c + 1] = {fg = cell.fg, bg = cell.bg, width = 1}
			c += 1
		}
		c += 1
	}
	baldr.term_touch(s, row)
	return c
}

// graphemes splits well enough for the demo: a character with the marks
// and joiners after it.
graphemes :: proc(s: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	start := -1
	prev_zwj := false
	for r, i in s {
		joins := r == 0x200D || (r >= 0x300 && r <= 0x36F) || (r >= 0xFE00 && r <= 0xFE0F) || (r >= 0x1F3FB && r <= 0x1F3FF)
		if start >= 0 && !joins && !prev_zwj {
			append(&out, s[start:i])
			start = i
		}
		if start < 0 do start = i
		prev_zwj = r == 0x200D
	}
	if start >= 0 do append(&out, s[start:])
	return out[:]
}

is_wide :: proc(g: string) -> bool {
	for r in g {
		switch r {
		case 0x1100 ..= 0x115F, 0x2E80 ..= 0xA4CF, 0xAC00 ..= 0xD7A3, 0xF900 ..= 0xFAFF, 0xFF00 ..= 0xFF60, 0x1F300 ..= 0x1FAFF: return true
		}
		return false
	}
	return false
}

fill :: proc(s: ^State) {
	scr := &s.screen
	for &c in scr.cells do c = {fg = scr.foreground, width = 1}
	c := put(scr, 0, 0, "Colours ")
	for p, i in PALETTE do c = put(scr, c, 0, fmt.tprintf(" %d ", i), fg = BG, bg = p)
	c = put(scr, c + 1, 0, "fg:")
	for p in PALETTE do c = put(scr, c, 0, "■", fg = p)
	c = put(scr, 0, 1, "Styles  ")
	c = put(scr, c, 1, "bold", style = {.Bold}) + 1
	c = put(scr, c, 1, "italic", style = {.Italic}) + 1
	c = put(scr, c, 1, "dim", style = {.Dim}) + 1
	c = put(scr, c, 1, "strike", style = {.Strike}) + 1
	c = put(scr, c, 1, "single", under = .Single) + 1
	c = put(scr, c, 1, "double", under = .Double) + 1
	c = put(scr, c, 1, "curly", under = .Curly, ul = 0xF38BA8) + 1
	c = put(scr, c, 1, "dotted", under = .Dotted) + 1
	put(scr, c, 1, "dashed", under = .Dashed)
	put(scr, 0, 2, "Boxes   ┌──┬──┐ ╔══╦══╗ ╭────╮ ┏━━┓ ▀▄█▌▐ ░▒▓ ╱╲╳")
	put(scr, 0, 3, "        │  │  │ ║  ║  ║ │ ok │ ┃  ┃ ▁▂▃▄▅▆▇█ ┄┈╌")
	put(scr, 0, 4, "        ├──┼──┤ ╠══╬══╣ ╰────╯ ┗━━┛ ╒═╤═╕ ╓─╥─╖")
	put(scr, 0, 5, "        └──┴──┘ ╚══╩══╝ ▖▗▘▙▚▛▜▝▞▟ ╘═╧═╛ ╙─╨─╜")
	put(scr, 0, 6, "Braille ⣀⣀⣤⣤⣶⣶⣿⣿⣿⣶⣤⣀⡀⢀⣠⣴⣾⣿⣿⣷⣦⣄⡀ ⠁⠂⠄⡀⠈⠐⠠⢀ ⣿", fg = 0xA6E3A1)
	put(scr, 0, 7, "Wide    😀 👍🏽 ❤️ 漢字かなカナ 한국어 é ä")
	c = put(scr, 0, 8, "Line    ")
	c = put(scr, c, 8, " user ", fg = BG, bg = 0x89B4FA)
	c = put(scr, c, 8, "", fg = 0x89B4FA, bg = 0xA6E3A1)
	c = put(scr, c, 8, " ~/odin ", fg = BG, bg = 0xA6E3A1)
	c = put(scr, c, 8, "", fg = 0xA6E3A1)
	put(scr, c + 1, 8, " ->  != =>  www", fg = 0xF9E2AF)
	prompt(s)
}

prompt :: proc(s: ^State) {
	scr := &s.screen
	row := min(10, max(scr.rows - 1, 0))
	cells := baldr.term_row(scr, row)
	for &c in cells do c = {fg = scr.foreground, width = 1}
	c := put(scr, 0, row, "$ ", fg = 0xA6E3A1, style = {.Bold})
	c = put(scr, c, row, string(s.typed[:]))
	scr.cursor = {col = min(c, max(scr.cols - 1, 0)), row = row, shape = s.shape, blink = true}
}

row_text :: proc(scr: ^baldr.Term_Screen, row: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in baldr.term_row(scr, row) {
		if c.text[0] == 0 {
			strings.write_byte(&b, ' ')
			continue
		}
		for r in c.text do if r != 0 do strings.write_rune(&b, r)
	}
	return strings.trim_right(strings.to_string(b), " ")
}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	scr := &s.screen
	switch v in m {
	case baldr.Term_Size:
		fmt.eprintfln("term: size %d x %d, cell %v, %v px", v.cols, v.rows, v.cell, v.px)
		s.cell = v.cell
		baldr.term_screen_resize(scr, v.cols, v.rows)
		fill(s)
	case baldr.Term_Key:
		fmt.eprintfln("term: key %v keysym 0x%x char %q mods %v repeat %v text %q", v.key, v.keysym, v.char, v.mods, v.repeat, v.text)
		switch {
		case len(v.text) > 0:          append(&s.typed, v.text)
		case v.key == .Backspace:      if len(s.typed) > 0 do resize(&s.typed, len(s.typed) - 1)
		case v.key == .Enter:          clear(&s.typed)
		case v.key == .Tab:            s.shape = baldr.Term_Cursor_Shape((int(s.shape) + 1) % 3) // Tab: the next cursor shape
		}
		prompt(s)
	case string:
		fmt.eprintfln("term: text %q", v)
		append(&s.typed, v)
		prompt(s)
	case baldr.Pointer_Samples:
		for p in v.samples {
			if p.kind != .Press do continue
			fmt.eprintfln("term: press %v, click %d at %v", p.button, p.clicks, p.pos)
			if p.button == .Left && p.clicks == 3 && s.cell.line_height > 0 { // a line: the primary selection
				line := row_text(scr, int((p.pos.y - 6) / s.cell.line_height)) // from the node: less the margin
				fmt.eprintfln("term: selected %q", line)
				return baldr.copy_text(Msg, line, primary = true)
			}
			if p.button == .Middle do return baldr.paste(Msg, proc(e: baldr.Ev(baldr.Pasted)) -> Msg { p := e.value; p.text = strings.clone(p.text); return p }, primary = true)
		}
	case baldr.Pasted:
		fmt.eprintfln("term: pasted %q", v.text)
		append(&s.typed, v.text)
		prompt(s)
	case Copy:
		fmt.eprintln("term: the app's own Ctrl+Shift+C")
	}
	return {}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.shortcut(ui, "Ctrl+Shift+C", Msg(Copy{}))
	baldr.column(ui, flex = 1); defer baldr.end(ui)
	n := baldr.terminal(ui, &s.screen, on_key = proc(e: baldr.Ev(baldr.Term_Key)) -> Msg { k := e.value; k.text = strings.clone(k.text); return k },
		on_text = proc(e: baldr.Ev(string)) -> Msg { return strings.clone(e.value) },
		on_resize = proc(e: baldr.Ev(baldr.Term_Size)) -> Msg { return e.value }, family = "JetBrains Mono", size = 15, padding = 6, label = "Terminal")
	baldr.pointer_samples(ui, n, proc(e: baldr.Ev(baldr.Pointer_Samples)) -> Msg { return e.value })
	baldr.pointer_area(ui, n, cursor = .Text)
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Terminal", app_id = "dev.baldr.terminal", size = {900, 330},
		init = proc() -> (s: State) {
			s.screen.foreground = baldr.rgb(FG)
			s.screen.background = baldr.rgb(BG)
			return
		},
		update = update,
		view = view,
	})
}
