#+build linux
package x11

// A cursor the app drew: a brush's outline following the pointer in an
// image editor, rather than one of the desktop's shapes.
//
// Core protocol cursors are one bit deep (a shape and a mask); an ARGB
// cursor needs the Render extension, so libxcb-render is loaded here.
// Without it a drawn cursor keeps the previous shape, and the log says so.
//
// Render's ARGB32 is premultiplied, unlike a Windows icon, which composites
// from straight alpha. The toolkit hands over straight alpha and each
// backend converts for its own compositor.

import "core:dynlib"
import "baldr:platform"

@(private = "file") CURSOR_MAX :: 512
// render.h: INDEXED is 0 and DIRECT is 1, not the other way round.
@(private = "file") PICT_TYPE_INDEXED :: 0
@(private = "file") PICT_TYPE_DIRECT  :: 1

Render_Api :: struct {
	query_pict_formats:       proc "c" (conn: Connection) -> Pict_Formats_Cookie,
	query_pict_formats_reply: proc "c" (conn: Connection, ck: Pict_Formats_Cookie, e: ^^Generic_Error) -> ^Pict_Formats_Reply,
	query_pict_formats_formats: proc "c" (r: ^Pict_Formats_Reply) -> [^]Pict_Form_Info,
	create_picture: proc "c" (conn: Connection, pid: Picture, drawable: Pixmap, format: Pict_Format,
		value_mask: u32, value_list: [^]u32) -> Void_Cookie,
	free_picture:   proc "c" (conn: Connection, pid: Picture) -> Void_Cookie,
	create_cursor:  proc "c" (conn: Connection, cid: Cursor_Id, source: Picture, x, y: u16) -> Void_Cookie,
}

Picture     :: distinct u32
Pict_Format :: distinct u32

Pict_Formats_Cookie :: struct { sequence: u32 }
Pict_Formats_Reply :: struct {
	response_type:  u8,
	pad0:           u8,
	sequence:       u16,
	length:         u32,
	num_formats:    u32,
	num_screens:    u32,
	num_depths:     u32,
	num_visuals:    u32,
	num_subpixel:   u32,
	pad1:           [4]u8,
}

Direct_Format :: struct {
	red_shift, red_mask:     u16,
	green_shift, green_mask: u16,
	blue_shift, blue_mask:   u16,
	alpha_shift, alpha_mask: u16,
}

Pict_Form_Info :: struct {
	id:        Pict_Format,
	type:      u8,
	depth:     u8,
	pad0:      [2]u8,
	direct:    Direct_Format,
	colormap:  u32,
}

@(private) render: Render_Api
@(private = "file") render_lib: dynlib.Library
@(private) argb32: Pict_Format

// render_start loads libxcb-render and finds the ARGB32 picture format,
// which is the one an alpha cursor is made from.
@(private)
render_start :: proc(x: ^X11) -> bool {
	l, lok := dynlib.load_library("libxcb-render.so.0")
	if !lok {
		debugf(x, "libxcb-render unavailable: a cursor the app drew will not be shown")
		return false
	}
	render_lib = l
	a := &render
	miss := make([dynamic]string, context.temp_allocator)
	a.query_pict_formats       = render_sym("xcb_render_query_pict_formats",       type_of(a.query_pict_formats), &miss)
	a.query_pict_formats_reply = render_sym("xcb_render_query_pict_formats_reply", type_of(a.query_pict_formats_reply), &miss)
	a.query_pict_formats_formats = render_sym("xcb_render_query_pict_formats_formats", type_of(a.query_pict_formats_formats), &miss)
	a.create_picture = render_sym("xcb_render_create_picture", type_of(a.create_picture), &miss)
	a.free_picture   = render_sym("xcb_render_free_picture",   type_of(a.free_picture), &miss)
	a.create_cursor  = render_sym("xcb_render_create_cursor",  type_of(a.create_cursor), &miss)
	if len(miss) > 0 {
		debugf(x, "libxcb-render is missing %v", miss[:])
		return false
	}

	ck := a.query_pict_formats(x.conn)
	err: ^Generic_Error
	reply := a.query_pict_formats_reply(x.conn, ck, &err)
	free_reply(err)
	if reply == nil {
		debugf(x, "this server has no Render extension")
		return false
	}
	defer free_reply(reply)
	formats := a.query_pict_formats_formats(reply)
	for i in 0 ..< int(reply.num_formats) {
		f := formats[i]
		// 32 bits deep, direct colour, and eight of them alpha: ARGB32.
		if f.depth == 32 && f.type == PICT_TYPE_DIRECT && f.direct.alpha_mask == 0xff {
			argb32 = f.id
			debugf(x, "Render ARGB32 format %d", u32(argb32))
			return true
		}
	}
	debugf(x, "this server offers no ARGB32 format")
	return false
}

@(private)
render_stop :: proc() {
	if render_lib != nil {
		dynlib.unload_library(render_lib)
		render_lib = nil
	}
}

@(private = "file")
render_sym :: proc($name: string, $T: typeid, miss: ^[dynamic]string) -> T {
	p, ok := dynlib.symbol_address(render_lib, name)
	if !ok {
		append(miss, name)
		return nil
	}
	return (T)(p)
}

// surface_set_cursor_image makes `s`'s pointer a picture the app drew
// (Backend.surface_set_cursor_image). It is the cursor until
// surface_set_cursor gives a shape.
@(private)
surface_set_cursor_image :: proc(b: ^platform.Backend, id: platform.Surface, pixels: []u8, size: [2]i32, hotspot: [2]i32, scale: f32) {
	x := data(b)
	s := get_surface(x, id)
	if s == nil || argb32 == Pict_Format(0) do return
	if size.x <= 0 || size.y <= 0 || size.x > CURSOR_MAX || size.y > CURSOR_MAX {
		debugf(x, "cursor picture %dx%d: not a size a cursor can be", size.x, size.y)
		return
	}
	n := int(size.x) * int(size.y)
	if len(pixels) < n * 4 do return

	// RGBA straight -> BGRA premultiplied, which is what Render's ARGB32 is
	// and what a little-endian ZPixmap of depth 32 holds.
	buf := make([]u8, n * 4, context.temp_allocator)
	for i in 0 ..< n {
		r, g, bl, a := pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2], pixels[i * 4 + 3]
		buf[i * 4 + 0] = u8((u32(bl) * u32(a)) / 255)
		buf[i * 4 + 1] = u8((u32(g) * u32(a)) / 255)
		buf[i * 4 + 2] = u8((u32(r) * u32(a)) / 255)
		buf[i * 4 + 3] = a
	}

	pix := Pixmap(api.generate_id(x.conn))
	api.create_pixmap(x.conn, 32, pix, x.screen.root, u16(size.x), u16(size.y))
	gc := Gcontext(api.generate_id(x.conn))
	api.create_gc(x.conn, gc, pix, 0, nil)
	api.put_image(x.conn, IMAGE_FORMAT_Z_PIXMAP, pix, gc, u16(size.x), u16(size.y), 0, 0, 0, 32,
		u32(len(buf)), raw_data(buf))
	api.free_gc(x.conn, gc)

	pic := Picture(api.generate_id(x.conn))
	render.create_picture(x.conn, pic, pix, argb32, 0, nil)
	cur := Cursor_Id(api.generate_id(x.conn))
	render.create_cursor(x.conn, cur, pic,
		u16(clamp(hotspot.x, 0, size.x - 1)), u16(clamp(hotspot.y, 0, size.y - 1)))
	render.free_picture(x.conn, pic)
	api.free_pixmap(x.conn, pix) // the cursor holds what it needs

	cursor_picture_drop(x, s)
	s.cursor_pic = cur
	vals := [1]u32{u32(cur)}
	api.change_window_attributes(x.conn, s.window, CW_CURSOR, raw_data(vals[:]))
	api.flush(x.conn)
	debugf(x, "cursor picture %dx%d hotspot %d,%d -> cursor %d", size.x, size.y, hotspot.x, hotspot.y, u32(cur))
}

// cursor_picture_drop forgets a drawn cursor, so a shape set afterwards
// wins — which is what the contract says happens.
@(private)
cursor_picture_drop :: proc(x: ^X11, s: ^Surface) {
	if s.cursor_pic == Cursor_Id(0) do return
	api.free_cursor(x.conn, s.cursor_pic)
	s.cursor_pic = Cursor_Id(0)
}
