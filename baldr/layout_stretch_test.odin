package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: behind this `when`, checking a program costs
// 1.0 GB instead of 9.2 GB. ODIN_TEST is set by `odin test`; BALDR_TESTS
// lets ./build.sh check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// The stretch rule: children fill the container's cross size; the container
// is as large as its parent dictates when tight, else as large as its
// largest child. Explicitly sized children are left alone.

@(test)
layout_stretch_loose_column_equalises_to_widest_child :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	row(&ui, padding = .lg)            // gives the column a loose width
	col := column(&ui, gap = .sm)      // default align = .Stretch
	fixed := box(&ui, width = 50, height = 10)
	btn := button(&ui, "A fairly long label", Ov_Msg{})
	txt := text(&ui, "x")
	end(&ui)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 400})
	cw := node_get(&ui.tree, col).abs.w
	bw := node_get(&ui.tree, btn).abs.w
	testing.expect(t, bw > 50, "button is the widest child")
	testing.expect_value(t, cw, bw)                          // column shrink-wraps to its widest child …
	testing.expect_value(t, node_get(&ui.tree, txt).abs.w, bw) // … and stretches the narrower ones to it
	testing.expect_value(t, node_get(&ui.tree, fixed).abs.w, 50) // an explicit width is respected
}

@(test)
layout_stretch_tight_column_fills_parent :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	column(&ui, padding = .lg)         // tight: the root stretches it
	txt := text(&ui, "x")
	fixed := box(&ui, width = 50, height = 10)
	inner := column(&ui)               // nested default column, also tight now
	t2 := text(&ui, "y")
	end(&ui)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 400})
	pad := ui.theme.space[.lg]
	testing.expect_value(t, node_get(&ui.tree, txt).abs.w, 600 - 2 * pad)
	testing.expect_value(t, node_get(&ui.tree, fixed).abs.w, 50)
	testing.expect_value(t, node_get(&ui.tree, inner).abs.w, 600 - 2 * pad)
	testing.expect_value(t, node_get(&ui.tree, t2).abs.w, 600 - 2 * pad)
}

@(test)
layout_stretch_row_equalises_heights_to_tallest :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	column(&ui, padding = .lg, gap = .md)
	r := row(&ui, align = .Stretch, gap = .sm)
	c1 := card(&ui, flex = 1); text(&ui, "one"); end(&ui)
	c2 := card(&ui, flex = 1); text(&ui, "one"); text(&ui, "two"); text(&ui, "three"); end(&ui)
	c3 := card(&ui, flex = 1); text(&ui, "one"); end(&ui)
	end(&ui)
	after := text(&ui, "below the cards")
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 800})
	h1 := node_get(&ui.tree, c1).abs.h
	h2 := node_get(&ui.tree, c2).abs.h
	h3 := node_get(&ui.tree, c3).abs.h
	testing.expect(t, h1 == h2 && h2 == h3, "cards share the tallest height")
	testing.expect_value(t, node_get(&ui.tree, r).abs.h, h2)
	rd := node_get(&ui.tree, r)
	testing.expect(t, node_get(&ui.tree, after).abs.y >= rd.abs.y + rd.abs.h, "the row does not swallow the page")
	testing.expect(t, h2 < 400, "the row is content-sized, not the remaining page height")
}

@(test)
layout_spacer_fills_or_measures :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	column(&ui)
	rw := row(&ui, width = 300)
	a := box(&ui, width = 50, height = 10)
	sp := spacer(&ui)
	b := box(&ui, width = 50, height = 10)
	end(&ui)
	cl := column(&ui, height = 200, width = 100)
	c := box(&ui, height = 10)
	gap := spacer(&ui, 20)
	d := box(&ui, height = 10)
	fill := spacer(&ui)
	e := box(&ui, height = 10)
	end(&ui)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 400})
	_ = a
	_ = rw
	_ = cl
	_ = c
	testing.expect_value(t, node_get(&ui.tree, sp).abs.w, 200)
	testing.expect_value(t, node_get(&ui.tree, b).abs.x, 250)
	testing.expect_value(t, node_get(&ui.tree, gap).abs.h, 20)
	testing.expect_value(t, node_get(&ui.tree, d).abs.y, node_get(&ui.tree, cl).abs.y + 30)
	testing.expect_value(t, node_get(&ui.tree, fill).abs.h, 200 - 50)
	testing.expect_value(t, node_get(&ui.tree, e).abs.y, node_get(&ui.tree, cl).abs.y + 190)
	testing.expect_value(t, node_get(&ui.tree, sp).access.role, Role.None)
}

} // when ODIN_TEST