package baldr

@(require) import "core:mem"
@(require) import "core:strings"
@(require) import "core:testing"

// What a retained Msg borrows, and for how long. A builder's `Msg` is
// stored on the node and sent when the control is used, which may be many
// builds later, because `component` leaves a subtree alone while its
// revision is unchanged. So a Msg must outlive every build in which its
// node still exists, not just the build that set it: a borrowed string
// freed at the start of every build is a dangling pointer the toolkit
// cannot see. Node text is different (the tree clones it in `set_text`),
// and so is anything the app looks up by id.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Ml_Msg :: union { string }

// A component whose revision has not changed is not rebuilt, so the Msg its
// button carries is the one an earlier build gave it.
@(test)
a_skipped_component_keeps_the_msg_an_earlier_build_gave_it :: proc(t: ^testing.T) {
	ui: Ui(Ml_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	// Two separately-allocated payloads, so the second cannot land on the
	// first's bytes and hide the difference.
	first := strings.clone("build-one")
	second := strings.clone("build-two")
	defer delete(first)
	defer delete(second)

	btn: Node
	ml_build := proc(ui: ^Ui(Ml_Msg), payload: string, rev: u64) -> Node {
		n: Node
		set_viewport(&ui.tree, {400, 300})
		begin_view(ui)
		column(ui, padding = .md)
		if component(ui, "rows", rev) {
			defer end(ui)
			n = button(ui, "Send", Ml_Msg(payload), key = 1)
		}
		end(ui)
		end_view(ui)
		frame(&ui.tree, {400, 300})
		return n
	}

	btn = ml_build(&ui, first, 1)
	testing.expect(t, btn != NODE_NONE, "the first build made the button")

	// rev unchanged: the component is skipped, so `second` never reaches it
	clear(&ui.msgs)
	n2 := ml_build(&ui, second, 1)
	testing.expect_value(t, n2, NODE_NONE) // the subtree was not built at all

	clear(&ui.msgs)
	testing.expect(t, click(&ui, btn), "the retained button still takes a click")
	testing.expect_value(t, len(ui.msgs), 1)
	got, ok := ui.msgs[0].(string)
	testing.expect(t, ok, "it sent a string")
	testing.expectf(t, raw_data(got) == raw_data(first),
		"and it is the FIRST build's payload, pointer and all (%q)", got)

	// …and a bumped revision does replace it
	clear(&ui.msgs)
	ml_build(&ui, second, 2)
	clear(&ui.msgs)
	click(&ui, btn)
	testing.expect_value(t, len(ui.msgs), 1)
	got2, _ := ui.msgs[0].(string)
	testing.expectf(t, raw_data(got2) == raw_data(second), "a bumped revision replaces it (%q)", got2)
}

// Node text is not borrowed: the tree clones every string it is given,
// so a label may point at a frame arena even though a Msg may not.
@(test)
node_text_is_cloned_not_borrowed :: proc(t: ^testing.T) {
	ui: Ui(Ml_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	buf: [64]u8
	arena: mem.Arena
	mem.arena_init(&arena, buf[:])
	tmp := mem.arena_allocator(&arena)
	borrowed, _ := strings.clone("Inbox", tmp)

	set_viewport(&ui.tree, {400, 300})
	begin_view(&ui)
	column(&ui, padding = .md)
	n := text(&ui, borrowed, key = 1)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 300})

	tk, ok := node_get(&ui.tree, n).kind.(Text_Kind)
	testing.expect(t, ok, "it is a text node")
	testing.expect_value(t, tk.str, "Inbox")
	testing.expect(t, raw_data(tk.str) != raw_data(borrowed), "the tree kept its own copy")

	free_all(tmp) // the app's arena goes; the node is unharmed
	testing.expect_value(t, tk.str, "Inbox")
}

}
