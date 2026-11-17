package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: behind this `when`, checking a program costs
// 1.0 GB instead of 9.2 GB. ODIN_TEST is set by `odin test`; BALDR_TESTS
// lets ./build.sh check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Capturing a chord: the view says it is listening, and every press comes
// to it — modifiers included, so the field can show the chord forming —
// instead of reaching the focused widget or the window's shortcuts.


@(private = "file")
Cap_Msg :: union {
	Chord,
	int, // what a shortcut or a widget would have sent instead
}

@(private = "file")
captured :: proc(e: Ev(Chord)) -> Cap_Msg { return e.value }

@(private = "file")
listening :: proc(ui: ^Ui(Cap_Msg), on: bool) -> Node {
	begin_view(ui)
	b := button(ui, "OK", Cap_Msg(1))
	shortcut(ui, "Ctrl+N", Cap_Msg(2))
	key_capture(ui, on, captured)
	end_view(ui)
	frame(&ui.tree, {400, 200})
	return b
}

@(test)
a_capture_takes_the_chord_the_window_would_have_used :: proc(t: ^testing.T) {
	ui: Ui(Cap_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	listening(&ui, true)
	clear(&ui.msgs)

	took := capture_key(&ui, .N, true, {.Ctrl}, "n")
	testing.expect(t, took, "the capture takes it")
	testing.expect_value(t, len(ui.msgs), 1)
	c, is_chord := ui.msgs[0].(Chord)
	testing.expect(t, is_chord, "and reports the chord, not the shortcut's message")
	testing.expect_value(t, c.key, Key.N)
	testing.expect_value(t, c.mods, Mods{.Ctrl})
	testing.expect_value(t, c.keysym, "n")
	testing.expect(t, !c.held, "a key with the modifiers is the answer")
	testing.expect_value(t, chord_text(c), "Ctrl+N")
}

@(test)
a_capture_shows_the_chord_as_it_is_pressed :: proc(t: ^testing.T) {
	ui: Ui(Cap_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	listening(&ui, true)
	clear(&ui.msgs)

	// Super goes down: nothing has been chosen yet, but the field can say so
	capture_key(&ui, .Super_L, true, {.Super}, "Super_L")
	testing.expect_value(t, len(ui.msgs), 1)
	c, _ := ui.msgs[0].(Chord)
	testing.expect(t, c.held, "only modifiers are down")
	testing.expect_value(t, chord_text(c), "Super+")

	// …then the last key arrives
	clear(&ui.msgs)
	capture_key(&ui, .Q, true, {.Super}, "q")
	c, _ = ui.msgs[0].(Chord)
	testing.expect(t, !c.held)
	testing.expect_value(t, chord_text(c), "Super+Q")

	// letting a modifier go shows the smaller chord
	clear(&ui.msgs)
	capture_key(&ui, .Super_L, false, {.Super}, "Super_L")
	c, _ = ui.msgs[0].(Chord)
	testing.expect(t, c.held)
	testing.expect_value(t, chord_text(c), "")
}

@(test)
a_capture_reports_a_key_the_enum_has_no_name_for :: proc(t: ^testing.T) {
	// the point of carrying the platform's own name: a keyboard's own keys
	// go in the configuration file by keysym
	ui: Ui(Cap_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	listening(&ui, true)
	clear(&ui.msgs)

	capture_key(&ui, .Volume_Up, true, {}, "XF86AudioRaiseVolume")
	c, _ := ui.msgs[0].(Chord)
	testing.expect_value(t, c.key, Key.Volume_Up)
	testing.expect_value(t, c.keysym, "XF86AudioRaiseVolume")
	testing.expect_value(t, chord_text(c), "Volume Up")

	// one the enum does not name still arrives, by its platform name
	clear(&ui.msgs)
	capture_key(&ui, .Unknown, true, {.Ctrl}, "XF86Launch5")
	c, _ = ui.msgs[0].(Chord)
	testing.expect_value(t, chord_text(c), "Ctrl+XF86Launch5")
}

@(test)
nothing_is_captured_unless_the_view_asks :: proc(t: ^testing.T) {
	ui: Ui(Cap_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	listening(&ui, false)
	clear(&ui.msgs)

	testing.expect(t, !capture_key(&ui, .N, true, {.Ctrl}, "n"), "no capture: the key goes on as usual")
	testing.expect(t, !ui.capture.inhibit, "and the desktop keeps its own shortcuts")
	testing.expect(t, shortcut_fire(&ui, .N, true, {.Ctrl}), "Ctrl+N is still the window's")

	// while listening, the window's shortcuts are held off as well
	listening(&ui, true)
	testing.expect(t, ui.capture.inhibit, "the desktop is asked to stand back")

	// …and a build that only asks for the inhibit gets it without a capture
	begin_view(&ui)
	inhibit_shortcuts(&ui, true)
	end_view(&ui)
	testing.expect(t, ui.capture.inhibit && !ui.capture.on, "the desktop stands back, nothing is captured")
}

@(test)
a_capture_stays_out_of_a_modal :: proc(t: ^testing.T) {
	ui: Ui(Cap_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	listening(&ui, true)
	clear(&ui.msgs)
	ui.tree.modal = ui.tree.root // a dialog is up
	testing.expect(t, !capture_key(&ui, .N, true, {.Ctrl}, "n"), "a dialog is the only thing listening")
	testing.expect_value(t, len(ui.msgs), 0)
}

@(test)
a_captured_chord_is_not_also_typed :: proc(t: ^testing.T) {
	// the pane doing the rebinding may have a search field focused: the
	// chord must not land in it as text
	ui: Ui(Cap_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	listening(&ui, false)
	testing.expect(t, !capture_takes_text(&ui), "nothing is captured: typing is typing")
	listening(&ui, true)
	testing.expect(t, capture_takes_text(&ui), "while listening, the character belongs to the chord")
	ui.tree.modal = ui.tree.root
	testing.expect(t, !capture_takes_text(&ui), "a dialog takes precedence over both")
}

} // when ODIN_TEST