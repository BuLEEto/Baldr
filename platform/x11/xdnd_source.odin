#+build linux
package x11

// XDND, the source half: dragging *out* of a Baldr window.
//
// Three jobs the target half (xdnd.odin) does not have:
//
//   - Hold the pointer: only a grab delivers moves over other programs'
//     windows.
//   - Find who is under it: walk the pointer's window down from the root,
//     then back up to the one with XdndAware, since under a reparenting
//     manager the deepest window is a frame, not the client.
//   - Answer for the data: offered through the XdndSelection selection, so
//     a target's ask is an ordinary SelectionRequest, INCR when big.
//
// Until the drop the app hears nothing; Ev_Drag_End ends it.

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:thread"
import "baldr:platform"

@(private = "file") XDND_VERSION :: 5

// Drag_Out is this app's drag while it is in flight.
@(private)
Drag_Out :: struct {
	live:     bool,
	source:   Window,  // our window, which every message names
	target:   Window,  // whose window the pointer is over, or none
	version:  u32,     // the target's XDND version, for what it understands
	accepted: bool,    // what the target last said in XdndStatus
	dropped:  bool,    // XdndDrop sent; waiting for XdndFinished
	items:    []platform.Clip_Item, // owned copy: the app's may not outlive the drag
	types:    [dynamic]Atom,
}

// Selection_Wait is a requested form whose bytes do not exist yet (files
// still being made, baldr's Files_Later). The loop thread must not block,
// so a thread of ours waits, then wakes the loop, which writes the
// property as it writes every other reply.
//
// The thread holds a duplicate of the wake eventfd, not the backend: if
// the backend goes first, the write reaches nobody rather than freed
// memory.
@(private)
Selection_Wait :: struct {
	later: ^platform.Clip_Later, // retained while this lasts
	fd:    linux.Fd,             // the thread's duplicate of the wake eventfd
	done:  int,                  // atomic: the wait has come back
	refs:  int,                  // atomic: the loop's reference and the thread's
	req:   Selection_Request_Event, // the ask to answer, copied whole
	prop:  Atom,
}

// drag_start hands a drag to the desktop (Backend.drag_start).
//
// `icon` is ignored: XDND carries no picture, and a source wanting one
// must move an override-redirect window with the pointer itself, which is
// not done here. A drag out of an X11 window shows the cursor alone.
@(private)
drag_start :: proc(b: ^platform.Backend, id: platform.Surface, items: []platform.Clip_Item, serial: u32, icon: platform.Drag_Icon) -> bool {
	x := data(b)
	s := get_surface(x, id)
	if s == nil || len(items) == 0 || x.drag.live do return false

	// The pointer has to come to us even over other windows, or the drag
	// stops at our own edge.
	ck := api.grab_pointer(x.conn, 0, s.window,
		EVENT_MASK_POINTER_MOTION | EVENT_MASK_BUTTON_RELEASE,
		GRAB_MODE_ASYNC, GRAB_MODE_ASYNC, WINDOW_NONE, Cursor_Id(0), CURRENT_TIME)
	err: ^Generic_Error
	reply := api.grab_pointer_reply(x.conn, ck, &err)
	free_reply(err)
	grabbed := reply != nil && reply.status == 0
	free_reply(reply)
	if !grabbed {
		debugf(x, "drag: the pointer could not be grabbed; somebody else has it")
		return false
	}

	x.drag = Drag_Out{live = true, source = s.window}
	x.drag.items = make([]platform.Clip_Item, len(items), x.allocator)
	for it, i in items {
		x.drag.items[i] = {
			mime = strings.clone(it.mime, x.allocator),
			data = make([]u8, len(it.data), x.allocator),
			later = it.later, // a form still being made: shared, by reference
		}
		copy(x.drag.items[i].data, it.data)
		if it.later != nil do platform.clip_later_retain(it.later)
		append(&x.drag.types, intern(x, it.mime))
	}

	// The data travels through this selection, so it must be ours before
	// any target asks.
	api.set_selection_owner(x.conn, s.window, x.atoms.xdnd_selection, CURRENT_TIME)
	// More than three types will not fit in XdndEnter, so they go in a
	// property the target reads instead.
	if len(x.drag.types) > 3 {
		api.change_property(x.conn, PROP_MODE_REPLACE, s.window, x.atoms.xdnd_type_list,
			ATOM_ATOM, 32, u32(len(x.drag.types)), raw_data(x.drag.types[:]))
	}
	api.flush(x.conn)
	debugf(x, "drag: started with %d type(s): %v", len(items), x.drag.types[:])
	return true
}

// drag_out_motion follows the pointer while a drag of ours is in flight.
@(private)
drag_out_motion :: proc(x: ^X11, root_x, root_y: i16) {
	if !x.drag.live || x.drag.dropped do return
	under := xdnd_target_at(x, root_x, root_y)
	if under != x.drag.target {
		if x.drag.target != WINDOW_NONE do drag_send(x, x.drag.target, x.atoms.xdnd_leave, {u32(x.drag.source), 0, 0, 0, 0})
		x.drag.target = under
		x.drag.accepted = false
		if under != WINDOW_NONE {
			x.drag.version = xdnd_version_of(x, under)
			t := x.drag.types
			d: [5]u32
			d[0] = u32(x.drag.source)
			d[1] = (min(x.drag.version, XDND_VERSION) << 24) | (1 if len(t) > 3 else 0)
			for i in 0 ..< min(len(t), 3) do d[2 + i] = u32(t[i])
			drag_send(x, under, x.atoms.xdnd_enter, d)
			debugf(x, "drag: over window %d (XDND v%d)", u32(under), x.drag.version)
		}
	}
	if x.drag.target == WINDOW_NONE do return
	drag_send(x, x.drag.target, x.atoms.xdnd_position,
		{u32(x.drag.source), 0, (u32(u16(root_x)) << 16) | u32(u16(root_y)), 0, u32(x.atoms.xdnd_action_copy)})
}

// drag_out_release is the button coming up: a drop where the target said it
// would take one, and nothing anywhere else.
@(private)
drag_out_release :: proc(x: ^X11) {
	if !x.drag.live || x.drag.dropped do return
	api.ungrab_pointer(x.conn, CURRENT_TIME)
	if x.drag.target != WINDOW_NONE && x.drag.accepted {
		x.drag.dropped = true
		drag_send(x, x.drag.target, x.atoms.xdnd_drop, {u32(x.drag.source), 0, u32(CURRENT_TIME), 0, 0})
		debugf(x, "drag: dropped on window %d", u32(x.drag.target))
		return // Ev_Drag_End waits for XdndFinished
	}
	if x.drag.target != WINDOW_NONE {
		drag_send(x, x.drag.target, x.atoms.xdnd_leave, {u32(x.drag.source), 0, 0, 0, 0})
	}
	debugf(x, "drag: let go over nothing that would take it")
	push(x, platform.Ev_Drag_End{dropped = false})
	drag_out_clear(x)
}

// drag_out_message handles what a target sends back. True when it was ours.
@(private)
drag_out_message :: proc(x: ^X11, e: ^Client_Message_Event) -> bool {
	if !x.drag.live do return false
	switch e.type {
	case x.atoms.xdnd_status:
		x.drag.accepted = e.data.data32[1] & 1 != 0
		return true
	case x.atoms.xdnd_finished:
		// Only now may the data go: until XdndFinished the target may still
		// be asking for it.
		debugf(x, "drag: the target finished (accepted %v)", e.data.data32[1] & 1 != 0)
		push(x, platform.Ev_Drag_End{dropped = e.data.data32[1] & 1 != 0, action = .Copy})
		drag_out_clear(x)
		return true
	}
	return false
}

// drag_out_request answers a target asking for the data, which arrives as
// an ordinary SelectionRequest on XdndSelection.
@(private)
drag_out_request :: proc(x: ^X11, e: ^Selection_Request_Event) -> bool {
	if !x.drag.live || e.selection != x.atoms.xdnd_selection do return false
	prop := e.property if e.property != ATOM_NONE else e.target
	ok := false
	if e.target == x.atoms.targets {
		api.change_property(x.conn, PROP_MODE_REPLACE, e.requestor, prop, ATOM_ATOM, 32,
			u32(len(x.drag.types)), raw_data(x.drag.types[:]))
		ok = true
	} else {
		for t, i in x.drag.types {
			if t != e.target do continue
			// A form still being made: parked and answered from the loop
			// once ready. The requestor waits for the SelectionNotify.
			if l := x.drag.items[i].later; l != nil {
				if selection_wait(x, e, prop, l) do return true
				break // nowhere to wait: refused, rather than stopping the window to wait here
			}
			d := x.drag.items[i].data
			if len(d) > chunk_size(x) {
				ok = incr_begin(x, e, prop, d)
			} else {
				api.change_property(x.conn, PROP_MODE_REPLACE, e.requestor, prop, e.target, 8, u32(len(d)), raw_data(d))
				ok = true
			}
			break
		}
	}
	drag_out_notify(x, e, prop, ok)
	return true
}

// drag_out_notify tells the requestor where its answer is, or that there
// is none (ATOM_NONE, which a target reads as a drop that brought nothing).
@(private = "file")
drag_out_notify :: proc(x: ^X11, e: ^Selection_Request_Event, prop: Atom, ok: bool) {
	notify := Selection_Notify_Event{
		response_type = SELECTION_NOTIFY, time = e.time, requestor = e.requestor,
		selection = e.selection, target = e.target, property = prop if ok else ATOM_NONE,
	}
	api.send_event(x.conn, 0, e.requestor, 0, &notify)
	api.flush(x.conn)
}

// selection_wait parks `e` and starts the thread that waits for `later`.
// False when it cannot (no eventfd, no thread, or one already parked); the
// caller then refuses.
@(private)
selection_wait :: proc(x: ^X11, e: ^Selection_Request_Event, prop: Atom, later: ^platform.Clip_Later) -> bool {
	if x.drag_waiting != nil || x.wake_fd == 0 do return false
	fd, err := linux.dup(x.wake_fd)
	if err != .NONE do return false
	w := new(Selection_Wait, runtime.heap_allocator())
	w.later, w.fd, w.refs = later, fd, 2
	w.req, w.prop = e^, prop
	platform.clip_later_retain(later)
	if thread.create_and_start_with_data(w, selection_wait_thread, self_cleanup = true) == nil {
		linux.close(fd)
		platform.clip_later_release(later)
		free(w, runtime.heap_allocator())
		return false
	}
	x.drag_waiting = w
	debugf(x, "selection: window %d asked for a form still being made; it waits", u32(e.requestor))
	return true
}

@(private = "file")
selection_wait_thread :: proc(p: rawptr) {
	w := (^Selection_Wait)(p)
	w.later.wait(w.later) // comes back: whoever makes the bytes gives up in the end
	sync.atomic_store(&w.done, 1)
	one := u64(1)
	_, _ = linux.write(w.fd, ([^]u8)(&one)[:8]) // the loop, which writes the property
	linux.close(w.fd)
	selection_wait_release(w)
}

// selection_wait_stop drops the loop's reference to a parked request: the
// backend is going, so nobody is left to answer it. The waiting thread
// holds its own reference and frees what is left when it comes back.
@(private)
selection_wait_stop :: proc(x: ^X11) {
	if w := x.drag_waiting; w != nil {
		x.drag_waiting = nil
		selection_wait_release(w)
	}
}

@(private = "file")
selection_wait_release :: proc(w: ^Selection_Wait) {
	if sync.atomic_sub(&w.refs, 1) != 1 do return
	platform.clip_later_release(w.later)
	free(w, runtime.heap_allocator())
}

// selection_wait_serve answers a parked request whose form has been made (or
// given up on). Called by the pump, which the waiting thread woke; nothing to
// do on any other pass.
//
// A drag's XdndSelection and the clipboard both park here. There is one
// slot: a second request while one waits is refused, not queued.
@(private)
selection_wait_serve :: proc(x: ^X11) {
	w := x.drag_waiting
	if w == nil || sync.atomic_load(&w.done) == 0 do return
	x.drag_waiting = nil
	defer selection_wait_release(w)
	// Answered even if the drag has ended: the selection's owner answers,
	// and a target that already finished just ignores it.
	d := w.later.wait(w.later) // back at once: the thread has already waited
	// An empty property, not a refusal, when the source gave up: a drop that
	// brought nothing, as an empty pipe says on Wayland.
	ok := true
	if len(d) > chunk_size(x) {
		ok = incr_begin(x, &w.req, w.prop, d)
	} else {
		api.change_property(x.conn, PROP_MODE_REPLACE, w.req.requestor, w.prop, w.req.target, 8, u32(len(d)), raw_data(d))
	}
	drag_out_notify(x, &w.req, w.prop, ok)
	debugf(x, "selection: the form it waited for went out, %d bytes", len(d))
}

@(private)
drag_out_clear :: proc(x: ^X11) {
	// A parked request is not the drag's: it outlives one deliberately
	// (selection_wait_serve), and selection_wait_stop is what ends it.
	for it in x.drag.items {
		delete(it.mime, x.allocator)
		delete(it.data, x.allocator)
		if it.later != nil do platform.clip_later_release(it.later)
	}
	delete(x.drag.items, x.allocator)
	delete(x.drag.types)
	x.drag = {}
}

@(private = "file")
drag_send :: proc(x: ^X11, to: Window, type: Atom, d: [5]u32) {
	if type == ATOM_NONE do return
	ev := Client_Message_Event{response_type = CLIENT_MESSAGE, format = 32, window = to, type = type}
	ev.data.data32 = d
	api.send_event(x.conn, 0, to, 0, &ev)
	api.flush(x.conn)
}

// xdnd_target_at finds the window under the pointer that takes drops.
//
// The deepest child under the pointer may be a frame or an inner window;
// XdndAware is on the client's toplevel. So the chain is walked down from
// the root, then searched from the deepest outwards.
@(private = "file")
xdnd_target_at :: proc(x: ^X11, root_x, root_y: i16) -> Window {
	if x.screen == nil do return WINDOW_NONE
	chain: [16]Window
	n := 0
	w := x.screen.root
	for n < len(chain) {
		ck := api.query_pointer(x.conn, w)
		err: ^Generic_Error
		reply := api.query_pointer_reply(x.conn, ck, &err)
		free_reply(err)
		if reply == nil do break
		child := reply.child
		free_reply(reply)
		if child == WINDOW_NONE do break
		chain[n] = child
		n += 1
		w = child
	}
	for i := n - 1; i >= 0; i -= 1 {
		if xdnd_version_of(x, chain[i]) > 0 do return chain[i]
	}
	return WINDOW_NONE
}

// xdnd_version_of reads XdndAware, which is both "takes drops" and "speaks
// this version of the protocol". 0 means neither.
@(private = "file")
xdnd_version_of :: proc(x: ^X11, w: Window) -> u32 {
	if x.atoms.xdnd_aware == ATOM_NONE do return 0
	ck := api.get_property(x.conn, 0, w, x.atoms.xdnd_aware, ATOM_ATOM, 0, 1)
	err: ^Generic_Error
	reply := api.get_property_reply(x.conn, ck, &err)
	free_reply(err)
	if reply == nil do return 0
	defer free_reply(reply)
	if reply.type != ATOM_ATOM || reply.value_len < 1 do return 0
	return ([^]u32)(api.get_property_value(reply))[0]
}

// intern asks the server for an atom by name, which is what a MIME type is
// on X (and what _GTK_THEME_VARIANT is, x11.odin).
@(private)
intern :: proc(x: ^X11, name: string) -> Atom {
	ck := api.intern_atom(x.conn, 0, u16(len(name)), cstring(raw_data(name)))
	err: ^Generic_Error
	reply := api.intern_atom_reply(x.conn, ck, &err)
	free_reply(err)
	if reply == nil do return ATOM_NONE
	defer free_reply(reply)
	return reply.atom
}
