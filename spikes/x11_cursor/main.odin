// x11_cursor — what does the pointer actually look like?
//
// A screenshot does not include the cursor on Windows, and Xephyr draws one
// only while the host's own pointer is over its window, so neither shows
// more than "the backend asked for an I-beam".
//
// X can answer it properly: XFixes hands back the *current cursor's pixels*.
// So this reports what is on screen right now — its size, its hotspot, and
// enough of its ink to tell one shape from another — and a Baldr app
// hovering a text field can be checked rather than assumed.
//
//   tools/nested-x.sh start
//   BALDR_X11_DEBUG=1 tools/nested-x.sh run 04_controls
//   DISPLAY=:2 xdotool mousemove <x> <y>
//   DISPLAY=:2 build/x11_cursor
package main

import "core:c"
import "core:dynlib"
import "core:fmt"
import "core:os"
import x11 "baldr:platform/x11"

Xfixes_Api :: struct {
	query_version:       proc "c" (conn: x11.Connection, major, minor: u32) -> Version_Cookie,
	query_version_reply: proc "c" (conn: x11.Connection, ck: Version_Cookie, e: ^^x11.Generic_Error) -> rawptr,
	get_cursor_image:       proc "c" (conn: x11.Connection) -> Cursor_Cookie,
	get_cursor_image_reply: proc "c" (conn: x11.Connection, ck: Cursor_Cookie, e: ^^x11.Generic_Error) -> ^Cursor_Image_Reply,
	get_cursor_image_cursor_image: proc "c" (r: ^Cursor_Image_Reply) -> [^]u32,
}

Version_Cookie :: struct { sequence: c.uint }
Cursor_Cookie  :: struct { sequence: c.uint }

// The reply's head; the pixels follow it, ARGB one word each.
Cursor_Image_Reply :: struct {
	response_type: u8,
	pad0:          u8,
	sequence:      u16,
	length:        u32,
	x, y:          i16,
	width, height: u16,
	xhot, yhot:    u16,
	cursor_serial: u32,
	pad1:          [8]u8,
}

main :: proc() {
	if ok, missing := x11.load(); !ok {
		fmt.eprintfln("libxcb did not load: %v", missing)
		os.exit(1)
	}
	screen: c.int
	conn := x11.api.connect(nil, &screen)
	if conn == nil || x11.api.connection_has_error(conn) != 0 {
		fmt.eprintln("no X connection")
		os.exit(1)
	}
	defer x11.api.disconnect(conn)

	lib, lok := dynlib.load_library("libxcb-xfixes.so.0")
	if !lok {
		fmt.eprintln("libxcb-xfixes is not installed; the cursor cannot be read")
		os.exit(1)
	}
	a: Xfixes_Api
	sym :: proc(lib: dynlib.Library, $name: string, $T: typeid) -> T {
		p, ok := dynlib.symbol_address(lib, name)
		if !ok {
			fmt.eprintfln("libxcb-xfixes has no %s", name)
			os.exit(1)
		}
		return (T)(p)
	}
	a.query_version       = sym(lib, "xcb_xfixes_query_version",       type_of(a.query_version))
	a.query_version_reply = sym(lib, "xcb_xfixes_query_version_reply", type_of(a.query_version_reply))
	a.get_cursor_image       = sym(lib, "xcb_xfixes_get_cursor_image",       type_of(a.get_cursor_image))
	a.get_cursor_image_reply = sym(lib, "xcb_xfixes_get_cursor_image_reply", type_of(a.get_cursor_image_reply))
	a.get_cursor_image_cursor_image = sym(lib, "xcb_xfixes_get_cursor_image_cursor_image", type_of(a.get_cursor_image_cursor_image))

	// XFixes refuses everything until a version has been agreed.
	vck := a.query_version(conn, 4, 0)
	verr: ^x11.Generic_Error
	vr := a.query_version_reply(conn, vck, &verr)
	x11.free_reply(verr)
	if vr == nil {
		fmt.eprintln("this server has no XFixes")
		os.exit(1)
	}
	x11.free_reply(vr)

	ck := a.get_cursor_image(conn)
	err: ^x11.Generic_Error
	r := a.get_cursor_image_reply(conn, ck, &err)
	x11.free_reply(err)
	if r == nil {
		fmt.eprintln("no cursor image came back")
		os.exit(1)
	}
	defer x11.free_reply(r)

	w, h := int(r.width), int(r.height)
	px := a.get_cursor_image_cursor_image(r)[:w * h]
	// A digest rather than the pixels: enough to tell one shape from
	// another, and to see an alpha that was handled wrongly.
	opaque, partial, clear_px := 0, 0, 0
	var_r, var_g, var_b := 0, 0, 0
	for p in px {
		alpha := (p >> 24) & 0xff
		switch {
		case alpha == 0:    clear_px += 1
		case alpha == 0xff: opaque += 1
		case:               partial += 1
		}
		if alpha > 0 {
			var_r += int((p >> 16) & 0xff)
			var_g += int((p >> 8) & 0xff)
			var_b += int(p & 0xff)
		}
	}
	ink := opaque + partial
	fmt.printfln("cursor %dx%d at hotspot %d,%d (serial %d)", w, h, r.xhot, r.yhot, r.cursor_serial)
	fmt.printfln("  pixels: %d opaque, %d partly transparent, %d clear", opaque, partial, clear_px)
	if ink > 0 {
		fmt.printfln("  mean colour of the ink: r%d g%d b%d", var_r / ink, var_g / ink, var_b / ink)
	}
	if partial == 0 && opaque > 0 {
		fmt.println("  no soft edge at all - either the shape has none, or an alpha was lost")
	}
}
