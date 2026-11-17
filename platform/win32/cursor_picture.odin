#+build windows
package win32

// A cursor the app drew: a brush's outline following the pointer in an
// image editor, rather than one of the desktop's shapes.
//
// Windows takes a cursor as an icon: a colour bitmap and a mask. The colour
// bitmap is a top-down 32-bit DIB section in BGRA (the toolkit's RGBA with
// red and blue swapped), with straight alpha. The mask is required even so,
// and is all zeros: with a colour bitmap that carries alpha it only has to
// not veto anything.
//
// The scale the contract carries is not used: a Windows cursor is device
// pixels and nothing else, so a 2x picture on a 2x screen is already the
// right size, and the hotspot (in the picture's own pixels) goes straight
// through rather than being divided as it is on Wayland.

import win "core:sys/windows"
import "baldr:platform"

// CURSOR_MAX bounds what will be turned into a cursor. Windows would take a
// larger one, but a cursor is composited on every pointer move, and a
// picture this big is a mistake to report rather than honour.
@(private = "file") CURSOR_MAX :: 512

// surface_set_cursor_image makes `s`'s pointer a picture the app drew
// (Backend.surface_set_cursor_image). It is the cursor until
// surface_set_cursor gives a shape.
@(private)
surface_set_cursor_image :: proc(b: ^platform.Backend, id: platform.Surface, pixels: []u8, size: [2]i32, hotspot: [2]i32, scale: f32) {
	w := data(b)
	s := get_surface(w, id)
	if s == nil do return
	if size.x <= 0 || size.y <= 0 || size.x > CURSOR_MAX || size.y > CURSOR_MAX {
		debugf(w, "cursor picture %dx%d: not a size a cursor can be", size.x, size.y)
		return
	}
	if len(pixels) < int(size.x) * int(size.y) * 4 {
		debugf(w, "cursor picture %dx%d: %d bytes is short of the %d it needs", size.x, size.y, len(pixels), int(size.x) * int(size.y) * 4)
		return
	}
	cur := cursor_from_pixels(w, pixels, size, hotspot)
	if cur == nil do return
	cursor_picture_drop(s)
	s.cursor_pic = cur
	if s.pointer_inside {
		win.SetCursor(cur)
		// Read it back: SetCursor can be accepted and do nothing (the thread
		// has to own the pointer), which without a visible pointer shows
		// nowhere else.
		debugf(w, "cursor picture %dx%d hotspot %d,%d -> icon %p, and the thread's cursor is now %p",
			size.x, size.y, hotspot.x, hotspot.y, rawptr(cur), rawptr(GetCursor()))
	} else {
		debugf(w, "cursor picture %dx%d hotspot %d,%d -> icon %p (the pointer is not over this surface yet)",
			size.x, size.y, hotspot.x, hotspot.y, rawptr(cur))
	}
}

// cursor_from_pixels builds the icon. nil when GDI would not give us one.
@(private = "file")
cursor_from_pixels :: proc(w: ^Win32, pixels: []u8, size: [2]i32, hotspot: [2]i32) -> win.HCURSOR {
	bi: win.BITMAPINFO
	bi.bmiHeader = {
		biSize        = size_of(win.BITMAPINFOHEADER),
		biWidth       = size.x,
		biHeight      = -size.y, // negative: top-down, the order the toolkit hands them over in
		biPlanes      = 1,
		biBitCount    = 32,
		biCompression = win.BI_RGB,
	}
	bits: win.PVOID
	dc := win.GetDC(nil)
	colour := win.CreateDIBSection(dc, &bi, win.DIB_RGB_COLORS, &bits, nil, 0)
	win.ReleaseDC(nil, dc)
	if colour == nil || bits == nil {
		debugf(w, "cursor picture: CreateDIBSection would not (error %d)", u32(win.GetLastError()))
		if colour != nil do win.DeleteObject(win.HGDIOBJ(colour))
		return nil
	}

	n := int(size.x) * int(size.y)
	rgba_to_bgra(([^]u8)(bits)[:n * 4], pixels[:n * 4])

	// The mask is required but has nothing to say: zeros everywhere, so the
	// colour bitmap's own alpha decides every pixel.
	mask := win.CreateBitmap(size.x, size.y, 1, 1, nil)
	if mask == nil {
		win.DeleteObject(win.HGDIOBJ(colour))
		return nil
	}

	info := win.ICONINFO{
		fIcon    = false, // a cursor, which is what makes the hotspot mean anything
		xHotspot = win.DWORD(clamp(hotspot.x, 0, size.x - 1)),
		yHotspot = win.DWORD(clamp(hotspot.y, 0, size.y - 1)),
		hbmMask  = mask,
		hbmColor = colour,
	}
	cur := win.CreateIconIndirect(&info)
	// CreateIconIndirect copies both bitmaps, so ours go now either way.
	win.DeleteObject(win.HGDIOBJ(colour))
	win.DeleteObject(win.HGDIOBJ(mask))
	if cur == nil do debugf(w, "cursor picture: CreateIconIndirect would not (error %d)", u32(win.GetLastError()))
	return win.HCURSOR(cur)
}

// rgba_to_bgra swaps red and blue into the order GDI wants and leaves the
// alpha straight: Windows composites a 32-bit icon from the alpha itself,
// so premultiplying would give every soft edge a dark rim.
@(private)
rgba_to_bgra :: proc(dst, src: []u8) {
	n := min(len(dst), len(src)) / 4
	for i in 0 ..< n {
		dst[i * 4 + 0] = src[i * 4 + 2]
		dst[i * 4 + 1] = src[i * 4 + 1]
		dst[i * 4 + 2] = src[i * 4 + 0]
		dst[i * 4 + 3] = src[i * 4 + 3]
	}
}

// cursor_picture_drop destroys the surface's picture, if it has one. Safe to
// call when it does not.
@(private)
cursor_picture_drop :: proc(s: ^Surface) {
	if s.cursor_pic == nil do return
	// Never while it is the one on screen: set the shape back first, or
	// Windows is left drawing a handle that has gone.
	if s.pointer_inside && GetCursor() == s.cursor_pic do win.SetCursor(s.w.cursors[s.cursor])
	win.DestroyIcon(win.HICON(s.cursor_pic))
	s.cursor_pic = nil
}

// cursor_of is the cursor this surface should be showing: its picture while
// it has one, else the shape it asked for.
@(private)
cursor_of :: proc(s: ^Surface) -> win.HCURSOR {
	return s.cursor_pic if s.cursor_pic != nil else s.w.cursors[s.cursor]
}
