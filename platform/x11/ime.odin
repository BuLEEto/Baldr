#+build linux
package x11

// Input methods on X11, through ibus over D-Bus.
//
// ibus rather than XIM: XIM means Xlib or a C library, both forbidden by
// the dependency rule, while ibus needs only D-Bus.
//
// ibus does not send strings: it sends its own objects serialised into
// D-Bus variants, and `CommitText` and `UpdatePreeditText` both carry one.
// The shapes, as a running `ibus-daemon` sends them:
//
//	UpdatePreeditText(v, u cursor_pos, b visible)
//	  v     = ('IBusText',      a{sv}, s text, v attrs)
//	  attrs = ('IBusAttrList',  a{sv}, av)
//	  attr  = ('IBusAttribute', a{sv}, u type, u value, u start, u end)
//
// Typing k, a, n, a in a Japanese engine gives the preedit "k", then "か",
// then "かn", each with one attribute of type 1 (underline) covering it.

import "core:fmt"
import "core:os"
import "core:strings"
import "baldr:dbus"
import "baldr:platform"

// IBus_Text is what an IBusText carried: the text, and the part of it the
// input method has underlined or highlighted.
//
// `text` points into the D-Bus connection's arena and is valid until the
// next dispatch — copy what is kept, as the rest of the backend does with
// event strings.
@(private)
IBus_Text :: struct {
	text:  string,
	attrs: []IBus_Attr,
}

// IBus_Attr is one run of the preedit marked by the input method. `kind` 1
// is an underline, 2 a foreground colour, 3 a background; `start` and `end`
// are in characters, not bytes.
@(private)
IBus_Attr :: struct {
	kind, value: u32,
	start, end:  u32,
}

@(private) IBUS_ATTR_UNDERLINE :: 1

// ibus_text reads an IBusText out of the variant ibus sent. False for
// anything that is not one — a different object, a truncated struct, a
// daemon speaking a shape this does not know.
//
// Strict about the type name: guessing from the shape alone would read an
// IBusEngineDesc as text.
@(private)
ibus_text :: proc(v: dbus.Value) -> (out: IBus_Text, ok: bool) {
	st := ibus_object(v, "IBusText") or_return
	// ('IBusText', attachments, text, attrs)
	if len(st) < 3 do return {}, false
	out.text = dbus.as_string(st[2]) or_return
	if len(st) >= 4 {
		if list, has := ibus_object(st[3], "IBusAttrList"); has && len(list) >= 3 {
			arr, is_arr := dbus.as_array(list[2])
			if is_arr {
				attrs := make([dynamic]IBus_Attr, 0, len(arr.items), context.temp_allocator)
				for item in arr.items {
					a, got := ibus_attr(item)
					if got do append(&attrs, a)
				}
				out.attrs = attrs[:]
			}
		}
	}
	return out, true
}

// ibus_attr reads one IBusAttribute: ('IBusAttribute', a{sv}, u, u, u, u).
@(private = "file")
ibus_attr :: proc(v: dbus.Value) -> (out: IBus_Attr, ok: bool) {
	st := ibus_object(v, "IBusAttribute") or_return
	if len(st) < 6 do return {}, false
	n := [4]u32{}
	for i in 0 ..< 4 {
		u, is_u := st[2 + i].(u32)
		if !is_u do return {}, false
		n[i] = u
	}
	return {kind = n[0], value = n[1], start = n[2], end = n[3]}, true
}

// ibus_object unwraps a variant holding one of ibus's serialised objects and
// checks its type name, returning the struct's fields.
//
// Every one begins with its name and an attachment dictionary.
@(private)
ibus_object :: proc(v: dbus.Value, name: string) -> (fields: []dbus.Value, ok: bool) {
	inner := dbus.unwrap(v)
	st, is_struct := inner.(dbus.Struct)
	if !is_struct || len(st.fields) < 2 do return nil, false
	got, is_name := dbus.as_string(st.fields[0])
	if !is_name || got != name do return nil, false
	return st.fields[:], true
}

// ibus_cursor_bytes turns ibus's cursor position, in characters, into the
// byte offset `Ev_Ime` wants.
//
// A preedit of "かn" with cursor 2 is byte 4, not byte 2; using the count
// as bytes puts the caret inside a character.
@(private)
ibus_cursor_bytes :: proc(text: string, chars: u32) -> i32 {
	if chars == 0 do return 0
	n: u32 = 0
	for _, i in text { // ranging a string walks runes, i is the byte index
		if n == chars do return i32(i)
		n += 1
	}
	return i32(len(text))
}

// ---------------------------------------------------------------- the bus

// Ime is the connection to the input method and the context it gave us.
// Zero when there is no input method, which is the ordinary case on a
// desktop with nothing installed: everything below then does nothing and
// keys take their usual path.
@(private)
Ime :: struct {
	bus:     ^dbus.Connection,
	path:    string, // the input context's object path; "" = none
	on:      bool,   // the toolkit asked for composing
	focused: bool,   // …and the context has been told
	caret:   [4]i32, // the last rectangle sent, to avoid saying it twice
}

@(private = "file") IBUS_SERVICE :: "org.freedesktop.IBus"
@(private = "file") IBUS_PATH    :: "/org/freedesktop/IBus"
@(private = "file") IBUS_IFACE   :: "org.freedesktop.IBus"
@(private = "file") IC_IFACE     :: "org.freedesktop.IBus.InputContext"

// What we can show. Not the lookup table or auxiliary text: leaving those
// unset makes ibus draw its own candidate window, matching the rest of the
// desktop. Baldr draws only the preedit.
@(private = "file") CAP_PREEDIT     :: 1 << 0
@(private = "file") CAP_FOCUS       :: 1 << 3
@(private = "file") CAP_SURROUNDING :: 1 << 5

// ime_address finds the input method's bus, which is not the session bus:
// ibus runs its own. `IBUS_ADDRESS` names it when set; otherwise it is in a
// `KEY=value` file under the user's config, keyed by machine id and display.
// "" when there is no input method, which is not an error.
@(private = "file")
ime_address :: proc(x: ^X11, allocator := context.temp_allocator) -> string {
	if env := os.get_env("IBUS_ADDRESS", context.temp_allocator); env != "" do return strings.clone(env, allocator)

	home := os.get_env("HOME", context.temp_allocator)
	if home == "" do return ""
	machine := ime_machine_id()
	if machine == "" do return ""

	// The display part: ":0" is "unix-0"; under Wayland ibus writes
	// "unix-wayland-0" as well, and an app on X wants the X one.
	disp := os.get_env("DISPLAY", context.temp_allocator)
	num := disp
	if i := strings.index_byte(disp, ':'); i >= 0 do num = disp[i + 1:]
	if i := strings.index_byte(num, '.'); i >= 0 do num = num[:i]
	if num == "" do num = "0"

	path := fmt.tprintf("%s/.config/ibus/bus/%s-unix-%s", home, machine, num)
	raw, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_err != nil do return ""
	text := string(raw)
	for line in strings.split_lines_iterator(&text) {
		if !strings.has_prefix(line, "IBUS_ADDRESS=") do continue
		return strings.clone(strings.trim_space(line[len("IBUS_ADDRESS="):]), allocator)
	}
	return ""
}

@(private = "file")
ime_machine_id :: proc() -> string {
	for p in ([]string{"/etc/machine-id", "/var/lib/dbus/machine-id"}) {
		if data, err := os.read_entire_file_from_path(p, context.temp_allocator); err == nil {
			return strings.trim_space(string(data))
		}
	}
	return ""
}

// ime_start connects to the input method and asks it for a context.
//
// Best-effort: no input method, a silent daemon or a refused context all
// leave `x.ime` zeroed, and the backend carries on without composing.
@(private)
ime_start :: proc(x: ^X11) {
	addr := ime_address(x)
	if addr == "" {
		debugf(x, "no input method: IBUS_ADDRESS unset and no address file")
		return
	}
	conn, err := dbus.connect_address(addr, x.allocator)
	if err != nil {
		debugf(x, "input method: cannot reach %s (%v)", addr, err)
		return
	}
	x.ime.bus = conn

	call := dbus.method_call(IBUS_SERVICE, IBUS_PATH, IBUS_IFACE, "CreateInputContext",
		{dbus.Value("baldr")})
	reply, cerr := dbus.call(conn, &call, allocator = context.temp_allocator)
	if cerr != nil || len(reply.body) < 1 {
		debugf(x, "input method: CreateInputContext failed (%v)", cerr)
		ime_stop(x)
		return
	}
	path, is_path := dbus.as_object_path(reply.body[0])
	if !is_path {
		debugf(x, "input method: CreateInputContext answered something that is not a path")
		ime_stop(x)
		return
	}
	x.ime.path = strings.clone(path, x.allocator)

	ime_call(x, "SetCapabilities", {dbus.Value(u32(CAP_PREEDIT | CAP_FOCUS | CAP_SURROUNDING))})

	// The signals that become Ev_Ime. They are only sent to this context, so
	// the match is narrowed by path as well as interface.
	for member in ([]string{"CommitText", "UpdatePreeditText", "ShowPreeditText",
		"HidePreeditText", "DeleteSurroundingText"}) {
		dbus.add_match(conn, fmt.tprintf("type='signal',interface='%s',member='%s',path='%s'",
			IC_IFACE, member, x.ime.path))
		dbus.on_signal(conn, IC_IFACE, member, ime_signal, x, path = x.ime.path)
	}
	debugf(x, "input method: ibus at %s, context %s", addr, x.ime.path)
}

@(private)
ime_stop :: proc(x: ^X11) {
	if x.ime.bus != nil do dbus.disconnect(x.ime.bus)
	if x.ime.path != "" do delete(x.ime.path, x.allocator)
	x.ime = {}
}

// ime_call sends one method to the input context and does not wait. Nothing
// here needs an answer — `ProcessKeyEvent` is the exception and has its own
// path — and waiting would put the input method in front of the frame.
@(private = "file")
ime_call :: proc(x: ^X11, member: string, body: []dbus.Value = nil) {
	if x.ime.bus == nil || x.ime.path == "" do return
	m := dbus.method_call(IBUS_SERVICE, x.ime.path, IC_IFACE, member, body)
	dbus.call_async(x.ime.bus, &m, nil, nil)
}

// ime_poll gives the input method's bus its turn, once a pump, as the
// session bus gets one.
@(private)
ime_poll :: proc(x: ^X11) {
	if x.ime.bus == nil do return
	dbus.dispatch(x.ime.bus)
}

// ime_signal turns what the input method says into `Ev_Ime`.
//
// An Ev_Ime is one round applied in order: remove the preedit, delete
// around the caret, insert the commit, show the new preedit. ibus sends
// each part as its own signal in that order, so each is pushed as it
// arrives with the rest zero: a commit and its following preedit are two
// rounds.
@(private = "file")
ime_signal :: proc(conn: ^dbus.Connection, sig: ^dbus.Message, user: rawptr) {
	x := (^X11)(user)
	s := ime_surface(x)
	if s == nil do return

	switch sig.member {
	case "CommitText":
		if len(sig.body) < 1 do return
		t, ok := ibus_text(sig.body[0])
		if !ok || t.text == "" do return
		push(x, platform.Ev_Ime{surface = s.id, commit = ime_keep(x, t.text)})

	case "UpdatePreeditText":
		if len(sig.body) < 3 do return
		t, ok := ibus_text(sig.body[0])
		if !ok do return
		visible, _ := sig.body[2].(bool)
		if !visible { // hidden: the preedit is gone, which is an empty one
			push(x, platform.Ev_Ime{surface = s.id, cursor_begin = -1, cursor_end = -1})
			return
		}
		cursor_chars, _ := sig.body[1].(u32)
		at := ibus_cursor_bytes(t.text, cursor_chars)
		push(x, platform.Ev_Ime{
			surface = s.id, preedit = ime_keep(x, t.text),
			cursor_begin = at, cursor_end = at,
		})

	case "HidePreeditText":
		push(x, platform.Ev_Ime{surface = s.id, cursor_begin = -1, cursor_end = -1})

	case "ShowPreeditText":
		// Nothing to do on its own: the text came with UpdatePreeditText,
		// and showing an empty one would clear what is there.

	case "DeleteSurroundingText":
		if len(sig.body) < 2 do return
		offset, _ := sig.body[0].(i32)
		n, _ := sig.body[1].(u32)
		// ibus counts characters from the caret, negative before it. The
		// contract wants bytes either side, so a negative offset is "before".
		ev := platform.Ev_Ime{surface = s.id, cursor_begin = -1, cursor_end = -1}
		if offset < 0 {
			ev.delete_before = u32(-offset)
			ev.delete_after = u32(max(i32(n) + offset, 0))
		} else {
			ev.delete_after = n
		}
		push(x, ev)
	}
}

// ime_keep copies a string out of the bus's arena into the text arena the
// rest of the backend's events use, which lives until the next pump.
@(private = "file")
ime_keep :: proc(x: ^X11, s: string) -> string {
	return strings.clone(s, text_allocator(x))
}

// ime_surface is the surface composing now: the one with the keyboard.
@(private = "file")
ime_surface :: proc(x: ^X11) -> ^Surface {
	return x.kbd_focus
}

// ime_set is the toolkit saying what the focused field is, where it is, and
// whether to compose at all (platform.Backend).
@(private)
ime_set :: proc(b: ^platform.Backend, st: platform.Ime_State) {
	x := data(b)
	if x.ime.bus == nil || x.ime.path == "" do return

	if st.on != x.ime.on {
		x.ime.on = st.on
		if st.on { ime_call(x, "FocusIn") } else { ime_call(x, "FocusOut") }
		x.ime.focused = st.on
		if !st.on {
			ime_call(x, "Reset")
			return
		}
	}
	if !st.on do return

	// Where the candidate window should sit, sent only when it moves: each
	// one is a D-Bus message.
	s := get_surface(x, st.surface)
	sx, sy: i32
	if s != nil do sx, sy = s.pos.x, s.pos.y
	sc := x.scale if x.scale > 0 else 1
	rect := [4]i32{
		sx + i32(st.caret.x * sc), sy + i32(st.caret.y * sc),
		i32(st.caret.z * sc), i32(st.caret.w * sc),
	}
	if rect != x.ime.caret {
		x.ime.caret = rect
		ime_call(x, "SetCursorLocation", {dbus.Value(rect[0]), rect[1], rect[2], rect[3]})
	}
}
