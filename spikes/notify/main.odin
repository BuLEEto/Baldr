// notify: does a notification actually reach the desktop, and does
// everything that happens to it afterwards reach the app?
//
// The parts that can only be judged live: the Notify call marshals (the
// signature is `susssasa{sv}i`, and one wrong type is a silent refusal),
// the server's u32 id maps back to the app's tag, and the signals it sends
// minutes later still find the right handler.
//
//   ./build.sh spike notify run
//
// Expect Shown, then Activated carrying the action key, then Closed /
// By_App; a second notify on the same tag replaces the first rather than
// stacking. The `actions` literal below is a slice of this proc's stack,
// which is why baldr/notify.odin copies it: the command runs later.
//
// It sends one notification with an action, prints every event it hears,
// replaces it after 2 s, takes it back after 4 s, and quits at 8 s. To
// check the action path without clicking, emit the signal by hand with the
// id it prints:
//
//   gdbus emit --session --object-path /org/freedesktop/Notifications \
//     --signal org.freedesktop.Notifications.ActionInvoked <id> "show"
package main

import "core:fmt"
import "baldr:baldr"

TAG :: 42

State :: struct { step: int }

Msg :: union { Heard, Replace, Take_Back, Done }
Heard     :: struct { n: baldr.Notification }
Replace   :: struct {}
Take_Back :: struct {}
Done      :: struct {}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "notify", app_id = "baldr.notifyspike", size = {420, 200},
		init = proc() -> State { return {} },
		start = proc(s: ^State) -> baldr.Cmd(Msg) {
			fmt.println("--- sending, tag", TAG)
			acts := []baldr.Notify_Action{{"show", "Show me"}, {"again", "Render again"}}
			return baldr.batch(Msg,
				baldr.notify(Msg, "Render finished", "kitchen.png — 4m 12s",
					actions = acts, icon = "image-x-generic", tag = TAG,
					on_event = proc(e: baldr.Ev(baldr.Notification)) -> Msg { return Heard{e.value} }),
				baldr.delay(Msg, 2000, Replace{}),
				baldr.delay(Msg, 4000, Take_Back{}),
				baldr.delay(Msg, 8000, Done{}),
			)
		},
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			switch v in m {
			case Heard:
				n := v.n
				fmt.printfln("  heard: tag %d  %v  action %q  reason %v  error %q",
					n.tag, n.event, n.action, n.reason, n.error)
			case Replace:
				fmt.println("--- replacing the same tag: one notification, not two")
				return baldr.notify(Msg, "Render finished", "kitchen.png — now with a second line",
					tag = TAG, on_event = proc(e: baldr.Ev(baldr.Notification)) -> Msg { return Heard{e.value} })
			case Take_Back:
				fmt.println("--- taking it back (expect Closed / By_App)")
				return baldr.notify_close(Msg, TAG)
			case Done:
				fmt.println("--- done")
				return baldr.quit(Msg)
			}
			return {}
		},
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			baldr.column(ui, flex = 1, padding = .lg, gap = .sm); defer baldr.end(ui)
			baldr.text(ui, "notify spike", role = .Headline)
			baldr.text(ui, "Watch the terminal; the notification is on your desktop.", muted = true)
		},
	})
}
