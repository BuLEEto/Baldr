#+build linux, darwin
package baldr

@(require) import "core:fmt"
@(require) import "core:os"
@(require) import "core:strings"
@(require) import "core:sys/posix"
@(require) import "core:testing"
@(require) import "core:time"

// Where the single-instance socket lives on Linux and macOS. The round
// trip itself, on every platform, is instance_handover_test.odin.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// The id is the app's own and may hold anything. A path separator in it
// would otherwise put the socket somewhere else entirely — or nowhere.
@(test)
an_app_id_with_a_separator_in_it_stays_in_one_directory :: proc(t: ^testing.T) {
	p := instance_path("../../etc/passwd", context.temp_allocator)
	testing.expect(t, len(p) > 0, "it is somewhere")
	bad := 0
	for i in 0 ..< len(p) {
		if p[i] == '/' do bad += 1
	}
	// Only the separators of the directory it belongs in, and none from
	// the id: the name itself has them replaced.
	dir := instance_path("x", context.temp_allocator)
	want := 0
	for i in 0 ..< len(dir) {
		if dir[i] == '/' do want += 1
	}
	testing.expectf(t, bad == want, "the id put %d extra separators in the path %q", bad - want, p)
}

// A folder anyone can write to (/tmp, where a desktop sets no run-time
// directory) is never where the socket goes: another user could make it
// first and be handed every launch's files. A folder of this user's own,
// closed to everyone else, is made inside it.
@(test)
the_instance_socket_is_kept_where_only_this_user_can_reach :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "baldr-inst-*", context.temp_allocator)
	if !testing.expect(t, err == nil, "a temporary folder") do return
	defer os.remove_all(dir)
	posix.chmod(strings.clone_to_cstring(dir, context.temp_allocator), posix.mode_t{.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IWGRP, .IXGRP, .IROTH, .IWOTH, .IXOTH})
	p := instance_path_in(dir, "org.example.app", context.temp_allocator)
	own := fmt.tprintf("%s/baldr-%d/", dir, posix.geteuid())
	testing.expectf(t, strings.has_prefix(p, own), "in a folder of its own: %q", p)
	st: posix.stat_t
	posix.lstat(strings.clone_to_cstring(own[:len(own) - 1], context.temp_allocator), &st)
	testing.expect(t, st.st_mode & (posix.S_IRWXG + posix.S_IRWXO) == {}, "which nobody else may enter")

	// a private folder is used as it is
	posix.chmod(strings.clone_to_cstring(dir, context.temp_allocator), posix.S_IRWXU)
	q := instance_path_in(dir, "org.example.app", context.temp_allocator)
	testing.expectf(t, q == fmt.tprintf("%s/baldr-org.example.app.sock", dir), "straight inside a private one: %q", q)
}

} // when ODIN_TEST
