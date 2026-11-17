package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

Fc_Msg :: struct {
	paths: []string,
	ok:    bool,
	token: u64,
}

@(private = "file")
on_files_msg :: proc(e: Ev(Files)) -> Fc_Msg { return {paths = e.value.paths, ok = e.value.ok, token = e.tag} }

// open_files / save_file describe the dialog the runtime asks the desktop
// for; files_deliver turns the outcome into the app's message either way
// a handler is given.
@(test)
file_commands_describe_dialogs_and_deliver_outcomes :: proc(t: ^testing.T) {
	filters := []File_Filter{{name = "Images", patterns = {"*.png", "*.jpg"}}}
	c := open_files(Fc_Msg, on_files_msg, title = "Choose an image", multiple = true, filters = filters, folder = "/tmp")
	testing.expect_value(t, c.kind, Cmd_Kind.Open_Files)
	testing.expect(t, !c.dialog.save && c.dialog.multiple && !c.dialog.directory && c.dialog.title == "Choose an image" && c.dialog.current_folder == "/tmp" && len(c.dialog.filters) == 1)
	s := save_file(Fc_Msg, on_files_msg, title = "Save as", name = "notes.md")
	testing.expect(t, s.kind == .Save_File && s.dialog.save && s.dialog.current_name == "notes.md")
	d := open_files(Fc_Msg, on_files_msg, directory = true)
	testing.expect(t, d.dialog.directory)
	testing.expect_value(t, quit(Fc_Msg).kind, Cmd_Kind.Quit)

	out := make([dynamic]Fc_Msg, context.temp_allocator)
	paths := []string{"/home/user/a.png", "/home/user/b.png"}
	testing.expect(t, files_deliver(c.on_files, Files{paths = paths, ok = true}, 7, &out))
	testing.expect_value(t, len(out), 1)
	testing.expect(t, out[0].ok && out[0].token == 7 && len(out[0].paths) == 2 && out[0].paths[1] == "/home/user/b.png")
	testing.expect(t, files_deliver(c.on_files, Files{ok = false}, 8, &out))
	testing.expect(t, !out[1].ok && out[1].token == 8 && len(out[1].paths) == 0, "a cancel arrives as ok = false")
	plain := open_files(Fc_Msg, Fc_Msg{token = 99}) // a plain message ignores the outcome
	testing.expect(t, files_deliver(plain.on_files, Files{ok = true}, 1, &out))
	testing.expect_value(t, out[2].token, u64(99))
	none: Handler(Fc_Msg, Files)
	testing.expect(t, !files_deliver(none, Files{ok = true}, 2, &out), "nil delivers nothing")
	testing.expect_value(t, len(out), 3)
	// the command copies what it was given: a caller's literals may go away
	pats := []string{"*.txt"}
	own := []File_Filter{{name = "Text", patterns = pats}}
	title := strings.clone("Pick", context.temp_allocator)
	c2 := open_files(Fc_Msg, on_files_msg, title = title, filters = own)
	pats[0] = "changed"
	own[0].name = "changed"
	(transmute([]u8)title)[0] = 'X'
	testing.expect(t, c2.dialog.filters[0].patterns[0] == "*.txt" && c2.dialog.filters[0].name == "Text" && c2.dialog.title == "Pick", "the command keeps its own copy")
}

} // when ODIN_TEST