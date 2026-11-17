#+build linux
package x11

// The clipboard and the primary selection.
//
// A selection on X is not a buffer the server keeps but an owner window:
// the paster asks the server to convert the selection to a target, the
// owner writes the bytes onto the requestor's window as a property and
// says so, and the requestor reads them off. Both halves are here.
//
//   - A copy does not outlive the program: the owner is our window. Holding
//     it after exit is a clipboard manager's job, a separate protocol not
//     spoken here.
//   - Getting a selection is asynchronous but `Backend.clipboard_get` is
//     not, so the get pumps the connection until the answer or a deadline,
//     handling every other event on the way: a paste must not swallow a
//     resize.
//
// The owner is a dedicated unmapped InputOnly window, not a surface's: a
// selection outlives the window it was copied from.

import "core:strings"
import "core:time"
import "baldr:platform"

// SELECTION_WAIT_MS bounds a paste. The owner is another program, and it
// may be busy, wedged, or gone between owning the selection and answering
// for it; waiting for ever would hang the app's whole loop.
@(private = "file") SELECTION_WAIT_MS :: 1000

// Selection is one of the two X selections the toolkit uses. There is a
// third, SECONDARY, which nothing has used since the 1990s.
@(private)
Selection :: enum u8 { Clipboard, Primary }

// Owned is what this app has put on a selection: one or more forms of the
// same thing — plain text beside a list of files, say. Owned by the backend
// until the selection is lost.
@(private)
Owned :: struct {
	items: []platform.Clip_Item, // owned copies; empty when this app owns nothing
	live:  bool,
}

// owned_text finds the plain-text form, which is what the text pair of
// clipboard_get / _set deals in. "" when there is none.
@(private = "file")
owned_text :: proc(o: ^Owned) -> (string, bool) {
	for it in o.items {
		if it.mime == MIME_TEXT || it.mime == "text/plain" do return string(it.data), true
	}
	return "", false
}

@(private = "file") MIME_TEXT :: "text/plain;charset=utf-8"

@(private = "file")
owned_free :: proc(x: ^X11, o: ^Owned) {
	for it in o.items {
		delete(it.mime, x.allocator)
		delete(it.data, x.allocator)
		if it.later != nil do platform.clip_later_release(it.later)
	}
	delete(o.items, x.allocator)
	o^ = {}
}

@(private)
clip_atom :: proc(x: ^X11, s: Selection) -> Atom {
	return x.atoms.clipboard if s == .Clipboard else ATOM_PRIMARY
}

// clipboard_start makes the window that owns selections. Unmapped and
// InputOnly: it is never seen, it only needs to exist and take events.
@(private)
clipboard_start :: proc(x: ^X11) {
	if x.screen == nil do return
	x.clip_window = Window(api.generate_id(x.conn))
	vals := [1]u32{EVENT_MASK_PROPERTY_CHANGE}
	api.create_window(x.conn, 0, x.clip_window, x.screen.root, 0, 0, 1, 1, 0,
		WINDOW_CLASS_INPUT_ONLY, Visual_Id(0), CW_EVENT_MASK, raw_data(vals[:]))
	api.flush(x.conn)
	debugf(x, "selection window %d", u32(x.clip_window))
}

@(private)
clipboard_stop :: proc(x: ^X11) {
	for &o in x.owned do owned_free(x, &o)
	if x.clip_window != WINDOW_NONE {
		api.destroy_window(x.conn, x.clip_window)
		x.clip_window = WINDOW_NONE
	}
}

// ---------------------------------------------------------------- setting

@(private)
clipboard_set :: proc(b: ^platform.Backend, text: string) -> bool {
	one := [1]platform.Clip_Item{{mime = MIME_TEXT, data = transmute([]u8)text}}
	return selection_set(data(b), .Clipboard, one[:])
}

@(private)
primary_set :: proc(b: ^platform.Backend, text: string) -> bool {
	one := [1]platform.Clip_Item{{mime = MIME_TEXT, data = transmute([]u8)text}}
	return selection_set(data(b), .Primary, one[:])
}

// clipboard_set_data offers several forms of the same thing at once — a
// list of files as text/uri-list beside their names as plain text, so
// whatever the other program understands is there.
@(private)
clipboard_set_data :: proc(b: ^platform.Backend, items: []platform.Clip_Item) -> bool {
	return selection_set(data(b), .Clipboard, items)
}

@(private)
selection_set :: proc(x: ^X11, which: Selection, items: []platform.Clip_Item) -> bool {
	if x.clip_window == WINDOW_NONE || len(items) == 0 do return false
	o := &x.owned[which]
	owned_free(x, o)
	o.items = make([]platform.Clip_Item, len(items), x.allocator)
	for it, i in items {
		o.items[i] = {
			mime  = strings.clone(it.mime, x.allocator),
			data  = make([]u8, len(it.data), x.allocator),
			later = it.later, // a form still being made: kept, not dropped
		}
		copy(o.items[i].data, it.data)
		// The selection outlives the call that set it, so the backend holds
		// its own reference, as the Wayland one does.
		if it.later != nil do platform.clip_later_retain(it.later)
	}
	o.live = true
	api.set_selection_owner(x.conn, x.clip_window, clip_atom(x, which), CURRENT_TIME)
	api.flush(x.conn)
	// The server may refuse — another client can win a race — and the only
	// way to know is to ask who owns it now.
	ck := api.get_selection_owner(x.conn, clip_atom(x, which))
	err: ^Generic_Error
	reply := api.get_selection_owner_reply(x.conn, ck, &err)
	free_reply(err)
	if reply == nil do return false
	defer free_reply(reply)
	ok := reply.owner == x.clip_window
	if !ok do debugf(x, "%v: the server gave the selection to window %d instead", which, u32(reply.owner))
	return ok
}

// on_selection_clear: another client took the selection. What this app had
// on it is gone, and holding the bytes would only answer for a selection
// that is no longer ours.
@(private)
on_selection_clear :: proc(x: ^X11, e: ^Selection_Clear_Event) {
	which := Selection.Clipboard if e.selection == x.atoms.clipboard else Selection.Primary
	owned_free(x, &x.owned[which])
	debugf(x, "%v: another client took it", which)
}

// on_selection_request: somebody is pasting what this app copied. The bytes
// go onto *their* window as a property, and the SelectionNotify tells them
// where.
@(private)
on_selection_request :: proc(x: ^X11, e: ^Selection_Request_Event) {
	which := Selection.Clipboard if e.selection == x.atoms.clipboard else Selection.Primary
	o := &x.owned[which]
	// An ancient client sends no property; the convention is to answer into
	// the target atom instead.
	prop := e.property if e.property != ATOM_NONE else e.target
	ok := false

	if o.live {
		if e.target == x.atoms.targets {
			// What this app can convert to, which is what a paster asks
			// first. TARGETS itself is in the list, as ICCCM says.
			list := make([dynamic]Atom, 0, len(o.items) + 4, context.temp_allocator)
			atom_add(&list, x.atoms.targets)
			if _, has_text := owned_text(o); has_text {
				// The three older spellings of "text", which plenty of X
				// programs still ask for and nothing else offers.
				atom_add(&list, x.atoms.utf8_string)
				atom_add(&list, ATOM_STRING)
				atom_add(&list, x.atoms.text)
			}
			for it in o.items do atom_add(&list, selection_atom(x, it.mime))
			api.change_property(x.conn, PROP_MODE_REPLACE, e.requestor, prop, ATOM_ATOM, 32, u32(len(list)), raw_data(list[:]))
			ok = true
		} else if l, waits := owned_later(x, o, e.target); waits {
			// A form still being made (a picture encoding, a file being
			// written): parked and answered from the loop once ready. The
			// requestor waits for the SelectionNotify, so a late answer is fine.
			if selection_wait(x, e, prop, l) do return
			// Nowhere to park it: refuse rather than block the loop here.
		} else if data, found := owned_for(x, o, e.target); found {
			// Too big for one property is not an error, it is INCR
			// (incr.odin): the reply says how much is coming and the data
			// follows a piece at a time.
			if len(data) > chunk_size(x) {
				ok = incr_begin(x, e, prop, data)
			} else {
				api.change_property(x.conn, PROP_MODE_REPLACE, e.requestor, prop, e.target, 8, u32(len(data)), raw_data(data))
				ok = true
			}
		}
	}

	// Refusing is `property = None`, and saying so matters: a paster that
	// hears nothing at all waits for its own timeout instead of trying
	// another target.
	notify := Selection_Notify_Event{
		response_type = SELECTION_NOTIFY,
		time          = e.time,
		requestor     = e.requestor,
		selection      = e.selection,
		target        = e.target,
		property      = prop if ok else ATOM_NONE,
	}
	api.send_event(x.conn, 0, e.requestor, 0, &notify)
	api.flush(x.conn)
}

// ---------------------------------------------------------------- getting

// atom_add puts an atom in the TARGETS list once. A form whose MIME *is*
// one of the older spellings of "text" — `copy_html` offers all five — would
// otherwise be named twice, and an atom the server would not intern must not
// be named at all: a paster asking for None gets nothing and waits out its
// own timeout.
@(private = "file")
atom_add :: proc(list: ^[dynamic]Atom, a: Atom) {
	if a == ATOM_NONE do return
	for have in list^ do if have == a do return
	append(list, a)
}

// owned_for finds the bytes to answer a target with. The text aliases all
// mean the same item, which is why this is a lookup rather than a match.
@(private = "file")
owned_for :: proc(x: ^X11, o: ^Owned, target: Atom) -> ([]u8, bool) {
	if target == x.atoms.utf8_string || target == ATOM_STRING || target == x.atoms.text {
		if t, has := owned_text(o); has do return transmute([]u8)t, true
	}
	for it in o.items {
		if selection_atom(x, it.mime) == target do return it.data, true
	}
	return nil, false
}

// owned_later is the still-being-made form for a target, where the copy
// carried one. A `Clip_Item` has either bytes or a `later`, never both, so
// this is asked before `owned_for` rather than after it.
@(private = "file")
owned_later :: proc(x: ^X11, o: ^Owned, target: Atom) -> (^platform.Clip_Later, bool) {
	for it in o.items {
		if it.later != nil && selection_atom(x, it.mime) == target do return it.later, true
	}
	return nil, false
}

// selection_atom is the atom for a MIME type: on X the type *is* an atom
// whose name is the MIME string. The two the backend already holds are
// answered without a round trip.
@(private = "file")
selection_atom :: proc(x: ^X11, mime: string) -> Atom {
	switch mime {
	case MIME_TEXT:    return x.atoms.text_plain_utf8
	case "UTF8_STRING": return x.atoms.utf8_string
	}
	ck := api.intern_atom(x.conn, 0, u16(len(mime)), cstring(raw_data(mime)))
	err: ^Generic_Error
	reply := api.intern_atom_reply(x.conn, ck, &err)
	free_reply(err)
	if reply == nil do return ATOM_NONE
	defer free_reply(reply)
	return reply.atom
}

// clipboard_types is what the clipboard is offering now, as MIME names.
// Empty when nothing owns it or the owner will not say.
@(private)
clipboard_types :: proc(b: ^platform.Backend, allocator := context.allocator) -> []string {
	x := data(b)
	if x.clip_window == WINDOW_NONE do return nil
	if o := &x.owned[Selection.Clipboard]; o.live {
		// Ours: answered from memory rather than by asking ourselves.
		out := make([]string, len(o.items), allocator)
		for it, i in o.items do out[i] = strings.clone(it.mime, allocator)
		return out
	}
	atoms := convert_atoms(x, x.atoms.clipboard, x.atoms.targets)
	if len(atoms) == 0 do return nil
	out := make([dynamic]string, 0, len(atoms), allocator)
	for a in atoms {
		if a == x.atoms.targets do continue // the question, not an answer
		if n := atom_name(x, a, allocator); n != "" do append(&out, n)
	}
	return out[:]
}

// clipboard_get_data is the clipboard in one particular form.
@(private)
clipboard_get_data :: proc(b: ^platform.Backend, mime: string, allocator := context.allocator) -> ([]u8, bool) {
	x := data(b)
	if x.clip_window == WINDOW_NONE do return nil, false
	if o := &x.owned[Selection.Clipboard]; o.live {
		if d, found := owned_for(x, o, selection_atom(x, mime)); found {
			out := make([]u8, len(d), allocator)
			copy(out, d)
			return out, true
		}
		return nil, false
	}
	target := selection_atom(x, mime)
	if target == ATOM_NONE do return nil, false
	text, ok := convert_and_wait(x, x.atoms.clipboard, target, allocator)
	return transmute([]u8)text, ok
}

@(private)
clipboard_get :: proc(b: ^platform.Backend, allocator := context.allocator) -> (string, bool) {
	return selection_get(data(b), .Clipboard, allocator)
}

@(private)
primary_get :: proc(b: ^platform.Backend, allocator := context.allocator) -> (string, bool) {
	return selection_get(data(b), .Primary, allocator)
}

@(private)
selection_get :: proc(x: ^X11, which: Selection, allocator := context.allocator) -> (string, bool) {
	if x.clip_window == WINDOW_NONE do return "", false
	// Pasting what this app itself copied never goes near the server: X
	// would ask us and we would answer ourselves, through two round trips
	// and a nested pump.
	if o := &x.owned[which]; o.live {
		if t, has := owned_text(o); has do return strings.clone(t, allocator), true
		return "", false
	}
	sel := clip_atom(x, which)
	// Ask for UTF-8 first and fall back to Latin-1 STRING, which is all an
	// older client offers.
	for target in ([2]Atom{x.atoms.utf8_string, ATOM_STRING}) {
		if target == ATOM_NONE do continue
		if text, ok := convert_and_wait(x, sel, target, allocator); ok do return text, true
	}
	return "", false
}

// convert_and_wait asks the owner to convert the selection and pumps until
// the answer lands.
@(private)
convert_and_wait :: proc(x: ^X11, selection, target: Atom, allocator := context.allocator) -> (string, bool) {
	api.delete_property(x.conn, x.clip_window, x.atoms.baldr_selection)
	api.convert_selection(x.conn, x.clip_window, selection, target, x.atoms.baldr_selection, CURRENT_TIME)
	api.flush(x.conn)

	start := time.tick_now()
	for time.duration_milliseconds(time.tick_since(start)) < SELECTION_WAIT_MS {
		ev := api.poll_for_event(x.conn)
		if ev == nil {
			if api.connection_has_error(x.conn) != 0 do return "", false
			time.sleep(time.Millisecond)
			continue
		}
		if ev.response_type & 0x7f == SELECTION_NOTIFY {
			e := (^Selection_Notify_Event)(ev)
			// Only ours: a drop in flight answers onto its own property, and
			// swallowing that would leave the drop waiting out its timeout.
			if e.property != x.atoms.baldr_selection {
				handle(x, ev)
				free_reply(ev)
				continue
			}
			refused := e.property == ATOM_NONE
			free_reply(ev)
			if refused do return "", false
			return read_selection_property(x, x.atoms.baldr_selection, allocator)
		}
		// Anything else is the app's and must not be lost to a paste.
		handle(x, ev)
		free_reply(ev)
	}
	debugf(x, "the selection owner did not answer within %d ms", SELECTION_WAIT_MS)
	return "", false
}

// read_selection_property takes the bytes the owner wrote onto our window.
// `prop` is which property it wrote them onto: a paste and a drop use
// different ones so that the two can be outstanding at the same time.
@(private)
read_selection_property :: proc(x: ^X11, prop: Atom, allocator := context.allocator) -> (string, bool) {
	cookie := api.get_property(x.conn, 0, x.clip_window, prop, Atom(0) /* AnyPropertyType */, 0, 0x1fffffff)
	err: ^Generic_Error
	reply := api.get_property_reply(x.conn, cookie, &err)
	free_reply(err)
	if reply == nil do return "", false

	if reply.type == x.atoms.incr {
		// Too big for one property: the rest arrives a piece at a time
		// (incr.odin). The reply we are holding is only the size.
		free_reply(reply)
		return incr_read(x, allocator)
	}
	defer free_reply(reply)
	n := int(api.get_property_value_length(reply))
	if n <= 0 {
		api.delete_property(x.conn, x.clip_window, x.atoms.baldr_selection)
		return "", false
	}
	src := ([^]u8)(api.get_property_value(reply))
	out := strings.clone(string(src[:n]), allocator)
	// Deleting it is how the owner is told the transfer is finished, and it
	// matters for INCR; doing it always keeps the window tidy either way.
	api.delete_property(x.conn, x.clip_window, x.atoms.baldr_selection)
	return out, true
}

// convert_atoms asks for a selection in a form that is a list of atoms —
// TARGETS, and nothing else in practice. Temp-allocated.
@(private = "file")
convert_atoms :: proc(x: ^X11, selection, target: Atom) -> []Atom {
	api.delete_property(x.conn, x.clip_window, x.atoms.baldr_selection)
	api.convert_selection(x.conn, x.clip_window, selection, target, x.atoms.baldr_selection, CURRENT_TIME)
	api.flush(x.conn)
	start := time.tick_now()
	for time.duration_milliseconds(time.tick_since(start)) < SELECTION_WAIT_MS {
		ev := api.poll_for_event(x.conn)
		if ev == nil {
			if api.connection_has_error(x.conn) != 0 do return nil
			time.sleep(time.Millisecond)
			continue
		}
		if ev.response_type & 0x7f == SELECTION_NOTIFY {
			e := (^Selection_Notify_Event)(ev)
			refused := e.property == ATOM_NONE
			free_reply(ev)
			if refused do return nil
			return prop_atoms(x, x.clip_window, x.atoms.baldr_selection)
		}
		handle(x, ev) // a paste must not swallow the app's own events
		free_reply(ev)
	}
	return nil
}
