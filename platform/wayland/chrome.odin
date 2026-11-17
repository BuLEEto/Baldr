#+build linux
// chrome.odin — what a window asks of its own frame: begin a move or a
// resize that the compositor runs, maximise, minimise, or show the window
// menu. A window drawing its own title bar (Surface_Desc.undecorated) needs
// all of it.
//
// Move and resize take the serial of the press that started them: the
// compositor only hands over a drag a real input event asked for.
package wayland

import "baldr:platform"
import "baldr:platform/wayland/wl"

@(private)
surface_act :: proc(b: ^platform.Backend, surface: platform.Surface, act: platform.Window_Act, edges: platform.Window_Edges, at: [2]f32) -> bool {
	st := state(b)
	s := lookup(st, surface)
	if s == nil || s.toplevel == nil || st.seat == nil do return false
	switch act {
	case .Move:
		wl.xdg_toplevel_move(s.toplevel, st.seat, st.input_serial)
	case .Resize:
		wl.xdg_toplevel_resize(s.toplevel, st.seat, st.input_serial, resize_edge(edges))
	case .Maximize:
		wl.xdg_toplevel_set_maximized(s.toplevel)
	case .Unmaximize:
		wl.xdg_toplevel_unset_maximized(s.toplevel)
	case .Minimize:
		wl.xdg_toplevel_set_minimized(s.toplevel)
	case .Menu:
		wl.xdg_toplevel_show_window_menu(s.toplevel, st.seat, st.input_serial, i32(at.x), i32(at.y))
	}
	wl.display_flush(st.display)
	debugf(st, "surface %d: asked the desktop for %v", surface, act)
	return true
}

// resize_edge maps the toolkit's edges onto xdg-shell's numbering, where the
// corners are their own values rather than a pair of bits.
@(private)
resize_edge :: proc(e: platform.Window_Edges) -> wl.Xdg_Toplevel_Resize_Edge {
	switch {
	case e == {.Top}:            return .Top
	case e == {.Bottom}:         return .Bottom
	case e == {.Left}:           return .Left
	case e == {.Right}:          return .Right
	case e == {.Top, .Left}:     return .Top_Left
	case e == {.Top, .Right}:    return .Top_Right
	case e == {.Bottom, .Left}:  return .Bottom_Left
	case e == {.Bottom, .Right}: return .Bottom_Right
	}
	return .None
}

// surface_post_close puts a close on the queue as if the frame's own button
// had been pressed, so a window that draws its own closes down the same path
// as one the desktop decorates.
@(private)
surface_post_close :: proc(b: ^platform.Backend, surface: platform.Surface) {
	st := state(b)
	push(st, platform.Ev_Close{surface = surface, reason = .User})
}
