package baldr

@(require) import "core:testing"
@(require) import "baldr:platform"

// A window reopening where it was left. Position is a **request**,
// exactly as `maximized` is: asked for at
// creation, answered by the desktop, and reported back as what actually
// happened. On Wayland a client is never told where it is and has no say in
// where it goes, so there it stays nil at both ends, and an app that saves
// what it is told simply has nothing to save.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Wp_Msg :: union { Window_State }

// A backend that knows where its window is, as X11 and Win32 do.
@(private = "file")
Wp_Fake :: struct {
	using b: platform.Backend,
	pos:     [2]i32,
	says:    bool, // false: the platform will not say (Wayland, or before the first configure)
}

@(private = "file")
wp_position :: proc(b: ^platform.Backend, s: platform.Surface) -> (pos: [2]i32, ok: bool) {
	f := (^Wp_Fake)(b)
	return f.pos, f.says
}

@(private = "file")
wp_rt :: proc(fake: ^Wp_Fake) -> ^Runtime(int, Wp_Msg) {
	rt := new(Runtime(int, Wp_Msg))
	c := new(Surface_Ctx(Wp_Msg))
	ui_init(&c.ui)
	c.surf = platform.Surface(1)
	c.kind = .Window
	c.desc.tag = 7
	c.desc.on_state = proc(e: Ev(Window_State)) -> Wp_Msg { return e.value }
	c.fc.backend, c.fc.surface = &fake.b, c.surf
	// what a first configure leaves behind: a real size, so the state is
	// worth reporting at all
	set_viewport(&c.ui.tree, {900, 700})
	c.ui.surface.scale = 1
	append(&rt.ctxs, c)
	return rt
}

@(private = "file")
wp_free :: proc(rt: ^Runtime(int, Wp_Msg)) {
	for c in rt.ctxs {
		ui_destroy(&c.ui)
		free(c)
	}
	delete(rt.ctxs)
	delete(rt.msgs)
	free(rt)
}

@(private = "file")
wp_last :: proc(rt: ^Runtime(int, Wp_Msg)) -> (got: Window_State, n: int) {
	for m in rt.msgs {
		if w, ok := m.(Window_State); ok {
			got = w
			n += 1
		}
	}
	return
}

// An app saves what it is told and passes it back on the next launch, so
// what it is told has to be a real place.
@(test)
a_window_is_told_where_it_is :: proc(t: ^testing.T) {
	fake := Wp_Fake{pos = {1240, 318}, says = true}
	fake.b.surface_position = wp_position
	rt := wp_rt(&fake)
	defer wp_free(rt)

	window_state_sync(rt.ctxs[0], &rt.msgs)
	got, n := wp_last(rt)
	testing.expect_value(t, n, 1)
	pos, known := got.position.?
	testing.expect(t, known, "the position is reported")
	testing.expect_value(t, pos, [2]i32{1240, 318})
}

// Wayland's case, and every backend's before the first configure: a client
// is not told, so the app is not told either. Nil, never a zero that reads
// as the top-left corner of the desktop.
@(test)
a_platform_that_will_not_say_reports_nothing :: proc(t: ^testing.T) {
	fake := Wp_Fake{pos = {77, 88}, says = false}
	fake.b.surface_position = wp_position
	rt := wp_rt(&fake)
	defer wp_free(rt)

	window_state_sync(rt.ctxs[0], &rt.msgs)
	got, n := wp_last(rt)
	testing.expect_value(t, n, 1)
	_, known := got.position.?
	testing.expect(t, !known, "no position rather than {0, 0}")

	// and a backend with no answer at all is the same thing, not a crash
	bare := Wp_Fake{}
	rt2 := wp_rt(&bare)
	defer wp_free(rt2)
	window_state_sync(rt2.ctxs[0], &rt2.msgs)
	got2, _ := wp_last(rt2)
	_, known2 := got2.position.?
	testing.expect(t, !known2, "a nil surface_position is nil position")
}

// Moving a window is something the app wants to hear: it is how the saved
// place keeps up. The state is compared once a frame, so the move has to be
// part of that comparison or the app would save the position the window
// opened at for ever.
@(test)
moving_the_window_tells_the_app_again :: proc(t: ^testing.T) {
	fake := Wp_Fake{pos = {100, 100}, says = true}
	fake.b.surface_position = wp_position
	rt := wp_rt(&fake)
	defer wp_free(rt)

	window_state_sync(rt.ctxs[0], &rt.msgs)
	_, n1 := wp_last(rt)
	testing.expect_value(t, n1, 1)

	// nothing moved: nothing to say
	window_state_sync(rt.ctxs[0], &rt.msgs)
	_, n2 := wp_last(rt)
	testing.expectf(t, n2 == 1, "a still window says nothing more (%d)", n2)

	// dragged to the other screen
	fake.pos = {2560, 240}
	window_state_sync(rt.ctxs[0], &rt.msgs)
	got, n3 := wp_last(rt)
	testing.expectf(t, n3 == 2, "the move was reported (%d messages)", n3)
	pos, _ := got.position.?
	testing.expect_value(t, pos, [2]i32{2560, 240})
}

// A saved position outlives the screen it was saved on, and asking for one
// tells the window manager the place was deliberate (X11's `US_POSITION`),
// so it will honour it onto a monitor that has since been unplugged: the
// window opens where it can neither be seen nor dragged back, because its
// title bar is off the desktop too. The toolkit guards it so no app has to.
@(test)
a_position_on_a_screen_that_is_gone_is_not_honoured :: proc(t: ^testing.T) {
	// a laptop and a second screen to its right
	two := []Output{
		{name = "eDP-1", pos = {0, 0}, size = {1920, 1080}, mode_px = {1920, 1080}, scale = 1, primary = true},
		{name = "DP-1", pos = {1920, 0}, size = {2560, 1440}, mode_px = {2560, 1440}, scale = 1},
	}
	testing.expect(t, position_reachable({2100, 300}, two), "a window on the second screen is reachable")
	testing.expect(t, position_reachable({-8, 40}, two), "and one a few pixels off the left edge still is: the bar can be grabbed")

	// undocked: only the laptop is left, and the window saved on DP-1 would
	// open 180 px beyond the right-hand edge of everything
	one := two[:1]
	testing.expect(t, !position_reachable({2100, 300}, one), "the second screen is gone, so that position is not honoured")
	testing.expect(t, position_reachable({600, 300}, one), "a position on the screen that remains still is")

	// a window whose title bar is just below the bottom of the only screen
	testing.expect(t, !position_reachable({600, 1080}, one), "nor one whose bar is under the bottom edge")

	// and a backend that reports no screens is not evidence against anything
	testing.expect(t, position_reachable({2100, 300}, nil), "unknown screens do not veto a saved position")
}

// The whole point of the guard is that the app does not have to know: what
// it saved is what it passes back, however the desk has changed since.
@(test)
the_app_passes_back_what_it_saved_and_the_toolkit_sorts_it_out :: proc(t: ^testing.T) {
	outs := []Output{{name = "eDP-1", pos = {0, 0}, size = {1920, 1080}, mode_px = {1920, 1080}, scale = 1}}
	// what surface creation does with each, without opening anything
	keep := Surface_Desc(int){kind = .Window, position = [2]i32{300, 200}, size = {800, 600}}
	gone := Surface_Desc(int){kind = .Window, position = [2]i32{4000, 200}, size = {800, 600}}

	pk := surface_resolve(keep, {}, "test")
	if p, want := pk.position.?; want && position_reachable(p, outs) {
		// honoured
	} else {
		testing.fail_now(t, "a position on a live screen is kept")
	}
	pg := surface_resolve(gone, {}, "test")
	p2, want2 := pg.position.?
	testing.expect(t, want2, "the desc still carries it")
	testing.expect(t, !position_reachable(p2, outs), "and creation drops it")
}

// `Output.pos` is logical on Wayland and X11 but device pixels on Windows,
// so a screen's extent is `size` on the first two and `mode_px` on the
// third. output_rect is what saves an app from that branch.
@(test)
a_screens_rectangle_does_not_need_a_platform_branch :: proc(t: ^testing.T) {
	// a 2x screen: logical 1280x800, device 2560x1600
	o := Output{name = "eDP-1", pos = {0, 0}, size = {1280, 800}, mode_px = {2560, 1600}, scale = 2}
	pos, size := output_rect(o)
	testing.expect_value(t, pos, [2]i32{0, 0})
	when ODIN_OS == .Windows {
		testing.expect_value(t, size, [2]i32{2560, 1600}) // pos is device px here, so the extent must be too
	} else {
		testing.expect_value(t, size, [2]i32{1280, 800})
	}
}

// Only a window has a position to ask for. A layer surface is placed by its
// anchors, an applet by its bar, a lock surface covers a screen — passing a
// position down for any of those would be asking the backend for something
// the kind cannot mean.
@(test)
only_a_window_asks_to_be_placed :: proc(t: ^testing.T) {
	caps := platform.Caps{.Layer_Shell, .Transparent}
	win := Surface_Desc(int){kind = .Window, position = [2]i32{40, 50}, size = {800, 600}}
	pd := surface_resolve(win, caps, "test")
	pos, want := pd.position.?
	testing.expect(t, want, "a window's position is passed down")
	testing.expect_value(t, pos, [2]i32{40, 50})

	for kind in ([]Surface_Kind{.Layer, .Applet, .Lock}) {
		d := Surface_Desc(int){kind = kind, position = [2]i32{40, 50}, size = {800, 600}}
		got := surface_resolve(d, caps, "test")
		_, asked := got.position.?
		testing.expectf(t, !asked, "%v asks for no position", kind)
	}
}

}
