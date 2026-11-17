package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A submenu has no entrance or exit transition: it is there when the pointer
// rests on its row and gone when it leaves, as on every desktop. A fade
// would leave two on screen at once while running down a menu, one fading
// out as the next fades in.

@(private = "file")
Sm_Msg :: union { int }

@(test)
a_submenu_has_no_entrance_and_no_exit :: proc(t: ^testing.T) {
	ui: Ui(Sm_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	build :: proc(ui: ^Ui(Sm_Msg)) {
		set_viewport(&ui.tree, {600, 400})
		begin_view(ui)
		column(ui, padding = .md)
		if submenu(ui, "Sort by", key = 1) do end(ui)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {600, 400})
	}

	build(&ui)
	// `submenu` registers its row in `ui.open` as it creates it, which is
	// the only handle on it from here: a Node is a generation-tagged handle,
	// not an index, so the tree cannot be walked by counting.
	row := NODE_NONE
	for n in ui.open do row = n
	if !testing.expect(t, row != NODE_NONE, "the row was built") do return

	submenu_open(&ui, row, false)
	build(&ui)
	pop := ui.submenus[row]
	if !testing.expect(t, pop != NODE_NONE, "…and its submenu opened") do return

	d := node_get(&ui.tree, pop)
	if d == nil do testing.fail_now(t, "no popup node")
	// This *is* the behaviour: with neither transition there is nothing to
	// play, so the submenu is there at once and gone at once, and two are
	// never on screen together.
	testing.expect_value(t, d.style.enter.kind, Transition_Kind.None)
	testing.expect_value(t, d.style.exit.kind, Transition_Kind.None)
}

}
