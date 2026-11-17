package baldr

@(require) import "core:fmt"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: about 9 GB without this `when`, 1 GB with it.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A scroll that follows its end while it is at its end (a reply streaming
// into a chat) and leaves the person where they scrolled.


@(private = "file")
Fe_Msg :: union { int }

// fe_build lays out `lines` of text in a scroll 200 px tall.
@(private = "file")
fe_build :: proc(ui: ^Ui(Fe_Msg), lines: int, follow: bool) -> Node {
	set_viewport(&ui.tree, {400, 200})
	begin_view(ui)
	n := scroll(ui, height = 200, follow_end = follow)
	for i in 0 ..< lines do text(ui, fmt.tprintf("line %d", i), key = u64(i + 1))
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 200})
	return n
}

@(private = "file")
fe_at_end :: proc(ui: ^Ui(Fe_Msg), n: Node) -> bool {
	st := ui.tree.scrolls[n]
	return st.offset.y >= max(st.content.y - st.viewport.y, 0) - SCROLL_END_EPS
}

@(test)
a_scroll_follows_its_end_until_the_person_scrolls_away :: proc(t: ^testing.T) {
	ui: Ui(Fe_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	// it opens at its end: a chat shows its last message, not its first
	n := fe_build(&ui, 40, true)
	testing.expect(t, fe_at_end(&ui, n) && scroll_offset(&ui.tree, n).y > 0, "opened at the end")

	// the content grows (a reply arriving): the view goes with it
	grew := fe_build(&ui, 60, true)
	testing.expect(t, grew == n && fe_at_end(&ui, n), "still at the end after the content grew")
	at_end_off := scroll_offset(&ui.tree, n).y

	// the person scrolls up to read: growth must not drag them back down
	scroll_by(&ui.tree, n, {0, -120})
	read_at := scroll_offset(&ui.tree, n).y
	testing.expect(t, read_at < at_end_off, "they moved up")
	fe_build(&ui, 80, true)
	testing.expect_value(t, scroll_offset(&ui.tree, n).y, read_at) // left exactly where they put it
	testing.expect(t, !fe_at_end(&ui, n))

	// …and once they scroll back to the end, it follows again
	scroll_by(&ui.tree, n, {0, 1e6})
	testing.expect(t, fe_at_end(&ui, n), "back at the end")
	fe_build(&ui, 100, true)
	testing.expect(t, fe_at_end(&ui, n), "following again")

	// without it, growth leaves the view alone
	ui2: Ui(Fe_Msg)
	ui_init(&ui2)
	defer ui_destroy(&ui2)
	m := fe_build(&ui2, 40, false)
	testing.expect_value(t, scroll_offset(&ui2.tree, m).y, f32(0)) // opens at the top
	fe_build(&ui2, 80, false)
	testing.expect_value(t, scroll_offset(&ui2.tree, m).y, f32(0))
}

} // when ODIN_TEST