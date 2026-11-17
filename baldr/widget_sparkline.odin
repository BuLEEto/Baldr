package baldr

// A sparkline: a small graph of a value over time, beside the number it
// shows — nothing but its line (a system monitor's sidebar tile at 64 × 28).
//
// It is not a small chart: it is read at a glance, next to a number that
// says the value exactly, so it has no axes, legend or keyboard path and
// takes no focus. What it keeps is what makes a line at this size honest:
// a scale that can be pinned (a CPU is read against 0–100 %, not its own
// busiest moment), a history that grows in from the right the way time
// runs, and a stroke that stays inside its box at its peaks.

import "core:fmt"

@(private) SPARK_LINE_W :: f32(1.5) // thin: at 28 px a chart's 2 px line reads as a band
@(private) SPARK_FILL_A :: f32(0.2) // the area under it: there, but quieter than the line

// Sparkline_Kept is what a sparkline holds past the build that passed its
// values, for paint.
@(private)
Sparkline_Kept :: struct {
	values:       [dynamic]f32,
	span:         int,
	y_min, y_max: Maybe(f32),
	color:        Color,
	fill:         bool,
}

// sparkline draws `values` (oldest first) as a line `width` × `height`, for
// a live value beside its number (a list row's `value`, a sidebar's tile).
// `span` is how many values the width holds: a history still filling up
// grows in from the right and older values leave at the left (0: as many as
// there are, edge to edge). `y_min` / `y_max` pin the scale (0 and 100 for a
// percentage); left out, it runs from 0, or the lowest value if that is
// below 0, to the highest. `color` is the line's ({}: the accent) and
// `fill` shades what is under it. It is decorative, as the number beside it
// is what is read; with a `label` it is an Image named that, described by
// its range and latest value.
//
//	baldr.sparkline(ui, s.cpu_history[:], color = cpu_blue, fill = true, y_min = 0, y_max = 100, span = 180)
sparkline :: proc(ui: ^Ui($Msg), values: []f32, width: f32 = 64, height: f32 = 28, color: Color = {}, fill := false,
	y_min: Maybe(f32) = nil, y_max: Maybe(f32) = nil, span: int = 0, label: string = "", key: u64 = 0, loc := #caller_location) -> Node {
	n, _ := reconcile_child(ui, .Custom, key, loc)
	t := &ui.tree
	d := node_get(t, n)
	kept, had := &t.sparklines[n]
	if !had {
		t.sparklines[n] = Sparkline_Kept{values = make([dynamic]f32, t.allocator)}
		kept = &t.sparklines[n]
	}
	same := had && len(kept.values) == len(values) && kept.span == span && kept.y_min == y_min && kept.y_max == y_max &&
		kept.color == color && kept.fill == fill
	if same do for v, i in values do if kept.values[i] != v {
		same = false
		break
	}
	if !same {
		clear(&kept.values)
		append(&kept.values, ..values)
		kept.span, kept.y_min, kept.y_max, kept.color, kept.fill = span, y_min, y_max, color, fill
		mark_paint_dirty(t, n)
	}
	if ck, ok := d.kind.(Custom_Kind); !ok || ck.size != {width, height} {
		d.kind = Custom_Kind{size = {width, height}, paint = paint_sparkline}
		mark_layout_dirty(t, n)
	}
	if label != "" {
		d.access.role = .Image
		set_name(t, n, label)
		set_describe(t, n, sparkline_summary(t, kept))
	} else {
		d.access.role = .None
	}
	return n
}

// sparkline_bounds is the scale of the `values` shown: pinned where the app
// said, else from 0 (or the lowest value below it) to the highest, never
// empty.
@(private)
sparkline_bounds :: proc(k: ^Sparkline_Kept, values: []f32) -> (lo, hi: f32) {
	lo, hi = 0, 0
	for v in values do lo, hi = min(lo, v), max(hi, v)
	if p, pinned := k.y_min.?; pinned do lo = p
	if p, pinned := k.y_max.?; pinned do hi = p
	if hi <= lo do hi = lo + 1
	return
}

// sparkline_summary is what a reader hears when it is labelled: the range
// and the latest value, as the chart's series say theirs.
@(private)
sparkline_summary :: proc(t: ^Tree, k: ^Sparkline_Kept) -> string {
	if len(k.values) == 0 do return "no data"
	lo, hi := k.values[0], k.values[0]
	for v in k.values do lo, hi = min(lo, v), max(hi, v)
	step := f64(chart_step(f64(hi - lo) / 5)) if hi > lo else 1
	return fmt.tprintf("%d values, %s to %s, now %s", len(k.values),
		chart_tick_text(t, f64(lo), step), chart_tick_text(t, f64(hi), step), chart_tick_text(t, f64(k.values[len(k.values) - 1]), step))
}

@(private)
paint_sparkline :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer) {
	k, has := &t.sparklines[n]
	if !has || len(k.values) == 0 do return
	r := d.abs
	half := SPARK_LINE_W * 0.5
	plot := Rect{r.x + half, r.y + half, max(r.w - SPARK_LINE_W, 1), max(r.h - SPARK_LINE_W, 1)} // the stroke inside the box at its peaks
	values := k.values[max(len(k.values) - k.span, 0):] if k.span > 0 else k.values[:] // more than the width holds: the latest
	lo, hi := sparkline_bounds(k, values) // scaled to what shows
	slots := max(k.span, len(values))
	step := plot.w / f32(max(slots - 1, 1))
	first := slots - len(values) // a history still filling up starts this many slots in
	at :: proc(plot: Rect, lo, hi, v: f32) -> f32 {
		f := clamp((v - lo) / (hi - lo), 0, 1) // a value past a pinned scale draws at its edge
		return plot.y + plot.h - f * plot.h
	}
	color := k.color if k.color != {} else t.theme.color.primary
	if disabled_within(t, n) do color = with_alpha(color, color.a * t.theme.state.disabled_alpha)
	base := at(plot, lo, hi, clamp(0, lo, hi))
	if k.fill && len(values) > 1 { // shaded under the line as a chart's area is
		pts := make([][2]f32, len(values), context.temp_allocator) // only while painting: nothing painted points into it
		for v, i in values do pts[i] = {plot.x + f32(first + i) * step, at(plot, lo, hi, v)}
		fill_under(l, pts, base, with_alpha(color, color.a * SPARK_FILL_A))
	}
	if len(values) == 1 { // one value is still a reading: a dot where it is
		y := at(plot, lo, hi, values[0])
		x := plot.x + f32(first) * step
		append(&l.cmds, Draw_Rect{rect = {x - 1.5, y - 1.5, 3, 3}, radius = 1.5, color = color})
		return
	}
	for i in 0 ..< len(values) - 1 {
		append(&l.cmds, Draw_Line{
			a = {plot.x + f32(first + i) * step, at(plot, lo, hi, values[i])},
			b = {plot.x + f32(first + i + 1) * step, at(plot, lo, hi, values[i + 1])},
			width = SPARK_LINE_W, color = color,
		})
	}
}

// sparkline_free gives a sparkline's values back when its node goes.
@(private)
sparkline_free :: proc(t: ^Tree, n: Node) {
	if k, has := &t.sparklines[n]; has {
		delete(k.values)
		delete_key(&t.sparklines, n)
	}
}
