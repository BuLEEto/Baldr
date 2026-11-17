package baldr

// Feedback: progress (a determinate bar, or an indeterminate sweep),
// spinner (an activity ring of dots) and badge (a small labelled pill).
// The bars and the spinner keep moving on their own while indeterminate;
// under reduce-motion they hold still.

import "core:fmt"
import "core:math"

PROGRESS_H :: f32(6)

// Tone colours a badge and other status chrome.
Tone :: enum u8 { Neutral, Primary, Success, Warning, Danger }

// progress shows `value` in 0..1 (clamped; the fill eases to it) or, with
// `indeterminate`, a sweeping band. Accessibility: Progress named `label`
// with the value, or Busy when indeterminate.
progress :: proc(ui: ^Ui($Msg), value: f32, label: string = "", width: f32 = 0, flex: f32 = 0, indeterminate := false,
	key: u64 = 0, loc := #caller_location) -> Node {
	t := &ui.tree
	n, created := reconcile_child(ui, .Custom, key, loc)
	d := node_get(t, n)
	if created {
		d.access.role = .Progress
		d.kind = Custom_Kind{size = {0, PROGRESS_H}, paint = paint_progress}
	}
	set_name(t, n, label)
	v := clamp(value, 0, 1)
	d.access.has_value = !indeterminate
	d.access.value, d.access.value_min, d.access.value_max = v, 0, 1
	if indeterminate { d.access.states += {.Busy} } else { d.access.states -= {.Busy} }
	if d.tag != (1 if indeterminate else 0) {
		d.tag = 1 if indeterminate else 0
		mark_paint_dirty(t, n)
	}
	set_layout(t, n, Layout_Props{width = width, flex = flex, height = PROGRESS_H, min_w = 40 if width == 0 && flex == 0 else 0})
	if !indeterminate do anim_target(t, n, .Value, v, t.theme.motion.base) // the fill eases to the new value
	return n
}

@(private)
paint_progress :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer) {
	th := &t.theme
	r := d.abs
	track := th.color.surface_variant
	track.a *= t.paint_opacity
	rad := pill_radius(th, r.h)
	append(&l.cmds, Draw_Rect{rect = r, radius = rad, color = track})
	fill := th.color.primary
	fill.a *= t.paint_opacity
	if d.tag == 0 {
		w := r.w * clamp(anim_value(t, n, .Value), 0, 1)
		if w > 0.5 do append(&l.cmds, Draw_Rect{rect = {r.x, r.y, w, r.h}, radius = rad, color = fill})
		return
	}
	// indeterminate: a band sweeps across, looping (a static band under reduce-motion)
	if th.motion.reduce {
		append(&l.cmds, Draw_Rect{rect = {r.x + r.w * 0.3, r.y, r.w * 0.4, r.h}, radius = rad, color = fill})
		return
	}
	if !anim_running(t, n, .Scroll) do anim_restart(t, n, .Scroll, 0, 1, 1300, .Ease_In_Out)
	p := anim_value(t, n, .Scroll)
	bw := r.w * 0.35
	x := r.x - bw + (r.w + bw) * p
	append(&l.cmds, Draw_Clip_Push{r})
	append(&l.cmds, Draw_Rect{rect = {x, r.y, bw, r.h}, radius = rad, color = fill})
	append(&l.cmds, Draw_Clip_Pop{})
}

// spinner is an activity ring of eight dots with a bright one going round.
// Accessibility: Status named `label`, Busy, announced politely.
spinner :: proc(ui: ^Ui($Msg), size: f32 = 20, label: string = "Loading", key: u64 = 0, loc := #caller_location) -> Node {
	t := &ui.tree
	n, created := reconcile_child(ui, .Custom, key, loc)
	d := node_get(t, n)
	if created {
		d.access.role = .Status
		set_live(t, n, .Polite)
		d.access.states += {.Busy}
	}
	if k, ok := d.kind.(Custom_Kind); !ok || k.size.x != size {
		d.kind = Custom_Kind{size = {size, size}, paint = paint_spinner}
		mark_layout_dirty(t, n)
	}
	set_name(t, n, label)
	return n
}

@(private)
paint_spinner :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer) {
	th := &t.theme
	r := d.abs
	phase: f32 = 0.25
	if !th.motion.reduce {
		if !anim_running(t, n, .Value) do anim_restart(t, n, .Value, 0, 1, 900, .Linear)
		phase = anim_value(t, n, .Value)
	}
	cx, cy := r.x + r.w / 2, r.y + r.h / 2
	orbit := r.w * 0.38
	dot := max(r.w * 0.16, 2)
	for i in 0 ..< 8 {
		f := f32(i) / 8
		ang := f * 2 * math.PI
		lead := f - phase
		lead -= f32(int(lead))
		if lead < 0 do lead += 1
		a := 0.2 + 0.8 * (1 - lead)
		c := th.color.primary
		c.a *= a * t.paint_opacity
		x := cx + orbit * math.cos(ang) - dot / 2
		y := cy + orbit * math.sin(ang) - dot / 2
		append(&l.cmds, Draw_Rect{rect = {x, y, dot, dot}, radius = dot / 2, color = c})
	}
}

// badge is a small pill with a word or a number in it: counts, states,
// tags. Accessibility: plain text.
badge :: proc(ui: ^Ui($Msg), label: string, tone: Tone = .Neutral, key: u64 = 0, loc := #caller_location) -> Node {
	t := &ui.tree
	th := &t.theme
	n, created := reconcile_child(ui, .Box, key, loc)
	d := node_get(t, n)
	if created do d.access.role = .Text
	set_name(t, n, label)
	set_layout(t, n, Layout_Props{axis = .Row, align = .Center, padding = {2, th.space[.sm], 2, th.space[.sm]}})
	bg, fg := tone_colors(th, tone)
	st := d.style
	st.bg = bg
	st.radius = th.radius.full
	set_style(t, n, st)
	open_scope(ui, n, loc)
	lbl := text(ui, label, role = .Caption, color = fg, nowrap = true, loc = loc)
	set_role(t, lbl, .None)
	close_scope(ui)
	return n
}

// tone_colors: a tinted background and a readable foreground for a tone.
tone_colors :: proc(th: ^Theme, tone: Tone) -> (bg, fg: Color) {
	c := &th.color
	switch tone {
	case .Neutral: return c.surface_high, c.on_surface
	case .Primary: return c.primary_container, c.on_primary_container
	case .Success: return mix(c.success, c.surface, 0.75), ensure_contrast(c.success, mix(c.success, c.surface, 0.75), 4.5)
	case .Warning: return mix(c.warning, c.surface, 0.75), ensure_contrast(c.warning, mix(c.warning, c.surface, 0.75), 4.5)
	case .Danger:  return mix(c.danger, c.surface, 0.75), ensure_contrast(c.danger, mix(c.danger, c.surface, 0.75), 4.5)
	}
	return c.surface_high, c.on_surface
}

@(private)
badge_text :: proc(n: int) -> string { return fmt.tprintf("%d", n) }
