package wayland

// The primary selection: what was last selected, pasted with
// a middle click, through zwp_primary_selection_v1. It works as the
// clipboard does (clipboard.odin) — one device per seat announces each
// selection as an offer with its mime types, and ours is a source the
// compositor asks to write into a pipe — with text only, which is all a
// selection is.

import "core:strings"
import "core:sys/linux"
import "baldr:platform"
import wl "baldr:platform/wayland/wl"

// Primary_Offer is a primary selection another client announced.
@(private)
Primary_Offer :: struct {
	st:    ^State,
	proxy: wl.Proxy,
	l:     wl.Zwp_Primary_Selection_Offer_V1_Listener,
	mimes: [dynamic]string,
}

// Primary is the seat's primary selection: the device, the offers it
// announced, the one that is the selection, and ours.
@(private)
Primary :: struct {
	mgr:      wl.Proxy, // zwp_primary_selection_device_manager_v1, may be nil
	device:   wl.Proxy,
	device_l: wl.Zwp_Primary_Selection_Device_V1_Listener,
	offers:   [dynamic]^Primary_Offer,
	current:  ^Primary_Offer, // nil: empty, or ours
	source:   wl.Proxy,       // ours, nil when another client has it
	source_l: wl.Zwp_Primary_Selection_Source_V1_Listener,
	text:     string,         // what ours holds (owned)
}

// primary_init makes the seat's device once the manager and the seat are
// bound (with clipboard_init, between the two registry roundtrips).
@(private)
primary_init :: proc(st: ^State) {
	p := &st.primary
	if p.mgr == nil || st.seat == nil || p.device != nil do return
	p.device = wl.zwp_primary_selection_device_manager_v1_get_device(p.mgr, st.seat)
	p.device_l = wl.zwp_primary_selection_device_v1_listener_noop()
	p.device_l.data_offer = on_primary_offer
	p.device_l.selection = on_primary_selection
	wl.zwp_primary_selection_device_v1_add_listener(p.device, &p.device_l, st)
}

@(private)
primary_teardown :: proc(st: ^State) {
	p := &st.primary
	primary_source_drop(st)
	primary_offer_free(p.current)
	p.current = nil
	for o in p.offers do primary_offer_free(o)
	delete(p.offers)
	p.offers = nil
	if p.device != nil do wl.zwp_primary_selection_device_v1_destroy(p.device)
	p.device = nil
	if p.mgr != nil do wl.zwp_primary_selection_device_manager_v1_destroy(p.mgr)
	p.mgr = nil
}

@(private)
primary_offer_free :: proc(o: ^Primary_Offer) {
	if o == nil do return
	if o.proxy != nil do wl.zwp_primary_selection_offer_v1_destroy(o.proxy)
	for m in o.mimes do delete(m)
	delete(o.mimes)
	free(o)
}

// on_primary_offer: a new offer, its mime types following on it.
@(private)
on_primary_offer :: proc "c" (data: rawptr, p: wl.Proxy, id: wl.Proxy) {
	st := (^State)(data)
	context = st.ctx
	o := new(Primary_Offer)
	o.st, o.proxy = st, id
	o.mimes = make([dynamic]string)
	o.l = wl.zwp_primary_selection_offer_v1_listener_noop()
	o.l.offer = on_primary_offer_mime
	wl.zwp_primary_selection_offer_v1_add_listener(id, &o.l, o)
	append(&st.primary.offers, o)
}

@(private)
on_primary_offer_mime :: proc "c" (data: rawptr, p: wl.Proxy, mime_type: cstring) {
	o := (^Primary_Offer)(data)
	context = o.st.ctx
	append(&o.mimes, strings.clone_from_cstring(mime_type))
}

// on_primary_selection: this offer is the primary selection now (nil: none).
@(private)
on_primary_selection :: proc "c" (data: rawptr, p: wl.Proxy, id: wl.Proxy) {
	st := (^State)(data)
	context = st.ctx
	pr := &st.primary
	primary_offer_free(pr.current)
	pr.current = nil
	for o, i in pr.offers {
		if o.proxy != id do continue
		pr.current = o
		unordered_remove(&pr.offers, i)
		break
	}
	debugf(st, "primary: selection %s", "offered" if pr.current != nil else "cleared")
}

@(private)
primary_source_drop :: proc(st: ^State) {
	p := &st.primary
	if p.source != nil do wl.zwp_primary_selection_source_v1_destroy(p.source)
	p.source = nil
	delete(p.text)
	p.text = ""
}

// on_primary_send: another client pastes ours; the text goes into its pipe
// on a thread of ours (pipe_write), as the clipboard's does.
@(private)
on_primary_send :: proc "c" (data: rawptr, p: wl.Proxy, mime_type: cstring, fd: i32) {
	st := (^State)(data)
	context = st.ctx
	if p != st.primary.source || !pipe_write(linux.Fd(fd), platform.Clip_Item{mime = string(mime_type), data = transmute([]u8)st.primary.text}) {
		linux.close(linux.Fd(fd))
	}
}

// on_primary_cancelled: another client selected something; ours goes.
@(private)
on_primary_cancelled :: proc "c" (data: rawptr, p: wl.Proxy) {
	st := (^State)(data)
	context = st.ctx
	if p != st.primary.source {
		wl.zwp_primary_selection_source_v1_destroy(p)
		return
	}
	primary_source_drop(st)
}

// primary_set makes `text` the primary selection, with the last input's
// serial as proof it came from the user. False without the protocol or
// before any input.
@(private)
primary_set :: proc(b: ^platform.Backend, text: string) -> bool {
	st := state(b)
	p := &st.primary
	if p.device == nil || p.mgr == nil || st.input_serial == 0 do return false
	primary_source_drop(st)
	p.source = wl.zwp_primary_selection_device_manager_v1_create_source(p.mgr)
	if p.source == nil do return false
	p.source_l = wl.zwp_primary_selection_source_v1_listener_noop()
	p.source_l.send = on_primary_send
	p.source_l.cancelled = on_primary_cancelled
	wl.zwp_primary_selection_source_v1_add_listener(p.source, &p.source_l, st)
	p.text = strings.clone(text)
	for m in TEXT_MIMES do wl.zwp_primary_selection_source_v1_offer(p.source, m)
	wl.zwp_primary_selection_device_v1_set_selection(p.device, p.source, st.input_serial)
	wl.display_flush(st.display)
	return true
}

// primary_get reads the primary selection as text, in the first text form
// it offers: ours from memory, another client's from a pipe (bounded, as
// the clipboard's is).
@(private)
primary_get :: proc(b: ^platform.Backend, allocator := context.allocator) -> (string, bool) {
	st := state(b)
	p := &st.primary
	if p.source != nil do return strings.clone(p.text, allocator), true
	o := p.current
	if o == nil do return "", false
	for want in TEXT_MIMES {
		offered := false
		for m in o.mimes do if m == string(want) { offered = true; break }
		if !offered do continue
		fds: [2]linux.Fd
		if linux.pipe2(&fds, {.CLOEXEC}) != .NONE do return "", false
		wl.zwp_primary_selection_offer_v1_receive(o.proxy, want, i32(fds[1])) // libwayland dups the fd on marshal
		linux.close(fds[1])
		wl.display_flush(st.display)
		out, ok := pipe_read(fds[0], allocator)
		linux.close(fds[0])
		return string(out), ok
	}
	return "", false
}
