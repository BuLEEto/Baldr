package baldr

@(require) import "core:fmt"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A slider that scrubs: the drag owns the value, a commit on letting go
// (and on each key), marks along the track, and the value as a reader
// reads it.


@(private = "file")
Sc_Msg :: union { Sc_Change, Sc_Commit }
@(private = "file") Sc_Change :: struct { v: f32 }
@(private = "file") Sc_Commit :: struct { v: f32 }

@(private = "file")
clock :: proc(v: f32) -> string {
	s := int(v)
	return fmt.tprintf("%d:%02d", s / 60, s % 60)
}

// seek: a 10-minute track, the player reporting `pos`, chapters at 2, 5 and 8 minutes
@(private = "file")
seek :: proc(ui: ^Ui(Sc_Msg), pos: f32, now: f64) -> Node {
	ui.tree.now_ms = now
	begin_view(ui)
	column(ui, padding = f32(40))
	n := slider(ui, pos, 0, 600, on_change = proc(e: Ev(f32)) -> Sc_Msg { return Sc_Change{e.value} },
		on_commit = proc(e: Ev(f32)) -> Sc_Msg { return Sc_Commit{e.value} }, width = 400, label = "Position", key = 1)
	slider_options(ui, n, marks = []f32{120, 300, 480}, format = clock)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 200})
	return n
}

@(private = "file")
x_of :: proc(ui: ^Ui(Sc_Msg), n: Node, v: f32) -> [2]f32 {
	d := node_get(&ui.tree, n)
	inner := d.abs.w - SLIDER_THUMB
	return {d.abs.x + SLIDER_THUMB / 2 + inner * v / 600, d.abs.y + d.abs.h / 2}
}

@(private = "file")
commits :: proc(ui: ^Ui(Sc_Msg)) -> (out: [dynamic]f32) {
	out = make([dynamic]f32, context.temp_allocator)
	for m in ui.msgs do if c, ok := m.(Sc_Commit); ok do append(&out, c.v)
	return
}

@(test)
a_dragged_slider_owns_its_value_and_commits_on_letting_go :: proc(t: ^testing.T) {
	ui: Ui(Sc_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := seek(&ui, 30, 1000)
	st := &ui.tree.sliders[n]

	pointer_move(&ui, x_of(&ui, n, 30))
	pointer_button(&ui, .Left, true, x_of(&ui, n, 30))
	pointer_move(&ui, x_of(&ui, n, 240))
	testing.expect(t, abs(st.value - 240) < 1, "dragged to 4:00")
	seek(&ui, 31, 1250) // the player's 4 Hz position, mid-drag
	testing.expect(t, abs(st.value - 240) < 1, "the drag owns the value: the player does not pull the thumb away")
	testing.expect_value(t, len(commits(&ui)), 0) // nothing to seek to yet
	pointer_button(&ui, .Left, false, x_of(&ui, n, 240))
	c := commits(&ui)
	testing.expect(t, len(c) == 1 && abs(c[0] - 240) < 1, "let go: one commit, at 4:00")

	seek(&ui, 31.5, 1400) // the player has not landed the seek yet
	testing.expect(t, abs(st.value - 240) < 1, "the committed value stands against the old position")
	seek(&ui, 240.3, 1500) // it landed
	testing.expect(t, abs(st.value - 240.3) < 0.01, "the player's again")
	seek(&ui, 241, 1750)
	testing.expect(t, abs(st.value - 241) < 0.01, "and it follows the player")

	clear(&ui.msgs) // a seek that never lands stands only a moment
	pointer_button(&ui, .Left, true, x_of(&ui, n, 480))
	pointer_button(&ui, .Left, false, x_of(&ui, n, 480))
	seek(&ui, 241.25, 2000)
	testing.expect(t, abs(st.value - 480) < 1, "held")
	seek(&ui, 241.5, 2000 + SLIDER_HOLD_MS + 1)
	testing.expect(t, abs(st.value - 241.5) < 0.01, "a second on, the player's value again")
}

@(test)
a_sliders_keys_commit_and_step_between_marks :: proc(t: ^testing.T) {
	ui: Ui(Sc_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := seek(&ui, 200, 1000)
	st := &ui.tree.sliders[n]
	set_focus(&ui.tree, n, true)

	key_event(&ui, .Right, true, {})
	c := commits(&ui)
	testing.expect(t, len(c) == 1 && abs(c[0] - 206) < 0.01, "a key's step is its own commit")
	clear(&ui.msgs)
	key_event(&ui, .Right, true, {.Ctrl})
	testing.expect(t, abs(st.value - 300) < 0.01, "Ctrl+Right: the next chapter")
	key_event(&ui, .Right, true, {.Ctrl})
	testing.expect(t, abs(st.value - 480) < 0.01, "and the one after")
	key_event(&ui, .Left, true, {.Ctrl})
	testing.expect(t, abs(st.value - 300) < 0.01, "Ctrl+Left: back one")
	key_event(&ui, .Left, true, {.Ctrl})
	key_event(&ui, .Left, true, {.Ctrl})
	testing.expect(t, abs(st.value - 0) < 0.01, "before the first chapter: the start")
	testing.expect_value(t, len(commits(&ui)), 5)
}

// The marks are ticked across the track, in the fill's own ink where the
// value has passed them. The value reads as the app formats it, for
// assistive technology and above the pointer — kept, so the kept draw list
// still says it after the frame's temp memory has gone.
@(test)
a_slider_shows_its_marks_and_its_value_as_read :: proc(t: ^testing.T) {
	ui: Ui(Sc_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := seek(&ui, 200, 1000)
	d := node_get(&ui.tree, n)
	testing.expect_value(t, d.access.value_text, "3:20")
	ticks, passed := 0, 0
	for c in draw_list(&ui.tree) do if r, ok := c.(Draw_Rect); ok && r.rect.w == 2 {
		ticks += 1
		if r.color == ui.tree.theme.color.on_primary do passed += 1
	}
	testing.expect_value(t, ticks, 3)
	testing.expect_value(t, passed, 1) // 2:00 is behind 3:20

	pointer_move(&ui, x_of(&ui, n, 450)) // resting over 7:30
	frame(&ui.tree, {600, 200})
	free_all(context.temp_allocator)
	junk := make([]u8, 1 << 14, context.temp_allocator)
	for &b in junk do b = 'X'
	found := false
	for c in draw_list(&ui.tree) do if tx, ok := c.(Draw_Text); ok && tx.str == "7:30" do found = true
	testing.expect(t, found, "7:30 above the pointer, still after the frame's memory has gone")
	pointer_leave(&ui)
	frame(&ui.tree, {600, 200})
	found = false
	for c in draw_list(&ui.tree) do if tx, ok := c.(Draw_Text); ok && tx.str == "7:30" do found = true
	testing.expect(t, !found, "gone with the pointer")
}

} // when ODIN_TEST