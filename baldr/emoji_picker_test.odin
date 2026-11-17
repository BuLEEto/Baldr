package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// The emoji picker itself. The table's own tests are in emoji_test.odin;
// these are about the grid, the cursor and what reaches the app.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Ep_Msg :: union { string, Skin_Tone }

@(private = "file")
ep_pick :: proc(e: Ev(string)) -> Ep_Msg { return e.value }
@(private = "file")
ep_tone :: proc(e: Ev(Skin_Tone)) -> Ep_Msg { return e.value }

@(private = "file")
ep_build :: proc(ui: ^Ui(Ep_Msg), recents: []string = nil, skin: Skin_Tone = .None, tones := false) -> Node {
	set_viewport(&ui.tree, {360, 420})
	begin_view(ui)
	column(ui, flex = 1)
	n: Node
	if tones {
		n = emoji_picker(ui, ep_pick, recents = recents, skin = skin, on_skin = ep_tone, width = 340, height = 360, key = 1)
	} else {
		n = emoji_picker(ui, ep_pick, recents = recents, skin = skin, width = 340, height = 360, key = 1)
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {360, 420})
	return n
}

@(private = "file")
ep_cells :: proc(ui: ^Ui(Ep_Msg), picker: Node) -> (out: [dynamic]Node) {
	out = make([dynamic]Node, context.temp_allocator)
	for c, ref in ui.emoji_cells do if ref.picker == picker do append(&out, c)
	return
}

@(private = "file")
ep_cell_at :: proc(ui: ^Ui(Ep_Msg), picker: Node, index: int) -> Node {
	for c, ref in ui.emoji_cells do if ref.picker == picker && ref.index == index do return c
	return NODE_NONE
}

// It builds, it is virtualised, and clicking a cell sends that emoji.
@(test)
an_emoji_picker_builds_a_grid_and_a_click_picks :: proc(t: ^testing.T) {
	ui: Ui(Ep_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := ep_build(&ui)

	st := &ui.emoji[n]
	testing.expect(t, st != nil, "the picker has state")
	testing.expectf(t, len(st.items) > 1500, "every emoji is in the layout (%d)", len(st.items))
	cells := ep_cells(&ui, n)
	testing.expectf(t, len(cells) > 0 && len(cells) < 200,
		"**but only a screenful is built**: %d cells for %d emoji", len(cells), len(st.items))

	clear(&ui.msgs)
	cell := ep_cell_at(&ui, n, 3)
	testing.expect(t, cell != NODE_NONE, "the fourth cell is built")
	testing.expect(t, click(&ui, cell), "it takes a click")
	testing.expect_value(t, len(ui.msgs), 1)
	got, ok := ui.msgs[0].(string)
	testing.expect(t, ok, "the app is sent a string")
	testing.expect_value(t, got, st.items[3].seq)
}

// A cell must be a pointer target: `interactive_target` climbs past plain
// boxes to the grid, so a cell known only to the picker would never get a
// real click. Calling `click` on the node skips that path, so this test goes
// through the pointer.
@(test)
an_emoji_cell_is_what_the_pointer_lands_on :: proc(t: ^testing.T) {
	ui: Ui(Ep_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := ep_build(&ui)

	cell := ep_cell_at(&ui, n, 3)
	testing.expect(t, cell != NODE_NONE, "the cell is built")
	testing.expect_value(t, interactive_target(&ui, cell), cell)

	// and a press at its middle picks it, through the real path
	r := node_get(&ui.tree, cell).abs
	clear(&ui.msgs)
	pointer_move(&ui, {r.x + r.w / 2, r.y + r.h / 2}, true)
	testing.expect_value(t, ui.tree.hover, cell)
	ep_build(&ui) // the build that follows reads the hover for its preview line
	testing.expect_value(t, ui.emoji[n].hover, 3)
}

// Searching replaces the sections with one run of matches, best first.
@(test)
searching_an_emoji_picker_shows_the_matches :: proc(t: ^testing.T) {
	ui: Ui(Ep_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := ep_build(&ui)
	st := &ui.emoji[n]
	whole := len(st.items)

	text_set(&st.query, "cat")
	ep_build(&ui)
	st = &ui.emoji[n]
	testing.expectf(t, len(st.items) < whole / 10, "a search narrows it right down (%d of %d)", len(st.items), whole)
	testing.expect(t, len(st.items) > 0, "and finds cats")
	for e in st.items {
		ok := strings.has_prefix(e.name, "cat") || strings.contains(e.name, " cat")
		testing.expectf(t, ok, "%q matches", e.name)
	}
	for r in st.rows do testing.expect_value(t, r.header, "") // no section headings while searching

	text_set(&st.query, "")
	ep_build(&ui)
	testing.expect_value(t, len(ui.emoji[n].items), whole) // and clearing it puts them all back
}

// Arrows move the cursor by one and by a row; Enter picks what it is on.
@(test)
the_emoji_grid_is_one_tab_stop_its_arrows_move_a_cursor :: proc(t: ^testing.T) {
	ui: Ui(Ep_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := ep_build(&ui)
	st := &ui.emoji[n]
	testing.expect(t, focusable(&ui.tree, st.grid), "the grid is the Tab stop, so it must be focusable")
	set_focus(&ui.tree, st.grid, true)
	testing.expect_value(t, ui.tree.focus, st.grid)
	st.cursor = 0

	testing.expect(t, emoji_key(&ui, .Right, {}), "the grid takes Right")
	testing.expect_value(t, ui.emoji[n].cursor, 1)
	emoji_key(&ui, .Down, {})
	testing.expect_value(t, ui.emoji[n].cursor, 1 + ui.emoji[n].cols)
	emoji_key(&ui, .Up, {})
	testing.expect_value(t, ui.emoji[n].cursor, 1)
	emoji_key(&ui, .Home, {})
	testing.expect_value(t, ui.emoji[n].cursor, 0)
	emoji_key(&ui, .Left, {}) // already at the start: it stays, it does not wrap
	testing.expect_value(t, ui.emoji[n].cursor, 0)

	// a letter is not the grid's: it goes on to the search field
	testing.expect(t, !emoji_key(&ui, .A, {}), "a letter belongs to the search field")

	clear(&ui.msgs)
	testing.expect(t, emoji_key(&ui, .Enter, {}), "Enter picks")
	testing.expect_value(t, len(ui.msgs), 1)
	got, _ := ui.msgs[0].(string)
	testing.expect_value(t, got, ui.emoji[n].items[0].seq)
}

// The cursor takes the grid with it. The picker asks its own grid to show
// the cursor's row through `reveal_own` (reveal_cmd.odin), behind a fence
// bracketed around the grid's build so an app's ask cannot land in it nor
// its ask in an app's list. A misplaced bracket leaves the grid unscrolled
// while the cursor tests still pass, so this one watches the view.
@(test)
the_emoji_grid_follows_its_cursor_down :: proc(t: ^testing.T) {
	ui: Ui(Ep_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := ep_build(&ui)
	st := &ui.emoji[n]
	set_focus(&ui.tree, st.grid, true)
	st.cursor = 0
	ep_build(&ui)
	grid := ui.emoji[n].grid
	testing.expect_value(t, scroll_offset(&ui.tree, grid).y, 0)

	// Down far enough to leave the rows on screen. Each press is a build, as
	// a key press is in an app.
	rows_shown := ui.lists[grid].last - ui.lists[grid].first
	testing.expect(t, rows_shown > 1, "the grid shows more than one row of cells")
	for _ in 0 ..< rows_shown + 2 {
		emoji_key(&ui, .Down, {})
		ep_build(&ui)
	}

	testing.expect(t, scroll_offset(&ui.tree, ui.emoji[n].grid).y > 0,
		"the grid scrolled to the row the cursor reached")
	testing.expect(t, ui.emoji[n].cursor > 0, "…and the cursor is where it was moved to")
}

// A tone is applied to what is sent, not just to what is drawn — and the
// modifier lands inside the sequence, which is what emoji_with_tone is for.
@(test)
a_chosen_skin_tone_reaches_the_app_in_the_picked_sequence :: proc(t: ^testing.T) {
	ui: Ui(Ep_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := ep_build(&ui, skin = .Medium, tones = true)
	st := &ui.emoji[n]

	// find a cell whose emoji has tones
	target := -1
	for e, i in st.items do if e.skin { target = i; break }
	testing.expect(t, target >= 0, "something in the first group has tones")

	st.cursor = target
	clear(&ui.msgs)
	emoji_send(&ui, n, st)
	testing.expect_value(t, len(ui.msgs), 1)
	got, _ := ui.msgs[0].(string)
	buf: [EMOJI_SEQ_MAX]u8
	testing.expect_value(t, got, emoji_with_tone(st.items[target], .Medium, buf[:]))
	testing.expect(t, got != st.items[target].seq, "and it is not the plain yellow one")
}

// The app's recents go in a section of their own, at the top, and one the
// bundled face no longer draws is dropped rather than shown as a box.
@(test)
recents_lead_the_picker_and_an_unknown_one_is_dropped :: proc(t: ^testing.T) {
	ui: Ui(Ep_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	table := emoji_table()
	recents := []string{table[5].seq, table[9].seq, "\U0010FFFF"} // the last is not an emoji at all
	n := ep_build(&ui, recents = recents)
	st := &ui.emoji[n]

	testing.expect_value(t, st.rows[0].header, "Recently used")
	testing.expect_value(t, st.items[0].seq, table[5].seq)
	testing.expect_value(t, st.items[1].seq, table[9].seq)
	testing.expect_value(t, st.rows[1].count, 2) // the third was dropped, not drawn as a box
	testing.expect_value(t, st.rows[2].header, EMOJI_GROUPS[0])
}

// The preview line names what the cursor or the pointer is on. A grid of
// pictures with no names is a guessing game, and the name is what search
// matches — so it has to be visible, not merely built.
@(test)
the_preview_line_names_what_is_under_the_cursor :: proc(t: ^testing.T) {
	ui: Ui(Ep_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := ep_build(&ui)
	st := &ui.emoji[n]
	st.cursor = 2
	ep_build(&ui)

	// the preview row is the picker's last child, and it has room
	last := NODE_NONE
	for c := node_get(&ui.tree, n).first; c != NODE_NONE; c = node_get(&ui.tree, c).next do last = c
	testing.expect(t, last != NODE_NONE, "the picker has children")
	r := node_get(&ui.tree, last).abs
	testing.expectf(t, r.h >= 20, "the preview line has a height (%.0f)", r.h)

	// …and it holds the name of the emoji the cursor is on
	want := ui.emoji[n].items[2].name
	found := false
	walk :: proc(t: ^Tree, at: Node, want: string, found: ^bool) {
		for c := node_first(t, at); c != NODE_NONE; c = node_next(t, c) {
			if tk, ok := node_get(t, c).kind.(Text_Kind); ok && tk.str == want do found^ = true
			walk(t, c, want, found)
		}
	}
	walk(&ui.tree, last, want, &found)
	testing.expectf(t, found, "the preview says %q", want)
}

// Typing a name and pressing Enter picks the best match, without reaching
// for the pointer at the last step; Down steps from the field into the grid.
@(test)
enter_in_the_search_field_picks_the_best_match :: proc(t: ^testing.T) {
	ui: Ui(Ep_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := ep_build(&ui)
	st := &ui.emoji[n]

	field := NODE_NONE
	for f, picker in ui.emoji_fields do if picker == n do field = f
	testing.expect(t, field != NODE_NONE, "the picker has a search field")

	text_set(&st.query, "rocket")
	ep_build(&ui)
	set_focus(&ui.tree, field, true)

	clear(&ui.msgs)
	testing.expect(t, emoji_key(&ui, .Enter, {}), "Enter in the field picks")
	testing.expect_value(t, len(ui.msgs), 1)
	got, _ := ui.msgs[0].(string)
	testing.expect_value(t, got, "\U0001F680") // the rocket, which is the best match for "rocket"

	// …and Down steps into the grid, so the arrows carry on from there
	set_focus(&ui.tree, field, true)
	testing.expect(t, emoji_key(&ui, .Down, {}), "Down leaves the field")
	testing.expect_value(t, ui.tree.focus, ui.emoji[n].grid)
}

// Tone swatches are only offered when the app can keep the answer.
@(test)
tones_are_offered_only_when_the_app_will_keep_them :: proc(t: ^testing.T) {
	ui: Ui(Ep_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	n := ep_build(&ui, tones = false)
	testing.expect_value(t, len(ui.emoji_tones), 0)

	ui2: Ui(Ep_Msg)
	ui_init(&ui2)
	defer ui_destroy(&ui2)
	ep_build(&ui2, tones = true)
	testing.expect_value(t, len(ui2.emoji_tones), len(Skin_Tone)) // six, including the yellow default
	_ = n
}

}
