package baldr

// list is a virtualised vertical list: only the rows that intersect the
// viewport (plus a small overscan) are built each view; the rest is
// represented by two spacers, so a hundred thousand rows cost what a screen
// of them does. Rows have one fixed `row_height` (plus `gap`); build them
// yourself between list and end, keyed by index:
//
//	first, last := baldr.list(ui, len(s.rows), row_height = 56, label = "Inbox"); {
//		defer baldr.end(ui)
//		for i in first ..< last {
//			baldr.card(ui, height = 56, key = u64(i + 1)); { defer baldr.end(ui); … }
//		}
//	}
//
// **Rows of different heights**: pass `estimated_height` instead of
// `row_height` and each row sizes to its content.
//
//	first, last := baldr.list(ui, len(s.msgs), estimated_height = 72, label = "Chat")
//
// A row is measured once it has been laid out and its height kept by its
// key, so rows loaded above do not renumber what is known. Rows never built
// stand at the estimate, so it should be near the common case: a bad one
// costs a visible settle, not correctness. The window is found by a binary
// search over the measured tops.
//
// **A list that knows its rows' heights** gives `height_of` instead (pages
// at the current zoom, a table of two row kinds): nothing is estimated or
// measured, the offsets are exact from the first build, and each row is made
// the height given. Use it when every row changes height together, which a
// list of estimates only catches up with as it measures again.
//
//	first, last := baldr.list(ui, len(s.pages), height_of = page_height, key_user = s)
//
// **Keeping the reader's place.** Give `key_of` so a row's identity does not
// move when the app prepends; then `follow_end` rides the newest row (and
// lets go the moment the reader scrolls up), and `on_at` reports a `List_At`
// whenever the resting place changes. `key_of` is asked only between this
// call and its `end`, so `key_user` may point at the build's temp memory;
// the key for an index must not change between two builds passed the same
// rows, or the heights follow the wrong rows.
//
// **Moving the view** is a command from `update` (reveal_cmd.odin), never a
// parameter: scrolling to a row happens once, and a view is rebuilt
// constantly. `reveal_key` sends it to a row (`table` and `icon_view` take
// `reveal_index`); revealing the last row pins to the end and follows again,
// so `at_end` is reported at once. `hold` and `hold_at`, returned with the
// zoom that needs them, keep a point still across it: applied in the build
// that changed the scale, before the range is chosen, so no frame is built
// from the old offsets. With `height_of` it lands exactly; with estimates it
// is out by their error above the row, so ask again on the next build.
//
//	baldr.hold_at(Msg, PAGES, at = {0, y}, axes = {.Y})  // keep what is there
//	baldr.hold(Msg, PAGES, row, point, at)               // …or a named point
//
// Prefer `hold_at`: it names a spot of the viewport, resolved from the offset
// the list is really on, where an app's own note can be a scroll behind (the
// list does not rebuild for a scroll that keeps the same rows on screen), and
// it keeps a fraction of the row, so there is no scale to apply. `hold`'s
// `point` is px into the row, which with `content_width` is that whole width,
// measured from the content's left edge and not inside the list's padding;
// `axes = {.Y}` spares that arithmetic.
//
// **`gutter`** keeps every row clear of the overlay scrollbar, always
// reserved, not only while the content overflows; pass it when rows put
// something at their right edge, which the bar would otherwise cover. `table`
// and `icon_view` take it off their column widths, so headings stay above
// their cells.
//
// **`content_width`** makes it scroll sideways too: rows are laid out that
// wide, a naturally wider row keeps its width and the others widen to match,
// and a bar is drawn along the bottom. It is the app's number because only
// built rows are measured, and the widest of those would move the extent as
// it scrolls. The wheel's x, Shift+wheel, a touchpad, `scroll_by` /
// `scroll_to` on `list_node(ui)` and Shift+Page/Home/End pan it;
// virtualisation stays by row, down.
//
// Scrolling that changes the visible range re-runs the view (Ui.needs_rebuild).
// Rows scrolled out of range are destroyed, so keep row state in the app,
// not in the widget. Accessibility: role List named by `label`; Page Up/Down,
// Home and End scroll it (with Shift, sideways where it scrolls sideways),
// and keyboard focus scrolls rows into view.

import "base:runtime"

List_State :: struct {
	count:      int,
	row_height: f32,
	gap:        f32,
	first, last: int, // rows built in the latest view
	tail_pad:   f32,  // empty space after the last row (background a file manager can click)
	warned:     bool, // unkeyed-row diagnostic already raised
	pitch_seen: f32,  // row pitch of the latest build: a change re-anchors the scroll on the same row
	range_sent: [2]int, // the rows on_range last reported ({-1, -1} before the first)

	// ---- variable-height rows: `estimate` > 0 turns it on. Each row's
	// height is measured once laid out and kept by its key, not its index,
	// so rows loaded above do not renumber what is known.
	estimate: f32,
	// …or the app's own exact numbers, and then nothing is estimated or
	// measured and `heights` stays empty.
	height_of: Row_Height,
	heights:  map[u64]f32,   // measured height by row key
	tops:     [dynamic]f32,  // tops[i] is row i's y; len is count+1, so tops[count] is the whole height
	tops_ok:  bool,
	key_of:   Row_Key,       // index -> the app's stable key (nil: u64(i + 1))
	key_user: rawptr,
	// The keys of the rows the last build built, `first ..< last`, so code
	// running between builds can name a row without calling `key_of`, whose
	// model may live in the build's temp memory. Only the built range: a few
	// dozen u64s, not one per row.
	built_keys: [dynamic]u64,

	// What the scroll was resting on last build, so that rows arriving
	// above it do not move it: the key of the first row on screen
	// and how far into that row the viewport's top was. `at_end` is whether
	// the view was against the bottom, which is what "follow the end" means.
	anchor_key:   u64,
	anchor_delta: f32,
	note_off:     f32,  // the offset that anchor was taken at, so a scroll since can re-take it
	height_seen:  f32,  // the content height at the end of the last build: a row that *grew* moved it
	at_end:       bool,
	following:    bool, // sticky: the reader is riding the newest row
	count_seen:   int,
	placed:       bool, // a first build has happened
	reveal_pend:  u64,  // …and the one still to be acted on, once there is a viewport to place it in
	reveal_end:   bool, // …and whether that key was the newest row when it was asked for: "to the end"
	reveal_tries: int,  // how many builds have refined it (bounded: see list_reveal_key)
	hold_ask:     Hold_Ask, // the `hold` command this list took (reveal_cmd.odin)
	hold_pend:    bool,     // …and whether it is still to be done, once there is a viewport to do it in
	hold_frac:    f32,      // how far into the row to hold, 0..1, for a by-spot hold; < 0 for px in hold_ask.point
	hold_idx:     int,      // …and which row, by index, for the same; < 0 to find hold_ask.key instead
	reveal_off:   f32,  // the offset the list itself last left (list_scroll_to); anything else there means someone scrolled, which ends a pending reveal
	at_sent:      List_At, // what on_at last reported
}

// List_At is where a list is resting, for an app that must act on it: a
// chat fetches older history as the reader nears the top, and shows a
// "jump to newest" button when they are not at the bottom.
//
// `first_key` is the key of the row the top of the viewport is on, so the
// app can remember the place across a restart.
List_At :: struct {
	first_key:  u64,
	at_end:     bool, // riding the newest row
	near_start: bool, // within a viewport of the oldest: time to fetch more
}

// Row_Key is a row's stable identity: given an index, the key the app builds
// that row with. The default, `u64(i + 1)`, is renumbered by a prepend and
// the heights would follow the wrong rows, so give one for any list whose
// rows can be prepended or removed (one that only appends needs none). It is
// called only during the build, for
// an index within that build's `count`, so `user` may point at the frame's
// temp memory. It must be a pure function of the app's rows: the list reuses
// the last build's answers between builds, so a key that changes its mind (a
// random id, a key folded in from selection or hover) misplaces the heights.
Row_Key :: proc(user: rawptr, index: int) -> u64

// Row_Height is a row's height for a list that knows it rather than
// measuring it (a page at the current zoom, a table of 32 and 64 px rows).
// Passed as `height_of`, it makes each row exactly this tall, so the offsets
// are exact on the first build and a reveal or hold lands at once. Like
// `Row_Key` it is asked only during the build, with `key_user`, so temp
// memory is fine; it is asked for every row when the offsets are redone and
// for the rows on screen every build, so it must be cheap arithmetic. Rows
// changing height together need nothing else said: the visible rows
// disagreeing with the offsets is how the list notices, and a row changed
// off screen is noticed when it comes back into range.
Row_Height :: proc(user: rawptr, index: int) -> f32

LIST_OVERSCAN :: 3
// How many builds a reveal refines itself over before settling for where it
// got to. See the comment at its use: chasing an exact landing in an
// estimated list does not converge.
@(private) LIST_REVEAL_TRIES :: 12
@(private) LIST_HEAD_KEY :: u64(0xF1F1_0000_0000_0001)
@(private) LIST_TAIL_KEY :: u64(0xF1F1_0000_0000_0002)

// list_node is the node of the `list` whose scope is open: what `scroll_by`,
// `scroll_to` and `scroll_offset` take, since `list` returns the row range
// rather than the node. A view that scrolls its own list asks for it between
// `list` and its `end`:
//
//	first, last := baldr.list(ui, len(s.blocks), estimated_height = 400)
//	s.body = baldr.list_node(ui)              // kept for the next Space
//	for i in first ..< last do row(ui, i, s)
//	baldr.end(ui)
//
// NODE_NONE when the open scope is not a list's, as after `end`. The node
// lives as long as the list does, so read it in the build that uses it
// rather than keeping it for ever.
list_node :: proc(ui: ^Ui($Msg)) -> Node {
	if len(ui.scopes) == 0 do return NODE_NONE
	sc := ui.scopes[len(ui.scopes) - 1]
	return sc.node if sc.list else NODE_NONE
}

list :: proc(ui: ^Ui($Msg), count: int, row_height: f32 = 0, estimated_height: f32 = 0,
	height_of: Row_Height = nil,
	key_of: Row_Key = nil, key_user: rawptr = nil, follow_end := false,
	on_at: Handler(Msg, List_At) = nil,
	gap: Space = Space_Token.none, padding: Space = Space_Token.none,
	flex: f32 = 1, height: f32 = 0, label: string = "", tail_pad: f32 = 0, on_range: Handler(Msg, [2]int) = nil,
	gutter := false, content_width: f32 = 0, key: u64 = 0, loc := #caller_location) -> (first, last: int) {
	// `follow_end` is the scroll's own: layout keeps the view on the end as
	// the content grows under it, which a list cannot do between builds. The
	// list still decides whether it rides the end, through
	// `Scroll_State.at_end`, which both read.
	n := scroll(ui, .Column, gap, padding, .Stretch, 0, height, flex, {}, follow_end = follow_end, gutter = gutter,
		content_width = content_width, key = key, loc = loc)
	t := &ui.tree
	d := node_get(t, n)
	d.access.role = .List
	set_name(t, n, label)
	ui.scopes[len(ui.scopes) - 1].list = true
	st := &ui.lists[n]
	if st == nil {
		ui.lists[n] = {range_sent = {-1, -1}}
		st = &ui.lists[n]
	}
	if st.count != max(count, 0) do st.tops_ok = false
	st.count = max(count, 0)
	// A new estimate is a new set of offsets: a zoom changes every row at
	// once (the estimate, and the keys where the app bumps a generation in
	// them), and a reveal against the old tops would land at the old scale.
	if st.estimate != max(estimated_height, 0) do st.tops_ok = false
	st.estimate = max(estimated_height, 0)
	st.height_of = height_of
	st.row_height = max(row_height, 1)
	st.tail_pad = max(tail_pad, 0)
	st.gap = space_px(&t.theme, gap)
	st.key_of, st.key_user = key_of, key_user
	list_rows_moved(st) // …a key or an exact height that is not what the offsets were built from
	if list_varies(st^) { // the offsets come from the rows' own heights, not one pitch
		// A by-spot hold is resolved here, before `list_tops`, against the
		// geometry this build is about to replace, because the offset it reads
		// is in those coordinates. A row and a fraction of it mean the same at
		// any scale, so the claim below can place it in the new geometry. The
		// row is an index, not a key: an app rescaling measured rows renames
		// every one on purpose, so an old key would match nothing, while index
		// 7 is the same page either side of a zoom. A build that also inserts
		// or removes rows is not covered.
		spot_idx:  int = -1
		spot_frac: f32
		spot_x:    f32
		if ask, waiting := hold_spot_waiting(ui, key); waiting {
			if sc := &t.scrolls[n]; sc != nil && sc.viewport.y > 0 {
				cy := sc.offset.y + ask.at.y
				idx := list_row_at(st^, cy)
				if idx >= 0 && idx < st.count {
					was := list_span(st^, idx) // the row's height as the reader sees it now
					spot_frac = clamp((cy - list_top(st^, idx)) / was, 0, 1) if was > 0 else 0
					spot_x, spot_idx = sc.offset.x + ask.at.x, idx
				}
			}
		}
		list_tops(st)
		// Rows arriving above or below must not move what the reader sees.
		// `follow_end` re-pins on every build while at the end, not only when
		// the count changed, because with estimates the content grows as rows
		// are measured. Following is sticky, not derived from the geometry:
		// measuring rows moves the content height by more than any sane
		// slack, and a row's worth of slack is more than a wheel notch, which
		// would pin a reader scrolling up back down. `Scroll_State` remembers
		// instead, re-answering "at the end?" only when something moves the
		// view (a clamp, or growth under a still view, leaves it alone), as
		// `scroll`'s own follow_end does.
		if !st.placed {
			st.following = follow_end // a chat opens on its newest message
		} else {
			st.following = list_rides_end(t, n)
		}
		st.at_end = st.following
		// Rows also grow after they were measured (a picture decoding, a
		// preview arriving), pushing everything below them down, so a change
		// of height re-anchors just as a change of count does.
		grew := abs(list_height(st^) - st.height_seen) > 0.01
		if st.count != st.count_seen || grew || (follow_end && st.following) {
			list_keep_place(t, n, st, follow_end)
		}
		st.count_seen = st.count
		st.placed = true
		// Bring a row into view once, a third of the way down rather than at
		// the top: a row with nothing above it reads as the start. The ask is
		// the `reveal_key` command (reveal_cmd.odin), taken here if it named
		// this list, so asking twice moves the view twice. It stays pending
		// until there is a viewport, or scroll_clamp would eat the jump.
		reveal_at := f32(0.33)
		if ask, taken := reveal_taken(ui, key, by_index = false); taken {
			reveal_at = ask.at
			st.reveal_pend, st.reveal_tries = ask.key, 0
			// "To the end" is decided when asked, because the end moves: rows
			// can arrive while the reveal refines over later builds, and the
			// row asked for is then no longer the last.
			st.reveal_end = st.count > 0 && ask.key == list_row_key(st^, st.count - 1)
		}
		// Re-placed for a few builds, not cleared on the first landing: that
		// lands on estimates, and the row slides as its neighbours are
		// measured. Bounded, because chasing it exactly does not converge —
		// the correction moves the window, which measures new rows, which
		// moves the target; "about a third down" is the contract. Anyone
		// else moving the view ends the reveal: the list knows the offset it
		// left (`list_scroll_to`), and putting the reader's own Space or
		// wheel notch back would undo it.
		if st.reveal_pend != 0 && st.reveal_tries > 0 {
			if sc := &t.scrolls[n]; sc != nil && sc.offset.y != st.reveal_off {
				st.reveal_pend, st.reveal_tries, st.reveal_end = 0, 0, false
			}
		}
		if st.reveal_pend != 0 {
			// Revealing the newest row is the reader coming back to the
			// bottom: pin to the end and follow again, so `at_end` is reported
			// at once rather than the row being placed a third down.
			newest := st.reveal_end || (st.count > 0 && st.reveal_pend == list_row_key(st^, st.count - 1))
			landed := false
			if newest {
				st.following, st.at_end = true, true
				list_keep_place(t, n, st, true)
				landed = true
			} else {
				landed = list_reveal_key(t, n, st, st.reveal_pend, reveal_at)
				st.following = false // being sent somewhere is not riding the newest row
			}
			st.reveal_tries += 1
			// Not cleared on landing: it re-places until LIST_REVEAL_TRIES,
			// by which time the rows around it are measured (see above).
			_ = landed
			if st.reveal_tries >= LIST_REVEAL_TRIES {
				st.reveal_pend, st.reveal_tries, st.reveal_end = 0, 0, false
			}
		}
		// Keep this point of this row at this spot of the viewport, once: a
		// zoom must leave the page under the pointer where it was. Applied
		// here, in the build that changed the scale and before the range is
		// chosen; afterwards it would move the view off the rows this build
		// built. The last explicit place wins, so a hold ends a reveal still
		// refining. It is a command (reveal_cmd.odin), not a parameter: an app
		// names the row it tracks on every build, and as a parameter that
		// would pin the view against the reader's scrolling.
		if ask, taken := hold_taken(ui, key); taken {
			if ask.by_spot {
				// Nothing under the spot — an empty list, or a first build
				// with no geometry yet — is nothing to hold: the ask is
				// spent rather than held against the wrong row.
				if spot_idx >= 0 {
					ask.point = {spot_x, 0}
					st.hold_frac, st.hold_idx = spot_frac, spot_idx
					st.hold_ask, st.hold_pend = ask, true
				}
			} else if ask.key != 0 {
				st.hold_frac, st.hold_idx = -1, -1 // the app gave a key and px into the row
				st.hold_ask, st.hold_pend = ask, true
			}
		}
		if st.hold_pend && list_hold_row(t, n, st, st.hold_ask, st.hold_frac, st.hold_idx) {
			st.hold_pend = false
			st.reveal_pend, st.reveal_tries, st.reveal_end = 0, 0, false
			st.following = false // being held somewhere is not riding the newest row
		}
	} else {
		pitch := st.row_height + st.gap
		if st.pitch_seen > 0 && pitch != st.pitch_seen do list_reanchor(t, n, st.pitch_seen, pitch) // a zoom keeps the same row at the top
		st.pitch_seen = pitch
	}
	st.first, st.last = list_range(t, n, st^)
	first, last = st.first, st.last
	if list_varies(st^) && st.key_of != nil { // see built_keys: the tick must not ask the app
		resize(&st.built_keys, max(st.last - st.first, 0))
		for i in st.first ..< st.last do st.built_keys[i - st.first] = st.key_of(st.key_user, i)
	}
	if handler_live(on_at) && list_varies(st^) {
		at := list_at(t, n, st^)
		if at != st.at_sent {
			st.at_sent = at
			handler_send(ui, on_at, at, n)
		}
	}
	if handler_live(on_range) && st.range_sent != {first, last} { // the rows on screen (and the overscan) changed: the app may load them
		st.range_sent = {first, last}
		handler_send(ui, on_range, [2]int{first, last}, n)
	}
	head := list_top(st^, first) - (st.gap if first > 0 else 0)
	h, _ := reconcile_child(ui, .Box, LIST_HEAD_KEY, loc)
	set_layout(t, h, Layout_Props{height = max(head, 0)})
	set_hidden(t, h, head <= 0)
	return
}


// ------------------------------------------------- variable-height rows
//
// A row's height is only known once it has been laid out, but the range to
// build is decided while the view is being built — before this frame's
// layout. So the list works from the heights it measured *last* frame and
// converges: a row appears at the estimate, is measured, and the next build
// places it exactly. That is how every variable-height virtual list works,
// and it is why `estimated_height` should be near the common case — a bad
// estimate costs a visible settle, not correctness.

// list_varies is whether the rows have heights of their own — measured from
// an `estimated_height`, or given exactly by `height_of` — rather than one
// `row_height` the whole list scrolls by.
@(private)
list_varies :: proc(st: List_State) -> bool {
	return st.estimate > 0 || st.height_of != nil
}

// list_row_height is row `i`'s height: the app's own number where it gave
// `height_of`, else what was measured for its key, else the estimate. Only
// during a build, because both callbacks are.
@(private)
list_row_height :: proc(st: List_State, i: int) -> f32 {
	if st.height_of != nil do return max(st.height_of(st.key_user, i), 0)
	h, known := st.heights[list_row_key(st, i)]
	return h if known else st.estimate
}

// list_span is the height row `i` was given in the offsets as they stand —
// the gap after it taken off, except for the last row, which has none.
@(private)
list_span :: proc(st: List_State, i: int) -> f32 {
	if i < 0 || i + 1 >= len(st.tops) do return 0
	h := st.tops[i + 1] - st.tops[i]
	if i < st.count - 1 do h -= st.gap
	return h
}

// list_rows_moved clears `tops_ok` when the heights it was worked out from
// no longer hold though the count did not change, as after a zoom. It checks
// only the rows the last build built — where a visible change shows first,
// for a handful of calls rather than one per row — for either sign:
//
//   - `height_of` answers a different number than the offsets gave a row;
//   - `key_of` answers a different key, which an app bumping a generation
//     into its keys at each zoom means on purpose.
//
// A row changed off screen is noticed when it comes back into range, which
// costs the offsets below the viewport, never what is in it.
@(private)
list_rows_moved :: proc(st: ^List_State) {
	if !st.tops_ok || len(st.tops) != st.count + 1 do return
	lo := clamp(st.first, 0, st.count)
	hi := clamp(st.last, lo, st.count)
	if st.height_of != nil {
		for i in lo ..< hi do if abs(list_row_height(st^, i) - list_span(st^, i)) > 0.01 {
			st.tops_ok = false
			return
		}
		return
	}
	if st.key_of == nil do return // arithmetic keys cannot change under us
	moved := false
	for i in lo ..< hi {
		was, named := list_key_noted(st^, i)
		if named && st.key_of(st.key_user, i) != was {
			moved = true
			break
		}
	}
	if !moved do return
	st.tops_ok = false
	// The heights of keys nobody will ask for again are dead weight, and an
	// app that bumps a generation at every zoom leaves `count` of them
	// behind each time. Thrown away only once they outnumber the rows
	// several times over, so the ordinary life of the map — a row scrolled
	// away and coming back, a message deleted — costs nothing.
	if len(st.heights) > 2 * st.count + 64 do clear(&st.heights)
}

// list_tops rebuilds the running offsets: tops[i] is row i's y, and
// tops[count] is the whole content height. A row never measured stands at
// `estimate`.
//
// O(count), but only when something changed — a height newly measured, a
// row added or removed. Scrolling alone does not touch it.
@(private)
list_tops :: proc(st: ^List_State) {
	if st.tops_ok && len(st.tops) == st.count + 1 do return
	resize(&st.tops, st.count + 1)
	y: f32
	for i in 0 ..< st.count {
		st.tops[i] = y
		y += list_row_height(st^, i) + st.gap
	}
	if st.count > 0 do y -= st.gap // no gap after the last row
	st.tops[st.count] = max(y, 0)
	st.tops_ok = true
}

// list_key_noted is list_row_key for code running between builds, where
// calling `key_of` is not allowed: an app may answer it out of the build's
// temp memory, which is gone once the build is over. It answers from
// `built_keys`, so it names only the rows on screen and their overscan —
// enough for the anchor. `false` means "not from the last build": the caller
// leaves what it has, and the rebuild a jump that large asks for fixes it a
// frame later.
@(private)
list_key_noted :: proc(st: List_State, i: int) -> (key: u64, ok: bool) {
	if i < 0 || i >= st.count do return 0, false
	if st.key_of == nil do return u64(i + 1), true // the default is arithmetic: no app to ask
	if i < st.first || i - st.first >= len(st.built_keys) do return 0, false
	return st.built_keys[i - st.first], true
}

// list_row_key is the key row `i` is built with: the app's own where it gave
// a `key_of`, else the index-derived default the widget's contract asks for.
// Only during a build; between builds use list_key_noted.
@(private)
list_row_key :: proc(st: List_State, i: int) -> u64 {
	if st.key_of != nil do return st.key_of(st.key_user, i)
	return u64(i + 1)
}

// list_top is row `i`'s y: from the measured offsets in variable mode, from
// the fixed pitch otherwise.
@(private)
list_top :: proc(st: List_State, i: int) -> f32 {
	if !list_varies(st) do return f32(i) * (st.row_height + st.gap)
	if len(st.tops) == 0 do return 0
	return st.tops[clamp(i, 0, len(st.tops) - 1)]
}

// list_height is the whole content's.
@(private)
list_height :: proc(st: List_State) -> f32 {
	if !list_varies(st) {
		pitch := st.row_height + st.gap
		return max(f32(st.count) * pitch - (st.gap if st.count > 0 else 0), 0)
	}
	return list_top(st, st.count)
}

// list_row_at is the first row whose bottom is past `y` — a binary search
// over the offsets: fifteen comparisons for 20,000 rows.
@(private)
list_row_at :: proc(st: List_State, y: f32) -> int {
	if !list_varies(st) {
		pitch := st.row_height + st.gap
		return clamp(int(y / max(pitch, 1)), 0, st.count)
	}
	lo, hi := 0, st.count
	for lo < hi {
		mid := (lo + hi) / 2
		if list_top(st, mid + 1) <= y { lo = mid + 1 } else { hi = mid }
	}
	return clamp(lo, 0, st.count)
}

// list_measure_rows reads what the last layout made each built row, and
// keeps it by key. A row built for the first time has no size yet, so it is
// left unmeasured and stands at the estimate until the next build.
@(private)
list_measure_rows :: proc(t: ^Tree, n: Node, st: ^List_State) {
	if st.height_of != nil do return // the app's numbers: there is nothing to measure
	changed := false
	for c := node_first(t, n); c != NODE_NONE; c = node_next(t, c) {
		d := node_get(t, c)
		if d == nil || d.key == LIST_HEAD_KEY || d.key == LIST_TAIL_KEY do continue
		if d.key == 0 || d.rect.h <= 0 do continue
		if was, had := st.heights[d.key]; !had || abs(was - d.rect.h) > 0.01 {
			st.heights[d.key] = d.rect.h
			changed = true
		}
	}
	if changed do st.tops_ok = false
}

// list_keep_place puts the scroll back where it was after rows arrived, left
// or grew, so rows paged in above do not move what the reader sees. It works
// from the key the viewport's top rested on and how far into that row, both
// recorded by list_note_place. With `follow_end`, a view that was against the
// bottom goes back against the bottom instead.
@(private)
list_keep_place :: proc(t: ^Tree, n: Node, st: ^List_State, follow_end: bool) {
	sc := &t.scrolls[n]
	if sc == nil do return
	if follow_end && st.at_end {
		// The clamp must see the height that is coming, not the one the last
		// layout left — the same trick list_reanchor uses — and then the
		// bottom is simply the furthest the scroll can go.
		sc.content.y = max(sc.content.y, list_height(st^))
		list_scroll_to(t, n, st, {sc.offset.x, list_max_off(sc^)})
		return
	}
	if st.anchor_key == 0 do return
	// where that row is now: its key has not changed, only its index
	at := -1
	for i in 0 ..< st.count do if list_row_key(st^, i) == st.anchor_key {
		at = i
		break
	}
	if at < 0 do return // the row it was resting on is gone; leave the scroll alone
	list_scroll_to(t, n, st, {sc.offset.x, max(list_top(st^, at) + st.anchor_delta, 0)})
}

// list_at_end says whether the view is against the bottom now, from the live
// offset and the content the last layout measured. Ask it afresh each build:
// the reader may have scrolled away, and a stale `true` would drag them back.
// The slack is SCROLL_END_EPS, the fractional pixel a layout can leave, as
// `scroll`'s follow_end allows — not a row's height, which can exceed a wheel
// notch and would pin a reader who scrolled up back down. A converging list
// is covered by the sticky answer in list_rides_end.
@(private)
list_at_end :: proc(t: ^Tree, n: Node) -> bool {
	sc := &t.scrolls[n]
	if sc == nil || sc.viewport.y <= 0 do return false
	return sc.offset.y >= list_max_off(sc^) - SCROLL_END_EPS
}

// list_rides_end is whether the list is on its newest row — what `follow_end`
// follows and `List_At.at_end` reports.
//
// Either of two answers is enough. `Scroll_State.at_end` is where the last
// move of the view left it, remembered since, so it survives the content
// growing underneath and the clamp pulling the view down, neither of which
// is the reader going anywhere. Being against the bottom now covers a list
// too short to scroll, where nothing has ever moved.
@(private)
list_rides_end :: proc(t: ^Tree, n: Node) -> bool {
	sc := &t.scrolls[n]
	if sc == nil do return false
	return sc.at_end || list_at_end(t, n)
}

// list_max_off is the furthest the scroll can go: the scroll's own
// `content - viewport`, as scroll_clamp uses. Not modelled from the list's
// heights and the node's rect, which lag a frame behind layout: "at the
// bottom" would answer no while the view sat there, and a pin would aim
// somewhere the clamp refuses.
@(private)
list_max_off :: proc(sc: Scroll_State) -> f32 {
	return max(sc.content.y - sc.viewport.y, 0)
}

// list_note_place records what the viewport rests on, for the next build's
// list_keep_place. It runs from the tick as well as the build, so it names
// the row through list_key_noted and never asks the app; within a build the
// row under the top is always in the built range. A row it cannot name means
// the reader scrolled clear of the built range, which asks for a rebuild, so
// the anchor is left alone and re-taken a frame later rather than replaced
// with a guess.
@(private)
list_note_place :: proc(t: ^Tree, n: Node, st: ^List_State) {
	d := node_get(t, n)
	if d == nil do return
	off := scroll_offset(t, n).y
	top := list_row_at(st^, off)
	if st.count == 0 {
		st.anchor_key, st.anchor_delta, st.note_off = 0, 0, off
		return
	}
	key, ok := list_key_noted(st^, top)
	if !ok do return
	st.anchor_key = key
	st.anchor_delta = off - list_top(st^, top)
	st.note_off = off
}

// list_at is where the list is resting now, for `on_at`.
@(private)
list_at :: proc(t: ^Tree, n: Node, st: List_State) -> List_At {
	sc := &t.scrolls[n]
	if sc == nil do return {}
	top := list_row_at(st, sc.offset.y)
	return {
		first_key  = list_row_key(st, top) if top < st.count else 0,
		at_end     = st.following,
		// within a viewport of the oldest row: far enough ahead that the
		// fetch lands before the reader arrives
		near_start = sc.offset.y <= sc.viewport.y,
	}
}

// list_reveal_key brings the row with `key` into view, `at` of the way down
// the viewport (0 the top, 0.33 a third down). Nothing happens if no row has
// that key — an app may ask for one that has not loaded yet.
@(private)
list_reveal_key :: proc(t: ^Tree, n: Node, st: ^List_State, key: u64, at: f32) -> (done: bool) {
	sc := &t.scrolls[n]
	if sc == nil || sc.viewport.y <= 0 do return false // nothing to place it in yet
	idx := -1
	for i in 0 ..< st.count do if list_row_key(st^, i) == key {
		idx = i
		break
	}
	if idx < 0 do return false // no row has that key: the app may ask for one not loaded yet
	sc.content.y = max(sc.content.y, list_height(st^)) // the clamp must see the coming height
	into := sc.viewport.y * clamp(at, 0, 1)
	list_scroll_to(t, n, st, {sc.offset.x, max(list_top(st^, idx) - into, 0)})
	// Done only when it landed: a row far from the window is placed from the
	// estimates above it and slides as those are measured, so this keeps
	// asking until it is where it was asked to be, or as close as the top of
	// the list allows.
	got := list_top(st^, idx) - scroll_offset(t, n).y
	return abs(got - into) < 2 || scroll_offset(t, n).y <= 0
}

// list_hold_row puts `point` (px into the row with `key`) at `at` (px into
// the viewport), which is what a zoom asks for: the place the reader was
// looking at must not move while every row around it changes size.
//
// Exact where the list was given `height_of` — the offsets are the app's own
// arithmetic, so this lands in the same build as the new scale. With
// estimates it is out by the error in the estimates of the rows above, and
// the app asks again on the next build, by which time those are measured.
//
// False means there was nothing to place it in yet (no viewport) or no row
// has that key, and the ask stays pending.
@(private)
list_hold_row :: proc(t: ^Tree, n: Node, st: ^List_State, ask: Hold_Ask, frac: f32, row := -1) -> (done: bool) {
	sc := &t.scrolls[n]
	if sc == nil || sc.viewport.y <= 0 do return false
	idx := row // a by-spot hold resolved the row itself, by index: see the claim
	if idx < 0 {
		for i in 0 ..< st.count do if list_row_key(st^, i) == ask.key {
			idx = i
			break
		}
	}
	if idx < 0 || idx >= st.count do return false // the app may hold a row that has not loaded yet
	sc.content.y = max(sc.content.y, list_height(st^)) // the clamp must see the coming height
	// A fraction of the row is a point at any scale: a by-spot hold carries
	// one so that neither the app nor this has to know what the scale was.
	// A hold the app wrote by hand gives px and says so with a negative one.
	into := ask.point.y
	if frac >= 0 do into = frac * list_span(st^, idx)
	want := [2]f32{
		max(ask.point.x - ask.at.x, 0),
		max(list_top(st^, idx) + into - ask.at.y, 0),
	}
	// Only the axes it asked for: a document zoomed by its page holds the
	// vertical and leaves scrolling across the page to the reader.
	axes := hold_axes_of(ask)
	if .X not_in axes do want.x = sc.offset.x
	if .Y not_in axes do want.y = sc.offset.y
	list_scroll_to(t, n, st, want)
	return true
}

// list_built_index is which row a child of this build is, from its
// reconciliation key: the app's own keys where it gave `key_of` (the build
// kept them in `built_keys`), the arithmetic default otherwise, and its
// place among the rows when the key says nothing — a row built without one,
// which list_unkeyed_row has already complained about.
@(private)
list_built_index :: proc(st: List_State, key: u64, ord: int) -> (i: int, ok: bool) {
	if key != 0 {
		if st.key_of == nil {
			if key <= u64(st.count) do return int(key) - 1, true
		} else {
			for k, j in st.built_keys do if k == key do return st.first + j, true
		}
	}
	i = st.first + ord
	return i, i >= 0 && i < st.count
}

// list_scroll_to moves this list's own view and notes where it left it, so
// the next build can tell the list's own placing from a scroll by the reader
// or the app. Everything else — a wheel, a drag of the bar, a Page key, an
// app's `scroll_by` — goes through the public scroll procs and leaves the
// offset somewhere this did not put it, which is the signal a pending reveal
// needs to stop.
@(private)
list_scroll_to :: proc(t: ^Tree, n: Node, st: ^List_State, off: [2]f32) -> bool {
	moved := scroll_to(t, n, off)
	if sc := &t.scrolls[n]; sc != nil do st.reveal_off = sc.offset.y
	return moved
}

// list_reanchor scales the scroll offset with a row pitch change so the
// row at the top stays the row at the top (rows do not jump when a table
// or icon view zooms).
@(private)
list_reanchor :: proc(t: ^Tree, n: Node, old_pitch, new_pitch: f32) {
	sc := &t.scrolls[n]
	if sc == nil || sc.offset.y <= 0 || old_pitch <= 0 do return
	k := new_pitch / old_pitch
	sc.content.y *= k // the clamp must see the coming content height, not the last layout's
	scroll_to(t, n, {sc.offset.x, sc.offset.y * k})
}

// list_range computes the rows to build from the container's scroll offset
// and viewport height (the window height on the first build).
@(private)
list_range :: proc(t: ^Tree, n: Node, st: List_State) -> (first, last: int) {
	d := node_get(t, n)
	vh := d.rect.h - d.layout.padding[0] - d.layout.padding[2]
	if vh <= 0 do vh = max(t.viewport.y, 1)
	off := scroll_offset(t, n).y
	first = clamp(list_row_at(st, off) - LIST_OVERSCAN, 0, st.count)
	last = clamp(list_row_at(st, off + vh) + 1 + LIST_OVERSCAN, first, st.count)
	return
}

@(private)
list_tail :: proc(ui: ^Ui($Msg), n: Node, loc: runtime.Source_Code_Location) {
	t := &ui.tree
	stp := &ui.lists[n]
	if stp == nil do return
	if list_varies(stp^) {
		// Both are taken before measuring, in the coordinate space the scroll
		// offset is in: this build's spacers were placed from these tops.
		// Taken after, the anchor would be read from the new tops at the old
		// offset and absorb the shift, and `height_seen` could never show a
		// row that grew.
		list_note_place(&ui.tree, n, stp) // what the viewport is resting on…
		stp.height_seen = list_height(stp^) // …and the height that place is in terms of
		list_measure_rows(&ui.tree, n, stp) // then: what the last layout made each row
		list_tops(stp)
	}
	st := stp^
	rest := st.count - st.last
	tail := list_height(st) - list_top(st, st.last) - (st.gap if rest > 0 else 0) + st.tail_pad
	tl, _ := reconcile_child(ui, .Box, LIST_TAIL_KEY, loc)
	set_layout(t, tl, Layout_Props{height = max(tail, 0)})
	set_hidden(t, tl, tail <= 0)
	// Every row clips its content, and its height is pinned wherever the list
	// rather than the row decides it (`row_height`, `height_of`).
	ord := 0
	for c := node_first(t, n); c != NODE_NONE; c = node_next(t, c) {
		d := node_get(t, c)
		if d == nil || d.key == LIST_HEAD_KEY || d.key == LIST_TAIL_KEY do continue
		// A fixed-height list pins every row to the pitch it scrolls by, so
		// a row whose content grew cannot paint into its neighbour. A
		// variable one must not: the row says how tall it is, and the list
		// measures it.
		if !list_varies(st) && d.layout.height != st.row_height {
			d.layout.height = st.row_height
			mark_layout_dirty(t, c)
		}
		// A list told its heights pins them too: the spacers, the reveal and
		// the hold are worked out from those numbers, so a row laid out at
		// another height would misplace everything below it.
		if st.height_of != nil {
			if i, ok := list_built_index(st, d.key, ord); ok {
				h := list_row_height(st, i)
				if abs(d.layout.height - h) > 0.01 {
					d.layout.height = h
					mark_layout_dirty(t, c)
				}
			}
			ord += 1
		}
		if .Clips not_in d.flags {
			d.flags += {.Clips}
			mark_paint_dirty(t, c)
		}
	}
	table_label_cells(ui, n) // a table's cell controls take their column header as their name
}

// list_state_destroy frees what a list's state owns (its measured heights
// and running offsets).
@(private)
list_state_destroy :: proc(st: ^List_State) {
	delete(st.heights)
	delete(st.tops)
	delete(st.built_keys)
	st^ = {}
}

// list_tick asks for a rebuild when scrolling moved a list's visible range,
// or changed whether the list rides its newest row. The second is decided in
// the build, so a scroll that arrives at the bottom without changing the rows
// on screen (a flick's last pixels) would otherwise leave the list not
// following. While a reveal refines, the list rebuilds every frame anyway.
@(private)
list_tick :: proc(ui: ^Ui($Msg)) {
	t := &ui.tree
	for n, st in ui.lists {
		if !node_valid(t, n) do continue
		// Re-take the anchor when the offset moved since the build: a stale
		// one would undo the reader's scrolling when a row above grows. The
		// tops do not change between builds, so this costs a binary search.
		if stp := &ui.lists[n]; stp != nil && list_varies(stp^) && stp.placed {
			if abs(scroll_offset(t, n).y - stp.note_off) > 0.01 do list_note_place(t, n, stp)
		}
		first, last := list_range(t, n, st)
		if first != st.first || last != st.last {
			ask_rebuild(ui)
			return
		}
		if list_varies(st) && st.reveal_pend == 0 && st.following != list_rides_end(t, n) {
			ask_rebuild(ui)
			return
		}
	}
}

@(private)
list_unkeyed_row :: proc(ui: ^Ui($Msg), n: Node, loc: runtime.Source_Code_Location) {
	st := &ui.lists[n]
	if st == nil || st.warned do return
	st.warned = true
	diag(&ui.tree, loc, "rows of a list must be keyed by index (key = u64(i + 1)); an unkeyed row is matched by position and keeps another row's state when the list scrolls")
}
