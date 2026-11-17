#+build darwin
package cocoa

// What this keyboard calls a key (Backend.key_name).
//
// `Ev_Key.native` on macOS is the virtual key code, which is positional:
// code 12 is where Q sits on a US keyboard whatever the key types
// (keys.odin), so it cannot be shown to a person. Carbon's `UCKeyTranslate`
// asks the current layout what a code types with no modifiers held, as
// `GetKeyNameTextW` does on Windows and the keysym name on Linux.
//
// It is not an xkb name: macOS has no such vocabulary. A printing key is
// its character ("," not "comma"), and a key with no character takes the
// name macOS shows in its menus. A configuration file shared across
// platforms keys by `Key`, not by this string.

import "base:runtime"
import "core:strings"
import "core:unicode/utf8"
import "baldr:platform"

foreign import Carbon "system:Carbon.framework"
foreign import CF "system:CoreFoundation.framework"

@(private) UC_KEY_ACTION_DISPLAY     :: u16(3) // "as it would be shown", not as typed
@(private) UC_KEY_TRANSLATE_NO_DEAD  :: u32(1) // …and do not start a dead-key sequence

@(default_calling_convention = "c")
foreign Carbon {
	TISCopyCurrentKeyboardLayoutInputSource :: proc() -> rawptr ---
	TISGetInputSourceProperty :: proc(source: rawptr, key: rawptr) -> rawptr ---
	LMGetKbdType :: proc() -> u8 ---
	UCKeyTranslate :: proc(
		layout: rawptr, code: u16, action: u16, modifiers: u32, kbd_type: u32,
		options: u32, dead_state: ^u32, max_len: uint, actual_len: ^uint, out: [^]u16) -> i32 ---
	kTISPropertyUnicodeKeyLayoutData: rawptr
}

@(default_calling_convention = "c")
foreign CF {
	CFDataGetBytePtr :: proc(data: rawptr) -> [^]u8 ---
	CFRelease :: proc(cf: rawptr) ---
}

// NAMED is every key that types nothing, by virtual key code. The names are
// the ones macOS shows for them, so what an app prints matches what the
// person reads elsewhere on their own machine.
@(private, rodata)
NAMED := #partial [128]string{
	36 = "Return", 48 = "Tab", 49 = "Space", 51 = "Delete", 53 = "Escape",
	55 = "Command", 56 = "Shift", 57 = "Caps Lock", 58 = "Option", 59 = "Control",
	60 = "Right Shift", 61 = "Right Option", 62 = "Right Control", 63 = "Function",
	64 = "F17", 71 = "Clear", 76 = "Enter", 79 = "F18", 80 = "F19",
	90 = "F20", 96 = "F5", 97 = "F6", 98 = "F7", 99 = "F3", 100 = "F8", 101 = "F9",
	103 = "F11", 105 = "F13", 106 = "F16", 107 = "F14", 109 = "F10", 111 = "F12",
	113 = "F15", 114 = "Help", 115 = "Home", 116 = "Page Up", 117 = "Forward Delete",
	118 = "F4", 119 = "End", 120 = "F2", 121 = "Page Down", 122 = "F1",
	123 = "Left", 124 = "Right", 125 = "Down", 126 = "Up",
}

@(private)
b_key_name :: proc(b: ^platform.Backend, native: u32, allocator := context.allocator) -> string {
	return key_name_of(native, allocator)
}

// key_name_of is b_key_name without a Backend, so `spikes/key_names` can
// ask about a code without a window. The string is the caller's, from `allocator`; ""
// when the key has no name.
key_name_of :: proc(native: u32, allocator := context.allocator) -> string {
	if native < u32(len(NAMED)) && NAMED[native] != "" {
		out, err := strings.clone(NAMED[native], allocator)
		return out if err == nil else ""
	}
	typed := key_typed(u16(native), allocator)
	return typed
}

// key_typed asks the layout what this code types with nothing held. "" when
// there is no layout to ask or the key types nothing printable — a caller
// then has `Key` and the number, which is all macOS can honestly give.
@(private = "file")
key_typed :: proc(code: u16, allocator: runtime.Allocator) -> string {
	src := TISCopyCurrentKeyboardLayoutInputSource()
	if src == nil do return ""
	defer CFRelease(src)
	data := TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData)
	if data == nil do return "" // a layout with no Unicode table: an old-style KCHR
	layout := CFDataGetBytePtr(data)
	if layout == nil do return ""

	buf: [8]u16
	n: uint
	dead: u32
	// A fresh dead state every call, with NoDead: a carried-over state would
	// make the next lookup answer with a composed letter, so a key's name
	// would depend on what was asked before.
	st := UCKeyTranslate(rawptr(layout), code, UC_KEY_ACTION_DISPLAY, 0,
		u32(LMGetKbdType()), UC_KEY_TRANSLATE_NO_DEAD, &dead, len(buf), &n, raw_data(buf[:]))
	if st != 0 || n == 0 do return ""

	runes := make([dynamic]rune, 0, n, context.temp_allocator)
	for u in buf[:n] {
		if u < 0x20 || u == 0x7f do return "" // a control character is not a name
		append(&runes, rune(u)) // no layout types a surrogate pair from one key
	}
	if len(runes) == 0 do return ""
	out, err := strings.clone(utf8.runes_to_string(runes[:], context.temp_allocator), allocator)
	return out if err == nil else ""
}
