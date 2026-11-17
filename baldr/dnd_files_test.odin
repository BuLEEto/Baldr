package baldr

@(require) import "base:runtime"
@(require) import "core:sync"
@(require) import "core:testing"
@(require) import "core:time"
@(require) import "baldr:platform"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Dnd_Files_Msg :: struct { files: []string, action: Drop_Action }

// A fake platform that keeps a drag's forms the way a backend does: a
// reference of its own on each form made later, given back when the drag
// is over.
@(private = "file")
Dnd_Files_Platform :: struct {
	started: int,
	items:   [dynamic]Clip_Item,
}

@(private = "file")
dnd_files_start :: proc(user: rawptr, surface: u32, items: []Clip_Item, serial: u32, icon: Drag_Icon) -> bool {
	f := (^Dnd_Files_Platform)(user)
	f.started += 1
	clear(&f.items)
	for it in items {
		append(&f.items, it)
		if it.later != nil do platform.clip_later_retain(it.later)
	}
	return serial != 0
}

@(private = "file")
dnd_files_platform_drop :: proc(f: ^Dnd_Files_Platform) {
	for it in f.items do if it.later != nil do platform.clip_later_release(it.later)
	clear(&f.items)
}

// What the program on the other end would read for one form: the bytes, or
// the wait for them, exactly as the thread writing its pipe does.
@(private = "file")
dnd_files_form :: proc(f: ^Dnd_Files_Platform, mime: string) -> string {
	for it in f.items {
		if it.mime != mime do continue
		if it.later == nil do return string(it.data)
		return string(it.later.wait(it.later))
	}
	return "\x00 no such form"
}

@(private = "file")
Dnd_Files_Source :: struct {
	inside:  []string,     // the source's own names, for a drop in the app
	outside: []string,     // real paths, for a drag that leaves
	promise: ^Files_Later, // nil: the paths outside are there already
	asked:   int,          // times files_out was asked
}

@(private = "file")
dnd_files_inside :: proc(user: rawptr, tag: u64, count: int, allocator: runtime.Allocator) -> []string {
	s := (^Dnd_Files_Source)(user)
	out := make([]string, len(s.inside), allocator)
	copy(out, s.inside)
	return out
}

@(private = "file")
dnd_files_outside :: proc(user: rawptr, tag: u64, count: int, allocator: runtime.Allocator) -> ([]string, ^Files_Later) {
	s := (^Dnd_Files_Source)(user)
	s.asked += 1
	out := make([]string, len(s.outside), allocator)
	copy(out, s.outside)
	return out, s.promise
}

// A window with one draggable row and a folder that takes it, the row
// answering with its own names inside the app and real paths on the way
// out (either of the two can be left off).
@(private = "file")
dnd_files_window :: proc(ui: ^Ui(Dnd_Files_Msg), src: ^Dnd_Files_Source, inside := true, outside := true) -> (row_n, folder: Node) {
	set_viewport(&ui.tree, {400, 300})
	begin_view(ui)
	column(ui, gap = .md, padding = .md)
	row_n = row(ui, height = 30, width = 200)
	text(ui, "beach.jpg")
	end(ui)
	draggable(ui, row_n, "file", tag = 1, user = src,
		files = dnd_files_inside if inside else nil,
		files_out = dnd_files_outside if outside else nil,
		on_drag_out = proc(e: Ev(Drop)) -> Dnd_Files_Msg { return {files = e.value.files, action = e.value.action} })
	folder = row(ui, height = 60, width = 200)
	text(ui, "Pictures")
	end(ui)
	drop_target(ui, folder, proc(e: Ev(Drop)) -> Dnd_Files_Msg { return {files = e.value.files, action = e.value.action} }, accepts = "file", tag = 7)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 300})
	return
}

// Lifts the row into a drag, ready to leave.
@(private = "file")
dnd_files_lift :: proc(ui: ^Ui(Dnd_Files_Msg), row_n: Node) {
	rd := node_get(&ui.tree, row_n)
	start := [2]f32{rd.abs.x + 20, rd.abs.y + 10}
	ui.pointer.press_serial = 42
	pointer_button(ui, .Left, true, start)
	pointer_move(ui, start + {20, 0}) // past the threshold: the drag is up
}

// The two answers are for two different questions: what leaves the window
// goes out as paths another program can open, and a drop inside the app
// still gets the names the source uses for itself.
@(test)
a_drag_that_leaves_is_asked_for_the_way_out :: proc(t: ^testing.T) {
	ui: Ui(Dnd_Files_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	fake: Dnd_Files_Platform
	defer delete(fake.items)
	ui.dnd = {user = &fake, surface = 1, start = dnd_files_start}
	src := Dnd_Files_Source{inside = {"archive:/home/u/Photos.zip!/2019/beach.jpg"}, outside = {"/tmp/cache/beach.jpg"}}
	row_n, folder := dnd_files_window(&ui, &src)

	dnd_files_lift(&ui, row_n)
	testing.expect(t, drag_leave_window(&ui), "it left with the paths it had")
	testing.expect_value(t, src.asked, 1)
	testing.expect_value(t, dnd_files_form(&fake, MIME_URI_LIST), "file:///tmp/cache/beach.jpg\r\n")

	// …and back in over our own folder: that drop is the app's own again
	fd := node_get(&ui.tree, folder)
	over := [2]f32{fd.abs.x + 10, fd.abs.y + 10}
	testing.expect(t, drag_ext_enter(&ui, over, true))
	testing.expect(t, drag_ext_drop(&ui, over))
	testing.expect_value(t, len(ui.msgs), 1)
	m := ui.msgs[0]
	testing.expect_value(t, len(m.files), 1)
	testing.expect_value(t, m.files[0], "archive:/home/u/Photos.zip!/2019/beach.jpg")
}

// A source with no `files_out` leaves with what its `files` answers.
@(test)
without_a_way_out_a_drag_leaves_with_its_own_files :: proc(t: ^testing.T) {
	ui: Ui(Dnd_Files_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	fake: Dnd_Files_Platform
	defer delete(fake.items)
	ui.dnd = {user = &fake, surface = 1, start = dnd_files_start}
	src := Dnd_Files_Source{inside = {"/home/u/beach.jpg"}}
	row_n, _ := dnd_files_window(&ui, &src, outside = false)
	dnd_files_lift(&ui, row_n)
	testing.expect(t, drag_leave_window(&ui))
	testing.expect_value(t, src.asked, 0)
	testing.expect_value(t, dnd_files_form(&fake, MIME_URI_LIST), "file:///home/u/beach.jpg\r\n")
}

// The paths go out, but not until the source says the files behind them
// exist: every form waits, and none of them carries bytes meanwhile.
@(test)
the_forms_wait_for_the_files_to_be_made :: proc(t: ^testing.T) {
	ui: Ui(Dnd_Files_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	fake: Dnd_Files_Platform
	defer delete(fake.items)
	ui.dnd = {user = &fake, surface = 1, start = dnd_files_start}
	promise := files_later_new()
	defer files_later_release(promise)
	src := Dnd_Files_Source{outside = {"/tmp/cache/beach.jpg"}, promise = promise}
	row_n, _ := dnd_files_window(&ui, &src, inside = false)

	dnd_files_lift(&ui, row_n)
	testing.expect(t, drag_leave_window(&ui), "a drag with only a way out still leaves")
	testing.expect_value(t, len(fake.items), 4)
	for it in fake.items {
		testing.expect(t, it.later != nil, "every form waits for the files")
		testing.expect_value(t, len(it.data), 0)
	}
	testing.expect_value(t, promise.refs, 1 + 4) // the source's, and one per form

	files_later_ready(promise)
	testing.expect_value(t, dnd_files_form(&fake, MIME_URI_LIST), "file:///tmp/cache/beach.jpg\r\n")
	testing.expect_value(t, dnd_files_form(&fake, MIME_GNOME_FILES), "copy\nfile:///tmp/cache/beach.jpg")
	testing.expect_value(t, dnd_files_form(&fake, MIME_TEXT_UTF8), "/tmp/cache/beach.jpg")

	dnd_files_platform_drop(&fake)
	testing.expect_value(t, promise.refs, 1) // the forms went, the source's reference did not
}

// Giving up is an answer: the forms go out empty and the program that
// asked for them reads a drop of nothing, rather than waiting for ever.
@(test)
a_source_that_gives_up_hands_over_nothing :: proc(t: ^testing.T) {
	ui: Ui(Dnd_Files_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	fake: Dnd_Files_Platform
	defer delete(fake.items)
	ui.dnd = {user = &fake, surface = 1, start = dnd_files_start}
	promise := files_later_new()
	defer files_later_release(promise)
	defer dnd_files_platform_drop(&fake)
	src := Dnd_Files_Source{outside = {"/tmp/cache/beach.jpg"}, promise = promise}
	row_n, _ := dnd_files_window(&ui, &src, inside = false)
	dnd_files_lift(&ui, row_n)
	testing.expect(t, drag_leave_window(&ui))

	files_later_failed(promise)
	testing.expect_value(t, dnd_files_form(&fake, MIME_URI_LIST), "")
	testing.expect_value(t, dnd_files_form(&fake, MIME_TEXT), "")

	files_later_ready(promise) // too late to change its mind
	testing.expect_value(t, dnd_files_form(&fake, MIME_URI_LIST), "")
}

// A source that never answers at all is a bounded wait, not a hang: the
// clock starts when the drag leaves, and the forms then go out empty.
@(test)
the_wait_for_the_files_has_an_end :: proc(t: ^testing.T) {
	ui: Ui(Dnd_Files_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	fake: Dnd_Files_Platform
	defer delete(fake.items)
	ui.dnd = {user = &fake, surface = 1, start = dnd_files_start}
	promise := files_later_new()
	defer files_later_release(promise)
	defer dnd_files_platform_drop(&fake)
	src := Dnd_Files_Source{outside = {"/tmp/cache/beach.jpg"}, promise = promise}
	row_n, _ := dnd_files_window(&ui, &src, inside = false)
	dnd_files_lift(&ui, row_n)
	testing.expect(t, drag_leave_window(&ui))

	if !testing.expect(t, sync.atomic_load(&promise.timed) == 1, "the drag leaving started the clock") do return
	settled, _ := files_later_settled(promise)
	testing.expect(t, !settled, "and it has not run out yet")

	promise.deadline = time.tick_now() // as if the minute had passed
	testing.expect(t, !files_later_wait(promise), "out of time: no files")
	testing.expect_value(t, dnd_files_form(&fake, MIME_URI_LIST), "")
}

// Where the files went is asked the same way they left, so a source whose
// only answer is the way out still hears what the other program did with
// them — and being asked twice costs it nothing.
@(test)
where_the_files_went_is_asked_the_way_they_left :: proc(t: ^testing.T) {
	ui: Ui(Dnd_Files_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	fake: Dnd_Files_Platform
	defer delete(fake.items)
	ui.dnd = {user = &fake, surface = 1, start = dnd_files_start}
	promise := files_later_new()
	defer files_later_release(promise)
	defer dnd_files_platform_drop(&fake)
	src := Dnd_Files_Source{outside = {"/tmp/cache/beach.jpg"}, promise = promise}
	row_n, _ := dnd_files_window(&ui, &src, inside = false)
	dnd_files_lift(&ui, row_n)
	testing.expect(t, drag_leave_window(&ui))
	testing.expect_value(t, promise.refs, 1 + 4)

	testing.expect(t, drag_ext_end(&ui, true, .Move), "the other app took it")
	testing.expect_value(t, src.asked, 2)
	testing.expect_value(t, promise.refs, 1 + 4) // asking for the paths takes no reference
	testing.expect_value(t, len(ui.msgs), 1)
	m := ui.msgs[0]
	testing.expect_value(t, m.action, Drop_Action.Move)
	testing.expect_value(t, len(m.files), 1)
	testing.expect_value(t, m.files[0], "/tmp/cache/beach.jpg")
}

}
