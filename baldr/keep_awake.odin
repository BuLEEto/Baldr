package baldr

// keep_awake.odin — asking the desktop not to dim, blank or lock the screen
// while the window is showing something to watch.
//
// An idle timer measures the keyboard and the pointer, and a film watched to
// the end touches neither. A desktop usually keeps a full-screen window
// awake itself, but not one playing in a window. So whatever is playing
// declares a flag from the view, and clears it the moment it stops: the
// screen going dark when nothing is happening is still right.

import "baldr:platform"

// keep_awake asks the desktop not to dim, blank or lock the screen while
// this window is showing. Declare it from the view for as long as you want
// it, the way `inhibit_shortcuts` is declared:
//
//	baldr.keep_awake(ui, s.playing && !s.paused)
//
// It is for watching rather than doing: a video, a slideshow, a
// presentation. Background work (a download, a render) needs the *system*
// kept awake, which is a different ask. Honoured on Wayland through
// `zwp_idle_inhibit_manager_v1` and on Windows through
// `SetThreadExecutionState`; on X11 it does nothing yet. The desktop
// decides, and may require the window to be visible. Clearing the flag (or
// the window closing) gives the idle timer straight back.
keep_awake :: proc(ui: ^Ui($Msg), on: bool) {
	if on do ui.keep_awake = true
}

// awake_sync tells the desktop what this surface's latest view asked for,
// only when the answer changes: the request is a standing one, and on
// Windows it is thread-wide state, so repeating it would hide which window
// asked.
@(private)
awake_sync :: proc(b: ^platform.Backend, surface: platform.Surface, want: bool, now: ^bool) {
	if want == now^ do return
	now^ = want
	if b != nil && b.keep_awake != nil do b.keep_awake(b, surface, want)
}
