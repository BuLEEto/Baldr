package baldr

@(require) import "base:runtime"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: about 9 GB without this `when`, 1 GB with it.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
three_buttons :: proc(ui: ^Ui(Test_Msg), middle_disabled := false) -> (a, b, c: Node) {
	begin_view(ui)
	column(ui, gap = .sm)
	a = button(ui, "A", Test_Msg.Inc)
	b = button(ui, "B", Test_Msg.Dec, disabled = middle_disabled)
	c = button(ui, "C", Test_Msg.Toggle)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {300, 300})
	return
}

@(test)
focus_tab_cycles_and_skips_disabled :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	a, _, c := three_buttons(&ui, middle_disabled = true)

	testing.expect(t, key_event(&ui, .Tab, true, {}))
	testing.expect_value(t, ui.focus, a)
	testing.expect(t, ui.focus_visible, "keyboard navigation shows the ring")
	key_event(&ui, .Tab, true, {})
	testing.expect_value(t, ui.focus, c) // b is disabled
	key_event(&ui, .Tab, true, {})
	testing.expect_value(t, ui.focus, a) // wraps
	key_event(&ui, .Tab, true, {.Shift})
	testing.expect_value(t, ui.focus, c) // backwards wraps too
	testing.expect(t, !key_event(&ui, .Tab, false, {}), "releases are ignored")
}

@(test)
focus_enter_and_space_activate :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	three_buttons(&ui)
	testing.expect(t, !key_event(&ui, .Enter, true, {}), "nothing focused: not consumed")
	key_event(&ui, .Tab, true, {})
	testing.expect(t, key_event(&ui, .Enter, true, {}))
	testing.expect(t, key_event(&ui, .Space, true, {}))
	testing.expect_value(t, len(ui.msgs), 2)
	testing.expect_value(t, ui.msgs[0], Test_Msg.Inc)
}

@(test)
focus_ring_only_when_visible :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	a, _, _ := three_buttons(&ui)
	count_rings :: proc(t: ^Tree) -> (n: int) {
		for c in draw_list(t) {
			if r, ok := c.(Draw_Rect); ok && r.border_w == 2 && r.color.a == 0 && r.border.a > 0.5 do n += 1
		}
		return
	}
	testing.expect_value(t, count_rings(&ui.tree), 0)

	// Pointer press focuses without a ring.
	r := node_get(&ui.tree, a).abs
	pointer_button(&ui, .Left, true, {r.x + 2, r.y + 2})
	pointer_button(&ui, .Left, false, {r.x + 2, r.y + 2})
	frame(&ui.tree, {300, 300})
	testing.expect_value(t, ui.focus, a)
	testing.expect(t, !ui.focus_visible)
	testing.expect_value(t, count_rings(&ui.tree), 0)

	// Tab makes it visible; exactly one ring, on the focused node (after the
	// ring's fade-in has run its course).
	key_event(&ui, .Tab, true, {})
	frame(&ui.tree, {300, 300})
	anim_tick(&ui.tree, 10_000)
	frame(&ui.tree, {300, 300})
	testing.expect(t, ui.focus_visible)
	testing.expect_value(t, count_rings(&ui.tree), 1)
	testing.expect(t, .Focused in node_get(&ui.tree, ui.focus).access.states, "a11y state follows")
}

// The ring goes when the keyboard leaves, and the focus does not. A ring
// left on a panel's button after its popover hands the keyboard back reads
// as "this is selected". Focus survives so Tab carries on from the same
// control when the keyboard returns and assistive technology still knows
// where it is; only the drawing stops.
@(test)
a_focus_ring_is_not_drawn_without_the_keyboard :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	a, _, _ := three_buttons(&ui)
	count_rings :: proc(t: ^Tree) -> (n: int) {
		for c in draw_list(t) {
			if r, ok := c.(Draw_Rect); ok && r.border_w == 2 && r.color.a == 0 && r.border.a > 0.5 do n += 1
		}
		return
	}

	key_event(&ui, .Tab, true, {})
	frame(&ui.tree, {300, 300})
	anim_tick(&ui.tree, 10_000)
	frame(&ui.tree, {300, 300})
	testing.expect_value(t, ui.focus, a)
	testing.expect_value(t, count_rings(&ui.tree), 1)

	// The keyboard goes elsewhere, as it does the moment a panel's popover
	// closes. The ring goes with it; the focus stays.
	tree_keyboard_set(&ui.tree, false)
	frame(&ui.tree, {300, 300})
	anim_tick(&ui.tree, 20_000)
	frame(&ui.tree, {300, 300})
	testing.expect_value(t, count_rings(&ui.tree), 0)
	testing.expect_value(t, ui.focus, a)
	testing.expect(t, ui.focus_visible, "the keyboard put it there; that is still true")
	testing.expect(t, .Focused in node_get(&ui.tree, a).access.states, "and assistive technology is still told")

	// …and it comes back with the keyboard, on the same control.
	tree_keyboard_set(&ui.tree, true)
	frame(&ui.tree, {300, 300})
	anim_tick(&ui.tree, 30_000)
	frame(&ui.tree, {300, 300})
	testing.expect_value(t, count_rings(&ui.tree), 1)
	testing.expect_value(t, ui.focus, a)
}

// Tab stays inside a popover whose own surface has the keyboard: a control
// outside it is on a surface the typing cannot reach, so Return would press
// something the person cannot see. A dialog traps Tab the same way.
@(test)
tab_stays_inside_a_popover_that_holds_the_keyboard :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {600, 400})

	begin_view(&ui)
	row(&ui)
	bar_btn := button(&ui, "Control Centre", Test_Msg.Inc, key = 1)
	end(&ui)
	here := runtime.Source_Code_Location{}
	pop, _ := overlay_begin(&ui, 0x1234, here)
	inside_a := button(&ui, "Preview one", Test_Msg.Inc, key = 2)
	inside_b := button(&ui, "Preview two", Test_Msg.Inc, key = 3)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 400})

	// Without the trap, Tab walks the page and reaches the bar.
	ui.tree.keyboard_popup = NODE_NONE
	set_focus(&ui.tree, NODE_NONE, false)
	focus_next(&ui.tree)
	testing.expect_value(t, ui.focus, bar_btn)

    // With the popup holding the keys, the first Tab lands on its first
	// control and the rest wrap inside it — the bar is never reached.
	ui.tree.keyboard_popup = pop
	set_focus(&ui.tree, NODE_NONE, false)
	focus_next(&ui.tree)
	testing.expect_value(t, ui.focus, inside_a)
	focus_next(&ui.tree)
	testing.expect_value(t, ui.focus, inside_b)
	focus_next(&ui.tree)
	testing.expect_value(t, ui.focus, inside_a) // wrapped, not out onto the bar

	// And backwards wraps the same way.
	focus_next(&ui.tree, backwards = true)
	testing.expect_value(t, ui.focus, inside_b)
}

@(test)
focus_is_dropped_with_the_node :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	three_buttons(&ui)
	key_event(&ui, .Tab, true, {})
	key_event(&ui, .Tab, true, {})
	begin_view(&ui)
	button(&ui, "only", Test_Msg.Inc)
	end_view(&ui)
	testing.expect(t, ui.focus == NODE_NONE || node_valid(&ui.tree, ui.focus), "no stale focus handle")
}

@(test)
theme_drives_button_colours_and_spacing :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	// The same view proc runs on every build, as in an app: nodes keep their identity.
	build :: proc(ui: ^Ui(Test_Msg)) -> (c, p, o: Node) {
		begin_view(ui)
		c = column(ui, gap = .lg)
		p = button(ui, "P", Test_Msg.Inc)
		o = button(ui, "O", Test_Msg.Inc, variant = .Outline)
		end(ui)
		end_view(ui)
		return
	}
	c, p, o := build(&ui)
	th := ui.theme
	testing.expect_value(t, node_get(&ui.tree, c).layout.gap, th.space[.lg])
	testing.expect_value(t, node_get(&ui.tree, p).style.bg, th.color.primary)
	testing.expect_value(t, node_get(&ui.tree, o).style.bg, Color{})
	testing.expect_value(t, node_get(&ui.tree, o).style.border, th.color.outline)

	// Swapping the theme and re-running the view re-resolves colours.
	set_theme(&ui.tree, theme_light())
	_, p2, _ := build(&ui)
	testing.expect_value(t, p2, p)
	testing.expect_value(t, node_get(&ui.tree, p).style.bg, theme_light().color.primary)
	testing.expect(t, !ui.theme.dark)
}

@(test)
theme_text_roles_and_defaults :: proc(t: ^testing.T) {
	ui: Ui(Test_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	h := text(&ui, "H", role = .Headline)
	b := text(&ui, "b")
	m := text(&ui, "m", muted = true)
	end_view(&ui)
	testing.expect_value(t, node_get(&ui.tree, h).kind.(Text_Kind).size, ui.theme.type.headline.size)
	testing.expect_value(t, node_get(&ui.tree, b).kind.(Text_Kind).size, ui.theme.type.body.size)
	testing.expect_value(t, node_get(&ui.tree, b).style.fg, ui.theme.color.on_surface)
	testing.expect_value(t, node_get(&ui.tree, m).style.fg, ui.theme.color.on_surface_muted)
}

} // when ODIN_TEST