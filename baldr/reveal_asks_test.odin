package baldr

@(require) import "core:testing"

// Who an ask is for, and how many can be waiting. Several asks in one update
// must all land rather than overwrite each other, and a list the toolkit
// builds for itself (the emoji picker's grid is `list(key = 4)`) must not
// claim an ask an app addressed to its own list of the same key.
//
// The collision is tested against the picker, not a table: `table` and
// `icon_view` build a fixed-pitch inner list, and the claim is inside
// `if list_varies(st^)`, so a list with one row height never takes an ask
// and a test against it would pass whatever the code did.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Ra_Msg :: union { int }

@(private = "file")
RA_APP   :: u64(4) // deliberately 4: the key the emoji picker's own grid uses
@(private = "file")
RA_OTHER :: u64(2)
@(private = "file")
ra_key_of :: proc(user: rawptr, index: int) -> u64 { return u64(index + 1) }

// ra_lists builds two plain lists, the app's own, and reports their nodes.
@(private = "file")
ra_lists :: proc(ui: ^Ui(Ra_Msg)) -> (a, b: Node) {
	set_viewport(&ui.tree, {400, 300})
	begin_view(ui)
	column(ui, flex = 1)
	list(ui, 200, estimated_height = 30, key_of = ra_key_of, flex = 1, label = "A", key = RA_APP)
	a = ui.scopes[len(ui.scopes) - 1].node
	end(ui)
	list(ui, 200, estimated_height = 30, key_of = ra_key_of, flex = 1, label = "B", key = RA_OTHER)
	b = ui.scopes[len(ui.scopes) - 1].node
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 300})
	return
}

// ra_picker_then_list builds the emoji picker *first* — whose grid is a
// measured list of its own, keyed 4 inside it — and then the app's own list,
// also keyed 4.
@(private = "file")
ra_picker_then_list :: proc(ui: ^Ui(Ra_Msg)) -> (app_list: Node) {
	set_viewport(&ui.tree, {400, 700})
	begin_view(ui)
	column(ui, flex = 1)
	emoji_picker(ui, nil, width = 340, height = 300, key = 9)
	list(ui, 200, estimated_height = 30, key_of = ra_key_of, flex = 1, label = "A", key = RA_APP)
	app_list = ui.scopes[len(ui.scopes) - 1].node
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 700})
	return
}

@(private = "file")
ra_offset :: proc(ui: ^Ui(Ra_Msg), n: Node) -> f32 {
	if sc := &ui.tree.scrolls[n]; sc != nil do return sc.offset.y
	return 0
}

// Both asks land. A reveal is refined over a few builds, so the test builds
// several times; neither ask may be thrown away by the other made in the
// same update.
@(test)
two_reveals_in_one_update_both_land :: proc(t: ^testing.T) {
	ui: Ui(Ra_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	a, b := ra_lists(&ui)
	testing.expect_value(t, ra_offset(&ui, a), 0)
	testing.expect_value(t, ra_offset(&ui, b), 0)

	// What `update` returning two commands at once comes to.
	reveal_put(&ui, Reveal_Ask{view = RA_APP, key = ra_key_of(nil, 150), at = 0.33})
	reveal_put(&ui, Reveal_Ask{view = RA_OTHER, key = ra_key_of(nil, 120), at = 0.33})
	testing.expect_value(t, len(ui.reveal_asks), 2) // neither overwrote the other

	for _ in 0 ..< LIST_REVEAL_TRIES + 1 do a, b = ra_lists(&ui)
	testing.expect(t, ra_offset(&ui, a) > 0, "the first list was placed")
	testing.expect(t, ra_offset(&ui, b) > 0, "and so was the second")
}

// Asking twice for the same view is the later one, not both: "show me row 4,
// no, row 9" has one answer.
@(test)
the_later_ask_for_a_view_replaces_the_earlier :: proc(t: ^testing.T) {
	ui: Ui(Ra_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	reveal_put(&ui, Reveal_Ask{view = RA_APP, key = 4, at = 0.33})
	reveal_put(&ui, Reveal_Ask{view = RA_APP, key = 9, at = 0.33})
	testing.expect_value(t, len(ui.reveal_asks), 1)
	testing.expect_value(t, ui.reveal_asks[0].key, u64(9))
}

// The app's list keeps its own reveal though the emoji picker built before
// it has a grid with the same key. The grid is a measured list, so it
// reaches the claim: this is the collision that can actually happen.
@(test)
a_pickers_grid_does_not_take_an_apps_reveal_for_a_list_of_the_same_key :: proc(t: ^testing.T) {
	ui: Ui(Ra_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	app_list := ra_picker_then_list(&ui)
	reveal_put(&ui, Reveal_Ask{view = RA_APP, key = ra_key_of(nil, 150), at = 0.33})
	for _ in 0 ..< LIST_REVEAL_TRIES + 1 do app_list = ra_picker_then_list(&ui)

	testing.expect(t, ra_offset(&ui, app_list) > 0,
		"the app's list was placed, not the picker's grid")
	testing.expect_value(t, len(ui.reveal_asks), 0) // and it was spent, not left waiting
}

// The same for a hold, where the key is all `hold_taken` matches on: there
// is no `by_index` to tell the two apart.
@(test)
a_pickers_grid_does_not_take_an_apps_hold_for_a_list_of_the_same_key :: proc(t: ^testing.T) {
	ui: Ui(Ra_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	// Scrolled away from the top first, so holding a row has somewhere to
	// hold it and a move is visible.
	app_list := ra_picker_then_list(&ui)
	reveal_put(&ui, Reveal_Ask{view = RA_APP, key = ra_key_of(nil, 150), at = 0.33})
	for _ in 0 ..< LIST_REVEAL_TRIES + 1 do app_list = ra_picker_then_list(&ui)
	placed := ra_offset(&ui, app_list)
	testing.expect(t, placed > 0, "placed before the hold is asked for")

	hold_put(&ui, Hold_Ask{view = RA_APP, key = ra_key_of(nil, 150), point = {0, 10}, at = {0, 100}})
	app_list = ra_picker_then_list(&ui)
	testing.expect_value(t, len(ui.hold_asks), 0) // claimed by somebody…
	testing.expect(t, ra_offset(&ui, app_list) != placed, "…and it was the app's list that moved")
}

// A view the toolkit builds for itself still gets the toolkit's own asks:
// the fence has two sides, and the emoji picker's grid is on the other one.
@(test)
a_widgets_own_view_takes_the_widgets_own_ask :: proc(t: ^testing.T) {
	ui: Ui(Ra_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	// An app's ask is refused while the toolkit is building one of its own…
	reveal_put(&ui, Reveal_Ask{view = RA_APP, key = 5, at = 0.33})
	view_inner_begin(&ui)
	_, taken := reveal_taken(&ui, RA_APP, by_index = false)
	testing.expect(t, !taken, "an app's ask does not land in a view of the toolkit's")
	view_inner_end(&ui)

	// …and taken by the app's own view, which is where it was addressed.
	ask, got := reveal_taken(&ui, RA_APP, by_index = false)
	testing.expect(t, got, "the app's view takes it")
	testing.expect_value(t, ask.key, u64(5))

	// The other way round: the toolkit's ask reaches only the toolkit's view.
	reveal_own(&ui, RA_APP, 6)
	_, wrong := reveal_taken(&ui, RA_APP, by_index = false)
	testing.expect(t, !wrong, "an app's view does not take the toolkit's ask")
	view_inner_begin(&ui)
	mine, ok := reveal_taken(&ui, RA_APP, by_index = false)
	view_inner_end(&ui)
	testing.expect(t, ok, "the toolkit's own view does")
	testing.expect_value(t, mine.key, u64(6))
}

// ------------------------------------------- asking from inside the build

// ra_build_asking builds the app's list, asking for a row either before the
// list or after it — the two orders a view can call `reveal_now` in, and the
// reason it exists: a book knows which row the chapter is only once the view
// has typeset it, which is after the list.
@(private = "file")
ra_build_asking :: proc(ui: ^Ui(Ra_Msg), row: u64, after: bool) -> (n: Node) {
	set_viewport(&ui.tree, {400, 300})
	begin_view(ui)
	column(ui, flex = 1)
	if row != 0 && !after do reveal_now(ui, RA_APP, row, at = 0)
	list(ui, 200, estimated_height = 30, key_of = ra_key_of, flex = 1, label = "A", key = RA_APP)
	n = ui.scopes[len(ui.scopes) - 1].node
	end(ui)
	if row != 0 && after do reveal_now(ui, RA_APP, row, at = 0)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 300})
	return
}

// Asked before the list: it lands in that build's layout.
@(test)
a_view_can_ask_for_a_row_before_it_builds_the_list :: proc(t: ^testing.T) {
	ui: Ui(Ra_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := ra_build_asking(&ui, 0, after = false)
	testing.expect_value(t, ra_offset(&ui, n), 0)

	n = ra_build_asking(&ui, ra_key_of(nil, 150), after = false)
	testing.expect(t, ra_offset(&ui, n) > 0, "placed by the build that asked")
	testing.expect_value(t, len(ui.reveal_asks), 0)
}

// Asked after the list: it lands in the next build, and the next build is
// asked for. Otherwise a view that learned its row late would wait for
// whatever rebuilt next, or for ever in an app sitting still.
@(test)
a_view_can_ask_for_a_row_after_it_has_built_the_list :: proc(t: ^testing.T) {
	ui: Ui(Ra_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := ra_build_asking(&ui, 0, after = false)
	ui.needs_rebuild = false

	n = ra_build_asking(&ui, ra_key_of(nil, 150), after = true)
	testing.expect_value(t, ra_offset(&ui, n), 0)        // too late for this build…
	testing.expect_value(t, len(ui.reveal_asks), 1)      // …so it is still waiting
	testing.expect(t, ui.needs_rebuild, "and the view is asked to run again for it")

	ui.needs_rebuild = false
	for _ in 0 ..< LIST_REVEAL_TRIES + 1 do n = ra_build_asking(&ui, 0, after = false)
	testing.expect(t, ra_offset(&ui, n) > 0, "the build after it places the row")
	testing.expect_value(t, len(ui.reveal_asks), 0)
}

// An ask that names another window is not this window's to take. From
// inside a build the window is already chosen, so this is the one place the
// toolkit can answer it at once rather than at dispatch.
@(test)
an_in_build_ask_for_another_window_is_not_made :: proc(t: ^testing.T) {
	ui: Ui(Ra_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.surface.tag = 2

	reveal_now(&ui, RA_APP, 5, surface = u64(3)) // another window's
	testing.expect_value(t, len(ui.reveal_asks), 0)
	reveal_now(&ui, RA_APP, 5, surface = u64(2)) // this one's
	testing.expect_value(t, len(ui.reveal_asks), 1)
	reveal_now(&ui, RA_OTHER, 5)                 // and nil is any
	testing.expect_value(t, len(ui.reveal_asks), 2)
}

// An ask no view claims is dropped after a few builds, each on its own
// count, so one waiting does not keep another alive.
@(test)
each_ask_ages_on_its_own :: proc(t: ^testing.T) {
	ui: Ui(Ra_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	reveal_put(&ui, Reveal_Ask{view = RA_APP, key = 1, at = 0.33})
	for _ in 0 ..< REVEAL_WAIT_BUILDS - 1 do reveal_sweep(&ui)
	reveal_put(&ui, Reveal_Ask{view = RA_OTHER, key = 2, at = 0.33}) // asked later
	reveal_sweep(&ui)
	testing.expect_value(t, len(ui.reveal_asks), 1) // the first gave up
	testing.expect_value(t, ui.reveal_asks[0].view, RA_OTHER)
	for _ in 0 ..< REVEAL_WAIT_BUILDS do reveal_sweep(&ui)
	testing.expect_value(t, len(ui.reveal_asks), 0)
}

// Which window. A multi-window app gives the same screen the same list key
// in each window, so an ask that goes to all of them is taken by whichever
// was built first, not the one the person is looking at. Naming the surface
// says which; nil is every window, which is what a one-window app wants.
@(test)
an_ask_can_name_the_window_it_is_for :: proc(t: ^testing.T) {
	testing.expect(t, ask_for_surface(nil, 0), "nil is every window")
	testing.expect(t, ask_for_surface(nil, 7), "…whatever its tag")
	testing.expect(t, ask_for_surface(u64(7), 7), "the window it names")
	testing.expect(t, !ask_for_surface(u64(7), 0), "and not another")
	// Tag 0 is a real tag — the default window's — so it cannot be the
	// "any" value, which is why this is a Maybe and not a sentinel.
	testing.expect(t, ask_for_surface(u64(0), 0), "tag 0 is a window like any other")
	testing.expect(t, !ask_for_surface(u64(0), 1), "…and names only itself")
}

} // when ODIN_TEST
