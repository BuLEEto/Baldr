#+build !linux
#+build !darwin
#+build !windows
// No audio backend on this platform yet: every stream reports
// `.Unsupported` and an app shows the same "no audio support" message it
// would show on a machine with no sound card. Linux, macOS and Windows all
// have one.
package audio

@(private)
backend_capture_open :: proc(c: ^Capture, latency_ms: int, device: string, allocator := context.allocator) -> Error {
	return .Unsupported
}

@(private)
backend_capture_close :: proc(c: ^Capture, allocator := context.allocator) {}

@(private)
backend_playback_open :: proc(p: ^Playback, latency_ms: int, device: string, allocator := context.allocator) -> Error {
	return .Unsupported
}

@(private)
backend_playback_close :: proc(p: ^Playback, allocator := context.allocator) {}

@(private)
backend_playback_nudge :: proc(p: ^Playback) {}

@(private)
backend_playback_flush :: proc(p: ^Playback) {}

@(private)
backend_playback_server_queued :: proc(p: ^Playback) -> int {
	return 0
}

// The probes, so a spike that prints them builds everywhere.
probe_clock_ok :: proc(p: ^Playback) -> bool { return false }
probe_written :: proc(p: ^Playback) -> int { return 0 }
probe_played :: proc(p: ^Playback) -> int { return 0 }
probe_last_status :: proc() -> (call: string, status: int) { return "", 0 }
