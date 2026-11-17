#+build linux
package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: behind this `when`, checking a program costs
// 1.0 GB instead of 9.2 GB. ODIN_TEST is set by `odin test`; BALDR_TESTS
// lets ./build.sh check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A node with a layer of its own — a scroll, a list, an editor — is one
// command in the layer that holds it, and its own contents are a list
// beside that. Both halves have to be told when the node is hidden and
// shown again, and the parent has to lay it out afresh: it was given no
// room while it was gone. Getting any of the three wrong loses the node for
// good — it is built, it is in the tree, and nothing draws it.


@(private = "file")
Lv_Msg :: enum { None }

@(private = "file")
lv_view :: proc(ui: ^Ui(Lv_Msg), hidden: bool) -> Node {
	set_viewport(&ui.tree, {400, 300})
	begin_view(ui)
	column(ui, flex = 1)
	sc := scroll(ui, .Column, flex = 1, key = 9)
	text(ui, "inside the scroll")
	end(ui)
	end(ui)
	end_view(ui)
	set_hidden(&ui.tree, sc, hidden)
	frame(&ui.tree, {400, 300})
	return sc
}

@(private = "file")
lv_texts :: proc(ui: ^Ui(Lv_Msg)) -> int {
	n := 0
	for c in draw_list(&ui.tree) do if _, is_text := c.(Draw_Text); is_text do n += 1
	return n
}

@(test)
a_hidden_scroll_comes_back_when_it_is_shown_again :: proc(t: ^testing.T) {
	ui: Ui(Lv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sc := lv_view(&ui, false)
	testing.expect_value(t, lv_texts(&ui), 1)
	lv_view(&ui, true)
	testing.expect_value(t, lv_texts(&ui), 0)
	lv_view(&ui, false)
	testing.expect_value(t, lv_texts(&ui), 1) // …and it is laid out again, not left at nothing
	d := node_get(&ui.tree, sc)
	testing.expect_value(t, d.abs.w, f32(400))
	testing.expect(t, d.abs.h > 0)
	// the layer that holds it draws it: one Draw_Layer naming the scroll
	found := 0
	for c in ui.tree.layers[ui.tree.root].cmds do if dl, is_layer := c.(Draw_Layer); is_layer && dl.node == sc do found += 1
	testing.expect_value(t, found, 1)
}

@(test)
a_scroll_built_hidden_draws_the_moment_it_is_shown :: proc(t: ^testing.T) {
	ui: Ui(Lv_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	lv_view(&ui, true)
	testing.expect_value(t, lv_texts(&ui), 0)
	lv_view(&ui, false)
	testing.expect_value(t, lv_texts(&ui), 1)
}

} // when ODIN_TEST