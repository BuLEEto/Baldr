#+build windows
package win32

// idle.odin — keeping the display on while a window is showing something to
// watch. Windows' equivalent of idle-inhibit is
// SetThreadExecutionState, which is a *thread's* standing request rather
// than a window's: ES_DISPLAY_REQUIRED with ES_CONTINUOUS until it is taken
// back with a bare ES_CONTINUOUS.
//
// So the per-surface asking the backend contract is written in has to be
// counted: the state is set when the first window asks and cleared when the
// last one stops. The loop calls this only when a window's answer changes,
// but counting here means the backend cannot be put out of step by a window
// closing while it still asks (surface_destroy clears it).
//
// ES_AWAYMODE_REQUIRED is deliberately not asked for: that is for a media
// *server* that must go on serving with the screen off, which is the
// opposite of this.

import "baldr:platform"
import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

ES_CONTINUOUS :: win.DWORD(0x8000_0000)
ES_DISPLAY_REQUIRED :: win.DWORD(0x0000_0002)

@(default_calling_convention = "system")
foreign kernel32 {
	// The previous state, or 0 for failure. Not in core:sys/windows.
	SetThreadExecutionState :: proc(esFlags: win.DWORD) -> win.DWORD ---
}

// keep_awake is Backend.keep_awake: hold the display on while this surface
// shows, or let the idle timer have it back.
@(private)
keep_awake :: proc(b: ^platform.Backend, surface: platform.Surface, on: bool) {
	w := data(b)
	if w == nil do return
	s := get_surface(w, surface)
	if s == nil || s.awake == on do return
	s.awake = on
	idle_apply(w)
}

// idle_release stops a surface asking as it goes (surface_destroy).
@(private)
idle_release :: proc(w: ^Win32, s: ^Surface) {
	if s == nil || !s.awake do return
	s.awake = false
	idle_apply(w)
}

// idle_apply tells Windows what the windows between them want, and only
// when that changes: the call is cheap but it is a thread-wide state, and
// setting it twice over hides which window actually asked.
@(private)
idle_apply :: proc(w: ^Win32) {
	want := false
	for s in w.surfaces do if s != nil && s.awake { want = true; break }
	if want == w.awake do return
	w.awake = want
	SetThreadExecutionState(ES_CONTINUOUS | ES_DISPLAY_REQUIRED if want else ES_CONTINUOUS)
}
