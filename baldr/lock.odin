package baldr

// Locking the session: a lock screen as a Baldr app.
//
// The protocol is ext-session-lock-v1, a freedesktop standard, so a lock
// screen written here is not tied to one desktop (docs/widgets.md, "What
// the desktop has to support"). Where a desktop has no lock protocol,
// on_finished arrives at once and no window ever stands in for a lock
// surface.
//
// The app asks for the lock with lock_session, declares one .Lock surface
// per screen in App.surfaces (by the screen's name, from outputs()), and
// ends the lock with unlock_session once the user has proved who they are.
// Tag each lock surface by its screen's name, so a screen going leaves the
// others in place (tagged by position, the ones after it would move).
//
//	surfaces :: proc(s: ^State, out: ^[dynamic]baldr.Surface_Desc(Msg)) {
//		if !s.locking do return
//		for o in baldr.outputs() do append(out, baldr.Surface_Desc(Msg){tag = hash.fnv64a(transmute([]u8)o.name), kind = .Lock, output = o.name})
//	}
//	…
//	case Lock:     s.locking = true; return baldr.lock_session(Msg, Locked{}, Lock_Finished{}, on_shown = Msg(Lock_Shown{}))
//	case Verified: s.locking = false; return baldr.unlock_session(Msg)
//
// The lock is the most security-sensitive thing Baldr does, so its rules
// are few and absolute:
//
//   - unlock_session is the only way the session unlocks. Baldr never
//     unlocks on its own: not when the app quits, returns from run, crashes,
//     drops its .Lock surfaces, loses the desktop, or hears on_finished. The
//     protocol's promise is that a lock outlives its client, and the
//     desktop keeps the session hidden.
//   - A lock surface shows the app's own drawing and nothing else: the
//     screen's size, opaque, no frame, no glass (what is behind it is the
//     session it hides). Without a lock protocol there is no lock surface,
//     never a window standing in for one.
//   - While the lock is live, only .Lock surfaces open. Anything else
//     declared then waits for the unlock (a notification's toast opens after
//     it); what was open already stays open, and the desktop hides it.
//     Menus and popovers on a lock surface open inside it.
//
// The keyboard follows the desktop (the lock surface on the screen the user
// is at); text fields, secret ones included, the pointer and touch work as
// on any surface.

import "core:fmt"
import "baldr:platform"

// lock_session asks the desktop to lock the session. `on_locked` comes when
// it has: every screen is hidden, and no frame of the session shows until
// unlock_session. `on_shown` comes once every .Lock surface has had a frame
// of its own on screen since then: the lock screen is up (a locker that
// sleeps the machine waits for this). `on_finished` comes when the desktop
// refused (another lock is live, or it cannot lock) or, after on_locked,
// ended the lock itself; the protocol then asks the app to unlock_session.
//
// While the lock is live — from this command until unlock_session — the
// app's .Lock surfaces open, and no other surface does. Ignored, with a
// message on stderr, while a lock the app asked for is still live.
lock_session :: proc($Msg: typeid, on_locked: Msg, on_finished: Msg, on_shown: Maybe(Msg) = nil) -> Cmd(Msg) {
	return {kind = .Lock, on_locked = on_locked, on_finished = on_finished, on_shown = on_shown}
}

// unlock_session unlocks the session, and is the only thing that does. The
// .Lock surfaces close with it. Before the desktop has answered
// lock_session, it withdraws the lock: the desktop's answer is waited for,
// and a session it goes on to lock is unlocked at once. An app may quit
// straight after: the desktop has the unlock before the connection closes.
// Nothing happens when no lock is live.
unlock_session :: proc($Msg: typeid) -> Cmd(Msg) {
	return {kind = .Unlock}
}

// Lock_Phase is where the app's session lock is.
@(private)
Lock_Phase :: enum u8 {
	None,   // no lock
	Asked,  // lock_session sent, the desktop has not answered
	Locked, // the desktop locked the session
	Ended,  // the desktop ended the lock after locking: unlock_session lets it go
}

// Session_Lock is the app's lock of the session, and what it is told.
@(private)
Session_Lock :: struct($Msg: typeid) {
	phase:       Lock_Phase,
	on_locked:   Msg,
	on_finished: Msg,
	on_shown:    Maybe(Msg),
	held_said:   bool, // a surface waiting for the unlock was reported
	output_said: bool, // a .Lock without `output` was reported
}

// lock_live says whether the app's lock holds the session (or has been
// asked for): its .Lock surfaces open, nothing else does.
@(private)
lock_live :: proc(rt: ^Runtime($State, $Msg)) -> bool {
	return rt.lock.phase != .None
}

// lock_start runs lock_session.
@(private)
lock_start :: proc(rt: ^Runtime($State, $Msg), cmd: Cmd(Msg)) {
	if lock_live(rt) {
		fmt.eprintln("baldr: lock_session: the lock asked for earlier is still live; this one is ignored")
		return
	}
	b := rt.backend
	if b == nil || b.session_lock == nil || .Session_Lock not_in b.caps || !b.session_lock(b) {
		fmt.eprintln("baldr: lock_session: this desktop cannot lock the session")
		append(&rt.msgs, cmd.on_finished)
		return
	}
	rt.lock = {phase = .Asked, on_locked = cmd.on_locked, on_finished = cmd.on_finished, on_shown = cmd.on_shown}
}

// lock_stop runs unlock_session: the backend unlocks (or withdraws the
// lock), and the lock surfaces close.
@(private)
lock_stop :: proc(rt: ^Runtime($State, $Msg)) {
	if !lock_live(rt) do return
	if b := rt.backend; b != nil && b.session_unlock != nil do b.session_unlock(b)
	rt.lock = {}
	lock_surfaces_close(rt)
}

// lock_surfaces_close closes the .Lock surfaces of a lock that is over.
@(private)
lock_surfaces_close :: proc(rt: ^Runtime($State, $Msg)) {
	for i := len(rt.ctxs) - 1; i >= 0; i -= 1 {
		if rt.ctxs[i].kind == .Lock do surface_close(rt, i)
	}
}

// lock_event takes the desktop's word on the lock (Ev_Lock) and tells the
// app. Nothing here unlocks: after a Finished the lock waits for
// unlock_session.
@(private)
lock_event :: proc(rt: ^Runtime($State, $Msg), ev: platform.Lock_Event) {
	switch ev {
	case .Locked:
		if rt.lock.phase != .Asked do return
		rt.lock.phase = .Locked
		append(&rt.msgs, rt.lock.on_locked)
	case .Shown:
		if rt.lock.phase != .Locked do return
		if m, ok := rt.lock.on_shown.?; ok do append(&rt.msgs, m)
	case .Finished:
		switch rt.lock.phase {
		case .None, .Ended:
		case .Asked: // refused: the backend let the lock go, never having locked
			m := rt.lock.on_finished
			rt.lock = {}
			lock_surfaces_close(rt)
			append(&rt.msgs, m)
		case .Locked: // ended by the desktop: still the app's to let go
			rt.lock.phase = .Ended
			append(&rt.msgs, rt.lock.on_finished)
		}
	}
}

// lock_hold takes out of rt.wanted what the lock keeps from opening: .Lock
// surfaces while no lock is live, one naming no screen, and one naming a
// screen an earlier one covers (two on a screen is a protocol error that
// would cost the app its connection); and while a lock is live, any other
// surface not open already. Says whether it held any: the run waits for
// them.
@(private)
lock_hold :: proc(rt: ^Runtime($State, $Msg)) -> (held: bool) {
	live := lock_live(rt)
	for i := 0; i < len(rt.wanted); {
		w := rt.wanted[i]
		keep := true
		if w.kind == .Lock {
			if !live {
				keep = false
			} else if w.output == "" {
				keep = false
				if !rt.lock.output_said {
					fmt.eprintfln("baldr: surfaces: .Lock surface %d names no screen (`output`); it covers one, by its name in outputs()", w.tag)
					rt.lock.output_said = true
				}
			} else {
				for v in rt.wanted[:i] do if v.kind == .Lock && v.output == w.output {
					fmt.eprintfln("baldr: surfaces: .Lock surfaces %d and %d both cover %q; the second is ignored", v.tag, w.tag, w.output)
					keep = false
					break
				}
			}
		} else if live && !surface_is_open(rt, w.tag) {
			keep = false
			if !rt.lock.held_said {
				fmt.eprintfln("baldr: surfaces: the session is locked: surface %d (%v) waits for unlock_session; only .Lock surfaces open until then", w.tag, w.kind)
				rt.lock.held_said = true
			}
		}
		if keep {
			i += 1
		} else {
			ordered_remove(&rt.wanted, i)
			held = true
		}
	}
	return
}

// lock_moved closes each open lock surface now declared for another screen
// (or as something else), so that sync_surfaces opens it again there after:
// closing first, two lock surfaces never share a screen, even for a moment.
@(private)
lock_moved :: proc(rt: ^Runtime($State, $Msg)) {
	for i := len(rt.ctxs) - 1; i >= 0; i -= 1 {
		c := rt.ctxs[i]
		if c.kind != .Lock do continue
		for w in rt.wanted do if w.tag == c.desc.tag {
			if w.kind != .Lock || w.output != c.desc.output do surface_close(rt, i)
			break
		}
	}
}

// surface_is_open says whether a surface with this tag is open.
@(private)
surface_is_open :: proc(rt: ^Runtime($State, $Msg), tag: u64) -> bool {
	for c in rt.ctxs do if c.desc.tag == tag do return true
	return false
}
