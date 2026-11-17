package main

// The OS keychain, end to end, on whichever desktop it is run.
//
// set → get → compare → delete → get again, printing what each answered.
// The last get must say `Not_Found`: a delete that silently does nothing
// looks exactly like one that worked, and leaves a token behind after a
// sign-out.
//
// It runs with no window at all (`keep_running`), so it is also the
// smallest check that a tray-resident app's lifecycle works on this
// platform: `run` comes up, the ops go round on their own threads, and the
// app ends on `quit` without a surface ever being declared.
//
//	./build.sh spike keychain_check run
//	KEYCHAIN_SERVICE=… KEYCHAIN_ACCOUNT=… build/keychain_check
//
// On macOS run it through the bundle (`open --stdout /tmp/kc.log
// build/keychain_check.app`): the login Keychain belongs to the logged-in
// session, and a binary started over ssh is not in it.

import "core:fmt"
import "core:os"
import "core:slice"
import "baldr:baldr"

SECRET :: "a device token and a 32-byte key walk into a keychain"

State :: struct {
	service: string,
	account: string,
	step:    int,
	bad:     int,
}

Msg :: union { Start, baldr.Secret }

Start :: struct {}

say :: proc(s: ^State, ok: bool, format: string, args: ..any) {
	if !ok do s.bad += 1
	fmt.eprintf("keychain: %s ", "ok  " if ok else "BAD ")
	fmt.eprintfln(format, ..args)
}

answered :: proc(e: baldr.Ev(baldr.Secret)) -> Msg { return e.value }

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch e in m {
	case Start:
		fmt.eprintfln("keychain: service %q, account %q", s.service, s.account)
		s.step = 1
		return baldr.secret_set(Msg, s.service, s.account, transmute([]u8)string(SECRET), answered)
	case baldr.Secret:
		switch s.step {
		case 1:
			say(s, e.status == .Ok, "set: %v %s", e.status, e.error)
			if e.status == .No_Keyring {
				fmt.eprintln("keychain: no keyring on this desktop; nothing more to check")
				return baldr.quit(Msg)
			}
			s.step = 2
			return baldr.secret_get(Msg, s.service, s.account, answered)
		case 2:
			same := e.status == .Ok && slice.equal(e.value, transmute([]u8)string(SECRET))
			say(s, same, "get: %v, %d bytes back%s", e.status, len(e.value),
				" (and they are what was stored)" if same else " — NOT what was stored")
			baldr.secret_scrub(e.value) // the bytes are not left in freed memory
			s.step = 3
			return baldr.secret_delete(Msg, s.service, s.account, answered)
		case 3:
			say(s, e.status == .Ok, "delete: %v %s", e.status, e.error)
			s.step = 4
			return baldr.secret_get(Msg, s.service, s.account, answered)
		case 4:
			say(s, e.status == .Not_Found, "get after delete: %v (it must be Not_Found)", e.status)
			fmt.eprintfln("keychain: %s", "all four answered as they should" if s.bad == 0 else "SOMETHING IS WRONG above")
			return baldr.quit(Msg)
		}
	}
	return {}
}

main :: proc() {
	s: State
	err := baldr.run(baldr.App(State, Msg){
		title = "Keychain check", app_id = "dev.baldr.keychain_check",
		init = proc() -> (s: State) {
			s.service = os.get_env("KEYCHAIN_SERVICE", context.allocator)
			s.account = os.get_env("KEYCHAIN_ACCOUNT", context.allocator)
			if s.service == "" do s.service = "dev.baldr.keychain_check"
			if s.account == "" do s.account = "check"
			return
		},
		start = proc(s: ^State) -> baldr.Cmd(Msg) { return baldr.delay(Msg, 1, Start{}) },
		update = update,
		// No surface is ever declared. An app with no `surfaces` proc
		// gets a default window, so saying nothing is not the same as
		// saying none: this appends nothing, and `keep_running` holds the
		// run instead.
		surfaces = proc(s: ^State, out: ^[dynamic]baldr.Surface_Desc(Msg)) {},
		keep_running = proc(s: ^State) -> bool { return true },
	})
	_ = s
	if baldr.run_failed(err) {
		fmt.eprintln("keychain_check: exit:", err)
		os.exit(1)
	}
}
