package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Right-to-left text in a rich paragraph wraps at its width like any other:
// a chat message in Arabic or Hebrew stays inside its bubble.
@(test)
right_to_left_rich_text_wraps_at_its_width :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init: the embedded fonts did not load")
	defer text_engine_destroy(&te)
	ui: Ui(int)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tree_use_text_engine(&ui.tree, &te)
	for s in ([]string{"مرحبا بالعالم، هذا نص طويل باللغة العربية للاختبار", "שלום עולם, זהו טקסט ארוך בעברית לבדיקה של שבירת שורות"}) {
		lay := rich_layout(&ui.tree, s, nil, Rich_Style{size = 15}, 120)
		testing.expectf(t, len(lay.lines) > 1, "%q is one line at 120 px", s)
		for line in lay.lines {
			testing.expectf(t, line.width > 0 && line.width <= 120.01, "a line of %q is %v wide, at a width of 120", s, line.width)
		}
	}
}

} // when ODIN_TEST
