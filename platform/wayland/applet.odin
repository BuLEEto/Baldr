#+build linux
// applet.odin — applet surfaces: a surface shown inside a
// desktop shell's bar, at a slot the shell reserved (the compositor's
// rikkiti-applet-v1). The shell starts the applet with the slot's token; the
// surface binds it and is configured to the slot's size and the bar's edge.
// It sits on the bar's glass, so nothing is drawn behind it, and its popups
// open through it as a layer surface's do (popup.odin).
package wayland

import "core:strings"
import "baldr:platform"
import wl "baldr:platform/wayland/wl"

// create_applet gives the surface the applet role with its slot's token. A
// token that is unknown, used or stale is answered with closed, not an
// error. The compositor reports how bright it is behind (the bar's glass
// over the desktop) where it can, so the toolkit can pick readable text.
@(private)
create_applet :: proc(st: ^State, s: ^Surface_State, desc: platform.Surface_Desc) {
	token := strings.clone_to_cstring(desc.applet.token, context.temp_allocator)
	s.applet = wl.rikkiti_applet_manager_v1_get_applet(st.applet_mgr, s.wl_surface, token)
	s.applet_l = wl.rikkiti_applet_v1_listener_noop()
	s.applet_l.configure = on_applet_configure
	s.applet_l.closed = on_applet_closed
	wl.rikkiti_applet_v1_add_listener(s.applet, &s.applet_l, s)
	if desc.applet.keyboard != .On_Demand do applet_keyboard(s, desc.applet.keyboard) // on_demand is the protocol's default
	backdrop_watch(st, s)
}

// on_applet_configure acks and adopts the slot's size and the bar's edge.
@(private)
on_applet_configure :: proc "c" (data: rawptr, p: wl.Proxy, serial: u32, width, height: u32, edge: wl.Rikkiti_Applet_Host_V1_Edge) {
	s := (^Surface_State)(data)
	context = s.st.ctx
	wl.rikkiti_applet_v1_ack_configure(p, serial)
	switch edge {
	case .Top:    s.edge = .Top
	case .Bottom: s.edge = .Bottom
	case .Left:   s.edge = .Left
	case .Right:  s.edge = .Right
	case:         // an edge this build doesn't know: keep the last
	}
	size := s.size
	if width > 0 && height > 0 {
		size = {f32(width), f32(height)}
	} else if !s.configured {
		size = s.default_size
	}
	debugf(s.st, "surface %d: applet configure %dx%d, bar on the %v edge", s.id, width, height, s.edge)
	apply_geometry(s, size)
}

// on_applet_closed: the slot was removed or the token wasn't valid; nothing
// the applet commits is shown again.
@(private)
on_applet_closed :: proc "c" (data: rawptr, p: wl.Proxy) {
	s := (^Surface_State)(data)
	context = s.st.ctx
	debugf(s.st, "surface %d: applet closed (its slot went, or its token was not valid)", s.id)
	push(s.st, platform.Ev_Close{surface = s.id, reason = .Compositor})
}

// surface_set_applet changes an open applet's keyboard setting.
surface_set_applet :: proc(b: ^platform.Backend, surface: platform.Surface, applet: platform.Applet_Desc) -> bool {
	st := state(b)
	s := lookup(st, surface)
	if s == nil || s.applet == nil do return false
	applet_keyboard(s, applet.keyboard)
	wl.display_flush(st.display)
	return true
}

// surface_set_size_hint tells the shell the length along the bar the applet
// can't go below and the one it would like.
surface_set_size_hint :: proc(b: ^platform.Backend, surface: platform.Surface, least, preferred: u32) {
	st := state(b)
	s := lookup(st, surface)
	if s == nil || s.applet == nil do return
	wl.rikkiti_applet_v1_set_size_hint(s.applet, least, preferred)
	wl.display_flush(st.display)
	debugf(st, "surface %d: size hint %d, preferring %d, along the bar", s.id, least, preferred)
}

@(private)
applet_keyboard :: proc(s: ^Surface_State, k: platform.Applet_Keyboard) {
	wl.rikkiti_applet_v1_set_keyboard_interactivity(s.applet, .None if k == .None else .On_Demand)
	debugf(s.st, "surface %d: applet keyboard %v", s.id, k)
}
