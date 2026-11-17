#+build linux
// Portal glue for the Wayland backend: the system theme comes from
// org.freedesktop.portal.Settings over baldr:dbus. Everything here degrades to defaults
// when the session bus or the portal is absent: `system_theme` then reports
// light / no accent / text_scale 1 and no Ev_Theme is ever emitted.
//
// The D-Bus socket joins the pump's poll set (wayland.odin, marked
// `// portal hook`); `dispatch` runs when it is readable and a
// SettingChanged that alters anything we track becomes an Ev_Theme.
package xdg

import "core:os"
import "core:strings"
import "baldr:dbus"
import "baldr:platform"
import portal "baldr:sys/portal"

// portal_init connects to the session bus and subscribes to appearance
// changes. Never fails: on any error the backend simply has no bus.
@(private)
portal_init :: proc(x: ^Xdg) {
	conn, err := dbus.connect_session(timeout_ms = PORTAL_TIMEOUT_MS)
	if err != .None {
		debugf(x, "session bus unavailable (%v): system theme uses defaults", err)
		return
	}
	x.bus = conn
	sub, read := portal.settings_subscribe(conn, on_appearance, x)
	if sub == nil {
		debugf(x, "portal Settings unavailable on %s: system theme uses defaults", conn.unique_name)
		return
	}
	x.settings_sub = sub
	if !read {
		debugf(x, "portal Settings did not answer within %d ms: defaults until it does", portal.SETTINGS_FIRST_WAIT_MS)
		return
	}
	x.appearance = sub.current
	x.has_appearance = true
	a := sub.current
	debugf(x, "portal settings (%s): scheme=%v accent=%v/%v contrast=%v reduce_motion=%v text_scale=%.2f font=%q (%.1f pt) icon_theme=%q button_layout=%q double_click=%q",
		conn.unique_name, a.color_scheme, a.has_accent, a.accent, a.contrast_high, a.reduce_motion, a.text_scale,
		portal.appearance_font_family(&x.appearance), portal.appearance_font_size(&x.appearance), portal.appearance_icon_theme(&x.appearance),
		portal.appearance_button_layout(&x.appearance), portal.appearance_double_click(&x.appearance))
}

// portal_shutdown unsubscribes and drops the bus connection.
@(private)
portal_shutdown :: proc(x: ^Xdg) {
	if x.settings_sub != nil {
		portal.settings_unsubscribe(x.settings_sub)
		x.settings_sub = nil
	}
	if x.bus != nil {
		dbus.disconnect(x.bus)
		x.bus = nil
	}
}

// dispatch drains the bus socket (non-blocking). A dead bus is
// dropped quietly: the last known appearance stays in force.
dispatch :: proc(x: ^Xdg) {
	if x.bus == nil do return
	if _, err := dbus.dispatch(x.bus); err != .None {
		debugf(x, "session bus lost (%v); keeping last appearance", err)
		portal_shutdown(x)
	}
}

// on_appearance is the Settings subscription callback (runs inside
// dispatch, i.e. inside pump): record and queue an Ev_Theme.
@(private)
on_appearance :: proc(user: rawptr, a: portal.Appearance) {
	x := (^Xdg)(user)
	x.appearance = a
	x.has_appearance = true // a portal slow to start answers here, after the window is up
	push(x, theme_event(&x.appearance))
}

// theme is what `system_theme` returns: the portal's appearance, or
// the defaults when nothing answered.
theme :: proc(x: ^Xdg) -> platform.Ev_Theme {
	if !x.has_appearance do return {dark = false, text_scale = 1}
	return theme_event(&x.appearance)
}

// theme_event maps a portal Appearance onto the platform contract; its
// icon_theme points into `a`.
@(private)
theme_event :: proc(a: ^portal.Appearance) -> platform.Ev_Theme {
	return {
		dark                = a.color_scheme == .Dark,
		has_accent          = a.has_accent,
		accent              = {a.accent[0], a.accent[1], a.accent[2], 1},
		reduce_motion       = a.reduce_motion,
		reduce_transparency = a.reduce_transparency,
		high_contrast       = a.contrast_high,
		text_scale          = a.text_scale if a.text_scale > 0 else 1,
		icon_theme          = portal.appearance_icon_theme(a),
		font_family         = portal.appearance_font_family(a),
		mono_family         = portal.appearance_mono_family(a),
		font_size           = portal.appearance_font_size(a),
		button_layout       = portal.appearance_button_layout(a),
		double_click        = portal.appearance_double_click(a),
		palette             = kde_palette(a),
	}
}

// kde_palette is the KDE colour scheme as a System_Palette, when the
// portal published one (at least the window's colours); a role it left out
// is taken from its nearest neighbour.
@(private)
kde_palette :: proc(a: ^portal.Appearance) -> (p: platform.System_Palette) {
	if .Window_Bg not_in a.kde_has || .Window_Fg not_in a.kde_has do return
	get :: proc(a: ^portal.Appearance, r, fallback: portal.Kde_Role) -> [4]f32 {
		c := a.kde[r] if r in a.kde_has else a.kde[fallback]
		return {c[0], c[1], c[2], 1}
	}
	p.ok = true
	p.window, p.window_text = get(a, .Window_Bg, .Window_Bg), get(a, .Window_Fg, .Window_Fg)
	p.view, p.view_text = get(a, .View_Bg, .Window_Bg), get(a, .View_Fg, .Window_Fg)
	p.button, p.button_text = get(a, .Button_Bg, .Window_Bg), get(a, .Button_Fg, .Window_Fg)
	p.selection, p.selection_text = get(a, .Selection_Bg, .Window_Fg), get(a, .Selection_Fg, .Window_Bg)
	p.link, p.inactive_text = get(a, .Window_Link, .Selection_Bg), get(a, .Window_Inactive, .Window_Fg)
	if .Window_Link not_in a.kde_has && .Selection_Bg not_in a.kde_has do p.link = p.window_text
	return
}

// ------------------------------------------------------------ file dialogs

File_Req :: struct {
	x:    ^Xdg,
	token: u64,
}

// file_dialog asks the FileChooser portal for the desktop's open / save
// dialog; the response arrives through dispatch and becomes an
// Ev_Files. Returns false when there is no bus (the toolkit answers the
// command with ok = false and `.Not_Shown`).
//
// `parent_window` is the asking window as the portal names one
// ("x11:<hex window id>" or "wayland:<exported handle>"), or "". With it the
// dialog is transient for the app's window; without it, a desktop that
// prevents focus stealing (Mutter, Muffin) may stack the dialog underneath.
//
// With no folder given it starts in the home folder: the portal backend
// would otherwise start in its own working directory (`/` when the bus
// daemon started it there), where a save fails to write.
file_dialog :: proc(x: ^Xdg, d: platform.File_Dialog, parent_window := "") -> bool {
	if x.bus == nil do return false
	ta := context.temp_allocator
	filters := make([]portal.File_Filter, len(d.filters), ta)
	for f, i in d.filters do filters[i] = {name = f.name, patterns = f.patterns, mime = f.mime}
	folder := d.current_folder
	if folder == "" do folder = os.get_env("HOME", ta)
	req := new(File_Req)
	req^ = {x = x, token = d.token}
	ok: bool
	if d.save {
		ok = portal.file_chooser_save(x.bus, {parent_window = parent_window, title = d.title, accept_label = d.accept_label, current_name = d.current_name, current_folder = folder, filters = filters}, on_files, req)
	} else {
		ok = portal.file_chooser_open(x.bus, {parent_window = parent_window, title = d.title, accept_label = d.accept_label, multiple = d.multiple, directory = d.directory, current_folder = folder, filters = filters}, on_files, req)
	}
	if !ok do free(req)
	debugf(x, "file dialog %d (%s), parent %q, folder %q: %v", d.token, "save" if d.save else "open", parent_window, folder, ok)
	return ok
}

// on_files runs inside dispatch (inside pump): the URIs become
// paths that live until the next pump, and one Ev_Files is queued.
@(private)
on_files :: proc(user: rawptr, result: portal.File_Result) {
	req := (^File_Req)(user)
	x := req.x
	ev := platform.Ev_Files{token = req.token, ok = result.response == .Success}
	ev.why = files_why(result.response)
	if ev.ok {
		paths := make([dynamic]string, x.text)
		for uri in result.uris {
			if p, ok := portal.uri_to_path(uri, x.text); ok do append(&paths, p)
		}
		ev.paths = paths[:]
		if len(ev.paths) == 0 {
			// chosen, and none of it a file here: say what it was
			ev.ok = false
			ev.why = .Unusable
			uris := make([]string, len(result.uris), x.text)
			for uri, i in result.uris do uris[i] = strings.clone(uri, x.text)
			ev.uris = uris
		}
	}
	debugf(x, "file dialog %d answered %v: %v, %d path(s)", req.token, result.response, ev.why, len(ev.paths))
	push(x, ev)
	free(req)
}

// files_why is what a portal's response says about a dialog. Response 2
// is the backend giving up, not a person deciding, and 255 is the portal
// refusing the call (no FileChooser backend on this desktop): neither
// showed a dialog anybody could use.
@(private)
files_why :: proc "contextless" (r: portal.Response) -> platform.Files_Why {
	switch r {
	case .Success:   return .Chosen
	case .Cancelled: return .Cancelled
	case .Other, .Failed: return .Not_Shown
	}
	return .Not_Shown
}
