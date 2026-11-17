#+build windows
package win32

// The tray on Windows: `Shell_NotifyIconW` for the icon and a popup menu
// built with `TrackPopupMenu`.
//
// The menu is ours to build, so a checkmark is a checkmark and a disabled
// item is grey, with nothing negotiated over a bus.
//
// The icon hangs off the message-only window `wake` uses, as the
// notification balloon does, so a tray-resident app needs no window at all.
// Windows puts a new icon in the overflow flyout until someone pins it.
//
// An icon that could not be made is refused: the shell takes an entry with
// no icon, returns TRUE and shows nothing, and the app would believe it was
// in the tray for ever.
//
// The shell can restart: Explorer coming back takes every tray icon with it
// and announces itself with a registered message, so the icon is added
// again when that arrives. An app hears `.Hosted` either way.

import "base:runtime"
import "core:mem/virtual"
import "core:strings"
import win "core:sys/windows"
import "baldr:platform"

// WM_APP_TRAY is the icon's callback message. +1 is `wake`, +2 the balloon.
@(private)
WM_APP_TRAY_MSG :: win.WM_APP + 3

@(private = "file") TPM_RIGHTBUTTON :: 0x0002
@(private = "file") MF_STRING      :: 0x00000000
@(private = "file") MF_ENABLED     :: 0x00000000
@(private = "file") MF_UNCHECKED   :: 0x00000000

// Tray_Entry is one icon this backend has in the notification area, with
// the menu it shows when asked.
Tray_Entry :: struct {
	tag:   u64,
	uid:   win.UINT,
	icon:  win.HICON,          // ours to destroy when it is replaced
	desc:  platform.Tray_Desc, // the menu, kept for when it is asked for
	mem:   virtual.Arena,
	added: bool,
}

@(private)
tray_set :: proc(b: ^platform.Backend, d: platform.Tray_Desc) -> bool {
	w := (^Win32)(b.data)
	if w.wake_hwnd == nil do return false
	i := -1
	for e, j in w.tray do if e.tag == d.tag do i = j
	if i < 0 {
		w.next_tray_uid += 1
		append(&w.tray, Tray_Entry{tag = d.tag, uid = w.next_tray_uid})
		i = len(w.tray) - 1
		if err := virtual.arena_init_growing(&w.tray[i].mem); err != nil {
			pop(&w.tray)
			return false
		}
	}
	e := &w.tray[i]

	// The description is kept whole: the menu is not built until the person
	// asks for it, and by then the app may have moved on.
	virtual.arena_free_all(&e.mem)
	e.desc = tray_clone(d, virtual.arena_allocator(&e.mem))

	old_icon := e.icon
	e.icon = tray_icon(d.icon)
	// No icon, no tray item: the shell would accept it and show nothing.
	if e.icon == nil {
		if old_icon != nil do win.DestroyIcon(old_icon)
		virtual.arena_destroy(&e.mem)
		ordered_remove(&w.tray, i)
		return false
	}

	nid: win.NOTIFYICONDATAW
	nid.cbSize = size_of(win.NOTIFYICONDATAW)
	nid.hWnd = w.wake_hwnd
	nid.uID = e.uid
	nid.uFlags = win.NIF_MESSAGE | win.NIF_TIP | win.NIF_ICON
	nid.uCallbackMessage = WM_APP_TRAY_MSG
	nid.hIcon = e.icon
	// szTip is 128 wide characters; wide_into truncates rather than running
	// past the end, which a tooltip is never worth.
	wide_into(nid.szTip[:], d.tooltip if len(d.tooltip) > 0 else d.title)

	ok := win.Shell_NotifyIconW(win.NIM_MODIFY if e.added else win.NIM_ADD, &nid) != win.FALSE
	if !ok && e.added {
		// The shell lost it (it restarted, or an icon was removed under us):
		// add it again rather than leaving the app with nothing.
		ok = win.Shell_NotifyIconW(win.NIM_ADD, &nid) != win.FALSE
	}
	if old_icon != nil && old_icon != e.icon do win.DestroyIcon(old_icon)
	if !ok {
		if e.icon != nil do win.DestroyIcon(e.icon)
		virtual.arena_destroy(&e.mem)
		ordered_remove(&w.tray, i)
		return false
	}
	if !e.added {
		e.added = true
		append(&w.queue, platform.Ev_Tray{tag = d.tag, kind = .Hosted})
	}
	return true
}

@(private)
tray_remove :: proc(b: ^platform.Backend, tag: u64) {
	w := (^Win32)(b.data)
	for &e, i in w.tray {
		if e.tag != tag do continue
		nid: win.NOTIFYICONDATAW
		nid.cbSize = size_of(win.NOTIFYICONDATAW)
		nid.hWnd = w.wake_hwnd
		nid.uID = e.uid
		win.Shell_NotifyIconW(win.NIM_DELETE, &nid)
		if e.icon != nil do win.DestroyIcon(e.icon)
		virtual.arena_destroy(&e.mem)
		ordered_remove(&w.tray, i)
		return
	}
}

// tray_shutdown takes every icon out of the notification area; one left
// behind stays as a ghost until the pointer brushes it.
@(private)
tray_shutdown :: proc(w: ^Win32) {
	for &e in w.tray {
		nid: win.NOTIFYICONDATAW
		nid.cbSize = size_of(win.NOTIFYICONDATAW)
		nid.hWnd = w.wake_hwnd
		nid.uID = e.uid
		win.Shell_NotifyIconW(win.NIM_DELETE, &nid)
		if e.icon != nil do win.DestroyIcon(e.icon)
		virtual.arena_destroy(&e.mem)
	}
	delete(w.tray)
}

// tray_message answers the icon's callback. True when it was ours.
@(private)
tray_message :: proc(w: ^Win32, wparam: win.WPARAM, lparam: win.LPARAM) -> bool {
	uid := win.UINT(wparam)
	i := -1
	for e, j in w.tray do if e.uid == uid do i = j
	if i < 0 do return false
	e := &w.tray[i]
	switch win.UINT(lparam) {
	case win.WM_LBUTTONUP:
		append(&w.queue, platform.Ev_Tray{tag = e.tag, kind = .Clicked})
		return true
	case win.WM_RBUTTONUP, win.WM_CONTEXTMENU:
		tray_popup(w, e)
		return true
	}
	return true // ours, and nothing to do with it
}

// tray_popup shows the menu and reports what was chosen.
//
// A popup owned by a window not in the foreground does not go away when the
// person clicks elsewhere. The SetForegroundWindow before and the null
// message after are the documented way round it.
@(private = "file")
tray_popup :: proc(w: ^Win32, e: ^Tray_Entry) {
	menu := win.CreatePopupMenu()
	if menu == nil do return
	defer win.DestroyMenu(menu)
	tray_fill(menu, e.desc.menu)

	pt: win.POINT
	win.GetCursorPos(&pt)
	win.SetForegroundWindow(w.wake_hwnd)
	cmd := win.TrackPopupMenu(menu, win.UINT(win.TPM_RETURNCMD | TPM_RIGHTBUTTON), pt.x, pt.y, 0, w.wake_hwnd, nil)
	win.PostMessageW(w.wake_hwnd, win.WM_NULL, 0, 0)
	if cmd != 0 do append(&w.queue, platform.Ev_Tray{tag = e.tag, kind = .Chosen, id = u32(cmd)})
}

// tray_fill builds a descriptor's items into `menu`. Package-private so
// `tray_test.odin` can build a menu and read it back without a click.
@(private)
tray_fill :: proc(menu: win.HMENU, items: []platform.Tray_Item) {
	for it in items {
		if it.separator {
			win.AppendMenuW(menu, win.MF_SEPARATOR, 0, nil)
			continue
		}
		label := win.utf8_to_wstring(it.label, context.temp_allocator)
		if len(it.children) > 0 {
			sub := win.CreatePopupMenu()
			if sub != nil {
				tray_fill(sub, it.children)
				win.AppendMenuW(menu, MF_STRING | win.MF_POPUP, win.UINT_PTR(uintptr(sub)), label)
				continue
			}
			// No submenu to be had: the parent stands on its own, which is
			// better than an item that cannot be reached.
		}
		flags := win.UINT(MF_STRING)
		if it.disabled do flags |= win.MF_GRAYED
		if on, has := it.checked.?; has && on do flags |= win.MF_CHECKED
		win.AppendMenuW(menu, flags, win.UINT_PTR(it.id), label)
	}
}

// tray_icon turns the toolkit's pixmaps into an HICON at the size the shell
// asks for.
@(private = "file")
tray_icon :: proc(sizes: []platform.Tray_Pixmap) -> win.HICON {
	if len(sizes) == 0 do return nil
	want := int(win.GetSystemMetrics(win.SM_CXSMICON))
	if want <= 0 do want = 16
	best := sizes[0]
	for p in sizes {
		if abs(p.w - want) < abs(best.w - want) do best = p
	}
	return icon_from_argb(best.w, best.h, best.argb)
}

// icon_from_argb makes an HICON from ARGB32 words, rows top to bottom, which
// is exactly what a 32-bit top-down DIB holds, so they go across unchanged.
// nil on failure; the caller DestroyIcons it.
@(private)
icon_from_argb :: proc(w, h: int, argb: []u32) -> win.HICON {
	if w <= 0 || h <= 0 || len(argb) < w * h do return nil
	bi: win.BITMAPINFO
	bi.bmiHeader.biSize = size_of(win.BITMAPINFOHEADER)
	bi.bmiHeader.biWidth = win.LONG(w)
	bi.bmiHeader.biHeight = win.LONG(-h) // top-down, as ours are
	bi.bmiHeader.biPlanes = 1
	bi.bmiHeader.biBitCount = 32
	bi.bmiHeader.biCompression = win.BI_RGB
	bits: rawptr
	colour := win.CreateDIBSection(nil, &bi, win.DIB_RGB_COLORS, &bits, nil, 0)
	if colour == nil || bits == nil do return nil
	defer win.DeleteObject(win.HGDIOBJ(colour))
	dst := ([^]u32)(bits)[:w * h]
	copy(dst, argb[:w * h])

	// A 32-bit icon still needs a mask, and its bits must be given:
	// `CreateBitmap` with a nil pointer leaves them undefined, and ones mask
	// the icon away while `Shell_NotifyIconW` still returns TRUE. Zeroed,
	// nothing is masked and the alpha channel decides.
	stride := ((w + 31) / 32) * 4 // a 1bpp row is padded to 4 bytes
	zeros := make([]u8, stride * h, context.temp_allocator)
	mask := win.CreateBitmap(win.INT(w), win.INT(h), 1, 1, raw_data(zeros))
	if mask == nil do return nil
	defer win.DeleteObject(win.HGDIOBJ(mask))

	ii := win.ICONINFO{fIcon = win.TRUE, hbmMask = mask, hbmColor = colour}
	return win.CreateIconIndirect(&ii)
}

@(private = "file")
tray_clone :: proc(d: platform.Tray_Desc, allocator: runtime.Allocator) -> platform.Tray_Desc {
	out := d
	out.title = strings.clone(d.title, allocator)
	out.tooltip = strings.clone(d.tooltip, allocator)
	out.icon = nil // the HICON is made at once; the pixels are not kept
	out.menu = tray_clone_items(d.menu, allocator)
	return out
}

@(private = "file")
tray_clone_items :: proc(src: []platform.Tray_Item, allocator: runtime.Allocator) -> []platform.Tray_Item {
	if len(src) == 0 do return nil
	out := make([]platform.Tray_Item, len(src), allocator)
	for it, i in src {
		out[i] = it
		out[i].label = strings.clone(it.label, allocator)
		out[i].icon = nil
		out[i].children = tray_clone_items(it.children, allocator)
	}
	return out
}
