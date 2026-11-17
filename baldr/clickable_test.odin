package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// clickable: a card that takes a click as a whole, as a notification does.


@(private = "file")
Clickable_KMsg :: union { int }

// note_card: a 320 px card holding a title and a dismiss button, clickable (sending 1) unless `plain`.
@(private = "file")
note_card :: proc(ui: ^Ui(Clickable_KMsg), plain := false) -> (c, title, dismiss: Node) {
	begin_view(ui)
	column(ui, padding = .md)
	c = card(ui, padding = .sm, width = 320, key = 1)
	on_click: Maybe(Clickable_KMsg) = Clickable_KMsg(1)
	if plain do on_click = nil // a Maybe with nothing in it, not an empty message
	clickable(ui, c, on_click, label = "Message from Ada", on_context = Clickable_KMsg(3))
	row(ui, align = .Center, key = 2)
	title = text(ui, "Message from Ada", key = 3)
	spacer(ui, key = 4)
	dismiss = button(ui, "Dismiss", Clickable_KMsg(2), variant = .Ghost, icon = .X, icon_only = true, key = 5)
	end(ui)
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 300})
	return
}

@(private = "file")
centre_of :: proc(t: ^Tree, n: Node) -> [2]f32 {
	d := node_get(t, n)
	return {d.abs.x + d.abs.w / 2, d.abs.y + d.abs.h / 2}
}

@(private = "file")
click_at :: proc(ui: ^Ui(Clickable_KMsg), p: [2]f32) {
	pointer_button(ui, .Left, true, p)
	pointer_button(ui, .Left, false, p)
}

// A click on the card's text sends the card's message, a click on its own
// button only the button's. It is one Tab stop, before its button, and
// Enter or Space while it has focus send its message, a right-click or the
// Menu key its context message. A Button named by its label, it shows hover
// like a row. Made plain again it takes no click, focus or Button role.
@(test)
a_card_takes_a_click_and_its_buttons_keep_theirs :: proc(t: ^testing.T) {
	ui: Ui(Clickable_KMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	c, title, dismiss := note_card(&ui)
	tr := &ui.tree

	click_at(&ui, centre_of(tr, title))
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == Clickable_KMsg(1), "a click on its text takes the card's action")
	clear(&ui.msgs)
	click_at(&ui, centre_of(tr, dismiss))
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == Clickable_KMsg(2), "its own button keeps its click")
	clear(&ui.msgs)

	set_focus(tr, NODE_NONE, false)
	key_event(&ui, .Tab, true, {})
	testing.expect_value(t, tr.focus, c) // the card first
	key_event(&ui, .Tab, true, {})
	testing.expect_value(t, tr.focus, dismiss) // then its button
	set_focus(tr, c, true)
	key_event(&ui, .Enter, true, {})
	key_event(&ui, .Space, true, {})
	testing.expect(t, len(ui.msgs) == 2 && ui.msgs[0] == Clickable_KMsg(1) && ui.msgs[1] == Clickable_KMsg(1), "Enter and Space take it too")
	clear(&ui.msgs)

	testing.expect(t, context_press(&ui, centre_of(tr, title)), "a right-click on its text")
	set_focus(tr, c, true)
	key_event(&ui, .Menu, true, {})
	testing.expect(t, len(ui.msgs) == 2 && ui.msgs[0] == Clickable_KMsg(3) && ui.msgs[1] == Clickable_KMsg(3), "a right-click and the Menu key send its context message")
	clear(&ui.msgs)

	cd := node_get(tr, c)
	testing.expect(t, cd.access.role == .Button && cd.access.name == "Message from Ada", "a Button named by its label")
	testing.expect_value(t, lint(tr), 0)
	pointer_move(&ui, centre_of(tr, title))
	testing.expect(t, .Hovered in cd.flags, "the pointer over its text hovers the card")

	c, title, _ = note_card(&ui, plain = true)
	cd = node_get(tr, c)
	click_at(&ui, centre_of(tr, title))
	testing.expect(t, !context_press(&ui, centre_of(tr, title)), "no context message either")
	testing.expect_value(t, len(ui.msgs), 0)
	testing.expect(t, .Focusable not_in cd.flags && cd.access.role != .Button, "plain again: no focus, not a Button")
}

// A clickable takes the wheel as a button does, so a cell too small for a
// button (an 18 px workspace cell) keeps scroll-to-switch.
@(test)
a_clickable_takes_the_wheel :: proc(t: ^testing.T) {
	Wh_Msg :: union { int }
	ui: Ui(Wh_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	build :: proc(ui: ^Ui(Wh_Msg), wheel: bool) -> Node {
		begin_view(ui)
		row(ui, gap = 2)
		cell := box(ui, width = 18, height = 18, key = 1)
		clickable(ui, cell, Wh_Msg(1), label = "Workspace 1", tag = 40,
			on_scroll = (proc(e: Ev(Scroll)) -> Wh_Msg { return Wh_Msg(100 + e.value.steps.y + int(e.tag)) }) if wheel else nil)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {200, 40})
		return cell
	}
	cell := build(&ui, true)
	cd := node_get(&ui.tree, cell).abs
	at := [2]f32{cd.x + 9, cd.y + 9}

	// half a step: nothing yet, and the half is kept…
	testing.expect(t, !scroll_event(&ui, at, {0, SCROLL_STEP_PX * 0.5}) || len(ui.msgs) == 0 || ui.msgs[0] == Wh_Msg(140))
	clear(&ui.msgs)
	// …so the other half makes one whole step, as a button's wheel does
	build(&ui, true) // a rebuild in between keeps the leftover
	scroll_event(&ui, at, {0, SCROLL_STEP_PX * 0.5})
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == Wh_Msg(141), "one step, from two halves across a rebuild, and the cell's tag with it")

	// without on_scroll it does not take the wheel — built with the ternary
	// an app will write, `(proc …) if on else nil`, whose nil is a nil proc
	// inside the union, not a nil union: it must be a plain cell, not a crash
	build(&ui, false)
	clear(&ui.msgs)
	scroll_event(&ui, at, {0, SCROLL_STEP_PX})
	testing.expect_value(t, len(ui.msgs), 0)
}

} // when ODIN_TEST