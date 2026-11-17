// macOS virtual key codes to Baldr's portable Key, NSEvent modifier flags to
// Mods, and an NSEvent's scrolling deltas to the logical pixels Ev_Scroll is
// in.
//
// Not `#+build darwin`: it is pure data with no AppKit, so it compiles and
// is tested on every platform.
//
// The codes are the `kVK_*` constants from Carbon's HIToolbox. They are
// positional (`A` is 0, `B` is 11, `C` is 8, after the Apple Extended
// Keyboard's wiring) and do not vary with the layout: kVK_ANSI_A is where A
// sits on a US keyboard whatever it types, which is the physical key `Key`
// wants. What a key types comes from the event's characters.
package cocoa

import "baldr:platform"

// KEYS maps a macOS virtual key code to a portable Key. Codes run 0..=126 in
// practice; anything outside, or a gap inside, is Unknown and the caller
// falls back to `Ev_Key.native`.
@(private, rodata)
KEYS := #partial [128]platform.Key{
	0 = .A, 1 = .S, 2 = .D, 3 = .F, 4 = .H, 5 = .G, 6 = .Z, 7 = .X, 8 = .C, 9 = .V,
	11 = .B, 12 = .Q, 13 = .W, 14 = .E, 15 = .R, 16 = .Y, 17 = .T,
	18 = .N1, 19 = .N2, 20 = .N3, 21 = .N4, 22 = .N6, 23 = .N5,
	24 = .Equal, 25 = .N9, 26 = .N7, 27 = .Minus, 28 = .N8, 29 = .N0,
	30 = .Bracket_R, 31 = .O, 32 = .U, 33 = .Bracket_L, 34 = .I, 35 = .P,
	36 = .Enter, 37 = .L, 38 = .J, 39 = .Apostrophe, 40 = .K, 41 = .Semicolon,
	42 = .Backslash, 43 = .Comma, 44 = .Slash, 45 = .N, 46 = .M, 47 = .Period,
	48 = .Tab, 49 = .Space, 50 = .Grave, 51 = .Backspace, 53 = .Escape,
	// The modifiers, which arrive as FlagsChanged rather than KeyDown.
	54 = .Super_R, 55 = .Super_L, 56 = .Shift_L, 57 = .Caps_Lock,
	58 = .Alt_L, 59 = .Ctrl_L, 60 = .Shift_R, 61 = .Alt_R, 62 = .Ctrl_R,
	64 = .F17, 65 = .KP_Decimal, 67 = .KP_Multiply, 69 = .KP_Add,
	71 = .Num_Lock, // kVK_ANSI_KeypadClear: the Mac keypad's Num Lock position
	72 = .Volume_Up, 73 = .Volume_Down, 74 = .Volume_Mute,
	75 = .KP_Divide, 76 = .KP_Enter, 78 = .KP_Subtract, 79 = .F18, 80 = .F19,
	81 = .KP_Equal,
	82 = .KP_0, 83 = .KP_1, 84 = .KP_2, 85 = .KP_3, 86 = .KP_4,
	87 = .KP_5, 88 = .KP_6, 89 = .KP_7, 90 = .F20, 91 = .KP_8, 92 = .KP_9,
	96 = .F5, 97 = .F6, 98 = .F7, 99 = .F3, 100 = .F8, 101 = .F9,
	103 = .F11, 105 = .F13, 106 = .F16, 107 = .F14, 109 = .F10, 111 = .F12,
	113 = .F15,
	114 = .Insert, // kVK_Help: where Insert sits on a PC keyboard
	115 = .Home, 116 = .Page_Up, 117 = .Delete, 118 = .F4, 119 = .End,
	120 = .F2, 121 = .Page_Down, 122 = .F1,
	123 = .Left, 124 = .Right, 125 = .Down, 126 = .Up,
}

// key_from_code is the portable key a macOS virtual key code stands for, or
// Unknown when Baldr has no name for it. The code is positional and does not
// move with the layout, so this never has to know which layout is active.
key_from_code :: proc "contextless" (code: u32) -> platform.Key {
	if code >= len(KEYS) do return .Unknown
	return KEYS[code]
}

// NSEventModifierFlags. AppKit sets more than the five modifiers: a
// device-dependent left/right discriminator in the low 16 bits, and
// NumericPad / Help / Function above them (an arrow key carries
// `{NumericPad, Function}`). So test one bit at a time and never compare a
// whole value: `flags == FLAG_SHIFT` is false for an ordinary Shift.
FLAG_CAPS     :: u64(1) << 16
FLAG_SHIFT    :: u64(1) << 17
FLAG_CTRL     :: u64(1) << 18
FLAG_ALT      :: u64(1) << 19
FLAG_SUPER    :: u64(1) << 20
FLAG_NUMPAD   :: u64(1) << 21
FLAG_HELP     :: u64(1) << 22
FLAG_FUNCTION :: u64(1) << 23

// mods_from_flags is the modifier set an NSEvent's flags carry. Super is
// Command and Alt is Option, which is right for a chord but not for text:
// Option+key types a character on macOS, so a backend must not suppress
// text because Alt is held.
mods_from_flags :: proc "contextless" (flags: u64) -> platform.Mods {
	out: platform.Mods
	f := flags
	if f & FLAG_SHIFT != 0 do out += {.Shift}
	if f & FLAG_CTRL != 0 do out += {.Ctrl}
	if f & FLAG_ALT != 0 do out += {.Alt}
	if f & FLAG_SUPER != 0 do out += {.Super}
	return out
}

// caps_lock_on reads the lock bit, which is not a modifier Baldr reports in
// `Mods` but is part of `Lock_Keys`.
caps_lock_on :: proc "contextless" (flags: u64) -> bool {
	return flags & FLAG_CAPS != 0
}

// PRIVATE_USE_LO / HI bound the block AppKit uses for arrows, function keys
// and the like in an event's `characters`. They are *not* text: letting one
// through puts a box in a text field when the user presses Up.
PRIVATE_USE_LO :: rune(0xf700)
PRIVATE_USE_HI :: rune(0xf8ff)

// text_of returns the typed text in `chars`, or "" when it is really a key
// with no text — a function key, an arrow, or anything else AppKit encodes in
// the private-use block. A control character is dropped for the same reason:
// Ctrl+C arrives as U+0003, which is a key, not something to insert.
text_of :: proc "contextless" (chars: string) -> string {
	if len(chars) == 0 do return ""
	for r in chars {
		if r >= PRIVATE_USE_LO && r <= PRIVATE_USE_HI do return ""
		if r < 0x20 || r == 0x7f do return ""
	}
	return chars
}

// scroll_delta turns an NSEvent's scrolling deltas into the logical pixels
// `Ev_Scroll` is in. A trackpad or Magic Mouse sets
// `hasPreciseScrollingDeltas` and reports points, passed through. A
// traditional wheel reports lines (±1 a notch, ±3 on some mice), scaled by
// SCROLL_STEP_PX. The sign is AppKit's: Baldr's +y means the content moves
// up, the direction macOS already reports.
@(private)
scroll_delta :: proc "contextless" (dx, dy: f32, precise: bool) -> [2]f32 {
	if precise do return {dx, dy} // points: the units Ev_Scroll is in
	return {dx * platform.SCROLL_STEP_PX, dy * platform.SCROLL_STEP_PX} // lines
}
