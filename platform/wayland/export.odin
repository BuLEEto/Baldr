#+build linux
package wayland

// A window named to another program, through xdg-foreign v2.
//
// The file chooser is drawn by the desktop's portal, a different process,
// which takes a `parent_window` of "wayland:<handle>"; the handle is what
// `zxdg_exporter_v2` gives for one of our toplevels. With it the compositor
// makes the dialog transient for the app's window (above, centred, modal).
// Without it the dialog is a window of its own, which a compositor that
// prevents focus stealing may stack under the window with the keyboard.
//
// A toplevel is exported once, on the first dialog, and the export lives as
// long as the window: destroying it would free the portal's window from its
// parent.

import "core:strings"
import wl "baldr:platform/wayland/wl"

// surface_export_handle is "wayland:<handle>" for `s`, exporting it on the
// first ask, or "" when the compositor has no xdg-foreign or `s` is not a
// toplevel. The string is the backend's (it lives as long as the window).
@(private)
surface_export_handle :: proc(st: ^State, s: ^Surface_State) -> string {
	if st.exporter == nil || s == nil || s.toplevel == nil || s.wl_surface == nil do return ""
	if s.export_handle != "" do return s.export_handle
	if s.exported == nil {
		@(static) listener: wl.Zxdg_Exported_V2_Listener
		listener.handle = proc "c" (data: rawptr, p: wl.Proxy, handle: cstring) {
			s := (^Surface_State)(data)
			context = s.st.ctx
			delete(s.export_handle, s.st.alloc)
			s.export_handle = strings.concatenate({"wayland:", string(handle)}, s.st.alloc)
		}
		s.exported = wl.zxdg_exporter_v2_export_toplevel(st.exporter, s.wl_surface)
		if s.exported == nil do return ""
		wl.zxdg_exported_v2_add_listener(s.exported, &listener, s)
	}
	// The handle comes back as an event: one round trip brings it, and a
	// dialog is not something a person asks for many times a second.
	wl.display_roundtrip(st.display)
	debugf(st, "surface %d exported as %q", s.id, s.export_handle)
	return s.export_handle
}

// surface_export_drop ends the export with the window it names.
@(private)
surface_export_drop :: proc(st: ^State, s: ^Surface_State) {
	if s.exported != nil {
		wl.zxdg_exported_v2_destroy(s.exported)
		s.exported = nil
	}
	delete(s.export_handle, st.alloc)
	s.export_handle = ""
}

// dialog_parent is the window a dialog asked for now belongs to: the one with
// the keyboard, else the first toplevel. Nil when there is none.
@(private)
dialog_parent :: proc(st: ^State) -> ^Surface_State {
	if st.kbd_focus != nil && st.kbd_focus.toplevel != nil do return st.kbd_focus
	for s in st.surfaces do if s != nil && s.toplevel != nil do return s
	return nil
}
