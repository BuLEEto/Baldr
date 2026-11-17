package baldr

// split + pane: two panes side by side (or stacked) with a draggable
// divider — sidebar and content, editor and preview, list and detail. The
// sized pane's extent is the app's state, echoed through on_change while
// the divider is dragged or nudged, so it can be remembered:
//
//	baldr.split(ui, s.sidebar_w, on_change = proc(e: baldr.Ev(f32)) -> Msg { return Sidebar{e.value} }, min = 160, max = 480); {
//		defer baldr.end(ui)
//		baldr.pane(ui, padding = .sm); { defer baldr.end(ui); sidebar(s, ui) }
//		baldr.pane(ui, padding = .lg); { defer baldr.end(ui); content(s, ui) }
//	}
//
// `gap` is a gutter either side of the divider, so the panes' content can
// sit flush with the split's top and bottom and still breathe sideways.
// The divider is a hairline with an 8 px grab zone (24 px on touch) that
// shows the resize cursor and an accent bar on hover; it is a Tab stop
// (role Separator, value = size): Left / Right (Up / Down when stacked) move
// it by 8 px, Shift by 32, Home / End to the limits. `min` bounds both
// panes; `max` the sized one.
//
// Phones show one pane at a time. `collapse = .Compact` (or `.Medium`)
// makes the split do that below the given size class: the first pane fills
// the window until `detail` is true, then the second pane fronts it with a
// Back button (`back_label`) that sends `on_close`; Escape sends it too.
// The app keeps `detail` in its state (picked something and not gone
// back), so resizing keeps whatever the split was showing:
//
//	baldr.split(ui, s.sidebar_w, on_change = …, collapse = .Compact,
//		detail = s.sel >= 0 && !s.dismissed, on_close = Msg(Back{}), back_label = "Project")

import "base:builtin"
import "core:strings"

SPLIT_DIVIDER_W   :: f32(1)
SPLIT_GRAB        :: f32(8)  // pointer zone centred on the divider
SPLIT_GRAB_TOUCH  :: f32(24)
SPLIT_KEY_STEP    :: f32(8)
SPLIT_MIN_DEFAULT :: f32(80)
SPLIT_DIVIDER_KEY :: u64(0x5350_4C49_5400_0001)

// Split_Sized says which pane `size` applies to; the other pane flexes.
Split_Sized :: enum u8 { First, Second }

// Collapse: at and below which size class the split shows one pane at a time.
Collapse :: enum u8 { Never, Compact, Medium }

SPLIT_BACK_KEY :: u64(0x5350_4C49_5400_0002)

Split_State :: struct {
	axis:                   Axis, // .Row: side by side (divider vertical); .Column: stacked
	size:                   f32,  // the sized pane's extent as built (clamped)
	gap:                    f32,  // gutter either side of the divider
	sent:                   f32,  // last size sent while dragging (0 = none)
	min, max:               f32,
	sized:                  Split_Sized,
	count:                  int,  // panes built so far this view
	divider, first, second: Node,
	hover, dragging:        bool,
	start_pos, start_size:  f32,
	divider_w:              f32,    // the divider's width as last laid out
	collapsed:              bool,   // one pane at a time (the size class matched `collapse`)
	detail:                 bool,   // …and it is the second pane that shows
	shown_detail:           bool,   // the detail pane was showing after the last build (enter transition)
	back_label:             string, // owned by the tree allocator
}

@(private)
split_state_destroy :: proc(t: ^Tree, sp: ^Split_State) {
	if len(sp.back_label) > 0 do delete(sp.back_label, t.allocator)
	sp.back_label = ""
}

@(private)
split_set_back_label :: proc(t: ^Tree, sp: ^Split_State, label: string) {
	if sp.back_label == label do return
	if len(sp.back_label) > 0 do delete(sp.back_label, t.allocator)
	sp.back_label = strings.clone(label, t.allocator)
}

// split opens the container: exactly two `pane` scopes follow. Close with end.
split :: proc(ui: ^Ui($Msg), size: f32, on_change: Handler(Msg, f32) = nil, axis: Axis = .Row,
	min: f32 = SPLIT_MIN_DEFAULT, max: f32 = 0, sized: Split_Sized = .First,
	collapse: Collapse = .Never, detail := false, on_close: Maybe(Msg) = nil, back_label: string = "Back",
	gap: Space = Space_Token.none, flex: f32 = 1, width: f32 = 0, height: f32 = 0, key: u64 = 0, loc := #caller_location) -> Node {
	t := &ui.tree
	n, created := reconcile_child(ui, .Box, key, loc)
	d := node_get(t, n)
	if created {
		d.access.role = .Group
		t.splits[n] = {divider = NODE_NONE, first = NODE_NONE, second = NODE_NONE, divider_w = SPLIT_DIVIDER_W}
	}
	ax := Axis.Column if axis == .Column else Axis.Row
	gutter := space_px(&t.theme, gap) // either side of the divider; the panes need no padding towards it
	set_layout(t, n, Layout_Props{axis = ax, align = .Stretch, flex = flex, width = width, height = height, gap = gutter})
	sp := &t.splits[n]
	sp.axis = ax
	sp.gap = gutter
	sp.min = builtin.max(min, 0)
	sp.max = max
	sp.size = builtin.max(size, sp.min)
	if max > 0 do sp.size = builtin.min(sp.size, max)
	sp.sized = sized
	sp.count = 0
	if !sp.dragging do sp.sent = 0
	sc := size_class(ui)
	sp.collapsed = (collapse == .Compact && sc == .Compact) || (collapse == .Medium && sc != .Expanded)
	sp.detail = detail
	split_set_back_label(t, sp, back_label)
	ui.split_change[n] = on_change
	if m, has := on_close.?; has { ui.split_close[n] = m } else { delete_key(&ui.split_close, n) }
	open_scope(ui, n, loc)
	return n
}

// pane opens one side of the open split: the first call is the first
// pane. `glass` gives it the theme's sidebar material — thinner than a
// window's own tint, over what the compositor blurs behind the window — for
// a sidebar beside opaque content; the window itself declares `clear` with
// no tint, so the sidebar's glass is the only tint there. Where glass isn't
// live (Solid, a compositor that can't blur, an opaque window) the pane is
// the sidebar's colour, opaque, unless `bg` gives one, so a see-through
// window never shows the desktop through its sidebar. Close with end.
pane :: proc(ui: ^Ui($Msg), gap: Space = Space_Token.none, padding: Space = Space_Token.none, align: Align = .Stretch,
	bg: Color = {}, glass := false, key: u64 = 0, loc := #caller_location) -> Node {
	t := &ui.tree
	th := &t.theme
	splitn := ui.scopes[len(ui.scopes) - 1].node
	sp, ok := &t.splits[splitn]
	if !ok {
		diag(t, loc, "pane outside a split")
		return column(ui, gap = gap, padding = padding, align = align, bg = bg, key = key, loc = loc)
	}
	index := sp.count
	sp.count += 1
	if index == 1 { // the divider sits between the panes
		lk := split_look(th)
		dv, dcreated := reconcile_child(ui, .Custom, SPLIT_DIVIDER_KEY, loc)
		dd := node_get(t, dv)
		if dcreated {
			dd.access.role = .Separator
			dd.flags += {.Focusable}
			dd.kind = Custom_Kind{paint = paint_split_divider}
		}
		// Every build, so a theme with a wider bar reaches a divider that
		// exists; the extra pixel is the bar's anti-aliased edge.
		if ck, is_custom := &dd.kind.(Custom_Kind); is_custom {
			if oh := max(split_indicator_inset(lk), 0) + 1; ck.overhang != oh {
				ck.overhang = oh
				mark_paint_dirty(t, dv)
			}
		}
		set_name(t, dv, "Divider")
		dd.access.has_value = true
		dd.access.value = sp.size
		dd.access.value_min = sp.min
		dd.access.value_max = sp.max
		// Kept for input, which runs on the tree's theme rather than this one.
		sp.divider_w = lk.width
		lp: Layout_Props
		if sp.axis == .Row { lp.width = lk.width } else { lp.height = lk.width }
		set_layout(t, dv, lp)
		set_hidden(t, dv, sp.collapsed)
		sp.divider = dv
	}
	if index > 1 do diag(t, loc, "a split takes two panes")
	n, created := reconcile_child(ui, .Box, key if key != 0 else u64(index + 1), loc)
	d := node_get(t, n)
	if created do d.flags += {.Clips}
	fixed := (index == 0) == (sp.sized == .First)
	lp := Layout_Props{axis = .Column, align = align, gap = space_px(th, gap), padding = pad4(space_px(th, padding))}
	if sp.collapsed {
		lp.flex = 1 // the shown pane fills the split
	} else if fixed {
		if sp.axis == .Row { lp.width = sp.size } else { lp.height = sp.size }
	} else {
		lp.flex = 1
		if sp.axis == .Row { lp.min_w = sp.min } else { lp.min_h = sp.min }
	}
	set_layout(t, n, lp)
	set_hidden(t, n, sp.collapsed && ((index == 0) == sp.detail)) // collapsed: the first pane until detail, then the second
	st := d.style
	st.bg = bg
	st.material = {}
	if m := th.material[th.glass].sidebar; glass {
		if t.glass.on && has_material(m) {
			// Live glass: the material carries the colour, its tint already as strong as the text needs over what
			// the compositor blurs behind the window (glass_adapt); bg stays clear.
			st.material = m
			st.bg = {}
		} else if bg == {} {
			// Nothing blurred behind it (Solid, a compositor that can't blur, an opaque window): the sidebar's
			// colour, opaque, as a window's own tint is where it can't blur (surface_clear). A sidebar sits beside
			// the content, not over it, so there is no content of the app's to show through either.
			st.bg = {m.tint.r, m.tint.g, m.tint.b, 1}
		}
	}
	set_style(t, n, st)
	if index == 0 { sp.first = n } else { sp.second = n }
	open_scope(ui, n, loc)
	if index == 1 {
		showing := sp.collapsed && sp.detail
		if showing {
			if !sp.shown_detail { // the detail page comes in front of the first pane
				d.style.enter = {kind = .Fade_Up, duration = th.motion.base}
				anim_restart(t, n, .Enter, 0, 1, th.motion.base)
			}
			if m, has := ui.split_close[splitn]; has {
				row(ui, key = SPLIT_BACK_KEY, loc = loc)
				button(ui, sp.back_label, m, icon = .Chevron_Left, variant = .Ghost, loc = loc)
				end(ui)
			}
		}
		sp.shown_detail = showing
	}
	return n
}

// split_escape: Escape leaves a collapsed split's detail pane (sends
// on_close), after any open overlay has had its turn.
split_escape :: proc(ui: ^Ui($Msg)) -> bool {
	for n, sp in ui.tree.splits {
		if !sp.collapsed || !sp.detail do continue
		if m, has := ui.split_close[n]; has {
			append(&ui.msgs, m)
			return true
		}
	}
	return false
}

// split_clamp keeps a size within min / max and leaves the other pane its minimum.
@(private)
split_clamp :: proc(t: ^Tree, s: Node, v: f32) -> f32 {
	sp := t.splits[s]
	d := node_get(t, s)
	if d == nil do return v
	extent := d.abs.w if sp.axis == .Row else d.abs.h
	hi := extent - sp.divider_w - 2 * sp.gap - sp.min
	if sp.max > 0 do hi = min(hi, sp.max)
	return clamp(v, sp.min, max(hi, sp.min))
}

// split_at returns the split whose divider grab zone contains `pos`, looking
// up from the hit node so an overlay above the split wins.
@(private)
split_at :: proc(t: ^Tree, hit: Node, pos: [2]f32) -> Node {
	// A finger's zone, also where the theme asks for big targets — but no
	// wider than that: a zone reaches into both panes, and one as wide as a
	// 44 px target would take the clicks meant for what sits beside it.
	grab := SPLIT_GRAB_TOUCH if t.touch else clamp(t.theme.min_target, SPLIT_GRAB, SPLIT_GRAB_TOUCH)
	for cur := hit; cur != NODE_NONE; {
		d := node_get(t, cur)
		if d == nil do break
		if sp, ok := t.splits[cur]; ok && !sp.collapsed {
			if dd := node_get(t, sp.divider); dd != nil {
				z := dd.abs
				if sp.axis == .Row { z.x -= grab / 2; z.w += grab } else { z.y -= grab / 2; z.h += grab }
				if rect_contains(z, pos) do return cur
			}
		}
		cur = d.parent
	}
	return NODE_NONE
}

// split_hover_update tracks the divider zone under the pointer (cursor and
// accent bar). Returns true if paint changed.
@(private)
split_hover_update :: proc(ui: ^Ui($Msg), hit: Node, pos: [2]f32) -> bool {
	t := &ui.tree
	s := split_at(t, hit, pos)
	if ui.split_drag != NODE_NONE do s = NODE_NONE // a drag owns the bar
	if s == ui.split_hover do return false
	if old, ok := &t.splits[ui.split_hover]; ok {
		old.hover = false
		mark_paint_dirty(t, old.divider)
	}
	ui.split_hover = s
	if sp, ok := &t.splits[s]; ok {
		sp.hover = true
		mark_paint_dirty(t, sp.divider)
	}
	return true
}

@(private)
split_press :: proc(ui: ^Ui($Msg), hit: Node, pos: [2]f32) -> bool {
	t := &ui.tree
	s := split_at(t, hit, pos)
	if s == NODE_NONE do return false
	sp := &t.splits[s]
	sp.dragging = true
	sp.start_pos = pos.x if sp.axis == .Row else pos.y
	sp.start_size = sp.size
	sp.sent = 0
	ui.split_drag = s
	set_focus(t, sp.divider, false)
	mark_paint_dirty(t, sp.divider)
	return true
}

@(private)
split_drag :: proc(ui: ^Ui($Msg), pos: [2]f32) -> bool {
	t := &ui.tree
	s := ui.split_drag
	sp := &t.splits[s]
	if sp == nil {
		ui.split_drag = NODE_NONE
		return false
	}
	p := pos.x if sp.axis == .Row else pos.y
	delta := p - sp.start_pos
	if sp.sized == .Second do delta = -delta
	want := split_clamp(t, s, sp.start_size + delta)
	if want == (sp.sent if sp.sent > 0 else sp.size) do return false
	sp.sent = want
	if h, ok := ui.split_change[s]; ok do return handler_send(ui, h, want, s)
	return false
}

@(private)
split_release :: proc(ui: ^Ui($Msg), pos: [2]f32) {
	t := &ui.tree
	s := ui.split_drag
	ui.split_drag = NODE_NONE
	if sp, ok := &t.splits[s]; ok {
		sp.dragging = false
		mark_paint_dirty(t, sp.divider)
	}
	split_hover_update(ui, hit_test(t, pos), pos)
}

// split_key nudges a focused divider.
split_key :: proc(ui: ^Ui($Msg), key: Key, mods: Mods) -> bool {
	t := &ui.tree
	if t.focus == NODE_NONE do return false
	s := NODE_NONE
	for n, sp in t.splits do if sp.divider == t.focus { s = n; break }
	if s == NODE_NONE do return false
	sp := &t.splits[s]
	step := SPLIT_KEY_STEP * (4 if .Shift in mods else 1)
	want := sp.size
	#partial switch key {
	case .Left:  if sp.axis != .Row do return false; want -= step
	case .Right: if sp.axis != .Row do return false; want += step
	case .Up:    if sp.axis != .Column do return false; want -= step
	case .Down:  if sp.axis != .Column do return false; want += step
	case .Home:  want = sp.min
	case .End:   want = UNBOUNDED
	case: return false
	}
	if sp.sized == .Second && key != .Home && key != .End do want = sp.size - (want - sp.size)
	want = split_clamp(t, s, want)
	if want == sp.size do return true
	if h, ok := ui.split_change[s]; ok do handler_send(ui, h, want, s)
	return true
}

// paint_split_divider: a hairline, and an accent bar while hovered or dragged.
@(private)
paint_split_divider :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer) {
	th := &t.theme
	lk := split_look(th)
	line := lk.fill
	line.a *= t.paint_opacity
	append(&l.cmds, Draw_Rect{rect = d.abs, color = line})
	sp, ok := t.splits[d.parent]
	active := ok && (sp.hover || sp.dragging)
	k := anim_target(t, n, .Hover, 1 if active else 0, th.motion.fast)
	if k > 0.01 {
		c := lk.indicator
		c.a *= k * t.paint_opacity
		e := split_indicator_inset(lk)
		r := Rect{d.abs.x - e, d.abs.y, d.abs.w + 2 * e, d.abs.h} if sp.axis == .Row else Rect{d.abs.x, d.abs.y - e, d.abs.w, d.abs.h + 2 * e}
		append(&l.cmds, Draw_Rect{rect = r, color = c, radius = lk.indicator_width / 2})
	}
}
