#+build linux
package x11

// The keyboard: a keymap built from the X server, and KeyPress/KeyRelease
// turned into Ev_Key and Ev_Text.
//
// The translation is platform/xkb, shared with Wayland. On X the keymap
// comes from libxkbcommon-x11, which asks the server directly; it is loaded
// separately, and without it there is no keyboard, which the log says.
//
// Auto-repeat: X sends a held key as KeyRelease then KeyPress at the same
// timestamp, so the key looks released and pressed again.
// XkbSetDetectableAutoRepeat turns that into repeated presses alone.

import "core:dynlib"
import "baldr:platform"
import "baldr:platform/xkb"

@(private = "file") XKB_CONTEXT_NO_FLAGS   :: 0
@(private = "file") XKB_KEYMAP_COMPILE_NO_FLAGS :: 0
@(private = "file") XKB_X11_SETUP_NO_FLAGS :: 0

Xkb_X11_Api :: struct {
	setup_extension: proc "c" (conn: Connection, major, minor: u16, flags: i32,
		major_out, minor_out: ^u16, base_event_out, base_error_out: ^u8) -> i32,
	core_device_id:  proc "c" (conn: Connection) -> i32,
	keymap_new:      proc "c" (ctx: rawptr, conn: Connection, device_id: i32, flags: i32) -> rawptr,
	state_new:       proc "c" (keymap: rawptr, conn: Connection, device_id: i32) -> rawptr,
}

@(private) xkb_x11: Xkb_X11_Api
@(private = "file") xkb_x11_lib: dynlib.Library

// keyboard_start builds the keymap from the server. False when there is no
// libxkbcommon-x11 or the server has no XKB — then keys are dropped, and
// the caller says so.
@(private)
keyboard_start :: proc(x: ^X11) -> bool {
	if ok, miss := xkb.load(&x.keys); !ok {
		debugf(x, "libxkbcommon unavailable (%s): the keyboard will report nothing", miss)
		return false
	}
	l, lok := dynlib.load_library("libxkbcommon-x11.so.0")
	if !lok {
		debugf(x, "libxkbcommon-x11 unavailable: the keyboard will report nothing")
		return false
	}
	xkb_x11_lib = l
	a := &xkb_x11
	miss := make([dynamic]string, context.temp_allocator)
	a.setup_extension = x11_sym("xkb_x11_setup_xkb_extension",           type_of(a.setup_extension), &miss)
	a.core_device_id  = x11_sym("xkb_x11_get_core_keyboard_device_id",   type_of(a.core_device_id), &miss)
	a.keymap_new      = x11_sym("xkb_x11_keymap_new_from_device",        type_of(a.keymap_new), &miss)
	a.state_new       = x11_sym("xkb_x11_state_new_from_device",         type_of(a.state_new), &miss)
	if len(miss) > 0 {
		debugf(x, "libxkbcommon-x11 is missing %v: the keyboard will report nothing", miss[:])
		return false
	}

	major, minor: u16
	base_event, base_error: u8
	if a.setup_extension(x.conn, 1, 0, XKB_X11_SETUP_NO_FLAGS, &major, &minor, &base_event, &base_error) == 0 {
		debugf(x, "this X server has no XKB extension: the keyboard will report nothing")
		return false
	}
	x.xkb_device = a.core_device_id(x.conn)
	if x.xkb_device == -1 {
		debugf(x, "the X server named no core keyboard")
		return false
	}
	if !keyboard_rebuild(x) do return false
	detectable_auto_repeat(x)
	k := xkb.keyboard(&x.keys)
	debugf(x, "keyboard: XKB %d.%d, device %d, layout %d of %d %q", major, minor, x.xkb_device, k.layout + 1, k.layouts, xkb.layout_name(&x.keys, k.layout))
	return true
}

// keyboard_rebuild asks the server for the keymap again — at start-up, and
// whenever the layout changes under the app.
@(private)
keyboard_rebuild :: proc(x: ^X11) -> bool {
	km := xkb_x11.keymap_new(x.keys.ctx, x.conn, x.xkb_device, XKB_KEYMAP_COMPILE_NO_FLAGS)
	if km == nil do return false
	st := xkb_x11.state_new(km, x.conn, x.xkb_device)
	if st == nil {
		x.keys.api.keymap_unref(km)
		return false
	}
	// adopt_keymap makes its own state; this one is only to prove the pair
	// builds, and goes straight back.
	x.keys.api.state_unref(st)
	return xkb.adopt_keymap(&x.keys, km)
}

@(private)
keyboard_stop :: proc(x: ^X11) {
	xkb.unload(&x.keys)
	if xkb_x11_lib != nil {
		dynlib.unload_library(xkb_x11_lib)
		xkb_x11_lib = nil
	}
}

@(private = "file")
x11_sym :: proc($name: string, $T: typeid, miss: ^[dynamic]string) -> T {
	p, ok := dynlib.symbol_address(xkb_x11_lib, name)
	if !ok {
		append(miss, name)
		return nil
	}
	return (T)(p)
}

// on_key turns a KeyPress or KeyRelease into Ev_Key, and a press that
// commits text into Ev_Text.
//
// The modifiers come from xkb's own state and not from the event's `state`
// field, which is what they were *before* the event: pressing Shift would
// otherwise report no Shift.
@(private)
on_key :: proc(x: ^X11, e: ^Input_Event, pressed: bool) {
	s := surface_of_window(x, e.event)
	if s == nil || !s.live do return
	if x.keys.state == nil do return

	keycode := u32(e.detail)
	x.keys.api.state_update_key(x.keys.state, keycode, XKB_KEY_DOWN if pressed else XKB_KEY_UP)
	mods := xkb.mods(&x.keys)

	// With detectable auto-repeat on, a held key arrives as presses with no
	// release between them, so the same keycode pressed twice running is a
	// repeat and not a second press.
	repeat := pressed && x.held == keycode
	if pressed {
		x.held = keycode
	} else if x.held == keycode {
		x.held = 0
	}

	key, sym, text := xkb.translate(&x.keys, keycode, text_allocator(x))
	debugf(x, "key %v (keycode %d, sym %#x) %s%s -> %q", key, keycode, sym,
		"pressed" if pressed else "released", " (repeat)" if repeat else "", text)
	push(x, platform.Ev_Key{
		surface = s.id, key = key, native = sym, pressed = pressed,
		repeat = repeat, mods = mods,
	})
	// A key held with Ctrl, Alt or Super is a shortcut and types nothing.
	// AltGr is Level 3, not Alt, so its characters still come through.
	if pressed && text != "" && mods & {.Ctrl, .Alt, .Super} == {} {
		push(x, platform.Ev_Text{surface = s.id, text = text})
	}
}

// keys_released is called when a surface loses the keyboard: X does not
// send a release for a key still down when focus goes, so the state is
// reset rather than left holding a phantom modifier.
@(private)
keys_released :: proc(x: ^X11, s: ^Surface) {
	if x.keys.state == nil do return
	x.held = 0
	keyboard_rebuild(x) // the cheapest way back to a state holding nothing
}

// detectable_auto_repeat asks the server to stop sending a KeyRelease
// before each repeated KeyPress of a held key.
//
// Without it a held key arrives as release/press pairs and is never seen
// as held. One call into libxcb-xkb, whose extension xkbcommon-x11 has
// already set up; without the library a held key is just noisier.
@(private = "file")
detectable_auto_repeat :: proc(x: ^X11) {
	lib, ok := dynlib.load_library("libxcb-xkb.so.1")
	if !ok {
		debugf(x, "libxcb-xkb unavailable: a held key will arrive as press/release pairs")
		return
	}
	defer dynlib.unload_library(lib)
	p, pok := dynlib.symbol_address(lib, "xcb_xkb_per_client_flags")
	if !pok {
		debugf(x, "libxcb-xkb has no xcb_xkb_per_client_flags")
		return
	}
	per_client_flags := (proc "c" (conn: Connection, device: u16, change, value, ctrls_to_change, auto_ctrls, auto_ctrls_values: u32) -> Void_Cookie)(p)
	XKB_ID_USE_CORE_KBD :: u16(0x0100)
	DETECTABLE_AUTO_REPEAT :: u32(1)
	per_client_flags(x.conn, XKB_ID_USE_CORE_KBD, DETECTABLE_AUTO_REPEAT, DETECTABLE_AUTO_REPEAT, 0, 0, 0)
	api.flush(x.conn)
	debugf(x, "detectable auto-repeat asked for")
}

@(private = "file") XKB_KEY_UP   :: 0
@(private = "file") XKB_KEY_DOWN :: 1
