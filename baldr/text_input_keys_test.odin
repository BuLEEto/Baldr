package baldr

@(require) import "core:testing"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A text field passes the keys it does not use on to `on_key`, with the
// modifiers held, so a list below it (a clipboard history, a launcher's
// results) can be walked and act on its current row.

@(private = "file")
Pressed :: struct { press: Key_Press, tag: u64 }
@(private = "file")
Bound :: struct {}
@(private = "file")
Submitted :: struct {}
@(private = "file")
Keys_Msg :: union { Pressed, Bound, Submitted }

@(private = "file")
Keys_Chord :: struct { key: Key, mods: Mods }

@(private = "file")
search :: proc(ui: ^Ui(Keys_Msg), keys: bool) -> Node {
	on_press :: proc(e: Ev(Key_Press)) -> Keys_Msg { return Pressed{e.value, e.tag} }
	on_sub :: proc(e: Ev(string)) -> Keys_Msg { return Submitted{} }
	h: Handler(Keys_Msg, Key_Press)
	if keys do h = on_press
	begin_view(ui)
	column(ui, gap = .sm)
	f := text_input(ui, nil, initial = "abc", label = "Search", on_key = h, on_submit = on_sub, tag = 7, key = 1)
	shortcut(ui, "Ctrl+R", Keys_Msg(Bound{}))
	shortcut(ui, "Ctrl+Page_Down", Keys_Msg(Bound{}))
	shortcut(ui, "Alt+Enter", Keys_Msg(Bound{}))
	end(ui)
	end_view(ui)
	frame(&ui.tree, {500, 300})
	return f
}

// heard presses `c` and returns what reached on_key, whether the key was
// consumed, and how many messages it sent.
@(private = "file")
heard :: proc(ui: ^Ui(Keys_Msg), c: Keys_Chord) -> (press: Key_Press, consumed: bool, sent: int) {
	clear(&ui.msgs)
	consumed = key_event(ui, c.key, true, c.mods)
	sent = len(ui.msgs)
	if sent == 1 {
		if p, is_press := ui.msgs[0].(Pressed); is_press && p.tag == 7 do press = p.press
	}
	return
}

@(test)
a_fields_on_key_hears_the_keys_it_does_not_use_with_their_modifiers :: proc(t: ^testing.T) {
	ui: Ui(Keys_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	f := search(&ui, true)
	set_focus(&ui.tree, f, true)
	s := text_input_state(&ui.tree, f)
	s.caret, s.anchor = 1, 1

	for c in ([]Keys_Chord{{.Down, {}}, {.Page_Up, {}}, {.Up, {.Shift}}, {.Delete, {.Shift}}, {.P, {.Ctrl}}, {.P, {.Ctrl, .Shift}},
		{.K, {.Alt}}, {.A, {.Alt}}, {.N1, {.Ctrl}}, {.Comma, {.Ctrl}}, {.Page_Down, {.Ctrl, .Shift}}}) {
		press, consumed, sent := heard(&ui, c)
		want := Key_Press{c.key, c.mods}
		testing.expectf(t, consumed && sent == 1 && press == want, "%v %v reaches on_key with its modifiers and the tag (got %v, %d messages)", c.mods, c.key, press, sent)
	}
	testing.expect(t, str(s.value^) == "abc", "Shift+Delete went to on_key, not the text")

	for c in ([]Keys_Chord{{.Delete, {}}, {.Left, {.Ctrl}}, {.Home, {.Shift}}, {.A, {.Ctrl}}, {.C, {.Ctrl}}, {.X, {.Ctrl}}, {.V, {.Ctrl}}}) {
		_, consumed, sent := heard(&ui, c)
		testing.expectf(t, consumed && sent == 0, "%v %v stays the field's", c.mods, c.key)
	}
	testing.expect(t, str(s.value^) == "ac", "Delete still deletes")

	for c in ([]Keys_Chord{{.Z, {.Ctrl}}, {.Y, {.Ctrl}}, {.Z, {.Ctrl, .Shift}}, {.P, {}}, {.P, {.Super}}, {.P, {.Ctrl, .Alt}}, {.F5, {.Ctrl}},
		{.Down, {.Alt}}, {.Page_Up, {.Super}}, {.R, {.Ctrl}}, {.Page_Down, {.Ctrl}}}) {
		_, _, sent := heard(&ui, c)
		testing.expectf(t, sent == 0, "%v %v goes on, not to on_key", c.mods, c.key)
	}
	clear(&ui.msgs)
	testing.expect(t, !key_event(&ui, .R, true, {.Ctrl}) && shortcut_fire(&ui, .R, true, {.Ctrl}), "a chord the window binds goes on to it")
	is_bound := false
	if len(ui.msgs) == 1 do _, is_bound = ui.msgs[0].(Bound)
	testing.expect(t, len(ui.msgs) == 1 && is_bound, "the window's binding fired")
}

@(test)
a_field_without_on_key_keeps_those_keys_as_before :: proc(t: ^testing.T) {
	ui: Ui(Keys_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	f := search(&ui, false)
	set_focus(&ui.tree, f, true)
	s := text_input_state(&ui.tree, f)
	s.caret, s.anchor = 1, 1
	testing.expect(t, key_event(&ui, .Delete, true, {.Shift}) && str(s.value^) == "ac", "Shift+Delete deletes")
	testing.expect(t, !key_event(&ui, .Down, true, {}), "Down goes on")
	testing.expect(t, !key_event(&ui, .P, true, {.Ctrl}), "Ctrl+P goes on to the window's shortcuts")
	testing.expect_value(t, len(ui.msgs), 0)
	// With no `on_key`, a modified Enter is still `on_submit`'s, so a dialog's
	// field submits however Enter was pressed rather than doing nothing.
	for mods in ([]Mods{{}, {.Shift}, {.Ctrl}}) {
		clear(&ui.msgs)
		consumed := key_event(&ui, .Enter, true, mods)
		sub := false
		if len(ui.msgs) == 1 do _, sub = ui.msgs[0].(Submitted)
		testing.expectf(t, consumed && sub, "%v Enter submits a field that has no on_key", mods)
	}
	// …but a chord the window bound is the window's even here, so a file
	// manager's Alt+Enter is Properties from its path field too.
	clear(&ui.msgs)
	testing.expect(t, !key_event(&ui, .Enter, true, {.Alt}), "the bound chord is not the field's")
	testing.expect_value(t, len(ui.msgs), 0)
}

// A find bar's Enter goes to the next match and Shift+Enter to the one
// before, which `on_submit` cannot express: `Ev(string)` carries no
// modifiers. So a *modified* Enter goes to `on_key` with its mods, as
// Shift+Delete does, and a plain Enter stays `on_submit`'s.
@(test)
a_fields_on_key_hears_enter_with_its_modifiers :: proc(t: ^testing.T) {
	ui: Ui(Keys_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	f := search(&ui, true)
	set_focus(&ui.tree, f, true)
	s := text_input_state(&ui.tree, f)
	s.caret, s.anchor = 1, 1

	// Shift, Ctrl and Shift+Ctrl: the app's, with the modifiers it needs to
	// tell "previous match" from "next".
	for c in ([]Keys_Chord{{.Enter, {.Shift}}, {.Enter, {.Ctrl}}, {.Enter, {.Ctrl, .Shift}}}) {
		press, consumed, sent := heard(&ui, c)
		want := Key_Press{c.key, c.mods}
		testing.expectf(t, consumed && sent == 1 && press == want, "%v Enter reaches on_key with its modifiers (got %v, %d messages)", c.mods, press, sent)
	}

	// A plain Enter is still a submit, and on_key never sees it.
	clear(&ui.msgs)
	testing.expect(t, key_event(&ui, .Enter, true, {}), "a plain Enter is the field's")
	sub := false
	if len(ui.msgs) == 1 do _, sub = ui.msgs[0].(Submitted)
	testing.expect(t, len(ui.msgs) == 1 && sub, "…and it submits rather than going to on_key")

	// Alt+Enter is bound by the window (Properties from a path field), so the
	// field declines it and the binding fires, as for any bound chord.
	clear(&ui.msgs)
	testing.expect(t, !key_event(&ui, .Enter, true, {.Alt}), "the chord the window bound is the window's")
	testing.expect_value(t, len(ui.msgs), 0)
	testing.expect(t, shortcut_fire(&ui, .Enter, true, {.Alt}), "…so the window's shortcut fires")
	bound := false
	if len(ui.msgs) == 1 do _, bound = ui.msgs[0].(Bound)
	testing.expect(t, len(ui.msgs) == 1 && bound, "the window's binding fired")

	testing.expect(t, str(s.value^) == "abc", "none of it typed or deleted anything")
}

@(private = "file", thread_local)
shared_copied: int

// Two fields on two surfaces editing one buffer (a lock screen's password
// card on every screen; a form shown twice). A field's caret and selection
// are its own and are fitted to the buffer when its surface builds; one
// whose buffer the other field shrank since must not use them past the end.
@(test)
two_fields_on_two_surfaces_can_share_one_buffer :: proc(t: ^testing.T) {
	shared := text_make("")
	defer text_destroy(&shared)
	build :: proc(ui: ^Ui(Test_Msg), v: ^Text) -> Node {
		begin_view(ui)
		column(ui, align = .Start)
		n := text_input(ui, v, label = "Name", width = 200)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {400, 200})
		return n
	}
	a, b: Ui(Test_Msg)
	ui_init(&a)
	ui_init(&b)
	defer { ui_destroy(&a); ui_destroy(&b) }
	na, nb := build(&a, &shared), build(&b, &shared)
	shared_copied = -1
	a.tree.clipboard = {set = proc(user: rawptr, text: string) -> bool {
		shared_copied = len(text)
		return true
	}}

	set_focus(&a.tree, na, true)
	text_event(&a, "hunter2")
	text_input_key(&a, .A, {.Ctrl}) // the first screen's field: all of it selected
	set_focus(&b.tree, nb, true)
	text_input_key(&b, .A, {.Ctrl})
	text_input_key(&b, .Backspace, {}) // the second's: all of it gone
	testing.expect_value(t, str(shared), "")

	// back on the first, not built since: its selection runs past the end of what is there
	text_input_key(&a, .C, {.Ctrl})
	testing.expect_value(t, shared_copied, -1) // nothing is selected in nothing: nothing copied
	text_event(&a, "x")
	testing.expect_value(t, str(shared), "x")
	testing.expect_value(t, text_input_state(&a.tree, na).caret, 1)
}

} // when ODIN_TEST