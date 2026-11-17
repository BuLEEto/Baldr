#+build linux
// The Linux backend: one PulseAudio threaded mainloop per stream, with the
// samples crossing between its thread and the app's through a `Ring`.
//
// Lock discipline:
//   - PulseAudio's callbacks run on the mainloop's thread with its lock
//     held. They touch the ring and the two atomic counters, and nothing
//     else.
//   - Any `pa_*` call from the app's thread must be inside
//     lock/unlock. `capture_read` makes none, so it takes no lock at all;
//     `playback_write`, `playback_queued` and `playback_flush` each take
//     it briefly.
package audio

import "base:runtime"
import "core:c"
import "core:strings"
import "core:time"

// How long to wait for the sound server to answer. A local socket answers
// in milliseconds; this bounds a server that accepted the connection and
// then stopped talking.
@(private = "file")
CONNECT_TIMEOUT :: 2 * time.Second

// How finely the open loop polls. Not `pa_threaded_mainloop_wait`: it has
// no timeout, and nothing wakes it if the server never changes state again.
@(private = "file")
POLL_STEP :: 2 * time.Millisecond

@(private = "file")
Pulse_Stream :: struct {
	api:     ^Pulse_Api,
	loop:    rawptr, // pa_threaded_mainloop
	ctx:     rawptr, // pa_context
	stream:  rawptr, // pa_stream
	cap:     ^Capture,  // set for a record stream
	play:    ^Playback, // set for a playback stream
	gap:     bool,      // playback: the server ran dry and nothing has followed yet
	written: u64,       // playback: samples handed to pa_stream_write, ever (mainloop lock)
	scratch: [4096]f32, // playback: ring → here → pa_stream_write
	silence: [1024]f32, // capture: zeros, for a hole the server skipped
}

@(private = "file")
spec_of :: proc(f: Format) -> Pa_Sample_Spec {
	return {format = PA_SAMPLE_F32, rate = u32(f.rate), channels = u8(f.channels)}
}

// pulse_connect brings up a mainloop and a context and waits for the
// server. On any failure it tears down what it made and returns why.
@(private = "file")
pulse_connect :: proc(ps: ^Pulse_Stream) -> Error {
	a := ps.api
	ps.loop = a.threaded_mainloop_new()
	if ps.loop == nil do return .Failed
	a.threaded_mainloop_set_name(ps.loop, "baldr-audio")
	if a.threaded_mainloop_start(ps.loop) < 0 {
		a.threaded_mainloop_free(ps.loop)
		ps.loop = nil
		return .Failed
	}

	a.threaded_mainloop_lock(ps.loop)
	ps.ctx = a.context_new(a.threaded_mainloop_get_api(ps.loop), "Baldr")
	if ps.ctx == nil {
		a.threaded_mainloop_unlock(ps.loop)
		return .Failed
	}
	a.context_set_state_callback(ps.ctx, on_context_state, ps)
	if a.context_connect(ps.ctx, nil, 0, nil) < 0 {
		err := pulse_error(a.context_errno(ps.ctx))
		a.threaded_mainloop_unlock(ps.loop)
		return .No_Server if err == .Failed else err
	}

	deadline := time.time_add(time.now(), CONNECT_TIMEOUT)
	for {
		switch a.context_get_state(ps.ctx) {
		case .Ready:
			a.threaded_mainloop_unlock(ps.loop)
			return .None
		case .Failed, .Terminated:
			err := pulse_error(a.context_errno(ps.ctx))
			a.threaded_mainloop_unlock(ps.loop)
			return err
		case .Unconnected, .Connecting, .Authorizing, .Setting_Name:
			// still coming up
		}
		if time.since(deadline) >= 0 {
			a.threaded_mainloop_unlock(ps.loop)
			return .No_Server
		}
		a.threaded_mainloop_unlock(ps.loop)
		time.sleep(POLL_STEP)
		a.threaded_mainloop_lock(ps.loop)
	}
}

// pulse_await_stream waits for a connected stream to become READY, with
// the mainloop lock held on entry and on return.
@(private = "file")
pulse_await_stream :: proc(ps: ^Pulse_Stream) -> Error {
	a := ps.api
	deadline := time.time_add(time.now(), CONNECT_TIMEOUT)
	for {
		switch a.stream_get_state(ps.stream) {
		case .Ready:
			return .None
		case .Failed, .Terminated:
			return pulse_error(a.context_errno(ps.ctx))
		case .Unconnected, .Creating:
			// still coming up
		}
		if time.since(deadline) >= 0 do return .No_Server
		a.threaded_mainloop_unlock(ps.loop)
		time.sleep(POLL_STEP)
		a.threaded_mainloop_lock(ps.loop)
	}
}

@(private = "file")
pulse_teardown :: proc(ps: ^Pulse_Stream, allocator := context.allocator) {
	if ps == nil do return
	a := ps.api
	if ps.loop != nil {
		a.threaded_mainloop_lock(ps.loop)
		if ps.stream != nil {
			a.stream_set_read_callback(ps.stream, nil, nil)
			a.stream_set_write_callback(ps.stream, nil, nil)
			a.stream_set_underflow_callback(ps.stream, nil, nil)
			a.stream_set_state_callback(ps.stream, nil, nil)
			a.stream_disconnect(ps.stream)
			a.stream_unref(ps.stream)
			ps.stream = nil
		}
		if ps.ctx != nil {
			a.context_set_state_callback(ps.ctx, nil, nil)
			a.context_disconnect(ps.ctx)
			a.context_unref(ps.ctx)
			ps.ctx = nil
		}
		a.threaded_mainloop_unlock(ps.loop)
		a.threaded_mainloop_stop(ps.loop)
		a.threaded_mainloop_free(ps.loop)
		ps.loop = nil
	}
	free(ps, allocator)
}

// --- callbacks, all on the mainloop's thread ---

@(private = "file")
on_context_state :: proc "c" (ctx: rawptr, user: rawptr) {
	context = runtime.default_context()
	ps := (^Pulse_Stream)(user)
	if ps == nil || ps.api.context_get_state == nil do return
	st := ps.api.context_get_state(ctx)
	if st != .Failed && st != .Terminated do return
	err := pulse_error(ps.api.context_errno(ctx))
	if err == .Failed do err = .Closed // the server went away mid-stream
	if ps.cap != nil do set_state(&ps.cap.state, err)
	if ps.play != nil do set_state(&ps.play.state, err)
}

@(private = "file")
on_stream_state :: proc "c" (s: rawptr, user: rawptr) {
	context = runtime.default_context()
	ps := (^Pulse_Stream)(user)
	if ps == nil do return
	st := ps.api.stream_get_state(s)
	if st != .Failed && st != .Terminated do return
	if ps.cap != nil do set_state(&ps.cap.state, .Closed)
	if ps.play != nil do set_state(&ps.play.state, .Closed)
}

// on_readable moves everything the server has into the ring. It must drain
// what it is offered whether or not the app has been reading, so an
// overrun is counted (`capture_lost`) rather than left to back up.
@(private = "file")
on_readable :: proc "c" (s: rawptr, nbytes: c.size_t, user: rawptr) {
	context = runtime.default_context()
	ps := (^Pulse_Stream)(user)
	if ps == nil || ps.cap == nil do return
	a := ps.api
	for {
		data: rawptr
		n: c.size_t
		if a.stream_peek(s, &data, &n) < 0 do return
		if n == 0 do return // nothing more queued
		if data == nil {
			// A hole: the server dropped `n` bytes. Write that much silence
			// so the recording's length still matches the wall clock.
			left := int(n) / size_of(f32)
			for left > 0 {
				take := min(left, len(ps.silence))
				ring_write_lossy(&ps.cap.ring, ps.silence[:take])
				left -= take
			}
		} else {
			ring_write_lossy(&ps.cap.ring, ([^]f32)(data)[:int(n) / size_of(f32)])
		}
		a.stream_drop(s)
	}
}

// on_writable hands the server as much as it asked for, or as much as the
// ring holds. Writing nothing is normal and correct at the end of a clip.
@(private = "file")
on_writable :: proc "c" (s: rawptr, nbytes: c.size_t, user: rawptr) {
	context = runtime.default_context()
	ps := (^Pulse_Stream)(user)
	if ps == nil || ps.play == nil do return
	pulse_push(ps, int(nbytes) / size_of(f32))
}

// on_underflow notes that the server ran dry, without counting it: every
// clip ends in one. `pulse_push` counts it once sound follows, so
// `playback_underruns` means "there was a gap in the middle".
@(private = "file")
on_underflow :: proc "c" (s: rawptr, user: rawptr) {
	context = runtime.default_context()
	ps := (^Pulse_Stream)(user)
	if ps == nil do return
	ps.gap = true
}

// pulse_push drains up to `want` samples from the ring into the server.
// Called from the write callback and from `playback_write`; the mainloop
// lock is held either way.
@(private = "file")
pulse_push :: proc(ps: ^Pulse_Stream, want: int) {
	a := ps.api
	left := want
	for left > 0 {
		take := min(left, len(ps.scratch))
		got := ring_read(&ps.play.ring, ps.scratch[:take])
		if got == 0 do break // nothing to give: the clip has ended, or the app is behind
		if ps.gap {
			// Sound is following an underflow, so that underflow was a gap
			// in the middle of something and not the end of it.
			ps.gap = false
			bump_i32(&ps.play.underruns)
		}
		if a.stream_write(ps.stream, raw_data(ps.scratch[:]), c.size_t(got * size_of(f32)), nil, 0, PA_SEEK_RELATIVE) < 0 {
			set_state(&ps.play.state, .Closed)
			return
		}
		ps.written += u64(got)
		left -= got
	}
}

// --- the seam ---

@(private)
backend_capture_open :: proc(c_: ^Capture, latency_ms: int, device: string, allocator := context.allocator) -> Error {
	a, ok := pulse_load()
	if !ok do return .No_Library

	ps := new(Pulse_Stream, allocator)
	if ps == nil do return .Failed
	ps.api, ps.cap = a, c_

	if err := pulse_connect(ps); err != .None {
		pulse_teardown(ps, allocator)
		return err
	}

	a.threaded_mainloop_lock(ps.loop)
	spec := spec_of(c_.format)
	ps.stream = a.stream_new(ps.ctx, "Recording", &spec, nil)
	if ps.stream == nil {
		err := pulse_error(a.context_errno(ps.ctx))
		a.threaded_mainloop_unlock(ps.loop)
		pulse_teardown(ps, allocator)
		return .Bad_Format if err == .Failed else err
	}
	a.stream_set_state_callback(ps.stream, on_stream_state, ps)
	a.stream_set_read_callback(ps.stream, on_readable, ps)

	// `fragsize` is how much the server batches before calling back; with
	// ADJUST_LATENCY it also asks the source to run that short.
	attr := Pa_Buffer_Attr {
		maxlength = PA_UNSPEC,
		tlength   = PA_UNSPEC,
		prebuf    = PA_UNSPEC,
		minreq    = PA_UNSPEC,
		fragsize  = u32(samples_for_ms(c_.format, max(latency_ms, 1)) * size_of(f32)),
	}
	dev_c: cstring
	if device != "" {
		dev_c = strings.clone_to_cstring(device, context.temp_allocator)
	}
	if a.stream_connect_record(ps.stream, dev_c, &attr, PA_STREAM_ADJUST_LATENCY) < 0 {
		err := pulse_error(a.context_errno(ps.ctx))
		a.threaded_mainloop_unlock(ps.loop)
		pulse_teardown(ps, allocator)
		return err
	}
	if err := pulse_await_stream(ps); err != .None {
		a.threaded_mainloop_unlock(ps.loop)
		pulse_teardown(ps, allocator)
		return err
	}
	// Check what was negotiated: a stream given a different format opens
	// without complaint and converts silently, so the mistake would arrive
	// as samples that are not floats.
	if got := a.stream_get_sample_spec(ps.stream); got != nil {
		if got.format != PA_SAMPLE_F32 {
			a.threaded_mainloop_unlock(ps.loop)
			pulse_teardown(ps, allocator)
			return .Bad_Format
		}
		c_.format = {rate = int(got.rate), channels = int(got.channels)}
	}
	a.threaded_mainloop_unlock(ps.loop)

	c_.be = ps
	return .None
}

@(private)
backend_capture_close :: proc(c_: ^Capture, allocator := context.allocator) {
	pulse_teardown((^Pulse_Stream)(c_.be), allocator)
	c_.be = nil
}

@(private)
backend_playback_open :: proc(p: ^Playback, latency_ms: int, device: string, allocator := context.allocator) -> Error {
	a, ok := pulse_load()
	if !ok do return .No_Library

	ps := new(Pulse_Stream, allocator)
	if ps == nil do return .Failed
	ps.api, ps.play = a, p

	if err := pulse_connect(ps); err != .None {
		pulse_teardown(ps, allocator)
		return err
	}

	a.threaded_mainloop_lock(ps.loop)
	spec := spec_of(p.format)
	ps.stream = a.stream_new(ps.ctx, "Playback", &spec, nil)
	if ps.stream == nil {
		err := pulse_error(a.context_errno(ps.ctx))
		a.threaded_mainloop_unlock(ps.loop)
		pulse_teardown(ps, allocator)
		return .Bad_Format if err == .Failed else err
	}
	a.stream_set_state_callback(ps.stream, on_stream_state, ps)
	a.stream_set_write_callback(ps.stream, on_writable, ps)
	a.stream_set_underflow_callback(ps.stream, on_underflow, ps)

	attr := Pa_Buffer_Attr {
		maxlength = PA_UNSPEC,
		tlength   = u32(samples_for_ms(p.format, max(latency_ms, 1)) * size_of(f32)),
		prebuf    = PA_UNSPEC, // = tlength: wait for a bufferful before starting, so a clip does not open with an underrun
		minreq    = PA_UNSPEC,
		fragsize  = PA_UNSPEC,
	}
	dev_c: cstring
	if device != "" {
		dev_c = strings.clone_to_cstring(device, context.temp_allocator)
	}
	// INTERPOLATE_TIMING and AUTO_TIMING_UPDATE are what make
	// `pa_stream_get_latency` answerable without a round trip, and that is
	// what `playback_queued` needs to include the server's own buffer.
	flags := PA_STREAM_ADJUST_LATENCY | PA_STREAM_INTERPOLATE_TIMING | PA_STREAM_AUTO_TIMING_UPDATE
	if a.stream_connect_playback(ps.stream, dev_c, &attr, flags, nil, nil) < 0 {
		err := pulse_error(a.context_errno(ps.ctx))
		a.threaded_mainloop_unlock(ps.loop)
		pulse_teardown(ps, allocator)
		return err
	}
	if err := pulse_await_stream(ps); err != .None {
		a.threaded_mainloop_unlock(ps.loop)
		pulse_teardown(ps, allocator)
		return err
	}
	if got := a.stream_get_sample_spec(ps.stream); got != nil {
		if got.format != PA_SAMPLE_F32 { // see the note in backend_capture_open
			a.threaded_mainloop_unlock(ps.loop)
			pulse_teardown(ps, allocator)
			return .Bad_Format
		}
		p.format = {rate = int(got.rate), channels = int(got.channels)}
	}
	a.threaded_mainloop_unlock(ps.loop)

	p.be = ps
	return .None
}

@(private)
backend_playback_close :: proc(p: ^Playback, allocator := context.allocator) {
	pulse_teardown((^Pulse_Stream)(p.be), allocator)
	p.be = nil
}

// backend_playback_nudge pushes straight away rather than waiting for the
// server to ask: once it has asked and been given nothing (every clip's
// end), nothing guarantees another request, and the next clip would sit in
// the ring. The lock is held for a memcpy.
@(private)
backend_playback_nudge :: proc(p: ^Playback) {
	ps := (^Pulse_Stream)(p.be)
	if ps == nil || ps.stream == nil do return
	a := ps.api
	a.threaded_mainloop_lock(ps.loop)
	if can := int(a.stream_writable_size(ps.stream)) / size_of(f32); can > 0 {
		pulse_push(ps, can)
	}
	a.threaded_mainloop_unlock(ps.loop)
}

@(private)
backend_playback_flush :: proc(p: ^Playback) {
	ps := (^Pulse_Stream)(p.be)
	if ps == nil || ps.stream == nil do return
	a := ps.api
	a.threaded_mainloop_lock(ps.loop)
	if op := a.stream_flush(ps.stream, nil, nil); op != nil do a.operation_unref(op)
	ps.gap = false // a flush is not a gap in anything
	// What was thrown away must stop counting as "still to be heard", or
	// `playback_queued` would never come down again after a stop.
	if played, ok := pulse_played(ps, p.format); ok {
		ps.written = played
	} else {
		ps.written = 0
	}
	a.threaded_mainloop_unlock(ps.loop)
}

// pulse_played is how much of what was written has been heard, from the
// stream's own playback clock. The mainloop lock must be held.
@(private = "file")
pulse_played :: proc(ps: ^Pulse_Stream, f: Format) -> (samples: u64, ok: bool) {
	usec: u64
	if ps.api.stream_get_time(ps.stream, &usec) < 0 do return 0, false
	return usec * u64(f.rate * f.channels) / 1_000_000, true
}

// backend_playback_server_queued is how much the server still holds, in
// samples: everything handed to `pa_stream_write` that the stream's own
// clock says has not been heard yet.
//
// Not `pa_stream_get_latency`: it includes the sink's latency, so it never
// reaches zero while the stream is open and `playback_drained` would stay
// false. Written-minus-played is exact and does reach zero.
@(private)
backend_playback_server_queued :: proc(p: ^Playback) -> int {
	ps := (^Pulse_Stream)(p.be)
	if ps == nil || ps.stream == nil do return 0
	a := ps.api
	a.threaded_mainloop_lock(ps.loop)
	defer a.threaded_mainloop_unlock(ps.loop)
	// The stream's clock stops when the server runs dry, short of the
	// written total, at the end of every clip. An underflow with nothing
	// written since means the server has handed on everything it was given.
	if ps.gap do return 0
	played, ok := pulse_played(ps, p.format)
	if !ok do return int(ps.written) // no clock yet: nothing can have been heard
	if played >= ps.written do return 0
	return int(ps.written - played)
}

// --- probes ---

// probe_clock_ok, probe_written and probe_played expose the two numbers
// `playback_queued` is the difference of, and whether the server's clock is
// answering at all: for a spike or a bug report, not for an app, which has
// `playback_queued` and `playback_drained`. `spikes/audio_check` prints them.
probe_clock_ok :: proc(p: ^Playback) -> bool {
	ps := (^Pulse_Stream)(p.be)
	if ps == nil || ps.stream == nil do return false
	ps.api.threaded_mainloop_lock(ps.loop)
	defer ps.api.threaded_mainloop_unlock(ps.loop)
	_, ok := pulse_played(ps, p.format)
	return ok
}

probe_written :: proc(p: ^Playback) -> int {
	ps := (^Pulse_Stream)(p.be)
	if ps == nil do return 0
	ps.api.threaded_mainloop_lock(ps.loop)
	defer ps.api.threaded_mainloop_unlock(ps.loop)
	return int(ps.written)
}

probe_played :: proc(p: ^Playback) -> int {
	ps := (^Pulse_Stream)(p.be)
	if ps == nil || ps.stream == nil do return 0
	ps.api.threaded_mainloop_lock(ps.loop)
	defer ps.api.threaded_mainloop_unlock(ps.loop)
	n, _ := pulse_played(ps, p.format)
	return int(n)
}

probe_last_status :: proc() -> (call: string, status: int) {
	return "", 0 // PulseAudio's failures are already named by `Error`
}
