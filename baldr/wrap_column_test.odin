package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A wrap that runs down, breaking into columns at its height,
// for a top or bottom bar's rows of applets.

// Icons take a 40 px cell; a text applet (a clock) takes a column's full
// height; each column is as wide as its widest child.
@(test)
a_vertical_wrap_fills_columns_down_and_is_as_wide_as_them :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	GAP :: f32(4)
	H :: 2 * 40 + GAP
	cells: [5]Node
	span, gone, after, w: Node
	begin_view(&ui)
	row(&ui, align = .Start)
	w = wrap(&ui, gap = GAP, align = .Center, justify = .End, height = H, vertical = true)
	cells[0] = box(&ui, width = 40, height = 40, key = 1)
	cells[1] = box(&ui, width = 20, height = 40, key = 2) // narrower: centred across its column
	cells[2] = box(&ui, width = 40, height = 40, key = 3) // alone in its column: at its foot (justify End)
	span = box(&ui, width = 60, height = H, key = 4)       // a clock: the column's full height
	gone = box(&ui, width = 40, height = 40, key = 5)
	set_hidden(&ui.tree, gone, true)
	cells[3] = box(&ui, width = 40, height = 40, key = 6)
	cells[4] = box(&ui, width = 40, height = 40, key = 7)
	end(&ui)
	after = box(&ui, width = 10, height = 10)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 400})

	at :: proc(ui: ^Ui(Ov_Msg), w, n: Node) -> [2]f32 {
		wd, nd := node_get(&ui.tree, w), node_get(&ui.tree, n)
		return {nd.abs.x - wd.abs.x, nd.abs.y - wd.abs.y}
	}
	testing.expect_value(t, at(&ui, w, cells[0]), [2]f32{0, 0})
	testing.expect_value(t, at(&ui, w, cells[1]), [2]f32{10, 40 + GAP})
	testing.expect_value(t, at(&ui, w, cells[2]), [2]f32{40 + GAP, 40 + GAP})
	testing.expect_value(t, at(&ui, w, span), [2]f32{2 * (40 + GAP), 0})
	testing.expect_value(t, at(&ui, w, cells[3]), [2]f32{2 * (40 + GAP) + 60 + GAP, 0})
	testing.expect_value(t, at(&ui, w, cells[4]), [2]f32{2 * (40 + GAP) + 60 + GAP, 40 + GAP})
	wd := node_get(&ui.tree, w)
	wide := 40 + GAP + 40 + GAP + 60 + GAP + 40 // four columns, three gaps
	testing.expect_value(t, [2]f32{wd.abs.w, wd.abs.h}, [2]f32{wide, H})
	testing.expect_value(t, node_get(&ui.tree, after).abs.x, wd.abs.x + wide) // the row goes on after its columns
	testing.expect(t, !drop_flows_sideways(&ui.tree, cells[0]), "a drop's Before / After run above / below, down its columns")

	least, natural := content_length(&ui.tree, true, H)
	testing.expect_value(t, natural, wide + 10) // a FIT top bar's length
	testing.expect_value(t, least, wide)        // a short screen squeezes the box, never the columns
}

// flex children grow down their column; Stretch widens them across it.
@(test)
a_vertical_wraps_flex_grows_down_and_stretch_widens_across :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	a, b, w: Node
	begin_view(&ui)
	row(&ui, align = .Start)
	w = wrap(&ui, align = .Stretch, height = 100, vertical = true)
	a = box(&ui, width = 30, height = 30, flex = 1, key = 1)
	b = box(&ui, height = 20, key = 2)
	end(&ui)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 400})
	ad, bd, wd := node_get(&ui.tree, a), node_get(&ui.tree, b), node_get(&ui.tree, w)
	testing.expect_value(t, ad.abs.h, 80)           // 30 and the column's 50 left over
	testing.expect_value(t, bd.abs.y - wd.abs.y, 80)
	testing.expect_value(t, bd.abs.w, 30)           // as wide as its column
	testing.expect_value(t, wd.abs.w, 30)
}

} // when ODIN_TEST