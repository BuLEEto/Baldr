#+build linux
package x11

// Reading properties back off a window: whether the window manager thinks
// it is maximised or full-screen, the session's DPI, and the size hints.
//
// X has no configure/ack carrying state as xdg-shell does: a
// ConfigureNotify says only the new size. The rest is properties the window
// manager writes, so `maximized` and `fullscreen` are read here on a
// PropertyNotify.

import "core:strconv"
import "core:strings"
import "baldr:platform"

// PROP_WORDS is how much of a property to ask for, in 4-byte units, not
// bytes: enough for _NET_WM_STATE (a few atoms) and RESOURCE_MANAGER (a few
// kilobytes of text).
@(private = "file") PROP_WORDS :: 4096

// prop_atoms reads a property that holds a list of atoms. The slice is
// temp-allocated.
@(private)
prop_atoms :: proc(x: ^X11, w: Window, property: Atom) -> []Atom {
	if property == ATOM_NONE do return nil
	cookie := api.get_property(x.conn, 0, w, property, ATOM_ATOM, 0, PROP_WORDS)
	err: ^Generic_Error
	reply := api.get_property_reply(x.conn, cookie, &err)
	free_reply(err)
	if reply == nil do return nil
	defer free_reply(reply)
	if reply.type != ATOM_ATOM || reply.format != 32 do return nil
	n := int(reply.value_len)
	if n <= 0 do return nil
	src := ([^]Atom)(api.get_property_value(reply))
	out := make([]Atom, n, context.temp_allocator)
	copy(out, src[:n])
	return out
}

// prop_text reads a property that holds bytes of text. Temp-allocated.
@(private)
prop_text :: proc(x: ^X11, w: Window, property: Atom) -> string {
	if property == ATOM_NONE do return ""
	cookie := api.get_property(x.conn, 0, w, property, ATOM_STRING, 0, PROP_WORDS)
	err: ^Generic_Error
	reply := api.get_property_reply(x.conn, cookie, &err)
	free_reply(err)
	if reply == nil do return ""
	defer free_reply(reply)
	n := int(api.get_property_value_length(reply))
	if n <= 0 do return ""
	src := ([^]u8)(api.get_property_value(reply))
	return strings.clone(string(src[:n]), context.temp_allocator)
}

// read_wm_state asks the window manager what it has decided about this
// window, and says whether anything the toolkit reports changed.
@(private)
read_wm_state :: proc(x: ^X11, s: ^Surface) -> (changed: bool) {
	states := prop_atoms(x, s.window, x.atoms.net_wm_state)
	full, horz, vert := false, false, false
	for a in states {
		switch a {
		case x.atoms.net_wm_state_fullscreen:      full = true
		case x.atoms.net_wm_state_maximized_horz:  horz = true
		case x.atoms.net_wm_state_maximized_vert:  vert = true
		}
	}
	// Maximised in one direction only is not what the toolkit means by
	// maximised: it means "the desktop is sizing this", which is both.
	max_now := horz && vert
	changed = max_now != s.maximized || full != s.fullscreen
	s.maximized, s.fullscreen = max_now, full
	return
}

// session_scale is the one scale X has: no per-window DPI and no protocol
// for it, so it reads `Xft.dpi` from the resource database, as every
// toolkit does. 1 when nothing says otherwise. Mixed-DPI setups cannot be
// served per surface as on Wayland.
@(private)
session_scale :: proc(x: ^X11) -> f32 {
	if x.screen == nil do return 1
	rm := prop_text(x, x.screen.root, ATOM_RESOURCE_MANAGER)
	if rm == "" do return 1
	// The database is "Name: value" a line at a time.
	for line in strings.split_lines_iterator(&rm) {
		trimmed := strings.trim_space(line)
		if !strings.has_prefix(trimmed, "Xft.dpi") do continue
		colon := strings.index_byte(trimmed, ':')
		if colon < 0 do continue
		if dpi, ok := strconv.parse_f64(strings.trim_space(trimmed[colon + 1:])); ok && dpi > 0 {
			return f32(dpi) / 96
		}
	}
	return 1
}

// wm_state_changed is the PropertyNotify hook: re-read and, when the answer
// differs, tell the app with a configure carrying the new truth.
@(private)
wm_state_changed :: proc(x: ^X11, s: ^Surface) {
	if !read_wm_state(x, s) do return
	debugf(x, "surface %d: the window manager says maximized=%v fullscreen=%v", s.id, s.maximized, s.fullscreen)
	emit_configure(x, s)
}

// ------------------------------------------------------------- size hints

// WM_SIZE_HINTS flag bits (ICCCM 4.1.2.3). Position uses the "user
// specified" pair, which managers honour; `P_POSITION` ("program
// specified") is often overridden.
US_POSITION :: u32(1 << 0)
US_SIZE     :: u32(1 << 1)
P_MIN_SIZE  :: u32(1 << 4)
P_MAX_SIZE  :: u32(1 << 5)

// wm_normal_hints tells the window manager where the window asked to be and
// how large it may be dragged (`Surface_Desc.position`, `min_size`,
// `max_size`, `fixed_size`). Both are hints the manager may ignore; the
// limits bind only its own resize handling.
//
// The property is always 18 CARD32s, zero where no flag claims a field:
// flags, the four obsolete x/y/width/height, min, max, inc, aspect (x2),
// base, gravity.
wm_normal_hints :: proc(x: ^X11, w: Window, pos: Maybe([2]i16), size, min, max: [2]u16) {
	hints: [18]u32
	if p, want := pos.?; want {
		hints[0] |= US_POSITION | US_SIZE
		hints[1], hints[2] = u32(i32(p.x)), u32(i32(p.y)) // x, y
		hints[3], hints[4] = u32(size.x), u32(size.y)     // width, height
	}
	if min.x > 0 || min.y > 0 {
		hints[0] |= P_MIN_SIZE
		hints[5], hints[6] = u32(min.x), u32(min.y)
	}
	if max.x > 0 || max.y > 0 {
		hints[0] |= P_MAX_SIZE
		hints[7], hints[8] = u32(max.x), u32(max.y)
	}
	if hints[0] == 0 do return // nothing asked for: leave the property alone
	api.change_property(x.conn, PROP_MODE_REPLACE, w, ATOM_WM_NORMAL_HINTS,
		ATOM_WM_SIZE_HINTS, 32, u32(len(hints)), raw_data(hints[:]))
}

// surface_position is where the window's top-left corner is on the desktop,
// the manager's frame included.
//
// Translated to root coordinates rather than read from the window's x/y: a
// reparenting manager makes those relative to its frame (a small offset
// like {1, 28}). Root coordinates are what `Surface_Desc.position` takes,
// so the two round-trip.
surface_position :: proc(b: ^platform.Backend, id: platform.Surface) -> (pos: [2]i32, ok: bool) {
	x := data(b)
	if x == nil || x.conn == nil || x.screen == nil do return {}, false
	s := get_surface(x, id)
	if s == nil || !s.live do return {}, false
	ck := api.translate_coordinates(x.conn, s.window, x.screen.root, 0, 0)
	err: ^Generic_Error
	rep := api.translate_coordinates_reply(x.conn, ck, &err)
	if rep == nil {
		free_reply(err)
		return {}, false
	}
	defer free_reply(rep)
	return {i32(rep.dst_x), i32(rep.dst_y)}, true
}
