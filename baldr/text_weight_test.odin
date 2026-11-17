package baldr

@(require) import "core:testing"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A medium text weight between regular and semibold.


@(private = "file")
TextWeight_WMsg :: union { int }

// Text comes in three weights. A theme role sets one (body regular, a label
// semibold), `text`'s weight overrides it, and a menu chip's label is
// medium. With the text engine they are the UI typeface at 400, 500 and 600,
// one set of font bytes: a word sets wider as it gets heavier.
@(test)
text_has_a_medium_weight :: proc(t: ^testing.T) {
	ui: Ui(TextWeight_WMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	column(&ui)
	body := text(&ui, "Speakers")
	label := text(&ui, "Speakers", role = .Label)
	medium := text(&ui, "Speakers", role = .Label, weight = .Medium)
	chip := menu_chip(&ui, "Speakers", false, TextWeight_WMsg(1))
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 300})
	weight_of :: proc(tr: ^Tree, n: Node) -> Font_Weight {
		tk, _ := node_get(tr, n).kind.(Text_Kind)
		return tk.weight
	}
	testing.expect_value(t, weight_of(&ui.tree, body), Font_Weight.Regular)
	testing.expect_value(t, weight_of(&ui.tree, label), Font_Weight.Semibold)
	testing.expect_value(t, weight_of(&ui.tree, medium), Font_Weight.Medium)
	testing.expect_value(t, weight_of(&ui.tree, node_get(&ui.tree, chip).first), Font_Weight.Medium)

	te: Text_Engine
	if !testing.expect(t, text_engine_init(&te), "the text engine loads its fonts") do return
	defer text_engine_destroy(&te)
	regular := prefix_width(&te, "Speakers", 12)
	med := prefix_width(&te, "Speakers", 12, weight = .Medium)
	semi := prefix_width(&te, "Speakers", 12, weight = .Semibold)
	testing.expectf(t, regular < med && med < semi, "heavier sets wider: %v, %v, %v", regular, med, semi)
	testing.expect(t, raw_data(font_data(.Medium)) == raw_data(font_data(.UI)) && raw_data(font_data(.Bold)) == raw_data(font_data(.UI)), "one set of the UI typeface's bytes")
}

} // when ODIN_TEST