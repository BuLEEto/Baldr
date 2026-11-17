#+build linux
// idle.odin — idle-inhibit-unstable-v1: asking the compositor not to dim,
// blank or lock the screen while one of our surfaces shows something to be
// watched rather than touched: a video in a window, a slideshow. (A
// full-screen window is usually handled by the compositor itself.)
//
// The protocol is one object per surface: create it while the screen should
// stay on, destroy it when it should not. The compositor does not report
// whether it honoured it and may ignore it (while the session is locked, for
// one). A desktop without the protocol dims as usual.
package wayland

import "baldr:platform"
import "baldr:platform/wayland/wl"

// keep_awake is Backend.keep_awake: hold the screen on while this surface
// shows, or let the idle timer have it back.
@(private)
keep_awake :: proc(b: ^platform.Backend, surface: platform.Surface, on: bool) {
	st := state(b)
	s := lookup(st, surface)
	if s == nil do return
	if !on {
		if s.idle_inhibit != nil {
			wl.zwp_idle_inhibitor_v1_destroy(s.idle_inhibit)
			s.idle_inhibit = nil
			debugf(st, "idle inhibit: released")
		}
		return
	}
	if s.idle_inhibit != nil do return // already asking
	if st.idle_mgr == nil {
		debugf(st, "idle inhibit: the compositor does not offer it")
		return
	}
	s.idle_inhibit = wl.zwp_idle_inhibit_manager_v1_create_inhibitor(st.idle_mgr, s.wl_surface)
	debugf(st, "idle inhibit: asked (the screen stays on while this window shows)")
}

// idle_release drops a surface's inhibitor as the surface goes, so the
// screen is not held on by a window that has closed.
@(private)
idle_release :: proc(s: ^Surface_State) {
	if s == nil || s.idle_inhibit == nil do return
	wl.zwp_idle_inhibitor_v1_destroy(s.idle_inhibit)
	s.idle_inhibit = nil
}
