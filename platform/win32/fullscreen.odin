#+build windows
package win32

// A window taking the whole screen, and closing itself.
//
// Windows has no "make me fullscreen" call: the convention is to remember
// where the window was, take its frame off, and put it over the monitor's
// whole rectangle. Going back is the same in reverse, which is why the
// previous placement is kept rather than recomputed.
//
// The app hears the result in the next Ev_Configure, as it does on every
// platform: `surface_set_fullscreen` is a request even here, where the
// answer happens to be immediate.

import win "core:sys/windows"
import "baldr:platform"

// surface_set_fullscreen gives the window the whole screen it is on, or
// gives it back.
@(private)
surface_set_fullscreen :: proc(b: ^platform.Backend, id: platform.Surface, on: bool) -> bool {
	w := data(b)
	s := get_surface(w, id)
	if s == nil || s.hwnd == nil do return false
	if s.fullscreen == on do return true
	// A window the app declared unresizable is still allowed the screen:
	// `fixed_size` is about dragging an edge, not about what the app may
	// ask for. The size hints are suspended while it is out there and put
	// back with the frame.
	if on {
		if !win.GetWindowPlacement(s.hwnd, &s.placement) do return false
		s.saved_style = win.GetWindowLongW(s.hwnd, win.GWL_STYLE)
		mon := win.MonitorFromWindow(s.hwnd, .MONITOR_DEFAULTTONEAREST)
		mi := win.MONITORINFO{cbSize = size_of(win.MONITORINFO)}
		if mon == nil || !win.GetMonitorInfoW(mon, &mi) do return false
		// Before SetWindowPos, not after: that call sends WM_SIZE
		// synchronously, which emits a configure there and then, so a flag
		// set afterwards goes out one event late and the app first builds a
		// windowed layout at the screen's size.
		s.fullscreen = true
		debugf(w, "fullscreen: flag set true, now resizing")
		win.SetWindowLongW(s.hwnd, win.GWL_STYLE, i32(u32(s.saved_style) & ~u32(win.WS_OVERLAPPEDWINDOW)))
		r := mi.rcMonitor
		win.SetWindowPos(s.hwnd, win.HWND_TOP, r.left, r.top, r.right - r.left, r.bottom - r.top,
			win.SWP_NOOWNERZORDER | win.SWP_FRAMECHANGED)
	} else {
		s.fullscreen = false
		debugf(w, "fullscreen: flag set false, now restoring")
		win.SetWindowLongW(s.hwnd, win.GWL_STYLE, s.saved_style)
		win.SetWindowPlacement(s.hwnd, &s.placement)
		win.SetWindowPos(s.hwnd, nil, 0, 0, 0, 0,
			win.SWP_NOMOVE | win.SWP_NOSIZE | win.SWP_NOZORDER | win.SWP_NOOWNERZORDER | win.SWP_FRAMECHANGED)
	}
	// Usually nothing: WM_SIZE has already emitted the configure, carrying
	// the flag because it was set first, and emit_configure drops a repeat
	// of what it last sent. This is for a desktop that sends no WM_SIZE —
	// asking for the screen a window already fills.
	emit_configure(s)
	return true
}

// surface_post_close asks for this window to close as if its frame's close
// button had been pressed, so a window drawing its own title bar goes down
// the path a decorated one does — the app hears Ev_Close and decides.
//
// WM_CLOSE rather than an event pushed straight onto the queue: the window
// procedure is the one place that decides what a close means, and posting
// keeps that true for a window that is also being closed by the desktop.
@(private)
surface_post_close :: proc(b: ^platform.Backend, id: platform.Surface) {
	s := get_surface(data(b), id)
	if s == nil || s.hwnd == nil do return
	win.PostMessageW(s.hwnd, win.WM_CLOSE, 0, 0)
}

// key_name is what *Windows* calls a key, which is not what xkb calls it:
// there is no unlocalised name on this platform, so a German keyboard says
// "Eingabe" where an English one says "Enter". A configuration written with
// these names is a Windows configuration, which is what
// `platform.Backend.key_name` says it is — `Chord.key` is the portable half.
@(private)
key_name :: proc(b: ^platform.Backend, native: u32, allocator := context.allocator) -> string {
	// GetKeyNameTextW wants the scancode in bits 16..23, and the extended
	// bit so that the arrow keys and the keypad are told apart.
	sc := win.MapVirtualKeyW(native, win.MAPVK_VK_TO_VSC)
	if sc == 0 do return ""
	lparam := i32(sc << 16)
	switch native {
	case win.VK_LEFT, win.VK_RIGHT, win.VK_UP, win.VK_DOWN,
	     win.VK_PRIOR, win.VK_NEXT, win.VK_END, win.VK_HOME,
	     win.VK_INSERT, win.VK_DELETE, win.VK_DIVIDE, win.VK_NUMLOCK:
		lparam |= 1 << 24
	}
	buf: [64]u16
	n := GetKeyNameTextW(lparam, raw_data(buf[:]), win.c_int(len(buf)))
	if n <= 0 do return ""
	out, err := win.utf16_to_utf8(buf[:n], allocator)
	return out if err == nil else ""
}
