package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A press on something that cannot take focus, such as a canvas, takes the
// focus off the control that had it. Otherwise a tool button clicked to pick
// a tool keeps the keys, and Enter or Space press it again instead of
// reaching the app's own shortcuts.

@(private = "file")
Fclick_Msg :: union { int }

// fc_view is a tool button beside a canvas that takes no focus.
@(private = "file")
fc_view :: proc(ui: ^Ui(Fclick_Msg), focus_on_click := true) -> (tool, canvas, label: Node) {
	begin_view(ui)
	column(ui, padding = .md)
	tool = button(ui, "Move", Fclick_Msg(1), key = 1)
	if !focus_on_click do button_options(ui, tool, focus_on_click = false)
	canvas = box(ui, width = 200, height = 120, key = 2)
	label = text(ui, "not a control", key = 3)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 400})
	return
}

@(private = "file")
fc_centre :: proc(t: ^Tree, n: Node) -> [2]f32 {
	d := node_get(t, n)
	return {d.abs.x + d.abs.w / 2, d.abs.y + d.abs.h / 2}
}

@(private = "file")
fc_click :: proc(ui: ^Ui(Fclick_Msg), p: [2]f32) {
	pointer_move(ui, p)
	pointer_button(ui, .Left, true, p)
	pointer_button(ui, .Left, false, p)
}

// After clicking a button, a press on something that cannot take focus
// takes it away, so the keys reach the window's shortcuts.
@(test)
a_press_on_something_unfocusable_takes_focus_away :: proc(t: ^testing.T) {
	ui: Ui(Fclick_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tool, canvas, _ := fc_view(&ui)
	tr := &ui.tree

	fc_click(&ui, fc_centre(tr, tool))
	testing.expect_value(t, tr.focus, tool) // a click still focuses a button
	clear(&ui.msgs)

	fc_click(&ui, fc_centre(tr, canvas))
	testing.expect_value(t, tr.focus, NODE_NONE) // …and the canvas takes it back off it
	testing.expect_value(t, len(ui.msgs), 0)     // pressing the canvas is not pressing the button

	// So Enter is the app's now, not the button's.
	key_event(&ui, .Enter, true, {})
	testing.expect_value(t, len(ui.msgs), 0)
}

// A press inside a focusable ancestor still focuses that ancestor: clicking
// a button's own label is clicking the button.
@(test)
a_press_inside_a_control_focuses_the_control :: proc(t: ^testing.T) {
	ui: Ui(Fclick_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree
	begin_view(&ui)
	column(&ui, padding = .md)
	c := card(&ui, padding = .sm, width = 300, key = 1)
	clickable(&ui, c, Fclick_Msg(1), label = "A card")
	inner := text(&ui, "its own words", key = 2)
	end(&ui)
	end(&ui)
	end_view(&ui)
	frame(tr, {400, 300})

	fc_click(&ui, fc_centre(tr, inner))
	testing.expect_value(t, tr.focus, c)
}

// focus_on_click = false: Tab reaches it, Enter presses it once it has
// focus, and clicking it leaves the keys where they were.
@(test)
a_button_can_decline_focus_from_the_pointer :: proc(t: ^testing.T) {
	ui: Ui(Fclick_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tool, canvas, _ := fc_view(&ui, focus_on_click = false)
	tr := &ui.tree

	fc_click(&ui, fc_centre(tr, tool))
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == Fclick_Msg(1), "it still takes the click")
	testing.expect_value(t, tr.focus, NODE_NONE) // …without taking the keys
	clear(&ui.msgs)

	// Nothing was focused to begin with, so nothing was taken away either.
	fc_click(&ui, fc_centre(tr, canvas))
	testing.expect_value(t, tr.focus, NODE_NONE)

	// Tab still reaches it, and then Enter presses it.
	key_event(&ui, .Tab, true, {})
	testing.expect_value(t, tr.focus, tool)
	key_event(&ui, .Enter, true, {})
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == Fclick_Msg(1), "Enter presses it when the keyboard chose it")
}

// …and it does not take the keys off something else either: a field being
// typed in keeps them while a toolbar button is clicked.
@(test)
a_button_that_declines_focus_leaves_the_field_alone :: proc(t: ^testing.T) {
	ui: Ui(Fclick_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree
	doc := document_make("hello")
	defer document_destroy(&doc)

	begin_view(&ui)
	column(&ui, padding = .md)
	fld := rich_text(&ui, &doc, label = "Notes", width = 300, height = 80, key = 1)
	zoom := button(&ui, "Zoom in", Fclick_Msg(2), key = 2)
	button_options(&ui, zoom, focus_on_click = false)
	end(&ui)
	end_view(&ui)
	frame(tr, {400, 300})

	area, _ := editor_area(tr, fld) // the frame is the node; the area inside it takes the keys
	set_focus(tr, area, true)
	testing.expect_value(t, tr.focus, area)
	fc_click(&ui, fc_centre(tr, zoom))
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == Fclick_Msg(2), "the button did its job")
	testing.expect_value(t, tr.focus, area) // and the typing carries on where it was
}

// focus_ancestor is the rule underneath: the nearest thing that can take
// focus, or nothing at all.
@(test)
the_focusable_ancestor_is_the_nearest_one :: proc(t: ^testing.T) {
	ui: Ui(Fclick_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tool, canvas, label := fc_view(&ui)
	tr := &ui.tree
	testing.expect_value(t, focus_ancestor(tr, tool), tool)
	testing.expect_value(t, focus_ancestor(tr, canvas), NODE_NONE)
	testing.expect_value(t, focus_ancestor(tr, label), NODE_NONE)
	testing.expect_value(t, focus_ancestor(tr, NODE_NONE), NODE_NONE)
}

}
