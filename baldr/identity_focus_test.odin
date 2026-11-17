package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Identity and focus, the shapes a sibling toolkit's users ran into: fields
// built by one helper keep their own state, a composite field sees its own
// focus, and a click leaves no focus ring behind.

@(private = "file")
Sr_Msg :: union { int, string }

@(private = "file")
sr_field :: proc(ui: ^Ui(Sr_Msg), label: string) -> Node {
	return text_input(ui, nil, label = label, width = 200) // every call from here shares one source line
}

@(private = "file")
sr_view :: proc(ui: ^Ui(Sr_Msg)) -> (a, b, search, btn: Node) {
	begin_view(ui)
	column(ui, gap = .md, padding = .md)
	a = sr_field(ui, "First")
	b = sr_field(ui, "Second")
	search = search_field(ui, nil, on_change = proc(e: Ev(string)) -> Sr_Msg { return e.value })
	btn = button(ui, "Go", Sr_Msg(1))
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 400})
	return
}

@(test)
fields_from_one_helper_keep_their_own_text_and_focus :: proc(t: ^testing.T) {
	ui: Ui(Sr_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	a, b, _, _ := sr_view(&ui)
	testing.expect(t, a != b, "two nodes, not one")
	set_focus(&ui.tree, b, true)
	text_event(&ui, "two")
	a, b, _, _ = sr_view(&ui)
	testing.expect_value(t, string(ui.tree.inputs[a].display), "")
	testing.expect_value(t, string(ui.tree.inputs[b].display), "two")
	testing.expect_value(t, ui.tree.focus, b)

	// the composite field: typing reaches it and it reports the change
	_, _, search, _ := sr_view(&ui)
	inner := search
	if _, is := ui.tree.inputs[inner]; !is do inner = node_first(&ui.tree, search) // the field inside its frame, if it has one
	for c := node_first(&ui.tree, search); c != NODE_NONE && !(inner in ui.tree.inputs); c = node_get(&ui.tree, c).next do inner = c
	set_focus(&ui.tree, inner, true)
	clear(&ui.msgs)
	text_event(&ui, "q")
	got := false
	for m in ui.msgs do if v, ok := m.(string); ok && v == "q" do got = true
	testing.expect(t, got, "the search field hears its own typing")
}

@(test)
a_click_leaves_no_focus_ring :: proc(t: ^testing.T) {
	ui: Ui(Sr_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	_, _, _, btn := sr_view(&ui)
	r := node_get(&ui.tree, btn).abs
	p := [2]f32{r.x + r.w / 2, r.y + r.h / 2}
	pointer_move(&ui, p)
	pointer_button(&ui, .Left, true, p)
	pointer_button(&ui, .Left, false, p)
	sr_view(&ui)
	testing.expect(t, !ring_shown(&ui.tree), "a pointer click draws no focus ring")
	// a click on nothing: no ring either, whatever keeps the keyboard
	pointer_move(&ui, {390, 390})
	pointer_button(&ui, .Left, true, {390, 390})
	pointer_button(&ui, .Left, false, {390, 390})
	sr_view(&ui)
	testing.expect(t, !ring_shown(&ui.tree), "nor after a click elsewhere")
	// Tab shows it, as the keyboard has moved focus
	key_event(&ui, .Tab, true, {})
	sr_view(&ui)
	testing.expect(t, ring_shown(&ui.tree), "the keyboard shows where it is")
}

// A form's keyboard path can be its fields alone: a control left out of the
// Tab order is still pressed, focused by the press and seen by a reader.
@(test)
a_control_can_leave_the_tab_order :: proc(t: ^testing.T) {
	ui: Ui(Sr_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	a, b, search, btn := sr_view(&ui)
	set_tab_stop(&ui.tree, btn, false)
	sr_view(&ui) // it stays left out across builds
	for _ in 0 ..< 8 {
		key_event(&ui, .Tab, true, {})
		testing.expect(t, ui.tree.focus != btn, "Tab passes the button by")
	}
	_ = a; _ = b; _ = search
	set_focus(&ui.tree, btn, true) // a press still focuses it
	testing.expect_value(t, ui.tree.focus, btn)
	set_tab_stop(&ui.tree, btn, true)
	set_focus(&ui.tree, btn, false)
	reached := false
	for _ in 0 ..< 8 {
		key_event(&ui, .Tab, true, {})
		if ui.tree.focus == btn do reached = true
	}
	testing.expect(t, reached, "and back in the order, Tab reaches it again")
}

// Any form control can be marked wrong or required: the states reach the
// part a reader lands on (the field inside a number or search field), and a
// field draws its frame in the danger colour, until the mark is taken away.
@(private = "file")
Sr_Fields :: struct { text, number, search, choice, date, check: Node }

@(private = "file")
sr_fields :: proc(ui: ^Ui(Sr_Msg)) -> (f: Sr_Fields) {
	options := []string{"One", "Two"}
	begin_view(ui)
	column(ui, gap = .md, padding = .md)
	f.text = text_input(ui, nil, label = "Name", width = 200)
	f.number = number_input(ui, 3, label = "Count")
	f.search = search_field(ui, nil)
	f.choice = select(ui, -1, options, label = "Size")
	f.date = date_field(ui, Date{2026, 11, 17}, label = "Due")
	f.check = checkbox(ui, false, "I agree")
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 600})
	return
}

@(private = "file")
sr_reader_node :: proc(t: ^Tree, n: Node) -> Node {
	if n in t.inputs do return n
	for c := node_first(t, n); c != NODE_NONE; c = node_get(t, c).next do if c in t.inputs do return c
	return n
}

@(test)
any_form_control_can_be_marked_invalid_and_required :: proc(t: ^testing.T) {
	ui: Ui(Sr_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	f := sr_fields(&ui)
	all := []Node{f.text, f.number, f.search, f.choice, f.date, f.check}
	for n in all {
		set_invalid(&ui.tree, n, true)
		set_required(&ui.tree, n, true)
	}
	f = sr_fields(&ui) // the marks stay across builds
	danger := ui.tree.theme.color.danger
	for n, i in ([]Node{f.text, f.number, f.search, f.choice, f.date, f.check}) {
		at := sr_reader_node(&ui.tree, n)
		st := node_get(&ui.tree, at).access.states
		testing.expectf(t, .Invalid in st && .Required in st, "control %d: the reader's node carries both states", i)
	}
	framed := 0
	for c in draw_list(&ui.tree) do if r, ok := c.(Draw_Rect); ok && r.border_w > 0 && r.border == danger do framed += 1
	testing.expectf(t, framed >= 5, "every field draws its frame in the danger colour: %d frames", framed)
	for n in all do set_invalid(&ui.tree, n, false)
	f = sr_fields(&ui)
	for n in ([]Node{f.text, f.number, f.search}) do testing.expect(t, .Invalid not_in node_get(&ui.tree, sr_reader_node(&ui.tree, n)).access.states, "and the mark comes off")
	still := 0
	for c in draw_list(&ui.tree) do if r, ok := c.(Draw_Rect); ok && r.border_w > 0 && r.border == danger do still += 1
	testing.expect_value(t, still, 0)
}

} // when ODIN_TEST
