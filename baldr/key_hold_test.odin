package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: behind this `when`, checking a program costs
// 1.0 GB instead of 9.2 GB. ODIN_TEST is set by `odin test`; BALDR_TESTS
// lets ./build.sh check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Keys held and let go on a focused node: an image editor's temporary tools
// (Space for the hand, Alt to sample).


@(private = "file")
Kh_Msg :: union { Key_Hold }

@(private = "file")
editor :: proc(ui: ^Ui(Kh_Msg), field: ^Text) -> (area, input, outside: Node) {
	begin_view(ui)
	row(ui)
	area = column(ui, width = 300, height = 200, key = 1)
	key_hold(ui, area, {.Space, .Alt_L}, proc(e: Ev(Key_Hold)) -> Kh_Msg { return e.value })
	input = text_input(ui, field, label = "Name", key = 2)
	end(ui)
	outside = button(ui, "Elsewhere", Kh_Msg{}, key = 3)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 300})
	return
}

@(private = "file")
holds :: proc(ui: ^Ui(Kh_Msg)) -> (out: [dynamic]Key_Hold) {
	out = make([dynamic]Key_Hold, context.temp_allocator)
	for m in ui.msgs do if h, ok := m.(Key_Hold); ok do append(&out, h)
	return
}

@(private = "file")
press :: proc(ui: ^Ui(Kh_Msg), k: Key, down: bool, mods: Mods = {}) {
	// The run loop's order: the focused control, then the keys held, then the
	// window's shortcuts (app.odin).
	if key_event(ui, k, down, mods) do return
	if key_hold_event(ui, k, down, mods) do return
	shortcut_fire(ui, k, down, mods)
}

// A chord is the window's, not a held key's: a canvas holding Z to zoom
// must not swallow Ctrl+Z. A key pressed with Ctrl, Alt or Super down
// passes on; a key that is one of those may still be held, which is how a
// momentary tool like an eyedropper on Alt is asked for.
@(test)
a_key_held_with_ctrl_goes_to_the_shortcut :: proc(t: ^testing.T) {
	ui: Ui(Kh_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	field := text_make("")
	defer text_destroy(&field)
	editor(&ui, &field)
	shortcut(&ui, "Ctrl+Space", Kh_Msg{}) // stands in for Ctrl+Z

	// Ctrl held: the hold does not take it, and the shortcut fires.
	press(&ui, .Space, true, {.Ctrl})
	testing.expect_value(t, len(holds(&ui)), 0)
	testing.expect_value(t, len(ui.msgs), 1)

	// Without Ctrl it is the hold's, as before.
	clear(&ui.msgs)
	press(&ui, .Space, true)
	press(&ui, .Space, false)
	testing.expect_value(t, len(holds(&ui)), 2)

	// Shift is not a chord: a held key with Shift down still works.
	clear(&ui.msgs)
	press(&ui, .Space, true, {.Shift})
	press(&ui, .Space, false, {.Shift})
	testing.expect_value(t, len(holds(&ui)), 2)

	// A key that *is* a modifier may be held while it is that modifier —
	// Alt arrives with Alt down, and an eyedropper still works.
	clear(&ui.msgs)
	press(&ui, .Alt_L, true, {.Alt})
	press(&ui, .Alt_L, false, {})
	h := holds(&ui)
	testing.expect(t, len(h) == 2 && h[0].down && !h[1].down, "Alt held even with Alt down")

	// A key already held stays held when a modifier is pressed after it: the
	// release must still arrive, or the app is stuck in its temporary tool.
	clear(&ui.msgs)
	press(&ui, .Space, true)
	press(&ui, .Space, true, {.Ctrl}) // a repeat while Ctrl went down
	press(&ui, .Space, false, {.Ctrl})
	h = holds(&ui)
	testing.expect(t, len(h) == 2 && h[0].down && !h[1].down, "held through, and let go")
}

@(test)
a_node_hears_a_key_held_and_let_go :: proc(t: ^testing.T) {
	ui: Ui(Kh_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	field := text_make("")
	defer text_destroy(&field)
	_, input, outside := editor(&ui, &field)

	press(&ui, .Space, true) // nothing focused: the window's, so the area's
	press(&ui, .Space, true) // the key repeating: still just held
	press(&ui, .Space, true)
	press(&ui, .Space, false)
	h := holds(&ui)
	testing.expect_value(t, len(h), 2)
	if len(h) == 2 do testing.expect(t, h[0] == {.Space, true} && h[1] == {.Space, false}, "down once, then up")

	clear(&ui.msgs)
	press(&ui, .Alt_R, true) // either Alt
	press(&ui, .Alt_R, false)
	h = holds(&ui)
	testing.expect(t, len(h) == 2 && h[0].key == .Alt_R && h[0].down && !h[1].down, "the other side of a modifier")

	clear(&ui.msgs)
	set_focus(&ui.tree, input, true) // a field keeps its Space
	press(&ui, .Space, true)
	press(&ui, .Space, false)
	testing.expect_value(t, len(holds(&ui)), 0)

	clear(&ui.msgs) // focus outside the area: not its keys
	set_focus(&ui.tree, outside, true)
	press(&ui, .Alt_L, true)
	testing.expect_value(t, len(holds(&ui)), 0)
	press(&ui, .Alt_L, false)

	clear(&ui.msgs) // held, then the focus moves away: the release still comes
	set_focus(&ui.tree, NODE_NONE, false)
	press(&ui, .Alt_L, true)
	set_focus(&ui.tree, outside, true)
	press(&ui, .Alt_L, false)
	h = holds(&ui)
	testing.expect(t, len(h) == 2 && !h[1].down, "let go wherever the focus went")

	clear(&ui.msgs) // held as the window loses the keyboard
	set_focus(&ui.tree, NODE_NONE, false)
	press(&ui, .Space, true)
	key_holds_release(&ui)
	h = holds(&ui)
	testing.expect(t, len(h) == 2 && h[1] == {.Space, false}, "let go when the keyboard went")
}

} // when ODIN_TEST