#+build linux
// portal_check — live check of baldr:sys/portal: reads the appearance from
// org.freedesktop.portal.Settings, subscribes to SettingChanged and prints
// every change for a few seconds, and optionally exercises the FileChooser
// and OpenURI portals (interactive: a dialog / browser opens).
//
//   ./build/portal_check [--seconds N] [--file-open] [--file-save] [--open-uri URI]
//
// Flip the colour scheme while it runs:
//   gsettings set org.gnome.desktop.interface color-scheme prefer-light
//   gsettings set org.gnome.desktop.interface color-scheme prefer-dark
//   gsettings set org.gnome.desktop.interface enable-animations false
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"
import "baldr:dbus"
import portal "baldr:sys/portal"

Opts :: struct {
	seconds:   f64,
	file_open: bool,
	file_save: bool,
	open_uri:  string,
}

parse_args :: proc() -> (o: Opts, ok: bool) {
	o.seconds = 5
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--seconds":
			if i + 1 >= len(args) do return o, false
			i += 1
			o.seconds, ok = strconv.parse_f64(args[i])
			if !ok do return o, false
		case "--file-open":
			o.file_open = true
		case "--file-save":
			o.file_save = true
		case "--open-uri":
			if i + 1 >= len(args) do return o, false
			i += 1
			o.open_uri = args[i]
		case "--help", "-h":
			fmt.println("usage: portal_check [--seconds N] [--file-open] [--file-save] [--open-uri URI]")
			os.exit(0)
		case:
			fmt.eprintln("unknown argument:", args[i])
			return o, false
		}
	}
	return o, true
}

print_appearance :: proc(prefix: string, a: portal.Appearance) {
	fmt.printfln("%s color_scheme=%v accent=%v (has_accent=%v) contrast_high=%v reduce_motion=%v reduce_transparency=%v text_scale=%.2f [fdo ns=%v gnome ns=%v]",
		prefix, a.color_scheme, a.accent, a.has_accent, a.contrast_high, a.reduce_motion, a.reduce_transparency, a.text_scale, a.has_appearance_ns, a.has_gnome_ns)
}

Watch :: struct {
	start:   time.Tick,
	changes: int,
}

on_change :: proc(user: rawptr, a: portal.Appearance) {
	w := (^Watch)(user)
	w.changes += 1
	print_appearance(fmt.tprintf("[%7.1f ms] SettingChanged ->", time.duration_milliseconds(time.tick_since(w.start))), a)
}

Dialog :: struct {
	done: bool,
	kind: string,
}

on_files :: proc(user: rawptr, r: portal.File_Result) {
	d := (^Dialog)(user)
	d.done = true
	fmt.printfln("%s: response=%v uris=%v", d.kind, r.response, r.uris)
}

on_uri :: proc(user: rawptr, r: portal.Response) {
	d := (^Dialog)(user)
	d.done = true
	fmt.printfln("OpenURI: response=%v", r)
}

// pump polls + dispatches until `stop` or the deadline.
pump :: proc(conn: ^dbus.Connection, seconds: f64, stop: ^bool) {
	start := time.tick_now()
	for !(stop != nil && stop^) {
		left := seconds - time.duration_seconds(time.tick_since(start))
		if left <= 0 do break
		readable, perr := dbus.wait_readable(conn, i32(min(left * 1000, 200)))
		if perr != .None {
			fmt.eprintln("poll error:", perr)
			return
		}
		if readable {
			if _, derr := dbus.dispatch(conn); derr != .None {
				fmt.eprintln("dispatch error:", derr)
				return
			}
		}
	}
}

main :: proc() {
	opts, aok := parse_args()
	if !aok do os.exit(2)

	conn, err := dbus.connect_session()
	if err != .None {
		fmt.eprintln("portal_check: session bus unavailable:", err)
		os.exit(1)
	}
	defer dbus.disconnect(conn)
	fmt.printfln("connected as %s", conn.unique_name)

	running, activatable := portal.portal_available(conn)
	fmt.printfln("org.freedesktop.portal.Desktop: running=%v activatable=%v", running, activatable)

	t0 := time.tick_now()
	a, ok := portal.settings_read_appearance(conn)
	fmt.printfln("ReadAll took %.1f ms, ok=%v", time.duration_milliseconds(time.tick_since(t0)), ok)
	print_appearance("appearance:", a)
	if !ok {
		fmt.println("portal_check: no Settings portal; every call above failed gracefully (ok=false). Nothing to subscribe to.")
		return
	}

	if opts.open_uri != "" {
		d := Dialog{kind = "OpenURI"}
		if portal.open_uri(conn, opts.open_uri, cb = on_uri, user = &d) {
			pump(conn, 30, &d.done)
			if !d.done do fmt.println("OpenURI: no response within 30 s")
		} else {
			fmt.println("OpenURI: request could not be sent")
		}
	}
	if opts.file_open {
		d := Dialog{kind = "OpenFile"}
		filters := [1]portal.File_Filter{{name = "Images", patterns = {"*.png", "*.jpg"}}}
		o := portal.Open_Options{title = "Baldr portal_check", accept_label = "Pick it", multiple = true, filters = filters[:]}
		if portal.file_chooser_open(conn, o, on_files, &d) {
			fmt.println("OpenFile: dialog requested, waiting up to 120 s …")
			pump(conn, 120, &d.done)
			if !d.done do fmt.println("OpenFile: no response within 120 s")
		} else {
			fmt.println("OpenFile: request could not be sent")
		}
	}
	if opts.file_save {
		d := Dialog{kind = "SaveFile"}
		o := portal.Save_Options{title = "Baldr portal_check save", current_name = "untitled.txt"}
		if portal.file_chooser_save(conn, o, on_files, &d) {
			fmt.println("SaveFile: dialog requested, waiting up to 120 s …")
			pump(conn, 120, &d.done)
			if !d.done do fmt.println("SaveFile: no response within 120 s")
		} else {
			fmt.println("SaveFile: request could not be sent")
		}
	}

	w := Watch{start = time.tick_now()}
	sub, sok := portal.settings_subscribe(conn, on_change, &w)
	if !sok {
		fmt.println("settings_subscribe failed")
		os.exit(1)
	}
	defer portal.settings_unsubscribe(sub)
	fmt.printfln("subscribed to SettingChanged; watching for %.0f s (flip: gsettings set org.gnome.desktop.interface color-scheme prefer-light|prefer-dark)", opts.seconds)
	pump(conn, opts.seconds, nil)
	fmt.printfln("portal_check: %d change(s) observed", w.changes)
	print_appearance("final:", sub.current)
}
