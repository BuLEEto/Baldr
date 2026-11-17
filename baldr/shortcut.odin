package baldr

// Window-level keyboard shortcuts. A view declares them like anything
// else it builds; a key the focused widget does not use is matched
// against them and the message goes to update. A menu item's `shortcut`
// text shows the binding; `shortcut(ui, …)` is what makes it work.

import "base:runtime"
import "core:fmt"
import "core:reflect"
import "core:strings"

// Shortcut is one binding of the latest view.
Shortcut :: struct($Msg: typeid) {
	key:  Key,
	mods: Mods,
	msg:  Msg,
}

// shortcut binds `keys` to `msg` for the window while the view declares
// it: "Ctrl+N", "Ctrl+Shift+N", "F2", "Delete", "Alt+Left", "Ctrl++".
// Modifiers are Ctrl, Shift, Alt and Super (also Cmd / Meta / Win); the
// key is a letter, digit, F-key, arrow or a name such as Delete, Enter,
// Escape, Space, Home, Page_Up, Comma. A key the focused widget uses
// (Delete in a text field, Ctrl+C in an editor) stays with the widget,
// and so does a character being typed: a binding on a printable key with
// no Ctrl, Alt or Super ("/", "R", "Shift+/") waits while the focus is a
// text field, an editable text area, a time picker taking digits or a view
// with type-ahead. Nothing fires while a modal dialog is open. A string that does not
// parse is reported as a build diagnostic and binds nothing.
//
//	baldr.shortcut(ui, "F2", Rename{})
//	baldr.shortcut(ui, "Ctrl+Shift+N", New_Folder{})
shortcut :: proc(ui: ^Ui($Msg), keys: string, msg: Msg, loc := #caller_location) {
	key, mods, ok := parse_shortcut(keys)
	if !ok {
		append(&ui.diags, Diag{msg = shortcut_complaint(keys, ui.allocator), loc = loc})
		return
	}
	append(&ui.shortcuts, Shortcut(Msg){key = key, mods = mods, msg = msg})
}

// shortcut_bound says whether the latest view bound `key` + `mods`: a
// toolkit chord that is also a common command (Ctrl+X picking an item up
// for a keyboard drag) yields to the app's own binding of it.
shortcut_bound :: proc(ui: ^Ui($Msg), key: Key, mods: Mods) -> bool {
	for s in ui.shortcuts do if s.key == key && s.mods == mods do return true
	return false
}

// shift_chord_bound says a Ctrl+Shift chord belongs to the app rather than
// to the widget the keyboard is in: the app bound that exact chord, and it
// is one a widget treats the same with or without Shift (C, X, V, A, Y), so
// letting the app have it takes nothing away. Unbound, the widget keeps it.
// Ctrl+Shift+Left and Ctrl+Shift+Z mean something with Shift held and are
// never on the list.
@(private)
shift_chord_bound :: proc(ui: ^Ui($Msg), key: Key, mods: Mods) -> bool {
	if .Ctrl not_in mods || .Shift not_in mods do return false
	#partial switch key {
	case .A, .C, .X, .V, .Y:
		return shortcut_bound(ui, key, mods)
	}
	return false
}

// shortcut_fire sends the message bound to `key` + `mods`, if any. Called
// by the run loop for a key press no widget consumed.
shortcut_fire :: proc(ui: ^Ui($Msg), key: Key, pressed: bool, mods: Mods) -> bool {
	if !pressed || key == .Unknown || ui.tree.modal != NODE_NONE do return false
	if typing_takes(ui, key, mods) do return false // its character comes next, as text, for the focused widget
	for s in ui.shortcuts {
		if s.key != key || s.mods != mods do continue
		append(&ui.msgs, s.msg)
		return true
	}
	return false
}

// key_prints: a key that types a character when nothing but Shift is held.
// A predicate rather than a set: Key has more values than a bit_set holds.
@(private)
key_prints :: proc "contextless" (key: Key) -> bool {
	#partial switch key {
	case .Space, .A, .B, .C, .D, .E, .F, .G, .H, .I, .J, .K, .L, .M, .N, .O, .P, .Q, .R, .S, .T, .U, .V, .W, .X, .Y, .Z,
		.N0, .N1, .N2, .N3, .N4, .N5, .N6, .N7, .N8, .N9,
		.Minus, .Equal, .Comma, .Period, .Slash, .Grave, .Bracket_L, .Bracket_R, .Backslash, .Semicolon, .Apostrophe:
		return true
	}
	return false
}

// typing_takes says whether the focused widget takes the character `key`
// types, which arrives after the key as text: a key press alone looks
// unused, so a shortcut must not take it first.
@(private)
typing_takes :: proc(ui: ^Ui($Msg), key: Key, mods: Mods) -> bool {
	if !key_prints(key) || mods & {.Ctrl, .Alt, .Super} != {} do return false
	t := &ui.tree
	if _, _, _, is_field := focused_input(t); is_field do return true
	if _, _, area, is_area := focused_area(t); is_area do return !area.readonly
	if tp, is_time := t.times[t.focus]; is_time { // time_type: digits, and A / P for the period
		if d := node_get(t, t.focus); d == nil || .Disabled in d.flags do return false
		if tp.cursor == .Period do return true
		return (key >= .N0 && key <= .N9) || ((key == .A || key == .P) && tp.segs[.Period] != NODE_NONE)
	}
	if key == .Space do return false // Space selects in a view; a blank never starts type-ahead
	if ts, is_table := t.tables[t.focus]; is_table do return ts.label_of != nil && ts.count > 0
	if vs, is_icons := t.icon_views[t.focus]; is_icons do return vs.label_of != nil && vs.count > 0
	return false
}

@(private)
shortcut_complaint :: proc(keys: string, allocator: runtime.Allocator) -> string {
	return fmt.aprintf("shortcut %q is not a key combination", keys, allocator = allocator)
}

// parse_shortcut reads "Ctrl+Shift+F2" into a key and its modifiers.
parse_shortcut :: proc(s: string) -> (key: Key, mods: Mods, ok: bool) {
	parts := strings.split(s, "+", context.temp_allocator)
	for part, i in parts {
		tok := strings.trim_space(part)
		if len(tok) == 0 {
			if i == len(parts) - 1 && i > 0 && key == .Unknown { // "Ctrl++": the plus key
				key = .Equal
				continue
			}
			continue
		}
		low := strings.to_lower(tok, context.temp_allocator)
		switch low {
		case "ctrl", "control", "ctl":
			mods += {.Ctrl}
			continue
		case "shift":
			mods += {.Shift}
			continue
		case "alt", "option", "opt":
			mods += {.Alt}
			continue
		case "super", "meta", "cmd", "command", "win", "windows":
			mods += {.Super}
			continue
		}
		if key != .Unknown do return .Unknown, {}, false // two keys
		k, found := key_from_name(low)
		if !found do return .Unknown, {}, false
		key = k
	}
	if key == .Unknown do return .Unknown, {}, false
	return key, mods, true
}

// key_from_name maps a lower-case token to a Key: aliases first, then
// the enum's own names (page_up, f10, a).
@(private)
key_from_name :: proc(low: string) -> (Key, bool) {
	switch low {
	case "del":                 return .Delete, true
	case "esc":                 return .Escape, true
	case "return":              return .Enter, true
	case "pgup", "pageup":      return .Page_Up, true
	case "pgdn", "pgdown", "pagedown": return .Page_Down, true
	case "ins":                 return .Insert, true
	case "plus", "=":           return .Equal, true
	case "minus", "-":          return .Minus, true
	case "comma", ",":          return .Comma, true
	case "period", "dot", ".":  return .Period, true
	case "/":                   return .Slash, true
	case ";":                   return .Semicolon, true
	case "'":                   return .Apostrophe, true
	case "`", "backtick":       return .Grave, true
	case "[":                   return .Bracket_L, true
	case "]":                   return .Bracket_R, true
	case "\\":                  return .Backslash, true
	case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
		return Key(int(Key.N0) + int(low[0] - '0')), true
	}
	// Ada_Case the token: "page_up" → "Page_Up", "f10" → "F10"
	b := strings.builder_make(context.temp_allocator)
	up := true
	for c in low {
		r := c
		if r == ' ' do r = '_'
		if up && r >= 'a' && r <= 'z' do r -= 32
		strings.write_rune(&b, r)
		up = r == '_'
	}
	return reflect.enum_from_name(Key, strings.to_string(b))
}
