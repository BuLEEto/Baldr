#+build linux
// Headless tests for the portal wrappers: option-dict encoding, ReadAll /
// SettingChanged folding, request path prediction. Run with:
//   odin test sys/portal -collection:baldr=.
package portal

@(require) import "core:strings"
@(require) import "core:testing"
@(require) import "baldr:dbus"

// Test files are part of the package, so everything that imports it would
// type-check them too: they sit behind this `when` (see baldr/canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// encode_decode_options runs entries through a real message body so the
// a{sv} is exercised on the wire, then returns the decoded dict Value.
@(private = "file")
encode_decode_options :: proc(t: ^testing.T, entries: []dbus.Dict_Entry) -> dbus.Value {
	ta := context.temp_allocator
	body := [3]dbus.Value{"", "Open", dbus.dict_sv(entries, ta)}
	m := dbus.method_call(DESKTOP_DEST, DESKTOP_PATH, IFACE_FILE_CHOOSER, "OpenFile", body[:])
	m.serial = 1
	bytes, eerr := dbus.encode_message(&m, ta)
	testing.expect_value(t, eerr, dbus.Error.None)
	testing.expect_value(t, m.signature, "ssa{sv}")
	d, derr := dbus.decode_message(bytes, ta)
	testing.expect_value(t, derr, dbus.Error.None)
	testing.expect_value(t, len(d.body), 3)
	return d.body[2]
}

@(test)
file_chooser_open_options_encode :: proc(t: ^testing.T) {
	ta := context.temp_allocator
	filters := [2]File_Filter{
		{name = "Images", patterns = {"*.png", "*.jpg"}},
		{name = "Text", patterns = {"text/plain"}, mime = true},
	}
	opts := Open_Options{
		title          = "Pick",
		accept_label   = "Choose",
		multiple       = true,
		directory      = false,
		current_folder = "/home/user",
		filters        = filters[:],
	}
	entries := open_options_entries(opts, ta)
	dict := encode_decode_options(t, entries)

	multiple, mok := dbus.as_bool(lookup(t, dict, "multiple"))
	testing.expect(t, mok)
	testing.expect_value(t, multiple, true)
	directory, _ := dbus.as_bool(lookup(t, dict, "directory"))
	testing.expect_value(t, directory, false)
	modal, _ := dbus.as_bool(lookup(t, dict, "modal"))
	testing.expect_value(t, modal, true)
	label, _ := dbus.as_string(lookup(t, dict, "accept_label"))
	testing.expect_value(t, label, "Choose")
	folder, fok := dbus.as_bytes(lookup(t, dict, "current_folder"))
	testing.expect(t, fok)
	testing.expect_value(t, len(folder), len("/home/user") + 1)
	testing.expect_value(t, string(folder[:len(folder) - 1]), "/home/user")
	testing.expect_value(t, folder[len(folder) - 1], u8(0))

	farr, faok := dbus.as_array(lookup(t, dict, "filters"))
	testing.expect(t, faok)
	testing.expect_value(t, farr.sig, "(sa(us))")
	testing.expect_value(t, len(farr.items), 2)
	if len(farr.items) == 2 {
		f0, _ := dbus.as_struct(farr.items[0])
		name0, _ := dbus.as_string(f0.fields[0])
		testing.expect_value(t, name0, "Images")
		pats0, _ := dbus.as_array(f0.fields[1])
		testing.expect_value(t, pats0.sig, "(us)")
		testing.expect_value(t, len(pats0.items), 2)
		p1, _ := dbus.as_struct(pats0.items[1])
		kind, _ := dbus.as_u32(p1.fields[0])
		pat, _ := dbus.as_string(p1.fields[1])
		testing.expect_value(t, kind, u32(0))
		testing.expect_value(t, pat, "*.jpg")
		f1, _ := dbus.as_struct(farr.items[1])
		pats1, _ := dbus.as_array(f1.fields[1])
		m0, _ := dbus.as_struct(pats1.items[0])
		mkind, _ := dbus.as_u32(m0.fields[0])
		testing.expect_value(t, mkind, u32(1))
	}
	// A minimal Open_Options has no optional keys.
	minimal := open_options_entries(Open_Options{}, ta)
	testing.expect_value(t, len(minimal), 3) // modal, multiple, directory
}

@(test)
file_chooser_save_options_encode :: proc(t: ^testing.T) {
	ta := context.temp_allocator
	opts := Save_Options{current_name = "untitled.txt", current_folder = "/tmp", accept_label = "Save as"}
	dict := encode_decode_options(t, save_options_entries(opts, ta))
	name, _ := dbus.as_string(lookup(t, dict, "current_name"))
	testing.expect_value(t, name, "untitled.txt")
	folder, _ := dbus.as_bytes(lookup(t, dict, "current_folder"))
	testing.expect_value(t, string(folder), "/tmp\x00")
	_, has_file := dbus.dict_get(dict, "current_file")
	testing.expect_value(t, has_file, false)
}

@(private = "file")
lookup :: proc(t: ^testing.T, dict: dbus.Value, key: string) -> dbus.Value {
	v, ok := dbus.dict_get(dict, key)
	testing.expectf(t, ok, "option %q missing", key)
	return v
}

@(test)
request_path_prediction :: proc(t: ^testing.T) {
	p := request_path(":1.39", "baldr_5", context.temp_allocator)
	testing.expect_value(t, p, "/org/freedesktop/portal/desktop/request/1_39/baldr_5")
	testing.expect(t, dbus.object_path_valid(p))
	p2 := request_path(":1.5.12", "t", context.temp_allocator)
	testing.expect_value(t, p2, "/org/freedesktop/portal/desktop/request/1_5_12/t")
}

// A KDE colour scheme arrives as "r,g,b" strings under the kdeglobals
// namespaces; a malformed one is ignored rather than read as black.
@(test)
settings_read_the_kde_colour_scheme :: proc(t: ^testing.T) {
	ta := context.temp_allocator
	a := Appearance{text_scale = 1}
	testing.expect(t, settings_apply(&a, "org.kde.kdeglobals.Colors:Window", "BackgroundNormal", dbus.variant("239,240,241", ta)))
	testing.expect(t, settings_apply(&a, "org.kde.kdeglobals.Colors:Selection", "BackgroundNormal", dbus.variant("61,174,233,255", ta)))
	testing.expect(t, .Window_Bg in a.kde_has && .Selection_Bg in a.kde_has)
	testing.expect_value(t, a.kde[.Window_Bg], [3]f32{239.0 / 255, 240.0 / 255, 241.0 / 255})
	testing.expect_value(t, a.kde[.Selection_Bg], [3]f32{61.0 / 255, 174.0 / 255, 233.0 / 255})
	testing.expect(t, !settings_apply(&a, "org.kde.kdeglobals.Colors:View", "BackgroundNormal", dbus.variant("not,a,colour", ta)))
	testing.expect(t, !settings_apply(&a, "org.kde.kdeglobals.Colors:View", "BackgroundNormal", dbus.variant("300,0,0", ta)))
	testing.expect(t, .View_Bg not_in a.kde_has)
	testing.expect(t, !settings_apply(&a, "org.kde.kdeglobals.Colors:Window", "DecorationFocus", dbus.variant("1,2,3", ta))) // a key the toolkit does not read
}

@(test)
settings_apply_maps_portal_keys :: proc(t: ^testing.T) {
	ta := context.temp_allocator
	a := Appearance{text_scale = 1}
	testing.expect(t, settings_apply(&a, "org.freedesktop.appearance", "color-scheme", dbus.variant(u32(1), ta)))
	testing.expect_value(t, a.color_scheme, Color_Scheme.Dark)
	testing.expect(t, a.has_appearance_ns)
	testing.expect(t, settings_apply(&a, "org.freedesktop.appearance", "color-scheme", dbus.variant(u32(2), ta)))
	testing.expect_value(t, a.color_scheme, Color_Scheme.Light)
	testing.expect(t, !settings_apply(&a, "org.freedesktop.appearance", "color-scheme", dbus.variant(u32(2), ta))) // unchanged
	settings_apply(&a, "org.freedesktop.appearance", "color-scheme", dbus.variant(u32(7), ta))
	testing.expect_value(t, a.color_scheme, Color_Scheme.No_Preference)
	testing.expect(t, settings_apply(&a, "org.freedesktop.appearance", "contrast", dbus.variant(u32(1), ta)))
	testing.expect(t, a.contrast_high)

	// accent-color (ddd): in range → accent; out of range → no preference.
	rgb := [3]dbus.Value{f64(0.2), f64(0.4), f64(1.0)}
	settings_apply(&a, "org.freedesktop.appearance", "accent-color", dbus.variant(dbus.Struct{fields = rgb[:]}, ta))
	testing.expect(t, a.has_accent)
	testing.expect_value(t, a.accent, [3]f32{0.2, 0.4, 1.0})
	bad := [3]dbus.Value{f64(-1), f64(0), f64(0)}
	settings_apply(&a, "org.freedesktop.appearance", "accent-color", dbus.variant(dbus.Struct{fields = bad[:]}, ta))
	testing.expect(t, !a.has_accent)

	// GNOME keys.
	testing.expect(t, settings_apply(&a, "org.gnome.desktop.interface", "enable-animations", dbus.variant(false, ta)))
	testing.expect(t, a.reduce_motion)
	testing.expect(t, settings_apply(&a, "org.gnome.desktop.interface", "text-scaling-factor", dbus.variant(f64(1.5), ta)))
	testing.expect_value(t, a.text_scale, f32(1.5))
	testing.expect(t, settings_apply(&a, "org.gnome.desktop.interface", "icon-theme", dbus.variant("Papirus-Dark", ta)))
	testing.expect_value(t, appearance_icon_theme(&a), "Papirus-Dark")
	testing.expect(t, !settings_apply(&a, "org.gnome.desktop.interface", "icon-theme", dbus.variant("Papirus-Dark", ta))) // unchanged
	testing.expect(t, settings_apply(&a, "org.gnome.desktop.interface", "icon-theme", dbus.variant("Adwaita", ta)))
	testing.expect_value(t, appearance_icon_theme(&a), "Adwaita") // the longer name before leaves nothing behind
	long := strings.repeat("x", 300, ta)
	settings_apply(&a, "org.gnome.desktop.interface", "icon-theme", dbus.variant(long, ta))
	testing.expect_value(t, len(appearance_icon_theme(&a)), 127) // cut to fit, still terminated
	// The GNOME colour scheme is ignored while org.freedesktop.appearance answers.
	testing.expect(t, !settings_apply(&a, "org.gnome.desktop.interface", "color-scheme", dbus.variant("prefer-dark", ta)))
	testing.expect_value(t, a.color_scheme, Color_Scheme.No_Preference)
	// …but used as a fallback when it does not.
	b := Appearance{text_scale = 1}
	testing.expect(t, settings_apply(&b, "org.gnome.desktop.interface", "color-scheme", dbus.variant("prefer-dark", ta)))
	testing.expect_value(t, b.color_scheme, Color_Scheme.Dark)
	testing.expect(t, settings_apply(&b, "org.gnome.desktop.a11y.interface", "high-contrast", dbus.variant(true, ta)))
	testing.expect(t, b.contrast_high)
	// Wrong types and unknown keys are ignored (on `a`, whose namespaces are
	// already marked present, so only the tracked fields could change).
	testing.expect(t, !settings_apply(&a, "org.freedesktop.appearance", "contrast", dbus.variant("high", ta)))
	testing.expect(t, !settings_apply(&a, "org.freedesktop.appearance", "font", dbus.variant("Inter", ta)))
	testing.expect(t, !settings_apply(&a, "com.example", "color-scheme", dbus.variant(u32(1), ta)))
	testing.expect(t, a.contrast_high)
}

@(test)
settings_readall_reply_folds_in_precedence_order :: proc(t: ^testing.T) {
	// A real reply's shape, GNOME namespace first: a{sa{sv}} with
	// org.gnome.desktop.interface color-scheme "prefer-light" but
	// org.freedesktop.appearance color-scheme 1 (dark). The portal namespace
	// wins regardless of dict order.
	ta := context.temp_allocator
	gnome := [3]dbus.Dict_Entry{
		{"color-scheme", "prefer-light"},
		{"enable-animations", true},
		{"text-scaling-factor", f64(1)},
	}
	fdo := [2]dbus.Dict_Entry{{"contrast", u32(0)}, {"color-scheme", u32(1)}}
	a11y := [1]dbus.Dict_Entry{{"high-contrast", false}}
	outer := [3]dbus.Dict_Entry{
		{"org.gnome.desktop.interface", dbus.dict_sv(gnome[:], ta)},
		{"org.gnome.desktop.a11y.interface", dbus.dict_sv(a11y[:], ta)},
		{"org.freedesktop.appearance", dbus.dict_sv(fdo[:], ta)},
	}
	reply := dbus.Value(dbus.Dict{key_sig = "s", value_sig = "a{sv}", entries = outer[:]})
	// Round-trip through the wire to be sure the shape is exactly ReadAll's.
	body := [1]dbus.Value{reply}
	m := dbus.method_call(DESKTOP_DEST, DESKTOP_PATH, IFACE_SETTINGS, "ReadAll", body[:])
	m.serial = 1
	bytes, _ := dbus.encode_message(&m, ta)
	testing.expect_value(t, m.signature, "a{sa{sv}}")
	d, derr := dbus.decode_message(bytes, ta)
	testing.expect_value(t, derr, dbus.Error.None)

	a := Appearance{text_scale = 1}
	testing.expect(t, appearance_from_readall(&a, d.body[0]))
	testing.expect_value(t, a.color_scheme, Color_Scheme.Dark)
	testing.expect_value(t, a.contrast_high, false)
	testing.expect_value(t, a.reduce_motion, false)
	testing.expect_value(t, a.text_scale, f32(1))
	testing.expect(t, a.has_appearance_ns && a.has_gnome_ns)
	testing.expect(t, !a.has_accent)
	testing.expect(t, !appearance_from_readall(&a, dbus.Value(u32(1))))
}

@(test)
uri_to_path_decodes_file_uris :: proc(t: ^testing.T) {
	ta := context.temp_allocator
	p, ok := uri_to_path("file:///home/user/a%20b.txt", ta)
	testing.expect(t, ok)
	testing.expect_value(t, p, "/home/user/a b.txt")
	p2, ok2 := uri_to_path("file://localhost/tmp/x%2Fy", ta)
	testing.expect(t, ok2)
	testing.expect_value(t, p2, "/tmp/x/y")
	_, ok3 := uri_to_path("https://example.org/a", ta)
	testing.expect(t, !ok3)
	p4, _ := uri_to_path("file:///plain", ta)
	testing.expect_value(t, p4, "/plain")
	p5, _ := uri_to_path("file:///odd%zz", ta) // a bad escape is kept as-is
	testing.expect_value(t, p5, "/odd%zz")

// A desktop states its font as a Pango description: a family and a size.
// The family and the size come back separately.
@(test)
settings_reads_the_font_family_without_its_size :: proc(t: ^testing.T) {
	ta := context.temp_allocator
	a := Appearance{text_scale = 1}
	settings_apply(&a, "org.gnome.desktop.interface", "font-name", dbus.variant("Cantarell 11", ta))
	settings_apply(&a, "org.gnome.desktop.interface", "monospace-font-name", dbus.variant("Source Code Pro 10", ta))
	testing.expect_value(t, appearance_font_family(&a), "Cantarell")
	testing.expect_value(t, appearance_mono_family(&a), "Source Code Pro")
	testing.expect_value(t, appearance_font_size(&a), 11)
}

// The pointer's theme and size, for a Wayland backend that draws its own
// cursor where the compositor has no cursor-shape protocol (GNOME's).
@(test)
settings_reads_the_cursor_theme_and_size :: proc(t: ^testing.T) {
	ta := context.temp_allocator
	a := Appearance{}
	testing.expect_value(t, appearance_cursor_theme(&a), "")
	testing.expect_value(t, a.cursor_size, 0)
	settings_apply(&a, "org.gnome.desktop.interface", "cursor-theme", dbus.variant("Breeze_Light", ta))
	settings_apply(&a, "org.gnome.desktop.interface", "cursor-size", dbus.variant(i32(32), ta))
	testing.expect_value(t, appearance_cursor_theme(&a), "Breeze_Light")
	testing.expect_value(t, a.cursor_size, 32)
	settings_apply(&a, "org.gnome.desktop.interface", "cursor-size", dbus.variant(i32(0), ta)) // nonsense is not taken
	testing.expect_value(t, a.cursor_size, 32)
}

// The UI font's size, in points, from every shape a description comes in;
// 0 when it states none. Pango's absolute "px" is 1/96 inch, so 14 px is
// 10.5 pt, and the family under it is "Sans", not "Sans 14px".
@(test)
settings_reads_the_ui_font_size :: proc(t: ^testing.T) {
	ta := context.temp_allocator
	a := Appearance{}
	cases := [?]struct { desc: string, size: f32, family: string }{
		{"Cantarell 11", 11, "Cantarell"},
		{"Noto Sans Bold 10.5", 10.5, "Noto Sans Bold"},
		{"Sans 14px", 10.5, "Sans"},
		{"Adwaita Sans 13 ", 13, "Adwaita Sans"},
		{"Inter", 0, "Inter"},  // no size: the desktop did not say
		{"11", 0, "11"},        // a size and no family: not a description
		{"Font2", 0, "Font2"},  // a number that is part of the name
		{"", 0, ""},
	}
	for c in cases {
		settings_apply(&a, "org.gnome.desktop.interface", "font-name", dbus.variant(c.desc, ta))
		testing.expectf(t, appearance_font_size(&a) == c.size, "%q: size %v, want %v", c.desc, appearance_font_size(&a), c.size)
		testing.expectf(t, appearance_font_family(&a) == c.family, "%q: family %q, want %q", c.desc, appearance_font_family(&a), c.family)
	}
}

@(test)
settings_font_family_handles_the_awkward_descriptions :: proc(t: ^testing.T) {
	ta := context.temp_allocator
	a := Appearance{}

	// no size at all: all of it is the family
	settings_apply(&a, "org.gnome.desktop.interface", "font-name", dbus.variant("Inter", ta))
	testing.expect_value(t, appearance_font_family(&a), "Inter")

	// a fractional size
	settings_apply(&a, "org.gnome.desktop.interface", "font-name", dbus.variant("Noto Sans 10.5", ta))
	testing.expect_value(t, appearance_font_family(&a), "Noto Sans")

	// A family whose name ends in a number loses it: Pango itself reads
	// "M PLUS 1" as the family "M PLUS" at size 1. The format is ambiguous,
	// and resolving it needs a font list, which belongs in the text engine.
	settings_apply(&a, "org.gnome.desktop.interface", "font-name", dbus.variant("M PLUS 1", ta))
	testing.expect_value(t, appearance_font_family(&a), "M PLUS")

	// nothing said
	b := Appearance{}
	testing.expect_value(t, appearance_font_family(&b), "")
}

}

@(private = "file")
Late_Seen :: struct { calls: int, scheme: Color_Scheme }

@(private = "file")
late_reading :: proc() -> dbus.Message {
	inner := make([]dbus.Dict_Entry, 1, context.temp_allocator)
	inner[0] = {key = "color-scheme", value = dbus.variant(u32(1), context.temp_allocator)}
	outer := make([]dbus.Dict_Entry, 1, context.temp_allocator)
	outer[0] = {key = "org.freedesktop.appearance", value = dbus.Dict{key_sig = "s", value_sig = "v", entries = inner}}
	body := make([]dbus.Value, 1, context.temp_allocator)
	body[0] = dbus.Dict{key_sig = "s", value_sig = "a{sv}", entries = outer}
	return dbus.Message{type = .Method_Return, body = body}
}

// The first reading waits only briefly. One that comes during the wait is
// the window's starting theme; one that comes after the window is up still
// reaches it, through the callback.
@(test)
a_late_appearance_reading_still_reaches_the_app :: proc(t: ^testing.T) {
	seen: Late_Seen
	sub := Settings_Subscription{cb = proc(user: rawptr, a: Appearance) {
		s := (^Late_Seen)(user)
		s.calls += 1
		s.scheme = a.color_scheme
	}, user = &seen}
	m := late_reading()
	on_read_all(nil, &m, .None, &sub) // during the wait: kept, not announced
	testing.expect(t, sub.read, "the reading is taken")
	testing.expect_value(t, sub.current.color_scheme, Color_Scheme.Dark)
	testing.expect_value(t, seen.calls, 0)

	late := Settings_Subscription{cb = sub.cb, user = &seen, waited = true}
	on_read_all(nil, &m, .None, &late) // after the window is up
	testing.expect_value(t, seen.calls, 1)
	testing.expect_value(t, seen.scheme, Color_Scheme.Dark)

	gone := Settings_Subscription{cb = sub.cb, user = &seen, waited = true}
	on_read_all(nil, nil, .Remote, &gone) // no portal: nothing to announce, and the wait can stop
	testing.expect(t, gone.refused && !gone.read, "a refusal ends the wait")
	testing.expect_value(t, seen.calls, 1)
}

} // when ODIN_TEST
