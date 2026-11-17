package baldr

// markdown_editor is the live-preview markdown editor: the Document holds
// markdown source, one line per block, and every block is shown rendered —
// headings, lists, quotes, code, marks applied — except the ones the
// selection touches, which show their source with the marks dimmed so they
// can be edited in place. Editing is plain text editing of the source, with
// the text area's keys; on top:
// Enter continues a list, quote or task prefix (an empty item ends it),
// Tab / Shift+Tab nest list items, Ctrl+B / I / E wrap or unwrap the
// selection in **, * and `, Ctrl+K makes a link, a click on a rendered
// task's box ticks it, Ctrl+click on a link sends `on_link`. Save the
// source as it is; it is the markdown. Accessibility: Text_Input named
// `label` with the source as its value.
//
//	baldr.markdown_editor(ui, &s.notes, on_change = …, label = "Notes", flex = 1)

import "core:strings"

markdown_editor :: proc(ui: ^Ui($Msg), doc: ^Document, on_change: Handler(Msg, int) = nil, label: string = "Markdown",
	placeholder: string = "", width: f32 = 0, height: f32 = 0, flex: f32 = 0, on_link: Handler(Msg, string) = nil,
	on_context: Handler(Msg, Editor_Context) = nil, disabled := false, focus := false, tag: u64 = 0, key: u64 = 0, loc := #caller_location) -> Node {
	t := &ui.tree
	n := area_build(ui, doc, placeholder, on_change, nil, on_context, label, width, height, flex, disabled, tag, key, loc, focus = focus,
		mono = false, def_wrap = true, def_min_lines = 6)
	s := &t.areas[n]
	if !s.live {
		s.rich = true // the rich painter draws the rendered lines
		s.live = true
		s.rich_state.toolbar = false
		s.tops_valid = false
		if s.rich_state.numbers == nil do s.rich_state.numbers = make([dynamic]u8, t.allocator)
		if s.rich_state.link_text.buf == nil do s.rich_state.link_text = text_make("", t.allocator)
		s.live_lo, s.live_hi = -1, -1
		mark_layout_dirty(t, n)
	}
	ui.on_link[n] = on_link
	return n
}

// live_numbered_index numbers a rendered numbered item among its
// neighbours of the same depth (nested items of any list kind between
// them do not break the count).
@(private)
live_numbered_index :: proc(t: ^Tree, s: ^Text_Area_State, b: int) -> int {
	m := area_meta(t, s, b)
	num := 1
	for k := b - 1; k >= 0; k -= 1 {
		pm := area_meta(t, s, k)
		listy := pm.kind == .Bullet || pm.kind == .Numbered || pm.kind == .Task
		if !listy do break
		if pm.depth > m.depth do continue
		if pm.kind != .Numbered || pm.depth < m.depth do break
		num += 1
	}
	return num
}

// live_prefix is a line's list / quote prefix ("- ", "1. ", "- [ ] ", "> "
// with its indent) and what the next line should start with.
@(private)
live_prefix :: proc(line: string) -> (prefix, next: string, is_list: bool) {
	ml := markdown_line(line)
	switch ml.meta.kind {
	case .Bullet:
		prefix = line[:ml.body]
		next = strings.concatenate({strings.repeat(" ", int(ml.meta.depth) * 2, context.temp_allocator), line[int(ml.meta.depth) * 2:ml.body]}, context.temp_allocator)
		return prefix, next, true
	case .Task:
		prefix = line[:ml.body]
		next = strings.concatenate({strings.repeat(" ", int(ml.meta.depth) * 2, context.temp_allocator), "- [ ] "}, context.temp_allocator)
		return prefix, next, true
	case .Numbered:
		prefix = line[:ml.body]
		trimmed := strings.trim_left(line, " ")
		n := 0
		for n < len(trimmed) && trimmed[n] >= '0' && trimmed[n] <= '9' do n += 1
		num := 0
		for c in trimmed[:n] do num = num * 10 + int(c - '0')
		buf: [24]u8
		next = strings.concatenate({strings.repeat(" ", int(ml.meta.depth) * 2, context.temp_allocator), strings.clone(strconv_itoa(buf[:], num + 1), context.temp_allocator), ". "}, context.temp_allocator)
		return prefix, next, true
	case .Quote:
		prefix = line[:ml.body]
		return prefix, "> ", false
	case .Paragraph, .Heading, .Code, .Rule, .Image, .Table, .Table_Sep:
	}
	return "", "", false
}

@(private)
strconv_itoa :: proc(buf: []u8, v: int) -> string {
	i := len(buf)
	v := v
	if v == 0 {
		i -= 1
		buf[i] = '0'
	}
	for v > 0 {
		i -= 1
		buf[i] = u8('0' + v % 10)
		v /= 10
	}
	return string(buf[i:])
}

// live_key: the source-level shortcuts of the live editor.
@(private)
live_key :: proc(ui: ^Ui($Msg), n: Node, s: ^Text_Area_State, key: Key, mods: Mods) -> bool {
	ctrl, shift := .Ctrl in mods, .Shift in mods
	lo, hi := pos_order(s.caret, s.anchor)
	line := block_str(s.doc, lo.block)
	in_fence := area_live_fences(s)[lo.block] // inside a code block the source is plain text
	ml := markdown_line(line)
	#partial switch key {
	case .Enter:
		if ctrl || s.readonly || lo != hi || in_fence do return false
		if ml.meta.kind == .Table { // Enter in a row: a new empty row under it; Shift+Enter or an empty row leaves the table
			if shift do return false // a plain new line
			if table_row_empty(line) {
				area_replace(ui, n, s, {lo.block, 0}, {lo.block, len(line)}, "")
				return true
			}
			end := Pos{lo.block, len(line)}
			area_replace(ui, n, s, end, end, strings.concatenate({"\n", table_empty_row(len(table_cells(line)))}, context.temp_allocator))
			s.caret.off, s.anchor.off = 2, 2
			area_touch(&ui.tree, n, s)
			return true
		}
		prefix, next, is_list := live_prefix(line)
		if len(prefix) == 0 || lo.off < len(prefix) do return false
		if len(line) == len(prefix) { // an empty item or quote line ends the run
			area_replace(ui, n, s, {lo.block, 0}, {lo.block, len(line)}, "")
			return true
		}
		_ = is_list
		area_replace(ui, n, s, lo, hi, strings.concatenate({"\n", next}, context.temp_allocator))
		return true
	case .Tab:
		if ctrl || s.readonly || in_fence do return false
		if ml.meta.kind == .Table { // the next / previous cell
			cells := table_cells(line)
			i := table_cell_at(line, lo.off) + (-1 if shift else 1)
			if i >= 0 && i < len(cells) {
				s.anchor, s.caret = {lo.block, cells[i][0]}, {lo.block, cells[i][1]}
				area_touch(&ui.tree, n, s)
			} else if !shift {
				area_replace(ui, n, s, {lo.block, len(line)}, {lo.block, len(line)}, strings.concatenate({"\n", table_empty_row(len(cells))}, context.temp_allocator))
				s.caret.off, s.anchor.off = 2, 2
				area_touch(&ui.tree, n, s)
			}
			return true
		}
		_, _, is_list := live_prefix(line)
		if !is_list do return false
		s.group += 1
		for b in lo.block ..= hi.block {
			l := block_str(s.doc, b)
			if _, _, listy := live_prefix(l); !listy do continue
			if shift {
				if strings.has_prefix(l, "  ") {
					document_replace(s.doc, {b, 0}, {b, 2}, "", s.group)
					if s.caret.block == b do s.caret.off = max(s.caret.off - 2, 0)
					if s.anchor.block == b do s.anchor.off = max(s.anchor.off - 2, 0)
				}
			} else {
				document_replace(s.doc, {b, 0}, {b, 0}, "  ", s.group)
				if s.caret.block == b do s.caret.off += 2
				if s.anchor.block == b do s.anchor.off += 2
			}
		}
		live_changed(ui, n, s)
		return true
	case .B:
		if !ctrl do return false
		live_wrap(ui, n, s, "**", "**")
		return true
	case .I:
		if !ctrl do return false
		live_wrap(ui, n, s, "*", "*")
		return true
	case .E:
		if !ctrl do return false
		live_wrap(ui, n, s, "`", "`")
		return true
	case .K:
		if !ctrl || s.readonly do return false
		if lo == hi {
			w0, w1 := word_at(line, lo.off)
			lo, hi = {lo.block, w0}, {lo.block, w1}
		}
		if lo.block != hi.block do return true
		label := block_str(s.doc, lo.block)[lo.off:hi.off]
		s.group += 1
		document_replace(s.doc, lo, hi, strings.concatenate({"[", label, "](url)"}, context.temp_allocator), s.group)
		// select "url" so typing replaces it
		s.anchor = {lo.block, lo.off + len(label) + 3}
		s.caret = {lo.block, lo.off + len(label) + 6}
		live_changed(ui, n, s)
		return true
	}
	return false
}

// live_wrap puts `open` … `close` around the selection (the word at the
// caret), or takes them off when they are already there.
@(private)
live_wrap :: proc(ui: ^Ui($Msg), n: Node, s: ^Text_Area_State, open, close: string) {
	if s.readonly do return
	lo, hi := pos_order(s.caret, s.anchor)
	line := block_str(s.doc, lo.block)
	if lo == hi {
		w0, w1 := word_at(line, lo.off)
		lo, hi = {lo.block, w0}, {lo.block, w1}
	}
	if lo.block != hi.block do return
	s.group += 1
	inner := strings.clone(line[lo.off:hi.off], context.temp_allocator) // the block's buffer moves under the replace
	if strings.has_prefix(inner, open) && strings.has_suffix(inner, close) && len(inner) >= len(open) + len(close) {
		document_replace(s.doc, lo, hi, inner[len(open):len(inner) - len(close)], s.group)
		s.anchor, s.caret = lo, {lo.block, hi.off - len(open) - len(close)}
	} else if lo.off >= len(open) && hi.off + len(close) <= len(line) && line[lo.off - len(open):lo.off] == open && line[hi.off:hi.off + len(close)] == close {
		document_replace(s.doc, {lo.block, lo.off - len(open)}, {lo.block, hi.off + len(close)}, inner, s.group)
		s.anchor, s.caret = {lo.block, lo.off - len(open)}, {lo.block, hi.off - len(open)}
	} else {
		document_replace(s.doc, lo, hi, strings.concatenate({open, inner, close}, context.temp_allocator), s.group)
		s.anchor, s.caret = {lo.block, lo.off + len(open)}, {lo.block, hi.off + len(open)}
	}
	live_changed(ui, n, s)
}

@(private)
live_changed :: proc(ui: ^Ui($Msg), n: Node, s: ^Text_Area_State) {
	t := &ui.tree
	area_break_typing(s)
	s.goal_x = -1
	mark_layout_dirty(t, n)
	area_touch(t, n, s)
	area_changed(ui, n, s)
}

// live_press: a click on a rendered task's box flips it in the source;
// Ctrl+click on a link follows it.
@(private)
live_press :: proc(ui: ^Ui($Msg), n: Node, d: ^Node_Data, s: ^Text_Area_State, pos: [2]f32) -> bool {
	t := &ui.tree
	inner := input_inner(d)
	scroll := scroll_offset(t, n)
	y := pos.y - inner.y + scroll.y
	b := block_at_y(t, s, y)
	meta := area_meta(t, s, b)
	x := pos.x - inner.x + scroll.x
	if meta.kind == .Task && x < block_indent(t, s, b) && !s.readonly {
		line := block_str(s.doc, b)
		ml := markdown_line(line)
		box := ml.body - 3 // the character inside "[ ]"
		if box >= 0 && box < len(line) {
			s.group += 1
			document_replace(s.doc, {b, box}, {b, box + 1}, " " if meta.checked else "x", s.group)
			live_changed(ui, n, s)
			return true
		}
	}
	if .Ctrl in ui.pointer.mods {
		p := area_hit(t, n, d, s, pos)
		disp := to_disp(t, s, b, p.off)
		for r in area_runs_plain(t, s, b) { // as shown: a line past its limit is source, with no links
			if disp >= r.end do continue
			// the run under the click, and only that one
			if .Link in r.attrs && len(r.href) > 0 {
				if h, has := ui.on_link[n]; has do handler_send(ui, h, r.href, n)
				return true
			}
			break
		}
	}
	return false
}

// ------------------------------------------------------------ actions

// live_act performs a formatting action on a markdown editor by editing its
// source, as the editor's own shortcuts do. What rich_apply sends here;
// every action is one undo step.
@(private)
live_act :: proc(ui: ^Ui($Msg), n: Node, s: ^Text_Area_State, action: Rich_Action) {
	t := &ui.tree
	if s.readonly do return
	_, hi := pos_order(s.caret, s.anchor)
	switch action {
	case .None, .Link_Apply, .Link_Remove, .Link_Close, .Image_Apply: // no bar in a markdown editor: nothing to apply or close
	case .Bold:      live_wrap(ui, n, s, "**", "**")
	case .Italic:    live_wrap(ui, n, s, "*", "*")
	case .Underline: live_wrap(ui, n, s, "<u>", "</u>")
	case .Strike:    live_wrap(ui, n, s, "~~", "~~")
	case .Code:      live_wrap(ui, n, s, "`", "`")
	case .Highlight: live_wrap(ui, n, s, "==", "==")
	case .Link:      live_link(ui, n, s, image = false)
	case .Image:     live_link(ui, n, s, image = true)
	case .H1:        live_prefix_set(ui, n, s, {kind = .Heading, level = 1})
	case .H2:        live_prefix_set(ui, n, s, {kind = .Heading, level = 2})
	case .H3:        live_prefix_set(ui, n, s, {kind = .Heading, level = 3})
	case .Paragraph: live_prefix_set(ui, n, s, {kind = .Paragraph})
	case .Bullet:    live_prefix_set(ui, n, s, {kind = .Bullet}, toggle = true)
	case .Numbered:  live_prefix_set(ui, n, s, {kind = .Numbered}, toggle = true)
	case .Task:      live_prefix_set(ui, n, s, {kind = .Task}, toggle = true)
	case .Quote:     live_prefix_set(ui, n, s, {kind = .Quote}, toggle = true)
	case .Code_Block: live_fence(ui, n, s)
	case .Rule:
		// a rule under the caret's line, with a blank line each side and the caret in the last
		end := Pos{hi.block, len(block_str(s.doc, hi.block))}
		s.group += 1
		p := document_replace(s.doc, end, end, "\n\n---\n", s.group)
		s.anchor, s.caret = p, p
		live_changed(ui, n, s)
	case .Table:
		end := Pos{hi.block, len(block_str(s.doc, hi.block))}
		s.group += 1
		document_replace(s.doc, end, end, "\n\n| Column | Column |\n|---|---|\n|  |  |", s.group)
		s.anchor, s.caret = Pos{hi.block + 2, 2}, Pos{hi.block + 2, 8} // the first heading cell, selected
		live_changed(ui, n, s)
	case .Undo:
		if p, did := document_undo(s.doc); did do area_after_history(ui, n, s, p)
	case .Redo:
		if p, did := document_redo(s.doc); did do area_after_history(ui, n, s, p)
	}
	_ = t
}

// live_link wraps the selection (or the word at the caret) in a markdown
// link or image, with the address selected so typing replaces it.
@(private)
live_link :: proc(ui: ^Ui($Msg), n: Node, s: ^Text_Area_State, image: bool) {
	lo, hi := pos_order(s.caret, s.anchor)
	line := block_str(s.doc, lo.block)
	if lo == hi {
		w0, w1 := word_at(line, lo.off)
		lo, hi = {lo.block, w0}, {lo.block, w1}
	}
	if lo.block != hi.block do return
	label := strings.clone(line[lo.off:hi.off], context.temp_allocator)
	open := "![" if image else "["
	s.group += 1
	document_replace(s.doc, lo, hi, strings.concatenate({open, label, "](url)"}, context.temp_allocator), s.group)
	at := lo.off + len(open) + len(label) + 2
	s.anchor, s.caret = Pos{lo.block, at}, Pos{lo.block, at + 3} // "url"
	live_changed(ui, n, s)
}

// live_prefix_set gives every selected line the block prefix of `meta`
// ("## ", "- ", "1. ", "- [ ] ", "> ") or takes it off again (`toggle`, or
// asking for what a line already is). Lines inside a code block are left
// as they are, and the selection follows its text.
@(private)
live_prefix_set :: proc(ui: ^Ui($Msg), n: Node, s: ^Text_Area_State, meta: Block_Meta, toggle := false) {
	lo, hi := pos_order(s.caret, s.anchor)
	fences := area_live_fences(s)
	same := true // every line is already what was asked for: the action takes it off
	any := false
	for b in lo.block ..= hi.block {
		ml := markdown_line(block_str(s.doc, b))
		if fences[b] || ml.fence do continue // a code block's lines, fences and all, keep their source
		any = true
		if ml.meta.kind != meta.kind || (meta.kind == .Heading && ml.meta.level != meta.level) do same = false
	}
	if !any do return
	off := (toggle || meta.kind == .Heading) && same // Paragraph is never a toggle: it always clears
	num := live_number_before(s, lo.block)
	s.group += 1
	for b in lo.block ..= hi.block {
		line := block_str(s.doc, b)
		ml := markdown_line(line)
		if fences[b] || ml.fence do continue
		indent := line[:len(line) - len(strings.trim_left(line, " "))]
		want := strings.clone(indent, context.temp_allocator)
		if !off {
			switch meta.kind {
			case .Heading:
				want = strings.concatenate({indent, strings.repeat("#", clamp(int(meta.level), 1, 6), context.temp_allocator), " "}, context.temp_allocator)
			case .Bullet:
				want = strings.concatenate({indent, "- "}, context.temp_allocator)
			case .Task:
				want = strings.concatenate({indent, "- [x] " if ml.meta.checked else "- [ ] "}, context.temp_allocator)
			case .Numbered:
				num += 1
				buf: [24]u8
				want = strings.concatenate({indent, strings.clone(strconv_itoa(buf[:], num), context.temp_allocator), ". "}, context.temp_allocator)
			case .Quote:
				want = strings.concatenate({indent, "> "}, context.temp_allocator)
			case .Paragraph, .Code, .Rule, .Image, .Table, .Table_Sep:
			}
		}
		body := ml.body if ml.meta.kind != .Paragraph else len(indent)
		if want == line[:body] do continue
		document_replace(s.doc, {b, 0}, {b, body}, want, s.group)
		delta := len(want) - body
		if s.caret.block == b do s.caret.off = max(s.caret.off + delta, len(want))
		if s.anchor.block == b do s.anchor.off = max(s.anchor.off + delta, len(want))
	}
	live_changed(ui, n, s)
}

// live_number_before is the number of the numbered item above `b`, so a
// list carries on counting (0 when there is none).
@(private)
live_number_before :: proc(s: ^Text_Area_State, b: int) -> int {
	if b == 0 do return 0
	line := strings.trim_left(block_str(s.doc, b - 1), " ")
	if markdown_line(line).meta.kind != .Numbered do return 0
	num := 0
	for i := 0; i < len(line) && line[i] >= '0' && line[i] <= '9'; i += 1 do num = num * 10 + int(line[i] - '0')
	return num
}

// live_fence puts ``` lines around the selected lines, or takes away the
// fences of the code block the caret is in.
@(private)
live_fence :: proc(ui: ^Ui($Msg), n: Node, s: ^Text_Area_State) {
	lo, hi := pos_order(s.caret, s.anchor)
	fences := area_live_fences(s)
	s.group += 1
	if fences[lo.block] || markdown_line(block_str(s.doc, lo.block)).fence { // inside a block: unfence it
		open := lo.block
		for open > 0 && !(markdown_line(block_str(s.doc, open)).fence && !fences[open]) do open -= 1
		close := open + 1
		for close < len(s.doc.blocks) && !markdown_line(block_str(s.doc, close)).fence do close += 1
		if close < len(s.doc.blocks) do document_replace(s.doc, {close - 1, len(block_str(s.doc, close - 1))}, {close, len(block_str(s.doc, close))}, "", s.group)
		if open + 1 < len(s.doc.blocks) do document_replace(s.doc, {open, 0}, {open + 1, 0}, "", s.group)
		s.caret.block = max(s.caret.block - 1, 0)
		s.anchor.block = max(s.anchor.block - 1, 0)
	} else {
		end := Pos{hi.block, len(block_str(s.doc, hi.block))}
		document_replace(s.doc, end, end, "\n```", s.group)
		document_replace(s.doc, {lo.block, 0}, {lo.block, 0}, "```\n", s.group)
		s.caret.block += 1
		s.anchor.block += 1
	}
	s.caret = pos_clamp(s.doc, s.caret)
	s.anchor = pos_clamp(s.doc, s.anchor)
	live_changed(ui, n, s)
}
