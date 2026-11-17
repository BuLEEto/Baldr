#+build windows
package win32

// Desktop notifications on Windows, through the notification area:
// Shell_NotifyIconW with NIF_INFO, which Windows shows as a toast in the
// bottom-right corner.
//
// A notification-area balloon has no action buttons — the shell draws the
// title, the text and an icon. `actions` are ignored, and a click arrives
// as an Activated with an empty action, as a click on the body does on
// Linux. Named buttons would need the Windows App SDK's toasts (a
// registered AppUserModelID and WinRT), which this toolkit does not have.
//
// The balloon hangs off the message-only window `wake` uses, so no app
// window is disturbed, and the icon is in the notification area only while
// a notification shows.
//
// A click may never arrive: Windows may route the balloon through the
// Action Center, which can swallow NIN_BALLOONUSERCLICK. Make the
// notification informative on its own, and give the same way in from
// inside the app.
//
// A failed Shell_NotifyIconW becomes a Failed the app hears, never a
// silence and never a crash.

import "core:mem/virtual"
import "core:strings"
import win "core:sys/windows"
import "baldr:platform"

// WM_APP_NOTIFY is the balloon's callback message. WM_APP + 1 is `wake`.
@(private)
WM_APP_NOTIFY :: win.WM_APP + 2

// The shell's balloon callbacks, which core:sys/windows does not name.
@(private = "file") NIN_BALLOONSHOW      :: 0x0402
@(private = "file") NIN_BALLOONHIDE      :: 0x0403
@(private = "file") NIN_BALLOONTIMEOUT   :: 0x0404
@(private = "file") NIN_BALLOONUSERCLICK :: 0x0405

@(private = "file") NIIF_INFO    :: 0x00000001
@(private = "file") NIIF_WARNING :: 0x00000002
@(private = "file") NIIF_ERROR   :: 0x00000003

// Notif is one notification showing. `uid` is what the shell knows it by;
// `tag` is the app's own name for it.
@(private)
Notif :: struct {
	tag: u64,
	uid: win.UINT,
}

@(private = "file")
notif_find :: proc(w: ^Win32, tag: u64) -> int {
	for n, i in w.notifs do if n.tag == tag do return i
	return -1
}

@(private = "file")
notif_by_uid :: proc(w: ^Win32, uid: win.UINT) -> int {
	for n, i in w.notifs do if n.uid == uid do return i
	return -1
}

// wide_into copies `s` into a fixed WCHAR field, truncated to fit and always
// terminated. The shell truncates over-long text itself, but it does not
// promise to terminate ours. (The tray's tooltip wants it too — tray.odin.)
@(private)
wide_into :: proc(dst: []win.WCHAR, s: string) {
	for i in 0 ..< len(dst) do dst[i] = 0
	if len(s) == 0 || len(dst) == 0 do return
	src := win.utf8_to_utf16(s, context.temp_allocator)
	n := min(len(src), len(dst) - 1) // room for the terminator
	for i in 0 ..< n do dst[i] = src[i]
}

// notify shows `d`, or replaces what this tag is showing
// (Backend.notify).
@(private)
notify :: proc(b: ^platform.Backend, d: platform.Notify_Desc) -> bool {
	w := data(b)
	if w.wake_hwnd == nil do return false

	i := notif_find(w, d.tag)
	adding := i < 0
	if adding {
		w.next_notif_uid += 1
		append(&w.notifs, Notif{tag = d.tag, uid = w.next_notif_uid})
		i = len(w.notifs) - 1
	}

	nid: win.NOTIFYICONDATAW
	nid.cbSize = size_of(win.NOTIFYICONDATAW)
	nid.hWnd = w.wake_hwnd
	nid.uID = w.notifs[i].uid
	nid.uFlags = win.NIF_INFO | win.NIF_MESSAGE | win.NIF_TIP | win.NIF_ICON
	nid.uCallbackMessage = WM_APP_NOTIFY
	// The icon is required: Windows shows a balloon only for a displayed
	// icon, and an entry with no hIcon returns TRUE and never appears. The
	// shell's default icon spares every app shipping one.
	// IDI_APPLICATION by its number: core:sys/windows declares it as a
	// `cstring`, and LoadIconW wants the wide form — a MAKEINTRESOURCE is an
	// integer in a pointer, so the width does not matter.
	if w.notify_icon == nil do w.notify_icon = win.LoadIconW(nil, transmute(win.LPCWSTR)uintptr(32512))
	nid.hIcon = w.notify_icon
	wide_into(nid.szInfoTitle[:], d.title)
	wide_into(nid.szInfo[:], d.body)
	wide_into(nid.szTip[:], d.title)
	switch d.urgency {
	case .Low:      nid.dwInfoFlags = NIIF_INFO
	case .Normal:   nid.dwInfoFlags = NIIF_INFO
	case .Critical: nid.dwInfoFlags = NIIF_WARNING
	}

	if win.Shell_NotifyIconW(win.NIM_ADD if adding else win.NIM_MODIFY, &nid) == win.FALSE {
		// A shell that refused it will refuse it again: drop the entry so a
		// later notification with this tag starts clean rather than trying
		// to modify an icon that was never added.
		ordered_remove(&w.notifs, i)
		append(&w.queue, platform.Ev_Notify{
			tag = d.tag, event = .Failed,
			error = strings.clone("the notification area would not take it", virtual.arena_allocator(&w.text)),
		})
		return true // the app was told, which is the promise
	}
	append(&w.queue, platform.Ev_Notify{tag = d.tag, event = .Shown})
	return true
}

// notify_close takes the notification back (Backend.notify_close).
@(private)
notify_close :: proc(b: ^platform.Backend, tag: u64) {
	w := data(b)
	i := notif_find(w, tag)
	if i < 0 do return
	notif_remove(w, i, .By_App)
}

// notif_remove takes the icon out and tells the app why it went.
@(private = "file")
notif_remove :: proc(w: ^Win32, i: int, reason: platform.Notify_Close_Reason) {
	if i < 0 || i >= len(w.notifs) do return
	nid: win.NOTIFYICONDATAW
	nid.cbSize = size_of(win.NOTIFYICONDATAW)
	nid.hWnd = w.wake_hwnd
	nid.uID = w.notifs[i].uid
	win.Shell_NotifyIconW(win.NIM_DELETE, &nid)
	tag := w.notifs[i].tag
	ordered_remove(&w.notifs, i)
	append(&w.queue, platform.Ev_Notify{tag = tag, event = .Closed, reason = reason})
}

// notify_message handles WM_APP_NOTIFY from the shell. Returns false when
// it was about something else. Called from the pump, before dispatch, since
// the message goes to the message-only window.
@(private)
notify_message :: proc(w: ^Win32, hwnd: win.HWND, wparam: win.WPARAM, lparam: win.LPARAM) -> bool {
	if hwnd != w.wake_hwnd do return false
	uid := win.UINT(wparam)
	i := notif_by_uid(w, uid)
	if i < 0 do return true // ours, but already finished with
	switch win.UINT(lparam) {
	case NIN_BALLOONUSERCLICK:
		// The person chose it. The icon goes now — the shell will not send
		// a timeout after a click, and leaving it would sit in the tray.
		tag := w.notifs[i].tag
		append(&w.queue, platform.Ev_Notify{tag = tag, event = .Activated})
		notif_remove(w, i, .By_App)
	case NIN_BALLOONTIMEOUT:
		// The shell uses this both when it expires and when the person
		// clicks its X, and does not say which. Dismissed is the more
		// careful reading of the two: an app must not take it for consent.
		notif_remove(w, i, .Dismissed)
	case NIN_BALLOONHIDE:
		notif_remove(w, i, .Expired)
	}
	return true
}

// notify_shutdown takes every icon out of the notification area. Without
// it they stay there as ghosts until the person waves the pointer over
// them, which is the classic Windows tray-icon leak.
@(private)
notify_shutdown :: proc(w: ^Win32) {
	for n in w.notifs {
		nid: win.NOTIFYICONDATAW
		nid.cbSize = size_of(win.NOTIFYICONDATAW)
		nid.hWnd = w.wake_hwnd
		nid.uID = n.uid
		win.Shell_NotifyIconW(win.NIM_DELETE, &nid)
	}
	delete(w.notifs)
	w.notifs = nil
}
