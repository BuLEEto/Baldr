package baldr

// Theme icons: an icon from the desktop's icon theme by name, found and
// decoded on a worker thread (SVG through svg_render, PNG, XPM) and drawn
// from the glyph atlas once ready; its space is kept meanwhile, and a size of
// it already loaded stands in, scaled, as does its picture from before the
// icon theme changed. An icon whose colours the desktop sets (symbolic, or
// styled with currentColor or KDE's ColorScheme classes) is drawn in the
// node's colour and follows it:
// one that takes only the text colour becomes a mask, tinted as it is
// drawn; one that also uses the accent or status colours is rendered again
// for each colour it is shown in. A full-colour icon keeps its own colours.
// The icon theme is the desktop's (the settings portal, else GTK's or
// KDE's settings), and a new theme, or a change to its files, shows
// without a restart.

import "base:runtime"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "baldr:gpu"
import runa "baldr:third_party/runa"

// THEME_ICON_MAX_PX is the largest a theme icon is rasterised, in device px.
THEME_ICON_MAX_PX :: 512

// theme_icon draws the icon theme's `name` (a .desktop file's Icon=, a tray
// item's IconName, "folder", "network-wireless-signal-good-symbolic", or an
// absolute path) at `size` logical px, ICON_SIZE by default. Its space is
// kept while it loads, and meanwhile the nearest size of it already loaded
// draws in its place, scaled (a dock growing its icons), as does its picture
// from before the icon theme changed; only its very first appearance draws
// nothing. A name nothing provides draws `fallback` instead (a
// Lucide icon; none: the theme's application-x-executable, else Lucide's
// app window). A symbolic or recolourable icon takes `color` (the text
// colour by default); a full-colour one fades with `color`'s alpha.
// Decorative unless `label` names it (then Image).
theme_icon :: proc(ui: ^Ui($Msg), name: string, size: f32 = 0, color: Color = {}, label: string = "",
	fallback: Icon = .None, key: u64 = 0, loc := #caller_location) -> Node {
	n, created := reconcile_child(ui, .Custom, key, loc)
	t := &ui.tree
	d := node_get(t, n)
	px := size if size > 0 else ICON_SIZE
	if ck, ok := d.kind.(Custom_Kind); !ok || created || ck.size.x != px || ck.paint != paint_theme_icon {
		d.kind = Custom_Kind{size = {px, px}, paint = paint_theme_icon}
		mark_layout_dirty(t, n)
	}
	if use, has := t.theme_icons[n]; !has || use.name != name {
		delete(use.name, t.allocator)
		use.name = strings.clone(name, t.allocator)
		t.theme_icons[n] = use
		mark_paint_dirty(t, n)
	}
	if use := &t.theme_icons[n]; use.fallback != fallback {
		use.fallback = fallback
		mark_paint_dirty(t, n)
	}
	fg := color if color != {} else t.theme.color.on_surface
	if d.style.fg != fg {
		d.style.fg = fg
		mark_paint_dirty(t, n)
	}
	if label != "" {
		d.access.role = .Image
		set_name(t, n, label)
	} else {
		d.access.role = .None
	}
	return n
}

// theme_icon_dir gives a theme icon one more directory to look in first: a
// tray item's IconThemePath, holding loose icons or a theme's layout.
theme_icon_dir :: proc(ui: ^Ui($Msg), n: Node, dir: string) {
	t := &ui.tree
	use, has := &t.theme_icons[n]
	if !has || use.dir == dir do return
	delete(use.dir, t.allocator)
	use.dir = strings.clone(dir, t.allocator)
	mark_paint_dirty(t, n)
}

@(private)
Theme_Icon_Use :: struct {
	name, dir: string, // owned by the tree
	fallback:  Icon,   // drawn instead once the lookup finds nothing
}

// THEME_ICON_GENERIC is a program's icon in every icon theme: what a theme
// icon nothing provides falls back to when it names no fallback of its own.
THEME_ICON_GENERIC :: "application-x-executable"

// THEME_ICON_FALLBACK_MAX is the largest a fallback Lucide icon is drawn,
// centred in a theme icon's larger place.
THEME_ICON_FALLBACK_MAX :: f32(24)

@(private)
theme_icon_use_free :: proc(t: ^Tree, use: Theme_Icon_Use) {
	delete(use.name, t.allocator)
	delete(use.dir, t.allocator)
}

@(private)
paint_theme_icon :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer) {
	use, ok := t.theme_icons[n]
	if !ok || use.name == "" do return
	c := d.style.fg
	c.a *= t.paint_opacity
	if disabled_within(t, n) do c.a *= t.theme.state.disabled_alpha
	append(&l.cmds, Draw_Theme_Icon{rect = d.abs, name = use.name, dir = use.dir, color = c, fallback = use.fallback})
}

// theme_icons_dirty repaints every theme icon of `t` (one arrived, or the
// theme changed).
@(private)
theme_icons_dirty :: proc(t: ^Tree) {
	for n in t.theme_icons do mark_paint_dirty(t, n)
}

// Drawing

@(private)
Theme_Icon_State :: enum u8 { Loading, Missing, Mask, Colour, Recolour }

@(private)
Theme_Icon_Entry :: struct {
	state: Theme_Icon_State, // Recolour: this key has no picture of its own; each colour has one under its colour key
	slot:  runa.Atlas_Slot,
}

// Theme_Icon_Family is what has loaded of one icon — its name and directory —
// at any size: a picture to draw, scaled, while the size asked for loads,
// and whether nothing provides the icon at all.
@(private)
Theme_Icon_Family :: struct {
	sizes:   [dynamic]Theme_Icon_Size,
	missing: bool, // the lookup found nothing: no other size will find it either
}

@(private)
Theme_Icon_Size :: struct {
	px:       int,
	slot:     runa.Atlas_Slot,
	format:   runa.Atlas_Format,
	recolour: bool,  // painted for one colour, `rgb`; else it takes any colour
	rgb:      [3]u8,
}

// theme_icon_family_key is the part of an icon's key that names the icon —
// its name and directory, without the size or colour.
@(private)
theme_icon_family_key :: proc(key: string) -> string {
	first := strings.index_byte(key, 0)
	if first < 0 do return key
	second := strings.index_byte(key[first + 1:], 0)
	if second < 0 do return key
	return key[:first + 1 + second]
}

@(private)
theme_icon_family :: proc(te: ^Text_Engine, key: string) -> ^Theme_Icon_Family {
	fk := theme_icon_family_key(key)
	if fk not_in te.theme_icon_families {
		te.theme_icon_families[strings.clone(fk, te.allocator)] = {sizes = make([dynamic]Theme_Icon_Size, te.allocator)}
	}
	return &te.theme_icon_families[fk]
}

// theme_icon_answered records what the icon theme as it is now said about an
// icon: a picture, or that nothing provides it. From here that stands in for
// the icon, so what stood in from before the theme changed is let go.
@(private)
theme_icon_answered :: proc(te: ^Text_Engine, key: string, size: Maybe(Theme_Icon_Size)) {
	f := theme_icon_family(te, key)
	if sz, ok := size.?; ok {
		append(&f.sizes, sz)
	} else {
		f.missing = true
	}
	fk := theme_icon_family_key(key)
	if fk in te.theme_icon_stale {
		old_key, old := delete_key(&te.theme_icon_stale, fk)
		delete(old.sizes)
		delete(old_key, te.allocator)
	}
}

@(private)
theme_icon_families_clear :: proc(te: ^Text_Engine, m: ^map[string]Theme_Icon_Family) {
	for k, f in m {
		delete(f.sizes)
		delete(k, te.allocator)
	}
	clear(m)
}

// theme_icon_stand_in is what draws while an icon's own picture loads:
// the icon at the loaded size nearest the one asked for — a
// larger one first, since scaling down reads better than up — else the
// picture it had before the icon theme changed; its fallback when nothing
// provides it; nothing only on its very first appearance. A picture painted
// for one colour stands in for another only when there is nothing else.
@(private)
theme_icon_stand_in :: proc(te: ^Text_Engine, base: string, px: int, rgb: [3]u8) -> (slot: runa.Atlas_Slot, format: runa.Atlas_Format, ok, missing: bool) {
	fk := theme_icon_family_key(base)
	fresh, has_fresh := te.theme_icon_families[fk]
	stale, has_stale := te.theme_icon_stale[fk]
	if has_fresh && fresh.missing do return {}, {}, false, true
	if !has_fresh && has_stale && stale.missing do return {}, {}, false, true
	for any_colour in ([2]bool{false, true}) {
		if has_fresh {
			if best, found := theme_icon_nearest(fresh.sizes[:], px, rgb, any_colour); found do return best.slot, best.format, true, false
		}
		if has_stale {
			if best, found := theme_icon_nearest(stale.sizes[:], px, rgb, any_colour); found do return best.slot, best.format, true, false
		}
	}
	return
}

@(private)
theme_icon_nearest :: proc(sizes: []Theme_Icon_Size, px: int, rgb: [3]u8, any_colour: bool) -> (best: Theme_Icon_Size, found: bool) {
	for sz in sizes {
		if sz.recolour && sz.rgb != rgb && !any_colour do continue
		if !found || theme_icon_nearer(sz.px, best.px, px) {
			best, found = sz, true
		}
	}
	return
}

// theme_icon_nearer says whether a picture `a` px across stands in for one
// `want` px across better than a picture `b` px across: the smallest that is
// at least as large, since it scales down, else the largest.
@(private)
theme_icon_nearer :: proc "contextless" (a, b, want: int) -> bool {
	if (a >= want) != (b >= want) do return a >= want
	if a >= want do return a < b
	return a > b
}

// render_theme_icon draws a loaded icon, square and centred in its box, or
// asks the loader for it.
@(private)
render_theme_icon :: proc(te: ^Text_Engine, t: ^Tree, v: Draw_Theme_Icon, s: f32, sink: ^Atlas_Sink, out: ^[dynamic]gpu.Cmd, glow := Glow{}) {
	side := min(v.rect.w, v.rect.h)
	px := int(math.round(side * s))
	if px <= 0 || px > THEME_ICON_MAX_PX || v.color.a <= 0 || v.name == "" do return
	scale := max(int(math.ceil(s - 0.01)), 1)
	slot, format, ok, missing := theme_icon_slot(te, t, v, max(int(math.round(side)), 1), scale, px)
	if missing { // nothing provides it: its fallback, else the theme's program icon, else Lucide's app window
		if v.fallback != .None {
			fs := min(side, THEME_ICON_FALLBACK_MAX) // a line icon grows heavier with its size: an app's 32 px place gets a 24 px one
			render_icon(te, Draw_Icon{pos = {v.rect.x + (v.rect.w - fs) / 2, v.rect.y + (v.rect.h - fs) / 2}, icon = v.fallback, size = fs, color = v.color}, s, sink, out, glow)
		} else if v.name != THEME_ICON_GENERIC {
			generic := v
			generic.name, generic.dir, generic.fallback = THEME_ICON_GENERIC, "", .App_Window
			render_theme_icon(te, t, generic, s, sink, out, glow)
		}
		return
	}
	if !ok do return
	ensure_pages(te, sink)
	uv := slot.uv_rect
	if int(slot.px_size.x) != px { // a stand-in of another size, scaled to the box: sampled half a texel in, clear of its atlas neighbours
		hu := (uv[2] - uv[0]) / f32(slot.px_size.x) / 2
		hv := (uv[3] - uv[1]) / f32(slot.px_size.y) / 2
		uv = {uv[0] + hu, uv[1] + hv, uv[2] - hu, uv[3] - hv}
	}
	append(out, gpu.Glyph{
		rect  = {math.round((v.rect.x + (v.rect.w - side) / 2) * s), math.round((v.rect.y + (v.rect.h - side) / 2) * s), f32(px), f32(px)},
		uv    = uv,
		page  = te.pages[format][slot.page_index].page,
		color = v.color,
	})
	if format == .Alpha8 do glow_under(out, len(out) - 1, glow, s) // a symbolic icon glows like text; a colour one stands on its own
}

@(private)
theme_icon_slot :: proc(te: ^Text_Engine, t: ^Tree, v: Draw_Theme_Icon, size, scale, px: int) -> (slot: runa.Atlas_Slot, format: runa.Atlas_Format, ok, missing: bool) {
	buf: [20]u8
	base := strings.concatenate({v.name, "\x00", v.dir, "\x00", strconv.write_int(buf[:], i64(px), 10)}, context.temp_allocator)
	rgb := theme_icon_rgb(v.color)
	e, seen := te.theme_icons[base]
	if !seen {
		te.theme_icons[strings.clone(base, te.allocator)] = {state = .Loading}
		theme_icons_request(te, t, base, v, size, scale, px, rgb)
		return theme_icon_stand_in(te, base, px, rgb)
	}
	#partial switch e.state {
	case .Loading:
		return theme_icon_stand_in(te, base, px, rgb)
	case .Mask:
		return e.slot, .Alpha8, true, false
	case .Colour:
		return e.slot, .RGBA8, true, false
	case .Missing:
		missing = true
	case .Recolour:
		key := theme_icon_colour_key(base, rgb, context.temp_allocator)
		ce, has := te.theme_icons[key]
		if !has {
			te.theme_icons[strings.clone(key, te.allocator)] = {state = .Loading}
			theme_icons_request(te, t, key, v, size, scale, px, rgb)
			return theme_icon_stand_in(te, base, px, rgb)
		}
		if ce.state == .Colour do return ce.slot, .RGBA8, true, false
		if ce.state == .Loading do return theme_icon_stand_in(te, base, px, rgb)
		missing = ce.state == .Missing
	}
	return
}

// theme_icon_rgb is a colour's sRGB bytes, alpha left out: fading an icon
// never asks for it again.
@(private)
theme_icon_rgb :: proc(c: Color) -> [3]u8 {
	return {u8(linear_to_srgb(clamp(c.r, 0, 1)) * 255 + 0.5), u8(linear_to_srgb(clamp(c.g, 0, 1)) * 255 + 0.5), u8(linear_to_srgb(clamp(c.b, 0, 1)) * 255 + 0.5)}
}

@(private)
theme_icon_colour_key :: proc(base: string, rgb: [3]u8, allocator: runtime.Allocator) -> string {
	hex := "0123456789abcdef"
	b: [7]u8
	for c, i in rgb {
		b[1 + i * 2] = hex[c >> 4]
		b[2 + i * 2] = hex[c & 15]
	}
	return strings.concatenate({base, string(b[:])}, allocator)
}

// Loading

@(private)
Icon_Request :: struct {
	key, name, dir, theme: string, // owned by the loader's allocator
	size, scale, px:       int,
	colors:                Svg_Colors,
	rgb:                   [3]u8,
	generation:            u64,
}

@(private)
Icon_Result :: struct {
	key:        string,
	pixels:     []u8, // px × px: Alpha8 for a mask, else RGBA8
	px:         int,
	rgb:        [3]u8,
	found:      bool,
	mask:       bool,
	recolored:  bool, // colours given to it painted it (a mask always is)
	generation: u64,
}

// Icon_Loader finds and decodes theme icons on a thread of its own; the UI
// thread queues requests and takes results. The lookup state belongs to
// whichever thread runs the requests.
@(private)
Icon_Loader :: struct {
	allocator:  runtime.Allocator,
	mu:         sync.Mutex,
	cond:       sync.Cond,
	requests:   [dynamic]Icon_Request,
	results:    [dynamic]Icon_Result,
	theme:      string, // the desktop's icon theme; "" until it says (GTK's or KDE's setting meanwhile)
	generation: u64, // bumped when the theme or its files change: older results are dropped
	changed:    bool, // the worker saw the theme's files change
	quit:       bool,
	thread:     ^thread.Thread,
	wake:       proc(user: rawptr),
	wake_user:  rawptr,
	themes:     Icon_Themes,
	has_themes: bool,
	fallback:   string, // icon_theme_default, read once
}

@(private)
icon_loader_init :: proc(ld: ^Icon_Loader, allocator: runtime.Allocator) {
	ld.allocator = allocator
	ld.requests = make([dynamic]Icon_Request, allocator)
	ld.results = make([dynamic]Icon_Result, allocator)
}

@(private)
icon_loader_destroy :: proc(ld: ^Icon_Loader) {
	if ld.thread != nil {
		sync.mutex_lock(&ld.mu)
		ld.quit = true
		sync.mutex_unlock(&ld.mu)
		sync.cond_signal(&ld.cond)
		thread.destroy(ld.thread) // joins
	}
	for &r in ld.requests do icon_request_free(ld, &r)
	for &r in ld.results do icon_result_free(ld, &r)
	delete(ld.requests)
	delete(ld.results)
	delete(ld.theme, ld.allocator)
	delete(ld.fallback, ld.allocator)
	if ld.has_themes do icon_themes_destroy(&ld.themes)
	ld^ = {}
}

// icon_loader_search points the lookup at `bases` and `pixmaps` instead of
// the XDG directories (tests, an app shipping its own theme); before any
// icon is asked for.
@(private)
icon_loader_search :: proc(ld: ^Icon_Loader, bases, pixmaps: []string) {
	if ld.has_themes do icon_themes_destroy(&ld.themes)
	icon_themes_init(&ld.themes, bases, pixmaps, ld.allocator)
	ld.has_themes = true
}

// theme_icons_start runs the loader on a thread of its own; `wake`
// interrupts the blocked run loop when an icon is ready.
@(private)
theme_icons_start :: proc(te: ^Text_Engine, wake: proc(user: rawptr), wake_user: rawptr) {
	ld := &te.icon_loader
	if ld.thread != nil do return
	ld.wake, ld.wake_user = wake, wake_user
	ld.thread = thread.create_and_start_with_data(ld, icon_loader_main)
}

// theme_icons_use makes `theme` the icon theme ("" for the desktop's GTK or
// KDE setting); true when it changed, so views showing theme icons repaint.
@(private)
theme_icons_use :: proc(te: ^Text_Engine, theme: string) -> bool {
	if te == nil do return false
	ld := &te.icon_loader
	sync.mutex_lock(&ld.mu)
	same := ld.theme == theme
	if !same {
		delete(ld.theme, ld.allocator)
		ld.theme = strings.clone(theme, ld.allocator)
	}
	sync.mutex_unlock(&ld.mu)
	if !same do theme_icons_forget(te)
	return !same
}

// theme_icons_forget drops every icon loaded or asked for, so each loads
// again from the theme as it is now. The glyph atlas keeps the old bitmaps,
// so each icon's pictures stand in until its new one arrives.
@(private)
theme_icons_forget :: proc(te: ^Text_Engine) {
	ld := &te.icon_loader
	sync.mutex_lock(&ld.mu)
	ld.generation += 1
	for &r in ld.requests do icon_request_free(ld, &r)
	clear(&ld.requests)
	sync.mutex_unlock(&ld.mu)
	for k in te.theme_icons do delete(k, te.allocator)
	clear(&te.theme_icons)
	for fk, f in te.theme_icon_families { // what was loaded stands in until the theme as it is now answers for it
		if fk in te.theme_icon_stale {
			old_key, old := delete_key(&te.theme_icon_stale, fk)
			delete(old.sizes)
			delete(old_key, te.allocator)
		}
		te.theme_icon_stale[fk] = f // the key's string moves with it
	}
	clear(&te.theme_icon_families)
}

@(private)
theme_icons_request :: proc(te: ^Text_Engine, t: ^Tree, key: string, v: Draw_Theme_Icon, size, scale, px: int, rgb: [3]u8) {
	ld := &te.icon_loader
	a := ld.allocator
	c := &t.theme.color
	req := Icon_Request{
		key = strings.clone(key, a), name = strings.clone(v.name, a), dir = strings.clone(v.dir, a),
		size = size, scale = scale, px = px, rgb = rgb,
		colors = {text = {v.color.r, v.color.g, v.color.b, 1}, highlight = c.primary, positive = c.success, neutral = c.warning, negative = c.danger},
	}
	sync.mutex_lock(&ld.mu)
	req.theme = strings.clone(ld.theme, a)
	req.generation = ld.generation
	append(&ld.requests, req)
	sync.mutex_unlock(&ld.mu)
	sync.cond_signal(&ld.cond)
}

// theme_icons_take packs what the loader finished into the glyph atlas; true
// when anything arrived or the theme's files changed, so views showing theme
// icons repaint.
@(private)
theme_icons_take :: proc(te: ^Text_Engine) -> (changed: bool) {
	if te == nil do return false
	ld := &te.icon_loader
	sync.mutex_lock(&ld.mu)
	results := ld.results
	ld.results = make([dynamic]Icon_Result, ld.allocator)
	files_changed := ld.changed
	ld.changed = false
	generation := ld.generation
	sync.mutex_unlock(&ld.mu)
	defer {
		for &r in results do icon_result_free(ld, &r)
		delete(results)
	}
	if files_changed {
		theme_icons_forget(te)
		return true
	}
	for &r in results {
		if r.generation != generation do continue // asked of a theme since replaced
		entry, seen := &te.theme_icons[r.key]
		if !seen do continue
		changed = true
		if !r.found {
			entry.state = .Missing
			theme_icon_answered(te, r.key, nil)
			continue
		}
		if r.mask {
			slot, err := runa.atlas_pack_alpha(&te.atlas, r.pixels, u16(r.px), u16(r.px), {0, 0})
			entry^ = {state = .Mask if err == .None else .Missing, slot = slot}
			if err == .None do theme_icon_answered(te, r.key, Theme_Icon_Size{px = r.px, slot = slot, format = .Alpha8})
			continue
		}
		slot, err := runa.atlas_pack_rgba(&te.atlas, r.pixels, u16(r.px), u16(r.px), {0, 0})
		if err != .None {
			entry.state = .Missing // too large to pack, not missing from the theme: other sizes may still come
			continue
		}
		one_colour := strings.count(r.key, "\x00") == 3
		if !r.recolored || one_colour { // its own colours, or the picture for one colour
			entry^ = {state = .Colour, slot = slot}
			theme_icon_answered(te, r.key, Theme_Icon_Size{px = r.px, slot = slot, format = .RGBA8, recolour = one_colour, rgb = r.rgb})
			continue
		}
		entry.state = .Recolour // each colour gets its own picture; this is the first
		te.theme_icons[theme_icon_colour_key(r.key, r.rgb, te.allocator)] = {state = .Colour, slot = slot}
		theme_icon_answered(te, r.key, Theme_Icon_Size{px = r.px, slot = slot, format = .RGBA8, recolour = true, rgb = r.rgb})
	}
	return
}

// theme_icons_load_now runs every waiting request on this thread (headless
// use, where no loader thread runs).
@(private)
theme_icons_load_now :: proc(te: ^Text_Engine) {
	ld := &te.icon_loader
	for {
		sync.mutex_lock(&ld.mu)
		if len(ld.requests) == 0 {
			sync.mutex_unlock(&ld.mu)
			return
		}
		req := ld.requests[0]
		ordered_remove(&ld.requests, 0)
		sync.mutex_unlock(&ld.mu)
		icon_loader_run(ld, &req)
	}
}

@(private)
icon_loader_main :: proc(p: rawptr) {
	ld := (^Icon_Loader)(p)
	for {
		sync.mutex_lock(&ld.mu)
		for len(ld.requests) == 0 && !ld.quit {
			if sync.cond_wait_with_timeout(&ld.cond, &ld.mu, ICON_THEME_RECHECK_MS * time.Millisecond) do continue
			sync.mutex_unlock(&ld.mu) // idle: are the theme's files still as they were?
			changed := ld.has_themes && icon_themes_recheck(&ld.themes)
			if changed && ld.wake != nil {
				sync.mutex_lock(&ld.mu)
				ld.changed = true
				sync.mutex_unlock(&ld.mu)
				ld.wake(ld.wake_user)
			}
			sync.mutex_lock(&ld.mu)
		}
		if ld.quit {
			sync.mutex_unlock(&ld.mu)
			return
		}
		req := ld.requests[0]
		ordered_remove(&ld.requests, 0)
		sync.mutex_unlock(&ld.mu)
		icon_loader_run(ld, &req)
		if ld.wake != nil do ld.wake(ld.wake_user)
		free_all(context.temp_allocator)
	}
}

// icon_loader_run answers one request and frees it.
@(private)
icon_loader_run :: proc(ld: ^Icon_Loader, req: ^Icon_Request) {
	res := icon_loader_resolve(ld, req)
	sync.mutex_lock(&ld.mu)
	append(&ld.results, res)
	sync.mutex_unlock(&ld.mu)
	icon_request_free(ld, req)
}

// icon_loader_resolve finds the icon's file and decodes it at px × px: an
// SVG rendered with the request's colours (a mask when it took only the
// text colour), a PNG or XPM fitted into the square (a mask when it is a
// -symbolic one).
@(private)
icon_loader_resolve :: proc(ld: ^Icon_Loader, req: ^Icon_Request) -> Icon_Result {
	res := Icon_Result{key = strings.clone(req.key, ld.allocator), px = req.px, rgb = req.rgb, generation = req.generation}
	if !ld.has_themes {
		icon_themes_init(&ld.themes, allocator = ld.allocator)
		ld.fallback = icon_theme_default(ld.allocator)
		ld.has_themes = true
	}
	icon_themes_use(&ld.themes, req.theme if req.theme != "" else ld.fallback)
	if icon_themes_recheck(&ld.themes) {
		sync.mutex_lock(&ld.mu)
		ld.changed = true
		sync.mutex_unlock(&ld.mu)
	}
	path, found := icon_theme_lookup(&ld.themes, req.name, req.size, req.scale, req.dir)
	if !found do return res
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil do return res
	px := req.px
	file := path[strings.last_index_byte(path, '/') + 1:]
	stem := file[:strings.last_index_byte(file, '.')] if strings.contains_rune(file, '.') else file
	symbolic := strings.has_suffix(stem, "-symbolic")
	img: Image
	ok: bool
	switch {
	case strings.has_suffix(file, ".svg"):
		colors := req.colors
		colors.symbolic = symbolic
		info: Svg_Info
		img, ok = svg_render(data, px, px, &colors, &info, context.temp_allocator)
		if !ok do return res
		res.found, res.recolored = true, info.recolored
		if info.monochrome {
			res.mask = true
			res.pixels = make([]u8, px * px, ld.allocator)
			for i in 0 ..< px * px do res.pixels[i] = img.pixels[i * 4 + 3]
		} else {
			res.pixels = make([]u8, px * px * 4, ld.allocator)
			copy(res.pixels, img.pixels)
		}
		return res
	case strings.has_suffix(file, ".png"):
		img, ok = image_load(data, context.temp_allocator)
	case strings.has_suffix(file, ".xpm"):
		img, ok = image_load_xpm(data, context.temp_allocator)
	}
	if !ok do return res
	fitted := icon_fit(&img, px, context.temp_allocator)
	res.found = true
	if symbolic {
		res.mask, res.recolored = true, true
		res.pixels = make([]u8, px * px, ld.allocator)
		for i in 0 ..< px * px do res.pixels[i] = fitted[i * 4 + 3]
	} else {
		res.pixels = make([]u8, px * px * 4, ld.allocator)
		copy(res.pixels, fitted)
	}
	return res
}

// icon_fit draws a picture into a px × px square, its aspect kept and
// centred: each pixel averages the picture's area under it when shrinking,
// or reads it bilinearly when growing.
@(private)
icon_fit :: proc(img: ^Image, px: int, allocator: runtime.Allocator) -> []u8 {
	out := make([]u8, px * px * 4, allocator)
	w, h := img.width, img.height
	if w <= 0 || h <= 0 || len(img.pixels) < w * h * 4 do return out
	scale := min(f32(px) / f32(w), f32(px) / f32(h))
	ox, oy := (f32(px) - f32(w) * scale) / 2, (f32(px) - f32(h) * scale) / 2
	for y in 0 ..< px {
		for x in 0 ..< px {
			acc: [4]f32
			if scale >= 1 {
				u, v := (f32(x) + 0.5 - ox) / scale, (f32(y) + 0.5 - oy) / scale
				if u < 0 || v < 0 || u >= f32(w) || v >= f32(h) do continue
				acc = svg_sample_image(img, u, v)
			} else {
				u0, u1 := (f32(x) - ox) / scale, (f32(x) + 1 - ox) / scale
				v0, v1 := (f32(y) - oy) / scale, (f32(y) + 1 - oy) / scale
				area := (u1 - u0) * (v1 - v0)
				for sy in max(int(math.floor(v0)), 0) ..< min(int(math.ceil(v1)), h) {
					wy := min(v1, f32(sy + 1)) - max(v0, f32(sy))
					if wy <= 0 do continue
					for sx in max(int(math.floor(u0)), 0) ..< min(int(math.ceil(u1)), w) {
						wx := min(u1, f32(sx + 1)) - max(u0, f32(sx))
						if wx <= 0 do continue
						p := img.pixels[(sy * w + sx) * 4:]
						a := f32(p[3]) / 255
						acc += [4]f32{f32(p[0]) / 255 * a, f32(p[1]) / 255 * a, f32(p[2]) / 255 * a, a} * (wx * wy / area)
					}
				}
			}
			if acc.a <= 0 do continue
			i := (y * px + x) * 4
			a := min(acc.a, 1)
			out[i], out[i + 1], out[i + 2] = u8(clamp(acc.r / a, 0, 1) * 255 + 0.5), u8(clamp(acc.g / a, 0, 1) * 255 + 0.5), u8(clamp(acc.b / a, 0, 1) * 255 + 0.5)
			out[i + 3] = u8(a * 255 + 0.5)
		}
	}
	return out
}

@(private)
icon_request_free :: proc(ld: ^Icon_Loader, r: ^Icon_Request) {
	delete(r.key, ld.allocator)
	delete(r.name, ld.allocator)
	delete(r.dir, ld.allocator)
	delete(r.theme, ld.allocator)
	r^ = {}
}

@(private)
icon_result_free :: proc(ld: ^Icon_Loader, r: ^Icon_Result) {
	delete(r.key, ld.allocator)
	delete(r.pixels, ld.allocator)
	r^ = {}
}
