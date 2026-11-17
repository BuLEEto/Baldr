package baldr

@(require) import "core:fmt"
@(require) import "core:testing"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// What an app says out loud while someone uses it: the row a cursor moved
// to inside a view that keeps the focus, what is selected now, and a live
// region that changed although nothing took focus.

@(private = "file")
Ave_Msg :: enum { None, Pick }

@(private = "file")
ave_grid :: proc(ui: ^Ui(Ave_Msg), sel: ^Selection, toast_text: string = "") -> Node {
	set_viewport(&ui.tree, {640, 480})
	begin_view(ui)
	column(ui, flex = 1)
	first, last := icon_view(ui, 12, sel, label = "Files", key = 3)
	for i in first ..< last do icon_item(ui, i, .File, fmt.tprintf("file-%d", i))
	end(ui)
	if toast_text != "" do toast(ui, toast_text, Ave_Msg.None, key = 77)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {640, 480})
	return node_first(&ui.tree, node_first(&ui.tree, ui.root))
}

// ave_sent is the last thing of one kind the toolkit said, and how many
// times it said one. The kind is a type, so a test naming a kind that no
// longer exists fails to compile rather than silently finding nothing.
@(private = "file")
ave_sent :: proc($T: typeid, events: []A11y_Said) -> (last: T, n: int) {
	for e in events do if v, is_kind := e.(T); is_kind {
		last = v
		n += 1
	}
	return
}

@(test)
a11y_says_which_row_the_cursor_is_on :: proc(t: ^testing.T) {
	ui: Ui(Ave_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	view := ave_grid(&ui, &sel)
	selection_set(&sel, 0)
	set_focus(&ui.tree, view, false)
	view = ave_grid(&ui, &sel) // the build is what names the cursor's row

	events := make([dynamic]A11y_Said, context.temp_allocator)
	a11y_test_window(&ui.tree, "Files")
	defer a11y_test_reset()
	a11y_test_watch(&events)

	a11y_events() // focus lands on the view, with a row already under its cursor
	view_id, _ := a11y_id(0, view)
	tile0, _ := a11y_id(0, node_get(&ui.tree, view).access.active)
	focus, focus_n := ave_sent(Said_Focus, events[:])
	testing.expect_value(t, focus_n, 1)
	testing.expect_value(t, focus.id, view_id)
	moved, moved_n := ave_sent(Said_Active_Item, events[:])
	testing.expect_value(t, moved_n, 1)
	testing.expect_value(t, moved.id, view_id) // the view says it: focus never left it
	testing.expect_value(t, moved.child, tile0)
	testing.expect_value(t, moved.index, 0)

	// the cursor moves: the view is still what has focus, so this is the
	// only thing that says which row is current now
	clear(&events)
	testing.expect(t, key_event(&ui, .Right, true, {}))
	ave_grid(&ui, &sel)
	a11y_events()
	moved, moved_n = ave_sent(Said_Active_Item, events[:])
	testing.expect_value(t, moved_n, 1)
	tile1, _ := a11y_id(0, node_get(&ui.tree, view).access.active)
	testing.expect_value(t, moved.child, tile1)
	testing.expect_value(t, moved.index, 1)
	testing.expect(t, tile1 != tile0, "a different row")
	_, picked := ave_sent(Said_Selection, events[:])
	testing.expect_value(t, picked, 1) // …and what is selected changed with it

	// the row under the cursor is where the keyboard is, and says so
	tile := node_get(&ui.tree, node_get(&ui.tree, view).access.active)
	testing.expect(t, .Focused in a11y_flags(&ui.tree, node_get(&ui.tree, view).access.active, tile))

	// nothing moved: nothing is said
	clear(&events)
	ave_grid(&ui, &sel)
	a11y_events()
	_, quiet := ave_sent(Said_Active_Item, events[:])
	testing.expect_value(t, quiet, 0)

	// selecting everything is a change to what is selected, not to the cursor
	clear(&events)
	testing.expect(t, key_event(&ui, .A, true, {.Ctrl}))
	ave_grid(&ui, &sel)
	a11y_events()
	_, all := ave_sent(Said_Selection, events[:])
	testing.expect_value(t, all, 1)
	testing.expect_value(t, selection_count(&sel), 12)
}

@(test)
a11y_announces_a_live_region :: proc(t: ^testing.T) {
	ui: Ui(Ave_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	ave_grid(&ui, &sel)

	events := make([dynamic]A11y_Said, context.temp_allocator)
	a11y_test_window(&ui.tree, "Files")
	defer a11y_test_reset()
	a11y_test_watch(&events)
	a11y_events() // nothing live yet

	// a toast appears: a reader hears it although nothing took focus
	ave_grid(&ui, &sel, "Copying 3 of 8")
	clear(&events)
	a11y_events()
	said, n := ave_sent(Said_Announce, events[:])
	testing.expect_value(t, n, 1)
	testing.expect_value(t, said.text, "Copying 3 of 8")
	testing.expect_value(t, said.assertive, false) // polite: it waits its turn

	// the same toast, unchanged: silence, not a repeat every wake-up
	clear(&events)
	ave_grid(&ui, &sel, "Copying 3 of 8")
	a11y_events()
	_, again := ave_sent(Said_Announce, events[:])
	testing.expect_value(t, again, 0)

	// it counts on: said again
	clear(&events)
	ave_grid(&ui, &sel, "Copying 8 of 8")
	a11y_events()
	said, n = ave_sent(Said_Announce, events[:])
	testing.expect_value(t, n, 1)
	testing.expect_value(t, said.text, "Copying 8 of 8")
}

// The window is the one frame a reader is shown: the tree's own root is not
// a second frame inside it, which a reader could not find an index for.
@(test)
a11y_shows_one_frame_and_not_the_root_node :: proc(t: ^testing.T) {
	ui: Ui(Ave_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	view := ave_grid(&ui, &sel, "Copying 3 of 8")
	a11y_test_window(&ui.tree, "Files")
	defer a11y_test_reset()

	_, root_is_object := a11y_obj(a11y_id_must(0, ui.tree.root))
	testing.expect(t, !root_is_object, "the tree's root is not an object of its own")
	_, overlay_is_object := a11y_obj(a11y_id_must(0, ui.tree.overlay))
	testing.expect(t, !overlay_is_object, "nor is the overlay")

	win_id, _ := a11y_id(0, NODE_NONE)
	win, _ := a11y_obj(win_id)
	testing.expect_value(t, win.role, A11y_Role.Window)
	view_node, _ := a11y_obj(a11y_id_must(0, view))
	testing.expect_value(t, view_node.parent, win_id) // the widget hangs off the window itself
	back, ok := a11y_obj_child(win_id, view_node.index)
	testing.expect(t, ok && back == a11y_id_must(0, view), "and the window has it where it says")
	// the toast lives in the overlay, and it too is the window's child
	toast_id, toast_ok := a11y_obj_child(win_id, win.child_count - 1)
	testing.expect(t, toast_ok)
	tn, _ := a11y_obj(toast_id)
	testing.expect_value(t, tn.role, A11y_Role.Status_Bar)
	testing.expect_value(t, tn.parent, win_id)
}

@(private = "file")
a11y_id_must :: proc(window: int, n: Node) -> u64 {
	id, _ := a11y_id(window, n)
	return id
}

// An object inside a hidden subtree is not an object. It still has a rect,
// but its parent does not list it, so a reader handed it could not place it.
@(test)
a11y_hands_over_nothing_from_inside_a_hidden_subtree :: proc(t: ^testing.T) {
	ui: Ui(Ave_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {400, 200})
	begin_view(&ui)
	column(&ui, flex = 1)
	wrap := column(&ui, key = 9)
	inner := button(&ui, "Save", Ave_Msg.None, key = 3)
	end(&ui)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 200})
	a11y_test_window(&ui.tree, "Files")
	defer a11y_test_reset()

	id, _ := a11y_id(0, inner)
	shown, have := a11y_obj(id)
	testing.expect(t, have && shown.index >= 0, "while it is shown it answers, with a place in its parent")

	set_hidden(&ui.tree, wrap, true)
	frame(&ui.tree, {400, 200})
	_, still := a11y_obj(id)
	testing.expect(t, !still, "under a hidden ancestor it is gone, not unplaceable")

	set_hidden(&ui.tree, wrap, false)
	frame(&ui.tree, {400, 200})
	back, again := a11y_obj(id)
	testing.expect(t, again && back.index >= 0, "and it comes back when the subtree does")
}

} // when ODIN_TEST