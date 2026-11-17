package baldr

// Desktop notifications: what an app says when the person is not looking
// at it, such as a long job finishing with the window behind others.
//
// A notification is the desktop's, not the app's: the desktop decides
// whether to show it, where and for how long, and the person's settings
// win. `Shown` means the desktop took it, not that anybody saw it.
//
// The app names each notification with a `tag` of its own, which comes
// back with everything that happens to it. A second notification with the
// same tag replaces the first in place, so a progress or "now playing"
// notification updates without piling up.

import "core:strings"
import "baldr:platform"

Notify_Urgency      :: platform.Notify_Urgency
Notify_Action       :: platform.Notify_Action
Notify_Event        :: platform.Notify_Event
Notify_Close_Reason :: platform.Notify_Close_Reason
Notify_Desc         :: platform.Notify_Desc

// Notification is what became of one. `event` says which of four things
// happened; `action` is the key of the button the person chose, empty for
// the notification itself; `reason` says why a Closed one closed; `error`
// says why a Failed one failed. Activated means the person wants what it
// offers; Closed means they waved it away, so do not act on both.
// `action` and `error` are the frame's: copy what you keep.
Notification :: struct {
	tag:    u64,
	event:  Notify_Event,
	action: string,
	reason: Notify_Close_Reason,
	error:  string,
}

// notify asks the desktop to show a notification and reports back through
// `on_event`: Shown or Failed first, then Activated if the person chooses
// it, then Closed when it goes away. A backend without notifications
// answers Failed at once, so the app can say it in its window instead.
//
// `actions` are its buttons: each `key` comes back in `Notification.action`.
// A click on the notification itself is an Activated with an empty action,
// on every desktop. `tag` names it for `notify_close` and for replacing it;
// the default 0 is a tag like any other, so two untagged notifications
// replace each other. `icon` is a desktop icon-theme name (the app's own
// when empty); `timeout_ms` is -1 for the desktop's choice and 0 for
// "until dismissed", both advisory.
//
// Do not make `Activated` the only way to the result: Windows ignores
// actions (its balloons have no buttons) and may not deliver the click
// (platform/win32/notify.odin). Everything passed is copied, so an
// `actions` literal in the call is safe.
//
//	baldr.notify(Msg, "Render finished", s.file,
//	    actions = []baldr.Notify_Action{{"show", "Show me"}},
//	    on_event = proc(e: baldr.Ev(baldr.Notification)) -> Msg { return Notified{e.value} })
notify :: proc($Msg: typeid, title: string, body: string = "", actions: []Notify_Action = nil,
	icon: string = "", urgency: Notify_Urgency = .Normal, timeout_ms: i32 = -1,
	tag: u64 = 0, on_event: Handler(Msg, Notification) = nil) -> Cmd(Msg) {
	// A command runs after `update` (or `start`) returns, so everything it
	// carries is copied into the frame's memory, as `batch` does. An
	// `actions` literal in the call is a slice of the caller's stack, gone
	// by the time the backend reads it.
	acts: []Notify_Action
	if len(actions) > 0 {
		acts = make([]Notify_Action, len(actions), context.temp_allocator)
		for a, i in actions {
			acts[i] = {
				key   = strings.clone(a.key, context.temp_allocator),
				label = strings.clone(a.label, context.temp_allocator),
			}
		}
	}
	return {
		kind = .Notify,
		notice = Notify_Desc{
			tag     = tag,
			title   = strings.clone(title, context.temp_allocator),
			body    = strings.clone(body, context.temp_allocator),
			icon    = strings.clone(icon, context.temp_allocator),
			actions = acts,
			urgency = urgency, timeout_ms = timeout_ms,
		},
		on_notify = on_event,
	}
}

// notify_close takes back the notification `tag` is showing. A tag that is
// not showing is not an error. The app hears a Closed with reason
// `By_App`, so every way a notification goes away arrives in one place.
notify_close :: proc($Msg: typeid, tag: u64) -> Cmd(Msg) {
	return {kind = .Notify_Close, notice = Notify_Desc{tag = tag}}
}

// Notify_Watch is an app's handler for one tag, kept until that tag is done
// with. A notification outlives the update that sent it — the person may
// choose it minutes later — so the handler cannot live on the command.
@(private)
Notify_Watch :: struct($Msg: typeid) {
	tag:     u64,
	on_done: Handler(Msg, Notification),
}

// notify_start runs the Notify command.
@(private)
notify_start :: proc(rt: ^Runtime($State, $Msg), cmd: Cmd(Msg)) {
	b := rt.backend
	notify_watch(rt, cmd.notice.tag, cmd.on_notify)
	if b == nil || b.notify == nil || !b.notify(b, cmd.notice) {
		notify_deliver(rt, platform.Ev_Notify{
			tag = cmd.notice.tag, event = .Failed,
			error = "this desktop has no notifications",
		})
	}
}

// notify_close_start runs the Notify_Close command.
@(private)
notify_close_start :: proc(rt: ^Runtime($State, $Msg), cmd: Cmd(Msg)) {
	b := rt.backend
	if b == nil || b.notify_close == nil do return
	b.notify_close(b, cmd.notice.tag)
}

// notify_watch remembers who to tell about `tag`, replacing any handler the
// tag already had — a replaced notification answers to whoever sent the
// newest one.
@(private)
notify_watch :: proc(rt: ^Runtime($State, $Msg), tag: u64, on_done: Handler(Msg, Notification)) {
	for &w in rt.notify_watches do if w.tag == tag {
		w.on_done = on_done
		return
	}
	append(&rt.notify_watches, Notify_Watch(Msg){tag = tag, on_done = on_done})
}

// notify_deliver turns an Ev_Notify into the app's message. A Failed or
// Closed notification is finished with, so its handler is dropped and the
// table does not grow over a long run.
@(private)
notify_deliver :: proc(rt: ^Runtime($State, $Msg), e: platform.Ev_Notify) {
	found := -1
	for w, i in rt.notify_watches do if w.tag == e.tag { found = i; break }
	if found < 0 do return // not ours, or already finished with
	on_done := rt.notify_watches[found].on_done
	if e.event == .Failed || e.event == .Closed do ordered_remove(&rt.notify_watches, found)

	// The strings are the backend's and live only until its next pump, so
	// they are copied and freed after the update that receives them has
	// run, as a link's are (url.odin).
	action, why := e.action, e.error
	if len(action) > 0 {
		action = strings.clone(action)
		append(&rt.spent_asks, action)
	}
	if len(why) > 0 {
		why = strings.clone(why)
		append(&rt.spent_asks, why)
	}
	handler_deliver(on_done, Notification{
		tag = e.tag, event = e.event, action = action, reason = e.reason, error = why,
	}, e.tag, &rt.msgs)
}
