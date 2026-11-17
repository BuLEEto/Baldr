package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// `max_lines` is a maximum, so it has to beat a flex. `code_editor` gives
// its area `flex = 1` when built with no height, and a flex child is handed
// its share of the parent as both its minimum and its maximum, which would
// throw a measured cap away. The cap is the node's own `Layout_Props.max_h`,
// which layout clamps into the constraints before a node measures.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Cb_Msg :: union { int }

@(private = "file")
cb_doc_text :: proc() -> string {
	return strings.repeat("SELECT a, b, c FROM t WHERE x = 1 AND y = 2 ", 46) // ~2,000 chars, one line
}

// cb_box builds a code editor with `cap` max_lines in a plain column and
// returns its area node and the window it was laid out in.
@(private = "file")
cb_box :: proc(ui: ^Ui(Cb_Msg), doc: ^Document, win: [2]f32, cap_lines: int) -> Node {
	ed: Node
	for _ in 0 ..< 5 { // settle: editor_options runs after the builder
		set_viewport(&ui.tree, win)
		begin_view(ui)
		column(ui, flex = 1, padding = .lg)
		ed = code_editor(ui, doc, label = "SQL", width = 632, key = 7)
		if a, has := ui.tree.area_of_frame[ed]; has do ed = a
		editor_options(ui, ed, wrap = true, readonly = true, max_lines = cap_lines)
		end(ui)
		end_view(ui)
		frame(&ui.tree, win)
	}
	return ed
}

// The box stops at its cap, whatever the window does. Two sizes, because a
// box that grows with the window can match a cap at one size by chance.
@(test)
a_code_box_keeps_its_line_cap_in_a_flexing_parent :: proc(t: ^testing.T) {
	text := cb_doc_text()
	defer delete(text)
	doc := document_make(text)
	defer document_destroy(&doc)

	heights: [2]f32
	for win, i in ([2][2]f32{{1361, 991}, {2560, 1400}}) {
		ui: Ui(Cb_Msg)
		ui_init(&ui)
		defer ui_destroy(&ui)
		ed := cb_box(&ui, &doc, win, 16)
		d := node_get(&ui.tree, ed)
		s := &ui.tree.areas[ed]
		heights[i] = d.abs.h
		lines := d.abs.h / s.line_h
		testing.expectf(t, lines < 18, "%.0f px window: %.1f lines drawn, cap is 16", win.y, lines)
		testing.expectf(t, d.abs.h < win.y * 0.6, "%.0f px window: the box filled it (%.0f px)", win.y, d.abs.h)
	}
	testing.expectf(t, heights[0] == heights[1],
		"the cap does not follow the window (%.0f px in a 991 px window, %.0f in a 1400)", heights[0], heights[1])
}

// The first frame counts. `editor_options` runs after the builder has set
// the node's layout and marks layout dirty without asking for a rebuild, so
// a cap read only where the builder runs would leave a view built once
// stretched for as long as it is open. One build, one layout, capped.
@(test)
a_code_box_is_capped_on_the_frame_it_is_built :: proc(t: ^testing.T) {
	text := cb_doc_text()
	defer delete(text)
	doc := document_make(text)
	defer document_destroy(&doc)
	ui: Ui(Cb_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	win := [2]f32{1361, 991}
	set_viewport(&ui.tree, win)
	begin_view(&ui)
	column(&ui, flex = 1, padding = .lg)
	ed := code_editor(&ui, &doc, label = "SQL", width = 632, key = 7)
	if a, has := ui.tree.area_of_frame[ed]; has do ed = a
	editor_options(&ui, ed, wrap = true, readonly = true, max_lines = 16)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, win)

	d := node_get(&ui.tree, ed)
	s := &ui.tree.areas[ed]
	lines := d.abs.h / s.line_h
	testing.expectf(t, lines < 18, "built once: %.1f lines drawn, cap is 16 (%.0f px)", lines, d.abs.h)
}

// Without a cap it still fills what it is given — the reason the flex is
// there, and the thing a careless fix would break.
@(test)
a_code_box_with_no_cap_still_fills_its_parent :: proc(t: ^testing.T) {
	text := cb_doc_text()
	defer delete(text)
	doc := document_make(text)
	defer document_destroy(&doc)
	small: f32
	for win, i in ([2][2]f32{{1361, 991}, {2560, 1400}}) {
		ui: Ui(Cb_Msg)
		ui_init(&ui)
		defer ui_destroy(&ui)
		ed := cb_box(&ui, &doc, win, 0) // no cap
		d := node_get(&ui.tree, ed)
		testing.expectf(t, d.abs.h > win.y * 0.5, "%.0f px window: an uncapped editor fills its pane (%.0f px)", win.y, d.abs.h)
		if i == 0 { small = d.abs.h } else {
			testing.expectf(t, d.abs.h > small, "and grows with it (%.0f then %.0f)", small, d.abs.h)
		}
	}
}

}
