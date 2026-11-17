package baldr

@(require) import "core:testing"
@(require) import "baldr:platform"

// Two ordinary things are decided in `update`, where there is no
// tree to read — whether the window has the keyboard (a messenger shows no
// notification for the chat you are looking at) and how big it was when it
// was closed (so it comes back that way). `ui.surface` answers both in
// `view`; `on_state` is the same answers as a message.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Ws_Msg :: union { Window_State }

@(private = "file")
ws_rt :: proc() -> ^Runtime(int, Ws_Msg) {
	rt := new(Runtime(int, Ws_Msg))
	c := new(Surface_Ctx(Ws_Msg))
	ui_init(&c.ui)
	c.surf = platform.Surface(1)
	c.desc.tag = 7
	c.desc.on_state = proc(e: Ev(Window_State)) -> Ws_Msg { return e.value }
	append(&rt.ctxs, c)
	return rt
}

@(private = "file")
ws_free :: proc(rt: ^Runtime(int, Ws_Msg)) {
	for c in rt.ctxs {
		ui_destroy(&c.ui)
		free(c)
	}
	delete(rt.ctxs)
	delete(rt.msgs)
	free(rt)
}

@(private = "file")
ws_last :: proc(rt: ^Runtime(int, Ws_Msg)) -> (got: Window_State, n: int) {
	for m in rt.msgs {
		if w, ok := m.(Window_State); ok {
			got = w
			n += 1
		}
	}
	return
}

// It arrives once the window has been configured — the app is told where it
// stands without having to wait for something to change — and then only
// when something actually does.
@(test)
on_state_reports_once_and_then_only_on_a_change :: proc(t: ^testing.T) {
	rt := ws_rt()
	defer ws_free(rt)
	c := rt.ctxs[0]

	// before the first configure there is nothing true to say
	window_state_sync(c, &rt.msgs)
	_, n := ws_last(rt)
	testing.expect_value(t, n, 0)

	set_viewport(&c.ui.tree, {900, 600})
	c.ui.surface.scale = 1
	window_state_sync(c, &rt.msgs)
	got, n2 := ws_last(rt)
	testing.expect_value(t, n2, 1)
	testing.expect_value(t, got.size, [2]f32{900, 600})
	testing.expect_value(t, got.tag, u64(7))
	testing.expect(t, !got.keyboard && !got.maximized, "the desktop has done neither yet")

	// nothing moved: nothing said, however many frames go by
	for _ in 0 ..< 5 do window_state_sync(c, &rt.msgs)
	_, n3 := ws_last(rt)
	testing.expect_value(t, n3, 1)
}

// The keyboard arriving and leaving is a change, which is the half a
// messenger needs: it suppresses a notification for the chat on screen only
// while the window actually has focus.
@(test)
on_state_reports_the_keyboard_coming_and_going :: proc(t: ^testing.T) {
	rt := ws_rt()
	defer ws_free(rt)
	c := rt.ctxs[0]
	set_viewport(&c.ui.tree, {900, 600})
	window_state_sync(c, &rt.msgs)

	keyboard_focus(c, c.surf, true)
	window_state_sync(c, &rt.msgs)
	got, n := ws_last(rt)
	testing.expect_value(t, n, 2)
	testing.expect(t, got.keyboard, "it has the keyboard")

	keyboard_focus(c, c.surf, false)
	window_state_sync(c, &rt.msgs)
	got2, n2 := ws_last(rt)
	testing.expect_value(t, n2, 3)
	testing.expect(t, !got2.keyboard, "and lost it")
}

// Resizing and maximising are changes too — the other half, for a window
// that comes back the way it was left.
@(test)
on_state_reports_the_size_and_the_maximised_state :: proc(t: ^testing.T) {
	rt := ws_rt()
	defer ws_free(rt)
	c := rt.ctxs[0]
	set_viewport(&c.ui.tree, {900, 600})
	window_state_sync(c, &rt.msgs)

	set_viewport(&c.ui.tree, {1280, 800})
	c.ui.surface.maximized = true
	window_state_sync(c, &rt.msgs)
	got, n := ws_last(rt)
	testing.expect_value(t, n, 2)
	testing.expect_value(t, got.size, [2]f32{1280, 800})
	testing.expect(t, got.maximized, "the desktop maximised it")

	// what an app writes out and passes back as Surface_Desc{size, maximized}
	desc := Surface_Desc(Ws_Msg){kind = .Window, size = got.size, maximized = got.maximized}
	res := surface_resolve(desc, {}, "Test")
	testing.expect_value(t, res.size, [2]f32{1280, 800})
	testing.expect(t, res.maximized, "and asks for it again next time")
}

// An app that sets no handler is told nothing and costs nothing.
@(test)
a_surface_with_no_on_state_handler_says_nothing :: proc(t: ^testing.T) {
	rt := ws_rt()
	defer ws_free(rt)
	c := rt.ctxs[0]
	c.desc.on_state = nil
	set_viewport(&c.ui.tree, {900, 600})
	c.ui.surface.maximized = true
	for _ in 0 ..< 4 do window_state_sync(c, &rt.msgs)
	_, n := ws_last(rt)
	testing.expect_value(t, n, 0)
}

// Only a .Window can be asked to open maximised; a layer surface or a lock
// screen is sized by the desktop and the ask is dropped.
@(test)
only_a_window_is_asked_to_open_maximised :: proc(t: ^testing.T) {
	win := surface_resolve(Surface_Desc(Ws_Msg){kind = .Window, size = {800, 600}, maximized = true}, {}, "Test")
	testing.expect(t, win.maximized, "a window may be")
	lock := surface_resolve(Surface_Desc(Ws_Msg){kind = .Lock, maximized = true}, {}, "Test")
	testing.expect(t, !lock.maximized, "a lock screen is not")
}

}
