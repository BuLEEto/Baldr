package baldr

// Pointer dispatch against the retained tree. Rects are already known, so
// hit-testing is exact for the current frame — no one-frame lag. Interaction
// state lives in node flags (Hovered / Pressed), which paint turns into state
// layers, so a hover costs one node repaint.

Mouse_Button :: enum u8 { Left, Right, Middle, Back, Forward }

Pointer :: struct {
	pos:     [2]f32,
	inside:  bool,
	hover:   Node, // interactive node under the pointer (or NODE_NONE)
	pressed: Node, // interactive node the current press started on
	button:  Mouse_Button,
	scroll_drag: Node, // scroll container whose thumb is being dragged
	slider_drag: Node, // slider being dragged
	mods:        Mods, // modifiers held for the current button event (set by the run loop)
	press_serial: u32, // the platform's serial for the latest press (a compositor drag needs it)
	middle_pressed: Node, // node a middle press landed on: a release over it sends its middle-click message
	area_held:   Node, // pointer area a left press landed on, until the release: it keeps its cursor (pointer_area.odin)
	buttons:     Mouse_Buttons, // held now (a pen's tip is Left)
	clicks:      Click_Count,   // the presses of one button in a row, for a sample's `clicks` (pointer_samples.odin)
	// The platform's own time for the latest button event, in ms, set by the
	// run loop. Multi-clicks are timed on this, never on `Tree.now_ms`, which
	// lags the click by the frame time and would make a slow app demand a
	// faster double-click. It is a 32-bit millisecond clock that wraps about
	// every 49 days, so every comparison also checks it has not gone backwards.
	time_ms:     f64,
}

// hit_test returns the deepest visible node whose absolute rect contains
// `p`. Later siblings are on top. NODE_NONE if nothing (not even the root).
hit_test :: proc(t: ^Tree, p: [2]f32) -> Node {
	if t.pointer_scope != NODE_NONE && node_valid(t, t.pointer_scope) do return hit_rec(t, t.pointer_scope, p) // over a popup's surface: only its card
	if t.popups_on { // overlays are on top, but a popup is hit on its own surface
		if o := node_get(t, t.overlay); o != nil && rect_contains(o.abs, p) {
			for c := o.last; c != NODE_NONE; c = node_get(t, c).prev {
				if popup_candidate(t, c) do continue
				if h := hit_rec(t, c, p); h != NODE_NONE do return h
			}
		}
		return hit_rec(t, t.root, p)
	}
	if h := hit_rec(t, t.overlay, p); h != NODE_NONE do return h // overlays are on top
	return hit_rec(t, t.root, p)
}

@(private)
hit_rec :: proc(t: ^Tree, n: Node, p: [2]f32) -> Node {
	d := node_get(t, n)
	if d == nil || d.flags & {.Hidden, .Exiting, .Hit_Transparent, .Inert} != {} || !rect_contains(d.abs, p) do return NODE_NONE
	if r, reveals := t.reveals[n]; reveals && !reveal_shown(t, n, r) do return NODE_NONE // not shown: the click lands on what it belongs to
	for c := d.last; c != NODE_NONE; c = node_get(t, c).prev {
		if hit := hit_rec(t, c, p); hit != NODE_NONE do return hit
	}
	// Nothing was hit inside it, so the node itself is the hit — unless it
	// is one of the two that only count through their children: the overlay
	// root, and any node an app marked with set_hit_children.
	if d.flags & {.Overlay, .Hit_Children} != {} do return NODE_NONE
	return n
}

// interactive_target climbs from `n` to the nearest node that reacts to the
// pointer: focusable, or with a click handler registered.
interactive_target :: proc(ui: ^Ui($Msg), n: Node) -> Node {
	cur := n
	for cur != NODE_NONE {
		d := node_get(&ui.tree, cur)
		if d == nil do return NODE_NONE
		if .Disabled in d.flags do return NODE_NONE
		if .Focusable in d.flags do return cur
		if _, ok := ui.clicks[cur]; ok do return cur
		if _, ok := ui.on_bool[cur]; ok do return cur
		if _, ok := ui.on_f32[cur]; ok do return cur
		if _, ok := ui.on_int[cur]; ok do return cur
		if _, ok := ui.rows[cur]; ok do return cur
		if _, ok := ui.tree.editor_ctl_of[cur]; ok do return cur // an editor's own control: a find bar's button, a completion candidate
		if _, ok := ui.drags[cur]; ok do return cur
		if _, ok := ui.tree.cal_day_of[cur]; ok do return cur // a date picker's day
		if _, ok := ui.tree.time_seg_of[cur]; ok do return cur // a time picker's segment
		if _, ok := ui.emoji_cells[cur]; ok do return cur // an emoji picker's cell
		if _, ok := ui.emoji_tones[cur]; ok do return cur // …its tone swatches
		if _, ok := ui.emoji_jumps[cur]; ok do return cur // …and its group buttons
		cur = d.parent
	}
	return NODE_NONE
}

// pointer_move updates hover state. Returns true when something visible changed.
// `moved` false is the pointer arriving without moving (a surface appearing
// under it, or given the pointer back when a modal overview closes): hover
// follows, so a click works at once, and so does a tracking node, since what
// the click lands on can depend on it (a magnifying dock); hoverable nodes
// hear it only once it moves, because an arrival isn't a rest.
pointer_move :: proc(ui: ^Ui($Msg), pos: [2]f32, moved := true) -> (changed: bool) {
	ui.pointer.pos = pos
	ui.pointer.inside = true
	track_move(ui, pos) // before a drag takes the motion: a tracking node follows the pointer through it, and hears where an arrival put it
	if ui.pointer.scroll_drag != NODE_NONE {
		return scrollbar_drag(&ui.tree, ui.pointer.scroll_drag, pos)
	}
	if ui.pointer.slider_drag != NODE_NONE {
		return slider_pointer(ui, ui.pointer.slider_drag, pos)
	}
	if ui.col_resize.table != NODE_NONE do return table_resize_drag(ui, pos)
	if ui.split_drag != NODE_NONE do return split_drag(ui, pos)
	if consumed, dc := drag_pointer_move(ui, pos); consumed do return dc
	if ui.time_scrub.picker != NODE_NONE && time_scrub_move(ui, pos) do return true
	if ui.marquee != NODE_NONE do return grid_marquee_drag(ui, pos)
	if ui.band_pending.view != NODE_NONE && grid_band_pending_move(ui, pos) do return true
	if ui.col_move.table != NODE_NONE && table_move_drag(ui, pos) do return true
	if graph_pointer(ui, pos) do return true // a node graph is being dragged, wired or panned
	if chart_hover(ui, pos) do return true // a chart shows the value the pointer is nearest
	if sel_scope_drag(ui, pos) do return true // a drag that has left the view it began in
	if text_area_pointer_move(ui, pos) do return true // a drag-select inside a text area
	if md_view_pointer_move(ui, pos) do return true // …and inside a markdown view
	if styled_pointer_move(ui, pos) do return true // …and inside a styled paragraph
	if text_input_pointer_move(ui, pos) do return true // text_input hook: drag-select
	hit := hit_test(&ui.tree, pos)
	if moved do hover_update(ui, hit) // hoverable nodes hear the pointer come and go, once it moves
	changed = scroll_hover_update(&ui.tree, hit, pos)
	changed = table_hover_update(ui, pos) || changed
	changed = split_hover_update(ui, hit, pos) || changed
	defer if menu_bar_hover_update(ui) do changed = true // after set_hover below
	target := interactive_target(ui, hit)
	if ui.pointer.pressed != NODE_NONE {
		// While a press is held, only the pressed node shows feedback.
		want_pressed := target == ui.pointer.pressed
		d := node_get(&ui.tree, ui.pointer.pressed)
		if d != nil && (.Pressed in d.flags) != want_pressed {
			if want_pressed { d.flags += {.Pressed} } else { d.flags -= {.Pressed} }
			mark_paint_dirty(&ui.tree, ui.pointer.pressed)
			changed = true
		}
	}
	changed = set_hover(ui, target) || changed
	slider_hover(ui, pos) // a slider with a format shows the value under the pointer
	return changed
}

// inert_hover_tick: the node the pointer rests on can turn inert under it (a
// shell entering edit mode); hover goes to what the pointer is over now, so
// no highlight or tooltip stays behind.
@(private)
inert_hover_tick :: proc(ui: ^Ui($Msg)) {
	t := &ui.tree
	if ui.pointer.hover == NODE_NONE || !ui.pointer.inside do return
	for cur := ui.pointer.hover; cur != NODE_NONE; {
		d := node_get(t, cur)
		if d == nil do return // a hover left on a node that is gone: the next move settles it
		if .Inert in d.flags {
			set_hover(ui, interactive_target(ui, hit_test(t, ui.pointer.pos)))
			return
		}
		cur = d.parent
	}
}

@(private)
set_hover :: proc(ui: ^Ui($Msg), target: Node) -> bool {
	if target == ui.pointer.hover do return false
	if old := node_get(&ui.tree, ui.pointer.hover); old != nil {
		old.flags -= {.Hovered}
		mark_paint_dirty(&ui.tree, ui.pointer.hover)
	}
	old := ui.pointer.hover
	ui.pointer.hover = target
	ui.tree.hover = target
	if d := node_get(&ui.tree, target); d != nil {
		d.flags += {.Hovered}
		mark_paint_dirty(&ui.tree, target)
	}
	reveals_touch(&ui.tree, old, target) // what shows only on hover shows, or goes
	// A hover normally only repaints. An emoji picker's preview line says
	// what the pointer is on by **name**, which is content and not paint,
	// so it needs the view: once per cell crossed, and nothing while the
	// pointer is still.
	if _, was := ui.emoji_cells[old]; was {
		ask_rebuild(ui)
	} else if _, now := ui.emoji_cells[target]; now {
		ask_rebuild(ui)
	}
	return true
}

// pointer_leave clears hover (pointer left the surface).
pointer_leave :: proc(ui: ^Ui($Msg)) -> (changed: bool) {
	ui.pointer.inside = false
	hover_update(ui, NODE_NONE)
	track_leave(ui)
	slider_hover(ui, {-1, -1}) // no value under a pointer that has gone
	changed = scroll_hover_update(&ui.tree, NODE_NONE, {-1, -1})
	changed = table_hover_update(ui, {-1e9, -1e9}) || changed
	return set_hover(ui, NODE_NONE) || changed
}

// middle_click: a middle press and release over the same node with a
// middle-click message sends it (a sidebar place opening in a new window).
@(private)
middle_click :: proc(ui: ^Ui($Msg), pressed: bool, pos: [2]f32) -> bool {
	t := &ui.tree
	target := NODE_NONE
	for cur := hit_test(t, pos); cur != NODE_NONE; cur = node_parent(t, cur) {
		if _, has := ui.middle_clicks[cur]; has {
			if .Disabled not_in node_get(t, cur).flags do target = cur
			break
		}
	}
	if pressed {
		ui.pointer.middle_pressed = target
		return target != NODE_NONE
	}
	was := ui.pointer.middle_pressed
	ui.pointer.middle_pressed = NODE_NONE
	if was == NODE_NONE || was != target do return false
	append(&ui.msgs, ui.middle_clicks[was])
	return true
}

// pointer_button handles press/release. A release over the node the press
// started on activates it (click → message). Returns true when something
// visible changed or a message was queued.
pointer_button :: proc(ui: ^Ui($Msg), button: Mouse_Button, pressed: bool, pos: [2]f32) -> (changed: bool) {
	if pressed { ui.pointer.buttons += {button} } else { ui.pointer.buttons -= {button} }
	changed = pointer_move(ui, pos)
	track_button(ui, button, pressed, pos) // a press over a tracking node holds it until the release
	t := &ui.tree
	if pressed do tooltip_hide(ui)
	if pressed {
		// Any button's press decides focus, not just the left one: a panel
		// that gains the keyboard because of this press must not land on its
		// first control or draw a ring. This cancels a landing already asked
		// for, and the flag stops one asked for before the next build
		// (keyboard_info.odin). Above the right and middle branches, which
		// return early; a landing left pending would pull focus out of the
		// menu a right-click opens.
		ui.entered_keyboard = false
		ui.pointer_took_focus = true
	}
	if pressed && dismiss_outside(ui, pos) do return true // a press outside an open popover/dialog closes it and is swallowed
	if button == .Right {
		if pressed && chrome_press(ui, pos, .Right) do return true // a title bar: the desktop's own window menu
		if pressed do return context_press(ui, pos) // item or background context request
		return
	}
	if button == .Middle && pressed && primary_paste(ui, pos) do return true // a field: the primary selection typed where it was pressed
	if button == .Middle do return middle_click(ui, pressed, pos)
	if button != .Left do return
	if !pressed do ui.pointer.area_held = NODE_NONE
	if pressed {
		// The bar before the content under it: a scroll bar's zone is drawn
		// over whatever scrolls, so the press is offered to the bar first or
		// the content always wins. That matters most where the scrolling node
		// is the content (a text area is itself the `.Scroll_V` node), hence
		// above the text-area and markdown-view presses.
		for cur := hit_test(t, pos); cur != NODE_NONE; cur = node_get(t, cur).parent {
			if fl := node_get(t, cur).flags; (.Scroll_V in fl || .Scroll_H in fl) && scrollbar_press(t, cur, pos) {
				ui.pointer.scroll_drag = cur
				return true
			}
		}
		took := text_area_pointer_button(ui, pressed, pos) || md_view_pointer_button(ui, pressed, pos) ||
			styled_pointer_button(ui, pressed, pos)
		if took { // the view placed its own selection; the scope starts from what it did
			sel_scope_press(t, hit_test(t, pos), .Shift in ui.pointer.mods)
			return true
		}
	} else {
		sel_scope_release(t)
		if text_area_pointer_button(ui, pressed, pos) do return true // drag end in a text area
		if md_view_pointer_button(ui, pressed, pos) do return true // …or in a markdown view
		if styled_pointer_button(ui, pressed, pos) do return true // …or in a styled paragraph
	}
	if text_input_pointer_button(ui, pressed, pos) do return true // text_input hook: caret placement / drag end
	if pressed {
		// A press decides focus by itself: to what it hit, to a focusable
		// ancestor, or to nothing. A pending keyboard landing was already
		// cancelled at the top of this proc.
		if split_press(ui, hit_test(t, pos), pos) do return true // a split divider takes the press
		if table_resize_press(ui, pos) do return true // a header divider takes the press
		table_header_press(ui, pos) // a header cell may turn into a column drag; the click still fires if it does not
		if grid_press(ui, pos) do return true // empty space in a table or icon view starts a rubber band
		// A window that draws its own frame, before the hover target: its
		// borders and its title bar are plain rows, which the hover never
		// tracks, so asking by target would never find them.
		if chrome_resize_press(ui, pos) do return true
		if chrome_press(ui, pos, .Left) do return true // drag to move, double click to maximise
		pointer_area_press(ui, pos) // a picture's double-click, and its cursor held through a drag; the press goes on
		target := ui.pointer.hover
		if target == NODE_NONE {
			// Nothing interactive under the pointer — a canvas, a panel's
			// background. Focus goes with the press, so the keys reach the
			// window's shortcuts rather than the last button clicked.
			focus_from_pointer(t, hit_test(t, pos))
			return
		}
		if graph_press(ui, pos) do return true // a node graph: a node, a port, a wire or the canvas
		if chart_press_at(ui, pos) do return true // a chart picks the point the pointer is nearest
		if _, is_slider := ui.on_f32[target]; is_slider {
			ui.pointer.slider_drag = target
			// `focus_on_click = false`: the press drags it without taking the
			// keyboard, as for a button, so Left and Right stay with the app
			// rather than a focused slider.
			if sd := node_get(t, target); sd == nil || .Keys_Only_Focus not_in sd.flags {
				set_focus(t, target, false)
			}
			return slider_pointer(ui, target, pos)
		}
		ui.pointer.pressed = target
		ui.pointer.button = button
		if d := node_get(t, target); d != nil {
			d.flags += {.Pressed}
			mark_paint_dirty(t, target)
		}
		focus_from_pointer(t, target) // to it, its focusable ancestor, or away
		drag_press(ui, target, pos) // a drag source: the press may become a drag
		time_scrub_press(ui, target, pos) // a time segment: the press may become a scrub
		return true
	}
	// release
	if graph_release(ui, pos) do return true // a wire landing on a port, or a drag or pan ending
	if drag_release(ui, pos) do return true
	if time_scrub_release(ui) { // a scrub ends without a click
		if d := node_get(t, ui.pointer.pressed); d != nil {
			d.flags -= {.Pressed}
			mark_paint_dirty(t, ui.pointer.pressed)
		}
		ui.pointer.pressed = NODE_NONE
		return true
	}
	if ui.col_resize.table != NODE_NONE {
		table_resize_release(ui, pos)
		return true
	}
	if ui.split_drag != NODE_NONE {
		split_release(ui, pos)
		return true
	}
	if ui.col_move.table != NODE_NONE && table_move_release(ui) do return true
	ui.band_pending = {}
	if ui.marquee != NODE_NONE {
		grid_marquee_release(ui)
		return true
	}
	if ui.pointer.scroll_drag != NODE_NONE {
		scrollbar_release(t, ui.pointer.scroll_drag)
		ui.pointer.scroll_drag = NODE_NONE
		return true
	}
	if ui.pointer.slider_drag != NODE_NONE {
		if st := &t.sliders[ui.pointer.slider_drag]; st != nil do st.dragging = false
		mark_paint_dirty(t, ui.pointer.slider_drag)
		slider_commit(ui, ui.pointer.slider_drag) // let go: the value to seek to
		ui.pointer.slider_drag = NODE_NONE
		return true
	}
	was := ui.pointer.pressed
	ui.pointer.pressed = NODE_NONE
	if was == NODE_NONE do return
	if d := node_get(t, was); d != nil {
		d.flags -= {.Pressed}
		mark_paint_dirty(t, was)
		changed = true
	}
	if ui.pointer.hover == was {
		click(ui, was)
		changed = true
	}
	return
}

// cursor_for returns the cursor the hovered node wants.
cursor_for :: proc(ui: ^Ui($Msg)) -> Cursor {
	if ui.drag.active && !ui.drag.keyboard do return .Grabbing
	if ui.col_move.dragging do return .Grabbing
	if ui.col_resize.table != NODE_NONE || ui.col_hover.table != NODE_NONE do return .Resize_EW
	if s := ui.split_drag if ui.split_drag != NODE_NONE else ui.split_hover; s != NODE_NONE {
		if sp, ok := ui.tree.splits[s]; ok do return .Resize_EW if sp.axis == .Row else .Resize_NS
	}
	// near the border of a window that draws its own frame: say it can be
	// resized before anyone tries (widget_chrome.odin)
	if c, on_edge := chrome_cursor(&ui.tree, ui.pointer.pos); on_edge do return c
	// Over a scroll bar's zone, or dragging one: the arrow, since the bar is
	// what a press grabs, not the text or picture under it. Held through the
	// drag so it does not flicker back to an I-beam off the zone.
	if ui.pointer.scroll_drag != NODE_NONE || ui.tree.bar_hover != NODE_NONE do return .Default
	if c, has := pointer_area_cursor(ui); has do return c // a picture's hand, or none in a slideshow
	if c, has := md_view_cursor(ui); has do return c // a markdown view: a hand on a link, an I-beam on its words
	if c, has := styled_cursor(ui); has do return c // …and the same pair over a styled paragraph
	d := node_get(&ui.tree, ui.pointer.hover)
	if d == nil do return .Default
	if d.access.role == .Text_Input || d.access.role == .Spin_Button do return .Text
	if d.access.role in INTERACTIVE_ROLES do return .Pointer
	return .Default
}

Cursor :: enum u8 {
	Default, Pointer, Text, Crosshair, Move, Not_Allowed, Grab, Grabbing,
	Resize_NS, Resize_EW, Resize_NESW, Resize_NWSE, Wait, Progress, Help, Hidden,
	Picture, // a picture the app drew (pointer_area's cursor_image)
}
