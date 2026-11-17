package baldr

// code_editor is the text area engine in the code face, for source: a
// line-number gutter (click one to select the line), tab stops, syntax
// colour from a `Language` (Odin, C, JSON ship; apps add their own), the
// caret line washed, matching brackets boxed, whitespace shown on request,
// wrap off by default (on request it soft-wraps). Editing keys on top of
// the text area's: Tab indents (the selected lines, or inserts one
// indent), Shift+Tab outdents, Enter keeps the indentation and opens a
// bracket pair onto its own line, Home goes to the first non-blank column
// then the margin, Ctrl+/ toggles line comments, Alt+Up / Down move lines,
// Ctrl+F opens find (Enter / Shift+Enter or F3 / Shift+F3 step through
// the matches, Escape closes and returns focus), Ctrl+G goes to a line,
// Ctrl+Tab / Ctrl+Shift+Tab move focus out (Tab is taken). Painting is
// virtual, so a 50 000-line file scrolls at full rate. Accessibility:
// Text_Input named `label` with the text as its value and "Line n, column
// m" as its description; the find bar is a field "Find" with buttons
// "Previous match", "Next match", "Close find".
//
//	baldr.code_editor(ui, &s.source, &baldr.LANG_ODIN, on_change = proc(e: baldr.Ev(int)) -> Msg { return Edited{} }, height = 400)

import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"

// Code_Bar is which of a code editor's own bars is open: find, find and
// replace, or go-to-line.
Code_Bar :: enum u8 { None, Find, Replace, Goto }

CODE_COMPLETE_SCAN :: 3000 // blocks around the caret the built-in completer reads

// `Completion`, `Completer`, `editor_complete` and the list itself live in
// editor_complete.odin: a plain `text_area` opens the same list on a trigger
// character, so none of it is the code editor's own.

// Code_State: the code editor's extras on a Text_Area_State.
Code_State :: struct {
	on:        bool,
	lang:      ^Language,
	gutter:    bool,
	spaces:    bool, // indent with spaces (tab_width of them) instead of a tab
	show_ws:   bool,
	ligatures: bool, // programming ligatures ("->" as one glyph); off by default
	tab_width: int,
	gutter_w:  f32,
	adv:       f32,  // one cell of the mono face
	states:    [dynamic]u32, // tokenizer state at each block's start (len = blocks + 1)
	state_stamps: [dynamic]u64, // the block stamp each state was read at (len = blocks)
	states_version: u64,
	states_valid:   bool,
	bar:       Code_Bar,
	query:     Text, // the find field's text (owned)
	goto_text: Text, // the go-to-line field's text (owned)
	matches:   [dynamic][2]Pos,
	match_version: u64,
	match_query:   string, // owned copy the matches were computed for
	match_valid:   bool,
	current:   int,  // the current match (-1 = none)
	search_from: Pos, // where the caret was when the bar opened: typing the query picks the match from here
	select_current: bool, // the next build selects the current match
	field:     Node, // the bar's text field (NONE when closed)
	field2:    Node, // the replace field
	frame:     Node, // the column holding the bar and the area
	desc:      [40]u8,
	column:    Code_Column, // where the caret's column was last counted (code_caret_column)
	numbers:   [dynamic]u8, // the gutter's line-number text for the current draw list (borrowed by it)
	replace_text: Text,     // the replace field's text (owned)
}

CODE_GUTTER_PAD :: f32(10)

// Code_Column is where code_caret_column last counted to: a place a cluster
// walk may start from (grapheme_restart), how many clusters come before it,
// and which line of which document that was.
@(private)
Code_Column :: struct {
	doc:    u64, // Document.id
	stamp:  u64, // block_stamp of the line
	at:     int,
	before: int,
}

@(private)
code_state_destroy :: proc(t: ^Tree, c: ^Code_State) {
	delete(c.states)
	delete(c.state_stamps)
	delete(c.matches)
	delete(c.numbers)
	text_destroy(&c.query)
	text_destroy(&c.goto_text)
	text_destroy(&c.replace_text)
	if len(c.match_query) > 0 do delete(c.match_query, t.allocator)
	c^ = {}
}

code_editor :: proc(ui: ^Ui($Msg), doc: ^Document, language: ^Language = nil, on_change: Handler(Msg, int) = nil,
	on_context: Handler(Msg, Editor_Context) = nil, label: string = "Code", width: f32 = 0, height: f32 = 0, flex: f32 = 0, disabled := false, focus := false, tag: u64 = 0, key: u64 = 0,
	loc := #caller_location) -> Node {
	t := &ui.tree
	th := &t.theme
	frame := column(ui, gap = .xs, width = width, flex = flex, key = key, loc = loc)
	area := t.area_of_frame[frame]
	s := &t.areas[area]
	// the bar above the text (find / go to line), when the state says it is open
	if s != nil && s.code.bar != .None && !disabled {
		code_find_compute(t, s) // so the bar's "n of m" is current
		code_bar_build(ui, area, s, loc)
	}
	area = area_build(ui, doc, "", on_change, nil, on_context, label, 0, height, 1 if height == 0 else 0, disabled, tag, 1, loc, focus = focus,
		mono = true, def_wrap = false, def_min_lines = 10)
	if t.area_of_frame[frame] != area do ask_rebuild(ui) // first build: the bar was wired before the area existed
	t.area_of_frame[frame] = area
	s = &t.areas[area]
	c := &s.code
	if !c.on {
		c.on = true
		c.current = -1
		c.gutter = true
		c.tab_width = 4
		s.tab = 4
		c.query = text_make("", t.allocator)
		c.goto_text = text_make("", t.allocator)
		c.replace_text = text_make("", t.allocator)
		c.states = make([dynamic]u32, t.allocator)
		c.state_stamps = make([dynamic]u64, t.allocator)
		c.matches = make([dynamic][2]Pos, t.allocator)
		c.numbers = make([dynamic]u8, t.allocator)
		mark_layout_dirty(t, area)
	}
	c.frame = frame
	if c.lang != language {
		c.lang = language
		c.states_valid = false
		mark_paint_dirty(t, area)
	}
	if d := node_get(t, area); d != nil {
		st := d.style
		st.radius = th.radius.md
		set_style(t, area, st)
	}
	code_find_update(t, area, s)
	if s.complete.open && !disabled && !s.readonly do complete_build(ui, area, s, loc)
	end(ui)
	return frame
}

// ------------------------------------------------------------ the bar

@(private)
code_bar_build :: proc(ui: ^Ui($Msg), area: Node, s: ^Text_Area_State, loc: runtime.Source_Code_Location) {
	t := &ui.tree
	th := &t.theme
	c := &s.code
	finds := c.bar == .Find || c.bar == .Replace
	box := column(ui, gap = .xs, padding = .xs, bg = th.color.surface_high, radius = th.radius.sm, key = 2, loc = loc)
	set_role(t, box, .Group)
	set_name(t, box, "Find" if finds else "Go to line")
	row(ui, gap = .sm, align = .Center, key = 1, loc = loc)
	baldr_icon(ui, .Search if finds else .Chevron_Right, ICON_SIZE, th.color.on_surface_muted, loc)
	if finds {
		c.field = text_input(ui, &c.query, placeholder = "Find", label = "Find", width = 220, key = 3, loc = loc)
		t.editor_ctl_of[c.field] = area
		note: string
		if len(c.matches) == 0 {
			note = "No matches" if len(str(c.query)) > 0 else ""
		} else {
			note = fmt.tprintf("%d of %d", c.current + 1, len(c.matches))
		}
		lbl := text(ui, note, role = .Caption, muted = true, nowrap = true, key = 4, loc = loc)
		set_role(t, lbl, .None)
		set_describe(t, box, note) // "2 of 3" reaches assistive technology through the group
		code_bar_button(ui, area, .Chevron_Up, "Previous match", 1, 5, loc)
		code_bar_button(ui, area, .Chevron_Down, "Next match", 2, 6, loc)
	} else {
		c.field = text_input(ui, &c.goto_text, placeholder = "Line number", label = "Go to line", width = 140, key = 7, loc = loc)
		t.editor_ctl_of[c.field] = area
		lbl := text(ui, fmt.tprintf("of %d", block_count(s.doc)) if s.doc != nil else "", role = .Caption, muted = true, nowrap = true, key = 8, loc = loc)
		set_role(t, lbl, .None)
	}
	spacer(ui, loc = loc)
	code_bar_button(ui, area, .X, "Close find" if finds else "Close go to line", 3, 9, loc)
	end(ui) // bar
	c.field2 = NODE_NONE
	if c.bar == .Replace {
		row(ui, gap = .sm, align = .Center, key = 10, loc = loc)
		baldr_icon(ui, .Pencil, ICON_SIZE, th.color.on_surface_muted, loc)
		c.field2 = text_input(ui, &c.replace_text, placeholder = "Replace with", label = "Replace with", width = 220, key = 11, loc = loc)
		t.editor_ctl_of[c.field2] = area
		code_bar_text_button(ui, area, "Replace", 4, 12, loc)
		code_bar_text_button(ui, area, "All", 5, 13, loc)
		end(ui)
	}
	if c.select_current && c.field != NODE_NONE { // freshly opened: type straight away
		ui.pending_focus = c.field
	}
	end(ui) // box
}

// code_bar_text_button: a small labelled button routed to the editor.
@(private)
code_bar_text_button :: proc(ui: ^Ui($Msg), area: Node, label: string, action: u64, key: u64, loc: runtime.Source_Code_Location) -> Node {
	t := &ui.tree
	th := &t.theme
	b, created := reconcile_child(ui, .Box, key, loc)
	d := node_get(t, b)
	if created {
		d.access.role = .Button
		d.flags += {.Focusable}
	}
	set_name(t, b, "Replace all" if action == 5 else label)
	d.tag = action
	t.editor_ctl_of[b] = area
	set_layout(t, b, Layout_Props{axis = .Row, align = .Center, justify = .Center, height = 28, padding = {0, th.space[.sm], 0, th.space[.sm]}})
	st := d.style
	st.radius = th.radius.sm
	st.border_w = 1
	st.border = th.color.outline
	set_style(t, b, st)
	open_scope(ui, b, loc)
	lbl := text(ui, label, role = .Label, nowrap = true, loc = loc)
	set_role(t, lbl, .None)
	close_scope(ui)
	return b
}

// code_bar_button: an icon button routed to the editor (no app message).
@(private)
code_bar_button :: proc(ui: ^Ui($Msg), area: Node, ic: Icon, name: string, action: u64, key: u64, loc: runtime.Source_Code_Location) -> Node {
	t := &ui.tree
	th := &t.theme
	b, created := reconcile_child(ui, .Box, key, loc)
	d := node_get(t, b)
	if created {
		d.access.role = .Button
		d.flags += {.Focusable}
	}
	set_name(t, b, name)
	d.tag = action
	t.editor_ctl_of[b] = area
	set_layout(t, b, Layout_Props{axis = .Row, align = .Center, justify = .Center, width = 28, height = 28})
	st := d.style
	st.radius = th.radius.sm
	set_style(t, b, st)
	open_scope(ui, b, loc)
	baldr_icon(ui, ic, ICON_SIZE, th.color.on_surface, loc)
	close_scope(ui)
	return b
}

// code_bar_click: the bar's buttons (previous / next / close).
@(private)
code_bar_click :: proc(ui: ^Ui($Msg), n: Node) -> bool {
	t := &ui.tree
	area, ok := t.editor_ctl_of[n]
	if !ok do return false
	d := node_get(t, n)
	s := &t.areas[area]
	if d == nil || s == nil || !s.code.on || (d.access.role != .Button && d.access.role != .List_Item) do return false
	if d.tag >= RICH_ACTION_BASE do return false // a rich editor's control
	switch d.tag {
	case 1: code_find_step(ui, area, s, -1)
	case 2: code_find_step(ui, area, s, +1)
	case 3: code_bar_close(ui, area, s)
	case 4: code_replace_current(ui, area, s)
	case 5: code_replace_all(ui, area, s)
	}
	return true
}

// code_bar_key: keys in the bar's field — Enter steps / jumps, Escape closes.
code_bar_key :: proc(ui: ^Ui($Msg), key: Key, mods: Mods) -> bool {
	t := &ui.tree
	area, ok := t.editor_ctl_of[t.focus]
	if !ok do return false
	s := &t.areas[area]
	if s == nil || !s.code.on do return false
	c := &s.code
	#partial switch key {
	case .Enter:
		switch {
		case c.bar == .Goto:
			code_goto_commit(ui, area, s)
		case t.focus == c.field2: // the replace field
			if .Ctrl in mods { code_replace_all(ui, area, s) } else { code_replace_current(ui, area, s) }
		case:
			code_find_compute(t, s) // Enter straight after typing: the matches may be a build behind
			code_find_step(ui, area, s, -1 if .Shift in mods else +1)
		}
		return true
	case .F3:
		if c.bar != .Find && c.bar != .Replace do return false
		code_find_step(ui, area, s, -1 if .Shift in mods else +1)
		return true
	case .Escape:
		code_bar_close(ui, area, s)
		return true
	}
	return false
}

@(private)
code_bar_open :: proc(ui: ^Ui($Msg), area: Node, s: ^Text_Area_State, which: Code_Bar) {
	t := &ui.tree
	c := &s.code
	if c.bar == which do return
	c.bar = which
	c.select_current = true
	c.search_from, _ = pos_order(s.caret, s.anchor) // the selection's start, or the caret
	if which == .Find || which == .Replace { // seed the query with the selection when it is one line
		lo, hi := pos_order(s.caret, s.anchor)
		if lo != hi && lo.block == hi.block {
			text_set(&c.query, block_str(s.doc, lo.block)[lo.off:hi.off])
			c.match_valid = false
		}
	} else {
		text_set(&c.goto_text, "")
	}
	ask_rebuild(ui)
	_ = t
}

@(private)
code_bar_close :: proc(ui: ^Ui($Msg), area: Node, s: ^Text_Area_State) {
	t := &ui.tree
	c := &s.code
	if c.bar == .None do return
	c.bar = .None
	c.field = NODE_NONE
	clear(&c.matches)
	c.current = -1
	c.match_valid = false
	set_focus(t, area, false)
	ask_rebuild(ui)
	mark_paint_dirty(t, area)
}

// code_tick asks for a rebuild when a find field's text no longer matches
// what the matches were computed for (typing in the field does not
// rebuild on its own).
code_tick :: proc(ui: ^Ui($Msg)) {
	for _, &s in ui.tree.areas {
		if s.code.on && (s.code.bar == .Find || s.code.bar == .Replace) && (str(s.code.query) != s.code.match_query || !s.code.match_valid) {
			ask_rebuild(ui)
			return
		}
	}
}

// ------------------------------------------------------------ find / go to

// code_find_update recomputes the matches when the query or the document
// changed, folds them into Highlight marks, and selects the current one
// when asked to (a step, a new query).
@(private)
code_find_update :: proc(t: ^Tree, area: Node, s: ^Text_Area_State) {
	c := &s.code
	if (c.bar != .Find && c.bar != .Replace) || s.doc == nil do return
	code_find_compute(t, s)
	for m in c.matches do append(&s.marks, Mark{from = m[0], to = m[1], kind = .Highlight})
	if len(c.matches) > 0 do s.marks_rev += 1 // the index follows (area_marks_for)
	if c.select_current && c.current >= 0 && c.current < len(c.matches) {
		m := c.matches[c.current]
		s.anchor, s.caret = m[0], m[1]
		s.goal_x = -1
		area_touch(t, area, s)
	}
	c.select_current = false
}

// code_find_compute refreshes the match list for the query and document.
@(private)
code_find_compute :: proc(t: ^Tree, s: ^Text_Area_State) {
	c := &s.code
	if (c.bar != .Find && c.bar != .Replace) || s.doc == nil do return
	q := str(c.query)
	if !c.match_valid || c.match_version != s.doc.version || c.match_query != q {
		query_same := c.match_valid && c.match_query == q
		clear(&c.matches)
		if len(c.match_query) > 0 do delete(c.match_query, t.allocator)
		c.match_query = strings.clone(q, t.allocator)
		c.match_version = s.doc.version
		c.match_valid = true
		if len(q) > 0 {
			ql := strings.to_lower(q, context.temp_allocator)
			for b in 0 ..< len(s.doc.blocks) {
				line := strings.to_lower(block_str(s.doc, b), context.temp_allocator)
				at := 0
				for at <= len(line) - len(ql) {
					i := strings.index(line[at:], ql)
					if i < 0 do break
					append(&c.matches, [2]Pos{{b, at + i}, {b, at + i + len(ql)}})
					at += i + max(len(ql), 1)
				}
			}
		}
		// the current match: the first at or after where the search started
		// (a new query keeps that anchor; an edit moves on from the caret)
		from := s.caret if query_same else c.search_from
		c.current = -1
		if len(c.matches) > 0 {
			c.current = 0
			for m, i in c.matches do if !pos_less(m[0], from) { c.current = i; break }
			c.select_current = true
		}
	}
}

@(private)
code_find_step :: proc(ui: ^Ui($Msg), area: Node, s: ^Text_Area_State, dir: int) {
	c := &s.code
	if len(c.matches) == 0 do return
	c.current = ((c.current + dir) % len(c.matches) + len(c.matches)) % len(c.matches)
	c.select_current = true
	ask_rebuild(ui) // the "n of m" caption follows
	code_find_update(&ui.tree, area, s)
}

// code_replace_current replaces the current match and moves to the next.
@(private)
code_replace_current :: proc(ui: ^Ui($Msg), area: Node, s: ^Text_Area_State) {
	t := &ui.tree
	c := &s.code
	if s.readonly do return
	code_find_compute(t, s)
	if c.current < 0 || c.current >= len(c.matches) do return
	m := c.matches[c.current]
	s.group += 1
	s.caret = document_replace(s.doc, m[0], m[1], str(c.replace_text), s.group)
	s.anchor = s.caret
	area_break_typing(s)
	mark_layout_dirty(t, area)
	area_changed(ui, area, s)
	code_find_compute(t, s) // the version moved: the next match at or after the caret is current
	c.select_current = true
	code_find_update(t, area, s)
}

// code_replace_all replaces every match as one undo step.
@(private)
code_replace_all :: proc(ui: ^Ui($Msg), area: Node, s: ^Text_Area_State) {
	t := &ui.tree
	c := &s.code
	if s.readonly do return
	code_find_compute(t, s)
	if len(c.matches) == 0 do return
	repl := str(c.replace_text)
	s.group += 1
	#reverse for m in c.matches do s.caret = document_replace(s.doc, m[0], m[1], repl, s.group) // from the end: earlier positions stay valid
	s.anchor = s.caret
	area_break_typing(s)
	mark_layout_dirty(t, area)
	area_touch(t, area, s)
	area_changed(ui, area, s)
	code_find_compute(t, s)
}

@(private)
code_goto_commit :: proc(ui: ^Ui($Msg), area: Node, s: ^Text_Area_State) {
	t := &ui.tree
	c := &s.code
	line, ok := strconv.parse_int(strings.trim_space(str(c.goto_text)))
	if !ok || s.doc == nil do return
	b := clamp(line - 1, 0, len(s.doc.blocks) - 1)
	code_bar_close(ui, area, s)
	area_move(t, area, s, {b, 0}, false)
	if st, has := &t.scrolls[area]; has { // centre the line
		top := block_top(t, s, b)
		st.offset.y = scroll_clamp(st^, {st.offset.x, top - st.viewport.y / 2}).y
	}
}

// ------------------------------------------------------------ measure / paint

@(private)
code_measure :: proc(t: ^Tree, s: ^Text_Area_State) {
	c := &s.code
	c.adv = text_advance(t.text, s.size, s.family)
	if c.gutter && s.doc != nil {
		digits := 1
		for n := len(s.doc.blocks); n >= 10; n /= 10 do digits += 1
		c.gutter_w = f32(max(digits, 2)) * c.adv + CODE_GUTTER_PAD * 2
	} else {
		c.gutter_w = 0
	}
}

// code_states makes sure the per-block tokenizer states match the
// document: what the lexer carries into each block (inside a comment, in
// a string), so a block in view can be coloured on its own.
//
// It reads from the first changed block only, and stops as soon as what it
// carries out of a line is what the rest of the file was already read with
// — for ordinary typing, the next line. Keying on the document's version
// would re-lex the whole file on every keystroke.
@(private)
code_states :: proc(s: ^Text_Area_State) -> []u32 {
	c := &s.code
	n := len(s.doc.blocks)
	if c.states_valid && c.states_version == s.doc.version && len(c.state_stamps) == n && len(c.states) == n + 1 do return c.states[:]
	done :: proc(c: ^Code_State, version: u64) -> []u32 {
		c.states_valid = true
		c.states_version = version
		return c.states[:]
	}
	toks := make([dynamic]Token, context.temp_allocator)
	from := 0
	if c.states_valid && len(c.states) == len(c.state_stamps) + 1 && n > 0 {
		old := len(c.state_stamps)
		p, q := stamp_span(s.doc, c.state_stamps[:], n)
		if old != n { // blocks were inserted or removed: the tail slides, states and all
			end := c.states[old]
			resize(&c.states, old)
			block_realign(&c.states, old, n, q)
			block_realign(&c.state_stamps, old, n, q)
			resize(&c.states, n + 1)
			c.states[n] = end
		}
		if p >= n do return done(c, s.doc.version) // every line is as it was read
		from = p
	} else {
		resize(&c.states, n + 1)
		resize(&c.state_stamps, n)
		c.states[0] = 0
	}
	st := c.states[from]
	for b in from ..< n {
		if b > from && c.state_stamps[b] == block_stamp(s.doc, b) && c.states[b] == st do return done(c, s.doc.version)
		c.states[b] = st
		c.state_stamps[b] = block_stamp(s.doc, b)
		clear(&toks)
		st = tokenize_line(c.lang, block_str(s.doc, b), st, &toks)
	}
	c.states[n] = st
	return done(c, s.doc.version)
}

@(private)
code_token_color :: proc(th: ^Theme, k: Token_Kind) -> Color {
	switch k {
	case .Keyword:   return th.color.code.keyword
	case .Type:      return th.color.code.type
	case .String:    return th.color.code.string
	case .Number:    return th.color.code.number
	case .Comment:   return th.color.code.comment
	case .Operator:  return th.color.code.operator
	case .Punct:     return th.color.code.punct
	case .Constant:  return th.color.code.constant
	case .Attribute: return th.color.code.attribute
	case .Plain, .Ident:
	}
	return th.color.on_surface
}

// code_paint_under: the caret line's wash and the gutter, before the text.
@(private)
code_paint_under :: proc(t: ^Tree, n: Node, d: ^Node_Data, s: ^Text_Area_State, l: ^Layer, inner: Rect, text_x, off: f32, focused: bool) {
	th := &t.theme
	c := &s.code
	if focused {
		line, _, _ := caret_line(t, s, s.caret)
		cy := inner.y - off + block_top(t, s, s.caret.block) + f32(line) * s.line_h
		wash := th.color.code.current_line
		wash.a *= t.paint_opacity
		append(&l.cmds, Draw_Rect{rect = {inner.x, cy, inner.w, s.line_h}, color = wash})
	}
	if c.gutter && c.gutter_w > 0 {
		gbg := th.color.surface_variant
		gbg.a *= t.paint_opacity
		append(&l.cmds, Draw_Rect{rect = {inner.x, d.abs.y + 1, c.gutter_w - CODE_GUTTER_PAD / 2, d.abs.h - 2}, color = gbg}) // covers text that scrolled sideways
		sep := th.color.outline_variant
		sep.a *= t.paint_opacity
		append(&l.cmds, Draw_Rect{rect = {inner.x + c.gutter_w - CODE_GUTTER_PAD / 2, d.abs.y + 1, 1, d.abs.h - 2}, color = sep})
		first := block_at_y(t, s, off)
		bottom := off + inner.h
		num_w := c.gutter_w - CODE_GUTTER_PAD * 2
		// the numbers live in the state until the next paint: the draw list borrows them
		clear(&c.numbers)
		last := first
		for b := first; b < len(s.doc.blocks); b += 1 {
			if block_top(t, s, b) >= bottom do break
			buf: [24]u8
			append(&c.numbers, ..transmute([]u8)strconv.write_int(buf[:], i64(b + 1), 10))
			append(&c.numbers, 0)
			last = b + 1
		}
		at := 0
		for b := first; b < last; b += 1 {
			end := at
			for c.numbers[end] != 0 do end += 1
			col := th.color.code.gutter_current if b == s.caret.block && focused else th.color.code.gutter
			col.a *= t.paint_opacity
			append(&l.cmds, Draw_Text{pos = {inner.x + CODE_GUTTER_PAD, inner.y - off + block_top(t, s, b)}, str = string(c.numbers[at:end]), size = s.size, color = col, mono = true, align = .End, box_w = num_w, family = s.family})
			at = end + 1
		}
	}
}

// code_paint_line draws one block's text as coloured tokens (one Draw_Text
// per token; the gaps are whitespace); plain runs between them included.
@(private)
code_paint_line :: proc(t: ^Tree, s: ^Text_Area_State, l: ^Layer, b: int, str: string, spans: []Line_Span, x0, y0, alpha: f32) {
	th := &t.theme
	states := code_states(s)
	toks := make([dynamic]Token, context.temp_allocator)
	if _, cut, capped := area_cap(t, s, b); capped && cut < len(str) && !(len(s.pre) > 0 && b == s.pre_block) {
		// a line past the limit: its first part coloured as code, the marker as a comment
		tokenize_line(s.code.lang, str[:cut], states[b], &toks)
		append(&toks, Token{start = cut, end = len(str), kind = .Comment})
	} else {
		tokenize_line(s.code.lang, str, states[b], &toks)
	}
	plain := th.color.on_surface
	plain.a *= alpha
	for sp, li in spans {
		y := y0 + f32(li) * s.line_h
		// the text between tokens is plain (a tokenizer need not cover every byte)
		gap :: proc(t: ^Tree, s: ^Text_Area_State, l: ^Layer, b: int, sp: Line_Span, str: string, from, to: int, x0, y: f32, col: Color) {
			ga, gz := max(from, sp.start), min(to, sp.end)
			if gz <= ga do return
			blank := true
			for i in ga ..< gz do if str[i] != ' ' && str[i] != '\t' { blank = false; break }
			if blank do return
			append(&l.cmds, Draw_Text{pos = {x0 + span_x(t, s, b, sp, ga), y}, str = str[ga:gz], size = s.size, color = col, mono = true, tab = s.tab, no_ligatures = !s.code.ligatures, family = s.family})
		}
		prev := 0
		for tk in toks {
			gap(t, s, l, b, sp, str, prev, tk.start, x0, y, plain)
			prev = max(prev, tk.end)
			a, z := max(tk.start, sp.start), min(tk.end, sp.end)
			if z <= a do continue
			col := code_token_color(th, tk.kind)
			col.a *= alpha
			x := x0 + span_x(t, s, b, sp, a)
			append(&l.cmds, Draw_Text{pos = {x, y}, str = str[a:z], size = s.size, color = col, mono = true, tab = s.tab, no_ligatures = !s.code.ligatures, family = s.family})
		}
		gap(t, s, l, b, sp, str, prev, len(str), x0, y, plain)
	}
}

// code_paint_whitespace shows spaces as dots and tabs as arrows.
@(private)
code_paint_whitespace :: proc(t: ^Tree, s: ^Text_Area_State, l: ^Layer, b: int, str: string, spans: []Line_Span, x0, y0, alpha: f32) {
	th := &t.theme
	col := th.color.on_surface_muted
	col.a *= alpha * 0.55
	for sp, li in spans {
		y := y0 + f32(li) * s.line_h
		for i := sp.start; i < sp.end; i += 1 {
			ch := str[i]
			if ch != ' ' && ch != '\t' do continue
			x := x0 + span_x(t, s, b, sp, i)
			append(&l.cmds, Draw_Text{pos = {x, y}, str = "·" if ch == ' ' else "→", size = s.size, color = col, mono = true, family = s.family})
		}
	}
}

// code_paint_over: the boxes around a matched bracket pair, after the text.
@(private)
code_paint_over :: proc(t: ^Tree, n: Node, d: ^Node_Data, s: ^Text_Area_State, l: ^Layer, inner: Rect, text_x, off: f32, focused: bool) {
	if !focused || s.caret != s.anchor do return
	a, b, ok := code_bracket_pair(s)
	if !ok do return
	th := &t.theme
	col := th.color.code.match
	col.a *= t.paint_opacity
	for p in ([2]Pos{a, b}) {
		line, sp, x := caret_line(t, s, p)
		y := inner.y - off + block_top(t, s, p.block) + f32(line) * s.line_h
		w := span_x(t, s, p.block, sp, p.off + 1) - x
		append(&l.cmds, Draw_Rect{rect = {text_x + x, y, max(w, s.code.adv), s.line_h}, radius = 2, color = col, border_w = 1, border = th.color.primary})
	}
}

// code_bracket_pair: the bracket at or just before the caret and its mate.
@(private)
code_bracket_pair :: proc(s: ^Text_Area_State) -> (a, b: Pos, ok: bool) {
	lang := s.code.lang if s.code.lang != nil else &LANG_PLAIN
	if len(lang.brackets) == 0 do return
	str := block_str(s.doc, s.caret.block)
	at := -1
	if s.caret.off < len(str) && strings.index_byte(lang.brackets, str[s.caret.off]) >= 0 do at = s.caret.off
	if at < 0 && s.caret.off > 0 && strings.index_byte(lang.brackets, str[s.caret.off - 1]) >= 0 do at = s.caret.off - 1
	if at < 0 do return
	mate, found := code_bracket_match(s.doc, lang, {s.caret.block, at})
	if !found do return
	return {s.caret.block, at}, mate, true
}

// code_bracket_match finds the mate of the bracket at `p` across blocks,
// counting nesting; up to CODE_MATCH_SPAN blocks away.
CODE_MATCH_SPAN :: 2000

@(private)
code_bracket_match :: proc(doc: ^Document, lang: ^Language, p: Pos) -> (Pos, bool) {
	str := block_str(doc, p.block)
	c := str[p.off]
	k := strings.index_byte(lang.brackets, c)
	if k < 0 do return {}, false
	opener := k % 2 == 0
	mate := lang.brackets[k + 1] if opener else lang.brackets[k - 1]
	depth := 0
	if opener {
		for b := p.block; b < len(doc.blocks) && b - p.block < CODE_MATCH_SPAN; b += 1 {
			line := block_str(doc, b)
			for i := p.off if b == p.block else 0; i < len(line); i += 1 {
				if line[i] == c do depth += 1
				if line[i] == mate {
					depth -= 1
					if depth == 0 do return {b, i}, true
				}
			}
		}
	} else {
		for b := p.block; b >= 0 && p.block - b < CODE_MATCH_SPAN; b -= 1 {
			line := block_str(doc, b)
			for i := p.off if b == p.block else len(line) - 1; i >= 0; i -= 1 {
				if line[i] == c do depth += 1
				if line[i] == mate {
					depth -= 1
					if depth == 0 do return {b, i}, true
				}
			}
		}
	}
	return {}, false
}

// code_describe_caret tells assistive technology the caret's line and column.
@(private)
code_describe_caret :: proc(t: ^Tree, n: Node, s: ^Text_Area_State) {
	set_describe(t, n, fmt.bprintf(s.code.desc[:], "Line %d, column %d", s.caret.block + 1, code_caret_column(s) + 1))
}

// code_caret_column is the caret's column, in clusters from the start of its
// line. Counting from the start would walk the whole line on every arrow
// key, so it keeps where it last counted to, at a place a walk can restart,
// and counts only what lies between, from whichever end is nearer. That
// place is a little behind the caret, so an edit at the caret falls after
// it and keeps it valid (area_replace).
@(private)
code_caret_column :: proc(s: ^Text_Area_State) -> int {
	COLUMN_BEHIND :: 256 // bytes
	str := block_str(s.doc, s.caret.block)
	off := clamp(s.caret.off, 0, len(str))
	stamp := block_stamp(s.doc, s.caret.block)
	r := grapheme_restart(str, max(off - COLUMN_BEHIND, 0))
	m := &s.code.column
	before: int
	if r == 0 {
		before = 0
	} else if m.doc == s.doc.id && m.stamp == stamp && m.at <= len(str) && abs(r - m.at) < r {
		before = m.before + grapheme_index(str[m.at:], r - m.at) if r >= m.at else m.before - grapheme_index(str[r:], m.at - r)
	} else {
		before = grapheme_index(str, r)
	}
	m^ = {doc = s.doc.id, stamp = stamp, at = r, before = before}
	return before + grapheme_index(str[r:], off - r)
}

// ------------------------------------------------------------ keys

@(private)
code_indent_unit :: proc(s: ^Text_Area_State, allocator := context.temp_allocator) -> string {
	if !s.code.spaces do return "\t"
	return strings.repeat(" ", s.code.tab_width, allocator)
}

@(private)
leading_ws :: proc(line: string) -> int {
	i := 0
	for i < len(line) && (line[i] == ' ' || line[i] == '\t') do i += 1
	return i
}

// code_key: the editor's own keys; false lets the text area handle the rest.
@(private)
code_key :: proc(ui: ^Ui($Msg), n: Node, s: ^Text_Area_State, key: Key, mods: Mods) -> bool {
	t := &ui.tree
	c := &s.code
	doc := s.doc
	shift, ctrl, alt := .Shift in mods, .Ctrl in mods, .Alt in mods
	lo, hi := pos_order(s.caret, s.anchor)
	#partial switch key {
	case .Space:
		if !ctrl do return false
		complete_open(ui, n, s, complete_word_start(s), by_key = true)
		return true
	case .H:
		if !ctrl do return false
		code_bar_open(ui, n, s, .Replace)
		return true
	case .Tab:
		if ctrl do return false // Ctrl+Tab moves focus out
		if s.readonly do return true
		multi := lo.block != hi.block
		if shift || multi {
			code_shift_lines(ui, n, s, lo.block, hi.block if hi.off > 0 || hi.block == lo.block else hi.block - 1, outdent = shift)
		} else {
			area_replace(ui, n, s, lo, hi, code_indent_unit(s))
		}
		return true
	case .Enter:
		if ctrl || s.readonly do return false
		line := block_str(doc, lo.block)
		ws := line[:min(leading_ws(line), lo.off)]
		unit := code_indent_unit(s)
		lang := c.lang if c.lang != nil else &LANG_PLAIN
		before := lo.off > 0 && strings.index_byte(lang.brackets, line[lo.off - 1]) >= 0 && strings.index_byte(lang.brackets, line[lo.off - 1]) % 2 == 0
		after := hi.off < len(line) && strings.index_byte(lang.brackets, line[hi.off]) >= 0 && strings.index_byte(lang.brackets, line[hi.off]) % 2 == 1
		if before && after { // {|} → the closer goes to its own line, the caret between
			ins := strings.concatenate({"\n", ws, unit, "\n", ws}, context.temp_allocator)
			area_replace(ui, n, s, lo, hi, ins)
			area_move(t, n, s, {lo.block + 1, len(ws) + len(unit)}, false)
		} else if before {
			area_replace(ui, n, s, lo, hi, strings.concatenate({"\n", ws, unit}, context.temp_allocator))
		} else {
			area_replace(ui, n, s, lo, hi, strings.concatenate({"\n", ws}, context.temp_allocator))
		}
		return true
	case .Home:
		if ctrl do return false
		line := block_str(doc, s.caret.block)
		first := leading_ws(line)
		_, sp, _ := caret_line(t, s, s.caret)
		to := first if s.caret.off != first && sp.start == 0 else sp.start
		area_move(t, n, s, {s.caret.block, to}, shift)
		return true
	case .Backspace:
		// spaces: a Backspace inside the indentation goes back to the previous tab stop
		if !c.spaces || lo != hi || s.readonly do return false
		line := block_str(doc, lo.block)
		if lo.off == 0 || lo.off > leading_ws(line) do return false
		back := lo.off % c.tab_width
		if back == 0 do back = c.tab_width
		area_replace(ui, n, s, {lo.block, lo.off - back}, lo, "")
		return true
	case .Slash:
		if !ctrl do return false
		code_toggle_comment(ui, n, s, lo.block, hi.block if hi.off > 0 || hi.block == lo.block else hi.block - 1)
		return true
	case .Up, .Down:
		if !alt do return false
		code_move_lines(ui, n, s, lo.block, hi.block if hi.off > 0 || hi.block == lo.block else hi.block - 1, -1 if key == .Up else +1)
		return true
	case .F:
		if !ctrl do return false
		code_bar_open(ui, n, s, .Find)
		return true
	case .G:
		if !ctrl do return false
		code_bar_open(ui, n, s, .Goto)
		return true
	case .F3:
		if c.bar != .Find && c.bar != .Replace do return false
		code_find_step(ui, n, s, -1 if shift else +1)
		return true
	case .Escape:
		if c.bar != .None {
			code_bar_close(ui, n, s)
			return true
		}
	}
	return false
}

// ------------------------------------------------------------ completion

// The list, its keys and its state are shared with the plain text area
// (editor_complete.odin). What is the code editor's own is below: the
// built-in completer, and the badge that colours a candidate by its kind.

// default_completer: the language's keywords, types and constants, and
// the identifiers of the surrounding CODE_COMPLETE_SCAN lines, that start
// with the prefix (the word being typed itself excluded).
default_completer :: proc(doc: ^Document, at: Pos, prefix: string, lang: ^Language, out: ^[dynamic]Completion) {
	seen := make(map[string]struct{}, context.temp_allocator)
	add :: proc(out: ^[dynamic]Completion, seen: ^map[string]struct{}, w, prefix, detail: string, kind: Token_Kind) {
		if len(w) < 2 || w == prefix || !strings.has_prefix(w, prefix) || w in seen do return
		seen[w] = {}
		append(out, Completion{label = w, detail = detail, kind = kind})
	}
	if lang != nil {
		for w in lang.keywords do add(out, &seen, w, prefix, "keyword", .Keyword)
		for w in lang.types do add(out, &seen, w, prefix, "type", .Type)
		for w in lang.constants do add(out, &seen, w, prefix, "", .Constant)
	}
	lo := max(at.block - CODE_COMPLETE_SCAN, 0)
	hi := min(at.block + CODE_COMPLETE_SCAN, len(doc.blocks) - 1)
	for b in lo ..= hi {
		line := block_str(doc, b)
		i := 0
		for i < len(line) {
			if !is_ident_start(line[i]) {
				i += 1
				continue
			}
			j := i
			for j < len(line) && is_ident_char(line[j]) do j += 1
			if !(b == at.block && j == at.off) do add(out, &seen, line[i:j], prefix, "", .Ident) // not the word under the caret
			i = j
		}
	}
}

// code_complete_build shows the candidates in a popover under the caret.
@(private)
code_complete_build :: proc(ui: ^Ui($Msg), area: Node, s: ^Text_Area_State, loc: runtime.Source_Code_Location) {
	t := &ui.tree
	th := &t.theme
	c := &s.code
	d := node_get(t, area)
	if d == nil do return
	k := (u64(area) * 0x9E37_79B9_7F4A_7C15) | 2
	pop, created := overlay_begin(ui, k, loc)
	popover_style(ui, pop, created, area, .Below, 0, true)
	pd := node_get(t, pop)
	pd.access.role = .List
	set_name(t, pop, "Completions")
	// at the caret's line, under it
	line, _, x := caret_line(t, s, s.caret)
	scroll := scroll_offset(t, area)
	inner := input_inner(d)
	at := [2]f32{inner.x + area_text_x(s) - scroll.x + x - f32(c.prefix_len) * c.adv - th.space[.sm], inner.y - scroll.y + block_top(t, s, s.caret.block) + f32(line + 1) * s.line_h + 2}
	t.overlay_rules[pop] = {fixed = true, at = at}
	// sized to its widest row between the bounds: never the window's width
	set_layout(t, pop, Layout_Props{axis = .Column, align = .Stretch, padding = {th.space[.xs], th.space[.xs], th.space[.xs], th.space[.xs]}, min_w = 240, max_w = 460})
	first := 0
	if c.sel >= CODE_COMPLETE_MAX do first = c.sel - CODE_COMPLETE_MAX + 1
	for i := first; i < len(c.items) && i < first + CODE_COMPLETE_MAX; i += 1 {
		it := c.items[i]
		item, icreated := reconcile_child(ui, .Box, u64(i + 1), loc)
		id := node_get(t, item)
		if icreated do id.access.role = .List_Item
		set_name(t, item, it.label)
		id.tag = u64(100 + i)
		t.editor_ctl_of[item] = area
		picked := i == c.sel
		if picked { id.access.states += {.Selected} } else { id.access.states -= {.Selected} }
		set_layout(t, item, Layout_Props{axis = .Row, align = .Center, justify = .Space_Between, gap = th.space[.md], padding = {th.space[.xxs], th.space[.sm], th.space[.xxs], th.space[.xs]}})
		st := id.style
		st.radius = th.radius.sm
		st.bg = th.color.primary_container if picked else Color{}
		set_style(t, item, st)
		open_scope(ui, item, loc)
		lead := row(ui, gap = .sm, align = .Center, loc = loc)
		set_role(t, lead, .None)
		// a kind badge: one letter in the token's colour
		kind_col := code_token_color(th, it.kind)
		badge := box(ui, width = 18, height = 18, radius = th.radius.xs, bg = Color{kind_col.r, kind_col.g, kind_col.b, 0.22}, loc = loc)
		set_layout(t, badge, Layout_Props{axis = .Row, align = .Center, justify = .Center, width = 18, height = 18})
		open_scope(ui, badge, loc)
		bl := text(ui, code_kind_letter(it.kind), role = .Caption, color = kind_col, nowrap = true, loc = loc)
		set_role(t, bl, .None)
		close_scope(ui)
		col := th.color.on_primary_container if picked else th.color.on_surface
		lbl := text(ui, it.label, role = .Body, color = col, nowrap = true, ellipsis = .End, loc = loc)
		set_role(t, lbl, .None)
		end(ui)
		if len(it.detail) > 0 {
			dt := text(ui, it.detail, role = .Caption, muted = !picked, color = th.color.on_primary_container if picked else Color{}, nowrap = true, loc = loc)
			set_role(t, dt, .None)
		}
		close_scope(ui)
	}
	end(ui)
}

@(private)
code_kind_letter :: proc(k: Token_Kind) -> string {
	switch k {
	case .Keyword:   return "k"
	case .Type:      return "T"
	case .Ident:     return "v"
	case .Constant:  return "c"
	case .String:    return "s"
	case .Number:    return "n"
	case .Attribute: return "@"
	case .Plain, .Comment, .Operator, .Punct:
	}
	return "·"
}

// code_shift_lines indents (or outdents) blocks a..b as one undo group.
@(private)
code_shift_lines :: proc(ui: ^Ui($Msg), n: Node, s: ^Text_Area_State, a, b: int, outdent: bool) {
	t := &ui.tree
	if s.readonly do return
	unit := code_indent_unit(s)
	s.group += 1
	lo, hi := pos_order(s.caret, s.anchor)
	had_sel := lo != hi
	for blk in a ..= b {
		line := block_str(s.doc, blk)
		if outdent {
			remove := 0
			if strings.has_prefix(line, "\t") {
				remove = 1
			} else {
				for remove < s.code.tab_width && remove < len(line) && line[remove] == ' ' do remove += 1
			}
			if remove == 0 do continue
			document_replace(s.doc, {blk, 0}, {blk, remove}, "", s.group)
			if s.caret.block == blk do s.caret.off = max(s.caret.off - remove, 0)
			if s.anchor.block == blk do s.anchor.off = max(s.anchor.off - remove, 0)
		} else {
			if len(line) == 0 && a != b do continue // blank lines stay blank
			document_replace(s.doc, {blk, 0}, {blk, 0}, unit, s.group)
			if s.caret.block == blk do s.caret.off += len(unit)
			if s.anchor.block == blk do s.anchor.off += len(unit)
		}
	}
	if had_sel && a != b { // keep whole lines selected
		s.anchor = {a, 0}
		s.caret = {b + 1, 0} if b + 1 < len(s.doc.blocks) else Pos{b, len(s.doc.blocks[b].text)}
	}
	area_break_typing(s)
	mark_layout_dirty(t, n)
	area_touch(t, n, s)
	area_changed(ui, n, s)
}

// code_toggle_comment adds the language's line comment to blocks a..b, or
// removes it when every non-blank line already has one.
@(private)
code_toggle_comment :: proc(ui: ^Ui($Msg), n: Node, s: ^Text_Area_State, a, b: int) {
	t := &ui.tree
	lang := s.code.lang if s.code.lang != nil else &LANG_PLAIN
	if s.readonly || len(lang.line_comment) == 0 do return
	marker := lang.line_comment
	all := true
	any := false
	for blk in a ..= b {
		line := block_str(s.doc, blk)
		body := line[leading_ws(line):]
		if len(body) == 0 do continue
		any = true
		if !strings.has_prefix(body, marker) do all = false
	}
	if !any do return
	s.group += 1
	for blk in a ..= b {
		line := block_str(s.doc, blk)
		ws := leading_ws(line)
		body := line[ws:]
		if len(body) == 0 do continue
		if all {
			remove := len(marker)
			if len(body) > remove && body[remove] == ' ' do remove += 1
			document_replace(s.doc, {blk, ws}, {blk, ws + remove}, "", s.group)
			if s.caret.block == blk && s.caret.off > ws do s.caret.off = max(s.caret.off - remove, ws)
			if s.anchor.block == blk && s.anchor.off > ws do s.anchor.off = max(s.anchor.off - remove, ws)
		} else {
			ins := strings.concatenate({marker, " "}, context.temp_allocator)
			document_replace(s.doc, {blk, ws}, {blk, ws}, ins, s.group)
			if s.caret.block == blk && s.caret.off >= ws do s.caret.off += len(ins)
			if s.anchor.block == blk && s.anchor.off >= ws do s.anchor.off += len(ins)
		}
	}
	area_break_typing(s)
	mark_layout_dirty(t, n)
	area_touch(t, n, s)
	area_changed(ui, n, s)
}

// code_move_lines moves blocks a..b one line up (dir < 0) or down.
@(private)
code_move_lines :: proc(ui: ^Ui($Msg), n: Node, s: ^Text_Area_State, a, b: int, dir: int) {
	t := &ui.tree
	if s.readonly do return
	if dir < 0 && a == 0 do return
	if dir > 0 && b == len(s.doc.blocks) - 1 do return
	other := a - 1 if dir < 0 else b + 1
	lines := make([dynamic]string, context.temp_allocator)
	if dir < 0 {
		for blk in a ..= b do append(&lines, strings.clone(block_str(s.doc, blk), context.temp_allocator))
		append(&lines, strings.clone(block_str(s.doc, other), context.temp_allocator))
	} else {
		append(&lines, strings.clone(block_str(s.doc, other), context.temp_allocator))
		for blk in a ..= b do append(&lines, strings.clone(block_str(s.doc, blk), context.temp_allocator))
	}
	first, last := min(a, other), max(b, other)
	joined := strings.join(lines[:], "\n", context.temp_allocator)
	s.group += 1
	document_replace(s.doc, {first, 0}, {last, len(s.doc.blocks[last].text)}, joined, s.group)
	s.caret.block += dir
	s.anchor.block += dir
	s.caret = pos_clamp(s.doc, s.caret)
	s.anchor = pos_clamp(s.doc, s.anchor)
	area_break_typing(s)
	mark_layout_dirty(t, n)
	area_touch(t, n, s)
	area_changed(ui, n, s)
}
