#+build linux
package x11

// File watches, which on Linux are inotify and belong to no window system
// (platform/inotify_linux.odin) — the same code the Wayland backend uses.
// The descriptor joins the pump's poll set so a change wakes the loop.

import "core:sys/linux"
import "baldr:platform"

@(private)
watch :: proc(b: ^platform.Backend, path: string, token: u64) -> bool {
	return platform.inotify_watch(&data(b).inotify, path, token)
}

@(private)
unwatch :: proc(b: ^platform.Backend, token: u64) {
	platform.inotify_unwatch(&data(b).inotify, token)
}

@(private)
watch_start :: proc(x: ^X11) {
	if !platform.inotify_open(&x.inotify) do debugf(x, "inotify unavailable: file watches report nothing")
}

@(private)
watch_stop :: proc(x: ^X11) {
	platform.inotify_close(&x.inotify)
}

@(private)
watch_fd_of :: proc(x: ^X11) -> linux.Fd {
	return x.inotify.fd
}
