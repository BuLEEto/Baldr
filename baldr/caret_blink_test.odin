package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A caret's blink costs a window as little as it can: each blink presents
// the caret and nothing else, and a caret left alone stops blinking, shown,
// so a window with the keyboard in an editor and nobody typing wakes for
// nothing. How it blinks is the desktop's to say.

@(private = "file")
Cb_Msg :: enum { None }

@(private = "file")
cb_view :: proc(ui: ^Ui(Cb_Msg), doc: ^Document, field: ^Text = nil) -> (area, input: Node) {
	set_viewport(&ui.tree, {600, 400})
	begin_view(ui)
	column(ui, padding = .lg)
	fr := code_editor(ui, doc, nil, label = "Source", height = 300)
	if field != nil do input = text_input(ui, field, label = "Find")
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	area = ui.tree.area_of_frame[fr]
	return
}

// cb_caret is the editor's caret as drawn: a rect one pixel wide and a
// line tall (the gutter's hairline is as thin, and the editor's height).
@(private = "file")
cb_caret :: proc(t: ^Tree) -> (r: Rect, shown: bool) {
	for c in draw_list(t) {
		if q, ok := c.(Draw_Rect); ok && q.rect.w == 1 && q.rect.h > 10 && q.rect.h < 40 do return q.rect, true
	}
	return
}

@(private = "file")
cb_covers :: proc(rects: []Rect, r: Rect) -> bool {
	for d in rects do if d.x <= r.x && d.y <= r.y && d.x + d.w >= r.x + r.w && d.y + d.h >= r.y + r.h do return true
	return false
}

// cb_settle runs each wake as it falls due until none is asked for, or
// `until` passes; it returns the last one that fired. It has its own bound:
// a wake asked for in the past would otherwise fire for ever.
@(private = "file")
cb_settle :: proc(t: ^Tree, until: f64, size := [2]f32{600, 400}) -> (last: f64) {
	for i := 0; t.wake_at_ms > 0 && t.wake_at_ms <= until; i += 1 {
		if i == 200 || t.wake_at_ms < t.now_ms {
			last = -1 // a runaway: the caller's expectations fail on it
			return
		}
		last = t.wake_at_ms
		anim_tick(t, last)
		frame(t, size)
		free_all(context.temp_allocator)
	}
	return
}

@(test)
a_blink_presents_the_caret_and_nothing_else :: proc(t: ^testing.T) {
	ui: Ui(Cb_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make("first line\nsecond line\nthird")
	defer document_destroy(&doc)
	tr := &ui.tree
	anim_tick(tr, 1000)
	area, _ := cb_view(&ui, &doc)
	set_focus(tr, area, true)
	frame(tr, {600, 400})
	testing.expect_value(t, tr.wake_at_ms, 1000 + CARET_BLINK_MS)
	anim_tick(tr, 1300) // the focus ring has come in
	frame(tr, {600, 400})
	take_damage(tr)
	whole := node_get(tr, area).abs
	caret, shown := cb_caret(tr)
	testing.expect(t, shown, "the caret shows when the editor takes the keyboard")

	anim_tick(tr, 1000 + CARET_BLINK_MS) // off
	frame(tr, {600, 400})
	dmg := take_damage(tr)
	_, shown = cb_caret(tr)
	testing.expect(t, !shown, "the blink hides it")
	testing.expect(t, len(dmg) > 0 && cb_covers(dmg, caret), "where it was is presented")
	for r in dmg do testing.expectf(t, r.w <= 4 && r.h < whole.h / 4, "and nothing more of the editor: %v", r)

	anim_tick(tr, 1000 + 2 * CARET_BLINK_MS) // on again
	frame(tr, {600, 400})
	dmg = take_damage(tr)
	caret, shown = cb_caret(tr)
	testing.expect(t, shown && cb_covers(dmg, caret), "the caret back, and presented")
	for r in dmg do testing.expectf(t, r.w <= 4 && r.h < whole.h / 4, "only the caret: %v", r)

	// anything else that changed the editor this frame presents all of it
	mark_paint_dirty(tr, area)
	anim_tick(tr, 1000 + 3 * CARET_BLINK_MS)
	frame(tr, {600, 400})
	testing.expect(t, cb_covers(take_damage(tr), whole), "a blink that coincides with another change is no narrower than it")
}

@(test)
a_caret_left_alone_stops_blinking_shown :: proc(t: ^testing.T) {
	ui: Ui(Cb_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make("some code")
	defer document_destroy(&doc)
	field: Text
	defer text_destroy(&field)
	tr := &ui.tree
	anim_tick(tr, 1000)
	area, input := cb_view(&ui, &doc, &field)

	for n in ([]Node{area, input}) {
		start := tr.now_ms
		set_focus(tr, n, true)
		cb_view(&ui, &doc, &field)
		last := cb_settle(tr, start + 3 * CARET_BLINK_TIMEOUT_MS)
		testing.expect_value(t, tr.wake_at_ms, 0)
		testing.expectf(t, last > start + CARET_BLINK_TIMEOUT_MS - CARET_BLINK_MS && last <= start + CARET_BLINK_TIMEOUT_MS + 1,
			"blinks for the timeout and then asks for nothing (last wake %v after %v)", last, start)
		if n == area {
			_, shown := cb_caret(tr)
			testing.expect(t, shown, "and the caret stays shown")
		}
		// a key starts it again
		if n == area { text_area_text(&ui, "x") } else { text_event(&ui, "x") }
		cb_view(&ui, &doc, &field)
		testing.expect(t, tr.wake_at_ms > tr.now_ms, "typing blinks again")
		cb_settle(tr, tr.now_ms + 3 * CARET_BLINK_TIMEOUT_MS)
	}
}

@(test)
the_desktop_says_how_a_caret_blinks :: proc(t: ^testing.T) {
	ui: Ui(Cb_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make("some code")
	defer document_destroy(&doc)
	tr := &ui.tree
	tree_a11y_prefs(tr, A11y_Prefs{caret_blink_ms = 300, caret_blink_timeout_ms = 1200})
	anim_tick(tr, 1000)
	area, _ := cb_view(&ui, &doc)
	set_focus(tr, area, true)
	frame(tr, {600, 400})
	testing.expect_value(t, tr.wake_at_ms, 1300)
	testing.expect_value(t, cb_settle(tr, 10_000), 2200) // 1300, 1600, 1900, then shown at 2200
	testing.expect_value(t, tr.wake_at_ms, 0)

	for p in ([]A11y_Prefs{{steady_caret = true}, {reduce_motion = true}}) {
		tree_a11y_prefs(tr, p)
		text_area_text(&ui, "x") // a key that would start a blink
		cb_view(&ui, &doc)
		cb_settle(tr, tr.now_ms + 1000) // a wake asked for before, if any
		_, shown := cb_caret(tr)
		testing.expect(t, shown && tr.wake_at_ms == 0, "a steady caret: shown, and no wake for it")
	}
}

// The desktop's caret settings arrive with its theme, as its other
// accessibility preferences do.
@(test)
the_desktops_caret_settings_reach_the_preferences :: proc(t: ^testing.T) {
	p := a11y_prefs_of({text_scale = 1, steady_caret = true, caret_blink_ms = 600, caret_blink_timeout_ms = 5000})
	testing.expect(t, p.steady_caret && p.caret_blink_ms == 600 && p.caret_blink_timeout_ms == 5000)
	tr: Tree
	tree_init(&tr)
	defer tree_destroy(&tr)
	tree_a11y_prefs(&tr, A11y_Prefs{caret_blink_ms = 1, caret_blink_timeout_ms = 1})
	half, timeout, blinks := caret_timing(&tr)
	testing.expect(t, blinks && half == 100 && timeout == 200, "a setting no one meant cannot spin a window")
}

@(private = "file")
Cb_Tty :: union { Term_Key }

@(test)
a_terminals_cursor_blinks_alone_and_stops :: proc(t: ^testing.T) {
	ui: Ui(Cb_Tty)
	ui_init(&ui)
	defer ui_destroy(&ui)
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text engine")
	defer text_engine_destroy(&te)
	ui.tree.text = &te
	s: Term_Screen
	term_screen_resize(&s, 20, 4)
	defer term_screen_destroy(&s)
	s.cursor = {col = 3, row = 1, shape = .Bar, blink = true}
	ui.surface.keyboard = true
	tr := &ui.tree
	anim_tick(tr, 1000)
	cb_term_view :: proc(ui: ^Ui(Cb_Tty), s: ^Term_Screen) -> Node {
		set_viewport(&ui.tree, {500, 300})
		begin_view(ui)
		column(ui)
		n := terminal(ui, s, size = 14, label = "shell")
		end(ui)
		end_view(ui)
		frame(&ui.tree, {500, 300})
		return n
	}
	n := cb_term_view(&ui, &s)
	set_focus(tr, n, false)
	frame(tr, {500, 300})
	take_damage(tr)
	whole := node_get(tr, n).abs
	testing.expect(t, tr.wake_at_ms > 1000, "a blinking cursor asks to blink")
	anim_tick(tr, tr.wake_at_ms)
	frame(tr, {500, 300})
	dmg := take_damage(tr)
	cell := ui.tree.terminals[n].px.logical
	testing.expect(t, len(dmg) > 0, "the blink is presented")
	for r in dmg do testing.expectf(t, r.w <= cell.advance + 3 && r.h <= cell.line_height + 3 && r.w < whole.w / 4, "as the cursor's cell alone: %v", r)
	cb_settle(tr, 1000 + 3 * CARET_BLINK_TIMEOUT_MS, {500, 300})
	testing.expect_value(t, tr.wake_at_ms, 0)
}

} // when ODIN_TEST
