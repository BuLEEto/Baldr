package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A select is a box of a fixed width: its label is cut with "…" where it
// does not fit, never wrapped to a second line, however large the text or
// long the option.


@(private = "file")
Sl_Msg :: union { int }

@(private = "file")
OPTIONS :: [?]string{"Short", "A rather long option that will not fit in a narrow select"}

@(private = "file")
view :: proc(ui: ^Ui(Sl_Msg), pick: int, width: f32) -> Node {
	opts := OPTIONS
	begin_view(ui)
	column(ui, padding = .lg)
	n := select(ui, pick, opts[:], width = width, label = "Pick")
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	return n
}

@(test)
a_select_can_be_as_wide_as_its_options :: proc(t: ^testing.T) {
	ui: Ui(Sl_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	fitted := view(&ui, 0, 0) // width 0: as wide as it needs
	wide := node_get(&ui.tree, fitted).abs.w
	testing.expect(t, wide > 100, "it measured its options rather than collapsing")
	testing.expect(t, wide <= SELECT_FIT_MAX, "…and is capped")

	// the widest option decides, so picking does not resize it
	picked := view(&ui, 1, 0)
	testing.expect_value(t, node_get(&ui.tree, picked).abs.w, wide)

	// a short set of options gives a narrower box than a long one
	short: Ui(Sl_Msg)
	ui_init(&short)
	defer ui_destroy(&short)
	begin_view(&short)
	column(&short, padding = .lg)
	small := select(&short, 0, {"Yes", "No"}, width = 0, label = "Pick")
	end(&short)
	end_view(&short)
	frame(&short.tree, {600, 400})
	testing.expect(t, node_get(&short.tree, small).abs.w < wide, "a select of short options is narrower")

	// the desktop's large text grows the box with the label, so nothing is cut
	// (measured on options well short of the cap, which the long one above is not)
	fit :: proc(ui: ^Ui(Sl_Msg)) -> f32 {
		begin_view(ui)
		column(ui, padding = .lg)
		n := select(ui, 0, {"Heading 1", "Default", "Normal"}, width = 0, label = "Style")
		end(ui)
		end_view(ui)
		frame(&ui.tree, {600, 400})
		return node_get(&ui.tree, n).abs.w
	}
	normal := fit(&short)
	tree_a11y_prefs(&short.tree, A11y_Prefs{text_scale = 1.5})
	testing.expectf(t, fit(&short) > normal, "at 1.5x text it is wider than it was (%v)", normal)

	// a width the app sets is still exactly that
	set := view(&ui, 0, 200)
	testing.expect_value(t, node_get(&ui.tree, set).abs.w, 200)
}

@(test)
a_selects_label_is_cut_not_wrapped :: proc(t: ^testing.T) {
	ui: Ui(Sl_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	short := view(&ui, 0, 200)
	one_line := node_get(&ui.tree, short).abs.h

	long := view(&ui, 1, 200) // the same box, an option far too long for it
	testing.expect_value(t, node_get(&ui.tree, long).abs.h, one_line)

	// and at the desktop's large text, where the label no longer fits either
	tree_a11y_prefs(&ui.tree, A11y_Prefs{text_scale = 1.5})
	big := view(&ui, 0, 200)
	big_h := node_get(&ui.tree, big).abs.h
	testing.expect(t, big_h > one_line, "larger text makes it taller")
	big_long := view(&ui, 1, 200)
	testing.expectf(t, node_get(&ui.tree, big_long).abs.h == big_h, "…but still one line, whatever is in it (%v, %v)", node_get(&ui.tree, big_long).abs.h, big_h)
}

} // when ODIN_TEST