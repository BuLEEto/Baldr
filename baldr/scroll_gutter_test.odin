package baldr

@(require) import "core:fmt"
@(require) import "core:testing"

// A scroll's overlay scrollbar is drawn over the end of its own content, so
// a row with a button at its right end sits under the bar unless the scroll
// keeps a `gutter`.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Sg_Msg :: union { int }

@(private = "file")
sg_build :: proc(ui: ^Ui(Sg_Msg), rows: int, gutter: bool) -> (sc: Node, last_btn: Node) {
	set_viewport(&ui.tree, {420, 300})
	begin_view(ui)
	column(ui, flex = 1)
	sc = scroll(ui, .Column, height = 200, gutter = gutter, key = 1)
	for i in 0 ..< rows {
		row(ui, align = .Center, key = u64(i + 1))
		text(ui, fmt.tprintf("Server %d", i), flex = 1)
		last_btn = button(ui, "Remove", Sg_Msg(i), key = 99)
		end(ui)
	}
	end(ui) // scroll
	end(ui) // column
	end_view(ui)
	frame(&ui.tree, {420, 300})
	return
}

// A right-aligned control ends clear of the bar, by at least its width.
@(test)
a_gutter_keeps_a_right_aligned_control_clear_of_the_bar :: proc(t: ^testing.T) {
	ui: Ui(Sg_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	sc, btn := sg_build(&ui, 20, false)
	track, _, overflows := scrollbar_geometry(&ui.tree, sc)
	testing.expect(t, overflows, "twenty rows in 200 px overflows, so there is a bar")
	bare := node_get(&ui.tree, btn).abs
	testing.expectf(t, bare.x + bare.w > track.x,
		"without a gutter the button runs under the bar (ends %.0f, bar starts %.0f)", bare.x + bare.w, track.x)

	sc2, btn2 := sg_build(&ui, 20, true)
	track2, _, _ := scrollbar_geometry(&ui.tree, sc2)
	with := node_get(&ui.tree, btn2).abs
	testing.expectf(t, with.x + with.w <= track2.x,
		"with one it ends before the bar (ends %.0f, bar starts %.0f)", with.x + with.w, track2.x)
}

// The gutter is always there, not only while the content overflows.
// Reserving it on demand oscillates: narrowing the content wraps the text,
// which makes it taller, which can make it overflow when it did not.
@(test)
a_gutter_does_not_come_and_go_with_the_content :: proc(t: ^testing.T) {
	ui: Ui(Sg_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	_, few := sg_build(&ui, 2, true) // nothing overflows: no bar is drawn
	short := node_get(&ui.tree, few).abs
	_, many := sg_build(&ui, 20, true)
	long := node_get(&ui.tree, many).abs
	testing.expectf(t, short.x + short.w == long.x + long.w,
		"the content ends in the same place either way (%.0f vs %.0f)", short.x + short.w, long.x + long.w)
}

// Without a gutter the content runs to the scroll's end.
@(test)
a_scroll_without_a_gutter_is_unchanged :: proc(t: ^testing.T) {
	ui: Ui(Sg_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sc, btn := sg_build(&ui, 4, false)
	d := node_get(&ui.tree, sc).abs
	b := node_get(&ui.tree, btn).abs
	testing.expect_value(t, b.x + b.w, d.x + d.w) // flush with the container's end
}

}
