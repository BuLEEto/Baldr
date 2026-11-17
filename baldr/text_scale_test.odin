package baldr

@(require) import "core:testing"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// The desktop's text size ("Large Text" in GNOME, the text-size slider in
// Windows) reaches the toolkit: every text role, and every size an app sets
// itself, is drawn that much larger, and the layout follows.


@(private = "file")
Ts_Msg :: union { int }

@(private = "file")
text_scaled :: proc(t: ^Tree, scale: f32) {
	tree_a11y_prefs(t, A11y_Prefs{text_scale = scale})
}

@(test)
the_desktops_text_size_scales_every_role :: proc(t: ^testing.T) {
	ui: Ui(Ts_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	base := ui.tree.theme.type

	text_scaled(&ui.tree, 1.5)
	now := ui.tree.theme.type
	testing.expect_value(t, now.body.size, base.body.size * 1.5)
	testing.expect_value(t, now.display.size, base.display.size * 1.5)
	testing.expect_value(t, now.caption.size, base.caption.size * 1.5)
	testing.expect_value(t, now.label.weight, base.label.weight) // only the size moves

	text_scaled(&ui.tree, 1) // back to the theme as it was set
	testing.expect_value(t, ui.tree.theme.type.body.size, base.body.size)

	// a desktop asking for something absurd is clamped, not obeyed
	text_scaled(&ui.tree, 99)
	testing.expect_value(t, ui.tree.theme.type.body.size, base.body.size * TEXT_SCALE_MAX)
	text_scaled(&ui.tree, 0.01)
	testing.expect_value(t, ui.tree.theme.type.body.size, base.body.size * TEXT_SCALE_MIN)
	text_scaled(&ui.tree, 0) // nothing said: normal size
	testing.expect_value(t, ui.tree.theme.type.body.size, base.body.size)
}

@(test)
larger_text_lays_out_larger :: proc(t: ^testing.T) {
	ui: Ui(Ts_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make("a line of prose\nand another")
	defer document_destroy(&doc)
	view :: proc(ui: ^Ui(Ts_Msg), doc: ^Document, size: Maybe(f32) = nil) -> (label, btn, ed: Node) {
		begin_view(ui)
		column(ui, padding = .lg)
		label = text(ui, "Notes", role = .Title)
		btn = button(ui, "Save", Ts_Msg(1))
		ed = text_area(ui, doc, label = "Notes", width = 420, height = 200)
		editor_options(ui, ed, size = size)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {600, 600})
		return
	}
	label, btn, ed := view(&ui, &doc)
	_, s := editor_area(&ui.tree, ed)
	label_h, btn_h := node_get(&ui.tree, label).abs.h, node_get(&ui.tree, btn).abs.h
	line := area_line_h(&ui.tree, s, 0)

	text_scaled(&ui.tree, 1.5)
	view(&ui, &doc)
	testing.expect(t, node_get(&ui.tree, label).abs.h > label_h, "a title is taller")
	testing.expect(t, node_get(&ui.tree, btn).abs.h > btn_h, "a button grows with its label")
	testing.expect(t, area_line_h(&ui.tree, s, 0) > line, "and an editor's lines are taller")

	// a size the app chose itself follows the desktop too: 18 px at normal size
	view(&ui, &doc, size = 18)
	testing.expect_value(t, s.size, 18 * 1.5)
	text_scaled(&ui.tree, 1)
	view(&ui, &doc, size = 18)
	testing.expect_value(t, s.size, 18)
}

@(test)
the_text_size_is_read_from_the_desktop_and_the_environment :: proc(t: ^testing.T) {
	// what the desktop said
	prefs := a11y_prefs_of({text_scale = 1.25})
	testing.expect_value(t, prefs.text_scale, 1.25)
	testing.expect_value(t, text_scale_of(prefs), 1.25)
	// a desktop that says nothing means normal size
	testing.expect_value(t, text_scale_of(a11y_prefs_of({})), 1)
}

// The desktop's UI font size is followed as well as its text size: a Linux
// desktop states its font as "Cantarell 11", and the size counts. Baldr's
// type scale is drawn for 11 pt (its 15 px body is GTK's 11 pt), so 11
// changes nothing, and the two settings multiply, as GTK multiplies them.
@(test)
the_desktops_font_size_scales_text_as_its_text_size_does :: proc(t: ^testing.T) {
	near :: proc(a, b: f32) -> bool { return abs(a - b) < 0.001 }
	testing.expect_value(t, a11y_prefs_of({text_scale = 1, font_size = 11}).text_scale, 1)
	testing.expect(t, near(a11y_prefs_of({text_scale = 1, font_size = 13}).text_scale, 13.0 / 11.0), "13 pt is 18 % larger")
	testing.expect(t, near(a11y_prefs_of({text_scale = 1, font_size = 10}).text_scale, 10.0 / 11.0), "a 10 pt desktop draws smaller")
	testing.expect(t, near(a11y_prefs_of({text_scale = 1.25, font_size = 13}).text_scale, 1.25 * 13.0 / 11.0), "Large Text and a larger font, both")
	testing.expect_value(t, a11y_prefs_of({text_scale = 1.25}).text_scale, 1.25) // no size stated: the text size alone
	testing.expect(t, near(a11y_prefs_of({font_size = 13}).text_scale, 13.0 / 11.0), "a size with no text scale stated")
	testing.expect_value(t, a11y_prefs_of({text_scale = 1, font_size = 400}).text_scale, 2.5) // a description nobody meant

	// And what that does to the drawn text: every role, by the same ratio.
	ui: Ui(Ts_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	base := ui.tree.theme.type
	tree_a11y_prefs(&ui.tree, a11y_prefs_of({text_scale = 1, font_size = 13}))
	testing.expectf(t, near(ui.tree.theme.type.body.size, base.body.size * 13.0 / 11.0),
		"body %v at 13 pt (it is %v at 11)", ui.tree.theme.type.body.size, base.body.size)
	testing.expect(t, near(ui.tree.theme.type.caption.size, base.caption.size * 13.0 / 11.0), "and the caption with it")
}

// An app can state these settings instead of the toolkit reading the
// platform's channel for them: a desktop that keeps text size, reduce motion
// and reduce transparency in its own config file passes them on this way.
@(test)
an_app_can_set_the_accessibility_preferences :: proc(t: ^testing.T) {
	ui: Ui(Ts_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	base := ui.tree.theme.type.body.size

	set_a11y_prefs(&ui.tree, A11y_Prefs{text_scale = 1.5, reduce_motion = true, reduce_transparency = true})
	testing.expect(t, ui.tree.a11y_app, "the tree remembers that the app said")
	testing.expect_value(t, ui.tree.theme.type.body.size, base * 1.5)
	testing.expect(t, ui.tree.theme.motion.reduce, "reduce motion is folded in like the desktop's")
	testing.expect_value(t, ui.tree.theme.glass, Glass_Level.Solid)

	// a size the app set itself follows what the app asked for, as it
	// follows what the desktop asks for
	doc := document_make("prose")
	defer document_destroy(&doc)
	begin_view(&ui)
	ed := text_area(&ui, &doc, label = "Notes", width = 300, height = 120)
	editor_options(&ui, ed, size = 18)
	end_view(&ui)
	frame(&ui.tree, {400, 300})
	_, s := editor_area(&ui.tree, ed)
	testing.expect_value(t, s.size, 18 * 1.5)

	// and what the app said is what the tree runs with until it says otherwise
	set_a11y_prefs(&ui.tree, A11y_Prefs{text_scale = 1})
	testing.expect_value(t, ui.tree.theme.type.body.size, base)
	testing.expect(t, !ui.tree.theme.motion.reduce, "a preference turned off gives the theme back")
}

} // when ODIN_TEST