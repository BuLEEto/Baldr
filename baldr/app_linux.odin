package baldr

import "core:os"
import "baldr:platform"
import "baldr:platform/wayland"
import "baldr:platform/x11"

// default_backend picks the Linux backend.
//
// Wayland when there is a Wayland display to connect to, X11 otherwise —
// the order every toolkit uses, because a Wayland session usually also runs
// Xwayland, and taking X there would give up per-surface scaling, the
// fractional-scale protocol and the shell protocols for nothing.
//
// `BALDR_BACKEND` forces one: `wayland` or `x11`. An X11 session has no
// WAYLAND_DISPLAY, so it needs no variable; the override is for testing the
// X11 backend from inside a Wayland session.
default_backend :: proc() -> ^platform.Backend {
	switch os.get_env("BALDR_BACKEND", context.temp_allocator) {
	case "x11":     return x11.backend()
	case "wayland": return wayland.backend()
	}
	if os.get_env("WAYLAND_DISPLAY", context.temp_allocator) != "" do return wayland.backend()
	if os.get_env("DISPLAY", context.temp_allocator) != "" do return x11.backend()
	return wayland.backend() // nothing to go on: Wayland's error message is the clearer one
}
