package baldr

@(require) import "core:fmt"
@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A wrapped editor's height map: a block's height is measured where it has
// been looked at and estimated from its length everywhere else
// (widget_text_area.odin, "the height map"), so opening or editing a long
// document does not shape every block.
//
// These tests hold both halves of that: opening a long document shapes only
// what is on screen, and nothing *drawn* is ever placed by an estimate; plus
// what the map must get right as the document is edited under it. The
// byte-to-x table (`area_cum`) tests check the cache that saves a painter
// from shaping a prefix per position on a line.

@(private = "file")
Hm_Msg :: union { int }

@(private = "file")
Hm_Fx :: struct {
	ui:   Ui(Hm_Msg),
	te:   Text_Engine,
	doc:  Document,
	n:    Node,
	font: bool, // a real text engine: estimates and measurements differ
	wrap: Maybe(bool), // what editor_options is told each build
	marks: []Mark,     // …and what editor_marks is given
	code: bool,        // build a code editor (mono, tab stops) rather than a text area
}

// hm_lines is a document of `n` lines of uneven length, as a log is.
@(private = "file")
hm_lines :: proc(n: int) -> string {
	b := strings.builder_make(context.temp_allocator) // the document copies it; hm_init frees nothing (its callers pass literals too)
	for i in 0 ..< n {
		fmt.sbprintf(&b, "line %d ", i)
		for _ in 0 ..< 3 + (i * 7) % 28 do strings.write_string(&b, "wordy ")
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

@(private = "file")
hm_build :: proc(fx: ^Hm_Fx, size: [2]f32 = {400, 300}) {
	begin_view(&fx.ui)
	column(&fx.ui, flex = 1)
	fx.n = code_editor(&fx.ui, &fx.doc, nil, flex = 1) if fx.code else text_area(&fx.ui, &fx.doc, flex = 1)
	if fx.code do fx.n = fx.ui.tree.area_of_frame[fx.n] // the code editor returns its frame
	if w, set := fx.wrap.?; set do editor_options(&fx.ui, fx.n, wrap = w)
	if fx.code do editor_options(&fx.ui, fx.n, tab_width = 4, line_numbers = false)
	if fx.marks != nil do editor_marks(&fx.ui, fx.n, fx.marks)
	end(&fx.ui)
	end_view(&fx.ui)
	frame(&fx.ui.tree, size)
}

@(private = "file")
hm_init :: proc(fx: ^Hm_Fx, text: string, font := false, size: [2]f32 = {400, 300}) {
	ui_init(&fx.ui)
	if font {
		fx.font = text_engine_init(&fx.te)
		if fx.font do tree_use_text_engine(&fx.ui.tree, &fx.te)
	}
	fx.doc = document_make(text) // the blocks take a copy
	hm_build(fx, size)
}

@(private = "file")
hm_destroy :: proc(fx: ^Hm_Fx) {
	ui_destroy(&fx.ui)
	document_destroy(&fx.doc)
	if fx.font do text_engine_destroy(&fx.te)
}

@(private = "file")
hm_state :: proc(fx: ^Hm_Fx) -> ^Text_Area_State {
	return &fx.ui.tree.areas[fx.n]
}

@(private = "file")
hm_measured :: proc(s: ^Text_Area_State) -> (n: int) {
	for m in s.hmeasured do if m do n += 1
	return
}

// Opening a long document shapes what is on screen, not the document.
@(test)
a_long_document_is_not_shaped_to_open_it :: proc(t: ^testing.T) {
	fx: Hm_Fx
	hm_init(&fx, hm_lines(4000), font = true)
	defer hm_destroy(&fx)
	s := hm_state(&fx)
	testing.expect_value(t, len(s.heights), 4001) // 4,000 lines and the empty one after the last newline
	shaped := hm_measured(s)
	testing.expectf(t, shaped < 120, "a 4,000 line document shaped %d blocks to open 300 px of it", shaped)
	testing.expect(t, shaped > 0, "…but it did shape the ones on screen")
	testing.expect(t, content_height(&fx.ui.tree, s) > 4000 * s.line_h * 0.5, "and it still has a height to scroll through")
}

// The invariant the estimates rest on: anything drawn was measured first,
// so an estimate only ever decides how far away something off screen is.
@(test)
what_is_painted_is_never_placed_by_an_estimate :: proc(t: ^testing.T) {
	fx: Hm_Fx
	hm_init(&fx, hm_lines(2000), font = true)
	defer hm_destroy(&fx)
	s := hm_state(&fx)
	for off in ([]f32{0, 900, 4000, 12_000}) {
		scroll_to(&fx.ui.tree, fx.n, {0, off})
		hm_build(&fx)
		st := fx.ui.tree.scrolls[fx.n]
		tops := area_tops(&fx.ui.tree, s)
		first := block_at_y(&fx.ui.tree, s, st.offset.y)
		for b := first; b < len(s.heights) && tops[b] < st.offset.y + st.viewport.y; b += 1 {
			testing.expectf(t, s.hmeasured[b], "block %d is in view at offset %.0f and was drawn from an estimate", b, st.offset.y)
		}
	}
}

// What an edit costs: the blocks it did not touch keep their heights and
// measurements, because they are stamped per block, not by document version.
@(test)
an_edit_keeps_the_heights_the_blocks_it_did_not_touch :: proc(t: ^testing.T) {
	fx: Hm_Fx
	hm_init(&fx, hm_lines(500), font = true)
	defer hm_destroy(&fx)
	s := hm_state(&fx)
	scroll_to(&fx.ui.tree, fx.n, {0, 3000}) // read a way into it, so there are measurements to keep
	hm_build(&fx)
	before := hm_measured(s)
	testing.expect(t, before > 4, "some blocks have been measured")
	far := -1
	for m, b in s.hmeasured do if m && b > 20 { far = b; break }
	testing.expect(t, far > 0, "…and one of them is well away from block 3")
	was := s.heights[far]

	document_replace(&fx.doc, {3, 0}, {3, 0}, "x", group = 1)
	hm_build(&fx)

	testing.expect(t, s.hmeasured[far], "a block the edit never touched is still measured")
	testing.expect_value(t, s.heights[far], was)
	testing.expectf(t, hm_measured(s) >= before - 2, "and the edit kept the rest: %d of %d left", hm_measured(s), before)
}

// …including when the edit inserts and removes whole blocks: the suffix
// is matched by stamp, so it slides rather than being measured again.
@(test)
blocks_inserted_above_do_not_cost_the_ones_below_their_heights :: proc(t: ^testing.T) {
	fx: Hm_Fx
	hm_init(&fx, hm_lines(300), font = true)
	defer hm_destroy(&fx)
	s := hm_state(&fx)
	scroll_to(&fx.ui.tree, fx.n, {0, 2000})
	hm_build(&fx)
	far := -1
	for m, b in s.hmeasured do if m && b > 30 { far = b; break }
	testing.expect(t, far > 0, "a measured block well below the insertion")
	was := s.heights[far]

	document_replace(&fx.doc, {2, 0}, {2, 0}, "one\ntwo\n", group = 1) // two new blocks above it
	hm_build(&fx)
	testing.expect_value(t, len(s.heights), 303) // 301 + 2
	testing.expect(t, s.hmeasured[far + 2], "the same block, two further down, kept its measurement")
	testing.expect_value(t, s.heights[far + 2], was)

	document_replace(&fx.doc, {2, 0}, {4, 0}, "", group = 2) // …and back out again
	hm_build(&fx)
	testing.expect_value(t, len(s.heights), 301)
	testing.expect(t, s.hmeasured[far], "and back where it was, still measured")
	testing.expect_value(t, s.heights[far], was)
}

// A block whose text changed is measured again rather than kept: the
// stamp is what says so, and this is the test that fails if a document
// mutation forgets to clear one.
@(test)
an_edited_block_is_measured_again :: proc(t: ^testing.T) {
	fx: Hm_Fx
	hm_init(&fx, hm_lines(200), font = true)
	defer hm_destroy(&fx)
	s := hm_state(&fx)
	tall := block_height(&fx.ui.tree, s, 0)
	testing.expect(t, s.hmeasured[0], "block 0 is on screen, so it is measured")

	// a long line in place of a short one: more wrapped lines, a taller block
	long := strings.repeat("a wrapped sentence that goes on ", 8, context.temp_allocator)
	document_replace(&fx.doc, {0, 0}, {0, 0}, long, group = 1)
	hm_build(&fx)
	testing.expect(t, s.heights[0] > tall, "the block it was typed into is taller now")
	testing.expect(t, s.hmeasured[0], "and that height is a measurement, not a guess")
	testing.expect_value(t, s.heights[0], block_height(&fx.ui.tree, s, 0))

	// …and the document's height followed it
	testing.expect(t, content_height(&fx.ui.tree, s) > 200 * s.line_h, "the document grew with it")
}

// Reading through a document replaces its estimates with measurements,
// and the height it reports settles on the real one.
@(test)
the_height_settles_as_the_document_is_read :: proc(t: ^testing.T) {
	fx: Hm_Fx
	hm_init(&fx, hm_lines(400), font = true)
	defer hm_destroy(&fx)
	s := hm_state(&fx)
	t2 := &fx.ui.tree
	for off: f32 = 0; off < content_height(t2, s); off += 250 {
		scroll_to(t2, fx.n, {0, off})
		hm_build(&fx)
	}
	testing.expect_value(t, hm_measured(s), len(s.heights)) // every block has been looked at
	sum: f32
	for b in 0 ..< len(s.heights) do sum += block_height(t2, s, b)
	got := content_height(t2, s)
	testing.expectf(t, abs(got - sum) < 0.5, "the height it reports (%.1f) is the one it measures (%.1f)", got, sum)
}

// A narrower window re-estimates every height, so keeping the content *y*
// would land the reader somewhere else entirely in a long document. The
// block they were reading goes back under the top of the view instead.
@(test)
the_view_keeps_its_place_when_the_width_changes :: proc(t: ^testing.T) {
	fx: Hm_Fx
	hm_init(&fx, hm_lines(600), font = true, size = {500, 300})
	defer hm_destroy(&fx)
	s := hm_state(&fx)
	t2 := &fx.ui.tree
	scroll_to(t2, fx.n, {0, 5000})
	hm_build(&fx, {500, 300})
	was := block_at_y(t2, s, fx.ui.tree.scrolls[fx.n].offset.y)
	testing.expect(t, was > 10, "a good way into the document")

	hm_build(&fx, {320, 300}) // the window narrows: every block wraps differently
	now := block_at_y(t2, s, fx.ui.tree.scrolls[fx.n].offset.y)
	testing.expectf(t, abs(now - was) <= 1, "the reader was on block %d and is now on block %d", was, now)
	testing.expect(t, fx.ui.tree.scrolls[fx.n].offset.y > 5000, "…which is further down the taller, narrower document")
}

// The map is per document: an editor given another file must not answer
// from the first one's heights.
@(test)
a_second_document_does_not_inherit_the_first_ones_heights :: proc(t: ^testing.T) {
	fx: Hm_Fx
	hm_init(&fx, hm_lines(300), font = true)
	defer hm_destroy(&fx)
	s := hm_state(&fx)
	tall := content_height(&fx.ui.tree, s)

	document_destroy(&fx.doc)
	fx.doc = document_make("one line only") // the builder is given a different document next build
	hm_build(&fx)
	s = hm_state(&fx)
	testing.expect_value(t, len(s.heights), 1)
	testing.expect(t, content_height(&fx.ui.tree, s) < tall / 10, "a one-line document is a one-line document")
}


// The table has to answer exactly what shaping a prefix answers, because
// it is what places carets, selections and syntax colours.
@(test)
the_byte_to_x_table_agrees_with_shaping_the_prefix :: proc(t: ^testing.T) {
	line := strings.concatenate({"let total = sum(values) + offset * 2;  // ",
		strings.repeat("a longer stretch of ordinary words ", 12, context.temp_allocator)}, context.temp_allocator)
	for wrapped in ([]bool{false, true}) {
		fx: Hm_Fx
		hm_init(&fx, strings.clone(line, context.temp_allocator), font = true, size = {420, 300})
		defer hm_destroy(&fx)
		if !fx.font do return // no fonts here: the table is not used at all
		fx.wrap = wrapped
		hm_build(&fx, {420, 300})
		s := hm_state(&fx)
		te := fx.ui.tree.text
		str := area_text(&fx.ui.tree, s, 0)
		spans := block_spans(&fx.ui.tree, s, 0, context.temp_allocator)
		testing.expect(t, wrapped == (len(spans) > 1), "the fixture wraps when it is meant to")
		checked := 0
		for sp in spans {
			for off := sp.start + 1; off < sp.end; off += 7 {
				got := span_x_disp(&fx.ui.tree, s, 0, sp, off)
				want := prefix_width(te, str[sp.start:off], s.size, s.mono, s.tab, no_liga = area_no_liga(s), family = s.family)
				testing.expectf(t, abs(got - want) < 0.5, "byte %d: the table says %.2f, shaping says %.2f", off, got, want)
				checked += 1
			}
		}
		testing.expect(t, checked > 20, "enough positions to mean something")
	}
}

// …and it is rebuilt when the line it describes changes, rather than
// answering for the text that was there before.
@(test)
the_byte_to_x_table_follows_an_edit :: proc(t: ^testing.T) {
	fx: Hm_Fx
	hm_init(&fx, "abcdefghij klmnopqrst", font = true)
	defer hm_destroy(&fx)
	if !fx.font do return
	fx.wrap = false
	hm_build(&fx)
	s := hm_state(&fx)
	spans := block_spans(&fx.ui.tree, s, 0, context.temp_allocator)
	was := span_x_disp(&fx.ui.tree, s, 0, spans[0], 11)

	document_replace(&fx.doc, {0, 0}, {0, 0}, "WWWW", group = 1) // four wide letters in front of it
	hm_build(&fx)
	spans = block_spans(&fx.ui.tree, s, 0, context.temp_allocator)
	now := span_x_disp(&fx.ui.tree, s, 0, spans[0], 15) // the same character, four bytes along
	testing.expectf(t, now > was + 10, "the x moved with the text: %.1f then %.1f", was, now)
	te := fx.ui.tree.text
	str := area_text(&fx.ui.tree, s, 0)
	want := prefix_width(te, str[:15], s.size, s.mono, s.tab, no_liga = area_no_liga(s), family = s.family)
	testing.expectf(t, abs(now - want) < 0.5, "and it is still the shaped width: %.2f against %.2f", now, want)

	// …and an edit that changes no byte count at all, which only the
	// block's stamp can report: four narrow letters for four wide ones.
	document_replace(&fx.doc, {0, 4}, {0, 8}, "WWWW", group = 2)
	hm_build(&fx)
	spans = block_spans(&fx.ui.tree, s, 0, context.temp_allocator)
	same_len := span_x_disp(&fx.ui.tree, s, 0, spans[0], 15)
	str = area_text(&fx.ui.tree, s, 0)
	want2 := prefix_width(te, str[:15], s.size, s.mono, s.tab, no_liga = area_no_liga(s), family = s.family)
	testing.expectf(t, abs(same_len - want2) < 0.5, "a same-length edit moved the text: %.2f against %.2f", same_len, want2)
	testing.expectf(t, same_len > now + 5, "and it is wider than before (%.1f against %.1f)", same_len, now)
}


// A block's *shape* can change without a byte of its text changing — a
// paragraph made a heading is taller, and nothing about its text says so.
// The stamp has to report that too, or a markdown editor shows a heading
// in a paragraph's space.
@(test)
a_blocks_height_follows_its_kind :: proc(t: ^testing.T) {
	fx: Hm_Fx
	hm_init(&fx, "a line of ordinary words\nanother line\n", font = true)
	defer hm_destroy(&fx)
	if !fx.font do return
	s := hm_state(&fx)
	s.rich = true // a markdown editor's view of the same document
	s.tops_valid = false
	hm_build(&fx)
	was := s.heights[0]

	document_set_meta(&fx.doc, 0, Block_Meta{kind = .Heading, level = 1}, group = 1)
	hm_build(&fx)
	testing.expectf(t, s.heights[0] > was * 1.2, "a heading takes more room than the paragraph did (%.1f against %.1f)", s.heights[0], was)
	testing.expect(t, s.hmeasured[0], "and it was measured, not guessed")
	testing.expect_value(t, s.heights[0], block_height(&fx.ui.tree, s, 0))
}


// Marks are indexed by block, since an editor may hand over one per word and
// a linear walk per block in view is too slow. The index must not change
// *which* marks are drawn: these cases break if the lookup is off by a
// block, or if a long mark falls out of it.
@(private = "file")
hm_mark_rects :: proc(fx: ^Hm_Fx, col: Color) -> (n: int) {
	for _, l in fx.ui.tree.layers do for c in l.cmds {
		if v, ok := c.(Draw_Rect); ok && v.color.r == col.r && v.color.g == col.g && v.color.b == col.b do n += 1
	}
	return
}

@(test)
a_mark_is_found_on_its_own_block_wherever_it_is :: proc(t: ^testing.T) {
	fx: Hm_Fx
	hm_init(&fx, hm_lines(400), font = true)
	defer hm_destroy(&fx)
	HIGH :: Color{0.9, 0.2, 0.2, 1}
	fx.marks = []Mark{
		{from = {2, 0}, to = {2, 4}, kind = .Highlight, color = HIGH},
		{from = {380, 0}, to = {380, 4}, kind = .Highlight, color = HIGH},
	}
	hm_build(&fx)
	testing.expect(t, hm_mark_rects(&fx, fx.ui.tree.theme.color.warning) > 0, "the mark near the top is painted")

	// …and the one 380 blocks down is painted when it is in view, which is
	// the lookup the index does
	scroll_to(&fx.ui.tree, fx.n, {0, block_top(&fx.ui.tree, hm_state(&fx), 380) - 40})
	hm_build(&fx)
	testing.expect(t, hm_mark_rects(&fx, fx.ui.tree.theme.color.warning) > 0, "and so is the one far down the document")

	// a block with no mark on it draws none of them
	scroll_to(&fx.ui.tree, fx.n, {0, block_top(&fx.ui.tree, hm_state(&fx), 200)})
	hm_build(&fx)
	testing.expect_value(t, hm_mark_rects(&fx, fx.ui.tree.theme.color.warning), 0)

	// …and a mark that *starts* on the block above still belongs to this
	// one: a selection-shaped mark over a line break is the common case,
	// and an index that looked only at marks starting here would lose it.
	fx.marks = []Mark{{from = {5, 2}, to = {6, 3}, kind = .Highlight, color = HIGH}}
	scroll_to(&fx.ui.tree, fx.n, {0, 0})
	hm_build(&fx)
	s := hm_state(&fx)
	on_six := area_marks_for(s, 6)
	testing.expect_value(t, len(on_six), 1)
	testing.expect_value(t, len(area_marks_for(s, 5)), 1) // and to the block it starts on
	testing.expect_value(t, len(area_marks_for(s, 7)), 0) // but not to the one after it
}

// A mark that covers hundreds of blocks (a focus fade) is not indexed by
// its first block — it is kept aside and looked at for every block, or it
// would vanish the moment the reader scrolled past its start.
@(test)
a_mark_covering_many_blocks_paints_in_the_middle_of_it :: proc(t: ^testing.T) {
	fx: Hm_Fx
	hm_init(&fx, hm_lines(300), font = true)
	defer hm_destroy(&fx)
	fx.marks = []Mark{{from = {0, 0}, to = {290, 2}, kind = .Dim}}
	hm_build(&fx)
	scroll_to(&fx.ui.tree, fx.n, {0, block_top(&fx.ui.tree, hm_state(&fx), 150)})
	hm_build(&fx)
	s := hm_state(&fx)
	testing.expect_value(t, len(s.mark_long), 1) // too long to be indexed by its first block
	testing.expect_value(t, len(area_marks_for(s, 150)), 1)
	tints := area_mark_tints(&fx.ui.tree, s, 150, context.temp_allocator)
	testing.expect(t, len(tints) > 0, "and block 150 in the middle of it is faded")
}


// Ctrl+End in a long wrapped file arrives at the end. A reveal worked out
// from estimates alone falls short, because measuring the blocks it brings
// into view moves the end further down; a reveal measures what it lands on.
@(test)
a_reveal_to_the_end_of_a_long_file_arrives_there :: proc(t: ^testing.T) {
	fx: Hm_Fx
	hm_init(&fx, hm_lines(2000), font = true, size = {420, 300})
	defer hm_destroy(&fx)
	if !fx.font do return
	hm_build(&fx, {420, 300})

	set_focus(&fx.ui.tree, fx.n, true)
	key_event(&fx.ui, .Home, true, {.Ctrl}) // to the top first, so the end is all estimates
	hm_build(&fx, {420, 300})
	key_event(&fx.ui, .End, true, {.Ctrl})
	hm_build(&fx, {420, 300})

	s := hm_state(&fx)
	st := fx.ui.tree.scrolls[fx.n]
	testing.expect_value(t, s.caret.block, len(s.heights) - 1) // the last block
	line, _, _ := caret_line(&fx.ui.tree, s, s.caret)
	cy := block_text_top(&fx.ui.tree, s, s.caret.block) + f32(line) * area_line_h(&fx.ui.tree, s, s.caret.block)
	testing.expectf(t, cy >= st.offset.y && cy <= st.offset.y + st.viewport.y,
		"the caret at %.0f is in the view [%.0f, %.0f]", cy, st.offset.y, st.offset.y + st.viewport.y)
}


// A markdown editor skips its picture bookkeeping when there are no
// pictures, which saves a walk of every block per call. The count has to
// follow blocks coming and going, or a document would either do that work
// for ever or stop following a picture that loaded.
@(test)
the_picture_count_follows_the_document :: proc(t: ^testing.T) {
	fx: Hm_Fx
	hm_init(&fx, "# A heading\n\nsome words\n\nmore words\n", font = true)
	defer hm_destroy(&fx)
	s := hm_state(&fx)
	s.rich = true
	s.tops_valid = false
	hm_build(&fx)
	testing.expect_value(t, hm_state(&fx).image_count, 0)

	// a picture block: the kind is the document's, not something a plain
	// editor parses out of the text
	document_replace(&fx.doc, {2, 0}, {2, 0}, "a picture\n", group = 1)
	document_set_meta(&fx.doc, 2, Block_Meta{kind = .Image, src = "shot.png"}, group = 1)
	hm_build(&fx)
	testing.expect_value(t, hm_state(&fx).image_count, 1)

	// a block inserted above it must not lose the count of it
	document_replace(&fx.doc, {0, 0}, {0, 0}, "another heading\n", group = 2)
	hm_build(&fx)
	testing.expect_value(t, hm_state(&fx).image_count, 1)
	testing.expect(t, hm_state(&fx).himage[3], "…and it is the block it moved to")

	// …and when it stops being a picture, the editor stops looking for one
	document_set_meta(&fx.doc, 3, Block_Meta{kind = .Paragraph}, group = 3)
	hm_build(&fx)
	testing.expect_value(t, hm_state(&fx).image_count, 0)
}


// An unwrapped editor's content width comes from its longest lines, ranked
// by byte length; but a tab is one byte and draws as up to tab-width cells,
// so a deeply tab-indented line can draw wider than lines with more bytes,
// and the horizontal scroll must still reach its end.
@(test)
a_tab_indented_line_counts_as_wide_as_it_draws :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for _ in 0 ..< 60 do strings.write_string(&b, "ordinary line of source that is fairly long\n")
	for _ in 0 ..< 14 do strings.write_byte(&b, '\t') // 14 tabs…
	strings.write_string(&b, "deep(arg)\n")           // …and almost nothing after them
	fx: Hm_Fx
	hm_init(&fx, strings.clone(strings.to_string(b), context.temp_allocator), font = true, size = {400, 300})
	defer hm_destroy(&fx)
	if !fx.font do return
	fx.code, fx.wrap = true, false // a code editor: mono, with tab stops
	hm_build(&fx, {400, 300})
	hm_build(&fx, {400, 300})
	s := hm_state(&fx)
	testing.expect(t, s.mono && s.tab == 4, "the fixture is a code editor with 4-cell tabs")

	tabbed := len(s.heights) - 2 // the tab-indented line, before the empty last block
	spans := block_spans(&fx.ui.tree, s, tabbed, context.temp_allocator)
	testing.expect_value(t, len(spans), 1)
	drawn := spans[0].width
	plain := block_spans(&fx.ui.tree, s, 0, context.temp_allocator)[0].width
	testing.expectf(t, drawn > plain, "the fixture's indented line draws wider (%.0f) than an ordinary one (%.0f)", drawn, plain)
	testing.expectf(t, area_widest(&fx.ui.tree, s) >= drawn, "the content is as wide as its widest line: %.0f against %.0f", area_widest(&fx.ui.tree, s), drawn)
}

}
