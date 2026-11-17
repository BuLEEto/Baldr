package baldr

// Touch: one finger drives the same controls the pointer does, with the
// gestures a phone user expects. A touch starts Pending; if it moves past
// TOUCH_SLOP it becomes a pan of the nearest container that scrolls along
// the dominant direction (with a fling on release), a slider drag when it
// started on a slider and moves sideways, or a plain press; a touch that
// lifts without moving is a tap (press + release through the pointer path,
// so buttons, tabs, options and text carets all work). Extra fingers are
// ignored. Hover never sticks after a touch.

TOUCH_SLOP :: f32(8)

Touch_Gesture :: enum u8 { None, Pending, Pan, Slider, Press, Drag }

TOUCH_LONG_PRESS_MS :: 450.0 // a finger resting this long on a drag source lifts it (a plain move scrolls)

Touch_State :: struct {
	id:      i32,
	gesture: Touch_Gesture,
	start:   [2]f32,
	pos:     [2]f32,
	last:    [2]f32,
	last_ms: f64,
	vel:     [2]f32, // px/s, smoothed
	target:  Node,   // interactive node under the finger at Down
	scroll:  Node,   // container being panned
	down_ms: f64,    // when the finger landed (long-press timing)
}

touch_down :: proc(ui: ^Ui($Msg), id: i32, pos: [2]f32, now_ms: f64) -> (changed: bool) {
	if ui.finger.gesture != .None do return false // second finger: ignored
	t := &ui.tree
	hit := hit_test(t, pos)
	ui.finger = {id = id, gesture = .Pending, start = pos, pos = pos, last = pos, last_ms = now_ms,
		target = interactive_target(ui, hit), down_ms = now_ms}
	tooltip_hide(ui)
	if src := drag_source_of(ui, ui.finger.target); src != NODE_NONE do tree_wake_at(t, now_ms + TOUCH_LONG_PRESS_MS, src)
	return false
}

// touch_tick lifts a drag when a finger has rested on a drag source for the
// long-press time without moving. Called from ui_after_events.
@(private)
touch_tick :: proc(ui: ^Ui($Msg), now_ms: f64) {
	ts := &ui.finger
	if ts.gesture != .Pending || now_ms - ts.down_ms < TOUCH_LONG_PRESS_MS do return
	src := drag_source_of(ui, ts.target)
	if src == NODE_NONE do return
	ts.gesture = .Drag
	ui.drag.start, ui.drag.pos = ts.start, ts.pos
	drag_begin(ui, src, false)
}

touch_move :: proc(ui: ^Ui($Msg), id: i32, pos: [2]f32, now_ms: f64) -> (changed: bool) {
	ts := &ui.finger
	if ts.gesture == .None || ts.id != id do return false
	t := &ui.tree
	delta := pos - ts.last
	dt := now_ms - ts.last_ms
	if dt > 0 {
		inst := delta / f32(dt / 1000)
		ts.vel = ts.vel * 0.5 + inst * 0.5
	}
	ts.last, ts.last_ms, ts.pos = pos, now_ms, pos
	if ts.gesture == .Pending {
		off := pos - ts.start
		if abs(off.x) < TOUCH_SLOP && abs(off.y) < TOUCH_SLOP do return false
		horizontal := abs(off.x) > abs(off.y)
		hit := hit_test(t, ts.start)
		if _, is_slider := ui.on_f32[ts.target]; is_slider && horizontal {
			ts.gesture = .Slider
			ui.pointer.slider_drag = ts.target
			set_focus(t, ts.target, false)
			return slider_pointer(ui, ts.target, pos)
		}
		sc := scroll_ancestor_axis(t, hit, 0 if horizontal else 1)
		if sc == NODE_NONE do sc = scroll_ancestor(t, hit)
		if sc != NODE_NONE {
			ts.gesture = .Pan
			ts.scroll = sc
			if st, ok := &t.scrolls[sc]; ok do st.fling = false
			return scroll_by(t, sc, -off)
		}
		ts.gesture = .Press
		changed = pointer_button(ui, .Left, true, ts.start)
		ui.drag.pending = false // a finger lifts a drag by resting, never by travelling
		return pointer_move(ui, pos) || changed
	}
	switch ts.gesture {
	case .Pan:    return scroll_by(t, ts.scroll, -delta)
	case .Slider: return slider_pointer(ui, ts.target, pos)
	case .Press:  return pointer_move(ui, pos)
	case .Drag:
		_, moved := drag_pointer_move(ui, pos)
		return moved
	case .None, .Pending:
	}
	return false
}

touch_up :: proc(ui: ^Ui($Msg), id: i32, now_ms: f64) -> (changed: bool) {
	ts := &ui.finger
	if ts.gesture == .None || ts.id != id do return false
	t := &ui.tree
	g := ts.gesture
	ts.gesture = .None
	switch g {
	case .Pending:
		// a tap: press and release where the finger landed
		pointer_move(ui, ts.start)
		pointer_button(ui, .Left, true, ts.start)
		pointer_button(ui, .Left, false, ts.start)
		pointer_leave(ui) // no hover lingers under a lifted finger
		return true
	case .Pan:
		if now_ms - ts.last_ms > 80 do ts.vel = {} // the finger rested before lifting
		scroll_fling(t, ts.scroll, -ts.vel)
		return true
	case .Slider, .Press:
		changed = pointer_button(ui, .Left, false, ts.pos)
		pointer_leave(ui)
		return true
	case .Drag:
		drag_release(ui, ts.pos)
		pointer_leave(ui)
		return true
	case .None:
	}
	return false
}

// touch_cancel drops the sequence without activating anything.
touch_cancel :: proc(ui: ^Ui($Msg)) -> (changed: bool) {
	ts := &ui.finger
	if ts.gesture == .None do return false
	g := ts.gesture
	ts.gesture = .None
	t := &ui.tree
	switch g {
	case .Slider:
		if st := &t.sliders[ts.target]; st != nil do st.dragging = false
		ui.pointer.slider_drag = NODE_NONE
		mark_paint_dirty(t, ts.target)
	case .Drag:
		drag_end(ui)
	case .Press:
		if d := node_get(t, ui.pointer.pressed); d != nil {
			d.flags -= {.Pressed}
			mark_paint_dirty(t, ui.pointer.pressed)
		}
		ui.pointer.pressed = NODE_NONE
	case .None, .Pending, .Pan:
	}
	pointer_leave(ui)
	return true
}
