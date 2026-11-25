#+build linux
// surface.odin — wl_surface + role objects (xdg_toplevel or
// zwlr_layer_surface_v1), the configure handshake, fractional scale via
// wp_fractional_scale_v1 + wp_viewport, frame callbacks, and cursors.
package wayland

import "core:math"
import "core:strings"
import "baldr:platform"
import wl "baldr:platform/wayland/wl"

DEFAULT_SIZE :: [2]f32{800, 600}

// Surface_State is one platform.Surface.
Surface_State :: struct {
	st:   ^State,
	id:   platform.Surface,
	kind: platform.Surface_Kind,

	wl_surface:    wl.Proxy,
	xdg_surface:   wl.Proxy,
	toplevel:      wl.Proxy,
	exported:      wl.Proxy, // zxdg_exported_v2, once a dialog has asked for this window's handle (export.odin)
	export_handle: string,   // "wayland:<handle>", owned
	decoration:    wl.Proxy, // zxdg_toplevel_decoration_v1, may be nil
	fractional:    wl.Proxy, // wp_fractional_scale_v1, may be nil
	viewport:      wl.Proxy, // wp_viewport, may be nil
	layer_surface: wl.Proxy, // zwlr_layer_surface_v1 for .Layer
	lock_surface:  wl.Proxy, // ext_session_lock_surface_v1 for .Lock (lock.odin)
	lock_output:   ^Output,  // …the screen it covers (nil once that screen has gone)
	lock_shown:    bool,     // …a frame of it has been on screen since the session locked
	applet:        wl.Proxy, // rikkiti_applet_v1 for .Applet (applet.odin)
	edge:          platform.Edge, // an applet: its bar's edge, from configure
	popup:         wl.Proxy, // xdg_popup for a popup (popup.odin)
	bg_effect:     wl.Proxy, // ext_background_effect_surface_v1, nil until a blur backdrop is asked for
	blur:          bool,     // the blur region currently covers the surface
	backdrop:      wl.Proxy, // rikkiti_backdrop_v1 while blurred or measured, when the compositor reports backdrops
	as_shown:      bool,     // …and it was asked to report it unblurred (measure_as_shown, protocol version 2)
	// the backdrop cell by cell (watch_map, protocol version 3): a map
	// arrives as map_begin, then map_rows until every row has come, then
	// map_done. The bytes are gathered here and the event carries a slice of
	// this buffer, which lives until the next map replaces it.
	map_watched:  bool,
	map_cells:    [dynamic]u8,
	map_cols:     int,
	map_rows:     int,
	map_cell:     int,
	map_origin:   [2]i32,
	frame_cb:      wl.Proxy, // pending wl_callback, nil when none
	ack_serial:    u32,  // a configure whose size we have not drawn yet: acked with the frame that answers it
	cursor_pic: Cursor_Picture, // the picture its cursor is while `cursor` is .Picture (cursor_picture.odin)
	activate_pending: bool,   // asked to come forward before it was shown: done as it first shows (activation.odin)
	activate_token:   string, // …with this token ("" : one asked for); owned
	configure_serial: u32, // the latest configure's, acked or not: a popup's grab before any input goes with its parent's
	ack_pending:   bool,
	geom_pending:  bool, // …and the geometry that goes with it, sent in that same commit
	inhibitor:     Inhibitor, // the desktop's shortcuts held off while this surface has the keyboard (shortcuts.odin)
	idle_inhibit:  wl.Proxy,  // zwp_idle_inhibitor_v1 while the app asks for the screen to stay on (idle.odin)

	// listeners (libwayland keeps the pointer; they must not move)
	surface_l:  wl.Wl_Surface_Listener,
	xdg_l:      wl.Xdg_Surface_Listener,
	toplevel_l: wl.Xdg_Toplevel_Listener,
	deco_l:     wl.Zxdg_Toplevel_Decoration_V1_Listener,
	frac_l:     wl.Wp_Fractional_Scale_V1_Listener,
	backdrop_l: wl.Rikkiti_Backdrop_V1_Listener,
	layer_l:    wl.Zwlr_Layer_Surface_V1_Listener,
	lock_l:     wl.Ext_Session_Lock_Surface_V1_Listener,
	applet_l:   wl.Rikkiti_Applet_V1_Listener,
	popup_l:    wl.Xdg_Popup_Listener,
	frame_l:    wl.Wl_Callback_Listener,

	// geometry (logical) and scale
	size:         [2]f32,
	size_px:      [2]u32,
	scale:        f32,
	frac_scale:   f32, // from preferred_scale; 0 = not received
	output:       ^Output, // last wl_surface.enter, for the integer-scale fallback
	default_size: [2]f32,
	exclusive_edge_set: bool, // a v5 exclusive edge was sent: clearing it must be sent too

	// xdg_toplevel.configure is buffered until xdg_surface.configure
	pending_size:   [2]i32,
	pending_states: struct { maximized, fullscreen, activated, tiled: bool },
	maximized, fullscreen, activated, tiled: bool,
	// a size of the window's own (surface_set_size: rolled up to its bar):
	// kept through configures while it floats; `own_guard` is the one chosen
	// before, not taken from a configure while handing back (`own_release`)
	own_size:    [2]f32,
	own_guard:   [2]f32,
	own_release: bool,
	// the desktop maximised a window rolled up (or while it came down): it
	// saved the rolled size as the one to restore, so the first floating
	// configure asking for [0] gets [1], the size the window had
	own_after:   [2][2]f32,
	min_size, max_size: [2]f32, // as asked at creation: loosened while a size of its own is smaller
	configured:     bool,
	mapped:         bool, // a compositor frame callback has fired: the surface is on screen
	frame_pending:  bool,
	// the frame clock (frames.odin)
	frames_on:      bool, // this surface wants an Ev_Frame every display frame
	present_ms:     f64,  // when the last frame actually reached the screen (wp_presentation; 0 = never told)
	refresh_ms:     f64,  // …and how long a refresh is there

	decoration_mode: wl.Zxdg_Toplevel_Decoration_V1_Mode, // 0 = not decided / no manager
	cursor:          platform.Cursor,
	last_configure:  platform.Ev_Configure, // last emitted; identical configures are dropped

	// a popup: how it was asked for, its xdg_popup.configure waiting for the
	// xdg_surface.configure, and its card's size
	popup_desc:       platform.Popup_Desc,
	pending_popup:    [4]i32,
	card:             [2]f32,
	reposition_token: u32,
	parent_clear:     f32, // what its parent popup keeps clear: that parent's geometry is this much larger than its card
}

@(private)
lookup :: proc(st: ^State, s: platform.Surface) -> ^Surface_State {
	i := int(s) - 1
	if i < 0 || i >= len(st.surfaces) do return nil
	return st.surfaces[i]
}

@(private)
lookup_wl :: proc(st: ^State, wl_surface: wl.Proxy) -> ^Surface_State {
	if wl_surface == nil do return nil
	for s in st.surfaces {
		if s != nil && s.wl_surface == wl_surface do return s
	}
	return nil
}

@(private)
find_output :: proc(st: ^State, proxy: wl.Proxy) -> ^Output {
	for o in st.outputs {
		if o.proxy == proxy do return o
	}
	return nil
}

// ---------------------------------------------------------------- create

@(private)
surface_create :: proc(b: ^platform.Backend, desc: platform.Surface_Desc) -> (platform.Surface, bool) {
	st := state(b)
	switch desc.kind {
	case .Window:
	case .Layer:
		if st.layer_shell == nil {
			debugf(st, "surface_create: compositor has no zwlr_layer_shell_v1")
			return 0, false
		}
	case .Lock:
		if lock_surface_refused(st, desc.output) do return 0, false
	case .Applet:
		if st.applet_mgr == nil {
			debugf(st, "surface_create: compositor has no rikkiti_applet_manager_v1")
			return 0, false
		}
	}

	s := surface_alloc(st, desc.kind, desc.size, desc.transparent)
	if desc.backdrop != .None do set_backdrop(st, s, desc.backdrop)

	switch desc.kind {
	case .Window: create_toplevel(st, s, desc)
	case .Layer:  create_layer(st, s, desc)
	case .Applet: create_applet(st, s, desc)
	case .Lock:   create_lock_surface(st, s, output_named(st, desc.output))
	}

	// Initial commit without a buffer asks for the first configure. Not a
	// lock surface's: it is configured at once, and a commit before that
	// configure is acked is a protocol error.
	if desc.kind != .Lock do wl.wl_surface_commit(s.wl_surface)
	wl.display_flush(st.display)
	debugf(st, "surface %d created (%v, wl_surface #%d)", s.id, desc.kind, wl.proxy_id(s.wl_surface))
	return s.id, true
}

// surface_alloc takes a slot and makes the wl_surface every role shares,
// with its fractional scale and viewport; an opaque surface says so.
@(private)
surface_alloc :: proc(st: ^State, kind: platform.Surface_Kind, size: [2]f32, transparent: bool) -> ^Surface_State {
	s := new(Surface_State)
	s.st = st
	s.kind = kind
	s.scale = 1
	s.cursor = .Default
	s.default_size = size
	if s.default_size.x <= 0 || s.default_size.y <= 0 do s.default_size = DEFAULT_SIZE

	slot := -1
	for e, i in st.surfaces {
		if e == nil { slot = i; break }
	}
	if slot < 0 {
		append(&st.surfaces, s)
		slot = len(st.surfaces) - 1
	} else {
		st.surfaces[slot] = s
	}
	s.id = platform.Surface(slot + 1)

	s.wl_surface = wl.wl_compositor_create_surface(st.compositor)
	s.surface_l = wl.wl_surface_listener_noop()
	s.surface_l.enter = on_surface_enter
	s.surface_l.leave = on_surface_leave
	wl.wl_surface_add_listener(s.wl_surface, &s.surface_l, s)

	if st.fractional_mgr != nil {
		s.fractional = wl.wp_fractional_scale_manager_v1_get_fractional_scale(st.fractional_mgr, s.wl_surface)
		s.frac_l = wl.wp_fractional_scale_v1_listener_noop()
		s.frac_l.preferred_scale = on_preferred_scale
		wl.wp_fractional_scale_v1_add_listener(s.fractional, &s.frac_l, s)
	}
	if st.viewporter != nil {
		s.viewport = wl.wp_viewporter_get_viewport(st.viewporter, s.wl_surface)
	}
	if !transparent {
		// Everything we draw is opaque: lets the compositor skip blending.
		region := wl.wl_compositor_create_region(st.compositor)
		wl.wl_region_add(region, 0, 0, 1 << 24, 1 << 24)
		wl.wl_surface_set_opaque_region(s.wl_surface, region)
		wl.wl_region_destroy(region)
	}
	return s
}

@(private)
create_toplevel :: proc(st: ^State, s: ^Surface_State, desc: platform.Surface_Desc) {
	s.xdg_surface = wl.xdg_wm_base_get_xdg_surface(st.wm_base, s.wl_surface)
	s.xdg_l = wl.xdg_surface_listener_noop()
	s.xdg_l.configure = on_xdg_surface_configure
	wl.xdg_surface_add_listener(s.xdg_surface, &s.xdg_l, s)

	s.toplevel = wl.xdg_surface_get_toplevel(s.xdg_surface)
	s.toplevel_l = wl.xdg_toplevel_listener_noop()
	s.toplevel_l.configure = on_toplevel_configure
	s.toplevel_l.close = on_toplevel_close
	wl.xdg_toplevel_add_listener(s.toplevel, &s.toplevel_l, s)

	title := strings.clone_to_cstring(desc.title if desc.title != "" else "Baldr", context.temp_allocator)
	app_id := strings.clone_to_cstring(desc.app_id if desc.app_id != "" else "baldr", context.temp_allocator)
	// A notification is signed with the app's name, and the app id is only
	// ever seen here — so the first surface to open is what names it
	// (notify.odin).
	if st.app_id == "" {
		st.app_id = strings.clone(string(app_id), st.alloc)
		st.xdg.app_id = st.app_id // what a notification is signed with (platform/xdg)
	}
	wl.xdg_toplevel_set_title(s.toplevel, title)
	wl.xdg_toplevel_set_app_id(s.toplevel, app_id)
	if p := lookup(st, desc.parent); p != nil && p.toplevel != nil do wl.xdg_toplevel_set_parent(s.toplevel, p.toplevel)

	min_size, max_size := desc.min_size, desc.max_size
	if desc.fixed_size {
		min_size, max_size = s.default_size, s.default_size
	}
	s.min_size, s.max_size = min_size, max_size
	if min_size.x > 0 || min_size.y > 0 {
		wl.xdg_toplevel_set_min_size(s.toplevel, i32(min_size.x), i32(min_size.y))
	}
	if max_size.x > 0 || max_size.y > 0 {
		wl.xdg_toplevel_set_max_size(s.toplevel, i32(max_size.x), i32(max_size.y))
	}
	// asked for on the way up; the compositor answers in its first configure
	if desc.fullscreen do wl.xdg_toplevel_set_fullscreen(s.toplevel, nil)
	if desc.maximized do wl.xdg_toplevel_set_maximized(s.toplevel) // a window coming back the way it was left

	if st.decoration_mgr != nil {
		s.decoration = wl.zxdg_decoration_manager_v1_get_toplevel_decoration(st.decoration_mgr, s.toplevel)
		s.deco_l = wl.zxdg_toplevel_decoration_v1_listener_noop()
		s.deco_l.configure = on_decoration_configure
		wl.zxdg_toplevel_decoration_v1_add_listener(s.decoration, &s.deco_l, s)
		wl.zxdg_toplevel_decoration_v1_set_mode(s.decoration, .Client_Side if desc.undecorated else .Server_Side)
	} else {
		// No manager: the compositor draws nothing, so the toolkit must (CSD).
		s.decoration_mode = .Client_Side
		debugf(st, "no zxdg_decoration_manager_v1: window %d needs client-side decorations", s.id)
	}
}

@(private)
create_layer :: proc(st: ^State, s: ^Surface_State, desc: platform.Surface_Desc) {
	l := desc.layer
	output: wl.Proxy
	if l.output != "" {
		for o in st.outputs {
			if o.out_name == l.output { output = o.proxy; break }
		}
	}
	layer: wl.Zwlr_Layer_Shell_V1_Layer
	switch l.level {
	case .Background: layer = .Background
	case .Bottom:     layer = .Bottom
	case .Top:        layer = .Top
	case .Overlay:    layer = .Overlay
	}
	namespace := strings.clone_to_cstring(desc.app_id if desc.app_id != "" else "baldr", context.temp_allocator)
	s.layer_surface = wl.zwlr_layer_shell_v1_get_layer_surface(st.layer_shell, s.wl_surface, output, layer, namespace)
	s.layer_l = wl.zwlr_layer_surface_v1_listener_noop()
	s.layer_l.configure = on_layer_configure
	s.layer_l.closed = on_layer_closed
	wl.zwlr_layer_surface_v1_add_listener(s.layer_surface, &s.layer_l, s)

	layer_apply(s, l, desc.size, live = false)
}

// layer_apply sends a layer surface's placement: anchors, size (0 stretches
// between the anchored edges; the compositor fills it in via configure),
// exclusive zone and edge (v5), margins, keyboard and, once it exists, its
// level (v2).
@(private)
layer_apply :: proc(s: ^Surface_State, l: platform.Layer_Desc, size: [2]f32, live: bool) {
	p := s.layer_surface
	v := wl.proxy_version(p)
	edges :: proc(set: bit_set[platform.Edge; u8]) -> (a: wl.Zwlr_Layer_Surface_V1_Anchor) {
		if .Top in set do a |= wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP
		if .Bottom in set do a |= wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM
		if .Left in set do a |= wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT
		if .Right in set do a |= wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT
		return
	}
	wl.zwlr_layer_surface_v1_set_anchor(p, edges(l.anchor))
	w, h := u32(max(size.x, 0)), u32(max(size.y, 0))
	if .Left in l.anchor && .Right in l.anchor do w = 0 // stretched between them
	if .Top in l.anchor && .Bottom in l.anchor do h = 0
	wl.zwlr_layer_surface_v1_set_size(p, w, h)
	wl.zwlr_layer_surface_v1_set_exclusive_zone(p, l.exclusive_zone)
	if v >= 5 && (card(l.exclusive_edge) == 1 || s.exclusive_edge_set) {
		wl.zwlr_layer_surface_v1_set_exclusive_edge(p, edges(l.exclusive_edge) if card(l.exclusive_edge) == 1 else {})
		s.exclusive_edge_set = card(l.exclusive_edge) == 1
	}
	wl.zwlr_layer_surface_v1_set_margin(p, l.margin[0], l.margin[1], l.margin[2], l.margin[3])
	ki: wl.Zwlr_Layer_Surface_V1_Keyboard_Interactivity
	switch l.keyboard {
	case .None:      ki = .None
	case .Exclusive: ki = .Exclusive
	case .On_Demand: ki = .On_Demand if v >= 4 else .Exclusive
	}
	wl.zwlr_layer_surface_v1_set_keyboard_interactivity(p, ki)
	if live && v >= 2 {
		level: wl.Zwlr_Layer_Shell_V1_Layer
		switch l.level {
		case .Background: level = .Background
		case .Bottom:     level = .Bottom
		case .Top:        level = .Top
		case .Overlay:    level = .Overlay
		}
		wl.zwlr_layer_surface_v1_set_layer(p, level)
	}
}

// commit_live carries pending surface state to the compositor — unless the
// surface has never been shown. Before its first buffer, everything set here
// (a frame request, an input or blur region, a layer placement) rides on the
// commit that attaches that buffer: a commit of its own would map an empty
// window, shadowed and blurred, until the first frame is drawn.
@(private)
commit_live :: proc(st: ^State, s: ^Surface_State) {
	if !s.mapped do return
	wl.wl_surface_commit(s.wl_surface)
	wl.display_flush(st.display)
}

// surface_set_layer changes an open layer surface's placement in place and
// commits; the compositor's configure follows as usual.
@(private)
surface_set_layer :: proc(b: ^platform.Backend, surface: platform.Surface, l: platform.Layer_Desc, size: [2]f32) -> bool {
	st := state(b)
	s := lookup(st, surface)
	if s == nil || s.layer_surface == nil do return false
	layer_apply(s, l, size, live = true)
	if size.x > 0 && size.y > 0 do s.default_size = size
	debugf(st, "surface %d: layer placement changed: size %v, anchors %v, margins %v", s.id, size, l.anchor, l.margin)
	if s.mapped {
		commit_live(st, s)
	} else {
		// Not on screen yet: its first frame waits for the configure this
		// size brings, and nothing else would commit it.
		wl.wl_surface_commit(s.wl_surface)
		wl.display_flush(st.display)
	}
	return true
}

// surface_set_input_region: where the surface takes the pointer, the rects
// widened to whole px and applied with a commit.
@(private)
surface_set_input_region :: proc(b: ^platform.Backend, surface: platform.Surface, rects: [][4]f32, all: bool) {
	st := state(b)
	s := lookup(st, surface)
	if s == nil do return
	if all {
		wl.wl_surface_set_input_region(s.wl_surface, nil)
	} else {
		lo :: proc(v: f32) -> i32 { i := i32(v); return i - 1 if f32(i) > v else i }
		hi :: proc(v: f32) -> i32 { i := i32(v); return i + 1 if f32(i) < v else i }
		region := wl.wl_compositor_create_region(st.compositor)
		for r in rects {
			x0, y0, x1, y1 := lo(r[0]), lo(r[1]), hi(r[0] + r[2]), hi(r[1] + r[3])
			if x1 > x0 && y1 > y0 do wl.wl_region_add(region, x0, y0, x1 - x0, y1 - y0)
		}
		wl.wl_surface_set_input_region(s.wl_surface, region)
		wl.wl_region_destroy(region)
	}
	debugf(st, "surface %d: input region %s %v", s.id, "everywhere" if all else "", rects)
	commit_live(st, s)
}

// surface_set_blur_region: where the compositor blurs behind the surface,
// the union of `rects` each rounded by its `radii` entry, in place of the
// whole surface. Takes effect on the next commit.
surface_set_blur_region :: proc(b: ^platform.Backend, surface: platform.Surface, rects: [][4]f32, radii: []f32) {
	st := state(b)
	s := lookup(st, surface)
	if s == nil || s.bg_effect == nil || !s.blur do return
	region := wl.wl_compositor_create_region(st.compositor)
	for r, i in rects {
		x, y := i32(math.floor(r[0])), i32(math.floor(r[1]))
		w, h := i32(math.ceil(r[0] + r[2])) - x, i32(math.ceil(r[1] + r[3])) - y
		radius := i32(math.round(radii[i])) if i < len(radii) else 0
		if w > 0 && h > 0 do region_add_rounded(region, x, y, w, h, radius)
	}
	wl.ext_background_effect_surface_v1_set_blur_region(s.bg_effect, region)
	wl.wl_region_destroy(region)
	debugf(st, "surface %d: blur region %v", s.id, rects)
	commit_live(st, s)
}

// set_backdrop asks the compositor for what goes behind the whole surface —
// a blur, or nothing — and for how bright it is. Takes effect on the next
// commit; the blur region follows the surface size (apply_geometry).
//
// The two are separate protocols, and `.Measure` asks for the second alone:
// a surface drawn straight on the desktop wants no blur but must still know
// what is behind its text. So a compositor without the blur protocol still
// reports, and callers check Backend.caps for the opaque fallback.
@(private)
set_backdrop :: proc(st: ^State, s: ^Surface_State, backdrop: platform.Backdrop) {
	blur := backdrop == .Blur
	set_blur(st, s, blur)
	if blur || backdrop == .Measure {
		backdrop_watch(st, s, as_shown = backdrop == .Measure)
	} else if s.backdrop != nil {
		wl.rikkiti_backdrop_v1_destroy(s.backdrop)
		s.backdrop = nil
		s.as_shown = false
	}
	debugf(st, "surface %d: backdrop %v", s.id, backdrop)
}

// set_blur covers the whole surface with a blur region
// (ext-background-effect-v1), or stops asking. No-op when the compositor
// lacks the protocol.
@(private = "file")
set_blur :: proc(st: ^State, s: ^Surface_State, blur: bool) {
	if st.bg_effect_mgr == nil || !st.blur_ok {
		if blur do debugf(st, "surface %d: blur backdrop asked for but the compositor has no ext_background_effect_v1 (blur=%v)", s.id, st.blur_ok)
		return
	}
	if s.bg_effect == nil {
		if !blur do return
		s.bg_effect = wl.ext_background_effect_manager_v1_get_background_effect(st.bg_effect_mgr, s.wl_surface)
	}
	s.blur = blur
	region := wl.wl_compositor_create_region(st.compositor)
	if blur do wl.wl_region_add(region, 0, 0, 1 << 15, 1 << 15) // larger than any surface; the compositor clips it
	wl.ext_background_effect_surface_v1_set_blur_region(s.bg_effect, region)
	wl.wl_region_destroy(region)
}

// backdrop_watch asks the compositor to report how bright it is behind the
// surface (rikkiti-backdrop-v1), when it can; the object is made once.
//
// `as_shown` asks for the numbers without the blur (measure_as_shown,
// protocol version 2; on version 1 they stay blurred). It is for a surface
// drawing straight on the desktop: a blur evens out exactly the contrast
// that decides whether a letter reads. There is no way back short of
// destroying the object, so it is sent only for a surface that asked, once.
@(private)
backdrop_watch :: proc(st: ^State, s: ^Surface_State, as_shown := false) {
	if st.backdrop_mgr == nil do return
	if s.backdrop == nil {
		s.backdrop = wl.rikkiti_backdrop_manager_v1_get_backdrop(st.backdrop_mgr, s.wl_surface)
		s.backdrop_l = wl.rikkiti_backdrop_v1_listener_noop()
		s.backdrop_l.luminance = on_backdrop_luminance
		wl.rikkiti_backdrop_v1_add_listener(s.backdrop, &s.backdrop_l, s)
	}
	if as_shown && !s.as_shown {
		s.as_shown = true
		// Logged either way: on version 1 the numbers arrive blurred, and an
		// ink chosen from them is chosen for a backdrop nobody sees.
		if v := wl.proxy_version(s.backdrop); v >= 2 {
			wl.rikkiti_backdrop_v1_measure_as_shown(s.backdrop)
			debugf(st, "surface %d: backdrop measured as shown (rikkiti_backdrop_v1 version %d)", s.id, v)
			// …and cell by cell where offered, so each piece of text can
			// read what is behind it rather than share one ink with the
			// whole surface. The cells are the ones min/avg/max come from,
			// so this costs the compositor no extra measuring.
			if v >= 3 && !s.map_watched {
				s.map_watched = true
				s.backdrop_l.map_begin = on_backdrop_map_begin
				s.backdrop_l.map_rows  = on_backdrop_map_rows
				s.backdrop_l.map_done  = on_backdrop_map_done
				wl.rikkiti_backdrop_v1_watch_map(s.backdrop)
				debugf(st, "surface %d: asked for the backdrop cell by cell", s.id)
			}
		} else {
			debugf(st, "surface %d: this compositor's rikkiti_backdrop_v1 is version %d, so the backdrop comes blurred", s.id, v)
		}
	}
}

// on_backdrop_luminance: the compositor measured what shows through the
// surface, or what lies straight behind it (0..65535 relative luminance);
// the toolkit picks its tint and text, and a view may read it
// (baldr.backdrop_range).
@(private)
on_backdrop_luminance :: proc "c" (data: rawptr, p: wl.Proxy, lo, avg, hi: u32) {
	s := (^Surface_State)(data)
	context = s.st.ctx
	push(s.st, platform.Ev_Backdrop{surface = s.id, min = f32(lo) / 65535, avg = f32(avg) / 65535, max = f32(hi) / 65535})
	debugf(s.st, "surface %d: backdrop luminance min %.3f avg %.3f max %.3f", s.id, f32(lo) / 65535, f32(avg) / 65535, f32(hi) / 65535)
}

// on_backdrop_map_begin: a new map starts. Its size and where it sits are
// kept and the cells are gathered until map_done; nothing is reported until
// the map is whole, because half a map would have text pick an ink from
// cells that are not there yet.
@(private)
on_backdrop_map_begin :: proc "c" (data: rawptr, p: wl.Proxy, columns, rows, cell: u32, x, y: i32) {
	s := (^Surface_State)(data)
	context = s.st.ctx
	s.map_cols, s.map_rows, s.map_cell = int(columns), int(rows), int(cell)
	s.map_origin = {x, y}
	clear(&s.map_cells)
	resize(&s.map_cells, s.map_cols * s.map_rows)
	debugf(s.st, "surface %d: backdrop map %dx%d cells of %d px at %d,%d", s.id, columns, rows, cell, x, y)
}

@(private)
on_backdrop_map_rows :: proc "c" (data: rawptr, p: wl.Proxy, first_row: u32, cells: ^wl.Array) {
	s := (^Surface_State)(data)
	context = s.st.ctx
	if cells == nil || s.map_cols <= 0 do return
	src := wl.array_slice(cells, u8)
	at := int(first_row) * s.map_cols
	if at < 0 || at + len(src) > len(s.map_cells) do return // a row past the map we were told about
	copy(s.map_cells[at:], src)
}

@(private)
on_backdrop_map_done :: proc "c" (data: rawptr, p: wl.Proxy) {
	s := (^Surface_State)(data)
	context = s.st.ctx
	if s.map_cols <= 0 || s.map_rows <= 0 do return
	push(s.st, platform.Ev_Backdrop_Map{
		surface = s.id,
		columns = s.map_cols, rows = s.map_rows, cell = s.map_cell,
		origin  = s.map_origin,
		cells   = s.map_cells[:],
	})
}

surface_set_backdrop :: proc(b: ^platform.Backend, s: platform.Surface, backdrop: platform.Backdrop) {
	st := state(b)
	ss := lookup(st, s)
	if ss == nil do return
	set_backdrop(st, ss, backdrop)
}

// surface_set_fullscreen asks the compositor for the whole screen, or gives
// it back (Backend.surface_set_fullscreen). It is a request: what actually
// happened arrives in the next configure, and `nil` for the output lets the
// compositor pick — usually the one the window is already on.
@(private)
surface_set_fullscreen :: proc(b: ^platform.Backend, surface: platform.Surface, on: bool) -> bool {
	st := state(b)
	s := lookup(st, surface)
	if s == nil || s.toplevel == nil do return false
	if on { wl.xdg_toplevel_set_fullscreen(s.toplevel, nil) } else { wl.xdg_toplevel_unset_fullscreen(s.toplevel) }
	wl.display_flush(st.display)
	debugf(st, "surface %d: asked the compositor for %s", surface, "the whole screen" if on else "its window back")
	return true
}

// surface_send_geometry tells the compositor how big this surface is: its
// viewport destination or buffer scale, and its window geometry. Called
// immediately before the frame that is that size is presented, so that the
// commit carrying the frame carries these with it.
@(private)
surface_send_geometry :: proc(s: ^Surface_State) {
	if !s.geom_pending do return
	s.geom_pending = false
	if s.viewport != nil {
		wl.wp_viewport_set_destination(s.viewport, i32(s.size.x), i32(s.size.y))
	} else if s.scale == f32(i32(s.scale)) {
		wl.wl_surface_set_buffer_scale(s.wl_surface, i32(s.scale))
	}
	if s.popup != nil {
		popup_window_geometry(s)
	} else if s.xdg_surface != nil {
		wl.xdg_surface_set_window_geometry(s.xdg_surface, 0, 0, i32(s.size.x), i32(s.size.y))
	}
}

// surface_ack_configure answers the configure this surface owes a frame for,
// called immediately before that frame is presented (see
// Backend.surface_ack_configure). Acking any earlier is what lets a
// compositor stretch the last frame over the new geometry.
@(private)
surface_ack_configure :: proc(b: ^platform.Backend, surface: platform.Surface) {
	st := state(b)
	s := lookup(st, surface)
	if s == nil do return
	surface_send_geometry(s) // the size, in the same commit as the frame that is it
	if !s.ack_pending do return
	if s.xdg_surface != nil {
		wl.xdg_surface_ack_configure(s.xdg_surface, s.ack_serial)
	} else if s.layer_surface != nil {
		wl.zwlr_layer_surface_v1_ack_configure(s.layer_surface, s.ack_serial)
	} else if s.lock_surface != nil {
		wl.ext_session_lock_surface_v1_ack_configure(s.lock_surface, s.ack_serial)
	}
	s.ack_pending = false
}

// --------------------------------------------------------------- destroy

@(private)
surface_destroy :: proc(b: ^platform.Backend, s: platform.Surface) {
	st := state(b)
	ss := lookup(st, s)
	if ss == nil do return
	debugf(st, "surface %d destroyed", s)
	was_lock := ss.lock_surface != nil
	surface_teardown(st, ss)
	st.surfaces[int(s) - 1] = nil
	wl.display_flush(st.display)
	if was_lock do lock_check_shown(st) // the lock surfaces left may all be shown now
}

// surface_teardown destroys the protocol objects in dependency order:
// extensions, role, then the wl_surface. The Vulkan surface/swapchain must
// already be gone (WSI holds proxies on this wl_surface).
@(private)
surface_teardown :: proc(st: ^State, s: ^Surface_State) {
	slots_drop_host(st, s.id) // a bar's applet slots go with it
	if st.ptr_focus == s do st.ptr_focus = nil
	if st.kbd_focus == s {
		st.kbd_focus = nil
		key_repeat_stop(st)
	}
	if s.inhibitor.proxy != nil { wl.zwp_keyboard_shortcuts_inhibitor_v1_destroy(s.inhibitor.proxy); s.inhibitor = {} }
	surface_export_drop(st, s) // before the role: the export names this toplevel
	idle_release(s) // a window that has gone does not hold the screen on (idle.odin)
	if s.frame_cb != nil { wl.proxy_destroy(s.frame_cb); s.frame_cb = nil }
	if s.decoration != nil { wl.zxdg_toplevel_decoration_v1_destroy(s.decoration); s.decoration = nil }
	if s.popup != nil { wl.xdg_popup_destroy(s.popup); s.popup = nil }
	if s.applet != nil { wl.rikkiti_applet_v1_destroy(s.applet); s.applet = nil }
	if s.toplevel != nil { wl.xdg_toplevel_destroy(s.toplevel); s.toplevel = nil }
	if s.xdg_surface != nil { wl.xdg_surface_destroy(s.xdg_surface); s.xdg_surface = nil }
	if s.layer_surface != nil { wl.zwlr_layer_surface_v1_destroy(s.layer_surface); s.layer_surface = nil }
	if s.lock_surface != nil { wl.ext_session_lock_surface_v1_destroy(s.lock_surface); s.lock_surface = nil } // the session stays locked: its screen shows the compositor's own colour
	if s.backdrop != nil { wl.rikkiti_backdrop_v1_destroy(s.backdrop); s.backdrop = nil }
	delete(s.map_cells)
	s.map_cells = nil
	if s.bg_effect != nil { wl.ext_background_effect_surface_v1_destroy(s.bg_effect); s.bg_effect = nil }
	if s.viewport != nil { wl.wp_viewport_destroy(s.viewport); s.viewport = nil }
	if s.fractional != nil { wl.wp_fractional_scale_v1_destroy(s.fractional); s.fractional = nil }
	if s.wl_surface != nil { wl.wl_surface_destroy(s.wl_surface); s.wl_surface = nil }
	delete(s.activate_token)
	cursor_picture_drop(&s.cursor_pic)
	free(s)
}

// ------------------------------------------------------------ properties

@(private)
surface_set_title :: proc(b: ^platform.Backend, s: platform.Surface, title: string) {
	st := state(b)
	ss := lookup(st, s)
	if ss == nil || ss.toplevel == nil do return
	wl.xdg_toplevel_set_title(ss.toplevel, strings.clone_to_cstring(title, context.temp_allocator))
	wl.display_flush(st.display)
}

@(private)
surface_geometry :: proc(b: ^platform.Backend, s: platform.Surface) -> (size: [2]f32, size_px: [2]u32, scale: f32) {
	ss := lookup(state(b), s)
	if ss == nil do return {}, {}, 1
	return ss.size, ss.size_px, ss.scale
}

// surface_request_frame arms one wl_surface.frame callback and commits it
// (a frame request is double-buffered state; the commit carries no buffer so
// the content is unchanged). Before the surface has ever been shown there is
// no commit of its own: the request waits for the commit that attaches the
// first painted buffer (commit_live), and the compositor has nothing to pace
// against meanwhile, so the first Ev_Redraw is synthesised: the app draws,
// presents, and from then on the compositor's frame callbacks drive redraws
// at the output's refresh rate.
@(private)
surface_request_frame :: proc(b: ^platform.Backend, s: platform.Surface) {
	st := state(b)
	ss := lookup(st, s)
	if ss == nil || !ss.configured do return
	frame_arm(st, ss)
	if !ss.mapped do push(st, platform.Ev_Redraw{surface = ss.id})
}

// frame_arm asks for one frame callback on `s`, unless one is on its way,
// and commits it when the surface is on screen (commit_live).
@(private)
frame_arm :: proc(st: ^State, s: ^Surface_State) {
	if s.frame_pending do return
	s.frame_pending = true
	s.frame_cb = wl.wl_surface_frame(s.wl_surface)
	s.frame_l = wl.wl_callback_listener_noop()
	s.frame_l.done = on_frame_done
	wl.wl_callback_add_listener(s.frame_cb, &s.frame_l, s)
	commit_live(st, s)
}

@(private)
on_frame_done :: proc "c" (data: rawptr, cb: wl.Proxy, callback_data: u32) {
	s := (^Surface_State)(data)
	context = s.st.ctx
	wl.proxy_destroy(cb) // done is a destructor event; the client frees the proxy
	if s.frame_cb == cb do s.frame_cb = nil
	s.frame_pending = false
	first := !s.mapped
	s.mapped = true
	if first do activate_on_show(s.st, s) // it is on screen now: the activation asked for before it was, or the launcher's
	if s.lock_surface != nil do lock_surface_shown(s.st, s)
	push(s.st, platform.Ev_Redraw{surface = s.id})
	frame_clock_tick(s.st, s, callback_data) // and the frame clock, if it asked
}

// ------------------------------------------------------------- configure

@(private)
on_toplevel_configure :: proc "c" (data: rawptr, p: wl.Proxy, width, height: i32, states: ^wl.Array) {
	s := (^Surface_State)(data)
	s.pending_size = {width, height}
	s.pending_states = {}
	for state in wl.array_slice(states, wl.Xdg_Toplevel_State) {
		#partial switch state {
		case .Maximized:  s.pending_states.maximized = true
		case .Fullscreen: s.pending_states.fullscreen = true
		case .Activated:  s.pending_states.activated = true
		case .Tiled_Left, .Tiled_Right, .Tiled_Top, .Tiled_Bottom: s.pending_states.tiled = true
		}
	}
}

@(private)
on_toplevel_close :: proc "c" (data: rawptr, p: wl.Proxy) {
	s := (^Surface_State)(data)
	context = s.st.ctx
	push(s.st, platform.Ev_Close{surface = s.id})
}

@(private)
on_xdg_surface_configure :: proc "c" (data: rawptr, p: wl.Proxy, serial: u32) {
	s := (^Surface_State)(data)
	context = s.st.ctx
	size := s.size
	told := s.pending_size.x > 0 && s.pending_size.y > 0
	asked := [2]f32{f32(s.pending_size.x), f32(s.pending_size.y)}
	ps := s.pending_states
	if ps.maximized || ps.fullscreen || ps.tiled { // the desktop's to size: a size of its own ends
		if s.own_size != {} || s.own_release do own_size_end(s)
	}
	floating := !(ps.maximized || ps.fullscreen || ps.tiled)
	switch {
	case s.own_size != {}:
		size = s.own_size // floating with a size of its own: the configure's is a hint it declines
	case told && s.own_release && asked == s.own_guard:
		// sent before the desktop saw the size handed back: not taken
	case told && floating && s.own_after[0] != {} && asked == s.own_after[0]:
		size = s.own_after[1] // restored to the rolled size the desktop saved: the size it had instead
		s.own_after = {}
	case told:
		size = asked
		s.own_release = false
		if floating do s.own_after = {}
	case !s.configured:
		size = s.default_size
	}
	s.configure_serial = serial
	// A configure that asks for a size we have not drawn is acked by the
	// frame that answers it (surface_ack_configure); anything else — a
	// window becoming active, a state we redraw in place — is acked here,
	// because no new frame is owed and the compositor should not be kept
	// waiting. Only the latest serial need be acked.
	if s.configured && size == s.size {
		wl.xdg_surface_ack_configure(p, serial)
		s.ack_pending = false
	} else {
		s.ack_serial, s.ack_pending = serial, true
	}
	s.maximized = s.pending_states.maximized
	s.fullscreen = s.pending_states.fullscreen
	s.activated = s.pending_states.activated
	s.tiled = s.pending_states.tiled
	apply_geometry(s, size)
}

// surface_set_size gives a floating window a size of its own (Backend.
// surface_set_size): a window rolled up to its title bar, and back. The
// commit carrying the frame drawn at it carries the size (surface_send_
// geometry), so nothing is committed here.
@(private)
surface_set_size :: proc(b: ^platform.Backend, surface: platform.Surface, size: [2]f32) {
	st := state(b)
	s := lookup(st, surface)
	if s == nil || s.toplevel == nil do return
	if size == {} {
		if s.own_size == {} do return
		s.own_size, s.own_release = {}, true
		own_limits(s, {})
		debugf(st, "surface %d: its size handed back to the desktop (%v kept meanwhile)", s.id, s.size)
		return
	}
	if s.maximized || s.fullscreen || s.tiled do return // the desktop's to size
	s.own_guard = s.own_size if s.own_size != {} else s.size
	s.own_size, s.own_release = size, false
	own_limits(s, size)
	debugf(st, "surface %d: a size of its own, %v", s.id, size)
	apply_geometry(s, size)
}

// own_limits loosens the window's size limits while a size of its own is
// outside them (a fixed-size dialog rolled up), and puts them back with
// {}. Applied with the next commit, the one carrying the frame at that size.
@(private)
own_limits :: proc(s: ^Surface_State, size: [2]f32) {
	lo, hi := s.min_size, s.max_size
	if size != {} {
		if lo.x > size.x do lo.x = 0
		if lo.y > size.y do lo.y = 0
		if hi.x > 0 && hi.x < size.x do hi.x = 0
		if hi.y > 0 && hi.y < size.y do hi.y = 0
	}
	wl.xdg_toplevel_set_min_size(s.toplevel, i32(lo.x), i32(lo.y))
	wl.xdg_toplevel_set_max_size(s.toplevel, i32(hi.x), i32(hi.y))
}

// own_size_end: the desktop sizes the window again (it was maximised, made
// full screen or tiled).
@(private)
own_size_end :: proc(s: ^Surface_State) {
	// The desktop saved the window's size as it last saw it, which may be
	// the rolled one: rolled up still, or coming down with the frame at its
	// size not yet committed (a maximise asked for straight after).
	switch {
	case s.own_size != {} && s.own_size != s.own_guard: s.own_after = {s.own_size, s.own_guard}
	case s.own_release:                                 s.own_after = {s.own_guard, s.size}
	}
	s.own_size, s.own_guard, s.own_release = {}, {}, false
	own_limits(s, {})
	debugf(s.st, "surface %d: sized by the desktop again", s.id)
}

@(private)
on_layer_configure :: proc "c" (data: rawptr, p: wl.Proxy, serial: u32, width, height: u32) {
	s := (^Surface_State)(data)
	context = s.st.ctx
	size := s.size
	if width > 0 && height > 0 {
		size = {f32(width), f32(height)}
	} else if !s.configured {
		size = s.default_size
	}
	s.configure_serial = serial
	if s.configured && size == s.size { // as above: nothing new to draw, so answer now
		wl.zwlr_layer_surface_v1_ack_configure(p, serial)
		s.ack_pending = false
	} else {
		s.ack_serial, s.ack_pending = serial, true
	}
	apply_geometry(s, size)
}

@(private)
on_layer_closed :: proc "c" (data: rawptr, p: wl.Proxy) {
	s := (^Surface_State)(data)
	context = s.st.ctx
	push(s.st, platform.Ev_Close{surface = s.id, reason = .Compositor}) // no longer shown: its screen went, or the compositor removed it
}

@(private)
on_decoration_configure :: proc "c" (data: rawptr, p: wl.Proxy, mode: wl.Zxdg_Toplevel_Decoration_V1_Mode) {
	s := (^Surface_State)(data)
	context = s.st.ctx
	s.decoration_mode = mode
	debugf(s.st, "surface %d decoration mode: %v", s.id, mode)
}

// apply_geometry adopts a logical size (and the current scale), tells the
// compositor how the buffer maps onto it, and emits Ev_Configure — but only
// when something changed. Every configure is acked by the caller regardless;
// some compositors send one per frame (re-arranging layer surfaces on every
// commit), and the toolkit must not relayout for those.
@(private)
apply_geometry :: proc(s: ^Surface_State, size: [2]f32) {
	st := s.st
	scale := effective_scale(s)
	size_px := [2]u32{
		max(u32(math.round(size.x * scale)), 1),
		max(u32(math.round(size.y * scale)), 1),
	}
	geometry_changed := !s.configured || size != s.size || scale != s.scale
	s.size, s.scale, s.size_px = size, scale, size_px
	// The size requests are not sent here: they apply on the next commit,
	// and a frame-callback commit may come before the frame at the new size.
	// A viewport destination applied to the old buffer stretches it, and a
	// window geometry ahead of the buffer moves the decorations before the
	// content. Both wait for that frame (surface_send_geometry).
	if geometry_changed do s.geom_pending = true
	ev := platform.Ev_Configure{
		surface    = s.id,
		size       = s.size,
		size_px    = s.size_px,
		scale      = s.scale,
		maximized  = s.maximized,
		fullscreen = s.fullscreen,
		activated  = s.activated,
		tiled      = s.tiled,
		edge       = s.edge,
	}
	if s.configured && ev == s.last_configure do return
	s.configured = true
	s.last_configure = ev
	debugf(st, "surface %d configure: %vx%v logical, %vx%v px, scale %.3f, max=%v full=%v act=%v tiled=%v",
		s.id, size.x, size.y, size_px.x, size_px.y, scale, s.maximized, s.fullscreen, s.activated, s.tiled)
	push(st, ev)
}

// effective_scale: fractional-scale preference, else the entered output's
// integer scale, else 1.
@(private)
effective_scale :: proc(s: ^Surface_State) -> f32 {
	if s.frac_scale > 0 do return s.frac_scale
	if s.output != nil do return f32(s.output.scale)
	return 1
}

// surface_update_scale re-emits Ev_Configure when the effective scale changed.
@(private)
surface_update_scale :: proc(s: ^Surface_State) {
	if !s.configured do return
	if effective_scale(s) == s.scale do return
	apply_geometry(s, s.size)
}

@(private)
on_preferred_scale :: proc "c" (data: rawptr, p: wl.Proxy, scale: u32) {
	s := (^Surface_State)(data)
	context = s.st.ctx
	s.frac_scale = f32(scale) / 120
	debugf(s.st, "surface %d preferred_scale %d/120 = %.3f", s.id, scale, s.frac_scale)
	surface_update_scale(s)
}

@(private)
on_surface_enter :: proc "c" (data: rawptr, p: wl.Proxy, output: wl.Proxy) {
	s := (^Surface_State)(data)
	context = s.st.ctx
	if o := find_output(s.st, output); o != nil {
		s.output = o
		debugf(s.st, "surface %d entered output %s (scale %d)", s.id, o.out_name, o.scale)
		surface_update_scale(s)
		push(s.st, platform.Ev_Surface_Output{surface = s.id, output = strings.clone(o.out_name, text_allocator(s.st))})
	}
}

@(private)
on_surface_leave :: proc "c" (data: rawptr, p: wl.Proxy, output: wl.Proxy) {
	// Keep the last output's scale until the surface enters another output;
	// a surface straddling two outputs gets its enter for the new one first.
}

// ---------------------------------------------------------------- cursor

@(private)
surface_set_cursor :: proc(b: ^platform.Backend, s: platform.Surface, c: platform.Cursor) {
	st := state(b)
	ss := lookup(st, s)
	if ss == nil do return
	ss.cursor = c
	if st.ptr_focus == ss do apply_cursor(st, ss)
	for t in st.tools do if t.focus == ss do tool_apply_cursor(t) // a pen over it takes the shape too
}

// apply_cursor sends the surface's cursor for the current pointer-enter
// serial. Compositors reset the cursor on every enter, so this runs on
// enter as well as on set_cursor.
@(private)
apply_cursor :: proc(st: ^State, s: ^Surface_State) {
	if st.pointer == nil do return
	debugf(st, "cursor on surface %d: %v", s.id, s.cursor)
	if s.cursor == .Picture {
		cursor_picture_apply(st, s)
		return
	}
	if s.cursor == .Hidden {
		wl.wl_pointer_set_cursor(st.pointer, st.ptr_enter_serial, nil, 0, 0)
		wl.display_flush(st.display)
		return
	}
	if st.cursor_device == nil {
		// No cursor-shape protocol (GNOME's Mutter has none): draw the shape
		// from the desktop's cursor theme instead (cursor_theme.odin).
		if theme_cursor_apply(st, s) do return
		if !st.cursor_warned {
			st.cursor_warned = true
			debugf(st, "no wp_cursor_shape_manager_v1 and no cursor theme to draw from: the pointer keeps whatever shape it had")
		}
		return
	}
	wl.wp_cursor_shape_device_v1_set_shape(st.cursor_device, st.ptr_enter_serial, cursor_shape(s.cursor))
	wl.display_flush(st.display)
}

@(private)
cursor_shape :: proc(c: platform.Cursor) -> wl.Wp_Cursor_Shape_Device_V1_Shape {
	switch c {
	case .Default:     return .Default
	case .Pointer:     return .Pointer
	case .Text:        return .Text
	case .Crosshair:   return .Crosshair
	case .Move:        return .Move
	case .Not_Allowed: return .Not_Allowed
	case .Grab:        return .Grab
	case .Grabbing:    return .Grabbing
	case .Resize_NS:   return .Ns_Resize
	case .Resize_EW:   return .Ew_Resize
	case .Resize_NESW: return .Nesw_Resize
	case .Resize_NWSE: return .Nwse_Resize
	case .Wait:        return .Wait
	case .Progress:    return .Progress
	case .Picture: return .Default // a picture is set through its own surface (cursor_picture.odin), never as a shape
	case .Help:        return .Help
	case .Hidden:      return .Default
	}
	return .Default
}
