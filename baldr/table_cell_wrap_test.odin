package baldr

@(require) import "core:math"
@(require) import "core:testing"

when ODIN_TEST || #config(BALDR_TESTS, false) {

// A markdown table's widest cell never wraps inside the column sized for it.
//
// A column is its widest cell's natural width plus padding, accumulated into
// edges, and `table_row_layout` recovers a cell's room as
// `cols[ci+1] - cols[ci] - TABLE_CELL_PAD * 2`. That f32 round trip loses low
// bits: at a body size of 15.950001 (14.5 at a 110% text size) the room comes
// back a few ULPs under the natural width, and `rich_layout` wraps. Whether a
// cell trips depends on its own width, so the size below is the one that
// matters. Columns are rounded up to a whole pixel to give that headroom;
// the editors' `area_table_cols` does the same.
//
// These tests install a real font engine: the headless mono measurer has
// whole-number advances, so nothing would land on a fraction.

@(private = "file")
Tcw_Msg :: union { int }

@(private = "file")
TCW_TABLES := []string{
	// plain cells
	"| Customer | Value |\n| --- | --- |\n| Northgate Supplies (Westbury) | £147,062 |\n| K L M Lighting Wholesalers Ltd | £34,915 |\n",
	// cells split into runs by inline formatting
	"| **Customer** | **Value** |\n| --- | --- |\n| *Northgate Supplies* (Westbury) | `£147,062` |\n| K L M **Lighting** Wholesalers Ltd | £34,915 |\n",
	// a link, and a bold figure
	"| Customer | Value |\n| --- | --- |\n| [Northgate Supplies](http://a) | £147,062 |\n| K L M Lighting Wholesalers Ltd | **£34,915** |\n",
}

@(test)
a_table_cell_with_room_is_never_wrapped :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init: embedded fonts failed to load")
	defer text_engine_destroy(&te)

	for src in TCW_TABLES {
		for scale in ([]f32{1.0, 1.25}) {
			ui: Ui(Tcw_Msg)
			ui_init(&ui)
			defer ui_destroy(&ui)
			ui.tree.text = &te
			md: Markdown_Doc
			defer md_destroy(&md)
			md_set(&md, src)
			set_text_scale(&ui.tree, scale)

			// Every width from "squeezed" to "four times the room needed".
			for w: f32 = 240; w <= 1600; w += 37 {
				set_viewport(&ui.tree, {w, 900})
				begin_view(&ui)
				n := markdown_view(&ui, &md, label = "Reply", width = w)
				end_view(&ui)
				frame(&ui.tree, {w, 900})
				s := &ui.tree.md_views[n]
				if s == nil do testing.fail_now(t, "the view kept no state")
				cols := md_view_table_cols(&ui.tree, s, 2, w, context.temp_allocator)

				for r in 0 ..< len(md.blocks) {
					if md.blocks[r].meta.kind != .Table do continue
					blk := md.blocks[r]
					base := md_view_style(&ui.tree, .Table, blk.meta.level)
					line := string(s.md.src[blk.from:blk.to])
					shown := markdown_render_line(line, false, false, context.temp_allocator)
					for cell, ci in table_cells(shown.text) {
						if ci + 1 >= len(cols) do break
						inner := max(cols[ci + 1] - cols[ci] - TABLE_CELL_PAD * 2, base.size)
						sub := shown.text[cell[0]:cell[1]]
						nat := rich_layout(&ui.tree, sub, nil, base, 0, context.temp_allocator)
						if len(nat.lines) == 0 do continue
						got := rich_layout(&ui.tree, sub, nil, base, inner, context.temp_allocator)
						// a column wide enough for the cell must not wrap it
						if inner >= nat.lines[0].width - 0.001 {
							testing.expectf(t, len(got.lines) == 1,
								"at %.0f px, %q is %.3f wide in a column offering %.3f and wrapped onto %d lines",
								w, sub, nat.lines[0].width, inner, len(got.lines))
						}
					}
				}
			}
		}
	}
}

@(test)
a_wrap_width_is_floored_on_purpose :: proc(t: ^testing.T) {
	// `text_lines` floors the wrap width to a whole pixel, so the width is a
	// usable cache key and text is never laid out for more room than it has.
	// So a caller that hands a fractional measurement back as the room loses
	// the fraction and wraps; `rich_layout` passes 0 and breaks lines itself.
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init: embedded fonts failed to load")
	defer text_engine_destroy(&te)

	fracs, wrapped := 0, 0
	for s in ([]string{"£147,062", "£34,915", "Northgate Supplies (Westbury)", "Customer", "Value"}) {
		un := text_lines(&te, s, 15, 0)
		if len(un) != 1 do continue
		nat := un[0].width
		if nat == math.floor(nat) do continue
		fracs += 1
		if len(text_lines(&te, s, 15, nat)) > 1 do wrapped += 1
		// …and a whole pixel more is always enough
		testing.expectf(t, len(text_lines(&te, s, 15, math.ceil(nat))) == 1,
			"%q is %.3f wide and did not fit in ceil(%.3f)", s, nat, nat)
	}
	testing.expect(t, fracs > 0, "these strings must measure to fractions, or the test proves nothing")
	testing.expect_value(t, wrapped, fracs) // every one of them, which is the floor doing its job
}

@(test)
a_column_has_room_for_its_cell_at_any_body_size :: proc(t: ^testing.T) {
	// The body size that trips the round trip, plus sizes either side so a
	// change cannot pass by landing on a lucky number.
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init: embedded fonts failed to load")
	defer text_engine_destroy(&te)

	for size in ([]f32{15.950001, 15, 14.5, 15.4, 16.5, 17.6, 13.2, 19.8}) {
		ui: Ui(Tcw_Msg)
		ui_init(&ui)
		defer ui_destroy(&ui)
		ui.tree.text = &te
		ui.tree.theme.type.body.size = size
		md: Markdown_Doc
		defer md_destroy(&md)
		md_set(&md, TCW_TABLES[0])

		set_viewport(&ui.tree, {912, 780})
		begin_view(&ui)
		n := markdown_view(&ui, &md, label = "Reply", width = 783.5)
		md_view_options(&ui, n, prose_width = 704)
		end_view(&ui)
		frame(&ui.tree, {912, 780})
		s := &ui.tree.md_views[n]
		if s == nil do testing.fail_now(t, "the view kept no state")

		for r in 0 ..< min(len(s.blocks), len(md.blocks)) {
			if md.blocks[r].meta.kind != .Table do continue
			c := s.blocks[r]
			// what the view actually drew
			testing.expectf(t, len(c.lay.lines) == 1,
				"at body size %.6f, table row %d wrapped onto %d lines with room to spare",
				size, r, len(c.lay.lines))
			// …and why: the column must not be a hair under its own cell
			base := md_view_style(&ui.tree, .Table, md.blocks[r].meta.level)
			sh := markdown_render_line(string(s.md.src[md.blocks[r].from:md.blocks[r].to]), false, false, context.temp_allocator)
			for cell, ci in table_cells(sh.text) {
				if ci + 1 >= len(c.cols) do break
				inner := max(c.cols[ci + 1] - c.cols[ci] - TABLE_CELL_PAD * 2, base.size)
				sub := sh.text[cell[0]:cell[1]]
				nat := rich_layout(&ui.tree, sub, nil, base, 0, context.temp_allocator)
				if len(nat.lines) == 0 do continue
				testing.expectf(t, inner >= nat.lines[0].width,
					"at body size %.6f, %q measures %.6f and its column offers only %.6f (short by %.8f)",
					size, sub, nat.lines[0].width, inner, nat.lines[0].width - inner)
			}
		}
	}
}

}
