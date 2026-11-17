package baldr

@(require) import "core:fmt"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// The debug lines that say why a view was built again name the first place that asked.


@(private = "file")
DebugCauses_CMsg :: union { int }

// A rebuild remembers the first place that asked for it since the last build,
// and a later ask doesn't overwrite it; loc_text names it by file and line, or
// by the cause alone when it has no place in the code.
@(test)
a_rebuild_remembers_who_asked_first :: proc(t: ^testing.T) {
	ui: Ui(DebugCauses_CMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	first := #location()
	ask_rebuild(&ui, first)
	ask_rebuild(&ui)
	testing.expect(t, ui.needs_rebuild, "a rebuild is asked for")
	testing.expect_value(t, ui.rebuild_from.line, first.line)
	testing.expect_value(t, loc_text(ui.rebuild_from), fmt.tprintf("debug_causes_test.odin:%d", first.line))
	testing.expect_value(t, loc_text({procedure = "messages"}), "messages")
}

} // when ODIN_TEST