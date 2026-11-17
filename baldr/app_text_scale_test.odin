package baldr

@(require) import "core:testing"

// An app's own S / M / L / XL text setting goes through `set_text_scale`.
// `set_a11y_prefs` takes all three preferences over and stops the desktop's
// reaching the tree, so a text size set that way would also switch off the
// person's reduce-motion and reduce-transparency.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
ats_msg :: struct {}

// The app's factor multiplies the desktop's. Someone running Large Text
// has said something about their eyes; an app's "Medium" must not take it
// away from them.
@(test)
an_apps_text_scale_multiplies_the_desktops :: proc(t: ^testing.T) {
	ui: Ui(int)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree

	testing.expect_value(t, text_scale(tr), f32(1))

	tree_a11y_prefs(tr, A11y_Prefs{text_scale = 1.5}) // the desktop: Large Text
	testing.expect_value(t, text_scale(tr), f32(1.5))

	set_text_scale(tr, 1.25) // …and the app: L
	testing.expect_value(t, text_scale(tr), f32(1.5 * 1.25))

	set_text_scale(tr, 1) // back to M: the desktop's is untouched
	testing.expect_value(t, text_scale(tr), f32(1.5))
}

// A size the app sets itself follows the whole text scale, the app's part
// included, as the type scale's steps do; and a size left to the theme is
// scaled once, not again on top of the step it comes from.
@(test)
an_explicit_size_follows_the_apps_text_scale_too :: proc(t: ^testing.T) {
	ui: Ui(int)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree
	build :: proc(ui: ^Ui(int)) -> (fixed, role: Node, term: f32) {
		@(static) screen: Term_Screen
		begin_view(ui)
		column(ui)
		fixed = text(ui, "eighteen", size = 18)
		role = text(ui, "body")
		tn := terminal(ui, &screen)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {400, 300})
		return fixed, role, ui.tree.terminals[tn].size
	}
	tree_a11y_prefs(tr, A11y_Prefs{text_scale = 1.5})
	set_text_scale(tr, 2)
	fixed, role, term := build(&ui)
	testing.expect_value(t, node_get(tr, fixed).kind.(Text_Kind).size, 18 * 1.5 * 2)
	testing.expect_value(t, node_get(tr, role).kind.(Text_Kind).size, tr.theme.type.body.size)
	testing.expect_value(t, term, tr.theme.type.body.size) // the terminal's default: scaled once
	testing.expect_value(t, tr.theme.type.body.size, theme_light().type.body.size * 1.5 * 2)
}

// Reduce-motion and reduce-transparency keep following the desktop, and a
// later change from the desktop still lands, which `set_a11y_prefs` stops.
@(test)
an_apps_text_scale_leaves_the_other_preferences_to_the_desktop :: proc(t: ^testing.T) {
	ui: Ui(int)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree

	tree_a11y_prefs(tr, A11y_Prefs{reduce_motion = true, reduce_transparency = true})
	set_text_scale(tr, 1.25)

	testing.expect(t, tr.theme.motion.reduce, "reduce motion still holds")
	testing.expect(t, a11y_prefs(tr).reduce_motion, "and is still the desktop's to say")
	testing.expect(t, a11y_prefs(tr).reduce_transparency, "so is reduce transparency")
	testing.expect(t, !tr.a11y_app, "the app has NOT taken the preferences over")

	// the desktop turns reduce-motion off again: it reaches the tree
	tree_a11y_prefs(tr, A11y_Prefs{reduce_transparency = true})
	testing.expect(t, !tr.theme.motion.reduce, "the desktop's change landed")
	testing.expectf(t, text_scale(tr) == 1.25, "and the app's text size survived it (%.2f)", text_scale(tr))
}

// Neither setting can make the other unreadable: the product is clamped.
@(test)
the_two_text_scales_together_stay_within_bounds :: proc(t: ^testing.T) {
	ui: Ui(int)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree

	tree_a11y_prefs(tr, A11y_Prefs{text_scale = 3})
	set_text_scale(tr, 3)
	testing.expect_value(t, text_scale(tr), TEXT_SCALE_MAX)

	set_text_scale(tr, 0.1)
	tree_a11y_prefs(tr, A11y_Prefs{text_scale = 0.5})
	testing.expect_value(t, text_scale(tr), TEXT_SCALE_MIN)
}

// It really changes the type scale, not just the number.
@(test)
setting_the_apps_text_scale_resizes_the_text :: proc(t: ^testing.T) {
	ui: Ui(int)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree
	before := tr.theme.type.body.size
	set_text_scale(tr, 1.5)
	after := tr.theme.type.body.size
	testing.expectf(t, after > before * 1.4, "body text grew with the app's scale (%.1f -> %.1f)", before, after)
}

}
