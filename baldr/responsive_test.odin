package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(test)
responsive_size_classes :: proc(t: ^testing.T) {
	testing.expect_value(t, size_class_of(0), Size_Class.Expanded)
	testing.expect_value(t, size_class_of(320), Size_Class.Compact)
	testing.expect_value(t, size_class_of(599), Size_Class.Compact)
	testing.expect_value(t, size_class_of(600), Size_Class.Medium)
	testing.expect_value(t, size_class_of(839), Size_Class.Medium)
	testing.expect_value(t, size_class_of(840), Size_Class.Expanded)
	testing.expect_value(t, size_class_of(2560), Size_Class.Expanded)
}

@(test)
responsive_crossing_a_breakpoint_rebuilds_the_view :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {400, 700})
	begin_view(&ui)
	testing.expect_value(t, size_class(&ui), Size_Class.Compact)
	column(&ui)
	if size_class(&ui) == .Compact { text(&ui, "phone") } else { text(&ui, "desktop") }
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 700})
	testing.expect_value(t, node_get(&ui.tree, node_first(&ui.tree, node_first(&ui.tree, ui.root))).access.name, "phone")
	ui_after_events(&ui, 1000)
	testing.expect(t, !ui.needs_rebuild, "same class: no rebuild")
	frame(&ui.tree, {500, 700}) // still Compact
	ui_after_events(&ui, 1100)
	testing.expect(t, !ui.needs_rebuild, "resize inside the class: no rebuild")
	frame(&ui.tree, {1000, 700})
	ui_after_events(&ui, 1200)
	testing.expect(t, ui.needs_rebuild, "crossed into Expanded: rebuild")
}

@(test)
layout_wrap_breaks_lines_and_grows_flex_children :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	column(&ui, align = .Start)
	w := wrap(&ui, gap = .sm, width = 250) // sm = 8
	b: [5]Node
	for i in 0 ..< 5 do b[i] = box(&ui, width = 100, height = 20, key = u64(i + 1))
	end(&ui)
	g := wrap(&ui, gap = .sm, width = 250)
	f: [3]Node
	for i in 0 ..< 3 {
		f[i] = box(&ui, width = 100, height = 20 + f32(i) * 10, flex = 1, key = u64(i + 1))
	}
	end(&ui)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 400})
	gap := ui.theme.space[.sm]
	// 250 wide, 100 px boxes: two per line, three lines.
	wd := node_get(&ui.tree, w)
	testing.expect_value(t, wd.abs.h, 3 * 20 + 2 * gap)
	testing.expect_value(t, node_get(&ui.tree, b[1]).abs.x, wd.abs.x + 100 + gap)
	testing.expect_value(t, node_get(&ui.tree, b[2]).abs.x, wd.abs.x)
	testing.expect_value(t, node_get(&ui.tree, b[2]).abs.y, wd.abs.y + 20 + gap)
	testing.expect_value(t, node_get(&ui.tree, b[4]).abs.y, wd.abs.y + 2 * (20 + gap))
	// Flex children fill their line: two share the first line, the last one has its own.
	gd := node_get(&ui.tree, g)
	half := (250 - gap) / 2
	testing.expect_value(t, node_get(&ui.tree, f[0]).abs.w, half)
	testing.expect_value(t, node_get(&ui.tree, f[1]).abs.w, half)
	testing.expect_value(t, node_get(&ui.tree, f[2]).abs.w, 250)
	testing.expect_value(t, node_get(&ui.tree, f[2]).abs.y, gd.abs.y + 30 + gap) // first line is as tall as its tallest child
}

} // when ODIN_TEST