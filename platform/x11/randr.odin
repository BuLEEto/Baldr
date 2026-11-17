#+build linux
// The screens, through the RandR extension (Backend.outputs).
//
// The core protocol's Screen is the whole desktop as one rectangle (two
// monitors are one 5120x1440 screen). RandR splits it into monitors; it is
// in libxcb-randr, loaded separately, and a server without it reports one
// screen.
//
// An output is a connector (DP-1, HDMI-A-1); a CRTC is the scanout engine
// driving it, and is what has a position, a size and a mode. An output with
// no CRTC is a connector with nothing plugged in, or one that is off.
package x11

import "core:c"
import "core:dynlib"
import "core:strings"
import "baldr:platform"

Randr_Output :: distinct u32
Randr_Crtc   :: distinct u32
Randr_Mode   :: distinct u32

@(private = "file") RANDR_CONNECTION_CONNECTED :: 0

// Rotation bits, as RandR spells them.
@(private = "file") ROTATE_0   :: 1
@(private = "file") ROTATE_90  :: 2
@(private = "file") ROTATE_180 :: 4
@(private = "file") ROTATE_270 :: 8
@(private = "file") REFLECT_X  :: 16
@(private = "file") REFLECT_Y  :: 32

Randr_Query_Version_Cookie :: struct { sequence: c.uint }
Randr_Query_Version_Reply :: struct {
	response_type: u8,
	pad0:          u8,
	sequence:      u16,
	length:        u32,
	major_version: u32,
	minor_version: u32,
	pad1:          [16]u8,
}

Randr_Resources_Cookie :: struct { sequence: c.uint }
Randr_Resources_Reply :: struct {
	response_type:    u8,
	pad0:             u8,
	sequence:         u16,
	length:           u32,
	timestamp:        Timestamp,
	config_timestamp: Timestamp,
	num_crtcs:        u16,
	num_outputs:      u16,
	num_modes:        u16,
	names_len:        u16,
	pad1:             [8]u8,
}

Randr_Output_Info_Cookie :: struct { sequence: c.uint }
Randr_Output_Info_Reply :: struct {
	response_type:  u8,
	status:         u8,
	sequence:       u16,
	length:         u32,
	timestamp:      Timestamp,
	crtc:           Randr_Crtc,
	mm_width:       u32,
	mm_height:      u32,
	connection:     u8,
	subpixel_order: u8,
	num_crtcs:      u16,
	num_modes:      u16,
	num_preferred:  u16,
	num_clones:     u16,
	name_len:       u16,
}

Randr_Crtc_Info_Cookie :: struct { sequence: c.uint }
Randr_Crtc_Info_Reply :: struct {
	response_type:        u8,
	status:               u8,
	sequence:             u16,
	length:               u32,
	timestamp:            Timestamp,
	x, y:                 i16,
	width, height:        u16,
	mode:                 Randr_Mode,
	rotation:             u16,
	rotations:            u16,
	num_outputs:          u16,
	num_possible_outputs: u16,
}

Randr_Mode_Info :: struct {
	id:           Randr_Mode,
	width:        u16,
	height:       u16,
	dot_clock:    u32,
	hsync_start:  u16,
	hsync_end:    u16,
	htotal:       u16,
	hskew:        u16,
	vsync_start:  u16,
	vsync_end:    u16,
	vtotal:       u16,
	name_len:     u32,
	mode_flags:   u32,
}

Randr_Api :: struct {
	query_version:       proc "c" (conn: Connection, major, minor: u32) -> Randr_Query_Version_Cookie,
	query_version_reply: proc "c" (conn: Connection, ck: Randr_Query_Version_Cookie, e: ^^Generic_Error) -> ^Randr_Query_Version_Reply,

	get_screen_resources_current:       proc "c" (conn: Connection, w: Window) -> Randr_Resources_Cookie,
	get_screen_resources_current_reply: proc "c" (conn: Connection, ck: Randr_Resources_Cookie, e: ^^Generic_Error) -> ^Randr_Resources_Reply,
	get_screen_resources_current_outputs: proc "c" (r: ^Randr_Resources_Reply) -> [^]Randr_Output,
	get_screen_resources_current_modes:   proc "c" (r: ^Randr_Resources_Reply) -> [^]Randr_Mode_Info,

	get_output_info:       proc "c" (conn: Connection, o: Randr_Output, ts: Timestamp) -> Randr_Output_Info_Cookie,
	get_output_info_reply: proc "c" (conn: Connection, ck: Randr_Output_Info_Cookie, e: ^^Generic_Error) -> ^Randr_Output_Info_Reply,
	get_output_info_name:  proc "c" (r: ^Randr_Output_Info_Reply) -> [^]u8,
	get_output_info_name_length: proc "c" (r: ^Randr_Output_Info_Reply) -> c.int,

	get_crtc_info:       proc "c" (conn: Connection, crtc: Randr_Crtc, ts: Timestamp) -> Randr_Crtc_Info_Cookie,
	get_crtc_info_reply: proc "c" (conn: Connection, ck: Randr_Crtc_Info_Cookie, e: ^^Generic_Error) -> ^Randr_Crtc_Info_Reply,
}

randr: Randr_Api
@(private = "file") randr_lib: dynlib.Library
@(private) randr_ok: bool

// randr_load dlopens libxcb-randr. False on a server without it, which is
// not an error: `outputs()` then reports the one screen the core protocol
// knows about.
@(private)
randr_load :: proc() -> bool {
	if randr_ok do return true
	l, lok := dynlib.load_library("libxcb-randr.so.0")
	if !lok do return false
	randr_lib = l
	miss := make([dynamic]string, context.temp_allocator)
	a := &randr
	a.query_version       = randr_sym("xcb_randr_query_version",       type_of(a.query_version), &miss)
	a.query_version_reply = randr_sym("xcb_randr_query_version_reply", type_of(a.query_version_reply), &miss)
	a.get_screen_resources_current       = randr_sym("xcb_randr_get_screen_resources_current",       type_of(a.get_screen_resources_current), &miss)
	a.get_screen_resources_current_reply = randr_sym("xcb_randr_get_screen_resources_current_reply", type_of(a.get_screen_resources_current_reply), &miss)
	a.get_screen_resources_current_outputs = randr_sym("xcb_randr_get_screen_resources_current_outputs", type_of(a.get_screen_resources_current_outputs), &miss)
	a.get_screen_resources_current_modes   = randr_sym("xcb_randr_get_screen_resources_current_modes",   type_of(a.get_screen_resources_current_modes), &miss)
	a.get_output_info       = randr_sym("xcb_randr_get_output_info",       type_of(a.get_output_info), &miss)
	a.get_output_info_reply = randr_sym("xcb_randr_get_output_info_reply", type_of(a.get_output_info_reply), &miss)
	a.get_output_info_name  = randr_sym("xcb_randr_get_output_info_name",  type_of(a.get_output_info_name), &miss)
	a.get_output_info_name_length = randr_sym("xcb_randr_get_output_info_name_length", type_of(a.get_output_info_name_length), &miss)
	a.get_crtc_info       = randr_sym("xcb_randr_get_crtc_info",       type_of(a.get_crtc_info), &miss)
	a.get_crtc_info_reply = randr_sym("xcb_randr_get_crtc_info_reply", type_of(a.get_crtc_info_reply), &miss)
	if len(miss) > 0 {
		dynlib.unload_library(randr_lib)
		randr_lib = nil
		return false
	}
	randr_ok = true
	return true
}

@(private = "file")
randr_sym :: proc($name: string, $T: typeid, miss: ^[dynamic]string) -> T {
	p, ok := dynlib.symbol_address(randr_lib, name)
	if !ok {
		append(miss, name)
		return nil
	}
	return (T)(p)
}

// outputs is the screens as last read (Backend.outputs). Owned by the
// backend, valid until the next Ev_Outputs.
@(private)
outputs :: proc(b: ^platform.Backend) -> []platform.Output {
	return data(b).screens[:]
}

// outputs_refresh re-reads the monitors, and says whether anything the
// toolkit reports changed.
@(private)
outputs_refresh :: proc(x: ^X11) -> (changed: bool) {
	next := make([dynamic]platform.Output, 0, 4, x.allocator)
	if !randr_read(x, &next) do randr_fallback(x, &next)
	changed = !outputs_same(x.screens[:], next[:])
	if !changed {
		outputs_free(next[:], x.allocator)
		delete(next)
		return
	}
	outputs_free(x.screens[:], x.allocator)
	delete(x.screens)
	x.screens = next
	return
}

// randr_read fills `out` from RandR. False when the extension is absent or
// says nothing useful.
@(private = "file")
randr_read :: proc(x: ^X11, out: ^[dynamic]platform.Output) -> bool {
	if !randr_ok || x.screen == nil do return false
	ck := randr.get_screen_resources_current(x.conn, x.screen.root)
	err: ^Generic_Error
	res := randr.get_screen_resources_current_reply(x.conn, ck, &err)
	free_reply(err)
	if res == nil do return false
	defer free_reply(res)

	out_ids := randr.get_screen_resources_current_outputs(res)
	modes := randr.get_screen_resources_current_modes(res)
	n_modes := int(res.num_modes)
	sc := x.scale if x.scale > 0 else 1

	for i in 0 ..< int(res.num_outputs) {
		oi_ck := randr.get_output_info(x.conn, out_ids[i], res.config_timestamp)
		oerr: ^Generic_Error
		oi := randr.get_output_info_reply(x.conn, oi_ck, &oerr)
		free_reply(oerr)
		if oi == nil do continue
		defer free_reply(oi)
		// Not connected, or connected and switched off: either way there is
		// no screen there to put a window on.
		if oi.connection != RANDR_CONNECTION_CONNECTED || oi.crtc == Randr_Crtc(0) do continue

		ci_ck := randr.get_crtc_info(x.conn, oi.crtc, res.config_timestamp)
		cerr: ^Generic_Error
		ci := randr.get_crtc_info_reply(x.conn, ci_ck, &cerr)
		free_reply(cerr)
		if ci == nil do continue
		defer free_reply(ci)
		if ci.width == 0 || ci.height == 0 do continue

		name := ""
		if nl := int(randr.get_output_info_name_length(oi)); nl > 0 {
			name = strings.clone(string(randr.get_output_info_name(oi)[:nl]), x.allocator)
		}
		o := platform.Output{
			name      = name,
			pos       = {i32(ci.x), i32(ci.y)},
			mode_px   = {i32(ci.width), i32(ci.height)},
			size      = {i32(f32(ci.width) / sc), i32(f32(ci.height) / sc)},
			scale     = sc,
			transform = transform_of(ci.rotation),
			refresh   = refresh_mhz(modes[:n_modes], ci.mode),
		}
		append(out, o)
	}
	return len(out) > 0
}

// randr_fallback is the whole desktop as one screen, which is what the core
// protocol knows and what a server without RandR can say.
@(private = "file")
randr_fallback :: proc(x: ^X11, out: ^[dynamic]platform.Output) {
	if x.screen == nil do return
	sc := x.scale if x.scale > 0 else 1
	w, h := i32(x.screen.width_in_pixels), i32(x.screen.height_in_pixels)
	append(out, platform.Output{
		name    = strings.clone("screen", x.allocator),
		pos     = {0, 0},
		mode_px = {w, h},
		size    = {i32(f32(w) / sc), i32(f32(h) / sc)},
		scale   = sc,
	})
}

// refresh_mhz works the rate out of the mode's timings, since RandR states
// the pixel clock rather than a rate: dot_clock / (htotal * vtotal).
@(private = "file")
refresh_mhz :: proc(modes: []Randr_Mode_Info, id: Randr_Mode) -> i32 {
	for m in modes {
		if m.id != id do continue
		total := u64(m.htotal) * u64(m.vtotal)
		if total == 0 do return 0
		return i32(u64(m.dot_clock) * 1000 / total)
	}
	return 0
}

// transform_of maps RandR's rotation bits onto the contract's, which counts
// counter-clockwise as Wayland does.
@(private = "file")
transform_of :: proc(rotation: u16) -> platform.Output_Transform {
	flipped := rotation & (REFLECT_X | REFLECT_Y) != 0
	switch {
	case rotation & ROTATE_90 != 0:  return .Flipped_270 if flipped else .Rotate_270
	case rotation & ROTATE_180 != 0: return .Flipped_180 if flipped else .Rotate_180
	case rotation & ROTATE_270 != 0: return .Flipped_90 if flipped else .Rotate_90
	}
	return .Flipped if flipped else .Normal
}

@(private = "file")
outputs_same :: proc(a, b: []platform.Output) -> bool {
	if len(a) != len(b) do return false
	for x, i in a {
		y := b[i]
		if x.name != y.name || x.pos != y.pos || x.size != y.size do return false
		if x.mode_px != y.mode_px || x.scale != y.scale do return false
		if x.transform != y.transform || x.refresh != y.refresh do return false
	}
	return true
}

@(private = "file")
outputs_free :: proc(list: []platform.Output, allocator := context.allocator) {
	for o in list {
		delete(o.name, allocator)
		delete(o.description, allocator)
	}
}

@(private)
outputs_shutdown :: proc(x: ^X11) {
	outputs_free(x.screens[:], x.allocator)
	delete(x.screens)
	x.screens = nil
}
