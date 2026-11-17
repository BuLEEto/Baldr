package baldr

// The tray / status item: what an app *is* when its window is closed — a
// sync client in the notification area, a recorder in the menu bar.
//
// It is declared, like a surface. `App.tray` is asked at start and after
// every update, and the runtime works out what changed, so a menu rebuilt at
// runtime needs no API of its own: return a different menu, the way a view
// returns different widgets. There is no handle and nothing to free.
//
//	tray = proc(s: ^State, out: ^[dynamic]baldr.Tray_Desc(Msg)) {
//		append(out, baldr.Tray_Desc(Msg){
//			tag = 1, icon = .Cloud, tooltip = s.state_text,
//			on_click = Msg(Show_Window{}),
//			menu = {
//				{label = s.state_text, disabled = true}, // a status line is a disabled item
//				{separator = true},
//				{label = "Pause syncing", checked = s.paused, msg = Msg(Toggle_Pause{})},
//				{label = "Show window", msg = Msg(Show_Window{})},
//				{label = "Quit", msg = Msg(Quit_App{})},
//			},
//		})
//	}
//
// A declared tray holds the run open, as `keep_running` does: an app in the
// tray with no window has not finished. One that declares neither has.
//
// Not everything arrives. A desktop may have no tray at all (GNOME without
// the AppIndicator extension) — `on_gone` says so, `on_hosted` says when one
// turns up — and some hosts open the menu for any click, so the primary
// click never comes. Keep everything reachable from the menu too.

import "base:runtime"
import "core:mem/virtual"
import "core:strings"
import "baldr:platform"

Tray_Status :: platform.Tray_Status
Tray_Event  :: platform.Tray_Event

// Tray_Item is one line of the menu.
//
// `separator = true` ignores everything else. **`checked` present means a
// checkable item** and absent means a plain one: the desktops draw "a
// checkbox that is off" and "no checkbox" differently, and an app that
// means one must not get the other. `children` is a submenu, one level deep
// where the desktop has them and flattened to the parent where it does not.
//
// The strings are read while the tray is worked out and copied if they are
// kept, so a label built in the frame's temp memory is fine.
Tray_Item :: struct($Msg: typeid) {
	label:     string,
	msg:       Maybe(Msg),
	icon:      Icon,
	checked:   Maybe(bool),
	disabled:  bool,
	separator: bool,
	children:  []Tray_Item(Msg),
}

// Tray_Desc is a tray item to show. `tag` names it, and a second descriptor
// with the same tag **updates** it in place rather than adding another.
//
// `icon` is the toolkit's own (a Lucide icon, rasterised for the desktop
// and redrawn when the desktop's theme changes); `icon_name` is a name from
// the desktop's icon theme instead, which Linux hosts theme themselves and
// prefer. Give either.
Tray_Desc :: struct($Msg: typeid) {
	tag:       u64,
	title:     string, // what the desktop calls it in its own lists
	tooltip:   string,
	icon:      Icon,
	icon_name: string,
	status:    Tray_Status,
	menu:      []Tray_Item(Msg),
	on_click:  Maybe(Msg), // the primary action, where the desktop sends one
	on_hosted: Maybe(Msg), // a tray exists and this item is in it
	on_gone:   Maybe(Msg), // …and now it is not
}

// TRAY_ICON_SIZES are the sizes rasterised for a desktop to pick from.
// SNI takes them all and chooses; Windows takes the one nearest
// SM_CXSMICON; macOS wants the 44 as a template image at 2×.
@(private)
TRAY_ICON_SIZES := [?]int{16, 22, 32, 44}

// Tray_Live is what the runtime remembers about one item it has shown: the
// platform descriptor it last sent (so an update that changes nothing sends
// nothing), the messages its menu ids map to, and whether a host has it.
@(private)
Tray_Live :: struct($Msg: typeid) {
	sent:   platform.Tray_Desc, // owned, in `mem`
	msgs:   [dynamic]Maybe(Msg), // id - 1 → what to send
	click:  Maybe(Msg),
	hosted: Maybe(Msg),
	gone:   Maybe(Msg),
	is_hosted: bool,
	said:      bool, // the app has been told the current answer, hosted or not
	mem:    virtual.Arena, // everything `sent` points at
}

// tray_sync asks the app what it wants in the tray and makes it so. True
// when anything is declared, which is also what holds the run open.
@(private)
tray_sync :: proc(rt: ^Runtime($State, $Msg)) -> bool {
	if rt.app.tray == nil do return false
	clear(&rt.tray_wanted)
	rt.app.tray(&rt.state, &rt.tray_wanted)

	// Gone first: an item the app stopped declaring goes away before
	// anything new takes its place, so a tag reused for something else
	// cannot be two items for an instant. The tags are gathered before any
	// are freed, because freeing one is a `delete_key` and a map is not
	// walked while it is being changed.
	dropped := make([dynamic]u64, context.temp_allocator)
	for tag in rt.tray_live {
		still := false
		for w in rt.tray_wanted do if w.tag == tag do still = true
		if !still do append(&dropped, tag)
	}
	for tag in dropped {
		if rt.backend != nil && rt.backend.tray_remove != nil do rt.backend.tray_remove(rt.backend, tag)
		tray_live_free(rt, tag)
	}

	for w in rt.tray_wanted {
		live := &rt.tray_live[w.tag]
		if live == nil {
			rt.tray_live[w.tag] = Tray_Live(Msg){}
			live = &rt.tray_live[w.tag]
			if err := virtual.arena_init_growing(&live.mem); err != nil do continue
			live.msgs = make([dynamic]Maybe(Msg))
		}
		// The icon is drawn in the desktop's own foreground colour, which
		// is what "it follows a light or dark taskbar" means; the theme
		// changing re-runs this and the pixels change with it.
		built, msgs := tray_build(w, rt.theme.color.on_surface, virtual.arena_allocator(&live.mem))
		live.click, live.hosted, live.gone = w.on_click, w.on_hosted, w.on_gone
		if live.sent.tag != 0 && tray_same(live.sent, built) {
			// Nothing a desktop can see has changed. The messages are
			// taken anyway: the app may have kept the same menu and
			// changed what an item means.
			tray_take_msgs(live, msgs)
			continue
		}
		shown := true
		if rt.backend != nil && rt.backend.tray_set != nil {
			shown = rt.backend.tray_set(rt.backend, built)
		} else {
			shown = false
		}
		tray_take_msgs(live, msgs)
		live.sent = built
		// A desktop with no tray is an answer: `on_gone` is said on the first
		// attempt too, not only when a hosted item stops being, so an app
		// that falls back to its window knows at the start. `on_hosted`
		// undoes it if a host turns up later.
		if !shown && (live.is_hosted || !live.said) {
			live.is_hosted, live.said = false, true
			if m, has := live.gone.?; has do append(&rt.msgs, m)
		}
	}
	return len(rt.tray_wanted) > 0
}

@(private)
tray_take_msgs :: proc(live: ^Tray_Live($Msg), msgs: [dynamic]Maybe(Msg)) {
	delete(live.msgs)
	live.msgs = msgs
}

// tray_event turns what the desktop reported into the app's own message.
//
// An id names a position in the menu as it was built, so a click that
// crosses a rebuild lands on whatever is in that place now; a rebuilt menu
// with the same shape keeps meaning the same things.
@(private)
tray_event :: proc(rt: ^Runtime($State, $Msg), e: platform.Ev_Tray) {
	live := &rt.tray_live[e.tag]
	if live == nil do return
	switch e.kind {
	case .Hosted:
		if live.is_hosted && live.said do return
		live.is_hosted, live.said = true, true
		if m, has := live.hosted.?; has do append(&rt.msgs, m)
	case .Gone:
		if !live.is_hosted && live.said do return
		live.is_hosted, live.said = false, true
		if m, has := live.gone.?; has do append(&rt.msgs, m)
	case .Clicked:
		if m, has := live.click.?; has do append(&rt.msgs, m)
	case .Chosen:
		i := int(e.id) - 1
		if i < 0 || i >= len(live.msgs) do return
		if m, has := live.msgs[i].?; has do append(&rt.msgs, m)
	}
}

// tray_build turns the app's descriptor into the platform's, giving every
// item an id and collecting what each id means. Ids are the **depth-first
// position**, from 1, so a menu rebuilt with the same shape keeps the same
// ids and the same meanings.
@(private)
tray_build :: proc(d: Tray_Desc($Msg), fg: Color, allocator := context.allocator) -> (platform.Tray_Desc, [dynamic]Maybe(Msg)) {
	msgs := make([dynamic]Maybe(Msg), context.allocator)
	out := platform.Tray_Desc{
		tag       = d.tag,
		title     = strings.clone(d.title, allocator),
		tooltip   = strings.clone(d.tooltip, allocator),
		icon_name = strings.clone(d.icon_name, allocator),
		status    = d.status,
	}
	if d.icon != .None do out.icon = tray_pixmaps(d.icon, fg, allocator)
	out.menu = tray_items(d.menu, fg, &msgs, allocator)
	return out, msgs
}

@(private)
tray_items :: proc(src: []Tray_Item($Msg), fg: Color, msgs: ^[dynamic]Maybe(Msg), allocator: runtime.Allocator) -> []platform.Tray_Item {
	if len(src) == 0 do return nil
	out := make([]platform.Tray_Item, len(src), allocator)
	for it, i in src {
		append(msgs, it.msg)
		out[i] = platform.Tray_Item{
			id        = u32(len(msgs)), // its depth-first position, from 1
			label     = strings.clone(it.label, allocator),
			checked   = it.checked,
			disabled  = it.disabled,
			separator = it.separator,
		}
		if it.icon != .None do out[i].icon = tray_pixmaps(it.icon, fg, allocator)
		if len(it.children) > 0 do out[i].children = tray_items(it.children, fg, msgs, allocator)
	}
	return out
}

// tray_pixmaps rasterises a Lucide icon for a desktop to pick from.
//
// The coverage mask is the picture: `svg_raster`'s 8-bit coverage is what
// macOS wants from a template image, and what the other two want once it
// carries a colour. An icon that follows the taskbar's light or dark is this
// run again with a different `fg`.
@(private)
tray_pixmaps :: proc(which: Icon, fg: Color, allocator := context.allocator) -> []platform.Tray_Pixmap {
	out := make([]platform.Tray_Pixmap, len(TRAY_ICON_SIZES), allocator)
	r := u32(clamp(fg.r, 0, 1) * 255 + 0.5)
	g := u32(clamp(fg.g, 0, 1) * 255 + 0.5)
	b := u32(clamp(fg.b, 0, 1) * 255 + 0.5)
	for px, i in TRAY_ICON_SIZES {
		scale := f32(px) / 24
		paths := svg_flatten(ICON_PATHS[which], scale, context.temp_allocator)
		mask := svg_raster(paths, px, px, 2 * scale, context.temp_allocator)
		argb := make([]u32, px * px, allocator)
		for cov, j in mask {
			// Premultiplied, which is what every one of the three takes.
			a := u32(cov)
			argb[j] = (a << 24) | ((r * a / 255) << 16) | ((g * a / 255) << 8) | (b * a / 255)
		}
		out[i] = platform.Tray_Pixmap{w = px, h = px, argb = argb}
	}
	return out
}

// tray_live_free lets go of one item's memory. The arena holds everything
// the platform descriptor points at, so it goes in one call.
@(private)
tray_live_free :: proc(rt: ^Runtime($State, $Msg), tag: u64) {
	live := &rt.tray_live[tag]
	if live == nil do return
	delete(live.msgs)
	virtual.arena_destroy(&live.mem)
	delete_key(&rt.tray_live, tag)
}

// tray_shutdown takes every item away and frees what they held.
@(private)
tray_shutdown :: proc(rt: ^Runtime($State, $Msg)) {
	going := make([dynamic]u64, context.temp_allocator)
	for tag in rt.tray_live {
		if rt.backend != nil && rt.backend.tray_remove != nil do rt.backend.tray_remove(rt.backend, tag)
		append(&going, tag)
	}
	for tag in going do tray_live_free(rt, tag) // not while the map is being walked
	delete(rt.tray_live)
	delete(rt.tray_wanted)
}

// tray_same says whether two platform descriptors would look the same to a
// desktop. A tray item is re-sent only when this is false, because on Linux
// a menu re-sent is a menu every host re-reads.
@(private)
tray_same :: proc(a, b: platform.Tray_Desc) -> bool {
	if a.tag != b.tag || a.title != b.title || a.tooltip != b.tooltip do return false
	if a.icon_name != b.icon_name || a.status != b.status do return false
	if len(a.icon) != len(b.icon) do return false
	for p, i in a.icon {
		if p.w != b.icon[i].w || p.h != b.icon[i].h do return false
		if len(p.argb) != len(b.icon[i].argb) do return false
		for v, j in p.argb do if v != b.icon[i].argb[j] do return false
	}
	return tray_items_same(a.menu, b.menu)
}

@(private)
tray_items_same :: proc(a, b: []platform.Tray_Item) -> bool {
	if len(a) != len(b) do return false
	for x, i in a {
		y := b[i]
		if x.id != y.id || x.label != y.label || x.disabled != y.disabled || x.separator != y.separator do return false
		xc, xhas := x.checked.?
		yc, yhas := y.checked.?
		if xhas != yhas || (xhas && xc != yc) do return false
		if len(x.icon) != len(y.icon) do return false
		if !tray_items_same(x.children, y.children) do return false
	}
	return true
}
