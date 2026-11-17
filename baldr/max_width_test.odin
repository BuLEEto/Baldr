package baldr

@(require) import "core:testing"

// Behind this `when` so a program importing Baldr does not type-check the
// test suite too, which costs gigabytes. ODIN_TEST is set by `odin test`;
// BALDR_TESTS lets ./build.sh check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A readable column: a container capped at a width and centred in a wider
// window, narrowing with the window below that cap.


@(private = "file")
Mw_Msg :: union { int }

@(private = "file")
mw_build :: proc(ui: ^Ui(Mw_Msg), viewport: [2]f32, align: Align, cap: f32, width: f32 = 0) -> (outer, inner: Node) {
	begin_view(ui)
	outer = column(ui, align = align)
	inner = column(ui, padding = .md, max_width = cap, width = width)
	text(ui, "a reply that would otherwise run the whole width of the window")
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, viewport)
	return
}

@(test)
a_column_can_be_capped_and_centred :: proc(t: ^testing.T) {
	ui: Ui(Mw_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	// stretched (the default): capped, and left where the stretch puts it
	_, inner := mw_build(&ui, {1200, 600}, .Stretch, 760)
	d := node_get(&ui.tree, inner)
	testing.expect_value(t, d.abs.w, f32(760))
	testing.expect_value(t, d.abs.x, f32(0))

	// centred by its parent: the readable column of a chat
	_, inner = mw_build(&ui, {1200, 600}, .Center, 760, width = 760)
	d = node_get(&ui.tree, inner)
	testing.expect(t, d.abs.w == 760 && d.abs.x == 220, "760 wide, centred in 1200")

	// narrower window: it gives way rather than overflowing
	_, inner = mw_build(&ui, {520, 600}, .Center, 760, width = 760)
	d = node_get(&ui.tree, inner)
	testing.expect(t, d.abs.w == 520 && d.abs.x == 0, "as wide as the window, no overflow")

	// a cap with no width: never wider than the cap, however wide the window
	_, inner = mw_build(&ui, {2000, 600}, .Stretch, 400)
	d = node_get(&ui.tree, inner)
	testing.expect_value(t, d.abs.w, f32(400))
}

@(test)
a_card_and_a_row_take_a_cap_too :: proc(t: ^testing.T) {
	ui: Ui(Mw_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	column(&ui, align = .Center)
	c := card(&ui, max_width = 600)
	text(&ui, "a message")
	end(&ui)
	r := row(&ui, max_width = 300)
	text(&ui, "one")
	text(&ui, "two")
	end(&ui)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {1000, 400})
	testing.expect(t, node_get(&ui.tree, c).abs.w <= 600, "a card's cap holds")
	testing.expect(t, node_get(&ui.tree, r).abs.w <= 300, "a row's cap holds")
}

} // when ODIN_TEST