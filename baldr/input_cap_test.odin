package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// A single-line field's length cap, so a paste cannot put megabytes into an
// app's state, and its right-click menu, as `text_area` has.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Ic_Msg :: union { Editor_Context }

@(private = "file")
ic_build :: proc(ui: ^Ui(Ic_Msg), v: ^Text, cap_: int, menu: bool) -> Node {
	set_viewport(&ui.tree, {400, 200})
	begin_view(ui)
	column(ui, padding = .md)
	n := text_input(ui, v, label = "Server", max_length = cap_,
		on_context = (proc(e: Ev(Editor_Context)) -> Ic_Msg { return e.value }) if menu else nil, key = 1)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 200})
	return n
}

// A paste longer than the cap is truncated, not refused: the person gets
// what fits, which is what every capped field does.
@(test)
a_capped_field_truncates_a_long_paste :: proc(t: ^testing.T) {
	v: Text
	text_set(&v, "")
	defer text_destroy(&v)
	ui: Ui(Ic_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := ic_build(&ui, &v, 10, false)
	d := node_get(&ui.tree, n)
	s := &ui.tree.inputs[n]
	testing.expect(t, s != nil, "the field has state")

	long := strings.repeat("x", 500, context.temp_allocator)
	input_replace(&ui, n, d, s, 0, 0, long)
	testing.expect_value(t, len(str(v)), 10)

	// and it stays capped: a second paste adds nothing
	input_replace(&ui, n, d, s, len(str(v)), len(str(v)), "more")
	testing.expect_value(t, len(str(v)), 10)
}

// The cap counts characters, not bytes, and never cuts a cluster in half:
// a field capped at 5 holding emoji must not end in a broken one.
@(test)
a_cap_counts_characters_and_keeps_clusters_whole :: proc(t: ^testing.T) {
	v: Text
	text_set(&v, "")
	defer text_destroy(&v)
	ui: Ui(Ic_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := ic_build(&ui, &v, 5, false)
	d := node_get(&ui.tree, n)
	s := &ui.tree.inputs[n]

	input_replace(&ui, n, d, s, 0, 0, "héllo wörld")
	got := str(v)
	testing.expectf(t, len(got) > 5, "five characters of accented text is more than five bytes (%d)", len(got))
	testing.expect_value(t, grapheme_snap(got, len(got)), len(got)) // ends on a boundary

	// …and a run of flags, where one character is eight bytes
	text_set(&v, "")
	s.caret, s.anchor = 0, 0
	input_replace(&ui, n, d, s, 0, 0, "🇬🇧🇫🇷🇩🇪🇪🇸🇮🇹🇯🇵🇺🇸")
	flags := str(v)
	testing.expect_value(t, grapheme_snap(flags, len(flags)), len(flags))
	testing.expectf(t, len(flags) <= 5 * 8, "no more than five flags' worth (%d bytes)", len(flags))
}

// Without a cap nothing changes.
@(test)
an_uncapped_field_takes_whatever_it_is_given :: proc(t: ^testing.T) {
	v: Text
	text_set(&v, "")
	defer text_destroy(&v)
	ui: Ui(Ic_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := ic_build(&ui, &v, 0, false)
	d := node_get(&ui.tree, n)
	s := &ui.tree.inputs[n]
	long := strings.repeat("y", 1000, context.temp_allocator)
	input_replace(&ui, n, d, s, 0, 0, long)
	testing.expect_value(t, len(str(v)), 1000)
}

// A right-click reaches the app with where it happened, and keeps an
// existing selection so the menu's Cut and Copy act on what was chosen.
@(test)
a_field_right_click_reaches_the_app :: proc(t: ^testing.T) {
	v: Text
	text_set(&v, "wss://chat.example")
	defer text_destroy(&v)
	ui: Ui(Ic_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := ic_build(&ui, &v, 0, true)
	r := node_get(&ui.tree, n).abs

	before := len(ui.msgs)
	took := input_context_press(&ui, {r.x + r.w / 2, r.y + r.h / 2})
	testing.expect(t, took, "the field took the right-click")
	got: Editor_Context
	for m in ui.msgs[before:] do if c, ok := m.(Editor_Context); ok do got = c
	testing.expect(t, got.at.x > 0, "and told the app where it was")
	testing.expect(t, !got.in_selection, "nothing was selected, so not on a selection")

	// with a selection under the pointer it says so, and keeps it
	s := &ui.tree.inputs[n]
	s.anchor, s.caret = 0, len(str(v))
	before = len(ui.msgs)
	input_context_press(&ui, {r.x + r.w / 2, r.y + r.h / 2})
	for m in ui.msgs[before:] do if c, ok := m.(Editor_Context); ok do got = c
	testing.expect(t, got.in_selection, "the click was on the selection")
	testing.expect_value(t, s.anchor, 0)
	testing.expect_value(t, s.caret, len(str(v))) // kept, not collapsed
}

// A field with no on_context does not swallow the right-click, so whatever
// is behind it still gets one.
@(test)
a_field_without_a_menu_lets_the_right_click_past :: proc(t: ^testing.T) {
	v: Text
	text_set(&v, "hello")
	defer text_destroy(&v)
	ui: Ui(Ic_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := ic_build(&ui, &v, 0, false)
	r := node_get(&ui.tree, n).abs
	testing.expect(t, !input_context_press(&ui, {r.x + r.w / 2, r.y + r.h / 2}),
		"it was given no on_context, so it takes nothing")
}

}
