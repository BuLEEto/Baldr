package baldr

// emoji_picker: a grid of every emoji the bundled face can draw, with a
// search field, the nine Unicode groups, skin tones and the app's own
// recents.
//
// It is one Tab stop, like `table` and `icon_view`: the grid takes the
// keyboard and the arrows move a cursor inside it, rather than putting two
// thousand Tab stops in the window. Typing goes to the search field.

import "base:runtime"
import "core:strings"

EMOJI_CELL      :: f32(34) // one cell, square
EMOJI_GLYPH     :: f32(24)
EMOJI_RECENT_MAX :: 24 // more than this and the section is a wall, not a shortcut

// Emoji_Row is one row of the picker's flat layout: a section heading, or a
// run of cells from `items`.
@(private)
Emoji_Row :: struct {
	header: string, // "" for a row of cells
	first:  int,    // into Emoji_Picker_State.items
	count:  int,
}

@(private)
Emoji_Picker_State :: struct {
	query:   Text,              // the search field's buffer (owned)
	items:   [dynamic]Emoji,    // what is shown, in order
	rows:    [dynamic]Emoji_Row,
	cursor:  int,               // index into items; -1 none
	cols:    int,
	skin:    Skin_Tone,
	built:   struct {           // what `items` was built for
		query:   string,        // owned
		recents: int,
		cols:    int,
		valid:   bool,
	},
	grid:    Node,
	hover:   int,  // the cell the pointer rests on, for the preview line
	jump_to: int,  // a group button was pressed: that row + 1 (0 = nothing asked)
	reveal_cursor: bool, // a key moved the cursor: bring it into view
	// The last sequence handed to the app. It lives here, not in temp
	// memory: a Msg is read in `update`, after the frame's scratch is gone.
	picked:   [EMOJI_SEQ_MAX]u8,
	picked_n: int,
}

@(private)
emoji_state_destroy :: proc(t: ^Tree, s: ^Emoji_Picker_State) {
	text_destroy(&s.query)
	delete(s.items)
	delete(s.rows)
	delete(s.built.query, t.allocator)
	s^ = {}
}

// emoji_picker builds the picker and sends `on_pick` the chosen emoji —
// the sequence itself, with the skin tone already applied, ready to insert.
//
// `recents` is the app's own list, most recent first (the first
// EMOJI_RECENT_MAX are shown), and `skin` the chosen tone: both outlive the
// window, so the app stores them, hearing a tone change through `on_skin`.
//
// The search field takes the keyboard when the picker appears. The whole
// grid is one Tab stop after it: arrows move the cursor, Home and End go to
// the ends of a row, Page Up and Down move a screen, and Enter or Space
// picks. Accessibility: the grid is a List named by `label` whose active
// item is the cell under the cursor, and every cell is named by its CLDR
// short name ("grinning face"), which is also what search matches.
emoji_picker :: proc(
	ui: ^Ui($Msg),
	on_pick: Handler(Msg, string),
	recents: []string = nil,
	skin: Skin_Tone = .None,
	on_skin: Handler(Msg, Skin_Tone) = nil,
	width: f32 = 0,
	height: f32 = 320,
	label := "Emoji",
	key: u64 = 0,
	loc := #caller_location,
) -> Node {
	t := &ui.tree
	th := &t.theme
	n := column(ui, gap = .xs, width = width, height = height, key = key, loc = loc)
	defer end(ui)
	set_role(t, n, .Group)
	set_name(t, n, label)

	st := &ui.emoji[n]
	fresh := st == nil
	if fresh {
		ui.emoji[n] = Emoji_Picker_State{cursor = -1, hover = -1}
		st = &ui.emoji[n]
		text_set(&st.query, "")
	}
	st.skin = skin

	// ---- search, and the tone swatch beside it
	row(ui, gap = .xs, align = .Center, key = 1, loc = loc)
	{
		defer end(ui)
		f := text_input(ui, &st.query, placeholder = "Search", label = "Search emoji", flex = 1, key = 1, loc = loc)
		set_role(t, f, .Search_Box)
		// The search field takes the keyboard when the picker appears, so
		// typing a name works at once; Tab moves on to the grid.
		if fresh do ui.pending_focus = f
		ui.emoji_fields[f] = n
		emoji_tone_row(ui, n, st, on_skin, loc)
	}

	// ---- the groups, as a strip that jumps the grid to a section
	emoji_group_strip(ui, n, st, loc)

	// ---- the grid
	q := strings.trim_space(str(st.query))
	cols := emoji_cols(t, n)
	st.cols = cols
	emoji_rebuild(t, st, q, recents, cols)
	// What the pointer rests on names itself in the preview line. A hover
	// only repaints, so the view is rebuilt when it moves to another cell:
	// once per cell crossed, nothing while the pointer is still.
	was_hover := st.hover
	st.hover = -1
	if ref, on_cell := ui.emoji_cells[t.hover]; on_cell && ref.picker == n do st.hover = ref.index
	if st.hover != was_hover do ask_rebuild(ui)

	st.grid = emoji_grid(ui, n, st, on_pick, label, loc)

	// ---- what is under the cursor, by name
	emoji_preview(ui, st, loc)
	_ = th
	return n
}

// emoji_cols is how many cells fit across. Taken from the picker's own
// width once it has been laid out, and from a sensible default before —
// which is one build of a slightly wrong grid, corrected on the next.
@(private)
emoji_cols :: proc(t: ^Tree, n: Node) -> int {
	w := node_get(t, n).rect.w
	if w <= 0 do w = 320
	return max(int(w / EMOJI_CELL), 1)
}

// emoji_rebuild lays the sections out, when something they depend on
// changed. Searching replaces the sections with one flat run of results:
// a heading per group over three matches is noise.
@(private)
emoji_rebuild :: proc(t: ^Tree, st: ^Emoji_Picker_State, query: string, recents: []string, cols: int) {
	if st.built.valid && st.built.cols == cols && st.built.query == query && st.built.recents == len(recents) do return
	delete(st.built.query, t.allocator)
	st.built = {query = strings.clone(query, t.allocator), recents = len(recents), cols = cols, valid = true}

	clear(&st.items)
	clear(&st.rows)
	add_rows :: proc(st: ^Emoji_Picker_State, from, cols: int) {
		for i := from; i < len(st.items); i += cols {
			append(&st.rows, Emoji_Row{first = i, count = min(cols, len(st.items) - i)})
		}
	}

	if len(query) > 0 {
		hits: [512]Emoji
		n := emoji_search(query, hits[:])
		append(&st.items, ..hits[:n])
		add_rows(st, 0, cols)
		st.cursor = 0 if n > 0 else -1
		return
	}

	if len(recents) > 0 {
		append(&st.rows, Emoji_Row{header = "Recently used"})
		from := len(st.items)
		for s in recents[:min(len(recents), EMOJI_RECENT_MAX)] {
			if e, ok := emoji_by_seq(s); ok do append(&st.items, e)
		}
		add_rows(st, from, cols)
	}
	for g, gi in EMOJI_GROUPS {
		lo, hi := emoji_group_range(gi)
		if lo >= hi do continue
		append(&st.rows, Emoji_Row{header = g})
		from := len(st.items)
		append(&st.items, ..emoji_table()[lo:hi])
		add_rows(st, from, cols)
	}
	if st.cursor >= len(st.items) do st.cursor = -1
}

// emoji_by_seq finds the table entry for a sequence the app remembered.
// A recent emoji the bundled face no longer draws is dropped rather than
// shown as a box.
@(private)
emoji_by_seq :: proc(seq: string) -> (Emoji, bool) {
	buf: [EMOJI_SEQ_MAX]u8
	for e in emoji_table() {
		if e.seq == seq do return e, true
		if !e.skin do continue
		for tone in Skin_Tone do if tone != .None && emoji_with_tone(e, tone, buf[:]) == seq do return e, true
	}
	return {}, false
}

// emoji_tone_row is the five tones plus the yellow default, as one small
// strip, always visible rather than behind a long press.
@(private)
emoji_tone_row :: proc(ui: ^Ui($Msg), owner: Node, st: ^Emoji_Picker_State, on_skin: Handler(Msg, Skin_Tone), loc: runtime.Source_Code_Location) {
	t := &ui.tree
	th := &t.theme
	if !handler_live(on_skin) do return // the app keeps no tone: do not offer one it would drop
	r := row(ui, gap = .xxs, align = .Center, key = 2, loc = loc)
	defer end(ui)
	set_role(t, r, .Group)
	set_name(t, r, "Skin tone")
	// The hand is the usual swatch: it is the emoji people check a tone
	// against, and it exists in every tone.
	hand, ok := emoji_by_name("raised back of hand")
	for tone in Skin_Tone {
		buf: [EMOJI_SEQ_MAX]u8
		glyph := "\U0001F590" if !ok else emoji_with_tone(hand, tone, buf[:])
		b, created := reconcile_child(ui, .Box, u64(tone) + 1, loc)
		d := node_get(t, b)
		if created {
			d.access.role = .Radio
			d.flags += {.Focusable}
		}
		set_name(t, b, emoji_tone_name(tone))
		set_checked(t, b, tone == st.skin)
		set_layout(t, b, Layout_Props{axis = .Row, align = .Center, justify = .Center, width = 22, height = 22})
		stl := d.style
		stl.radius = th.radius.sm
		stl.bg = with_alpha(th.color.primary, 0.18) if tone == st.skin else Color{}
		set_style(t, b, stl)
		handler_store_skin(ui, b, on_skin, tone)
		open_scope(ui, b, loc)
		g := text(ui, glyph, size = 15, nowrap = true, loc = loc)
		set_role(t, g, .None)
		close_scope(ui)
	}
}

@(private)
emoji_tone_name :: proc(tone: Skin_Tone) -> string {
	switch tone {
	case .None:         return "Default"
	case .Light:        return "Light skin tone"
	case .Medium_Light: return "Medium-light skin tone"
	case .Medium:       return "Medium skin tone"
	case .Medium_Dark:  return "Medium-dark skin tone"
	case .Dark:         return "Dark skin tone"
	}
	return "Default"
}

@(private)
emoji_by_name :: proc(name: string) -> (Emoji, bool) {
	for e in emoji_table() do if e.name == name do return e, true
	return {}, false
}

// handler_store_skin wires a tone swatch to send the app its tone.
@(private)
handler_store_skin :: proc(ui: ^Ui($Msg), n: Node, h: Handler(Msg, Skin_Tone), tone: Skin_Tone) {
	if !handler_live(h) do return
	ui.emoji_tones[n] = {h = h, tone = tone}
}

// emoji_group_strip is the nine groups as a row of buttons that scroll the
// grid to that section, with the first emoji of each as its face.
@(private)
emoji_group_strip :: proc(ui: ^Ui($Msg), owner: Node, st: ^Emoji_Picker_State, loc: runtime.Source_Code_Location) {
	t := &ui.tree
	th := &t.theme
	r := row(ui, gap = .xxs, align = .Center, key = 3, loc = loc)
	defer end(ui)
	set_role(t, r, .Tab_List)
	set_name(t, r, "Emoji groups")
	for g, gi in EMOJI_GROUPS {
		lo, _ := emoji_group_range(gi)
		face := emoji_table()[lo].seq if lo < len(emoji_table()) else "?"
		b, created := reconcile_child(ui, .Box, u64(gi) + 1, loc)
		d := node_get(t, b)
		if created {
			d.access.role = .Tab
			d.flags += {.Focusable}
		}
		set_name(t, b, g)
		set_layout(t, b, Layout_Props{axis = .Row, align = .Center, justify = .Center, flex = 1, height = 26})
		stl := d.style
		stl.radius = th.radius.sm
		set_style(t, b, stl)
		ui.emoji_jumps[b] = {picker = owner, group = gi}
		open_scope(ui, b, loc)
		gl := text(ui, face, size = 17, nowrap = true, loc = loc)
		set_role(t, gl, .None)
		close_scope(ui)
	}
}

// emoji_grid is the virtualised part: a `list` whose rows are a section
// heading or a run of cells, so two thousand emoji cost a screenful.
@(private)
emoji_grid :: proc(ui: ^Ui($Msg), owner: Node, st: ^Emoji_Picker_State, on_pick: Handler(Msg, string), label: string, loc: runtime.Source_Code_Location) -> Node {
	t := &ui.tree
	th := &t.theme

	// Where the grid should be looking. A group button says outright; an
	// arrow key says only when it took the cursor off screen, and then from
	// the nearer edge, so walking the grid scrolls by a row rather than
	// jumping the cursor to the middle every time.
	reveal := u64(0)
	at := f32(0)
	if st.jump_to > 0 {
		reveal, at = u64(st.jump_to), 0
	} else if st.reveal_cursor {
		if ri, ok := emoji_row_of(st, st.cursor); ok {
			was, seen := ui.lists[st.grid]
			switch {
			case !seen || ri < was.first: reveal, at = u64(ri + 1), 0.1
			case ri >= was.last:          reveal, at = u64(ri + 1), 0.9
			}
		}
	}
	// The grid is this picker's own list (key 4), and asking twice for the
	// same row is asking twice — no generation to keep in step
	// (reveal_cmd.odin).
	if reveal != 0 do reveal_own(ui, 4, reveal, at)

	// Keyed inside the picker, not in the app's key space: see
	// widget_table.odin, and `reveal_own` above asks for it as the toolkit.
	view_inner_begin(ui)
	first, last := list(ui, len(st.rows), estimated_height = EMOJI_CELL, flex = 1, label = label,
		key = 4, loc = loc)
	view_inner_end(ui)
	grid := ui.scopes[len(ui.scopes) - 1].node
	defer end(ui)
	set_role(t, grid, .List)
	// The grid itself takes the keyboard, which a scroll does not do on its
	// own: it is the one Tab stop for every cell, as a table is for its rows.
	node_get(t, grid).flags += {.Focusable}
	ui.emoji_grids[grid] = owner
	st.jump_to = 0

	buf: [EMOJI_SEQ_MAX]u8
	cursor_cell := NODE_NONE
	for ri in first ..< last {
		r := st.rows[ri]
		if r.header != "" {
			h := text(ui, r.header, role = .Label, muted = true, key = u64(ri + 1), loc = loc)
			set_role(t, h, .Heading)
			continue
		}
		row(ui, gap = 0, key = u64(ri + 1), loc = loc)
		for i in r.first ..< r.first + r.count {
			e := st.items[i]
			seq := emoji_with_tone(e, st.skin, buf[:])
			c, created := reconcile_child(ui, .Box, u64(i - r.first + 1), loc)
			d := node_get(t, c)
			if created do d.access.role = .List_Item
			set_name(t, c, e.name)
			set_layout(t, c, Layout_Props{axis = .Row, align = .Center, justify = .Center, width = EMOJI_CELL, height = EMOJI_CELL})
			stl := d.style
			stl.radius = th.radius.sm
			stl.bg = with_alpha(th.color.primary, 0.20) if i == st.cursor else Color{}
			set_style(t, c, stl)
			if i == st.cursor {
				d.access.states += {.Selected}
				set_active_item(t, grid, c)
				cursor_cell = c
			} else {
				d.access.states -= {.Selected}
			}
			ui.emoji_cells[c] = {picker = owner, index = i}
			open_scope(ui, c, loc)
			g := text(ui, seq, size = EMOJI_GLYPH, nowrap = true, loc = loc)
			set_role(t, g, .None)
			close_scope(ui)
		}
		end(ui)
	}
	if cursor_cell != NODE_NONE && st.reveal_cursor {
		scroll_into_view(t, cursor_cell) // it was built: a row's worth of movement, not a jump
	}
	st.reveal_cursor = false
	if handler_live(on_pick) do ui.emoji_picks[grid] = on_pick
	return grid
}

// emoji_row_of is the row holding item `i`.
@(private)
emoji_row_of :: proc(st: ^Emoji_Picker_State, i: int) -> (int, bool) {
	if i < 0 do return 0, false
	for r, ri in st.rows {
		if r.header == "" && i >= r.first && i < r.first + r.count do return ri, true
	}
	return 0, false
}

// emoji_preview is the line under the grid: the emoji the cursor or the
// pointer is on, and its name, which is what search matches.
@(private)
emoji_preview :: proc(ui: ^Ui($Msg), st: ^Emoji_Picker_State, loc: runtime.Source_Code_Location) {
	t := &ui.tree
	at := st.hover if st.hover >= 0 else st.cursor
	r := row(ui, gap = .sm, align = .Center, height = 24, key = 5, loc = loc)
	defer end(ui)
	set_role(t, r, .None)
	if at < 0 || at >= len(st.items) {
		text(ui, "", role = .Caption, muted = true, key = 1, loc = loc)
		return
	}
	buf: [EMOJI_SEQ_MAX]u8
	e := st.items[at]
	g := text(ui, emoji_with_tone(e, st.skin, buf[:]), size = 18, nowrap = true, key = 2, loc = loc)
	set_role(t, g, .None)
	text(ui, e.name, role = .Caption, muted = true, key = 1, loc = loc)
}

// ------------------------------------------------------------ wiring

// Emoji_Cell_Ref, Emoji_Jump_Ref and Emoji_Tone_Ref say what a node inside
// a picker means, so a click can be routed without reading its tag.
Emoji_Cell_Ref :: struct { picker: Node, index: int }
Emoji_Jump_Ref :: struct { picker: Node, group: int }
Emoji_Tone_Ref :: struct($Msg: typeid) { h: Handler(Msg, Skin_Tone), tone: Skin_Tone }

// emoji_click routes a click inside a picker: a cell picks, a swatch
// changes the tone, a group button jumps the grid to that section.
@(private)
emoji_click :: proc(ui: ^Ui($Msg), n: Node) -> bool {
	if ref, is_cell := ui.emoji_cells[n]; is_cell {
		st := &ui.emoji[ref.picker]
		if st == nil do return false
		st.cursor = ref.index
		if st.grid != NODE_NONE do set_focus(&ui.tree, st.grid, false) // the arrows carry on from where the pointer left off
		emoji_send(ui, ref.picker, st)
		return true
	}
	if ref, is_tone := ui.emoji_tones[n]; is_tone {
		handler_send(ui, ref.h, ref.tone, 0)
		return true
	}
	if ref, is_jump := ui.emoji_jumps[n]; is_jump {
		st := &ui.emoji[ref.picker]
		if st == nil do return false
		for r, ri in st.rows {
			if r.header == EMOJI_GROUPS[ref.group] {
				// +1 because 0 means "nothing asked". Pressing the same
				// group twice still moves: the ask is made each time
				// (reveal_cmd.odin).
				st.jump_to = ri + 1
				ask_rebuild(ui)
				return true
			}
		}
		return true
	}
	return false
}

// emoji_send tells the app what was picked, with the tone applied.
@(private)
emoji_send :: proc(ui: ^Ui($Msg), picker: Node, st: ^Emoji_Picker_State) {
	if st.cursor < 0 || st.cursor >= len(st.items) do return
	h, ok := ui.emoji_picks[st.grid]
	if !ok || h == nil do return
	seq := emoji_with_tone(st.items[st.cursor], st.skin, st.picked[:])
	// emoji_with_tone returns the table's own string when there is no tone
	// to apply, so copy either way: the app must get one answer, with one
	// lifetime, not two.
	st.picked_n = copy(st.picked[:], seq)
	handler_send(ui, h, string(st.picked[:st.picked_n]), 0)
}

// emoji_key moves the cursor in a focused grid and picks with it. The grid
// is one Tab stop, so these are the grid's own keys; anything else — a
// letter, Backspace — goes to the search field, which is what every picker
// does and what makes one usable without the pointer.
@(private)
emoji_key :: proc(ui: ^Ui($Msg), key: Key, mods: Mods) -> bool {
	t := &ui.tree
	// From the search field: Enter takes the best match, Down steps into
	// the grid, so a name typed and Enter needs no pointer.
	if owner, in_field := ui.emoji_fields[t.focus]; in_field {
		st := &ui.emoji[owner]
		if st == nil || len(st.items) == 0 do return false
		#partial switch key {
		case .Enter:
			if st.cursor < 0 do st.cursor = 0
			emoji_send(ui, owner, st)
			return true
		case .Down:
			if st.grid != NODE_NONE {
				if st.cursor < 0 do st.cursor = 0
				set_focus(t, st.grid, true)
				ask_rebuild(ui)
				return true
			}
		}
		return false
	}
	owner, is_grid := ui.emoji_grids[t.focus]
	if !is_grid do return false
	st := &ui.emoji[owner]
	if st == nil || len(st.items) == 0 do return false
	cols := max(st.cols, 1)
	cur := st.cursor if st.cursor >= 0 else 0
	moved := true
	#partial switch key {
	case .Left:   cur -= 1
	case .Right:  cur += 1
	case .Up:     cur -= cols
	case .Down:   cur += cols
	case .Home:   cur -= cur % cols
	case .End:    cur += cols - 1 - (cur % cols)
	case .Page_Up:   cur -= cols * 5
	case .Page_Down: cur += cols * 5
	case .Enter, .Space:
		st.cursor = clamp(cur, 0, len(st.items) - 1)
		emoji_send(ui, owner, st)
		return true
	case:
		moved = false
	}
	if !moved do return false
	st.cursor = clamp(cur, 0, len(st.items) - 1)
	st.reveal_cursor = true
	ask_rebuild(ui)
	return true
}
