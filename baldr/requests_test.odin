package baldr

@(require) import "base:runtime"
@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A file manager's needs: drops on a view's background, drag actions, a
// virtual view's visible range, picture release, surface changes, folding
// breadcrumbs and app-bound cut and paste keys.


@(private = "file")
Requests_RMsg :: struct { kind: enum { None, Drop, Out, Range, Cut, Paste }, background: bool, tag: u64, action: Drop_Action, mods: Mods, files: int, first, last: int }

@(private = "file")
row_paths :: proc(user: rawptr, tag: u64, count: int, allocator: runtime.Allocator) -> []string {
	out := make([]string, 1, allocator)
	out[0] = "/home/user/Files/row.txt"
	return out
}

@(private = "file")
Fake :: struct { started: int, offer: string, finished: int, accepted: bool }
@(private = "file")
fake_start :: proc(user: rawptr, surface: u32, items: []Clip_Item, serial: u32, icon: Drag_Icon) -> bool { (^Fake)(user).started += 1; return serial != 0 }
@(private = "file")
fake_accept :: proc(user: rawptr, accept: bool) {}
@(private = "file")
fake_receive :: proc(user: rawptr, mime: string) -> bool {
	return mime == MIME_URI_LIST
}
@(private = "file")
fake_finish :: proc(user: rawptr, accepted: bool) { f := (^Fake)(user); f.finished += 1; f.accepted = accepted }

@(private = "file")
files_table :: proc(ui: ^Ui(Requests_RMsg), rows: int, accepts: string) -> Node {
	set_viewport(&ui.tree, {600, 400})
	begin_view(ui)
	column(ui, flex = 1)
	cols := []Column{{title = "Name"}}
	first, last := table(ui, cols, rows, nil,
		drag = "file", drag_files = row_paths, accepts = accepts,
		on_drop = proc(e: Ev(Drop)) -> Requests_RMsg { return {kind = .Drop, background = e.value.background, tag = e.tag, action = e.value.action, mods = e.value.mods, files = len(e.value.files)} },
		on_drag_out = proc(e: Ev(Drop)) -> Requests_RMsg { return {kind = .Out, tag = e.tag, action = e.value.action, files = len(e.value.files)} },
		label = "Files", key = 3)
	for i in first ..< last {
		table_row(ui, i)
		cell_text(ui, "row.txt")
		end(ui)
	}
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	return node_first(&ui.tree, node_first(&ui.tree, ui.root))
}

@(private = "file")
row_text_at :: proc(ui: ^Ui(Requests_RMsg), tbl: Node, index: int) -> [2]f32 {
	for n, ref in ui.rows do if ref.table == tbl && ref.index == index {
		rd := node_get(&ui.tree, n)
		return {rd.abs.x + 16, rd.abs.y + rd.abs.h / 2} // on the name: the item, not the row's blank part
	}
	return {}
}

// A row dropped on the view's empty space lands in the folder, and the drop
// says so; on a row it names the row. Modifiers pick the action.
@(test)
drop_on_background_and_004_action :: proc(t: ^testing.T) {
	ui: Ui(Requests_RMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tbl := files_table(&ui, 3, "file")
	start := row_text_at(&ui, tbl, 0)
	pointer_button(&ui, .Left, true, start)
	pointer_move(&ui, start + {24, 0})
	testing.expect(t, ui.drag.active, "the row lifts")
	below := [2]f32{300, 360} // under the last row: the folder's empty space
	pointer_move(&ui, below)
	testing.expect_value(t, ui.drag.target, tbl) // the view itself shows it will take the drop
	ui.pointer.mods = {.Ctrl}
	pointer_button(&ui, .Left, false, below)
	testing.expect_value(t, len(ui.msgs), 1)
	m := ui.msgs[0]
	testing.expect(t, m.kind == .Drop && m.background, "a drop on the background")
	testing.expect_value(t, m.action, Drop_Action.Copy)
	testing.expect_value(t, m.mods, Mods{.Ctrl})
	testing.expect_value(t, m.files, 1)

	clear(&ui.msgs)
	ui.pointer.mods = {}
	tbl = files_table(&ui, 3, "file")
	start = row_text_at(&ui, tbl, 0)
	on_row := row_text_at(&ui, tbl, 2)
	pointer_button(&ui, .Left, true, start)
	pointer_move(&ui, start + {24, 0})
	pointer_move(&ui, on_row)
	ui.pointer.mods = {.Shift}
	pointer_button(&ui, .Left, false, on_row)
	testing.expect_value(t, len(ui.msgs), 1)
	m = ui.msgs[0]
	testing.expect(t, m.kind == .Drop && !m.background && m.tag == 2, "a drop on row 2 is row 2")
	testing.expect_value(t, m.action, Drop_Action.Move)
	testing.expect_value(t, drop_action_of_mods({}), Drop_Action.Default)
	testing.expect_value(t, drop_action_of_mods({.Alt}), Drop_Action.Ask)
	testing.expect_value(t, drop_action_of_mods({.Ctrl, .Shift}), Drop_Action.Ask)
}

// An empty folder takes files from another app, with the action negotiated
// with it.
@(test)
empty_folder_takes_a_drop_from_another_app :: proc(t: ^testing.T) {
	ui: Ui(Requests_RMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	fake := Fake{offer = "file:///tmp/a.png\r\n"}
	ui.dnd = {user = &fake, surface = 1, start = fake_start, accept = fake_accept, receive = fake_receive, finish = fake_finish}
	tbl := files_table(&ui, 0, "files")
	testing.expect(t, drag_ext_enter(&ui, {300, 200}, true))
	testing.expect_value(t, ui.drag.target, tbl)
	testing.expect(t, drag_ext_drop(&ui, {300, 200}, .Move, {}))
	testing.expect(t, drag_ext_data(&ui, transmute([]u8)fake.offer, true), "its paths arrive")
	testing.expect_value(t, len(ui.msgs), 1)
	if len(ui.msgs) != 1 do return
	m := ui.msgs[0]
	testing.expect(t, m.kind == .Drop && m.background && m.files == 1, "the empty folder took it")
	testing.expect_value(t, m.action, Drop_Action.Move)
	testing.expect(t, fake.finished == 1 && fake.accepted)
}

// A row dragged out and dropped in another app tells its view what that
// app did.
@(test)
drag_out_reports_the_other_apps_action :: proc(t: ^testing.T) {
	ui: Ui(Requests_RMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	fake: Fake
	ui.dnd = {user = &fake, surface = 1, start = fake_start, accept = fake_accept, receive = fake_receive, finish = fake_finish}
	tbl := files_table(&ui, 3, "file")
	start := row_text_at(&ui, tbl, 1)
	ui.pointer.press_serial = 42
	pointer_button(&ui, .Left, true, start)
	pointer_move(&ui, start + {24, 0})
	pointer_move(&ui, {700, 150}) // past the window's edge
	testing.expect(t, ui.drag.compositor && fake.started == 1)
	testing.expect(t, drag_ext_end(&ui, true, .Move))
	testing.expect_value(t, len(ui.msgs), 1)
	m := ui.msgs[0]
	testing.expect(t, m.kind == .Out && m.tag == 1 && m.files == 1, "the source row hears it")
	testing.expect_value(t, m.action, Drop_Action.Move)
	testing.expect(t, !ui.drag.active)
}

// A virtual view reports the rows it builds when they change.
@(test)
visible_range :: proc(t: ^testing.T) {
	ui: Ui(Requests_RMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	on_range :: proc(e: Ev([2]int)) -> Requests_RMsg { return {kind = .Range, first = e.value[0], last = e.value[1]} }
	build :: proc(ui: ^Ui(Requests_RMsg), on_range: proc(e: Ev([2]int)) -> Requests_RMsg, grid: bool) -> Node {
		set_viewport(&ui.tree, {600, 400})
		begin_view(ui)
		column(ui, flex = 1)
		if grid {
			f, l := icon_view(ui, 1000, nil, on_range = on_range, label = "Pictures", key = 5)
			for i in f ..< l do icon_item(ui, i, .File, "pic")
		} else {
			f, l := list(ui, 1000, 20, on_range = on_range, label = "Lines", key = 6)
			for i in f ..< l do box(ui, height = 20, key = u64(i + 1))
		}
		end(ui)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {600, 400})
		return node_first(&ui.tree, node_first(&ui.tree, ui.root))
	}
	for grid in ([]bool{false, true}) {
		clear(&ui.msgs)
		n := build(&ui, on_range, grid)
		build(&ui, on_range, grid) // the second build knows the real height
		testing.expect(t, len(ui.msgs) >= 1, "the first rows are reported")
		last := ui.msgs[len(ui.msgs) - 1]
		testing.expect(t, last.kind == .Range && last.first == 0 && last.last > 0, "from the top")
		clear(&ui.msgs)
		build(&ui, on_range, grid)
		testing.expect_value(t, len(ui.msgs), 0) // unchanged: nothing
		list_node := n if !grid else ui.tree.icon_views[n].list
		scroll_to(&ui.tree, list_node, {0, 3000})
		build(&ui, on_range, grid)
		testing.expect_value(t, len(ui.msgs), 1)
		m := ui.msgs[0]
		testing.expect(t, m.first > 0 && m.last > m.first, "scrolled: a later range")
		if grid do testing.expect_value(t, m.first % ui.tree.icon_views[n].cols, 0) // whole rows of tiles, as item indices
		ui_destroy(&ui)
		ui_init(&ui)
	}
}

// A new picture where an old one was freed is not mistaken for it, and a
// full picture atlas starts over (unless the screen needs the room).
@(test)
pictures_are_released :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do return
	defer text_engine_destroy(&te)
	small := make([]u8, 4 * 4 * 4, context.temp_allocator)
	img, _ := image_from_rgba(4, 4, small)
	_, ok1 := image_slot(&te, &img)
	image_destroy(&img)
	img, _ = image_from_rgba(4, 4, small) // same address, version 1 again
	_, ok2 := image_slot(&te, &img)
	testing.expect(t, ok1 && ok2)
	testing.expect_value(t, len(te.images), 2) // a new identity, a new upload
	image_destroy(&img)
	clear(&te.images)
	te.image_frame_px = 0

	big_px := make([]u8, 1000 * 1000 * 4, context.temp_allocator)
	big, _ := image_from_rgba(1000, 1000, big_px)
	defer image_destroy(&big)
	for _ in 0 ..< IMAGE_ATLAS_PAGES + 1 { // one page each
		_, ok := image_slot(&te, &big)
		testing.expect(t, ok)
		big.version += 1
	}
	testing.expect(t, te.images_full, "past the page budget")
	images_begin_frame(&te, nil) // but all of them were on screen this frame
	testing.expect_value(t, len(te.images), IMAGE_ATLAS_PAGES + 1) // so the atlas grows rather than thrash
	testing.expect(t, !te.images_full)

	_, ok := image_slot(&te, &big) // a later frame draws one new picture
	testing.expect(t, ok && te.images_full)
	images_begin_frame(&te, nil)
	testing.expect_value(t, len(te.images), 0) // started over
	for p in te.image_atlas.pages_color do testing.expect_value(t, len(p.shelves), 0)
	big.version += 1
	slot, sok := image_slot(&te, &big)
	testing.expect(t, sok && slot.page_index == 0, "the next picture packs from the first page")
	testing.expect_value(t, len(te.atlas.pages_color), 0) // glyph and emoji pages untouched
}

// What changed on a surface that stays open.
@(test)
an_open_surface_reports_what_changed :: proc(t: ^testing.T) {
	a := Surface_Desc(Requests_RMsg){tag = 1, title = "Home — Files", size = {1180, 740}, transparent = true, backdrop = .Blur}
	b := a
	testing.expect_value(t, surface_changes(a, b), Surface_Changes{})
	b.title = strings.clone("Pictures — Files", context.temp_allocator)
	testing.expect_value(t, surface_changes(a, b), Surface_Changes{.Title})
	b.size = {900, 600} // a window's size is live: the app may change it
	testing.expect_value(t, surface_changes(a, b), Surface_Changes{.Title, .Size})
	b.backdrop = .None
	b.transparent = false
	b.layer.margin = {4, 0, 0, 0} // a window has no layer placement: not a change
	ch := surface_changes(a, b)
	testing.expect_value(t, ch, Surface_Changes{.Title, .Size, .Backdrop, .Transparent})
	testing.expect_value(t, ch - SURFACE_LIVE_CHANGES, Surface_Changes{.Transparent})
}

// A trail folds by the width it gets, not only at phone size, and every
// crumb it shows is readable.
@(test)
breadcrumbs_fold_by_width :: proc(t: ^testing.T) {
	ui: Ui(Requests_RMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	parts := []string{"File System", "tmp", "shared-team-project-folder", "quarterly-reports-and-presentation", "3d1e7a90-backup-2026-11-holiday", "pictures-and-scans01", "samples"}
	full := crumbs_width(&ui.tree, parts, 0)
	view :: proc(ui: ^Ui(Requests_RMsg), parts: []string, w: f32) -> Node {
		set_viewport(&ui.tree, {w, 200})
		begin_view(ui)
		row(ui, padding = .md, gap = .sm, align = .Center)
		button(ui, "Back", Requests_RMsg{})
		b := breadcrumbs(ui, parts, Requests_RMsg{}, flex = 1)
		button(ui, "Search", Requests_RMsg{})
		end(ui)
		end_view(ui)
		frame(&ui.tree, {w, 200})
		return b
	}
	narrow := max(full * 0.6 + 200, 700)
	testing.expect(t, size_class_of(narrow) != .Compact, "a desktop width")
	view(&ui, parts, narrow)
	b := view(&ui, parts, narrow)
	dump := access_dump(&ui.tree)
	testing.expect(t, strings.contains(dump, "Button \"…\""), dump)
	testing.expect(t, strings.contains(dump, "Button \"pictures-and-scans01\"") && strings.contains(dump, "Text \"samples\""), "the parent and the current place stay")
	testing.expect(t, !strings.contains(dump, "Button \"File System\""), "the leading parts fold")
	first := crumbs_first_shown(&ui.tree, parts, ui.crumbs[b], false)
	dots := node_first(&ui.tree, b)
	testing.expect_value(t, node_get(&ui.tree, dots).tag, u64(first - 1)) // "…" goes to the nearest folded part
	for c := node_first(&ui.tree, b); c != NODE_NONE; c = node_next(&ui.tree, c) {
		cd := node_get(&ui.tree, c)
		if cd.access.role == .Button do testing.expectf(t, cd.abs.w >= crumb_width(&ui.tree, cd.access.name) - 1, "%q is squeezed to %v", cd.access.name, cd.abs.w)
	}

	wide := full + 600
	set_viewport(&ui.tree, {wide, 200})
	frame(&ui.tree, {wide, 200})
	ui.needs_rebuild = false
	breadcrumbs_tick(&ui)
	testing.expect(t, ui.needs_rebuild, "more room: rebuild")
	view(&ui, parts, wide)
	dump = access_dump(&ui.tree)
	testing.expect(t, !strings.contains(dump, "Button \"…\"") && strings.contains(dump, "Button \"File System\""), "it all fits again")
}

@(private = "file")
cut_view :: proc(ui: ^Ui(Requests_RMsg), sel: ^Selection, bind: bool) -> Node {
	set_viewport(&ui.tree, {600, 400})
	begin_view(ui)
	column(ui, flex = 1)
	if bind {
		shortcut(ui, "Ctrl+X", Requests_RMsg{kind = .Cut})
		shortcut(ui, "Ctrl+V", Requests_RMsg{kind = .Paste})
	}
	cols := []Column{{title = "Name"}}
	first, last := table(ui, cols, 3, sel, drag = "files", drag_files = row_paths, label = "Files", key = 3)
	for i in first ..< last {
		table_row(ui, i)
		cell_text(ui, "row.txt")
		end(ui)
	}
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	return node_first(&ui.tree, node_first(&ui.tree, ui.root))
}

// A file view whose app binds Ctrl+X and Ctrl+V cuts and pastes with them;
// without those bindings the keys still pick up and drop.
@(test)
app_cut_and_paste_keys_beat_the_keyboard_pick_up :: proc(t: ^testing.T) {
	ui: Ui(Requests_RMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	tbl := cut_view(&ui, &sel, false)
	set_focus(&ui.tree, tbl, true)
	key_event(&ui, .Down, true, {})
	clear(&ui.msgs)
	testing.expect(t, key_event(&ui, .X, true, {.Ctrl}), "no Ctrl+X of the app's: the keyboard pick-up")
	testing.expect(t, ui.drag.active && ui.drag.keyboard)
	key_event(&ui, .Escape, true, {})
	testing.expect(t, !ui.drag.active)

	tbl = cut_view(&ui, &sel, true)
	clear(&ui.msgs)
	testing.expect(t, !key_event(&ui, .X, true, {.Ctrl}), "the app bound Ctrl+X: the view leaves it")
	testing.expect(t, !ui.drag.active, "nothing picked up")
	testing.expect(t, shortcut_fire(&ui, .X, true, {.Ctrl}))
	testing.expect(t, !key_event(&ui, .V, true, {.Ctrl}), "nothing carried: Ctrl+V is the app's")
	testing.expect(t, shortcut_fire(&ui, .V, true, {.Ctrl}))
	testing.expect_value(t, len(ui.msgs), 2)
	testing.expect(t, ui.msgs[0].kind == .Cut && ui.msgs[1].kind == .Paste, "Cut, then Paste")
}

} // when ODIN_TEST