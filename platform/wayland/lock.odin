package wayland

// Session lock (ext-session-lock-v1): a lock screen that is a
// Baldr app. The app asks for the lock (session_lock), makes one lock
// surface per screen (surface_create with .Lock), and ends the lock with
// session_unlock once it has decided to — the only request here that
// unlocks anything.
//
// The protocol's safety is that a lock outlives its client: if the client
// goes without unlock_and_destroy, the compositor keeps the session hidden.
// So nothing on a cleanup path touches the lock object. Not shutdown, not a
// lost connection, not the compositor's `finished`, not a lock surface
// going: the session stays locked until the app says otherwise. And after
// `locked` the object is never sent `destroy` (a protocol error), only
// unlock_and_destroy.

import "core:time"
import "baldr:platform"
import wl "baldr:platform/wayland/wl"

// Lock_State is one ext_session_lock_v1 this app asked for.
@(private)
Lock_State :: struct {
	st:        ^State,
	proxy:     wl.Proxy,
	listener:  wl.Ext_Session_Lock_V1_Listener,
	locked:    bool, // the compositor sent `locked`: only unlock_and_destroy may end it now
	finished:  bool, // …or `finished`
	withdrawn: bool, // session_unlock came before either: ended as soon as the compositor answers
	shown:     bool, // Ev_Lock Shown was sent
}

// LOCK_WITHDRAW_WAIT is how long shutdown waits for the compositor to answer
// a lock the app withdrew before it was answered, so that the unlock it is
// owed can be sent. A lock the compositor answers later than this stays
// locked: it fails closed.
@(private)
LOCK_WITHDRAW_WAIT :: 3 * time.Second

// session_lock asks the compositor to lock the session (Backend.session_lock).
@(private)
session_lock :: proc(b: ^platform.Backend) -> bool {
	st := state(b)
	if st.lock_mgr == nil {
		debugf(st, "session_lock: the compositor has no ext_session_lock_manager_v1")
		return false
	}
	if st.lock != nil {
		debugf(st, "session_lock: this app's lock is still live")
		return false
	}
	l := new(Lock_State)
	l.st = st
	l.proxy = wl.ext_session_lock_manager_v1_lock(st.lock_mgr)
	l.listener = wl.ext_session_lock_v1_listener_noop()
	l.listener.locked = on_lock_locked
	l.listener.finished = on_lock_finished
	wl.ext_session_lock_v1_add_listener(l.proxy, &l.listener, l)
	st.lock = l
	wl.display_flush(st.display)
	debugf(st, "session lock asked for (ext_session_lock_v1 #%d)", wl.proxy_id(l.proxy))
	return true
}

// session_unlock ends this app's lock (Backend.session_unlock): at once when
// the compositor has answered, else when it does. The caller closes its lock
// surfaces after.
@(private)
session_unlock :: proc(b: ^platform.Backend) {
	st := state(b)
	l := st.lock
	if l == nil do return
	st.lock = nil
	if !l.locked && !l.finished {
		// Not answered yet. A destroy now could cross a `locked` already on
		// its way, which makes the destroy a protocol error; the answer
		// decides instead (on_lock_locked, on_lock_finished).
		l.withdrawn = true
		append(&st.locks_withdrawn, l)
		debugf(st, "session lock withdrawn before the compositor answered: ended when it does")
		return
	}
	lock_end(st, l)
}

// lock_end ends a lock the app unlocked or withdrew: unlock_and_destroy once
// the compositor has locked (the only request that may end it then),
// destroy while it never did. Reached from session_unlock only, directly or
// through a withdrawn lock's answer.
@(private)
lock_end :: proc(st: ^State, l: ^Lock_State) {
	if l.locked {
		wl.ext_session_lock_v1_unlock_and_destroy(l.proxy)
		st.unlock_sent = true // shutdown makes sure it arrives (lock_shutdown)
		debugf(st, "session unlocked (unlock_and_destroy)")
	} else {
		wl.ext_session_lock_v1_destroy(l.proxy)
		debugf(st, "session lock dropped before it locked (destroy)")
	}
	wl.display_flush(st.display)
	for w, i in st.locks_withdrawn do if w == l {
		ordered_remove(&st.locks_withdrawn, i)
		break
	}
	free(l)
}

@(private)
on_lock_locked :: proc "c" (data: rawptr, p: wl.Proxy) {
	l := (^Lock_State)(data)
	st := l.st
	context = st.ctx
	l.locked = true
	if l.withdrawn { // the app unlocked before the compositor answered
		lock_end(st, l)
		return
	}
	debugf(st, "session locked")
	push(st, platform.Ev_Lock{event = .Locked})
	// Shown waits for a frame of every lock surface's own with the session
	// hidden: one on screen already shows it again, one not yet drawn
	// counts its first.
	for s in st.surfaces do if s != nil && s.lock_surface != nil {
		s.lock_shown = false
		if s.mapped do frame_arm(st, s)
	}
}

@(private)
on_lock_finished :: proc "c" (data: rawptr, p: wl.Proxy) {
	l := (^Lock_State)(data)
	st := l.st
	context = st.ctx
	l.finished = true
	if l.withdrawn {
		lock_end(st, l)
		return
	}
	if !l.locked {
		// Refused (another lock is live, or the compositor said no): the
		// object is spent and never locked, so destroy is the protocol's
		// answer, and nothing is unlocked by it.
		debugf(st, "session lock refused (finished before locked)")
		wl.ext_session_lock_v1_destroy(l.proxy)
		wl.display_flush(st.display)
		if st.lock == l do st.lock = nil
		free(l)
	} else {
		// The compositor ended the lock itself. The object stays until the
		// app's session_unlock sends unlock_and_destroy, as the protocol
		// asks; nothing here unlocks.
		debugf(st, "session lock finished by the compositor after locking")
	}
	push(st, platform.Ev_Lock{event = .Finished})
}

// lock_surface_shown notes a lock surface's frame on screen since the
// session locked, and says Shown once every lock surface has had one.
@(private)
lock_surface_shown :: proc(st: ^State, s: ^Surface_State) {
	l := st.lock
	if l == nil || !l.locked || s.lock_shown do return
	s.lock_shown = true
	lock_check_shown(st)
}

// lock_check_shown sends Ev_Lock Shown, once per lock, when there are lock
// surfaces and each has shown a frame since the session locked.
@(private)
lock_check_shown :: proc(st: ^State) {
	l := st.lock
	if l == nil || !l.locked || l.finished || l.shown do return
	any := false
	for s in st.surfaces do if s != nil && s.lock_surface != nil {
		if !s.lock_shown do return
		any = true
	}
	if !any do return
	l.shown = true
	debugf(st, "every lock surface has shown a frame")
	push(st, platform.Ev_Lock{event = .Shown})
}

// lock_surface_refused says (and logs) why no lock surface can be made for
// the screen `name`: no live lock, no such screen, or it has one already —
// a second is a protocol error (duplicate_output) that would cost the app
// its connection.
@(private)
lock_surface_refused :: proc(st: ^State, name: string) -> bool {
	if st.lock == nil {
		debugf(st, "surface_create: a lock surface needs a live session lock (session_lock)")
		return true
	}
	o := output_named(st, name)
	if o == nil {
		debugf(st, "surface_create: no screen called %q for a lock surface", name)
		return true
	}
	for s in st.surfaces do if s != nil && s.lock_surface != nil && s.lock_output == o {
		debugf(st, "surface_create: %q has a lock surface already (surface %d)", name, s.id)
		return true
	}
	return false
}

// output_named is the screen called `name`, or nil.
@(private)
output_named :: proc(st: ^State, name: string) -> ^Output {
	if name == "" do return nil
	for o in st.outputs do if o.out_name == name do return o
	return nil
}

// create_lock_surface gives `s` the lock-surface role on the screen `o`.
// The compositor configures it at once; nothing is committed before that
// configure is acked (surface_ack_configure, just before the first frame
// is presented).
@(private)
create_lock_surface :: proc(st: ^State, s: ^Surface_State, o: ^Output) {
	s.lock_output = o
	s.lock_surface = wl.ext_session_lock_v1_get_lock_surface(st.lock.proxy, s.wl_surface, o.proxy)
	s.lock_l = wl.ext_session_lock_surface_v1_listener_noop()
	s.lock_l.configure = on_lock_configure
	wl.ext_session_lock_surface_v1_add_listener(s.lock_surface, &s.lock_l, s)
}

// on_lock_configure: the screen's size, which the lock surface must be;
// acked by the frame drawn at it, as a layer surface's is.
@(private)
on_lock_configure :: proc "c" (data: rawptr, p: wl.Proxy, serial: u32, width, height: u32) {
	s := (^Surface_State)(data)
	context = s.st.ctx
	size := s.size
	if width > 0 && height > 0 {
		size = {f32(width), f32(height)}
	} else if !s.configured {
		size = s.default_size
	}
	s.configure_serial = serial
	if s.configured && size == s.size {
		wl.ext_session_lock_surface_v1_ack_configure(p, serial)
		s.ack_pending = false
	} else {
		s.ack_serial, s.ack_pending = serial, true
	}
	apply_geometry(s, size)
}

// lock_shutdown runs as the connection is about to close, and never
// unlocks: a live lock stays locked, which is the protocol's promise for a
// client that goes. It only makes sure what the app did ask for arrives: a
// lock withdrawn before the compositor answered is waited on a moment
// (LOCK_WITHDRAW_WAIT) so the unlock it is owed can be sent, and an unlock
// sent reaches the compositor before the socket closes — the protocol's
// advice for a client that quits straight after unlocking, since a
// compositor seeing the hang-up may drop requests it has not read.
// Dispatching here is safe: nothing reads the events it queues.
@(private)
lock_shutdown :: proc(st: ^State) {
	deadline := time.tick_add(time.tick_now(), LOCK_WITHDRAW_WAIT)
	for len(st.locks_withdrawn) > 0 && !st.lost {
		left := time.tick_diff(time.tick_now(), deadline)
		if left <= 0 {
			debugf(st, "shutdown: %d withdrawn lock(s) still unanswered: they stay locked", len(st.locks_withdrawn))
			break
		}
		pump_once(st, i32(max(left / time.Millisecond, 1)))
	}
	if st.unlock_sent && !st.lost do wl.display_roundtrip(st.display)
}

// lock_free frees the lock bookkeeping once the connection is closed. No
// request is sent: see lock_shutdown.
@(private)
lock_free :: proc(st: ^State) {
	if st.lock != nil do free(st.lock)
	st.lock = nil
	for l in st.locks_withdrawn do free(l)
	delete(st.locks_withdrawn)
}
