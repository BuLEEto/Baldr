// editor_large — what a wrapped editor costs as a document grows.
//
// Each run: build the view and `frame` at 1200x800 (a file opening), then
// at 1000x800 (a window resized), then put one letter in and frame again
// (a key pressed), for documents from 50 KB to a 4.6 MB log. Run it with
// BALDR_FAST=1 — a -debug build reads about ten times slow.
package main

import "core:fmt"
import "core:strings"
import "core:time"
import "baldr:baldr"

Msg :: union { int }

// A log-ish document: lines of uneven length, none shorter than a stamp,
// the longest about 630 characters, as a real log's are.
make_text :: proc(bytes: int) -> string {
	b := strings.builder_make()
	words := []string{"opening", "surface", "wayland", "frame", "renderer", "atlas", "upload", "glyph", "cache", "miss",
		"commit", "damage", "scanout", "buffer", "release", "pointer", "keyboard", "focus", "output", "scale"}
	line, w := 0, 0
	for strings.builder_len(b) < bytes {
		fmt.sbprintf(&b, "2026-10-17 11:%02d:%02d.%03d  thread-%d  ", (line / 60) %% 60, line %% 60, (line * 37) %% 1000, line %% 8)
		n := 4 + (line * 13) %% 90        // most lines short…
		if line %% 97 == 0 do n = 90 + (line * 7) %% 10 // …one in a hundred long
		for _ in 0 ..< n {
			strings.write_string(&b, words[w %% len(words)])
			strings.write_byte(&b, ' ')
			w += 1
		}
		strings.write_byte(&b, '\n')
		line += 1
	}
	return strings.to_string(b)
}

Mode :: enum { Area_Wrapped, Area_Unwrapped, Markdown, Code, Code_Plain, Code_No_Numbers, Area_Marked, Markdown_Plain }

MODE_NAME := [Mode]string{.Area_Wrapped = "text_area (wrapped)", .Area_Unwrapped = "text_area, wrap = false",
	.Markdown = "markdown_editor", .Code = "code_editor (not wrapped)",
	.Code_Plain = "code_editor, no language", .Code_No_Numbers = "code_editor, no gutter",
	.Area_Marked = "text_area + a mark a word", .Markdown_Plain = "markdown_editor, no pictures"}

build :: proc(ui: ^baldr.Ui(Msg), doc: ^baldr.Document, mode: Mode, size: [2]f32) {
	baldr.begin_view(ui)
	baldr.column(ui, flex = 1)
	n: baldr.Node
	switch mode {
	case .Area_Wrapped:   n = baldr.text_area(ui, doc, flex = 1)
	case .Area_Unwrapped: n = baldr.text_area(ui, doc, flex = 1); baldr.editor_options(ui, n, wrap = false)
	case .Markdown:       n = baldr.markdown_editor(ui, doc, flex = 1)
	case .Code:           n = baldr.code_editor(ui, doc, &baldr.LANG_ODIN, flex = 1)
	case .Code_Plain:     n = baldr.code_editor(ui, doc, nil, flex = 1)
	case .Markdown_Plain: n = baldr.markdown_editor(ui, doc, flex = 1)
	case .Area_Marked:
		n = baldr.text_area(ui, doc, flex = 1)
		baldr.editor_marks(ui, n, spell_marks(doc))
	case .Code_No_Numbers:
		n = baldr.code_editor(ui, doc, &baldr.LANG_ODIN, flex = 1)
		baldr.editor_options(ui, n, line_numbers = false)
	}
	baldr.end(ui)
	baldr.end_view(ui)
	baldr.frame(&ui.tree, size)
}

ms :: proc(start: time.Tick) -> f64 { return time.duration_milliseconds(time.tick_since(start)) }

// What a spell checker hands an editor: one mark a word, every build —
// about 98,000 of them on a 4.6 MB log.
marks_buf: [dynamic]baldr.Mark
spell_marks :: proc(doc: ^baldr.Document) -> []baldr.Mark {
	if len(marks_buf) > 0 do return marks_buf[:]
	for b in 0 ..< baldr.block_count(doc) {
		str := baldr.block_str(doc, b)
		at := 0
		for at < len(str) {
			for at < len(str) && str[at] == ' ' do at += 1
			end := at
			for end < len(str) && str[end] != ' ' do end += 1
			if end > at do append(&marks_buf, baldr.Mark{from = {b, at}, to = {b, end}, kind = .Warning, message = "spelling"})
			at = end
		}
	}
	return marks_buf[:]
}

run :: proc(te: ^baldr.Text_Engine, label: string, text: string, mode: Mode) {
	ui: baldr.Ui(Msg)
	baldr.ui_init(&ui)
	defer baldr.ui_destroy(&ui)
	baldr.tree_use_text_engine(&ui.tree, te)
	doc := baldr.document_make(text)
	defer baldr.document_destroy(&doc)

	t0 := time.tick_now()
	build(&ui, &doc, mode, {1200, 800})
	open := ms(t0)

	t1 := time.tick_now()
	build(&ui, &doc, mode, {1000, 800})
	narrower := ms(t1)

	baldr.document_replace(&doc, {0, 0}, {0, 0}, "x", group = 1)
	t2 := time.tick_now()
	build(&ui, &doc, mode, {1000, 800})
	typed := ms(t2)

	fmt.printf("| %-10s | %-25s | %9.1f | %9.1f | %9.1f |\n", label, MODE_NAME[mode], open, narrower, typed)
}

main :: proc() {
	te: baldr.Text_Engine
	if !baldr.text_engine_init(&te) { fmt.println("fonts failed to load"); return }
	defer baldr.text_engine_destroy(&te)

	sizes := []struct{ label: string, bytes: int }{
		{"50 KB", 50 * 1024}, {"200 KB", 200 * 1024}, {"1 MB", 1024 * 1024}, {"4.6 MB", 4_600_000},
	}
	fmt.println("| document   | mode                      |      open | narrower |  one key |")
	fmt.println("|------------|---------------------------|-----------|----------|----------|")
	for sz in sizes {
		text := make_text(sz.bytes)
		defer delete(text)
		lines := strings.count(text, "\n")
		run(&te, sz.label, text, .Area_Wrapped)
		run(&te, sz.label, text, .Markdown)
		if sz.bytes > 1_000_000 {
			clear(&marks_buf)
			run(&te, sz.label, text, .Area_Marked)
			fmt.printfln("   (%s: %d marks)", sz.label, len(marks_buf))
			run(&te, sz.label, text, .Code)
			run(&te, sz.label, text, .Code_Plain)
			run(&te, sz.label, text, .Code_No_Numbers)
			run(&te, sz.label, text, .Area_Unwrapped)
		}
		fmt.printf("   (%s: %d lines)\n", sz.label, lines)
	}
}
