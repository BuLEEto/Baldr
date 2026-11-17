#+build linux
// shortcuts.odin — keyboard-shortcuts-inhibit-unstable-v1: asking the
// compositor to stop acting on its own shortcuts while one of our surfaces
// has the keyboard. A shortcut editor listening for a chord needs Super+Q to
// arrive rather than close the window; so does a remote desktop or a virtual
// machine passing keys to its guest.
//
// The compositor decides: it sends `active` when it has stopped, `inactive`
// when it starts again (its own escape hatch, or the surface losing focus).
// A desktop without the protocol simply keeps its shortcuts, and everything
// else goes on working.
package wayland

import "baldr:platform"
import "baldr:platform/xkb"
import "baldr:platform/wayland/wl"

// Inhibitor is one surface's request, live while the surface asks for it.
@(private)
Inhibitor :: struct {
	proxy:    wl.Proxy,
	listener: wl.Zwp_Keyboard_Shortcuts_Inhibitor_V1_Listener,
	active:   bool, // the compositor said it has stopped acting on them
}

// inhibit_shortcuts is Backend.inhibit_shortcuts: hold the desktop's
// shortcuts off while this surface has the keyboard, or let them go again.
@(private)
inhibit_shortcuts :: proc(b: ^platform.Backend, surface: platform.Surface, on: bool) {
	st := state(b)
	s := lookup(st, surface)
	if s == nil do return
	if !on {
		if s.inhibitor.proxy != nil {
			wl.zwp_keyboard_shortcuts_inhibitor_v1_destroy(s.inhibitor.proxy)
			s.inhibitor = {}
			debugf(st, "shortcuts inhibit: released")
		}
		return
	}
	if s.inhibitor.proxy != nil do return // already asking
	if st.shortcuts_mgr == nil || st.seat == nil {
		debugf(st, "shortcuts inhibit: the compositor does not offer it")
		return
	}
	s.inhibitor.proxy = wl.zwp_keyboard_shortcuts_inhibit_manager_v1_inhibit_shortcuts(st.shortcuts_mgr, s.wl_surface, st.seat)
	if s.inhibitor.proxy == nil do return
	s.inhibitor.listener = wl.zwp_keyboard_shortcuts_inhibitor_v1_listener_noop()
	s.inhibitor.listener.active = on_inhibitor_active
	s.inhibitor.listener.inactive = on_inhibitor_inactive
	wl.zwp_keyboard_shortcuts_inhibitor_v1_add_listener(s.inhibitor.proxy, &s.inhibitor.listener, st)
	debugf(st, "shortcuts inhibit: asked")
}

@(private)
on_inhibitor_active :: proc "c" (data: rawptr, p: wl.Proxy) {
	st := (^State)(data)
	context = st.ctx
	for s in st.surfaces do if s != nil && s.inhibitor.proxy == p do s.inhibitor.active = true
	debugf(st, "shortcuts inhibit: the compositor stopped acting on its own")
}

@(private)
on_inhibitor_inactive :: proc "c" (data: rawptr, p: wl.Proxy) {
	st := (^State)(data)
	context = st.ctx
	for s in st.surfaces do if s != nil && s.inhibitor.proxy == p do s.inhibitor.active = false
	debugf(st, "shortcuts inhibit: the compositor is acting on its own again")
}

// key_name is Backend.key_name: what xkb calls the keysym a key press
// carried, which is what a keyboard configuration file is written in.
@(private)
key_name :: proc(b: ^platform.Backend, native: u32, allocator := context.allocator) -> string {
	return xkb.keysym_name(&state(b).keys, native, allocator)
}
