package baldr

// Telling the desktop about changes away from the keyboard: a progress bar
// filling, a row arriving in a list, a status line rewriting itself while
// someone is looking somewhere else. The focused object is watched in
// a11y_events.odin; this is the rest.
//
// Only objects the reader has asked about are reported on: anything it
// never asked about it cannot be holding, so a change there is not news.
// The work is proportional to what is being read, not to the tree; a list
// of ten thousand rows costs nothing until someone reads it.
//
// `A11Y_SWEEP` objects are looked at per wake-up, in turn, so no frame pays
// for a large set. Focus, the caret and the focused object's contents stay
// immediate; everything else may be a frame or two late.

import "core:strings"

// A11Y_SWEEP is how many known objects are looked at per wake-up, and
// A11Y_KNOWN_MAX how many are remembered at all. Past that a reader still
// gets every answer it asks for, but no change events for objects beyond
// the limit: the map stays bounded.
@(private) A11Y_SWEEP     :: 128
@(private) A11Y_KNOWN_MAX :: 4096

// A11y_Seen is an object as the desktop last heard it.
@(private)
A11y_Seen :: struct {
	name:      string, // owned
	describe:  string, // owned
	flags:     A11y_Flags,
	value:     f64,
	has_value: bool,
	kids:      [dynamic]u64, // its children, to say which arrived or left
}

@(private)
a11y_seen_free :: proc(s: ^A11y_Seen) {
	delete(s.name)
	delete(s.describe)
	delete(s.kids)
	s^ = {}
}

// a11y_forget drops everything we were remembering (the bridge stopping, or
// an app closing its last window).
@(private)
a11y_forget :: proc() {
	for _, &seen in a11y.known do a11y_seen_free(&seen)
	delete(a11y.known)
	delete(a11y.order)
	a11y_live_forget()
	delete(a11y.live_said)
	a11y.live_said = nil
	a11y.known = nil
	a11y.order = nil
	a11y.cursor = 0
}

// a11y_seen_record notes an object the reader just asked about, so that a
// change to it later is worth an event. Called when we answer a question
// from the desktop — never from our own sweep, which would remember objects
// nobody asked for.
@(private)
a11y_seen_record :: proc(id: u64, t: ^Tree, n: Node, out: A11y_Obj) {
	if a11y.sweeping || id == A11Y_APP_ID do return
	if id in a11y.known do return
	if len(a11y.known) >= A11Y_KNOWN_MAX do return
	if a11y.known == nil {
		a11y.known = make(map[u64]A11y_Seen)
		a11y.order = make([dynamic]u64)
	}
	seen := A11y_Seen{
		name      = strings.clone(out.name),
		describe  = strings.clone(out.describe),
		flags     = out.flags,
		has_value = out.has_value,
		value     = out.value,
		kids      = make([dynamic]u64),
	}
	a11y_kid_ids(t, n, id, &seen.kids)
	a11y.known[id] = seen
	append(&a11y.order, id)
}

// a11y_kid_ids collects an object's children as ids, in order.
@(private)
a11y_kid_ids :: proc(t: ^Tree, n: Node, id: u64, out: ^[dynamic]u64) {
	window, _, ok := a11y_unpack(id)
	if !ok do return
	kids := make([dynamic]Node, context.temp_allocator)
	if n == NODE_NONE { a11y_roots(t, &kids) } else { a11y_kids(t, n, &kids) }
	for k in kids do if kid, named := a11y_id(window, k); named do append(out, kid)
}

// a11y_sweep looks at a slice of the known objects and says what changed.
@(private)
a11y_sweep :: proc() {
	// (nothing listening is not a reason to skip the bookkeeping: an object
	// that has gone is dropped either way, and the events cost nothing when
	// there is nothing to send them to)
	if len(a11y.order) == 0 do return
	a11y.sweeping = true
	defer a11y.sweeping = false
	looked := 0
	for looked < A11Y_SWEEP && len(a11y.order) > 0 {
		if a11y.cursor >= len(a11y.order) do a11y.cursor = 0
		id := a11y.order[a11y.cursor]
		seen, known := &a11y.known[id]
		if !known { // dropped from under us
			unordered_remove(&a11y.order, a11y.cursor)
			continue
		}
		looked += 1
		if id == a11y.watch.id { // the focused object is reported as it happens
			a11y.cursor += 1
			continue
		}
		window, n, unpacked := a11y_unpack(id)
		t := a11y.windows[window].tree if unpacked else nil
		d := node_get(t, n) if t != nil && n != NODE_NONE else nil
		gone := !unpacked || t == nil || (n != NODE_NONE && (d == nil || !a11y_reachable(t, n)))
		if gone {
			a11y_say(Said_Flag{id = id, flag = .Defunct, on = true}) // it has been taken away under them
			a11y_seen_free(seen)
			delete_key(&a11y.known, id)
			unordered_remove(&a11y.order, a11y.cursor)
			continue
		}
		a11y_seen_diff(id, t, n, d, seen)
		a11y.cursor += 1
	}
}

// a11y_seen_diff says what changed about one object since it was last
// looked at, and remembers the new picture.
@(private)
a11y_seen_diff :: proc(id: u64, t: ^Tree, n: Node, d: ^Node_Data, seen: ^A11y_Seen) {
	name, describe: string
	flags: A11y_Flags
	has_value: bool
	value: f64
	if n == NODE_NONE { // the window itself
		w := a11y.windows[a11y_window_index(id)]
		name = w.title
		flags = {.Enabled, .Sensitive, .Showing, .Visible, .Resizable}
		if w.active do flags += {.Active}
	} else {
		name, describe = d.access.name, d.access.describe
		flags = a11y_flags(t, n, d)
		has_value, value = d.access.has_value, f64(d.access.value)
	}

	if name != seen.name {
		a11y_say(Said_Name{id = id, name = name})
		delete(seen.name)
		seen.name = strings.clone(name)
	}
	if describe != seen.describe {
		a11y_say(Said_Describe{id = id, describe = describe})
		delete(seen.describe)
		seen.describe = strings.clone(describe)
	}
	if flags != seen.flags {
		for f in A11y_Flag do if f in FLAGS_WATCHED && (f in flags) != (f in seen.flags) {
			a11y_say(Said_Flag{id = id, flag = f, on = f in flags})
		}
		seen.flags = flags
	}
	if has_value && (!seen.has_value || value != seen.value) {
		a11y_say(Said_Value{id = id, value = value})
		seen.has_value, seen.value = true, value
	}

	kids := make([dynamic]u64, context.temp_allocator)
	a11y_kid_ids(t, n, id, &kids)
	if !a11y_same_kids(kids[:], seen.kids[:]) {
		a11y_kids_changed(id, kids[:], seen.kids[:])
		clear(&seen.kids)
		append(&seen.kids, ..kids[:])
	}
}

@(private)
a11y_same_kids :: proc(now, was: []u64) -> bool {
	if len(now) != len(was) do return false
	for k, i in now do if k != was[i] do return false
	return true
}

// a11y_kids_changed says which children arrived and which left. A reader
// takes each event as "a child appeared at this index" or "the child at
// this index went", which is what it needs to keep its own picture.
@(private)
a11y_kids_changed :: proc(id: u64, now, was: []u64) {
	for old, i in was {
		found := false
		for k in now do if k == old { found = true; break }
		if !found do a11y_say(Said_Children{id = id, added = false, index = i, child = old})
	}
	for k, i in now {
		found := false
		for old in was do if old == k { found = true; break }
		if !found do a11y_say(Said_Children{id = id, added = true, index = i, child = k})
	}
}

// a11y_window_index is which window an id belongs to (0 when it does not
// name one, which the callers have already ruled out).
@(private)
a11y_window_index :: proc(id: u64) -> int {
	w, _, ok := a11y_unpack(id)
	return w if ok else 0
}
