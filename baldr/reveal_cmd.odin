package baldr

// Bringing a row into view, as a command.
//
// A list is rebuilt every time anything changes, so "scroll to this row"
// cannot be a value the view passes in: it would scroll there again on
// every build. It is a command instead, the shape `focus` uses: the ask
// happens once, where the app decided it, and asking for the same row twice
// is calling it twice. The ask is kept for a few builds, because the command
// usually causes the screen holding the list to be built; one no view takes
// in that time is dropped, so a key that never appears cannot be claimed
// later by an unrelated screen.
//
// `update` returns a command (`reveal_key`, `reveal_index`, `hold`,
// `hold_at`); a view that learns the row while building asks directly
// (`reveal_now` and its three peers). Either way it is the same ask,
// claimed by the same views, and a window holds a set of them, so two asks
// in one update are two asks.

// Reveal_Ask is what a reveal command carries. Built by `reveal_key` and
// `reveal_index` rather than by hand.
Reveal_Ask :: struct {
	view:     u64,        // the list, table or icon view's own reconciliation key
	key:      u64,        // a `list` row, by the key `key_of` gives it
	index:    int,        // a `table` or `icon_view` row, by position
	at:       f32,        // where in the viewport it lands, 0..1 from the top
	by_index: bool,       // which of the two above names the row
	surface:  Maybe(u64), // which window's view, by its surface tag; nil is whichever has it
	internal: bool,       // the toolkit asking one of its own views (reveal_own)
	in_build: bool,       // asked from inside a build (reveal_now), so a build is owed to it
	tries:    int,        // builds this ask has waited for a view to take it
}

// REVEAL_WAIT_BUILDS is how many builds an unclaimed ask survives, as
// FOCUS_WAIT_BUILDS is for the keyboard. A list that takes several builds
// to land on the row does its own retrying (`LIST_REVEAL_TRIES`); this is
// only about the list existing at all.
@(private) REVEAL_WAIT_BUILDS :: 3

// reveal_key brings a `list` row into view, the row named by the key
// `key_of` gives it. `view` is the list's own `key`, which is how this finds
// it among the surfaces; it need only be unique among the app's own views
// (the lists the toolkit builds inside `table`, `icon_view` and the emoji
// picker are kept apart), and a multi-window app can name the window with
// `surface`. `at` is where in the viewport the row lands, a third of the way
// down by default: a message against the very top reads as the start of a
// conversation when it is not. Revealing the last row pins the list to the bottom and
// resumes following, so it reports `at_end` straight away.
//
//	LOG :: u64(0x109)
//	baldr.list(ui, len(s.rows), key_of = msg_key, key = LOG)   // in the view
//	return baldr.reveal_key(Msg, LOG, msg_key(nil, len(s.rows) - 1))  // in update
reveal_key :: proc($Msg: typeid, view: u64, row: u64, at: f32 = 0.33, surface: Maybe(u64) = nil) -> Cmd(Msg) {
	return {kind = .Reveal, reveal = {view = view, key = row, at = at, surface = surface}}
}

// reveal_index brings a `table` or `icon_view` row into view — those name
// a row by its position, which is what they are given to build. Otherwise
// exactly `reveal_key`.
reveal_index :: proc($Msg: typeid, view: u64, row: int, at: f32 = 0.33, surface: Maybe(u64) = nil) -> Cmd(Msg) {
	return {kind = .Reveal, reveal = {view = view, index = row, at = at, by_index = true, surface = surface}}
}

// reveal_own is how a widget inside the toolkit asks one of its own views to
// show a row (the emoji picker scrolling to the group its tab names). It is
// marked `internal`, so only a view the toolkit itself builds can take it
// (see `view_inner` below), which keeps it out of an app's key space.
// `reveal_now` is the app's door; the run loop, and a test asking as an app,
// pass the raw `Reveal_Ask` or `Hold_Ask` to `reveal_put` / `hold_put`.
@(private)
reveal_own :: proc(ui: ^Ui($Msg), view: u64, row: u64, at: f32 = 0.33) {
	reveal_put(ui, Reveal_Ask{view = view, key = row, at = at, internal = true, in_build = true})
}

// ------------------------------------------------- asking from inside a view
//
// Some rows are only known once the view has built them: a book's chapter,
// whose row comes out of typesetting in the view. Returning a command
// instead costs a message, and a frame can show the old offset before the
// reveal lands. These take the same arguments as the commands, in the same
// order, without the `$Msg`.
//
// Order inside the build does not matter. Called before the list, the ask
// is claimed by that same build. Called after it, the ask waits and the
// view is asked to run again, so it lands in the next layout rather than
// whenever something else rebuilds. That is what `in_build` marks: an ask
// the app cannot re-make for itself, because a build made it.

// reveal_now brings a row into view, asked from inside the build that knows
// which row it is. Otherwise exactly `reveal_key`.
//
//	// in the view, right after typesetting said which row the chapter is
//	baldr.reveal_now(ui, READ_LIST, row, at = 0)
reveal_now :: proc(ui: ^Ui($Msg), view: u64, row: u64, at: f32 = 0.33, surface: Maybe(u64) = nil) {
	if !ask_for_surface(surface, ui.surface.tag) do return
	reveal_put(ui, Reveal_Ask{view = view, key = row, at = at, surface = surface, in_build = true})
}

// reveal_now_index is reveal_now for a `table` or an `icon_view`, which name
// a row by its position. Otherwise exactly `reveal_index`.
reveal_now_index :: proc(ui: ^Ui($Msg), view: u64, row: int, at: f32 = 0.33, surface: Maybe(u64) = nil) {
	if !ask_for_surface(surface, ui.surface.tag) do return
	reveal_put(ui, Reveal_Ask{view = view, index = row, at = at, by_index = true, surface = surface, in_build = true})
}

// hold_now keeps a point of a row still, asked from inside the build.
// Otherwise exactly `hold`, with the same rules as `reveal_now`.
hold_now :: proc(ui: ^Ui($Msg), view: u64, row: u64, point: [2]f32, at: [2]f32,
	axes: Hold_Axes = {.X, .Y}, surface: Maybe(u64) = nil) {
	if !ask_for_surface(surface, ui.surface.tag) do return
	hold_put(ui, Hold_Ask{view = view, key = row, point = point, at = at, axes = axes, surface = surface, in_build = true})
}

// hold_now_at is `hold_at` asked from inside the build.
hold_now_at :: proc(ui: ^Ui($Msg), view: u64, at: [2]f32,
	axes: Hold_Axes = {.X, .Y}, surface: Maybe(u64) = nil) {
	if !ask_for_surface(surface, ui.surface.tag) do return
	hold_put(ui, Hold_Ask{view = view, at = at, axes = axes, by_spot = true, surface = surface, in_build = true})
}

// Hold_Axis is an axis a hold keeps still. A hold that names only `.Y`
// leaves the horizontal offset exactly where the reader left it — which is
// what a document zoomed by its page wants, since the page's width is the
// app's business and the view's scroll across it is the reader's.
Hold_Axis :: enum u8 { X, Y }
Hold_Axes :: bit_set[Hold_Axis; u8]

// Hold_Ask is what a hold command carries: put this point of that row at
// this spot in the viewport, once, in the build that changed the scale.
// `axes` says which offsets it may move; an empty set means both, so the
// zero value moves both.
Hold_Ask :: struct {
	view:     u64,        // the list's own reconciliation key
	key:      u64,        // the row, by the key `key_of` gives it — 0 with by_spot
	point:    [2]f32,     // px into that row
	at:       [2]f32,     // px into the viewport
	axes:     Hold_Axes,  // which offsets it may move; {} is both
	by_spot:  bool,       // no row named: keep whatever the list has at `at` now
	surface:  Maybe(u64), // which window's list, by its surface tag; nil is whichever has it
	internal: bool,       // the toolkit asking one of its own lists
	in_build: bool,       // asked from inside a build (hold_now), so a build is owed to it
	tries:    int,        // builds this ask has waited
}

// hold_axes_of reads an ask's axes, where the zero value means both.
@(private)
hold_axes_of :: proc(ask: Hold_Ask) -> Hold_Axes {
	return {.X, .Y} if ask.axes == {} else ask.axes
}

// hold keeps a point still while everything around it changes size: the
// page under the pointer, or the middle of the view, must not move while a
// document zooms. Return it from `update` with the zoom that needs it, so it
// applies in the build that changed the scale, before the range is chosen,
// and no frame is built from the old offsets. `point` is px into the row and
// `at` px into the viewport. It is a command rather than a parameter because
// an app names the row it tracks on every build, so naming cannot be the ask.
hold :: proc($Msg: typeid, view: u64, row: u64, point: [2]f32, at: [2]f32,
	axes: Hold_Axes = {.X, .Y}, surface: Maybe(u64) = nil) -> Cmd(Msg) {
	return {kind = .Hold, hold = {view = view, key = row, point = point, at = at, axes = axes, surface = surface}}
}

// hold_at keeps whatever is at that spot of the viewport where it is,
// naming no row: the list works out which row is there and how far into it
// from the offset it is actually on when the ask is claimed. Prefer it to
// `hold` wherever the app knows the position only from the last build: a
// list does not rebuild for a scroll that keeps the same rows on screen, so
// an app's own note of the position can be behind, and the list's never is.
// What is kept is a fraction of the row, not pixels, so the app has nothing
// to scale.
//
//	// in update, in the same breath as the zoom
//	return baldr.hold_at(Msg, PAGES, at = {0, s.pointer.y}, axes = {.Y})
hold_at :: proc($Msg: typeid, view: u64, at: [2]f32,
	axes: Hold_Axes = {.X, .Y}, surface: Maybe(u64) = nil) -> Cmd(Msg) {
	return {kind = .Hold, hold = {view = view, at = at, axes = axes, by_spot = true, surface = surface}}
}

// ------------------------------------------------- several asks at a time
//
// A window holds a set of asks, each claimed by the view it names, so two
// commands from one `update` for different views both land. Asking twice
// for the same view means the later one wins ("row 4, no, row 9"): `*_put`
// replaces an ask with the same addressee rather than appending beside it.

// ask_for_surface is whether an ask addressed at one window is for this one.
// A nil `surface` is every window, which is what a one-window app wants.
@(private)
ask_for_surface :: proc(want: Maybe(u64), tag: u64) -> bool {
	t, named := want.?
	return !named || t == tag
}

// reveal_put adds an ask, replacing any still waiting for the same view.
@(private)
reveal_put :: proc(ui: ^Ui($Msg), ask: Reveal_Ask) {
	for &a in ui.reveal_asks {
		if a.view == ask.view && a.internal == ask.internal {
			a = ask
			return
		}
	}
	append(&ui.reveal_asks, ask)
}

// hold_put is reveal_put for a hold.
@(private)
hold_put :: proc(ui: ^Ui($Msg), ask: Hold_Ask) {
	for &a in ui.hold_asks {
		if a.view == ask.view && a.internal == ask.internal {
			a = ask
			return
		}
	}
	append(&ui.hold_asks, ask)
}

// ------------------------------------------------- whose ask is it, anyway
//
// A widget's own view is not in the app's key space. `table` and
// `icon_view` each build an inner `list(key = 1)`, and the emoji picker's
// grid is `list(key = 4)`, so a key alone cannot tell an app's list from
// one of those. The ask says which it is (`internal`, set only by
// `reveal_own`) and the claim side knows whether it is building one of its
// own (`ui.view_inner`, raised around those three calls), so an app's ask
// reaches an app's view and a widget's the widget's, whatever numbers
// either chose.

// view_inner_begin / view_inner_end bracket a view the toolkit builds for
// itself, so the claim below can tell it from one the app asked for.
@(private) view_inner_begin :: proc(ui: ^Ui($Msg)) { ui.view_inner += 1 }
@(private) view_inner_end   :: proc(ui: ^Ui($Msg)) { ui.view_inner -= 1 }

// hold_spot_waiting *looks* for a by-spot hold meant for this list without
// taking it. A list has to read the geometry the build is about to replace
// before it replaces it — which is the whole point of a by-spot hold — and
// that happens before the claim below.
@(private)
hold_spot_waiting :: proc(ui: ^Ui($Msg), key: u64) -> (ask: Hold_Ask, waiting: bool) {
	inner := ui.view_inner > 0
	for a in ui.hold_asks {
		if a.view != key || a.view == 0 || !a.by_spot do continue
		if a.internal != inner do continue
		return a, true
	}
	return {}, false
}

// hold_taken is a list asking whether a hold was meant for it.
@(private)
hold_taken :: proc(ui: ^Ui($Msg), key: u64) -> (ask: Hold_Ask, taken: bool) {
	inner := ui.view_inner > 0
	for a, i in ui.hold_asks {
		if a.view != key || a.view == 0 do continue
		if a.internal != inner do continue
		ask = a
		ordered_remove(&ui.hold_asks, i) // first asked, first served
		return ask, true
	}
	return {}, false
}

// hold_sweep drops an ask no list claimed, as reveal_sweep does.
@(private)
hold_sweep :: proc(ui: ^Ui($Msg)) {
	owed := false
	for i := len(ui.hold_asks) - 1; i >= 0; i -= 1 {
		ui.hold_asks[i].tries += 1
		if ui.hold_asks[i].tries >= REVEAL_WAIT_BUILDS {
			ordered_remove(&ui.hold_asks, i)
		} else if ui.hold_asks[i].in_build {
			owed = true
		}
	}
	if owed do ask_rebuild(ui)
}

// reveal_taken is a view asking "was this ask meant for me?", and taking
// it if so. Called by `list`, `table` and `icon_view` while they build.
@(private)
reveal_taken :: proc(ui: ^Ui($Msg), key: u64, by_index: bool) -> (ask: Reveal_Ask, taken: bool) {
	inner := ui.view_inner > 0
	for a, i in ui.reveal_asks {
		if a.view != key || a.view == 0 do continue
		if a.by_index != by_index do continue // a list asked by index, or the other way round
		if a.internal != inner do continue
		ask = a
		ordered_remove(&ui.reveal_asks, i)
		return ask, true
	}
	return {}, false
}

// reveal_sweep drops an ask no view claimed, a few builds on. Called from
// end_view beside focus_sweep.
@(private)
reveal_sweep :: proc(ui: ^Ui($Msg)) {
	// A build is owed to an ask made inside one (`reveal_now`): the app
	// cannot ask again by itself, so an unclaimed one runs the view again
	// rather than waiting for whatever happens next. Bounded by
	// `REVEAL_WAIT_BUILDS`, so a key that never appears costs three builds.
	owed := false
	for i := len(ui.reveal_asks) - 1; i >= 0; i -= 1 {
		ui.reveal_asks[i].tries += 1
		if ui.reveal_asks[i].tries >= REVEAL_WAIT_BUILDS {
			ordered_remove(&ui.reveal_asks, i)
		} else if ui.reveal_asks[i].in_build {
			owed = true
		}
	}
	if owed do ask_rebuild(ui)
}
