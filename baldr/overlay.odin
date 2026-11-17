package baldr

// Overlays: popover, select, dialog. They are built into the overlay root
// (Tree.overlay), a stack that covers the window and is painted last, so any
// view proc can open one from anywhere in the tree. Positions come from the
// anchor's rect in the retained tree, so no second layout pass is needed.
// Dismissal — a press outside, or Escape — either queues the app's message
// (popover, dialog) or clears the widget's own open state (select).

import "base:runtime"
import "core:fmt"
import "core:hash"

// Placement: which side of its anchor an overlay sits on, or `.Over`: on
// the anchor itself, aligned across it by `align` and moved by `nudge`,
// covering it and its neighbours (an icon tile's rename editor, which grows
// past its tile).
Placement :: enum u8 { Below, Above, Right, Left, Over }

// Dismiss_Rule: how an open overlay closes. `inside` is the rect a press must
// land in to NOT dismiss (the popover itself, or a dialog's card); presses on
// `anchor` are left to the anchor (it toggles itself).
Dismiss_Rule :: struct($Msg: typeid) {
	fired:   bool, // already dismissed this build; kept until the sweep for `restore`
	has_msg: bool,
	msg:     Msg,
	owner:   Node, // select trigger whose `open` flag is cleared
	anchor:  Node,
	inside:  Node,
	restore: Node, // where focus goes when the overlay closes with focus inside it
	// …and where it goes when Escape closed it, when that differs: a menu
	// bar's dropdown returns focus to its title on Escape so the bar stays
	// navigable, but to the previous holder when an item is chosen or the
	// menu is clicked away.
	restore_key: Node,
	by_key:      bool, // Escape closed it, so `restore_key` decides
	// A press on the scrim does not dismiss this one: a form dialog's
	// Cancel, Escape and ✕ still do, but a stray click must not discard
	// what was typed.
	keep_on_outside: bool,
}

POPOVER_GAP :: f32(6)

// How long a popover takes to arrive and to go, in ms. Not theme motion
// tokens: `fast` is for a state layer and `base` for something the eye
// follows, and a menu should be there almost at once and gone the moment
// it is dismissed. motion.reduce makes both instant.
POPOVER_ENTER_MS :: f32(140)
POPOVER_EXIT_MS :: f32(100)

// POPOVER_MARGIN is the room a popover leaves between itself and the edge of
// the window when it has to be cut short, and POPOVER_MIN_ROOM the least it
// will cut itself to.
POPOVER_MARGIN   :: f32(8)
POPOVER_MIN_ROOM :: f32(120)

// popover_room is how tall a popover anchored `gap` from `anchor` may be
// without running off the window: the room below it, or above it when that is
// greater, since popover_offset flips it there. A longer list scrolls
// rather than hanging past the edge, where its last items could not be
// reached. It reads the anchor's last layout: a control does not move
// while its list is open.
@(private)
popover_room :: proc(t: ^Tree, anchor: Node, placement: Placement, gap: f32) -> f32 {
	vp := t.viewport
	d := node_get(t, anchor)
	if d == nil || vp.y <= 0 do return 0
	#partial switch placement {
	case .Below, .Above:
		below := vp.y - (d.abs.y + d.abs.h) - gap - POPOVER_MARGIN
		above := d.abs.y - gap - POPOVER_MARGIN
		// A floor: an anchor with almost no room either side would squash
		// its list to a line or two, which is worse than overflowing.
		return clamp(max(below, above), min(POPOVER_MIN_ROOM, vp.y - POPOVER_MARGIN * 2), max(vp.y - POPOVER_MARGIN * 2, 0))
	}
	return max(vp.y - POPOVER_MARGIN * 2, 0) // beside it: the window's own height
}

// Overlay_Rule places an overlay-root child at layout time, when its size and
// the anchor's rect are current: anchored next to `anchor`, or covering the
// viewport (a dialog's scrim).
Overlay_Rule :: struct {
	anchor:    Node,
	placement: Placement,
	gap:       f32,
	cover:     bool,
	fixed:     bool,   // placed at `at` (a context menu at the pointer), kept inside the viewport
	at:        [2]f32,
	// How much room above `at` a flip must leave as well (0: `at` is a
	// point, as a context menu's pointer is). A card hanging off a line (a
	// completion list under the caret) that flips above must clear that
	// line, or it covers the text being typed.
	at_avoid:  f32,
	// Kept inside this node's width as well as the window's, so a card
	// centred on a tile in a view's first column does not spill over a
	// sidebar beside it. Height is free: a rename on the last row may grow
	// past the view, stopped only by the window. NONE: the window alone.
	within:    Node,
	nudge:     [2]f32, // added after placement (a submenu lines its first item up with its row)
	align:     Align,  // along the anchor: .Start (its start with the anchor's), .Center, .End; .Stretch is .Start
	edge:      Overlay_Edge, // hugs the viewport's bottom or top, centred (toasts); `stack` counts earlier ones
	stack:     int,
	edge_margin: f32, // how far an edge overlay keeps from that edge
	stack_gap:   f32, // between edge overlays stacked on one another
}

// Overlay_Edge is which screen edge an overlay has been pushed against, so
// it can be kept a margin clear of it.
Overlay_Edge :: enum u8 { None, Bottom, Top }
OVERLAY_EDGE_MARGIN :: f32(16)
OVERLAY_STACK_GAP   :: f32(8)

// position_overlay_children re-anchors overlay children after every layout
// pass (the anchor may have moved, the popover may have grown). Called by
// layout. A child whose anchor is gone keeps its last position (it is fading).
@(private)
position_overlay_children :: proc(t: ^Tree) {
	o := node_get(t, t.overlay)
	if o == nil do return
	if t.popups_on { // a popup's surface draws its own layer, which the surface below leaves out
		for c := o.first; c != NODE_NONE; c = node_get(t, c).next do if popup_candidate(t, c) do set_layer(t, c, true)
	}
	// A child anchored inside another overlay child (a submenu beside its
	// row) is placed after that one, so the anchor's rect is current.
	done := make([dynamic]Node, context.temp_allocator)
	is_done :: proc(done: []Node, n: Node) -> bool {
		for d in done do if d == n do return true
		return false
	}
	for _ in 0 ..< 8 {
		progress := false
		for c := o.first; c != NODE_NONE; c = node_get(t, c).next {
			if is_done(done[:], c) do continue
			rule, ok := t.overlay_rules[c]
			if !ok || rule.cover { // placed by layout (a dialog's backdrop fills the viewport): what opens inside it can be placed now
				append(&done, c)
				progress = true
				continue
			}
			if rule.edge == .None && !rule.fixed {
				if owner := overlay_child_of(t, rule.anchor); owner != NODE_NONE && owner != c && !is_done(done[:], owner) do continue
			}
			append(&done, c)
			progress = true
			place_overlay_child(t, o, c, rule)
		}
		if !progress do break
	}
}

@(private)
place_overlay_child :: proc(t: ^Tree, o: ^Node_Data, c: Node, rule: Overlay_Rule) {
	{
		cd := node_get(t, c)
		off: [2]f32
		if popup_candidate(t, c) { // where the compositor put its surface
			p, has := t.popups[c]
			if !has || !p.placed do return
			off = p.origin - {o.abs.x, o.abs.y}
		} else if rule.edge != .None {
			vp := t.viewport
			off.x = max((vp.x - cd.rect.w) / 2, 0)
			lift := f32(rule.stack) * (cd.rect.h + rule.stack_gap)
			off.y = rule.edge_margin + lift if rule.edge == .Top else max(vp.y - rule.edge_margin - cd.rect.h - lift, 0)
		} else if rule.fixed {
			off = fixed_offset(t, rule.at, {cd.rect.w, cd.rect.h}, rule.at_avoid)
		} else {
			if !node_valid(t, rule.anchor) do return
			keep: Rect
			if w := node_get(t, rule.within); w != nil do keep = w.abs
			off = popover_offset(t, rule.anchor, {cd.rect.w, cd.rect.h}, rule.placement, rule.gap, rule.nudge, rule.align, keep)
		}
		if off != {cd.rect.x, cd.rect.y} {
			cd.rect.x, cd.rect.y = off.x, off.y
			resolve_abs(t, c, {o.abs.x, o.abs.y}, ancestor_clip(t, c))
		}
	}
}

// overlay_begin reconciles a keyed child of the overlay root and opens its
// scope on top of a redirect scope. `created` is true whenever the overlay
// opens this build: new, or brought back while its exit transition still
// ran (a menu closed and opened again at once), so what opening does — its
// transition, its first focus — happens again. Callers set `extra_pops` on
// the scope they want `end` to close through.
@(private)
overlay_begin :: proc(ui: ^Ui($Msg), key: u64, loc: runtime.Source_Code_Location) -> (n: Node, created: bool) {
	t := &ui.tree
	revived := false
	for c := node_first(t, t.overlay); c != NODE_NONE; c = node_next(t, c) {
		if d := node_get(t, c); d.key == key && kind_tag(d.kind) == .Box && .Exiting in d.flags {
			revived = true
			break
		}
	}
	// After the overlays already built this build: build order is stacking order, so one opened from inside
	// another (a select's list in a dialog) paints and hits over it. The last child is on top for both.
	cursor := node_first(t, t.overlay)
	for cursor != NODE_NONE && node_get(t, cursor).epoch == ui.epoch do cursor = node_next(t, cursor)
	append(&ui.scopes, Scope{node = t.overlay, cursor = cursor, loc = loc, redirect = true})
	n, created = reconcile_child(ui, .Box, key, loc)
	created = created || revived
	open_scope(ui, n, loc)
	ui.scopes[len(ui.scopes) - 1].extra_pops = 1
	if th, ok := popup_theme(t, n); ok { // glass on a surface of its own reads over its own backdrop
		append(&ui.themes_saved, t.theme)
		t.theme = th
		ui.scopes[len(ui.scopes) - 1].theme_pop = true
	} else if ui.theme_areas_open > 0 {
		// Opened from inside a theme_area: the popup floats over the whole
		// window, not that page, so it is built in the window's theme.
		append(&ui.themes_saved, t.theme)
		t.theme = ui.theme_outside
		ui.scopes[len(ui.scopes) - 1].theme_pop = true
	}
	return
}

// sweep_overlay removes overlay children the view did not emit this build
// (exit transitions run first), and releases the focus trap of a closed dialog.
@(private)
sweep_overlay :: proc(ui: ^Ui($Msg)) {
	t := &ui.tree
	c := node_first(t, t.overlay)
	for c != NODE_NONE {
		next := node_next(t, c)
		d := node_get(t, c)
		if d != nil && d.epoch != ui.epoch && .Exiting not_in d.flags {
			if t.modal != NODE_NONE && (t.modal == c || node_parent(t, t.modal) == c) {
				t.modal = NODE_NONE
				if node_valid(t, ui.focus_before_modal) do set_focus(t, ui.focus_before_modal, false)
				ui.focus_before_modal = NODE_NONE
			}
			if rule, ok := ui.dismiss[c]; ok {
				back := rule.restore
				if rule.by_key && rule.restore_key != NODE_NONE do back = rule.restore_key
				if back != NODE_NONE && node_valid(t, back) {
					if t.focus == NODE_NONE || overlay_child_of(t, t.focus) == c do set_focus(t, back, t.focus_visible)
				}
			}
			delete_key(&ui.dismiss, c)
			if d.style.exit.kind != .None && !t.theme.motion.reduce {
				begin_exit(t, c)
			} else {
				forget_subtree(ui, c)
				node_destroy(t, c)
			}
		}
		c = next
	}
}

// fixed_offset places a `size` box with its top-left at `at`, flipping to
// the left / upwards when it would leave the viewport (a context menu).
// `avoid` is how much above `at` the flip must clear too: the line of text
// `at` hangs under, so a completion list that flips above the caret does
// not cover the words being typed.
@(private)
fixed_offset :: proc(t: ^Tree, at: [2]f32, size: [2]f32, avoid: f32 = 0) -> [2]f32 {
	vp := t.viewport
	off := at
	if vp.x > 0 && off.x + size.x > vp.x do off.x = max(at.x - size.x, 0)
	if vp.y > 0 && off.y + size.y > vp.y do off.y = max(at.y - avoid - size.y, 0)
	return off
}

// popover_offset places a popover of last-frame size `size` next to
// `anchor`, flipping to the other side when it would leave the viewport.
@(private)
popover_offset :: proc(t: ^Tree, anchor: Node, size: [2]f32, placement: Placement, gap: f32, nudge: [2]f32 = {}, align: Align = .Start, within: Rect = {}) -> [2]f32 {
	a := node_get(t, anchor)
	if a == nil do return {}
	r := a.abs
	vp := t.viewport
	// along the anchor: its start, its middle over the anchor's, or its end
	// (a dock's menu centred over its button reads as coming from it)
	along :: proc(start, length, size: f32, align: Align) -> f32 {
		#partial switch align {
		case .Center: return start + (length - size) / 2
		case .End:    return start + length - size
		}
		return start
	}
	off: [2]f32
	switch placement {
	case .Below:
		off = {along(r.x, r.w, size.x, align), r.y + r.h + gap}
		if vp.y > 0 && off.y + size.y > vp.y && r.y - gap - size.y >= 0 do off.y = r.y - gap - size.y
	case .Above:
		off = {along(r.x, r.w, size.x, align), r.y - gap - size.y}
		if off.y < 0 do off.y = r.y + r.h + gap
	case .Right:
		off = {r.x + r.w + gap, along(r.y, r.h, size.y, align)}
		if vp.x > 0 && off.x + size.x > vp.x && r.x - gap - size.x >= 0 do off.x = r.x - gap - size.x
	case .Left:
		off = {r.x - gap - size.x, along(r.y, r.h, size.y, align)}
		if off.x < 0 do off.x = r.x + r.w + gap
	case .Over:
		// On the anchor: `align` across it, its top at the anchor's, and
		// `nudge` for the rest. The clamp below keeps it in the window.
		off = {along(r.x, r.w, size.x, align), r.y}
	}
	off += nudge
	// Inside `within`'s width first (the view a tile belongs to), then
	// inside the window: a card is never half over what is beside its view.
	if within.w > 0 do off.x = clamp(off.x, within.x, max(within.x + within.w - size.x, within.x))
	if vp.x > 0 do off.x = clamp(off.x, 0, max(vp.x - size.x, 0))
	if vp.y > 0 do off.y = clamp(off.y, 0, max(vp.y - size.y, 0))
	return off
}

// popover opens a floating surface anchored to `anchor` while `open` is true.
// A press outside it (and outside the anchor) or Escape queues `dismiss`; the
// app then sets its open flag to false. Close the scope with end. Returns
// whether the scope is open. `align` is where it sits along the anchor:
// `.Start` (its start with the anchor's, the default), `.Center` (its middle
// over the anchor's — a dock's menu over its button) or `.End`; it slides
// back onto the screen as any placement does.
popover :: proc(ui: ^Ui($Msg), anchor: Node, open: bool, dismiss: Msg, placement: Placement = .Below,
	min_width: f32 = 0, glass := true, align: Align = .Start, key: u64 = 0, loc := #caller_location) -> bool {
	if !open do return false
	k := key if key != 0 else (u64(anchor) * 0x9E37_79B9_7F4A_7C15) | 1
	n, created := overlay_begin(ui, k, loc)
	popover_style(ui, n, created, anchor, placement, min_width, glass)
	if rule, has := &ui.tree.overlay_rules[n]; has do rule.align = align
	set_rule(ui, n, Dismiss_Rule(Msg){has_msg = true, msg = dismiss, anchor = anchor, inside = n})
	return true
}

// set_rule installs an overlay's dismiss rule. A rule that fired is replaced
// only if the view builds the overlay again (the app kept it open): then it
// may fire again. An overlay the app closed keeps its fired rule until the
// sweep, which uses `restore`.
@(private)
set_rule :: proc(ui: ^Ui($Msg), n: Node, rule: Dismiss_Rule(Msg)) {
	ui.dismiss[n] = rule
}

// popover_style dresses an overlay child as a popover's card; `menu` gives
// it the menu style's card (a menu, submenu, a select's list).
@(private)
popover_style :: proc(ui: ^Ui($Msg), n: Node, created: bool, anchor: Node, placement: Placement, min_width: f32, glass: bool, scrolls := false, menu := false) {
	t := &ui.tree
	th := &t.theme
	d := node_get(t, n)
	// A glass popup inside its window is over the app's own content, which
	// nothing measures (the compositor reports the desktop behind the
	// window), so it takes the worst-case theme. On a popup surface of its
	// own the compositor does measure, and overlay_begin swaps that theme
	// in. `popups_on`, not `popup_candidate`: the rule written below is what
	// makes it a candidate, so on its first build it is not one yet.
	in_app := glass && t.in_app_theme_ok && len(ui.scopes) > 0 && !t.popups_on
	if in_app {
		sc := &ui.scopes[len(ui.scopes) - 1]
		if !sc.theme_pop {
			append(&ui.themes_saved, t.theme)
			sc.theme_pop = true
		}
		t.theme = t.in_app_theme
		d.flags += {.Glass_In_App}
	} else {
		d.flags -= {.Glass_In_App}
	}
	if created {
		d.access.role = .Group
		transition(ui, n, .Fade_Scale, .Fade)
		d.style.enter.whole, d.style.exit.whole = true, true // it opens over controls: its glass or fill is whole, only its items fade
		// Always a layer: the Fade_Scale is applied to a layer's finished
		// command list (paint.odin, `scaled`), the only place a scale can go
		// without re-laying-out the subtree as it grows.
		set_layer(t, n, true)
		// Faster than motion.base, and leaving faster than arriving: by the
		// time a menu is dismissed the person has already decided.
		d.style.enter.duration = POPOVER_ENTER_MS
		d.style.exit.duration = POPOVER_EXIT_MS
	}
	// Resolved after the swap above, so its colours are the theme the popup is built in.
	card := popover_look(th)
	if menu {
		ml := menu_look(th)
		card.fill, card.border, card.border_width, card.radius = ml.fill, ml.border, ml.border_width, ml.radius
		card.shadow, card.padding, card.gap = ml.shadow, ml.padding, ml.gap
	}
	st := d.style
	st.bg = card.fill
	st.radius = card.radius
	st.border_w = card.border_width
	st.border = card.border
	st.shadow = card.shadow
	st.material = {}
	t.overlay_rules[n] = {anchor = anchor, placement = placement, gap = card.anchor_gap}
	if m := th.material[th.glass].popover; glass && has_material(m) {
		// on a popup surface its tint follows its own backdrop (glass.odin);
		// over the app's content it is the worst case already (in_app_theme,
		// swapped in above), with glass_in_app's floor kept as well
		st.material = m if popup_candidate(t, n) else glass_in_app(m)
		st.bg = {}
		st.border_w = 0 // its edge is the material's
		if has_shadow(m.shadow) do st.shadow = m.shadow
	}
	set_style(t, n, st)
	// A list that can outgrow the window scrolls, so its last items can be
	// reached. The popover itself scrolls: an inner scroll node would put a
	// Scroll_Area between a menu and its items, which its keys and a reader
	// both walk. Its height cap is layout's: only there is it known whether
	// this is a surface of its own, which the window does not bound.
	if scrolls && created {
		d.flags += {.Clips, .Scroll_V}
		t.scrolls[n] = scroll_state_new()
	}
	set_layout(t, n, Layout_Props{
		axis = .Column, align = .Stretch, padding = card.padding, gap = card.gap,
		min_w = min_width,
	})
}

// dismiss_outside fires every open overlay's rule whose `inside` rect (and
// anchor) does not contain `pos`. Returns true if any closed.
dismiss_outside :: proc(ui: ^Ui($Msg), pos: [2]f32) -> (any: bool) {
	if len(ui.dismiss) == 0 do return false
	t := &ui.tree
	fired := make([dynamic]Node, context.temp_allocator)
	for n, rule in ui.dismiss {
		d := node_get(t, n)
		if rule.fired || d == nil || .Exiting in d.flags do continue
		inside := node_get(t, rule.inside)
		if inside != nil && rect_contains(inside.abs, pos) do continue
		if a := node_get(t, rule.anchor); a != nil && rect_contains(a.abs, pos) do continue
		if press_in_submenus_of(ui, rule.inside, pos) do continue // a press in a submenu is inside its parent
		if press_in_overlays_of(ui, n, pos) do continue // …and in a menu or list opened from inside it
		if rule.keep_on_outside do continue // a form dialog: only Cancel, Escape or ✕ close it
		append(&fired, n)
	}
	for n in fired do fire_dismiss(ui, n, fmt.tprintf("a press outside it at %v", pos) if ui.tree.debug_events else "")
	return len(fired) > 0
}

// press_in_overlays_of: whether `pos` lands in an open overlay anchored on a
// node inside overlay `parent` (a menu opened from a chip in a popover, a
// select's list, a date picker), or in one anchored inside that, and so on.
@(private)
press_in_overlays_of :: proc(ui: ^Ui($Msg), parent: Node, pos: [2]f32, depth := 0) -> bool {
	t := &ui.tree
	if parent == NODE_NONE || depth > 8 do return false
	for m, rule in ui.dismiss {
		if m == parent || rule.fired || rule.anchor == NODE_NONE || !node_valid(t, m) || !node_valid(t, rule.anchor) do continue
		if .Exiting in node_get(t, m).flags || overlay_child_of(t, rule.anchor) != parent do continue
		if inside := node_get(t, rule.inside); inside != nil && rect_contains(inside.abs, pos) do return true
		if press_in_overlays_of(ui, m, pos, depth + 1) do return true
	}
	return false
}

// dismiss_innermost closes the open overlays nothing else is open inside:
// Escape in a menu opened from a chip in a popover closes the menu, and the
// next Escape the popover. Returns true if any closed.
@(private)
dismiss_innermost :: proc(ui: ^Ui($Msg)) -> (any: bool) {
	t := &ui.tree
	fired := make([dynamic]Node, context.temp_allocator)
	outer: for n, rule in ui.dismiss {
		d := node_get(t, n)
		if rule.fired || d == nil || .Exiting in d.flags do continue
		for m, inner in ui.dismiss {
			if m == n || inner.fired || !node_valid(t, m) || .Exiting in node_get(t, m).flags do continue
			if inner.anchor != NODE_NONE && overlay_child_of(t, inner.anchor) == n do continue outer // something is open inside it
		}
		append(&fired, n)
	}
	for n in fired do fire_dismiss(ui, n, "Escape, innermost first", by_key = true)
	return len(fired) > 0
}

// press_in_submenus_of: whether `pos` lands in an open submenu (or one of
// its own) whose row is inside `menu`.
@(private)
press_in_submenus_of :: proc(ui: ^Ui($Msg), menu: Node, pos: [2]f32) -> bool {
	t := &ui.tree
	if menu == NODE_NONE do return false
	for row, pop in ui.submenus {
		if pop == NODE_NONE || !node_valid(t, pop) || !node_valid(t, row) || overlay_child_of(t, row) != menu do continue
		if rect_contains(node_get(t, pop).abs, pos) || press_in_submenus_of(ui, pop, pos) do return true
	}
	return false
}

// dismiss_all closes every open overlay and hides the tooltip. Escape uses
// dismiss_escape, which closes the innermost first.
dismiss_all :: proc(ui: ^Ui($Msg)) -> (any: bool) {
	if ui.tip_anchor != NODE_NONE {
		tooltip_hide(ui)
		any = true
	}
	fired := make([dynamic]Node, context.temp_allocator)
	for n, rule in ui.dismiss {
		if d := node_get(&ui.tree, n); !rule.fired && d != nil && .Exiting not_in d.flags do append(&fired, n)
	}
	for n in fired do fire_dismiss(ui, n, "every overlay dismissed")
	return any || len(fired) > 0
}

// close_owner closes the popup a menu item / option belongs to: an overlay
// child with a dismiss rule, or a select trigger's own open flag.
@(private)
close_owner :: proc(ui: ^Ui($Msg), owner: Node) {
	if rule, has := ui.dismiss[owner]; has {
		fire_dismiss(ui, owner, "an item in it was chosen")
		if rule.owner != NODE_NONE && rule.owner in ui.submenus { // a submenu: the menu holding its row closes too
			ui.submenus[rule.owner] = NODE_NONE
			if parent := overlay_child_of(&ui.tree, rule.owner); parent != NODE_NONE do close_owner(ui, parent)
		}
		return
	}
	if owner in ui.open {
		if ui.tree.debug_events && ui.open[owner] do overlay_log(ui, owner, "closed", "an item in it was chosen")
		ui.open[owner] = false
		ask_rebuild(ui)
	}
}

@(private)
fire_dismiss :: proc(ui: ^Ui($Msg), n: Node, why: string, by_key := false) {
	rule, ok := &ui.dismiss[n]
	if !ok || rule.fired do return
	if ui.tree.debug_events do overlay_log(ui, rule.owner if rule.owner != NODE_NONE else n, "closed", why)
	rule.fired = true // once; the rule stays for the focus restore in sweep_overlay
	rule.by_key = by_key
	if rule.has_msg do append(&ui.msgs, rule.msg)
	if rule.owner != NODE_NONE {
		ui.open[rule.owner] = false
		ask_rebuild(ui)
	}
}

// overlay_log says, under BALDR_DEBUG_EVENTS, that an overlay opened or
// closed and why: the control that owns it (a select, a menu's button) by
// role and name, or the overlay itself for one the app opens.
@(private)
overlay_log :: proc(ui: ^Ui($Msg), n: Node, what, why: string) {
	d := node_get(&ui.tree, n)
	if d == nil do return
	fmt.eprintfln("baldr/events: %v %q (node %d) %s: %s", d.access.role, d.access.name, u64(n), what, why)
}

// menu_nav moves the highlight to the next/previous focusable inside the
// overlay child that contains the focus (a select's list, a menu), from the
// item the keys act on (menu_current). When nothing is highlighted yet, a
// menu opened with the pointer, Down goes to the first item and Up to the
// last. False if focus is not inside an overlay.
menu_nav :: proc(ui: ^Ui($Msg), forward: bool) -> bool {
	t := &ui.tree
	root := overlay_child_of(t, t.focus)
	if root == NODE_NONE do return false
	order := make([dynamic]Node, context.temp_allocator)
	collect_focusable(t, root, &order)
	if len(order) == 0 do return false
	next := 0 if forward else len(order) - 1
	if cur := menu_current(ui, order[:]); cur >= 0 do next = (cur + (1 if forward else len(order) - 1)) % len(order)
	set_focus(t, order[next], true)
	return true
}

// menu_current is the index in `order` (a menu's or list's items) of the
// item the keys act on: the one the keyboard highlighted, else the row the
// pointer rests on, else a list's selected option; -1 when none is (a menu
// just opened with the pointer).
@(private)
menu_current :: proc(ui: ^Ui($Msg), order: []Node) -> int {
	t := &ui.tree
	index :: proc(order: []Node, n: Node) -> int {
		for m, i in order do if m == n do return i
		return -1
	}
	if t.focus_visible {
		if i := index(order, t.focus); i >= 0 do return i
	}
	if ui.pointer.inside {
		if i := index(order, menu_row_of(ui, ui.pointer.hover)); i >= 0 do return i
	}
	if d := node_get(t, t.focus); d != nil && .Selected in d.access.states do return index(order, t.focus)
	return -1
}

// menu_end: Home / End in a menu or list highlight its first / last item.
@(private)
menu_end :: proc(ui: ^Ui($Msg), last: bool) -> bool {
	t := &ui.tree
	root := overlay_child_of(t, t.focus)
	if root == NODE_NONE || node_get(t, root).access.role != .Menu do return false
	order := make([dynamic]Node, context.temp_allocator)
	collect_focusable(t, root, &order)
	if len(order) == 0 do return false
	set_focus(t, order[len(order) - 1 if last else 0], true)
	return true
}

// menu_unlit_key: Enter or Space in a menu or list the keyboard hasn't
// highlighted anything in (it opened with the pointer) act on the row the
// pointer rests on or a list's selected option, and otherwise do nothing:
// an item the user can't see is never activated. False where an item is
// highlighted (it takes the key as usual) or focus isn't in a menu.
@(private)
menu_unlit_key :: proc(ui: ^Ui($Msg)) -> bool {
	t := &ui.tree
	root := overlay_child_of(t, t.focus)
	if root == NODE_NONE || t.focus_visible || node_get(t, root).access.role != .Menu do return false
	order := make([dynamic]Node, context.temp_allocator)
	collect_focusable(t, root, &order)
	if cur := menu_current(ui, order[:]); cur >= 0 do click(ui, order[cur])
	return true
}

// select_fit is how wide a select must be for its widest option: the text at
// the field's size in force (the desktop's text size included), the trigger's
// padding, the gap and the chevron, capped at SELECT_FIT_MAX.
@(private)
select_fit :: proc(t: ^Tree, lk: Field_Look, options: []string, placeholder: string) -> f32 {
	size := lk.text_size
	fam := lk.text_family
	if lk.family_name != "" do fam = look_family(t, lk.family_name)
	w := text_measure(t, placeholder, size, 0, lk.text_weight, family = fam).x
	for opt in options do w = max(w, text_measure(t, opt, size, 0, lk.text_weight, family = fam).x)
	chev := text_measure(t, "⌄", size, 0, lk.text_weight, family = fam).x
	// The two sides summed first, then the gap: f32 sums round in order.
	return min(w + chev + (lk.dropdown_padding[1] + lk.dropdown_padding[3]) + lk.gap + 1, SELECT_FIT_MAX)
}

// overlay_child_of returns the overlay-root child that contains `n` (or NONE).
@(private)
overlay_child_of :: proc(t: ^Tree, n: Node) -> Node {
	cur := n
	for cur != NODE_NONE {
		d := node_get(t, cur)
		if d == nil do return NODE_NONE
		if d.parent == t.overlay do return cur
		cur = d.parent
	}
	return NODE_NONE
}

// SELECT_FIT_MAX is the widest a select sizes itself to for its options
// (`width = 0`); a longer option is cut, as one too long for a set width is.
SELECT_FIT_MAX :: f32(420)

// select is a drop-down: a trigger showing the selected option, and a popup
// list while open. `width = 0` sizes it to its widest option at the text
// size in force (the desktop's included), so the box does not change as
// options are picked. Open state is the widget's own (click, Enter, Space
// toggle it; an outside press or Escape closes it); choosing an option
// sends its index through `on_change` and closes. An option too long for
// `width` is cut with "…" on one line. Roles: Combo_Box trigger (with a
// popup, Expanded while open), Menu with Menu_Items.
select :: proc(ui: ^Ui($Msg), selected: int, options: []string, on_change: Handler(Msg, int) = nil,
	placeholder: string = "Select…", width: f32 = 200, disabled := false, label: string = "",
	tag: u64 = 0, key: u64 = 0, loc := #caller_location) -> Node {
	n, created := reconcile_child(ui, .Box, key, loc)
	t := &ui.tree
	th := &t.theme
	d := node_get(t, n)
	if created {
		d.access.role = .Combo_Box
		d.flags += {.Focusable, .Clips} // a squeezed select clips its label rather than spilling
		ui.open[n] = false
		mark_layout_dirty(t, n)
	}
	d.tag = tag
	valid := selected >= 0 && selected < len(options)
	set_name(t, n, label if label != "" else placeholder)
	set_disabled(t, n, disabled)
	is_open := ui.open[n]
	popup_states(d, is_open) // it opens a popup: Has_Popup, Expanded while open
	lk := field_look(th)
	width := width
	if width == 0 do width = select_fit(t, lk, options, placeholder)
	set_layout(t, n, Layout_Props{axis = .Row, align = .Center, justify = .Space_Between, width = width,
		padding = lk.dropdown_padding, gap = lk.gap, min_h = lk.min_height})
	st := d.style
	st.bg = lk.fill
	st.radius = lk.radius
	st.border_w = lk.focus_border_width if is_open else lk.border_width
	st.border = lk.focus_border if is_open else lk.border
	set_style(t, n, st)

	vsize, vfam := field_value_size(t, lk), field_value_family(t, lk)
	open_scope(ui, n, loc)
	// one line, cut with "…" where it does not fit: a select is a fixed box, and large text must not make it two lines
	lbl := text(ui, options[selected] if valid else placeholder, size = vsize, color = lk.ink if valid else lk.placeholder,
		nowrap = true, ellipsis = .End, weight = lk.value_weight, family = vfam, loc = loc)
	set_role(t, lbl, .None)
	chev := text(ui, "⌃" if is_open else "⌄", size = vsize, color = lk.icon, weight = lk.value_weight, family = vfam, loc = loc) // Inter's arrowheads (U+2303/U+2304)
	set_role(t, chev, .None)
	close_scope(ui)

	if is_open && !disabled {
		k := (u64(n) * 0x9E37_79B9_7F4A_7C15) | 1
		pop, pcreated := overlay_begin(ui, k, loc)
		popover_style(ui, pop, pcreated, n, .Below, width, true, scrolls = true, menu = true)
		ml := menu_look(th) // after popover_style: the rows are in the list's theme, glass included
		node_get(t, pop).access.role = .Menu
		set_rule(ui, pop, Dismiss_Rule(Msg){owner = n, anchor = n, inside = pop, restore = n})
		sel_row := NODE_NONE
		for opt, i in options {
			row, rcreated := reconcile_child(ui, .Box, u64(i + 1), loc)
			rd := node_get(t, row)
			if rcreated {
				rd.access.role = .Menu_Item
				rd.flags += {.Focusable}
			}
			set_layout(t, row, Layout_Props{axis = .Row, align = .Center, padding = ml.item_padding, min_h = ml.item_min_height})
			rd.tag = u64(i)
			set_name(t, row, opt)
			is_sel := i == selected
			if is_sel do sel_row = row
			if was := .Selected in rd.access.states; was != is_sel {
				if is_sel { rd.access.states += {.Selected} } else { rd.access.states -= {.Selected} }
			}
			rs := rd.style
			rs.radius = ml.item_radius
			rs.bg = ml.selected_fill if is_sel else Color{}
			set_style(t, row, rs)
			ui.on_int[row] = on_change
			ui.option_of[row] = n // picked from the select, with its tag
			ui.closes[row] = pop
			open_scope(ui, row, loc)
			ol := text(ui, opt, role = ml.text.role, size = ml.text.size, color = ml.selected_ink if is_sel else ml.ink,
				weight = ml.text.weight, family = look_family(t, ml.text.family), loc = loc)
			set_role(t, ol, .None)
			close_scope(ui)
		}
		if pcreated {
			ui.pending_focus = sel_row if sel_row != NODE_NONE else pop // the list starts at the selected option
			// …and is scrolled to it, whether opened by pointer or key: a
			// click leaves focus invisible, and invisible focus reveals
			// nothing.
			if sel_row != NODE_NONE do t.reveal = sel_row
		}
		end(ui) // closes the popup scope and its redirect
	}
	return n
}

// dialog opens a modal: a scrim over the window and a centred card that traps
// keyboard focus. Escape queues `dismiss`. Build the card's content inside
// and close with end. Returns whether it is open.
//
// A press on the scrim does nothing unless `dismiss_outside` is set, so a
// stray click cannot discard a form's typed work; Escape, Cancel and ✕
// still close it. Set `dismiss_outside = true` for a dialog holding nothing
// worth keeping (a picture at full size, an about box).
//
// `dismiss` must be the safe answer, never the destructive one: Escape and
// a scrim press mean "not now". Put anything destructive on a button inside
// the dialog, and have `dismiss` keep everything and ask again; the toolkit
// cannot tell a destructive message from a safe one.
//
// `width = 0` takes the theme's (Dialog_Style.width, 420 by default).
dialog :: proc(ui: ^Ui($Msg), open: bool, dismiss: Msg, title: string = "", width: f32 = 0,
	dismiss_outside := false,
	key: u64 = 0, loc := #caller_location) -> bool {
	if !open do return false
	t := &ui.tree
	th := &t.theme
	k := key if key != 0 else hash.fnv64a(transmute([]byte)string("baldr.dialog")) | 1
	back, bcreated := overlay_begin(ui, k, loc)
	look := dialog_look(th) // after overlay_begin, which may swap the theme in
	w := width if width > 0 else look.width
	bd := node_get(t, back)
	if bcreated do transition(ui, back, .Fade, .Fade)
	set_layout(t, back, Layout_Props{axis = .Stack, align = .Center})
	t.overlay_rules[back] = {cover = true} // sized to the viewport at layout time, so a resize follows
	bs := bd.style
	bs.bg = look.scrim
	set_style(t, back, bs)

	card_n, ccreated := reconcile_child(ui, .Box, 1, loc)
	cd := node_get(t, card_n)
	if ccreated {
		cd.access.role = .Dialog
		cd.access.states += {.Modal}
		transition(ui, card_n, .Fade_Scale, .Fade)
		cd.style.enter.whole, cd.style.exit.whole = true, true // over the app's controls: its card is whole, only what is on it fades
		ui.focus_before_modal = t.focus
		ui.pending_focus = card_n
	}
	set_name(t, card_n, title)
	set_layout(t, card_n, Layout_Props{axis = .Column, width = w, padding = look.padding, gap = look.gap, align = .Stretch})
	cs := cd.style
	cs.bg = look.fill
	cs.radius = look.radius
	cs.border_w = look.border_width
	cs.border = look.border
	cs.shadow = look.shadow
	cs.material = {}
	if m := th.material[th.glass].sheet; has_material(m) {
		// The floor, not a popup's worst case: the scrim over the whole
		// window already bounds the sheet's ground (black at 0.35–0.5 takes
		// white paper to a mid grey) before the sheet's own tint goes on.
		cs.material = glass_in_app(m)
		cs.bg = {}
	}
	set_style(t, card_n, cs)
	t.modal = card_n
	set_rule(ui, back, Dismiss_Rule(Msg){has_msg = true, msg = dismiss, inside = card_n, keep_on_outside = !dismiss_outside})
	open_scope(ui, card_n, loc)
	ui.scopes[len(ui.scopes) - 1].extra_pops = 2 // card, backdrop, redirect
	if title != "" {
		tt := text(ui, title, role = look.title_text.role, size = look.title_text.size, weight = look.title_text.weight,
			family = look_family(t, look.title_text.family), loc = loc)
		set_role(t, tt, .None)
	}
	return true
}

// menu is a popover that behaves as a menu: role Menu, keyboard focus moves
// onto its first item when it opens (Up/Down walk, Enter activates, Escape
// closes) and returns to `anchor` when it closes. Fill it with menu_item and
// separator; an activated item queues its message and the menu's `dismiss`.
menu :: proc(ui: ^Ui($Msg), anchor: Node, open: bool, dismiss: Msg, placement: Placement = .Below,
	min_width: f32 = 180, key: u64 = 0, loc := #caller_location) -> bool {
	if !open do return false
	k := key if key != 0 else (u64(anchor) * 0x9E37_79B9_7F4A_7C15) | 1
	n, created := overlay_begin(ui, k, loc)
	popover_style(ui, n, created, anchor, placement, min_width, true, scrolls = true, menu = true)
	node_get(&ui.tree, n).access.role = .Menu
	if created do ui.pending_focus = n
	set_rule(ui, n, Dismiss_Rule(Msg){has_msg = true, msg = dismiss, anchor = anchor, inside = n, restore = anchor})
	return true
}

// context_menu is a menu that opens where the latest right-click, Menu key
// or drop happened (`Ui.context_pos`, recorded before `on_context` or
// `on_drop` fires). Use it with a table's or icon view's `on_context`: the
// message tells the app which item (or -1 for the background) to build the
// menu for; or after an Alt-drop (`Drop.action == .Ask`) for Copy here /
// Move here.
//
//	if baldr.context_menu(ui, s.ctx_open, Msg(Ctx_Close{})) {
//		defer baldr.end(ui)
//		if s.ctx_item >= 0 { baldr.menu_item(ui, "Open", …) } else { baldr.menu_item(ui, "New folder", …) }
//	}
context_menu :: proc(ui: ^Ui($Msg), open: bool, dismiss: Msg, min_width: f32 = 180,
	key: u64 = 0, loc := #caller_location) -> bool {
	if !open do return false
	t := &ui.tree
	k := key if key != 0 else hash.fnv64a(transmute([]byte)string("baldr.context_menu")) | 1
	n, created := overlay_begin(ui, k, loc)
	popover_style(ui, n, created, NODE_NONE, .Below, min_width, true, menu = true)
	t.overlay_rules[n] = {fixed = true, at = ui.context_pos}
	node_get(t, n).access.role = .Menu
	if created do ui.pending_focus = n
	set_rule(ui, n, Dismiss_Rule(Msg){has_msg = true, msg = dismiss, inside = n, restore = t.focus if created else NODE_NONE})
	return true
}

// menu_item is one row of a menu: label left, optional shortcut hint right.
// Activating it (click, Enter, Space) queues `on_click` and closes the menu.
// `checked` (a bool, or nil for a plain item) shows a check mark — or a
// dot when `radio` — in a leading slot and sets the Checked state; give the
// plain items of such a menu `checked = false` so their labels line up.
// `icon` or `theme_icon` (an icon theme name: a jump-list action's Icon=, a
// dbusmenu icon-name) goes before the label.
menu_item :: proc(ui: ^Ui($Msg), label: string, on_click: Msg, shortcut: string = "", disabled := false,
	icon: Icon = .None, theme_icon := "", checked: Maybe(bool) = nil, radio := false, tag: u64 = 0, key: u64 = 0, loc := #caller_location) -> Node {
	n, created := reconcile_child(ui, .Box, key, loc)
	t := &ui.tree
	th := &t.theme
	lk := menu_look(th) // inside the menu's scope: its glass theme is in already
	d := node_get(t, n)
	if created {
		d.access.role = .Menu_Item
		d.flags += {.Focusable}
	}
	set_layout(t, n, Layout_Props{axis = .Row, align = .Center, justify = .Space_Between, gap = lk.item_gap,
		padding = lk.item_padding, min_h = lk.item_min_height})
	d.tag = tag
	set_name(t, n, label)
	set_disabled(t, n, disabled)
	is_checked, checkable := checked.?
	if checkable && is_checked { d.access.states += {.Checked} } else { d.access.states -= {.Checked} }
	st := d.style
	st.radius = lk.item_radius
	set_style(t, n, st)
	ui.clicks[n] = on_click
	if owner := overlay_child_of(t, ui.scopes[len(ui.scopes) - 1].node); owner != NODE_NONE do ui.closes[n] = owner
	open_scope(ui, n, loc)
	lead := row(ui, gap = lk.icon_gap, align = .Center, loc = loc)
	if checkable {
		slot := row(ui, width = lk.icon_size, align = .Center, justify = .Center, key = u64(Control_Part.Check), loc = loc)
		if is_checked && radio {
			box(ui, width = 7, height = 7, bg = lk.ink, radius = 3.5, loc = loc)
		} else if is_checked {
			baldr_icon(ui, .Check, lk.icon_size, lk.ink, loc)
		}
		set_role(t, slot, .None)
		close_scope(ui)
	}
	if icon != .None && theme_icon == "" do baldr_icon(ui, icon, lk.icon_size, lk.ink, loc, key = u64(Control_Part.Icon))
	if theme_icon != "" do baldr_theme_icon(ui, theme_icon, lk.icon_size, lk.ink, loc, key = u64(Control_Part.Theme_Icon), fallback = icon) // the icon stands in when no theme provides it
	l := text(ui, label, role = lk.text.role, size = lk.text.size, color = lk.ink, weight = lk.text.weight,
		family = look_family(t, lk.text.family), key = u64(Control_Part.Label), loc = loc)
	set_role(t, l, .None)
	close_scope(ui)
	_ = lead
	if shortcut != "" {
		s := text(ui, shortcut, role = lk.shortcut_text.role, size = lk.shortcut_text.size, color = lk.shortcut_ink,
			weight = lk.shortcut_text.weight, family = look_family(t, lk.shortcut_text.family), loc = loc)
		set_role(t, s, .None)
	}
	close_scope(ui)
	return n
}

SUBMENU_DELAY_MS :: 180.0

// submenu is a menu row that opens a further menu beside it: when the
// pointer rests on it, on click, Right, Enter or Space. Inside it, Left or
// Escape close it and focus returns to the row; the pointer resting on
// another row of the parent closes it too. Fill it with menu_item /
// submenu / separator and close with end only when it returns true. An
// item activated inside closes the whole chain of menus. `icon` or
// `theme_icon` goes before the label, as on a menu_item. Role Menu_Item
// (with a popup, Expanded / Collapsed) whose popup is a Menu.
//
//	if baldr.submenu(ui, "Sort by", icon = .Arrow_Down_Up) { defer baldr.end(ui)
//		baldr.menu_item(ui, "Name", By_Name{}, checked = s.sort == .Name, radio = true)
//		baldr.menu_item(ui, "Size", By_Size{}, checked = s.sort == .Size, radio = true)
//	}
submenu :: proc(ui: ^Ui($Msg), label: string, icon: Icon = .None, theme_icon := "", disabled := false, min_width: f32 = 180,
	key: u64 = 0, loc := #caller_location) -> bool {
	n, created := reconcile_child(ui, .Box, key, loc)
	t := &ui.tree
	th := &t.theme
	lk := menu_look(th) // the parent menu's theme: the row, and where its submenu goes
	d := node_get(t, n)
	if created {
		d.access.role = .Menu_Item
		d.flags += {.Focusable}
		ui.open[n] = false
	}
	set_layout(t, n, Layout_Props{axis = .Row, align = .Center, justify = .Space_Between, gap = lk.item_gap,
		padding = lk.item_padding, min_h = lk.item_min_height})
	set_name(t, n, label)
	set_disabled(t, n, disabled)
	open := ui.open[n] && !disabled
	popup_states(d, open) // it opens a popup: Has_Popup, Expanded while open
	st := d.style
	st.radius = lk.item_radius
	st.bg = lk.open_fill if open else Color{}
	set_style(t, n, st)
	ui.submenus[n] = NODE_NONE
	open_scope(ui, n, loc)
	lead := row(ui, gap = lk.icon_gap, align = .Center, loc = loc)
	if icon != .None && theme_icon == "" do baldr_icon(ui, icon, lk.icon_size, lk.ink, loc, key = u64(Control_Part.Icon))
	if theme_icon != "" do baldr_theme_icon(ui, theme_icon, lk.icon_size, lk.ink, loc, key = u64(Control_Part.Theme_Icon), fallback = icon) // the icon stands in when no theme provides it
	l := text(ui, label, role = lk.text.role, size = lk.text.size, color = lk.ink, weight = lk.text.weight,
		family = look_family(t, lk.text.family), key = u64(Control_Part.Label), loc = loc)
	set_role(t, l, .None)
	close_scope(ui)
	_ = lead
	baldr_icon(ui, .Chevron_Right, lk.icon_size, lk.shortcut_ink, loc) // as legible as a shortcut hint
	close_scope(ui)
	if !open do return false
	k := (u64(n) * 0x9E37_79B9_7F4A_7C15) | 1
	pop, pcreated := overlay_begin(ui, k, loc)
	popover_style(ui, pop, pcreated, n, .Right, min_width, true, menu = true)
	// A submenu appears and goes with nothing animating, as on every major
	// desktop: a fade lights up each submenu passed on the way down a menu
	// and leaves two on screen at once. The parent menu keeps its own.
	transition(ui, pop, .None, .None)
	t.overlay_rules[pop] = {anchor = n, placement = .Right, gap = lk.submenu_gap, nudge = lk.submenu_nudge} // just outside the parent menu's edge, first item level with the row
	node_get(t, pop).access.role = .Menu
	if pcreated && ui.sub_kbd == n {
		ui.pending_focus = pop
		ui.sub_kbd = NODE_NONE
	}
	set_rule(ui, pop, Dismiss_Rule(Msg){owner = n, anchor = n, inside = pop, restore = n})
	ui.submenus[n] = pop
	return true
}

@(private)
submenu_open :: proc(ui: ^Ui($Msg), row: Node, from_keyboard: bool) {
	ui.open[row] = true
	if from_keyboard do ui.sub_kbd = row
	ask_rebuild(ui)
	mark_paint_dirty(&ui.tree, row)
}

@(private)
submenu_close :: proc(ui: ^Ui($Msg), row: Node) {
	if pop := ui.submenus[row]; pop != NODE_NONE {
		fire_dismiss(ui, pop, "its submenu row closed it")
		ui.submenus[row] = NODE_NONE
	}
	ui.open[row] = false
	ask_rebuild(ui)
	mark_paint_dirty(&ui.tree, row)
}

// submenu_key: Right / Enter / Space on a submenu row open it (focus goes
// to its first item); Left / Escape inside a submenu's popup close that
// one and focus its row.
@(private)
submenu_key :: proc(ui: ^Ui($Msg), key: Key, mods: Mods) -> bool {
	t := &ui.tree
	f := t.focus
	if f == NODE_NONE do return false
	if pop, is_row := ui.submenus[f]; is_row && t.focus_visible && .Disabled not_in node_get(t, f).flags { // a highlighted row: an unlit one waits for Down
		#partial switch key {
		case .Right, .Enter, .Space:
			if pop == NODE_NONE {
				submenu_open(ui, f, true)
			} else {
				focus_first(t, pop, true)
			}
			return true
		}
	}
	pop := overlay_child_of(t, f)
	if pop == NODE_NONE do return false
	rule, has := ui.dismiss[pop]
	if !has || rule.owner == NODE_NONE || rule.owner not_in ui.submenus do return false
	if key == .Left || key == .Escape {
		submenu_close(ui, rule.owner)
		set_focus(t, rule.owner, true)
		return true
	}
	return false
}

// submenu_tick: after the pointer rests on a menu row for a moment, a
// submenu row opens and the other submenus of that menu close.
@(private)
submenu_tick :: proc(ui: ^Ui($Msg), now_ms: f64) {
	t := &ui.tree
	row := NODE_NONE
	if ui.pointer.inside do row = menu_row_of(ui, ui.pointer.hover)
	if row != ui.sub_hover {
		ui.sub_hover = row
		ui.sub_since = now_ms
		ui.sub_acted = NODE_NONE
		if row != NODE_NONE do tree_wake_at(t, now_ms + SUBMENU_DELAY_MS, row)
	}
	if row == NODE_NONE || ui.sub_acted == row || now_ms - ui.sub_since < SUBMENU_DELAY_MS do return
	ui.sub_acted = row
	menu := overlay_child_of(t, row)
	for r, pop in ui.submenus {
		if r == row || pop == NODE_NONE || !node_valid(t, r) || overlay_child_of(t, r) != menu do continue
		submenu_close(ui, r)
	}
	if pop, is_sub := ui.submenus[row]; is_sub && pop == NODE_NONE && .Disabled not_in node_get(t, row).flags do submenu_open(ui, row, false)
}

// menu_row_of climbs from `n` to the menu row (item or submenu) holding it.
@(private)
menu_row_of :: proc(ui: ^Ui($Msg), n: Node) -> Node {
	t := &ui.tree
	for cur := n; cur != NODE_NONE; cur = node_parent(t, cur) {
		if cur in ui.submenus || cur in ui.closes do return cur
	}
	return NODE_NONE
}

// separator is a hairline between groups: horizontal in a column or menu,
// vertical in a row. Role Separator.
separator :: proc(ui: ^Ui($Msg), key: u64 = 0, loc := #caller_location) -> Node {
	n, created := reconcile_child(ui, .Box, key, loc)
	t := &ui.tree
	th := &t.theme
	d := node_get(t, n)
	if created do d.access.role = .Separator
	parent := node_get(t, d.parent)
	vertical := parent != nil && parent.layout.axis == .Row
	sl := separator_look(th)
	set_layout(t, n, Layout_Props{height = 0 if vertical else sl.thickness, width = sl.thickness if vertical else 0,
		offset = {0, th.space[.xxs] if !vertical else 0}})
	st := d.style
	st.bg = sl.fill
	set_style(t, n, st)
	return n
}

TOOLTIP_DELAY_MS :: 600.0

// tooltip attaches a short description to `anchor`: shown after the pointer
// rests on it for 600 ms, or while it has visible keyboard focus; hidden on
// leave, press or Escape. The text also becomes the anchor's accessible
// description, so assistive technology gets it without hovering.
tooltip :: proc(ui: ^Ui($Msg), anchor: Node, tip: string, loc := #caller_location) {
	t := &ui.tree
	ad := node_get(t, anchor)
	if ad == nil do return
	if ad.access.describe != tip do set_describe(t, anchor, tip)
	ui.tips[anchor] = {}
	if ui.tip_anchor == anchor do tooltip_show(ui, anchor, tip, loc)
}

// text_trimmed: the node is a text whose last layout cut it with "…", so
// the pointer resting on it gets the whole text as a tooltip (text builds
// that itself; nothing to register).
text_trimmed :: proc(t: ^Tree, n: Node) -> bool {
	d := node_get(t, n)
	if d == nil do return false
	k, ok := d.kind.(Text_Kind)
	return ok && len(k.display) > 0
}

@(private)
tooltip_show :: proc(ui: ^Ui($Msg), anchor: Node, tip: string, loc: runtime.Source_Code_Location, at: [2]f32 = {}, fixed := false, at_avoid: f32 = 0) {
	t := &ui.tree
	th := &t.theme
	k := (u64(anchor) * 0xD1B5_4A32_D192_ED03) | 1
	n, created := overlay_begin(ui, k, loc)
	d := node_get(t, n)
	if created {
		d.access.role = .Tooltip
		// A tooltip never takes the pointer: a press must reach what is
		// under it (a link's URL tip can sit over the next line's link, and
		// a tap moves and presses at once). Hit_Transparent rather than
		// Inert, which would take its name out of the accessibility tree.
		d.flags += {.Hit_Transparent}
		transition(ui, n, .Fade, .Fade, th.motion.fast)
	}
	set_name(t, n, tip) // the tooltip's own name is its text, for assistive technology
	look := tooltip_look(th) // after overlay_begin, which may swap the theme in
	st := d.style
	st.bg = look.fill // opaque: the text must stay readable over anything
	st.radius = look.radius
	st.border_w = look.border_width
	st.border = look.border
	st.shadow = look.shadow
	set_style(t, n, st)
	set_layout(t, n, Layout_Props{axis = .Row, padding = look.padding, max_w = look.max_width})
	t.overlay_rules[n] = {anchor = anchor, placement = .Above, gap = look.anchor_gap}
	if fixed do t.overlay_rules[n] = {fixed = true, at = at, at_avoid = at_avoid} // a point, not a node (a mark in a text area); at_avoid is the line it hangs under
	l := text(ui, tip, role = look.text.role, size = look.text.size, color = look.ink, weight = look.text.weight,
		family = look_family(t, look.text.family), loc = loc)
	set_role(t, l, .None)
	end(ui)
}

// tooltip_tick decides which tooltip (if any) should be showing and asks for
// a rebuild when that changes. Called from ui_tick.
@(private)
tooltip_tick :: proc(ui: ^Ui($Msg), now_ms: f64) {
	t := &ui.tree
	h := ui.pointer.hover
	if ui.pointer.inside {
		if hit := hit_test(t, ui.pointer.pos); text_trimmed(t, hit) do h = hit // a trimmed text tells the whole story on hover
	}
	has_tip := h != NODE_NONE && (h in ui.tips || text_trimmed(t, h))
	mark := -1
	if s, is_area := &t.areas[h]; is_area && ui.pointer.inside { // a mark with a message under the pointer
		mark = area_mark_at(t, h, s, ui.pointer.pos)
		has_tip = mark >= 0
	}
	if _, is_view := &t.md_views[h]; is_view && ui.pointer.inside { // a link in a reply: its target
		mark = md_view_link_id(t, h, ui.pointer.pos)
		has_tip = mark >= 0
	}
	if h != ui.tip_hover || mark != ui.tip_mark_hover {
		ui.tip_hover = h
		ui.tip_mark_hover = mark
		ui.tip_since = now_ms
		ui.tip_block = NODE_NONE
		if ui.tip_anchor != NODE_NONE && ui.tip_mark >= 0 { // off the mark: the tip goes at once
			ui.tip_anchor = NODE_NONE
			ask_rebuild(ui)
		}
		if has_tip do tree_wake_at(t, now_ms + TOOLTIP_DELAY_MS, h)
	}
	if t.focus != ui.tip_focus {
		ui.tip_focus = t.focus
		if ui.tip_block != NODE_NONE && ui.tip_block != h do ui.tip_block = NODE_NONE
	}
	want := NODE_NONE
	if has_tip && h != ui.tip_block && !overlay_open_on(ui, h) && !behind_modal(t, h) && now_ms - ui.tip_since >= TOOLTIP_DELAY_MS {
		want = h
	} else if t.focus_visible && t.focus != NODE_NONE && t.focus != ui.tip_block && t.focus in ui.tips && !overlay_open_on(ui, t.focus) && !behind_modal(t, t.focus) {
		want = t.focus
	}
	if want != ui.tip_anchor || (want != NODE_NONE && ui.tip_mark != mark && mark >= 0) {
		ui.tip_anchor = want
		ui.tip_mark = mark if want == h else -1
		ask_rebuild(ui)
	}
}

// behind_modal: `n` is behind an open dialog's scrim (not in the dialog,
// nor in anything opened from it), so a tooltip on it would float over the
// scrim beside the card.
@(private)
behind_modal :: proc(t: ^Tree, n: Node) -> bool {
	return t.modal != NODE_NONE && node_valid(t, t.modal) && !node_within(t, n, t.overlay)
}

// overlay_open_on: a popover or menu anchored to `n` is open, so a tooltip
// on `n` would only cover it.
@(private)
overlay_open_on :: proc(ui: ^Ui($Msg), n: Node) -> bool {
	for _, rule in ui.dismiss do if rule.anchor == n && !rule.fired do return true
	return false
}

// tooltip_hide hides the current tooltip and keeps it hidden until the
// pointer or focus moves elsewhere.
@(private)
tooltip_hide :: proc(ui: ^Ui($Msg)) {
	ui.tip_block = ui.tip_anchor if ui.tip_anchor != NODE_NONE else ui.pointer.hover
	if ui.tip_anchor != NODE_NONE {
		ui.tip_anchor = NODE_NONE
		ask_rebuild(ui)
	}
}

// dismiss_escape is Escape's: the tooltip goes, and the innermost open
// overlays close (dismiss_innermost).
@(private)
dismiss_escape :: proc(ui: ^Ui($Msg)) -> (any: bool) {
	if ui.tip_anchor != NODE_NONE {
		tooltip_hide(ui)
		any = true
	}
	return dismiss_innermost(ui) || any
}
