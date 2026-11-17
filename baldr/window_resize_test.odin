package baldr

// A window sized by its app: a video player fitting its window
// to the film it has just opened. Two things decide it — whether the
// declaration is even noticed as a change, and what is asked for once it is.

@(require) import "core:testing"
@(require) import "baldr:platform"

when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Wsz_Msg :: union { bool }

@(private = "file")
wsz_screens :: proc() -> []Output {
	@(static) screens := [2]Output{
		{name = "DP-1", size = {1920, 1080}},
		{name = "DP-2", size = {3840, 2160}},
	}
	return screens[:]
}

// A window's `size` is watched the way a layer surface's is, not read once
// when the window is made, so an app can fit its window to what it opened.
@(test)
a_windows_size_is_noticed_when_it_changes :: proc(t: ^testing.T) {
	was := Surface_Desc(Wsz_Msg){kind = .Window, size = {960, 600}}
	now := was
	now.size = {1280, 720}
	testing.expect(t, .Size in surface_changes(was, now), "a window's new size is a change")
	testing.expect(t, .Size not_in surface_changes(was, was), "and an unchanged one is not")

	// …as it is for a layer surface.
	lay_was := Surface_Desc(Wsz_Msg){kind = .Layer, size = {FIT, 40}}
	lay_now := lay_was
	lay_now.size = {FIT, 56}
	testing.expect(t, .Size in surface_changes(lay_was, lay_now), "a layer surface's too")

	// An applet's size is its bar's business and a popup's is its parent's,
	// so neither is taken from the declaration.
	app_was := Surface_Desc(Wsz_Msg){kind = .Applet, size = {100, 40}}
	app_now := app_was
	app_now.size = {200, 40}
	testing.expect(t, .Size not_in surface_changes(app_was, app_now), "an applet's is not")

	// It is a live change: a window does not have to be reopened for it.
	testing.expect(t, .Size in SURFACE_LIVE_CHANGES, "applied to an open window")
}

// What is asked for, and when nothing is.
@(test)
a_window_asks_for_a_size_that_fits_its_screen :: proc(t: ^testing.T) {
	screens := wsz_screens()

	want, ask := window_size_wanted({1280, 720}, false, "DP-1", screens)
	testing.expect(t, ask && want == {1280, 720}, "a size that fits is asked for as it is")

	// A film bigger than the screen: what fits. An app would otherwise have
	// to find its own window among the screens before it could ask.
	want, ask = window_size_wanted({3840, 2160}, false, "DP-1", screens)
	testing.expect(t, ask && want == {1920, 1080}, "kept to the screen it is on")
	want, ask = window_size_wanted({3840, 2160}, false, "DP-2", screens)
	testing.expect(t, ask && want == {3840, 2160}, "…which on the big screen is all of it")

	// Only one side may be too big, and only that side is brought in.
	want, ask = window_size_wanted({1280, 2160}, false, "DP-1", screens)
	testing.expect(t, ask && want == {1280, 1080}, "the tall side alone")

	// Before the window has entered a screen there is no name to match, and
	// the biggest is the honest guess rather than refusing to ask at all.
	want, ask = window_size_wanted({2400, 1400}, false, "", screens)
	testing.expect(t, ask && want == {2400, 1400}, "the biggest screen, until it is known which")
	want, ask = window_size_wanted({1280, 720}, false, "DP-9", nil)
	testing.expect(t, ask && want == {1280, 720}, "and with no screens known, as asked")
}

// While the desktop is sizing the window, the app's size is dropped — not
// remembered. Holding it would mean a window jumping to a size asked for
// minutes ago the moment someone unmaximised it, which reads as a fault.
@(test)
a_window_the_desktop_is_sizing_keeps_the_size_it_was_given :: proc(t: ^testing.T) {
	screens := wsz_screens()
	for sizing in ([2]bool{true, false}) {
		_, ask := window_size_wanted({1280, 720}, sizing, "DP-1", screens)
		testing.expectf(t, ask == !sizing, "maximised, full screen or tiled: %v → asked %v", sizing, ask)
	}

	// Nothing is asked for a size of nothing either: 0 means "the desktop's
	// to choose", and FIT is a layer surface's word, which a window that
	// borrowed it would otherwise send to the desktop as -1.
	_, none := window_size_wanted({}, false, "DP-1", screens)
	testing.expect(t, !none, "no size, nothing asked")
	_, fit := window_size_wanted({FIT, 600}, false, "DP-1", screens)
	testing.expect(t, !fit, "FIT is not a window's word")
	_, neg := window_size_wanted({1280, -4}, false, "DP-1", screens)
	testing.expect(t, !neg, "nor is a negative side")
}

// The backend call itself, for a window that is the app's to size.
//
// Two calls, every time one is made: the size, and then {0, 0} handing it
// back. `surface_set_size` keeps a size of the window's own through the
// desktop's configures — that is what a rolled-up title bar needs — so an
// ask that did not hand it back would hold the window at the app's size and
// it could not be resized by hand.
@(test)
a_floating_window_is_asked_for_on_the_desktop :: proc(t: ^testing.T) {
	Asked :: struct { size: [2]f32, back: int, n: int }
	asked: Asked
	b := platform.Backend{data = &asked}
	b.surface_set_size = proc(b: ^platform.Backend, s: platform.Surface, size: [2]f32) {
		a := (^Asked)(b.data)
		if size == {} {
			a.back += 1 // handed back; a.size stays the one asked for
			return
		}
		a.size, a.n = size, a.n + 1
	}

	c := new(Surface_Ctx(Wsz_Msg))
	defer free(c)
	c.surf = 3
	c.output = "DP-1"
	window_resize(c, &b, {1280, 720}, wsz_screens())
	testing.expect(t, asked.n == 1 && asked.size == {1280, 720}, "asked for once, as given")
	testing.expect_value(t, asked.back, 1) // …and let go of again, so an edge can still be dragged

	c.ui.surface.maximized = true
	window_resize(c, &b, {800, 600}, wsz_screens())
	testing.expect_value(t, asked.n, 1) // dropped: the desktop is sizing it
	testing.expect_value(t, asked.back, 1) // and nothing was handed back either: nothing was taken
	c.ui.surface.maximized, c.ui.surface.tiled = false, true
	window_resize(c, &b, {800, 600}, wsz_screens())
	testing.expect_value(t, asked.n, 1)
	c.ui.surface.tiled = false
	window_resize(c, &b, {800, 600}, wsz_screens())
	testing.expect(t, asked.n == 2 && asked.size == {800, 600}, "floating again: asked for")
	testing.expect_value(t, asked.back, 2)

	// A backend with no way to size a window says so instead of breaking.
	b.surface_set_size = nil
	window_resize(c, &b, {640, 480}, wsz_screens())
	testing.expect_value(t, asked.n, 2)
}

}
