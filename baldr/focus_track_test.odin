package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// focus_track tells an app when the keyboard reaches or leaves a node. Tab
// moves the ring before any widget sees the key, so a `text_input` laid over
// a document's form field would otherwise never hear that it lost the
// keyboard; and Tab landing on the next field's row lets the app open an
// editor there.

@(private = "file")
Ft_Moved :: struct { tag: u64, has: bool, by_key: bool }
@(private = "file")
Ft_Msg :: union { Ft_Moved, int }

@(private = "file")
ft_moved :: proc(e: Ev(Focus_At)) -> Ft_Msg {
	return Ft_Moved{tag = e.tag, has = e.value.has, by_key = e.value.by_key}
}

// A field, and a row below it standing for the form's next field. `with_field`
// off builds the page without the field at all, as the app does when it takes
// the box away.
@(private = "file")
ft_build :: proc(ui: ^Ui(Ft_Msg), with_field := true) -> (field, row: Node) {
	set_viewport(&ui.tree, {400, 300})
	begin_view(ui)
	column(ui, flex = 1)
	if with_field {
		field = text_input(ui, nil, initial = "Ada", label = "Name", tag = 1, key = 1)
		focus_track(ui, field, ft_moved)
	}
	row = button(ui, "Address", Ft_Msg(2), tag = 2, key = 2)
	focus_track(ui, row, ft_moved)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 300})
	return
}

@(private = "file")
ft_moves :: proc(ui: ^Ui(Ft_Msg)) -> (out: [dynamic]Ft_Moved) {
	out = make([dynamic]Ft_Moved, context.temp_allocator)
	for m in ui.msgs do if v, is := m.(Ft_Moved); is do append(&out, v)
	clear(&ui.msgs)
	return
}

@(test)
focus_track_tells_a_field_the_keyboard_left_and_a_row_it_arrived :: proc(t: ^testing.T) {
	ui: Ui(Ft_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	field, row := ft_build(&ui)

	// The keyboard arrives on the field from the keyboard's own doing.
	set_focus(&ui.tree, field, true)
	ui_after_events(&ui, 1)
	moves := ft_moves(&ui)
	testing.expect_value(t, len(moves), 1)
	testing.expect_value(t, moves[0], Ft_Moved{tag = 1, has = true, by_key = true})

	// Reported once: nothing more while focus sits still.
	ui_after_events(&ui, 2)
	testing.expect_value(t, len(ft_moves(&ui)), 0)

	// Tab: the field hears it lost the keyboard, then the row hears it has
	// it — in that order, because the draft must reach the document before
	// anything opens an editor on the next field.
	testing.expect(t, key_event(&ui, .Tab, true, {}), "Tab moves the ring")
	ui_after_events(&ui, 3)
	moves = ft_moves(&ui)
	testing.expect_value(t, len(moves), 2)
	testing.expect_value(t, moves[0], Ft_Moved{tag = 1, has = false, by_key = true})
	testing.expect_value(t, moves[1], Ft_Moved{tag = 2, has = true, by_key = true})
	testing.expect_value(t, ui.tree.focus, row)
}

// A click is not Tab: `by_key` is how a form tells "the keyboard reached this
// field, open its editor" from "the person clicked it", which says so itself.
@(test)
focus_track_says_whether_the_move_was_the_keyboards :: proc(t: ^testing.T) {
	ui: Ui(Ft_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	field, _ := ft_build(&ui)
	r := node_get(&ui.tree, field).abs
	pos := [2]f32{r.x + r.w / 2, r.y + r.h / 2}
	pointer_button(&ui, .Left, true, pos)
	pointer_button(&ui, .Left, false, pos)
	ui_after_events(&ui, 1)
	moves := ft_moves(&ui)
	testing.expect_value(t, len(moves), 1)
	testing.expect_value(t, moves[0], Ft_Moved{tag = 1, has = true, by_key = false})
}

// The *window* losing the keyboard is not the field losing it: focus stays
// where it was and comes back to it, so a field must not give its words away
// and vanish because the person alt-tabbed to another window.
@(test)
focus_track_says_nothing_when_the_window_loses_the_keyboard :: proc(t: ^testing.T) {
	ui: Ui(Ft_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	field, _ := ft_build(&ui)
	set_focus(&ui.tree, field, true)
	ui_after_events(&ui, 1)
	_ = ft_moves(&ui)

	tree_keyboard_set(&ui.tree, false)
	ui_after_events(&ui, 2)
	testing.expect_value(t, len(ft_moves(&ui)), 0)
	testing.expect_value(t, ui.tree.focus, field) // still where it was
	tree_keyboard_set(&ui.tree, true)
	ui_after_events(&ui, 3)
	testing.expect_value(t, len(ft_moves(&ui)), 0)
}

// The app takes the box away in the build after it hears the blur, so the
// node that had the keyboard is destroyed. Nothing is reported for a node
// that no longer exists, and nothing reads freed state doing it.
@(test)
focus_track_is_quiet_when_the_focused_node_is_destroyed :: proc(t: ^testing.T) {
	ui: Ui(Ft_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	field, _ := ft_build(&ui)
	set_focus(&ui.tree, field, true)
	ui_after_events(&ui, 1)
	_ = ft_moves(&ui)

	ft_build(&ui, with_field = false) // the box goes
	ui_after_events(&ui, 2)
	testing.expect_value(t, len(ft_moves(&ui)), 0)
	testing.expect_value(t, len(ui.on_focus), 1) // only the row's registration is left
}

}
