package baldr

@(require) import "core:fmt"
@(require) import "core:testing"

// `list`, `table` and `icon_view` pass `gutter` through to their scroll, so
// the overlay scrollbar is not drawn over the right edge of their rows (a
// row's "…" button, an unread pill).
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Lg_Msg :: union { int }

@(private = "file")
lg_list :: proc(ui: ^Ui(Lg_Msg), gutter: bool) -> (lst: Node, last_btn: Node) {
	set_viewport(&ui.tree, {420, 300})
	begin_view(ui)
	column(ui, flex = 1)
	first, last := list(ui, 40, row_height = 32, gutter = gutter, key = 1)
	lst = ui.scopes[len(ui.scopes) - 1].node
	for i in first ..< last {
		row(ui, align = .Center, height = 32, key = u64(i + 1))
		text(ui, fmt.tprintf("Chat %d", i), flex = 1)
		last_btn = button(ui, "…", Lg_Msg(i), key = 99)
		end(ui)
	}
	end(ui) // list
	end(ui) // column
	end_view(ui)
	frame(&ui.tree, {420, 300})
	return
}

// A row's own control ends clear of the bar, as it does in a plain scroll.
@(test)
a_list_gutter_keeps_a_rows_control_clear_of_the_bar :: proc(t: ^testing.T) {
	bare, with: Rect
	{
		ui: Ui(Lg_Msg)
		ui_init(&ui)
		defer ui_destroy(&ui)
		_, b := lg_list(&ui, false)
		bare = node_get(&ui.tree, b).abs
	}
	{
		ui: Ui(Lg_Msg)
		ui_init(&ui)
		defer ui_destroy(&ui)
		_, b := lg_list(&ui, true)
		with = node_get(&ui.tree, b).abs
	}
	testing.expectf(t, with.x + with.w <= bare.x + bare.w - SCROLLBAR_GUTTER + 0.5,
		"the gutter moved the button in by %v, wanted %v",
		(bare.x + bare.w) - (with.x + with.w), SCROLLBAR_GUTTER)
}

// Always reserved, as on `scroll`: a list short enough not to overflow
// keeps the room, because giving it back on demand oscillates.
@(test)
a_list_gutter_does_not_come_and_go_with_the_content :: proc(t: ^testing.T) {
	ui: Ui(Lg_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {420, 300})
	begin_view(&ui)
	column(&ui, flex = 1)
	first, last := list(&ui, 2, row_height = 32, gutter = true, key = 1)
	btn: Node
	for i in first ..< last {
		row(&ui, align = .Center, height = 32, key = u64(i + 1))
		text(&ui, "short", flex = 1)
		btn = button(&ui, "…", Lg_Msg(i), key = 99)
		end(&ui)
	}
	end(&ui)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {420, 300})
	b := node_get(&ui.tree, btn)
	testing.expectf(t, b != nil && b.abs.x + b.abs.w <= 420 - SCROLLBAR_GUTTER + 0.5,
		"two rows cannot overflow, but the room is kept anyway: the button ends at %v of 420", b.abs.x + b.abs.w)
}

// A table's headings stay over their cells: the gutter comes off the column
// widths, because the header sits above the scroll, not inside it.
@(test)
a_table_gutter_keeps_the_heading_over_its_cells :: proc(t: ^testing.T) {
	ui: Ui(Lg_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	hdr_cell, body_cell: Node
	// Twice: the first build has no width yet and guesses; the columns are
	// resolved at the second, with the real 480.
	for pass in 0 ..< 2 {
		cols := []Column{{title = "Name", flex = 1}, {title = "Size", width = 90, numeric = true}}
		set_viewport(&ui.tree, {480, 300})
		begin_view(&ui)
		column(&ui, flex = 1)
		first, last := table(&ui, cols, 40, gutter = true, key = 1)
		for i in first ..< last {
			r := table_row(&ui, i)
			if i == first {
				text(&ui, fmt.tprintf("file %d", i))
				body_cell = text(&ui, "12 kB")
			} else {
				text(&ui, fmt.tprintf("file %d", i))
				text(&ui, "12 kB")
			}
			_ = r
			end(&ui)
		}
		end(&ui)
		end(&ui)
		end_view(&ui)
		frame(&ui.tree, {480, 300})
		_ = pass
	}
	// the last heading: the header row's last child
	for _, ts in ui.tree.tables {
		for c := node_first(&ui.tree, ts.header); c != NODE_NONE; c = node_next(&ui.tree, c) {
			hdr_cell = c
		}
	}
	h := node_get(&ui.tree, hdr_cell)
	b := node_get(&ui.tree, body_cell)
	testing.expect(t, h != nil && b != nil, "a heading and a cell under it")
	testing.expectf(t, h.abs.x + h.abs.w <= 480 - SCROLLBAR_GUTTER + 0.5,
		"the last heading ends at %v of 480, inside the bar's gutter", h.abs.x + h.abs.w)
	testing.expectf(t, b.abs.x + b.abs.w <= 480 - SCROLLBAR_GUTTER + 0.5,
		"the last cell ends at %v of 480, under the bar", b.abs.x + b.abs.w)
}

}
