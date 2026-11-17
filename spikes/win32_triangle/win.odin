#+build windows
package main

// win.odin — the Win32 side of the spike: window class, DPI awareness, dark
// title bar, WndProc, and the message pump. Everything comes from
// core:sys/windows except three user32 procs core lacks (MsgWaitForMultipleObjectsEx
// and two DPI-awareness queries), declared below against the same User32.lib
// core already links.

import "base:runtime"
import win "core:sys/windows"

CLASS_NAME   :: "BaldrSpikeWindow"
WINDOW_TITLE :: "Baldr spike"
RENDER_TIMER :: 1 // SetTimer id used while Windows runs its modal size/move loop

foreign import user32 "system:User32.lib"

@(default_calling_convention="system")
foreign user32 {
	MsgWaitForMultipleObjectsEx         :: proc(nCount: win.DWORD, pHandles: [^]win.HANDLE, dwMilliseconds: win.DWORD, dwWakeMask: win.DWORD, dwFlags: win.DWORD) -> win.DWORD ---
	GetAwarenessFromDpiAwarenessContext :: proc(value: win.DPI_AWARENESS_CONTEXT) -> Dpi_Awareness ---
	AreDpiAwarenessContextsEqual        :: proc(a, b: win.DPI_AWARENESS_CONTEXT) -> win.BOOL ---
}

MWMO_INPUTAVAILABLE :: 0x0004

Dpi_Awareness :: enum i32 { INVALID = -1, UNAWARE = 0, SYSTEM_AWARE = 1, PER_MONITOR_AWARE = 2 }

// Creates the window with a DEFAULT_WIDTH x DEFAULT_HEIGHT *logical* client
// area, scaled to the monitor's DPI once the window exists (we cannot know
// the DPI before we know which monitor the window lands on).
win_create_window :: proc(a: ^App) -> bool {
	// Per-monitor-v2 must be set before any window exists. It fails with
	// ERROR_ACCESS_DENIED if a manifest already set an awareness; there is none here.
	if win.SetProcessDpiAwarenessContext(win.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) {
		log("dpi awareness: per-monitor v2")
	} else {
		// ERROR_ACCESS_DENIED (5) = already set, by a manifest or an earlier call.
		err := win.GetLastError()
		ctx := win.GetThreadDpiAwarenessContext()
		log("dpi awareness: SetProcessDpiAwarenessContext failed (error %d); current awareness %v, per-monitor-v2 already active: %v",
			err, GetAwarenessFromDpiAwarenessContext(ctx),
			AreDpiAwarenessContextsEqual(ctx, win.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2))
	}

	a.hinstance = win.HINSTANCE(win.GetModuleHandleW(nil))
	class_name := win.utf8_to_wstring(CLASS_NAME)
	wc := win.WNDCLASSEXW{
		cbSize        = size_of(win.WNDCLASSEXW),
		style         = win.CS_HREDRAW | win.CS_VREDRAW,
		lpfnWndProc   = wnd_proc,
		hInstance     = a.hinstance,
		hCursor       = win.LoadCursorW(nil, win.LPCWSTR(win._IDC_ARROW)),
		hbrBackground = win.CreateSolidBrush(0x00201c1a), // dark grey until the first present (COLORREF is 0x00BBGGRR)
		lpszClassName = class_name,
	}
	if win.RegisterClassExW(&wc) == 0 {
		log_errf("win32: RegisterClassExW failed (error %d)", win.GetLastError())
		return false
	}

	style: u32 = win.WS_OVERLAPPEDWINDOW
	exstyle: u32 = win.WS_EX_APPWINDOW
	a.hwnd = win.CreateWindowExW(
		exstyle, class_name, win.utf8_to_wstring(WINDOW_TITLE), style,
		win.CW_USEDEFAULT, win.CW_USEDEFAULT, DEFAULT_WIDTH, DEFAULT_HEIGHT,
		nil, nil, a.hinstance, nil)
	if a.hwnd == nil {
		log_errf("win32: CreateWindowExW failed (error %d)", win.GetLastError())
		return false
	}

	// Now that we know the monitor, size the frame so the client area is
	// DEFAULT_WIDTH x DEFAULT_HEIGHT logical pixels at this DPI.
	a.dpi = u32(win.GetDpiForWindow(a.hwnd))
	if a.dpi == 0 { a.dpi = 96 }
	rc := win.RECT{0, 0, win.LONG(DEFAULT_WIDTH * i32(a.dpi) / 96), win.LONG(DEFAULT_HEIGHT * i32(a.dpi) / 96)}
	win.AdjustWindowRectExForDpi(&rc, style, win.FALSE, exstyle, a.dpi)
	win.SetWindowPos(a.hwnd, nil, 0, 0, rc.right - rc.left, rc.bottom - rc.top,
		win.SWP_NOMOVE | win.SWP_NOZORDER | win.SWP_NOACTIVATE)

	// Dark title bar (Windows 10 20H1+ uses attribute 20; older builds fail — ignored).
	dark: win.BOOL = win.TRUE
	hr := win.DwmSetWindowAttribute(a.hwnd, u32(win.DWMWINDOWATTRIBUTE.DWMWA_USE_IMMERSIVE_DARK_MODE), &dark, size_of(dark))
	if hr >= 0 {
		log("dark title bar: DWMWA_USE_IMMERSIVE_DARK_MODE ok")
	} else {
		log("dark title bar: DwmSetWindowAttribute failed (hr 0x%08x), ignored", u32(hr))
	}

	win.ShowWindow(a.hwnd, win.SW_SHOW)
	client: win.RECT
	win.GetClientRect(a.hwnd, &client)
	a.width, a.height = client.right - client.left, client.bottom - client.top
	a.resize_needed = false // WM_SIZE fired during creation; the first swapchain uses this size
	log("window created: client %dx%d px (logical %dx%d), dpi %d (%d%%), hwnd %p",
		a.width, a.height, DEFAULT_WIDTH, DEFAULT_HEIGHT, a.dpi, a.dpi * 100 / 96, a.hwnd)
	return true
}

win_destroy_window :: proc(a: ^App) {
	if a.hwnd != nil {
		win.DestroyWindow(a.hwnd)
		a.hwnd = nil
	}
	win.UnregisterClassW(win.utf8_to_wstring(CLASS_NAME), a.hinstance)
}

// Window procedure. Runs on the thread that created the window, either from
// our DispatchMessageW or — during the modal size/move loop, which Windows
// runs inside DefWindowProcW — from the system's own loop. That is why
// WM_TIMER renders: it is the only hook we get while the user drags the frame.
wnd_proc :: proc "system" (hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT {
	context = runtime.default_context()
	a := &app
	switch msg {
	case win.WM_SIZE:
		if wparam == win.SIZE_MINIMIZED {
			if !a.minimized {
				a.minimized = true
				log("WM_SIZE minimized: rendering paused")
			}
			return 0
		}
		w, h := i32(win.LOWORD(lparam)), i32(win.HIWORD(lparam))
		was_minimized := a.minimized
		a.minimized = false
		if w != a.width || h != a.height || was_minimized {
			a.width, a.height = w, h
			a.resize_needed = true
			if a.vk_ready { // creation-time WM_SIZEs are not "resizes"
				a.resize_events += 1
				kind := "restored"
				if wparam == win.SIZE_MAXIMIZED { kind = "maximized" }
				if a.in_size_move { kind = "dragging" }
				log("WM_SIZE %dx%d (%s)", w, h, kind)
			}
		}
		return 0

	case win.WM_DPICHANGED:
		// wParam = new DPI (both words), lParam = suggested window rect in the new DPI.
		new_dpi := u32(win.HIWORD(wparam))
		rc := (^win.RECT)(uintptr(lparam))
		log("WM_DPICHANGED %d -> %d: suggested rect %d,%d %dx%d", a.dpi, new_dpi,
			rc.left, rc.top, rc.right - rc.left, rc.bottom - rc.top)
		a.dpi = new_dpi
		win.SetWindowPos(hwnd, nil, rc.left, rc.top, rc.right - rc.left, rc.bottom - rc.top,
			win.SWP_NOZORDER | win.SWP_NOACTIVATE)
		return 0

	case win.WM_ENTERSIZEMOVE:
		a.in_size_move = true
		win.SetTimer(hwnd, RENDER_TIMER, win.USER_TIMER_MINIMUM, nil)
		log("WM_ENTERSIZEMOVE: render timer on (%d ms)", win.USER_TIMER_MINIMUM)
		return 0

	case win.WM_EXITSIZEMOVE:
		a.in_size_move = false
		win.KillTimer(hwnd, RENDER_TIMER)
		log("WM_EXITSIZEMOVE: render timer off, client %dx%d", a.width, a.height)
		return 0

	case win.WM_TIMER:
		if wparam == RENDER_TIMER {
			render_frame(a)
			return 0
		}

	case win.WM_PAINT:
		// Vulkan owns the client area; just tell USER the region is valid or
		// WM_PAINT keeps coming back and the idle loop never idles.
		win.ValidateRect(hwnd, nil)
		return 0

	case win.WM_GETMINMAXINFO:
		mmi := (^win.MINMAXINFO)(uintptr(lparam))
		mmi.ptMinTrackSize = {160, 120}
		return 0

	case win.WM_KEYDOWN:
		if wparam == win.VK_ESCAPE {
			win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0)
			return 0
		}

	case win.WM_CLOSE:
		if a.exit_reason == "" { a.exit_reason = "WM_CLOSE" }
		win.DestroyWindow(hwnd)
		return 0

	case win.WM_DESTROY:
		a.hwnd = nil
		win.PostQuitMessage(0)
		return 0
	}
	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}

// Drains the queue. Returns false once WM_QUIT has been seen.
win_pump_messages :: proc(a: ^App) -> bool {
	msg: win.MSG
	for win.PeekMessageW(&msg, nil, 0, 0, win.PM_REMOVE) {
		if msg.message == win.WM_QUIT {
			if a.exit_reason == "" { a.exit_reason = "WM_QUIT" }
			return false
		}
		win.TranslateMessage(&msg)
		win.DispatchMessageW(&msg)
	}
	return true
}

// Blocks until a message arrives or `timeout_ms` passes (-1 = forever). No
// handles yet; the real platform layer will put its wake event / IOCP here.
win_wait_messages :: proc(timeout_ms: i32) {
	timeout := win.INFINITE if timeout_ms < 0 else u32(timeout_ms)
	MsgWaitForMultipleObjectsEx(0, nil, timeout, win.QS_ALLINPUT, MWMO_INPUTAVAILABLE)
}
