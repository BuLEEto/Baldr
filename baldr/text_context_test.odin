package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// A right-click or the Menu key in read-only text, and in a field, reaches
// the app as an editor's does, and the menu's Copy runs through
// editor_action. Driven through the run loop's own entries: the press that
// opens a menu decides what Copy will take.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Tc_Ctx :: struct { ctx: Editor_Context, node: Node, tag: u64 }

@(private = "file")
Tc_Msg :: union { Tc_Ctx, string }

@(private = "file")
tc_on_context :: proc(e: Ev(Editor_Context)) -> Tc_Msg { return Tc_Ctx{e.value, e.node, e.tag} }

@(private = "file")
TC_TEXT :: "Meet me at the north gate at seven."

@(private = "file")
Tc_Clip :: struct { text: string }

@(private = "file")
tc_clip_install :: proc(ui: ^Ui(Tc_Msg), c: ^Tc_Clip) {
	ui.tree.clipboard = {
		user = c,
		set = proc(user: rawptr, text: string) -> bool {
			c := (^Tc_Clip)(user)
			delete(c.text)
			c.text = strings.clone(text)
			return true
		},
		get = proc(user: rawptr, allocator := context.allocator) -> (string, bool) {
			c := (^Tc_Clip)(user)
			if len(c.text) == 0 do return "", false
			return strings.clone(c.text, allocator), true
		},
	}
}

// tc_context is the one context message the last event sent, cleared.
@(private = "file")
tc_context :: proc(ui: ^Ui(Tc_Msg)) -> (got: Tc_Ctx, ok: bool) {
	for m in ui.msgs {
		if c, is := m.(Tc_Ctx); is {
			got, ok = c, true
		}
	}
	clear(&ui.msgs)
	return
}

// Two messages of a chat, the first with a menu of the app's, the second
// inside a context_area and without one; then the composer.
@(private = "file")
tc_chat :: proc(ui: ^Ui(Tc_Msg), draft: ^Text, menu := true) -> (a, b, field: Node) {
	set_viewport(&ui.tree, {420, 360})
	begin_view(ui)
	column(ui, padding = .md, gap = .sm)
	a = styled_text(ui, TC_TEXT, on_context = tc_on_context if menu else nil, width = 380, tag = 77, key = 1)
	box := column(ui, key = 2)
	b = styled_text(ui, "Second message, no menu of its own.", width = 380, key = 3)
	end(ui)
	context_area(ui, box, Tc_Msg("bubble"))
	field = text_input(ui, draft, label = "Message", on_context = tc_on_context, key = 4)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {420, 360})
	return
}

// tc_drag selects from `from` to `to` with the left button, as a hand does.
@(private = "file")
tc_drag :: proc(ui: ^Ui(Tc_Msg), from, to: [2]f32, ms: u32) {
	mouse_button_event(ui, .Left, true, from, ms)
	pointer_move(ui, to)
	mouse_button_event(ui, .Left, false, to, ms + 10)
}

// Right-click on what was dragged: the selection stays, the app hears where
// and from which message, and the menu's Copy copies exactly the selection,
// never the whole message.
@(test)
a_right_click_on_a_paragraphs_selection_keeps_it_for_copy :: proc(t: ^testing.T) {
	ui: Ui(Tc_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	clip: Tc_Clip
	defer delete(clip.text)
	tc_clip_install(&ui, &clip)
	draft: Text
	defer text_destroy(&draft)

	a, _, _ := tc_chat(&ui, &draft)
	r := node_get(&ui.tree, a).abs
	y := r.y + r.h / 2
	tc_drag(&ui, {r.x + 2, y}, {r.x + r.w * 0.5, y}, 1000)
	tc_chat(&ui, &draft)
	s := &ui.tree.styled[a]
	sel_a, sel_c := s.anchor, s.caret
	text := TC_TEXT
	want := text[min(sel_a, sel_c):max(sel_a, sel_c)]
	testing.expect(t, len(want) > 0 && len(want) < len(TC_TEXT), "part of the message is selected")
	testing.expect_value(t, editor_actions(&ui.tree, a), Editor_Actions{.Copy, .Select_All})

	at := [2]f32{r.x + r.w * 0.2, y}
	clear(&ui.msgs)
	mouse_button_event(&ui, .Right, true, at, 3000)
	mouse_button_event(&ui, .Right, false, at, 3010)
	c, sent := tc_context(&ui)
	testing.expect(t, sent, "the paragraph's on_context was sent")
	testing.expect(t, c.ctx.in_selection, "on the selection")
	testing.expect_value(t, c.node, a)
	testing.expect_value(t, c.tag, u64(77))
	testing.expect_value(t, c.ctx.at, at)
	testing.expect_value(t, ui.context_pos, at)
	testing.expect(t, s.anchor == sel_a && s.caret == sel_c, "the selection is kept")

	testing.expect(t, editor_action(&ui, c.node, .Copy), "Copy")
	testing.expect_value(t, clip.text, want)
	// read-only: nothing else a menu could ask changes it
	testing.expect(t, !editor_action(&ui, a, .Cut) && !editor_action(&ui, a, .Paste) && !editor_action(&ui, a, .Undo), "no edits")
	testing.expect_value(t, s.text, TC_TEXT)
}

// Right-click away from the selection drops it, here and in every other
// message, so Copy greys rather than copying text no longer shown.
@(test)
a_right_click_off_the_selection_drops_it :: proc(t: ^testing.T) {
	ui: Ui(Tc_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	clip: Tc_Clip
	defer delete(clip.text)
	tc_clip_install(&ui, &clip)
	draft: Text
	defer text_destroy(&draft)

	a, b, _ := tc_chat(&ui, &draft)
	r := node_get(&ui.tree, a).abs
	y := r.y + r.h / 2
	tc_drag(&ui, {r.x + 2, y}, {r.x + r.w * 0.3, y}, 1000)
	tc_chat(&ui, &draft)
	end_x := r.x
	for line in ui.tree.styled[a].lay.lines do end_x = max(end_x, r.x + line.x + line.width)
	at := [2]f32{end_x - 3, y} // the last word, well past what was dragged
	mouse_button_event(&ui, .Right, true, at, 3000)
	mouse_button_event(&ui, .Right, false, at, 3010)
	c, sent := tc_context(&ui)
	testing.expect(t, sent && !c.ctx.in_selection, "sent, off the selection")
	s := &ui.tree.styled[a]
	testing.expect_value(t, s.anchor, s.caret)
	testing.expect_value(t, editor_actions(&ui.tree, a), Editor_Actions{.Select_All})
	testing.expect(t, !editor_action(&ui, a, .Copy), "nothing to copy")
	testing.expect_value(t, clip.text, "")

	// a selection in one message, a right-click in another that has a menu:
	// the first lets go
	rb := node_get(&ui.tree, b).abs
	tc_drag(&ui, {rb.x + 2, rb.y + rb.h / 2}, {rb.x + rb.w * 0.4, rb.y + rb.h / 2}, 5000)
	tc_chat(&ui, &draft)
	sb := &ui.tree.styled[b]
	testing.expect(t, sb.anchor != sb.caret, "the second message is selected")
	mouse_button_event(&ui, .Right, true, {r.x + 4, y}, 7000)
	mouse_button_event(&ui, .Right, false, {r.x + 4, y}, 7010)
	testing.expect_value(t, sb.anchor, sb.caret)
}

// A message without a menu of its own leaves the right-click to what holds
// it, and keeps its selection.
@(test)
a_paragraph_without_on_context_leaves_the_right_click_to_its_holder :: proc(t: ^testing.T) {
	ui: Ui(Tc_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	draft: Text
	defer text_destroy(&draft)

	_, b, _ := tc_chat(&ui, &draft)
	rb := node_get(&ui.tree, b).abs
	y := rb.y + rb.h / 2
	tc_drag(&ui, {rb.x + 2, y}, {rb.x + rb.w * 0.4, y}, 1000)
	tc_chat(&ui, &draft)
	sb := &ui.tree.styled[b]
	lo, hi := styled_sel(sb)
	clear(&ui.msgs)
	mouse_button_event(&ui, .Right, true, {rb.x + rb.w * 0.8, y}, 3000)
	mouse_button_event(&ui, .Right, false, {rb.x + rb.w * 0.8, y}, 3010)
	got := ""
	for m in ui.msgs do if s, is := m.(string); is do got = s
	testing.expect_value(t, got, "bubble")
	l2, h2 := styled_sel(sb)
	testing.expect(t, l2 == lo && h2 == hi && hi > lo, "the selection is untouched")
}

// The Menu key and Shift+F10 in a paragraph the pointer gave the keyboard
// open its menu under the selection's moving end.
@(test)
the_menu_key_in_a_paragraph_opens_its_menu_under_the_selection :: proc(t: ^testing.T) {
	ui: Ui(Tc_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	draft: Text
	defer text_destroy(&draft)

	a, _, _ := tc_chat(&ui, &draft)
	r := node_get(&ui.tree, a).abs
	y := r.y + r.h / 2
	tc_drag(&ui, {r.x + 2, y}, {r.x + r.w * 0.5, y}, 1000)
	tc_chat(&ui, &draft)
	testing.expect_value(t, ui.tree.focus, a)
	clear(&ui.msgs)
	testing.expect(t, key_event(&ui, .Menu, true, {}), "the Menu key was taken")
	c, sent := tc_context(&ui)
	testing.expect(t, sent && c.ctx.in_selection, "sent, with a selection")
	s := &ui.tree.styled[a]
	testing.expect_value(t, c.ctx.pos, Pos{0, s.caret})
	testing.expectf(t, c.ctx.at.x > r.x + r.w * 0.3 && c.ctx.at.x <= r.x + r.w, "under the selection's end (x %v)", c.ctx.at.x)
	testing.expectf(t, c.ctx.at.y > r.y && c.ctx.at.y <= r.y + r.h + 0.5, "below its line, inside the message (y %v)", c.ctx.at.y)
	testing.expect_value(t, ui.context_pos, c.ctx.at)
	testing.expect(t, key_event(&ui, .F10, true, {.Shift}), "Shift+F10 was taken")
	c2, sent2 := tc_context(&ui)
	testing.expect(t, sent2 && c2.ctx.at == c.ctx.at, "Shift+F10 asks the same")
}

// A reply rendered from markdown has the same menu: right-click on the
// selection keeps it, Copy copies it as clean text, and a right-click off
// it drops it.
@(test)
a_right_click_in_a_reply_keeps_its_selection_for_copy :: proc(t: ^testing.T) {
	ui: Ui(Tc_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	clip: Tc_Clip
	defer delete(clip.text)
	tc_clip_install(&ui, &clip)
	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, "The **north** gate opens at seven, and the south one never.\n")

	build :: proc(ui: ^Ui(Tc_Msg), md: ^Markdown_Doc) -> Node {
		set_viewport(&ui.tree, {420, 300})
		begin_view(ui)
		n := markdown_view(ui, md, label = "Reply", width = 400, tag = 5)
		md_view_options(ui, n, on_context = tc_on_context)
		end_view(ui)
		frame(&ui.tree, {420, 300})
		return n
	}
	n := build(&ui, &md)
	r := node_get(&ui.tree, n).abs
	y := r.y + 8
	tc_drag(&ui, {r.x + 1, y}, {r.x + r.w * 0.35, y}, 1000)
	build(&ui, &md)
	want := strings.clone(md_view_selected_text(&ui.tree, n), context.temp_allocator)
	testing.expect(t, len(want) > 0, "part of the reply is selected")
	testing.expect_value(t, editor_actions(&ui.tree, n), Editor_Actions{.Copy, .Select_All})

	clear(&ui.msgs)
	mouse_button_event(&ui, .Right, true, {r.x + r.w * 0.15, y}, 3000)
	mouse_button_event(&ui, .Right, false, {r.x + r.w * 0.15, y}, 3010)
	c, sent := tc_context(&ui)
	testing.expect(t, sent && c.ctx.in_selection, "sent, on the selection")
	testing.expect(t, c.node == n && c.tag == 5, "from the reply")
	testing.expect(t, editor_action(&ui, n, .Copy), "Copy")
	testing.expect_value(t, clip.text, want)
	testing.expect(t, !strings.contains(clip.text, "**"), "clean text, no markup")

	testing.expect(t, key_event(&ui, .Menu, true, {}), "the Menu key was taken")
	k, ksent := tc_context(&ui)
	testing.expect(t, ksent && k.ctx.in_selection && k.ctx.at.y > r.y, "the Menu key asks under the selection")

	mouse_button_event(&ui, .Right, true, {r.x + r.w * 0.9, y}, 5000)
	mouse_button_event(&ui, .Right, false, {r.x + r.w * 0.9, y}, 5010)
	c2, sent2 := tc_context(&ui)
	testing.expect(t, sent2 && !c2.ctx.in_selection, "off the selection")
	lo, hi := md_view_selection(&ui.tree, n)
	testing.expect_value(t, lo, hi)
	testing.expect_value(t, editor_actions(&ui.tree, n), Editor_Actions{.Select_All})
	testing.expect(t, editor_action(&ui, n, .Select_All), "Select All")
	lo, hi = md_view_selection(&ui.tree, n)
	testing.expect(t, lo == 0 && hi == len(md_text(&md)), "the whole reply")
}

// A field's menu runs through editor_action too, step for step as its
// shortcuts do, and the Menu key opens it under the field.
@(test)
a_fields_menu_runs_through_editor_action :: proc(t: ^testing.T) {
	ui: Ui(Tc_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	clip: Tc_Clip
	defer delete(clip.text)
	tc_clip_install(&ui, &clip)
	draft: Text
	defer text_destroy(&draft)

	_, _, field := tc_chat(&ui, &draft)
	set_focus(&ui.tree, field, false)
	text_event(&ui, "hello world")
	tc_chat(&ui, &draft)
	testing.expect_value(t, editor_actions(&ui.tree, field), Editor_Actions{.Paste, .Select_All, .Undo})
	testing.expect(t, editor_action(&ui, field, .Select_All), "Select All")
	testing.expect_value(t, editor_actions(&ui.tree, field), Editor_Actions{.Cut, .Copy, .Paste, .Select_All, .Undo})
	testing.expect(t, editor_action(&ui, field, .Cut), "Cut")
	testing.expect_value(t, clip.text, "hello world")
	testing.expect_value(t, str(draft), "")
	testing.expect(t, editor_action(&ui, field, .Undo), "Undo")
	testing.expect_value(t, str(draft), "hello world")
	testing.expect(t, .Redo in editor_actions(&ui.tree, field), "Redo offered")
	testing.expect(t, editor_action(&ui, field, .Paste), "Paste")
	testing.expect_value(t, str(draft), "hello world") // the selection the undo restored is replaced by the same words
	testing.expect(t, editor_action(&ui, field, .Paste), "Paste again, at the caret")
	testing.expect_value(t, str(draft), "hello worldhello world")

	clear(&ui.msgs)
	fd := node_get(&ui.tree, field)
	testing.expect(t, key_event(&ui, .Menu, true, {}), "the Menu key was taken")
	c, sent := tc_context(&ui)
	testing.expect(t, sent && c.node == field, "the field's on_context")
	testing.expect_value(t, c.ctx.at.y, fd.abs.y + fd.abs.h)
	testing.expect(t, c.ctx.at.x >= fd.abs.x && c.ctx.at.x <= fd.abs.x + fd.abs.w, "at the caret")
}

// A password field never offers its text to the clipboard from a menu,
// as Ctrl+C never does.
@(test)
a_password_fields_menu_offers_no_copy :: proc(t: ^testing.T) {
	ui: Ui(Tc_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	clip: Tc_Clip
	defer delete(clip.text)
	tc_clip_install(&ui, &clip)
	secret: Text
	defer text_destroy(&secret)
	build :: proc(ui: ^Ui(Tc_Msg), v: ^Text) -> Node {
		set_viewport(&ui.tree, {300, 120})
		begin_view(ui)
		n := text_input(ui, v, label = "Passphrase", password = true, on_context = tc_on_context)
		end_view(ui)
		frame(&ui.tree, {300, 120})
		return n
	}
	n := build(&ui, &secret)
	set_focus(&ui.tree, n, false)
	text_event(&ui, "hunter2")
	build(&ui, &secret)
	editor_action(&ui, n, .Select_All)
	can := editor_actions(&ui.tree, n)
	testing.expect(t, .Copy not_in can && .Cut not_in can && .Undo not_in can, "no copy, no history")
	testing.expect(t, !editor_action(&ui, n, .Copy) && !editor_action(&ui, n, .Cut), "refused")
	testing.expect_value(t, clip.text, "")
	testing.expect_value(t, str(secret), "hunter2")
}

}
