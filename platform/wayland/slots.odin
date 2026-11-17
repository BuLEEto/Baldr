#+build linux
// slots.odin — applet slots, the bar's side of rikkiti-applet-v1. A bar
// reserves a rectangle of one of its own layer surfaces for
// another program's applet; the compositor gives it a token to start the
// applet with, shows the applet's surface there (clipped to it, on the
// bar's glass), and says when an applet attaches, detaches and what length
// it would like. A slot's geometry follows the bar's layout and takes
// effect with the bar's next commit.
package wayland

import "core:math"
import "core:strings"
import "baldr:platform"
import wl "baldr:platform/wayland/wl"

// Slot_State is one rikkiti_applet_slot_v1.
@(private)
Slot_State :: struct {
	st:    ^State,
	proxy: wl.Proxy,
	l:     wl.Rikkiti_Applet_Slot_V1_Listener,
	id:    platform.Slot,
	host:  platform.Surface,
}

// slot_ints widens a logical rect to whole px, never empty (the protocol
// refuses a slot without area).
@(private)
slot_ints :: proc(rect: [4]f32) -> (x, y, w, h: i32) {
	x = i32(math.floor(rect[0]))
	y = i32(math.floor(rect[1]))
	w = max(i32(math.ceil(rect[0] + rect[2])) - x, 1)
	h = max(i32(math.ceil(rect[1] + rect[3])) - y, 1)
	return
}

@(private)
slot_wl_edge :: proc "contextless" (e: platform.Edge) -> wl.Rikkiti_Applet_Host_V1_Edge {
	switch e {
	case .Top:    return .Top
	case .Bottom: return .Bottom
	case .Left:   return .Left
	case .Right:  return .Right
	}
	return .Top
}

@(private)
slot_find :: proc(st: ^State, id: platform.Slot) -> (^Slot_State, int) {
	for sl, i in st.slots do if sl.id == id do return sl, i
	return nil, -1
}

// slot_create is Backend.slot_create: only on a layer surface of this client
// (anything else is a protocol error, so it is refused here).
slot_create :: proc(b: ^platform.Backend, host: platform.Surface, rect: [4]f32, edge: platform.Edge) -> (platform.Slot, bool) {
	st := state(b)
	s := lookup(st, host)
	if st.applet_host == nil || s == nil || s.layer_surface == nil {
		debugf(st, "slot_create: surface %d can't hold applet slots", host)
		return 0, false
	}
	st.next_slot += 1
	sl := new(Slot_State)
	sl.st, sl.id, sl.host = st, platform.Slot(st.next_slot), host
	x, y, w, h := slot_ints(rect)
	sl.proxy = wl.rikkiti_applet_host_v1_create_slot(st.applet_host, s.wl_surface, x, y, w, h, slot_wl_edge(edge))
	sl.l = wl.rikkiti_applet_slot_v1_listener_noop()
	sl.l.token = on_slot_token
	sl.l.attached = on_slot_attached
	sl.l.detached = on_slot_detached
	sl.l.size_hint = on_slot_size_hint
	wl.rikkiti_applet_slot_v1_add_listener(sl.proxy, &sl.l, sl)
	append(&st.slots, sl)
	wl.display_flush(st.display)
	debugf(st, "slot %d on surface %d at %d,%d %dx%d on the %v edge", sl.id, host, x, y, w, h, edge)
	return sl.id, true
}

// slot_set_geometry is Backend.slot_set_geometry.
slot_set_geometry :: proc(b: ^platform.Backend, id: platform.Slot, rect: [4]f32, edge: platform.Edge) {
	st := state(b)
	sl, _ := slot_find(st, id)
	if sl == nil do return
	x, y, w, h := slot_ints(rect)
	wl.rikkiti_applet_slot_v1_set_geometry(sl.proxy, x, y, w, h, slot_wl_edge(edge))
	wl.display_flush(st.display)
	debugf(st, "slot %d moved to %d,%d %dx%d on the %v edge", id, x, y, w, h, edge)
}

// slot_destroy is Backend.slot_destroy.
slot_destroy :: proc(b: ^platform.Backend, id: platform.Slot) {
	st := state(b)
	sl, i := slot_find(st, id)
	if sl == nil do return
	wl.rikkiti_applet_slot_v1_destroy(sl.proxy)
	ordered_remove(&st.slots, i)
	free(sl)
	wl.display_flush(st.display)
	debugf(st, "slot %d removed", id)
}

// slots_drop_host destroys the slots on a surface that is going (the
// compositor removes them with it anyway).
@(private)
slots_drop_host :: proc(st: ^State, host: platform.Surface) {
	for i := len(st.slots) - 1; i >= 0; i -= 1 {
		sl := st.slots[i]
		if sl.host != host do continue
		wl.rikkiti_applet_slot_v1_destroy(sl.proxy)
		ordered_remove(&st.slots, i)
		free(sl)
	}
}

// slots_shutdown destroys every slot and the host global.
@(private)
slots_shutdown :: proc(st: ^State) {
	for sl in st.slots {
		wl.rikkiti_applet_slot_v1_destroy(sl.proxy)
		free(sl)
	}
	delete(st.slots)
	if st.applet_host != nil {
		wl.rikkiti_applet_host_v1_destroy(st.applet_host)
		st.applet_host = nil
	}
}

@(private)
on_slot_token :: proc "c" (data: rawptr, p: wl.Proxy, token: cstring) {
	sl := (^Slot_State)(data)
	context = sl.st.ctx
	push(sl.st, platform.Ev_Slot{slot = sl.id, kind = .Token, token = strings.clone_from_cstring(token, text_allocator(sl.st))})
	debugf(sl.st, "slot %d: a token for an applet", sl.id)
}

@(private)
on_slot_attached :: proc "c" (data: rawptr, p: wl.Proxy, pid: u32) {
	sl := (^Slot_State)(data)
	context = sl.st.ctx
	push(sl.st, platform.Ev_Slot{slot = sl.id, kind = .Attached, pid = pid})
	debugf(sl.st, "slot %d: applet attached (pid %d)", sl.id, pid)
}

@(private)
on_slot_detached :: proc "c" (data: rawptr, p: wl.Proxy) {
	sl := (^Slot_State)(data)
	context = sl.st.ctx
	push(sl.st, platform.Ev_Slot{slot = sl.id, kind = .Detached})
	debugf(sl.st, "slot %d: applet detached", sl.id)
}

@(private)
on_slot_size_hint :: proc "c" (data: rawptr, p: wl.Proxy, least, preferred: u32) {
	sl := (^Slot_State)(data)
	context = sl.st.ctx
	push(sl.st, platform.Ev_Slot{slot = sl.id, kind = .Size_Hint, least = least, preferred = preferred})
	debugf(sl.st, "slot %d: applet would like %d, at least %d", sl.id, preferred, least)
}
