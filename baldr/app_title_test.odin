package baldr

@(require) import "core:fmt"
@(require) import "core:mem"
@(require) import "core:strings"
@(require) import "core:unicode/utf8"
@(require) import "core:testing"

// The runtime owns its copy of the app's title and id. The natural way to
// write an App is `title = fmt.tprintf("Theme lab — %s", th.name)` in the
// struct literal, which is temp memory freed before the first frame, and
// the title is re-applied on every surface sync. On macOS an NSString built
// from bytes that are no longer valid UTF-8 is nil, and `setTitle:` raises
// on nil, which aborts the process.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
At_Msg :: union { int }

// The runtime takes its own copy, so an App built with temp strings — the
// obvious way to write one — survives the scratch being reset.
@(test)
the_runtime_owns_the_apps_title_and_id :: proc(t: ^testing.T) {
	rt: Runtime(int, At_Msg)
	// exactly what an app writes, and exactly where it goes wrong
	rt.app.title = fmt.tprintf("Theme lab — %s", "Baldr Dark")
	rt.app.app_id = fmt.tprintf("baldr.%s", "theme_lab")
	was_title, was_id := raw_data(rt.app.title), raw_data(rt.app.app_id)

	app_own_strings(&rt)
	defer app_free_strings(&rt)
	testing.expect(t, raw_data(rt.app.title) != was_title, "the title was copied out of the caller's memory")
	testing.expect(t, raw_data(rt.app.app_id) != was_id, "and so was the id")

	// the frame's scratch goes, as it does before the first surface sync
	free_all(context.temp_allocator)

	testing.expect_value(t, rt.app.title, "Theme lab — Baldr Dark")
	testing.expect_value(t, rt.app.app_id, "baldr.theme_lab")
	// …and it is still valid UTF-8, which is the property macOS aborts over
	testing.expect(t, utf8.valid_string(rt.app.title), "a title built from freed bytes is not")
}

// An empty or missing title is not special-cased into something odd: it
// stays empty, and the backend is the one that decides what to show.
@(test)
an_app_with_no_title_owns_an_empty_one :: proc(t: ^testing.T) {
	rt: Runtime(int, At_Msg)
	app_own_strings(&rt)
	defer app_free_strings(&rt)
	testing.expect_value(t, rt.app.title, "")
	testing.expect_value(t, rt.app.app_id, "")
	testing.expect(t, utf8.valid_string(rt.app.title))
}

// A string whose bytes have been reused is not valid UTF-8, which the Cocoa
// backend cannot turn into an NSString.
@(test)
freed_scratch_really_does_stop_being_utf8 :: proc(t: ^testing.T) {
	buf: [64]u8
	arena: mem.Arena
	mem.arena_init(&arena, buf[:])
	scratch := mem.arena_allocator(&arena)

	borrowed, _ := strings.clone("Theme lab — Baldr Dark", scratch) // an em dash: multi-byte
	testing.expect(t, utf8.valid_string(borrowed))

	free_all(scratch)
	other, _ := strings.clone("\xff\xfe\xff\xfe\xff\xfe\xff\xfe\xff\xfe\xff\xfe\xff\xfe", scratch) // whatever lands there next
	_ = other
	testing.expect(t, !utf8.valid_string(borrowed),
		"the title the toolkit was still holding is no longer text at all")
}

}
