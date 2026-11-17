#+build linux
package x11

// The window-manager protocol (EWMH): asking the window manager for things
// that are its to decide, and the two small things that are the server's.
//
// A client does not maximise or full-screen its own window on X. It sends
// the window manager a message about the window and the manager answers by
// resizing it — or does not, which is equally its right. So these ask, and
// the app hears the outcome in the Ev_Configure that follows, if one does.
//
// Every such message goes to the root window with SubstructureRedirect
// set, not to the window it is about: the window manager is what is
// listening, and that is how it is told to listen.

import "core:sys/linux"
import "baldr:platform"
import "baldr:platform/xkb"

// wm_message sends the window manager a _NET_* client message about `w`.
@(private)
wm_message :: proc(x: ^X11, w: Window, type: Atom, data: [5]u32) -> bool {
	if x.screen == nil || type == ATOM_NONE do return false
	ev := Client_Message_Event{
		response_type = CLIENT_MESSAGE,
		format        = 32,
		window        = w,
		type          = type,
	}
	ev.data.data32 = data
	api.send_event(x.conn, 0, x.screen.root,
		EVENT_MASK_SUBSTRUCTURE_NOTIFY | EVENT_MASK_SUBSTRUCTURE_REDIRECT, &ev)
	api.flush(x.conn)
	return true
}

// surface_set_fullscreen asks for the whole screen, or gives it back.
//
// True only means the ask went out: the window manager decides, and what it
// decided arrives as a PropertyNotify on _NET_WM_STATE and then a configure
// (props.odin). A window manager that does not advertise the atom cannot be
// asked at all, and that is worth false rather than a silent nothing.
@(private)
surface_set_fullscreen :: proc(b: ^platform.Backend, id: platform.Surface, on: bool) -> bool {
	x := data(b)
	s := get_surface(x, id)
	if s == nil || x.atoms.net_wm_state == ATOM_NONE || x.atoms.net_wm_state_fullscreen == ATOM_NONE {
		return false
	}
	action := u32(NET_WM_STATE_ADD if on else NET_WM_STATE_REMOVE)
	// 0 is the second property, unused here; 1 says the request comes from
	// an application rather than a pager, which some window managers weigh.
	return wm_message(x, s.window, x.atoms.net_wm_state,
		{action, u32(x.atoms.net_wm_state_fullscreen), 0, 1, 0})
}

// activate asks for this window to be brought forward and given the
// keyboard (_NET_ACTIVE_WINDOW).
//
// `token` is Wayland's xdg-activation token and has no X equivalent; X uses
// the triggering input's timestamp to refuse focus stealing. With
// CurrentTime a strict window manager may only mark the window as wanting
// attention, which the contract allows: the desktop decides.
@(private)
activate :: proc(b: ^platform.Backend, id: platform.Surface, token: string) {
	x := data(b)
	s := get_surface(x, id)
	if s == nil || x.atoms.net_active_window == ATOM_NONE do return
	last := x.kbd_focus.window if x.kbd_focus != nil else WINDOW_NONE
	wm_message(x, s.window, x.atoms.net_active_window,
		{1, u32(CURRENT_TIME), u32(last), 0, 0}) // 1: from an application
}

// key_name is the xkb keysym name for Ev_Key.native ("q", "comma",
// "XF86AudioPlay"), the names window-manager configuration is written in.
@(private)
key_name :: proc(b: ^platform.Backend, native: u32, allocator := context.allocator) -> string {
	return xkb.keysym_name(&data(b).keys, native, allocator)
}

// watch_fd puts a descriptor the toolkit owns — the accessibility bus — in
// the pump's poll set, so it wakes the loop when it has something. The
// backend reads nothing from it; waking is the whole job.
@(private)
watch_fd :: proc(b: ^platform.Backend, fd: i32, on: bool) {
	x := data(b)
	if fd < 0 do return
	f := linux.Fd(fd)
	for got, i in x.extra_fds {
		if got != f do continue
		if !on do unordered_remove(&x.extra_fds, i)
		return
	}
	if on do append(&x.extra_fds, f)
}
