package baldr

@(require) import "core:os"
@(require) import "core:path/filepath"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// open_path opens documents. A file a desktop would run instead (a program,
// a script, a shortcut, a launcher) is refused by its kind, in any case, even
// without an execute bit, which Windows never reports.
@(test)
open_path_refuses_what_a_desktop_would_run :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "baldr-open-*", context.temp_allocator)
	if !testing.expect(t, derr == nil, "a temporary folder") do return
	defer os.remove_all(dir)
	make_file :: proc(dir, name: string) -> string {
		p, _ := filepath.join({dir, name}, context.temp_allocator)
		_ = os.write_entire_file(p, transmute([]u8)string("x"))
		return p
	}
	for name in ([]string{"report.pdf.exe", "REPORT.EXE", "run.bat", "link.lnk", "page.hta", "tool.jar", "app.desktop", "App.Desktop", "go.sh", "setup.msi", "open.command"}) {
		testing.expectf(t, !path_openable(make_file(dir, name)), "%s is refused", name)
	}
	for name in ([]string{"report.pdf", "photo.JPG", "notes.txt", "song.flac", "archive.tar.gz"}) {
		testing.expectf(t, path_openable(make_file(dir, name)), "%s opens", name)
	}
	// a folder opens as itself, except on macOS one the Finder would launch
	plain, _ := filepath.join({dir, "Photos"}, context.temp_allocator)
	bundle, _ := filepath.join({dir, "Invoice.app"}, context.temp_allocator)
	os.make_directory(plain)
	os.make_directory(bundle)
	testing.expect(t, path_openable(plain, dir_ok = true), "a folder opens")
	when ODIN_OS == .Darwin {
		testing.expect(t, !path_openable(bundle, dir_ok = true), "an application bundle is refused")
	}
}

} // when ODIN_TEST
