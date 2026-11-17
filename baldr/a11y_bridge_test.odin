package baldr

@(require) import "core:testing"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// What a screen reader walks: the application, its windows, and the tree
// underneath. These call the same provider the bridge calls, with no bus in
// sight, so they say what a screen reader would be told.

@(private = "file")
with_window :: proc(ui: ^Ui(Test_Msg), title: string) {
	a11y_test_window(&ui.tree, title)
}

@(private = "file")
forget_windows :: proc() {
	a11y_test_reset()
}

@(private = "file")
kid :: proc(t: ^testing.T, id: u64, index: int) -> (A11y_Obj, bool) {
	child, have := a11y_obj_child(id, index)
	if !have do return {}, false
	return a11y_obj(child)
}

@(private = "file")
A11yBridge_Seen :: struct {
	role:   A11y_Role,
	name:   string,
	id:     u64,
	parent: u64,
	flags:  A11y_Flags,
	size:   [2]i32,
}

// collect walks from `id` the way a reader does: children by index, each one
// asked what it is.
@(private = "file")
collect :: proc(id: u64, out: ^[dynamic]A11yBridge_Seen) {
	n, ok := a11y_obj(id)
	if !ok do return
	for i in 0 ..< n.child_count {
		cid, have := a11y_obj_child(id, i)
		if !have do continue
		c, cok := a11y_obj(cid)
		if !cok do continue
		append(out, A11yBridge_Seen{role = c.role, name = c.name, id = cid, parent = c.parent, flags = c.flags, size = {c.extents[2], c.extents[3]}})
		collect(cid, out)
	}
}

@(private = "file")
seen_named :: proc(all: []A11yBridge_Seen, name: string) -> (A11yBridge_Seen, bool) {
	for s in all do if s.name == name do return s, true
	return {}, false
}

@(test)
a11y_bridge_walks_the_tree :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	column(&ui)
	text(&ui, "Title")
	button(&ui, "OK", Test_Msg.Inc)
	button(&ui, "Away", Test_Msg.Dec, disabled = true)
	end(&ui)
	end_view(&ui)
	layout(&ui.tree, {800, 600}) // a reader asks where things are: they have to have been placed
	with_window(&ui, "Notes")
	defer forget_windows()

	app, have_app := a11y_obj(A11Y_APP_ID)
	testing.expect(t, have_app, "the application answers")
	testing.expect_value(t, app.role, A11y_Role.Application)
	testing.expect_value(t, app.name, "Test App")
	testing.expect_value(t, app.child_count, 1)

	win, have_win := kid(t, A11Y_APP_ID, 0)
	testing.expect(t, have_win, "the window answers")
	testing.expect_value(t, win.role, A11y_Role.Window)
	testing.expect_value(t, win.name, "Notes")
	testing.expect(t, .Active in win.flags, "the focused window reads as active")
	testing.expect_value(t, win.parent, A11Y_APP_ID)
	testing.expect(t, win.child_count > 0, "the window has the view under it")

	all := make([dynamic]A11yBridge_Seen, context.temp_allocator)
	collect(win.id, &all)

	ok_button, found := seen_named(all[:], "OK")
	testing.expect(t, found, "the button is in the tree a reader walks")
	if found {
		testing.expect_value(t, ok_button.role, A11y_Role.Button)
		testing.expect(t, .Enabled in ok_button.flags && .Sensitive in ok_button.flags, "a live button reads as enabled")
		testing.expect(t, .Focusable in ok_button.flags, "a button can take focus")
		testing.expect(t, ok_button.size.x > 0 && ok_button.size.y > 0, "it has a size")
	}

	away, found_away := seen_named(all[:], "Away")
	testing.expect(t, found_away, "a disabled button is still there to be read")
	if found_away do testing.expect(t, .Enabled not_in away.flags && .Sensitive not_in away.flags, "and reads as dimmed")

	title, found_title := seen_named(all[:], "Title")
	testing.expect(t, found_title, "so is the text")
	if found_title do testing.expect(t, title.role == .Static || title.role == .Label, "text reads as text")

	// every object points back at a parent that answers, up to the window,
	// and that parent has it among its children at exactly the index it
	// reports: the check a screen reader makes to work out where it is
	for s in all {
		parent, parent_ok := a11y_obj(s.parent)
		testing.expectf(t, parent_ok, "%q's parent answers", s.name)
		if !parent_ok do continue
		self, self_ok := a11y_obj(s.id)
		testing.expectf(t, self_ok && self.index >= 0 && self.index < parent.child_count,
			"%q says it is child %d of %d", s.name, self.index, parent.child_count)
		if !self_ok || self.index < 0 do continue
		back, back_ok := a11y_obj_child(s.parent, self.index)
		testing.expectf(t, back_ok && back == s.id, "%q is where it says it is in its parent", s.name)
	}
}

@(test)
a11y_bridge_hides_what_the_tree_hides :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	column(&ui)
	secret := button(&ui, "Secret", Test_Msg.Inc)
	button(&ui, "Shown", Test_Msg.Dec)
	end(&ui)
	end_view(&ui)
	layout(&ui.tree, {800, 600})
	set_hidden(&ui.tree, secret, true)
	with_window(&ui, "Notes")
	defer forget_windows()

	win, _ := kid(t, A11Y_APP_ID, 0)
	all := make([dynamic]A11yBridge_Seen, context.temp_allocator)
	collect(win.id, &all)
	_, secret_there := seen_named(all[:], "Secret")
	testing.expect(t, !secret_there, "a hidden node is not on the accessibility bus")
	_, shown_there := seen_named(all[:], "Shown")
	testing.expect(t, shown_there, "its sibling still is")
}

@(test)
a11y_bridge_id_survives_a_rebuild_and_a_freed_node_does_not :: proc(t: ^testing.T) {
	// The id carries the node handle's generation: a slot that is freed and
	// reused answers nothing rather than answering as the wrong widget.
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	b := button(&ui, "OK", Test_Msg.Inc)
	end_view(&ui)
	with_window(&ui, "Notes")
	defer forget_windows()

	id, packed := a11y_id(0, b)
	testing.expect(t, packed, "a node can be named")
	n, ok := a11y_obj(id)
	testing.expect(t, ok, "and answers")
	testing.expect_value(t, n.name, "OK")

	window, node, unpacked := a11y_unpack(id)
	testing.expect(t, unpacked)
	testing.expect_value(t, window, 0)
	testing.expect_value(t, node, b)

	stale := node_make(node_index(b), node_gen(b) + 1) // the same slot, one life later
	stale_id, _ := a11y_id(0, stale)
	testing.expect(t, stale_id != id, "a reused slot is a different id")
	_, still_there := a11y_obj(stale_id)
	testing.expect(t, !still_there, "an id from a past life is defunct, not someone else")
}


// A radio group's items must carry their own name and the Radio_Button
// role: a reader handed a nameless control says "empty".
@(test)
a11y_names_every_radio_in_a_group :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	column(&ui, flex = 1)
	group := radio(&ui, 2, {"Apple", "Banana", "Cherry"}, label = "Fruit")
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 300})
	with_window(&ui, "Fruit")
	defer a11y_test_reset()

	gid, _ := a11y_id(0, group)
	g, ok := a11y_obj(gid)
	testing.expect(t, ok, "the group is exposed")
	testing.expect_value(t, g.child_count, 3)

	want := [3]string{"Apple", "Banana", "Cherry"}
	for i in 0 ..< 3 {
		kid, got := a11y_obj_child(gid, i)
		testing.expect(t, got)
		n, have := a11y_obj(kid)
		testing.expect(t, have)
		testing.expect_value(t, n.role, A11y_Role.Radio_Button)
		testing.expect_value(t, n.name, want[i])
		// …and nothing inside it: the dot and the label are how the control
		// is drawn, and a reader handed either as an object of its own lands
		// on something nameless and reads it as "empty".
		testing.expect_value(t, n.child_count, 0)
	}
}

} // when ODIN_TEST