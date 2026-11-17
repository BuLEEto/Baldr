#+build linux
package x11

// Cursor shapes, through libxcb-cursor.
//
// X has no cursor-shape protocol: a cursor is a server-side resource a
// client makes and hands to a window, and the shapes come from the cursor
// theme on disk. libxcb-cursor reads the theme (Xcursor files, `Inherits`,
// XCURSOR_THEME, XCURSOR_SIZE) and is loaded at runtime like every other X
// library here.
//
// The names are the freedesktop cursor-spec ones, the same Wayland's
// cursor-shape protocol uses. A theme lacking one falls back to the older X
// names ("xterm" for "text"), then to the core cursor font.
//
// Without the library every pointer is the default arrow, and the log says
// so: text fields without an I-beam look broken.

import "core:dynlib"
import "core:strings"
import "baldr:platform"

Cursor_Api :: struct {
	context_new:  proc "c" (conn: Connection, screen: ^Screen, ctx: ^rawptr) -> i32,
	context_free: proc "c" (ctx: rawptr),
	load_cursor:  proc "c" (ctx: rawptr, name: cstring) -> Cursor_Id,
}

@(private) cursor_api: Cursor_Api
@(private = "file") cursor_lib: dynlib.Library

// cursor_start loads the library and makes a context for this screen.
@(private)
cursor_start :: proc(x: ^X11) -> bool {
	l, lok := dynlib.load_library("libxcb-cursor.so.0")
	if !lok {
		debugf(x, "libxcb-cursor unavailable: every pointer will be the default arrow")
		return false
	}
	cursor_lib = l
	a := &cursor_api
	miss := make([dynamic]string, context.temp_allocator)
	a.context_new  = cursor_sym("xcb_cursor_context_new",  type_of(a.context_new), &miss)
	a.context_free = cursor_sym("xcb_cursor_context_free", type_of(a.context_free), &miss)
	a.load_cursor  = cursor_sym("xcb_cursor_load_cursor",  type_of(a.load_cursor), &miss)
	if len(miss) > 0 {
		debugf(x, "libxcb-cursor is missing %v: every pointer will be the default arrow", miss[:])
		return false
	}
	if a.context_new(x.conn, x.screen, &x.cursor_ctx) < 0 || x.cursor_ctx == nil {
		debugf(x, "no cursor theme could be opened; falling back to the core cursor font")
		x.cursor_ctx = nil
	}
	// Load the two every app uses now: it warms the cache and logs whether
	// this desktop has a usable cursor theme at all.
	debugf(x, "cursors: Default -> %d, Pointer -> %d%s",
		u32(cursor_for(x, .Default)), u32(cursor_for(x, .Pointer)),
		"" if x.cursor_ctx != nil else " (core font: this desktop names no Xcursor theme)")
	return true
}

@(private)
cursor_stop :: proc(x: ^X11) {
	// The cursors themselves are the server's and go with the connection.
	if x.cursor_ctx != nil && cursor_api.context_free != nil {
		cursor_api.context_free(x.cursor_ctx)
		x.cursor_ctx = nil
	}
	if cursor_lib != nil {
		dynlib.unload_library(cursor_lib)
		cursor_lib = nil
	}
	delete(x.cursors)
	x.cursors = nil
}

@(private = "file")
cursor_sym :: proc($name: string, $T: typeid, miss: ^[dynamic]string) -> T {
	p, ok := dynlib.symbol_address(cursor_lib, name)
	if !ok {
		append(miss, name)
		return nil
	}
	return (T)(p)
}

// surface_set_cursor gives `s`'s pointer a shape (Backend.surface_set_cursor).
@(private)
surface_set_cursor :: proc(b: ^platform.Backend, id: platform.Surface, c: platform.Cursor) {
	x := data(b)
	ss := get_surface(x, id)
	if ss == nil do return
	// A shape replaces a picture, as the contract says.
	had_picture := ss.cursor_pic != Cursor_Id(0)
	if ss.cursor == c && !had_picture do return
	ss.cursor = c
	cursor_picture_drop(x, ss)
	apply_cursor(x, ss)
}

@(private)
apply_cursor :: proc(x: ^X11, s: ^Surface) {
	cur := cursor_for(x, s.cursor)
	// Cursor_Id(0) is XCB_CURSOR_NONE, "inherit the parent's". It does not
	// hide the pointer; Hidden needs an empty cursor (empty_cursor).
	vals := [1]u32{u32(cur)}
	api.change_window_attributes(x.conn, s.window, CW_CURSOR, raw_data(vals[:]))
	api.flush(x.conn)
}

// cursor_for loads a shape once and remembers it: every load reads files
// off disk, and a pointer moving between a button and a text field would
// otherwise do that on every crossing.
@(private = "file")
cursor_for :: proc(x: ^X11, c: platform.Cursor) -> Cursor_Id {
	if got, had := x.cursors[c]; had do return got
	if x.cursors == nil do x.cursors = make(map[platform.Cursor]Cursor_Id, 8, x.allocator)
	// Hidden is not a shape any theme has, and it must not fall through to
	// "inherit the parent's", which would leave the arrow showing.
	if c == .Hidden {
		id := empty_cursor(x)
		x.cursors[c] = id
		return id
	}
	if x.cursor_ctx == nil do return Cursor_Id(0)

	id := Cursor_Id(0)
	if x.cursor_ctx != nil {
		for name in platform.cursor_theme_names(c) {
			if name == "" do continue
			n := strings.clone_to_cstring(name, context.temp_allocator)
			if got := cursor_api.load_cursor(x.cursor_ctx, n); got != Cursor_Id(0) {
				id = got
				break
			}
		}
	}
	// No theme, or a theme without this shape: fall back to the core
	// `cursor` font. Desktops with no Xcursor theme are common, and cursor 0
	// means "inherit the parent's", so the pointer would never change shape.
	if id == Cursor_Id(0) do id = glyph_cursor(x, cursor_glyph(c))
	x.cursors[c] = id
	if id == Cursor_Id(0) {
		debugf(x, "no cursor in this theme for %v (tried %v)", c, platform.cursor_theme_names(c))
	} else {
		debugf(x, "cursor %v -> theme cursor %d", c, u32(id))
	}
	return id
}

// empty_cursor makes a 1x1 fully transparent cursor, which is how a pointer
// is hidden on X: there is no "show nothing", only a cursor with nothing in
// it. The pixmap is depth 1 and never drawn into, so every bit is 0 — no
// source, no mask, nothing on screen.
@(private = "file")
empty_cursor :: proc(x: ^X11) -> Cursor_Id {
	if x.screen == nil || api.create_pixmap == nil do return Cursor_Id(0)
	pix := Pixmap(api.generate_id(x.conn))
	api.create_pixmap(x.conn, 1, pix, x.screen.root, 1, 1)
	cur := Cursor_Id(api.generate_id(x.conn))
	api.create_cursor(x.conn, cur, pix, pix, 0, 0, 0, 0, 0, 0, 0, 0)
	api.free_pixmap(x.conn, pix) // the cursor holds what it needs
	api.flush(x.conn)
	debugf(x, "an empty cursor for Hidden: %d", u32(cur))
	return cur
}

// cursor_glyph is the core cursor font's character for a shape
// (X11/cursorfont.h). The mask is always the character after it.
@(private = "file")
cursor_glyph :: proc(c: platform.Cursor) -> u16 {
	switch c {
	case .Default:     return 68  // XC_left_ptr
	case .Pointer:     return 60  // XC_hand2
	case .Text:        return 152 // XC_xterm
	case .Crosshair:   return 34  // XC_crosshair
	case .Move:        return 52  // XC_fleur
	case .Not_Allowed: return 24  // XC_circle, the nearest the old font has
	case .Grab:        return 58  // XC_hand1
	case .Grabbing:    return 60  // XC_hand2: the font has no closed hand
	case .Resize_NS:   return 116 // XC_sb_v_double_arrow
	case .Resize_EW:   return 108 // XC_sb_h_double_arrow
	case .Resize_NESW: return 12  // XC_bottom_left_corner
	case .Resize_NWSE: return 14  // XC_bottom_right_corner
	case .Wait:        return 150 // XC_watch
	case .Progress:    return 150 // …the old font has no busy-pointer either
	case .Help:        return 92  // XC_question_arrow
	case .Hidden:      return 68  // handled by an empty cursor, never by a glyph
	case .Picture:     return 68
	}
	return 68
}

// glyph_cursor makes a cursor from the core font, opening it once.
@(private = "file")
glyph_cursor :: proc(x: ^X11, glyph: u16) -> Cursor_Id {
	if api.create_glyph_cursor == nil do return Cursor_Id(0)
	if x.cursor_font == Font(0) {
		x.cursor_font = Font(api.generate_id(x.conn))
		name := "cursor"
		api.open_font(x.conn, x.cursor_font, u16(len(name)), cstring(raw_data(name)))
	}
	cur := Cursor_Id(api.generate_id(x.conn))
	// Black on white, which is what the font's shapes are drawn for.
	api.create_glyph_cursor(x.conn, cur, x.cursor_font, x.cursor_font, glyph, glyph + 1,
		0, 0, 0, 0xffff, 0xffff, 0xffff)
	return cur
}
