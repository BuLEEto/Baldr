// Package audio is PCM in and PCM out, and nothing else: open the
// microphone, read f32 samples, open the speakers, write f32 samples.
//
// It is a sibling of Baldr, not part of it (`import "baldr:audio"`): an
// app that never makes a noise should not pay for a sound server
// connection. Nothing here imports `baldr`, and nothing in `baldr` imports
// this.
//
// There are no codecs. Opus, MP3, WAV headers, resampling and mixing belong
// to the app, which already links whatever it decodes with; the seam is raw
// interleaved f32.
//
// The shape of a recording:
//
//	c: audio.Capture
//	if err := audio.capture_open(&c); err != .None {
//		show(audio.error_text(err))   // a real error, for a real dialog
//		return
//	}
//	defer audio.capture_close(&c)
//	for recording {                   // once per frame is often enough
//		n, err := audio.capture_read(&c, buf[:])
//		if err != .None do break      // the server went away
//		append(&note, ..buf[:n])
//	}
//
// and of playing one back:
//
//	p: audio.Playback
//	audio.playback_open(&p)
//	audio.playback_write(&p, note[:])        // short writes are normal
//	for !audio.playback_drained(&p) { … }    // poll from the UI loop
//	audio.playback_close(&p)
//
// Neither read nor write blocks or takes a lock: the sound server's thread
// and the UI thread meet at a lock-free ring (ring.odin), so a slow frame
// cannot glitch a recording and a busy sound card cannot stall a frame.
// Only `capture_open` and `playback_open` block, briefly, while the server
// answers.
//
// Backends: PulseAudio on Linux, loaded at runtime via `core:dynlib`,
// which is also how a PipeWire desktop is reached (every one of them runs
// `pipewire-pulse`); CoreAudio's AudioQueue on macOS; WASAPI in shared
// mode on Windows. Each converts to the device's own rate and channel
// count, so there is no resampler here.
package audio

// Error is what went wrong, as a value. `error_text` turns it into
// something a dialog can show.
Error :: enum i32 {
	None = 0,
	Unsupported, // this platform has no audio backend yet
	No_Library,  // the sound server's client library is not installed
	No_Server,   // the library is there, but no sound server answered
	No_Device,   // the server has no microphone (or no speakers)
	Permission,  // the server or the portal refused the microphone
	Bad_Format,  // that sample rate or channel count was refused
	Closed,      // used after closing, or the server dropped the stream
	Failed,      // anything else
}

// error_text is one short sentence, suitable for showing a person.
error_text :: proc(err: Error) -> string {
	switch err {
	case .None:        return "no error"
	case .Unsupported: return "this system has no audio support yet"
	case .No_Library:  return "the audio library is not installed"
	case .No_Server:   return "no sound server is running"
	case .No_Device:   return "no audio device"
	case .Permission:  return "permission to use the microphone was refused"
	case .Bad_Format:  return "that sample rate or channel count is not supported"
	case .Closed:      return "the audio stream was closed"
	case .Failed:      return "the audio stream failed"
	}
	return "the audio stream failed"
}

// Format is a stream's sample rate and channel count. Samples are f32 in
// [-1, 1], interleaved when there is more than one channel.
//
// 48 kHz mono is the default because it is what a voice recording wants
// and what every sound server runs natively, so nothing resamples.
Format :: struct {
	rate:     int, // frames per second, e.g. 48000
	channels: int, // 1 mono, 2 stereo
}

DEFAULT_FORMAT :: Format{48_000, 1}

// samples_for_ms is how many samples of this format fill a duration, for
// sizing a read buffer. Counts everywhere in this package are samples, not
// frames: `len(buf)` of an interleaved `[]f32`.
samples_for_ms :: proc(f: Format, ms: int) -> int {
	return f.rate * f.channels * ms / 1000
}

// ms_for_samples is the inverse, rounded down.
ms_for_samples :: proc(f: Format, samples: int) -> int {
	per := f.rate * f.channels
	if per <= 0 do return 0
	return samples * 1000 / per
}

// Capture is a microphone being recorded. Open it, read from it every
// frame, close it. One at a time per process.
//
// `format` is what the server actually gave, which is what was asked for
// unless it refused — read it back before trusting the rate.
Capture :: struct {
	format: Format,
	ring:   Ring,
	be:     rawptr, // backend state, platform's own
	state:  i32,    // atomic Error: .None while running
	open:   bool,
}

// Playback is a stream being written to the speakers.
Playback :: struct {
	format:    Format,
	ring:      Ring,
	be:        rawptr,
	state:     i32, // atomic Error
	open:      bool,
	underruns: i32, // atomic: times the ring ran dry mid-stream
}

// capture_open starts recording from the default input.
//
// `latency_ms` is how much the server may buffer before handing samples
// over: smaller is more responsive and costs more wake-ups; 20 ms suits a
// live level meter. `buffer_ms` is how much this package holds for an app
// that does not read for a while; two seconds means only a severe stall
// shows in `capture_lost`. `device` is a backend's own input name (this
// package offers no list of them); empty is the desktop's default.
//
// It blocks while the server answers, giving up after two seconds with
// `.No_Server`. Everything after it is non-blocking.
capture_open :: proc(
	c: ^Capture,
	format := DEFAULT_FORMAT,
	latency_ms := 20,
	buffer_ms := 2000,
	device := "",
	allocator := context.allocator,
) -> Error {
	if c.open do return .Failed
	if format.rate < 4000 || format.rate > 384_000 do return .Bad_Format
	if format.channels < 1 || format.channels > 8 do return .Bad_Format
	c^ = {format = format}
	if !ring_init(&c.ring, max(samples_for_ms(format, buffer_ms), 1024), allocator) {
		return .Failed
	}
	err := backend_capture_open(c, latency_ms, device, allocator)
	if err != .None {
		ring_destroy(&c.ring, allocator)
		c^ = {}
		return err
	}
	c.open = true
	return .None
}

// capture_read takes up to `len(dst)` recorded samples and returns how many
// it got; 0, when nothing new has arrived, is a normal answer. It never
// blocks. A non-`.None` error means the stream is finished (the server went
// away, the device was unplugged); the samples returned with it are still
// good. Close it and tell the person.
capture_read :: proc(c: ^Capture, dst: []f32) -> (n: int, err: Error) {
	if !c.open do return 0, .Closed
	n = ring_read(&c.ring, dst)
	return n, state_of(&c.state)
}

// capture_available is how many samples are waiting, for an app that
// would rather size its own buffer than call with a fixed one.
capture_available :: proc(c: ^Capture) -> int {
	if !c.open do return 0
	return ring_available(&c.ring)
}

// capture_lost is the running total of samples dropped because nobody
// read them in time, plus any the server itself skipped. It only grows;
// keep the last value to notice a new gap. A recording with a non-zero
// total has a hole in it and is shorter than the wall clock.
capture_lost :: proc(c: ^Capture) -> int {
	if !c.open do return 0
	return ring_lost(&c.ring)
}

// capture_close stops recording and frees everything. Safe on a `Capture`
// that never opened, and on one already closed.
capture_close :: proc(c: ^Capture, allocator := context.allocator) {
	if !c.open {
		c^ = {}
		return
	}
	backend_capture_close(c, allocator)
	ring_destroy(&c.ring, allocator)
	c^ = {}
}

// playback_open opens the default output.
//
// `latency_ms` is the server-side buffer: 60 ms is safe on a desktop that
// is also compositing. `buffer_ms` is how much this package holds on top;
// raise it past the longest clip written in one go, or write in chunks and
// watch the short return. Like `capture_open` it blocks while the server
// answers, and nothing after it does.
playback_open :: proc(
	p: ^Playback,
	format := DEFAULT_FORMAT,
	latency_ms := 60,
	buffer_ms := 2000,
	device := "",
	allocator := context.allocator,
) -> Error {
	if p.open do return .Failed
	if format.rate < 4000 || format.rate > 384_000 do return .Bad_Format
	if format.channels < 1 || format.channels > 8 do return .Bad_Format
	p^ = {format = format}
	if !ring_init(&p.ring, max(samples_for_ms(format, buffer_ms), 1024), allocator) {
		return .Failed
	}
	err := backend_playback_open(p, latency_ms, device, allocator)
	if err != .None {
		ring_destroy(&p.ring, allocator)
		p^ = {}
		return err
	}
	p.open = true
	return .None
}

// playback_write queues samples to be heard and returns how many it took.
// A short return is normal, not an error: the buffer is full, so keep the
// rest and offer it again next frame. `playback_writable` says how much
// would be taken.
playback_write :: proc(p: ^Playback, src: []f32) -> (n: int, err: Error) {
	if !p.open do return 0, .Closed
	if bad := state_of(&p.state); bad != .None do return 0, bad
	n = ring_write(&p.ring, src)
	backend_playback_nudge(p)
	return n, .None
}

// playback_writable is how many samples `playback_write` would take now.
playback_writable :: proc(p: ^Playback) -> int {
	if !p.open do return 0
	return ring_free(&p.ring)
}

// playback_queued is how many samples have been handed over but not yet
// heard: this package's buffer and the server's, so it reaches 0 when the
// sound has left the speakers, not when the last write was accepted.
// `ms_for_samples(p.format, playback_queued(&p))` is the time left to hear.
playback_queued :: proc(p: ^Playback) -> int {
	if !p.open do return 0
	return ring_available(&p.ring) + backend_playback_server_queued(p)
}

// playback_drained is true once everything written has been heard. Poll it
// from the UI loop (an `every` subscription, or each frame while a clip is
// playing) to know when to put the play button back.
playback_drained :: proc(p: ^Playback) -> bool {
	if !p.open do return true
	return playback_queued(p) == 0
}

// playback_underruns counts the times the stream ran dry with the app
// still writing — the difference between "the clip ended" and "the clip
// stuttered". A clip written in one go and allowed to finish ends with 0.
playback_underruns :: proc(p: ^Playback) -> int {
	if !p.open do return 0
	return int(load_i32(&p.underruns))
}

// playback_flush drops everything queued, here and in the server: stop
// now, not at the end of the clip. The stream stays open and more can be
// written straight away.
//
// It may take a moment (on macOS it stops and restarts the audio queue,
// about 25 ms), so it belongs on a "stop" the person pressed, not in a loop.
playback_flush :: proc(p: ^Playback) {
	if !p.open do return
	ring_clear(&p.ring)
	backend_playback_flush(p)
}

// playback_error is the stream's state without writing to it.
playback_error :: proc(p: ^Playback) -> Error {
	if !p.open do return .Closed
	return state_of(&p.state)
}

// playback_close stops the stream and frees everything, discarding
// anything still queued — call `playback_drained` first if the clip
// should be allowed to finish. Safe on one that never opened.
playback_close :: proc(p: ^Playback, allocator := context.allocator) {
	if !p.open {
		p^ = {}
		return
	}
	backend_playback_close(p, allocator)
	ring_destroy(&p.ring, allocator)
	p^ = {}
}
