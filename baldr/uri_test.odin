package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(test)
uri_list_round_trips_paths :: proc(t: ^testing.T) {
	paths := []string{"/home/user/My Photos/été.png", "/tmp/a#b%c.txt", "relative/x"}
	text := uri_list_encode(paths, context.temp_allocator)
	testing.expect_value(t, text, "file:///home/user/My%20Photos/%C3%A9t%C3%A9.png\r\nfile:///tmp/a%23b%25c.txt\r\nfile:///relative/x\r\n")
	back := uri_list_decode(text, context.temp_allocator)
	testing.expect_value(t, len(back), 3)
	testing.expect_value(t, back[0], "/home/user/My Photos/été.png")
	testing.expect_value(t, back[1], "/tmp/a#b%c.txt")
	testing.expect_value(t, back[2], "/relative/x")
}

@(test)
uri_list_decode_skips_comments_hosts_and_other_schemes :: proc(t: ^testing.T) {
	got := uri_list_decode("# from thunar\r\nfile://localhost/etc/hosts\nhttps://example.org/x\nfile:/var/log\n\n", context.temp_allocator)
	testing.expect_value(t, len(got), 2)
	testing.expect_value(t, got[0], "/etc/hosts")
	testing.expect_value(t, got[1], "/var/log")

	// another machine's file is not this machine's file of the same path,
	// and a relative path or a hidden NUL is not a file at all
	far := uri_list_decode("file://fileserver/etc/passwd\r\nfile:relative/x\r\nfile:///tmp/a%00.png\r\nfile://LOCALHOST/ok\r\n", context.temp_allocator)
	testing.expect_value(t, len(far), 1)
	if len(far) == 1 do testing.expect_value(t, far[0], "/ok")
}

} // when ODIN_TEST