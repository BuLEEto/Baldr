package baldr

@(require) import "core:testing"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Right-click and scroll on a button, as a shell's tray icon uses them.


@(private = "file")
B_Click :: struct {}

@(private = "file")
B_Menu :: struct {}

@(private = "file")
B_Scroll :: struct {
	steps:   [2]int,
	delta:   [2]f32,
	precise: bool,
	shift:   bool,
}

@(private = "file")
ButtonEvents_BMsg :: union { B_Click, B_Menu, B_Scroll }

@(private = "file")
on_tray_scroll :: proc(e: Ev(Scroll)) -> ButtonEvents_BMsg {
	return B_Scroll{steps = e.value.steps, delta = e.value.delta, precise = e.value.precise, shift = .Shift in e.value.mods}
}

// tray_view: a tray icon with a menu and a scroll, and a list holding a
// button that listens to the wheel too.
@(private = "file")
tray_view :: proc(ui: ^Ui(ButtonEvents_BMsg), disabled := false) -> (tray, listed: Node) {
	set_viewport(&ui.tree, {400, 300})
	begin_view(ui)
	column(ui, padding = .lg, gap = .md)
	tray = button(ui, "Volume", ButtonEvents_BMsg(B_Click{}), disabled = disabled, on_context = ButtonEvents_BMsg(B_Menu{}), on_scroll = on_tray_scroll)
	scroll(ui, height = 80)
	listed = button(ui, "In a list", ButtonEvents_BMsg(B_Click{}), on_scroll = on_tray_scroll)
	for _ in 0 ..< 12 do text(ui, "row")
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 300})
	return
}

@(private = "file")
scrolled :: proc(ui: ^Ui(ButtonEvents_BMsg), i: int) -> B_Scroll {
	if i >= len(ui.msgs) do return {steps = {-99, -99}}
	s, _ := ui.msgs[i].(B_Scroll)
	return s
}

@(test)
a_right_click_or_the_menu_key_asks_a_button_for_its_menu :: proc(t: ^testing.T) {
	ui: Ui(ButtonEvents_BMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.motion.reduce = true
	tray, _ := tray_view(&ui)
	d := node_get(&ui.tree, tray)
	at := [2]f32{d.abs.x + 5, d.abs.y + 5}

	pointer_button(&ui, .Right, true, at)
	pointer_button(&ui, .Right, false, at)
	testing.expect_value(t, len(ui.msgs), 1)
	if len(ui.msgs) == 1 {
		_, is_menu := ui.msgs[0].(B_Menu)
		testing.expect(t, is_menu, "its menu, not its click")
	}
	testing.expect_value(t, ui.context_pos, at) // a context_menu opens where it was clicked
	testing.expect_value(t, ui.tree.focus, tray)

	clear(&ui.msgs)
	key_event(&ui, .Menu, true, {})
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.context_pos, [2]f32{d.abs.x, d.abs.y + d.abs.h}) // from the keyboard: under the button
	clear(&ui.msgs)
	key_event(&ui, .F10, true, {.Shift})
	testing.expect_value(t, len(ui.msgs), 1) // Shift+F10 too

	clear(&ui.msgs)
	tray_view(&ui, disabled = true)
	pointer_button(&ui, .Right, true, at)
	pointer_button(&ui, .Right, false, at)
	testing.expect_value(t, len(ui.msgs), 0) // a disabled button offers no menu
}

@(test)
a_scroll_over_a_button_is_its_own_and_takes_no_focus :: proc(t: ^testing.T) {
	ui: Ui(ButtonEvents_BMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.motion.reduce = true
	tray, listed := tray_view(&ui)
	td := node_get(&ui.tree, tray)
	over := [2]f32{td.abs.x + 5, td.abs.y + 5}

	testing.expect(t, scroll_event(&ui, over, {0, SCROLL_STEP_PX}), "one wheel click down")
	testing.expect(t, scroll_event(&ui, over, {0, -2 * SCROLL_STEP_PX}), "two up")
	testing.expect(t, len(ui.msgs) == 2 && scrolled(&ui, 0).steps == {0, 1} && scrolled(&ui, 1).steps == {0, -2}, "whole wheel steps, +y down")

	clear(&ui.msgs)
	for _ in 0 ..< 3 do scroll_event(&ui, over, {0, 20}, precise = true) // a touchpad's 60 px
	testing.expect(t, len(ui.msgs) == 3 && scrolled(&ui, 0).steps == {} && scrolled(&ui, 1).steps == {} && scrolled(&ui, 2).steps == {0, 1} && scrolled(&ui, 2).precise, "smooth scrolling adds up to a step")

	clear(&ui.msgs)
	scroll_event(&ui, over, {10, 0}, mods = {.Shift})
	testing.expect(t, len(ui.msgs) == 1 && scrolled(&ui, 0).shift && scrolled(&ui, 0).delta == {10, 0}, "with its modifiers and the event's px")
	testing.expect_value(t, ui.tree.focus, NODE_NONE) // scrolling takes no focus

	// a button inside a list takes the wheel; elsewhere the list scrolls
	clear(&ui.msgs)
	view := listed
	for view != NODE_NONE {
		cur := node_get(&ui.tree, view)
		if cur == nil || .Scroll_V in cur.flags do break
		view = cur.parent
	}
	testing.expect(t, view != NODE_NONE, "the list scrolls")
	before := scroll_offset(&ui.tree, view)
	ld := node_get(&ui.tree, listed)
	testing.expect(t, scroll_event(&ui, {ld.abs.x + 5, ld.abs.y + 5}, {0, SCROLL_STEP_PX}))
	testing.expect(t, len(ui.msgs) == 1 && scroll_offset(&ui.tree, view) == before, "the button took it; the list stayed")
	vd := node_get(&ui.tree, view)
	testing.expect(t, scroll_event(&ui, {vd.abs.x + vd.abs.w - 5, vd.abs.y + vd.abs.h - 5}, {0, SCROLL_STEP_PX}) && scroll_offset(&ui.tree, view) != before, "past the button the list scrolls")

	clear(&ui.msgs)
	tray_view(&ui, disabled = true)
	testing.expect(t, !scroll_event(&ui, over, {0, SCROLL_STEP_PX}) && len(ui.msgs) == 0, "a disabled button lets the wheel pass")
}

} // when ODIN_TEST