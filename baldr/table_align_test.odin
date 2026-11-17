package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A table's columns line up the way the table asks, and a column of figures
// lines up right even when it does not ask: most generated markdown has no
// alignment row, so the automatic case is the common one.

@(test)
a_separator_line_says_how_its_columns_are_set :: proc(t: ^testing.T) {
	got := table_sep_align("|---|:---|---:|:---:|")
	if !testing.expect_value(t, len(got), 4) do return
	testing.expect_value(t, got[0], Table_Align.Default)
	testing.expect_value(t, got[1], Table_Align.Left)
	testing.expect_value(t, got[2], Table_Align.Right)
	testing.expect_value(t, got[3], Table_Align.Center)

	// spaces around the dashes are allowed, and so are longer runs
	spaced := table_sep_align("| :------ | ------: |")
	if testing.expect_value(t, len(spaced), 2) {
		testing.expect_value(t, spaced[0], Table_Align.Left)
		testing.expect_value(t, spaced[1], Table_Align.Right)
	}

	// …and a line that is not a separator says nothing at all
	testing.expect_value(t, len(table_sep_align("| Line | Qty |")), 0)
	testing.expect_value(t, len(table_sep_align("just some prose")), 0)
}

// The automatic rule, and the things it must not catch.
@(test)
a_column_of_figures_is_recognised_and_prose_is_not :: proc(t: ^testing.T) {
	numeric :: proc(row: string) -> bool { return table_cells_numeric(row, table_cells(row)) }

	testing.expect(t, numeric("| 130 | 35 | 74 |"), "plain integers")
	testing.expect(t, numeric("| 1,250.00 | -3.5 | 99% |"), "grouping, a decimal, a leading minus, a percent")
	testing.expect(t, numeric("| £12.50 | $4 | €9 |"), "currency symbols, which are not one byte")
	testing.expect(t, numeric("| 5 |  | 7 |"), "one gap does not make a column prose")

	testing.expect(t, !numeric("| P001 | P002 |"), "part numbers have letters")
	testing.expect(t, !numeric("| Line | Part |"), "words are not numbers")
	testing.expect(t, !numeric("| 12 | twelve |"), "one word is enough to disqualify the column")
	testing.expect(t, !numeric("|  |  |"), "an empty column is not a column of figures")
	testing.expect(t, !numeric("| 三 | 五 |"), "digits in another script are not matched by accident")
	testing.expect(t, !numeric("| 5-3 | 2 |"), "a minus only leads")
}


// The view and the editor must give the same answer, or the same table
// reads two ways depending on which widget shows it.
@(private = "file")
Ta_Msg :: union { int }

@(test)
the_editor_and_the_view_set_a_table_the_same_way :: proc(t: ^testing.T) {
	src := "| part | on hand |\n|---|---:|\n| P001 | 130 |\n| P002 | 35 |\n"

	ui: Ui(Ta_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make("")
	defer document_destroy(&doc)
	document_set_markdown(&doc, src)

	n: Node
	set_viewport(&ui.tree, {500, 400})
	begin_view(&ui)
	column(&ui, padding = .md)
	n = markdown_editor(&ui, &doc, label = "Doc", flex = 1)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {500, 400})

	area, st := editor_area(&ui.tree, n)
	if st == nil do testing.fail_now(t, "no editor")
	_ = area

	// the first table row in the document
	row := -1
	for bi in 0 ..< block_count(&doc) do if block_meta(&doc, bi).kind == .Table { row = bi; break }
	if !testing.expect(t, row >= 0, "the document has a table") do return

	al := area_table_align(&ui.tree, st, row)
	if !testing.expect_value(t, len(al), 2) do return
	testing.expect_value(t, al[0], Table_Align.Default) // part numbers: left where they were
	// The numeric rule, not the "---:": the editor reads no separator block
	// (see area_table_align).
	testing.expect_value(t, al[1], Table_Align.Right)

	// and with nothing declared, the figures still find their own way right
	doc2 := document_make("")
	defer document_destroy(&doc2)
	document_set_markdown(&doc2, "| part | on hand |\n|---|---|\n| P001 | 130 |\n| P002 | 35 |\n")
	begin_view(&ui)
	column(&ui, padding = .md)
	n2 := markdown_editor(&ui, &doc2, label = "Doc2", flex = 1, key = 9)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {500, 400})
	_, st2 := editor_area(&ui.tree, n2)
	if st2 == nil do testing.fail_now(t, "no second editor")
	row2 := -1
	for bi in 0 ..< block_count(&doc2) do if block_meta(&doc2, bi).kind == .Table { row2 = bi; break }
	al2 := area_table_align(&ui.tree, st2, row2)
	if testing.expect_value(t, len(al2), 2) {
		testing.expect_value(t, al2[0], Table_Align.Default)
		testing.expect_value(t, al2[1], Table_Align.Right)
	}
}


// A markdown file's alignment survives being parsed into a Document and
// written back, so opening and saving a file never drops the author's colons.
@(test)
a_tables_alignment_survives_a_round_trip :: proc(t: ^testing.T) {
	src := "| name | qty | note |\n|:---|---:|:--:|\n| Ann | 41 | hello |\n"
	doc := document_make("")
	defer document_destroy(&doc)
	document_set_markdown(&doc, src)

	// it is kept on the header row, which is where the separator's meaning
	// belongs once the separator itself is gone
	head := -1
	for bi in 0 ..< block_count(&doc) do if block_meta(&doc, bi).kind == .Table { head = bi; break }
	if !testing.expect(t, head >= 0, "the document has a table") do return
	m := block_meta(&doc, head)
	testing.expect_value(t, m.level, 1)
	testing.expect_value(t, table_align_get(m.align, 0), Table_Align.Left)
	testing.expect_value(t, table_align_get(m.align, 1), Table_Align.Right)
	testing.expect_value(t, table_align_get(m.align, 2), Table_Align.Center)

	// …and comes back out
	out := document_markdown(&doc, context.temp_allocator)
	testing.expect(t, strings.contains(out, ":---"), "the left column is still declared left")
	testing.expect(t, strings.contains(out, "---:"), "…the right one right")
	testing.expect(t, strings.contains(out, ":--:"), "…and the centred one centred")

	// round-tripping again is stable: what came out parses to the same thing
	doc2 := document_make("")
	defer document_destroy(&doc2)
	document_set_markdown(&doc2, out)
	m2 := block_meta(&doc2, head)
	testing.expect_value(t, m2.align, m.align)

	// a table that declared nothing still writes a plain separator
	plain := document_make("")
	defer document_destroy(&plain)
	document_set_markdown(&plain, "| a | b |\n|---|---|\n| 1 | 2 |\n")
	testing.expect_value(t, block_meta(&plain, 0).align, 0)
	testing.expect(t, strings.contains(document_markdown(&plain, context.temp_allocator), "|---|---|"),
		"nothing declared, nothing invented")
}

// The packing is two bits a column, so it has edges worth pinning.
@(test)
packed_alignment_holds_what_it_says_it_does :: proc(t: ^testing.T) {
	p := u64(0)
	p = table_align_set(p, 0, .Right)
	p = table_align_set(p, 31, .Center)
	testing.expect_value(t, table_align_get(p, 0), Table_Align.Right)
	testing.expect_value(t, table_align_get(p, 31), Table_Align.Center)
	testing.expect_value(t, table_align_get(p, 1), Table_Align.Default)
	testing.expect_value(t, table_align_get(p, 32), Table_Align.Default) // past the end, not a crash
	testing.expect_value(t, table_align_get(p, -1), Table_Align.Default)

	// setting a column again replaces it rather than merging
	p = table_align_set(p, 0, .Left)
	testing.expect_value(t, table_align_get(p, 0), Table_Align.Left)
	testing.expect_value(t, table_align_get(p, 31), Table_Align.Center) // …and leaves its neighbours
}

}
