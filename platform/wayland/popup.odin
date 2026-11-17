#+build linux
// popup.odin — xdg_popups opened from a layer surface (through
// zwlr_layer_surface_v1.get_popup), a toplevel or another popup. An
// xdg_positioner puts the card beside its anchor rect, flipping to
// the other side and sliding along to stay on the screen; a grab with the
// latest input event makes a press outside dismiss it (popup_done). The
// surface is a margin larger than the card for its shadow; the window
// geometry is the card with the room it keeps clear of the screen's edges
// (platform.popup_positioner_rects); the input and blur regions follow the
// card.
package wayland

import "core:math"
import "baldr:platform"
import wl "baldr:platform/wayland/wl"

@(private)
popup_create :: proc(b: ^platform.Backend, desc: platform.Popup_Desc) -> (platform.Surface, bool) {
	st := state(b)
	parent := lookup(st, desc.parent)
	if parent == nil || st.wm_base == nil || (parent.layer_surface == nil && parent.applet == nil && parent.xdg_surface == nil) {
		debugf(st, "popup_create: surface %d can't open a popup", desc.parent)
		return 0, false
	}
	d := desc
	d.clear = clamp(d.clear, 0, d.margin) // the clearance lies inside the surface's margin
	s := surface_alloc(st, .Window, d.size + 2 * d.margin, transparent = true)
	s.popup_desc = d
	if parent.popup != nil do s.parent_clear = parent.popup_desc.clear
	s.card = desc.size
	s.output, s.frac_scale = parent.output, parent.frac_scale // its scale until it enters an output of its own

	s.xdg_surface = wl.xdg_wm_base_get_xdg_surface(st.wm_base, s.wl_surface)
	s.xdg_l = wl.xdg_surface_listener_noop()
	s.xdg_l.configure = on_popup_surface_configure
	wl.xdg_surface_add_listener(s.xdg_surface, &s.xdg_l, s)

	positioner := popup_positioner(st, d, s.parent_clear)
	if parent.layer_surface != nil {
		s.popup = wl.xdg_surface_get_popup(s.xdg_surface, nil, positioner)
		wl.zwlr_layer_surface_v1_get_popup(parent.layer_surface, s.popup)
	} else if parent.applet != nil { // the same way, through the applet
		s.popup = wl.xdg_surface_get_popup(s.xdg_surface, nil, positioner)
		wl.rikkiti_applet_v1_get_popup(parent.applet, s.popup)
	} else {
		s.popup = wl.xdg_surface_get_popup(s.xdg_surface, parent.xdg_surface, positioner)
	}
	wl.xdg_positioner_destroy(positioner)
	s.popup_l = wl.xdg_popup_listener_noop()
	s.popup_l.configure = on_popup_configure
	s.popup_l.popup_done = on_popup_done
	wl.xdg_popup_add_listener(s.popup, &s.popup_l, s)

	grab_from := "none"
	if desc.grab && st.seat != nil {
		if serial, from := grab_serial(st, parent); serial != 0 {
			wl.xdg_popup_grab(s.popup, st.seat, serial)
			grab_from = from
		}
	}
	if desc.backdrop != .None do set_backdrop(st, s, desc.backdrop)
	popup_regions(st, s)
	wl.wl_surface_commit(s.wl_surface)
	wl.display_flush(st.display)
	debugf(st, "popup %d from surface %d: %v beside %v (%v), card %v, grab %v (serial: %s)", s.id, desc.parent, desc.placement, desc.anchor, desc.align, desc.size, desc.grab, grab_from)
	return s.id, true
}

// popup_reposition moves an open popup with a new positioner (xdg_popup v3);
// the compositor's configure follows.
@(private)
popup_reposition :: proc(b: ^platform.Backend, surface: platform.Surface, desc: platform.Popup_Desc) -> bool {
	st := state(b)
	s := lookup(st, surface)
	if s == nil || s.popup == nil || wl.proxy_version(s.popup) < 3 do return false
	d := desc
	d.parent, d.grab = s.popup_desc.parent, s.popup_desc.grab // what it opened from and how stay
	d.clear = clamp(d.clear, 0, d.margin)
	s.popup_desc = d
	positioner := popup_positioner(st, d, s.parent_clear)
	s.reposition_token += 1
	wl.xdg_popup_reposition(s.popup, positioner, s.reposition_token)
	wl.xdg_positioner_destroy(positioner)
	wl.display_flush(st.display)
	debugf(st, "popup %d moved: beside %v, card %v", s.id, d.anchor, d.size)
	return true
}

// popup_positioner describes where the card goes: beside the anchor on the
// placement's side, left or top edges lined up, flipping and sliding when
// the screen ends, and keeping `clear` from its edges.
@(private)
popup_positioner :: proc(st: ^State, desc: platform.Popup_Desc, parent_clear: f32) -> wl.Proxy {
	p := wl.xdg_wm_base_create_positioner(st.wm_base)
	// The gap widens the anchor rect on both sides of the placement's axis
	// rather than riding on the offset, so a flip keeps it whichever way the
	// compositor treats a flipped offset.
	r := platform.popup_positioner_rects(desc, parent_clear)
	wl.xdg_positioner_set_size(p, r.size.x, r.size.y)
	wl.xdg_positioner_set_anchor_rect(p, r.anchor[0], r.anchor[1], r.anchor[2], r.anchor[3])
	anchor: wl.Xdg_Positioner_Anchor
	gravity: wl.Xdg_Positioner_Gravity
	adjust: wl.Xdg_Positioner_Constraint_Adjustment
	off := desc.offset
	// Along the anchor: a point on its edge and a gravity that grows the card
	// from there — the start corner growing on (Start), the edge's middle
	// growing both ways (Center), or the end corner growing back (End).
	// Sliding keeps any of them on screen.
	switch desc.placement {
	case .Below:
		switch desc.align {
		case .Start:  anchor, gravity = .Bottom_Left, .Bottom_Right
		case .Center: anchor, gravity = .Bottom, .Bottom
		case .End:    anchor, gravity = .Bottom_Right, .Bottom_Left
		}
		adjust = wl.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_FLIP_Y | wl.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_X | wl.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_Y
	case .Above:
		switch desc.align {
		case .Start:  anchor, gravity = .Top_Left, .Top_Right
		case .Center: anchor, gravity = .Top, .Top
		case .End:    anchor, gravity = .Top_Right, .Top_Left
		}
		adjust = wl.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_FLIP_Y | wl.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_X | wl.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_Y
	case .Right:
		switch desc.align {
		case .Start:  anchor, gravity = .Top_Right, .Bottom_Right
		case .Center: anchor, gravity = .Right, .Right
		case .End:    anchor, gravity = .Bottom_Right, .Top_Right
		}
		adjust = wl.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_FLIP_X | wl.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_Y | wl.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_X
	case .Left:
		switch desc.align {
		case .Start:  anchor, gravity = .Top_Left, .Bottom_Left
		case .Center: anchor, gravity = .Left, .Left
		case .End:    anchor, gravity = .Bottom_Left, .Top_Left
		}
		adjust = wl.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_FLIP_X | wl.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_Y | wl.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_X
	case .At:
		anchor, gravity = .Top_Left, .Bottom_Right
		adjust = wl.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_FLIP_X | wl.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_FLIP_Y | wl.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_X | wl.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_Y
	}
	wl.xdg_positioner_set_anchor(p, anchor)
	wl.xdg_positioner_set_gravity(p, gravity)
	wl.xdg_positioner_set_constraint_adjustment(p, adjust)
	wl.xdg_positioner_set_offset(p, i32(math.round(off.x)), i32(math.round(off.y)))
	wl.xdg_positioner_set_reactive(p) // v3: placed again when what it opened from moves
	return p
}

@(private)
on_popup_configure :: proc "c" (data: rawptr, p: wl.Proxy, x, y, width, height: i32) {
	s := (^Surface_State)(data)
	s.pending_popup = {x, y, width, height}
}

// grab_serial is the serial a popup's grab goes with: the latest input
// event's; before there has been any, the newer of the pointer's and the
// keyboard's latest enter; before those, its parent's latest configure. A
// popup opened before any input (a start menu on the compositor's own key
// right after login) still needs a grab: in xdg-shell only the topmost
// grabbing popup takes the keyboard. wlroots does not check the serial; a
// stricter compositor may dismiss the popup at once (popup_done), which is
// better than one that cannot be typed into. 0: nothing at all yet.
@(private)
grab_serial :: proc(st: ^State, parent: ^Surface_State) -> (serial: u32, from: string) {
	if st.input_serial != 0 do return st.input_serial, "input"
	a, b := st.ptr_enter_serial, st.kbd_enter_serial
	if a != 0 || b != 0 {
		newer := a if b == 0 || (a != 0 && i32(a - b) > 0) else b // serials only grow, wrapping
		return newer, "enter"
	}
	if parent != nil && parent.configure_serial != 0 do return parent.configure_serial, "configure"
	return 0, ""
}

// on_popup_surface_configure acks, tells the toolkit where the card went,
// and sizes the surface to the card and its margin.
@(private)
on_popup_surface_configure :: proc "c" (data: rawptr, p: wl.Proxy, serial: u32) {
	s := (^Surface_State)(data)
	context = s.st.ctx
	s.configure_serial = serial
	wl.xdg_surface_ack_configure(p, serial)
	pos, card := platform.popup_card_of(s.pending_popup, s.popup_desc.clear, s.parent_clear)
	if s.pending_popup[2] <= 0 || s.pending_popup[3] <= 0 do card = s.popup_desc.size
	resized := card != s.card
	s.card = card
	debugf(s.st, "popup %d placed: card at %v, %v", s.id, pos, card)
	push(s.st, platform.Ev_Popup_Configure{surface = s.id, pos = pos, size = card})
	if resized || !s.configured do popup_regions(s.st, s)
	size := platform.popup_surface_size(card, s.popup_desc.margin, s.size if s.configured else {})
	kept := s.configured && size == s.size
	apply_geometry(s, size)
	if kept && resized do popup_window_geometry(s) // the same surface, a new card: the geometry the compositor places follows it
}

// popup_window_geometry sets a popup's window geometry: its card and the room
// kept clear around it, inside the margin its shadow draws in.
@(private)
popup_window_geometry :: proc(s: ^Surface_State) {
	c := s.popup_desc.clear
	m := i32(math.round(s.popup_desc.margin - c))
	wl.xdg_surface_set_window_geometry(s.xdg_surface, m, m, i32(math.ceil(s.card.x + 2 * c)), i32(math.ceil(s.card.y + 2 * c)))
}

@(private)
on_popup_done :: proc "c" (data: rawptr, p: wl.Proxy) {
	s := (^Surface_State)(data)
	context = s.st.ctx
	debugf(s.st, "popup %d dismissed", s.id)
	push(s.st, platform.Ev_Popup_Done{surface = s.id})
}

// popup_regions: the pointer only on the card (a press on its shadow is a
// press outside); the blur on the card with its corners rounded.
@(private)
popup_regions :: proc(st: ^State, s: ^Surface_State) {
	m := i32(math.round(s.popup_desc.margin))
	w, h := i32(math.ceil(s.card.x)), i32(math.ceil(s.card.y))
	input := wl.wl_compositor_create_region(st.compositor)
	wl.wl_region_add(input, m, m, w, h)
	wl.wl_surface_set_input_region(s.wl_surface, input)
	wl.wl_region_destroy(input)
	if s.bg_effect != nil && s.blur {
		blur := wl.wl_compositor_create_region(st.compositor)
		region_add_rounded(blur, m, m, w, h, i32(math.round(s.popup_desc.radius)))
		wl.ext_background_effect_surface_v1_set_blur_region(s.bg_effect, blur)
		wl.wl_region_destroy(blur)
	}
}

// region_add_rounded adds a rounded rectangle: one rect per row through the
// corners, one for the rest.
@(private)
region_add_rounded :: proc(region: wl.Proxy, x, y, w, h, radius: i32) {
	r := clamp(radius, 0, min(w, h) / 2)
	if r == 0 {
		wl.wl_region_add(region, x, y, w, h)
		return
	}
	for i in 0 ..< r {
		dy := f32(r - i) - 0.5
		inset := r - i32(math.round(math.sqrt(max(f32(r * r) - dy * dy, 0))))
		wl.wl_region_add(region, x + inset, y + i, w - 2 * inset, 1)
		wl.wl_region_add(region, x + inset, y + h - 1 - i, w - 2 * inset, 1)
	}
	wl.wl_region_add(region, x, y + r, w, h - 2 * r)
}
