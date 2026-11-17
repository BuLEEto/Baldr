#+build linux
package wayland

// Cursor shapes from the desktop's cursor theme, for a compositor without
// `wp_cursor_shape_manager_v1`.
//
// With the protocol, a client names a shape and the compositor draws it.
// Without it (GNOME's Mutter, Cinnamon's Muffin) a client draws its own:
// read the theme, put the picture in shared memory and hand the compositor a
// surface. Setting no cursor there leaves the pointer in whatever shape it
// came in with.
//
// `libwayland-cursor` reads a theme (Xcursor files, the `Inherits` chain, a
// size) and gives back `wl_buffer`s. It ships with `libwayland-client` and
// is loaded at run time the same way; the X11 backend does the same with
// `libxcb-cursor` (platform/x11/cursor.odin). Without it the pointer is left
// as it was, and the log says why.
//
// The theme and size are the desktop's: the portal's `cursor-theme` and
// `cursor-size` (what GTK uses), then XCURSOR_THEME and XCURSOR_SIZE, then
// the library's default at 24. A theme is opened once per pixel size (the
// size times the surface's scale, so a 2× screen gets the 48 px pictures,
// not a stretch), and its buffers are the theme's to free. An animated
// cursor shows its first frame. `BALDR_NO_CURSOR_SHAPE=1` skips the protocol,
// to try this path on a compositor that has it.

import "core:dynlib"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "baldr:platform"
import wl "baldr:platform/wayland/wl"
import "baldr:sys/portal"

// The two structs libwayland-cursor hands back, as wayland-cursor.h
// declares them.
@(private)
Wl_Cursor_Image :: struct {
	width, height:        u32,
	hotspot_x, hotspot_y: u32,
	delay:                u32,
}

@(private)
Wl_Cursor :: struct {
	image_count: u32,
	images:      [^]^Wl_Cursor_Image,
	name:        cstring,
}

@(private)
Cursor_Theme_Api :: struct {
	theme_load:    proc "c" (name: cstring, size: i32, shm: wl.Proxy) -> rawptr,
	theme_destroy: proc "c" (theme: rawptr),
	get_cursor:    proc "c" (theme: rawptr, name: cstring) -> ^Wl_Cursor,
	image_buffer:  proc "c" (image: ^Wl_Cursor_Image) -> wl.Proxy,
}

// Cursor_Themes is the library, its procs, and the theme opened at each
// pixel size. `failed` is set once loading has been tried and could not
// work, so it is not tried on every pointer crossing.
@(private)
Cursor_Themes :: struct {
	lib:    dynlib.Library,
	api:    Cursor_Theme_Api,
	tried:  bool,
	failed: bool,
	name:   string, // the theme asked for, "" for the library's default (owned)
	size:   i32,    // logical px
	by_px:  map[i32]rawptr,
}

// theme_cursor_apply sets the pointer's cursor on `s` from the desktop's
// cursor theme. False when there is no theme to draw from: the library is
// missing, or neither the shape nor its old X name is in the theme.
@(private)
theme_cursor_apply :: proc(st: ^State, s: ^Surface_State) -> bool {
	ct := &st.cursor_themes
	if !cursor_themes_start(st) do return false
	if st.compositor == nil || st.shm == nil do return false

	scale := effective_scale(s)
	px := max(i32(math.ceil(f32(ct.size) * scale)), 1)
	theme, have := ct.by_px[px]
	if !have {
		name := strings.clone_to_cstring(ct.name, context.temp_allocator) if ct.name != "" else nil
		theme = ct.api.theme_load(name, px, st.shm)
		ct.by_px[px] = theme // nil too: a size that will not open is not asked for again
		debugf(st, "cursor theme %q at %d px: %s", ct.name if ct.name != "" else "(default)", px, "opened" if theme != nil else "could not be opened")
	}
	if theme == nil do return false

	for name in platform.cursor_theme_names(s.cursor) {
		if name == "" do continue
		cur := ct.api.get_cursor(theme, strings.clone_to_cstring(name, context.temp_allocator))
		if cur == nil || cur.image_count == 0 do continue
		img := cur.images[0]
		buf := ct.api.image_buffer(img)
		if buf == nil do continue
		if st.cursor_surface == nil do st.cursor_surface = wl.wl_compositor_create_surface(st.compositor)
		if st.cursor_viewport == nil && st.viewporter != nil do st.cursor_viewport = wl.wp_viewporter_get_viewport(st.viewporter, st.cursor_surface)
		pic := Cursor_Picture{
			buffer  = buf,
			size    = {i32(img.width), i32(img.height)},
			hotspot = {i32(img.hotspot_x), i32(img.hotspot_y)},
			scale   = f32(px) / f32(ct.size),
		}
		hot := cursor_picture_show(st, st.cursor_surface, st.cursor_viewport, pic)
		wl.wl_pointer_set_cursor(st.pointer, st.ptr_enter_serial, st.cursor_surface, hot.x, hot.y)
		wl.display_flush(st.display)
		debugf(st, "cursor on surface %d: %v from the theme as %q, %dx%d, hotspot %d,%d", s.id, s.cursor, name, img.width, img.height, hot.x, hot.y)
		return true
	}
	debugf(st, "cursor theme has no %v (tried %v)", s.cursor, platform.cursor_theme_names(s.cursor))
	return false
}

// cursor_themes_start loads libwayland-cursor and settles the theme's name
// and size, once.
@(private = "file")
cursor_themes_start :: proc(st: ^State) -> bool {
	ct := &st.cursor_themes
	if ct.tried do return !ct.failed
	ct.tried = true
	ct.failed = true

	lib, ok := dynlib.load_library("libwayland-cursor.so.0")
	if !ok {
		debugf(st, "no wp_cursor_shape_manager_v1, and libwayland-cursor is unavailable: the pointer keeps whatever shape it had")
		return false
	}
	ct.lib = lib
	missing := false
	sym :: proc(l: dynlib.Library, symbol: string, miss: ^bool) -> rawptr {
		p, found := dynlib.symbol_address(l, symbol)
		if !found do miss^ = true
		return p
	}
	ct.api.theme_load    = (type_of(ct.api.theme_load))(sym(lib, "wl_cursor_theme_load", &missing))
	ct.api.theme_destroy = (type_of(ct.api.theme_destroy))(sym(lib, "wl_cursor_theme_destroy", &missing))
	ct.api.get_cursor    = (type_of(ct.api.get_cursor))(sym(lib, "wl_cursor_theme_get_cursor", &missing))
	ct.api.image_buffer  = (type_of(ct.api.image_buffer))(sym(lib, "wl_cursor_image_get_buffer", &missing))
	if missing {
		debugf(st, "libwayland-cursor is missing a symbol: the pointer keeps whatever shape it had")
		dynlib.unload_library(lib)
		ct.lib = nil
		return false
	}

	// The desktop's choice, then the environment's, then the library's default.
	name := ""
	size := i32(0)
	if st.xdg.has_appearance {
		name = portal.appearance_cursor_theme(&st.xdg.appearance)
		size = st.xdg.appearance.cursor_size
	}
	if name == "" do name = os.get_env("XCURSOR_THEME", context.temp_allocator)
	if size <= 0 {
		if n, nok := strconv.parse_int(os.get_env("XCURSOR_SIZE", context.temp_allocator)); nok && n > 0 do size = i32(n)
	}
	ct.name = strings.clone(name, st.alloc)
	ct.size = size if size > 0 else 24
	ct.by_px = make(map[i32]rawptr, 2, st.alloc)
	ct.failed = false
	debugf(st, "no wp_cursor_shape_manager_v1: cursors come from the theme %q at %d px (libwayland-cursor)", ct.name if ct.name != "" else "(default)", ct.size)
	return true
}

// cursor_themes_shutdown frees every theme opened and the library. Their
// buffers go with them, so it runs after the cursor surface is destroyed.
@(private)
cursor_themes_shutdown :: proc(st: ^State) {
	ct := &st.cursor_themes
	for _, theme in ct.by_px do if theme != nil && ct.api.theme_destroy != nil do ct.api.theme_destroy(theme)
	delete(ct.by_px)
	delete(ct.name, st.alloc)
	if ct.lib != nil do dynlib.unload_library(ct.lib)
	ct^ = {}
}
