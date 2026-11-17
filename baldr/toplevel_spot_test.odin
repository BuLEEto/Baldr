package baldr

// A taskbar button saying where it is: the compositor flies a
// minimising window into the thing that stands for it, so it has to know
// where that is. What is worth pinning is not the protocol call but the
// bookkeeping around it — which spots still mean anything, and in which
// order they are sent when two bars show the same window.

@(require) import "core:testing"

when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Spot_Msg :: union { u64 }

@(private = "file")
spot_windows :: proc() -> []Toplevel {
	@(static) ws := [3]Toplevel{
		{id = 11, title = "Notes", outputs = {}},
		{id = 22, title = "Browser", outputs = {}},
		{id = 33, title = "Files", outputs = {}},
	}
	@(static) one := [1]string{"DP-1"}
	@(static) two := [1]string{"DP-2"}
	ws[0].outputs = one[:] // Notes is on DP-1
	ws[1].outputs = two[:] // the browser is on the other screen
	ws[2].outputs = one[:]
	return ws[:]
}

// spot_bar builds a bar of buttons, one per window given, each saying which
// window it stands for.
@(private = "file")
spot_bar :: proc(ui: ^Ui(Spot_Msg), ids: []u64) {
	set_viewport(&ui.tree, {400, 40})
	begin_view(ui)
	row(ui, gap = 4, padding = 4, key = 1)
	for id in ids {
		// A box rather than a button: this is about the rectangle layout
		// gives a node, and a button sizes itself from its label.
		b := box(ui, width = 80, height = 32, key = id)
		toplevel_spot(ui, b, id)
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 40})
}

// spot_component_bar is the same bar inside a `component`, so a build with
// an unchanged revision skips the subtree that declares the spots.
@(private = "file")
spot_component_bar :: proc(ui: ^Ui(Spot_Msg), rev: u64, ids: []u64) {
	set_viewport(&ui.tree, {400, 40})
	begin_view(ui)
	row(ui, gap = 4, padding = 4, key = 1)
	if component(ui, "windows", rev) {
		for id in ids {
			b := box(ui, width = 80, height = 32, key = id)
			toplevel_spot(ui, b, id)
		}
		end(ui)
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 40})
}

// A button that lives on but stops standing for a window withdraws its
// spot — a pinned app's button whose window moved to a screen the bar does
// not list. The node is still there, so
// "the node went" cannot be the test; what distinguishes it is that the
// node was **built again** and did not say it this time.
@(test)
a_button_that_stops_saying_it_withdraws_its_spot :: proc(t: ^testing.T) {
	ui: Ui(Spot_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	spot_bar(&ui, []u64{11, 22})
	out := make([dynamic]Toplevel_Rect, context.temp_allocator)
	toplevel_spots_of(&ui.tree, 1, "DP-1", spot_windows(), &out)
	testing.expect_value(t, len(out), 2)

	// The same bar, built again, now saying it for one window only. The
	// other button keeps its node — same key, same place — and both windows
	// are still open.
	spot_bar(&ui, []u64{11})
	clear(&out)
	toplevel_spots_of(&ui.tree, 1, "DP-1", spot_windows(), &out)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0].id, 11)
	_, had := ui.tree.toplevel_spots[22]
	testing.expect(t, !had, "the window it no longer stands for is withdrawn")
}

// …but a `component` whose subtree was skipped never said anything, which
// is not the same as saying nothing. Its spots stand.
@(test)
a_skipped_component_keeps_the_spots_inside_it :: proc(t: ^testing.T) {
	ui: Ui(Spot_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	spot_component_bar(&ui, 1, []u64{11, 22})
	out := make([dynamic]Toplevel_Rect, context.temp_allocator)
	toplevel_spots_of(&ui.tree, 1, "DP-1", spot_windows(), &out)
	testing.expect_value(t, len(out), 2)

	// Built again with the same revision: the subtree is skipped, so
	// nothing inside it runs — and nothing inside it is withdrawn.
	spot_component_bar(&ui, 1, []u64{11, 22})
	clear(&out)
	toplevel_spots_of(&ui.tree, 1, "DP-1", spot_windows(), &out)
	testing.expectf(t, len(out) == 2, "a skipped subtree keeps its spots, got %d", len(out))
	testing.expect_value(t, len(ui.tree.toplevel_spots), 2)

	// …and a revision that changed rebuilds it, so a window it no longer
	// shows is withdrawn as usual.
	spot_component_bar(&ui, 2, []u64{11})
	clear(&out)
	toplevel_spots_of(&ui.tree, 1, "DP-1", spot_windows(), &out)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0].id, 11)
}

// What a bar says, and what it stops saying. A spot is kept across builds
// without being re-declared — a `component` may skip the subtree that
// declared it — so the test of whether it still means anything happens when
// the rectangles are collected, not when they are declared.
@(test)
a_bar_says_where_each_window_is :: proc(t: ^testing.T) {
	ui: Ui(Spot_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	spot_bar(&ui, []u64{11, 22, 33})
	testing.expect_value(t, len(ui.tree.toplevel_spots), 3)

	out := make([dynamic]Toplevel_Rect, context.temp_allocator)
	toplevel_spots_of(&ui.tree, 1, "DP-1", spot_windows(), &out)
	testing.expect_value(t, len(out), 3)
	for r in out {
		testing.expectf(t, r.rect.z == 80 && r.rect.w == 32, "window %d: the button's own size, got %v", r.id, r.rect)
		testing.expectf(t, r.surface == 1, "on the surface it was collected from")
		// Notes and Files are on this screen; the browser is not.
		testing.expectf(t, r.own == (r.id != 22), "window %d: own screen %v", r.id, r.own)
	}

	// A window that closed is forgotten: no rectangle, and the spot goes,
	// so a later window with the same id cannot inherit it.
	clear(&out)
	toplevel_spots_of(&ui.tree, 1, "DP-1", spot_windows()[:2], &out)
	testing.expect_value(t, len(out), 2)
	testing.expect_value(t, len(ui.tree.toplevel_spots), 2)
	_, had := ui.tree.toplevel_spots[33]
	testing.expect(t, !had, "the closed window's spot is gone")

	// A button that goes with its window is forgotten too.
	spot_bar(&ui, []u64{11})
	clear(&out)
	toplevel_spots_of(&ui.tree, 1, "DP-1", spot_windows(), &out)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0].id, 11)
}

// A button that is not on screen says nothing *and keeps its spot*: a bar
// hidden at its edge, or a button fading out, is not the same as a button
// that has gone, and it comes back without the view having to re-declare it.
@(test)
a_button_with_nothing_on_screen_says_nothing_yet :: proc(t: ^testing.T) {
	ui: Ui(Spot_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	spot_bar(&ui, []u64{11, 22})
	out := make([dynamic]Toplevel_Rect, context.temp_allocator)

	d := node_get(&ui.tree, ui.tree.toplevel_spots[11].node)
	testing.expect(t, d != nil, "the button is there")
	was := d.abs
	d.abs = {} // nothing laid out yet, or laid out to nothing
	toplevel_spots_of(&ui.tree, 1, "DP-1", spot_windows(), &out)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, len(ui.tree.toplevel_spots), 2) // kept

	d.abs = was
	d.flags += {.Exiting} // on its way out: its place is no longer where it is
	clear(&out)
	toplevel_spots_of(&ui.tree, 1, "DP-1", spot_windows(), &out)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, len(ui.tree.toplevel_spots), 2)

	d.flags -= {.Exiting}
	clear(&out)
	toplevel_spots_of(&ui.tree, 1, "DP-1", spot_windows(), &out)
	testing.expect_value(t, len(out), 2) // back, with nothing re-declared
}

// A spot inside a popover shown on a surface of its own says nothing: the
// node is laid out in this tree's coordinates but drawn on another surface,
// so its rectangle would name a place on the wrong one.
@(test)
a_spot_inside_a_popover_of_its_own_names_nothing :: proc(t: ^testing.T) {
	ui: Ui(Spot_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.motion.reduce = true
	set_viewport(&ui.tree, {400, 40})

	begin_view(&ui)
	row(&ui, flex = 1, align = .Center, key = 1)
	anchor := button(&ui, "Windows", Spot_Msg(0), key = 2)
	on_bar := box(&ui, width = 80, height = 32, key = 3)
	toplevel_spot(&ui, on_bar, 11)
	end(&ui)
	if popover(&ui, anchor, true, Spot_Msg(0)) {
		in_menu := box(&ui, width = 120, height = 28, key = 4)
		toplevel_spot(&ui, in_menu, 22)
		end(&ui)
	}
	end_view(&ui)
	frame(&ui.tree, {400, 40})

	out := make([dynamic]Toplevel_Rect, context.temp_allocator)
	// With popups drawn in this surface, both are this surface's to name.
	toplevel_spots_of(&ui.tree, 1, "DP-1", spot_windows(), &out)
	testing.expect_value(t, len(out), 2)

	// On their own surfaces, the one in the menu is not.
	ui.tree.popups_on = true
	clear(&out)
	toplevel_spots_of(&ui.tree, 1, "DP-1", spot_windows(), &out)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0].id, 11)
	testing.expect_value(t, len(ui.tree.toplevel_spots), 2) // kept, not forgotten
}

// A surface that has not entered a screen yet claims no window as its own,
// rather than claiming every window.
@(test)
a_surface_with_no_screen_claims_nothing :: proc(t: ^testing.T) {
	ui: Ui(Spot_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	spot_bar(&ui, []u64{11})
	out := make([dynamic]Toplevel_Rect, context.temp_allocator)
	toplevel_spots_of(&ui.tree, 1, "", spot_windows(), &out)
	testing.expect_value(t, len(out), 1)
	testing.expect(t, !out[0].own, "no screen known, no claim")
}

// What is actually sent: only what moved, a zero rectangle for what is no
// longer shown, and — the reason this is a step of its own — the surface on
// the window's own screen last, because the compositor keeps the last
// rectangle it was given.
@(test)
only_what_moved_is_sent_and_the_right_screen_goes_last :: proc(t: ^testing.T) {
	a := Toplevel_Rect{id = 11, surface = 1, rect = {4, 4, 80, 32}, own = false}
	b := Toplevel_Rect{id = 11, surface = 2, rect = {4, 4, 80, 32}, own = true}

	// Nothing said before: both go, the own-screen one second.
	clears, sends := toplevel_rect_changes(nil, []Toplevel_Rect{b, a})
	testing.expect_value(t, len(clears), 0)
	testing.expect_value(t, len(sends), 2)
	testing.expect_value(t, sends[0].surface, 1)
	testing.expect_value(t, sends[1].surface, 2) // last wins, and this is the one that should
	testing.expect(t, sends[1].own, "the window's own screen is the one kept")

	// Said, and unchanged: nothing at all.
	clears, sends = toplevel_rect_changes([]Toplevel_Rect{a, b}, []Toplevel_Rect{a, b})
	testing.expect_value(t, len(clears), 0)
	testing.expect_value(t, len(sends), 0)

	// Moved along the bar: only that one.
	moved := a
	moved.rect = {88, 4, 80, 32}
	clears, sends = toplevel_rect_changes([]Toplevel_Rect{a, b}, []Toplevel_Rect{moved, b})
	testing.expect_value(t, len(clears), 0)
	testing.expect_value(t, len(sends), 1)
	testing.expect_value(t, sends[0].rect.x, 88)

	// No longer shown anywhere: a zero rectangle, so the compositor chooses
	// for itself again rather than flying into a button that has gone.
	clears, sends = toplevel_rect_changes([]Toplevel_Rect{a, b}, nil)
	testing.expect_value(t, len(sends), 0)
	testing.expect_value(t, len(clears), 2)
	for c in clears do testing.expectf(t, c.rect == {}, "a cleared spot is zero, got %v", c.rect)

	// One surface stops showing it, the other goes on: a clear for the one
	// that stopped, and nothing for the one that did not move.
	clears, sends = toplevel_rect_changes([]Toplevel_Rect{a, b}, []Toplevel_Rect{b})
	testing.expect_value(t, len(sends), 0)
	testing.expect_value(t, len(clears), 1)
	testing.expect_value(t, clears[0].surface, 1)
}

}
