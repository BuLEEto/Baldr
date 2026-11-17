package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: about 9 GB without this `when`, 1 GB with it.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Measuring a bar that is as long as its content must not repaint it.


@(private = "file")
Fit_Measure_Msg :: union { int }

// Measuring a bar's natural length lays it out at another size and back:
// when that leaves everything where it was, nothing is damaged, so the bar
// has nothing to present.
@(test)
measuring_a_bars_length_damages_nothing :: proc(t: ^testing.T) {
	ui: Ui(Fit_Measure_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	row(&ui, flex = 1, align = .Center, gap = .sm, padding = .xs)
	button(&ui, "Apps", Fit_Measure_Msg(1), icon = .Layout_Grid, variant = .Ghost)
	text(&ui, "12:34")
	button(&ui, "Control Centre", Fit_Measure_Msg(2), icon = .Settings, icon_only = true, variant = .Ghost)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 36})
	take_damage(&ui.tree)
	_, natural := content_length(&ui.tree, true, 36)
	testing.expect(t, natural > 0 && natural < 400, "fixture: it measured its content")
	frame(&ui.tree, {400, 36})
	testing.expect_value(t, len(take_damage(&ui.tree)), 0)
}

} // when ODIN_TEST