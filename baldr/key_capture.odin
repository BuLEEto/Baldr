package baldr

// Asking "what did they just press?" — the other direction from
// `shortcut(ui, "Ctrl+N", …)`, which says "when they press this, do that".
// A shortcut editor is the reason it exists: to rebind Super+Q, the chord
// has to reach the app instead of closing the window, and it has to arrive
// as something that can be written down and read back.
//
// While a view declares a capture, every key press goes to its handler
// instead of the focused widget and the window's shortcuts, and the
// desktop is asked to stop acting on its own shortcuts
// (`keyboard-shortcuts-inhibit-unstable-v1` on Wayland). A desktop that
// does not offer that keeps its shortcuts, and the chords it swallows never
// arrive — the capture still works for everything else.

import "core:reflect"
import "core:strings"

// Chord is one press, as a shortcut editor needs it: the portable key, what
// the platform calls it, and what was held down with it.
//
// `keysym` is the xkb keysym name on Linux — "q", "comma", "Print",
// "XF86AudioPlay" — which is what a compositor's configuration file is
// written in, and "" where the platform cannot say. It is valid while the
// message is handled; clone it to keep it.
//
// `held` is a chord still being pressed: only modifiers are down, and a
// field can show "Super + …" while someone reaches for the last key. The
// answer is the press where `held` is false.
Chord :: struct {
	key:    Key,
	keysym: string,
	mods:   Mods,
	held:   bool,
}

// Key_Capture is what the latest view asked for.
@(private)
Key_Capture :: struct($Msg: typeid) {
	on:      bool,
	inhibit: bool, // hold the desktop's own shortcuts off (a capture always does; inhibit_shortcuts alone also does)
	handler: Handler(Msg, Chord),
}

// key_capture takes the next chord. While `on`, every key press is reported
// to `handler` — with its modifiers, and again as they are pressed and
// released so a field can show the chord forming — instead of reaching the
// focused widget or the window's shortcuts, and the desktop is asked to
// hold its own shortcuts off so that Super+Q arrives rather than closing
// the window. Declare it from the view for as long as you are listening:
//
//	baldr.key_capture(ui, s.capturing, proc(e: baldr.Ev(baldr.Chord)) -> Msg {
//		return e.value.held ? Showing{e.value} : Captured{e.value}
//	})
//
// Escape is reported like any other key: a capture that should be
// cancellable does so itself. Nothing is captured while a modal dialog is
// open.
key_capture :: proc(ui: ^Ui($Msg), on: bool, handler: Handler(Msg, Chord), loc := #caller_location) {
	if !on do return
	ui.capture.on = true
	ui.capture.inhibit = true
	ui.capture.handler = handler
}

// inhibit_shortcuts asks the desktop to stop acting on its own keyboard
// shortcuts while this window has the keyboard, so they reach the app
// instead: a remote desktop or a virtual machine passing Super+Q to its
// guest, a game that binds it. `key_capture` does this for as long as it
// listens; this is the same thing without the capture.
//
// The desktop decides — a compositor without the protocol keeps its
// shortcuts, and one that has it usually keeps an escape hatch of its own
// so a window cannot hold the keyboard hostage. Declare it from the view
// for as long as you want it.
inhibit_shortcuts :: proc(ui: ^Ui($Msg), on: bool) {
	if on do ui.capture.inhibit = true
}

// capture_key offers a key press to the capture, which takes every one of
// them while it is listening. Called by the run loop before the focused
// widget sees it.
@(private)
capture_key :: proc(ui: ^Ui($Msg), key: Key, pressed: bool, mods: Mods, keysym: string) -> bool {
	if !ui.capture.on || ui.tree.modal != NODE_NONE do return false
	held := key_is_modifier(key)
	if !pressed && !held do return true // the press was the answer; swallow the release
	c := Chord{key = key, keysym = keysym, mods = mods, held = held}
	if !pressed { // a modifier let go: the chord being shown is smaller now
		c.mods = mods - mods_of_key(key)
	}
	handler_send(ui, ui.capture.handler, c, NODE_NONE)
	return true
}

// capture_takes_text says the text a key would have typed belongs to the
// capture too: a chord being pressed must not also be typed into whatever
// had focus (a search field in the same pane).
@(private)
capture_takes_text :: proc(ui: ^Ui($Msg)) -> bool {
	return ui.capture.on && ui.tree.modal == NODE_NONE
}

// key_is_modifier: a key that cannot be a chord by itself.
@(private)
key_is_modifier :: proc(key: Key) -> bool {
	#partial switch key {
	case .Shift_L, .Shift_R, .Ctrl_L, .Ctrl_R, .Alt_L, .Alt_R, .Super_L, .Super_R: return true
	}
	return false
}

// mods_of_key is the modifier a modifier key stands for, so letting one go
// can be taken off the chord being shown.
@(private)
mods_of_key :: proc(key: Key) -> Mods {
	#partial switch key {
	case .Shift_L, .Shift_R: return {.Shift}
	case .Ctrl_L, .Ctrl_R:   return {.Ctrl}
	case .Alt_L, .Alt_R:     return {.Alt}
	case .Super_L, .Super_R: return {.Super}
	}
	return {}
}

// chord_text writes a chord the way a person reads it — "Super+Shift+Q",
// "Ctrl+Comma", "Volume Up" — for the field that shows what was pressed.
// A chord still being held ends in a "+", so it reads as unfinished. The
// text is in temp memory by default: copy it into a message you keep.
chord_text :: proc(c: Chord, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	if .Ctrl in c.mods do strings.write_string(&b, "Ctrl+")
	if .Alt in c.mods do strings.write_string(&b, "Alt+")
	if .Shift in c.mods do strings.write_string(&b, "Shift+")
	if .Super in c.mods do strings.write_string(&b, "Super+")
	if c.held {
		return strings.to_string(b) // "Super+Shift+", still being pressed
	}
	strings.write_string(&b, key_text(c.key, c.keysym))
	return strings.to_string(b)
}

// key_text is a key's name for a person: the portable name with its
// underscores opened out ("Page Up", "Volume Up"), or what the platform
// called it when the enum has no name for it.
@(private)
key_text :: proc(key: Key, keysym: string, allocator := context.temp_allocator) -> string {
	if key == .Unknown do return keysym
	name, ok := reflect.enum_name_from_value(key)
	if !ok do return keysym
	out := strings.builder_make(allocator)
	for r in name do strings.write_rune(&out, ' ' if r == '_' else r)
	return strings.to_string(out)
}
