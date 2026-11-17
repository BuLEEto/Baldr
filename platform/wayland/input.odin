#+build linux
// input.odin — wl_seat → wl_pointer / wl_keyboard. Pointer coordinates are
// surface-local logical pixels already (wl_fixed). Scroll is accumulated per
// wl_pointer.frame. Keyboard goes through xkb.odin; key repeat uses a
// timerfd that the pump polls alongside the display fd.
package wayland

import "core:strings"
import "core:sys/linux"
import "baldr:platform"
import "baldr:platform/xkb"
import wl "baldr:platform/wayland/wl"

BTN_LEFT :: 0x110
BTN_RIGHT :: 0x111
BTN_MIDDLE :: 0x112
BTN_SIDE :: 0x113
BTN_EXTRA :: 0x114

// Scroll_Acc collects axis events between wl_pointer.frame boundaries.
Scroll_Acc :: struct {
	axis:         [2]f32, // continuous, logical px
	v120:         [2]i32,
	discrete:     [2]i32,
	has_axis:     bool,
	has_v120:     bool,
	has_discrete: bool,
	source:       wl.Wl_Pointer_Axis_Source,
	has_source:   bool,
}

@(private)
input_teardown :: proc(st: ^State) {
	if st.cursor_device != nil { wl.wp_cursor_shape_device_v1_destroy(st.cursor_device); st.cursor_device = nil }
	if st.pointer != nil { wl.wl_pointer_release(st.pointer); st.pointer = nil }
	if st.touch != nil { wl.wl_touch_release(st.touch); st.touch = nil }
	if st.keyboard != nil { wl.wl_keyboard_release(st.keyboard); st.keyboard = nil }
}

@(private)
on_seat_capabilities :: proc "c" (data: rawptr, seat: wl.Proxy, caps: wl.Wl_Seat_Capability) {
	st := (^State)(data)
	context = st.ctx
	has_pointer := caps & wl.WL_SEAT_CAPABILITY_POINTER != 0
	has_keyboard := caps & wl.WL_SEAT_CAPABILITY_KEYBOARD != 0
	if has_pointer && st.pointer == nil {
		st.pointer = wl.wl_seat_get_pointer(seat)
		st.pointer_l = wl.wl_pointer_listener_noop()
		st.pointer_l.enter = on_pointer_enter
		st.pointer_l.leave = on_pointer_leave
		st.pointer_l.motion = on_pointer_motion
		st.pointer_l.button = on_pointer_button
		st.pointer_l.axis = on_pointer_axis
		st.pointer_l.frame = on_pointer_frame
		st.pointer_l.axis_source = on_pointer_axis_source
		st.pointer_l.axis_discrete = on_pointer_axis_discrete
		st.pointer_l.axis_value120 = on_pointer_axis_value120
		wl.wl_pointer_add_listener(st.pointer, &st.pointer_l, st)
		if st.cursor_shape_mgr != nil {
			st.cursor_device = wl.wp_cursor_shape_manager_v1_get_pointer(st.cursor_shape_mgr, st.pointer)
		}
		debugf(st, "seat: pointer v%d", wl.proxy_version(st.pointer))
	} else if !has_pointer && st.pointer != nil {
		if st.cursor_device != nil { wl.wp_cursor_shape_device_v1_destroy(st.cursor_device); st.cursor_device = nil }
		wl.wl_pointer_release(st.pointer)
		st.pointer = nil
		if st.ptr_focus != nil {
			push(st, platform.Ev_Pointer_Leave{surface = st.ptr_focus.id})
			st.ptr_focus = nil
		}
	}
	has_touch := caps & wl.WL_SEAT_CAPABILITY_TOUCH != 0
	if has_touch && st.touch == nil {
		st.touch = wl.wl_seat_get_touch(seat)
		st.touch_l = wl.wl_touch_listener_noop()
		st.touch_l.down = on_touch_down
		st.touch_l.up = on_touch_up
		st.touch_l.motion = on_touch_motion
		st.touch_l.cancel = on_touch_cancel
		wl.wl_touch_add_listener(st.touch, &st.touch_l, st)
		push(st, platform.Ev_Input_Caps{touch = true})
		debugf(st, "seat: touch v%d", wl.proxy_version(st.touch))
	} else if !has_touch && st.touch != nil {
		wl.wl_touch_release(st.touch)
		st.touch = nil
		st.touch_focus = nil
		push(st, platform.Ev_Input_Caps{touch = false})
	}
	if has_keyboard && st.keyboard == nil {
		st.keyboard = wl.wl_seat_get_keyboard(seat)
		st.keyboard_l = wl.wl_keyboard_listener_noop()
		st.keyboard_l.keymap = on_keymap
		st.keyboard_l.enter = on_keyboard_enter
		st.keyboard_l.leave = on_keyboard_leave
		st.keyboard_l.key = on_key
		st.keyboard_l.modifiers = on_modifiers
		st.keyboard_l.repeat_info = on_repeat_info
		wl.wl_keyboard_add_listener(st.keyboard, &st.keyboard_l, st)
		// Pre-v4 seats never send repeat_info; use the usual desktop defaults.
		if wl.proxy_version(st.keyboard) < 4 {
			st.repeat_rate = 25
			st.repeat_delay = 600
		}
		debugf(st, "seat: keyboard v%d", wl.proxy_version(st.keyboard))
	} else if !has_keyboard && st.keyboard != nil {
		wl.wl_keyboard_release(st.keyboard)
		st.keyboard = nil
		key_repeat_stop(st)
		if st.kbd_focus != nil {
			push(st, platform.Ev_Focus{surface = st.kbd_focus.id, focused = false})
			st.kbd_focus = nil
		}
	}
}

// --------------------------------------------------------------- pointer

@(private)
on_pointer_enter :: proc "c" (data: rawptr, p: wl.Proxy, serial: u32, surface: wl.Proxy, sx, sy: wl.Fixed) {
	st := (^State)(data)
	context = st.ctx
	st.ptr_enter_serial = serial
	s := lookup_wl(st, surface)
	if s == nil do return
	st.ptr_focus = s
	st.ptr_pos = {wl.fixed_to_f32(sx), wl.fixed_to_f32(sy)}
	apply_cursor(st, s)
	push(st, platform.Ev_Pointer_Enter{surface = s.id, pos = st.ptr_pos})
}

@(private)
on_pointer_leave :: proc "c" (data: rawptr, p: wl.Proxy, serial: u32, surface: wl.Proxy) {
	st := (^State)(data)
	context = st.ctx
	s := lookup_wl(st, surface)
	if s == nil do s = st.ptr_focus
	if s != nil do push(st, platform.Ev_Pointer_Leave{surface = s.id})
	if st.ptr_focus == s do st.ptr_focus = nil
}

@(private)
on_pointer_motion :: proc "c" (data: rawptr, p: wl.Proxy, time: u32, sx, sy: wl.Fixed) {
	st := (^State)(data)
	context = st.ctx
	st.ptr_pos = {wl.fixed_to_f32(sx), wl.fixed_to_f32(sy)}
	if st.ptr_focus == nil do return
	push(st, platform.Ev_Pointer_Motion{surface = st.ptr_focus.id, pos = st.ptr_pos, time_ms = time, mods = st.mods})
}

@(private)
on_pointer_button :: proc "c" (data: rawptr, p: wl.Proxy, serial: u32, time: u32, button: u32, state: wl.Wl_Pointer_Button_State) {
	st := (^State)(data)
	context = st.ctx
	st.input_serial = serial
	if st.ptr_focus == nil do return
	mb: platform.Mouse_Button
	switch button {
	case BTN_LEFT:   mb = .Left
	case BTN_RIGHT:  mb = .Right
	case BTN_MIDDLE: mb = .Middle
	case BTN_SIDE:   mb = .Back
	case BTN_EXTRA:  mb = .Forward
	case: return
	}
	push(st, platform.Ev_Pointer_Button{
		surface = st.ptr_focus.id,
		button  = mb,
		pressed = state == .Pressed,
		pos     = st.ptr_pos,
		mods    = st.mods,
		serial  = serial,
		time_ms = time,
	})
}

// --------------------------------------------------------------- touch

@(private)
on_touch_down :: proc "c" (data: rawptr, p: wl.Proxy, serial: u32, time: u32, surface: wl.Proxy, id: i32, x, y: wl.Fixed) {
	st := (^State)(data)
	context = st.ctx
	st.input_serial = serial
	s := lookup_wl(st, surface)
	if s == nil do return
	st.touch_focus = s
	push(st, platform.Ev_Touch{surface = s.id, id = id, phase = .Down, pos = {wl.fixed_to_f32(x), wl.fixed_to_f32(y)}})
}

@(private)
on_touch_motion :: proc "c" (data: rawptr, p: wl.Proxy, time: u32, id: i32, x, y: wl.Fixed) {
	st := (^State)(data)
	context = st.ctx
	if st.touch_focus == nil do return
	push(st, platform.Ev_Touch{surface = st.touch_focus.id, id = id, phase = .Move, pos = {wl.fixed_to_f32(x), wl.fixed_to_f32(y)}})
}

@(private)
on_touch_up :: proc "c" (data: rawptr, p: wl.Proxy, serial: u32, time: u32, id: i32) {
	st := (^State)(data)
	context = st.ctx
	if st.touch_focus == nil do return
	push(st, platform.Ev_Touch{surface = st.touch_focus.id, id = id, phase = .Up})
}

@(private)
on_touch_cancel :: proc "c" (data: rawptr, p: wl.Proxy) {
	st := (^State)(data)
	context = st.ctx
	if st.touch_focus == nil do return
	push(st, platform.Ev_Touch{surface = st.touch_focus.id, id = -1, phase = .Cancel})
	st.touch_focus = nil
}

@(private)
axis_index :: #force_inline proc "contextless" (axis: wl.Wl_Pointer_Axis) -> int {
	return 1 if axis == .Vertical_Scroll else 0
}

@(private)
on_pointer_axis :: proc "c" (data: rawptr, p: wl.Proxy, time: u32, axis: wl.Wl_Pointer_Axis, value: wl.Fixed) {
	st := (^State)(data)
	context = st.ctx
	st.scroll.axis[axis_index(axis)] += wl.fixed_to_f32(value)
	st.scroll.has_axis = true
	if wl.proxy_version(p) < 5 do flush_scroll(st) // no frame events before v5
}

@(private)
on_pointer_axis_source :: proc "c" (data: rawptr, p: wl.Proxy, source: wl.Wl_Pointer_Axis_Source) {
	st := (^State)(data)
	st.scroll.source = source
	st.scroll.has_source = true
}

@(private)
on_pointer_axis_discrete :: proc "c" (data: rawptr, p: wl.Proxy, axis: wl.Wl_Pointer_Axis, discrete: i32) {
	st := (^State)(data)
	st.scroll.discrete[axis_index(axis)] += discrete
	st.scroll.has_discrete = true
}

@(private)
on_pointer_axis_value120 :: proc "c" (data: rawptr, p: wl.Proxy, axis: wl.Wl_Pointer_Axis, value120: i32) {
	st := (^State)(data)
	st.scroll.v120[axis_index(axis)] += value120
	st.scroll.has_v120 = true
}

@(private)
on_pointer_frame :: proc "c" (data: rawptr, p: wl.Proxy) {
	st := (^State)(data)
	context = st.ctx
	flush_scroll(st)
}

// flush_scroll turns the accumulated axis state into one Ev_Scroll. Wheel
// steps (value120, else axis_discrete) become SCROLL_STEP_PX per notch;
// finger/continuous sources pass the compositor's logical-pixel deltas.
@(private)
flush_scroll :: proc(st: ^State) {
	acc := &st.scroll
	defer acc^ = {}
	if !(acc.has_axis || acc.has_v120 || acc.has_discrete) do return
	if st.ptr_focus == nil do return
	delta: [2]f32
	switch {
	case acc.has_v120:
		delta = {platform.SCROLL_STEP_PX * f32(acc.v120.x) / 120, platform.SCROLL_STEP_PX * f32(acc.v120.y) / 120}
	case acc.has_discrete:
		delta = {platform.SCROLL_STEP_PX * f32(acc.discrete.x), platform.SCROLL_STEP_PX * f32(acc.discrete.y)}
	case:
		delta = acc.axis
	}
	if delta == {} do return
	precise := acc.has_source && (acc.source == .Finger || acc.source == .Continuous)
	push(st, platform.Ev_Scroll{surface = st.ptr_focus.id, delta = delta, pos = st.ptr_pos, precise = precise, mods = st.mods})
}

// -------------------------------------------------------------- keyboard

@(private)
on_keymap :: proc "c" (data: rawptr, p: wl.Proxy, format: wl.Wl_Keyboard_Keymap_Format, fd: i32, size: u32) {
	st := (^State)(data)
	context = st.ctx
	defer linux.close(linux.Fd(fd))
	if format != .Xkb_V1 || !st.keys.loaded {
		debugf(st, "keymap format %v ignored (xkb loaded=%v)", format, st.keys.loaded)
		return
	}
	// The string is NUL-terminated inside the mapping (xkb_v1 contract).
	mapping, merr := linux.mmap(0, uint(size), {.READ}, {.PRIVATE}, linux.Fd(fd), 0)
	if merr != .NONE || mapping == nil {
		debugf(st, "keymap mmap failed: %v", merr)
		return
	}
	defer linux.munmap(mapping, uint(size))
	if !xkb.set_keymap(&st.keys, cstring(mapping)) {
		debugf(st, "xkb_keymap_new_from_string failed")
		return
	}
	st.mods = xkb.mods(&st.keys)
	debugf(st, "keymap loaded (%d bytes)", size)
	keyboard_sync(st, force = true)
}

// keyboard_sync tells the toolkit what a view may show of the keyboard —
// the lock keys on, the active layout — when it changed (Ev_Keyboard), or
// always with `force` (a new keymap: a new layout list).
@(private)
keyboard_sync :: proc(st: ^State, force := false) {
	k := xkb.keyboard(&st.keys)
	if !force && k == st.kbd_info do return
	st.kbd_info = k
	name := xkb.layout_name(&st.keys, k.layout)
	debugf(st, "keyboard: locks %v, layout %d of %d %q", k.locks, k.layout + 1, k.layouts, name)
	push(st, platform.Ev_Keyboard{locks = k.locks, layout = strings.clone(name, text_allocator(st)), layouts = int(k.layouts)})
}

@(private)
on_keyboard_enter :: proc "c" (data: rawptr, p: wl.Proxy, serial: u32, surface: wl.Proxy, keys: ^wl.Array) {
	st := (^State)(data)
	context = st.ctx
	s := lookup_wl(st, surface)
	if s == nil do return
	st.kbd_focus = s
	st.kbd_enter_serial = serial
	debugf(st, "keyboard focus: surface %d", s.id)
	push(st, platform.Ev_Focus{surface = s.id, focused = true})
}

@(private)
on_keyboard_leave :: proc "c" (data: rawptr, p: wl.Proxy, serial: u32, surface: wl.Proxy) {
	st := (^State)(data)
	context = st.ctx
	key_repeat_stop(st)
	s := lookup_wl(st, surface)
	if s == nil do s = st.kbd_focus
	if s != nil {
		debugf(st, "keyboard left surface %d", s.id)
		push(st, platform.Ev_Focus{surface = s.id, focused = false})
	}
	if st.kbd_focus == s do st.kbd_focus = nil
}

@(private)
on_modifiers :: proc "c" (data: rawptr, p: wl.Proxy, serial: u32, depressed, latched, locked, group: u32) {
	st := (^State)(data)
	context = st.ctx
	st.mods = xkb.update_mods(&st.keys, depressed, latched, locked, group)
	debugf(st, "modifiers: depressed %x latched %x locked %x group %d", depressed, latched, locked, group)
	keyboard_sync(st) // Caps Lock, Num Lock or the layout may have changed: said only when one did
}

@(private)
on_repeat_info :: proc "c" (data: rawptr, p: wl.Proxy, rate, delay: i32) {
	st := (^State)(data)
	st.repeat_rate = max(rate, 0)
	st.repeat_delay = max(delay, 0)
}

@(private)
on_key :: proc "c" (data: rawptr, p: wl.Proxy, serial: u32, time: u32, key: u32, state: wl.Wl_Keyboard_Key_State) {
	st := (^State)(data)
	context = st.ctx
	st.input_serial = serial
	if st.kbd_focus == nil do return
	keycode := key + xkb.EVDEV_OFFSET
	pressed := state == .Pressed
	if pressed {
		emit_key(st, keycode, false)
		if st.repeat_rate > 0 && xkb.key_repeats(&st.keys, keycode) {
			key_repeat_start(st, keycode)
		}
	} else {
		k, sym, _ := xkb.translate(&st.keys, keycode, context.temp_allocator)
		push(st, platform.Ev_Key{surface = st.kbd_focus.id, key = k, native = sym, pressed = false, mods = st.mods})
		if st.repeat_keycode == keycode do key_repeat_stop(st)
	}
}

// emit_key produces Ev_Key (pressed) and, when the key commits printable
// text, Ev_Text. A key held with Ctrl, Alt or Super types nothing, as in
// GTK and Qt: it is a shortcut, though xkb still gives "1" for Ctrl+1.
// AltGr is Level 3, not Alt, so its characters come through. Text lives in
// the pump's arena until the next pump.
@(private)
emit_key :: proc(st: ^State, keycode: u32, repeat: bool) {
	if st.kbd_focus == nil do return
	k, sym, text := xkb.translate(&st.keys, keycode, text_allocator(st))
	push(st, platform.Ev_Key{surface = st.kbd_focus.id, key = k, native = sym, pressed = true, repeat = repeat, mods = st.mods})
	if text != "" && key_types(st.mods) do push(st, platform.Ev_Text{surface = st.kbd_focus.id, text = text})
}

// key_types: whether a key pressed with `mods` commits its text.
@(private)
key_types :: proc "contextless" (mods: platform.Mods) -> bool {
	return mods & {.Ctrl, .Alt, .Super} == {}
}

// ------------------------------------------------------------ key repeat

@(private)
key_repeat_start :: proc(st: ^State, keycode: u32) {
	st.repeat_keycode = keycode
	interval_ns := i64(1_000_000_000) / i64(max(st.repeat_rate, 1))
	delay_ns := i64(st.repeat_delay) * 1_000_000
	if delay_ns <= 0 do delay_ns = interval_ns
	spec := linux.ITimer_Spec{
		interval = {time_sec = uint(interval_ns / 1_000_000_000), time_nsec = uint(interval_ns % 1_000_000_000)},
		value    = {time_sec = uint(delay_ns / 1_000_000_000), time_nsec = uint(delay_ns % 1_000_000_000)},
	}
	linux.timerfd_settime(st.repeat_fd, {}, &spec, nil)
}

@(private)
key_repeat_stop :: proc(st: ^State) {
	if st.repeat_keycode == 0 do return
	st.repeat_keycode = 0
	spec: linux.ITimer_Spec
	linux.timerfd_settime(st.repeat_fd, {}, &spec, nil)
}

// key_repeat_fire is called by the pump when the timerfd expires. One
// repeat per wake-up regardless of how many expirations were missed, so a
// stalled app does not get a burst.
@(private)
key_repeat_fire :: proc(st: ^State) {
	if st.repeat_keycode == 0 || st.kbd_focus == nil {
		key_repeat_stop(st)
		return
	}
	emit_key(st, st.repeat_keycode, true)
}
