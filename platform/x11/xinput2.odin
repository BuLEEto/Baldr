#+build linux
package x11

// XInput2, for scrolling that is smooth rather than notched.
//
// Core X scrolls by buttons 4 to 7, one step per click, so a touchpad's
// glide arrives as discrete steps. XI2 puts scrolling on valuators, running
// totals that move by fractions of a click; the delta between readings is
// the real movement.
//
// Selecting an XI2 event on a window unselects the core one: with XI_Motion
// selected the core MotionNotify stops, and hover would die. So motion is
// also pushed from the XI2 event through `pointer_moved` (input.odin);
// buttons, enter and leave are not selected and stay core events.
//
//   - A device with scroll valuators also sends the old button 4-7 events.
//     Only those a valuator moved for are dropped (`xi2_wheel_echoed`); a
//     click with nothing behind it is input, not an echo.
//   - A window is selected only when there is a valuator to read: a server
//     may offer XI2 2.1 with no scrolling axis, and then losing core motion
//     is all cost.
//
// The event layout has libxcb's spliced-in `full_sequence`; the struct
// follows xcb/xinput.h and asserts its size.

import "core:c"
import "core:dynlib"
import "baldr:platform"

@(private = "file") XI_MOTION :: 6
@(private = "file") XI_DEVICE_CHANGED :: 1     // a master's classes changed, or a different slave sent through it
@(private = "file") XI_HIERARCHY_CHANGED :: 11 // a device came, went, or was attached elsewhere
@(private = "file") GE_GENERIC :: 35
@(private = "file") DEVICE_ALL :: 0
@(private = "file") DEVICE_ALL_MASTER :: 1
@(private = "file") CLASS_TYPE_SCROLL :: 3
@(private = "file") SCROLL_TYPE_VERTICAL :: 1
@(private = "file") SCROLL_TYPE_HORIZONTAL :: 2
@(private = "file") EVENT_MASK_XI_MOTION :: 1 << XI_MOTION
@(private = "file") EVENT_MASK_XI_DEVICE_CHANGED :: 1 << XI_DEVICE_CHANGED
@(private = "file") EVENT_MASK_XI_HIERARCHY_CHANGED :: 1 << XI_HIERARCHY_CHANGED

Fp3232 :: struct { integral: i32, frac: u32 }

@(private = "file")
fp3232_f64 :: proc(v: Fp3232) -> f64 {
	return f64(v.integral) + f64(v.frac) / 4294967296.0
}

Xi_Version_Cookie :: struct { sequence: c.uint }
Xi_Version_Reply :: struct {
	response_type: u8,
	pad0:          u8,
	sequence:      u16,
	length:        u32,
	major_version: u16,
	minor_version: u16,
	pad1:          [20]u8,
}

Xi_Query_Device_Cookie :: struct { sequence: c.uint }
Xi_Query_Device_Reply :: struct {
	response_type: u8,
	pad0:          u8,
	sequence:      u16,
	length:        u32,
	num_infos:     u16,
	pad1:          [22]u8,
}

Xi_Device_Info :: struct {
	deviceid:    u16,
	type:        u16,
	attachment:  u16,
	num_classes: u16,
	name_len:    u16,
	enabled:     u8,
	pad0:        u8,
}

Device_Class :: struct {
	type:     u16,
	len:      u16, // in 4-byte units
	sourceid: u16,
	pad0:     u16,
}

Scroll_Class :: struct {
	type:        u16,
	len:         u16,
	sourceid:    u16,
	number:      u16,
	scroll_type: u16, // 1 vertical, 2 horizontal
	pad0:        u16,
	flags:       u32,
	increment:   Fp3232, // how much of a valuator makes one click
}

// Xi_Motion is XI2's motion event. Everything up to `group` is fixed; the
// button mask, the valuator mask and the axis values follow it.
Xi_Motion :: struct {
	response_type: u8,
	extension:     u8,
	sequence:      u16,
	length:        u32,
	event_type:    u16,
	deviceid:      u16,
	time:          Timestamp,
	detail:        u32,
	root:          Window,
	event:         Window,
	child:         Window,
	full_sequence: u32, // libxcb splices this into every generic event
	root_x:        i32, // 16.16 fixed point
	root_y:        i32,
	event_x:       i32,
	event_y:       i32,
	buttons_len:   u16,
	valuators_len: u16,
	sourceid:      u16,
	pad0:          [2]u8,
	flags:         u32,
	mods:          [4]u32,
	group:         [4]u8,
}
#assert(size_of(Xi_Motion) == 84)

// Scroll_Axis is one scrolling valuator of one device.
@(private)
Scroll_Axis :: struct {
	device:     u16,
	number:     u16,
	horizontal: bool,
	increment:  f64,
	last:       f64,
	seen:       bool, // a valuator's absolute value means nothing until read once
}

Xi_Api :: struct {
	query_version:       proc "c" (conn: Connection, major, minor: u16) -> Xi_Version_Cookie,
	query_version_reply: proc "c" (conn: Connection, ck: Xi_Version_Cookie, e: ^^Generic_Error) -> ^Xi_Version_Reply,
	query_device:        proc "c" (conn: Connection, deviceid: u16) -> Xi_Query_Device_Cookie,
	query_device_reply:  proc "c" (conn: Connection, ck: Xi_Query_Device_Cookie, e: ^^Generic_Error) -> ^Xi_Query_Device_Reply,
	select_events:       proc "c" (conn: Connection, window: Window, num_mask: u16, masks: rawptr) -> Void_Cookie,
}

@(private) xi: Xi_Api
@(private = "file") xi_lib: dynlib.Library

// xi2_start loads libxcb-xinput, agrees a version and finds every scrolling
// valuator. False when the server or the library cannot do it, and then the
// wheel stays on core buttons — which works, it is simply notched.
@(private)
xi2_start :: proc(x: ^X11) -> bool {
	l, lok := dynlib.load_library("libxcb-xinput.so.0")
	if !lok {
		debugf(x, "libxcb-xinput unavailable: scrolling stays notched")
		return false
	}
	xi_lib = l
	a := &xi
	miss := make([dynamic]string, context.temp_allocator)
	a.query_version       = xi_sym("xcb_input_xi_query_version",       type_of(a.query_version), &miss)
	a.query_version_reply = xi_sym("xcb_input_xi_query_version_reply", type_of(a.query_version_reply), &miss)
	a.query_device        = xi_sym("xcb_input_xi_query_device",        type_of(a.query_device), &miss)
	a.query_device_reply  = xi_sym("xcb_input_xi_query_device_reply",  type_of(a.query_device_reply), &miss)
	a.select_events       = xi_sym("xcb_input_xi_select_events",       type_of(a.select_events), &miss)
	if len(miss) > 0 {
		debugf(x, "libxcb-xinput is missing %v: scrolling stays notched", miss[:])
		return false
	}

	// 2.1 is the version that introduced smooth scrolling.
	ck := a.query_version(x.conn, 2, 1)
	err: ^Generic_Error
	reply := a.query_version_reply(x.conn, ck, &err)
	free_reply(err)
	if reply == nil {
		debugf(x, "this server has no XInput2: scrolling stays notched")
		return false
	}
	major, minor := reply.major_version, reply.minor_version
	free_reply(reply)
	if major < 2 || (major == 2 && minor < 1) {
		debugf(x, "XInput %d.%d is too old for smooth scrolling", major, minor)
		return false
	}
	x.xi_opcode = extension_opcode(x, "XInputExtension")
	if x.xi_opcode == 0 do return false
	xi2_find_axes(x)
	// Listen for device changes even when nothing was found: a mouse plugged
	// in later, or a different slave sending through the master pointer,
	// changes the axes, so they are re-read rather than remembered.
	xi2_watch_devices(x)
	debugf(x, "XInput %d.%d, opcode %d, %d scroll axis/axes", major, minor, x.xi_opcode, len(x.scroll_axes))
	return len(x.scroll_axes) > 0
}

// xi2_watch_devices asks the root window for the two events that say the
// device set has changed: one for devices coming and going, one for a
// master's classes changing under it (a different slave sending through it).
//
// Neither has a core equivalent, so selecting them takes no core event
// away; only `XI_Motion` on a window does.
@(private = "file")
xi2_watch_devices :: proc(x: ^X11) {
	buf: [3]u32
	hdr := (^[2]u16)(&buf[0])
	hdr[0] = DEVICE_ALL // hierarchy events are only sent to a selection made for all devices
	hdr[1] = 1
	buf[1] = EVENT_MASK_XI_HIERARCHY_CHANGED | EVENT_MASK_XI_DEVICE_CHANGED
	xi.select_events(x.conn, x.screen.root, 1, raw_data(buf[:]))
	api.flush(x.conn)
}

// xi2_devices_changed re-reads the scrolling valuators and brings every
// window's selection into line with the answer.
//
// Both directions matter: new axes need windows selected for XI2 motion,
// and axes going away need them unselected, or core MotionNotify stays off
// and the pointer stops reaching the app.
@(private = "file")
xi2_devices_changed :: proc(x: ^X11) {
	was := xi2_scrolls(x)
	clear(&x.scroll_axes)
	xi2_find_axes(x)
	now := xi2_scrolls(x)
	if now == was {
		// Logged anyway, so "unchanged" can be told from "never arrived".
		debugf(x, "the devices changed: still %d scroll axis/axes", len(x.scroll_axes))
		return
	}
	debugf(x, "the devices changed: %d scroll axis/axes now, so XI2 motion is %s",
		len(x.scroll_axes), "selected" if now else "given up")
	for s in x.surfaces {
		if s == nil || !s.live do continue
		if now { xi2_watch(x, s.window) } else { xi2_unwatch(x, s.window) }
	}
}

// xi2_unwatch gives up XI2 motion on a window, which is what hands its core
// MotionNotify back.
@(private = "file")
xi2_unwatch :: proc(x: ^X11, w: Window) {
	buf: [3]u32
	hdr := (^[2]u16)(&buf[0])
	hdr[0] = DEVICE_ALL_MASTER
	hdr[1] = 1
	buf[1] = 0 // an empty mask is how a selection is dropped
	xi.select_events(x.conn, w, 1, raw_data(buf[:]))
	api.flush(x.conn)
}

@(private)
xi2_stop :: proc(x: ^X11) {
	delete(x.scroll_axes)
	x.scroll_axes = nil
	if xi_lib != nil {
		dynlib.unload_library(xi_lib)
		xi_lib = nil
	}
}

@(private = "file")
xi_sym :: proc($name: string, $T: typeid, miss: ^[dynamic]string) -> T {
	p, ok := dynlib.symbol_address(xi_lib, name)
	if !ok {
		append(miss, name)
		return nil
	}
	return (T)(p)
}

// xi2_find_axes walks every master device's classes for scrolling
// valuators. A device's classes follow its info after a name padded to four
// bytes; getting the padding wrong silently finds nothing.
@(private = "file")
xi2_find_axes :: proc(x: ^X11) {
	ck := xi.query_device(x.conn, DEVICE_ALL_MASTER)
	err: ^Generic_Error
	reply := xi.query_device_reply(x.conn, ck, &err)
	free_reply(err)
	if reply == nil do return
	defer free_reply(reply)

	base := ([^]u8)(reply)
	off := size_of(Xi_Query_Device_Reply)
	total := size_of(Xi_Query_Device_Reply) + int(reply.length) * 4
	for _ in 0 ..< int(reply.num_infos) {
		if off + size_of(Xi_Device_Info) > total do break
		info := (^Xi_Device_Info)(&base[off])
		p := off + size_of(Xi_Device_Info)
		p += (int(info.name_len) + 3) & ~int(3) // the name, padded to four bytes
		for _ in 0 ..< int(info.num_classes) {
			if p + size_of(Device_Class) > total do break
			cls := (^Device_Class)(&base[p])
			if cls.type == CLASS_TYPE_SCROLL && p + size_of(Scroll_Class) <= total {
				sc := (^Scroll_Class)(&base[p])
				inc := fp3232_f64(sc.increment)
				if inc != 0 {
					append(&x.scroll_axes, Scroll_Axis{
						device     = sc.sourceid,
						number     = sc.number,
						horizontal = sc.scroll_type == SCROLL_TYPE_HORIZONTAL,
						increment  = inc,
					})
				}
			}
			if cls.len == 0 do break // a zero length would loop for ever
			p += int(cls.len) * 4
		}
		off = p
	}
}

// xi2_watch asks for XI2 motion on a window, which is where the scroll
// valuators arrive. Selecting it costs the window its core MotionNotify, so
// it is only worth doing when there is a valuator to read for it.
@(private)
xi2_watch :: proc(x: ^X11, w: Window) {
	if !xi2_scrolls(x) do return
	// An event mask is a header of two u16s followed by mask_len words.
	buf: [3]u32
	hdr := (^[2]u16)(&buf[0])
	hdr[0] = DEVICE_ALL_MASTER
	hdr[1] = 1 // one mask word
	buf[1] = EVENT_MASK_XI_MOTION
	xi.select_events(x.conn, w, 1, raw_data(buf[:]))
	api.flush(x.conn)
}

// xi2_event turns an XI2 motion into scrolling. True when it was XI2's.
@(private)
xi2_event :: proc(x: ^X11, ev: ^Generic_Event) -> bool {
	if x.xi_opcode == 0 || ev.response_type & 0x7f != GE_GENERIC do return false
	e := (^Xi_Motion)(ev)
	if e.extension != x.xi_opcode do return false
	if e.event_type == XI_HIERARCHY_CHANGED || e.event_type == XI_DEVICE_CHANGED {
		xi2_devices_changed(x)
		return true
	}
	if e.event_type != XI_MOTION do return true // XI2's, but not a motion

	// The move, which the core event no longer carries for this window. The
	// coordinates are 16.16 fixed point, and `mods` is
	// {base, latched, locked, effective}.
	pointer_moved(x, e.event, i16(e.event_x >> 16), i16(e.event_y >> 16),
		i16(e.root_x >> 16), i16(e.root_y >> 16), u32(e.time), mods_of(u16(e.mods[3])))

	s := surface_of_window(x, e.event)
	if s == nil || !s.live do return true

	// After the fixed part: the button mask, then the valuator mask, then
	// one 3232 fixed-point value for each bit set in it.
	base := ([^]u8)(ev)
	mask_off := size_of(Xi_Motion) + int(e.buttons_len) * 4
	vals_off := mask_off + int(e.valuators_len) * 4
	mask := ([^]u32)(&base[mask_off])[:e.valuators_len]
	values := ([^]Fp3232)(&base[vals_off])

	delta: [2]f32
	moved := false
	vi := 0 // which value, counting only the bits that are set
	for word, wi in mask {
		for bit in 0 ..< u32(32) {
			if word & (1 << bit) == 0 do continue
			number := u16(wi) * 32 + u16(bit)
			v := fp3232_f64(values[vi])
			vi += 1
			for &ax in x.scroll_axes {
				if ax.number != number || ax.device != e.sourceid do continue
				// A valuator is a running total, so the first reading only
				// says where it started; the movement is the difference.
				if ax.seen {
					clicks := (v - ax.last) / ax.increment
					if ax.horizontal {
						delta.x += f32(clicks) * platform.SCROLL_STEP_PX
					} else {
						delta.y += f32(clicks) * platform.SCROLL_STEP_PX
					}
					moved = true
				}
				ax.last, ax.seen = v, true
			}
		}
	}
	if moved && delta != {0, 0} {
		x.wheel_echo_ms, x.wheel_echo_delta = e.time, delta
		push(x, platform.Ev_Scroll{
			surface = s.id,
			delta   = delta,
			pos     = logical(x, i16(e.event_x >> 16), i16(e.event_y >> 16)),
			precise = true, // a valuator moves by fractions of a click: this is the smooth one
			mods    = mods_of(u16(e.mods[3])), // the effective modifiers
		})
	}
	return true
}

// xi2_scrolls says whether XI2 is giving us axes at all.
@(private)
xi2_scrolls :: proc(x: ^X11) -> bool {
	return x.xi_opcode != 0 && len(x.scroll_axes) > 0
}

// How long after a valuator scroll its compatibility buttons still count as
// that same scroll. They are generated from it, so in practice they carry
// its own timestamp; the window is slack, not a guess at a delay.
@(private = "file") WHEEL_ECHO_MS :: 30

// xi2_wheel_echoed says whether this button 4-7 is the server's
// compatibility copy of a scroll already taken from a valuator, and so is
// to be dropped rather than counted twice.
//
// Narrow on purpose: "XI2 has axes" is not enough. The server emulates
// these buttons from valuator movement with the same timestamp, but XTEST
// devices have no valuators, so injected clicks (remote desktops, assistive
// tools) arrive as buttons alone and must count. Direction is checked too,
// so a vertical scroll cannot swallow a nearby horizontal click.
@(private)
xi2_wheel_echoed :: proc(x: ^X11, detail: u8, t: Timestamp) -> bool {
	if !xi2_scrolls(x) do return false
	// Unsigned, so an X timestamp wrapping round 49 days still subtracts to
	// a small number rather than a huge one.
	if u32(t) - u32(x.wheel_echo_ms) > WHEEL_ECHO_MS do return false
	d := x.wheel_echo_delta
	switch detail {
	case BUTTON_WHEEL_UP:    return d.y < 0
	case BUTTON_WHEEL_DOWN:  return d.y > 0
	case BUTTON_WHEEL_LEFT:  return d.x < 0
	case BUTTON_WHEEL_RIGHT: return d.x > 0
	}
	return false
}
