package baldr

@(require) import "core:testing"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A text sized where it is made, as the other leaves are.


@(private = "file")
Ts_Msg :: enum { None }

@(private = "file")
facts :: proc(ui: ^Ui(Ts_Msg), value: string) -> (label, val: Node) {
	begin_view(ui)
	column(ui, width = 400, key = 1)
	row(ui, gap = .md, key = 2)
	label = text(ui, "Licence", muted = true, width = 120, align = .End, key = 3)
	val = text(ui, value, flex = 1, key = 4)
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	return
}

// A label of one width and a value taking the rest of the row, wrapping in
// it: no box around either.
@(test)
a_text_takes_a_width_and_a_share_of_the_row :: proc(t: ^testing.T) {
	ui: Ui(Ts_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	gap := ui.tree.theme.space[.md]
	label, val := facts(&ui, "Short")
	ld, vd := node_get(&ui.tree, label), node_get(&ui.tree, val)
	testing.expect_value(t, ld.rect.w, 120) // its width, whatever its words need
	testing.expect_value(t, vd.rect.w, 400 - 120 - gap) // the rest of the row
	one_line := vd.rect.h

	long := "GNU General Public License, version 3 or any later version, with the classpath exception and more words to wrap"
	label, val = facts(&ui, long)
	vd = node_get(&ui.tree, val)
	testing.expect_value(t, vd.rect.w, 400 - 120 - gap)
	testing.expect(t, vd.rect.h > one_line * 2, "it wraps at the width it was given")

	begin_view(&ui)
	column(&ui, width = 400, align = .Start, key = 1)
	narrow := text(&ui, "a b", min_width = 90, key = 2)
	wide := text(&ui, long, max_width = 150, key = 3)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 400})
	testing.expect_value(t, node_get(&ui.tree, narrow).rect.w, 90) // at least its minimum
	wd := node_get(&ui.tree, wide)
	testing.expect(t, wd.rect.w <= 150 && wd.rect.h > one_line * 3, "at most its maximum, wrapping")
}

} // when ODIN_TEST