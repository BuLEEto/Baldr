package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A window wide enough for a wide table is far too wide for prose: at
// 1,200 px a paragraph runs to about 170 characters a line, where 45-75
// reads best and WCAG 1.4.8 says under 80. `prose_width` caps the prose and
// centres it while tables and code keep the whole width.

@(private = "file")
Pw_Msg :: union { int }

@(private = "file")
Pw_Fx :: struct {
	ui:   Ui(Pw_Msg),
	te:   Text_Engine,
	md:   Markdown_Doc,
	n:    Node,
}

@(private = "file")
pw_build :: proc(fx: ^Pw_Fx, src: string, view_w: f32, prose: f32) -> ^Md_View_State {
	md_set(&fx.md, src)
	set_viewport(&fx.ui.tree, {view_w + 40, 600})
	begin_view(&fx.ui)
	column(&fx.ui, padding = .none)
	fx.n = markdown_view(&fx.ui, &fx.md, width = view_w)
	md_view_options(&fx.ui, fx.n, prose_width = prose)
	end(&fx.ui)
	end_view(&fx.ui)
	frame(&fx.ui.tree, {view_w + 40, 600})
	return &fx.ui.tree.md_views[fx.n]
}

@(private = "file")
pw_open :: proc(fx: ^Pw_Fx, t: ^testing.T) {
	if !text_engine_init(&fx.te) do testing.fail_now(t, "text_engine_init")
	ui_init(&fx.ui)
	fx.ui.tree.text = &fx.te
}

@(private = "file")
pw_close :: proc(fx: ^Pw_Fx) {
	ui_destroy(&fx.ui)
	md_destroy(&fx.md)
	text_engine_destroy(&fx.te)
}

SRC :: "A paragraph long enough that it has to wrap more than once when it is held to a reading width, and would run right across a wide view without one.\n\n| part | qty |\n|---|---|\n| P001 | 130 |\n\n```odin\nmain :: proc() { fmt.println(\"a line of code that is fairly long and must not be wrapped\") }\n```\n"

// Prose is held to the reading width and centred; a table and a code block
// keep the whole view.
@(test)
prose_is_held_to_its_width_while_tables_and_code_keep_the_view :: proc(t: ^testing.T) {
	fx: Pw_Fx
	pw_open(&fx, t)
	defer pw_close(&fx)

	wide := pw_build(&fx, SRC, 1000, 0)
	prose_wide := wide.blocks[0].lay.lines[0].width
	testing.expect(t, len(wide.blocks) >= 3, "a paragraph, a table and some code")
	testing.expect_value(t, wide.blocks[0].indent, 0) // nothing centred without a reading width
	// what the wide blocks looked like with no reading width at all, to
	// compare against: a code block has an indent of its own, so "keeps the
	// full width" means *unchanged*, not zero
	was := make(map[int][2]f32, context.temp_allocator)
	for c, i in wide.blocks do was[i] = {c.indent, c.wrap_w}

	narrow := pw_build(&fx, SRC, 1000, 400)
	p := narrow.blocks[0]
	testing.expect(t, p.lay.lines[0].width <= 400, "the paragraph wraps at the reading width")
	testing.expect(t, p.lay.lines[0].width < prose_wide, "…which is narrower than it was")
	testing.expect(t, len(p.lay.lines) > 1, "so it takes more than one line")
	testing.expectf(t, p.indent > 290 && p.indent < 310,
		"and sits centred: (1000 - 400) / 2 = 300, got %.1f", p.indent)

	// A table and a code block start on the same left edge as the prose (one
	// margin down the page) but may run on past the reading width to the
	// view's right edge. Centring them would give three different left edges.
	checked := 0
	for c, i in narrow.blocks {
		k := narrow.md.blocks[i].meta.kind
		if k != .Table && k != .Code do continue
		before := was[i]
		testing.expectf(t, c.shift == p.shift, "a %v shares the prose's left edge (%.1f vs %.1f)", k, c.shift, p.shift)
		testing.expectf(t, c.wrap_w > 400, "…and may be wider than the reading column: %.0f", c.wrap_w)
		testing.expectf(t, c.wrap_w <= before[1], "…without exceeding the view: %.0f of %.0f", c.wrap_w, before[1])
		checked += 1
	}
	testing.expect(t, checked >= 2, "a table row and a code line were both checked")

	// and prose really is the narrow one of the two
	testing.expect(t, p.wrap_w < narrow.blocks[1].wrap_w, "prose is held in while the table is not")
}

// A wide table must end inside the view: it starts at the reading column's
// offset, so its columns are sized to the view less that offset, or it
// overhangs the right edge by exactly that much.
@(test)
a_wide_table_ends_inside_the_view :: proc(t: ^testing.T) {
	fx: Pw_Fx
	pw_open(&fx, t)
	defer pw_close(&fx)

	// four columns with enough in them to want every pixel
	wide_table := "| day | route | stops | notes |\n|---|---|---|---|\n| Monday | the long way round the north side | 14 | call ahead because the gate is usually locked before nine |\n"
	view_w := f32(848)
	prose := f32(620)
	s := pw_build(&fx, wide_table, view_w, prose)
	shift := (view_w - prose) / 2

	checked := 0
	for c, i in s.blocks {
		if s.md.blocks[i].meta.kind != .Table do continue
		if !testing.expect(t, len(c.cols) > 0, "the row has columns") do continue
		right := c.indent + c.cols[len(c.cols) - 1]
		testing.expectf(t, right <= view_w + 0.5,
			"the table ends inside the view: %.1f of %.0f (indent %.1f, shift %.1f)", right, view_w, c.indent, shift)
		testing.expectf(t, c.indent >= shift - 0.5, "…and starts on the prose's left edge (%.1f vs %.1f)", c.indent, shift)
		checked += 1
	}
	testing.expect(t, checked > 0, "a table row was checked")

	// a second pass reuses the measured columns rather than rebuilding them:
	// the cache check must compare the width the rows are cached under
	before := s.blocks[0].cols
	again := pw_build(&fx, wide_table, view_w, prose)
	testing.expect(t, raw_data(again.blocks[0].cols) == raw_data(before), "the columns were reused, not measured again")
}

// A code block's band is as wide as its longest line needs: never narrower
// than the reading column, never wider than the room there is. A band at the
// full width would strand a short fence's Copy button far past the prose.
// The clamp is to the room there is, not to the block's own width, which for
// a code block is already the full width.
@(test)
a_code_bands_width_follows_its_longest_line :: proc(t: ^testing.T) {
	fx: Pw_Fx
	pw_open(&fx, t)
	defer pw_close(&fx)

	view_w, prose := f32(1000), f32(400)
	band_of :: proc(s: ^Md_View_State) -> f32 {
		for c, i in s.blocks do if s.md.blocks[i].meta.kind == .Code && c.band > 0 do return c.band
		return -1
	}

	short := pw_build(&fx, "```text\nHello, world!\n```\n", view_w, prose)
	sb := band_of(short)
	testing.expectf(t, sb > 0 && sb <= prose + 1,
		"a short fence stops at the reading column: %.0f of %.0f", sb, prose)

	long := pw_build(&fx, "```text\nSELECT customer, order_date, part_number, quantity, unit_price, line_total FROM orders WHERE order_date > '2026-01-01' ORDER BY order_date DESC\n```\n", view_w, prose)
	lb := band_of(long)
	testing.expectf(t, lb > prose, "a long line gets the extra room: %.0f of %.0f", lb, prose)
	testing.expectf(t, lb <= view_w, "…but never more than there is: %.0f of %.0f", lb, view_w)
}

// A click has to land where the reader sees the text, not where it would
// have been without the offset.
@(test)
a_click_on_centred_prose_lands_where_the_reader_sees_it :: proc(t: ^testing.T) {
	fx: Pw_Fx
	pw_open(&fx, t)
	defer pw_close(&fx)

	s := pw_build(&fx, SRC, 1000, 400)
	d := node_get(&fx.ui.tree, fx.n)
	if d == nil do testing.fail_now(t, "no node")
	p := s.blocks[0]
	testing.expect(t, p.indent > 0, "the paragraph is centred")

	// inside the reading column: an x further right gives an offset further on
	y := d.abs.y + p.top + 1
	prev := -1
	for dx := f32(4); dx < 380; dx += 8 {
		off := md_view_at(&fx.ui.tree, fx.n, s, {d.abs.x + p.indent + dx, y})
		testing.expectf(t, off >= prev, "x %.0f gives %d, after %d", dx, off, prev)
		prev = off
	}
	testing.expect(t, prev > 0, "…and it got somewhere")

	// to the left of the column is the start of the line, not the middle of it
	left := md_view_at(&fx.ui.tree, fx.n, s, {d.abs.x + 2, y})
	inside := md_view_at(&fx.ui.tree, fx.n, s, {d.abs.x + p.indent + 200, y})
	testing.expect(t, left < inside, "the gutter reads as the line's start, not as text")
}

}
