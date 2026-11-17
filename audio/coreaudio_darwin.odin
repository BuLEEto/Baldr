#+build darwin
// The macOS backend: one AudioQueue per stream (AudioToolbox), with the
// samples crossing between the queue's own thread and the app's through a
// `Ring`.
//
// AudioQueue rather than AUHAL: an AudioUnit render callback has lower
// latency, but AudioQueue converts to the device's real rate and channel
// count itself, so `capture_open(48 kHz mono)` works on a 44.1 kHz stereo
// interface without a resampler here. With a nil run loop it runs its own
// thread, which is the one thread the seam allows a backend.
//
// Thread discipline:
//   - The queue's callbacks run on a thread CoreAudio owns. They touch the
//     ring, the two atomic counters and `held`, and nothing else.
//   - The app's thread calls AudioQueue* only from open, close, nudge and
//     flush. Those are safe to call while callbacks run; none of them
//     wait on one.
package audio

import "base:runtime"
import "core:sync"

// How many buffers go round the queue. Three is the usual answer: one
// playing, one queued behind it, one being filled. Two leaves no slack for
// a late callback; four costs latency for nothing.
@(private = "file")
CA_BUFFERS :: 3

// The smallest buffer worth asking for. CoreAudio will take less and then
// wake the callback absurdly often for a stream nobody is listening hard
// to; 256 frames is about 5 ms at 48 kHz.
@(private = "file")
CA_MIN_FRAMES :: 256

@(private = "file")
Ca_Stream :: struct {
	queue:    Audio_Queue_Ref,
	bufs:     [CA_BUFFERS]Audio_Queue_Buffer_Ref,
	held:     [CA_BUFFERS]i32, // playback: real samples in each buffer, not yet heard
	cap:      ^Capture,        // set for a record queue
	play:     ^Playback,       // set for a playback queue
	pending:  i32,             // atomic: real samples the queue still holds
	gap:      bool,            // playback: it ran dry and nothing has followed yet
	had_sound: bool,           // playback: something real has been played, so a dry buffer is now a gap
	started:  bool,            // playback: the queue is running
	samples:  int,             // samples (not frames) one buffer holds
	channels: int,
}

@(private = "file")
asbd_of :: proc(f: Format) -> Audio_Stream_Basic_Description {
	bytes_per_frame := u32(f.channels * size_of(f32))
	return {
		sample_rate        = f64(f.rate),
		format_id          = K_AUDIO_FORMAT_LINEAR_PCM,
		// Native-endian packed float: exactly what the ring reads the bytes as.
		format_flags       = K_FLAG_IS_FLOAT | K_FLAG_IS_PACKED,
		bytes_per_packet   = bytes_per_frame,
		frames_per_packet  = 1,
		bytes_per_frame    = bytes_per_frame,
		channels_per_frame = u32(f.channels),
		bits_per_channel   = 32,
	}
}

// ca_error turns an OSStatus into the error an app can show. Anything not
// named here is `.Failed`, which is honest: a code this does not know is
// not a code it can describe.
@(private = "file")
ca_error :: proc(st: OS_Status) -> Error {
	switch st {
	case 0:                             return .None
	case K_AQ_ERR_PERMISSIONS:          return .Permission
	case K_AQ_ERR_INVALID_DEVICE:       return .No_Device
	case K_AQ_ERR_CANNOT_START:         return .No_Device
	case K_AUDIO_FORMAT_UNSUPPORTED:    return .Bad_Format
	case K_AQ_ERR_INVALID_QUEUE_TYPE:   return .Bad_Format
	case K_AUDIO_ERR_PARAM:             return .Bad_Format
	case K_AQ_ERR_QUEUE_INVALIDATED:    return .Closed
	case K_AQ_ERR_DISPOSAL_PENDING:     return .Closed
	}
	return .Failed
}

// ca_stopping says whether a refused enqueue only means the queue is being
// reset, stopped or disposed of — which the callback must not latch as the
// stream having failed, because the app asked for it.
@(private = "file")
ca_stopping :: proc "contextless" (st: OS_Status) -> bool {
	return st == K_AQ_ERR_ENQUEUE_DURING_RESET ||
		st == K_AQ_ERR_DISPOSAL_PENDING ||
		st == K_AQ_ERR_INVALID_RUN_STATE
}

// ca_index is which of our buffers this is. The queue hands the callback a
// pointer we allocated, so it is always one of them; -1 would mean the
// queue invented one, which it does not.
@(private = "file")
ca_index :: proc "contextless" (cs: ^Ca_Stream, buf: Audio_Queue_Buffer_Ref) -> int {
	for b, i in cs.bufs do if b == buf do return i
	return -1
}

// ca_set_device points the queue at a named output or input. `device` is
// CoreAudio's own UID for it (what `kAudioDevicePropertyDeviceUID`
// reports); empty means the default, which is what the person chose in
// Sound settings.
@(private = "file")
ca_set_device :: proc(q: Audio_Queue_Ref, device: string) -> Error {
	if device == "" do return .None
	uid := CFStringCreateWithBytes(nil, raw_data(device), len(device), K_CF_STRING_ENCODING_UTF8, false)
	if uid == nil do return .No_Device
	defer CFRelease(uid)
	st := AudioQueueSetProperty(q, K_AUDIO_QUEUE_PROPERTY_CURRENT_DEVICE, &uid, size_of(CF_String_Ref))
	if st != 0 do return .No_Device
	return .None
}

// --- the callbacks, on CoreAudio's thread ---

// ca_output fills a buffer that has just finished playing.
//
// A short buffer rather than a padded one: `audio_data_byte_size` is what
// the ring gave, so `pending` is the real number of samples still to be
// heard, which `playback_drained` turns on. Only an empty buffer is sent
// full of silence, to keep the queue running for the next write.
@(private = "file")
ca_output :: proc "c" (user: rawptr, aq: Audio_Queue_Ref, buf: Audio_Queue_Buffer_Ref) {
	context = runtime.default_context()
	cs := (^Ca_Stream)(user)
	if cs == nil || cs.play == nil || buf == nil do return

	// whatever this buffer held has now been heard
	if i := ca_index(cs, buf); i >= 0 && cs.held[i] != 0 {
		sync.atomic_sub_explicit(&cs.pending, cs.held[i], .Relaxed)
		cs.held[i] = 0
	}

	dst := ([^]f32)(buf.audio_data)[:cs.samples]
	got := ring_read(&cs.play.ring, dst)
	if got > 0 {
		if cs.gap {
			// Sound after a dry buffer makes that buffer a gap, not an end:
			// `playback_underruns` means "it stuttered", not "it finished".
			cs.gap = false
			bump_i32(&cs.play.underruns)
		}
		cs.had_sound = true
	}
	// The silence a queue runs on before the app's first write is not a
	// gap in anything: a clip written in one go must report no underruns.
	if got < cs.samples && cs.had_sound do cs.gap = true

	if got > 0 {
		buf.audio_data_byte_size = u32(got * size_of(f32))
		if i := ca_index(cs, buf); i >= 0 do cs.held[i] = i32(got)
		sync.atomic_add_explicit(&cs.pending, i32(got), .Relaxed)
	} else {
		for i in 0 ..< cs.samples do dst[i] = 0
		buf.audio_data_byte_size = u32(cs.samples * size_of(f32))
	}
	if st := AudioQueueEnqueueBuffer(aq, buf, 0, nil); st != 0 && !ca_stopping(st) {
		set_state(&cs.play.state, ca_error(st))
	}
}

// ca_input takes a recorded buffer and gives it straight back.
@(private = "file")
ca_input :: proc "c" (user: rawptr, aq: Audio_Queue_Ref, buf: Audio_Queue_Buffer_Ref,
	start: ^Audio_Time_Stamp, n_packets: u32, descs: rawptr) {
	context = runtime.default_context()
	cs := (^Ca_Stream)(user)
	if cs == nil || cs.cap == nil || buf == nil do return
	if n := int(buf.audio_data_byte_size) / size_of(f32); n > 0 {
		// Lossy on purpose: a capture callback must return whether or not
		// the app has been reading, and `capture_lost` is how a recording
		// says it has a hole in it.
		ring_write_lossy(&cs.cap.ring, ([^]f32)(buf.audio_data)[:n])
	}
	if st := AudioQueueEnqueueBuffer(aq, buf, 0, nil); st != 0 && !ca_stopping(st) {
		set_state(&cs.cap.state, ca_error(st))
	}
}

// --- open and close ---

// ca_buffer_samples is one buffer's worth, from the latency asked for
// split across the buffers in the ring of them.
@(private = "file")
ca_buffer_samples :: proc(f: Format, latency_ms: int) -> int {
	frames := f.rate * max(latency_ms, 1) / 1000 / CA_BUFFERS
	return max(frames, CA_MIN_FRAMES) * f.channels
}

@(private = "file")
ca_allocate :: proc(cs: ^Ca_Stream) -> Error {
	bytes := u32(cs.samples * size_of(f32))
	for i in 0 ..< CA_BUFFERS {
		if st := ca_note("AudioQueueAllocateBuffer", AudioQueueAllocateBuffer(cs.queue, bytes, &cs.bufs[i])); st != 0 {
			return ca_error(st)
		}
	}
	return .None
}

@(private = "file")
ca_teardown :: proc(cs: ^Ca_Stream) {
	if cs.queue != nil {
		// Immediate: stop now and do not wait for what is queued to play.
		// `playback_close` already says it discards anything still queued.
		AudioQueueStop(cs.queue, true)
		for b in cs.bufs do if b != nil do AudioQueueFreeBuffer(cs.queue, b)
		AudioQueueDispose(cs.queue, true)
		cs.queue = nil
	}
	cs.bufs = {}
}

// ca_prime fills every buffer with silence, enqueues them and starts the
// queue turning. Used to open a playback stream and to pick it up again
// after a flush has stopped it.
@(private = "file")
ca_prime :: proc(cs: ^Ca_Stream) -> Error {
	for b in cs.bufs {
		if b == nil do return .Failed
		dst := ([^]f32)(b.audio_data)[:cs.samples]
		for i in 0 ..< cs.samples do dst[i] = 0
		b.audio_data_byte_size = u32(cs.samples * size_of(f32))
		if st := AudioQueueEnqueueBuffer(cs.queue, b, 0, nil); st != 0 do return ca_error(st)
	}
	if st := ca_note("AudioQueueStart", AudioQueueStart(cs.queue, nil)); st != 0 do return ca_error(st)
	cs.started = true
	return .None
}

// --- the seam ---

@(private)
backend_capture_open :: proc(c_: ^Capture, latency_ms: int, device: string, allocator := context.allocator) -> Error {
	cs := new(Ca_Stream, allocator)
	if cs == nil do return .Failed
	cs.cap = c_
	cs.samples = ca_buffer_samples(c_.format, latency_ms)
	cs.channels = c_.format.channels

	desc := asbd_of(c_.format)
	if st := ca_note("AudioQueueNewInput", AudioQueueNewInput(&desc, ca_input, cs, nil, nil, 0, &cs.queue)); st != 0 {
		free(cs, allocator)
		return ca_error(st)
	}
	if err := ca_set_device(cs.queue, device); err != .None {
		ca_teardown(cs)
		free(cs, allocator)
		return err
	}
	if err := ca_allocate(cs); err != .None {
		ca_teardown(cs)
		free(cs, allocator)
		return err
	}
	for b in cs.bufs {
		if st := AudioQueueEnqueueBuffer(cs.queue, b, 0, nil); st != 0 {
			ca_teardown(cs)
			free(cs, allocator)
			return ca_error(st)
		}
	}
	// macOS refuses the microphone (TCC) at this call, so the error is
	// reported here rather than becoming a recording of silence.
	if st := ca_note("AudioQueueStart(input)", AudioQueueStart(cs.queue, nil)); st != 0 {
		err := ca_error(st)
		ca_teardown(cs)
		free(cs, allocator)
		return err
	}
	c_.be = cs
	return .None
}

@(private)
backend_capture_close :: proc(c_: ^Capture, allocator := context.allocator) {
	cs := (^Ca_Stream)(c_.be)
	if cs == nil do return
	ca_teardown(cs)
	c_.be = nil
	free(cs, allocator)
}

@(private)
backend_playback_open :: proc(p: ^Playback, latency_ms: int, device: string, allocator := context.allocator) -> Error {
	cs := new(Ca_Stream, allocator)
	if cs == nil do return .Failed
	cs.play = p
	cs.samples = ca_buffer_samples(p.format, latency_ms)
	cs.channels = p.format.channels

	desc := asbd_of(p.format)
	if st := ca_note("AudioQueueNewOutput", AudioQueueNewOutput(&desc, ca_output, cs, nil, nil, 0, &cs.queue)); st != 0 {
		free(cs, allocator)
		return ca_error(st)
	}
	if err := ca_set_device(cs.queue, device); err != .None {
		ca_teardown(cs)
		free(cs, allocator)
		return err
	}
	if err := ca_allocate(cs); err != .None {
		ca_teardown(cs)
		free(cs, allocator)
		return err
	}
	// Started here, on silence: starting costs the device's spin-up (tens
	// of ms), and `playback_open` may block where `playback_write` must not.
	// The callback picks the app's samples up within one buffer of a write;
	// `had_sound` keeps the leading silence from counting as an underrun.
	if err := ca_prime(cs); err != .None {
		ca_teardown(cs)
		free(cs, allocator)
		return err
	}
	p.be = cs
	return .None
}

@(private)
backend_playback_close :: proc(p: ^Playback, allocator := context.allocator) {
	cs := (^Ca_Stream)(p.be)
	if cs == nil do return
	ca_teardown(cs)
	p.be = nil
	free(cs, allocator)
}

// backend_playback_nudge has nothing to do: the queue is already running
// and asks for samples whether or not it has been given any.
@(private)
backend_playback_nudge :: proc(p: ^Playback) {}

// backend_playback_flush drops what the queue still holds and sets it
// turning again.
//
// Not `AudioQueueReset`: it hands every buffer to the callback, whose
// enqueue is then refused with `kAudioQueueErr_EnqueueDuringReset`, and the
// queue starves for ever. An immediate stop is synchronous (no callback in
// flight when it returns), so the buffers are ours to refill and enqueue.
@(private)
backend_playback_flush :: proc(p: ^Playback) {
	cs := (^Ca_Stream)(p.be)
	if cs == nil || cs.queue == nil do return
	cs.started = false
	AudioQueueStop(cs.queue, true)
	cs.held = {}
	sync.atomic_store_explicit(&cs.pending, 0, .Relaxed)
	cs.gap, cs.had_sound = false, false
	if err := ca_prime(cs); err != .None do set_state(&p.state, err)
}

// backend_playback_server_queued is the real samples the queue holds: what
// each buffer was given, less what has been played, counted by the
// callback as each buffer comes back. No clock is involved, so none can
// stop at an underflow.
@(private)
backend_playback_server_queued :: proc(p: ^Playback) -> int {
	cs := (^Ca_Stream)(p.be)
	if cs == nil do return 0
	return int(max(sync.atomic_load_explicit(&cs.pending, .Relaxed), 0))
}

// --- probes ---

// ca_last is the last CoreAudio call that refused, for `spikes/ca_probe`:
// `.No_Device` is also what a wrong binding would give, so the raw status
// and its call are worth reading.
@(private = "file")
ca_last: struct { call: string, status: OS_Status }

@(private = "file")
ca_note :: proc(call: string, st: OS_Status) -> OS_Status {
	if st != 0 do ca_last = {call, st}
	return st
}

probe_last_status :: proc() -> (call: string, status: int) {
	return ca_last.call, int(ca_last.status)
}



// probe_clock_ok, probe_written and probe_played are for `spikes/audio_check`
// and for a bug report, not for an app. There is no server clock here, so
// "ok" means the queue is running and the two numbers are derived from the
// buffer accounting rather than from a timestamp.
probe_clock_ok :: proc(p: ^Playback) -> bool {
	cs := (^Ca_Stream)(p.be)
	return cs != nil && cs.queue != nil && cs.started
}

probe_written :: proc(p: ^Playback) -> int {
	cs := (^Ca_Stream)(p.be)
	if cs == nil do return 0
	return int(sync.atomic_load_explicit(&cs.pending, .Relaxed))
}

probe_played :: proc(p: ^Playback) -> int {
	return 0 // the queue reports what it still holds, not what it has played
}
