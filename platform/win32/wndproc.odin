#+build windows
package win32

// wndproc.odin — the window procedure: Win32 messages → platform.Event.
// Runs on the pump thread, either from our DispatchMessageW or, during the
// modal size/move loop Windows runs inside DefWindowProcW, from the system's
// own loop — which is why WM_TIMER/WM_PAINT call `redraw_callback` there.

import "core:unicode/utf16"
import "core:unicode/utf8"
import "core:mem/virtual"
import win "core:sys/windows"
import "baldr:platform"

@(private)
wnd_proc :: proc "system" (hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT {
	if msg == win.WM_NCCREATE {
		cs := (^win.CREATESTRUCTW)(uintptr(lparam))
		if cs.lpCreateParams != nil {
			s := (^Surface)(cs.lpCreateParams)
			s.hwnd = hwnd
			win.SetWindowLongPtrW(hwnd, win.GWLP_USERDATA, win.LONG_PTR(uintptr(s)))
		}
		return win.DefWindowProcW(hwnd, msg, wparam, lparam)
	}
	s := (^Surface)(uintptr(win.GetWindowLongPtrW(hwnd, win.GWLP_USERDATA)))
	if s == nil {
		// The message-only wake window, and WM_GETMINMAXINFO before WM_NCCREATE.
		return win.DefWindowProcW(hwnd, msg, wparam, lparam)
	}
	context = s.w.ctx
	w := s.w

	switch msg {
	// ---------------------------------------------------------- lifecycle
	case win.WM_SIZE:
		if wparam == win.SIZE_MINIMIZED {
			s.minimized = true // no extent: no Ev_Configure, Ev_Redraw is held until restore
			return 0
		}
		s.minimized = false
		s.size_px = {u32(win.LOWORD(lparam)), u32(win.HIWORD(lparam))}
		s.maximized = wparam == win.SIZE_MAXIMIZED
		emit_configure(s)
		return 0

	case win.WM_DPICHANGED:
		// wParam: new DPI (both words); lParam: suggested window rect in the new DPI.
		s.dpi = u32(win.HIWORD(wparam))
		rc := (^win.RECT)(uintptr(lparam))
		win.SetWindowPos(hwnd, nil, rc.left, rc.top, rc.right - rc.left, rc.bottom - rc.top, win.SWP_NOZORDER | win.SWP_NOACTIVATE)
		emit_configure(s) // usually a repeat of the WM_SIZE inside SetWindowPos; deduped
		if outputs_refresh(w) { append(&w.queue, platform.Ev_Outputs{}) } // the screen's scale, and so its logical size
		return 0

	case win.WM_ACTIVATE:
		s.activated = win.LOWORD(wparam) != win.WA_INACTIVE
		emit_configure(s)
		// fall through to DefWindowProcW: it moves keyboard focus to the window

	case win.WM_SETFOCUS:
		s.focused = true
		if s.live { append(&w.queue, platform.Ev_Focus{surface = s.id, focused = true}) }
		return 0

	case win.WM_KILLFOCUS:
		s.focused = false
		if s.live { append(&w.queue, platform.Ev_Focus{surface = s.id, focused = false}) }
		return 0

	case win.WM_CLOSE:
		// The app decides; the toolkit calls surface_destroy if it agrees.
		if s.live { append(&w.queue, platform.Ev_Close{surface = s.id}) }
		return 0

	case win.WM_NCDESTROY:
		win.SetWindowLongPtrW(hwnd, win.GWLP_USERDATA, 0)
		s.hwnd = nil

	case win.WM_ENDSESSION:
		if wparam != 0 && s.live { append(&w.queue, platform.Ev_Quit{}) }
		return 0

	case win.WM_GETMINMAXINFO:
		min_max_info(s, (^win.MINMAXINFO)(uintptr(lparam)))
		return 0

	// ----------------------------------------------------------- painting
	case win.WM_ERASEBKGND:
		if !s.painted {
			rc: win.RECT
			win.GetClientRect(hwnd, &rc)
			win.FillRect(win.HDC(wparam), &rc, w.bg_brush)
		}
		return 1 // Vulkan owns the client area

	case win.WM_PAINT:
		// Validate or USER re-posts WM_PAINT forever and the pump never idles.
		win.ValidateRect(hwnd, nil)
		if s.in_size_move { modal_redraw(s) }
		return 0

	case win.WM_ENTERSIZEMOVE:
		s.in_size_move = true
		win.SetTimer(hwnd, RENDER_TIMER, win.USER_TIMER_MINIMUM, nil)
		return 0

	case win.WM_EXITSIZEMOVE:
		s.in_size_move = false
		win.KillTimer(hwnd, RENDER_TIMER)
		return 0

	case win.WM_TIMER:
		if wparam == RENDER_TIMER || wparam == DIALOG_TIMER { // a size / move loop, or a file dialog: both swallow our pump
			modal_redraw(s)
			return 0
		}

	// ------------------------------------------------------------ pointer
	case win.WM_SETCURSOR:
		if win.LOWORD(lparam) == win.HTCLIENT {
			win.SetCursor(cursor_of(s))
			return 1
		}

	case win.WM_MOUSEMOVE:
		pos := client_pos(s, lparam)
		if s.live {
			if !s.pointer_inside {
				s.pointer_inside = true
				append(&w.queue, platform.Ev_Pointer_Enter{surface = s.id, pos = pos})
			} else if pos != s.pointer_pos {
				append(&w.queue, platform.Ev_Pointer_Motion{surface = s.id, pos = pos, time_ms = u32(GetMessageTime())})
			}
			s.pointer_pos = pos
		}
		// While a button is held the window has capture and moves outside
		// keep coming; TME_LEAVE is re-armed after the release instead.
		if !s.tracking && s.buttons == {} { track_leave(s) }
		return 0

	case win.WM_MOUSELEAVE:
		s.tracking = false
		if s.buttons == {} { pointer_left(s) }
		return 0

	case win.WM_LBUTTONDOWN: button(s, .Left, true, lparam);    return 0
	case win.WM_LBUTTONUP:   button(s, .Left, false, lparam);   return 0
	case win.WM_RBUTTONDOWN: button(s, .Right, true, lparam);   return 0
	case win.WM_RBUTTONUP:   button(s, .Right, false, lparam);  return 0
	case win.WM_MBUTTONDOWN: button(s, .Middle, true, lparam);  return 0
	case win.WM_MBUTTONUP:   button(s, .Middle, false, lparam); return 0
	case win.WM_XBUTTONDOWN, win.WM_XBUTTONUP:
		b: platform.Mouse_Button = .Back if win.GET_XBUTTON_WPARAM(wparam) == win.XBUTTON1 else .Forward
		button(s, b, msg == win.WM_XBUTTONDOWN, lparam)
		return 1 // documented: return TRUE for WM_XBUTTON*

	case win.WM_CAPTURECHANGED:
		// Capture taken away (Alt-Tab, a system menu): release what is held so
		// the toolkit never sees a stuck button.
		if s.buttons != {} {
			pos := cursor_client_pos(s)
			for b in platform.Mouse_Button {
				if b in s.buttons { push_button(s, b, false, pos) }
			}
			s.buttons = {}
			after_release(s)
		}
		return 0

	case win.WM_MOUSEWHEEL, win.WM_MOUSEHWHEEL:
		// Wheel positions are in screen coordinates, unlike every other mouse message.
		pt := win.POINT{win.GET_X_LPARAM(lparam), win.GET_Y_LPARAM(lparam)}
		win.ScreenToClient(hwnd, &pt)
		steps := f32(win.GET_WHEEL_DELTA_WPARAM(wparam)) / win.WHEEL_DELTA
		delta: [2]f32
		if msg == win.WM_MOUSEWHEEL {
			delta.y = -steps * platform.SCROLL_STEP_PX // wheel forward (positive) = content moves down
		} else {
			delta.x = steps * platform.SCROLL_STEP_PX
		}
		if s.live {
			append(&w.queue, platform.Ev_Scroll{
				surface = s.id,
				delta   = delta,
				pos     = [2]f32{f32(pt.x), f32(pt.y)} / scale_of(s),
				precise = false,
				mods    = mods(),
			})
		}
		return 0

	// ----------------------------------------------------------- keyboard
	// ------------------------------------------------------- input methods
	case win.WM_IME_STARTCOMPOSITION, win.WM_IME_COMPOSITION, win.WM_IME_ENDCOMPOSITION,
	     win.WM_IME_SETCONTEXT, win.WM_IME_CHAR:
		if done, res := ime_message(s, msg, wparam, lparam); done { return res }

	case win.WM_KEYDOWN, win.WM_SYSKEYDOWN, win.WM_KEYUP, win.WM_SYSKEYUP:
		key(s, u32(wparam), lparam, msg == win.WM_KEYDOWN || msg == win.WM_SYSKEYDOWN)
		// fall through to DefWindowProcW: Alt+F4, Alt+Space, F10 live there

	case win.WM_CHAR:
		char_utf16(s, u16(wparam))
		return 0

	case win.WM_SYSCHAR:
		// Alt+letter: no Ev_Text and no beep. Alt+Space still opens the system menu.
		if wparam != ' ' { return 0 }

	case win.WM_UNICHAR:
		if wparam == win.UNICODE_NOCHAR { return 1 } // "yes, we take WM_UNICHAR"
		text(s, rune(wparam))
		return 0

	// -------------------------------------------------------------- theme
	case win.WM_SETTINGCHANGE:
		if lparam != 0 {
			name, _ := win.wstring_to_utf8(win.wstring(rawptr(uintptr(lparam))), -1, context.temp_allocator)
			if name == "ImmersiveColorSet" {
				w.dark = !apps_use_light_theme()
				w.theme_pending = true
				for other in w.surfaces {
					if other != nil { apply_dark_title_bar(other) }
				}
			}
		}

	case win.WM_DWMCOLORIZATIONCOLORCHANGED:
		w.theme_pending = true // accent changed

	// ------------------------------------------------------------ screens
	// WM_DISPLAYCHANGE is broadcast to top-level windows, which is why the
	// screens are read here rather than on the message-only wake window
	// (broadcasts do not reach HWND_MESSAGE). An app always has a window by
	// the time one can change.
	case win.WM_DISPLAYCHANGE:
		if outputs_refresh(w) { append(&w.queue, platform.Ev_Outputs{}) }
	}
	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}

// modal_redraw lets the toolkit paint while Windows owns the loop (drag-resize
// / move). Queued events (the WM_SIZE configures) are still waiting for the
// next pump, so the callback should consult surface_geometry.
@(private)
modal_redraw :: proc(s: ^Surface) {
	w := s.w
	if w.backend.redraw_callback == nil || !s.live || !can_paint(s) { return }
	s.frame_requested = false
	s.painted = true
	w.backend.redraw_callback(w.backend.redraw_user, s.id)
}

// min_max_info converts the logical min/max (or the fixed size) to outer
// window px at the current DPI.
@(private)
min_max_info :: proc(s: ^Surface, mmi: ^win.MINMAXINFO) {
	scale := scale_of(s)
	frame := win.RECT{}
	win.AdjustWindowRectExForDpi(&frame, s.style, win.FALSE, s.exstyle, s.dpi if s.dpi != 0 else 96)
	fw, fh := frame.right - frame.left, frame.bottom - frame.top
	lo, hi := s.min_size, s.max_size
	if s.fixed_size { lo, hi = s.logical_size, s.logical_size }
	if lo.x > 0 { mmi.ptMinTrackSize.x = px_size(lo, scale).x + fw }
	if lo.y > 0 { mmi.ptMinTrackSize.y = px_size(lo, scale).y + fh }
	if hi.x > 0 { mmi.ptMaxTrackSize.x = px_size(hi, scale).x + fw }
	if hi.y > 0 { mmi.ptMaxTrackSize.y = px_size(hi, scale).y + fh }
}

// ---------------------------------------------------------------- pointer

@(private)
client_pos :: #force_inline proc(s: ^Surface, lparam: win.LPARAM) -> [2]f32 {
	return [2]f32{f32(win.GET_X_LPARAM(lparam)), f32(win.GET_Y_LPARAM(lparam))} / scale_of(s)
}

@(private)
cursor_client_pos :: proc(s: ^Surface) -> [2]f32 {
	pt: win.POINT
	win.GetCursorPos(&pt)
	win.ScreenToClient(s.hwnd, &pt)
	return [2]f32{f32(pt.x), f32(pt.y)} / scale_of(s)
}

@(private)
track_leave :: proc(s: ^Surface) {
	tme := win.TRACKMOUSEEVENT{cbSize = size_of(win.TRACKMOUSEEVENT), dwFlags = win.TME_LEAVE, hwndTrack = s.hwnd}
	s.tracking = bool(win.TrackMouseEvent(&tme))
}

@(private)
pointer_left :: proc(s: ^Surface) {
	if !s.pointer_inside { return }
	s.pointer_inside = false
	if s.live { append(&s.w.queue, platform.Ev_Pointer_Leave{surface = s.id}) }
}

// after_release: capture is gone; if the drag ended outside the client area
// report the Leave that was suppressed, otherwise re-arm TME_LEAVE.
@(private)
after_release :: proc(s: ^Surface) {
	pt: win.POINT
	win.GetCursorPos(&pt)
	win.ScreenToClient(s.hwnd, &pt)
	rc: win.RECT
	win.GetClientRect(s.hwnd, &rc)
	inside := pt.x >= rc.left && pt.x < rc.right && pt.y >= rc.top && pt.y < rc.bottom
	if inside {
		if !s.tracking { track_leave(s) }
	} else {
		s.tracking = false
		pointer_left(s)
	}
}

@(private)
push_button :: proc(s: ^Surface, b: platform.Mouse_Button, pressed: bool, pos: [2]f32) {
	w := s.w
	w.serial += 1
	if s.live {
		append(&w.queue, platform.Ev_Pointer_Button{
			surface = s.id, button = b, pressed = pressed, pos = pos, mods = mods(), serial = w.serial,
			time_ms = u32(GetMessageTime()),
		})
	}
}

@(private)
button :: proc(s: ^Surface, b: platform.Mouse_Button, pressed: bool, lparam: win.LPARAM) {
	pos := client_pos(s, lparam)
	if pressed {
		if s.buttons == {} { win.SetCapture(s.hwnd) } // drags leaving the window keep reporting
		s.buttons += {b}
		push_button(s, b, true, pos)
	} else {
		if b not_in s.buttons { return } // already released by WM_CAPTURECHANGED, or pressed over another window
		s.buttons -= {b}
		push_button(s, b, false, pos)
		if s.buttons == {} {
			win.ReleaseCapture() // WM_CAPTURECHANGED arrives now; buttons is already empty
			after_release(s)
		}
	}
}

@(private)
mods :: proc() -> platform.Mods {
	m: platform.Mods
	if win.GetKeyState(win.VK_SHIFT) < 0   { m += {.Shift} }
	if win.GetKeyState(win.VK_CONTROL) < 0 { m += {.Ctrl} }
	if win.GetKeyState(win.VK_MENU) < 0    { m += {.Alt} }
	if win.GetKeyState(win.VK_LWIN) < 0 || win.GetKeyState(win.VK_RWIN) < 0 { m += {.Super} }
	if win.GetKeyState(win.VK_CAPITAL) & 1 != 0 { m += {.Caps_Lock} }
	if win.GetKeyState(win.VK_NUMLOCK) & 1 != 0 { m += {.Num_Lock} }
	return m
}

// --------------------------------------------------------------- keyboard

@(private)
key :: proc(s: ^Surface, vk_in: u32, lparam: win.LPARAM, pressed: bool) {
	flags := u32(win.HIWORD(lparam)) // KF_EXTENDED | KF_REPEAT | KF_UP | scan code in the low byte
	scancode := flags & 0xff
	extended := flags & win.KF_EXTENDED != 0
	vk := vk_in
	switch vk {
	case win.VK_SHIFT:
		vk = u32(win.MapVirtualKeyW(scancode, win.MAPVK_VSC_TO_VK_EX)) // VK_LSHIFT / VK_RSHIFT
		if vk == 0 { vk = win.VK_LSHIFT }
	case win.VK_CONTROL:
		vk = win.VK_RCONTROL if extended else win.VK_LCONTROL
	case win.VK_MENU:
		vk = win.VK_RMENU if extended else win.VK_LMENU
	}
	if !s.live { return }
	append(&s.w.queue, platform.Ev_Key{
		surface = s.id,
		key     = vk_to_key(vk, extended),
		native  = vk,
		pressed = pressed,
		repeat  = pressed && flags & win.KF_REPEAT != 0,
		mods    = mods(),
	})
}

// char_utf16 assembles surrogate pairs (WM_CHAR delivers UTF-16 code units).
@(private)
char_utf16 :: proc(s: ^Surface, c: u16) {
	switch {
	case c >= 0xD800 && c <= 0xDBFF:
		s.high_surrogate = c
	case c >= 0xDC00 && c <= 0xDFFF:
		if s.high_surrogate != 0 {
			text(s, utf16.decode_surrogate_pair(rune(s.high_surrogate), rune(c)))
		}
		s.high_surrogate = 0
	case:
		s.high_surrogate = 0
		text(s, rune(c))
	}
}

// text queues Ev_Text for a committed code point. Control characters (Enter,
// Tab, Backspace, Escape, Ctrl+letter, DEL) are keys, not text.
@(private)
text :: proc(s: ^Surface, r: rune) {
	if r < 0x20 || r == 0x7f || !s.live { return }
	buf, n := utf8.encode_rune(r)
	str := make([]u8, n, virtual.arena_allocator(&s.w.text))
	copy(str, buf[:n])
	append(&s.w.queue, platform.Ev_Text{surface = s.id, text = string(str)})
}
