#+build linux
package x11

// Holding the screen on while a surface shows something.
//
// X11 has no protocol for this, so it goes over the session bus to
// `org.freedesktop.ScreenSaver` (`platform/xdg/idle.odin`); this is the
// per-surface bookkeeping.
//
// The service has one inhibit per application and no notion of a window,
// so any surface asking holds it: the cookie is taken when the first asks
// and given back when the last stops or closes (`idle_release`).

import "baldr:platform"
import "baldr:platform/xdg"

// keep_awake is Backend.keep_awake: hold the screen on while this surface
// shows, or let the desktop's idle timer have it back.
@(private)
keep_awake :: proc(b: ^platform.Backend, surface: platform.Surface, on: bool) {
	x := data(b)
	if x == nil do return
	s := get_surface(x, surface)
	if s == nil || s.awake == on do return
	s.awake = on
	idle_apply(x)
}

// idle_release stops a surface asking as it goes (surface_destroy).
@(private)
idle_release :: proc(x: ^X11, s: ^Surface) {
	if s == nil || !s.awake do return
	s.awake = false
	idle_apply(x)
}

// idle_apply tells the session bus whether anything still wants it.
@(private)
idle_apply :: proc(x: ^X11) {
	want := false
	for s in x.surfaces do if s != nil && s.live && s.awake { want = true; break }
	xdg.keep_awake(&x.xdg, want)
}
