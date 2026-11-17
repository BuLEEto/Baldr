package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A wide table's cells wrap inside their columns and the row grows
// downwards, rather than a long cell drawing on under the next column and
// the table running off the side of the view. `<br>` is the line break that
// comes with it: the only one GFM gives a cell, and what a model writes when
// it wants one.

@(private = "file")
Mt_Msg :: union { int }

// WIDE is four columns, one of them long prose, and a `<br>` in the second.
@(private = "file")
WIDE :: `| Day | Route(s) | Depot Stops (stops per depot per day) | Notes |
|-----|----------|--------------------------------------|-------|
| Mon | R1: D1-D2-D3<br>R4: D4-D5-D6 | 2-3 each | High-priority stops first on each leg. |
| Wed | R1 + R2 | Same as Mon/Tue but with priority reordering based on SLA deadlines. | Use for same-day delivery windows. |
`

@(private = "file")
mt_build :: proc(ui: ^Ui(Mt_Msg), md: ^Markdown_Doc, w: f32) -> Node {
	set_viewport(&ui.tree, {w, 900})
	begin_view(ui)
	n := markdown_view(ui, md, label = "Reply", width = w)
	end_view(ui)
	frame(&ui.tree, {w, 900})
	return n
}

// mt_rows is the table rows' caches in `s`, in order.
@(private = "file")
mt_rows :: proc(s: ^Md_View_State) -> []Md_Line_Cache {
	out := make([dynamic]Md_Line_Cache, context.temp_allocator)
	for c, i in s.blocks do if s.md.blocks[i].meta.kind == .Table do append(&out, c)
	return out[:]
}

// No cell may draw outside its own column.
@(test)
a_table_keeps_every_cell_inside_its_column :: proc(t: ^testing.T) {
	for width in ([]f32{760, 520, 380}) { // a chat's reading column, and narrower
		ui: Ui(Mt_Msg)
		ui_init(&ui)
		defer ui_destroy(&ui)
		md: Markdown_Doc
		defer md_destroy(&md)
		md_set(&md, WIDE)

		n := mt_build(&ui, &md, width)
		s := &ui.tree.md_views[n]
		rows := mt_rows(s)
		testing.expectf(t, len(rows) >= 3, "at %v px the table has its rows", width)

		for c in rows {
			cols := c.cols
			if len(cols) < 2 do continue
			testing.expectf(t, cols[len(cols) - 1] <= width + 0.5,
				"at %v px the table is %v wide", width, cols[len(cols) - 1])
			for line in c.lay.lines do for sg in line.segs {
				// the column this piece sits in: the last start not past it
				ci := 0
				for k in 0 ..< len(cols) - 1 do if cols[k] <= sg.x + 0.5 do ci = k
				right := sg.x + sg.width
				testing.expectf(t, right <= cols[ci + 1] + 0.5,
					"at %v px a cell runs to %v, past its column's edge at %v", width, right, cols[ci + 1])
			}
		}
	}
}

// A row is as tall as its tallest cell, and the rows below it move down —
// which is what "grows downwards instead of sideways" has to mean.
@(test)
a_wrapped_table_row_is_as_tall_as_its_tallest_cell :: proc(t: ^testing.T) {
	ui: Ui(Mt_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, WIDE)

	n := mt_build(&ui, &md, 380)
	s := &ui.tree.md_views[n]
	rows := mt_rows(s)
	if len(rows) < 3 do testing.fail_now(t, "no rows")

	one := rows[0].lay.line_h
	for c, i in rows {
		testing.expectf(t, c.height >= one - 0.5, "row %d has a height", i)
		testing.expectf(t, c.height >= c.lay.height - 0.5, "row %d is as tall as its layout", i)
	}
	// The last row's cells wrap at this width, so it is more than one line.
	testing.expect(t, rows[len(rows) - 1].height > one + 1, "a row with a sentence in it grew")
	// And nothing overlaps.
	for i in 1 ..< len(s.blocks) {
		testing.expectf(t, s.blocks[i].top >= s.blocks[i - 1].top + s.blocks[i - 1].height - 0.5,
			"block %d overlaps the one above it", i)
	}
}

// `<br>` is a line break inside a cell, not four characters of text.
@(test)
a_br_in_a_table_cell_is_a_line_break :: proc(t: ^testing.T) {
	ui: Ui(Mt_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, WIDE)

	n := mt_build(&ui, &md, 760) // wide enough that nothing else wraps
	s := &ui.tree.md_views[n]
	rows := mt_rows(s)
	if len(rows) < 3 do testing.fail_now(t, "no rows")
	mon := rows[1] // the header, then Mon

	testing.expect(t, !strings.contains(mon.text, "<br>"), "the tag is gone from the text")
	testing.expect(t, strings.contains(mon.text, "\n"), "…and a break is there instead")
	testing.expect(t, strings.contains(mon.text, "R1: D1-D2-D3"), "the text either side of it stays")
	testing.expect(t, strings.contains(mon.text, "R4: D4-D5-D6"))

	// The cell it is in has two lines, one above the other, and the row is
	// two lines tall even though nothing needed to wrap.
	testing.expect(t, len(mon.lay.lines) >= 2, "the row has a second line for it")
	second := ""
	for sg in mon.lay.lines[1].segs do second = strings.concatenate({second, mon.text[sg.start:sg.end]}, context.temp_allocator)
	testing.expect(t, strings.contains(second, "R4:"), "…and it is the text after the break")
	testing.expect(t, mon.height > mon.lay.line_h + 1, "the row grew for it")
}

// `<br/>` and `<br />` are the same thing, and case does not matter.
@(test)
a_br_is_recognised_however_it_is_written :: proc(t: ^testing.T) {
	testing.expect_value(t, md_br_at("<br>", 0), 4)
	testing.expect_value(t, md_br_at("<br/>", 0), 5)
	testing.expect_value(t, md_br_at("<br />", 0), 6)
	testing.expect_value(t, md_br_at("<BR>", 0), 4)
	testing.expect_value(t, md_br_at("<Br/>", 0), 5)
	testing.expect_value(t, md_br_at("a<br>b", 1), 4)
	testing.expect_value(t, md_br_at("<brr>", 0), 0)
	testing.expect_value(t, md_br_at("<b>", 0), 0)
	testing.expect_value(t, md_br_at("<br", 0), 0)
	testing.expect_value(t, md_br_at("br>", 0), 0)
}

// Outside a table a `<br>` is text, as every other scrap of HTML in
// markdown is. Only a cell has no other way to ask for a break.
@(test)
a_br_in_a_paragraph_is_still_text :: proc(t: ^testing.T) {
	ui: Ui(Mt_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, "one<br>two\n")

	n := mt_build(&ui, &md, 400)
	s := &ui.tree.md_views[n]
	if len(s.blocks) == 0 do testing.fail_now(t, "no block")
	testing.expect(t, strings.contains(s.blocks[0].text, "<br>"), "left as it was written")
}

// A short table, what most replies hold, stays one line a row, every column
// as wide as its widest cell.
@(test)
a_short_table_is_unchanged :: proc(t: ^testing.T) {
	ui: Ui(Mt_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, "| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n")

	n := mt_build(&ui, &md, 400)
	s := &ui.tree.md_views[n]
	rows := mt_rows(s)
	testing.expect_value(t, len(rows), 3)
	for c, i in rows {
		testing.expectf(t, c.height <= c.lay.line_h + 0.5, "row %d is one line", i)
		testing.expectf(t, c.cols[len(c.cols) - 1] < 400, "row %d does not fill the view", i)
	}
}

// The fitting policy itself: a column never goes below its longest word
// while another column still has room to give up.
@(test)
fitting_columns_never_squeezes_one_below_its_longest_word :: proc(t: ^testing.T) {
	widths := []f32{40, 300}
	mins := []f32{40, 60}
	table_fit_cols(widths, mins, 200)
	testing.expect_value(t, widths[0], 40)  // it wanted only 40 and keeps it
	testing.expect_value(t, widths[1], 160) // the other gives up the rest
	total := widths[0] + widths[1]
	testing.expect_value(t, total, 200)

	// When even the minimums do not fit, the proportions are kept: there is
	// nothing else to do, and the cells break mid-word.
	tight := []f32{100, 300}
	tmins := []f32{90, 280}
	table_fit_cols(tight, tmins, 200)
	testing.expect(t, tight[0] + tight[1] <= 200.5, "inside the view either way")
	testing.expect(t, tight[1] > tight[0], "and still in proportion")

	// Already fitting: untouched.
	small := []f32{30, 40}
	smins := []f32{10, 10}
	table_fit_cols(small, smins, 200)
	testing.expect_value(t, small[0], 30)
	testing.expect_value(t, small[1], 40)
}

}
