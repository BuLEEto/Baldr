#+build linux
package x11

// INCR: moving a selection that will not fit in one property.
//
// A single X request is capped, at a couple of hundred kilobytes on a
// typical server, so a large selection (a picture) goes as INCR, a protocol
// inside the selection one. Both sides:
//
//   1. The owner answers with a property of type INCR holding roughly how
//      much is coming, and watches the requestor's window.
//   2. The requestor sees INCR, deletes the property, and waits.
//   3. Deleting the property asks for the next piece; the owner writes it.
//   4. A zero-length chunk is the end.
//
// Because delete means "more", `read_selection_property` always deletes the
// property, INCR or not.

import "core:strings"
import "core:time"
import "baldr:platform"

// INCR_WAIT_MS bounds a single chunk, not the transfer: each chunk should
// be prompt, while the whole may take a while.
@(private = "file") INCR_WAIT_MS :: 2000

// Incr_Out is a transfer this app is sending, one per requestor.
@(private)
Incr_Out :: struct {
	requestor: Window,
	property:  Atom,
	target:    Atom,
	data:      []u8, // owned: a copy, because the selection may be replaced mid-transfer
	sent:      int,
	live:      bool,
}

// chunk_size is what fits in one property write, with room for the request
// around it. maximum_request_length is in 4-byte units.
@(private)
chunk_size :: proc(x: ^X11) -> int {
	words := int(api.get_maximum_request_length(x.conn))
	if words <= 0 do return 64 * 1024
	n := words * 4 - 1024 // the request header and then some
	return clamp(n, 4 * 1024, 1024 * 1024)
}

// incr_begin answers a SelectionRequest that is too big for one property.
// The reply says "INCR, about this much"; the data follows a piece at a
// time as the requestor asks for it.
@(private)
incr_begin :: proc(x: ^X11, e: ^Selection_Request_Event, prop: Atom, data: []u8) -> bool {
	if x.atoms.incr == ATOM_NONE do return false
	slot := -1
	for o, i in x.incr_out do if !o.live { slot = i; break }
	if slot < 0 {
		append(&x.incr_out, Incr_Out{})
		slot = len(x.incr_out) - 1
	}
	o := &x.incr_out[slot]
	o^ = Incr_Out{
		requestor = e.requestor,
		property  = prop,
		target    = e.target,
		data      = make([]u8, len(data), x.allocator),
		live      = true,
	}
	copy(o.data, data)

	// The requestor's property changes are what drive the rest, so they
	// have to be asked for before the first reply goes out.
	vals := [1]u32{EVENT_MASK_PROPERTY_CHANGE}
	api.change_window_attributes(x.conn, e.requestor, CW_EVENT_MASK, raw_data(vals[:]))

	total := u32(len(data))
	api.change_property(x.conn, PROP_MODE_REPLACE, e.requestor, prop, x.atoms.incr, 32, 1, &total)
	api.flush(x.conn)
	debugf(x, "INCR out: %d bytes to window %d", len(data), u32(e.requestor))
	return true
}

// incr_continue is the requestor deleting the property, which means "send
// the next piece". A zero-length write ends it.
@(private)
incr_continue :: proc(x: ^X11, e: ^Property_Notify_Event) {
	if e.state != PROPERTY_DELETE do return
	for &o in x.incr_out {
		if !o.live || o.requestor != e.window || o.property != e.atom do continue
		if o.sent >= len(o.data) {
			// The end: a property of length zero, and then it is finished.
			api.change_property(x.conn, PROP_MODE_REPLACE, o.requestor, o.property, o.target, 8, 0, nil)
			api.flush(x.conn)
			debugf(x, "INCR out: finished, %d bytes", len(o.data))
			delete(o.data, x.allocator)
			o = {}
			return
		}
		n := min(chunk_size(x), len(o.data) - o.sent)
		api.change_property(x.conn, PROP_MODE_REPLACE, o.requestor, o.property, o.target, 8,
			u32(n), raw_data(o.data[o.sent:o.sent + n]))
		api.flush(x.conn)
		o.sent += n
		return
	}
}

@(private)
incr_stop :: proc(x: ^X11) {
	for &o in x.incr_out {
		if o.live do delete(o.data, x.allocator)
		o = {}
	}
	delete(x.incr_out)
	x.incr_out = nil
}

// incr_read is the other half: the property came back as INCR, so the real
// data arrives a piece at a time, each announced by a PropertyNotify and
// asked for by deleting the last one.
@(private)
incr_read :: proc(x: ^X11, allocator := context.allocator) -> (string, bool) {
	out := make([dynamic]u8, 0, 64 * 1024, context.temp_allocator)
	// Deleting the INCR property is what tells the owner to start.
	api.delete_property(x.conn, x.clip_window, x.atoms.baldr_selection)
	api.flush(x.conn)

	last := time.tick_now()
	start := last
	for {
		if time.duration_milliseconds(time.tick_since(last)) > INCR_WAIT_MS {
			debugf(x, "INCR in: the owner stopped after %d bytes", len(out))
			return "", false
		}
		// as a whole too, however steadily the owner dribbles, and never past the size cap
		if time.duration_milliseconds(time.tick_since(start)) > platform.TRANSFER_DEADLINE_MS || len(out) > platform.TRANSFER_MAX_BYTES {
			debugf(x, "INCR in: given up after %d bytes", len(out))
			return "", false
		}
		ev := api.poll_for_event(x.conn)
		if ev == nil {
			if api.connection_has_error(x.conn) != 0 do return "", false
			time.sleep(time.Millisecond)
			continue
		}
		kind := ev.response_type & 0x7f
		if kind != PROPERTY_NOTIFY {
			handle(x, ev) // the app's events are not lost to a big paste
			free_reply(ev)
			continue
		}
		e := (^Property_Notify_Event)(ev)
		mine := e.window == x.clip_window && e.atom == x.atoms.baldr_selection && e.state == PROPERTY_NEW_VALUE
		free_reply(ev)
		if !mine do continue

		n, ok := incr_chunk(x, &out)
		if !ok do return "", false
		// Deleting it asks for the next piece; a zero-length one was the end.
		api.delete_property(x.conn, x.clip_window, x.atoms.baldr_selection)
		api.flush(x.conn)
		if n == 0 {
			debugf(x, "INCR in: %d bytes", len(out))
			return strings.clone(string(out[:]), allocator), true
		}
		last = time.tick_now()
	}
}

// incr_chunk appends one piece and says how long it was; 0 is the end.
@(private = "file")
incr_chunk :: proc(x: ^X11, out: ^[dynamic]u8) -> (int, bool) {
	cookie := api.get_property(x.conn, 0, x.clip_window, x.atoms.baldr_selection, Atom(0), 0, 0x1fffffff)
	err: ^Generic_Error
	reply := api.get_property_reply(x.conn, cookie, &err)
	free_reply(err)
	if reply == nil do return 0, false
	defer free_reply(reply)
	n := int(api.get_property_value_length(reply))
	if n <= 0 do return 0, true
	src := ([^]u8)(api.get_property_value(reply))
	append(out, ..src[:n])
	return n, true
}

_ :: platform
