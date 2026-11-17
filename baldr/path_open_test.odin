package baldr

@(require) import "core:os"
@(require) import "core:strings"
@(require) import "core:testing"
@(require) import "baldr:platform"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// `open_url` takes URLs out of content and allows three schemes;
// `open_path` takes a path the app itself made, so what is checked is not
// where it came from but what it *is*. The point of the checks is that a
// mistake upstream cannot turn "open my spreadsheet" into "run this".

@(private = "file")
tmp_file :: proc(name: string, exec := false) -> string {
	_ = os.make_directory("build")
	path := strings.concatenate({"build/", name}, context.temp_allocator)
	_ = os.write_entire_file(path, transmute([]u8)string("x"))
	when ODIN_OS != .Windows {
		mode := os.Permissions{.Read_User, .Write_User}
		if exec do mode += {.Execute_User}
		_ = os.chmod(path, mode)
	}
	return path
}

@(test)
a_path_is_opened_when_it_is_a_plain_file_that_exists :: proc(t: ^testing.T) {
	f := tmp_file("open_me.txt")
	testing.expect(t, path_openable(f), "a plain file the app made")
	testing.expect(t, path_openable(f, dir_ok = true), "…and reveal takes it too")

	testing.expect(t, !path_openable("build/there-is-no-such-file.txt"), "a path that is not there")
	testing.expect(t, !path_openable(""), "nothing")
	testing.expect(t, !path_openable(strings.repeat("a", PATH_MAX_LEN + 1, context.temp_allocator)), "a runaway string")
	testing.expect(t, !path_openable("build/open\x00me.txt"), "a NUL in it")
}

// Pot_Spy stands in for a desktop: it records what the toolkit handed it.
// Without one, a refused path and a path with nowhere to go both answer
// `ok = false`, so the two cannot be told apart.
@(private = "file")
Pot_Spy :: struct {
	asked:  bool,
	path:   string,
	reveal: bool,
}

@(private = "file")
pot_spy_open :: proc(b: ^platform.Backend, path: string, reveal: bool, token: u64) -> bool {
	spy := (^Pot_Spy)(b.data)
	spy.asked, spy.path, spy.reveal = true, path, reveal
	return true
}

// A folder is a thing to open as well as a thing to reveal, and every
// backend can open one: ShellExecuteW "open", the portal's OpenFile on a
// directory descriptor, xdg-open on the path.
@(test)
a_folder_is_opened_as_itself_and_revealed_in_its_parent :: proc(t: ^testing.T) {
	Msg :: union { Path_Opened }
	_ = os.make_directory("build")

	reached :: proc(t: ^testing.T, kind: Cmd_Kind) -> Pot_Spy {
		spy: Pot_Spy
		b: platform.Backend
		b.data = &spy
		b.open_path = pot_spy_open
		rt: Runtime(int, Msg)
		rt.backend = &b
		rt.msgs = make([dynamic]Msg)
		defer delete(rt.msgs)
		rt.pending_paths = make(map[u64]Path_Ask(Msg))
		defer {
			for _, ask in rt.pending_paths do delete(ask.path)
			delete(rt.pending_paths)
		}
		path_open_start(&rt, Cmd(Msg){kind = kind, path = "build"})
		return spy
	}

	o := reached(t, .Open_Path)
	testing.expect(t, o.asked, "a folder reaches the desktop to be opened — it used to be refused here")
	testing.expect(t, !o.reveal, "…as an open, so the backend opens it as itself")
	testing.expect_value(t, o.path, "build")

	r := reached(t, .Reveal_Path)
	testing.expect(t, r.asked && r.reveal, "and a folder still reveals, which is the other thing")

	// The narrower question an app can still ask for itself.
	testing.expect(t, path_openable("build", dir_ok = true), "a folder is openable when folders are allowed")
	testing.expect(t, !path_openable("build"), "…and not when they are not")
}

// An executable is refused, whatever it is called: handing a handler an
// executable or a launcher is how "open the spreadsheet I exported" becomes
// "run this", and an exported file has no reason to carry an execute bit.
@(test)
an_executable_is_never_opened :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows {
		x := tmp_file("run_me.sh", exec = true)
		testing.expect(t, !path_openable(x), "not an executable")
		testing.expect(t, !path_openable(x, dir_ok = true), "…not for reveal either")
	}
	d := tmp_file("launcher.desktop")
	testing.expect(t, !path_openable(d), "nor a launcher, whatever its bits say")
}

// A refused path answers at once rather than silently doing nothing, so an
// app can tell the person where the file is instead.
@(test)
a_refused_path_comes_back_as_not_opened :: proc(t: ^testing.T) {
	Msg :: union { Path_Opened }
	told :: proc(e: Ev(Path_Opened)) -> Msg { return e.value }

	rt: Runtime(int, Msg)
	rt.msgs = make([dynamic]Msg)
	defer delete(rt.msgs)
	// No backend at all: the same path an app takes when the desktop has no
	// way to open anything.
	path_open_start(&rt, Cmd(Msg){kind = .Open_Path, path = "build/there-is-no-such-file.txt", on_path = told})
	testing.expect_value(t, len(rt.msgs), 1)
	got, ok := rt.msgs[0].(Path_Opened)
	testing.expect(t, ok && !got.ok, "answered, and answered no")
	testing.expect_value(t, got.path, "build/there-is-no-such-file.txt")
}

// The commands carry what the runtime needs and nothing else.
@(test)
open_and_reveal_are_two_commands_over_one_path :: proc(t: ^testing.T) {
	Msg :: union { Path_Opened }
	o := open_path(Msg, "/tmp/sheet.xlsx")
	r := reveal_path(Msg, "/tmp/sheet.xlsx")
	testing.expect_value(t, o.kind, Cmd_Kind.Open_Path)
	testing.expect_value(t, r.kind, Cmd_Kind.Reveal_Path)
	testing.expect_value(t, o.path, "/tmp/sheet.xlsx")
	testing.expect_value(t, r.path, "/tmp/sheet.xlsx")
}

}
