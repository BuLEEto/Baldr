package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(test)
access_button_carries_role_and_name :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	b := button(&ui, "Save", Test_Msg.Inc)
	d := button(&ui, "Delete", Test_Msg.Dec, disabled = true)
	end_view(&ui)
	a := node_get(&ui.tree, b).access
	testing.expect_value(t, a.role, Role.Button)
	testing.expect_value(t, a.name, "Save")
	testing.expect(t, .Disabled in node_get(&ui.tree, d).access.states)
	testing.expect_value(t, lint(&ui.tree), 0)
}

@(test)
access_lint_flags_unnamed_interactive_nodes :: proc(t: ^testing.T) {
	tr: Tree
	tree_init(&tr)
	defer tree_destroy(&tr)
	n := node_new(&tr, Box_Kind{})
	node_get(&tr, n).access.role = .Button
	node_append(&tr, tr.root, n)
	testing.expect_value(t, lint(&tr), 1)
	testing.expect(t, strings.contains(tr.diags[0].msg, "accessible name"))
	testing.expect(t, tr.diags[0].loc.line > 0, "diag points at the creator")

	set_hidden(&tr, n, true)
	testing.expect_value(t, lint(&tr), 0)
}

@(test)
access_dump_shows_tree :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	column(&ui)
	text(&ui, "Title")
	button(&ui, "OK", Test_Msg.Inc)
	end(&ui)
	end_view(&ui)
	dump := access_dump(&ui.tree)
	testing.expect(t, strings.contains(dump, "Window\n"), dump)
	testing.expect(t, strings.contains(dump, "Text \"Title\""), dump)
	testing.expect(t, strings.contains(dump, "Button \"OK\""), dump)
	testing.expect(t, !strings.contains(dump, "Text \"OK\""), "button label is not a separate a11y node")
}

@(test)
access_lint_flags_too_transparent_glass :: proc(t: ^testing.T) {
	tr: Tree
	tree_init(&tr)
	defer tree_destroy(&tr)
	n := node_new(&tr, Box_Kind{})
	node_get(&tr, n).style.material = {tint = {0, 0, 0, 0.3}, blur = 20, saturation = 1}
	node_append(&tr, tr.root, n)
	testing.expect_value(t, lint(&tr), 1)
	testing.expect(t, strings.contains(tr.diags[0].msg, "glass"))
	node_get(&tr, n).style.material.tint.a = 0.72
	testing.expect_value(t, lint(&tr), 0)
}

@(private = "file")
Lint_Msg :: enum { None, Close }

// Glass the builders make over the app's own content passes the lint at
// every level, Clear's thin popover tint included (glass_in_app lifts it).
@(test)
access_lint_passes_the_builders_glass_at_every_level :: proc(t: ^testing.T) {
	for level in Glass_Level {
		ui: Ui(Lint_Msg)
		ui_init(&ui)
		th := theme_light()
		th.glass = level
		set_theme(&ui.tree, th)
		ui.tree.theme.motion.reduce = true
		begin_view(&ui)
		column(&ui, padding = .lg)
		anchor := button(&ui, "Open", Lint_Msg.None)
		card(&ui, glass = true)
		text(&ui, "On glass")
		end(&ui)
		end(&ui)
		if popover(&ui, anchor, true, Lint_Msg.Close) {
			text(&ui, "Inside")
			end(&ui)
		}
		end_view(&ui)
		frame(&ui.tree, {400, 300})
		testing.expectf(t, lint(&ui.tree) == 0, "%v: %v", level, ui.tree.diags[:])
		ui_destroy(&ui)
	}
}

} // when ODIN_TEST