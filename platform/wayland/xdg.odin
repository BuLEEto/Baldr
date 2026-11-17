#+build linux
// This backend's side of the desktop services (platform/xdg).
//
// The theme, notifications, opening links and files, and the file chooser
// are not Wayland's — they are D-Bus, and the X11 backend will want the
// same code. `platform/xdg` holds it and knows nothing of a window system;
// this file is the whole of what Wayland has to say to it: what it needs
// from here, and the Backend procs that hand a call through.
package wayland

import "baldr:dbus"
import "baldr:platform"
import "baldr:platform/xdg"

// xdg_wire tells the desktop services where to put events and which memory
// to use. Called once in init, before xdg.init, and after `pending`, the
// text arena, `alloc` and `debug` are in place.
//
// `app_id` is left for surface.odin: on Wayland the app's id is the first
// toplevel's, which is not known yet.
@(private)
xdg_wire :: proc(st: ^State) {
	st.xdg.events = &st.pending
	st.xdg.alloc = st.alloc
	st.xdg.text = text_allocator(st)
	st.xdg.debug = st.debug
}

@(private)
open_url :: proc(b: ^platform.Backend, url: string, token: u64) -> bool {
	return xdg.open_url(&state(b).xdg, url, token)
}

@(private)
open_path :: proc(b: ^platform.Backend, path: string, reveal: bool, token: u64) -> bool {
	return xdg.open_path(&state(b).xdg, path, reveal, token)
}

@(private)
notify :: proc(b: ^platform.Backend, d: platform.Notify_Desc) -> bool {
	return xdg.notify(&state(b).xdg, d)
}

@(private)
notify_close :: proc(b: ^platform.Backend, tag: u64) {
	xdg.notify_close(&state(b).xdg, tag)
}

@(private)
tray_set :: proc(b: ^platform.Backend, t: platform.Tray_Desc) -> bool {
	return xdg.tray_set(&state(b).xdg, t)
}

@(private)
tray_remove :: proc(b: ^platform.Backend, tag: u64) {
	xdg.tray_remove(&state(b).xdg, tag)
}

// file_dialog asks the FileChooser portal for the desktop's own open / save
// dialog; the answer arrives through the pump as an Ev_Files. False when
// there is no bus (the toolkit answers the command with ok = false).
file_dialog :: proc(b: ^platform.Backend, d: platform.File_Dialog) -> bool {
	st := state(b)
	return xdg.file_dialog(&st.xdg, d, surface_export_handle(st, dialog_parent(st))) // the asking window, so the dialog is its (export.odin)
}

// session_bus exposes the backend's D-Bus connection (nil when the bus was
// unavailable) so higher layers can drive portals on the same socket the
// pump already polls. Owned by the backend.
session_bus :: proc(b: ^platform.Backend) -> ^dbus.Connection {
	return state(b).xdg.bus
}
