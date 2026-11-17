#+build linux
// The desktop's own services, shared by every Linux backend.
//
// This is the part of a Linux backend that is not about Wayland or X11 at
// all: the Settings portal (theme, accent, contrast), desktop
// notifications, opening links and files, the file chooser, and the locale.
// It speaks D-Bus and libc, and a window system never comes into it — so
// Wayland and X11 use one copy of it rather than two that drift.
//
// A backend owns an `Xdg`, fills in the fields under "what the backend
// provides", calls `init` and `shutdown` around its own, adds `x.bus`'s
// descriptor to its poll set, and calls `dispatch` when that descriptor is
// readable and `poll` once per pump. Everything else here is one of the
// Backend procs, taking `^Xdg` instead of `^platform.Backend` so it owes
// the window system nothing.
//
// Everything degrades when there is no session bus: `theme` reports light /
// no accent / text_scale 1, `file_dialog` and `notify` answer false, and
// `open_url` / `open_path` fall back to `xdg-open`.
package xdg

import "base:runtime"
import "core:fmt"
import "baldr:dbus"
import "baldr:platform"
import portal "baldr:sys/portal"

// PORTAL_TIMEOUT_MS bounds the blocking calls made to the bus itself during
// init (Hello, AddMatch). The portal's own answer is not waited on this long:
// see SETTINGS_FIRST_WAIT_MS.
PORTAL_TIMEOUT_MS :: i32(2000)

// Xdg is what the desktop services need from the backend hosting them, plus
// the state they keep of their own. Zero value is valid: it behaves as a
// session with no bus.
Xdg :: struct {
	// ---- what the backend provides, before `init` ----

	// events is the backend's pending queue. Everything here reports by
	// appending a platform.Event to it, exactly as the backend's own code
	// does, and the app sees it on the next pump.
	events: ^[dynamic]platform.Event,
	// alloc is for anything outliving a pump: the notification table and the
	// descriptions saved in it.
	alloc:  runtime.Allocator,
	// text is memory for strings *inside* events — the backend's per-pump
	// arena, so a string lives until the pump after the one that made it.
	// Snapshot an allocator over a stable arena; it is copied by value.
	text:   runtime.Allocator,
	// app_id is the app's id as the desktop knows it; a notification is
	// signed with it. Owned by the backend, which may set it after `init`
	// (the first surface's id is what Wayland has to go on). Empty means
	// "baldr".
	app_id: string,
	// debug turns on the same tracing as BALDR_WAYLAND_DEBUG / BALDR_X11_DEBUG.
	debug:  bool,
	// the screen held on for this app, where the desktop listens for it
	// (idle.odin)
	idle:   Idle,

	// ---- the session bus, shared by everything below (portal.odin) ----

	bus:            ^dbus.Connection, // nil when there is none
	settings_sub:   ^portal.Settings_Subscription,
	appearance:     portal.Appearance,
	has_appearance: bool,

	// ---- notifications (notify.odin) ----

	notifs:        [dynamic]Notify_Entry,
	notify_action: dbus.Handler_Id,
	notify_closed: dbus.Handler_Id,
	notify_ready:  bool,
	notify_plain:  bool, // the server said it shows no markup: the body goes as it is (otherwise it is escaped)

	// ---- openers still running (open_url.odin) ----

	url_children: [dynamic]Url_Child,

	// ---- the tray (tray.odin) ----

	tray:       [dynamic]Tray_Entry,
	tray_watch: dbus.Handler_Id, // the watcher coming and going
}

// init opens the session bus, subscribes to appearance changes and to the
// notification server's signals. Never fails: on any error the backend
// simply has no bus, and everything here degrades.
init :: proc(x: ^Xdg) {
	portal_init(x)
	notify_init(x) // rides the portal's bus
	tray_init(x)   // …and so does the tray
}

// shutdown reaps the openers still running, unsubscribes and closes the bus.
// Safe on an Xdg that never had one.
shutdown :: proc(x: ^Xdg) {
	url_children_drop(x)
	tray_shutdown(x)
	notify_shutdown(x)
	portal_shutdown(x)
}

// poll is the once-per-pump tick: it asks after the `xdg-open`s still
// running without waiting on any of them.
poll :: proc(x: ^Xdg) {
	url_children_poll(x)
}

// push queues an event for the app, as the backend's own push does.
@(private)
push :: proc(x: ^Xdg, ev: platform.Event) {
	if x.events != nil do append(x.events, ev)
}

@(private)
debugf :: proc(x: ^Xdg, format: string, args: ..any) {
	if !x.debug do return
	fmt.eprintf("baldr/xdg: ")
	fmt.eprintfln(format, ..args)
}
