package baldr

// Popups from shell surfaces. On a .Layer surface, what the
// overlay root would draw beside an anchor (a popover, menu, submenu, select
// list, context menu or tooltip) gets a surface of its own, an xdg_popup on
// Wayland, so a 36 px bar can open a 570 px Control Centre. It stays in the
// same tree: the view builds it as always, layout sizes it free of the bar's
// bounds, and it sits where the compositor placed it; the bar's own drawing,
// hit tests and input region leave it out, and its surface draws only it. A
// press outside a menu or popover (the compositor's grab) sends its dismiss
// message; a tooltip takes no grab.

import "core:fmt"
import "core:math"
import "baldr:gpu"
import "baldr:platform"

// Popup_Place is where a popup's card sits in its tree: the compositor's
// placement, added to its parent's.
@(private)
Popup_Place :: struct {
	origin:   [2]f32,
	placed:   bool,
	glass:      bool,           // its surface shows the desktop through its card
	known:      bool,           // how bright that is: the compositor's report, or what it opened from's until that comes
	backdrop:   Backdrop_Range,
	measured:   bool,           // the compositor's report for its own surface has come
	wait_until: f64,            // clock ms: its first paint waits for that report until then (popup_waiting)
}

// POPUP_BACKDROP_WAIT_MS is the longest a glass popup's first paint waits
// for the compositor to measure what is behind it.
POPUP_BACKDROP_WAIT_MS :: 100.0

// popup_candidate: an overlay child that shows on a popup surface of its own
// in this tree (anything placed beside an anchor or at a point).
@(private)
popup_candidate :: proc(t: ^Tree, c: Node) -> bool {
	if !t.popups_on do return false
	rule, ok := t.overlay_rules[c]
	// A card placed `.Over` its anchor is part of the window's own content;
	// the compositor would place a surface of its own beside the anchor.
	return ok && !rule.cover && rule.edge == .None && rule.placement != .Over
}

// popup_holds says whether `n` is in an overlay child shown on a popup
// surface of its own.
@(private)
popup_holds :: proc(t: ^Tree, n: Node) -> bool {
	if !t.popups_on do return false
	owner := overlay_child_of(t, n)
	return owner != NODE_NONE && popup_candidate(t, owner)
}

// popup_draw_list is what a popup's surface draws: its card's layer.
@(private)
popup_draw_list :: proc(t: ^Tree, n: Node, allocator := context.temp_allocator) -> []Draw_Cmd {
	out := make([dynamic]Draw_Cmd, allocator)
	flatten_layer(t, n, &out)
	return out[:]
}

// Popup_Ctx is an overlay child shown on a surface of its own.
@(private)
Popup_Ctx :: struct {
	node:       Node,
	surf:       platform.Surface,
	parent:     ^Popup_Ctx, // nil: opened from the surface itself
	vk_surf:    Vk_Surface,
	fc:         Frame_Ctx, // its target and frames; fc.origin is the surface's top-left in the tree
	desc:       platform.Popup_Desc, // as last sent
	rel:        [2]f32, // where the compositor put the card, relative to the parent's card
	configured: bool,
	placing:    bool, // a move went to the compositor and its configure hasn't come (popup_resync)
	held:       bool, // a frame waits for that configure…
	held_ms:    f64,  // …to be drawn at the clock it was laid out at
	stuck:      bool, // the backend couldn't move it: popups_sync opens it again instead
	closing:    bool, // scratch for popups_sync
}

// popups_sync opens a popup surface for each popup candidate of `c`'s tree,
// moves one whose card or anchor changed, and closes the ones gone, a popup
// before the one it opened from. Lays out first, so sizes and anchors are
// current. A popup opens once what it opens from has been placed.
@(private)
popups_sync :: proc(b: ^platform.Backend, r: ^gpu.Renderer, c: ^Surface_Ctx($Msg)) {
	t := &c.ui.tree
	on := (c.desc.kind == .Layer || c.kind == .Applet) && b != nil && b.popup_create != nil && .Popups in b.caps && !c.popups_failed
	if t.popups_on != on {
		t.popups_on = on
		mark_layout_dirty(t, t.overlay)
		mark_paint_dirty(t, t.overlay)
	}
	if !on && len(c.popups) == 0 do return
	layout(t, t.viewport)
	for p in c.popups do p.closing = !node_valid(t, p.node) || !popup_candidate(t, p.node) || (p.parent != nil && p.parent.closing) // parents come first
	#reverse for p, i in c.popups do if p.closing do popup_close(b, r, c, i)
	if !on do return
	for ch := node_first(t, t.overlay); ch != NODE_NONE; ch = node_next(t, ch) {
		if !popup_candidate(t, ch) do continue
		existing := popup_of(c, ch)
		desc, parent, ready := popup_desc_of(c, ch, existing)
		if !ready do continue
		if existing == nil {
			popup_open(b, r, c, ch, parent, desc)
			continue
		}
		if !popup_moved(existing.desc, desc) || existing.placing do continue // one move at a time: the next once the compositor has placed this one
		if existing.fc.target != 0 && b.popup_reposition != nil && !existing.stuck {
			// a drawn popup moves with its next frame, so the card it draws is the one placed (popup_resync)
			if !existing.fc.frame_requested && b.surface_request_frame != nil {
				b.surface_request_frame(b, existing.surf)
				existing.fc.frame_requested = true
			}
			continue
		}
		if b.popup_reposition != nil && b.popup_reposition(b, existing.surf, desc) {
			existing.desc = desc
			continue
		}
		// the backend can't move it: open it again, with what was opened from it
		for p in c.popups do p.closing = p == existing || popup_descends(p, existing)
		#reverse for p, i in c.popups do if p.closing do popup_close(b, r, c, i)
		popup_open(b, r, c, ch, parent, desc)
	}
}

// popup_desc_of works out how overlay child `ch` opens: from which surface,
// beside what (in that surface's card), how big, and whether it grabs.
@(private)
popup_desc_of :: proc(c: ^Surface_Ctx($Msg), ch: Node, existing: ^Popup_Ctx) -> (desc: platform.Popup_Desc, parent: ^Popup_Ctx, ready: bool) {
	t := &c.ui.tree
	d := node_get(t, ch)
	rule := t.overlay_rules[ch]
	if d == nil || d.rect.w <= 0 || d.rect.h <= 0 do return
	anchor: [4]f32
	if rule.fixed {
		if existing != nil {
			parent = existing.parent
		} else {
			key := node_get(t, ch).key
			for p in c.popups { // a right-click inside a popup opens its menu from that popup
				if p.node == ch || !p.configured do continue
				// Never a popup holding the same key: that is this node's own
				// predecessor still closing (a drag's ghost remade). Adopted,
				// it would close the newcomer with it, which reopens, adopts
				// the next, and so on.
				if pd := node_get(t, p.node); pd != nil && pd.key != key && rect_contains(pd.abs, rule.at) {
					parent = p
				}
			}
		}
		anchor = {rule.at.x, rule.at.y, 1, 1}
		desc.placement = .At
	} else {
		a := node_get(t, rule.anchor)
		if a == nil do return
		if owner := overlay_child_of(t, rule.anchor); owner != NODE_NONE && owner != ch && popup_candidate(t, owner) {
			parent = popup_of(c, owner)
			if parent == nil || !parent.configured do return
		}
		anchor = {a.abs.x, a.abs.y, a.abs.w, a.abs.h}
		switch rule.placement {
		case .Below: desc.placement = .Below
		case .Above: desc.placement = .Above
		case .Right: desc.placement = .Right
		case .Left:  desc.placement = .Left
		case .Over:  desc.placement = .At // cannot arrive: a card over its anchor is never a popup candidate (below)
		}
		#partial switch rule.align {
		case .Center: desc.align = .Center
		case .End:    desc.align = .End
		}
	}
	desc.parent = c.surf
	if parent != nil {
		origin := t.popups[parent.node].origin
		anchor[0] -= origin.x
		anchor[1] -= origin.y
		desc.parent = parent.surf
	}
	gap := rule.gap
	if edge, on_edge := c.ui.surface.edge.?; on_edge && parent == nil && desc.placement != .At {
		desc.placement = popup_away(edge) // a bar's or applet's popups open away from the screen edge it is on
		anchor = popup_bar_anchor(anchor, edge, t.viewport) // …clear of the bar, not of the button inside it
		gap = POPUP_BAR_GAP
	}
	desc.clear = POPUP_SCREEN_MARGIN
	desc.margin = max(popup_margin(d.style.shadow), POPUP_SCREEN_MARGIN)
	desc.anchor = anchor
	desc.size = {d.rect.w, d.rect.h}
	desc.gap, desc.offset, desc.radius = gap, rule.nudge, d.style.radius
	desc.grab = ch in c.ui.dismiss // menus, popovers, lists; not a tooltip
	if c.ui.tree.glass.popups && has_material(d.style.material) do desc.backdrop = .Blur
	return desc, parent, true
}

// POPUP_BAR_GAP is how far a bar's popup keeps from the bar's outer edge;
// POPUP_SCREEN_MARGIN how far every popup keeps from the screen's edges.
POPUP_BAR_GAP       :: f32(8)
POPUP_SCREEN_MARGIN :: f32(8)

// popup_bar_anchor stretches an anchor inside a bar on screen edge `edge`
// out to the bar's outer edge on the side its popups open, so a popup keeps
// its gap from the bar rather than from the button inside it.
@(private)
popup_bar_anchor :: proc "contextless" (a: [4]f32, edge: Edge, bar: [2]f32) -> [4]f32 {
	r := a
	switch edge {
	case .Top:
		r[3] = bar.y - r[1]
	case .Bottom:
		r[3] = r[1] + r[3]
		r[1] = 0
	case .Left:
		r[2] = bar.x - r[0]
	case .Right:
		r[2] = r[0] + r[2]
		r[0] = 0
	}
	return r
}

// popup_away is the side a popup opens on from a surface on a screen edge:
// away from that edge (below a top bar, above a bottom one, right of a left
// one, left of a right one), sliding along the bar.
@(private)
popup_away :: proc "contextless" (edge: Edge) -> platform.Popup_Placement {
	switch edge {
	case .Top:    return .Below
	case .Bottom: return .Above
	case .Left:   return .Right
	case .Right:  return .Left
	}
	return .Below
}

// popup_margin is the room a card's shadow needs around it on its surface.
@(private)
popup_margin :: proc(sh: Shadow_Style) -> f32 {
	if sh.color.a <= 0 do return 2
	return math.ceil(shadow_reach(sh.blur) + max(abs(sh.offset.x), abs(sh.offset.y))) + 1
}

@(private)
popup_moved :: proc(a, b: platform.Popup_Desc) -> bool {
	return a.anchor != b.anchor || a.size != b.size || a.placement != b.placement || a.align != b.align || a.gap != b.gap ||
		a.offset != b.offset || a.margin != b.margin || a.clear != b.clear || a.radius != b.radius || a.backdrop != b.backdrop
}

@(private)
popup_open :: proc(b: ^platform.Backend, r: ^gpu.Renderer, c: ^Surface_Ctx($Msg), n: Node, parent: ^Popup_Ctx, desc: platform.Popup_Desc) {
	t := &c.ui.tree
	surf, ok := b.popup_create(b, desc)
	if !ok {
		popup_warn(c.desc.tag)
		c.popups_failed = true
		return
	}
	vk_surf: Vk_Surface
	if r != nil {
		vs, vok := b.drawable_create(b, surf, gpu.instance(r))
		if !vok {
			b.surface_destroy(b, surf)
			c.popups_failed = true
			return
		}
		vk_surf = gpu.Drawable(vs)
	}
	p := new(Popup_Ctx)
	p^ = {node = n, surf = surf, parent = parent, vk_surf = vk_surf, desc = desc}
	p.fc = Frame_Ctx{
		tree = t, r = r, backend = b, surface = surf, scale = c.fc.scale, t0 = c.fc.t0, transparent = true,
		debug = c.fc.debug, timing = c.fc.timing, sink = c.fc.sink, popup = n,
		cmds = make([dynamic]gpu.Cmd), damage = make([dynamic][4]f32),
	}
	set_layer(t, n, true)
	// Until its own report comes it reads over what it opened from: the bar
	// beside it, or the popup it opened from.
	place := Popup_Place{glass = desc.backdrop == .Blur, known = t.glass.known, backdrop = t.glass.backdrop, wait_until = clock_ms(&c.fc) + POPUP_BACKDROP_WAIT_MS}
	if parent != nil {
		if pp, has := t.popups[parent.node]; has do place.known, place.backdrop = pp.known, pp.backdrop
	}
	t.popups[n] = place
	delete_key(&t.popup_themes, n)
	append(&c.popups, p)
}

// popup_waiting: a glass popup's first paint waits until the compositor has
// measured what is behind it. Drawn before, it would show a tint made for
// another backdrop that changes a frame later, as if the glass came after
// the popover. Its surface presents meanwhile, empty, so the compositor can
// measure it; POPUP_BACKDROP_WAIT_MS at most, and never where the
// compositor doesn't report.
@(private)
popup_waiting :: proc(t: ^Tree, n: Node, now_ms: f64) -> bool {
	place, ok := t.popups[n]
	return ok && place.glass && t.glass.popups && t.glass.reported && !place.measured && now_ms < place.wait_until
}

// popup_hold keeps a waiting popup's fade-in at its start, so it fades in
// whole once it shows.
@(private)
popup_hold :: proc(t: ^Tree, n: Node) {
	d := node_get(t, n)
	if d == nil || d.style.enter.kind == .None do return
	dur := d.style.enter.duration if d.style.enter.duration > 0 else t.theme.motion.base
	anim_restart(t, n, .Enter, 0, 1, dur, d.style.enter.easing)
}

@(private)
popup_warn :: proc(tag: u64) {
	fmt.eprintfln("baldr: surface %d: a popup could not be opened; its popovers draw inside it", tag)
}

@(private)
popup_close :: proc(b: ^platform.Backend, r: ^gpu.Renderer, c: ^Surface_Ctx($Msg), i: int) {
	p := c.popups[i]
	t := &c.ui.tree
	if t.pointer_scope == p.node do t.pointer_scope = NODE_NONE
	if t.keyboard_popup == p.node do t.keyboard_popup = NODE_NONE // Tab is no longer trapped in it
	hide_surface_closed(c, p.surf, clock_ms(&c.fc)) // it held the pointer or the keyboard no longer, for a surface that hides
	if p.fc.target != 0 {
		gpu.target_remove(r, p.fc.target) // the swapchain goes before the surface it presents to
	} else {
		gpu.drawable_release(r, p.vk_surf) // never became a target: ours to let go of
	}
	b.surface_destroy(b, p.surf)
	delete(p.fc.cmds)
	delete(p.fc.damage)
	delete_key(&t.popups, p.node)
	delete_key(&t.popup_themes, p.node)
	ordered_remove(&c.popups, i)
	free(p)
}

// popups_close_all closes every popup of `c`, the last opened first.
@(private)
popups_close_all :: proc(b: ^platform.Backend, r: ^gpu.Renderer, c: ^Surface_Ctx($Msg)) {
	#reverse for _, i in c.popups do popup_close(b, r, c, i)
}

@(private)
popup_of :: proc(c: ^Surface_Ctx($Msg), n: Node) -> ^Popup_Ctx {
	for p in c.popups do if p.node == n do return p
	return nil
}

@(private)
popup_descends :: proc(q, p: ^Popup_Ctx) -> bool {
	for a := q.parent; a != nil; a = a.parent do if a == p do return true
	return false
}

// popup_configured records where the compositor put a popup's card and
// moves the popups opened from it along.
@(private)
popup_configured :: proc(c: ^Surface_Ctx($Msg), p: ^Popup_Ctx, pos: [2]f32) {
	t := &c.ui.tree
	if !p.configured && t.glass.popups && t.popups[p.node].glass do ask_view(c) // built again with its own theme (glass.odin)
	p.rel = pos
	p.configured = true
	p.placing = false // the move it waited for has landed
	popup_place(c, p)
	mark_layout_dirty(t, p.node) // placed again as layout ends (position_overlay_children); nothing else in the overlay moved, so nothing else is damaged
	for q in c.popups do if popup_descends(q, p) { // parents come first
		popup_place(c, q)
		mark_layout_dirty(t, q.node)
	}
	c.needs_frame = true
}

// popup_resync lays a drawn popup out for the frame it is about to draw.
// When its card or anchor changed, it sends the compositor the new place and
// holds the frame for the configure: drawn then (popup_take_held), at the
// clock it was laid out at, the card is the size and in the place the
// compositor gave it. A popover easing its height through a page change so
// moves once a frame, never drawn at a size its surface hasn't got. One move
// waits at a time. True when the frame waits.
@(private)
popup_resync :: proc(b: ^platform.Backend, c: ^Surface_Ctx($Msg), p: ^Popup_Ctx, now_ms: f64) -> bool {
	if p.placing {
		p.held = true
		return true
	}
	if b == nil || b.popup_reposition == nil || p.stuck do return false
	t := &c.ui.tree
	anim_tick(t, now_ms)
	layout(t, t.viewport)
	desc, _, ready := popup_desc_of(c, p.node, p)
	if !ready || !popup_moved(p.desc, desc) do return false
	if !b.popup_reposition(b, p.surf, desc) {
		p.stuck = true
		return false
	}
	p.desc = desc
	p.placing, p.held, p.held_ms = true, true, now_ms
	return true
}

// popup_take_held says whether popup `p`'s held frame is due, its configure
// come or POPUP_PLACE_WAIT_MS gone without it, and the clock to draw it at.
// Taking it ends the hold.
@(private)
popup_take_held :: proc(p: ^Popup_Ctx, now_ms: f64) -> (pin_ms: f64, due: bool) {
	if !p.held || (p.placing && now_ms < p.held_ms + POPUP_PLACE_WAIT_MS) do return
	p.held, p.placing = false, false
	p.fc.frame_requested = false
	return p.held_ms, true
}

// POPUP_PLACE_WAIT_MS is the longest a popup's frame waits for the
// compositor to place it after a move.
POPUP_PLACE_WAIT_MS :: 50.0

@(private)
popup_place :: proc(c: ^Surface_Ctx($Msg), p: ^Popup_Ctx) {
	if !p.configured do return
	t := &c.ui.tree
	base: [2]f32
	if p.parent != nil do base = t.popups[p.parent.node].origin
	origin := base + p.rel
	if place, ok := &t.popups[p.node]; ok {
		place.origin, place.placed = origin, true
	} else {
		t.popups[p.node] = {origin = origin, placed = true}
	}
	p.fc.origin = origin - p.desc.margin
}

// popup_dismissed: the compositor closed a popup (a press outside its
// grab), so it closes as a press outside it would close it.
@(private)
popup_dismissed :: proc(c: ^Surface_Ctx($Msg), p: ^Popup_Ctx) {
	if p.node in c.ui.dismiss {
		fire_dismiss(&c.ui, p.node, "the compositor dismissed its popup")
	} else if c.ui.tip_anchor != NODE_NONE {
		tooltip_hide(&c.ui)
	}
	c.needs_frame = true
}

// popup_pointer maps a position on surface `s` into `c`'s tree, and keeps
// the tree's hits inside the popup the pointer is over (none: the surface's
// own content).
@(private)
popup_pointer :: proc(c: ^Surface_Ctx($Msg), s: platform.Surface, pos: [2]f32) -> [2]f32 {
	for p in c.popups {
		if p.surf == s {
			c.ui.tree.pointer_scope = p.node
			return pos + p.fc.origin
		}
	}
	c.ui.tree.pointer_scope = NODE_NONE
	return pos - c.fc.slide // a surface sliding off its edge draws its tree moved
}

// target_why puts the renderer's refusal into a few words for the lines
// below. The renderer has already printed the precise error on stderr with
// a "gpu:" prefix (its last_error); this names the kind of fault, so a
// driver that cannot present does not read like a slot leak.
@(private)
target_why :: proc(r: ^gpu.Renderer) -> string {
	switch gpu.target_fault(r) {
	case .Slots:    return fmt.tprintf("all %d GPU targets are in use", gpu.MAX_TARGETS)
	case .Drawable: return "there is nothing for the GPU to draw into"
	case .Device:   return "no GPU device could be made for it"
	case .Surface:  return "the GPU cannot present to it"
	case .Objects:  return "its swapchain could not be made"
	case .None:     // target_add said no and set nothing: it should not happen
	}
	return "the renderer did not say"
}

// target_retry says whether a surface that could not get a GPU target is
// worth asking for again on its next configure. Only a full slot table
// clears itself, when another window or popup closes; every other fault
// belongs to this window or device and would give the same answer forever.
@(private)
target_retry :: proc(fault: gpu.Target_Fault) -> bool {
	return fault == .Slots
}

// target_warn_popup and target_warn_surface say, once per surface, that the
// renderer would not give it a target, and why. Once, because a drag can
// open popups as fast as it closes them and a line per attempt would be a
// line per frame; said at all, because the fallbacks are otherwise silent.
@(private)
target_warn_popup :: proc(c: ^Surface_Ctx($Msg), why: string) {
	if c.target_warned do return
	c.target_warned = true
	fmt.eprintfln("baldr: surface %d: no GPU target for a popup (%s); its popovers draw inside it",
		c.desc.tag, why)
}

@(private)
target_warn_surface :: proc(c: ^Surface_Ctx($Msg), why: string) {
	if c.target_warned do return
	c.target_warned = true
	fmt.eprintfln("baldr: surface %d: no GPU target yet (%s); it draws nothing until one frees up",
		c.desc.tag, why)
}

// target_fail_surface is the end of the road for a window: the renderer
// cannot present to it and nothing it waits for will change that, so the run
// ends with the reason on stderr (run returns .Gpu). A popup can draw inside
// its parent instead; a window cannot, and an app alive but drawing nothing
// looks healthy enough that nothing would restart it.
@(private)
target_fail_surface :: proc(c: ^Surface_Ctx($Msg), why: string) {
	fmt.eprintfln("baldr: surface %d cannot be drawn on: %s. Nothing would ever show in it, so the app stops here.",
		c.desc.tag, why)
}
