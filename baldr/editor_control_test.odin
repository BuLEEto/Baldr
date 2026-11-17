package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: about 9 GB without this `when`, 1 GB with it.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// An app's own find bar counts as part of the editor: while focus is in it,
// the editor keeps showing its selection, so the current match looks
// selected rather than like every other highlight.


@(private = "file")
Ct_Msg :: union { int }

@(private = "file")
build :: proc(ui: ^Ui(Ct_Msg), doc: ^Document, find: ^Text, own := true) -> (ed, field: Node) {
	begin_view(ui)
	column(ui, padding = .lg)
	field = text_input(ui, find, label = "Find", width = 200)
	ed = text_area(ui, doc, label = "Notes", width = 420, height = 200)
	editor_control(ui, field, ed if own else NODE_NONE)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 600})
	return
}

// is the editor's selection painted?
@(private = "file")
selection_drawn :: proc(ui: ^Ui(Ct_Msg), ed: Node) -> bool {
	d := node_get(&ui.tree, ed)
	sel, _ := selection_pair(&ui.tree.theme) // the band a selection draws now (selection_paint.odin)
	for _, l in ui.tree.layers do for c in l.cmds {
		if r, ok := c.(Draw_Rect); ok && r.color == sel && rect_contains(d.abs, {r.rect.x + 1, r.rect.y + 1}) do return true
	}
	return false
}

@(test)
an_apps_own_find_bar_keeps_the_editors_selection_showing :: proc(t: ^testing.T) {
	ui: Ui(Ct_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make("find the match in this line")
	defer document_destroy(&doc)
	find := text_make("match", context.allocator)
	defer text_destroy(&find)
	ed, field := build(&ui, &doc, &find)
	area, _ := editor_area(&ui.tree, ed)

	editor_select(&ui, ed, Pos{0, 9}, Pos{0, 14}) // the app selects the match it found
	set_focus(&ui.tree, area, true)
	build(&ui, &doc, &find)
	testing.expect(t, selection_drawn(&ui, area), "focused: its selection shows")

	set_focus(&ui.tree, field, true) // …and typing carries on in the find field
	build(&ui, &doc, &find)
	testing.expect(t, selection_drawn(&ui, area), "focus in the app's find bar: the match still looks selected")

	// without the registration it goes
	build(&ui, &doc, &find, own = false)
	testing.expect(t, !selection_drawn(&ui, area), "a field that is not the editor's: no selection while it has focus")

	// and a control somewhere else in the window never counts
	build(&ui, &doc, &find)
	set_focus(&ui.tree, ed, true)
	build(&ui, &doc, &find)
	testing.expect(t, selection_drawn(&ui, area), "focus back in the editor")
}

} // when ODIN_TEST