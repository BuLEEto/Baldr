#+build linux
// org.freedesktop.portal.Settings: read the system appearance and follow
// changes.
//
// The keys read:
//
//   org.freedesktop.appearance     color-scheme u (0 none, 1 dark, 2 light)
//                                  contrast     u (0 normal, 1 high)
//                                  accent-color (ddd), when the portal
//                                  backend provides it (not all do)
//   org.gnome.desktop.interface    enable-animations b  → reduce_motion
//                                  text-scaling-factor d → text_scale
//                                  color-scheme s ("prefer-dark"…) fallback
//                                  when org.freedesktop.appearance is absent
//                                  icon-theme s → icon_theme
//                                  cursor-blink b, cursor-blink-time i (ms,
//                                  the whole cycle), cursor-blink-timeout i
//                                  (s) → the text caret's blink
//   org.gnome.desktop.a11y.interface high-contrast b   fallback for contrast
//   org.kde.kdeglobals.Colors:Window, :View, :Button, :Selection
//                                  BackgroundNormal, ForegroundNormal (and
//                                  Window's ForegroundInactive, ForegroundLink)
//                                  "r,g,b" → the KDE colour scheme
//   org.gnome.desktop.wm.preferences button-layout s   → a title bar's buttons
//                                  (":minimize,maximize,close")
//                                  action-double-click-titlebar s
//                                  ("toggle-maximize") → what a double-click does
//
// Neither the portal spec nor GNOME defines a reduce-transparency key, so
// `reduce_transparency` stays false here; the field waits for one.
// SettingChanged fires for every key above, and a GNOME key that
// org.freedesktop.appearance mirrors (color-scheme) fires for both.
package portal

import "base:runtime"
import "core:strconv"
import "core:time"
import "baldr:dbus"

// Kde_Role is one colour of a KDE colour scheme that the toolkit reads.
Kde_Role :: enum u8 { Window_Bg, Window_Fg, Window_Inactive, Window_Link, View_Bg, View_Fg, Button_Bg, Button_Fg, Selection_Bg, Selection_Fg }

// Color_Scheme mirrors org.freedesktop.appearance color-scheme.
Color_Scheme :: enum u8 {
	No_Preference,
	Dark,
	Light,
}

// Appearance is the system look as far as the portal tells us. Zero value
// = "no preferences known" except text_scale, which read/subscribe set to
// 1 when absent.
Appearance :: struct {
	color_scheme:        Color_Scheme,
	accent:              [3]f32, // sRGB 0..1, valid when has_accent
	has_accent:          bool,
	contrast_high:       bool,
	reduce_motion:       bool, // org.gnome.desktop.interface enable-animations == false
	reduce_transparency: bool, // no portal or GNOME key exists; always false (see file comment)
	text_scale:          f32,  // org.gnome.desktop.interface text-scaling-factor, 1 = default
	icon_theme:          [128]u8, // org.gnome.desktop.interface icon-theme, NUL-padded, empty when unsaid (appearance_icon_theme)
	// The desktop's UI fonts, as Pango descriptions ("Cantarell 11"):
	// org.gnome.desktop.interface font-name and monospace-font-name.
	// NUL-padded, empty when unsaid; appearance_font_family and
	// appearance_mono_family hand back the family without the size, and
	// appearance_font_size the UI font's size.
	font_name:           [128]u8,
	mono_font_name:      [128]u8,
	// The pointer's theme and size: org.gnome.desktop.interface cursor-theme
	// ("Adwaita") and cursor-size (24). Read by a backend that draws the
	// cursor from the theme itself — Wayland on a compositor without the
	// cursor-shape protocol. Empty and 0 when unsaid.
	cursor_theme:        [128]u8,
	cursor_size:         i32,
	// The text caret's blink: org.gnome.desktop.interface cursor-blink
	// (false → steady_caret), cursor-blink-time (the whole on-and-off cycle,
	// ms) and cursor-blink-timeout (s). 0 when unsaid.
	steady_caret:        bool,
	caret_cycle_ms:      i32,
	caret_timeout_s:     i32,
	// A title bar's choices, in GNOME's words, NUL-padded, empty when unsaid
	button_layout:       [128]u8, // org.gnome.desktop.wm.preferences button-layout (":minimize,maximize,close")
	double_click:        [32]u8,  // org.gnome.desktop.wm.preferences action-double-click-titlebar ("toggle-maximize")
	// The KDE colour scheme, as xdg-desktop-portal-kde publishes it; a role
	// is valid when it is in `kde_has`.
	kde:                 [Kde_Role][3]f32,
	kde_has:             bit_set[Kde_Role],
	// Which namespaces answered; they decide fallback precedence.
	has_appearance_ns:   bool, // org.freedesktop.appearance was present
	has_gnome_ns:        bool, // org.gnome.desktop.interface was present
}

// appearance_font_family and appearance_mono_family are the families the
// desktop named, "" when none.
//
// GNOME states a font as a Pango description — "Cantarell 11", "Source Code
// Pro 10" — which carries the family *and* a size. These hand back the
// family; `appearance_font_size` hands back the UI font's size.
appearance_font_family :: proc(a: ^Appearance) -> string {
	return pango_family(padded_string(a.font_name[:]))
}

// appearance_font_size is the size of the desktop's UI font in points, as
// its description states it ("Cantarell 11" → 11), and 0 when it states
// none. It is separate from `text-scaling-factor`, not an overlap: GTK
// draws text at this size times that factor, so following both matches the
// rest of the desktop.
appearance_font_size :: proc(a: ^Appearance) -> f32 {
	return pango_size(padded_string(a.font_name[:]))
}

appearance_mono_family :: proc(a: ^Appearance) -> string {
	return pango_family(padded_string(a.mono_font_name[:]))
}

// pango_family drops the trailing size from a Pango font description and
// leaves anything else alone: "Cantarell Bold 11" keeps the "Bold", because
// matching style keywords belongs in the text engine, not a settings reader.
@(private)
pango_family :: proc(s: string) -> string {
	cut := len(s)
	for cut > 0 && s[cut - 1] == ' ' do cut -= 1
	if cut >= 2 && s[cut - 2:cut] == "px" do cut -= 2 // an absolute size, "Sans 14px"
	end := cut
	for cut > 0 {
		c := s[cut - 1]
		if (c >= '0' && c <= '9') || c == '.' { cut -= 1 } else { break }
	}
	if cut == end do return s // no trailing number: all of it is the family
	if cut > 0 && s[cut - 1] != ' ' do return s // a number that is part of the name ("Font2")
	for cut > 0 && s[cut - 1] == ' ' do cut -= 1
	if cut == 0 do return s // a size and nothing else: not a description we understand
	return s[:cut]
}

// pango_size is the trailing size of a Pango font description, in points:
// "Cantarell 11" is 11, "Noto Sans Bold 10.5" is 10.5, and an absolute
// "Sans 14px" is 10.5 — Pango's pixels are 1/96 inch, its points 1/72. A
// description with no size, a size and nothing else, or a number that is
// not one gives 0: "the desktop did not say".
@(private)
pango_size :: proc(s: string) -> f32 {
	cut := len(s)
	for cut > 0 && s[cut - 1] == ' ' do cut -= 1
	px := false
	if cut >= 2 && s[cut - 2:cut] == "px" {
		px = true
		cut -= 2
	}
	end := cut
	for cut > 0 {
		c := s[cut - 1]
		if (c >= '0' && c <= '9') || c == '.' { cut -= 1 } else { break }
	}
	if cut == end || cut == 0 || s[cut - 1] != ' ' do return 0 // no number, nothing before it, or a number glued to a word ("Font2")
	v, ok := strconv.parse_f32(s[cut:end])
	if !ok || v <= 0 do return 0
	return v * 72.0 / 96.0 if px else v
}

// appearance_cursor_theme is the cursor theme the desktop named, "" when
// none. It points into `a`.
appearance_cursor_theme :: proc(a: ^Appearance) -> string { return padded_string(a.cursor_theme[:]) }

// appearance_icon_theme is the icon theme the desktop named, "" when none.
appearance_icon_theme :: proc(a: ^Appearance) -> string {
	return padded_string(a.icon_theme[:])
}

// appearance_button_layout and appearance_double_click are the title bar's
// choices as the desktop wrote them (GNOME's), "" when it didn't say. Both
// point into `a`.
appearance_button_layout :: proc(a: ^Appearance) -> string { return padded_string(a.button_layout[:]) }
appearance_double_click :: proc(a: ^Appearance) -> string { return padded_string(a.double_click[:]) }

@(private)
padded_string :: proc(b: []u8) -> string {
	for c, i in b do if c == 0 do return string(b[:i])
	return string(b)
}

// set_padded copies `s` into `b`, cut to leave a NUL at the end.
@(private)
set_padded :: proc(b: []u8, s: string) {
	for &c in b do c = 0
	copy(b[:len(b) - 1], s)
}

// NAMESPACES is what settings_read_appearance asks ReadAll for. Globs are
// allowed by the portal but exact names keep the reply small.
NAMESPACES := [8]string{"org.freedesktop.appearance", "org.gnome.desktop.interface", "org.gnome.desktop.a11y.interface", "org.gnome.desktop.wm.preferences",
	"org.kde.kdeglobals.Colors:Window", "org.kde.kdeglobals.Colors:View", "org.kde.kdeglobals.Colors:Button", "org.kde.kdeglobals.Colors:Selection"}

// settings_read_appearance calls Settings.ReadAll for NAMESPACES and folds
// the result into an Appearance. ok=false when the portal is absent, the
// call errors, or times out (the Appearance is then the default: no
// preference, text_scale 1). Blocking, bounded by timeout_ms.
settings_read_appearance :: proc(conn: ^dbus.Connection, timeout_ms := DEFAULT_TIMEOUT_MS) -> (a: Appearance, ok: bool) {
	a.text_scale = 1
	if !dbus.is_connected(conn) do return a, false
	arg := [1]dbus.Value{dbus.strings_array(NAMESPACES[:], context.temp_allocator)}
	m := dbus.method_call(DESKTOP_DEST, DESKTOP_PATH, IFACE_SETTINGS, "ReadAll", arg[:])
	reply, err := dbus.call(conn, &m, timeout_ms, context.temp_allocator)
	if err != .None || len(reply.body) != 1 do return a, false
	if !appearance_from_readall(&a, reply.body[0]) do return a, false
	return a, true
}

// appearance_from_readall folds a ReadAll reply value (a{sa{sv}}) into a.
// org.freedesktop.appearance is applied first so the GNOME fallbacks never
// override it whatever order the dict came in. false if v is not a dict.
appearance_from_readall :: proc(a: ^Appearance, v: dbus.Value) -> bool {
	outer, ok := dbus.as_dict(v)
	if !ok do return false
	for pass in 0 ..< 2 {
		for e in outer.entries {
			ns, nok := e.key.(string)
			if !nok do continue
			is_fdo := ns == "org.freedesktop.appearance"
			if (pass == 0) != is_fdo do continue
			inner, iok := dbus.as_dict(e.value)
			if !iok do continue
			for kv in inner.entries {
				key, kok := kv.key.(string)
				if !kok do continue
				settings_apply(a, ns, key, kv.value)
			}
		}
	}
	return true
}

// settings_apply folds one (namespace, key, value) triple — a ReadAll entry
// or a SettingChanged signal — into a. Returns true when a changed. Unknown
// keys are ignored; wrong-typed values are ignored.
settings_apply :: proc(a: ^Appearance, namespace, key: string, value: dbus.Value) -> (changed: bool) {
	before := a^
	switch namespace {
	case "org.freedesktop.appearance":
		a.has_appearance_ns = true
		switch key {
		case "color-scheme":
			if u, ok := dbus.as_u32(value); ok {
				switch u {
				case 1: a.color_scheme = .Dark
				case 2: a.color_scheme = .Light
				case:   a.color_scheme = .No_Preference
				}
			}
		case "contrast":
			if u, ok := dbus.as_u32(value); ok do a.contrast_high = u == 1
		case "accent-color":
			if s, ok := dbus.as_struct(value); ok && len(s.fields) == 3 {
				rgb: [3]f32
				valid := true
				for f, i in s.fields {
					d, dok := dbus.as_f64(f)
					if !dok || d < 0 || d > 1 do valid = false
					rgb[i] = f32(d)
				}
				a.has_accent = valid // out-of-range means "no preference" per spec
				a.accent = rgb if valid else {}
			}
		}
	case "org.gnome.desktop.interface":
		a.has_gnome_ns = true
		switch key {
		case "enable-animations":
			if b, ok := dbus.as_bool(value); ok do a.reduce_motion = !b
		case "text-scaling-factor":
			if d, ok := dbus.as_f64(value); ok && d > 0 do a.text_scale = f32(d)
		case "icon-theme":
			if s, ok := dbus.as_string(value); ok do set_padded(a.icon_theme[:], s) // a name longer than that is cut, still NUL-terminated
		case "font-name":
			if s, ok := dbus.as_string(value); ok do set_padded(a.font_name[:], s)
		case "monospace-font-name":
			if s, ok := dbus.as_string(value); ok do set_padded(a.mono_font_name[:], s)
		case "cursor-theme":
			if s, ok := dbus.as_string(value); ok do set_padded(a.cursor_theme[:], s)
		case "cursor-size":
			if n, ok := dbus.as_i32(value); ok && n > 0 do a.cursor_size = n
		case "cursor-blink":
			if b, ok := dbus.as_bool(value); ok do a.steady_caret = !b
		case "cursor-blink-time":
			if n, ok := dbus.as_i32(value); ok && n > 0 do a.caret_cycle_ms = n
		case "cursor-blink-timeout":
			if n, ok := dbus.as_i32(value); ok && n > 0 do a.caret_timeout_s = n
		case "color-scheme":
			if a.has_appearance_ns do break
			if s, ok := dbus.as_string(value); ok {
				switch s {
				case "prefer-dark":  a.color_scheme = .Dark
				case "prefer-light": a.color_scheme = .Light
				case:                a.color_scheme = .No_Preference
				}
			}
		}
	case "org.gnome.desktop.a11y.interface":
		if key == "high-contrast" && !a.has_appearance_ns {
			if b, ok := dbus.as_bool(value); ok do a.contrast_high = b
		}
	case "org.kde.kdeglobals.Colors:Window", "org.kde.kdeglobals.Colors:View", "org.kde.kdeglobals.Colors:Button", "org.kde.kdeglobals.Colors:Selection":
		if role, ok := kde_role(namespace, key); ok {
			if rgb, cok := kde_color(value); cok {
				a.kde[role] = rgb
				a.kde_has += {role}
			}
		}
	case "org.gnome.desktop.wm.preferences":
		switch key {
		case "button-layout":
			if s, ok := dbus.as_string(value); ok do set_padded(a.button_layout[:], s)
		case "action-double-click-titlebar":
			if s, ok := dbus.as_string(value); ok do set_padded(a.double_click[:], s)
		}
	}
	return a^ != before
}

// kde_role is the role a kdeglobals colour key stands for, if it is one the
// toolkit reads.
kde_role :: proc(namespace, key: string) -> (Kde_Role, bool) {
	switch namespace {
	case "org.kde.kdeglobals.Colors:Window":
		switch key {
		case "BackgroundNormal":   return .Window_Bg, true
		case "ForegroundNormal":   return .Window_Fg, true
		case "ForegroundInactive": return .Window_Inactive, true
		case "ForegroundLink":     return .Window_Link, true
		}
	case "org.kde.kdeglobals.Colors:View":
		switch key {
		case "BackgroundNormal": return .View_Bg, true
		case "ForegroundNormal": return .View_Fg, true
		}
	case "org.kde.kdeglobals.Colors:Button":
		switch key {
		case "BackgroundNormal": return .Button_Bg, true
		case "ForegroundNormal": return .Button_Fg, true
		}
	case "org.kde.kdeglobals.Colors:Selection":
		switch key {
		case "BackgroundNormal": return .Selection_Bg, true
		case "ForegroundNormal": return .Selection_Fg, true
		}
	}
	return {}, false
}

// kde_color reads a kdeglobals colour, "r,g,b" with each 0..255 (a fourth,
// alpha, value is ignored), into sRGB 0..1. A struct of three numbers is
// taken too, in case a portal sends it typed.
kde_color :: proc(value: dbus.Value) -> (rgb: [3]f32, ok: bool) {
	if s, sok := dbus.as_string(value); sok {
		n := 0
		rest := s
		for n < 3 {
			comma := len(rest)
			for c, i in rest do if c == ',' { comma = i; break }
			v, vok := strconv.parse_int(rest[:comma])
			if !vok || v < 0 || v > 255 do return {}, false
			rgb[n] = f32(v) / 255
			n += 1
			if comma >= len(rest) do break
			rest = rest[comma + 1:]
		}
		return rgb, n == 3
	}
	if st, stok := dbus.as_struct(value); stok && len(st.fields) >= 3 {
		for i in 0 ..< 3 {
			if d, dok := dbus.as_f64(st.fields[i]); dok { rgb[i] = f32(d) / 255 if d > 1 else f32(d); continue }
			if u, uok := dbus.as_i32(st.fields[i]); uok { rgb[i] = f32(u) / 255; continue }
			return {}, false
		}
		return rgb, true
	}
	return {}, false
}

// Settings_Callback receives the full, updated Appearance after a
// SettingChanged that altered something we track.
Settings_Callback :: #type proc(user: rawptr, a: Appearance)

// Settings_Subscription is a live SettingChanged subscription; `current`
// is always the latest folded state.
Settings_Subscription :: struct {
	conn:      ^dbus.Connection,
	allocator: runtime.Allocator,
	current:   Appearance,
	cb:        Settings_Callback,
	user:      rawptr,
	handler:   dbus.Handler_Id,
	read:      bool, // the first reading has come
	refused:   bool, // …or the portal answered that it has none
	waited:    bool, // settings_subscribe has returned: a reading now goes to cb
}

// SETTINGS_FIRST_WAIT_MS is how long settings_subscribe waits for the first
// reading. A running portal answers in milliseconds; one installed but slow
// to start answers later, through the callback, rather than holding up the
// window.
SETTINGS_FIRST_WAIT_MS :: i32(250)

@(private)
SETTINGS_MATCH :: "type='signal',sender='org.freedesktop.portal.Desktop',interface='org.freedesktop.portal.Settings',member='SettingChanged',path='/org/freedesktop/portal/desktop'"

// settings_subscribe registers for SettingChanged, asks for the current
// appearance, and waits up to `wait_ms` for it. `read` says whether it came
// in that time (then `sub.current` holds it); a reading that comes later,
// and every tracked change after, goes to cb from dbus.dispatch. nil when
// the bus is gone or AddMatch fails. Free with settings_unsubscribe.
settings_subscribe :: proc(conn: ^dbus.Connection, cb: Settings_Callback, user: rawptr, allocator := context.allocator,
	wait_ms := SETTINGS_FIRST_WAIT_MS) -> (sub: ^Settings_Subscription, read: bool) {
	if !dbus.is_connected(conn) do return nil, false
	if err := dbus.add_match(conn, SETTINGS_MATCH); err != .None do return nil, false
	sub = new(Settings_Subscription, allocator)
	sub.conn = conn
	sub.allocator = allocator
	sub.current.text_scale = 1
	sub.cb = cb
	sub.user = user
	sub.handler = dbus.on_signal(conn, IFACE_SETTINGS, "SettingChanged", on_setting_changed, sub, path = DESKTOP_PATH)
	arg := [1]dbus.Value{dbus.strings_array(NAMESPACES[:], context.temp_allocator)}
	m := dbus.method_call(DESKTOP_DEST, DESKTOP_PATH, IFACE_SETTINGS, "ReadAll", arg[:])
	if _, err := dbus.call_async(conn, &m, on_read_all, sub); err == .None {
		deadline := time.tick_add(time.tick_now(), time.Duration(wait_ms) * time.Millisecond)
		for !sub.read && !sub.refused {
			left := time.tick_diff(time.tick_now(), deadline)
			if left <= 0 do break
			readable, perr := dbus.wait_readable(conn, i32(max(left / time.Millisecond, 1)))
			if perr != .None do break
			if readable do dbus.dispatch(conn)
		}
	}
	sub.waited = true
	return sub, sub.read
}

// on_read_all takes the first reading: into `current` while settings_subscribe
// waits, and to the callback once it has returned.
@(private)
on_read_all :: proc(conn: ^dbus.Connection, reply: ^dbus.Message, err: dbus.Error, user: rawptr) {
	sub := (^Settings_Subscription)(user)
	if err != .None || reply == nil || len(reply.body) != 1 {
		sub.refused = true
		return
	}
	a := Appearance{text_scale = 1}
	if !appearance_from_readall(&a, reply.body[0]) {
		sub.refused = true
		return
	}
	sub.current = a
	sub.read = true
	if sub.waited && sub.cb != nil do sub.cb(sub.user, sub.current)
}

// settings_unsubscribe removes the handler and match rule and frees sub.
settings_unsubscribe :: proc(sub: ^Settings_Subscription) {
	if sub == nil do return
	if sub.handler != 0 do dbus.off_signal(sub.conn, sub.handler)
	if dbus.is_connected(sub.conn) do dbus.remove_match(sub.conn, SETTINGS_MATCH)
	free(sub, sub.allocator)
}

// on_setting_changed parses SettingChanged(s namespace, s key, v value).
@(private)
on_setting_changed :: proc(conn: ^dbus.Connection, sig: ^dbus.Message, user: rawptr) {
	sub := (^Settings_Subscription)(user)
	if len(sig.body) != 3 do return
	ns, nok := dbus.as_string(sig.body[0])
	key, kok := dbus.as_string(sig.body[1])
	if !nok || !kok do return
	if settings_apply(&sub.current, ns, key, sig.body[2]) && sub.cb != nil {
		sub.cb(sub.user, sub.current)
	}
}
