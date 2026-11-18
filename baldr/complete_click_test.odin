package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A completion list is picked from with the pointer as with the keys: a
// click on a row puts it in, and the keyboard stays in the editor.

@(private = "file")
Cc_Msg :: enum { None }

@(private = "file")
cc_view :: proc(ui: ^Ui(Cc_Msg), doc: ^Document) -> (ed, area: Node) {
	set_viewport(&ui.tree, {600, 400})
	begin_view(ui)
	column(ui, padding = .lg)
	ed = code_editor(ui, doc, nil, label = "Source", height = 200, key = 1)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	return ed, ui.tree.area_of_frame[ed]
}

@(test)
a_click_on_a_completion_puts_it_in :: proc(t: ^testing.T) {
	ui: Ui(Cc_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make("roomList = 1\n")
	defer document_destroy(&doc)
	ed, area := cc_view(&ui, &doc)
	set_focus(&ui.tree, ed, false)
	st := &ui.tree.areas[area]
	st.caret, st.anchor = {1, 0}, {1, 0}
	for r in "roo" do text_area_text(&ui, string([]u8{u8(r)}))
	cc_view(&ui, &doc)
	cc_view(&ui, &doc)
	row := NODE_NONE
	for n, a in ui.tree.editor_ctl_of {
		d := node_get(&ui.tree, n)
		if a == area && d != nil && d.access.role == .List_Item && d.access.name == "roomList" do row = n
	}
	if !testing.expect(t, row != NODE_NONE, "the list offers roomList") do return
	r := node_get(&ui.tree, row).abs
	at := [2]f32{r.x + r.w * 0.5, r.y + r.h * 0.5}
	pointer_move(&ui, at)
	pointer_button(&ui, .Left, true, at)
	testing.expect_value(t, ui.tree.focus, area) // the press leaves the keyboard in the code
	ui_after_events(&ui, ui.tree.now_ms)
	pointer_button(&ui, .Left, false, at)
	cc_view(&ui, &doc)
	testing.expect_value(t, document_text(&doc, context.temp_allocator), "roomList = 1\nroomList")
	testing.expect_value(t, ui.tree.focus, area)
	testing.expect(t, !ui.tree.areas[area].complete.open, "and the list is gone")
	text_area_text(&ui, "!")
	testing.expect_value(t, document_text(&doc, context.temp_allocator), "roomList = 1\nroomList!")
}

} // when ODIN_TEST
