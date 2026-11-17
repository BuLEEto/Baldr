package baldr

@(require) import "core:testing"

when ODIN_TEST || #config(BALDR_TESTS, false) {

// drag_rest: a drag that stands still on something opens it — a
// spring-loaded folder, a taskbar button raising its window — so a file
// can be carried three folders down, or onto a covered window, without
// letting go.
//
// The awkward parts, each with a test below: it fires once where the drag
// settles, not every tick; a node that takes no drop still hears it (a
// taskbar button takes "pin" drops, not files); and once the handler has
// changed what is under the pointer, the drop target is worked out again,
// or the drop lands on the row that opened rather than inside it.

@(private = "file")
Rest_Msg :: struct {
	kind:  string,
	tag:   u64,
	count: int,
	at:    [2]f32,
}

@(private = "file")
rest_files :: proc(user: rawptr, tag: u64, count: int, allocator := context.allocator) -> []string {
	out := make([]string, 1, allocator)
	out[0] = "/home/user/Files/row.txt"
	return out
}

@(private = "file")
Rest_Fx :: struct {
	ui:     Ui(Rest_Msg),
	source: Node,
	folder: Node, // hears a rest, and takes no drop
	bin:    Node, // takes a drop and hears nothing
}

// rest_window: a draggable row, a folder that springs open but accepts no
// drop of this kind, and a bin that takes the drop and springs at nothing.
@(private = "file")
rest_build :: proc(fx: ^Rest_Fx, folder_accepts := "", opened := false, navigated := false) {
	ui := &fx.ui
	set_viewport(&ui.tree, {400, 400})
	begin_view(ui)
	column(ui, gap = .md, padding = .md)
	if !navigated { // the file is listed here; opening a folder navigates away from it
		fx.source = row(ui, height = 30, width = 200)
		text(ui, "row.txt")
		end(ui)
		draggable(ui, fx.source, "file", tag = 1, files = rest_files)
	} else {
		box(ui, height = 30, width = 200) // the same room, so the rows below do not move
	}

	fx.folder = row(ui, height = 60, width = 200)
	text(ui, "Pictures/2019" if opened else "Pictures")
	end(ui)
	if opened {
		// what "the handler opened the folder" comes to: the same place
		// on screen now takes the drop
		drop_target(ui, fx.folder, proc(e: Ev(Drop)) -> Rest_Msg { return Rest_Msg{kind = e.value.kind} }, accepts = "file")
	} else {
		drag_rest(ui, fx.folder, proc(e: Ev(Drag_Rest)) -> Rest_Msg {
			return Rest_Msg{kind = e.value.kind, tag = e.value.tag, count = e.value.count, at = e.value.at}
		}, accepts = folder_accepts)
	}

	fx.bin = row(ui, height = 60, width = 200)
	text(ui, "Rubbish Bin")
	end(ui)
	drop_target(ui, fx.bin, proc(e: Ev(Drop)) -> Rest_Msg { return Rest_Msg{kind = e.value.kind} }, accepts = "file")
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 400})
}

@(private = "file")
rest_mid :: proc(fx: ^Rest_Fx, n: Node) -> [2]f32 {
	d := node_get(&fx.ui.tree, n)
	return {d.abs.x + d.abs.w / 2, d.abs.y + d.abs.h / 2}
}

// rest_lift presses on the row and drags to `to`, crossing the threshold.
@(private = "file")
rest_lift :: proc(fx: ^Rest_Fx, to: [2]f32) {
	from := rest_mid(fx, fx.source)
	fx.ui.pointer.press_serial = 42
	pointer_button(&fx.ui, .Left, true, from)
	pointer_move(&fx.ui, from + {20, 0})
	pointer_move(&fx.ui, to)
}

// rest_wait runs the tick at `now`, as a wake-up would.
@(private = "file")
rest_wait :: proc(fx: ^Rest_Fx, now: f64) {
	fx.ui.tree.now_ms = now
	ui_after_events(&fx.ui, now)
}

@(test)
a_drag_that_rests_on_a_node_is_heard_once :: proc(t: ^testing.T) {
	fx: Rest_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	rest_build(&fx)
	rest_lift(&fx, rest_mid(&fx, fx.folder))
	testing.expect(t, fx.ui.drag.active, "the drag is up")

	rest_wait(&fx, DRAG_REST_MS - 50)
	testing.expect_value(t, len(fx.ui.msgs), 0) // not yet: it has not stood still long enough

	rest_wait(&fx, DRAG_REST_MS + 10)
	if !testing.expect(t, len(fx.ui.msgs) == 1, "it is heard once it has stood still") do return
	m := fx.ui.msgs[0]
	testing.expect_value(t, m.kind, "file")
	testing.expect_value(t, m.tag, u64(1))
	testing.expect_value(t, m.count, 1)
	// `at` is from the node's own top-left, as Drop.at is
	fd := node_get(&fx.ui.tree, fx.folder)
	testing.expect_value(t, m.at, [2]f32{fd.abs.w / 2, fd.abs.h / 2})

	clear(&fx.ui.msgs)
	rest_wait(&fx, DRAG_REST_MS * 3)
	testing.expect_value(t, len(fx.ui.msgs), 0) // …and once only, however long it stands there
}

@(test)
a_drag_that_moves_on_and_settles_is_heard_again :: proc(t: ^testing.T) {
	fx: Rest_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	rest_build(&fx)
	at := rest_mid(&fx, fx.folder)
	rest_lift(&fx, at)
	rest_wait(&fx, DRAG_REST_MS + 10)
	testing.expect_value(t, len(fx.ui.msgs), 1)
	clear(&fx.ui.msgs)

	// A drift of a pixel or two is still standing still — a hand on a
	// mouse is never perfectly still, and restarting on that would mean
	// nothing ever sprang open.
	fx.ui.tree.now_ms = DRAG_REST_MS + 20
	pointer_move(&fx.ui, at + {DRAG_REST_SLOP - 1, 0})
	rest_wait(&fx, DRAG_REST_MS * 2 + 40)
	testing.expect_value(t, len(fx.ui.msgs), 0)

	// Moving off it and back is a new rest, and is heard again.
	fx.ui.tree.now_ms = DRAG_REST_MS * 2 + 50
	pointer_move(&fx.ui, rest_mid(&fx, fx.bin))
	pointer_move(&fx.ui, at)
	rest_wait(&fx, DRAG_REST_MS * 3 + 100)
	testing.expect_value(t, len(fx.ui.msgs), 1)
}

@(test)
a_node_that_takes_no_drop_still_hears_a_rest :: proc(t: ^testing.T) {
	// The taskbar button: it takes "pin" drops, not files, and a file
	// held over it should still bring its window up. So a rest is asked
	// for apart from `drop_target` and is heard whatever that says.
	fx: Rest_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	rest_build(&fx)
	_, has_drop := fx.ui.tree.drops[fx.folder]
	testing.expect(t, !has_drop, "the folder takes no drop at all")

	rest_lift(&fx, rest_mid(&fx, fx.folder))
	rest_wait(&fx, DRAG_REST_MS + 10)
	testing.expect_value(t, len(fx.ui.msgs), 1)
	testing.expect_value(t, fx.ui.drag.target, NODE_NONE) // …and nothing is ringed
}

@(test)
a_rest_hears_only_the_kinds_it_asked_for :: proc(t: ^testing.T) {
	fx: Rest_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	rest_build(&fx, folder_accepts = "folder") // the drag is a "file"
	rest_lift(&fx, rest_mid(&fx, fx.folder))
	rest_wait(&fx, DRAG_REST_MS + 10)
	testing.expect_value(t, len(fx.ui.msgs), 0)
}

@(test)
a_keyboard_drag_and_a_spring_back_are_never_heard :: proc(t: ^testing.T) {
	// There is no pointer standing still in a keyboard drag, and a
	// cancelled drag flying home must not open whatever it passes over.
	fx: Rest_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	rest_build(&fx)
	testing.expect(t, drag_begin(&fx.ui, fx.source, true), "picked up with the keyboard")
	fx.ui.drag.pos = rest_mid(&fx, fx.folder)
	rest_wait(&fx, DRAG_REST_MS * 2)
	testing.expect_value(t, len(fx.ui.msgs), 0)
	drag_end(&fx.ui)
	clear(&fx.ui.msgs)

	// …and during the spring-back after Escape
	at := rest_mid(&fx, fx.folder)
	rest_lift(&fx, at)
	fx.ui.tree.now_ms = 10
	testing.expect(t, drag_cancel(&fx.ui), "Escape sends it home")
	testing.expect(t, fx.ui.drag.returning, "it is on its way")
	fx.ui.drag.pos = at // whatever it passes over on the way
	fx.ui.drag.rest_due = 1
	rest_wait(&fx, DRAG_REST_MS + 20)
	testing.expect_value(t, len(fx.ui.msgs), 0)
}

@(test)
another_apps_drag_rests_too :: proc(t: ^testing.T) {
	// A file dragged in from another program is the case this matters
	// most for, and it arrives through drag_ext_* rather than the
	// pointer. Its kind is "files".
	fx: Rest_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	rest_build(&fx, folder_accepts = "files")
	at := rest_mid(&fx, fx.folder)
	testing.expect(t, drag_ext_enter(&fx.ui, at, true), "another app's file drag is taken")
	testing.expect(t, drag_ext_motion(&fx.ui, at))
	rest_wait(&fx, DRAG_REST_MS + 10)
	if !testing.expect(t, len(fx.ui.msgs) == 1, "it is heard") do return
	testing.expect_value(t, fx.ui.msgs[0].kind, "files")
}

@(test)
what_the_handler_opens_is_what_the_drop_lands_in :: proc(t: ^testing.T) {
	// The handler opens the folder, the app rebuilds, and the pointer has
	// not moved — so the drop target has to be worked out again from where
	// it stands, or the drop lands on the row that opened rather than inside
	// what it opened.
	fx: Rest_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	rest_build(&fx)
	at := rest_mid(&fx, fx.folder)
	rest_lift(&fx, at)
	rest_wait(&fx, DRAG_REST_MS + 10)
	testing.expect_value(t, len(fx.ui.msgs), 1)
	testing.expect_value(t, fx.ui.drag.target, NODE_NONE) // the folder itself takes nothing

	// The app answers by opening it: the same place now takes the drop.
	// Rebuilt from the same builder calls, so the nodes reconcile as a real
	// view's rebuild does. Opening the folder navigates away from the file,
	// so the dragged row itself leaves the view — what spring-loading
	// always does — and the drag must outlive its source node.
	clear(&fx.ui.msgs)
	rest_build(&fx, opened = true, navigated = true)
	testing.expect(t, fx.ui.drag.active, "the drag survives its own row leaving the view")
	testing.expect_value(t, fx.ui.drag.source, NODE_NONE) // …and has let go of the node
	testing.expect_value(t, fx.ui.drag.kind, "file")      // what it carries is still there
	testing.expect_value(t, fx.ui.drag.tag, u64(1))

	rest_wait(&fx, DRAG_REST_MS + 20)
	testing.expectf(t, fx.ui.drag.target == fx.folder,
		"the drop target is worked out again under the still pointer (%v, wanted %v)", fx.ui.drag.target, fx.folder)

	// …and letting go now lands the drop there, which is the whole point.
	pointer_button(&fx.ui, .Left, false, at)
	if testing.expect(t, len(fx.ui.msgs) == 1, "the drop is delivered") {
		testing.expect_value(t, fx.ui.msgs[0].kind, "file")
	}
}

@(test)
a_drag_outlives_the_row_it_was_lifted_from :: proc(t: ^testing.T) {
	// A spring-loaded folder navigates the view, and the file's own row
	// goes with it. A drag is its kind, tag, count and paths; the node is
	// only where it started.
	fx: Rest_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	rest_build(&fx)
	rest_lift(&fx, rest_mid(&fx, fx.folder))
	testing.expect(t, fx.ui.drag.active)

	rest_build(&fx, navigated = true)
	testing.expect(t, fx.ui.drag.active, "the drag goes on without the row it came from")
	testing.expect_value(t, fx.ui.drag.source, NODE_NONE)
	testing.expect_value(t, fx.ui.tree.drag_source, NODE_NONE)
	testing.expect(t, fx.ui.drag.picture == nil, "and lets go of the source's picture, which the app may now free")
	testing.expect(t, !fx.ui.drag.previewing, "a reorder preview was about that node and goes with it")
	// the ghost falls back to the chip, since there is nothing left to mirror
	testing.expect_value(t, drag_mirror_of(&fx.ui.tree), NODE_NONE)
}

@(private = "file")
Rest_View_Msg :: struct { tag: u64 }

@(test)
a_views_rows_hear_a_rest_with_their_own_tag :: proc(t: ^testing.T) {
	// A file manager's folders are rows inside an icon view or a table,
	// and the view builds those nodes itself — so the app has no node to
	// call `drag_rest` on, and a rest on the whole view would hand back
	// the view's tag and leave the app to redo the view's hit testing.
	// `on_rest` sits beside `on_drop` and fires with the row's tag.
	ui: Ui(Rest_View_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)

	build :: proc(ui: ^Ui(Rest_View_Msg), sel: ^Selection) -> Node {
		set_viewport(&ui.tree, {600, 400})
		begin_view(ui)
		column(ui, flex = 1)
		first, last := icon_view(ui, 6, sel, drag = "files", accepts = "files",
			on_drop = proc(e: Ev(Drop)) -> Rest_View_Msg { return Rest_View_Msg{e.tag} },
			on_rest = proc(e: Ev(Drag_Rest)) -> Rest_View_Msg { return Rest_View_Msg{e.tag} },
			label = "Desktop", key = 11)
		for i in first ..< last do icon_item(ui, i, .Folder, "folder")
		end(ui)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {600, 400})
		return node_first(&ui.tree, node_first(&ui.tree, ui.root))
	}
	view := build(&ui, &sel)

	// the tile for item 2, and another app's drag held still over it
	tile, tile_tag := NODE_NONE, u64(0)
	for n, ref in ui.rows do if ref.table == view && ref.index == 2 {
		tile = n
		tile_tag = node_get(&ui.tree, n).tag
	}
	if !testing.expect(t, tile != NODE_NONE, "the view built a tile for item 2") do return
	td := node_get(&ui.tree, tile).abs
	at := [2]f32{td.x + td.w / 2, td.y + td.h / 2}

	testing.expect(t, drag_ext_enter(&ui, at, true))
	testing.expect(t, drag_ext_motion(&ui, at))
	ui.tree.now_ms = DRAG_REST_MS + 10
	ui_after_events(&ui, DRAG_REST_MS + 10)
	if !testing.expect(t, len(ui.msgs) == 1, "the tile under the drag hears it rest") do return
	testing.expectf(t, ui.msgs[0].tag == tile_tag,
		"and it is the row's own tag, as on_drop gives (%d, wanted %d)", ui.msgs[0].tag, tile_tag)

	// …and the view's own background opens nothing: there is nothing there
	// to open, and a rest on empty space should not act.
	clear(&ui.msgs)
	_, on_view := ui.tree.rests[view]
	testing.expect(t, !on_view, "the view itself is not a rest target")
}

@(test)
a_crumb_hears_a_rest :: proc(t: ^testing.T) {
	// Resting on a part of the path goes up to it, as a desktop file
	// manager's path bar does.
	ui: Ui(Rest_View_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	parts := []string{"Home", "Pictures", "2019"}
	set_viewport(&ui.tree, {600, 400})
	begin_view(&ui)
	column(&ui, flex = 1, padding = .md)
	bc := breadcrumbs(&ui, parts, on_rest = proc(e: Ev(Drag_Rest)) -> Rest_View_Msg { return Rest_View_Msg{e.tag} })
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 400})

	// the first part, "Home": tag 0
	home := node_first(&ui.tree, bc)
	if !testing.expect(t, home != NODE_NONE, "the path has parts") do return
	hd := node_get(&ui.tree, home).abs
	at := [2]f32{hd.x + hd.w / 2, hd.y + hd.h / 2}

	testing.expect(t, drag_ext_enter(&ui, at, true))
	testing.expect(t, drag_ext_motion(&ui, at))
	ui.tree.now_ms = DRAG_REST_MS + 10
	ui_after_events(&ui, DRAG_REST_MS + 10)
	if !testing.expect(t, len(ui.msgs) == 1, "the crumb hears the drag rest on it") do return
	testing.expect_value(t, ui.msgs[0].tag, u64(0)) // which part of the path it was
}

// ---- what the drag carries, once it is carrying it

@(private = "file")
Shelf :: struct {
	rows:  []string, // what the window is showing *now*
	asked: int,      // how many times the source was asked for its paths
}

// shelf_files answers from the window's current rows, the way a file
// manager's does: `tag` is a row number, not a file, so it means something
// different once the folder under the drag has changed.
@(private = "file")
shelf_files :: proc(user: rawptr, tag: u64, count: int, allocator := context.allocator) -> []string {
	sh := (^Shelf)(user)
	sh.asked += 1
	if int(tag) >= len(sh.rows) do return nil // row 0 of an empty folder
	out := make([]string, 1, allocator)
	out[0] = sh.rows[tag]
	return out
}

@(test)
a_drop_moves_the_file_that_was_picked_up :: proc(t: ^testing.T) {
	// The paths are asked for once, as the drag is picked up. A source
	// answers from the rows it is showing, and with spring-loading the
	// folder changes under the drag by design, so asking as the drop lands
	// would resolve the old row number against the new folder — a
	// different file, or none.
	fx: Rest_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	shelf := Shelf{rows = []string{"/work/one.txt", "/work/two.txt"}}

	build :: proc(fx: ^Rest_Fx, sh: ^Shelf) {
		ui := &fx.ui
		set_viewport(&ui.tree, {400, 400})
		begin_view(ui)
		column(ui, gap = .md, padding = .md)
		fx.source = row(ui, height = 30, width = 200)
		text(ui, "one.txt")
		end(ui)
		draggable(ui, fx.source, "file", tag = 0, files = shelf_files, user = sh)
		fx.bin = row(ui, height = 60, width = 200)
		text(ui, "a")
		end(ui)
		drop_target(ui, fx.bin, proc(e: Ev(Drop)) -> Rest_Msg {
			return Rest_Msg{kind = e.value.files[0] if len(e.value.files) > 0 else "nothing"}
		}, accepts = "file")
		end(ui)
		end_view(ui)
		frame(&ui.tree, {400, 400})
	}
	build(&fx, &shelf)
	rest_lift(&fx, rest_mid(&fx, fx.bin))
	testing.expectf(t, shelf.asked == 1, "the source is asked once, as the drag is picked up (%d)", shelf.asked)

	// The folder opens under the drag: the window is showing other rows
	// now, and row 0 is a different file — or no file at all.
	shelf.rows = []string{"/work/a/other.txt"}
	build(&fx, &shelf)

	at := rest_mid(&fx, fx.bin)
	pointer_button(&fx.ui, .Left, false, at)
	if !testing.expect(t, len(fx.ui.msgs) == 1, "the drop lands") do return
	testing.expectf(t, fx.ui.msgs[0].kind == "/work/one.txt",
		"it carries the file that was picked up, not row 0 of wherever it ended up (%s)", fx.ui.msgs[0].kind)
	testing.expectf(t, shelf.asked == 1, "and the source is never asked again (%d)", shelf.asked)
}

@(test)
an_empty_folder_cannot_swallow_the_drop :: proc(t: ^testing.T) {
	// The same hazard at its quietest: the folder the drag opened is
	// empty, so row 0 would resolve to nothing and the drop carry no paths.
	fx: Rest_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	shelf := Shelf{rows = []string{"/work/one.txt"}}
	build :: proc(fx: ^Rest_Fx, sh: ^Shelf) {
		ui := &fx.ui
		set_viewport(&ui.tree, {400, 400})
		begin_view(ui)
		column(ui, gap = .md, padding = .md)
		fx.source = row(ui, height = 30, width = 200)
		text(ui, "one.txt")
		end(ui)
		draggable(ui, fx.source, "file", tag = 0, files = shelf_files, user = sh)
		fx.bin = row(ui, height = 60, width = 200)
		text(ui, "b")
		end(ui)
		drop_target(ui, fx.bin, proc(e: Ev(Drop)) -> Rest_Msg {
			return Rest_Msg{count = len(e.value.files)}
		}, accepts = "file")
		end(ui)
		end_view(ui)
		frame(&ui.tree, {400, 400})
	}
	build(&fx, &shelf)
	rest_lift(&fx, rest_mid(&fx, fx.bin))
	shelf.rows = nil // b is empty
	build(&fx, &shelf)
	pointer_button(&fx.ui, .Left, false, rest_mid(&fx, fx.bin))
	if !testing.expect(t, len(fx.ui.msgs) == 1, "the drop lands") do return
	testing.expect_value(t, fx.ui.msgs[0].count, 1) // the file it was carrying
}

@(test)
a_folder_in_the_same_slot_springs_in_turn :: proc(t: ^testing.T) {
	// Holding still over a folder whose first row is itself a folder, in
	// the same place on screen: the view reuses the row node (rows are
	// keyed by index), so "the same node, already told" alone would stop
	// the descent. A rest is heard again on the same node once the view has
	// been built since, so a handler that changes nothing is heard once.
	fx: Rest_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	rest_build(&fx)
	at := rest_mid(&fx, fx.folder)
	rest_lift(&fx, at)
	rest_wait(&fx, DRAG_REST_MS + 10)
	testing.expect_value(t, len(fx.ui.msgs), 1)
	clear(&fx.ui.msgs)

	// The handler opened it: a rebuild, with the same row node in the
	// same slot (same builder call, same key).
	rest_build(&fx)
	rest_wait(&fx, DRAG_REST_MS * 2 + 30)
	testing.expectf(t, len(fx.ui.msgs) == 1,
		"the slot springs again once the view has changed under the drag (%d)", len(fx.ui.msgs))
	clear(&fx.ui.msgs)

	// …and with no rebuild, it is heard once and no more, however long
	// the drag stands there.
	rest_wait(&fx, DRAG_REST_MS * 4)
	rest_wait(&fx, DRAG_REST_MS * 6)
	testing.expect_value(t, len(fx.ui.msgs), 0)
}

@(test)
a_path_bar_goes_up_one_level_and_waits :: proc(t: ^testing.T) {
	// Resting on a part of the path goes up to it, and then the bar
	// reflows, so an ancestor slides under a pointer that never moved;
	// holding still would climb the whole path. So a crumb acts once and
	// nothing else is heard until the drag moves.
	//
	// A folder row is the opposite case and keeps springing, because what
	// it opens appears under the pointer. That is `repeat`, and it is the
	// caller's to say: only the caller knows where its handler goes.
	ui: Ui(Rest_View_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	deep := []string{"Home", "work", "a", "aa"}

	build :: proc(ui: ^Ui(Rest_View_Msg), parts: []string) -> Node {
		set_viewport(&ui.tree, {600, 400})
		begin_view(ui)
		column(ui, flex = 1, padding = .md)
		bc := breadcrumbs(ui, parts, on_rest = proc(e: Ev(Drag_Rest)) -> Rest_View_Msg { return Rest_View_Msg{e.tag} })
		end(ui)
		end_view(ui)
		frame(&ui.tree, {600, 400})
		return bc
	}
	bc := build(&ui, deep)
	part := node_first(&ui.tree, bc)
	if !testing.expect(t, part != NODE_NONE, "the path has parts") do return
	pd := node_get(&ui.tree, part).abs
	at := [2]f32{pd.x + pd.w / 2, pd.y + pd.h / 2}

	testing.expect(t, drag_ext_enter(&ui, at, true))
	testing.expect(t, drag_ext_motion(&ui, at))
	ui.tree.now_ms = DRAG_REST_MS + 10
	ui_after_events(&ui, DRAG_REST_MS + 10)
	testing.expect_value(t, len(ui.msgs), 1) // up one level
	clear(&ui.msgs)

	// The app went up, so the bar is shorter and a different part is
	// under the still pointer. Nothing more is heard.
	build(&ui, deep[:2])
	ui.tree.now_ms = DRAG_REST_MS * 3
	ui_after_events(&ui, DRAG_REST_MS * 3)
	ui.tree.now_ms = DRAG_REST_MS * 5
	ui_after_events(&ui, DRAG_REST_MS * 5)
	testing.expectf(t, len(ui.msgs) == 0, "it does not go on climbing under a still pointer (%d)", len(ui.msgs))

	// …until the drag moves, when the bar is live again.
	bc = build(&ui, deep[:2])
	part = node_first(&ui.tree, bc)
	pd = node_get(&ui.tree, part).abs
	moved := [2]f32{pd.x + pd.w / 2, pd.y + pd.h / 2}
	ui.tree.now_ms = DRAG_REST_MS * 5
	testing.expect(t, drag_ext_motion(&ui, moved + {40, 0}))
	testing.expect(t, drag_ext_motion(&ui, moved))
	ui_after_events(&ui, DRAG_REST_MS * 6 + 20)
	testing.expectf(t, len(ui.msgs) == 1, "moving to a part and settling is heard again (%d)", len(ui.msgs))
}

}
