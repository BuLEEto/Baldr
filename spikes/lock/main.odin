package main

// A Baldr lock screen, for trying the session lock in the nested harness.
// It locks at once, puts a lock surface on every screen (the password is
// "baldr"), and says what happens on stdout, one a line: "asked", "locked",
// "shown", "finished", "wrong", "unlocking".
//
// LOCK_THEN is what it does once the lock screen is shown, so a test can
// see the session stays locked whatever a locker does short of unlocking:
//   (unset)      waits for the password; right, it unlocks and quits
//   quit         quits (Baldr's own cleanup, with the lock live)
//   drop         drops its lock surfaces, and carries on
//   withdraw     no waiting: locks, unlocks and quits in its first command,
//                before the desktop can answer (the withdrawn lock's path)
// A test kills it with SIGKILL for a crash. On `finished` it quits.
//
// The password card goes on the lock surface with the keyboard, with
// Caps Lock and the layout said under it; the other screens show
// "Locked". Each surface's view says on stdout what it shows when that
// changes: "view TAG keyboard=… caps=… layout=…/N", and "screen TAG NAME"
// names each tag's screen.
//
// The Unlock button is the first thing at the top left of the card, so a
// harness can click it without looking.

import "core:fmt"
import "core:hash"
import "core:os"
import "core:strings"
import "baldr:baldr"

State :: struct {
	then:     string,
	locking:  bool,
	password: string,
	status:   string,
	said:     map[u64]string, // what each surface's view last said on stdout
}

Msg :: union {
	Locked,
	Shown,
	Finished,
	Typed,
	Unlock,
}
Locked :: struct {}
Shown :: struct {}
Finished :: struct {}
Typed :: struct { text: string }
Unlock :: struct {}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		app_id = "dev.baldr.lock",
		init = proc() -> State {
			return {then = os.get_env("LOCK_THEN", context.allocator), locking = true, status = "Type the password"}
		},
		start = proc(s: ^State) -> baldr.Cmd(Msg) {
			say("asked")
			lock := baldr.lock_session(Msg, Locked{}, Finished{}, on_shown = Shown{})
			if s.then == "withdraw" {
				s.locking = false
				return baldr.batch(Msg, lock, baldr.unlock_session(Msg), baldr.quit(Msg))
			}
			return lock
		},
		update = update,
		view = view,
		surfaces = proc(s: ^State, out: ^[dynamic]baldr.Surface_Desc(Msg)) {
			if !s.locking do return
			// each tagged by its screen's name: a screen going leaves the others' as they are
			for o in baldr.outputs() {
				tag := hash.fnv64a(transmute([]u8)o.name)
				append(out, baldr.Surface_Desc(Msg){tag = tag, kind = .Lock, output = o.name})
				line := fmt.tprintf("screen %d %s", tag, o.name)
				if s.said[tag + 1] != line {
					delete(s.said[tag + 1])
					s.said[tag + 1] = strings.clone(line)
					say(line)
				}
			}
		},
		keep_running = proc(s: ^State) -> bool { return true }, // a locker with its surfaces dropped still holds the lock
	})
}

say :: proc(line: string) {
	fmt.println(line)
	os.flush(os.stdout)
}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch v in m {
	case Locked:
		say("locked")
	case Shown:
		say("shown")
		switch s.then {
		case "quit": return baldr.quit(Msg)
		case "drop": s.locking = false
		}
	case Finished:
		say("finished")
		return baldr.quit(Msg)
	case Typed:
		delete(s.password)
		s.password = strings.clone(v.text)
	case Unlock:
		if s.password != "baldr" {
			say("wrong")
			s.status = "That is not the password"
			return {}
		}
		say("unlocking")
		s.locking = false
		return baldr.batch(Msg, baldr.unlock_session(Msg), baldr.quit(Msg))
	}
	return {}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	tag := ui.surface.tag
	caps := .Caps in baldr.keyboard_locks(ui)
	layout, layouts := baldr.keyboard_layout(ui)
	line := fmt.tprintf("view %d keyboard=%v caps=%v layout=%s/%d", tag, ui.surface.keyboard, caps, layout, layouts)
	if s.said[tag] != line {
		delete(s.said[tag])
		s.said[tag] = strings.clone(line)
		say(line)
	}
	baldr.column(ui, gap = .md, padding = .lg, align = .Start); defer baldr.end(ui)
	if !ui.surface.keyboard { // the other screens: the lock, and where to go
		baldr.text(ui, "Locked", role = .Title)
		return
	}
	baldr.button(ui, "Unlock", Unlock{})
	baldr.text_input(ui, nil, placeholder = "Password", label = "Password", password = true, width = 320, focus = true,
		on_change = proc(e: baldr.Ev(string)) -> Msg { return Typed{e.value} },
		on_submit = proc(e: baldr.Ev(string)) -> Msg { return Unlock{} })
	baldr.text(ui, s.status)
	if caps do baldr.text(ui, "Caps Lock is on", muted = true)
	if layouts > 1 do baldr.text(ui, layout, muted = true)
}
