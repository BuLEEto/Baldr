#+build linux
package xdg

// Desktop notifications: org.freedesktop.Notifications, which every Linux
// desktop answers (GNOME, KDE, and the standalone daemons a wlroots desktop
// runs). It rides the session bus the portal already opened (portal.odin),
// so there is no second connection, thread or fd: replies and signals
// arrive in `dispatch`.
//
// The desktop owns what is shown and for how long. This passes the app's
// description on and reports what became of it; `Shown` means the desktop
// took it, not that anyone saw it.
//
// Two numbers name one notification: the app's `tag`, fixed, and the
// server's u32 `id` from Notify, which the signals carry. `notifs` maps
// between them. The id is unknown until the reply, so a close or replace
// in the meantime is marked and acted on then.

import "core:fmt"
import "core:strings"
import "baldr:dbus"
import "baldr:platform"

@(private = "file") NOTIFY_NAME  :: "org.freedesktop.Notifications"
@(private = "file") NOTIFY_PATH  :: "/org/freedesktop/Notifications"
@(private = "file") NOTIFY_IFACE :: "org.freedesktop.Notifications"

// The match rule is narrowed to the notification server's own signals, so
// the bus does not route us every notification on the session.
@(private = "file")
NOTIFY_MATCH :: "type='signal',interface='org.freedesktop.Notifications',path='/org/freedesktop/Notifications'"

// Notify_Entry is one notification the app has asked for. `id` is 0 until
// the server answers; `closing` and `replace` remember what the app asked
// for while it was still 0.
@(private)
Notify_Entry :: struct {
	tag:     u64,
	id:      u32,
	closing: bool,      // notify_close arrived before the id did
	replace: bool,      // a second notify for this tag arrived before the id did
	queued:  Notify_Saved, // …and this is what it said
}

// Notify_Saved owns its strings: the app's description is only borrowed for
// the length of the call.
@(private)
Notify_Saved :: struct {
	title, body, icon: string,
	actions:           []platform.Notify_Action,
	urgency:           platform.Notify_Urgency,
	timeout_ms:        i32,
}

// Notify_Req is one Notify call in flight.
@(private = "file")
Notify_Req :: struct {
	x:  ^Xdg,
	tag: u64,
}

// notify_init subscribes to the server's signals. The subscription is all
// that is set up here: there is no handshake, and a desktop with no
// notification server simply fails the first Notify.
@(private)
notify_init :: proc(x: ^Xdg) {
	if x.bus == nil do return
	if err := dbus.add_match(x.bus, NOTIFY_MATCH, PORTAL_TIMEOUT_MS); err != .None {
		debugf(x, "notifications: AddMatch failed (%v); actions and dismissals will not be heard", err)
		return
	}
	x.notify_action = dbus.on_signal(x.bus, NOTIFY_IFACE, "ActionInvoked", on_action_invoked, x, NOTIFY_PATH)
	x.notify_closed = dbus.on_signal(x.bus, NOTIFY_IFACE, "NotificationClosed", on_notification_closed, x, NOTIFY_PATH)
	x.notify_ready = true
	// Whether the server reads markup in a body: until it says, the body is
	// escaped, which shows `&amp;` at worst rather than running a message's links.
	caps := dbus.method_call(NOTIFY_NAME, NOTIFY_PATH, NOTIFY_IFACE, "GetCapabilities")
	dbus.call_async(x.bus, &caps, on_notify_caps, x)
}

@(private = "file")
on_notify_caps :: proc(conn: ^dbus.Connection, reply: ^dbus.Message, err: dbus.Error, user: rawptr) {
	x := (^Xdg)(user)
	if err != .None || reply == nil || len(reply.body) < 1 do return
	arr, ok := reply.body[0].(dbus.Array)
	if !ok do return
	markup := false
	for it in arr.items do if s, is := it.(string); is && s == "body-markup" do markup = true
	x.notify_plain = !markup
}

// notify_escape is a body as text in markup: what a message says is shown,
// never followed as a link or drawn as a picture.
@(private)
notify_escape :: proc(s: string) -> string {
	if strings.index_any(s, "&<>\"'") < 0 do return s
	b := strings.builder_make(context.temp_allocator)
	for r in s {
		switch r {
		case '&':  strings.write_string(&b, "&amp;")
		case '<':  strings.write_string(&b, "&lt;")
		case '>':  strings.write_string(&b, "&gt;")
		case '"':  strings.write_string(&b, "&quot;")
		case '\'': strings.write_string(&b, "&apos;")
		case:      strings.write_rune(&b, r)
		}
	}
	return strings.to_string(b)
}

@(private)
notify_shutdown :: proc(x: ^Xdg) {
	for &e in x.notifs do notify_saved_free(x, &e.queued)
	delete(x.notifs)
	x.notifs = nil
	x.notify_ready = false
}

@(private = "file")
notify_saved_free :: proc(x: ^Xdg, s: ^Notify_Saved) {
	delete(s.title, x.alloc)
	delete(s.body, x.alloc)
	delete(s.icon, x.alloc)
	for a in s.actions {
		delete(a.key, x.alloc)
		delete(a.label, x.alloc)
	}
	delete(s.actions, x.alloc)
	s^ = {}
}

@(private = "file")
notify_save :: proc(x: ^Xdg, d: platform.Notify_Desc) -> Notify_Saved {
	out := Notify_Saved{
		title      = strings.clone(d.title, x.alloc),
		body       = strings.clone(d.body, x.alloc),
		icon       = strings.clone(d.icon, x.alloc),
		urgency    = d.urgency,
		timeout_ms = d.timeout_ms,
	}
	if len(d.actions) > 0 {
		acts := make([]platform.Notify_Action, len(d.actions), x.alloc)
		for a, i in d.actions {
			acts[i] = {key = strings.clone(a.key, x.alloc), label = strings.clone(a.label, x.alloc)}
		}
		out.actions = acts
	}
	return out
}

@(private = "file")
notify_find :: proc(x: ^Xdg, tag: u64) -> int {
	for e, i in x.notifs do if e.tag == tag do return i
	return -1
}

@(private = "file")
notify_by_id :: proc(x: ^Xdg, id: u32) -> int {
	if id == 0 do return -1
	for e, i in x.notifs do if e.id == id do return i
	return -1
}

// notify shows `d`, or replaces what this tag is already showing
// (Backend.notify).
notify :: proc(x: ^Xdg, d: platform.Notify_Desc) -> bool {
	
	if x.bus == nil do return false
	if !x.notify_ready do notify_init(x) // the bus came up after the backend did
	if x.bus == nil do return false

	i := notify_find(x, d.tag)
	if i < 0 {
		append(&x.notifs, Notify_Entry{tag = d.tag})
		i = len(x.notifs) - 1
	} else if x.notifs[i].id == 0 {
		// No id to replace yet: keep the newest description and send it when
		// the id lands, rather than showing two and orphaning one.
		notify_saved_free(x, &x.notifs[i].queued)
		x.notifs[i].queued = notify_save(x, d)
		x.notifs[i].replace = true
		x.notifs[i].closing = false
		return true
	}
	return notify_send(x, i, d.tag, d, x.notifs[i].id)
}

// notify_send makes the call. `replaces` is 0 for a new notification.
@(private = "file")
notify_send :: proc(x: ^Xdg, i: int, tag: u64, d: platform.Notify_Desc, replaces: u32) -> bool {
	// actions go over the wire as a flat [key, label, key, label, …]
	flat := make([]dbus.Value, len(d.actions) * 2, context.temp_allocator)
	for a, k in d.actions {
		flat[k * 2], flat[k * 2 + 1] = dbus.Value(a.key), dbus.Value(a.label)
	}
	urgency := u8(0)
	switch d.urgency {
	case .Low:      urgency = 0
	case .Normal:   urgency = 1
	case .Critical: urgency = 2
	}
	hints := make([]dbus.Dict_Entry, 1, context.temp_allocator)
	hints[0] = {key = dbus.Value("urgency"), value = dbus.variant(dbus.Value(urgency), context.temp_allocator)}

	app := x.app_id if x.app_id != "" else "baldr"
	body := []dbus.Value{
		dbus.Value(app),
		dbus.Value(replaces),
		dbus.Value(d.icon),
		dbus.Value(d.title),
		dbus.Value(d.body if x.notify_plain else notify_escape(d.body)),
		dbus.Array{sig = "s", items = flat},
		dbus.Dict{key_sig = "s", value_sig = "v", entries = hints},
		dbus.Value(d.timeout_ms),
	}
	m := dbus.method_call(NOTIFY_NAME, NOTIFY_PATH, NOTIFY_IFACE, "Notify", body)
	req := new(Notify_Req, x.alloc)
	req^ = {x = x, tag = tag}
	if _, err := dbus.call_async(x.bus, &m, on_notify_reply, req); err != .None {
		free(req, x.alloc)
		notify_drop(x, i)
		why := fmt.tprintf("the session bus would not take it (%v)", err)
		push(x, platform.Ev_Notify{tag = tag, event = .Failed, error = strings.clone(why, x.text)})
		return true // the failure reaches the app as an event
	}
	return true
}

// on_notify_reply takes the server's id, or reports the failure. Runs
// inside dispatch, i.e. inside the pump.
@(private = "file")
on_notify_reply :: proc(conn: ^dbus.Connection, reply: ^dbus.Message, err: dbus.Error, user: rawptr) {
	req := (^Notify_Req)(user)
	x, tag := req.x, req.tag
	defer free(req, x.alloc)

	i := notify_find(x, tag)
	if err != .None || reply == nil || reply.type == .Error || len(reply.body) < 1 {
		why := dbus.error_text(reply) if reply != nil && reply.type == .Error else "no notification service on this desktop"
		if i >= 0 do notify_drop(x, i)
		push(x, platform.Ev_Notify{tag = tag, event = .Failed, error = strings.clone(why, x.text)})
		return
	}
	id, ok := dbus.as_u32(reply.body[0])
	if !ok || i < 0 {
		if i >= 0 do notify_drop(x, i)
		push(x, platform.Ev_Notify{tag = tag, event = .Failed, error = "the notification service answered with no id"})
		return
	}
	x.notifs[i].id = id
	debugf(x, "notification tag %d is the server's id %d", tag, id)
	push(x, platform.Ev_Notify{tag = tag, event = .Shown})

	// What the app asked for while the id was unknown, in the order it asked.
	if x.notifs[i].replace {
		q := x.notifs[i].queued
		x.notifs[i].replace = false
		x.notifs[i].queued = {}
		d := platform.Notify_Desc{
			tag = tag, title = q.title, body = q.body, icon = q.icon,
			actions = q.actions, urgency = q.urgency, timeout_ms = q.timeout_ms,
		}
		notify_send(x, i, tag, d, id)
		saved := q
		notify_saved_free(x, &saved)
		return
	}
	if x.notifs[i].closing do notify_close_id(x, id)
}

// notify_close takes back what `tag` is showing (Backend.notify_close).
notify_close :: proc(x: ^Xdg, tag: u64) {
	
	i := notify_find(x, tag)
	if i < 0 do return
	if x.notifs[i].id == 0 {
		x.notifs[i].closing = true // no id yet: closed the moment there is one
		x.notifs[i].replace = false
		notify_saved_free(x, &x.notifs[i].queued)
		return
	}
	notify_close_id(x, x.notifs[i].id)
}

@(private = "file")
notify_close_id :: proc(x: ^Xdg, id: u32) {
	if x.bus == nil do return
	body := []dbus.Value{dbus.Value(id)}
	m := dbus.method_call(NOTIFY_NAME, NOTIFY_PATH, NOTIFY_IFACE, "CloseNotification", body)
	m.flags = {.No_Reply_Expected}
	// The server answers with NotificationClosed either way, which is where
	// the app hears about it — so nothing is reported from here.
	_, _ = dbus.send(x.bus, &m)
}

@(private = "file")
notify_drop :: proc(x: ^Xdg, i: int) {
	if i < 0 || i >= len(x.notifs) do return
	notify_saved_free(x, &x.notifs[i].queued)
	ordered_remove(&x.notifs, i)
}

// on_action_invoked: the person chose the notification, or one of its
// buttons. The key "default" is the body itself, which most desktops make
// clickable without drawing a button; it reaches the app as an empty
// action, so "they chose this" is one case and not two.
@(private = "file")
on_action_invoked :: proc(conn: ^dbus.Connection, sig: ^dbus.Message, user: rawptr) {
	x := (^Xdg)(user)
	if len(sig.body) < 2 do return
	id, ok := dbus.as_u32(sig.body[0])
	if !ok do return
	i := notify_by_id(x, id)
	if i < 0 do return // someone else's notification, or one we have finished with
	key, _ := dbus.as_string(sig.body[1])
	if key == "default" do key = ""
	push(x, platform.Ev_Notify{tag = x.notifs[i].tag, event = .Activated, action = strings.clone(key, x.text)})
}

// on_notification_closed: it went away. The reasons are the spec's.
@(private = "file")
on_notification_closed :: proc(conn: ^dbus.Connection, sig: ^dbus.Message, user: rawptr) {
	x := (^Xdg)(user)
	if len(sig.body) < 2 do return
	id, ok := dbus.as_u32(sig.body[0])
	if !ok do return
	i := notify_by_id(x, id)
	if i < 0 do return
	raw, _ := dbus.as_u32(sig.body[1])
	reason: platform.Notify_Close_Reason
	switch raw {
	case 1:  reason = .Expired
	case 2:  reason = .Dismissed
	case 3:  reason = .By_App
	case:    reason = .Unknown
	}
	tag := x.notifs[i].tag
	notify_drop(x, i) // its id will not be seen again
	push(x, platform.Ev_Notify{tag = tag, event = .Closed, reason = reason})
}
