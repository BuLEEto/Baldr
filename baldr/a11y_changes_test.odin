package baldr

@(require) import "core:testing"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// The bookkeeping behind "something changed over there": which objects the
// reader is holding, what we noticed about them, and what we say when a
// child arrives or one goes away. (The events themselves need a bus; these
// check the decisions that produce them.)


@(private = "file")
with_window :: proc(ui: ^Ui(Test_Msg)) {
	a11y_test_window(&ui.tree)
}

@(private = "file")
forget :: proc() {
	a11y_test_reset()
}

@(test)
a11y_remembers_only_what_the_reader_asked_about :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	column(&ui)
	save := button(&ui, "Save", Test_Msg.Inc)
	button(&ui, "Quit", Test_Msg.Dec)
	end(&ui)
	end_view(&ui)
	layout(&ui.tree, {400, 200})
	with_window(&ui)
	defer forget()

	testing.expect_value(t, len(a11y.known), 0) // nobody has asked anything yet

	id, _ := a11y_id(0, save)
	a11y_obj(id) // the reader asks about one button
	testing.expect_value(t, len(a11y.known), 1)
	testing.expect(t, id in a11y.known, "the one it asked about")

	// what we ask ourselves during a sweep is not the reader asking
	a11y.sweeping = true
	quit_id, _ := a11y_id(0, button_of(&ui, "Quit"))
	a11y_obj(quit_id)
	a11y.sweeping = false
	testing.expect_value(t, len(a11y.known), 1)
}

@(private = "file")
button_of :: proc(ui: ^Ui(Test_Msg), name: string) -> Node {
	for d, i in ui.tree.nodes {
		if .Alive in d.flags && d.access.name == name do return node_make(u32(i), d.gen)
	}
	return NODE_NONE
}

@(test)
a11y_sees_a_change_away_from_the_keyboard :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	view :: proc(ui: ^Ui(Test_Msg), label: string, on: bool) -> Node {
		begin_view(ui)
		column(ui)
		n := checkbox(ui, on, label, Test_Msg.Inc)
		end(ui)
		end_view(ui)
		layout(&ui.tree, {400, 200})
		return n
	}
	box := view(&ui, "Wrap", false)
	with_window(&ui)
	defer forget()

	id, _ := a11y_id(0, box)
	a11y_obj(id)
	seen := &a11y.known[id]
	testing.expect(t, .Checked not_in seen.flags, "as the reader last heard it")

	// the app changes it while focus is elsewhere
	view(&ui, "Wrap lines", true)
	d := node_get(&ui.tree, box)
	testing.expect(t, d != nil)
	a11y_seen_diff(id, &ui.tree, box, d, seen) // no bus in a test: the events go nowhere, the picture updates
	testing.expect(t, .Checked in seen.flags, "the change was noticed")
	testing.expect_value(t, seen.name, "Wrap lines")
}

@(test)
a11y_says_which_child_arrived_and_which_went :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	rows :: proc(ui: ^Ui(Test_Msg), n: int) {
		begin_view(ui)
		column(ui)
		for i in 0 ..< n do button(ui, fmt_row(i), Test_Msg.Inc, key = u64(i + 1))
		end(ui)
		end_view(ui)
		layout(&ui.tree, {400, 400})
	}
	rows(&ui, 2)
	with_window(&ui)
	defer forget()

	win_id, _ := a11y_id(0, NODE_NONE)
	a11y_obj(win_id)
	seen := &a11y.known[win_id]
	testing.expect_value(t, len(seen.kids), 2)

	rows(&ui, 3) // a row arrives
	kids := make([dynamic]u64, context.temp_allocator)
	a11y_kid_ids(&ui.tree, NODE_NONE, win_id, &kids)
	testing.expect_value(t, len(kids), 3)
	testing.expect(t, !a11y_same_kids(kids[:], seen.kids[:]), "the children are not what they were")

	// …and the first two are the same objects, so only the third is news
	testing.expect_value(t, kids[0], seen.kids[0])
	testing.expect_value(t, kids[1], seen.kids[1])
}

@(private = "file")
fmt_row :: proc(i: int) -> string {
	names := [4]string{"One", "Two", "Three", "Four"}
	return names[i % 4]
}

@(test)
a11y_forgets_an_object_that_has_gone :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	column(&ui)
	doomed := button(&ui, "Temporary", Test_Msg.Inc)
	end(&ui)
	end_view(&ui)
	layout(&ui.tree, {400, 200})
	with_window(&ui)
	defer forget()

	id, _ := a11y_id(0, doomed)
	a11y_obj(id)
	testing.expect_value(t, len(a11y.known), 1)

	// it is not built this time round
	begin_view(&ui)
	column(&ui)
	end(&ui)
	end_view(&ui)
	layout(&ui.tree, {400, 200})

	_, still := a11y_obj(id)
	testing.expect(t, !still, "the id names nothing now")
	a11y_sweep() // no bridge in a test: the sweep still clears its books
	testing.expect_value(t, len(a11y.known), 0)
	testing.expect_value(t, len(a11y.order), 0)
}

@(test)
a11y_action_and_selection_are_offered_where_they_mean_something :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	column(&ui)
	b := button(&ui, "Save", Test_Msg.Inc)
	off := button(&ui, "Away", Test_Msg.Dec, disabled = true)
	label := text(&ui, "Just words")
	end(&ui)
	end_view(&ui)
	layout(&ui.tree, {400, 200})
	with_window(&ui)
	defer forget()

	id, _ := a11y_id(0, b)
	n, _ := a11y_obj(id)
	testing.expect(t, n.has_action, "a button can be pressed for someone")

	off_id, _ := a11y_id(0, off)
	n, _ = a11y_obj(off_id)
	testing.expect(t, !n.has_action, "a dimmed one cannot")

	label_id, _ := a11y_id(0, label)
	n, _ = a11y_obj(label_id)
	testing.expect(t, !n.has_action, "and text is not pressable")
	testing.expect(t, !n.has_selection)

	// with no way back into the run loop (as in a test), acting fails
	// rather than pretending
	testing.expect(t, !a11y_do_action(id), "nothing to act through")
}

} // when ODIN_TEST