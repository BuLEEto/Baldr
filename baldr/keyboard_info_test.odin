package baldr

@(require) import "core:testing"
@(require) import "baldr:platform"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: behind this `when`, checking a program costs
// 1.0 GB instead of 9.2 GB. ODIN_TEST is set by `odin test`; BALDR_TESTS
// lets ./build.sh check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Which surface has the keyboard, the lock keys, the layout (what a lock
// screen shows), and a password field saying Caps Lock is on.


@(private = "file")
Kb_Msg :: union { int }

@(test)
the_keyboards_state_reaches_every_view :: proc(t: ^testing.T) {
	rt: Runtime(int, Kb_Msg)
	defer {
		for c in rt.ctxs {
			ui_destroy(&c.ui)
			free(c)
		}
		delete(rt.ctxs)
		delete(rt.keyboard.layout)
	}
	for i in 0 ..< 2 {
		c := new(Surface_Ctx(Kb_Msg))
		ui_init(&c.ui)
		c.surf = platform.Surface(i + 1)
		append(&rt.ctxs, c)
	}
	name := "English (UK)"
	keyboard_event(&rt, {locks = {.Caps}, layout = name, layouts = 2})
	for c in rt.ctxs {
		testing.expect_value(t, keyboard_locks(&c.ui), Lock_Keys{.Caps})
		got, n := keyboard_layout(&c.ui)
		testing.expect(t, got == "English (UK)" && n == 2, "the layout and how many there are")
		testing.expect(t, raw_data(got) != raw_data(name), "the toolkit's own copy")
		testing.expect(t, c.needs_view, "and the view is built again")
		c.needs_view = false
	}
	keyboard_event(&rt, {layout = "Russian", layouts = 2}) // the old name freed: the leak check says so
	got, _ := keyboard_layout(&rt.ctxs[1].ui)
	testing.expect(t, keyboard_locks(&rt.ctxs[0].ui) == {} && got == "Russian", "Caps Lock off, the other layout")

	// which surface has the keyboard: it, or a popup of it, counts
	c := rt.ctxs[0]
	c.needs_view = false
	keyboard_focus(c, c.surf, true)
	testing.expect(t, c.ui.surface.keyboard && c.needs_view, "it has the keyboard: built again")
	c.needs_view = false
	keyboard_focus(c, 9, true) // its popup takes it…
	keyboard_focus(c, c.surf, false)
	testing.expect(t, c.ui.surface.keyboard && !c.needs_view, "…still this surface's: nothing to build again")
	keyboard_focus(c, 9, false)
	testing.expect(t, !c.ui.surface.keyboard && c.needs_view, "gone: built again")
}

@(private = "file")
kb_field :: proc(ui: ^Ui(Kb_Msg), password: bool) -> Node {
	begin_view(ui)
	column(ui, align = .Start, padding = .md)
	n := text_input(ui, nil, label = "Password", password = password, width = 240)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 200})
	return n
}

@(private = "file")
kb_sign :: proc(t: ^Tree) -> (Draw_Icon, bool) {
	for c in draw_list(t) do if ic, ok := c.(Draw_Icon); ok && ic.icon == .Arrow_Big_Up_Dash do return ic, true
	return {}, false
}

@(test)
a_password_field_says_caps_lock_is_on :: proc(t: ^testing.T) {
	ui: Ui(Kb_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := kb_field(&ui, true)
	d := node_get(&ui.tree, n)
	testing.expect_value(t, d.access.describe, "")

	ui.tree.keyboard.locks = {.Caps}
	n = kb_field(&ui, true)
	d = node_get(&ui.tree, n)
	testing.expect_value(t, d.access.describe, "Caps Lock is on") // a screen reader hears it
	_, shown := kb_sign(&ui.tree)
	testing.expect(t, !shown, "no sign on a field that hasn't the keyboard")

	set_focus(&ui.tree, n, true)
	frame(&ui.tree, {400, 200})
	sign, on := kb_sign(&ui.tree)
	testing.expect(t, on, "with the keyboard, the sign shows")
	testing.expect(t, sign.pos.x + sign.size <= d.abs.x + d.abs.w && sign.pos.x > d.abs.x + d.abs.w / 2, "at the field's end")
	testing.expect(t, contrast_ratio(sign.color, d.style.bg) >= 3, "and it reads: 3:1, as any sign that means something")

	// typed past the field's width, the text and the caret stop short of it
	text_event(&ui, "correct horse battery staple")
	frame(&ui.tree, {400, 200})
	sign, _ = kb_sign(&ui.tree)
	s := text_input_state(&ui.tree, n)
	caret := input_caret_rect(&ui.tree, n, d, s)
	testing.expect(t, caret.x < sign.pos.x, "the caret stays clear of the sign")

	ui.tree.keyboard.locks = {.Num} // Caps Lock off, Num Lock on: not the field's business
	n = kb_field(&ui, true)
	_, on = kb_sign(&ui.tree)
	testing.expect(t, !on && node_get(&ui.tree, n).access.describe == "", "Caps Lock off: the sign and the words go")

	ui.tree.keyboard.locks = {.Caps}
	ui2: Ui(Kb_Msg)
	ui_init(&ui2)
	defer ui_destroy(&ui2)
	ui2.tree.keyboard.locks = {.Caps}
	m := kb_field(&ui2, false)
	set_focus(&ui2.tree, m, true)
	frame(&ui2.tree, {400, 200})
	_, on = kb_sign(&ui2.tree)
	testing.expect(t, !on && node_get(&ui2.tree, m).access.describe == "", "an ordinary field says nothing of Caps Lock")
}

} // when ODIN_TEST