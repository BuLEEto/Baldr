#+build linux
// This backend's side of the desktop services (platform/xdg).
//
// The theme, notifications, opening links and files, the file chooser and
// the locale are D-Bus and libc, not X, and shared with the Wayland
// backend. This file is what they need from here, and the Backend procs
// that hand a call through.
package x11

import "core:fmt"
import "baldr:dbus"
import "baldr:platform"
import "baldr:platform/xdg"

// xdg_start tells the desktop services where to put events and which memory
// to use, then opens the session bus. Called in init once `queue`, the text
// arena and `debug` are in place.
@(private)
xdg_start :: proc(x: ^X11) {
	x.xdg.events = &x.queue
	x.xdg.alloc = x.allocator
	x.xdg.text = text_allocator(x)
	x.xdg.debug = x.debug
	x.xdg.app_id = "baldr" // X has no equivalent of Wayland's first-toplevel id
	xdg.init(&x.xdg)
}

@(private)
xdg_stop :: proc(x: ^X11) {
	xdg.shutdown(&x.xdg)
}

// xdg_dispatch drains the bus, and is the once-per-pump tick for the
// openers still running.
@(private)
xdg_dispatch :: proc(x: ^X11) {
	xdg.dispatch(&x.xdg)
	xdg.poll(&x.xdg)
}

@(private)
system_theme :: proc(b: ^platform.Backend) -> platform.Ev_Theme {
	return xdg.theme(&data(b).xdg)
}

@(private)
locale :: proc(b: ^platform.Backend) -> platform.Locale {
	return data(b).locale
}

@(private)
open_url :: proc(b: ^platform.Backend, url: string, token: u64) -> bool {
	return xdg.open_url(&data(b).xdg, url, token)
}

@(private)
open_path :: proc(b: ^platform.Backend, path: string, reveal: bool, token: u64) -> bool {
	return xdg.open_path(&data(b).xdg, path, reveal, token)
}

@(private)
notify :: proc(b: ^platform.Backend, d: platform.Notify_Desc) -> bool {
	return xdg.notify(&data(b).xdg, d)
}

@(private)
notify_close :: proc(b: ^platform.Backend, tag: u64) {
	xdg.notify_close(&data(b).xdg, tag)
}

@(private)
tray_set :: proc(b: ^platform.Backend, t: platform.Tray_Desc) -> bool {
	return xdg.tray_set(&data(b).xdg, t)
}

@(private)
tray_remove :: proc(b: ^platform.Backend, tag: u64) {
	xdg.tray_remove(&data(b).xdg, tag)
}

// file_dialog asks the FileChooser portal for the desktop's own dialog; the
// answer arrives through the pump as an Ev_Files. False when there is no
// bus (the toolkit answers the command with ok = false).
//
// The parent goes as "x11:<id in hex>": the window with the keyboard, else
// the first. Without it the dialog is not transient for the app, and a
// window manager that prevents focus stealing may stack it out of sight.
file_dialog :: proc(b: ^platform.Backend, d: platform.File_Dialog) -> bool {
	x := data(b)
	parent := ""
	pick: ^Surface
	for s in x.surfaces do if s != nil && s.focused { pick = s; break }
	if pick == nil do for s in x.surfaces do if s != nil { pick = s; break }
	if pick != nil do parent = fmt.tprintf("x11:%x", u32(pick.window))
	return xdg.file_dialog(&x.xdg, d, parent)
}

// session_bus exposes the backend's D-Bus connection (nil when there is
// none) so higher layers can drive portals on the socket the pump already
// polls. Owned by the backend.
session_bus :: proc(b: ^platform.Backend) -> ^dbus.Connection {
	return data(b).xdg.bus
}
