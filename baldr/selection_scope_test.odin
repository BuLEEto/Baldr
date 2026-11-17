package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// One selection across several messages. A conversation is a column of
// views (the person's question in a read-only editor, the answer in a
// markdown view), and a drag that starts in one and ends in another has to
// select everything between, as a page does.


@(private = "file")
Sc_Msg :: union { int }

@(private = "file")
Sc_Fx :: struct {
	ui:    Ui(Sc_Msg),
	ask:   Document,
	reply: Markdown_Doc,
	again: Document,
	scope, q1, r1, q2: Node,
}

@(private = "file")
sc_build :: proc(fx: ^Sc_Fx) {
	ui := &fx.ui
	set_viewport(&ui.tree, {420, 900})
	begin_view(ui)
	fx.scope = column(ui, gap = .md, padding = .md)
	fx.q1 = text_area(ui, &fx.ask, label = "You", width = 380, height = 48)
	editor_options(ui, fx.q1, readonly = true)
	fx.r1 = markdown_view(ui, &fx.reply, label = "Reply", width = 380)
	fx.q2 = text_area(ui, &fx.again, label = "You again", width = 380, height = 48)
	editor_options(ui, fx.q2, readonly = true)
	end(ui)
	end_view(ui)
	selection_scope(ui, fx.scope)
	frame(&ui.tree, {420, 900})
}

@(private = "file")
sc_start :: proc(fx: ^Sc_Fx) {
	ui_init(&fx.ui)
	fx.ask = document_make("what is an arena?")
	fx.again = document_make("thanks, that helps")
	md_set(&fx.reply, "An arena hands out memory and frees it all at once.")
	sc_build(fx)
}

@(private = "file")
sc_stop :: proc(fx: ^Sc_Fx) {
	ui_destroy(&fx.ui)
	document_destroy(&fx.ask)
	document_destroy(&fx.again)
	md_destroy(&fx.reply)
}

@(private = "file")
sc_point :: proc(fx: ^Sc_Fx, n: Node, dx, dy: f32) -> [2]f32 {
	d := node_get(&fx.ui.tree, n)
	return {d.abs.x + dx, d.abs.y + dy}
}

@(private = "file")
sc_area_sel :: proc(fx: ^Sc_Fx, n: Node) -> (lo, hi: int) {
	s := &fx.ui.tree.areas[n]
	a, c := pos_order(s.anchor, s.caret)
	return document_flat_off(s.doc, a), document_flat_off(s.doc, c)
}

@(test)
a_drag_across_messages_is_one_selection :: proc(t: ^testing.T) {
	fx: Sc_Fx
	sc_start(&fx)
	defer sc_stop(&fx)

	// press in the first message, drag through the reply, release in the last
	from := sc_point(&fx, fx.q1, 30, 10)
	through := sc_point(&fx, fx.r1, 60, 6)
	to := sc_point(&fx, fx.q2, 100, 10) // well into it: the headless measurer is half the size per rune
	pointer_move(&fx.ui, from)
	pointer_button(&fx.ui, .Left, true, from)
	pointer_move(&fx.ui, through)
	pointer_move(&fx.ui, to)
	pointer_button(&fx.ui, .Left, false, to)

	lo1, hi1 := sc_area_sel(&fx, fx.q1)
	rlo, rhi := md_view_selection(&fx.ui.tree, fx.r1)
	lo2, hi2 := sc_area_sel(&fx, fx.q2)
	testing.expect(t, hi1 > lo1, "the first message is selected from where the drag began")
	testing.expect_value(t, hi1, len(document_text(&fx.ask, context.temp_allocator)))
	testing.expect_value(t, rlo, 0) // the reply is wholly inside the selection
	testing.expect_value(t, rhi, len(fx.reply.src))
	testing.expect_value(t, lo2, 0) // …and the last message up to the pointer
	testing.expect(t, hi2 > 0 && hi2 < len(document_text(&fx.again, context.temp_allocator)),
		"the last message stops where the drag did")

	// copying takes the three in order, a blank line between messages
	text := selection_scope_text(&fx.ui.tree, fx.scope)
	testing.expect(t, strings.contains(text, "arena?"), "the tail of the question")
	testing.expect(t, strings.contains(text, "An arena hands out memory"), "the whole reply")
	testing.expect(t, strings.contains(text, "thanks"), "and the head of what follows")
	testing.expect(t, strings.contains(text, "\n\n"), "the messages are kept apart")
	testing.expect(t, strings.index(text, "arena?") < strings.index(text, "thanks"), "in the order they were said")
}

@(test)
a_selection_inside_one_message_stays_its_own :: proc(t: ^testing.T) {
	// The scope only owns a selection that spans views. A drag within one
	// message is that widget's own.
	fx: Sc_Fx
	sc_start(&fx)
	defer sc_stop(&fx)

	a := sc_point(&fx, fx.r1, 10, 6)
	b := sc_point(&fx, fx.r1, 120, 6)
	pointer_move(&fx.ui, a)
	pointer_button(&fx.ui, .Left, true, a)
	pointer_move(&fx.ui, b)
	pointer_button(&fx.ui, .Left, false, b)

	testing.expect(t, !sel_scope_spans(&fx.ui.tree, fx.scope), "one view: the scope does not span")
	lo, hi := md_view_selection(&fx.ui.tree, fx.r1)
	testing.expect(t, hi > lo, "the reply has its own selection")
	q_lo, q_hi := sc_area_sel(&fx, fx.q1)
	testing.expect_value(t, q_lo, q_hi) // and nothing else is lit
}

@(test)
shift_click_extends_across_messages :: proc(t: ^testing.T) {
	fx: Sc_Fx
	sc_start(&fx)
	defer sc_stop(&fx)

	first := sc_point(&fx, fx.q1, 30, 10)
	pointer_move(&fx.ui, first)
	pointer_button(&fx.ui, .Left, true, first)
	pointer_button(&fx.ui, .Left, false, first)
	testing.expect(t, !sel_scope_spans(&fx.ui.tree, fx.scope))

	later := sc_point(&fx, fx.q2, 40, 10)
	fx.ui.pointer.mods = {.Shift}
	pointer_move(&fx.ui, later)
	pointer_button(&fx.ui, .Left, true, later)
	pointer_button(&fx.ui, .Left, false, later)
	fx.ui.pointer.mods = {}

	testing.expect(t, sel_scope_spans(&fx.ui.tree, fx.scope), "Shift+click reached the later message")
	rlo, rhi := md_view_selection(&fx.ui.tree, fx.r1)
	testing.expect(t, rhi > rlo, "and the reply between them came with it")
}

@(test)
copying_and_letting_go :: proc(t: ^testing.T) {
	fx: Sc_Fx
	sc_start(&fx)
	defer sc_stop(&fx)

	copied: string
	fx.ui.tree.clipboard = {
		user = &copied,
		set = proc(user: rawptr, text: string) -> bool {
			(^string)(user)^ = strings.clone(text)
			return true
		},
	}
	from := sc_point(&fx, fx.q1, 30, 10)
	to := sc_point(&fx, fx.q2, 40, 10)
	pointer_move(&fx.ui, from)
	pointer_button(&fx.ui, .Left, true, from)
	pointer_move(&fx.ui, to)
	pointer_button(&fx.ui, .Left, false, to)
	set_focus(&fx.ui.tree, fx.q2, false)

	testing.expect(t, sel_scope_key(&fx.ui, .C, {.Ctrl}), "Ctrl+C is the scope's while it spans")
	defer delete(copied)
	testing.expect(t, strings.contains(copied, "An arena hands out memory"), "the reply is in the clipboard")

	testing.expect(t, sel_scope_key(&fx.ui, .Escape, {}), "Escape lets the whole thing go")
	testing.expect(t, !sel_scope_spans(&fx.ui.tree, fx.scope))
	rlo, rhi := md_view_selection(&fx.ui.tree, fx.r1)
	testing.expect_value(t, rlo, rhi) // every view let go of its part
	q_lo, q_hi := sc_area_sel(&fx, fx.q1)
	testing.expect_value(t, q_lo, q_hi)
}

@(test)
a_reply_that_grows_does_not_move_the_selection :: proc(t: ^testing.T) {
	// The ends are a view and an offset into it, so bytes landing at the
	// end of the last message cannot move a selection made earlier — the
	// same promise the markdown view makes on its own.
	fx: Sc_Fx
	sc_start(&fx)
	defer sc_stop(&fx)

	from := sc_point(&fx, fx.q1, 30, 10)
	to := sc_point(&fx, fx.r1, 60, 6)
	pointer_move(&fx.ui, from)
	pointer_button(&fx.ui, .Left, true, from)
	pointer_move(&fx.ui, to)
	pointer_button(&fx.ui, .Left, false, to)
	was := selection_scope_text(&fx.ui.tree, fx.scope, context.temp_allocator)
	testing.expect(t, len(was) > 0)

	md_append(&fx.reply, " It is one reset.")
	sc_build(&fx)
	sel_scope_apply(&fx.ui.tree, fx.scope)
	now := selection_scope_text(&fx.ui.tree, fx.scope, context.temp_allocator)
	testing.expect_value(t, now, was)
}

@(test)
ctrl_a_takes_the_message_then_the_conversation :: proc(t: ^testing.T) {
	// The escalation an editor teaches: the first Ctrl+A is the message's
	// own, the second — that message already whole — takes everything.
	fx: Sc_Fx
	sc_start(&fx)
	defer sc_stop(&fx)
	set_focus(&fx.ui.tree, fx.r1, false)

	testing.expect(t, !sel_scope_key(&fx.ui, .A, {.Ctrl}), "the first Ctrl+A is the reply's own")
	testing.expect(t, md_view_key(&fx.ui, .A, {.Ctrl}), "…which the reply takes")
	lo, hi := md_view_selection(&fx.ui.tree, fx.r1)
	testing.expect_value(t, lo, 0)
	testing.expect_value(t, hi, len(fx.reply.src))
	testing.expect(t, !sel_scope_spans(&fx.ui.tree, fx.scope), "one message so far")

	testing.expect(t, sel_scope_key(&fx.ui, .A, {.Ctrl}), "the second takes the conversation")
	testing.expect(t, sel_scope_spans(&fx.ui.tree, fx.scope))
	q1_lo, q1_hi := sc_area_sel(&fx, fx.q1)
	q2_lo, q2_hi := sc_area_sel(&fx, fx.q2)
	testing.expect_value(t, q1_lo, 0)
	testing.expect(t, q1_hi > 0, "the first message came with it")
	testing.expect_value(t, q2_lo, 0)
	testing.expect_value(t, q2_hi, len(document_text(&fx.again, context.temp_allocator)))
	text := selection_scope_text(&fx.ui.tree, fx.scope)
	testing.expect(t, strings.contains(text, "what is an arena?"), "every message is in it")
	testing.expect(t, strings.contains(text, "thanks, that helps"))
}

@(private = "file")
sc_build_scrolled :: proc(fx: ^Sc_Fx) {
	ui := &fx.ui
	set_viewport(&ui.tree, {420, 260})
	begin_view(ui)
	column(ui, flex = 1)
	scroll(ui, height = 120, key = 9) // smaller than the conversation, which is the point
	fx.scope = column(ui, gap = .md)
	fx.q1 = text_area(ui, &fx.ask, label = "You", width = 380, height = 48)
	editor_options(ui, fx.q1, readonly = true)
	fx.r1 = markdown_view(ui, &fx.reply, label = "Reply", width = 380)
	fx.q2 = text_area(ui, &fx.again, label = "You again", width = 380, height = 48)
	editor_options(ui, fx.q2, readonly = true)
	end(ui) // the scope's column
	end(ui) // the scroll
	end(ui) // the page
	end_view(ui)
	selection_scope(ui, fx.scope)
	frame(&ui.tree, {420, 260})
}

@(test)
a_drag_at_the_edge_keeps_going :: proc(t: ^testing.T) {
	// A long conversation does not fit, so a drag downwards reaches the
	// bottom of the window with the selection unfinished. The pointer then
	// stops sending events, and without a tick of its own the drag stops
	// too — which is a selection a person cannot finish.
	fx: Sc_Fx
	ui_init(&fx.ui)
	fx.ask = document_make("what is an arena?")
	fx.again = document_make("thanks, that helps")
	md_set(&fx.reply, "An arena hands out memory and frees it all at once.")
	defer sc_stop(&fx)
	sc_build_scrolled(&fx)

	scroller := scroll_ancestor(&fx.ui.tree, fx.scope)
	testing.expect(t, scroller != NODE_NONE, "the conversation is in a scroll")
	st := &fx.ui.tree.scrolls[scroller]
	testing.expect(t, st.content.y > st.viewport.y, "…and does not fit in it")

	from := sc_point(&fx, fx.q1, 30, 10)
	pointer_move(&fx.ui, from)
	pointer_button(&fx.ui, .Left, true, from)

	// the pointer reaches the bottom edge and stays there
	d := node_get(&fx.ui.tree, scroller)
	edge := [2]f32{from.x, d.abs.y + st.viewport.y - 4}
	pointer_move(&fx.ui, edge)
	was := st.offset.y
	for i in 1 ..= 8 do ui_after_events(&fx.ui, f64(i) * 20)
	testing.expect(t, st.offset.y > was, "the conversation moved under the drag")
	testing.expect(t, sel_scope_spans(&fx.ui.tree, fx.scope), "and the selection reached the messages below")

	pointer_button(&fx.ui, .Left, false, edge)
	settled := st.offset.y
	for i in 9 ..= 16 do ui_after_events(&fx.ui, f64(i) * 20)
	testing.expect_value(t, st.offset.y, settled) // the drag is over: it stops
}

} // when ODIN_TEST