// xdg_text — do the strings inside a desktop event arrive intact from
// platform/xdg?
//
// They are allocated from one `runtime.Allocator` snapshotted into
// `Xdg.text` at init: `virtual.arena_allocator(&st.text_arena)`, a pure
// function of a pointer into a heap allocation that never moves. A wrong
// allocator here would show up as a corrupt string in an event rather than
// a crash, so this checks it with a run.
//
// So: send a notification, have the bus hand an action back, and print the
// action string the app receives. No window interaction at all — the
// notification goes out from `start`, and the reply comes over the session
// bus.
//
//   ./build.sh spike xdg_text run
//   # then, with the id it prints:
//   gdbus emit --session --object-path /org/freedesktop/Notifications \
//     --signal org.freedesktop.Notifications.ActionInvoked <id> 'the-key'
//
// Expected: `action "the-key"` — the exact string, not empty and not
// rubbish. `.Failed` proves the same allocator by another route (its
// `error` is allocated the same way), so either answer is a pass as long
// as the text is intact.
package main

import "core:fmt"
import "core:os"
import "baldr:baldr"

TAG :: 4242

State :: struct { said: string, seen: int }

Msg :: union { Heard, Give_Up }
Heard   :: struct { n: baldr.Notification }
Give_Up :: struct {}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "xdg text", app_id = "baldr.xdgtext", size = {420, 140},
		init = proc() -> State { return {said = "waiting"} },
		start = proc(s: ^State) -> baldr.Cmd(Msg) {
			// Named with its type: a nested literal inferred through the
			// parameter costs the compiler minutes.
			acts := []baldr.Notify_Action{{"the-key", "A label with spaces"}}
			return baldr.notify(Msg, "xdg_text", "checking the string allocator",
				actions = acts, tag = TAG,
				on_event = proc(e: baldr.Ev(baldr.Notification)) -> Msg { return Heard{e.value} })
		},
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			switch v in m {
			case Heard:
				n := v.n
				s.seen += 1
				switch n.event {
				case .Shown:
					fmt.printfln("shown   tag=%d", n.tag)
					fmt.println("now: gdbus emit --session --object-path /org/freedesktop/Notifications \\")
					fmt.println("       --signal org.freedesktop.Notifications.ActionInvoked <id> 'the-key'")
					os.flush(os.stdout)
				case .Activated:
					fmt.printfln("action %q  (len %d)", n.action, len(n.action))
					s.said = fmt.aprintf("action %q", n.action)
					os.flush(os.stdout)
					return baldr.quit(Msg)
				case .Failed:
					fmt.printfln("failed %q  (len %d)", n.error, len(n.error))
					os.flush(os.stdout)
					return baldr.quit(Msg)
				case .Closed:
					fmt.printfln("closed  reason=%v", n.reason)
					os.flush(os.stdout)
					return baldr.quit(Msg)
				}
			case Give_Up:
				fmt.println("nothing arrived")
				return baldr.quit(Msg)
			}
			return {}
		},
		subscriptions = proc(s: ^State, out: ^[dynamic]baldr.Sub(Msg)) {
			append(out, baldr.every(Msg, 60000, Give_Up{}))
		},
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			baldr.column(ui, flex = 1, padding = .lg, gap = .sm); defer baldr.end(ui)
			baldr.text(ui, "xdg text", role = .Headline)
			baldr.text(ui, s.said, muted = true)
		},
	})
}
