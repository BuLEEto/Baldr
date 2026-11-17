package baldr

@(require) import "core:testing"

// See canvas_test.odin for why test files sit behind this `when`.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// While a build is pending nothing may read an editor's Document: `update`
// may have freed it (a blank tab replaced by a file that arrived), and
// `ime_sync`, which runs after the update and before the next view, would
// read it through the area node the last view built.
//
// Here the area is left pointing at a Document that no longer has the
// caret's line, which is what a freed and reused one looks like: reading it
// indexes out of range and the test dies. After the build the input method
// is told about the new one.

@(private = "file")
Bp_Msg :: union { int }

@(private = "file")
Bp_Spy :: struct { calls: int }

@(private = "file")
bp_build :: proc(ui: ^Ui(Bp_Msg), doc: ^Document) -> Node {
	begin_view(ui)
	column(ui, padding = .lg)
	ed := text_area(ui, doc, label = "Notes", width = 320, height = 120, key = 1)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 200})
	return ed
}

@(test)
nothing_reads_an_editors_document_while_a_build_is_pending :: proc(t: ^testing.T) {
	ui: Ui(Bp_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	spy: Bp_Spy
	ui.tree.ime.hook = {
		user = &spy,
		surface = 1,
		set = proc(user: rawptr, surface: u32, info: Ime_Info) { (^Bp_Spy)(user).calls += 1 },
	}
	old := document_make("one\ntwo\nthree")
	defer document_destroy(&old)
	ed := bp_build(&ui, &old)
	set_focus(&ui.tree, ed, false)
	s := &ui.tree.areas[ed]
	s.caret = {block = 2, off = 3}
	s.anchor = s.caret
	ui_after_events(&ui, 0) // told once about the field as it is
	told := spy.calls

	// update ran: the app took the old document away. The area still points
	// at something with no line 2 until the view runs again.
	gone := document_make("")
	defer document_destroy(&gone)
	s.doc = &gone
	ui.build_pending = true
	ui_after_events(&ui, 0) // must not read it: block 2 of `gone` would be out of range
	testing.expect_value(t, spy.calls, told)

	// The view runs and gives the area what it shows now; then the input
	// method hears about it.
	bp_build(&ui, &gone)
	s = &ui.tree.areas[ed]
	s.caret, s.anchor = {}, {}
	ui_after_build(&ui)
	testing.expect(t, !ui.build_pending, "the build answered it")
	testing.expectf(t, spy.calls == told + 1, "and the input method was told about the field after the build (%d calls, %d before)", spy.calls, told)
}

}
