#+build linux
package x11

// A *measured* frame clock, through the Present extension.
//
// The nominal rate is an assumption: a 60 Hz mode is often 59.94 Hz, and
// a variable-refresh screen has no fixed interval. Present says when a
// vblank actually happened.
//
// It is asked for directly, not hooked onto the app's presents: with
// Vulkan the present happens inside vkQueuePresentKHR, so there is nothing
// here to attach a request to. `notify_msc` asks the server to report when
// a vblank count is reached, drawn or not; one request per frame, each for
// the next count, is a vblank clock.
//
// A PresentCompleteNotify carries `ust` (the vblank's time, microseconds on
// the server's clock) and `msc` (its number). The interval is the
// difference between two; a gap in the counts means missed frames.

import "core:c"
import "core:dynlib"

Present_Api :: struct {
	query_version:       proc "c" (conn: Connection, major, minor: u32) -> Present_Version_Cookie,
	query_version_reply: proc "c" (conn: Connection, ck: Present_Version_Cookie, e: ^^Generic_Error) -> ^Present_Version_Reply,
	select_input: proc "c" (conn: Connection, eid: u32, window: Window, event_mask: u32) -> Void_Cookie,
	notify_msc:   proc "c" (conn: Connection, window: Window, serial: u32,
		target_msc, divisor, remainder: u64) -> Void_Cookie,
}

Present_Version_Cookie :: struct { sequence: c.uint }
Present_Version_Reply :: struct {
	response_type: u8,
	pad0:          u8,
	sequence:      u16,
	length:        u32,
	major_version: u32,
	minor_version: u32,
}

// PresentCompleteNotify, as it arrives inside a GenericEvent.
//
// #packed, with `full_sequence` between `ust` and `msc`: the header marks
// it XCB_PACKED, and libxcb splices `full_sequence` into every generic
// event. Get either wrong and the event still arrives with nonsense numbers.
// Layout as in xcb/present.h.
Present_Complete_Notify :: struct #packed {
	response_type: u8,
	extension:     u8,
	sequence:      u16,
	length:        u32,
	evtype:        u16,
	kind:          u8, // 0 = this was a notify_msc, 1 = a pixmap reached the screen
	mode:          u8, // copied, flipped, skipped, suboptimal
	eid:           u32,
	window:        Window,
	serial:        u32,
	ust:           u64, // the vblank's time, microseconds on the server's clock
	full_sequence: u32,
	msc:           u64, // …and its number
}
#assert(size_of(Present_Complete_Notify) == 44)

@(private = "file") PRESENT_COMPLETE_NOTIFY :: 0
@(private = "file") PRESENT_EVENT_MASK_COMPLETE_NOTIFY :: 1 << 0
@(private = "file") GE_GENERIC :: 35

@(private) present: Present_Api
@(private = "file") present_lib: dynlib.Library

// present_start loads libxcb-present and agrees a version. False on a
// server without it, which is not an error: the clock then paces on the
// nominal rate and says `estimated`.
@(private)
present_start :: proc(x: ^X11) -> bool {
	l, lok := dynlib.load_library("libxcb-present.so.0")
	if !lok {
		debugf(x, "libxcb-present unavailable: the frame clock uses the nominal rate")
		return false
	}
	present_lib = l
	a := &present
	miss := make([dynamic]string, context.temp_allocator)
	a.query_version       = present_sym("xcb_present_query_version",       type_of(a.query_version), &miss)
	a.query_version_reply = present_sym("xcb_present_query_version_reply", type_of(a.query_version_reply), &miss)
	a.select_input        = present_sym("xcb_present_select_input",        type_of(a.select_input), &miss)
	a.notify_msc          = present_sym("xcb_present_notify_msc",          type_of(a.notify_msc), &miss)
	if len(miss) > 0 {
		debugf(x, "libxcb-present is missing %v", miss[:])
		return false
	}
	ck := a.query_version(x.conn, 1, 0)
	err: ^Generic_Error
	reply := a.query_version_reply(x.conn, ck, &err)
	free_reply(err)
	if reply == nil {
		debugf(x, "this server has no Present extension: the frame clock uses the nominal rate")
		return false
	}
	defer free_reply(reply)
	// The opcode is what marks a GenericEvent as Present's.
	x.present_opcode = extension_opcode(x, "Present")
	if x.present_opcode == 0 do return false
	debugf(x, "Present %d.%d, opcode %d", reply.major_version, reply.minor_version, x.present_opcode)
	return true
}

@(private)
present_stop :: proc() {
	if present_lib != nil {
		dynlib.unload_library(present_lib)
		present_lib = nil
	}
}

@(private = "file")
present_sym :: proc($name: string, $T: typeid, miss: ^[dynamic]string) -> T {
	p, ok := dynlib.symbol_address(present_lib, name)
	if !ok {
		append(miss, name)
		return nil
	}
	return (T)(p)
}

// present_watch starts a vblank clock on `s`, or stops one.
@(private)
present_watch :: proc(x: ^X11, s: ^Surface, on: bool) {
	if x.present_opcode == 0 do return
	if on {
		if s.present_eid == 0 {
			s.present_eid = api.generate_id(x.conn)
			present.select_input(x.conn, s.present_eid, s.window, PRESENT_EVENT_MASK_COMPLETE_NOTIFY)
			debugf(x, "Present: watching window %d as eid %d", u32(s.window), s.present_eid)
		}
		present_ask_next(x, s)
	} else if s.present_eid != 0 {
		present.select_input(x.conn, s.present_eid, s.window, 0)
		s.present_eid = 0
		s.present_msc = 0
	}
	api.flush(x.conn)
}

// present_ask_next asks to be told about the next vblank.
//
// Ask for a count in the future, not a rule: "any msc" (divisor 1, target
// 0) is satisfied by a past vblank, so the server answers at once and the
// clock stops after one event. `last + 1` with divisor 0 is the next vblank
// only. The first request asks the loose way, to learn the current count.
@(private)
present_ask_next :: proc(x: ^X11, s: ^Surface) {
	if x.present_opcode == 0 || s.present_eid == 0 do return
	if s.present_msc == 0 {
		present.notify_msc(x.conn, s.window, 0, 0, 1, 0) // "whatever it is now"
	} else {
		present.notify_msc(x.conn, s.window, 0, s.present_msc + 1, 0, 0)
	}
	api.flush(x.conn)
}

// present_event handles a GenericEvent that might be Present's. True when
// it was, and the caller should not look further.
@(private)
present_event :: proc(x: ^X11, ev: ^Generic_Event) -> bool {
	if x.present_opcode == 0 || ev.response_type & 0x7f != GE_GENERIC do return false
	e := (^Present_Complete_Notify)(ev)
	if e.extension != u8(x.present_opcode) do return false
	if e.evtype != PRESENT_COMPLETE_NOTIFY do return true // Present's, but not ours to use

	s := surface_of_window(x, e.window)
	if s == nil || !s.live do return true

	// Two vblanks make an interval; the first only starts the clock.
	// Some drivers report `ust` equal to `msc`, which would set the clock
	// wrong, so a refresh outside 1 to 100 ms (1000 Hz to 10 Hz) is not a
	// display: it is dropped and the nominal rate stands.
	if s.present_msc != 0 && e.msc > s.present_msc && e.ust > s.present_ust {
		gap := e.msc - s.present_msc
		us := f64(e.ust - s.present_ust)
		ms := us / 1000.0 / f64(gap) // per vblank, even if some were missed
		if gap > 0 && ms >= 1 && ms <= 100 {
			s.refresh_ms = ms
			s.measured = true
		} else if !s.present_warned {
			s.present_warned = true
			debugf(x, "Present timings are not believable (%.3f ms between msc %d and %d); keeping the nominal rate",
				ms, s.present_msc, e.msc)
		}
	}
	s.present_msc, s.present_ust = e.msc, e.ust
	present_ask_next(x, s) // keep the clock running
	return true
}

// extension_opcode asks which major opcode an extension was given, which is
// what marks its GenericEvents.
@(private)
extension_opcode :: proc(x: ^X11, name: string) -> u8 {
	ck := api.query_extension(x.conn, u16(len(name)), cstring(raw_data(name)))
	err: ^Generic_Error
	reply := api.query_extension_reply(x.conn, ck, &err)
	free_reply(err)
	if reply == nil do return 0
	defer free_reply(reply)
	if reply.present == 0 do return 0
	return reply.major_opcode
}
