package baldr

@(require) import "core:testing"
@(require) import "baldr:platform"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// An app with several windows in one process builds its messages in procs
// that cannot capture, so a handler's `tag` is how it learns which window
// a divider or a file dialog belongs to.

@(private = "file")
Tag_Msg :: struct { tag: u64, size: f32, ok: bool, why: Files_Why, paths: int }

@(test)
a_split_says_whose_divider_moved :: proc(t: ^testing.T) {
	ui: Ui(Tag_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tagged_split :: proc(ui: ^Ui(Tag_Msg), tag: u64) -> Node {
		set_viewport(&ui.tree, {600, 400})
		begin_view(ui)
		sp := split(ui, 200, on_change = proc(e: Ev(f32)) -> Tag_Msg { return {tag = e.tag, size = e.value} }, min = 100, tag = tag)
		pane(ui); end(ui)
		pane(ui); end(ui)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {600, 400})
		return sp
	}
	sp := tagged_split(&ui, 42)
	pointer_move(&ui, {203, 100})
	pointer_button(&ui, .Left, true, {203, 100})
	pointer_move(&ui, {253, 100})
	pointer_button(&ui, .Left, false, {253, 100})
	testing.expect(t, len(ui.msgs) > 0, "the drag was heard")
	for m in ui.msgs do testing.expect(t, m.tag == 42, "a drag carries the split's tag")
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1].size, f32(250))
	clear(&ui.msgs)

	tagged_split(&ui, 43) // the tag follows the build, as every handler's does
	set_focus(&ui.tree, ui.tree.splits[sp].divider, true)
	key_event(&ui, .Right, true, {})
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0].tag == 43, "a key's nudge carries it too")
}

// Fd_Log is the fake backend: the token of the dialog it last showed.
@(private = "file")
Fd_Log :: struct {
	token: u64,
	show:  bool,
}

@(test)
a_file_dialogs_answer_says_who_asked :: proc(t: ^testing.T) {
	log := Fd_Log{show = true}
	b := platform.Backend{data = &log}
	b.file_dialog = proc(b: ^platform.Backend, d: platform.File_Dialog) -> bool {
		lg := (^Fd_Log)(b.data)
		lg.token = d.token
		return lg.show
	}
	rt: Runtime(int, Tag_Msg)
	rt.backend = &b
	rt.pending_files = make(map[u64]Pending_Files(Tag_Msg))
	defer {
		delete(rt.pending_files)
		delete(rt.msgs)
	}
	files_heard :: proc(e: Ev(Files)) -> Tag_Msg { return {tag = e.tag, ok = e.value.ok, why = e.value.why, paths = len(e.value.paths)} }

	// two windows' dialogs open at once, answered in the other order
	run_cmd(&rt, open_files(Tag_Msg, files_heard, title = "Open", tag = 7))
	first := log.token
	run_cmd(&rt, save_file(Tag_Msg, files_heard, title = "Save As", name = "notes.md", tag = 9))
	second := log.token
	testing.expect(t, len(rt.msgs) == 0 && len(rt.pending_files) == 2, "nothing said until the desktop answers")
	files_done(&rt, {token = second, ok = true, paths = {"/home/user/notes.md"}, why = .Chosen})
	files_done(&rt, {token = first, ok = false, why = .Cancelled})
	testing.expect_value(t, len(rt.msgs), 2)
	testing.expect(t, rt.msgs[0].tag == 9 && rt.msgs[0].ok && rt.msgs[0].paths == 1, "the save answers the document that asked")
	testing.expect(t, rt.msgs[1].tag == 7 && !rt.msgs[1].ok && rt.msgs[1].why == .Cancelled, "the open answers its window")
	files_done(&rt, {token = first, ok = true}) // an answer twice over is not heard twice
	testing.expect_value(t, len(rt.msgs), 2)
	clear(&rt.msgs)

	// a desktop with no dialog says so at once, with the tag still on it
	log.show = false
	run_cmd(&rt, open_files(Tag_Msg, files_heard, tag = 11))
	testing.expect(t, len(rt.msgs) == 1 && rt.msgs[0].tag == 11 && rt.msgs[0].why == .Not_Shown, "not shown, and whose")
	clear(&rt.msgs)

	// no tag asked for is 0, not the toolkit's own token
	log.show = true
	run_cmd(&rt, open_files(Tag_Msg, files_heard))
	files_done(&rt, {token = log.token, ok = false, why = .Cancelled})
	testing.expect(t, len(rt.msgs) == 1 && rt.msgs[0].tag == 0)
}

} // when ODIN_TEST
