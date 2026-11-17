package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Every test here runs headless with the real text engine (Inter through
// runa), so caret positions and hit-testing are checked against the same
// glyph layout the renderer draws.

@(private = "file")
Input_Fx :: struct {
	ui:          Ui(Test_Msg),
	te:          Text_Engine,
	value:       Text,
	n:           Node,
	placeholder: string,
	label:       string,
	width:       f32,
	disabled:    bool,
	password:    bool,
	on_change:   Handler(Test_Msg, string),
	on_submit:   Handler(Test_Msg, string),
}

@(private = "file")
fx_init :: proc(t: ^testing.T, fx: ^Input_Fx, initial := "", placeholder := "Name", width: f32 = 200) {
	if !text_engine_init(&fx.te) do testing.fail_now(t, "text_engine_init: embedded fonts failed to load")
	ui_init(&fx.ui)
	tree_use_text_engine(&fx.ui.tree, &fx.te)
	fx.value = text_make(initial)
	fx.placeholder = placeholder
	fx.width = width
	if fx.on_change == nil do fx.on_change = Test_Msg.Inc
	if fx.on_submit == nil do fx.on_submit = Test_Msg.Toggle
	fx_view(fx)
}

@(private = "file")
fx_view :: proc(fx: ^Input_Fx) {
	begin_view(&fx.ui)
	column(&fx.ui, align = .Start, padding = .lg) // Start: the field shows its intrinsic width
	fx.n = text_input(&fx.ui, &fx.value, placeholder = fx.placeholder, on_change = fx.on_change, on_submit = fx.on_submit,
		label = fx.label, width = fx.width, disabled = fx.disabled, password = fx.password, tag = 7)
	end(&fx.ui)
	end_view(&fx.ui)
	frame(&fx.ui.tree, {400, 200})
}

@(private = "file")
fx_destroy :: proc(fx: ^Input_Fx) {
	ui_destroy(&fx.ui)
	text_engine_destroy(&fx.te)
	text_destroy(&fx.value)
}

@(private = "file")
fx_focus :: proc(fx: ^Input_Fx) {
	set_focus(&fx.ui.tree, fx.n, true)
	frame(&fx.ui.tree, {400, 200})
}

@(private = "file")
press :: proc(fx: ^Input_Fx, k: Key, mods: Mods = {}) -> bool {
	return key_event(&fx.ui, k, true, mods)
}

@(private = "file")
sel :: proc(fx: ^Input_Fx) -> [2]int {
	lo, hi := text_input_selection(&fx.ui.tree, fx.n)
	return {lo, hi}
}

@(private = "file")
caret :: proc(fx: ^Input_Fx) -> int {
	return text_input_state(&fx.ui.tree, fx.n).caret
}

// caret_rect finds the caret in the draw list: a 1 px wide on_surface rect.
@(private = "file")
caret_rect :: proc(fx: ^Input_Fx) -> (r: Rect, ok: bool) {
	for c in draw_list(&fx.ui.tree) {
		if d, is := c.(Draw_Rect); is && d.rect.w == 1 && d.border_w == 0 && d.color == fx.ui.theme.color.on_surface {
			return d.rect, true
		}
	}
	return
}

@(private = "file")
selection_rect :: proc(fx: ^Input_Fx) -> (r: Rect, ok: bool) {
	band, _ := selection_pair(&fx.ui.tree.theme) // the band a selection draws (selection_paint.odin)
	for c in draw_list(&fx.ui.tree) {
		if d, is := c.(Draw_Rect); is && d.color == band do return d.rect, true
	}
	return
}

@(private = "file")
drawn_text :: proc(fx: ^Input_Fx, s: string) -> (Draw_Text, bool) {
	for c in draw_list(&fx.ui.tree) {
		if d, is := c.(Draw_Text); is && d.str == s do return d, true
	}
	return {}, false
}

@(private = "file")
inner_rect :: proc(fx: ^Input_Fx) -> Rect {
	return input_inner(node_get(&fx.ui.tree, fx.n))
}

// ---------------------------------------------------------------- Text buffer

@(test)
text_buffer_zero_value_and_edits :: proc(t: ^testing.T) {
	tx: Text // zero value: allocates on first edit
	defer text_destroy(&tx)
	testing.expect_value(t, str(tx), "")
	testing.expect_value(t, text_insert(&tx, 0, "héllo"), 6)
	testing.expect_value(t, str(tx), "héllo")
	testing.expect_value(t, text_insert(&tx, 100, "!"), 7) // clamped to the end
	testing.expect_value(t, str(tx), "héllo!")
	testing.expect_value(t, text_delete(&tx, 1, 3), 2) // the two bytes of é
	testing.expect_value(t, str(tx), "hllo!")
	testing.expect_value(t, text_delete(&tx, 4, 2), 2) // reversed and clamped
	testing.expect_value(t, str(tx), "hl!")
	testing.expect_value(t, text_delete(&tx, 50, 60), 0)
	text_set(&tx, str(tx)[1:]) // aliasing our own storage
	testing.expect_value(t, str(tx), "l!")
	text_set(&tx, "new")
	testing.expect_value(t, str(tx), "new")

	m := text_make("abc")
	testing.expect_value(t, str(m), "abc")
	text_destroy(&m)
	text_destroy(&m) // twice is fine
	testing.expect_value(t, str(m), "")
}

@(test)
text_grapheme_and_word_boundaries :: proc(t: ^testing.T) {
	// e + combining acute (3 bytes), a, a family ZWJ sequence (18 bytes), b
	s := "e\u0301a\U0001F468\u200D\U0001F469\u200D\U0001F467b"
	testing.expect_value(t, len(s), 23)
	testing.expect_value(t, grapheme_next(s, 0), 3)
	testing.expect_value(t, grapheme_next(s, 3), 4)
	testing.expect_value(t, grapheme_next(s, 4), 22)
	testing.expect_value(t, grapheme_next(s, 22), 23)
	testing.expect_value(t, grapheme_next(s, 23), 23)
	testing.expect_value(t, grapheme_prev(s, 23), 22)
	testing.expect_value(t, grapheme_prev(s, 22), 4)
	testing.expect_value(t, grapheme_prev(s, 3), 0)
	testing.expect_value(t, grapheme_prev(s, 0), 0)
	testing.expect_value(t, grapheme_snap(s, 1), 0)  // inside é
	testing.expect_value(t, grapheme_snap(s, 10), 4) // inside the emoji
	testing.expect_value(t, grapheme_snap(s, 99), 23)
	testing.expect_value(t, grapheme_count(s), 4)
	testing.expect_value(t, grapheme_index(s, 22), 3)
	testing.expect_value(t, grapheme_offset(s, 3), 22)
	testing.expect_value(t, grapheme_offset(s, 9), 23)

	w := "hello world  foo"
	testing.expect_value(t, word_next(w, 0), 5)
	testing.expect_value(t, word_next(w, 5), 11)
	testing.expect_value(t, word_next(w, 11), 16)
	testing.expect_value(t, word_next(w, 16), 16)
	testing.expect_value(t, word_prev(w, 16), 13)
	testing.expect_value(t, word_prev(w, 13), 6)
	testing.expect_value(t, word_prev(w, 6), 0)
	testing.expect_value(t, word_prev(w, 3), 0)
	lo, hi := word_at(w, 7)
	testing.expect_value(t, [2]int{lo, hi}, [2]int{6, 11})
	lo, hi = word_at(w, 5)
	testing.expect_value(t, [2]int{lo, hi}, [2]int{5, 6}) // the gap
	lo, hi = word_at(w, 16)
	testing.expect_value(t, [2]int{lo, hi}, [2]int{13, 16}) // at the end: the last word
	lo, hi = word_at("", 0)
	testing.expect_value(t, [2]int{lo, hi}, [2]int{0, 0})

	bad := "a\xffb"
	testing.expect_value(t, grapheme_next(bad, 0), 1)
	testing.expect_value(t, grapheme_next(bad, 1), 2)
	testing.expect_value(t, grapheme_count(bad), 3)
	testing.expect_value(t, word_next(bad, 0), 1) // the bad byte is its own segment
	testing.expect_value(t, word_next(bad, 1), 2)
	testing.expect_value(t, word_prev(bad, 3), 2)

	testing.expect_value(t, sanitize_input("a\nb\tc\x7fd\r"), "abcd")
	clean := "plain"
	testing.expect(t, raw_data(sanitize_input(clean)) == raw_data(clean), "clean input is returned as-is")
	testing.expect_value(t, sanitize_input("\n\r"), "")
}

// ---------------------------------------------------------------- editing

@(test)
text_input_typing_edits_buffer_and_queues_on_change :: proc(t: ^testing.T) {
	fx: Input_Fx
	fx_init(t, &fx)
	defer fx_destroy(&fx)
	testing.expect(t, !text_event(&fx.ui, "x"), "nothing focused: text goes nowhere")
	testing.expect_value(t, str(fx.value), "")
	fx_focus(&fx)
	testing.expect(t, text_event(&fx.ui, "Hi"))
	testing.expect_value(t, str(fx.value), "Hi")
	testing.expect_value(t, caret(&fx), 2)
	testing.expect_value(t, len(fx.ui.msgs), 1)
	testing.expect_value(t, fx.ui.msgs[0], Test_Msg.Inc)
	press(&fx, .Left)
	text_event(&fx.ui, "é")
	testing.expect_value(t, str(fx.value), "Héi")
	testing.expect_value(t, caret(&fx), 3)
	testing.expect_value(t, len(fx.ui.msgs), 2)
	testing.expect(t, !text_event(&fx.ui, "\n"), "control characters are dropped")
	testing.expect_value(t, str(fx.value), "Héi")

	// The a11y value and the drawn string follow the buffer.
	frame(&fx.ui.tree, {400, 200})
	testing.expect_value(t, node_get(&fx.ui.tree, fx.n).access.value_text, "Héi")
	_, drawn := drawn_text(&fx, "Héi")
	testing.expect(t, drawn, "the text is drawn")
}

@(test)
text_input_on_change_proc_gets_value_and_tag :: proc(t: ^testing.T) {
	fx: Input_Fx
	fx.on_change = proc(e: Ev(string)) -> Test_Msg {
		if e.tag == 7 && e.value == "ab" do return .Toggle
		return .Dec
	}
	fx_init(t, &fx)
	defer fx_destroy(&fx)
	fx_focus(&fx)
	text_event(&fx.ui, "a")
	text_event(&fx.ui, "b")
	testing.expect_value(t, len(fx.ui.msgs), 2)
	testing.expect_value(t, fx.ui.msgs[0], Test_Msg.Dec)
	testing.expect_value(t, fx.ui.msgs[1], Test_Msg.Toggle)
}

@(test)
text_input_backspace_and_delete_are_grapheme_aware :: proc(t: ^testing.T) {
	fx: Input_Fx
	fx_init(t, &fx, "ae\u0301\U0001F468\u200D\U0001F469\u200D\U0001F467")
	defer fx_destroy(&fx)
	fx_focus(&fx)
	press(&fx, .End)
	testing.expect_value(t, caret(&fx), len(str(fx.value)))
	testing.expect(t, press(&fx, .Backspace))
	testing.expect_value(t, str(fx.value), "ae\u0301") // the whole ZWJ sequence in one step
	press(&fx, .Backspace)
	testing.expect_value(t, str(fx.value), "a") // e + combining acute in one step
	press(&fx, .Backspace)
	testing.expect_value(t, str(fx.value), "")
	n := len(fx.ui.msgs)
	testing.expect(t, press(&fx, .Backspace), "consumed even when there is nothing to delete")
	testing.expect_value(t, len(fx.ui.msgs), n) // but no change message

	text_set(&fx.value, "e\u0301x")
	fx_view(&fx)
	press(&fx, .Home)
	press(&fx, .Delete)
	testing.expect_value(t, str(fx.value), "x")
	press(&fx, .Delete)
	testing.expect_value(t, str(fx.value), "")
}

@(test)
text_input_word_movement :: proc(t: ^testing.T) {
	fx: Input_Fx
	fx_init(t, &fx, "hello world foo")
	defer fx_destroy(&fx)
	fx_focus(&fx)
	press(&fx, .End)
	press(&fx, .Left, {.Ctrl})
	testing.expect_value(t, caret(&fx), 12)
	press(&fx, .Left, {.Ctrl})
	testing.expect_value(t, caret(&fx), 6)
	press(&fx, .Right, {.Ctrl})
	testing.expect_value(t, caret(&fx), 11)
	press(&fx, .Right, {.Ctrl})
	testing.expect_value(t, caret(&fx), 15)
	press(&fx, .Left, {.Ctrl, .Shift})
	testing.expect_value(t, sel(&fx), [2]int{12, 15})
	testing.expect_value(t, caret(&fx), 12)
	press(&fx, .Escape)
	testing.expect_value(t, sel(&fx), [2]int{12, 12}) // collapses onto the caret
	press(&fx, .End)
	press(&fx, .Backspace, {.Ctrl})
	testing.expect_value(t, str(fx.value), "hello world ")
	press(&fx, .Home)
	press(&fx, .Delete, {.Ctrl})
	testing.expect_value(t, str(fx.value), " world ")
}

@(test)
text_input_selection_and_replace :: proc(t: ^testing.T) {
	fx: Input_Fx
	fx_init(t, &fx, "hello world")
	defer fx_destroy(&fx)
	fx_focus(&fx)
	press(&fx, .End)
	for _ in 0 ..< 5 do press(&fx, .Left, {.Shift})
	testing.expect_value(t, sel(&fx), [2]int{6, 11})
	frame(&fx.ui.tree, {400, 200})
	r, has := selection_rect(&fx)
	testing.expect(t, has, "selection is drawn while focused")
	st := text_input_state(&fx.ui.tree, fx.n)
	x6 := input_caret_x(&fx.ui.tree, st, 6)
	x11 := input_caret_x(&fx.ui.tree, st, 11)
	testing.expect_value(t, r.x, inner_rect(&fx).x + x6)
	testing.expect_value(t, r.w, x11 - x6)

	text_event(&fx.ui, "there")
	testing.expect_value(t, str(fx.value), "hello there")
	testing.expect_value(t, sel(&fx), [2]int{11, 11})
	press(&fx, .Home, {.Shift})
	testing.expect_value(t, sel(&fx), [2]int{0, 11})
	press(&fx, .Left) // collapses to the start
	testing.expect_value(t, sel(&fx), [2]int{0, 0})
	press(&fx, .End, {.Shift})
	press(&fx, .Right) // collapses to the end
	testing.expect_value(t, sel(&fx), [2]int{11, 11})
	press(&fx, .Left, {.Shift})
	press(&fx, .Left, {.Shift})
	press(&fx, .Backspace)
	testing.expect_value(t, str(fx.value), "hello the")

	set_focus(&fx.ui.tree, NODE_NONE, false)
	frame(&fx.ui.tree, {400, 200})
	_, has = selection_rect(&fx)
	testing.expect(t, !has, "no selection highlight when unfocused")
}

@(test)
text_input_select_all_then_backspace :: proc(t: ^testing.T) {
	fx: Input_Fx
	fx_init(t, &fx, "some text")
	defer fx_destroy(&fx)
	fx_focus(&fx)
	testing.expect(t, press(&fx, .A, {.Ctrl}))
	testing.expect_value(t, sel(&fx), [2]int{0, 9})
	press(&fx, .Backspace)
	testing.expect_value(t, str(fx.value), "")
	testing.expect_value(t, len(fx.ui.msgs), 1)
	testing.expect_value(t, fx.ui.msgs[0], Test_Msg.Inc)
	testing.expect(t, press(&fx, .A), "a plain letter key is swallowed (its text arrives separately)")
	testing.expect_value(t, str(fx.value), "")
}

@(test)
text_input_enter_submits_escape_clears_selection :: proc(t: ^testing.T) {
	fx: Input_Fx
	fx_init(t, &fx, "go")
	defer fx_destroy(&fx)
	fx_focus(&fx)
	testing.expect(t, press(&fx, .Enter))
	testing.expect_value(t, len(fx.ui.msgs), 1)
	testing.expect_value(t, fx.ui.msgs[0], Test_Msg.Toggle)
	testing.expect_value(t, str(fx.value), "go")
	press(&fx, .A, {.Ctrl})
	testing.expect(t, press(&fx, .Escape), "Escape with a selection is consumed")
	testing.expect_value(t, sel(&fx), [2]int{2, 2})
	testing.expect(t, !press(&fx, .Escape), "Escape without a selection falls through")
	testing.expect(t, !text_input_key(&fx.ui, .Tab, {}), "Tab is not consumed by the field")
	testing.expect(t, press(&fx, .Tab), "so key_event still runs focus traversal")
	testing.expect_value(t, len(fx.ui.msgs), 1)
}

// ---------------------------------------------------------------- paint

@(test)
text_input_caret_only_when_focused_and_blink_on :: proc(t: ^testing.T) {
	fx: Input_Fx
	fx_init(t, &fx, "abc")
	defer fx_destroy(&fx)
	tr := &fx.ui.tree
	_, has := caret_rect(&fx)
	testing.expect(t, !has, "unfocused: no caret")
	testing.expect_value(t, tr.wake_at_ms, 0)

	anim_tick(tr, 1000)
	fx_focus(&fx)
	testing.expect_value(t, caret(&fx), 0) // a pre-filled field starts with the caret at the front
	press(&fx, .End)
	frame(tr, {400, 200})
	r, on := caret_rect(&fx)
	testing.expect(t, on, "focused: caret visible")
	inner := inner_rect(&fx)
	st := text_input_state(tr, fx.n)
	testing.expect_value(t, r.x, inner.x + input_caret_x(tr, st, 3))
	testing.expect_value(t, r.h, text_line_height(&fx.te, st.size))
	testing.expect_value(t, tr.wake_at_ms, 1000 + CARET_BLINK_MS)

	// The wake fires: the caret goes off, then on again.
	tr.wake_at_ms = 0
	anim_tick(tr, 1000 + CARET_BLINK_MS)
	text_input_wake(tr)
	frame(tr, {400, 200})
	_, on = caret_rect(&fx)
	testing.expect(t, !on, "second phase: caret hidden")
	testing.expect_value(t, tr.wake_at_ms, 1000 + 2 * CARET_BLINK_MS)
	tr.wake_at_ms = 0
	anim_tick(tr, 1000 + 2 * CARET_BLINK_MS + 5)
	text_input_wake(tr)
	frame(tr, {400, 200})
	_, on = caret_rect(&fx)
	testing.expect(t, on, "third phase: caret visible")

	// Typing during an off phase makes the caret visible immediately.
	anim_tick(tr, 1000 + 3 * CARET_BLINK_MS + 5)
	text_input_wake(tr)
	frame(tr, {400, 200})
	_, on = caret_rect(&fx)
	testing.expect(t, !on)
	text_event(&fx.ui, "d")
	frame(tr, {400, 200})
	_, on = caret_rect(&fx)
	testing.expect(t, on, "typing resets the blink to visible")

	set_focus(tr, NODE_NONE, false)
	frame(tr, {400, 200})
	_, has = caret_rect(&fx)
	testing.expect(t, !has, "blurred: no caret")
}

@(test)
text_input_placeholder_and_password :: proc(t: ^testing.T) {
	fx: Input_Fx
	fx_init(t, &fx, "", "Your name")
	defer fx_destroy(&fx)
	ph, has := drawn_text(&fx, "Your name")
	testing.expect(t, has, "empty field draws its placeholder")
	testing.expect_value(t, ph.color, fx.ui.theme.color.on_surface_muted)
	testing.expect_value(t, ph.pos.x, inner_rect(&fx).x)
	fx_focus(&fx)
	text_event(&fx.ui, "x")
	frame(&fx.ui.tree, {400, 200})
	_, has = drawn_text(&fx, "Your name")
	testing.expect(t, !has, "placeholder goes away with content")
	tx, has_x := drawn_text(&fx, "x")
	testing.expect(t, has_x)
	testing.expect_value(t, tx.color, fx.ui.theme.color.on_surface)

	fx.password = true
	text_set(&fx.value, "ab\u0301c")
	fx_view(&fx)
	_, has = drawn_text(&fx, "•••")
	testing.expect(t, has, "password mode draws one bullet per grapheme")
	_, has = drawn_text(&fx, "ab\u0301c")
	testing.expect(t, !has)
	testing.expect_value(t, node_get(&fx.ui.tree, fx.n).access.value_text, "•••")
	press(&fx, .End)
	press(&fx, .Backspace)
	testing.expect_value(t, str(fx.value), "ab\u0301") // edits the real buffer
	press(&fx, .Left)
	testing.expect_value(t, caret(&fx), 1)
	frame(&fx.ui.tree, {400, 200})
	r, on := caret_rect(&fx)
	testing.expect(t, on)
	st := text_input_state(&fx.ui.tree, fx.n)
	testing.expect_value(t, r.x, inner_rect(&fx).x + input_caret_x(&fx.ui.tree, st, len(PASSWORD_BULLET))) // after the first bullet
}

@(test)
text_input_layout_is_one_line_plus_padding :: proc(t: ^testing.T) {
	fx: Input_Fx
	fx_init(t, &fx, "abc", width = 0)
	defer fx_destroy(&fx)
	th := fx.ui.theme
	d := node_get(&fx.ui.tree, fx.n)
	testing.expect_value(t, d.abs.h, text_line_height(&fx.te, th.type.body.size) + 2 * th.space[.sm])
	testing.expect_value(t, d.abs.w, TEXT_INPUT_DEFAULT_WIDTH) // the fixture's column aligns .Start: intrinsic width
	testing.expect_value(t, d.style.bg, th.color.surface_variant)
	testing.expect_value(t, d.style.radius, th.radius.md)
	border_ok := false
	for c in draw_list(&fx.ui.tree) {
		if r, is := c.(Draw_Rect); is && r.border_w == 1 && r.border == th.color.outline && r.rect == d.abs do border_ok = true
	}
	testing.expect(t, border_ok, "1 px outline border")

	fx.width = 300
	fx_view(&fx)
	testing.expect_value(t, node_get(&fx.ui.tree, fx.n).abs.w, 300)

	// Default (Stretch) column: fills the parent.
	begin_view(&fx.ui)
	column(&fx.ui, padding = .lg)
	n := text_input(&fx.ui, &fx.value, placeholder = "p")
	end(&fx.ui)
	end_view(&fx.ui)
	frame(&fx.ui.tree, {400, 200})
	testing.expect_value(t, node_get(&fx.ui.tree, n).abs.w, 400 - 2 * th.space[.lg])

	fx.n = n // a different view (call site) built a different node
	fx_focus(&fx)
	frame(&fx.ui.tree, {400, 200})
	focused_border := false
	for c in draw_list(&fx.ui.tree) {
		if r, is := c.(Draw_Rect); is && r.border_w == 1 && r.border == th.color.primary do focused_border = true
	}
	testing.expect(t, focused_border, "focused border uses primary")
}

// ---------------------------------------------------------------- clipboard

@(private = "file")
Fake_Clip :: struct {
	buf: [dynamic]u8,
}

@(private = "file")
fake_get :: proc(user: rawptr, allocator := context.allocator) -> (string, bool) {
	c := (^Fake_Clip)(user)
	return strings.clone(string(c.buf[:]), allocator), true
}

@(private = "file")
fake_set :: proc(user: rawptr, text: string) -> bool {
	c := (^Fake_Clip)(user)
	clear(&c.buf)
	append(&c.buf, ..transmute([]u8)text)
	return true
}

@(test)
text_input_clipboard_round_trip :: proc(t: ^testing.T) {
	fx: Input_Fx
	fx_init(t, &fx, "hello world")
	defer fx_destroy(&fx)
	clip: Fake_Clip
	defer delete(clip.buf)
	fx_focus(&fx)
	// No clipboard installed: copy/paste are harmless no-ops.
	press(&fx, .A, {.Ctrl})
	testing.expect(t, press(&fx, .C, {.Ctrl}))
	testing.expect(t, press(&fx, .V, {.Ctrl}))
	testing.expect_value(t, str(fx.value), "hello world")

	fx.ui.clipboard = {user = &clip, get = fake_get, set = fake_set}
	press(&fx, .End)
	press(&fx, .Left, {.Ctrl, .Shift})
	press(&fx, .C, {.Ctrl})
	testing.expect_value(t, string(clip.buf[:]), "world")
	press(&fx, .Home)
	press(&fx, .V, {.Ctrl})
	testing.expect_value(t, str(fx.value), "worldhello world")
	testing.expect_value(t, caret(&fx), 5)
	press(&fx, .A, {.Ctrl})
	press(&fx, .X, {.Ctrl})
	testing.expect_value(t, str(fx.value), "")
	testing.expect_value(t, string(clip.buf[:]), "worldhello world")
	press(&fx, .V, {.Ctrl})
	testing.expect_value(t, str(fx.value), "worldhello world")
	fake_set(&clip, "a\nb")
	press(&fx, .V, {.Ctrl})
	testing.expect_value(t, str(fx.value), "worldhello worldab") // newlines dropped
	n := len(fx.ui.msgs)
	press(&fx, .Escape)
	press(&fx, .X, {.Ctrl}) // nothing selected: nothing cut, nothing queued
	testing.expect_value(t, str(fx.value), "worldhello worldab")
	testing.expect_value(t, len(fx.ui.msgs), n)
}

// ---------------------------------------------------------------- disabled

@(test)
text_input_disabled_ignores_input :: proc(t: ^testing.T) {
	fx: Input_Fx
	fx.disabled = true
	fx_init(t, &fx, "fixed")
	defer fx_destroy(&fx)
	d := node_get(&fx.ui.tree, fx.n)
	testing.expect(t, .Disabled in d.access.states)
	testing.expect(t, !set_focus(&fx.ui.tree, fx.n, true), "not focusable")
	testing.expect(t, !key_event(&fx.ui, .Tab, true, {}), "Tab finds nothing to focus")
	testing.expect(t, !text_event(&fx.ui, "x"))
	testing.expect(t, !press(&fx, .Backspace))
	r := d.abs
	pointer_button(&fx.ui, .Left, true, {r.x + r.w / 2, r.y + r.h / 2})
	pointer_button(&fx.ui, .Left, false, {r.x + r.w / 2, r.y + r.h / 2})
	testing.expect_value(t, fx.ui.focus, NODE_NONE)
	testing.expect_value(t, str(fx.value), "fixed")
	testing.expect_value(t, len(fx.ui.msgs), 0)
	_, has := caret_rect(&fx)
	testing.expect(t, !has)
	tx, drawn := drawn_text(&fx, "fixed")
	testing.expect(t, drawn)
	testing.expect_value(t, tx.color.a, fx.ui.theme.state.disabled_alpha)

	// Disabling a focused field stops its editing; re-enabling resumes.
	fx.disabled = false
	fx_view(&fx)
	fx_focus(&fx)
	press(&fx, .End)
	text_event(&fx.ui, "!")
	testing.expect_value(t, str(fx.value), "fixed!")
	fx.disabled = true
	fx_view(&fx)
	testing.expect(t, !text_event(&fx.ui, "?"))
	testing.expect_value(t, str(fx.value), "fixed!")
}

// ---------------------------------------------------------------- pointer

@(test)
text_input_click_places_caret_at_nearest_grapheme :: proc(t: ^testing.T) {
	fx: Input_Fx
	fx_init(t, &fx, "ae\u0301b") // a, é (e + combining acute), b
	defer fx_destroy(&fx)
	tr := &fx.ui.tree
	inner := inner_rect(&fx)
	st := text_input_state(tr, fx.n)
	// bytes: a = 0..1, e + U+0301 = 1..4, b = 4..5
	x1 := input_caret_x(tr, st, 1) // after a
	x4 := input_caret_x(tr, st, 4) // after e+U+0301
	x5 := input_caret_x(tr, st, 5) // end
	testing.expect(t, 0 < x1 && x1 < x4 && x4 < x5, "boundaries advance")
	y := inner.y + inner.h / 2

	click :: proc(fx: ^Input_Fx, x, y: f32, at_ms: f64) -> bool {
		anim_tick(&fx.ui.tree, at_ms)
		fx.ui.pointer.time_ms = at_ms // a real click time, or every click is a multi-click
		a := pointer_button(&fx.ui, .Left, true, {x, y})
		pointer_button(&fx.ui, .Left, false, {x, y})
		return a
	}
	testing.expect(t, click(&fx, inner.x + x4 - 0.4, y, 1000))
	testing.expect_value(t, caret(&fx), 4) // just left of the boundary after the cluster: never bytes 2 or 3
	testing.expect_value(t, fx.ui.focus, fx.n)
	testing.expect(t, !fx.ui.focus_visible, "pointer focus shows no ring")
	click(&fx, inner.x + (x1 + x4) / 2 + 0.5, y, 2000) // inside the cluster, right half: after it
	testing.expect_value(t, caret(&fx), 4)
	click(&fx, inner.x + (x1 + x4) / 2 - 0.5, y, 3000) // inside the cluster, left half: before it
	testing.expect_value(t, caret(&fx), 1)
	click(&fx, inner.x + x5 + 40, y, 4000) // past the text, inside the field
	testing.expect_value(t, caret(&fx), 5)
	click(&fx, node_get(tr, fx.n).abs.x + 2, y, 5000) // in the left padding
	testing.expect_value(t, caret(&fx), 0)
	frame(tr, {400, 200})
	r, on := caret_rect(&fx)
	testing.expect(t, on)
	testing.expect_value(t, r.x, inner.x)
	testing.expect(t, !text_input_pointer_button(&fx.ui, true, {1, 1}), "a press elsewhere is not the field's")
	testing.expect_value(t, caret(&fx), 0)

	// Drag selects; double-click selects the word; triple-click everything.
	text_set(&fx.value, "hello world")
	fx_view(&fx)
	st = text_input_state(tr, fx.n)
	hx2 := input_caret_x(tr, st, 2)
	hx5 := input_caret_x(tr, st, 5)
	hx8 := input_caret_x(tr, st, 8)
	anim_tick(tr, 5000)
	pointer_button(&fx.ui, .Left, true, {inner.x + hx2 + 0.1, y})
	testing.expect(t, pointer_move(&fx.ui, {inner.x + hx5 + 0.1, y}), "drag reports a change")
	testing.expect_value(t, sel(&fx), [2]int{2, 5})
	testing.expect_value(t, caret(&fx), 5)
	pointer_button(&fx.ui, .Left, false, {inner.x + hx5 + 0.1, y})
	testing.expect(t, !text_input_state(tr, fx.n).dragging)
	pointer_move(&fx.ui, {inner.x + hx8, y})
	testing.expect_value(t, sel(&fx), [2]int{2, 5}) // released: moving no longer selects

	click(&fx, inner.x + hx8, y, 6000)
	click(&fx, inner.x + hx8 + 1, y, 6100)
	testing.expect_value(t, sel(&fx), [2]int{6, 11}) // "world"
	click(&fx, inner.x + hx8, y, 6200)
	testing.expect_value(t, sel(&fx), [2]int{0, 11})
	click(&fx, inner.x + hx8, y, 7000) // too late for a fourth: back to a single click
	testing.expect_value(t, sel(&fx), [2]int{8, 8})
	testing.expect_value(t, cursor_for(&fx.ui), Cursor.Text)
}

@(test)
text_input_scrolls_to_keep_caret_visible :: proc(t: ^testing.T) {
	fx: Input_Fx
	fx_init(t, &fx, "The quick brown fox jumps over the lazy dog and keeps running", width = 120)
	defer fx_destroy(&fx)
	tr := &fx.ui.tree
	inner := inner_rect(&fx)
	st := text_input_state(tr, fx.n)
	text_w := input_caret_x(tr, st, len(st.display))
	testing.expect(t, text_w > inner.w, "the text overflows the field")
	testing.expect_value(t, st.scroll_x, 0)

	fx_focus(&fx)
	press(&fx, .End)
	frame(tr, {400, 200})
	r, on := caret_rect(&fx)
	testing.expect(t, on)
	testing.expect(t, r.x >= inner.x && r.x + r.w <= inner.x + inner.w, "caret inside the field at the end")
	testing.expect(t, st.scroll_x > 0, "content scrolled")
	testing.expect_value(t, st.scroll_x, text_w + 1 - inner.w)
	drawn, has := drawn_text(&fx, st.display)
	testing.expect(t, has)
	testing.expect_value(t, drawn.pos.x, inner.x - st.scroll_x)
	clip_ok := false
	for c in draw_list(tr) {
		if p, is := c.(Draw_Clip_Push); is && p.rect.x == inner.x && p.rect.w == inner.w do clip_ok = true
	}
	testing.expect(t, clip_ok, "text is clipped to the field")

	// Clicking while scrolled hits the visible glyphs, not the hidden ones.
	y := inner.y + inner.h / 2
	pointer_button(&fx.ui, .Left, true, {inner.x + inner.w - 2, y})
	pointer_button(&fx.ui, .Left, false, {inner.x + inner.w - 2, y})
	testing.expect_value(t, caret(&fx), len(st.display))

	press(&fx, .Home)
	frame(tr, {400, 200})
	testing.expect_value(t, st.scroll_x, 0)
	r, on = caret_rect(&fx)
	testing.expect(t, on)
	testing.expect_value(t, r.x, inner.x)
	// Moving right one grapheme at a time keeps the caret inside without scrolling until needed.
	for _ in 0 ..< 3 do press(&fx, .Right)
	frame(tr, {400, 200})
	testing.expect_value(t, st.scroll_x, 0)

	// Widening the field so everything fits pulls the scroll back to zero.
	press(&fx, .End)
	frame(tr, {400, 200})
	testing.expect(t, st.scroll_x > 0)
	fx.width = 0
	begin_view(&fx.ui)
	column(&fx.ui, align = .Stretch)
	fx.n = text_input(&fx.ui, &fx.value, placeholder = fx.placeholder, width = 0)
	end(&fx.ui)
	end_view(&fx.ui)
	frame(tr, {2000, 200})
	testing.expect_value(t, text_input_state(tr, fx.n).scroll_x, 0)
}

// ---------------------------------------------------------------- a11y / robustness

@(test)
text_input_a11y_tree_and_lint :: proc(t: ^testing.T) {
	fx: Input_Fx
	fx.label = "Search"
	fx_init(t, &fx, "abc", "Type to search")
	defer fx_destroy(&fx)
	tr := &fx.ui.tree
	a := node_get(tr, fx.n).access
	testing.expect_value(t, a.role, Role.Text_Input)
	testing.expect_value(t, a.name, "Search")
	testing.expect_value(t, a.value_text, "abc")
	testing.expect_value(t, lint(tr), 0)
	dump := access_dump(tr)
	testing.expect(t, strings.contains(dump, "Text_Input \"Search\" =\"abc\""), dump)
	fx_focus(&fx)
	testing.expect(t, .Focused in node_get(tr, fx.n).access.states)
	testing.expect(t, strings.contains(access_dump(tr), "Focused"), "focus is in the a11y state")
	testing.expect(t, .Focusable in node_get(tr, fx.n).flags)

	// Placeholder is the fallback name.
	fx.label = ""
	fx_view(&fx)
	testing.expect_value(t, node_get(tr, fx.n).access.name, "Type to search")
	testing.expect_value(t, lint(tr), 0)

	// Neither: the lint points at the builder call.
	fx.placeholder = ""
	fx_view(&fx)
	testing.expect_value(t, lint(tr), 1)
	last := tr.diags[len(tr.diags) - 1]
	testing.expect(t, strings.contains(last.msg, "Text_Input has no accessible name"), last.msg)
	testing.expect(t, strings.has_suffix(last.loc.file_path, "text_input_test.odin"))
}

@(test)
text_input_survives_odd_input_and_external_edits :: proc(t: ^testing.T) {
	fx: Input_Fx
	fx_init(t, &fx, "ab")
	defer fx_destroy(&fx)
	tr := &fx.ui.tree
	fx_focus(&fx)
	press(&fx, .End)
	testing.expect(t, text_event(&fx.ui, "\xff"), "invalid UTF-8 is stored, not rejected")
	testing.expect_value(t, len(str(fx.value)), 3)
	frame(tr, {400, 200})
	press(&fx, .Backspace)
	testing.expect_value(t, str(fx.value), "ab")

	// A huge buffer lays out, paints, moves, and hit-tests.
	big := strings.repeat("word ", 4000, context.temp_allocator)
	text_set(&fx.value, big)
	fx_view(&fx)
	press(&fx, .End)
	testing.expect_value(t, caret(&fx), len(big))
	press(&fx, .Left, {.Ctrl})
	testing.expect_value(t, caret(&fx), len(big) - 5)
	frame(tr, {400, 200})
	inner := inner_rect(&fx)
	pointer_button(&fx.ui, .Left, true, {inner.x + 3, inner.y + 3})
	pointer_button(&fx.ui, .Left, false, {inner.x + 3, inner.y + 3})
	testing.expect(t, caret(&fx) >= 0 && caret(&fx) <= len(big))
	press(&fx, .A, {.Ctrl})
	press(&fx, .Backspace)
	testing.expect_value(t, str(fx.value), "")

	// The app rewrote the buffer in `update`: the next view clamps the caret
	// onto a boundary and redraws.
	text_event(&fx.ui, "hello")
	testing.expect_value(t, caret(&fx), 5)
	text_set(&fx.value, "e\u0301")
	text_input_state(tr, fx.n).caret = 1 // deliberately inside the cluster
	fx_view(&fx)
	testing.expect_value(t, caret(&fx), 0)
	testing.expect_value(t, node_get(tr, fx.n).access.value_text, "e\u0301")
	text_set(&fx.value, "")
	fx_view(&fx)
	testing.expect_value(t, caret(&fx), 0)
	_, ph := drawn_text(&fx, fx.placeholder)
	testing.expect(t, ph, "placeholder returns when the app clears the text")

	// State survives a rebuild and is dropped with the node.
	text_event(&fx.ui, "zz")
	press(&fx, .Left)
	fx_view(&fx)
	testing.expect_value(t, caret(&fx), 1)
	testing.expect_value(t, len(tr.inputs), 1)
	begin_view(&fx.ui)
	text(&fx.ui, "gone")
	end_view(&fx.ui)
	testing.expect_value(t, len(tr.inputs), 0)
	testing.expect_value(t, len(fx.ui.input_handlers), 0)
	testing.expect_value(t, tr.focus, NODE_NONE)
	testing.expect(t, !text_event(&fx.ui, "x"))
}

@(test)
text_input_headless_without_engine_still_works :: proc(t: ^testing.T) {
	// The mono measurer path: layout, caret, and hit-testing stay consistent.
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	v := text_make("abcd")
	defer text_destroy(&v)
	begin_view(&ui)
	n := text_input(&ui, &v, placeholder = "p", width = 200)
	end_view(&ui)
	frame(&ui.tree, {400, 200})
	set_focus(&ui.tree, n, true)
	key_event(&ui, .End, true, {})
	frame(&ui.tree, {400, 200})
	d := node_get(&ui.tree, n)
	inner := input_inner(d)
	st := text_input_state(&ui.tree, n)
	testing.expect_value(t, input_caret_x(&ui.tree, st, 4), 4 * st.size * 0.5)
	pointer_button(&ui, .Left, true, {inner.x + 2 * st.size * 0.5 + 0.1, inner.y + 2})
	pointer_button(&ui, .Left, false, {inner.x + 2 * st.size * 0.5 + 0.1, inner.y + 2})
	testing.expect_value(t, st.caret, 2)
	testing.expect_value(t, d.abs.h, st.size * 1.25 + 2 * ui.theme.space[.sm])
}

} // when ODIN_TEST