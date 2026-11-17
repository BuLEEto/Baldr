#+build linux
// Package xkb is libxkbcommon loaded at runtime (core:dynlib, nothing
// linked): build a keymap, track modifier state, translate keycodes to
// keysyms and UTF-8, and map keysyms to platform.Key. The keysym→Key table
// is in this file too.
//
// Shared by both Linux backends: only where the keymap comes from differs —
// a string the compositor sends over a descriptor on Wayland
// (`set_keymap`), or one built from the server through xkbcommon-x11 on X
// (`adopt_keymap`).
//
// A dependency tolerated while required; a pure-Odin xkb package can
// replace it without touching either backend.
package xkb

import "core:c"
import "core:dynlib"
import "core:strings"
import "baldr:platform"

XKB_KEYMAP_FORMAT_TEXT_V1 :: 1
XKB_KEY_UP :: 0
XKB_KEY_DOWN :: 1
XKB_STATE_MODS_EFFECTIVE :: 1 << 3
XKB_STATE_MODS_LOCKED    :: 1 << 2
XKB_STATE_LAYOUT_EFFECTIVE :: 1 << 7

// Evdev keycodes are offset by 8 in xkb keymaps.
EVDEV_OFFSET :: 8

// Xkb_Api is the dlsym'd function table for libxkbcommon.so.0.
Xkb_Api :: struct {
	context_new:                  proc "c" (flags: i32) -> rawptr,
	context_unref:                proc "c" (ctx: rawptr),
	keymap_new_from_string:       proc "c" (ctx: rawptr, s: cstring, format: i32, flags: i32) -> rawptr,
	keymap_unref:                 proc "c" (km: rawptr),
	keymap_key_repeats:           proc "c" (km: rawptr, key: u32) -> i32,
	keymap_key_get_syms_by_level: proc "c" (km: rawptr, key: u32, layout: u32, level: u32, syms_out: ^[^]u32) -> i32,
	state_new:                    proc "c" (km: rawptr) -> rawptr,
	state_unref:                  proc "c" (st: rawptr),
	state_update_key:             proc "c" (st: rawptr, key: u32, direction: i32) -> i32,
	state_update_mask:            proc "c" (st: rawptr, depressed, latched, locked, layout_depressed, layout_latched, layout_locked: u32) -> i32,
	state_key_get_one_sym:        proc "c" (st: rawptr, key: u32) -> u32,
	state_key_get_utf8:           proc "c" (st: rawptr, key: u32, buf: [^]u8, size: c.size_t) -> i32,
	state_key_get_layout:         proc "c" (st: rawptr, key: u32) -> u32,
	state_mod_name_is_active:     proc "c" (st: rawptr, name: cstring, type: i32) -> i32,
	state_led_name_is_active:     proc "c" (st: rawptr, name: cstring) -> i32,
	state_serialize_layout:       proc "c" (st: rawptr, components: i32) -> u32,
	keymap_num_layouts:           proc "c" (km: rawptr) -> u32,
	keymap_layout_get_name:       proc "c" (km: rawptr, idx: u32) -> cstring,
	keysym_get_name:              proc "c" (sym: u32, buf: [^]u8, size: c.size_t) -> i32,
}

// Xkb is the per-backend keyboard translation state.
Xkb :: struct {
	lib:    dynlib.Library,
	api:    Xkb_Api,
	loaded: bool,
	ctx:    rawptr, // xkb_context
	keymap: rawptr, // xkb_keymap (nil until wl_keyboard.keymap)
	state:  rawptr, // xkb_state
}

// load dlopens libxkbcommon and creates a context. Returns false when
// the library or a symbol is missing; the backend then reports Key.Unknown
// and no text, which is the documented degradation.
load :: proc(x: ^Xkb) -> (ok: bool, missing: string) {
	if x.loaded do return true, ""
	lib, lok := dynlib.load_library("libxkbcommon.so.0")
	if !lok do return false, "libxkbcommon.so.0"
	x.lib = lib
	a := &x.api
	miss := ""
	sym :: proc(lib: dynlib.Library, name: string, $T: typeid, miss: ^string) -> T {
		p, ok := dynlib.symbol_address(lib, name)
		if !ok || p == nil {
			if miss^ == "" do miss^ = name
			z: T
			return z
		}
		return transmute(T)p
	}
	a.context_new                  = sym(lib, "xkb_context_new",                  type_of(a.context_new), &miss)
	a.context_unref                = sym(lib, "xkb_context_unref",                type_of(a.context_unref), &miss)
	a.keymap_new_from_string       = sym(lib, "xkb_keymap_new_from_string",       type_of(a.keymap_new_from_string), &miss)
	a.keymap_unref                 = sym(lib, "xkb_keymap_unref",                 type_of(a.keymap_unref), &miss)
	a.keymap_key_repeats           = sym(lib, "xkb_keymap_key_repeats",           type_of(a.keymap_key_repeats), &miss)
	a.keymap_key_get_syms_by_level = sym(lib, "xkb_keymap_key_get_syms_by_level", type_of(a.keymap_key_get_syms_by_level), &miss)
	a.state_new                    = sym(lib, "xkb_state_new",                    type_of(a.state_new), &miss)
	a.state_unref                  = sym(lib, "xkb_state_unref",                  type_of(a.state_unref), &miss)
	a.state_update_key             = sym(lib, "xkb_state_update_key",             type_of(a.state_update_key), &miss)
	a.state_update_mask            = sym(lib, "xkb_state_update_mask",            type_of(a.state_update_mask), &miss)
	a.state_key_get_one_sym        = sym(lib, "xkb_state_key_get_one_sym",        type_of(a.state_key_get_one_sym), &miss)
	a.state_key_get_utf8           = sym(lib, "xkb_state_key_get_utf8",           type_of(a.state_key_get_utf8), &miss)
	a.state_key_get_layout         = sym(lib, "xkb_state_key_get_layout",         type_of(a.state_key_get_layout), &miss)
	a.state_mod_name_is_active     = sym(lib, "xkb_state_mod_name_is_active",     type_of(a.state_mod_name_is_active), &miss)
	a.state_led_name_is_active     = sym(lib, "xkb_state_led_name_is_active",     type_of(a.state_led_name_is_active), &miss)
	a.state_serialize_layout       = sym(lib, "xkb_state_serialize_layout",       type_of(a.state_serialize_layout), &miss)
	a.keymap_num_layouts           = sym(lib, "xkb_keymap_num_layouts",           type_of(a.keymap_num_layouts), &miss)
	a.keymap_layout_get_name       = sym(lib, "xkb_keymap_layout_get_name",       type_of(a.keymap_layout_get_name), &miss)
	a.keysym_get_name              = sym(lib, "xkb_keysym_get_name",              type_of(a.keysym_get_name), &miss)
	if miss != "" {
		dynlib.unload_library(lib)
		x.lib = nil
		return false, miss
	}
	x.ctx = a.context_new(0)
	if x.ctx == nil {
		dynlib.unload_library(lib)
		x.lib = nil
		return false, "xkb_context_new failed"
	}
	x.loaded = true
	return true, ""
}

unload :: proc(x: ^Xkb) {
	if !x.loaded do return
	drop_keymap(x)
	if x.ctx != nil do x.api.context_unref(x.ctx)
	x.ctx = nil
	if x.lib != nil do dynlib.unload_library(x.lib)
	x.lib = nil
	x.api = {}
	x.loaded = false
}

drop_keymap :: proc(x: ^Xkb) {
	if x.state != nil do x.api.state_unref(x.state)
	if x.keymap != nil do x.api.keymap_unref(x.keymap)
	x.state = nil
	x.keymap = nil
}

// adopt_keymap takes a keymap built elsewhere (xkbcommon-x11 builds one
// from the X server) and makes a state for it. The keymap becomes this
// Xkb's to unref.
adopt_keymap :: proc(x: ^Xkb, keymap: rawptr) -> bool {
	if x.api.state_new == nil || keymap == nil do return false
	drop_keymap(x)
	x.keymap = keymap
	x.state = x.api.state_new(keymap)
	return x.state != nil
}

// set_keymap compiles a keymap from its text form (the mmapped
// wl_keyboard.keymap fd) and starts a fresh state for it.
set_keymap :: proc(x: ^Xkb, text: cstring) -> bool {
	if !x.loaded do return false
	drop_keymap(x)
	x.keymap = x.api.keymap_new_from_string(x.ctx, text, XKB_KEYMAP_FORMAT_TEXT_V1, 0)
	if x.keymap == nil do return false
	x.state = x.api.state_new(x.keymap)
	if x.state == nil {
		x.api.keymap_unref(x.keymap)
		x.keymap = nil
		return false
	}
	return true
}

// update_mods applies a wl_keyboard.modifiers event and returns the
// effective portable modifier set.
update_mods :: proc(x: ^Xkb, depressed, latched, locked, group: u32) -> platform.Mods {
	if x.state == nil do return {}
	x.api.state_update_mask(x.state, depressed, latched, locked, 0, 0, group)
	return mods(x)
}

mods :: proc(x: ^Xkb) -> (m: platform.Mods) {
	if x.state == nil do return {}
	active :: proc(x: ^Xkb, name: cstring) -> bool {
		return x.api.state_mod_name_is_active(x.state, name, XKB_STATE_MODS_EFFECTIVE) > 0
	}
	if active(x, "Shift") do m += {.Shift}
	if active(x, "Control") do m += {.Ctrl}
	if active(x, "Mod1") do m += {.Alt}
	if active(x, "Mod4") do m += {.Super}
	if active(x, "Lock") do m += {.Caps_Lock}
	if active(x, "Mod2") do m += {.Num_Lock}
	return
}

// Xkb_Keyboard is what a view may show of the keyboard (platform.Ev_Keyboard):
// `layout` is the active group's index; its name comes from the keymap.
Xkb_Keyboard :: struct {
	locks:   platform.Lock_Keys,
	layout:  u32,
	layouts: u32,
}

// keyboard reads the lock keys that are on and the active layout. A
// lock key is its LED (Caps Lock, Num Lock), which follows the locked
// modifier whatever key sets it; a keymap without the LED falls back to the
// locked modifier (Lock, Mod2).
keyboard :: proc(x: ^Xkb) -> (k: Xkb_Keyboard) {
	if x.state == nil || x.keymap == nil do return
	on :: proc(x: ^Xkb, led, mod: cstring) -> bool {
		switch x.api.state_led_name_is_active(x.state, led) {
		case 1: return true
		case 0: return false
		}
		return x.api.state_mod_name_is_active(x.state, mod, XKB_STATE_MODS_LOCKED) > 0
	}
	if on(x, "Caps Lock", "Lock") do k.locks += {.Caps}
	if on(x, "Num Lock", "Mod2") do k.locks += {.Num}
	k.layout = x.api.state_serialize_layout(x.state, XKB_STATE_LAYOUT_EFFECTIVE)
	k.layouts = x.api.keymap_num_layouts(x.keymap)
	return
}

// layout_name is the name of layout `idx` ("English (UK)"), "" when the
// keymap gives none. It points into the keymap: copy it to keep it.
layout_name :: proc(x: ^Xkb, idx: u32) -> string {
	if x.keymap == nil do return ""
	return string(x.api.keymap_layout_get_name(x.keymap, idx))
}

key_repeats :: proc(x: ^Xkb, keycode: u32) -> bool {
	if x.keymap == nil do return false
	return x.api.keymap_key_repeats(x.keymap, keycode) != 0
}

// translate turns an xkb keycode (evdev + 8) into the portable key (from
// the key's base level so Shift+1 is still N1), the effective keysym, and the
// committed UTF-8 text (empty for control characters and dead keys). `text`
// is allocated from `allocator`.
translate :: proc(x: ^Xkb, keycode: u32, allocator := context.allocator) -> (key: platform.Key, sym: u32, text: string) {
	if x.state == nil do return .Unknown, 0, ""
	sym = x.api.state_key_get_one_sym(x.state, keycode)
	layout := x.api.state_key_get_layout(x.state, keycode)
	base_syms: [^]u32
	n := x.api.keymap_key_get_syms_by_level(x.keymap, keycode, layout, 0, &base_syms)
	if n > 0 do key = keysym_to_key(base_syms[0])
	if key == .Unknown do key = keysym_to_key(sym)
	buf: [64]u8
	got := x.api.state_key_get_utf8(x.state, keycode, &buf[0], len(buf))
	if got > 0 && got < len(buf) {
		s := string(buf[:got])
		if text_is_printable(s) do text = strings.clone(s, allocator)
	}
	return
}

@(private = "file")
text_is_printable :: proc(s: string) -> bool {
	for r in s {
		if r < 0x20 || r == 0x7f || (r >= 0x80 && r < 0xa0) do return false
	}
	return true
}

// keysym_name is what xkb calls a keysym ("q", "comma", "Print",
// "XF86AudioPlay"), which is what every Wayland compositor's configuration
// file is written in. "" when the library is not loaded or does not know it.
keysym_name :: proc(x: ^Xkb, sym: u32, allocator := context.allocator) -> string {
	if !x.loaded || x.api.keysym_get_name == nil || sym == 0 do return ""
	buf: [64]u8
	n := x.api.keysym_get_name(sym, &buf[0], len(buf))
	if n <= 0 || int(n) >= len(buf) do return ""
	return strings.clone(string(buf[:n]), allocator)
}

// keysym_to_key maps X11/xkb keysyms (xkbcommon-keysyms.h values) to the
// portable platform.Key. Keypad navigation keysyms (NumLock off) map to the
// physical KP_* key so both NumLock states agree.
keysym_to_key :: proc(sym: u32) -> platform.Key {
	switch sym {
	case 0x61 ..= 0x7a: return platform.Key(int(platform.Key.A) + int(sym - 0x61)) // a-z
	case 0x41 ..= 0x5a: return platform.Key(int(platform.Key.A) + int(sym - 0x41)) // A-Z
	case 0x30 ..= 0x39: return platform.Key(int(platform.Key.N0) + int(sym - 0x30)) // 0-9
	case 0xffbe ..= 0xffd5: return platform.Key(int(platform.Key.F1) + int(sym - 0xffbe)) // F1-F24
	case 0xffb0 ..= 0xffb9: return platform.Key(int(platform.Key.KP_0) + int(sym - 0xffb0)) // KP_0-KP_9

	case 0xff1b: return .Escape
	case 0xff0d: return .Enter
	case 0xff09, 0xfe20: return .Tab // Tab, ISO_Left_Tab
	case 0xff08: return .Backspace
	case 0x20: return .Space

	case 0xff51: return .Left
	case 0xff53: return .Right
	case 0xff52: return .Up
	case 0xff54: return .Down
	case 0xff50: return .Home
	case 0xff57: return .End
	case 0xff55: return .Page_Up
	case 0xff56: return .Page_Down
	case 0xff63: return .Insert
	case 0xffff: return .Delete

	case 0xffe1: return .Shift_L
	case 0xffe2: return .Shift_R
	case 0xffe3: return .Ctrl_L
	case 0xffe4: return .Ctrl_R
	case 0xffe9: return .Alt_L
	case 0xffea, 0xfe03: return .Alt_R // Alt_R, ISO_Level3_Shift (AltGr)
	case 0xffeb: return .Super_L
	case 0xffec: return .Super_R
	case 0xffe7: return .Super_L // Meta_L
	case 0xffe8: return .Super_R // Meta_R

	case 0xffe5: return .Caps_Lock
	case 0xff7f: return .Num_Lock
	case 0xff14: return .Scroll_Lock
	case 0xff61: return .Print
	case 0xff13: return .Pause
	case 0xff67: return .Menu

	case 0x2d: return .Minus
	case 0x3d: return .Equal
	case 0x5b: return .Bracket_L
	case 0x5d: return .Bracket_R
	case 0x5c: return .Backslash
	case 0x3b: return .Semicolon
	case 0x27: return .Apostrophe
	case 0x60: return .Grave
	case 0x2c: return .Comma
	case 0x2e: return .Period
	case 0x2f: return .Slash
	// Shifted US punctuation, used only as a fallback when the base level
	// gave nothing (e.g. a keymap without a level-0 keysym).
	case 0x5f: return .Minus       // underscore
	case 0x2b: return .Equal       // plus
	case 0x7b: return .Bracket_L   // braceleft
	case 0x7d: return .Bracket_R   // braceright
	case 0x7c: return .Backslash   // bar
	case 0x3a: return .Semicolon   // colon
	case 0x22: return .Apostrophe  // quotedbl
	case 0x7e: return .Grave       // asciitilde
	case 0x3c: return .Comma       // less
	case 0x3e: return .Period      // greater
	case 0x3f: return .Slash       // question
	case 0x21: return .N1
	case 0x40: return .N2
	case 0x23: return .N3
	case 0x24: return .N4
	case 0x25: return .N5
	case 0x5e: return .N6
	case 0x26: return .N7
	case 0x2a: return .N8
	case 0x28: return .N9
	case 0x29: return .N0

	// the keys beyond the typewriter (XF86*), which desktops bind by default
	case 0x1008ff13: return .Volume_Up
	case 0x1008ff11: return .Volume_Down
	case 0x1008ff12: return .Volume_Mute
	case 0x1008ffb2: return .Mic_Mute
	case 0x1008ff14: return .Media_Play
	case 0x1008ff31: return .Media_Pause
	case 0x1008ff32: return .Media_Play_Pause // XF86AudioPlayPause on keymaps that have it
	case 0x1008ff15: return .Media_Stop
	case 0x1008ff16: return .Media_Prev
	case 0x1008ff17: return .Media_Next
	case 0x1008ff3e: return .Media_Rewind
	case 0x1008ff97: return .Media_Forward
	case 0x1008ff1c: return .Media_Record
	case 0x1008ff02: return .Brightness_Up
	case 0x1008ff03: return .Brightness_Down
	case 0x1008ff05: return .Kbd_Brightness_Up
	case 0x1008ff06: return .Kbd_Brightness_Down
	case 0x1008ff2a: return .Power
	case 0x1008ff2f: return .Sleep
	case 0x1008ff2b: return .Wake
	case 0x1008ff2c: return .Eject
	case 0x1008ff1b: return .Search
	case 0x1008ff18: return .Home_Page
	case 0x1008ff19: return .Mail
	case 0x1008ff1d: return .Calculator
	case 0x1008ff5d: return .Explorer
	case 0x1008ff30: return .Favorites
	case 0x1008ff81: return .Tools
	case 0x1008ff29: return .Refresh
	case 0x1008ff26: return .Browser_Back
	case 0x1008ff27: return .Browser_Forward
	case 0x1008ff59: return .Display_Switch
	case 0x1008ffa9: return .Touchpad_Toggle
	case 0x1008ff95: return .Wlan
	case 0x1008ff94: return .Bluetooth
	case 0x1008ffb5: return .Rf_Kill

	case 0xffae: return .KP_Decimal
	case 0xffac: return .KP_Decimal // KP_Separator (comma decimal locales)
	case 0xffaf: return .KP_Divide
	case 0xffaa: return .KP_Multiply
	case 0xffad: return .KP_Subtract
	case 0xffab: return .KP_Add
	case 0xff8d: return .KP_Enter
	case 0xffbd: return .KP_Equal
	// Keypad with NumLock off.
	case 0xff9e: return .KP_0 // KP_Insert
	case 0xff9c: return .KP_1 // KP_End
	case 0xff99: return .KP_2 // KP_Down
	case 0xff9b: return .KP_3 // KP_Page_Down
	case 0xff96: return .KP_4 // KP_Left
	case 0xff9d: return .KP_5 // KP_Begin
	case 0xff98: return .KP_6 // KP_Right
	case 0xff95: return .KP_7 // KP_Home
	case 0xff97: return .KP_8 // KP_Up
	case 0xff9a: return .KP_9 // KP_Page_Up
	case 0xff9f: return .KP_Decimal // KP_Delete
	}
	return .Unknown
}
