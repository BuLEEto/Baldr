package baldr

import "core:math"

// Scroll containers. A node flagged Scroll_V / Scroll_H lets its children
// overflow along that axis; layout shifts them by Scroll_State.offset, so
// hit-testing, focus, and painting all see the true positions — nothing is
// special-cased downstream. Wheel input bubbles from the node under the
// pointer to the nearest ancestor that can still move in that direction. An
// overlay scrollbar fades in while scrolling and can be dragged.

Scroll_State :: struct {
	offset:           [2]f32, // logical px scrolled (0 = top/left)
	shift_since_layout: [2]f32, // offset change since the last layout: a scroll is not a move to animate
	content:          [2]f32, // laid-out content size (inside padding)
	viewport:         [2]f32, // visible size (inside padding)
	last_activity_ms: f64,    // for the scrollbar fade
	velocity:         [2]f32, // px/s while flinging after a touch pan
	fling:            bool,
	target:           [2]f32, // where a smooth scroll is heading
	smooth:           bool,
	thumb_drag:       bool,
	thumb_axis:       int,  // …which bar: 1 the vertical one, 0 the horizontal one
	drag_start_off:   f32,
	drag_start_pos:   f32,
	follow_end:       bool, // asked for by the builder: stay at the end while the content grows
	at_end:           bool, // …and it is there now, so growth takes it with it
}

// SCROLL_END_EPS is how near the end still counts as at it: a fractional
// line left over from a layout must not stop a chat following its own
// last message.
SCROLL_END_EPS :: f32(2)

// scroll_at_end says whether `off` is at the end of what there is to
// scroll, along the axis that scrolls.
@(private)
scroll_at_end :: proc "contextless" (st: Scroll_State, off: [2]f32, vertical: bool) -> bool {
	if vertical do return off.y >= max(st.content.y - st.viewport.y, 0) - SCROLL_END_EPS
	return off.x >= max(st.content.x - st.viewport.x, 0) - SCROLL_END_EPS
}

SCROLLBAR_W         :: f32(6)   // resting width
SCROLLBAR_W_WIDE    :: f32(10)  // while the pointer is in the bar zone or dragging
SCROLLBAR_MARGIN    :: f32(3)
SCROLLBAR_ZONE      :: f32(18)  // px from the right edge that count as "on the bar"
SCROLLBAR_MIN_THUMB :: f32(24)
SCROLLBAR_LINGER_MS :: f64(900)
SCROLLBAR_IDLE      :: f32(0.55) // opacity while the pointer merely rests inside the container
// What `scroll(…, gutter = true)` keeps clear at the end for the bar: its
// widest form plus the margin on each side, so a control right-aligned in
// the content never ends up underneath it.
SCROLLBAR_GUTTER    :: SCROLLBAR_W_WIDE + 2 * SCROLLBAR_MARGIN
SCROLL_FRICTION     :: f32(4.5)  // fling decay per second (e^-4.5 ≈ 1% left after a second)
SCROLL_FLING_MIN    :: f32(40)   // px/s below which a fling stops
REVEAL_MARGIN       :: f32(4)    // scroll_into_view keeps this much room around the node

// scroll_state_new is a fresh state whose scrollbar is hidden (no activity yet).
scroll_state_new :: proc "contextless" () -> Scroll_State {
	return {last_activity_ms = -1e12}
}

// scroll_clamp keeps an offset inside [0, content - viewport] per axis.
scroll_clamp :: proc "contextless" (st: Scroll_State, off: [2]f32) -> [2]f32 {
	return {
		clamp(off.x, 0, max(st.content.x - st.viewport.x, 0)),
		clamp(off.y, 0, max(st.content.y - st.viewport.y, 0)),
	}
}

// scroll_offset returns the current offset of a scroll container (zero for
// anything else).
scroll_offset :: proc(t: ^Tree, n: Node) -> [2]f32 {
	if st, ok := t.scrolls[n]; ok do return st.offset
	return {}
}

// scroll_viewport is how much of a scroll container is visible: the size
// inside its padding, as the last layout measured it (zero for anything
// else, and before the first layout). An app needs it to say where in the
// view it wants something: `hold_at` is px into the viewport, so holding the
// middle still across a zoom asks for half of this. Read it in the build
// that uses it rather than keeping it, since a window resize changes it.
scroll_viewport :: proc(t: ^Tree, n: Node) -> [2]f32 {
	if st, ok := t.scrolls[n]; ok do return st.viewport
	return {}
}

// scroll_to sets the offset (clamped) and re-lays the container. Returns true
// if it moved.
scroll_to :: proc(t: ^Tree, n: Node, off: [2]f32) -> bool {
	d := node_get(t, n)
	if d == nil || (.Scroll_V not_in d.flags && .Scroll_H not_in d.flags) do return false
	st := &t.scrolls[n]
	if st == nil {
		t.scrolls[n] = scroll_state_new()
		st = &t.scrolls[n]
	}
	want := scroll_clamp(st^, off)
	if .Scroll_V not_in d.flags do want.y = st.offset.y
	if .Scroll_H not_in d.flags do want.x = st.offset.x
	if want != st.offset do st.at_end = scroll_at_end(st^, want, .Scroll_V in d.flags) // the person put it here: follow again only at the end
	if want == st.offset do return false
	st.shift_since_layout += want - st.offset
	st.offset = want
	st.smooth = false // any direct move ends a smooth scroll (the ticker re-arms it)
	st.last_activity_ms = t.now_ms
	tree_wake_at(t, t.now_ms + SCROLLBAR_LINGER_MS + 1, n)
	mark_layout_dirty(t, n)
	return true
}

// scroll_by moves by a delta (logical px). Returns true if it moved.
scroll_by :: proc(t: ^Tree, n: Node, delta: [2]f32) -> bool {
	return scroll_to(t, n, scroll_offset(t, n) + delta)
}

// scroll_event dispatches a wheel/trackpad delta at `pos`: a control under
// the pointer that listens for scrolls (`on_scroll`) takes it; else the
// innermost scroll container that can move in that direction; otherwise it
// bubbles up. `precise` marks a touchpad. Returns true if anything moved or
// a message was queued.
scroll_event :: proc(ui: ^Ui($Msg), pos: [2]f32, delta: [2]f32, precise := false, mods: Mods = {}) -> bool {
	t := &ui.tree
	if scroll_send(ui, pos, delta, precise, mods) do return true // a control that listens to the wheel (a tray icon)
	if chrome_wheel(ui, pos, delta) do return true // a title bar that rolls its window up and down (widget_chrome.odin)
	if time_wheel(ui, hit_test(t, pos), delta) do return true // a wheel over a time segment steps it
	for cur := hit_test(t, pos); cur != NODE_NONE; cur = node_get(t, cur).parent {
		d := node_get(t, cur)
		if d == nil do break
		if .Scroll_V in d.flags || .Scroll_H in d.flags {
			dl := delta
			// A wheel over a strip that only scrolls sideways scrolls it sideways.
			if .Scroll_H in d.flags && .Scroll_V not_in d.flags && dl.x == 0 do dl = {dl.y, 0}
			if st, ok := &t.scrolls[cur]; ok do st.fling = false
			if scroll_by(t, cur, dl) do return true
		}
	}
	return false
}

// scroll_to_smooth eases the offset to `off` over a short time (keyboard
// jumps, reveals): the same clamping as scroll_to, instant under
// reduce-motion. Wheel, drag or fling input takes over immediately.
scroll_to_smooth :: proc(t: ^Tree, n: Node, off: [2]f32) -> bool {
	d := node_get(t, n)
	if d == nil || (.Scroll_V not_in d.flags && .Scroll_H not_in d.flags) do return false
	st := &t.scrolls[n]
	if st == nil do return scroll_to(t, n, off)
	want := scroll_clamp(st^, off)
	if .Scroll_V not_in d.flags do want.y = st.offset.y
	if .Scroll_H not_in d.flags do want.x = st.offset.x
	if want != st.offset do st.at_end = scroll_at_end(st^, want, .Scroll_V in d.flags)
	if want == st.offset do return false
	if t.theme.motion.reduce do return scroll_to(t, n, want)
	st.target = want
	st.smooth = true
	st.fling = false
	st.last_activity_ms = t.now_ms
	t.anim_active = true
	mark_paint_dirty(t, n)
	return true
}

SCROLL_SMOOTH_RATE :: f32(16) // per second: the remaining distance shrinks by e^-16·dt (≈ 200 ms to settle)

// scroll_fling starts a decelerating scroll at `velocity` px/s (a touch pan
// let go). Instant stop under reduce-motion.
scroll_fling :: proc(t: ^Tree, n: Node, velocity: [2]f32) {
	st := &t.scrolls[n]
	if st == nil || t.theme.motion.reduce do return
	if abs(velocity.x) + abs(velocity.y) < SCROLL_FLING_MIN do return
	st.velocity = velocity
	st.fling = true
	t.anim_active = true
}

// scroll_tick advances flings by `dt` seconds. Called by anim_tick.
@(private)
scroll_tick :: proc(t: ^Tree, dt: f32) -> (active: bool) {
	if dt <= 0 do return
	for n, &st in t.scrolls {
		if st.smooth {
			if node_get(t, n) == nil {
				st.smooth = false
				continue
			}
			rem := st.target - st.offset
			next := st.target
			if abs(rem.x) > 0.5 || abs(rem.y) > 0.5 do next = st.offset + rem * (1 - math.exp(-SCROLL_SMOOTH_RATE * dt))
			target := st.target
			scroll_to(t, n, next) // clears smooth; re-arm unless we have arrived
			if st.offset != target {
				st.smooth = true
				st.target = target
				active = true
			}
			continue
		}
		if !st.fling do continue
		if node_get(t, n) == nil {
			st.fling = false
			continue
		}
		moved := scroll_by(t, n, st.velocity * dt)
		st.velocity *= math.exp(-SCROLL_FRICTION * dt)
		if !moved || abs(st.velocity.x) + abs(st.velocity.y) < SCROLL_FLING_MIN {
			st.fling = false
			st.velocity = {}
		}
		active = true
	}
	return
}

// scroll_ancestor_axis returns the nearest ancestor of `n` (or `n`) that
// scrolls along the given axis (0 = horizontal, 1 = vertical), or NONE.
scroll_ancestor_axis :: proc(t: ^Tree, n: Node, axis: int) -> Node {
	for cur := n; cur != NODE_NONE; cur = node_get(t, cur).parent {
		d := node_get(t, cur)
		if d == nil do return NODE_NONE
		if axis == 0 && .Scroll_H in d.flags do return cur
		if axis == 1 && .Scroll_V in d.flags do return cur
	}
	return NODE_NONE
}

// scrollbar_overflows says whether `n` has more content than viewport along
// `axis` (0 horizontal, 1 vertical), and so a bar to show for it.
@(private)
scrollbar_overflows :: proc "contextless" (d: ^Node_Data, st: Scroll_State, axis: int) -> bool {
	if axis == 1 && .Scroll_V not_in d.flags do return false
	if axis == 0 && .Scroll_H not_in d.flags do return false
	return st.content[axis] > st.viewport[axis] + 0.5
}

// scrollbar_geometry returns the overlay scrollbar's track and thumb rects —
// the vertical one by default, the one along the bottom with `axis = 0` — or
// ok = false when nothing overflows that way. Where a container scrolls
// both ways each track stops short of the other's end, so the two thumbs
// never sit on top of each other in the corner.
scrollbar_geometry :: proc(t: ^Tree, n: Node, axis := 1) -> (track, thumb: Rect, ok: bool) {
	d := node_get(t, n)
	if d == nil do return
	st, has := t.scrolls[n]
	if !has || !scrollbar_overflows(d, st, axis) do return
	lk := scrollbar_look(&t.theme)
	w := lk.hover_width if (st.thumb_drag && st.thumb_axis == axis) || (t.bar_hover == n && t.bar_hover_axis == axis) else lk.width
	short: f32 = lk.gutter if scrollbar_overflows(d, st, 1 - axis) else 0 // room for the other bar's end
	if axis == 1 {
		track = Rect{
			d.abs.x + d.abs.w - w - lk.margin,
			d.abs.y + lk.margin,
			w,
			d.abs.h - 2 * lk.margin - short,
		}
	} else {
		track = Rect{
			d.abs.x + lk.margin,
			d.abs.y + d.abs.h - w - lk.margin,
			d.abs.w - 2 * lk.margin - short,
			w,
		}
	}
	long := track.h if axis == 1 else track.w
	if long <= 0 do return
	frac := st.viewport[axis] / st.content[axis]
	len_ := max(long * frac, min(lk.min_thumb, long))
	travel := long - len_
	pos := travel * (st.offset[axis] / max(st.content[axis] - st.viewport[axis], 1))
	thumb = Rect{track.x, track.y + pos, track.w, len_} if axis == 1 else Rect{track.x + pos, track.y, len_, track.h}
	return track, thumb, true
}

// scrollbar_visible is the 0..1 fade amount of the scrollbar for painting:
// full while scrolling, dragging, or with the pointer in the bar zone; dimmed
// while the pointer rests anywhere inside the container; gone otherwise.
scrollbar_visible :: proc(t: ^Tree, n: Node) -> f32 {
	st, has := t.scrolls[n]
	if !has do return 0
	recent := st.thumb_drag || t.now_ms - st.last_activity_ms < SCROLLBAR_LINGER_MS
	if recent && !st.thumb_drag do tree_wake_at(t, st.last_activity_ms + SCROLLBAR_LINGER_MS + 1, n)
	target: f32 = 0
	switch {
	case recent || t.bar_hover == n: target = 1
	case t.scroll_hover == n:        target = SCROLLBAR_IDLE
	}
	return anim_target(t, n, .Scroll, target, t.theme.motion.fast if target > 0 else t.theme.motion.base)
}

// scrollbar_zone is the strip along the right edge — the bottom edge with
// `axis = 0` — where presses go to the scrollbar and the pointer counts as
// hovering it (wider than the bar).
scrollbar_zone :: proc(t: ^Tree, n: Node, axis := 1) -> (zone: Rect, ok: bool) {
	track, _, has := scrollbar_geometry(t, n, axis)
	if !has do return
	d := node_get(t, n)
	thick, grabbable := scrollbar_grab(d.abs.h if axis == 0 else d.abs.w, scrollbar_look(&t.theme).reach)
	if !grabbable do return
	if axis == 1 do return Rect{d.abs.x + d.abs.w - thick, track.y, thick, track.h}, true
	return Rect{track.x, d.abs.y + d.abs.h - thick, track.w, thick}, true
}

// scrollbar_grab is how far in from the edge counts as "on the bar" for a
// press, across a container `cross` wide (tall, for the bottom bar), and
// whether the bar can be grabbed at all. `SCROLLBAR_ZONE` is the slop that
// makes a thin bar hittable on a long list, but on a short container (a
// 36 px tab strip) it would cover the content, so the zone is capped at a
// third of the container, and below the bar's own footprint it is not
// offered: there the bar is an indicator, moved by the wheel, the keyboard
// and reveals. `reach` is the widest bar's footprint from the edge; the zone
// is never narrower, or a wide themed bar could not be grabbed anywhere.
@(private)
scrollbar_grab :: proc(cross: f32, reach: f32 = SCROLLBAR_W_WIDE + SCROLLBAR_MARGIN) -> (thick: f32, grabbable: bool) {
	thick = min(max(SCROLLBAR_ZONE, reach), cross / 3)
	return thick, thick >= reach
}

// scroll_ancestor returns `n` or its nearest ancestor that scrolls (or NONE).
scroll_ancestor :: proc(t: ^Tree, n: Node) -> Node {
	for cur := n; cur != NODE_NONE; cur = node_get(t, cur).parent {
		d := node_get(t, cur)
		if d == nil do return NODE_NONE
		if .Scroll_V in d.flags || .Scroll_H in d.flags do return cur
	}
	return NODE_NONE
}

// scroll_hover_update tracks which container (and whose bar zone) the
// pointer is over so the bar can reveal itself. Returns true if paint changed.
scroll_hover_update :: proc(t: ^Tree, hit: Node, pos: [2]f32) -> (changed: bool) {
	sc := scroll_ancestor(t, hit)
	bar, bar_axis := NODE_NONE, 1
	if sc != NODE_NONE {
		// The vertical bar first. The two zones cannot overlap (each track
		// stops short of the other's end), so the corner between them is
		// neither bar's and a press there reaches the content.
		for axis in ([]int{1, 0}) {
			if zone, ok := scrollbar_zone(t, sc, axis); ok && rect_contains(zone, pos) {
				bar, bar_axis = sc, axis
				break
			}
		}
	}
	if sc != t.scroll_hover {
		if t.scroll_hover != NODE_NONE do mark_paint_dirty(t, t.scroll_hover)
		t.scroll_hover = sc
		if sc != NODE_NONE do mark_paint_dirty(t, sc)
		changed = true
	}
	if bar != t.bar_hover || (bar != NODE_NONE && bar_axis != t.bar_hover_axis) {
		if t.bar_hover != NODE_NONE do mark_paint_dirty(t, t.bar_hover)
		t.bar_hover, t.bar_hover_axis = bar, bar_axis
		if bar != NODE_NONE do mark_paint_dirty(t, bar)
		changed = true
	}
	return
}

// scroll_into_view scrolls every scrolling ancestor, on whichever axis it
// scrolls, so that `n` is visible (keyboard focus must never land
// off-screen). Smooth unless `instant` (a resize never animates). Returns
// true if any moved.
scroll_into_view :: proc(t: ^Tree, n: Node, instant := false) -> (moved: bool) {
	d := node_get(t, n)
	if d == nil do return
	return scroll_rect_into_view(t, n, d.abs, instant)
}

// scroll_rect_into_view brings a rect *inside* `n` into view — a moving
// selection end in a reply, where the node itself is already as tall as its
// content and only part of it is on screen. `rect` is in absolute
// coordinates. scroll_into_view is this with the node's own rect.
@(private)
scroll_rect_into_view :: proc(t: ^Tree, n: Node, rect: Rect, instant := false) -> (moved: bool) {
	nd := node_get(t, n)
	if nd == nil do return
	// A small margin keeps the focus ring (drawn just outside the node)
	// clear of the container's clip edge, however far a theme's ring reaches.
	m := max(REVEAL_MARGIN, focus_ring_look(&t.theme).overhang)
	for cur := nd.parent; cur != NODE_NONE; cur = node_get(t, cur).parent {
		cd := node_get(t, cur)
		if cd == nil do break
		if .Scroll_V not_in cd.flags && .Scroll_H not_in cd.flags do continue
		st, ok := t.scrolls[cur]
		if !ok do continue
		delta: [2]f32
		if .Scroll_V in cd.flags {
			y0 := cd.abs.y + cd.layout.padding[0]
			y1 := y0 + st.viewport.y
			if rect.y - m < y0 {
				delta.y = rect.y - m - y0
			} else if rect.y + rect.h + m > y1 {
				delta.y = rect.y + rect.h + m - y1
			}
		}
		if .Scroll_H in cd.flags {
			x0 := cd.abs.x + cd.layout.padding[3]
			x1 := x0 + st.viewport.x
			if rect.x - m < x0 {
				delta.x = rect.x - m - x0
			} else if rect.x + rect.w + m > x1 {
				delta.x = rect.x + rect.w + m - x1
			}
		}
		if delta != {} {
			if instant {
				if scroll_to(t, cur, st.offset + delta) do moved = true
			} else if scroll_to_smooth(t, cur, st.offset + delta) {
				moved = true
			}
		}
	}
	return
}

// scroll_key scrolls the container that has keyboard focus inside it (else
// the one under the pointer) by a page or to an end. Returns true if it moved.
//
// `hover_claims` is false when the window bound this key with `shortcut`:
// the pointer merely resting over a scroll is a weaker claim on a Page key
// than a binding is. A scroll the keyboard is inside still takes the key
// first either way.
scroll_key :: proc(t: ^Tree, key: Key, hover_claims := true, mods: Mods = {}) -> bool {
	n := scroll_ancestor(t, t.focus)
	if n == NODE_NONE && hover_claims do n = t.scroll_hover
	if n == NODE_NONE do return false
	st, ok := t.scrolls[n]
	d := node_get(t, n)
	if !ok || d == nil do return false
	// Which way the keys go: down a container that scrolls vertically;
	// across one that only scrolls sideways, as the wheel does; and across
	// either with Shift held, so a surface that scrolls both ways can be
	// panned from the keyboard. A view has had its say before this, so a
	// Shift+Page a table uses to extend its selection never reaches here.
	axis := 1 if .Scroll_V in d.flags else 0
	if .Shift in mods && .Scroll_H in d.flags do axis = 0
	page := st.viewport[axis] * 0.9
	from := st.target if st.smooth else st.offset
	to := from
	#partial switch key {
	case .Page_Down: to[axis] = from[axis] + page
	case .Page_Up:   to[axis] = from[axis] - page
	case .Home:      to[axis] = 0
	case .End:       to[axis] = st.content[axis]
	case:            return false
	}
	return scroll_to_smooth(t, n, to)
}

// scrollbar_press starts a thumb drag if `pos` is in the bar zone: on the
// thumb it grabs, on the track it jumps the thumb there. Returns true if the
// press was consumed.
scrollbar_press :: proc(t: ^Tree, n: Node, pos: [2]f32) -> bool {
	for axis in ([]int{1, 0}) do if scrollbar_press_axis(t, n, pos, axis) do return true // the vertical bar first
	return false
}

@(private)
scrollbar_press_axis :: proc(t: ^Tree, n: Node, pos: [2]f32, axis: int) -> bool {
	track, thumb, ok := scrollbar_geometry(t, n, axis)
	zone, _ := scrollbar_zone(t, n, axis)
	if !ok || !rect_contains(zone, pos) do return false
	if axis == 1 {
		thumb.x, thumb.w = zone.x, zone.w // grab anywhere across the zone at the thumb's height
	} else {
		thumb.y, thumb.h = zone.y, zone.h // …or along it, at the thumb's place
	}
	st := &t.scrolls[n]
	if !rect_contains(thumb, pos) {
		// Track click: centre the thumb on the pointer.
		travel := (track.h - thumb.h) if axis == 1 else (track.w - thumb.w)
		along := (pos.y - track.y - thumb.h / 2) if axis == 1 else (pos.x - track.x - thumb.w / 2)
		frac := clamp(along / max(travel, 1), 0, 1)
		want := st.offset
		want[axis] = frac * (st.content[axis] - st.viewport[axis])
		scroll_to(t, n, want)
		_, thumb, _ = scrollbar_geometry(t, n, axis)
	}
	st.thumb_drag = true
	st.thumb_axis = axis
	st.drag_start_off = st.offset[axis]
	st.drag_start_pos = pos.y if axis == 1 else pos.x
	st.last_activity_ms = t.now_ms
	mark_paint_dirty(t, n)
	return true
}

scrollbar_drag :: proc(t: ^Tree, n: Node, pos: [2]f32) -> bool {
	st := &t.scrolls[n]
	if st == nil || !st.thumb_drag do return false
	axis := st.thumb_axis
	track, thumb, ok := scrollbar_geometry(t, n, axis)
	if !ok do return false
	travel := max((track.h - thumb.h) if axis == 1 else (track.w - thumb.w), 1)
	per_px := (st.content[axis] - st.viewport[axis]) / travel
	at := pos.y if axis == 1 else pos.x
	want := st.offset
	want[axis] = st.drag_start_off + (at - st.drag_start_pos) * per_px
	return scroll_to(t, n, want)
}

scrollbar_release :: proc(t: ^Tree, n: Node) {
	if st := &t.scrolls[n]; st != nil && st.thumb_drag {
		st.thumb_drag = false
		st.last_activity_ms = t.now_ms
		tree_wake_at(t, t.now_ms + SCROLLBAR_LINGER_MS + 1, n)
		mark_paint_dirty(t, n)
	}
}
