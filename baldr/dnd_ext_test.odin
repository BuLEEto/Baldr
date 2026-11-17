package baldr

@(require) import "base:runtime"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
DndExt_XMsg :: struct { files: []string, kind: string, tag: u64, count: int, action: Drop_Action, at: [2]f32 }

// A fake platform: records what the toolkit asked of it.
@(private = "file")
Fake_Dnd :: struct {
	started:  int,
	items:    int,
	uris:     string,
	accepts:  [dynamic]bool,
	finished: int,
	accepted: bool,
	offer:    string, // what an incoming drag carries
	asked:    int,    // how many times its data was asked for
	icon_size:   [2]i32, // the picture the drag left with
	icon_offset: [2]i32,
}
@(private = "file")
fake_start :: proc(user: rawptr, surface: u32, items: []Clip_Item, serial: u32, icon: Drag_Icon) -> bool {
	f := (^Fake_Dnd)(user)
	f.started += 1
	f.items = len(items)
	f.icon_size, f.icon_offset = icon.size, icon.offset // the pixels are the frame's; the shape is all a fake needs
	for it in items do if it.mime == MIME_URI_LIST do f.uris = string(it.data)
	return serial != 0
}
@(private = "file")
fake_accept :: proc(user: rawptr, accept: bool) { append(&(^Fake_Dnd)(user).accepts, accept) }
@(private = "file")
fake_receive :: proc(user: rawptr, mime: string) -> bool {
	f := (^Fake_Dnd)(user)
	f.asked += 1
	return mime == MIME_URI_LIST
}
@(private = "file")
fake_finish :: proc(user: rawptr, accepted: bool) {
	f := (^Fake_Dnd)(user)
	f.finished += 1
	f.accepted = accepted
}

@(private = "file")
row_files :: proc(user: rawptr, tag: u64, count: int, allocator: runtime.Allocator) -> []string {
	out := make([]string, 1, allocator)
	out[0] = "/home/user/Files/row.txt" if tag == 1 else "/home/user/Files/other.txt"
	return out
}

// A window with a draggable file row and a folder that takes files.
@(private = "file")
files_window :: proc(ui: ^Ui(DndExt_XMsg), accepts := "files", drag_out := false) -> (row_n, folder: Node) {
	set_viewport(&ui.tree, {400, 300})
	begin_view(ui)
	column(ui, gap = .md, padding = .md)
	row_n = row(ui, height = 30, width = 200)
	text(ui, "row.txt")
	end(ui)
	out: Handler(DndExt_XMsg, Drop)
	if drag_out do out = DndExt_XMsg{kind = "out"}
	draggable(ui, row_n, "file", tag = 1, files = row_files, on_drag_out = out)
	folder = row(ui, height = 60, width = 200)
	text(ui, "Pictures")
	end(ui)
	drop_target(ui, folder, proc(e: Ev(Drop)) -> DndExt_XMsg { return DndExt_XMsg{e.value.files, e.value.kind, e.tag, e.value.count, e.value.action, e.value.at} }, accepts = accepts, tag = 7)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 300})
	return
}

@(test)
drop_from_another_app_lands_as_files :: proc(t: ^testing.T) {
	ui: Ui(DndExt_XMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	fake := Fake_Dnd{offer = "file:///tmp/a.png\r\nfile:///tmp/b%20c.png\r\n"}
	defer delete(fake.accepts)
	ui.dnd = {user = &fake, surface = 1, start = fake_start, accept = fake_accept, receive = fake_receive, finish = fake_finish}
	_, folder := files_window(&ui)
	fd := node_get(&ui.tree, folder)
	over := [2]f32{fd.abs.x + 10, fd.abs.y + 10}
	away := [2]f32{fd.abs.x + 10, fd.abs.y - 30}

	testing.expect(t, !drag_ext_enter(&ui, away, false), "a drag without files is ignored")
	testing.expect(t, !ui.drag.active)
	testing.expect(t, drag_ext_enter(&ui, away, true), "one with files is taken")
	testing.expect(t, ui.drag.active && ui.drag.external)
	testing.expect_value(t, ui.drag.kind, "files")
	testing.expect_value(t, ui.drag.target, NODE_NONE)
	testing.expect(t, drag_ext_motion(&ui, over))
	testing.expect_value(t, ui.drag.target, folder)
	testing.expect(t, len(fake.accepts) >= 1 && fake.accepts[len(fake.accepts) - 1], "the source hears the folder would take it")
	testing.expect(t, drag_ext_drop(&ui, over))
	testing.expect(t, fake.asked == 1 && ui.drag.receiving && len(ui.msgs) == 0 && fake.finished == 0, "its paths are asked for, and nothing waits for them")
	testing.expect(t, drag_ext_data(&ui, transmute([]u8)fake.offer, true))
	testing.expect_value(t, len(ui.msgs), 1)
	if len(ui.msgs) != 1 do return
	m := ui.msgs[0]
	testing.expect_value(t, m.kind, "files")
	testing.expect_value(t, m.tag, 7)
	testing.expect_value(t, len(m.files), 2)
	testing.expect_value(t, m.files[1], "/tmp/b c.png")
	// Where it landed, inside the target: this path builds its Drop only
	// once the data comes, and must still carry `at`, or an icon view puts
	// the file in its corner. `over` is ten pixels inside the folder.
	testing.expect_value(t, m.at, [2]f32{10, 10})
	testing.expect(t, fake.finished == 1 && fake.accepted, "the platform was told the drop landed")
	testing.expect(t, !ui.drag.active, "and the drag is over")
	testing.expect_value(t, fake.started, 0)
}

@(test)
drop_from_another_app_over_nothing_is_refused :: proc(t: ^testing.T) {
	ui: Ui(DndExt_XMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	fake := Fake_Dnd{offer = "file:///tmp/a.png\r\n"}
	defer delete(fake.accepts)
	ui.dnd = {user = &fake, surface = 1, start = fake_start, accept = fake_accept, receive = fake_receive, finish = fake_finish}
	files_window(&ui)
	drag_ext_enter(&ui, {390, 290}, true)
	testing.expect(t, drag_ext_drop(&ui, {390, 290}))
	testing.expect_value(t, len(ui.msgs), 0)
	testing.expect(t, fake.finished == 1 && !fake.accepted)
	testing.expect(t, !ui.drag.active)
}

@(test)
file_drag_leaving_the_window_is_handed_to_the_compositor :: proc(t: ^testing.T) {
	ui: Ui(DndExt_XMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	fake: Fake_Dnd
	defer delete(fake.accepts)
	ui.dnd = {user = &fake, surface = 1, start = fake_start, accept = fake_accept, receive = fake_receive, finish = fake_finish}
	row_n, folder := files_window(&ui)
	rd := node_get(&ui.tree, row_n)
	start := [2]f32{rd.abs.x + 20, rd.abs.y + 10}
	ui.pointer.press_serial = 42
	pointer_button(&ui, .Left, true, start)
	pointer_move(&ui, start + {20, 0}) // past the threshold: the drag is up
	testing.expect(t, ui.drag.active && !ui.drag.compositor)
	testing.expect(t, drag_leave_window(&ui), "leaving with files: handed over")
	testing.expect(t, ui.drag.compositor)
	testing.expect_value(t, fake.started, 1)
	testing.expect_value(t, fake.items, 4)
	testing.expect_value(t, fake.uris, "file:///home/user/Files/row.txt\r\n")
	testing.expect(t, !drag_leave_window(&ui), "only once")
	// it comes back over our own folder and drops there: the in-window handler gets it, with the paths
	fd := node_get(&ui.tree, folder)
	over := [2]f32{fd.abs.x + 10, fd.abs.y + 10}
	testing.expect(t, drag_ext_enter(&ui, over, true))
	testing.expect_value(t, ui.drag.target, NODE_NONE) // the folder takes "files", not "file"
	testing.expect(t, drag_ext_drop(&ui, over))
	testing.expect_value(t, len(ui.msgs), 0)
	testing.expect(t, fake.finished == 1 && !fake.accepted)
	testing.expect(t, ui.drag.returning, "over nothing: the ghost springs back")
	testing.expect(t, drag_ext_end(&ui, false), "and the compositor's cancel ends it")
	testing.expect(t, !ui.drag.active)
}

@(test)
file_drag_dropped_elsewhere_ends_on_the_platforms_word :: proc(t: ^testing.T) {
	ui: Ui(DndExt_XMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	fake: Fake_Dnd
	defer delete(fake.accepts)
	ui.dnd = {user = &fake, surface = 1, start = fake_start, accept = fake_accept, receive = fake_receive, finish = fake_finish}
	row_n, _ := files_window(&ui)
	rd := node_get(&ui.tree, row_n)
	start := [2]f32{rd.abs.x + 20, rd.abs.y + 10}
	ui.pointer.press_serial = 42
	pointer_button(&ui, .Left, true, start)
	pointer_move(&ui, start + {20, 0})
	pointer_move(&ui, {420, 150}) // past the window's right edge: handed over on the move itself
	testing.expect(t, ui.drag.compositor)
	testing.expect_value(t, fake.started, 1)
	drag_ext_end(&ui, true)
	testing.expect(t, !ui.drag.active, "dropped in another app: over here")
	testing.expect_value(t, len(ui.msgs), 0)
	// without a serial the platform refuses and the drag stays in the window
	pointer_button(&ui, .Left, false, start)
	ui.pointer.press_serial = 0
	pointer_button(&ui, .Left, true, start)
	pointer_move(&ui, start + {20, 0})
	testing.expect(t, ui.drag.active)
	testing.expect(t, !drag_leave_window(&ui))
	testing.expect(t, ui.drag.active && !ui.drag.compositor)
}

// Another app's drop whose data never comes (ok false) lands nowhere, and
// the platform hears it was refused.
@(test)
drop_from_another_app_without_its_data_is_refused :: proc(t: ^testing.T) {
	ui: Ui(DndExt_XMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	fake: Fake_Dnd
	defer delete(fake.accepts)
	ui.dnd = {user = &fake, surface = 1, start = fake_start, accept = fake_accept, receive = fake_receive, finish = fake_finish}
	_, folder := files_window(&ui)
	fd := node_get(&ui.tree, folder)
	over := [2]f32{fd.abs.x + 10, fd.abs.y + 10}
	drag_ext_enter(&ui, over, true)
	testing.expect(t, drag_ext_drop(&ui, over))
	testing.expect(t, ui.drag.receiving)
	testing.expect(t, !drag_ext_drop(&ui, over), "released once")
	testing.expect(t, drag_ext_data(&ui, nil, false))
	testing.expect_value(t, len(ui.msgs), 0)
	testing.expect(t, fake.finished == 1 && !fake.accepted, "the platform hears it was refused")
	testing.expect(t, !ui.drag.active)
	testing.expect(t, !drag_ext_data(&ui, nil, true), "nothing waits any more")
}

// A file drag from one window of an app over another of its windows (the
// compositor carries it between them) is taken there as the same drag: its
// kind, tag, count and files, dropped as an in-app Drop with the action the
// modifiers ask for. Nothing is read from a pipe, and the window it left
// ends its drag without on_drag_out, which is for other apps.
@(test)
file_drag_between_two_windows_of_one_app :: proc(t: ^testing.T) {
	a, b: Ui(DndExt_XMsg)
	ui_init(&a)
	defer ui_destroy(&a)
	ui_init(&b)
	defer ui_destroy(&b)
	fa, fb: Fake_Dnd
	defer delete(fa.accepts)
	defer delete(fb.accepts)
	a.dnd = {user = &fa, surface = 1, start = fake_start, accept = fake_accept, receive = fake_receive, finish = fake_finish}
	b.dnd = {user = &fb, surface = 2, start = fake_start, accept = fake_accept, receive = fake_receive, finish = fake_finish}
	row_n, _ := files_window(&a, drag_out = true)
	_, folder := files_window(&b, accepts = "file")
	rd := node_get(&a.tree, row_n)
	start := [2]f32{rd.abs.x + 20, rd.abs.y + 10}
	a.pointer.press_serial = 42
	pointer_button(&a, .Left, true, start)
	pointer_move(&a, start + {20, 0})
	testing.expect(t, drag_leave_window(&a) && a.drag.compositor, "fixture: A's drag went to the compositor")

	fd := node_get(&b.tree, folder)
	over := [2]f32{fd.abs.x + 10, fd.abs.y + 10}
	testing.expect(t, drag_sibling_enter(&b, &a, {390, 290}))
	testing.expect(t, b.drag.active && b.drag.sibling && !b.drag.compositor)
	testing.expect_value(t, b.drag.kind, "file")
	testing.expect_value(t, b.drag.target, NODE_NONE)
	testing.expect(t, drag_ext_leave(&b), "it leaves B again")
	testing.expect(t, !b.drag.active && a.drag.active && a.drag.compositor, "B's view of it ends; A's drag goes on")

	drag_sibling_enter(&b, &a, {390, 290})
	testing.expect(t, drag_ext_motion(&b, over))
	testing.expect_value(t, b.drag.target, folder)
	testing.expect(t, len(fb.accepts) > 0 && fb.accepts[len(fb.accepts) - 1], "the compositor hears B would take it")
	testing.expect(t, drag_ext_drop(&b, over, .Default, {.Alt}, &a))
	testing.expect_value(t, fb.asked, 0) // answered inside the app: no pipe
	testing.expect_value(t, len(b.msgs), 1)
	if len(b.msgs) == 1 {
		m := b.msgs[0]
		testing.expect_value(t, m.kind, "file")
		testing.expect_value(t, m.tag, 7)
		testing.expect_value(t, m.count, 1)
		testing.expect(t, len(m.files) == 1 && m.files[0] == "/home/user/Files/row.txt", "A's own paths")
		testing.expect_value(t, m.action, Drop_Action.Ask) // Alt: Copy here / Move here, as within one window
	}
	testing.expect(t, fb.finished == 1 && fb.accepted, "the compositor hears it landed")
	testing.expect(t, !b.drag.active && !a.drag.active, "both windows' drags are over")
	testing.expect(t, !drag_ext_end(&a, true, .Copy), "the compositor's end then finds nothing to end")
	testing.expect_value(t, len(a.msgs), 0) // A's on_drag_out is for drops in other apps
}

} // when ODIN_TEST