package wayland

// Drawing tablets (zwp_tablet_v2): a pen's position, pressure,
// tilt, rotation, distance, which end is down, its barrel buttons, and it
// coming near and going away. A tool's events arrive in a burst closed by
// `frame`; each burst becomes one Ev_Pen carrying the tool's whole state.
// Once an app binds the protocol a compositor sends it tablet events rather
// than pointer events made from them, so the toolkit drives its ordinary
// pointer from Ev_Pen too (a pen presses buttons and drags sliders) as well
// as handing the samples to a canvas.

import "baldr:platform"
import wl "baldr:platform/wayland/wl"

// BTN_STYLUS* are the barrel buttons, in the order a pen numbers them.
@(private) BTN_STYLUS  :: 0x14b
@(private) BTN_STYLUS2 :: 0x14c
@(private) BTN_STYLUS3 :: 0x149

// Tool_State is one tablet tool (a pen, its eraser, an airbrush) and what
// its current frame has changed.
@(private)
Tool_State :: struct {
	st:        ^State,
	proxy:     wl.Proxy,
	l:         wl.Zwp_Tablet_Tool_V2_Listener,
	cursor:    wl.Proxy, // its wp_cursor_shape_device_v1
	pic_surface:  wl.Proxy, // its own surface for a cursor picture (a surface is one device's cursor)
	pic_viewport: wl.Proxy,
	tool:      platform.Pen_Tool,
	focus:     ^Surface_State,
	enter_serial: u32,
	pos:       [2]f32,
	pressure:  f32,
	tilt:      [2]f32,
	rotation:  f32,
	distance:  f32,
	contact:   bool,
	buttons:   u8,
	// what this frame did, sent in this order when it closes
	near, moved, down, up, away: bool,
	changed:   [dynamic]Button_Change,
	serial:    u32,
}

@(private)
Button_Change :: struct { button: u8, pressed: bool, serial: u32 }

@(private)
tablet_init :: proc(st: ^State) {
	if st.tablet_mgr == nil || st.seat == nil do return
	st.tablet_seat = wl.zwp_tablet_manager_v2_get_tablet_seat(st.tablet_mgr, st.seat)
	@(static) seat_l: wl.Zwp_Tablet_Seat_V2_Listener
	seat_l = wl.zwp_tablet_seat_v2_listener_noop()
	seat_l.tool_added = on_tool_added
	wl.zwp_tablet_seat_v2_add_listener(st.tablet_seat, &seat_l, st)
	debugf(st, "tablet: seat bound")
}

@(private)
tablet_shutdown :: proc(st: ^State) {
	for t in st.tools do tool_free(t)
	delete(st.tools)
	st.tools = nil
	if st.tablet_seat != nil { wl.zwp_tablet_seat_v2_destroy(st.tablet_seat); st.tablet_seat = nil }
	if st.tablet_mgr != nil { wl.zwp_tablet_manager_v2_destroy(st.tablet_mgr); st.tablet_mgr = nil }
}

@(private)
tool_free :: proc(t: ^Tool_State) {
	if t.cursor != nil do wl.wp_cursor_shape_device_v1_destroy(t.cursor)
	if t.pic_viewport != nil do wl.wp_viewport_destroy(t.pic_viewport)
	if t.pic_surface != nil do wl.wl_surface_destroy(t.pic_surface)
	if t.proxy != nil do wl.zwp_tablet_tool_v2_destroy(t.proxy)
	delete(t.changed)
	free(t)
}

@(private)
on_tool_added :: proc "c" (data: rawptr, p: wl.Proxy, id: wl.Proxy) {
	st := (^State)(data)
	context = st.ctx
	t := new(Tool_State)
	t.st, t.proxy, t.distance = st, id, -1
	t.l = wl.zwp_tablet_tool_v2_listener_noop()
	t.l.type_ = proc "c" (data: rawptr, p: wl.Proxy, kind: wl.Zwp_Tablet_Tool_V2_Type) {
		t := (^Tool_State)(data)
		#partial switch kind {
		case .Pen:      t.tool = .Pen
		case .Eraser:   t.tool = .Eraser
		case .Brush:    t.tool = .Brush
		case .Pencil:   t.tool = .Pencil
		case .Airbrush: t.tool = .Airbrush
		case .Finger:   t.tool = .Finger
		case .Mouse:    t.tool = .Mouse
		case .Lens:     t.tool = .Lens
		}
	}
	t.l.removed = proc "c" (data: rawptr, p: wl.Proxy) {
		t := (^Tool_State)(data)
		context = t.st.ctx
		for x, i in t.st.tools do if x == t {
			unordered_remove(&t.st.tools, i)
			break
		}
		tool_free(t)
	}
	t.l.proximity_in = proc "c" (data: rawptr, p: wl.Proxy, serial: u32, tablet: wl.Proxy, surface: wl.Proxy) {
		t := (^Tool_State)(data)
		context = t.st.ctx
		t.focus = lookup_wl(t.st, surface)
		t.enter_serial = serial
		t.near = true
		tool_apply_cursor(t)
	}
	t.l.proximity_out = proc "c" (data: rawptr, p: wl.Proxy) {
		t := (^Tool_State)(data)
		t.away = true
	}
	t.l.down = proc "c" (data: rawptr, p: wl.Proxy, serial: u32) {
		t := (^Tool_State)(data)
		t.contact, t.down, t.serial = true, true, serial
		t.st.input_serial = serial // proof of a user action, as a button's
	}
	t.l.up = proc "c" (data: rawptr, p: wl.Proxy) {
		t := (^Tool_State)(data)
		t.contact, t.up = false, true
	}
	t.l.motion = proc "c" (data: rawptr, p: wl.Proxy, x, y: wl.Fixed) {
		t := (^Tool_State)(data)
		t.pos = {wl.fixed_to_f32(x), wl.fixed_to_f32(y)}
		t.moved = true
	}
	t.l.pressure = proc "c" (data: rawptr, p: wl.Proxy, v: u32) {
		t := (^Tool_State)(data)
		t.pressure = f32(v) / 65535
		t.moved = true
	}
	t.l.distance = proc "c" (data: rawptr, p: wl.Proxy, v: u32) {
		t := (^Tool_State)(data)
		t.distance = f32(v) / 65535
		t.moved = true
	}
	t.l.tilt = proc "c" (data: rawptr, p: wl.Proxy, x, y: wl.Fixed) {
		t := (^Tool_State)(data)
		t.tilt = {wl.fixed_to_f32(x), wl.fixed_to_f32(y)}
		t.moved = true
	}
	t.l.rotation = proc "c" (data: rawptr, p: wl.Proxy, degrees: wl.Fixed) {
		t := (^Tool_State)(data)
		t.rotation = wl.fixed_to_f32(degrees)
		t.moved = true
	}
	t.l.button = proc "c" (data: rawptr, p: wl.Proxy, serial: u32, button: u32, state: wl.Zwp_Tablet_Tool_V2_Button_State) {
		t := (^Tool_State)(data)
		context = t.st.ctx
		which: u8
		switch button {
		case BTN_STYLUS:  which = 0
		case BTN_STYLUS2: which = 1
		case BTN_STYLUS3: which = 2
		case: return
		}
		pressed := state == .Pressed
		if pressed { t.buttons |= 1 << which } else { t.buttons &~= 1 << which }
		t.st.input_serial = serial
		append(&t.changed, Button_Change{which, pressed, serial})
	}
	t.l.frame = on_tool_frame
	wl.zwp_tablet_tool_v2_add_listener(id, &t.l, t)
	if st.cursor_shape_mgr != nil do t.cursor = wl.wp_cursor_shape_manager_v1_get_tablet_tool_v2(st.cursor_shape_mgr, id)
	append(&st.tools, t)
}

// on_tool_frame closes a burst: what it did goes out as Ev_Pen, in the
// order it happened — near, the tip down, a move, the buttons, the tip up,
// away — each carrying the tool's whole state.
@(private)
on_tool_frame :: proc "c" (data: rawptr, p: wl.Proxy, time: u32) {
	t := (^Tool_State)(data)
	st := t.st
	context = st.ctx
	defer {
		t.near, t.moved, t.down, t.up, t.away = false, false, false, false, false
		clear(&t.changed)
	}
	s := t.focus
	if s == nil do return // over something not ours
	send :: proc(t: ^Tool_State, s: ^Surface_State, phase: platform.Pen_Phase, time: u32, button: u8 = 0, pressed := false, serial: u32 = 0) {
		push(t.st, platform.Ev_Pen{
			surface = s.id, phase = phase, tool = t.tool, pos = t.pos,
			pressure = t.pressure, tilt = t.tilt, rotation = t.rotation, distance = t.distance,
			contact = t.contact, buttons = t.buttons, button = button, pressed = pressed,
			mods = t.st.mods, time_ms = time, serial = serial if serial != 0 else t.serial,
		})
	}
	if t.near do send(t, s, .Near, time)
	if t.down do send(t, s, .Down, time)
	if t.moved && !t.near do send(t, s, .Move, time)
	for c in t.changed do send(t, s, .Button, time, c.button, c.pressed, c.serial)
	if t.up do send(t, s, .Up, time)
	if t.away {
		send(t, s, .Away, time)
		t.focus = nil
	}
}

// tool_apply_cursor gives the tool the shape its surface wants, as the
// pointer's is given on enter (apply_cursor).
@(private)
tool_apply_cursor :: proc(t: ^Tool_State) {
	s := t.focus
	if s == nil do return
	if s.cursor == .Hidden {
		wl.zwp_tablet_tool_v2_set_cursor(t.proxy, t.enter_serial, nil, 0, 0)
	} else if s.cursor == .Picture && s.cursor_pic.buffer != nil {
		if t.pic_surface == nil do t.pic_surface = wl.wl_compositor_create_surface(t.st.compositor)
		if t.pic_viewport == nil && t.st.viewporter != nil do t.pic_viewport = wl.wp_viewporter_get_viewport(t.st.viewporter, t.pic_surface)
		hot := cursor_picture_show(t.st, t.pic_surface, t.pic_viewport, s.cursor_pic)
		wl.zwp_tablet_tool_v2_set_cursor(t.proxy, t.enter_serial, t.pic_surface, hot.x, hot.y)
	} else if t.cursor != nil {
		wl.wp_cursor_shape_device_v1_set_shape(t.cursor, t.enter_serial, cursor_shape(s.cursor))
	}
	wl.display_flush(t.st.display)
}
