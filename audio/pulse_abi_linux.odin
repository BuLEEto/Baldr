#+build linux
// libpulse's client ABI, loaded at runtime with `core:dynlib` — nothing is
// linked and no C is compiled, as the dependency rule requires.
//
// PulseAudio rather than PipeWire: every PipeWire desktop runs
// `pipewire-pulse`, so the Pulse client protocol reaches both. Native
// PipeWire wants its format as an SPA POD, built in C by macro, which from
// Odin is several hundred lines of hand-assembled ABI; `pa_sample_spec` is
// three fields. A native PipeWire backend can drop in behind the same seam.
//
// Not ALSA: `default` goes through whichever plugin is installed, and on a
// PipeWire box without `pipewire-alsa` it takes the card exclusively or
// fails because PipeWire already holds it.
//
// Layouts and prototypes follow /usr/include/pulse (PulseAudio 17.0,
// protocol 35); this part of the ABI has not changed since 0.9.x.
package audio

import "core:c"
import "core:dynlib"

// pa_sample_format_t, in full. The formats never asked for are not
// padding: dropping one shifts every value after it, and asking for S16LE
// while reading f32 is no error (the server converts, and the samples
// arrive as NaNs and denormals).
Pa_Sample_Format :: enum i32 {
	Invalid   = -1,
	U8        = 0,
	ALaw      = 1,
	ULaw      = 2,
	S16LE     = 3,
	S16BE     = 4,
	Float32LE = 5,
	Float32BE = 6,
	S32LE     = 7,
	S32BE     = 8,
	S24LE     = 9,
	S24BE     = 10,
	S24_32LE  = 11,
	S24_32BE  = 12,
}

// The f32 format in this machine's byte order.
PA_SAMPLE_F32 :: Pa_Sample_Format.Float32LE when ODIN_ENDIAN == .Little else Pa_Sample_Format.Float32BE

// pa_sample_spec: i32 + u32 + u8, 12 bytes with tail padding.
Pa_Sample_Spec :: struct {
	format:   Pa_Sample_Format,
	rate:     u32,
	channels: u8,
}

// pa_buffer_attr: five u32s. `(u32)-1` on any of them means "whatever the
// server thinks sensible", which is the documented default.
Pa_Buffer_Attr :: struct {
	maxlength: u32,
	tlength:   u32, // playback: the latency target, with ADJUST_LATENCY
	prebuf:    u32,
	minreq:    u32,
	fragsize:  u32, // record: how much the server batches before calling back
}

PA_UNSPEC :: u32(0xffff_ffff)

Pa_Context_State :: enum i32 {
	Unconnected  = 0,
	Connecting   = 1,
	Authorizing  = 2,
	Setting_Name = 3,
	Ready        = 4,
	Failed       = 5,
	Terminated   = 6,
}

Pa_Stream_State :: enum i32 {
	Unconnected = 0,
	Creating    = 1,
	Ready       = 2,
	Failed      = 3,
	Terminated  = 4,
}

PA_STREAM_INTERPOLATE_TIMING :: u32(0x0002)
PA_STREAM_AUTO_TIMING_UPDATE :: u32(0x0008)
PA_STREAM_ADJUST_LATENCY     :: u32(0x2000)

PA_SEEK_RELATIVE :: i32(0)

// pa_error_code_t, in order, starting at PA_OK = 0.
PA_OK                       :: i32(0)
PA_ERR_ACCESS               :: i32(1)
PA_ERR_INVALID              :: i32(3)
PA_ERR_NOENTITY             :: i32(5)
PA_ERR_CONNECTIONREFUSED    :: i32(6)
PA_ERR_CONNECTIONTERMINATED :: i32(11)
PA_ERR_KILLED               :: i32(12)
PA_ERR_INVALIDSERVER        :: i32(13)
PA_ERR_NOTSUPPORTED         :: i32(19)

Pa_Notify_Cb  :: proc "c" (obj: rawptr, user: rawptr)
Pa_Request_Cb :: proc "c" (s: rawptr, nbytes: c.size_t, user: rawptr)

// Pulse_Api is the dlsym'd function table for libpulse.so.0. Opaque
// pointers stay `rawptr`: this package never looks inside one.
Pulse_Api :: struct {
	threaded_mainloop_new:         proc "c" () -> rawptr,
	threaded_mainloop_free:        proc "c" (m: rawptr),
	threaded_mainloop_start:       proc "c" (m: rawptr) -> i32,
	threaded_mainloop_stop:        proc "c" (m: rawptr),
	threaded_mainloop_lock:        proc "c" (m: rawptr),
	threaded_mainloop_unlock:      proc "c" (m: rawptr),
	threaded_mainloop_get_api:     proc "c" (m: rawptr) -> rawptr,
	threaded_mainloop_set_name:    proc "c" (m: rawptr, name: cstring),
	context_new:                   proc "c" (api: rawptr, name: cstring) -> rawptr,
	context_unref:                 proc "c" (ctx: rawptr),
	context_set_state_callback:    proc "c" (ctx: rawptr, cb: Pa_Notify_Cb, user: rawptr),
	context_connect:               proc "c" (ctx: rawptr, server: cstring, flags: u32, api: rawptr) -> i32,
	context_disconnect:            proc "c" (ctx: rawptr),
	context_get_state:             proc "c" (ctx: rawptr) -> Pa_Context_State,
	context_errno:                 proc "c" (ctx: rawptr) -> i32,
	stream_new:                    proc "c" (ctx: rawptr, name: cstring, ss: ^Pa_Sample_Spec, chmap: rawptr) -> rawptr,
	stream_unref:                  proc "c" (s: rawptr),
	stream_get_state:              proc "c" (s: rawptr) -> Pa_Stream_State,
	stream_set_state_callback:     proc "c" (s: rawptr, cb: Pa_Notify_Cb, user: rawptr),
	stream_set_read_callback:      proc "c" (s: rawptr, cb: Pa_Request_Cb, user: rawptr),
	stream_set_write_callback:     proc "c" (s: rawptr, cb: Pa_Request_Cb, user: rawptr),
	stream_set_underflow_callback: proc "c" (s: rawptr, cb: Pa_Notify_Cb, user: rawptr),
	stream_connect_record:         proc "c" (s: rawptr, dev: cstring, attr: ^Pa_Buffer_Attr, flags: u32) -> i32,
	stream_connect_playback:       proc "c" (s: rawptr, dev: cstring, attr: ^Pa_Buffer_Attr, flags: u32, volume: rawptr, sync_stream: rawptr) -> i32,
	stream_disconnect:             proc "c" (s: rawptr) -> i32,
	stream_peek:                   proc "c" (s: rawptr, data: ^rawptr, nbytes: ^c.size_t) -> i32,
	stream_drop:                   proc "c" (s: rawptr) -> i32,
	stream_write:                  proc "c" (s: rawptr, data: rawptr, nbytes: c.size_t, free_cb: rawptr, offset: i64, seek: i32) -> i32,
	stream_writable_size:          proc "c" (s: rawptr) -> c.size_t,
	stream_get_latency:            proc "c" (s: rawptr, r_usec: ^u64, negative: ^i32) -> i32,
	stream_get_time:               proc "c" (s: rawptr, r_usec: ^u64) -> i32,
	stream_flush:                  proc "c" (s: rawptr, cb: rawptr, user: rawptr) -> rawptr,
	stream_get_sample_spec:        proc "c" (s: rawptr) -> ^Pa_Sample_Spec,
	operation_unref:               proc "c" (o: rawptr),
	strerror:                      proc "c" (err: i32) -> cstring,
}

@(private = "file")
pulse_lib: dynlib.Library
@(private = "file")
pulse_api: Pulse_Api
@(private = "file")
pulse_ok: bool
@(private = "file")
pulse_tried: bool

// pulse_load dlopens libpulse.so.0 once per process and fills the table.
// Returns false when the library or any symbol is missing — the stream
// then reports `.No_Library`, which is a real answer for a machine with no
// sound server installed.
@(private)
pulse_load :: proc() -> (^Pulse_Api, bool) {
	if pulse_tried do return &pulse_api, pulse_ok
	pulse_tried = true

	lib, lok := dynlib.load_library("libpulse.so.0")
	if !lok do return &pulse_api, false
	pulse_lib = lib

	a := &pulse_api
	missing := false
	sym :: proc(lib: dynlib.Library, name: string, $T: typeid, missing: ^bool) -> T {
		p, ok := dynlib.symbol_address(lib, name)
		if !ok || p == nil {
			missing^ = true
			z: T
			return z
		}
		return transmute(T)p
	}
	a.threaded_mainloop_new         = sym(lib, "pa_threaded_mainloop_new",         type_of(a.threaded_mainloop_new), &missing)
	a.threaded_mainloop_free        = sym(lib, "pa_threaded_mainloop_free",        type_of(a.threaded_mainloop_free), &missing)
	a.threaded_mainloop_start       = sym(lib, "pa_threaded_mainloop_start",       type_of(a.threaded_mainloop_start), &missing)
	a.threaded_mainloop_stop        = sym(lib, "pa_threaded_mainloop_stop",        type_of(a.threaded_mainloop_stop), &missing)
	a.threaded_mainloop_lock        = sym(lib, "pa_threaded_mainloop_lock",        type_of(a.threaded_mainloop_lock), &missing)
	a.threaded_mainloop_unlock      = sym(lib, "pa_threaded_mainloop_unlock",      type_of(a.threaded_mainloop_unlock), &missing)
	a.threaded_mainloop_get_api     = sym(lib, "pa_threaded_mainloop_get_api",     type_of(a.threaded_mainloop_get_api), &missing)
	a.threaded_mainloop_set_name    = sym(lib, "pa_threaded_mainloop_set_name",    type_of(a.threaded_mainloop_set_name), &missing)
	a.context_new                   = sym(lib, "pa_context_new",                   type_of(a.context_new), &missing)
	a.context_unref                 = sym(lib, "pa_context_unref",                 type_of(a.context_unref), &missing)
	a.context_set_state_callback    = sym(lib, "pa_context_set_state_callback",    type_of(a.context_set_state_callback), &missing)
	a.context_connect               = sym(lib, "pa_context_connect",               type_of(a.context_connect), &missing)
	a.context_disconnect            = sym(lib, "pa_context_disconnect",            type_of(a.context_disconnect), &missing)
	a.context_get_state             = sym(lib, "pa_context_get_state",             type_of(a.context_get_state), &missing)
	a.context_errno                 = sym(lib, "pa_context_errno",                 type_of(a.context_errno), &missing)
	a.stream_new                    = sym(lib, "pa_stream_new",                    type_of(a.stream_new), &missing)
	a.stream_unref                  = sym(lib, "pa_stream_unref",                  type_of(a.stream_unref), &missing)
	a.stream_get_state              = sym(lib, "pa_stream_get_state",              type_of(a.stream_get_state), &missing)
	a.stream_set_state_callback     = sym(lib, "pa_stream_set_state_callback",     type_of(a.stream_set_state_callback), &missing)
	a.stream_set_read_callback      = sym(lib, "pa_stream_set_read_callback",      type_of(a.stream_set_read_callback), &missing)
	a.stream_set_write_callback     = sym(lib, "pa_stream_set_write_callback",     type_of(a.stream_set_write_callback), &missing)
	a.stream_set_underflow_callback = sym(lib, "pa_stream_set_underflow_callback", type_of(a.stream_set_underflow_callback), &missing)
	a.stream_connect_record         = sym(lib, "pa_stream_connect_record",         type_of(a.stream_connect_record), &missing)
	a.stream_connect_playback       = sym(lib, "pa_stream_connect_playback",       type_of(a.stream_connect_playback), &missing)
	a.stream_disconnect             = sym(lib, "pa_stream_disconnect",             type_of(a.stream_disconnect), &missing)
	a.stream_peek                   = sym(lib, "pa_stream_peek",                   type_of(a.stream_peek), &missing)
	a.stream_drop                   = sym(lib, "pa_stream_drop",                   type_of(a.stream_drop), &missing)
	a.stream_write                  = sym(lib, "pa_stream_write",                  type_of(a.stream_write), &missing)
	a.stream_writable_size          = sym(lib, "pa_stream_writable_size",          type_of(a.stream_writable_size), &missing)
	a.stream_get_latency            = sym(lib, "pa_stream_get_latency",            type_of(a.stream_get_latency), &missing)
	a.stream_get_time               = sym(lib, "pa_stream_get_time",               type_of(a.stream_get_time), &missing)
	a.stream_flush                  = sym(lib, "pa_stream_flush",                  type_of(a.stream_flush), &missing)
	a.stream_get_sample_spec        = sym(lib, "pa_stream_get_sample_spec",        type_of(a.stream_get_sample_spec), &missing)
	a.operation_unref               = sym(lib, "pa_operation_unref",               type_of(a.operation_unref), &missing)
	a.strerror                      = sym(lib, "pa_strerror",                      type_of(a.strerror), &missing)

	if missing {
		dynlib.unload_library(lib)
		pulse_lib = nil
		return &pulse_api, false
	}
	pulse_ok = true
	return &pulse_api, true
}

// pulse_error maps a PulseAudio errno onto an `Error`. The ones worth
// telling apart are "nothing is running", "there is no such device" and
// "you may not have the microphone"; the rest are `.Failed`.
@(private)
pulse_error :: proc(errno: i32) -> Error {
	switch errno {
	case PA_ERR_ACCESS:                                     return .Permission
	case PA_ERR_CONNECTIONREFUSED, PA_ERR_INVALIDSERVER:    return .No_Server
	case PA_ERR_NOENTITY:                                   return .No_Device
	case PA_ERR_CONNECTIONTERMINATED, PA_ERR_KILLED:        return .Closed
	case PA_ERR_NOTSUPPORTED, PA_ERR_INVALID:               return .Bad_Format
	}
	return .Failed
}
