#+build linux
package x11

// XDND: drag and drop between X clients.
//
// This is the target half: something dragged onto a Baldr window. The
// source half (dragging out) is xdnd_source.odin.
//
// XDND is a conversation in client messages, each step with a reply the
// other side waits for:
//
//   XdndEnter     the source says "I am over you, and I offer these types"
//   XdndPosition  ...and again for every move, with where and what action
//   XdndStatus    the target answers *every* Position: will I take it, and
//                 over what rectangle the answer holds good
//   XdndDrop      the pointer was let go
//   XdndFinished  the target says it is done, and only then may the source
//                 free what it was carrying
//
// A Position left without a Status wedges the drag (the source waits, the
// cursor sticks), so Status goes back for every Position, refusals too.
//
// The data comes through the XdndSelection selection, converted to the
// type the target picked: a big drop is INCR (incr.odin), and files arrive
// as text/uri-list.

import "core:strings"
import "core:time"
import "baldr:platform"

@(private = "file") XDND_VERSION :: 5

// The bits of XdndPosition's and XdndStatus's data words that are not
// coordinates. Status packs "I will take it" into bit 0 of data[1], and the
// rectangle it holds for into data[2] and data[3].
@(private = "file") STATUS_ACCEPT :: 1 << 0

// Xdnd is the drag in progress over this app, if any.
@(private)
Xdnd :: struct {
	source:    Window, // the other program's window; WINDOW_NONE when no drag
	surface:   ^Surface,
	version:   u32,
	types:     [dynamic]Atom, // what it offers, best first
	mimes:     [dynamic]string, // …the same as names, owned
	action:    Atom,
	accepted:  bool, // what we last told the source
	dropped:   bool, // XdndDrop arrived; waiting for the data
	pos:       [2]f32, // where the last XdndPosition was, in the surface's logical px
	drop_time: Timestamp,
	// A conversion asked for and not yet answered. Parked rather than
	// waited on: a source still making its files may take up to
	// DROP_WAIT_MS, and the SelectionNotify finishes it.
	waiting:   bool,
	deadline:  time.Tick,
}

@(private)
xdnd_start :: proc(x: ^X11) {
	x.xdnd.source = WINDOW_NONE
}

@(private)
xdnd_stop :: proc(x: ^X11) {
	xdnd_clear(x)
	delete(x.xdnd.types)
	delete(x.xdnd.mimes)
	x.xdnd = {}
}

@(private = "file")
xdnd_clear :: proc(x: ^X11) {
	for m in x.xdnd.mimes do delete(m, x.allocator)
	clear(&x.xdnd.mimes)
	clear(&x.xdnd.types)
	x.xdnd.source = WINDOW_NONE
	x.xdnd.surface = nil
	x.xdnd.dropped = false
	x.xdnd.accepted = false
}

// xdnd_advertise puts XdndAware on a window, which is the whole of how a
// source learns this window takes drops. Without it a drag passes over the
// app as though it were the desktop.
@(private)
xdnd_advertise :: proc(x: ^X11, w: Window) {
	if x.atoms.xdnd_aware == ATOM_NONE do return
	v := u32(XDND_VERSION)
	api.change_property(x.conn, PROP_MODE_REPLACE, w, x.atoms.xdnd_aware, ATOM_ATOM, 32, 1, &v)
}

// xdnd_message handles the source's client messages. True when it was one.
@(private)
xdnd_message :: proc(x: ^X11, e: ^Client_Message_Event) -> bool {
	switch e.type {
	case x.atoms.xdnd_enter:    xdnd_enter(x, e)
	case x.atoms.xdnd_position: xdnd_position(x, e)
	case x.atoms.xdnd_leave:    xdnd_leave(x, e)
	case x.atoms.xdnd_drop:     xdnd_drop(x, e)
	case: return false
	}
	return true
}

@(private = "file")
xdnd_enter :: proc(x: ^X11, e: ^Client_Message_Event) {
	s := surface_of_window(x, e.window)
	if s == nil || !s.live do return
	xdnd_clear(x)
	x.xdnd.source = Window(e.data.data32[0])
	x.xdnd.surface = s
	x.xdnd.version = e.data.data32[1] >> 24

	// Three types fit in the message; more than three are in a property on
	// the source's window, and bit 0 says which.
	if e.data.data32[1] & 1 != 0 {
		for a in prop_atoms_of(x, x.xdnd.source, x.atoms.xdnd_type_list) do append(&x.xdnd.types, a)
	} else {
		for i in 2 ..= 4 {
			if a := Atom(e.data.data32[i]); a != ATOM_NONE do append(&x.xdnd.types, a)
		}
	}
	for a in x.xdnd.types do append(&x.xdnd.mimes, atom_name(x, a, x.allocator))

	debugf(x, "XDND enter from window %d, v%d, %d type(s): %v",
		u32(x.xdnd.source), x.xdnd.version, len(x.xdnd.types), x.xdnd.mimes[:])
	push(x, platform.Ev_Drag_Enter{
		surface = s.id,
		pos     = {}, // XdndEnter carries no position; the first Position has it
		mimes   = x.xdnd.mimes[:],
		// Whether this drag is ours, so the toolkit can hand the drop the
		// app's own payload (`drag_user`), not only the MIME data.
		own     = x.drag.live,
	})
}

@(private = "file")
xdnd_position :: proc(x: ^X11, e: ^Client_Message_Event) {
	if x.xdnd.source == WINDOW_NONE || x.xdnd.surface == nil do return
	s := x.xdnd.surface
	// The position is root-relative. Not converted by subtracting `s.pos`:
	// a reparented window's ConfigureNotify is relative to the manager's
	// frame (1,18 for a window really at 221,134), so the server is asked
	// where the window is.
	rx, ry := i16(e.data.data32[2] >> 16), i16(e.data.data32[2] & 0xffff)
	ox, oy := root_origin(x, s.window)
	pos := logical(x, rx - ox, ry - oy)
	x.xdnd.action = Atom(e.data.data32[4])
	x.xdnd.pos = pos
	push(x, platform.Ev_Drag_Motion{surface = s.id, pos = pos})
	// Answer now with what the toolkit last decided, one move behind,
	// rather than hold the source up while a frame is built.
	xdnd_status(x)
}

// xdnd_status is the reply every XdndPosition must get.
@(private = "file")
xdnd_status :: proc(x: ^X11) {
	if x.xdnd.source == WINDOW_NONE || x.xdnd.surface == nil do return
	ev := Client_Message_Event{
		response_type = CLIENT_MESSAGE,
		format        = 32,
		window        = x.xdnd.source,
		type          = x.atoms.xdnd_status,
	}
	ev.data.data32[0] = u32(x.xdnd.surface.window)
	ev.data.data32[1] = STATUS_ACCEPT if x.xdnd.accepted else 0
	// A zero rectangle means "ask me again for every move", which is what a
	// toolkit wants: what is under the pointer changes with it.
	ev.data.data32[2] = 0
	ev.data.data32[3] = 0
	ev.data.data32[4] = u32(x.atoms.xdnd_action_copy if x.xdnd.accepted else ATOM_NONE)
	api.send_event(x.conn, 0, x.xdnd.source, 0, &ev)
	api.flush(x.conn)
}

@(private = "file")
xdnd_leave :: proc(x: ^X11, e: ^Client_Message_Event) {
	if x.xdnd.surface == nil do return
	push(x, platform.Ev_Drag_Leave{surface = x.xdnd.surface.id})
	debugf(x, "XDND leave")
	xdnd_clear(x)
}

@(private = "file")
xdnd_drop :: proc(x: ^X11, e: ^Client_Message_Event) {
	if x.xdnd.surface == nil do return
	// A refused Drop still needs XdndFinished, or the source waits for
	// ever; it is finished here rather than handed to the app.
	if !x.xdnd.accepted {
		debugf(x, "XDND drop on something that takes nothing: finishing it")
		xdnd_finish(x, false)
		return
	}
	x.xdnd.dropped = true
	x.xdnd.drop_time = Timestamp(e.data.data32[2])
	debugf(x, "XDND drop")
	// The last XdndPosition, not pointer_pos: the source holds a pointer
	// grab, so no motion reaches us and pointer_pos is stale.
	push(x, platform.Ev_Drag_Drop{
		surface = x.xdnd.surface.id,
		pos     = x.xdnd.pos,
		action  = .Copy,
	})
}

// drag_accept says whether the app would take this drag; the source hears
// it in the next XdndStatus and shows the person a cursor to match.
@(private)
drag_accept :: proc(b: ^platform.Backend, accept: bool) {
	x := data(b)
	if x.xdnd.source == WINDOW_NONE do return
	if x.xdnd.accepted == accept do return
	x.xdnd.accepted = accept
	xdnd_status(x) // say so now rather than waiting for the next move
}

// drag_receive asks the source for the drop in one form and does not wait.
// The answer arrives like any paste, INCR included, and becomes
// Ev_Drag_Data. A source still making what it hands over (a file being
// written) gets `platform.DROP_WAIT_MS`; pumping for that inside this call
// would freeze the app.
@(private)
drag_receive :: proc(b: ^platform.Backend, mime: string) -> bool {
	x := data(b)
	if x.xdnd.source == WINDOW_NONE || !x.xdnd.dropped do return false
	if x.xdnd.waiting do return false // one at a time: the app asks again when this one lands
	target := ATOM_NONE
	for a, i in x.xdnd.types {
		if x.xdnd.mimes[i] == mime { target = a; break }
	}
	if target == ATOM_NONE {
		debugf(x, "XDND the app asked for %q, which was not offered (%v)", mime, x.xdnd.mimes[:])
		return false
	}
	api.delete_property(x.conn, x.clip_window, x.atoms.baldr_drop)
	api.convert_selection(x.conn, x.clip_window, x.atoms.xdnd_selection, target,
		x.atoms.baldr_drop, CURRENT_TIME)
	api.flush(x.conn)
	x.xdnd.waiting = true
	x.xdnd.deadline = time.tick_now()
	debugf(x, "XDND asked for %q; waiting up to %d ms for the source", mime, platform.DROP_WAIT_MS)
	return true
}

// drop_answered finishes a parked conversion: the source wrote the data onto
// our window, or refused. Called from the SelectionNotify the pump hands on.
@(private)
drop_answered :: proc(x: ^X11, e: ^Selection_Notify_Event) -> bool {
	if !x.xdnd.waiting || e.property != x.atoms.baldr_drop do return false
	x.xdnd.waiting = false
	if e.property == ATOM_NONE {
		debugf(x, "XDND the source refused the conversion")
		push(x, platform.Ev_Drag_Data{ok = false})
		return true
	}
	// Reading what is already written is fast, INCR included.
	text, ok := read_selection_property(x, x.atoms.baldr_drop, text_allocator(x))
	debugf(x, "XDND the source answered: %v, %d bytes", ok, len(text))
	push(x, platform.Ev_Drag_Data{data = transmute([]u8)text, ok = ok})
	return true
}

// drop_wait_ms is how long is left on a parked drop, so the pump never
// sleeps past it.
@(private)
drop_wait_ms :: proc(x: ^X11) -> (i32, bool) {
	if !x.xdnd.waiting do return 0, false
	spent := time.duration_milliseconds(time.tick_since(x.xdnd.deadline))
	return i32(max(platform.DROP_WAIT_MS - spent, 0)), true
}

// drop_timeout gives up on a source that never answered, so an app that
// asked is not left waiting for ever. Called once a pump.
@(private)
drop_timeout :: proc(x: ^X11) {
	if !x.xdnd.waiting do return
	if time.duration_milliseconds(time.tick_since(x.xdnd.deadline)) < platform.DROP_WAIT_MS do return
	x.xdnd.waiting = false
	debugf(x, "XDND the source did not answer within %d ms", platform.DROP_WAIT_MS)
	push(x, platform.Ev_Drag_Data{ok = false})
}

// drag_finish tells the source it may let go of what it was carrying.
// Until this arrives the source is still holding the drag.
@(private)
drag_finish :: proc(b: ^platform.Backend, accepted: bool) {
	xdnd_finish(data(b), accepted)
}

@(private = "file")
xdnd_finish :: proc(x: ^X11, accepted: bool) {
	if x.xdnd.source == WINDOW_NONE do return
	ev := Client_Message_Event{
		response_type = CLIENT_MESSAGE,
		format        = 32,
		window        = x.xdnd.source,
		type          = x.atoms.xdnd_finished,
	}
	ev.data.data32[0] = u32(x.xdnd.surface.window if x.xdnd.surface != nil else WINDOW_NONE)
	ev.data.data32[1] = 1 if accepted else 0
	ev.data.data32[2] = u32(x.atoms.xdnd_action_copy if accepted else ATOM_NONE)
	api.send_event(x.conn, 0, x.xdnd.source, 0, &ev)
	api.flush(x.conn)
	debugf(x, "XDND finished (accepted %v)", accepted)
	xdnd_clear(x)
}

// prop_atoms_of reads an atom-list property off somebody else's window.
@(private = "file")
prop_atoms_of :: proc(x: ^X11, w: Window, property: Atom) -> []Atom {
	return prop_atoms(x, w, property)
}

// atom_name asks the server what an atom is called, which is what a MIME
// type is on X: the type names in a drag are atoms whose names are the MIME
// strings.
@(private)
atom_name :: proc(x: ^X11, a: Atom, allocator := context.allocator) -> string {
	ck := api.get_atom_name(x.conn, a)
	err: ^Generic_Error
	reply := api.get_atom_name_reply(x.conn, ck, &err)
	free_reply(err)
	if reply == nil do return strings.clone("", allocator)
	defer free_reply(reply)
	n := int(api.get_atom_name_name_length(reply))
	if n <= 0 do return strings.clone("", allocator)
	src := ([^]u8)(api.get_atom_name_name(reply))
	return strings.clone(string(src[:n]), allocator)
}

// root_origin is where a window's top-left really is on screen, which is
// not what its own ConfigureNotify says once a window manager has
// reparented it.
@(private)
root_origin :: proc(x: ^X11, w: Window) -> (i16, i16) {
	if x.screen == nil do return 0, 0
	ck := api.translate_coordinates(x.conn, w, x.screen.root, 0, 0)
	err: ^Generic_Error
	reply := api.translate_coordinates_reply(x.conn, ck, &err)
	free_reply(err)
	if reply == nil do return 0, 0
	defer free_reply(reply)
	return reply.dst_x, reply.dst_y
}
