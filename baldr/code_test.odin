package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

Cd_Msg :: struct { version: int }

@(private = "file")
on_edit :: proc(e: Ev(int)) -> Cd_Msg { return {version = e.value} }

@(private = "file")
Cd_Fx :: struct {
	ui:  Ui(Cd_Msg),
	doc: Document,
}

@(private = "file")
cd_view :: proc(fx: ^Cd_Fx, wrap := false, whitespace := false, spaces := false, lang: ^Language = nil, complete: Completer = nil) -> (fr, area: Node) {
	ui := &fx.ui
	set_viewport(&ui.tree, {600, 400})
	begin_view(ui)
	column(ui, padding = .lg)
	fr = code_editor(ui, &fx.doc, lang if lang != nil else &LANG_ODIN, on_edit, label = "Source", height = 240)
	editor_options(ui, fr, wrap = wrap, whitespace = whitespace, spaces = spaces)
	if complete != nil do editor_complete(ui, fr, complete)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	area = ui.tree.area_of_frame[fr]
	return
}

@(private = "file")
cd_text :: proc(fx: ^Cd_Fx) -> string { return document_text(&fx.doc, context.temp_allocator) }

@(private = "file")
draw_texts :: proc(ui: ^Ui(Cd_Msg)) -> (n: int) {
	for _, l in ui.tree.layers do for c in l.cmds do if _, ok := c.(Draw_Text); ok do n += 1
	return
}

// The editor is a Text_Input with the line and column described, paints a
// line-number gutter and coloured tokens, and only the lines in view: a
// long file costs a screen of draw calls, not a file of them.
@(test)
code_editor_paints_gutter_tokens_and_only_the_view :: proc(t: ^testing.T) {
	fx: Cd_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	b := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< 10_000 do strings.write_string(&b, "x := 1 // line\n")
	fx.doc = document_make(strings.to_string(b))
	defer document_destroy(&fx.doc)
	_, area := cd_view(&fx)
	d := node_get(&fx.ui.tree, area)
	testing.expect_value(t, d.access.role, Role.Text_Input)
	testing.expect_value(t, d.access.name, "Source")
	testing.expect(t, fx.ui.tree.areas[area].code.on && fx.ui.tree.areas[area].mono)
	set_focus(&fx.ui.tree, area, true)
	key_event(&fx.ui, .Right, true, {})
	testing.expect_value(t, d.access.describe, "Line 1, column 2")
	fx.ui.needs_rebuild = false
	cd_view(&fx)
	n := draw_texts(&fx.ui)
	testing.expect(t, n > 20 && n < 400, "a screen of tokens and line numbers, not ten thousand lines")
	// a line number is drawn right-aligned in the gutter; the tokens carry the theme's colours
	th := fx.ui.tree.theme
	saw_num, saw_kw_col := false, false
	for _, l in fx.ui.tree.layers do for c in l.cmds {
		if dt, ok := c.(Draw_Text); ok {
			if dt.str == "1" && dt.align == .End do saw_num = true
			if dt.str == "1" && dt.color == th.color.code.number do saw_kw_col = true
		}
	}
	testing.expect(t, saw_num, "line number 1 in the gutter")
	testing.expect(t, saw_kw_col, "the number token in the number colour")
	testing.expect(t, fx.ui.tree.areas[area].code.gutter_w > 0)
	// Page Down from the top reaches a later line and the view follows
	key_event(&fx.ui, .Page_Down, true, {})
	testing.expect(t, fx.ui.tree.areas[area].caret.block > 5)
	testing.expect(t, fx.ui.tree.scrolls[area].offset.y >= 0)
	testing.expect_value(t, lint(&fx.ui.tree), 0)
}

// Indentation keys: Tab inserts one indent (a tab, or spaces), Tab over a
// multi-line selection indents every line and Shift+Tab outdents, Enter
// keeps the indentation and opens a bracket pair onto its own line, Home
// goes to the first non-blank column first, Backspace in spaces mode
// steps back a tab stop, Ctrl+/ toggles comments, Alt+Down moves a line.
@(test)
code_editor_indents_comments_and_moves_lines :: proc(t: ^testing.T) {
	fx: Cd_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	fx.doc = document_make("main :: proc() {}\nb\nc")
	defer document_destroy(&fx.doc)
	_, area := cd_view(&fx)
	s := &fx.ui.tree.areas[area]
	set_focus(&fx.ui.tree, area, true)
	// Enter between {} opens the pair with the caret indented inside
	area_move(&fx.ui.tree, area, s, {0, 16}, false)
	key_event(&fx.ui, .Enter, true, {})
	testing.expect_value(t, cd_text(&fx), "main :: proc() {\n\t\n}\nb\nc")
	testing.expect_value(t, s.caret, Pos{1, 1})
	text_area_text(&fx.ui, "x")
	key_event(&fx.ui, .Enter, true, {}) // keeps the tab
	testing.expect_value(t, block_str(&fx.doc, 2), "\t")
	// Tab inserts an indent; Home toggles between the text and the margin
	key_event(&fx.ui, .Tab, true, {})
	testing.expect_value(t, block_str(&fx.doc, 2), "\t\t")
	text_area_text(&fx.ui, "y")
	key_event(&fx.ui, .Home, true, {})
	testing.expect_value(t, s.caret, Pos{2, 2})
	key_event(&fx.ui, .Home, true, {})
	testing.expect_value(t, s.caret, Pos{2, 0})
	key_event(&fx.ui, .Home, true, {})
	testing.expect_value(t, s.caret, Pos{2, 2})
	// select lines 1..2 (x and y): Tab indents both, Shift+Tab outdents both
	s.anchor, s.caret = {1, 0}, {3, 0}
	key_event(&fx.ui, .Tab, true, {})
	testing.expect_value(t, block_str(&fx.doc, 1), "\t\tx")
	testing.expect_value(t, block_str(&fx.doc, 2), "\t\t\ty")
	testing.expect(t, s.anchor == Pos{1, 0} && s.caret == Pos{3, 0}, "whole lines stay selected")
	key_event(&fx.ui, .Tab, true, {.Shift})
	key_event(&fx.ui, .Tab, true, {.Shift})
	testing.expect_value(t, block_str(&fx.doc, 1), "x")
	testing.expect_value(t, block_str(&fx.doc, 2), "\ty")
	// Ctrl+/ comments both, again uncomments
	key_event(&fx.ui, .Slash, true, {.Ctrl})
	testing.expect_value(t, block_str(&fx.doc, 1), "// x")
	testing.expect_value(t, block_str(&fx.doc, 2), "\t// y")
	key_event(&fx.ui, .Slash, true, {.Ctrl})
	testing.expect_value(t, block_str(&fx.doc, 1), "x")
	testing.expect_value(t, block_str(&fx.doc, 2), "\ty")
	// Alt+Down moves the caret's line under the next one; Ctrl+Z undoes it in one go
	s.anchor, s.caret = {1, 0}, {1, 0}
	key_event(&fx.ui, .Down, true, {.Alt})
	testing.expect_value(t, block_str(&fx.doc, 1), "\ty")
	testing.expect_value(t, block_str(&fx.doc, 2), "x")
	testing.expect_value(t, s.caret, Pos{2, 0})
	key_event(&fx.ui, .Z, true, {.Ctrl})
	testing.expect_value(t, block_str(&fx.doc, 1), "x")
	// Ctrl+Tab is not taken: focus can leave
	testing.expect(t, !text_area_key(&fx.ui, .Tab, {.Ctrl}))
	// spaces mode: Tab writes four spaces, Backspace inside them steps a stop back
	fx.ui.needs_rebuild = false
	_, area2 := cd_view(&fx, spaces = true)
	testing.expect_value(t, area2, area)
	s.anchor, s.caret = {2, 0}, {2, 0}
	key_event(&fx.ui, .Tab, true, {})
	testing.expect_value(t, block_str(&fx.doc, 2), "    \ty")
	text_area_text(&fx.ui, " ")
	testing.expect_value(t, s.caret.off, 5)
	key_event(&fx.ui, .Backspace, true, {})
	testing.expect_value(t, s.caret.off, 4)
	key_event(&fx.ui, .Backspace, true, {})
	testing.expect_value(t, block_str(&fx.doc, 2), "\ty")
	testing.expect(t, len(fx.ui.msgs) > 0 && fx.ui.msgs[len(fx.ui.msgs) - 1].version == int(fx.doc.version), "on_change carries the version")
}

// Find: Ctrl+F opens a bar with a named field and buttons, the query's
// matches become highlights and the first at or after the caret is
// selected, Enter and the buttons step around, Escape closes the bar and
// returns focus; Ctrl+G goes to a line. A click on a line number selects
// the line, and matched brackets are boxed.
@(test)
code_editor_finds_goes_to_and_matches_brackets :: proc(t: ^testing.T) {
	fx: Cd_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	fx.doc = document_make("foo(a)\nbar\nFoo(b)\nfoo\n")
	defer document_destroy(&fx.doc)
	_, area := cd_view(&fx)
	s := &fx.ui.tree.areas[area]
	set_focus(&fx.ui.tree, area, true)
	area_move(&fx.ui.tree, area, s, {1, 0}, false)
	testing.expect(t, key_event(&fx.ui, .F, true, {.Ctrl}), "Ctrl+F opens find")
	testing.expect_value(t, s.code.bar, Code_Bar.Find)
	fx.ui.needs_rebuild = false
	cd_view(&fx)
	dump := access_dump(&fx.ui.tree)
	testing.expect(t, strings.contains(dump, "Text_Input \"Find\"") && strings.contains(dump, "Button \"Next match\"") && strings.contains(dump, "Button \"Close find\""), dump)
	field := s.code.field
	testing.expect_value(t, fx.ui.tree.focus, field)
	text_event(&fx.ui, "f") // typed into the find field, a character at a time
	cd_view(&fx)
	testing.expect_value(t, s.code.current, 1) // the first at or after where the search started (line 3)
	text_event(&fx.ui, "oo")
	cd_view(&fx)
	testing.expect_value(t, len(s.code.matches), 3) // case-insensitive
	testing.expect_value(t, s.code.current, 1)      // typing on does not creep forward
	testing.expect(t, s.anchor == Pos{2, 0} && s.caret == Pos{2, 3}, "the current match is selected")
	highlights := 0
	for m in s.marks do if m.kind == .Highlight do highlights += 1
	testing.expect_value(t, highlights, 3)
	bar := node_get(&fx.ui.tree, node_parent(&fx.ui.tree, node_parent(&fx.ui.tree, field)))
	testing.expect_value(t, bar.access.describe, "2 of 3") // the bar's group tells assistive technology
	key_event(&fx.ui, .Enter, true, {}) // next
	testing.expect_value(t, s.code.current, 2)
	testing.expect_value(t, s.anchor, Pos{3, 0})
	key_event(&fx.ui, .Enter, true, {}) // wraps
	testing.expect_value(t, s.code.current, 0)
	key_event(&fx.ui, .Enter, true, {.Shift})
	testing.expect_value(t, s.code.current, 2)
	key_event(&fx.ui, .Escape, true, {})
	testing.expect_value(t, s.code.bar, Code_Bar.None)
	testing.expect_value(t, fx.ui.tree.focus, area)
	cd_view(&fx)
	testing.expect_value(t, len(s.marks), 0)
	// go to line 2
	key_event(&fx.ui, .G, true, {.Ctrl})
	cd_view(&fx)
	testing.expect_value(t, fx.ui.tree.focus, s.code.field)
	text_event(&fx.ui, "2")
	key_event(&fx.ui, .Enter, true, {})
	testing.expect_value(t, s.caret, Pos{1, 0})
	testing.expect_value(t, fx.ui.tree.focus, area)
	// brackets: the caret after "(" boxes both parens
	area_move(&fx.ui.tree, area, s, {0, 4}, false)
	a, b, ok := code_bracket_pair(s)
	testing.expect(t, ok && a == Pos{0, 3} && b == Pos{0, 5})
	cd_view(&fx)
	boxes := 0
	for _, l in fx.ui.tree.layers do for c in l.cmds do if r, is_rect := c.(Draw_Rect); is_rect && r.border_w == 1 && r.color == fx.ui.tree.theme.color.code.match do boxes += 1
	testing.expect_value(t, boxes, 2)
	// a click in the gutter selects that line
	d := node_get(&fx.ui.tree, area)
	inner := input_inner(d)
	line_y := inner.y + s.line_h * 2.5
	pointer_button(&fx.ui, .Left, true, {inner.x + 4, line_y})
	pointer_button(&fx.ui, .Left, false, {inner.x + 4, line_y})
	testing.expect(t, s.anchor == Pos{2, 0} && s.caret == Pos{3, 0}, "line 3 selected")
}

// Replace: Ctrl+H opens find with a replace row; Enter in the replace
// field replaces the current match and moves on, "All" replaces every
// match as one undo step.
@(test)
code_editor_replaces :: proc(t: ^testing.T) {
	fx: Cd_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	fx.doc = document_make("cat\ncatalog cat\ndog")
	defer document_destroy(&fx.doc)
	_, area := cd_view(&fx)
	s := &fx.ui.tree.areas[area]
	set_focus(&fx.ui.tree, area, true)
	testing.expect(t, key_event(&fx.ui, .H, true, {.Ctrl}))
	testing.expect_value(t, s.code.bar, Code_Bar.Replace)
	fx.ui.needs_rebuild = false
	cd_view(&fx)
	dump := access_dump(&fx.ui.tree)
	testing.expect(t, strings.contains(dump, "Text_Input \"Replace with\"") && strings.contains(dump, "Button \"Replace all\""), dump)
	text_event(&fx.ui, "cat") // the find field has focus
	cd_view(&fx)
	testing.expect_value(t, len(s.code.matches), 3)
	set_focus(&fx.ui.tree, s.code.field2, true)
	text_event(&fx.ui, "bird")
	key_event(&fx.ui, .Enter, true, {}) // replace the current (first) match
	testing.expect_value(t, cd_text(&fx), "bird\ncatalog cat\ndog")
	cd_view(&fx)
	testing.expect_value(t, len(s.code.matches), 2)
	testing.expect_value(t, s.code.current, 0) // moved on to the next
	key_event(&fx.ui, .Enter, true, {.Ctrl}) // all
	testing.expect_value(t, cd_text(&fx), "bird\nbirdalog bird\ndog")
	cd_view(&fx)
	testing.expect_value(t, len(s.code.matches), 0)
	set_focus(&fx.ui.tree, area, true)
	key_event(&fx.ui, .Z, true, {.Ctrl}) // one undo step for "all"
	testing.expect_value(t, cd_text(&fx), "bird\ncatalog cat\ndog")
}

// Completion: typing two identifier characters opens a list of the
// language's words and the document's identifiers that start with them;
// Down / Enter accept (replacing the prefix), Ctrl+Space opens on demand,
// Escape closes, and a custom completer takes over the candidates.
@(test)
code_editor_completes :: proc(t: ^testing.T) {
	fx: Cd_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	fx.doc = document_make("package demo\nprintln_twice :: proc() {}\n")
	defer document_destroy(&fx.doc)
	_, area := cd_view(&fx)
	s := &fx.ui.tree.areas[area]
	set_focus(&fx.ui.tree, area, true)
	area_move(&fx.ui.tree, area, s, {2, 0}, false)
	text_area_text(&fx.ui, "p")
	testing.expect(t, !s.complete.open, "one character is not enough")
	text_area_text(&fx.ui, "r")
	testing.expect(t, s.complete.open, "two characters open the list")
	labels := make([dynamic]string, context.temp_allocator)
	for it in s.complete.items do append(&labels, it.label)
	testing.expect(t, len(labels) >= 2, "proc and println_twice")
	has_proc, has_ident := false, false
	for l in labels {
		if l == "proc" do has_proc = true
		if l == "println_twice" do has_ident = true
	}
	testing.expect(t, has_proc && has_ident)
	fx.ui.needs_rebuild = false
	cd_view(&fx)
	dump := access_dump(&fx.ui.tree)
	testing.expect(t, strings.contains(dump, "List \"Completions\"") && strings.contains(dump, "List_Item \"proc\""), dump)
	// the list follows the typing: "pri" leaves only println_twice; Enter accepts it
	text_area_text(&fx.ui, "i")
	testing.expect_value(t, len(s.complete.items), 1)
	testing.expect_value(t, s.complete.items[0].label, "println_twice")
	key_event(&fx.ui, .Enter, true, {})
	testing.expect_value(t, block_str(&fx.doc, 2), "println_twice")
	testing.expect(t, !s.complete.open)
	// Escape closes an open list; Ctrl+Space reopens on demand with Down / Tab accepting
	text_area_text(&fx.ui, " ")
	text_area_text(&fx.ui, "p")
	text_area_text(&fx.ui, "a")
	testing.expect(t, s.complete.open)
	key_event(&fx.ui, .Escape, true, {})
	testing.expect(t, !s.complete.open)
	key_event(&fx.ui, .Space, true, {.Ctrl})
	testing.expect(t, s.complete.open)
	testing.expect_value(t, s.complete.items[0].label, "package")
	key_event(&fx.ui, .Tab, true, {})
	testing.expect_value(t, block_str(&fx.doc, 2), "println_twice package")
	// a custom completer
	mine :: proc(doc: ^Document, at: Pos, prefix: string, lang: ^Language, out: ^[dynamic]Completion) {
		append(out, Completion{label = "banana", detail = "fruit", kind = .String})
	}
	cd_view(&fx, complete = mine) // the same call site: the editor keeps its state
	set_focus(&fx.ui.tree, area, true)
	key_event(&fx.ui, .Space, true, {.Ctrl})
	testing.expect_value(t, len(s.complete.items), 1)
	testing.expect_value(t, s.complete.items[0].detail, "fruit")
}

// A mark with a message shows it in a tooltip when the pointer rests on
// the marked text, placed under that line, and hides it when the pointer
// leaves the mark.
@(test)
text_area_marks_show_their_message :: proc(t: ^testing.T) {
	fx: Cd_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	fx.doc = document_make("teh cat")
	defer document_destroy(&fx.doc)
	view :: proc(fx: ^Cd_Fx) -> Node {
		ui := &fx.ui
		set_viewport(&ui.tree, {600, 400})
		begin_view(ui)
		column(ui, padding = .lg)
		marks := []Mark{{from = {0, 0}, to = {0, 3}, kind = .Error, message = "Did you mean 'the'?"}}
		a := text_area(ui, &fx.doc, label = "Notes")
		editor_marks(ui, a, marks)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {600, 400})
		return a
	}
	area := view(&fx)
	d := node_get(&fx.ui.tree, area)
	inner := input_inner(d)
	on_mark := [2]f32{inner.x + 4, inner.y + 6}
	pointer_move(&fx.ui, on_mark)
	ui_after_events(&fx.ui, 100)
	testing.expect_value(t, fx.ui.tip_anchor, NODE_NONE) // not yet: the delay
	ui_after_events(&fx.ui, 100 + TOOLTIP_DELAY_MS + 1)
	testing.expect_value(t, fx.ui.tip_anchor, area)
	testing.expect_value(t, fx.ui.tip_mark, 0)
	view(&fx)
	tip := node_first(&fx.ui.tree, fx.ui.tree.overlay)
	testing.expect(t, tip != NODE_NONE && node_get(&fx.ui.tree, tip).access.role == .Tooltip, "a tooltip is up")
	testing.expect(t, strings.contains(access_dump(&fx.ui.tree), "Did you mean 'the'?"))
	td := node_get(&fx.ui.tree, tip)
	testing.expect(t, td.abs.y >= inner.y + fx.ui.tree.areas[area].line_h, "placed under the line")
	// off the mark: gone
	pointer_move(&fx.ui, {inner.x + 60, inner.y + 6})
	ui_after_events(&fx.ui, 2000)
	testing.expect_value(t, fx.ui.tip_anchor, NODE_NONE)
}

} // when ODIN_TEST