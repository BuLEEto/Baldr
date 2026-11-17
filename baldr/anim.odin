package baldr

import "core:math"

// Animation. Every node can own a small set of tweened values (hover, press,
// focus, opacity); only nodes with a running tween cost anything per frame.
// Widgets never animate explicitly for state changes — paint asks
// anim_target() for the eased amount of a state, and a change of target
// starts a tween from the current value. The run loop ticks with the frame
// clock and requests frames only while something moves.
//
// Accessibility: when Theme.motion.reduce is set (OS reduce-motion), every
// tween is instant. Nothing in Baldr moves, scales, or flashes for a user
// who asked it not to.

Anim_Prop :: enum u8 {
	Hover,   // 0..1 hover state layer
	Press,   // 0..1 press state layer
	Focus,   // 0..1 focus ring
	Opacity, // 0..1 node opacity (rest 1)
	Scroll,  // 0..1 scrollbar visibility
	Value,   // 0..1 widget-defined (toggle knob position, …)
	Mark_Length, // a button's mark length, logical px (button_options)
	Mark_Color, // 0..1 through a change of the mark's colour
	Badge,      // 0..1 a button's badge grown in (button_options)
	Height,     // a pages container's eased height, logical px: layout runs again while it moves
	Enter,   // 0..1 enter/exit transition progress (rest 0: a new node with a transition fades in)
	Move,    // 1..0 remaining fraction of a layout move (paint shifts by move_from × value)
	Hide,    // 0..1 a surface slid off its screen edge (hide.odin), on its root
	Progress,    // a button's progress value, eased as it changes (button_options)
	Progress_On, // 0..1 that bar grown in
	Progress_Spin, // 0..1 a button's busy progress going round (a ring) or along (a bar), looping
}

// Easing curves. Ease_Out for state and most motion, Ease_In_Out for
// symmetric moves, Spring for a slight overshoot that settles.
Easing :: enum u8 { Ease_Out, Ease_In_Out, Spring, Linear }

Tween :: struct {
	from, to: f32,
	start:    f64, // ms on the tree clock
	duration: f32, // ms; 0 = instant
	easing:   Easing,
	active:   bool,
}

Anim_State :: struct {
	tweens:  [Anim_Prop]Tween,
	value:   [Anim_Prop]f32,
	engaged: bit_set[Anim_Prop], // props a target or restart has set: until then a prop is at rest, never shown moving
	painted: Rect, // where paint last drew the node, clipped (paint_left_behind)
}

@(private)
anim_rest :: proc "contextless" (p: Anim_Prop) -> f32 {
	return 1 if p == .Opacity else 0
}

// anim_target declares where `prop` of node `n` should be. A changed target
// starts a tween from the current value over `duration_ms` (instant under
// reduce-motion). The first target a prop gets is where it starts, so a
// control shown for the first time draws its state at once (a switch that is
// on, a segmented control's pill); a node's entrance plays because paint
// starts its .Enter from rest (transition_progress). Returns the current
// eased value — call it from paint.
anim_target :: proc(t: ^Tree, n: Node, prop: Anim_Prop, to: f32, duration_ms: f32, easing: Easing = .Ease_Out) -> f32 {
	st := anim_state(t, n)
	tw := &st.tweens[prop]
	if prop not_in st.engaged { // the first target: where it starts
		st.engaged += {prop}
		tw^ = {from = to, to = to}
		st.value[prop] = to
		return to
	}
	if tw.to != to {
		dur := duration_ms
		if t.theme.motion.reduce do dur = 0
		tw^ = {from = st.value[prop], to = to, start = t.now_ms, duration = dur, easing = easing, active = dur > 0}
		if dur <= 0 {
			st.value[prop] = to
		} else {
			t.anim_active = true
		}
	}
	return st.value[prop]
}

// anim_restart starts a tween of `prop` from `from` to `to` now, whatever
// its current value or target (a layout move that begins at 1, an enter
// fade played again). Instant under reduce-motion.
anim_restart :: proc(t: ^Tree, n: Node, prop: Anim_Prop, from, to: f32, duration_ms: f32, easing: Easing = .Ease_Out) {
	st := anim_state(t, n)
	st.engaged += {prop}
	dur := duration_ms
	if t.theme.motion.reduce do dur = 0
	st.tweens[prop] = {from = from, to = to, start = t.now_ms, duration = dur, easing = easing, active = dur > 0}
	st.value[prop] = to if dur <= 0 else from
	if dur > 0 do t.anim_active = true
	mark_paint_dirty(t, n)
}

@(private)
anim_state :: proc(t: ^Tree, n: Node) -> ^Anim_State {
	st, ok := &t.anims[n]
	if !ok {
		s: Anim_State
		for p in Anim_Prop {
			s.value[p] = anim_rest(p)
			s.tweens[p] = {from = s.value[p], to = s.value[p]}
		}
		t.anims[n] = s
		st = &t.anims[n]
	}
	return st
}

// anim_running reports whether `prop` of `n` has a tween in flight.
anim_running :: proc(t: ^Tree, n: Node, prop: Anim_Prop) -> bool {
	if st, ok := t.anims[n]; ok do return st.tweens[prop].active
	return false
}

// anim_value reads the current value without changing the target.
anim_value :: proc(t: ^Tree, n: Node, prop: Anim_Prop) -> f32 {
	if st, ok := t.anims[n]; ok do return st.value[prop]
	return anim_rest(prop)
}

// anim_tick advances every running tween to `now_ms`, dirtying the nodes
// whose values changed. Returns true while anything is still in motion — the
// caller must then draw another frame.
anim_tick :: proc(t: ^Tree, now_ms: f64) -> (active: bool) {
	dt := f32(clamp((now_ms - t.now_ms) / 1000, 0, 0.1)) if t.now_ms > 0 else 0
	t.now_ms = now_ms
	fire_timers(t, now_ms)
	if scroll_tick(t, dt) do active = true
	stale := make([dynamic]Node, context.temp_allocator)
	for n, &st in t.anims {
		if node_get(t, n) == nil {
			append(&stale, n)
			continue
		}
		changed := false
		for p in Anim_Prop {
			tw := &st.tweens[p]
			if !tw.active do continue
			k := f32((now_ms - tw.start) / f64(tw.duration))
			if k >= 1 {
				st.value[p] = tw.to
				tw.active = false
				if p == .Move { // the move is over: paint at the layout position from now on
					if d := node_get(t, n); d != nil do d.move_from = {}
				}
			} else {
				st.value[p] = tw.from + (tw.to - tw.from) * ease(max(k, 0), tw.easing)
				active = true
			}
			changed = true
			if p == .Height do mark_layout_dirty(t, n) // a height that moves takes its space as it goes
		}
		if changed do mark_paint_dirty(t, n)
	}
	for n in stale do delete_key(&t.anims, n)
	if pictures_tick(t, now_ms) do active = true
	t.anim_active = active
	return
}

// pictures_tick advances every animated picture that is on screen. One off
// screen is not stepped, asks for no frame and costs nothing, which is why
// the frames live in one texture and a frame is only a source rectangle.
//
// Under reduce-motion nothing moves and frame 0 stands.
@(private)
pictures_tick :: proc(t: ^Tree, now_ms: f64) -> (active: bool) {
	if t.theme.motion.reduce do return false
	for n, &p in t.pictures {
		if p.frames <= 1 || p.released || len(p.delays) != p.frames do continue
		d := node_get(t, n)
		if d == nil || .Hidden in d.flags do continue
		if !picture_on_screen(t, d) do continue
		frame, _ := image_frame_at(p.delays, p.started_ms, now_ms)
		active = true // it is on screen and moving: keep the frames coming
		if frame == p.frame do continue
		p.frame = frame
		p.source = image_frame_rect_of(p.size.x, p.size.y, p.frames, p.cols, frame)
		mark_paint_dirty(t, n)
	}
	return
}

// picture_on_screen is whether any of the node is inside the window. A
// virtualised list destroys what scrolls far enough away, but a plain
// column keeps it, and a GIF under the fold must still cost nothing.
@(private)
picture_on_screen :: proc(t: ^Tree, d: ^Node_Data) -> bool {
	r := d.abs
	if r.w <= 0 || r.h <= 0 do return false
	return r.x < t.viewport.x && r.y < t.viewport.y && r.x + r.w > 0 && r.y + r.h > 0
}

// ease maps 0..1 progress through the chosen curve.
ease :: proc "contextless" (k: f32, e: Easing) -> f32 {
	switch e {
	case .Ease_Out:    return ease_out_cubic(k)
	case .Ease_In_Out: return ease_in_out_cubic(k)
	case .Spring:      return ease_spring(k)
	case .Linear:      return clamp(k, 0, 1)
	}
	return ease_out_cubic(k)
}

// ease_spring overshoots by about 9% around 40% of the way and settles by
// the end: a damped oscillation.
ease_spring :: proc "contextless" (k: f32) -> f32 {
	if k >= 1 do return 1
	return 1 - math.exp(-6 * k) * math.cos(2 * math.PI * 1.2 * k)
}

ease_out_cubic :: proc "contextless" (k: f32) -> f32 {
	x := 1 - k
	return 1 - x * x * x
}

ease_in_out_cubic :: proc "contextless" (k: f32) -> f32 {
	if k < 0.5 do return 4 * k * k * k
	x := -2 * k + 2
	return 1 - x * x * x / 2
}
