package baldr

@(require) import "core:testing"
@(require) import "baldr:platform"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A bar, a dock or an applet is not a window: nothing takes the keyboard
// away from it and nothing hands it over, so without these rules a panel is
// pointer-only and a person who cannot use a pointer cannot reach it.
//
// Landing and leaving are the toolkit's, and both are here. The way in, a
// compositor binding that gives a panel the keyboard, is the compositor's:
// no client can supply it for itself on Wayland.

@(private = "file")
Pk_Msg :: union { int }

@(private = "file")
pk_ctx :: proc(kind: platform.Surface_Kind, keyboard: platform.Keyboard_Interactivity) -> ^Surface_Ctx(Pk_Msg) {
	c := new(Surface_Ctx(Pk_Msg))
	ui_init(&c.ui)
	c.surf = platform.Surface(1)
	c.kind = kind
	c.ui.surface.kind = kind
	c.desc.kind = kind
	c.desc.layer.keyboard = keyboard
	return c
}

@(private = "file")
pk_free :: proc(c: ^Surface_Ctx(Pk_Msg)) {
	ui_destroy(&c.ui)
	free(c)
}

// Three buttons in a bar. The first is what focus should land on.
@(private = "file")
pk_view :: proc(ui: ^Ui(Pk_Msg)) -> (first: Node) {
	begin_view(ui)
	row(ui, padding = .xs)
	first = button(ui, "Apps", Pk_Msg(1), key = 1)
	button(ui, "Files", Pk_Msg(2), key = 2)
	button(ui, "Clock", Pk_Msg(3), key = 3)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {800, 36})
	return
}

// The keyboard arriving at a bar is always deliberate — a click on it, or
// the compositor's own binding — so it lands on the first control and shows
// the ring. A bar that took the keyboard and showed nothing would leave the
// person with no way to tell it had happened, let alone where they were.
@(test)
a_panel_given_the_keyboard_lands_on_its_first_control :: proc(t: ^testing.T) {
	c := pk_ctx(.Layer, .On_Demand)
	defer pk_free(c)
	first := pk_view(&c.ui)

	testing.expect_value(t, c.ui.tree.focus, NODE_NONE) // nothing yet: the keyboard has not arrived
	keyboard_focus(c, c.surf, true)
	testing.expect(t, c.ui.entered_keyboard, "the arrival was noted for the view to act on")
	pk_view(&c.ui) // the view runs again, which is where focus is placed
	testing.expect_value(t, c.ui.tree.focus, first)
	testing.expect(t, c.ui.tree.focus_visible, "and the ring shows: the person must see where they are")
	testing.expect(t, !c.ui.entered_keyboard, "asked for once, not every build")
}

// Coming back to a bar keeps where the person was. Landing on the first
// control every time would throw away their place on every visit.
@(test)
a_panel_returned_to_keeps_where_focus_was :: proc(t: ^testing.T) {
	c := pk_ctx(.Layer, .On_Demand)
	defer pk_free(c)
	pk_view(&c.ui)
	keyboard_focus(c, c.surf, true)
	pk_view(&c.ui)
	focus_next(&c.ui.tree) // the person tabbed on to the second control
	was := c.ui.tree.focus

	keyboard_focus(c, c.surf, false) // …and the keyboard went elsewhere
	keyboard_focus(c, c.surf, true)  // …and came back
	testing.expect(t, !c.ui.entered_keyboard, "something is focused already: leave it alone")
	pk_view(&c.ui)
	testing.expect_value(t, c.ui.tree.focus, was)
}

// A click on a bar's empty space gives it the keyboard, but a press on
// nothing focuses nothing and a ring never follows a pointer press (see the
// top of focus.odin), so the landing is only for an arrival with no pointer
// in it.
@(test)
a_click_on_a_bar_lands_on_nothing_as_a_click_should :: proc(t: ^testing.T) {
	c := pk_ctx(.Layer, .On_Demand)
	defer pk_free(c)
	pk_view(&c.ui)

	// a press on the bar itself, hitting nothing focusable
	pointer_move(&c.ui, {400, 18})
	pointer_button(&c.ui, .Left, true, {400, 18})
	testing.expect(t, c.ui.pointer_took_focus, "the press decided focus")
	testing.expect_value(t, c.ui.tree.focus, NODE_NONE) // a press on nothing focuses nothing

	keyboard_focus(c, c.surf, true) // …and the keyboard arrives because of it
	testing.expect(t, !c.ui.entered_keyboard, "the press already said where focus goes")
	pk_view(&c.ui)
	testing.expect_value(t, c.ui.tree.focus, NODE_NONE)
	testing.expect(t, !c.ui.pointer_took_focus, "and the flag lasts one build, not for ever")

	// the keyboard arriving on its own after that still lands
	keyboard_focus(c, c.surf, false)
	keyboard_focus(c, c.surf, true)
	testing.expect(t, c.ui.entered_keyboard, "no pointer this time: land on the first control")
	pk_view(&c.ui)
	testing.expect(t, c.ui.tree.focus != NODE_NONE && c.ui.tree.focus_visible, "with the ring")
}

// A window is left alone: there the keyboard follows the desktop's window
// focus, and moving the ring on every alt-tab would be noise.
@(test)
a_window_gaining_the_keyboard_moves_no_focus :: proc(t: ^testing.T) {
	c := pk_ctx(.Window, .None)
	defer pk_free(c)
	pk_view(&c.ui)
	keyboard_focus(c, c.surf, true)
	testing.expect(t, !c.ui.entered_keyboard, "a window's focus is the desktop's business")
	pk_view(&c.ui)
	testing.expect_value(t, c.ui.tree.focus, NODE_NONE)
}

// Escape is the way out, which is what Escape means everywhere else. It
// clears focus and asks the run loop to hand the keyboard back — letting go
// is the compositor's to do, since a client cannot give focus to another.
@(test)
escape_hands_a_panels_keyboard_back :: proc(t: ^testing.T) {
	c := pk_ctx(.Layer, .On_Demand)
	defer pk_free(c)
	pk_view(&c.ui)
	keyboard_focus(c, c.surf, true)
	pk_view(&c.ui)
	testing.expect(t, c.ui.tree.focus != NODE_NONE, "in the bar")

	testing.expect(t, key_event(&c.ui, .Escape, true, {}), "Escape was taken")
	testing.expect_value(t, c.ui.tree.focus, NODE_NONE)
	testing.expect(t, c.ui.release_keyboard, "…and the compositor is asked to take it back")
}

// Escape is the *last* thing the surface tries: anything inside that wants
// it has it first. Here a popover is open, so Escape closes the popover and
// the bar keeps the keyboard — pressing it twice is what leaves.
@(test)
escape_leaves_a_panel_only_when_nothing_inside_wanted_it :: proc(t: ^testing.T) {
	c := pk_ctx(.Layer, .On_Demand)
	defer pk_free(c)
	ui := &c.ui
	open := true
	for _ in 0 ..< 2 { // built twice: the popover's own scope opens on the second
		begin_view(ui)
		row(ui, padding = .xs)
		b := button(ui, "Apps", Pk_Msg(1), key = 1)
		if popover(ui, b, open, Pk_Msg(9), key = 2) {
			button(ui, "Inside", Pk_Msg(3), key = 3)
			end(ui)
		}
		end(ui)
		end_view(ui)
		frame(&ui.tree, {800, 36})
	}
	keyboard_focus(c, c.surf, true)

	testing.expect(t, key_event(ui, .Escape, true, {}), "Escape was taken")
	testing.expect(t, !ui.release_keyboard, "…by the popover, not the bar: one Escape does one thing")
}

// A panel's button stays ringed after a menu navigated by key is escaped.
// One Escape does one thing (the test above): the popover takes it and the
// panel keeps the keyboard, and the popover closing gives focus back to its
// anchor with the ring, because the keyboard was used inside it. The panel
// still has the keyboard, so the ring is honest by the rule; whether one
// Escape on a panel should also hand the keyboard back is an open question.
// Without navigating inside the menu first, focus was never visible and no
// ring is drawn.
@(test)
a_panel_keeps_its_ring_after_a_menu_navigated_by_key_is_escaped :: proc(t: ^testing.T) {
	c := pk_ctx(.Layer, .On_Demand)
	defer pk_free(c)
	ui := &c.ui
	build :: proc(ui: ^Ui(Pk_Msg), open: bool) {
		for _ in 0 ..< 2 {
			begin_view(ui)
			row(ui, padding = .xs)
			b := button(ui, "Apps", Pk_Msg(1), key = 1)
			if popover(ui, b, open, Pk_Msg(9), key = 2) {
				button(ui, "Inside", Pk_Msg(3), key = 3)
				end(ui)
			}
			end(ui)
			end_view(ui)
			frame(&ui.tree, {800, 36})
		}
	}
	build(ui, true)
	keyboard_focus(c, c.surf, true)

	// The keyboard is used inside the menu, which is what makes focus visible.
	key_event(ui, .Tab, true, {})
	frame(&ui.tree, {800, 36})
	testing.expect(t, ui.tree.focus_visible, "the keyboard has been used")

	// Escape: the popover takes it, the panel keeps the keyboard.
	testing.expect(t, key_event(ui, .Escape, true, {}), "Escape was taken")
	testing.expect(t, !ui.release_keyboard, "by the popover, not the panel")
	build(ui, false)

	// …and that is a drawn ring on a surface that still has the keyboard.
	testing.expect(t, ui.surface.keyboard, "the panel still holds it")
	testing.expect(t, ring_shown(&ui.tree), "so the ring is drawn, and the button reads as selected")
}

// Any button's press cancels a pending landing. The compositor gives a bar
// the keyboard just before the press that earned it, which asks for a
// landing on the bar's first control. A right press (the context path) and a
// middle press must cancel it as a left one does, or the next build pulls
// focus out of the menu the press just opened and onto the bar behind it.
@(test)
any_press_cancels_a_pending_keyboard_landing :: proc(t: ^testing.T) {
	for button in ([]Mouse_Button{.Right, .Middle, .Left}) {
		c := pk_ctx(.Layer, .On_Demand)
		defer pk_free(c)
		pk_view(&c.ui)
		keyboard_focus(c, c.surf, true)
		testing.expect(t, c.ui.entered_keyboard, "the keyboard arriving asks for a landing")

		pointer_button(&c.ui, button, true, {10, 10})
		testing.expectf(t, !c.ui.entered_keyboard, "a %v press cancels the landing", button)
		testing.expectf(t, c.ui.pointer_took_focus, "a %v press decided focus", button)
	}
}

// A build that puts focus somewhere deliberately answers the question the
// landing was waiting on, and must not leave it to fire on the next build.
@(test)
a_pending_focus_clears_a_pending_landing :: proc(t: ^testing.T) {
	c := pk_ctx(.Layer, .On_Demand)
	defer pk_free(c)
	first := pk_view(&c.ui)
	keyboard_focus(c, c.surf, true)
	testing.expect(t, c.ui.entered_keyboard, "a landing is pending")

	c.ui.pending_focus = first // as a menu opening does
	pk_view(&c.ui)
	testing.expect(t, !c.ui.entered_keyboard, "the build that placed focus took the landing with it")
}

// A panel can say the keyboard should land on nothing. A bar reached from
// the keyboard wants its first control ringed: nothing else says where the
// person is. A full-screen overlay does not: its first button would look
// chosen and Enter would press it. Its keys are its own while nothing is
// focused.
@(test)
a_panel_can_keep_the_keyboard_from_landing_on_a_control :: proc(t: ^testing.T) {
	// The default: a bar lands on its first control.
	bar := pk_ctx(.Layer, .On_Demand)
	defer pk_free(bar)
	pk_view(&bar.ui)
	keyboard_focus(bar, bar.surf, true)
	testing.expect(t, bar.ui.entered_keyboard, "a bar lands on its first control, as before")

	// An overlay that says otherwise does not.
	over := pk_ctx(.Layer, .On_Demand)
	defer pk_free(over)
	over.desc.layer.keyboard_landing = .Nothing
	pk_view(&over.ui)
	keyboard_focus(over, over.surf, true)
	testing.expect(t, !over.ui.entered_keyboard, "an overlay keeps its keys while nothing is focused")
	testing.expect_value(t, over.ui.tree.focus, NODE_NONE)
}

// A surface that binds Escape itself gets it: a full-screen overlay with
// `shortcut(ui, "Escape", Cancel)` must close, not have `panel_escape` take
// the key and its keyboard with it. A bar has nothing to do with Escape and
// needs the way out; an overlay has its own meaning for it.
@(test)
a_surface_that_binds_escape_keeps_it :: proc(t: ^testing.T) {
	c := pk_ctx(.Layer, .On_Demand)
	defer pk_free(c)
	ui := &c.ui
	begin_view(ui)
	row(ui, padding = .xs)
	button(ui, "Copy", Pk_Msg(1), key = 1)
	end(ui)
	shortcut(ui, "Escape", Pk_Msg(7))
	end_view(ui)
	frame(&ui.tree, {800, 600})
	keyboard_focus(c, c.surf, true)

	key_event(ui, .Escape, true, {}) // offered to the focused control and the panel first
	testing.expect(t, !ui.release_keyboard, "the panel does not hand the keyboard back")
	testing.expect(t, shortcut_fire(ui, .Escape, true, {}), "the app's Escape fires")

	// Without the binding it is the panel's way out.
	clear(&ui.msgs)
	begin_view(ui)
	row(ui, padding = .xs)
	button(ui, "Copy", Pk_Msg(1), key = 1)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {800, 600})
	testing.expect(t, key_event(ui, .Escape, true, {}), "Escape was taken")
	testing.expect(t, ui.release_keyboard, "…by the panel, which hands the keyboard back")
}

// A `.Exclusive` layer surface keeps it. A session lock's whole job is to
// hold the keyboard and not let go, and Escape must not be a way off a lock
// screen — so the release asks the surface's own declaration first.
@(test)
escape_does_not_unlock_a_screen_that_asked_for_the_keyboard :: proc(t: ^testing.T) {
	c := pk_ctx(.Layer, .Exclusive)
	defer pk_free(c)
	pk_view(&c.ui)
	keyboard_focus(c, c.surf, true)
	pk_view(&c.ui)

	key_event(&c.ui, .Escape, true, {})
	// panel_escape does clear focus, as Escape does anywhere; what must not
	// happen is the surface letting the keyboard go.
	keyboard_release(nil, c)
	testing.expect(t, !c.keyboard_dropped, "no backend to ask, and nothing dropped")

	c.ui.release_keyboard = false
	c.desc.layer.keyboard = .Exclusive
	b: platform.Backend
	b.surface_set_layer = proc(b: ^platform.Backend, s: platform.Surface, l: platform.Layer_Desc, size: [2]f32) -> bool {
		(^int)(b.data)^ += 1
		return true
	}
	asked := 0
	b.data = &asked
	keyboard_release(&b, c)
	testing.expect_value(t, asked, 0)
	testing.expect(t, !c.keyboard_dropped, "an exclusive surface keeps the keyboard it asked for")
}

// The release and the restore are a frame apart on purpose: layer-shell
// state is applied on commit, so asking for None and On_Demand in one
// commit is a compositor that sees only the second and never moves focus.
@(test)
a_released_keyboard_is_asked_for_again_a_frame_later :: proc(t: ^testing.T) {
	c := pk_ctx(.Layer, .On_Demand)
	defer pk_free(c)

	Seen :: struct { modes: [dynamic]platform.Keyboard_Interactivity }
	seen: Seen
	seen.modes = make([dynamic]platform.Keyboard_Interactivity)
	defer delete(seen.modes)
	b: platform.Backend
	b.data = &seen
	b.surface_set_layer = proc(b: ^platform.Backend, s: platform.Surface, l: platform.Layer_Desc, size: [2]f32) -> bool {
		append(&(^Seen)(b.data).modes, l.keyboard)
		return true
	}

	keyboard_release(&b, c)
	testing.expect(t, c.keyboard_dropped && c.needs_frame, "dropped, and a frame asked for to put it back")
	keyboard_release(&b, c) // a second Escape before that frame asks nothing twice
	keyboard_restore(&b, c)
	testing.expect(t, !c.keyboard_dropped, "back to wanting it on demand")
	keyboard_restore(&b, c) // and every later frame leaves it alone

	testing.expect_value(t, len(seen.modes), 2)
	testing.expect_value(t, seen.modes[0], platform.Keyboard_Interactivity.None)
	testing.expect_value(t, seen.modes[1], platform.Keyboard_Interactivity.On_Demand)
}

}
