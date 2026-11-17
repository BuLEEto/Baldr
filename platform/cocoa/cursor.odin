#+build darwin
package cocoa

// The pointer's shape (Backend.surface_set_cursor) and an app-drawn
// picture for it (Backend.surface_set_cursor_image).
//
// AppKit's way in is cursor rects, not a call that sets the pointer: a view
// declares the cursor over its parts in `resetCursorRects`, and AppKit asks
// again when it needs to. That suits this backend, whose view swallows mouse
// events (`pump` reads the queue instead) and so has nowhere to re-apply a
// cursor by hand. A new shape invalidates the rects and AppKit comes back
// for it.
//
// The diagonal resize cursors and a busy pointer exist only as private
// methods or as something the system draws itself (the beachball), so they
// fall back rather than use a selector an update can remove: the diagonals
// to the nearest straight resize, Wait and Progress to the arrow.

import NS "vendor:darwin/AppKit"
import ObjC "core:sys/darwin/ObjectiveC"
import "base:intrinsics"
import "baldr:platform"

@(private, objc_class = "NSCursor")          Cur_Cursor :: struct { using _: NS.Object }
@(private, objc_class = "NSImage")           Cur_Image  :: struct { using _: NS.Object }
@(private, objc_class = "NSBitmapImageRep")  Cur_Rep    :: struct { using _: NS.Object }

// NSBitmapImageRep's spelling of "RGBA, straight alpha".
@(private) NS_DEVICE_RGB :: "NSDeviceRGBColorSpace"
@(private) NS_ALPHA_NON_PREMULTIPLIED :: NS.UInteger(1 << 1) // NSBitmapFormatAlphaNonpremultiplied

@(private)
b_surface_set_cursor :: proc(b: ^platform.Backend, id: platform.Surface, cur: platform.Cursor) {
	c := self(b)
	s := find(c, id)
	if s == nil do return
	// Hidden is not a shape: AppKit hides the pointer for the whole app,
	// and it is reference counted, so it is only ever asked once per change.
	if (cur == .Hidden) != s.cursor_hidden {
		s.cursor_hidden = cur == .Hidden
		if s.cursor_hidden {
			intrinsics.objc_send(nil, Cur_Cursor, "hide")
		} else {
			intrinsics.objc_send(nil, Cur_Cursor, "unhide")
		}
	}
	if cur == .Hidden do return
	cursor_hold(c, s, shape_cursor(cur))
}

@(private)
b_surface_set_cursor_image :: proc(b: ^platform.Backend, id: platform.Surface, pixels: []u8,
	size: [2]i32, hotspot: [2]i32, scale: f32) {
	c := self(b)
	s := find(c, id)
	if s == nil do return
	if size.x <= 0 || size.y <= 0 || len(pixels) < int(size.x) * int(size.y) * 4 do return
	sc := scale if scale > 0 else 1

	img := ns_image_from_rgba(pixels, size, sc)
	if img == nil do return
	defer intrinsics.objc_send(nil, img, "release")

	// The hotspot is in points, like the image's size.
	hot := NS.Point{NS.Float(f32(hotspot.x) / sc), NS.Float(f32(hotspot.y) / sc)}
	cur := intrinsics.objc_send(^Cur_Cursor, Cur_Cursor, "alloc")
	cur = intrinsics.objc_send(^Cur_Cursor, cur, "initWithImage:hotSpot:", img, hot)
	if cur == nil do return
	cursor_hold(c, s, cur, owned = true)
}

// ns_image_from_rgba is an NSImage from the pixels the toolkit hands over:
// RGBA8, straight alpha, row-major, in device pixels, as for both the
// picture cursor and a drag's picture (platform.odin). The NSImage is sized
// in points, so a 2× picture is the same size on screen as a 1× one, only
// sharper.
@(private)
ns_image_from_rgba :: proc(pixels: []u8, size: [2]i32, scale: f32) -> ^Cur_Image {
	if size.x <= 0 || size.y <= 0 || len(pixels) < int(size.x) * int(size.y) * 4 do return nil
	sc := scale if scale > 0 else 1

	// Straight alpha, said so rather than left to NSBitmapImageRep's default
	// (premultiplied), which would darken every soft edge.
	planes := [1]rawptr{raw_data(pixels)}
	cs := ns_str(NS_DEVICE_RGB)
	defer cs->release()
	rep := intrinsics.objc_send(^Cur_Rep, Cur_Rep, "alloc")
	rep = intrinsics.objc_send(^Cur_Rep, rep,
		"initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bitmapFormat:bytesPerRow:bitsPerPixel:",
		&planes[0], NS.Integer(size.x), NS.Integer(size.y), NS.Integer(8), NS.Integer(4),
		NS.BOOL(true), NS.BOOL(false), cs,
		NS_ALPHA_NON_PREMULTIPLIED, NS.Integer(size.x * 4), NS.Integer(32))
	if rep == nil do return nil
	defer intrinsics.objc_send(nil, rep, "release")

	pts := NS.Size{NS.Float(f32(size.x) / sc), NS.Float(f32(size.y) / sc)}
	img := intrinsics.objc_send(^Cur_Image, Cur_Image, "alloc")
	img = intrinsics.objc_send(^Cur_Image, img, "initWithSize:", pts)
	if img == nil do return nil
	intrinsics.objc_send(nil, img, "addRepresentation:", rep)
	return img
}

// cursor_hold keeps the cursor this surface wants and asks AppKit to come
// back for it. `owned` is a cursor we allocated (a picture) and must
// release; the shape cursors are AppKit's shared ones and must not be.
@(private = "file")
cursor_hold :: proc(c: ^Cocoa, s: ^Surface, cur: ^Cur_Cursor, owned := false) {
	if cur == nil do return
	if s.cursor_owned && s.cursor != nil do intrinsics.objc_send(nil, s.cursor, "release")
	s.cursor, s.cursor_owned = cur, owned
	if s.win != nil && s.view != nil {
		intrinsics.objc_send(nil, s.win, "invalidateCursorRectsForView:", s.view)
	}
}

// cursor_release drops a picture cursor a surface owned (it going away).
@(private)
cursor_release :: proc(s: ^Surface) {
	if s.cursor_owned && s.cursor != nil do intrinsics.objc_send(nil, s.cursor, "release")
	s.cursor, s.cursor_owned = nil, false
	if s.cursor_hidden {
		s.cursor_hidden = false
		intrinsics.objc_send(nil, Cur_Cursor, "unhide")
	}
}

// v_reset_cursor_rects is AppKit asking the view what the pointer should be
// over it. Added to the view's class in view.odin.
@(private)
v_reset_cursor_rects :: proc "c" (self: ObjC.id, cmd: ObjC.SEL) {
	s := surface_of(self)
	if s == nil || s.cursor == nil do return
	context = s.cocoa.ctx
	v := cast(^NS.View)self
	bounds := intrinsics.objc_send(NS.Rect, v, "bounds")
	intrinsics.objc_send(nil, v, "addCursorRect:cursor:", bounds, s.cursor)
}

// shape_cursor is AppKit's shared cursor for one of the toolkit's shapes.
@(private = "file")
shape_cursor :: proc(cur: platform.Cursor) -> ^Cur_Cursor {
	sel: cstring
	switch cur {
	case .Default, .Picture:   sel = "arrowCursor"
	case .Pointer:             sel = "pointingHandCursor"
	case .Text:                sel = "IBeamCursor"
	case .Crosshair:           sel = "crosshairCursor"
	case .Move:                sel = "closedHandCursor" // AppKit has no "move": a held thing is the nearest
	case .Not_Allowed:         sel = "operationNotAllowedCursor"
	case .Grab:                sel = "openHandCursor"
	case .Grabbing:            sel = "closedHandCursor"
	case .Resize_NS:           sel = "resizeUpDownCursor"
	case .Resize_EW:           sel = "resizeLeftRightCursor"
	// No public diagonal: the nearest straight one says "this edge resizes"
	// without reaching for a private selector that an update can take away.
	case .Resize_NESW:         sel = "resizeLeftRightCursor"
	case .Resize_NWSE:         sel = "resizeLeftRightCursor"
	// The beachball is the system's to show, never an app's to ask for.
	case .Wait, .Progress:     sel = "arrowCursor"
	case .Help:                sel = "arrowCursor" // AppKit publishes no help cursor
	case .Hidden:              sel = "arrowCursor" // handled before this is reached
	}
	return cursor_named(sel)
}

@(private = "file")
cursor_named :: proc(sel: cstring) -> ^Cur_Cursor {
	// objc_send wants a literal selector, so the shared cursors are listed
	// rather than looked up by the name above.
	switch sel {
	case "pointingHandCursor":       return intrinsics.objc_send(^Cur_Cursor, Cur_Cursor, "pointingHandCursor")
	case "IBeamCursor":              return intrinsics.objc_send(^Cur_Cursor, Cur_Cursor, "IBeamCursor")
	case "crosshairCursor":          return intrinsics.objc_send(^Cur_Cursor, Cur_Cursor, "crosshairCursor")
	case "operationNotAllowedCursor":return intrinsics.objc_send(^Cur_Cursor, Cur_Cursor, "operationNotAllowedCursor")
	case "openHandCursor":           return intrinsics.objc_send(^Cur_Cursor, Cur_Cursor, "openHandCursor")
	case "closedHandCursor":         return intrinsics.objc_send(^Cur_Cursor, Cur_Cursor, "closedHandCursor")
	case "resizeUpDownCursor":       return intrinsics.objc_send(^Cur_Cursor, Cur_Cursor, "resizeUpDownCursor")
	case "resizeLeftRightCursor":    return intrinsics.objc_send(^Cur_Cursor, Cur_Cursor, "resizeLeftRightCursor")
	}
	return intrinsics.objc_send(^Cur_Cursor, Cur_Cursor, "arrowCursor")
}
