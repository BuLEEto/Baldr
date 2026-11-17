package wayland

// The clipboard and drags across apps, through wl_data_device: one data
// device per seat announces every selection and every drag as a
// wl_data_offer (its mime types arrive first), and what we offer — a copy
// or an outgoing drag — is a wl_data_source the compositor asks to `send`
// into a pipe when another client takes it.

import "base:runtime"
import "core:strings"
import "core:sys/linux"
import "core:thread"
import "core:time"
import "baldr:platform"
import wl "baldr:platform/wayland/wl"

// Data_Offer is a selection (or drag) another client announced; the
// listener lives here so its address stays stable for the offer's life.
@(private)
Data_Offer :: struct {
	st:    ^State,
	proxy: wl.Proxy,
	l:     wl.Wl_Data_Offer_Listener,
	mimes: [dynamic]string,
	source_actions: wl.Wl_Data_Device_Manager_Dnd_Action, // a drag: what the source allows
	action:         wl.Wl_Data_Device_Manager_Dnd_Action, // …and what the compositor chose
}

// Text mime types in the order we ask for them and offer them.
@(private)
TEXT_MIMES := [?]cstring{"text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "TEXT", "STRING"}

// The pipe read on paste gives up after this long without data: a source
// that never writes must not hang the app.
@(private)
CLIPBOARD_READ_TIMEOUT_MS :: i32(2000)

// clipboard_init creates the seat's data device once both globals are
// bound (init calls it between the two registry roundtrips, so the initial
// selection arrives with the seat's other first events).
@(private)
clipboard_init :: proc(st: ^State) {
	if st.data_mgr == nil || st.seat == nil || st.data_device != nil do return
	st.data_device = wl.wl_data_device_manager_get_data_device(st.data_mgr, st.seat)
	st.data_device_l = wl.wl_data_device_listener_noop()
	st.data_device_l.data_offer = on_data_offer
	st.data_device_l.selection = on_data_selection
	st.data_device_l.enter = on_data_enter
	st.data_device_l.leave = on_data_leave
	st.data_device_l.motion = on_data_motion
	st.data_device_l.drop = on_data_drop
	wl.wl_data_device_add_listener(st.data_device, &st.data_device_l, st)
}

@(private)
clipboard_teardown :: proc(st: ^State) {
	source_drop(st)
	drag_source_drop(st)
	dnd_read_stop(st)
	delete(st.dnd_read)
	offer_destroy(st.selection)
	st.selection = nil
	offer_destroy(st.dnd_offer)
	st.dnd_offer = nil
	for o in st.offers do offer_destroy(o)
	delete(st.offers)
	st.offers = nil
	if st.data_device != nil {
		wl.wl_data_device_release(st.data_device)
		st.data_device = nil
	}
	if st.data_mgr != nil {
		wl.proxy_destroy(st.data_mgr)
		st.data_mgr = nil
	}
}

@(private)
offer_destroy :: proc(o: ^Data_Offer) {
	if o == nil do return
	if o.proxy != nil do wl.wl_data_offer_destroy(o.proxy)
	for m in o.mimes do delete(m)
	delete(o.mimes)
	free(o)
}

// offer_take finds the announced offer for `id` and removes it from the
// waiting list (nil when the compositor never introduced it).
@(private)
offer_take :: proc(st: ^State, id: wl.Proxy) -> ^Data_Offer {
	if id == nil do return nil
	for o, i in st.offers {
		if o.proxy != id do continue
		unordered_remove(&st.offers, i)
		return o
	}
	return nil
}

// on_data_offer: a new offer, mime types follow on the offer itself before
// the selection / enter that says what it is for.
@(private)
on_data_offer :: proc "c" (data: rawptr, p: wl.Proxy, id: wl.Proxy) {
	st := (^State)(data)
	context = st.ctx
	o := new(Data_Offer)
	o.st = st
	o.proxy = id
	o.l = wl.wl_data_offer_listener_noop()
	o.l.offer = on_offer_mime
	o.l.source_actions = on_offer_source_actions
	o.l.action = on_offer_action
	wl.wl_data_offer_add_listener(id, &o.l, o)
	append(&st.offers, o)
}

@(private)
on_offer_source_actions :: proc "c" (data: rawptr, p: wl.Proxy, source_actions: wl.Wl_Data_Device_Manager_Dnd_Action) {
	(^Data_Offer)(data).source_actions = source_actions
}

@(private)
on_offer_action :: proc "c" (data: rawptr, p: wl.Proxy, dnd_action: wl.Wl_Data_Device_Manager_Dnd_Action) {
	(^Data_Offer)(data).action = dnd_action
}

@(private)
on_offer_mime :: proc "c" (data: rawptr, p: wl.Proxy, mime_type: cstring) {
	o := (^Data_Offer)(data)
	context = o.st.ctx
	append(&o.mimes, strings.clone(string(mime_type)))
}

@(private)
on_data_selection :: proc "c" (data: rawptr, p: wl.Proxy, id: wl.Proxy) {
	st := (^State)(data)
	context = st.ctx
	offer_destroy(st.selection)
	st.selection = offer_take(st, id)
	if st.debug {
		if st.selection == nil {
			debugf(st, "clipboard: selection cleared")
		} else {
			debugf(st, "clipboard: selection offered as %v", st.selection.mimes[:])
		}
	}
}

// -------------------------------------------------------- drags over us

// The forms a drop can take, best first.
@(private)
DRAG_MIMES := [?]cstring{"text/uri-list", "text/plain;charset=utf-8", "text/plain"}

@(private)
dnd_offer_free :: proc(st: ^State) {
	offer_destroy(st.dnd_offer)
	st.dnd_offer = nil
	st.dnd_surface = nil
	st.dnd_dropped = false
}

// on_data_enter: a drag came over one of our surfaces. Accept the best
// form we can take right away (the toolkit refines it per target with
// drag_accept) and ask for a copy.
@(private)
on_data_enter :: proc "c" (data: rawptr, p: wl.Proxy, serial: u32, surface: wl.Proxy, x, y: wl.Fixed, id: wl.Proxy) {
	st := (^State)(data)
	context = st.ctx
	dnd_offer_free(st)
	o := offer_take(st, id)
	s := lookup_wl(st, surface)
	if o == nil || s == nil {
		offer_destroy(o)
		return
	}
	st.dnd_offer = o
	st.dnd_serial = serial
	st.dnd_surface = s
	st.dnd_pos = {wl.fixed_to_f32(x), wl.fixed_to_f32(y)}
	if wl.proxy_version(o.proxy) >= 3 {
		all := wl.WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY | wl.WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE | wl.WL_DATA_DEVICE_MANAGER_DND_ACTION_ASK
		wl.wl_data_offer_set_actions(o.proxy, all, wl.WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY)
	}
	wl.wl_data_offer_accept(o.proxy, serial, dnd_best_mime(o))
	debugf(st, "drag: entered surface %d at %v offering %v", s.id, st.dnd_pos, o.mimes[:])
	mimes := make([]string, len(o.mimes), text_allocator(st))
	for m, i in o.mimes do mimes[i] = strings.clone(m, text_allocator(st))
	push(st, platform.Ev_Drag_Enter{surface = s.id, pos = st.dnd_pos, mimes = mimes, own = st.drag_source != nil}) // a seat carries one drag at a time
}

@(private)
dnd_best_mime :: proc(o: ^Data_Offer) -> cstring {
	for want in DRAG_MIMES do for have in o.mimes do if have == string(want) do return want
	return nil
}

@(private)
on_data_motion :: proc "c" (data: rawptr, p: wl.Proxy, time: u32, x, y: wl.Fixed) {
	st := (^State)(data)
	context = st.ctx
	if st.dnd_offer == nil || st.dnd_surface == nil do return
	st.dnd_pos = {wl.fixed_to_f32(x), wl.fixed_to_f32(y)}
	push(st, platform.Ev_Drag_Motion{surface = st.dnd_surface.id, pos = st.dnd_pos})
}

@(private)
on_data_leave :: proc "c" (data: rawptr, p: wl.Proxy) {
	st := (^State)(data)
	context = st.ctx
	if st.dnd_offer == nil do return
	if st.dnd_dropped do return // the leave after a drop: the offer lives until drag_finish
	debugf(st, "drag: left")
	if st.dnd_surface != nil do push(st, platform.Ev_Drag_Leave{surface = st.dnd_surface.id})
	dnd_offer_free(st)
}

@(private)
on_data_drop :: proc "c" (data: rawptr, p: wl.Proxy) {
	st := (^State)(data)
	context = st.ctx
	if st.dnd_offer == nil || st.dnd_surface == nil do return
	st.dnd_dropped = true
	debugf(st, "drag: dropped at %v", st.dnd_pos)
	mods := st.mods if st.kbd_focus != nil else platform.Mods{} // our keyboard's modifiers are current only while we have it
	push(st, platform.Ev_Drag_Drop{surface = st.dnd_surface.id, pos = st.dnd_pos, action = dnd_action_of(st, st.dnd_offer), mods = mods})
}

// dnd_action_of is what the user asked a drop from another client to do:
// the modifiers when our window has the keyboard, else the action the
// compositor chose. Copy is our preferred action, so a chosen copy is only
// the user's word when the source cannot move at all.
@(private)
dnd_action_of :: proc(st: ^State, o: ^Data_Offer) -> platform.Drag_Action {
	if st.kbd_focus != nil {
		if .Alt in st.mods || (.Ctrl in st.mods && .Shift in st.mods) do return .Ask
		if .Ctrl in st.mods do return .Copy
		if .Shift in st.mods do return .Move
	}
	if o == nil || wl.proxy_version(o.proxy) < 3 do return .Default
	switch o.action {
	case wl.WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE: return .Move
	case wl.WL_DATA_DEVICE_MANAGER_DND_ACTION_ASK:  return .Ask
	case wl.WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY:
		return .Copy if o.source_actions & wl.WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE == wl.WL_DATA_DEVICE_MANAGER_DND_ACTION_NONE else .Default
	}
	return .Default
}

// drag_action_from_wl maps what a target chose for our drag.
@(private)
drag_action_from_wl :: proc "contextless" (a: wl.Wl_Data_Device_Manager_Dnd_Action) -> platform.Drag_Action {
	switch a {
	case wl.WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY: return .Copy
	case wl.WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE: return .Move
	case wl.WL_DATA_DEVICE_MANAGER_DND_ACTION_ASK:  return .Ask
	}
	return .Default
}

// drag_accept: the toolkit says whether the target under the drag would
// take it; the source's cursor follows.
@(private)
drag_accept :: proc(b: ^platform.Backend, accept: bool) {
	st := state(b)
	o := st.dnd_offer
	if o == nil || st.dnd_dropped do return
	wl.wl_data_offer_accept(o.proxy, st.dnd_serial, dnd_best_mime(o) if accept else nil)
	wl.display_flush(st.display)
}

// drag_receive asks for the dropped data in one form; it comes as
// Ev_Drag_Data. Our own drag's is answered from memory at once (asking the
// compositor would wait on our own event loop, so nothing would come);
// another client's pipe is read between events, so a slow source never
// stalls the app or lets the compositor's buffer for us fill.
@(private)
drag_receive :: proc(b: ^platform.Backend, mime: string) -> bool {
	st := state(b)
	o := st.dnd_offer
	if o == nil do return false
	dnd_read_stop(st)
	if st.drag_source != nil { // a seat carries one drag at a time: this one is ours
		// A form still being made has no bytes here, and waiting would wait on
		// our own loop. It need not: a drag of ours back over our own window is
		// taken in-process and never asks the compositor.
		it, have := item_find(st.drag_items, mime)
		if !have do return false
		append(&st.dnd_read, ..it.data)
		push(st, platform.Ev_Drag_Data{data = st.dnd_read[:], ok = true})
		return true
	}
	offered := false
	for have in o.mimes do if have == mime { offered = true; break }
	if !offered do return false
	fds: [2]linux.Fd
	if linux.pipe2(&fds, {.CLOEXEC}) != .NONE do return false
	if flags, ferr := linux.fcntl_getfl(fds[0], linux.F_GETFL); ferr == .NONE { // our end only: the source's stays as it expects
		linux.fcntl_setfl(fds[0], linux.F_SETFL, flags + {.NONBLOCK})
	}
	wl.wl_data_offer_receive(o.proxy, strings.clone_to_cstring(mime, context.temp_allocator), i32(fds[1])) // libwayland dups the fd on marshal
	linux.close(fds[1])
	wl.display_flush(st.display)
	st.dnd_read_fd, st.dnd_reading = fds[0], true
	// A drop's source is given longer than a paste's: it may be making the
	// files its paths name while we read (platform.DROP_WAIT_MS). The read is
	// between events, so the wait does not block the app.
	st.dnd_read_deadline = time.tick_add(time.tick_now(), platform.DROP_WAIT_MS * time.Millisecond)
	debugf(st, "drag: reading the drop's %s", mime)
	return true
}

// dnd_read_more takes what a drop's source has written so far; the pipe's
// end delivers the data.
@(private)
dnd_read_more :: proc(st: ^State) {
	chunk: [4096]u8
	for st.dnd_reading {
		n, err := linux.read(st.dnd_read_fd, chunk[:])
		if err == .EINTR do continue
		if err == .EAGAIN do return // more to come
		if err != .NONE || n <= 0 {
			dnd_read_done(st, err == .NONE)
			return
		}
		if len(st.dnd_read) + n > platform.TRANSFER_MAX_BYTES {
			dnd_read_done(st, false) // more than any drop carries
			return
		}
		append(&st.dnd_read, ..chunk[:n])
	}
}

// dnd_read_check gives up on a drop whose source has written nothing more in time.
@(private)
dnd_read_check :: proc(st: ^State) {
	if st.dnd_reading && time.tick_diff(st.dnd_read_deadline, time.tick_now()) > 0 do dnd_read_done(st, false)
}

@(private)
dnd_read_done :: proc(st: ^State, ok: bool) {
	if !st.dnd_reading do return
	linux.close(st.dnd_read_fd)
	st.dnd_reading = false
	if !ok do debugf(st, "drag: the drop's source did not answer in time")
	push(st, platform.Ev_Drag_Data{data = st.dnd_read[:] if ok else nil, ok = ok})
}

// dnd_read_stop abandons a drop's read and forgets its data.
@(private)
dnd_read_stop :: proc(st: ^State) {
	if st.dnd_reading {
		linux.close(st.dnd_read_fd)
		st.dnd_reading = false
	}
	clear(&st.dnd_read)
}

// drag_finish ends the drop: the source hears it succeeded (or not) and
// the offer goes.
@(private)
drag_finish :: proc(b: ^platform.Backend, accepted: bool) {
	st := state(b)
	dnd_read_stop(st)
	o := st.dnd_offer
	if o == nil do return
	if accepted && wl.proxy_version(o.proxy) >= 3 do wl.wl_data_offer_finish(o.proxy)
	dnd_offer_free(st)
	wl.display_flush(st.display)
}

// ---------------------------------------------------------- our drags out

@(private)
drag_source_drop :: proc(st: ^State) {
	if st.drag_source != nil {
		wl.wl_data_source_destroy(st.drag_source)
		st.drag_source = nil
	}
	items_free(st.drag_items)
	st.drag_items = nil
	drag_icon_drop(st)
}

// drag_icon_make gives the compositor a surface to draw beside the pointer
// while it carries our drag: the picture the toolkit drew, in shared memory,
// offset so it sits where the in-window ghost sat. Nil without a compositor
// or shm, or for a picture with no pixels; `wl_data_device_start_drag`
// accepts a nil icon.
@(private)
drag_icon_make :: proc(st: ^State, icon: platform.Drag_Icon) -> wl.Proxy {
	if st.compositor == nil || st.shm == nil do return nil
	if icon.size.x <= 0 || icon.size.y <= 0 do return nil
	if len(icon.pixels) < int(icon.size.x) * int(icon.size.y) * 4 do return nil
	buf := shm_buffer(st, icon.pixels, icon.size)
	if buf == nil do return nil
	surf := wl.wl_compositor_create_surface(st.compositor)
	if surf == nil {
		wl.wl_buffer_destroy(buf)
		return nil
	}
	scale := icon.scale if icon.scale > 0 else 1
	st.drag_icon_pic = {buffer = buf, size = icon.size, scale = scale}
	wl.wl_surface_attach(surf, buf, 0, 0)
	wl.wl_surface_damage_buffer(surf, 0, 0, icon.size.x, icon.size.y)
	// The picture is drawn in device pixels, so the surface says how many
	// of them go to a logical one — a viewport where there is one (it can
	// take a fractional scale), the integer buffer scale otherwise.
	if st.viewporter != nil {
		st.drag_icon_vp = wl.wp_viewporter_get_viewport(st.viewporter, surf)
		wl.wp_viewport_set_destination(st.drag_icon_vp, max(i32(f32(icon.size.x) / scale + 0.5), 1), max(i32(f32(icon.size.y) / scale + 0.5), 1))
	} else if s := i32(scale + 0.5); s >= 1 {
		wl.wl_surface_set_buffer_scale(surf, s)
	}
	// The offset is surface-local (logical px). From wl_surface v5 it is its
	// own request: `attach` with a non-zero x or y is a protocol error there,
	// and ours is bound up to WL_COMPOSITOR_VERSION 6.
	dx, dy := i32(f32(icon.offset.x) / scale + 0.5), i32(f32(icon.offset.y) / scale + 0.5)
	if dx != 0 || dy != 0 {
		if wl.proxy_version(surf) >= 5 {
			wl.wl_surface_offset(surf, dx, dy)
		} else {
			wl.wl_surface_attach(surf, buf, dx, dy)
		}
	}
	wl.wl_surface_commit(surf)
	return surf
}

// drag_icon_drop lets the drag's picture go: the surface at once, its
// buffer as soon as the compositor releases it.
@(private)
drag_icon_drop :: proc(st: ^State) {
	if st.drag_icon_vp != nil {
		wl.wp_viewport_destroy(st.drag_icon_vp)
		st.drag_icon_vp = nil
	}
	if st.drag_icon != nil {
		wl.wl_surface_destroy(st.drag_icon)
		st.drag_icon = nil
	}
	cursor_picture_drop(&st.drag_icon_pic)
}

// drag_start hands a drag begun in `surface` to the compositor, offering
// `items` and carrying `icon` beside the pointer. False without a data
// device or a serial to prove the press.
@(private)
drag_start :: proc(b: ^platform.Backend, surface: platform.Surface, items: []platform.Clip_Item, serial: u32, icon: platform.Drag_Icon) -> bool {
	st := state(b)
	if st.data_device == nil || st.data_mgr == nil || serial == 0 || len(items) == 0 do return false
	s := lookup(st, surface)
	if s == nil || s.wl_surface == nil do return false
	drag_source_drop(st)
	st.drag_source = wl.wl_data_device_manager_create_data_source(st.data_mgr)
	if st.drag_source == nil do return false
	st.drag_source_l = wl.wl_data_source_listener_noop()
	st.drag_source_l.send = on_source_send
	st.drag_source_l.cancelled = on_drag_source_cancelled
	st.drag_source_l.dnd_finished = on_drag_source_finished
	st.drag_source_l.action = on_drag_source_action
	st.drag_action = wl.WL_DATA_DEVICE_MANAGER_DND_ACTION_NONE
	wl.wl_data_source_add_listener(st.drag_source, &st.drag_source_l, st)
	st.drag_items = items_clone(items)
	for it in st.drag_items do wl.wl_data_source_offer(st.drag_source, strings.clone_to_cstring(it.mime, context.temp_allocator))
	if wl.proxy_version(st.drag_source) >= 3 {
		wl.wl_data_source_set_actions(st.drag_source, wl.WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY | wl.WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE)
	}
	st.drag_icon = drag_icon_make(st, icon)
	wl.wl_data_device_start_drag(st.data_device, st.drag_source, s.wl_surface, st.drag_icon, serial)
	wl.display_flush(st.display)
	debugf(st, "drag: handed to the compositor with %d forms, icon %dx%d", len(items), icon.size.x, icon.size.y)
	return true
}

@(private)
on_drag_source_cancelled :: proc "c" (data: rawptr, p: wl.Proxy) {
	st := (^State)(data)
	context = st.ctx
	if p != st.drag_source {
		wl.wl_data_source_destroy(p)
		return
	}
	drag_source_drop(st)
	push(st, platform.Ev_Drag_End{dropped = false})
}

@(private)
on_drag_source_finished :: proc "c" (data: rawptr, p: wl.Proxy) {
	st := (^State)(data)
	context = st.ctx
	if p != st.drag_source do return
	action := drag_action_from_wl(st.drag_action)
	drag_source_drop(st)
	push(st, platform.Ev_Drag_End{dropped = true, action = action})
}

// on_drag_source_action: the target (with the user's modifiers) chose
// what our drag does; the last one before the drop is the answer.
@(private)
on_drag_source_action :: proc "c" (data: rawptr, p: wl.Proxy, dnd_action: wl.Wl_Data_Device_Manager_Dnd_Action) {
	st := (^State)(data)
	if p == st.drag_source do st.drag_action = dnd_action
}

// ---------------------------------------------------------------- source

@(private)
source_drop :: proc(st: ^State) {
	if st.source != nil {
		wl.wl_data_source_destroy(st.source)
		st.source = nil
	}
	items_free(st.source_items)
	st.source_items = nil
}

@(private)
items_free :: proc(items: []platform.Clip_Item) {
	for it in items {
		delete(it.mime)
		delete(it.data)
		if it.later != nil do platform.clip_later_release(it.later)
	}
	delete(items)
}

// items_clone deep-copies what a caller offers, so it may free its own; a
// form made later is shared, by reference.
@(private)
items_clone :: proc(items: []platform.Clip_Item) -> []platform.Clip_Item {
	out := make([]platform.Clip_Item, len(items))
	for it, i in items {
		data := make([]u8, len(it.data))
		copy(data, it.data)
		out[i] = {mime = strings.clone(it.mime), data = data, later = it.later}
		if it.later != nil do platform.clip_later_retain(it.later)
	}
	return out
}

@(private)
item_find :: proc(items: []platform.Clip_Item, mime: string) -> (platform.Clip_Item, bool) {
	for it in items do if it.mime == mime do return it, true
	return {}, false
}

// on_source_send: another client pastes; its pipe is written on a thread
// of our own (pipe_write), so a slow or stalled reader never holds up the
// UI, and a form made later (a picture's PNG) is waited for there.
@(private)
on_source_send :: proc "c" (data: rawptr, p: wl.Proxy, mime_type: cstring, fd: i32) {
	st := (^State)(data)
	context = st.ctx
	items := st.source_items if p == st.source else st.drag_items if p == st.drag_source else nil
	item, have := item_find(items, string(mime_type))
	if !have || !pipe_write(linux.Fd(fd), item) do linux.close(linux.Fd(fd))
}

// Pipe_Write is one form on its way into a pipe: its own copy of the bytes,
// or a reference to the form made later.
@(private)
Pipe_Write :: struct {
	fd:    linux.Fd,
	data:  []u8,
	later: ^platform.Clip_Later,
}

// pipe_write writes `item` into `fd` on a thread that ends by itself, and
// takes the fd (closed when done). False when no thread could be started:
// the fd is still the caller's.
@(private)
pipe_write :: proc(fd: linux.Fd, item: platform.Clip_Item) -> bool {
	w := new(Pipe_Write, runtime.heap_allocator())
	w.fd = fd
	if item.later != nil {
		w.later = item.later
		platform.clip_later_retain(w.later)
	} else {
		w.data = make([]u8, len(item.data), runtime.heap_allocator())
		copy(w.data, item.data)
	}
	if thread.create_and_start_with_data(w, pipe_writer, self_cleanup = true) != nil do return true
	if w.later != nil do platform.clip_later_release(w.later)
	delete(w.data, runtime.heap_allocator())
	free(w, runtime.heap_allocator())
	return false
}

// pipe_writer is the thread: SIGPIPE blocked in it, so a reader that closes
// its end early ends the write with EPIPE rather than ending the app; the
// write is non-blocking with a bounded wait when the pipe is full, so a
// reader that stalls lets the thread go.
@(private)
pipe_writer :: proc(p: rawptr) {
	w := (^Pipe_Write)(p)
	context.allocator = runtime.heap_allocator()
	defer {
		linux.close(w.fd)
		if w.later != nil do platform.clip_later_release(w.later)
		delete(w.data)
		free(w)
	}
	block: linux.Sig_Set
	block[0] = 1 << (uint(linux.Signal.SIGPIPE) - 1)
	linux.rt_sigprocmask(.SIG_BLOCK, &block, nil)
	buf := w.data
	if w.later != nil do buf = w.later.wait(w.later)
	if flags, ferr := linux.fcntl_getfl(w.fd, linux.F_GETFL); ferr == .NONE {
		linux.fcntl_setfl(w.fd, linux.F_SETFL, flags + {.NONBLOCK})
	}
	for len(buf) > 0 {
		n, err := linux.write(w.fd, buf)
		if err == .EINTR do continue
		if err == .EAGAIN {
			fds := [1]linux.Poll_Fd{{fd = w.fd, events = {.OUT}}}
			if got, _ := linux.poll(fds[:], CLIPBOARD_READ_TIMEOUT_MS); got <= 0 do return
			continue
		}
		if err != .NONE || n <= 0 do return
		buf = buf[n:]
	}
}

// on_source_cancelled: another client took the selection (or the
// compositor dropped ours). Pastes now read the new offer.
@(private)
on_source_cancelled :: proc "c" (data: rawptr, p: wl.Proxy) {
	st := (^State)(data)
	context = st.ctx
	if p != st.source {
		wl.wl_data_source_destroy(p)
		return
	}
	source_drop(st)
	debugf(st, "clipboard: our selection was replaced")
}

// -------------------------------------------------------------- backend

// clipboard_types lists the mime types the selection offers now.
@(private)
clipboard_types :: proc(b: ^platform.Backend, allocator := context.allocator) -> []string {
	st := state(b)
	if st.source != nil {
		out := make([]string, len(st.source_items), allocator)
		for it, i in st.source_items do out[i] = strings.clone(it.mime, allocator)
		return out
	}
	if st.selection == nil do return {}
	out := make([]string, len(st.selection.mimes), allocator)
	for m, i in st.selection.mimes do out[i] = strings.clone(m, allocator)
	return out
}

// clipboard_get_data reads the selection in one mime type. Our own
// selection is answered from memory (asking the compositor for it would
// wait on our own event loop); another client's is read from a pipe
// until it closes it.
@(private)
clipboard_get_data :: proc(b: ^platform.Backend, mime: string, allocator := context.allocator) -> ([]u8, bool) {
	st := state(b)
	if st.source != nil {
		it, have := item_find(st.source_items, mime)
		if !have do return nil, false
		src := it.data
		if it.later != nil do src = it.later.wait(it.later) // ours, still being made: wait for it
		out := make([]u8, len(src), allocator)
		copy(out, src)
		return out, true
	}
	if st.selection == nil do return nil, false
	return offer_receive(st, st.selection, mime, allocator)
}

// clipboard_read starts reading one form for a thread to finish: our own
// selection is written into a pipe by a thread of ours (pipe_write),
// another client's is asked for into a pipe; either way the reader gets
// the pipe's end.
@(private)
clipboard_read :: proc(b: ^platform.Backend, mime: string) -> (r: platform.Clip_Reader, ok: bool) {
	st := state(b)
	fds: [2]linux.Fd
	if st.source != nil {
		it, have := item_find(st.source_items, mime)
		if !have do return
		if linux.pipe2(&fds, {.CLOEXEC}) != .NONE do return
		if !pipe_write(fds[1], it) {
			linux.close(fds[0])
			linux.close(fds[1])
			return
		}
		return platform.Clip_Reader{read = clip_pipe_read, fd = int(fds[0])}, true
	}
	if st.selection == nil do return
	offered := false
	for have in st.selection.mimes do if have == mime do offered = true
	if !offered do return
	if linux.pipe2(&fds, {.CLOEXEC}) != .NONE do return
	wl.wl_data_offer_receive(st.selection.proxy, strings.clone_to_cstring(mime, context.temp_allocator), i32(fds[1])) // libwayland dups the fd on marshal
	linux.close(fds[1])
	wl.display_flush(st.display)
	return platform.Clip_Reader{read = clip_pipe_read, fd = int(fds[0])}, true
}

// clip_pipe_read reads a pipe to its end, on whatever thread, and closes it.
@(private)
clip_pipe_read :: proc(r: platform.Clip_Reader, allocator: runtime.Allocator) -> ([]u8, bool) {
	fd := linux.Fd(r.fd)
	defer linux.close(fd)
	out, ok := pipe_read(fd, allocator)
	return out, ok
}

// pipe_read reads until the other end closes (true), or fails (false, with
// what came): quiet for CLIPBOARD_READ_TIMEOUT_MS, longer than
// TRANSFER_DEADLINE_MS in all, or more than TRANSFER_MAX_BYTES. A source
// that sends a byte a second must not hold the app, nor one that never stops.
@(private)
pipe_read :: proc(fd: linux.Fd, allocator: runtime.Allocator) -> ([]u8, bool) {
	out := make([dynamic]u8, allocator)
	chunk: [16384]u8
	start := time.tick_now()
	for {
		left := i64(platform.TRANSFER_DEADLINE_MS) - i64(time.duration_milliseconds(time.tick_since(start)))
		if left <= 0 do return out[:], false
		wait := [1]linux.Poll_Fd{{fd = fd, events = {.IN}}}
		got, perr := linux.poll(wait[:], i32(min(i64(CLIPBOARD_READ_TIMEOUT_MS), left)))
		if perr == .EINTR do continue
		if got <= 0 do return out[:], false
		n, err := linux.read(fd, chunk[:])
		if err == .EINTR do continue
		if err != .NONE do return out[:], false
		if n <= 0 do return out[:], true
		if len(out) + n > platform.TRANSFER_MAX_BYTES do return out[:], false
		append(&out, ..chunk[:n])
	}
}

// offer_receive reads one form of an offer from a pipe until the other
// client closes it (bounded: a source that never writes cannot hang us).
@(private)
offer_receive :: proc(st: ^State, o: ^Data_Offer, mime: string, allocator := context.allocator) -> ([]u8, bool) {
	offered := false
	for have in o.mimes do if have == mime { offered = true; break }
	if !offered do return nil, false
	cmime := strings.clone_to_cstring(mime, context.temp_allocator)

	fds: [2]linux.Fd
	if linux.pipe2(&fds, {.CLOEXEC}) != .NONE do return nil, false
	wl.wl_data_offer_receive(o.proxy, cmime, i32(fds[1])) // libwayland dups the fd on marshal
	linux.close(fds[1])
	wl.display_flush(st.display)
	defer linux.close(fds[0])

	out, ok := pipe_read(fds[0], allocator) // bounded in time and in size
	if !ok {
		debugf(st, "clipboard: the source did not finish in time or sent too much (%d bytes)", len(out))
		delete(out, allocator)
		return nil, false
	}
	return out, true
}

// clipboard_get reads the selection as text, in the first text form it
// offers.
@(private)
clipboard_get :: proc(b: ^platform.Backend, allocator := context.allocator) -> (string, bool) {
	for want in TEXT_MIMES {
		if data, ok := clipboard_get_data(b, string(want), allocator); ok do return string(data), true
	}
	return "", false
}

// clipboard_set_data offers `items` as the selection, with the last input
// serial as the compositor's proof of a user action. False before any
// input (nothing to prove with) or without a data device.
@(private)
clipboard_set_data :: proc(b: ^platform.Backend, items: []platform.Clip_Item) -> bool {
	st := state(b)
	if st.data_device == nil || st.data_mgr == nil || st.input_serial == 0 || len(items) == 0 do return false
	source_drop(st)
	st.source = wl.wl_data_device_manager_create_data_source(st.data_mgr)
	if st.source == nil do return false
	st.source_l = wl.wl_data_source_listener_noop()
	st.source_l.send = on_source_send
	st.source_l.cancelled = on_source_cancelled
	wl.wl_data_source_add_listener(st.source, &st.source_l, st)
	st.source_items = items_clone(items)
	for it in st.source_items do wl.wl_data_source_offer(st.source, strings.clone_to_cstring(it.mime, context.temp_allocator))
	wl.wl_data_device_set_selection(st.data_device, st.source, st.input_serial)
	wl.display_flush(st.display)
	return true
}

// clipboard_set offers `text` in every text form.
@(private)
clipboard_set :: proc(b: ^platform.Backend, text: string) -> bool {
	items: [len(TEXT_MIMES)]platform.Clip_Item
	for m, i in TEXT_MIMES do items[i] = {mime = string(m), data = transmute([]u8)text}
	return clipboard_set_data(b, items[:])
}
