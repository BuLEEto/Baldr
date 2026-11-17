// editor_big_window — a very large file in a real window, to look at.
//
// The height map decides where unseen blocks are by
// estimating them, so the things that can go wrong are things only a
// person (or a capture) sees: text that jumps while scrolling, a scroll
// bar that lurches, a caret that lands away from the pointer, a view that
// changes place when the window is resized. The numbers are in
// `spikes/editor_large`; this is the one to *watch*.
//
//	./build.sh spike editor_big_window run            # 4.6 MB of log
//	BIG_LINES=200000 build/editor_big_window          # bigger
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "baldr:baldr"

State :: struct {
	doc:  baldr.Document,
	note: string,
}

Msg :: union {
	Typed,
	Wrap,
}

Typed :: struct { at: int }
Wrap  :: struct {}

wrap_on := true

init :: proc() -> (s: State) {
	lines := 31_160 // about 4.6 MB
	if v := os.get_env("BIG_LINES", context.temp_allocator); len(v) > 0 {
		if n, ok := strconv.parse_int(v); ok do lines = max(n, 1)
	}
	b := strings.builder_make()
	words := []string{"opening", "surface", "wayland", "frame", "renderer", "atlas", "upload", "glyph",
		"cache", "miss", "commit", "damage", "scanout", "buffer", "release", "pointer", "keyboard"}
	w := 0
	for i in 0 ..< lines {
		fmt.sbprintf(&b, "2026-10-17 %02d:%02d:%02d.%03d  thread-%d  ", (i / 3600) % 24, (i / 60) % 60, i % 60, (i * 37) % 1000, i % 8)
		n := 3 + (i * 13) % 26
		if i % 97 == 0 do n = 60 + (i * 7) % 40 // one line in a hundred is long
		for _ in 0 ..< n {
			strings.write_string(&b, words[w % len(words)])
			strings.write_byte(&b, ' ')
			w += 1
		}
		strings.write_byte(&b, '\n')
	}
	text := strings.to_string(b)
	s.doc = baldr.document_make(text)
	s.note = fmt.aprintf("%d lines, %.1f MB", baldr.block_count(&s.doc), f32(len(text)) / (1024 * 1024))
	delete(text)
	return
}

update :: proc(s: ^State, msg: Msg) -> baldr.Cmd(Msg) {
	switch _ in msg {
	case Typed:
	case Wrap: wrap_on = !wrap_on
	}
	return {}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, flex = 1, padding = .md, gap = .sm); defer baldr.end(ui)
	{
		baldr.row(ui, gap = .md, align = .Center); defer baldr.end(ui)
		baldr.text(ui, s.note, role = .Title)
		baldr.spacer(ui)
		baldr.button(ui, "Wrap: on" if wrap_on else "Wrap: off", Msg(Wrap{}), variant = .Outline)
	}
	ed := baldr.text_area(ui, &s.doc, flex = 1, label = "The log",
		on_change = proc(e: baldr.Ev(int)) -> Msg { return Typed{e.value} })
	baldr.editor_options(ui, ed, wrap = wrap_on)
}

main :: proc() {
	err := baldr.run(baldr.App(State, Msg){
		title = "A very large file", app_id = "dev.baldr.bigfile", size = {1100, 720},
		init = init, update = update, view = view,
	})
	if err != .None do fmt.eprintln("exit:", err)
}
