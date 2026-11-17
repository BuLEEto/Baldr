package baldr

@(require) import "core:testing"
@(require) import "core:unicode/utf8"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(test)
document_edits_split_join_and_undo_in_groups :: proc(t: ^testing.T) {
	doc := document_make("hello\nworld")
	defer document_destroy(&doc)
	testing.expect_value(t, block_count(&doc), 2)
	testing.expect_value(t, block_str(&doc, 1), "world")
	// insert with a newline splits; the caret lands after the insertion
	p := document_replace(&doc, {0, 5}, {0, 5}, " big\nnew", group = 1)
	testing.expect_value(t, p, Pos{1, 3})
	testing.expect_value(t, block_count(&doc), 3)
	testing.expect_value(t, block_str(&doc, 0), "hello big")
	testing.expect_value(t, block_str(&doc, 1), "new")
	txt := document_text(&doc, context.temp_allocator)
	testing.expect_value(t, txt, "hello big\nnew\nworld")
	// deleting across blocks joins them
	p = document_replace(&doc, {0, 7}, {2, 2}, "", group = 2)
	testing.expect_value(t, p, Pos{0, 7})
	testing.expect_value(t, block_count(&doc), 1)
	testing.expect_value(t, block_str(&doc, 0), "hello brld")
	// undo restores group 2, then group 1 (both of its edits at once)
	c, ok := document_undo(&doc)
	testing.expect(t, ok)
	testing.expect_value(t, document_text(&doc, context.temp_allocator), "hello big\nnew\nworld")
	testing.expect_value(t, c, Pos{2, 2})
	c, ok = document_undo(&doc)
	testing.expect(t, ok)
	testing.expect_value(t, document_text(&doc, context.temp_allocator), "hello\nworld")
	testing.expect_value(t, c, Pos{0, 5})
	_, ok = document_undo(&doc)
	testing.expect(t, !ok, "nothing left to undo")
	c, ok = document_redo(&doc)
	testing.expect(t, ok)
	testing.expect_value(t, document_text(&doc, context.temp_allocator), "hello big\nnew\nworld")
	testing.expect_value(t, c, Pos{1, 3})
	// a new edit clears the redo stack
	document_replace(&doc, {0, 0}, {0, 0}, "X", group = 3)
	_, ok = document_redo(&doc)
	testing.expect(t, !ok)
	// movement across block boundaries
	testing.expect_value(t, pos_next_grapheme(&doc, {0, 10}), Pos{1, 0})
	testing.expect_value(t, pos_prev_grapheme(&doc, {1, 0}), Pos{0, 10})
	testing.expect_value(t, document_range_text(&doc, {0, 8}, {1, 2}, context.temp_allocator), "ig\nne")
}

Area_Fx :: struct {
	ui:  Ui(Ov_Msg),
	doc: Document,
	n:   Node,
}

@(private = "file")
fx_view :: proc(fx: ^Area_Fx, height: f32 = 0, max_lines := 0) {
	set_viewport(&fx.ui.tree, {400, 300})
	begin_view(&fx.ui)
	column(&fx.ui, padding = .lg)
	fx.n = text_area(&fx.ui, &fx.doc, placeholder = "Notes", label = "Notes", width = 200, height = height,
		on_change = proc(e: Ev(int)) -> Ov_Msg { return {kind = .Pick, i = e.value} })
	editor_options(&fx.ui, fx.n, max_lines = max_lines)
	end(&fx.ui)
	end_view(&fx.ui)
	frame(&fx.ui.tree, {400, 300})
}

@(private = "file")
fx_init :: proc(fx: ^Area_Fx, initial: string) {
	ui_init(&fx.ui)
	fx.doc = document_make(initial)
	fx_view(fx)
	set_focus(&fx.ui.tree, fx.n, true)
	frame(&fx.ui.tree, {400, 300})
}

@(private = "file")
fx_destroy :: proc(fx: ^Area_Fx) {
	ui_destroy(&fx.ui)
	document_destroy(&fx.doc)
}

@(private = "file")
fx_state :: proc(fx: ^Area_Fx) -> ^Text_Area_State {
	return &fx.ui.tree.areas[fx.n]
}

@(private = "file")
type_text :: proc(fx: ^Area_Fx, s: string) {
	for r in s {
		buf, n := utf8.encode_rune(r)
		text_area_text(&fx.ui, string(buf[:n]))
	}
}

@(test)
text_area_types_wraps_grows_and_navigates_lines :: proc(t: ^testing.T) {
	fx: Area_Fx
	fx_init(&fx, "")
	defer fx_destroy(&fx)
	s := fx_state(&fx)
	d := node_get(&fx.ui.tree, fx.n)
	testing.expect_value(t, d.access.role, Role.Text_Input)
	testing.expect_value(t, d.access.name, "Notes")
	lh := s.line_h
	pad := fx.ui.theme.space[.sm]
	testing.expect_value(t, d.abs.h, 3 * lh + 2 * pad) // min_lines = 3
	// the headless measure gives half the font size per rune
	per := int(s.wrap_w / (s.size * 0.5)) // runes per wrapped line
	testing.expect(t, per > 16 && per < 43, "the fixture wraps a 43-rune sentence into exactly two lines")
	type_text(&fx, "The quick brown fox jumps over the lazy dog") // 43 runes → 2 wrapped lines
	testing.expect_value(t, block_count(&fx.doc), 1)
	testing.expect_value(t, s.caret, Pos{0, 43})
	fx_view(&fx)
	spans := block_spans(&fx.ui.tree, s, 0)
	testing.expect_value(t, len(spans), 2)
	testing.expect_value(t, spans[0].end, per)
	text_area_key(&fx.ui, .Enter, {})
	type_text(&fx, "second paragraph")
	testing.expect_value(t, block_count(&fx.doc), 2)
	testing.expect_value(t, s.caret, Pos{1, 16})
	fx_view(&fx)
	testing.expect_value(t, node_get(&fx.ui.tree, fx.n).abs.h, 3 * lh + 2 * pad) // three wrapped lines still fit min_lines
	text_area_key(&fx.ui, .Enter, {})
	text_area_key(&fx.ui, .Enter, {})
	fx_view(&fx)
	testing.expect_value(t, node_get(&fx.ui.tree, fx.n).abs.h, 5 * lh + 2 * pad) // grew with the content
	testing.expect(t, len(fx.ui.msgs) > 0 && fx.ui.msgs[len(fx.ui.msgs) - 1].kind == .Pick, "on_change fired")
	// Up from the empty last block lands on the line above, Home/End are per wrapped line
	text_area_key(&fx.ui, .Up, {})
	testing.expect_value(t, s.caret, Pos{2, 0})
	text_area_key(&fx.ui, .Up, {})
	testing.expect_value(t, s.caret.block, 1)
	testing.expect_value(t, s.caret.off, 0)
	text_area_key(&fx.ui, .End, {})
	testing.expect_value(t, s.caret, Pos{1, 16})
	text_area_key(&fx.ui, .Up, {}) // into the second wrapped line of block 0, keeping x = 16 runes
	testing.expect_value(t, s.caret.block, 0)
	testing.expect_value(t, s.caret.off, per + 16)
	text_area_key(&fx.ui, .Up, {}) // first wrapped line, same x
	testing.expect_value(t, s.caret, Pos{0, 16})
	text_area_key(&fx.ui, .Home, {})
	testing.expect_value(t, s.caret, Pos{0, 0})
	text_area_key(&fx.ui, .End, {.Ctrl})
	testing.expect_value(t, s.caret, Pos{3, 0})
	// Backspace at a block start joins with the previous block
	text_area_key(&fx.ui, .Backspace, {})
	testing.expect_value(t, block_count(&fx.doc), 3)
	testing.expect_value(t, s.caret, Pos{2, 0})
	// Left across a block boundary
	text_area_key(&fx.ui, .Left, {})
	testing.expect_value(t, s.caret, Pos{1, 16})
	// select all, copy, cut, undo
	testing.expect(t, text_area_key(&fx.ui, .A, {.Ctrl}))
	lo, hi := pos_order(s.caret, s.anchor)
	testing.expect_value(t, lo, Pos{0, 0})
	testing.expect_value(t, hi, Pos{2, 0})
	text_area_key(&fx.ui, .Delete, {})
	testing.expect_value(t, document_text(&fx.doc, context.temp_allocator), "")
	testing.expect(t, text_area_key(&fx.ui, .Z, {.Ctrl}))
	testing.expect_value(t, document_text(&fx.doc, context.temp_allocator), "The quick brown fox jumps over the lazy dog\nsecond paragraph\n")
	testing.expect(t, text_area_key(&fx.ui, .Y, {.Ctrl}))
	testing.expect_value(t, document_text(&fx.doc, context.temp_allocator), "")
	testing.expect(t, text_area_key(&fx.ui, .Z, {.Ctrl}))
	// typing groups into one undo entry
	text_area_key(&fx.ui, .End, {.Ctrl})
	type_text(&fx, "abc")
	testing.expect(t, text_area_key(&fx.ui, .Z, {.Ctrl}))
	testing.expect_value(t, document_text(&fx.doc, context.temp_allocator), "The quick brown fox jumps over the lazy dog\nsecond paragraph\n")
	testing.expect(t, lint(&fx.ui.tree) == 0)
}

@(test)
text_area_pointer_places_caret_drags_and_scrolls :: proc(t: ^testing.T) {
	fx: Area_Fx
	fx_init(&fx, "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight")
	defer fx_destroy(&fx)
	fx_view(&fx, max_lines = 4)
	s := fx_state(&fx)
	d := node_get(&fx.ui.tree, fx.n)
	pad := fx.ui.theme.space[.sm]
	testing.expect_value(t, d.abs.h, 4 * s.line_h + 2 * pad) // capped: the rest scrolls
	st := fx.ui.tree.scrolls[fx.n]
	testing.expect_value(t, st.content.y, 8 * s.line_h)
	inner := input_inner(d)
	// click in the middle of "three" (row 2): just past 2 runes
	adv := s.size * 0.5
	p := [2]f32{inner.x + 2 * adv + 1, inner.y + 2 * s.line_h + 4}
	pointer_button(&fx.ui, .Left, true, p)
	testing.expect_value(t, s.caret, Pos{2, 2})
	// drag down one line extends the selection
	pointer_move(&fx.ui, {inner.x + adv, inner.y + 3 * s.line_h + 4})
	testing.expect_value(t, s.caret, Pos{3, 1})
	testing.expect_value(t, s.anchor, Pos{2, 2})
	pointer_button(&fx.ui, .Left, false, {inner.x + adv, inner.y + 3 * s.line_h + 4})
	testing.expect(t, !s.dragging)
	// double-click selects the word, triple-click the paragraph
	fx.ui.tree.now_ms, fx.ui.pointer.time_ms = 1000, 1000 // a pair is timed on the click
	pointer_button(&fx.ui, .Left, true, p)
	pointer_button(&fx.ui, .Left, false, p)
	fx.ui.tree.now_ms, fx.ui.pointer.time_ms = 1100, 1100 // a pair is timed on the click
	pointer_button(&fx.ui, .Left, true, p)
	pointer_button(&fx.ui, .Left, false, p)
	testing.expect_value(t, s.anchor, Pos{2, 0})
	testing.expect_value(t, s.caret, Pos{2, 5})
	fx.ui.tree.now_ms, fx.ui.pointer.time_ms = 1200, 1200 // a pair is timed on the click
	pointer_button(&fx.ui, .Left, true, p)
	pointer_button(&fx.ui, .Left, false, p)
	testing.expect_value(t, s.caret, Pos{2, 5})
	testing.expect_value(t, s.anchor, Pos{2, 0})
	// keyboard down past the visible lines scrolls the caret into view
	text_area_key(&fx.ui, .End, {.Ctrl})
	testing.expect(t, fx.ui.tree.scrolls[fx.n].offset.y >= 4 * s.line_h - 0.5, "scrolled so the last line is visible")
	text_area_key(&fx.ui, .Home, {.Ctrl})
	testing.expect_value(t, fx.ui.tree.scrolls[fx.n].offset.y, 0)
	// the wheel scrolls it too
	testing.expect(t, scroll_event(&fx.ui, p, {0, 48}))
	testing.expect_value(t, fx.ui.tree.scrolls[fx.n].offset.y, 48)
	// selection rectangles and the caret are painted
	fx_view(&fx, max_lines = 4)
	set_focus(&fx.ui.tree, fx.n, true)
	text_area_key(&fx.ui, .A, {.Ctrl})
	frame(&fx.ui.tree, {400, 300})
	sel_rects := 0
	band, _ := selection_pair(&fx.ui.tree.theme) // the band a selection draws (selection_paint.odin)
	for c in draw_list(&fx.ui.tree) do if r, ok := c.(Draw_Rect); ok && r.color == band do sel_rects += 1
	testing.expect(t, sel_rects >= 4, "one selection rect per line")
}

@(private = "file")
fx_view_opts :: proc(fx: ^Area_Fx, max_length := 0, readonly := false, invalid := false, wrap := true, marks: []Mark = nil) {
	set_viewport(&fx.ui.tree, {400, 300})
	begin_view(&fx.ui)
	column(&fx.ui, padding = .lg)
	fx.n = text_area(&fx.ui, &fx.doc, label = "Notes", width = 200,
		on_submit = proc(e: Ev(int)) -> Ov_Msg { return {kind = .Delete, i = e.value} })
	editor_options(&fx.ui, fx.n, max_length = max_length, readonly = readonly, wrap = wrap)
	set_invalid(&fx.ui.tree, fx.n, invalid)
	set_required(&fx.ui.tree, fx.n, invalid)
	editor_marks(&fx.ui, fx.n, marks)
	end(&fx.ui)
	end_view(&fx.ui)
	frame(&fx.ui.tree, {400, 300})
}

@(test)
text_area_limits_readonly_validation_submit_and_shift_click :: proc(t: ^testing.T) {
	fx: Area_Fx
	fx_init(&fx, "abc")
	defer fx_destroy(&fx)
	s := fx_state(&fx)
	// max_length caps typing and pasting at the limit (characters, block breaks included)
	fx_view_opts(&fx, max_length = 6)
	s = fx_state(&fx)
	set_focus(&fx.ui.tree, fx.n, true)
	text_area_key(&fx.ui, .End, {.Ctrl})
	type_text(&fx, "defgh")
	testing.expect_value(t, document_text(&fx.doc, context.temp_allocator), "abcdef")
	text_area_key(&fx.ui, .Enter, {})
	testing.expect_value(t, block_count(&fx.doc), 1) // no room for the break either
	text_area_key(&fx.ui, .Backspace, {})
	text_area_key(&fx.ui, .Enter, {})
	testing.expect_value(t, document_text(&fx.doc, context.temp_allocator), "abcde\n")
	// readonly: navigation and selection work, edits do not
	document_set_text(&fx.doc, "read only")
	fx_view_opts(&fx, readonly = true)
	s = fx_state(&fx) // a different call site built a different node
	set_focus(&fx.ui.tree, fx.n, true)
	testing.expect(t, .Readonly in node_get(&fx.ui.tree, fx.n).access.states)
	text_area_key(&fx.ui, .End, {.Ctrl})
	type_text(&fx, "X")
	text_area_key(&fx.ui, .Backspace, {})
	testing.expect_value(t, document_text(&fx.doc, context.temp_allocator), "read only")
	testing.expect(t, text_area_key(&fx.ui, .A, {.Ctrl}))
	lo, hi := pos_order(s.caret, s.anchor)
	testing.expect(t, lo == Pos{0, 0} && hi == Pos{0, 9})
	// invalid + required: states and a danger border
	fx_view_opts(&fx, invalid = true)
	d := node_get(&fx.ui.tree, fx.n)
	testing.expect(t, .Invalid in d.access.states && .Required in d.access.states)
	danger_border := false
	for c in draw_list(&fx.ui.tree) do if r, ok := c.(Draw_Rect); ok && r.border_w == 1 && r.border == fx.ui.theme.color.danger do danger_border = true
	testing.expect(t, danger_border)
	// Ctrl+Enter submits with the version, Enter alone inserts a break
	fx_view_opts(&fx)
	s = fx_state(&fx)
	set_focus(&fx.ui.tree, fx.n, true)
	before := len(fx.ui.msgs)
	testing.expect(t, text_area_key(&fx.ui, .Enter, {.Ctrl}))
	testing.expect_value(t, fx.ui.msgs[before].kind, Ov_Kind.Delete)
	testing.expect_value(t, block_count(&fx.doc), 1)
	// Shift-click extends from the anchor
	d = node_get(&fx.ui.tree, fx.n)
	inner := input_inner(d)
	adv := s.size * 0.5
	text_area_key(&fx.ui, .Home, {.Ctrl})
	fx.ui.pointer.mods = {.Shift}
	p := [2]f32{inner.x + 4 * adv + 1, inner.y + 4}
	pointer_button(&fx.ui, .Left, true, p)
	pointer_button(&fx.ui, .Left, false, p)
	fx.ui.pointer.mods = {}
	testing.expect_value(t, s.anchor, Pos{0, 0})
	testing.expect_value(t, s.caret, Pos{0, 4})
}

@(test)
text_area_marks_and_no_wrap_scroll :: proc(t: ^testing.T) {
	fx: Area_Fx
	fx_init(&fx, "teh quick brown fox\nrecieve the parcel")
	defer fx_destroy(&fx)
	marks := []Mark{{from = {0, 0}, to = {0, 3}, kind = .Error}, {from = {1, 0}, to = {1, 7}, kind = .Warning}, {from = {0, 10}, to = {0, 15}, kind = .Highlight}, {from = {1, 8}, to = {1, 11}, kind = .Info}}
	fx_view_opts(&fx, marks = marks)
	s := fx_state(&fx)
	_ = s
	adv := s.size * 0.5
	squiggle, highlight, underline := 0, 0, 0
	for c in draw_list(&fx.ui.tree) {
		#partial switch v in c {
		case Draw_Wave:
			if v.color == fx.ui.theme.color.danger do testing.expect_value(t, v.width, 3 * adv)
			if v.color == fx.ui.theme.color.warning do testing.expect_value(t, v.width, 7 * adv)
			squiggle += 1
		case Draw_Rect:
			switch {
			case v.rect.h == s.line_h && v.color.a < 0.5 && v.color.a > 0.2: highlight += 1
			case v.rect.h == 1 && v.color == fx.ui.theme.color.primary:   underline += 1
			}
		}
	}
	testing.expect_value(t, squiggle, 2) // one wave per misspelling
	testing.expect_value(t, highlight, 1)
	testing.expect_value(t, underline, 1)
	testing.expect_value(t, len(s.marks), 4)
	// no-wrap: one span per block, content wider than the box, caret-into-view scrolls sideways
	document_set_text(&fx.doc, "a very long line of text that is much wider than two hundred pixels of box")
	fx_view_opts(&fx, wrap = false)
	s = fx_state(&fx)
	d := node_get(&fx.ui.tree, fx.n)
	testing.expect(t, .Scroll_H in d.flags)
	spans := block_spans(&fx.ui.tree, s, 0)
	testing.expect_value(t, len(spans), 1)
	st := fx.ui.tree.scrolls[fx.n]
	testing.expect(t, st.content.x > st.viewport.x, "content overflows sideways")
	set_focus(&fx.ui.tree, fx.n, true)
	text_area_key(&fx.ui, .End, {.Ctrl})
	testing.expect(t, fx.ui.tree.scrolls[fx.n].offset.x > 0, "scrolled to keep the caret visible")
	text_area_key(&fx.ui, .Home, {.Ctrl})
	testing.expect_value(t, fx.ui.tree.scrolls[fx.n].offset.x, 0)
	// Shift+wheel scrolls it sideways
	inner := input_inner(d)
	testing.expect(t, scroll_event(&fx.ui, {inner.x + 10, inner.y + 5}, {40, 0}))
	testing.expect_value(t, fx.ui.tree.scrolls[fx.n].offset.x, 40)
}


// A space typed into an editor through the run loop's path: the key first,
// then the text it typed. The focus handler sees Space before the text
// arrives, so the two must be tried together, not the text alone.
@(test)
a_space_typed_into_an_editor_lands :: proc(t: ^testing.T) {
	fx: Area_Fx
	fx_init(&fx, "ab")
	defer fx_destroy(&fx)
	st := fx_state(&fx)
	st.caret, st.anchor = Pos{0, 2}, Pos{0, 2}

	// the run loop's order for one keystroke
	key_event(&fx.ui, .Space, true, {})
	text_area_text(&fx.ui, " ")
	key_event(&fx.ui, .Space, false, {})
	for r in "cd" {
		buf, n := utf8.encode_rune(r)
		key_event(&fx.ui, .C if r == 'c' else .D, true, {})
		text_area_text(&fx.ui, string(buf[:n]))
		key_event(&fx.ui, .C if r == 'c' else .D, false, {})
	}
	testing.expect_value(t, document_text(&fx.doc, context.temp_allocator), "ab cd")
}

} // when ODIN_TEST