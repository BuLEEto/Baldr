package baldr

@(require) import "core:testing"
@(require) import "baldr:platform"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A render takes minutes and an export can take longer, and the run carries
// on with the window closed or behind others, so an app needs a way to say
// it is done that does not depend on being on screen.

@(private = "file")
Nf_Msg :: union { Notification }

@(private = "file")
nf_heard :: proc(e: Ev(Notification)) -> Nf_Msg { return e.value }

// Nf_Log records what the backend was asked to do.
@(private = "file")
Nf_Log :: struct {
	shown:  [dynamic]platform.Notify_Desc,
	closed: [dynamic]u64,
	refuse: bool,
}

@(private = "file")
nf_backend :: proc(log: ^Nf_Log) -> platform.Backend {
	b := platform.Backend{data = log}
	b.notify = proc(b: ^platform.Backend, d: platform.Notify_Desc) -> bool {
		lg := (^Nf_Log)(b.data)
		if lg.refuse do return false
		append(&lg.shown, d)
		return true
	}
	b.notify_close = proc(b: ^platform.Backend, tag: u64) {
		append(&(^Nf_Log)(b.data).closed, tag)
	}
	return b
}

@(private = "file")
nf_free :: proc(rt: ^Runtime(int, Nf_Msg), log: ^Nf_Log) {
	delete(log.shown)
	delete(log.closed)
	for str in rt.spent_asks do delete(str)
	delete(rt.spent_asks)
	delete(rt.notify_watches)
	delete(rt.msgs)
}

// The whole life of one notification, in the order it happens: the desktop
// takes it, the person chooses an action, and it goes away.
@(test)
a_notification_reports_every_step_of_its_life :: proc(t: ^testing.T) {
	log: Nf_Log
	b := nf_backend(&log)
	rt: Runtime(int, Nf_Msg)
	rt.backend = &b
	defer nf_free(&rt, &log)

	acts := []Notify_Action{{"show", "Show me"}}
	run_cmd(&rt, notify(Nf_Msg, "Render finished", "kitchen.png", actions = acts, tag = 7, on_event = nf_heard))
	if !testing.expect_value(t, len(log.shown), 1) do return
	testing.expect_value(t, log.shown[0].tag, 7)
	testing.expect_value(t, log.shown[0].title, "Render finished")
	testing.expect_value(t, log.shown[0].body, "kitchen.png")
	testing.expect_value(t, len(rt.msgs), 0) // nothing said until the desktop answers

	notify_deliver(&rt, platform.Ev_Notify{tag = 7, event = .Shown})
	if testing.expect_value(t, len(rt.msgs), 1) {
		n := rt.msgs[0].(Notification)
		testing.expect_value(t, n.event, Notify_Event.Shown)
		testing.expect_value(t, n.tag, 7)
	}
	clear(&rt.msgs)

	notify_deliver(&rt, platform.Ev_Notify{tag = 7, event = .Activated, action = "show"})
	if testing.expect_value(t, len(rt.msgs), 1) {
		n := rt.msgs[0].(Notification)
		testing.expect_value(t, n.event, Notify_Event.Activated)
		testing.expect_value(t, n.action, "show")
	}
	clear(&rt.msgs)

	notify_deliver(&rt, platform.Ev_Notify{tag = 7, event = .Closed, reason = .Dismissed})
	if testing.expect_value(t, len(rt.msgs), 1) {
		n := rt.msgs[0].(Notification)
		testing.expect_value(t, n.event, Notify_Event.Closed)
		testing.expect_value(t, n.reason, Notify_Close_Reason.Dismissed)
	}
}

// A command is run after the update that wrote it has returned, so nothing
// it carries may point into that update's stack. `actions` is where this
// bites, because the natural way to write them is a literal in the call,
// and that slice is gone by the time the backend reads it.
@(test)
a_notifications_actions_do_not_point_at_the_callers_stack :: proc(t: ^testing.T) {
	made: Cmd(Nf_Msg)
	{
		// a scope that goes away, exactly as an update's does
		acts := []Notify_Action{{"show", "Show me"}, {"again", "Render again"}}
		made = notify(Nf_Msg, "Render finished", "kitchen.png", actions = acts, tag = 3)
		testing.expect(t, raw_data(made.notice.actions) != raw_data(acts), "the slice was copied, not borrowed")
		testing.expect(t, raw_data(made.notice.actions[0].key) != raw_data(acts[0].key), "…and so were its strings")
	}
	if !testing.expect_value(t, len(made.notice.actions), 2) do return
	testing.expect_value(t, made.notice.actions[0].key, "show")
	testing.expect_value(t, made.notice.actions[1].label, "Render again")
	testing.expect_value(t, made.notice.title, "Render finished")
	testing.expect_value(t, made.notice.body, "kitchen.png")
}

// A desktop with no notifications must not leave the app in silence: it
// hears Failed at once, in the same update, and can say it in its window
// instead.
@(test)
a_desktop_that_cannot_notify_says_so_at_once :: proc(t: ^testing.T) {
	log := Nf_Log{refuse = true}
	b := nf_backend(&log)
	rt: Runtime(int, Nf_Msg)
	rt.backend = &b
	defer nf_free(&rt, &log)

	run_cmd(&rt, notify(Nf_Msg, "Render finished", tag = 1, on_event = nf_heard))
	if testing.expect_value(t, len(rt.msgs), 1) {
		n := rt.msgs[0].(Notification)
		testing.expect_value(t, n.event, Notify_Event.Failed)
		testing.expect(t, len(n.error) > 0, "…and says why")
	}

	// No backend at all is the same answer, not a crash.
	rt2: Runtime(int, Nf_Msg)
	rt2.spent_asks = make([dynamic]string)
	defer { delete(rt2.msgs); delete(rt2.notify_watches); for s in rt2.spent_asks do delete(s); delete(rt2.spent_asks) }
	run_cmd(&rt2, notify(Nf_Msg, "Render finished", tag = 1, on_event = nf_heard))
	testing.expect_value(t, len(rt2.msgs), 1)
}

// A notification that has failed or closed is finished with, and its
// handler goes with it — an app that notifies all day should not grow a
// table of the dead.
@(test)
a_finished_notification_is_not_kept :: proc(t: ^testing.T) {
	log: Nf_Log
	b := nf_backend(&log)
	rt: Runtime(int, Nf_Msg)
	rt.backend = &b
	defer nf_free(&rt, &log)

	for tag in u64(1) ..= 3 do run_cmd(&rt, notify(Nf_Msg, "job", tag = tag, on_event = nf_heard))
	testing.expect_value(t, len(rt.notify_watches), 3)

	notify_deliver(&rt, platform.Ev_Notify{tag = 1, event = .Shown})
	testing.expect_value(t, len(rt.notify_watches), 3) // still live: more can happen to it
	notify_deliver(&rt, platform.Ev_Notify{tag = 1, event = .Closed, reason = .Expired})
	testing.expect_value(t, len(rt.notify_watches), 2)
	notify_deliver(&rt, platform.Ev_Notify{tag = 2, event = .Failed, error = "no"})
	testing.expect_value(t, len(rt.notify_watches), 1)

	// …and a straggler about a tag already finished with says nothing at all
	clear(&rt.msgs)
	notify_deliver(&rt, platform.Ev_Notify{tag = 1, event = .Activated})
	testing.expect_value(t, len(rt.msgs), 0)
}

// The same tag twice replaces, rather than stacking — and the newest sender
// is who hears about it.
@(test)
the_same_tag_replaces_and_answers_to_whoever_sent_it_last :: proc(t: ^testing.T) {
	log: Nf_Log
	b := nf_backend(&log)
	rt: Runtime(int, Nf_Msg)
	rt.backend = &b
	defer nf_free(&rt, &log)

	run_cmd(&rt, notify(Nf_Msg, "Rendering… 10%", tag = 4, on_event = nf_heard))
	run_cmd(&rt, notify(Nf_Msg, "Rendering… 90%", tag = 4, on_event = nil))
	testing.expect_value(t, len(log.shown), 2)          // the backend is told twice…
	testing.expect_value(t, len(rt.notify_watches), 1)  // …but it is one notification

	clear(&rt.msgs)
	notify_deliver(&rt, platform.Ev_Notify{tag = 4, event = .Shown})
	testing.expect_value(t, len(rt.msgs), 0) // the second sender wanted no answer
}

// Choosing a notification and waving it away are different answers: the
// body arrives as an Activated with an empty action, a dismissal as a
// Closed. An app that treated them alike would interrupt twice.
@(test)
choosing_a_notification_is_not_the_same_as_dismissing_it :: proc(t: ^testing.T) {
	log: Nf_Log
	b := nf_backend(&log)
	rt: Runtime(int, Nf_Msg)
	rt.backend = &b
	defer nf_free(&rt, &log)

	run_cmd(&rt, notify(Nf_Msg, "Export finished", tag = 5, on_event = nf_heard))
	notify_deliver(&rt, platform.Ev_Notify{tag = 5, event = .Activated, action = ""})
	if testing.expect_value(t, len(rt.msgs), 1) {
		n := rt.msgs[0].(Notification)
		testing.expect_value(t, n.event, Notify_Event.Activated)
		testing.expect_value(t, n.action, "") // the notification itself, not a button
	}
	clear(&rt.msgs)
	notify_deliver(&rt, platform.Ev_Notify{tag = 5, event = .Closed, reason = .Dismissed})
	n := rt.msgs[0].(Notification)
	testing.expect(t, n.event != Notify_Event.Activated, "a dismissal is not a choice")
}

// notify_close reaches the backend, and a tag that is not showing is not an
// error.
@(test)
an_app_can_take_a_notification_back :: proc(t: ^testing.T) {
	log: Nf_Log
	b := nf_backend(&log)
	rt: Runtime(int, Nf_Msg)
	rt.backend = &b
	defer nf_free(&rt, &log)

	run_cmd(&rt, notify(Nf_Msg, "Downloading", tag = 9, on_event = nf_heard))
	run_cmd(&rt, notify_close(Nf_Msg, 9))
	testing.expect_value(t, len(log.closed), 1)
	testing.expect_value(t, log.closed[0], 9)

	run_cmd(&rt, notify_close(Nf_Msg, 404)) // never shown: not an error
	testing.expect_value(t, len(log.closed), 2)
}

}
