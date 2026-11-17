#+build linux
package xdg

// Holding the screen on, for a desktop that listens on the session bus.
//
// Wayland has a protocol for this; X11 has none, and the convention there
// (GNOME, KDE, Xfce, media players) is `org.freedesktop.ScreenSaver`'s
// `Inhibit` / `UnInhibit` over the session bus — so it lives beside the
// other session-bus services rather than in `platform/x11`.
//
// One inhibit for the process: the service has no notion of a window, only
// a cookie. The backend keeps the per-surface flags and tells this whether
// anything wants the screen on; the cookie is taken when the first surface
// asks and given back when the last stops, as in `platform/win32/idle.odin`.
//
// The call is asynchronous, so a want that goes away before the reply
// arrives is released as soon as the cookie lands; otherwise the inhibit
// would leak for the session's life.

import "baldr:dbus"

@(private) SCREENSAVER_NAME  :: "org.freedesktop.ScreenSaver"
@(private) SCREENSAVER_PATH  :: "/org/freedesktop/ScreenSaver"
@(private) SCREENSAVER_IFACE :: "org.freedesktop.ScreenSaver"

// Idle is what this file keeps on the Xdg state.
Idle :: struct {
	want:    bool, // something on this app wants the screen kept on
	have:    bool, // …and the service has given us a cookie for it
	pending: bool, // …or we have asked and not yet heard back
	cookie:  u32,
}

// keep_awake asks the desktop to hold the screen on, or gives that back.
// Idempotent: repeated calls with the same value send nothing.
keep_awake :: proc(x: ^Xdg, on: bool) {
	if x == nil || x.bus == nil do return
	if x.idle.want == on do return
	x.idle.want = on
	idle_apply(x)
}

// keep_awake_release gives the cookie back for good, at backend shutdown.
keep_awake_release :: proc(x: ^Xdg) {
	if x == nil do return
	x.idle.want = false
	idle_apply(x)
}

@(private)
idle_apply :: proc(x: ^Xdg) {
	if x.bus == nil do return
	switch {
	case x.idle.want && !x.idle.have && !x.idle.pending:
		body := []dbus.Value{dbus.Value(idle_app_name(x)), dbus.Value("playing")}
		m := dbus.method_call(SCREENSAVER_NAME, SCREENSAVER_PATH, SCREENSAVER_IFACE, "Inhibit", body)
		if _, err := dbus.call_async(x.bus, &m, on_inhibit_reply, x); err != .None {
			debugf(x, "keep_awake: the session bus would not take Inhibit (%v)", err)
			return
		}
		x.idle.pending = true
	case !x.idle.want && x.idle.have:
		body := []dbus.Value{dbus.Value(x.idle.cookie)}
		m := dbus.method_call(SCREENSAVER_NAME, SCREENSAVER_PATH, SCREENSAVER_IFACE, "UnInhibit", body)
		dbus.call_async(x.bus, &m, nil, nil) // no reply needed: nothing to do if it fails
		x.idle.have, x.idle.cookie = false, 0
	}
}

// on_inhibit_reply takes the cookie, and gives it straight back when the
// want went away while the call was in flight; otherwise the screen would
// be held on for ever.
@(private = "file")
on_inhibit_reply :: proc(conn: ^dbus.Connection, reply: ^dbus.Message, err: dbus.Error, user: rawptr) {
	x := (^Xdg)(user)
	if x == nil do return
	x.idle.pending = false
	if err != .None || reply == nil || reply.type == .Error || len(reply.body) < 1 {
		// No screensaver service: the screen dims as usual, which the
		// contract allows.
		debugf(x, "keep_awake: no org.freedesktop.ScreenSaver here, so the screen dims as usual")
		return
	}
	cookie, ok := dbus.as_u32(reply.body[0])
	if !ok do return
	x.idle.have, x.idle.cookie = true, cookie
	debugf(x, "keep_awake: holding the screen on (cookie %d)", cookie)
	if !x.idle.want do idle_apply(x) // it was turned off while we were asking
}

@(private)
idle_app_name :: proc(x: ^Xdg) -> string {
	return x.app_id if x.app_id != "" else "baldr"
}
