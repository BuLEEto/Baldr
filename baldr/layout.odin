package baldr

import "base:runtime"

import "core:strings"

import "core:math"
import "core:unicode/utf8"

// Layout protocol: constraints go down, sizes come up, the parent positions.
// Single pass. A node that is not dirty and receives the same constraints as
// last time returns its cached size without visiting its subtree — that is
// what makes a local change cheap in a large tree.

Axis    :: enum u8 { Column, Row, Stack, Wrap, Wrap_Column } // Stack: children overlap at the padding origin (+ their `offset`); Wrap: a row that breaks into lines; Wrap_Column: a column that breaks into columns
Align   :: enum u8 { Start, Center, End, Stretch }               // cross axis
Justify :: enum u8 { Start, Center, End, Space_Between, Space_Around, Space_Evenly } // main axis

// Layout_Props is everything a node says about its own size and how it lays
// out children. Zero means "auto" for sizes and "none" for limits.
Layout_Props :: struct {
	axis:                       Axis,
	offset:                     [2]f32, // position inside a Stack parent (ignored elsewhere)
	width, height:              f32,
	min_w, min_h, max_w, max_h: f32,
	flex:                       f32,    // > 0: share of the parent's free main-axis space
	padding:                    [4]f32, // top, right, bottom, left
	gap:                        f32,
	align:                      Align,
	justify:                    Justify,
	// content_w is the width a container that scrolls sideways lays its
	// children out to, past its own (`scroll` / `list`'s `content_width`: a
	// zoomed document's widest page). It is the children's minimum, never
	// the container's, which still shrinks with the window (and
	// `min_content_width` still lets a row squeeze it); a child wider than
	// it keeps its width, with the others widened to match.
	content_w:                  f32,
}

Constraints :: struct {
	min, max: [2]f32,
}

// UNBOUNDED marks an axis with no upper limit (a scroll viewport's content axis).
UNBOUNDED :: f32(1e30)

is_bounded :: proc "contextless" (v: f32) -> bool { return v < UNBOUNDED * 0.5 }

constraints_tight :: proc "contextless" (size: [2]f32) -> Constraints { return {size, size} }
constraints_loose :: proc "contextless" (max: [2]f32) -> Constraints { return {{0, 0}, max} }

constrain :: proc "contextless" (c: Constraints, size: [2]f32) -> [2]f32 {
	return {clamp(size.x, c.min.x, c.max.x), clamp(size.y, c.min.y, c.max.y)}
}

pad4 :: proc "contextless" (p: f32) -> [4]f32 { return {p, p, p, p} }

// measure_text_mono is the headless text measurer: fixed advance of half the
// font size, line height 1.25×. Deterministic, so tests can assert numbers.
measure_text_mono :: proc(t: ^Tree, s: string, size: f32, max_w: f32, weight: Font_Weight, mono: bool = false, family: Family_Id = 0, tabular: bool = false) -> [2]f32 {
	adv := size * 0.5
	lh := size * 1.25
	n := f32(utf8.rune_count_in_string(s))
	if n == 0 do return {0, lh}
	if max_w > 0 && n * adv > max_w {
		per_line := max(f32(int(max_w / adv)), 1)
		lines := math.ceil(n / per_line)
		return {min(n * adv, per_line * adv), lines * lh}
	}
	return {n * adv, lh}
}

// TOUCH_TARGET is the minimum height of an interactive node, in logical px,
// while a touchscreen is present.
TOUCH_TARGET :: f32(44)

// set_touch records whether a touchscreen is present and re-lays out every
// node, since interactive targets change size (layout_node's minimum).
set_touch :: proc(t: ^Tree, touch: bool) {
	if t.touch == touch do return
	t.touch = touch
	relayout_all(t)
}

// relayout_all lays every node out again: something every interactive
// node's size depends on changed (a touchscreen came or went, the theme's
// `min_target`).
@(private)
relayout_all :: proc(t: ^Tree) {
	for &d, i in t.nodes {
		if i == 0 || .Alive not_in d.flags do continue
		d.flags += {.Dirty_Layout}
	}
	mark_layout_dirty(t, t.overlay)
	mark_layout_dirty(t, t.root)
}

// target_min is the smallest an interactive node is laid out, across and
// down: the theme's `min_target` both ways, and at least
// TOUCH_TARGET tall while a touchscreen is present.
@(private)
target_min :: proc "contextless" (t: ^Tree) -> [2]f32 {
	m := max(t.theme.min_target, 0)
	return {m, max(m, TOUCH_TARGET if t.touch else 0)}
}

// layout runs the layout pass for every queued dirty root. The root is laid
// out tight to `viewport`. Boundaries whose size changed escalate to their
// parent, so the pass converges to a consistent tree.
layout :: proc(t: ^Tree, viewport: [2]f32) {
	set_viewport(t, viewport)
	layout_pass(t)
	if t.viewport_changed && tab_bars_reveal_selected(t) do layout_pass(t) // a narrower window must not hide the current tab
	if t.reveal != NODE_NONE {
		n := t.reveal
		t.reveal = NODE_NONE
		if node_valid(t, n) && scroll_into_view(t, n) do layout_pass(t)
	}
	area_reveals(t) // a position an app asked an editor to show, now each editor has its width and heights
	t.viewport_changed = false
}

@(private)
layout_pass :: proc(t: ^Tree) {
	viewport := t.viewport
	for len(t.dirty_roots) > 0 {
		n := pop(&t.dirty_roots)
		d := node_get(t, n)
		if d == nil do continue
		d.flags -= {.Dirty_Root}
		if .Dirty_Layout not_in d.flags do continue
		if t.layout_here do t.layouts += 1

		c := d.cached_c
		origin: [2]f32
		top := n == t.root || n == t.overlay
		if top {
			c = constraints_tight(viewport)
		} else {
			p := node_get(t, d.parent)
			if p == nil do continue
			origin = {p.abs.x, p.abs.y}
		}
		old := [2]f32{d.rect.w, d.rect.h}
		size := layout_node(t, n, c)
		if !top && size != old {
			// A boundary whose size changed is not a boundary for this change:
			// its parent must reposition siblings.
			mark_layout_dirty(t, d.parent)
			continue
		}
		if top do d.rect = {0, 0, size.x, size.y}
		t.damage_off = popup_holds(t, n) // what moves inside a popup is its own surface's, which presents whole
		resolve_abs(t, n, origin, ancestor_clip(t, n))
		t.damage_off = false
	}
	t.layout_here = false
	position_overlay_children(t)
}

// ancestor_clip is the intersection of every clipping ancestor's rect above
// `n` (absolute px); unbounded when none clips.
@(private)
ancestor_clip :: proc(t: ^Tree, n: Node) -> Rect {
	clip := Rect{-UNBOUNDED / 2, -UNBOUNDED / 2, UNBOUNDED, UNBOUNDED}
	d := node_get(t, n)
	if d == nil do return clip
	for cur := d.parent; cur != NODE_NONE; cur = node_get(t, cur).parent {
		cd := node_get(t, cur)
		if .Clips in cd.flags do clip = rect_clip(clip, cd.abs)
	}
	return clip
}

// layout_node sizes `n` under `c`, lays out its children, and returns its
// size. Children's parent-local rects are written; absolute rects are
// resolved afterwards by resolve_abs.
layout_node :: proc(t: ^Tree, n: Node, c: Constraints) -> [2]f32 {
	d := node_get(t, n)
	if d == nil do return {}
	if .Hidden in d.flags {
		d.rect.w, d.rect.h = 0, 0
		d.cached_c = c
		d.flags -= {.Dirty_Layout}
		return {}
	}
	if .Dirty_Layout not_in d.flags && c == d.cached_c {
		return {d.rect.w, d.rect.h}
	}
	d.cached_c = c
	t.stats.layout_nodes += 1

	cc := apply_size_props(c, d.layout)

	// Every interactive node is at least as big as a finger, or as the
	// theme's `min_target` asks (target_min). A disabled one too: disabling
	// repaints without a relayout, so a different size would show up only
	// when something else moved it. The minimum never passes the maximum.
	if .Focusable in d.flags || d.access.role in INTERACTIVE_ROLES {
		tm := target_min(t)
		if m := min(tm.x, cc.max.x); m > cc.min.x do cc.min.x = m
		if m := min(tm.y, cc.max.y); m > cc.min.y do cc.min.y = m
	}
	size: [2]f32
	switch k in d.kind {
	case Text_Kind:
		// An ellipsis without max_lines is one line, trimmed: measured as one
		// line, so its box and what it draws agree.
		one_line := k.nowrap || (k.ellipsis != .None && k.max_lines == 0)
		max_w := cc.max.x if is_bounded(cc.max.x) && !one_line else 0
		measured := text_kind_measure(t, k, k.str, max_w)
		// A text given its whole width is set on one line. Text layout wraps at
		// the width rounded down to a pixel, so a word given exactly the width
		// it needs (63.996 px, wrapped at 63) would break in two.
		if max_w > 0 && measured.y > text_kind_measure(t, k, "x", 0).y * 1.5 {
			if one := text_kind_measure(t, k, k.str, 0); one.x <= max_w + 0.01 {
				measured, max_w = one, 0
			}
		}
		tk := k
		tk.wrap_w = max_w // the width it was measured with; render lays out with the same value
		// A wrapped text taller than the height it was given (a fixed-height
		// row at phone width) keeps the lines that fit and ends with "…"
		// rather than painting past its box.
		fit := tk
		if is_bounded(cc.max.y) && !one_line && measured.y > cc.max.y + 0.01 {
			lh := text_kind_measure(t, k, "x", 0).y
			lines := max(int((cc.max.y + 0.01) / max(lh, 1)), 1)
			if fit.max_lines <= 0 || lines < fit.max_lines do fit.max_lines = lines
			if fit.ellipsis == .None do fit.ellipsis = .End
		}
		shown := raw_data(tk.display)
		if fit.ellipsis != .None && is_bounded(cc.max.x) {
			measured = text_fit(t, &fit, cc.max.x, measured)
			tk.display, tk.wrap_w = fit.display, fit.wrap_w
		} else if len(tk.display) > 0 {
			delete(tk.display, t.allocator)
			tk.display = ""
		}
		// A new trim frees the old one, which the layer's cached Draw_Text
		// points at: repaint the text even when its box did not move.
		if raw_data(tk.display) != shown do mark_paint_dirty(t, n)
		size = constrain(cc, measured)
		if spills := measured.x > size.x + 1; spills != tk.spills {
			tk.spills = spills
			mark_paint_dirty(t, n)
		}
		tk.drawn_h = measured.y
		// A clickable text grown to target_min is centred in that height, as
		// a button's label is. Height a parent stretches it to beyond that
		// stays below, as for any text.
		inset: f32
		if .Focusable in d.flags || d.access.role in INTERACTIVE_ROLES {
			if grown := min(size.y, target_min(t).y); grown > measured.y do inset = (grown - measured.y) / 2
		}
		if inset != tk.inset_y {
			tk.inset_y = inset
			mark_paint_dirty(t, n)
		}
		d.kind = tk
	case Text_Input_Kind:
		size = layout_text_input(t, n, d, cc) // text_input hook
	case Box_Kind:
		size = layout_box(t, n, d, cc)
	case Custom_Kind:
		// A custom measure, a fixed intrinsic size, or — when neither is
		// given — a normal box layout of its children (custom paint draws
		// underneath them).
		switch {
		case k.measure != nil: size = k.measure(t, n, d, cc)
		case k.size != {}:     size = constrain(cc, k.size)
		case:                  size = layout_box(t, n, d, cc)
		}
	case:
		size = layout_box(t, n, d, cc)
	}
	d.rect.w, d.rect.h = size.x, size.y
	d.flags -= {.Dirty_Layout}
	return size
}

// min_content_width is the narrowest a node can be without breaking what
// it shows: a wrapping text's longest word ("…" when it trims, its whole
// line when it does not wrap); a custom node's intrinsic size; a row's
// children floors plus gaps, a column's widest child floor, padding
// included; `min_width` when given; nothing for a sideways scroll region, a
// text field or an empty box (they narrow gracefully — an explicit `width`
// is a preference a tight row may still squeeze). Rows use it to decide
// what shrinks.
@(private)
min_content_width :: proc(t: ^Tree, n: Node) -> f32 {
	d := node_get(t, n)
	if d == nil || .Hidden in d.flags do return 0
	L := d.layout
	floor: f32
	switch k in d.kind {
	case Text_Kind:
		floor = text_min_width(t, k)
	case Text_Input_Kind:
		floor = 0
	case Custom_Kind:
		if k.size.x > 0 || k.measure != nil {
			floor = k.size.x
		} else {
			floor = box_min_content_width(t, d)
		}
	case Box_Kind:
		floor = box_min_content_width(t, d)
	}
	return max(floor, L.min_w)
}

@(private)
box_min_content_width :: proc(t: ^Tree, d: ^Node_Data) -> f32 {
	L := d.layout
	pad := L.padding[3] + L.padding[1]
	if .Scroll_H in d.flags do return pad
	sum, widest: f32
	count := 0
	for ch := d.first; ch != NODE_NONE; ch = node_get(t, ch).next {
		cd := node_get(t, ch)
		if .Hidden in cd.flags do continue
		m := min_content_width(t, ch)
		sum += m
		widest = max(widest, m)
		count += 1
	}
	if L.axis == .Row do return sum + f32(max(count - 1, 0)) * L.gap + pad
	if L.axis == .Wrap_Column do return max(d.rect.w, widest + pad) // its height sets its columns: as laid out, a row does not squeeze them
	return widest + pad
}

// text_kind_measure measures `s` as text node `k` draws it. The hook has no
// say in italic, so an italic text is measured by the engine directly when
// the hook is the engine's own; the italic face is narrower or wider than
// the upright one, and a box measured upright would cut or crowd it.
@(private)
text_kind_measure :: proc(t: ^Tree, k: Text_Kind, s: string, max_w: f32) -> [2]f32 {
	if k.italic && t.measure_text == text_measure do return text_measure_as(t, s, k.size, max_w, k.weight, k.mono, k.family, k.tabular, italic = true)
	return t.measure_text(t, s, k.size, max_w, k.weight, k.mono, k.family, k.tabular)
}

// text_min_width: what a text needs so that no word is broken apart.
@(private)
text_min_width :: proc(t: ^Tree, k: Text_Kind) -> f32 {
	if k.ellipsis != .None do return text_kind_measure(t, k, "…", 0).x
	if k.nowrap do return text_kind_measure(t, k, k.str, 0).x
	longest: f32
	rest := k.str
	for word in strings.split_multi_iterate(&rest, {" ", "\n", "\t", "\r"}) {
		if word == "" do continue
		longest = max(longest, text_kind_measure(t, k, word, 0).x)
	}
	return longest
}

@(private)
apply_size_props :: proc "contextless" (c: Constraints, l: Layout_Props) -> Constraints {
	cc := c
	if l.width > 0 {
		w := clamp(l.width, c.min.x, c.max.x)
		cc.min.x, cc.max.x = w, w
	}
	if l.height > 0 {
		h := clamp(l.height, c.min.y, c.max.y)
		cc.min.y, cc.max.y = h, h
	}
	if l.min_w > 0 do cc.min.x = max(cc.min.x, min(l.min_w, cc.max.x))
	if l.min_h > 0 do cc.min.y = max(cc.min.y, min(l.min_h, cc.max.y))
	if l.max_w > 0 { cc.max.x = min(cc.max.x, l.max_w); cc.min.x = min(cc.min.x, cc.max.x) }
	if l.max_h > 0 { cc.max.y = min(cc.max.y, l.max_h); cc.min.y = min(cc.min.y, cc.max.y) }
	return cc
}

// text_fit trims a text that does not fit `avail` (one line, or
// `max_lines` wrapped lines) with "…", keeping the longest prefix (End) or
// prefix + suffix (Middle) that fits, by binary search on rune counts. It
// stores the trimmed string in tk.display and returns its size: a cut text
// is as wide as the room it was given (its whole wants more), so what sits
// beside it doesn't jitter as characters drop, and a capped box stays at its
// cap.
@(private)
text_fit :: proc(t: ^Tree, tk: ^Text_Kind, avail: f32, full: [2]f32) -> [2]f32 {
	wrap_w := avail if tk.max_lines > 0 else 0
	lh := text_kind_measure(t, tk^, "x", 0).y
	fits :: proc(m: [2]f32, avail, lh: f32, max_lines: int) -> bool {
		if max_lines > 0 do return int(math.round(m.y / lh)) <= max_lines && m.x <= avail + 0.01
		return m.x <= avail + 0.01
	}
	measured := full
	if tk.max_lines > 0 do measured = text_kind_measure(t, tk^, tk.str, wrap_w)
	if fits(measured, avail, lh, tk.max_lines) {
		if len(tk.display) > 0 {
			delete(tk.display, t.allocator)
			tk.display = ""
		}
		tk.wrap_w = wrap_w
		return measured
	}
	total := utf8.rune_count_in_string(tk.str)
	lo, hi := 0, total - 1 // rune counts kept; hi is exclusive of the full string (which does not fit)
	best := ""
	best_m := [2]f32{0, lh}
	for lo < hi {
		mid := (lo + hi + 1) / 2
		cand := ellipsis_candidate(tk.str, mid, tk.ellipsis, context.temp_allocator)
		m := text_kind_measure(t, tk^, cand, wrap_w)
		if fits(m, avail, lh, tk.max_lines) {
			lo = mid
			best, best_m = cand, m
		} else {
			hi = mid - 1
		}
	}
	if best == "" {
		best = "…"
		best_m = text_kind_measure(t, tk^, best, wrap_w)
	}
	if tk.display != best {
		if len(tk.display) > 0 do delete(tk.display, t.allocator)
		tk.display = strings.clone(best, t.allocator)
	}
	tk.wrap_w = wrap_w
	return {max(best_m.x, avail), best_m.y}
}

// ellipsis_candidate keeps `keep` runes of `s` plus "…": all at the front
// (End) or split front/back (Middle).
@(private)
ellipsis_candidate :: proc(s: string, keep: int, mode: Ellipsis, allocator: runtime.Allocator) -> string {
	if mode == .Middle {
		front := (keep + 1) / 2
		back := keep - front
		return strings.concatenate({rune_prefix(s, front), "…", rune_suffix(s, back)}, allocator)
	}
	return strings.concatenate({rune_prefix(s, keep), "…"}, allocator)
}

@(private)
rune_prefix :: proc(s: string, n: int) -> string {
	i, count := 0, 0
	for count < n && i < len(s) {
		_, w := utf8.decode_rune_in_string(s[i:])
		i += w
		count += 1
	}
	return s[:i]
}

@(private)
rune_suffix :: proc(s: string, n: int) -> string {
	if n <= 0 do return ""
	i, count := len(s), 0
	for count < n && i > 0 {
		_, w := utf8.decode_last_rune_in_string(s[:i])
		i -= w
		count += 1
	}
	return s[i:]
}

// set_viewport records the window's logical size. The run loop calls it as
// soon as a configure arrives so a view built before the first frame already
// sees the right size (and size class); layout calls it too.
set_viewport :: proc(t: ^Tree, viewport: [2]f32) {
	if viewport == t.viewport do return
	t.viewport = viewport
	t.viewport_changed = true
	mark_layout_dirty(t, t.overlay)
	mark_layout_dirty(t, t.root) // pushed last → laid out first, so anchors are current
}

// layout_box is the column/row algorithm: measure non-flex children, split
// the remaining main-axis space among flex children by weight, then place.
@(private)
layout_box :: proc(t: ^Tree, n: Node, d: ^Node_Data, cc: Constraints) -> [2]f32 {
	L := d.layout
	pad := [2]f32{L.padding[3] + L.padding[1], L.padding[0] + L.padding[2]}

	inner_max, inner_min: [2]f32
	for i in 0 ..< 2 {
		inner_max[i] = cc.max[i] - pad[i] if is_bounded(cc.max[i]) else UNBOUNDED
		if inner_max[i] < 0 do inner_max[i] = 0
		inner_min[i] = max(cc.min[i] - pad[i], 0)
	}

	// Scroll containers: children may overflow along the scroll axis, and are
	// shifted by the current offset. The container itself keeps the size its
	// parent gives it.
	scroll_v := .Scroll_V in d.flags
	scroll_h := .Scroll_H in d.flags
	viewport_max := inner_max
	if scroll_v do inner_max.y = UNBOUNDED
	if scroll_h do inner_max.x = UNBOUNDED
	off: [2]f32
	if scroll_v || scroll_h {
		if st, ok := t.scrolls[n]; ok do off = st.offset
	}
	// How wide (tall) a stretched child is made: the container's own size,
	// or `content_w` where it asks for more. Along a scrolling axis there is
	// no limit to stretch to (UNBOUNDED as a minimum is nonsense), so the
	// viewport is what stretch means there.
	stretch_max := inner_max
	if scroll_h {
		if is_bounded(viewport_max.x) do stretch_max.x = max(viewport_max.x, L.content_w)
		if L.content_w > inner_min.x do inner_min.x = L.content_w // …and a shrink-wrapped stretch widens to it
	}
	if scroll_v && is_bounded(viewport_max.y) do stretch_max.y = viewport_max.y

	if L.axis == .Stack {
		// Overlapping children, each at padding origin + its offset. With
		// align = .Stretch children fill the bounded inner box; with .Center
		// / .End they are aligned inside it on both axes.
		content: [2]f32
		for ch := d.first; ch != NODE_NONE; ch = node_get(t, ch).next {
			cd := node_get(t, ch)
			if .Hidden in cd.flags {
				layout_node(t, ch, constraints_loose({0, 0}))
				continue
			}
			child_c := Constraints{max = inner_max}
			cover, popup := false, false
			if .Overlay in d.flags {
				rule, has_rule := t.overlay_rules[ch]
				if has_rule do cover = rule.cover
				popup = popup_candidate(t, ch)
				if popup do child_c = constraints_loose({UNBOUNDED, UNBOUNDED}) // on a surface of its own, free of the bar's bounds
				// Anchored inside the window: no taller than the room beside
				// its anchor, so a long list scrolls instead of hanging past
				// the edge. Only here is it known whether this one is a
				// surface of its own.
				if !popup && has_rule && !cover && rule.edge == .None && !rule.fixed {
					if room := popover_room(t, rule.anchor, rule.placement, rule.gap); room > 0 {
						child_c.max.y = min(child_c.max.y, room)
					}
				}
			}
			if !popup && (L.align == .Stretch || cover) {
				if is_bounded(inner_max.x) && (cover || !cross_fixed(cd, 0)) do child_c.min.x = inner_max.x
				if is_bounded(inner_max.y) && (cover || !cross_fixed(cd, 1)) do child_c.min.y = inner_max.y
			}
			sz := layout_node(t, ch, child_c)
			cd.rect.x = L.padding[3] + cd.layout.offset.x
			cd.rect.y = L.padding[0] + cd.layout.offset.y
			if L.align != .Start && L.align != .Stretch && is_bounded(inner_max.x) && is_bounded(inner_max.y) {
				cd.rect.x += align_offset(L.align, inner_max.x, sz.x)
				cd.rect.y += align_offset(L.align, inner_max.y, sz.y)
			}
			content.x = max(content.x, cd.layout.offset.x + sz.x)
			content.y = max(content.y, cd.layout.offset.y + sz.y)
		}
		return constrain(cc, content + pad)
	}

	if L.axis == .Wrap || L.axis == .Wrap_Column do return layout_wrap(t, d, cc, inner_max, pad, L)

	main := 1 if L.axis == .Column else 0
	cross := 1 - main
	stretch := L.align == .Stretch
	// Stretch makes children as large as the container on the cross axis.
	// The container's cross size is what its parent dictates when the
	// constraint is tight (root, a fixed width/height, a flex child, a child
	// of a Stretch parent); when it is loose, or unbounded (a menu on a popup
	// surface of its own), the container is as large as its largest child or
	// its min_width, and the others are stretched to match (a row of cards, a
	// popover's rows). Same rule on both axes.
	loose_cross := stretch && cc.min[cross] < cc.max[cross]

	// pass 1: non-flex children at their natural size; flex children only
	// reserve their minimum for now
	total_flex, used_main, max_cross, reserved: f32
	count := 0
	for ch := d.first; ch != NODE_NONE; ch = node_get(t, ch).next {
		cd := node_get(t, ch)
		if .Hidden in cd.flags {
			layout_node(t, ch, constraints_loose({0, 0}))
			continue
		}
		count += 1
		if cd.layout.flex > 0 {
			total_flex += cd.layout.flex
			m := cd.layout.min_w if main == 0 else cd.layout.min_h
			reserved += m
			used_main += m
			continue
		}
		child_c: Constraints
		child_c.max[main] = inner_max[main]
		child_c.max[cross] = inner_max[cross]
		if stretch && !loose_cross && !cross_fixed(cd, cross) do child_c.min[cross] = stretch_max[cross]
		sz := layout_node(t, ch, child_c)
		used_main += sz[main]
		max_cross = max(max_cross, sz[cross])
	}
	gaps := f32(max(count - 1, 0)) * L.gap

	// A row whose children do not fit takes the deficit from the children
	// that can give: each has a floor (its min-content width — a button's
	// label and padding, a wrapping text's longest word, "…" for a text with
	// an ellipsis, a `min_width`) and the room above the floor is what
	// shrinks, in proportion. When even the floors do not fit, the row
	// overflows and a clipping ancestor cuts it: a label or a word is never
	// broken to make room. Columns overflow downwards, which is what
	// scrolling is for.
	if L.axis == .Row && is_bounded(inner_max[main]) && used_main + gaps > inner_max[main] + 0.01 {
		natural := used_main - reserved
		avail := max(inner_max[main] - gaps - reserved, 0)
		if natural > 0 && avail < natural {
			deficit := natural - avail
			give_sum: f32
			for ch := d.first; ch != NODE_NONE; ch = node_get(t, ch).next {
				cd := node_get(t, ch)
				if .Hidden in cd.flags || cd.layout.flex > 0 do continue
				give_sum += max(cd.rect.w - min_content_width(t, ch), 0)
			}
			used_main = reserved
			max_cross = 0
			for ch := d.first; ch != NODE_NONE; ch = node_get(t, ch).next {
				cd := node_get(t, ch)
				if .Hidden in cd.flags || cd.layout.flex > 0 do continue
				floor := min_content_width(t, ch) // pass 1 may have clamped the child below it; it grows back
				want := floor // even the floors overflow: everything at its floor, the row overflows
				if deficit <= give_sum + 0.01 {
					want = cd.rect.w - (deficit * max(cd.rect.w - floor, 0) / give_sum if give_sum > 0 else 0)
				}
				child_c: Constraints
				child_c.max[main] = max(want, 0)
				child_c.max[cross] = inner_max[cross]
				if stretch && !loose_cross && !cross_fixed(cd, cross) do child_c.min[cross] = stretch_max[cross]
				sz := layout_node(t, ch, child_c)
				used_main += sz[main]
				max_cross = max(max_cross, sz[cross])
			}
		}
	}

	// pass 2: flex children get their minimum plus a share of what is left
	free: f32 = 0
	if total_flex > 0 {
		if is_bounded(inner_max[main]) do free = max(inner_max[main] - used_main - gaps, 0)
		for ch := d.first; ch != NODE_NONE; ch = node_get(t, ch).next {
			cd := node_get(t, ch)
			if .Hidden in cd.flags || cd.layout.flex <= 0 do continue
			m := cd.layout.min_w if main == 0 else cd.layout.min_h
			child_c: Constraints
			if is_bounded(inner_max[main]) {
				share := m + free * cd.layout.flex / total_flex
				child_c.min[main], child_c.max[main] = share, share
			} else { // no space to share out (a scroll's content, an applet measured along its bar): its natural size
				child_c.min[main], child_c.max[main] = m, UNBOUNDED
			}
			child_c.max[cross] = inner_max[cross]
			if stretch && !loose_cross && !cross_fixed(cd, cross) do child_c.min[cross] = stretch_max[cross]
			sz := layout_node(t, ch, child_c)
			used_main += sz[main]
			max_cross = max(max_cross, sz[cross])
		}
	}

	// pass 3 (shrink-wrapped stretch): widen children to the widest sibling.
	// A column that scrolls sideways does it too where a child came out
	// wider than `content_w`: it pans to the widest, and a narrower row
	// would end its selection and hover wash short there.
	widen_cross := stretch && scroll_h && main == 1 && max_cross > stretch_max[cross] + 0.01
	if loose_cross || widen_cross {
		target := max(max_cross, inner_min[cross])
		for ch := d.first; ch != NODE_NONE; ch = node_get(t, ch).next {
			cd := node_get(t, ch)
			if .Hidden in cd.flags || cross_fixed(cd, cross) do continue
			if ([2]f32{cd.rect.w, cd.rect.h})[cross] == target do continue
			child_c: Constraints
			// keep the main size already decided; only the cross size changes
			cur := ([2]f32{cd.rect.w, cd.rect.h})[main]
			child_c.min[main], child_c.max[main] = cur, cur
			child_c.min[cross], child_c.max[cross] = target, target
			layout_node(t, ch, child_c)
		}
		max_cross = target
	}

	content: [2]f32
	content[main] = used_main + gaps
	content[cross] = max_cross
	size := constrain(cc, content + pad)
	if scroll_v || scroll_h {
		// A scroll container never grows with its content along the scroll
		// axis: it is as large as its parent allows (or its own width/height).
		if scroll_v && is_bounded(viewport_max.y) do size.y = min(size.y, viewport_max.y + pad.y)
		if scroll_h && is_bounded(viewport_max.x) do size.x = min(size.x, viewport_max.x + pad.x)
		st := &t.scrolls[n]
		if st == nil {
			t.scrolls[n] = scroll_state_new()
			st = &t.scrolls[n]
		}
		st.content = content
		st.viewport = size - pad
		// A scroll that follows its end stays there as the content grows
		// (a reply streaming into a chat), until scrolled away from the end
		// and again once scrolled back to it.
		if st.follow_end && st.at_end {
			if scroll_v do st.offset.y = max(st.content.y - st.viewport.y, 0)
			if scroll_h do st.offset.x = max(st.content.x - st.viewport.x, 0)
		}
		st.offset = scroll_clamp(st^, st.offset)
		off = st.offset
	}

	// place
	inner_main := size[main] - pad[main]
	leftover := max(inner_main - content[main], 0)
	start_off, between := justify_offsets(L.justify, leftover, count, L.gap)
	pad_start_main  := L.padding[0] if main == 1 else L.padding[3]
	pad_start_cross := L.padding[3] if main == 1 else L.padding[0]
	inner_cross := size[cross] - pad[cross]
	if scroll_v && main == 0 do inner_cross = max(inner_cross, content.y) // horizontal box scrolling vertically keeps its content height
	if scroll_h && main == 1 do inner_cross = max(inner_cross, content.x) // …and a column scrolling sideways its content width, so `align` places inside that, not the viewport
	pos := pad_start_main + start_off
	for ch := d.first; ch != NODE_NONE; ch = node_get(t, ch).next {
		cd := node_get(t, ch)
		if .Hidden in cd.flags do continue
		sz := [2]f32{cd.rect.w, cd.rect.h}
		p: [2]f32
		p[main] = pos
		p[cross] = pad_start_cross + align_offset(L.align, inner_cross, sz[cross])
		cd.rect.x, cd.rect.y = p.x - off.x, p.y - off.y
		pos += sz[main] + between
	}
	return size
}

// layout_wrap is the flow algorithm: children are measured at their natural
// size and laid along the main axis, left to right (top to bottom for a
// Wrap_Column), starting a new line (a new column) when the next one would
// not fit; `flex` children then grow to fill their line (a card grid that
// reflows with the window); `align` positions or stretches each child across
// its line; `justify` spreads a line's leftover.
@(private)
layout_wrap :: proc(t: ^Tree, d: ^Node_Data, cc: Constraints, inner_max, pad: [2]f32, L: Layout_Props) -> [2]f32 {
	main := 1 if L.axis == .Wrap_Column else 0
	cross := 1 - main
	Line :: struct {
		count:             int,
		length, thickness: f32, // natural length along the main axis incl. gaps; the thickest child
		flex:              f32,
	}
	lines := make([dynamic]Line, context.temp_allocator)
	cur: Line
	avail := inner_max[main]
	for ch := d.first; ch != NODE_NONE; ch = node_get(t, ch).next {
		cd := node_get(t, ch)
		if .Hidden in cd.flags {
			layout_node(t, ch, constraints_loose({0, 0}))
			continue
		}
		sz := layout_node(t, ch, Constraints{max = inner_max})
		need := sz[main] + (L.gap if cur.count > 0 else 0)
		if cur.count > 0 && is_bounded(avail) && cur.length + need > avail + 0.01 {
			append(&lines, cur)
			cur = {}
			need = sz[main]
		}
		cur.count += 1
		cur.length += need
		cur.thickness = max(cur.thickness, sz[cross])
		cur.flex += max(cd.layout.flex, 0)
	}
	if cur.count > 0 do append(&lines, cur)

	content: [2]f32
	for l, i in lines {
		content[main] = max(content[main], l.length)
		content[cross] += l.thickness + (L.gap if i > 0 else 0)
	}
	size := constrain(cc, content + pad)
	inner_main := size[main] - pad[main]
	origin := [2]f32{L.padding[3], L.padding[0]}

	line_at := origin[cross]
	ch := d.first
	for &l in lines {
		leftover := max(inner_main - l.length, 0)
		// flex children absorb the line's leftover in proportion
		if l.flex > 0 && leftover > 0 {
			c := ch
			for placed := 0; placed < l.count && c != NODE_NONE; c = node_get(t, c).next {
				cd := node_get(t, c)
				if .Hidden in cd.flags do continue
				placed += 1
				if cd.layout.flex <= 0 do continue
				grown := ([2]f32{cd.rect.w, cd.rect.h})[main] + leftover * cd.layout.flex / l.flex
				grow: Constraints
				grow.min[main], grow.max[main] = grown, grown
				grow.max[cross] = inner_max[cross]
				sz := layout_node(t, c, grow)
				l.thickness = max(l.thickness, sz[cross])
			}
			l.length = inner_main
			leftover = 0
		}
		start, between := justify_offsets(L.justify, leftover, l.count, L.gap)
		along := origin[main] + start
		placed := 0
		for placed < l.count && ch != NODE_NONE {
			cd := node_get(t, ch)
			if .Hidden in cd.flags {
				ch = cd.next
				continue
			}
			rs := [2]f32{cd.rect.w, cd.rect.h}
			if L.align == .Stretch && rs[cross] != l.thickness && !cross_fixed(cd, cross) {
				fit: Constraints
				fit.min[main], fit.max[main] = rs[main], rs[main]
				fit.min[cross], fit.max[cross] = l.thickness, l.thickness
				layout_node(t, ch, fit)
				rs = {cd.rect.w, cd.rect.h}
			}
			at: [2]f32
			at[main] = along
			at[cross] = line_at + align_offset(L.align, l.thickness, rs[cross])
			cd.rect.x, cd.rect.y = at.x, at.y
			along += rs[main] + between
			placed += 1
			ch = cd.next
		}
		line_at += l.thickness + L.gap
	}
	return size
}

// cross_fixed reports whether a child sets its own size on axis `axis`
// (an explicit width/height, or a Custom_Kind with a size): Stretch leaves
// such children alone, like CSS does for a definite cross size.
@(private)
cross_fixed :: proc "contextless" (cd: ^Node_Data, axis: int) -> bool {
	if axis == 0 && cd.layout.width > 0 do return true
	if axis == 1 && cd.layout.height > 0 do return true
	if k, ok := cd.kind.(Custom_Kind); ok && k.size[axis] > 0 do return true
	return false
}

@(private)
justify_offsets :: proc "contextless" (j: Justify, leftover: f32, n: int, gap: f32) -> (start, between: f32) {
	between = gap
	if n <= 0 do return
	switch j {
	case .Start:
	case .Center: start = leftover / 2
	case .End:    start = leftover
	case .Space_Between:
		if n > 1 do between = gap + leftover / f32(n - 1) // a lone child stays at the start, as in CSS
	case .Space_Around:
		per := leftover / f32(n)
		start = per / 2
		between = gap + per
	case .Space_Evenly:
		per := leftover / f32(n + 1)
		start = per
		between = gap + per
	}
	return
}

@(private)
align_offset :: proc "contextless" (a: Align, inner, size: f32) -> f32 {
	switch a {
	case .Start, .Stretch: return 0
	case .Center: return (inner - size) / 2
	case .End:    return inner - size
	}
	return 0
}

// resolve_abs converts parent-local rects into absolute ones below `n`,
// dirtying paint (and damaging the old rect, limited to `clip`) for every
// node that moved. `shift` is how far the parent's content moved this
// layout for reasons that are not a rebuild (the parent itself moved, or
// scrolled): only the rest of a node's move is animated.
@(private)
resolve_abs :: proc(t: ^Tree, n: Node, origin: [2]f32, clip: Rect, shift: [2]f32 = {}) {
	d := node_get(t, n)
	if d == nil do return
	was_off := t.damage_off
	defer t.damage_off = was_off
	if d.parent == t.overlay && popup_candidate(t, n) do t.damage_off = true // a popup: its surface presents whole
	new_abs := Rect{origin.x + d.rect.x, origin.y + d.rect.y, d.rect.w, d.rect.h}
	moved: [2]f32
	if new_abs != d.abs {
		ring := focus_ring_look(&t.theme).overhang
		if t.debug_damage && !t.damage_off do damage_log(t, n, "moved", rect_clip(paint_bounds(d, ring), clip))
		damage_add(t, rect_clip(paint_bounds(d, ring), clip))
		old := d.abs
		d.abs = new_abs
		mark_paint_dirty(t, n)
		mark_host_layer_dirty(t, n) // moved or resized: whether it is drawn at all is decided one layer up
		if old != {} do moved = {new_abs.x - old.x, new_abs.y - old.y}
		// A node that a rebuild moved inside an animating container glides
		// from where it was: paint shifts by move_from × the Move tween.
		if p := node_get(t, d.parent); p != nil && .Animate_Moves in p.flags && old != {} && (!t.viewport_changed || .Animate_Resize in p.flags) &&
			.Exiting not_in d.flags && .Hidden not_in d.flags && !t.theme.motion.reduce {
			delta := [2]f32{old.x - new_abs.x, old.y - new_abs.y} + shift
			if abs(delta.x) > 0.01 || abs(delta.y) > 0.01 {
				d.move_from = delta + d.move_from * anim_value(t, n, .Move)
				anim_restart(t, n, .Move, 1, 0, t.theme.motion.base)
			}
		}
	}
	if .Hidden in d.flags do return
	o := [2]f32{new_abs.x, new_abs.y}
	child_clip := rect_clip(clip, new_abs) if .Clips in d.flags else clip
	child_shift := moved
	if st, ok := &t.scrolls[n]; ok {
		child_shift -= st.shift_since_layout // scrolling moved the children too
		st.shift_since_layout = {}
	}
	for c := d.first; c != NODE_NONE; c = node_get(t, c).next {
		resolve_abs(t, c, o, child_clip, child_shift)
	}
}
