package baldr

@(require) import "core:testing"
@(require) import "baldr:gpu"
@(require) import runa "baldr:third_party/runa"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them. ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh
// check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Space for Quick Look on a view, and control characters inside text.


@(private = "file")
RequestsStep6_QMsg :: enum { None, Open, Close, Look, Pick }

@(private = "file")
node_named :: proc(t: ^Tree, root: Node, name: string) -> Node {
	d := node_get(t, root)
	if d == nil do return NODE_NONE
	if d.access.name == name do return root
	for c := d.first; c != NODE_NONE; c = node_get(t, c).next {
		if found := node_named(t, c, name); found != NODE_NONE do return found
	}
	return NODE_NONE
}

@(private = "file")
Views :: struct { tbl, icons, tree: Node }

@(private = "file")
space_views :: proc(ui: ^Ui(RequestsStep6_QMsg), sa, sb: ^Selection, bind: bool) -> (v: Views) {
	set_viewport(&ui.tree, {800, 600})
	begin_view(ui)
	column(ui, gap = .sm, flex = 1)
	if bind do shortcut(ui, "Space", RequestsStep6_QMsg.Look)
	cols := []Column{{title = "Name"}}
	first, last := table(ui, cols, 3, sa, label = "Files", key = 1)
	for i in first ..< last {
		table_row(ui, i)
		cell_text(ui, "a")
		end(ui)
	}
	f2, l2 := icon_view(ui, 3, sb, label = "Icons", key = 2)
	for i in f2 ..< l2 do icon_item(ui, i, .None, "b")
	v.tree = tree_view(ui, label = "Places", key = 3)
	tree_item(ui, "Home", RequestsStep6_QMsg.Pick)
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {800, 600})
	for n in ui.tree.tables do v.tbl = n
	for n in ui.tree.icon_views do v.icons = n
	return
}

@(test)
an_app_space_binding_wins_over_a_views_space :: proc(t: ^testing.T) {
	ui: Ui(RequestsStep6_QMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sa := selection_make(multi = true)
	defer selection_destroy(&sa)
	sb := selection_make(multi = true)
	defer selection_destroy(&sb)
	press :: proc(ui: ^Ui(RequestsStep6_QMsg), key: Key, mods: Mods) -> bool {
		return key_event(ui, key, true, mods) || shortcut_fire(ui, key, true, mods) // the run loop's order
	}
	v := space_views(&ui, &sa, &sb, true)
	for view, i in ([]Node{v.tbl, v.icons}) {
		sel := &sa if i == 0 else &sb
		selection_set(sel, 1)
		set_focus(&ui.tree, view, true)
		clear(&ui.msgs)
		testing.expect(t, press(&ui, .Space, {}))
		testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == .Look, "Space is the app's: Quick Look")
		testing.expect(t, selection_contains(sel, 1), "and the selection stays")
		press(&ui, .Space, {.Ctrl})
		testing.expect(t, !selection_contains(sel, 1), "Ctrl+Space still toggles")
	}
	set_focus(&ui.tree, v.tree, true)
	tree_set_cursor(&ui.tree, v.tree, node_named(&ui.tree, v.tree, "Home"))
	clear(&ui.msgs)
	press(&ui, .Space, {})
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == .Look, "the tree's Space yields the same way")

	space_views(&ui, &sa, &sb, false) // no binding: Space is the views' again
	set_focus(&ui.tree, v.tbl, true)
	selection_set(&sa, 1)
	clear(&ui.msgs)
	testing.expect(t, press(&ui, .Space, {}))
	testing.expect(t, !selection_contains(&sa, 1) && len(ui.msgs) == 0, "Space toggles the row")
	press(&ui, .Space, {})
	testing.expect(t, selection_contains(&sa, 1))
}

@(private = "file")
Ql :: struct { open, ready, other_close: bool }

@(private = "file")
ql_view :: proc(ui: ^Ui(RequestsStep6_QMsg), s: ^Ql) -> (look: Node) {
	set_viewport(&ui.tree, {800, 600})
	begin_view(ui)
	column(ui, padding = .lg, gap = .sm)
	shortcut(ui, "Space", RequestsStep6_QMsg.Open)
	look = button(ui, "Quick Look", RequestsStep6_QMsg.Open, variant = .Ghost, icon = .Maximize_2, icon_only = true)
	tooltip(ui, look, "Quick Look (Space)")
	if dialog(ui, s.open, RequestsStep6_QMsg.Close, title = "notes.txt", width = 500) {
		if s.ready { // the large picture decoded
			box(ui, width = 400, height = 200)
		} else { // the thumbnail while it decodes
			column(ui, gap = .xs)
			spinner(ui, size = 14, label = "Loading")
			text(ui, "line one\nline two")
			end(ui)
		}
		row(ui, gap = .sm)
		button(ui, "Open", RequestsStep6_QMsg.None, variant = .Outline)
		spacer(ui)
		if s.other_close { // another builder's Close: a node of its own
			button(ui, "Close", RequestsStep6_QMsg.Close, default = true)
		} else {
			button(ui, "Close", RequestsStep6_QMsg.Close, variant = .Primary, default = true)
		}
		end(ui)
		end(ui)
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {800, 600})
	return
}

@(private = "file")
ql_deliver :: proc(ui: ^Ui(RequestsStep6_QMsg), s: ^Ql) {
	for m in ui.msgs {
		#partial switch m {
		case .Open:  s.open = true
		case .Close: s.open = false
		}
	}
	clear(&ui.msgs)
}

// A dialog opened by a click on a button showing its tooltip focuses its
// default button, and Space on that Close closes it.
@(test)
a_pointer_opened_dialog_focuses_its_default_button :: proc(t: ^testing.T) {
	ui: Ui(RequestsStep6_QMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	s: Ql
	look := ql_view(&ui, &s)
	ld := node_get(&ui.tree, look)
	at := [2]f32{ld.abs.x + ld.abs.w / 2, ld.abs.y + ld.abs.h / 2}
	now := 1000.0
	pointer_move(&ui, at)
	ui_tick(&ui, now)
	now += TOOLTIP_DELAY_MS + 50
	ui_tick(&ui, now)
	look = ql_view(&ui, &s)
	testing.expect_value(t, ui.tip_anchor, look) // the tooltip is up
	pointer_button(&ui, .Left, true, at)
	pointer_button(&ui, .Left, false, at)
	ui_tick(&ui, now)
	ql_deliver(&ui, &s)
	testing.expect(t, s.open)
	ql_view(&ui, &s)
	close := node_named(&ui.tree, ui.tree.overlay, "Close")
	testing.expect(t, close != NODE_NONE)
	testing.expect_value(t, ui.tree.focus, close)
	for _ in 0 ..< 30 { // the tooltip fades, the dialog scales in
		now += 16
		ui_tick(&ui, now)
		ql_view(&ui, &s)
	}
	testing.expect_value(t, ui.tree.focus, close)
	s.ready = true // Ql_Ready: the content above the buttons changes
	for _ in 0 ..< 5 {
		now += 16
		ui_tick(&ui, now)
		ql_view(&ui, &s)
	}
	testing.expect(t, node_named(&ui.tree, ui.tree.overlay, "Close") == close, "the button row kept its nodes")
	testing.expectf(t, ui.tree.focus == close, "focus stays on Close once the picture arrives (focus %v, Close %v)", ui.tree.focus, close)
	s.other_close = true // the focused button itself is replaced
	ql_view(&ui, &s)
	close2 := node_named(&ui.tree, ui.tree.overlay, "Close")
	testing.expect(t, close2 != close && close2 != NODE_NONE)
	testing.expect_value(t, ui.tree.focus, close2) // focus stays inside the dialog, on its default
	clear(&ui.msgs)
	testing.expect(t, key_event(&ui, .Space, true, {}) || shortcut_fire(&ui, .Space, true, {}))
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == .Close, "Space on the default Close closes")
}

@(test)
control_characters_in_text_take_no_room_and_draw_nothing :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init: embedded fonts failed to load")
	defer text_engine_destroy(&te)
	line_widths :: proc(te: ^Text_Engine, s: string) -> (widths: [4]f32, n: int) {
		lines := text_lines(te, s, 16, 0)
		for l, i in lines do if i < len(widths) do widths[i] = l.width
		return widths, len(lines)
	}
	glyphs_drawn :: proc(te: ^Text_Engine, s: string) -> int {
		out := make([dynamic]gpu.Cmd, context.temp_allocator)
		render_text(te, Draw_Text{str = s, size = 16}, 1, nil, &out)
		return len(out)
	}
	ab, _ := line_widths(&te, "ab")
	cd, _ := line_widths(&te, "cd")
	w, n := line_widths(&te, "ab\ncd")
	testing.expect_value(t, n, 2)
	testing.expect(t, abs(w[0] - ab[0]) < 0.01 && abs(w[1] - cd[0]) < 0.01, "the break takes no room")
	crlf, cn := line_widths(&te, "ab\r\ncd")
	testing.expect_value(t, cn, 2)
	testing.expect(t, abs(crlf[0] - ab[0]) < 0.01, "nor does a CRLF")
	b, _ := line_widths(&te, "b")
	tabbed, _ := line_widths(&te, "a\tb")
	stop := prefix_width(&te, "0", 16) * 4
	testing.expect(t, abs(tabbed[0] - (stop + b[0])) < 0.01, "a tab reaches the next stop")
	testing.expect_value(t, glyphs_drawn(&te, "ab\ncd"), 4)
	testing.expect_value(t, glyphs_drawn(&te, "ab\r\ncd\t"), 4) // no missing-glyph boxes
	testing.expect_value(t, glyphs_drawn(&te, "abcd"), 4)
}

// The same contract, for the controls that are more than one byte wide:
// NEL (U+0085) and the rest of the C1 set, and the line and paragraph
// separators (U+2028, U+2029). A per-byte test misses them (a NEL is 0xC2
// 0x85), and the box the shaper gives a character no font has a glyph for
// is then drawn in the middle of the text. runa's shaper blanks these as
// well; this is the half that does not depend on which runa is vendored.
//
// Text like that is not exotic: U+2028 comes in from JSON and from text
// copied out of some editors, NEL from anything converted off a mainframe.
@(test)
a_control_wider_than_one_byte_draws_nothing_either :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init: embedded fonts failed to load")
	defer text_engine_destroy(&te)
	// Written as bytes, because bytes are the trap: a NEL's first byte,
	// 0xC2, is not below 0x20, so a per-byte test says "not a control".
	NEL :: "a\xc2\x85b"  // U+0085, a line break
	C1  :: "a\xc2\x90b"  // U+0090, a C1 that is not a break
	LS  :: "a\xe2\x80\xa8b" // U+2028, line separator
	PS  :: "a\xe2\x80\xa9b" // U+2029, paragraph separator
	drawn :: proc(te: ^Text_Engine, s: string) -> int {
		out := make([dynamic]gpu.Cmd, context.temp_allocator)
		render_text(te, Draw_Text{str = s, size = 16}, 1, nil, &out)
		return len(out)
	}
	width :: proc(te: ^Text_Engine, s: string) -> (w: f32) {
		for l in text_lines(te, s, 16, 0) do w = max(w, l.width)
		return
	}

	// The hazard is real in the fonts that ship with the toolkit: glyph 0 is
	// .notdef and this .notdef draws, so anything that reached the atlas for
	// one of these characters would be a visible box. Asked of the font
	// rather than of a shaped control, because which glyph a shaper hands
	// back for a control is the shaper's business (runa ≤ 1.5.1 gives
	// .notdef, 1.5.2 a zero-advance space); the assertions below are about
	// what is drawn.
	base := text_lines(&te, "a", 16, 0)
	testing.expect(t, len(base) == 1 && len(base[0].glyphs) == 1, "one letter, one glyph")
	if len(base) != 1 || len(base[0].glyphs) != 1 do return
	slot, err := runa.raster_glyph(base[0].glyphs[0].font, 0, 16, 0, &te.atlas, te.allocator)
	testing.expect(t, err == .None && slot.px_size.x > 0 && slot.px_size.y > 0, "the missing glyph is a box with ink, which is why nothing may reach it")

	// NEL and the two separators break the line, as they are meant to: two
	// lines, each as wide as its own letter, and two glyphs drawn in all.
	// Each line is measured on its own, because a width taken against "ab"
	// would pass just as well on a line that never broke.
	a, b := width(&te, "a"), width(&te, "b")
	for s in ([]string{NEL, LS, PS}) {
		lines := text_lines(&te, s, 16, 0)
		testing.expectf(t, len(lines) == 2, "%q breaks the line, giving %d", s, len(lines))
		if len(lines) != 2 do continue
		testing.expectf(t, abs(lines[0].width - a) < 0.01 && abs(lines[1].width - b) < 0.01, "%q: the break takes no room (%.2f, %.2f against %.2f, %.2f)", s, lines[0].width, lines[1].width, a, b)
		testing.expectf(t, drawn(&te, s) == 2, "%q draws its two letters and nothing else, not %d", s, drawn(&te, s))
	}

	// A C1 that is not a break stays inside the line and still draws
	// nothing — the case a separator cannot prove, because a break hides a
	// stray advance at the end of a line nobody measures.
	ab := width(&te, "ab")
	testing.expect_value(t, len(text_lines(&te, C1, 16, 0)), 1)
	testing.expectf(t, abs(width(&te, C1) - ab) < 0.01, "a C1 inside a line takes no room: %.2f against %.2f", width(&te, C1), ab)
	testing.expect_value(t, drawn(&te, C1), 2)
}

// …and the predicate on its own, because the test above cannot reach it:
// runa ≥ 1.5.2 blanks these controls in the shaper too, so a per-byte
// `is_control_at` would still pass every assertion above. This is Baldr's
// half, and it has to hold on an older vendored runa.
@(test)
the_control_test_reads_the_rune_and_nothing_else :: proc(t: ^testing.T) {
	yes :: proc(t: ^testing.T, s: string, what: string) {
		testing.expectf(t, is_control_at(s, 0), "%s is a control", what)
	}
	no :: proc(t: ^testing.T, s: string, what: string) {
		testing.expectf(t, !is_control_at(s, 0), "%s is not a control", what)
	}
	yes(t, "\x00", "NUL")
	yes(t, "\n", "LF")
	yes(t, "\t", "TAB")
	yes(t, "\x7f", "DEL")
	yes(t, "\xc2\x85", "NEL")
	yes(t, "\xc2\x80", "the first C1")
	yes(t, "\xc2\x9f", "the last C1")
	yes(t, "\xe2\x80\xa8", "U+2028")
	yes(t, "\xe2\x80\xa9", "U+2029")

	no(t, " ", "a space")
	no(t, "a", "a letter")
	no(t, "\xc2\xa0", "a no-break space (U+00A0, just past the C1 set)")
	no(t, "\xc3\xa9", "an e-acute")
	no(t, "\xe2\x80\x8d", "a zero-width joiner, which the shaper handles")
	no(t, "\xe2\x80\xa7", "U+2027, just before the separators")
	no(t, "\xe2\x80\xaa", "U+202A, just after them")
	no(t, "\xe6\x97\xa5", "a CJK character")
	no(t, "", "the end of the string")
	testing.expect(t, !is_control_at("ab", 5), "a cluster past the end is not a control")
}

} // when ODIN_TEST