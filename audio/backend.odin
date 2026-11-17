package audio

import "core:sync"

// The backend seam. Each platform file defines these six procs behind its
// own `#+build` tag; `stub.odin` answers `.Unsupported` everywhere else.
// Nothing above this line knows what a sound server is, and nothing below
// it knows what a `Ring` is for.
//
//	backend_capture_open   (c, latency_ms, device, allocator) -> Error
//	backend_capture_close  (c, allocator)
//	backend_playback_open  (p, latency_ms, device, allocator) -> Error
//	backend_playback_close (p, allocator)
//	backend_playback_nudge (p)                 // the app wrote; make progress
//	backend_playback_flush (p)                 // drop the server's buffer too
//	backend_playback_server_queued (p) -> int  // samples the server still holds
//
// A backend owns one thread at most, writes to the ring and to the `state`
// and `underruns` counters, and reads nothing else.

// state_of reads a stream's latched error. The backend's thread writes it
// with `set_state` when the server drops the stream.
@(private)
state_of :: proc(p: ^i32) -> Error {
	return Error(sync.atomic_load_explicit(p, .Acquire))
}

@(private)
set_state :: proc(p: ^i32, err: Error) {
	sync.atomic_store_explicit(p, i32(err), .Release)
}

@(private)
load_i32 :: proc(p: ^i32) -> i32 {
	return sync.atomic_load_explicit(p, .Relaxed)
}

@(private)
bump_i32 :: proc(p: ^i32) {
	sync.atomic_add_explicit(p, 1, .Relaxed)
}
