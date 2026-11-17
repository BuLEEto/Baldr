package baldr

import "core:os"
import "core:sys/linux"
import "core:testing"
import "baldr:platform"

// wait_watch polls the inotify fd and drains once something arrived.
@(private="file")
wait_watch :: proc(n: ^platform.Inotify, out: ^[dynamic]platform.Event) -> bool {
	fds := [1]linux.Poll_Fd{{fd = n.fd, events = {.IN}}}
	got, _ := linux.poll(fds[:], 1500)
	if got <= 0 do return false
	platform.inotify_drain(n, out, context.temp_allocator)
	return len(out) > 0
}

@(private="file")
has_watch :: proc(out: []platform.Event, token: u64, name: string, kind: platform.Watch_Kind) -> bool {
	for e in out do if w, is := e.(platform.Ev_Watch); is && w.token == token && w.name == name && w.kind == kind do return true
	return false
}

@(test)
inotify_reports_directory_entries_and_a_watched_file :: proc(t: ^testing.T) {
	os.make_directory("build")
	dir := "build/inotify_test_dir"
	os.make_directory(dir)
	os.remove("build/inotify_test_dir/note.txt")
	n: platform.Inotify
	if !platform.inotify_open(&n) {
		testing.expect(t, true, "no inotify here")
		return
	}
	defer platform.inotify_close(&n)
	out := make([dynamic]platform.Event); defer delete(out)

	testing.expect(t, platform.inotify_watch(&n, dir, 1), "a directory")
	testing.expect(t, platform.inotify_watch(&n, "build/inotify_test_dir/note.txt", 2), "a file that does not exist yet")
	testing.expect_value(t, len(n.watches), 2)
	testing.expect(t, n.watches[0].wd == n.watches[1].wd, "both watch the directory")

	_ = os.write_entire_file("build/inotify_test_dir/note.txt", transmute([]u8)string("one"))
	testing.expect(t, wait_watch(&n, &out), "the write is reported")
	testing.expect(t, has_watch(out[:], 1, "note.txt", .Created), "the directory names the entry")
	testing.expect(t, has_watch(out[:], 2, "", .Created) || has_watch(out[:], 2, "", .Modified), "the file watch reports itself")
	for e in out do if w, is := e.(platform.Ev_Watch); is do testing.expect(t, w.token != 1 || w.name != "", "no unnamed report from the directory")

	clear(&out)
	platform.inotify_unwatch(&n, 1)
	testing.expect_value(t, len(n.watches), 1)
	_ = os.write_entire_file("build/inotify_test_dir/other.txt", transmute([]u8)string("x"))
	os.remove("build/inotify_test_dir/note.txt")
	testing.expect(t, wait_watch(&n, &out), "still watching the file")
	testing.expect(t, has_watch(out[:], 2, "", .Removed), "the file's removal")
	testing.expect(t, !has_watch(out[:], 1, "other.txt", .Created), "the stopped directory watch is silent")
	os.remove("build/inotify_test_dir/other.txt")
}
