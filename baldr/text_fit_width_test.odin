package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A heading beside a row that takes all the room it is offered: the row
// gives the heading exactly its natural width back, a fraction of a pixel
// over a whole number, and the heading must stay on one line rather than
// break its only word at the pixel text layout rounds down to.
@(test)
a_text_given_its_natural_width_stays_on_one_line :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)
	ui: Ui(int)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tree_use_text_engine(&ui.tree, &te)
	for w in ([]f32{960, 912, 800, 701}) {
		begin_view(&ui)
		column(&ui, padding = .xl)
		row(&ui, align = .Center, gap = .md)
		title := text(&ui, "Inbox", role = .Headline)
		spacer(&ui)
		row(&ui, align = .Center, gap = .md)
		text(&ui, "100 000 messages · 0 picked", muted = true, nowrap = true, ellipsis = .End)
		spacer(&ui) // the row takes everything it is offered
		button(&ui, "Wide rows", 1, variant = .Outline)
		end(&ui)
		end(&ui)
		end(&ui)
		end_view(&ui)
		frame(&ui.tree, {w, 600})
		d := node_get(&ui.tree, title)
		one_line := text_line_height(&te, d.kind.(Text_Kind).size, family = d.kind.(Text_Kind).family)
		testing.expectf(t, d.abs.w >= min_content_width(&ui.tree, title) - 0.01, "at %v the heading is as wide as its word: %v", w, d.abs.w)
		testing.expectf(t, d.abs.h < one_line * 1.5, "at %v the heading is one line: %v tall, a line is %v", w, d.abs.h, one_line)
	}
}

} // when ODIN_TEST
