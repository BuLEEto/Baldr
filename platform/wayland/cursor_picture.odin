package wayland

// A cursor the app draws: a brush's outline as the pointer, moving with it
// rather than a frame behind. The picture goes into shared
// memory (wl_shm, ARGB8888 premultiplied, the byte order a compositor
// reads) on a surface of its own, made the pointer's cursor — and a pen's
// over the same surface, each device on its own cursor surface. Its buffer
// goes when the compositor has let go of it.

import "core:sys/linux"
import "baldr:platform"
import wl "baldr:platform/wayland/wl"

// Cursor_Picture is a cursor picture in shared memory: its buffer, its size
// in pixels, its hotspot, and its pixels per logical pixel.
@(private)
Cursor_Picture :: struct {
	buffer:  wl.Proxy,
	size:    [2]i32,
	hotspot: [2]i32,
	scale:   f32,
}

@(private)
surface_set_cursor_image :: proc(b: ^platform.Backend, s: platform.Surface, pixels: []u8, size: [2]i32, hotspot: [2]i32, scale: f32) {
	st := state(b)
	ss := lookup(st, s)
	if ss == nil || st.shm == nil || size.x <= 0 || size.y <= 0 || len(pixels) < int(size.x) * int(size.y) * 4 do return
	buf := shm_buffer(st, pixels, size)
	if buf == nil do return
	cursor_picture_drop(&ss.cursor_pic) // released by the compositor once it holds the new one
	ss.cursor_pic = {buffer = buf, size = size, hotspot = hotspot, scale = scale if scale > 0 else 1}
	ss.cursor = .Picture
	if st.ptr_focus == ss do apply_cursor(st, ss)
	for t in st.tools do if t.focus == ss do tool_apply_cursor(t)
}

// cursor_picture_apply makes the pointer's cursor the surface's picture.
@(private)
cursor_picture_apply :: proc(st: ^State, s: ^Surface_State) {
	if s.cursor_pic.buffer == nil || st.compositor == nil do return
	if st.cursor_surface == nil do st.cursor_surface = wl.wl_compositor_create_surface(st.compositor)
	if st.cursor_viewport == nil && st.viewporter != nil do st.cursor_viewport = wl.wp_viewporter_get_viewport(st.viewporter, st.cursor_surface)
	hot := cursor_picture_show(st, st.cursor_surface, st.cursor_viewport, s.cursor_pic)
	wl.wl_pointer_set_cursor(st.pointer, st.ptr_enter_serial, st.cursor_surface, hot.x, hot.y)
	wl.display_flush(st.display)
}

// cursor_picture_show puts `pic` on cursor surface `surf` at its logical
// size and returns its hotspot in logical px.
@(private)
cursor_picture_show :: proc(st: ^State, surf, viewport: wl.Proxy, pic: Cursor_Picture) -> [2]i32 {
	wl.wl_surface_attach(surf, pic.buffer, 0, 0)
	wl.wl_surface_damage_buffer(surf, 0, 0, pic.size.x, pic.size.y)
	scale := pic.scale if pic.scale > 0 else 1
	if viewport != nil {
		wl.wp_viewport_set_destination(viewport, max(i32(f32(pic.size.x) / scale + 0.5), 1), max(i32(f32(pic.size.y) / scale + 0.5), 1))
	} else if s := i32(scale + 0.5); s >= 1 {
		wl.wl_surface_set_buffer_scale(surf, s)
	}
	wl.wl_surface_commit(surf)
	return {i32(f32(pic.hotspot.x) / scale), i32(f32(pic.hotspot.y) / scale)}
}

// cursor_picture_drop lets a picture's buffer go: destroyed as soon as the
// compositor releases it (at once if it never held it).
@(private)
cursor_picture_drop :: proc(pic: ^Cursor_Picture) {
	if pic.buffer == nil do return
	@(static) release_l: wl.Wl_Buffer_Listener
	release_l.release = proc "c" (data: rawptr, buffer: wl.Proxy) { wl.wl_buffer_destroy(buffer) }
	wl.wl_buffer_add_listener(pic.buffer, &release_l, nil)
	pic^ = {}
}

@(private)
cursor_picture_shutdown :: proc(st: ^State) {
	for s in st.surfaces do if s != nil do cursor_picture_drop(&s.cursor_pic)
	if st.cursor_viewport != nil { wl.wp_viewport_destroy(st.cursor_viewport); st.cursor_viewport = nil }
	if st.cursor_surface != nil { wl.wl_surface_destroy(st.cursor_surface); st.cursor_surface = nil }
	if st.shm != nil { wl.proxy_destroy(st.shm); st.shm = nil } // version 1 has no request for it: the proxy goes on our side
}

// shm_buffer copies RGBA8 straight-alpha `pixels` into a new shared-memory
// buffer as ARGB8888 premultiplied (bytes B, G, R, A). nil on failure.
@(private)
shm_buffer :: proc(st: ^State, pixels: []u8, size: [2]i32) -> wl.Proxy {
	bytes := int(size.x) * int(size.y) * 4
	fd, err := linux.memfd_create("baldr-cursor", {.CLOEXEC})
	if err != nil do return nil
	defer linux.close(fd)
	if linux.ftruncate(fd, i64(bytes)) != nil do return nil
	mem, merr := linux.mmap(0, uint(bytes), {.READ, .WRITE}, {.SHARED}, fd, 0)
	if merr != nil do return nil
	out := ([^]u8)(mem)[:bytes]
	for i in 0 ..< int(size.x) * int(size.y) {
		r, g, b, a := u32(pixels[i * 4]), u32(pixels[i * 4 + 1]), u32(pixels[i * 4 + 2]), u32(pixels[i * 4 + 3])
		out[i * 4 + 0] = u8((b * a + 127) / 255)
		out[i * 4 + 1] = u8((g * a + 127) / 255)
		out[i * 4 + 2] = u8((r * a + 127) / 255)
		out[i * 4 + 3] = u8(a)
	}
	linux.munmap(mem, uint(bytes))
	pool := wl.wl_shm_create_pool(st.shm, i32(fd), i32(bytes))
	if pool == nil do return nil
	buf := wl.wl_shm_pool_create_buffer(pool, 0, size.x, size.y, size.x * 4, .Argb8888)
	wl.wl_shm_pool_destroy(pool)
	return buf
}
