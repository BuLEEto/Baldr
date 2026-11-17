package baldr

@(require) import "core:testing"

// A dialog holding a form holds typed work, so a press on the scrim leaves
// it open, and everything that should close it still does: a dismissal is
// never the destructive choice (see `dialog`'s own comment).
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Dout_Msg :: union { Dout_Close }
@(private = "file")
Dout_Close :: struct {}

@(private = "file")
dout_view :: proc(ui: ^Ui(Dout_Msg), outside: bool) -> (card: Node) {
	set_viewport(&ui.tree, {500, 400})
	begin_view(ui)
	column(ui, flex = 1)
	if dialog(ui, true, Dout_Msg(Dout_Close{}), title = "Change passphrase",
		dismiss_outside = outside, key = 1) {
		defer end(ui)
		card = ui.scopes[len(ui.scopes) - 1].node
		text(ui, "Current passphrase")
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {500, 400})
	return
}

// A press beside it leaves it open — and Escape still closes it, so it is
// never a trap.
@(test)
a_press_beside_a_dialog_leaves_it_open :: proc(t: ^testing.T) {
	ui: Ui(Dout_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	dout_view(&ui, false)

	clear(&ui.msgs)
	pointer_button(&ui, .Left, true, {6, 6})
	pointer_button(&ui, .Left, false, {6, 6})
	testing.expect_value(t, len(ui.msgs), 0)

	testing.expect(t, key_event(&ui, .Escape, true, {}), "Escape is still the way out")
	testing.expect_value(t, len(ui.msgs), 1)
}

// An app that wants click-away — a picture at full size, an about box,
// something holding nothing worth keeping — asks for it.
@(test)
dismiss_outside_restores_the_click_away :: proc(t: ^testing.T) {
	ui: Ui(Dout_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	dout_view(&ui, true)

	clear(&ui.msgs)
	pointer_button(&ui, .Left, true, {6, 6})
	testing.expect_value(t, len(ui.msgs), 1)
}

// Whichever way it is set, the press never reaches the window behind: the
// scrim is still a scrim.
@(test)
the_scrim_swallows_the_press_either_way :: proc(t: ^testing.T) {
	for outside in ([]bool{false, true}) {
		ui: Ui(Dout_Msg)
		ui_init(&ui)
		defer ui_destroy(&ui)
		card := dout_view(&ui, outside)
		testing.expect(t, card != NODE_NONE)

		clear(&ui.msgs)
		pointer_button(&ui, .Left, true, {6, 6})
		testing.expectf(t, ui.pointer.pressed == NODE_NONE,
			"dismiss_outside = %v: nothing beneath the scrim took the press", outside)
	}
}

// A press inside the card does nothing at all, either way: typing in a
// field must not close the thing you are typing into.
@(test)
a_press_inside_the_card_never_dismisses :: proc(t: ^testing.T) {
	ui: Ui(Dout_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	card := dout_view(&ui, true) // even with click-away on
	r := node_get(&ui.tree, card).abs

	clear(&ui.msgs)
	pointer_button(&ui, .Left, true, {r.x + r.w / 2, r.y + r.h / 2})
	pointer_button(&ui, .Left, false, {r.x + r.w / 2, r.y + r.h / 2})
	testing.expect_value(t, len(ui.msgs), 0)
}

}
