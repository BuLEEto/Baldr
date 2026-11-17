// keychain — the secret commands against the desktop's own keyring: store a
// token, read it back, delete it, and check it is gone. Then the part that
// matters for a locked keyring: six calls asked for at once, and the order
// they come back in. Keychain calls take their turn, so the answers arrive
// in the order they were asked and each get reads what its own set wrote —
// which is what lets an app ask for all its secrets at once and be prompted
// once. It writes "baldr-spike"/"probe" and three "queue-N" entries, and
// removes every one of them before quitting.
//
//   ./build.sh spike keychain run
package main

import "core:fmt"
import "core:os"
import "baldr:baldr"

TOKEN :: "sk-not-a-real-token-0123456789"

ACCOUNTS :: [3]string{"queue-1", "queue-2", "queue-3"}

State :: struct {
	order:    [dynamic]string, // how the six answers actually came back
	cleaning: int,             // deletes still to answer at the end
	bad:      bool,
}

Msg :: union { Stored, Got, Deleted, Gone, Queued, Swept }
Stored  :: struct { secret: baldr.Secret }
Got     :: struct { secret: baldr.Secret }
Deleted :: struct { secret: baldr.Secret }
Gone    :: struct { secret: baldr.Secret }
Queued  :: struct { account: string, kind: string, value: string, status: baldr.Secret_Status }
Swept   :: struct {}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "keychain", app_id = "baldr.keychain", size = {360, 120},
		init = proc() -> State { return {} },
		start = proc(s: ^State) -> baldr.Cmd(Msg) {
			fmt.println("storing…")
			return baldr.secret_set(Msg, "baldr-spike", "probe", transmute([]u8)string(TOKEN),
				on_done = proc(e: baldr.Ev(baldr.Secret)) -> Msg { return Stored{e.value} })
		},
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			switch v in m {
			case Stored:
				fmt.printfln("stored:  %v  %s", v.secret.status, v.secret.error)
				if v.secret.status != .Ok do os.exit(1)
				return baldr.secret_get(Msg, "baldr-spike", "probe",
					proc(e: baldr.Ev(baldr.Secret)) -> Msg { return Got{e.value} })
			case Got:
				got := v.secret
				fmt.printfln("read:    %v  %q", got.status, string(got.value))
				if got.status != .Ok || string(got.value) != TOKEN do os.exit(2)
				baldr.secret_scrub(&got)
				return baldr.secret_delete(Msg, "baldr-spike", "probe",
					on_done = proc(e: baldr.Ev(baldr.Secret)) -> Msg { return Deleted{e.value} })
			case Deleted:
				fmt.printfln("deleted: %v  %s", v.secret.status, v.secret.error)
				if v.secret.status != .Ok do os.exit(3)
				return baldr.secret_get(Msg, "baldr-spike", "probe",
					proc(e: baldr.Ev(baldr.Secret)) -> Msg { return Gone{e.value} })
			case Gone:
				fmt.printfln("after:   %v  (expected Not_Found)", v.secret.status)
				if v.secret.status != .Not_Found do os.exit(4)

				// Six at once. In the order asked, each set is on the keyring
				// before the get that reads it; run together, a get could
				// easily win the race and read nothing.
				fmt.println("\nsix calls asked for at once:")
				s.order = make([dynamic]string)
				cmds: [6]baldr.Cmd(Msg)
				for a, i in ACCOUNTS {
					cmds[i] = baldr.secret_set(Msg, "baldr-spike", a, transmute([]u8)a,
						on_done = proc(e: baldr.Ev(baldr.Secret)) -> Msg {
							return Queued{e.value.account, "set", "", e.value.status}
						})
				}
				for a, i in ACCOUNTS {
					cmds[3 + i] = baldr.secret_get(Msg, "baldr-spike", a,
						proc(e: baldr.Ev(baldr.Secret)) -> Msg {
							return Queued{e.value.account, "get", string(e.value.value), e.value.status}
						})
				}
				return baldr.batch(Msg, ..cmds[:])

			case Queued:
				step := fmt.aprintf("%s %s", v.kind, v.account)
				append(&s.order, step)
				fmt.printfln("  %-12s %v  %q", step, v.status, v.value)
				if v.status != .Ok do s.bad = true
				if v.kind == "get" && v.value != v.account do s.bad = true // a get that did not read its own set
				if len(s.order) < 6 do return {}

				want := [6]string{"set queue-1", "set queue-2", "set queue-3", "get queue-1", "get queue-2", "get queue-3"}
				for w, i in want do if s.order[i] != w {
					fmt.printfln("out of order: wanted %v, got %v", want, s.order[:])
					s.bad = true
				}
				fmt.println(s.bad ? "\nOUT OF ORDER" : "\nsix calls, answered in the order they were asked")

				s.cleaning = len(ACCOUNTS)
				sweep: [3]baldr.Cmd(Msg)
				for a, i in ACCOUNTS {
					sweep[i] = baldr.secret_delete(Msg, "baldr-spike", a,
						on_done = proc(e: baldr.Ev(baldr.Secret)) -> Msg { return Swept{} })
				}
				return baldr.batch(Msg, ..sweep[:])

			case Swept:
				s.cleaning -= 1
				if s.cleaning > 0 do return {}
				fmt.println("tidied up")
				os.exit(5 if s.bad else 0)
			}
			return {}
		},
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			baldr.column(ui, padding = .lg); {
				defer baldr.end(ui)
				baldr.text(ui, "Talking to the keyring…")
			}
		},
	})
}
