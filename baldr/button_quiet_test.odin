package baldr

@(require) import "core:testing"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A button that answers the pointer another way (a dock's icon growing),
// not by a wash behind it. `quiet` takes the hover and press state layers
// off; everything else about the button stays.


@(private = "file")
ButtonQuiet_QMsg :: union { int }

@(private = "file")
dock :: proc(ui: ^Ui(ButtonQuiet_QMsg), quiet: bool) -> Node {
	begin_view(ui)
	row(ui, height = 48, padding = .xs, align = .Center)
	b := button(ui, "Files", ButtonQuiet_QMsg(1), variant = .Ghost, icon = .Check, icon_only = true)
	button_options(ui, b, quiet = quiet, mark = Button_Mark{side = .Bottom, length = 6})
	end(ui)
	end_view(ui)
	frame(&ui.tree, {200, 48})
	return b
}

// fill: the colour painted over the whole of button `b`, if anything is.
@(private = "file")
fill :: proc(ui: ^Ui(ButtonQuiet_QMsg), b: Node) -> (color: Color, ok: bool) {
	bd := node_get(&ui.tree, b)
	for c in draw_list(&ui.tree) {
		r, is_rect := c.(Draw_Rect)
		if is_rect && r.rect == bd.abs do return r.color, true
	}
	return
}

// settle_quiet: hover the middle of `b` (or leave it) and run the wash's tween out.
@(private = "file")
settle_quiet :: proc(ui: ^Ui(ButtonQuiet_QMsg), b: Node, over: bool, press := false) {
	bd := node_get(&ui.tree, b)
	at := [2]f32{bd.abs.x + bd.abs.w / 2, bd.abs.y + bd.abs.h / 2} if over else {-10, -10}
	pointer_move(ui, at)
	if press do pointer_button(ui, .Left, true, at)
	for _ in 1 ..= 4 { // past motion.fast, so the tween is at its end
		anim_tick(&ui.tree, ui.tree.now_ms + f64(ui.tree.theme.motion.fast))
		frame(&ui.tree, {200, 48})
	}
}

@(test)
a_quiet_button_draws_no_hover_or_press_wash :: proc(t: ^testing.T) {
	ui: Ui(ButtonQuiet_QMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	b := dock(&ui, quiet = true)
	settle_quiet(&ui, b, over = false)
	rest, rested := fill(&ui, b)

	settle_quiet(&ui, b, over = true)
	hovered, drew := fill(&ui, b)
	testing.expect(t, .Hovered in node_get(&ui.tree, b).flags, "it still knows the pointer is on it")
	testing.expectf(t, drew == rested && hovered == rest, "hover paints nothing new (was %v %v, now %v %v)", rested, rest, drew, hovered)

	settle_quiet(&ui, b, over = true, press = true)
	pressed, drew_pressed := fill(&ui, b)
	testing.expect(t, .Pressed in node_get(&ui.tree, b).flags, "and that it is held")
	testing.expectf(t, drew_pressed == rested && pressed == rest, "nor does a press (%v %v)", drew_pressed, pressed)
}

// The wash is what goes; the rest of the button is untouched.
@(test)
a_quiet_button_keeps_its_ring_mark_and_role :: proc(t: ^testing.T) {
	ui: Ui(ButtonQuiet_QMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	b := dock(&ui, quiet = true)
	bd := node_get(&ui.tree, b)
	testing.expect_value(t, bd.access.role, Role.Button)
	testing.expect(t, .Focusable in bd.flags, "still reached by Tab")
	testing.expect(t, bd.access.name == "Files", "still named for a screen reader")

	mark := false
	for c in draw_list(&ui.tree) {
		r, is_rect := c.(Draw_Rect)
		if is_rect && r.rect.h == BUTTON_MARK_THICKNESS && r.rect.w == 6 do mark = true
	}
	testing.expect(t, mark, "its running mark is drawn as before")

	set_focus(&ui.tree, b, true)
	for _ in 1 ..= 4 { // the ring grows over motion.fast
		anim_tick(&ui.tree, ui.tree.now_ms + f64(ui.tree.theme.motion.fast))
		frame(&ui.tree, {200, 48})
	}
	ring := false
	for c in draw_list(&ui.tree) {
		if r, is_rect := c.(Draw_Rect); is_rect && r.border_w > 0 do ring = true
	}
	testing.expect(t, ring, "and the focus ring still shows")
}

// A plain button in the same place does wash, so the quiet one is the
// difference and not the test looking in the wrong place.
@(test)
a_plain_button_still_washes_on_hover :: proc(t: ^testing.T) {
	ui: Ui(ButtonQuiet_QMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	b := dock(&ui, quiet = false)
	settle_quiet(&ui, b, over = false)
	rest, _ := fill(&ui, b)
	settle_quiet(&ui, b, over = true)
	hovered, drew := fill(&ui, b)
	testing.expect(t, drew, "a hovered button paints over itself")
	testing.expectf(t, hovered != rest, "and it is not the resting colour (%v)", hovered)
}

} // when ODIN_TEST