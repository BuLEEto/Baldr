package baldr

// A chart: what a series of numbers looks like.
//
// The app hands over its series and says what shape they take — a line, an
// area, bars, a scatter — and the widget does the rest: bounds, ticks that
// land on round numbers in the desktop's own notation, a grid that stays out
// of the way, a legend, the value under the pointer, and a keyboard path
// through every point for someone who cannot use one.
//
// Three rules it keeps, because a chart that breaks them misleads:
//
//   - **One vertical scale.** Two measures of different size are two charts,
//     or one indexed to a common base — never two axes, which lets the
//     drawing imply a relationship that the numbers do not have.
//   - **Identity is never colour alone.** Two or more series always carry a
//     legend, four or fewer are also labelled where they end, and a scatter's
//     series take a marker shape of their own (chart_palette.odin explains
//     what that is protecting).
//   - **The text is text.** Values, ticks and labels wear the theme's text
//     colours; the coloured thing is the mark beside them, which is what
//     carries identity.

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"

// Chart_Kind is the shape a series takes. A chart can mix them — bars with a
// line over them is the common one — by setting `kind` per series.
Chart_Kind :: enum u8 {
	Line,    // a value that moves through time or another continuous run
	Area,    // …the same, with what is under it filled: a total, not a rate
	Bar,     // a magnitude per category, read against a zero baseline
	Scatter, // two measures against each other, one point per observation
}

// Chart_Point is one observation. `x` is the position along the bottom — an
// index for categories, or any number for a continuous run — and `y` the
// value.
Chart_Point :: struct {
	x, y: f64,
}

// Chart_Series is one line, area, set of bars or cloud of points. `color`
// left zero takes the series' slot in the palette, which is the usual thing
// to do: the slots are chosen to be told apart (chart_palette.odin).
Chart_Series :: struct {
	name:   string,
	points: []Chart_Point,
	kind:   Maybe(Chart_Kind), // nil: the chart's own kind
	color:  Color,
}

// Chart_Hit is a point the reader picked, by pointer or by key.
Chart_Hit :: struct {
	series: int,
	index:  int,
	point:  Chart_Point,
	name:   string, // the series' name, for the message that wants to say it: the chart's copy, valid while the message is handled
}

@(private) CHART_PAD_L      :: f32(52) // room for the value axis' labels
@(private) CHART_PAD_B      :: f32(28) // …and the bottom axis'
@(private) CHART_PAD_T      :: f32(10)
@(private) CHART_PAD_R      :: f32(12)
@(private) CHART_LINE_W     :: f32(2)  // a thin mark: the data is the ink, not the line
@(private) CHART_MARKER     :: f32(8)  // the smallest a point can be and still be aimed at
@(private) CHART_BAR_GAP    :: f32(2)  // the surface showing between neighbouring bars
@(private) CHART_TICKS      :: 5
@(private) CHART_DIRECT_MAX :: 4       // series up to this many are labelled where they end
@(private) CHART_HIT_SLACK  :: f32(24) // how far the pointer may be from a point and still mean it

// Chart_State is what the widget remembers between builds: where the pointer
// is, and where the keyboard is.
@(private)
Chart_State :: struct {
	kind:     Chart_Kind,
	hover:    int, // index along x under the pointer, -1 for none
	hover_s:  int, // …and which series, for a scatter
	cursor:   int, // the keyboard's point, -1 until a key moves it
	cursor_s: int,
	bounds:   Chart_Bounds,
	x_grid:   f64,  // vertical grid lines at every multiple of this along x (0: none): they move as the range moves
	plot:     Rect, // where the marks go, inside the axes
	count:    int,  // series built last time, so the cursor stays in range
	longest:  int,  // …and the longest series
	readout:  string, // the value being read, kept here so paint allocates nothing
	ticks:    [CHART_TICKS + 1]string, // the value axis' labels, bottom up: kept, as the painted draw list outlives the frame
}

@(private)
Chart_Bounds :: struct {
	x_lo, x_hi, y_lo, y_hi: f64,
	step:                   f64, // the value axis' tick step
	slot:                   f64, // the width along x a category's bars share: the smallest step between bars' x (0: no bars)
}

// chart draws `series`. `kind` is what they are unless a series says
// otherwise; `label` names the chart for a screen reader and `describe` adds
// a sentence of context. `y_min` / `y_max` pin the value axis where the data
// alone would mislead (a rate read against 0–100); left out, they come from
// the data, rounded outwards to the tick. `x_labels` names the categories
// along the bottom, label i at x = i; bars stand on their x, so a missing
// category is a gap. `x_min` / `x_max` pin the bottom axis the
// same way, so a window of time keeps its place and a series that starts
// partway across is drawn from where it starts. `x_grid` draws a vertical
// line at every multiple of it along x; the lines scroll as the range moves,
// so a steady value still reads as live. The value under the pointer is
// shown; arrow keys walk the points and Up / Down change series, and every
// series is in the accessibility tree.
//
//	baldr.chart(ui, sales[:], kind = .Bar, label = "Sales by month",
//		x_labels = months[:], on_select = proc(e: baldr.Ev(baldr.Chart_Hit)) -> Msg { return Picked{e.value} })
chart :: proc(ui: ^Ui($Msg), series: []Chart_Series, kind: Chart_Kind = .Line,
	label: string = "", describe: string = "", x_labels: []string = nil,
	y_min: Maybe(f64) = nil, y_max: Maybe(f64) = nil, legend := true, grid := true,
	height: f32 = 240, width: f32 = 0, flex: f32 = 0,
	on_select: Handler(Msg, Chart_Hit) = nil, x_min: Maybe(f64) = nil, x_max: Maybe(f64) = nil, x_grid: f64 = 0,
	tag: u64 = 0, key: u64 = 0, loc := #caller_location) -> Node {
	// A chart is a plot and a legend, one above the other: the legend is made
	// of real nodes so it is themed, laid out and read like anything else,
	// and the plot is the node that paints itself. Giving the legend its own
	// room is also what keeps it from sitting on top of the marks.
	outer := column(ui, gap = .sm, width = width, height = 0, flex = flex, key = key, loc = loc)
	defer end(ui)
	t := &ui.tree
	n, created := reconcile_child(ui, .Custom, 1, loc)
	d := node_get(t, n)
	if created {
		t.charts[n] = Chart_State{hover = -1, hover_s = -1, cursor = -1, cursor_s = 0}
		d.flags += {.Focusable}
	}
	s := &t.charts[n]
	if s.kind != kind do mark_paint_dirty(t, n)
	s.kind = kind
	s.count = len(series)
	s.longest = 0
	for se in series do s.longest = max(s.longest, len(se.points))
	if s.cursor >= 0 { // the data may have shrunk under it
		s.cursor_s = clamp(s.cursor_s, 0, max(len(series) - 1, 0))
		if s.cursor_s < len(series) do s.cursor = clamp(s.cursor, 0, max(len(series[s.cursor_s].points) - 1, 0))
	}
	bounds := chart_bounds(series, kind, y_min, y_max, x_min, x_max)
	if s.bounds != bounds || s.x_grid != x_grid do mark_paint_dirty(t, n) // a moving window of time moves the marks and the grid
	s.bounds = bounds
	s.x_grid = max(x_grid, 0)
	chart_ticks_set(t, n, s)

	// The series are kept for paint and for the pointer, in the tree's own
	// memory: the app's slice is only borrowed for this build.
	chart_keep(t, n, series, x_labels)
	d.kind = Custom_Kind{paint = paint_chart, measure = measure_chart, user = rawptr(uintptr(n))}
	set_layout(t, n, Layout_Props{height = height})

	// What a reader is told: the chart itself, and then a legend row per
	// series carrying that series' own summary — which is how the numbers
	// reach someone who cannot see the marks at all.
	d.access.role = .Group
	set_name(t, n, label if label != "" else "Chart")
	set_describe(t, n, chart_summary(t, n, describe))
	// the app's sentence is kept, not borrowed: it is read again every time
	// the reading moves, long after the build that passed it
	if old, had := t.chart_note[n]; !had || old != describe {
		if had do delete(old, t.allocator)
		t.chart_note[n] = strings.clone(describe, t.allocator)
	}
	if handler_live(on_select) do ui.chart_select[n] = on_select
	if legend && len(series) >= 2 do chart_legend(ui, n, series)
	return outer
}

// chart_bounds is the range the marks are drawn in: the data's own, with the
// value axis rounded outwards to a round number so the ticks read as ones.
@(private)
chart_bounds :: proc(series: []Chart_Series, kind: Chart_Kind, y_min, y_max: Maybe(f64), x_min: Maybe(f64) = nil, x_max: Maybe(f64) = nil) -> (b: Chart_Bounds) {
	b = {x_lo = max(f64), x_hi = min(f64), y_lo = max(f64), y_hi = min(f64)}
	any_point := false
	for se in series do for p in se.points {
		any_point = true
		b.x_lo, b.x_hi = min(b.x_lo, p.x), max(b.x_hi, p.x)
		b.y_lo, b.y_hi = min(b.y_lo, p.y), max(b.y_hi, p.y)
	}
	if !any_point do b = {x_lo = 0, x_hi = 1, y_lo = 0, y_hi = 1, step = 1}
	if lo, said := y_min.?; said do b.y_lo = lo
	if hi, said := y_max.?; said do b.y_hi = hi
	if lo, said := x_min.?; said do b.x_lo = lo
	if hi, said := x_max.?; said do b.x_hi = hi
	// A bar is read as a length from zero, and an area's fill makes the same
	// claim, so the axis includes zero whatever the data does: a bar chart
	// starting at 20 exaggerates every difference. An axis the app pins
	// itself is taken at its word.
	for se in series {
		k := kind
		if own, said := se.kind.?; said do k = own
		if k == .Bar || k == .Area {
			if y_min == nil do b.y_lo = min(b.y_lo, 0)
			if y_max == nil do b.y_hi = max(b.y_hi, 0)
			break
		}
	}
	// half a slot either side, so the outer bars fit and each bar is centred
	// on its x, under its label
	b.slot = chart_bar_slot(series, kind)
	if b.slot > 0 && any_point {
		if x_min == nil do b.x_lo -= b.slot * 0.5
		if x_max == nil do b.x_hi += b.slot * 0.5
	}
	if b.x_hi <= b.x_lo do b.x_hi = b.x_lo + 1
	if b.y_hi <= b.y_lo do b.y_hi = b.y_lo + 1
	b.step = chart_step((b.y_hi - b.y_lo) / f64(CHART_TICKS))
	if y_min == nil do b.y_lo = math.floor(b.y_lo / b.step) * b.step
	if y_max == nil do b.y_hi = math.ceil(b.y_hi / b.step) * b.step
	return
}

// chart_bar_slot is the smallest distance between two different x values
// among the bar series, 1 when they have only one; 0 when there are no
// bars.
@(private)
chart_bar_slot :: proc(series: []Chart_Series, kind: Chart_Kind) -> f64 {
	xs := make([dynamic]f64, context.temp_allocator)
	for se in series {
		k := kind
		if own, said := se.kind.?; said do k = own
		if k == .Bar do for p in se.points do append(&xs, p.x)
	}
	if len(xs) == 0 do return 0
	slice.sort(xs[:])
	gap := max(f64)
	for i in 1 ..< len(xs) do if d := xs[i] - xs[i - 1]; d > 0 do gap = min(gap, d)
	return 1 if gap == max(f64) else gap
}

// chart_step is the round number nearest `raw` from the 1–2–5 series, so a
// tick lands on 20 rather than 17.43.
@(private)
chart_step :: proc(raw: f64) -> f64 {
	if raw <= 0 do return 1
	mag := math.pow(10, math.floor(math.log10(raw)))
	n := raw / mag
	step := mag
	switch {
	case n <= 1: step = mag
	case n <= 2: step = 2 * mag
	case n <= 5: step = 5 * mag
	case:        step = 10 * mag
	}
	return step
}

// chart_tick_text writes a tick in the desktop's notation: its decimal mark,
// its thousands separator, and no more decimals than the step needs.
@(private)
chart_tick_text :: proc(t: ^Tree, v, step: f64) -> string {
	decimals := 0
	for s := step; s < 1 && decimals < 6; s *= 10 do decimals += 1
	s := number_format(t, f32(v), decimals)
	if t.locale.thousands == "" do return s
	// group the integer part from the right
	dot := strings.index(s, t.locale.decimal if t.locale.decimal != "" else ".")
	head := s if dot < 0 else s[:dot]
	tail := "" if dot < 0 else s[dot:]
	neg := strings.has_prefix(head, "-")
	if neg do head = head[1:]
	if len(head) <= 3 do return s
	b := strings.builder_make(context.temp_allocator)
	if neg do strings.write_string(&b, "-")
	lead := len(head) % 3
	if lead > 0 {
		strings.write_string(&b, head[:lead])
		if len(head) > lead do strings.write_string(&b, t.locale.thousands)
	}
	for i := lead; i < len(head); i += 3 {
		strings.write_string(&b, head[i:i + 3])
		if i + 3 < len(head) do strings.write_string(&b, t.locale.thousands)
	}
	strings.write_string(&b, tail)
	return strings.to_string(b)
}

// chart_ticks_set writes the value axis' labels into the chart's own
// memory when they change. Paint must not make them: a layer's draw list is
// kept and drawn again on later frames, after the frame's temp memory a
// label made there has gone.
@(private)
chart_ticks_set :: proc(t: ^Tree, n: Node, s: ^Chart_State) {
	b := s.bounds
	for i in 0 ..= CHART_TICKS {
		v := b.y_lo + (b.y_hi - b.y_lo) * f64(i) / f64(CHART_TICKS)
		label := chart_tick_text(t, v, b.step)
		if label == s.ticks[i] do continue
		delete(s.ticks[i], t.allocator)
		s.ticks[i] = strings.clone(label, t.allocator)
		mark_paint_dirty(t, n)
	}
}

// ------------------------------------------------------------ what it keeps

// Chart_Kept is the data as the widget holds it: the app's slices are only
// borrowed for the build that passed them, and paint happens later.
@(private)
Chart_Kept :: struct {
	series:   [dynamic]Chart_Kept_Series,
	x_labels: [dynamic]string,
}

@(private)
Chart_Kept_Series :: struct {
	name:   string,
	points: [dynamic]Chart_Point,
	kind:   Maybe(Chart_Kind),
	color:  Color,
}

@(private)
chart_keep :: proc(t: ^Tree, n: Node, series: []Chart_Series, x_labels: []string) {
	kept, had := &t.chart_data[n]
	if !had {
		t.chart_data[n] = Chart_Kept{}
		kept = &t.chart_data[n]
	}
	// Paint draws these strings by alias, so the same data keeps them; new
	// data repaints, which makes freeing the old copies safe.
	if had && chart_same(kept, series, x_labels) do return
	mark_paint_dirty(t, n)
	chart_kept_clear(t, kept)
	for se in series {
		k := Chart_Kept_Series{name = strings.clone(se.name, t.allocator), kind = se.kind, color = se.color}
		k.points = make([dynamic]Chart_Point, t.allocator)
		append(&k.points, ..se.points)
		append(&kept.series, k)
	}
	for l in x_labels do append(&kept.x_labels, strings.clone(l, t.allocator))
}

// chart_same: the series and labels are what the chart already holds.
@(private)
chart_same :: proc(kept: ^Chart_Kept, series: []Chart_Series, x_labels: []string) -> bool {
	if len(kept.series) != len(series) || len(kept.x_labels) != len(x_labels) do return false
	for se, i in series {
		k := kept.series[i]
		if k.name != se.name || k.kind != se.kind || k.color != se.color || len(k.points) != len(se.points) do return false
		for p, j in se.points do if k.points[j] != p do return false
	}
	for l, i in x_labels do if kept.x_labels[i] != l do return false
	return true
}

@(private)
chart_kept_clear :: proc(t: ^Tree, kept: ^Chart_Kept) {
	for &se in kept.series {
		delete(se.name, t.allocator)
		delete(se.points)
	}
	if kept.series == nil do kept.series = make([dynamic]Chart_Kept_Series, t.allocator)
	clear(&kept.series)
	for l in kept.x_labels do delete(l, t.allocator)
	if kept.x_labels == nil do kept.x_labels = make([dynamic]string, t.allocator)
	clear(&kept.x_labels)
}

// chart_free gives a chart's data back when its node goes.
@(private)
chart_free :: proc(t: ^Tree, n: Node) {
	if kept, has := &t.chart_data[n]; has {
		chart_kept_clear(t, kept)
		delete(kept.series)
		delete(kept.x_labels)
		delete_key(&t.chart_data, n)
	}
	if s, has := &t.charts[n]; has {
		delete(s.readout, t.allocator)
		for tick in s.ticks do delete(tick, t.allocator)
	}
	if note, has := t.chart_note[n]; has do delete(note, t.allocator)
	delete_key(&t.charts, n)
	delete_key(&t.chart_note, n)
}

// ------------------------------------------------------------ what it says

// chart_summary is the sentence a reader hears on the chart itself: what
// shape it is, how many series, what the value axis spans, and whichever
// point the keyboard is on.
@(private)
chart_summary :: proc(t: ^Tree, n: Node, extra: string) -> string {
	s, has := &t.charts[n]
	kept, had := &t.chart_data[n]
	if !has || !had do return extra
	b := strings.builder_make(context.temp_allocator)
	if extra != "" {
		strings.write_string(&b, extra)
		strings.write_string(&b, ". ")
	}
	shape := "Line chart"
	switch s.kind {
	case .Line:    shape = "Line chart"
	case .Area:    shape = "Area chart"
	case .Bar:     shape = "Bar chart"
	case .Scatter: shape = "Scatter chart"
	}
	fmt.sbprintf(&b, "%s, %d series", shape, len(kept.series))
	fmt.sbprintf(&b, ", values %s to %s", chart_tick_text(t, s.bounds.y_lo, s.bounds.step), chart_tick_text(t, s.bounds.y_hi, s.bounds.step))
	if s.cursor >= 0 && s.cursor_s < len(kept.series) {
		se := kept.series[s.cursor_s]
		if s.cursor < len(se.points) {
			p := se.points[s.cursor]
			fmt.sbprintf(&b, ". %s, %s: %s", se.name, chart_x_text(t, n, s.cursor, p.x), chart_tick_text(t, p.y, s.bounds.step))
		}
	}
	return strings.to_string(b)
}

// chart_x_text is what to call a position along the bottom: its category
// where the app named one, else the number.
@(private)
chart_x_text :: proc(t: ^Tree, n: Node, index: int, x: f64) -> string {
	if kept, has := &t.chart_data[n]; has && index >= 0 && index < len(kept.x_labels) do return kept.x_labels[index]
	return chart_tick_text(t, x, 1)
}

// chart_series_summary is what a reader hears on one series: its name, how
// many points, the range, and where it ends — the numbers behind the line,
// for someone who is not going to see the line.
@(private)
chart_series_summary :: proc(t: ^Tree, n: Node, i: int) -> string {
	kept, has := &t.chart_data[n]
	s, had := &t.charts[n]
	if !has || !had || i >= len(kept.series) do return ""
	se := kept.series[i]
	if len(se.points) == 0 do return fmt.tprintf("%s, no data", se.name)
	lo, hi := se.points[0].y, se.points[0].y
	for p in se.points {
		lo, hi = min(lo, p.y), max(hi, p.y)
	}
	last := se.points[len(se.points) - 1]
	return fmt.tprintf("%s, %d points, %s to %s, ending %s",
		se.name, len(se.points),
		chart_tick_text(t, lo, s.bounds.step), chart_tick_text(t, hi, s.bounds.step),
		chart_tick_text(t, last.y, s.bounds.step))
}

// chart_legend is the legend — which is also the chart's index for a screen
// reader: one row per series, named with that series' own summary, so the
// data is reachable whatever the colours are doing. Two or more series always
// have one (a single series is named by the chart itself).
@(private)
chart_legend :: proc(ui: ^Ui($Msg), n: Node, series: []Chart_Series) {
	t := &ui.tree
	wrap(ui, gap = .md, key = 2)
	defer end(ui)
	pal := chart_colors(&t.theme)
	for se, i in series {
		item := row(ui, gap = .xs, align = .Center, key = u64(i + 2))
		box(ui, width = 10, height = 10, radius = 3, bg = se.color if se.color != {} else palette_color(pal, i), key = 1)
		text(ui, se.name, role = .Caption, key = 2)
		end(ui)
		if d := node_get(t, item); d != nil {
			d.access.role = .List_Item
			set_name(t, item, chart_series_summary(t, n, i))
		}
	}
}

// ------------------------------------------------------------ measuring

@(private)
measure_chart :: proc(t: ^Tree, n: Node, d: ^Node_Data, cc: Constraints) -> [2]f32 {
	w := d.layout.width if d.layout.width > 0 else cc.max.x
	h := d.layout.height if d.layout.height > 0 else 240
	return {clamp(w, cc.min.x, cc.max.x), clamp(h, cc.min.y, cc.max.y)}
}

// chart_plot is the rect the marks live in: the node less the room the axes
// and their labels take.
@(private)
chart_plot :: proc(r: Rect) -> Rect {
	return {r.x + CHART_PAD_L, r.y + CHART_PAD_T, max(r.w - CHART_PAD_L - CHART_PAD_R, 1), max(r.h - CHART_PAD_T - CHART_PAD_B, 1)}
}

@(private)
chart_x_at :: proc(plot: Rect, b: Chart_Bounds, x: f64) -> f32 {
	span := b.x_hi - b.x_lo
	if span <= 0 do return plot.x
	return plot.x + f32((x - b.x_lo) / span) * plot.w
}

@(private)
chart_y_at :: proc(plot: Rect, b: Chart_Bounds, y: f64) -> f32 {
	span := b.y_hi - b.y_lo
	if span <= 0 do return plot.y + plot.h
	return plot.y + plot.h - f32((y - b.y_lo) / span) * plot.h
}

// ------------------------------------------------------------ painting

@(private)
paint_chart :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer) {
	s, has := &t.charts[n]
	kept, had := &t.chart_data[n]
	if !has || !had do return
	th := &t.theme
	rect := Rect{d.abs.x, d.abs.y, d.abs.w, d.abs.h}
	plot := chart_plot(rect)
	s.plot = plot
	b := s.bounds
	pal := chart_colors(th)
	ink := th.color.on_surface
	muted := th.color.on_surface_muted
	tick_size := th.type.caption.size

	// The grid and the axes: recessive, behind everything, never competing
	// with the data for attention.
	for i in 0 ..= CHART_TICKS {
		v := b.y_lo + (b.y_hi - b.y_lo) * f64(i) / f64(CHART_TICKS)
		y := chart_y_at(plot, b, v)
		append(&l.cmds, Draw_Line{a = {plot.x, y}, b = {plot.x + plot.w, y}, width = 1,
			color = with_alpha(th.color.outline_variant, 0.9 if i > 0 else 1)})
		append(&l.cmds, Draw_Text{pos = {rect.x, y - tick_size * 0.7}, str = s.ticks[i], size = tick_size,
			color = muted, align = .End, box_w = CHART_PAD_L - 8})
	}

	// The vertical grid: at fixed values along x, so it scrolls as a moving
	// window of time moves, and a steady line still reads as live.
	if s.x_grid > 0 && b.x_hi > b.x_lo && (b.x_hi - b.x_lo) / s.x_grid <= 200 {
		for x := math.ceil(b.x_lo / s.x_grid) * s.x_grid; x <= b.x_hi; x += s.x_grid {
			px := chart_x_at(plot, b, x)
			append(&l.cmds, Draw_Line{a = {px, plot.y}, b = {px, plot.y + plot.h}, width = 1, color = with_alpha(th.color.outline_variant, 0.9)})
		}
	}

	// The marks themselves, inside the plot: a pinned range may leave a
	// point just outside it, whose segment enters from the edge.
	append(&l.cmds, Draw_Clip_Push{{plot.x, plot.y - CHART_LINE_W, plot.w, plot.h + 2 * CHART_LINE_W}})
	for se, si in kept.series {
		kind := s.kind
		if k, said := se.kind.?; said do kind = k
		color := se.color if se.color != {} else palette_color(pal, si)
		switch kind {
		case .Bar:
			bar, bars := chart_bar_of(kept, s.kind, si)
			chart_paint_bars(t, l, plot, b, se, bar, bars, color)
		case .Line:    chart_paint_line(l, plot, b, se, color, false)
		case .Area:    chart_paint_line(l, plot, b, se, color, true)
		case .Scatter: chart_paint_points(l, plot, b, se, color, chart_marker(si))
		}
	}
	append(&l.cmds, Draw_Clip_Pop{})

	// Where the pointer or the keyboard is: a rule down the chart and the
	// value beside it, so the number is read rather than estimated.
	at, at_s := s.hover, s.hover_s
	if at < 0 && s.cursor >= 0 { at, at_s = s.cursor, s.cursor_s }
	if at >= 0 && at_s >= 0 && at_s < len(kept.series) {
		se := kept.series[at_s]
		if at < len(se.points) {
			p := se.points[at]
			px, py := chart_x_at(plot, b, p.x), chart_y_at(plot, b, p.y)
			if (se.kind.? or_else s.kind) == .Bar && b.slot > 0 { // on the bar being read, not between the group's
				bar, bars := chart_bar_of(kept, s.kind, at_s)
				left, w := chart_bar_span(plot, b, p.x, bar, bars)
				px = left + w * 0.5
			}
			append(&l.cmds, Draw_Line{a = {px, plot.y}, b = {px, plot.y + plot.h}, width = 1, color = with_alpha(ink, 0.35)})
			color := se.color if se.color != {} else palette_color(pal, at_s)
			append(&l.cmds, Draw_Rect{rect = {px - 5, py - 5, 10, 10}, radius = 5, color = th.color.surface, border_w = 2, border = color})
			readout := s.readout
			if readout == "" do readout = se.name
			tw := text_measure(t, readout, tick_size, 0, .Regular).x + 12
			tx := clamp(px + 8, plot.x, plot.x + plot.w - tw)
			ty := clamp(py - 28, plot.y, plot.y + plot.h - 22)
			append(&l.cmds, Draw_Rect{rect = {tx, ty, tw, 20}, radius = th.radius.sm, color = th.color.surface_high, border_w = 1, border = th.color.outline})
			append(&l.cmds, Draw_Text{pos = {tx + 6, ty + 3}, str = readout, size = tick_size, color = ink})
		}
	}

	// The bottom axis' labels: the categories the app named, thinned to what
	// fits rather than overlapped.
	if len(kept.x_labels) > 0 {
		every := 1
		widest := f32(0)
		for lbl in kept.x_labels do widest = max(widest, text_measure(t, lbl, tick_size, 0, .Regular).x)
		if widest > 0 {
			fits := int(plot.w / (widest + 12))
			if fits > 0 do every = max(1, (len(kept.x_labels) + fits - 1) / fits)
		}
		for lbl, i in kept.x_labels {
			if i % every != 0 do continue
			x := chart_x_at(plot, b, f64(i))
			append(&l.cmds, Draw_Text{pos = {x - widest * 0.5, plot.y + plot.h + 6}, str = lbl, size = tick_size,
				color = muted, align = .Center, box_w = widest})
		}
	}

	// A focus ring, because it takes the keyboard: flush outside the chart,
	// with no gap, so it grows by its width alone.
	if t.focus == n && ring_shown(t) {
		ring := focus_ring_look(th)
		rw := ring.width
		append(&l.cmds, Draw_Rect{rect = {rect.x - rw, rect.y - rw, rect.w + 2 * rw, rect.h + 2 * rw}, radius = th.radius.sm + rw,
			border_w = rw, border = ring.color})
	}
}

@(private)
chart_paint_line :: proc(l: ^Layer, plot: Rect, b: Chart_Bounds, se: Chart_Kept_Series, color: Color, area: bool) {
	if len(se.points) == 0 do return
	base := chart_y_at(plot, b, max(b.y_lo, 0))
	if area && len(se.points) > 1 { // the fill first, under the line
		pts := make([][2]f32, len(se.points), context.temp_allocator) // only while painting: nothing painted points into it
		for p, i in se.points do pts[i] = {chart_x_at(plot, b, p.x), chart_y_at(plot, b, p.y)}
		fill_under(l, pts, base, with_alpha(color, 0.18))
	}
	for i in 0 ..< len(se.points) - 1 {
		append(&l.cmds, Draw_Line{
			a = {chart_x_at(plot, b, se.points[i].x), chart_y_at(plot, b, se.points[i].y)},
			b = {chart_x_at(plot, b, se.points[i + 1].x), chart_y_at(plot, b, se.points[i + 1].y)},
			width = CHART_LINE_W, color = color,
		})
	}
	if len(se.points) == 1 { // one point is still a reading
		p := se.points[0]
		append(&l.cmds, Draw_Rect{rect = {chart_x_at(plot, b, p.x) - 4, chart_y_at(plot, b, p.y) - 4, 8, 8}, radius = 4, color = color})
	}
}

// fill_under shades what lies between a line through `pts` (x ascending)
// and `base` with columns a pixel wide, each as tall as the line at its
// middle, meeting without overlapping: the shape under a line needs no
// polygon. Overlapping columns would double the shade at every joint and
// stripe the area.
@(private)
fill_under :: proc(l: ^Layer, pts: [][2]f32, base: f32, color: Color) {
	if len(pts) < 2 do return
	x0, x1 := pts[0].x, pts[len(pts) - 1].x
	seg := 0
	for x := math.floor(x0); x < x1; x += 1 {
		left, right := max(x, x0), min(x + 1, x1)
		if right <= left do continue
		mid := (left + right) / 2
		for seg < len(pts) - 2 && pts[seg + 1].x < mid do seg += 1
		a, b := pts[seg], pts[seg + 1]
		f := (mid - a.x) / (b.x - a.x) if b.x > a.x else 0
		y := a.y + (b.y - a.y) * clamp(f, 0, 1)
		append(&l.cmds, Draw_Rect{rect = {left, min(y, base), right - left, abs(base - y)}, color = color})
	}
}

@(private)
chart_paint_bars :: proc(t: ^Tree, l: ^Layer, plot: Rect, b: Chart_Bounds, se: Chart_Kept_Series, bar, bars: int, color: Color) {
	if len(se.points) == 0 || b.slot <= 0 do return
	base := chart_y_at(plot, b, clamp(0, b.y_lo, b.y_hi))
	for p in se.points {
		x, w := chart_bar_span(plot, b, p.x, bar, bars)
		y := chart_y_at(plot, b, p.y)
		top, h := min(y, base), abs(base - y)
		// 4 px rounded at the data end, square at the baseline: the end that
		// carries the value is the end that is shaped
		append(&l.cmds, Draw_Rect{rect = {x, top, w, max(h, 1)}, radius = 4, color = color,
			square = {.Bottom_Left, .Bottom_Right} if p.y >= 0 else {.Top_Left, .Top_Right}})
	}
}

// chart_bar_of is which of the chart's bar series `si` is, and how many
// there are: they share each category's slot, side by side.
@(private)
chart_bar_of :: proc(kept: ^Chart_Kept, kind: Chart_Kind, si: int) -> (bar, bars: int) {
	for se, i in kept.series {
		if (se.kind.? or_else kind) != .Bar do continue
		if i < si do bar += 1
		bars += 1
	}
	return
}

// chart_bar_span is a bar's left edge and width: the `bar`-th of `bars` in
// the slot at `x`. Paint, the pointer and the marker all use it.
@(private)
chart_bar_span :: proc(plot: Rect, b: Chart_Bounds, x: f64, bar, bars: int) -> (left, w: f32) {
	slot := f32(b.slot / (b.x_hi - b.x_lo)) * plot.w
	each := max((slot - CHART_BAR_GAP * 2) / f32(max(bars, 1)), 1)
	return chart_x_at(plot, b, x) - slot * 0.5 + CHART_BAR_GAP + each * f32(bar), max(each - CHART_BAR_GAP, 1)
}

@(private)
chart_paint_points :: proc(l: ^Layer, plot: Rect, b: Chart_Bounds, se: Chart_Kept_Series, color: Color, marker: Chart_Marker) {
	r := CHART_MARKER * 0.5
	for p in se.points {
		x, y := chart_x_at(plot, b, p.x), chart_y_at(plot, b, p.y)
		switch marker {
		case .Circle:
			append(&l.cmds, Draw_Rect{rect = {x - r, y - r, r * 2, r * 2}, radius = r, color = color})
		case .Square:
			append(&l.cmds, Draw_Rect{rect = {x - r, y - r, r * 2, r * 2}, radius = 1, color = color})
		case .Diamond: // two crossed capsules: no rotation in a rect, but a line has one
			append(&l.cmds, Draw_Line{a = {x - r, y}, b = {x + r, y}, width = r, color = color})
			append(&l.cmds, Draw_Line{a = {x, y - r}, b = {x, y + r}, width = r, color = color})
		case .Triangle:
			append(&l.cmds, Draw_Line{a = {x - r, y + r}, b = {x + r, y + r}, width = 2, color = color, flat = true})
			append(&l.cmds, Draw_Line{a = {x - r, y + r}, b = {x, y - r}, width = 2, color = color})
			append(&l.cmds, Draw_Line{a = {x + r, y + r}, b = {x, y - r}, width = 2, color = color})
		}
	}
}

// ------------------------------------------------------------ reading it

// chart_readout is the line shown beside the point being read, and the line a
// screen reader is given. It is kept in the widget's own memory, not built
// during paint: paint runs every frame and must not allocate.
@(private)
chart_readout_set :: proc(t: ^Tree, n: Node, s: ^Chart_State) {
	kept, had := &t.chart_data[n]
	at, at_s := s.hover, s.hover_s
	if at < 0 && s.cursor >= 0 { at, at_s = s.cursor, s.cursor_s }
	text := ""
	if had && at >= 0 && at_s >= 0 && at_s < len(kept.series) {
		se := kept.series[at_s]
		if at < len(se.points) {
			p := se.points[at]
			if len(kept.series) > 1 { // which of them is being read
				text = fmt.tprintf("%s · %s %s", chart_x_text(t, n, at, p.x), se.name, chart_tick_text(t, p.y, s.bounds.step))
			} else {
				text = fmt.tprintf("%s  %s", chart_x_text(t, n, at, p.x), chart_tick_text(t, p.y, s.bounds.step))
			}
		}
	}
	if text == s.readout do return
	delete(s.readout, t.allocator)
	s.readout = strings.clone(text, t.allocator)
	mark_paint_dirty(t, n)
}

// chart_at finds the point nearest `pos`: the column for a line or area
// (where x is what the reader is aiming at), the bar under the pointer for
// bars (a group's bars share a column), the nearest mark for a scatter
// (where both axes are). Returns the series and the index, or -1.
@(private)
chart_at :: proc(t: ^Tree, n: Node, pos: [2]f32) -> (series: int, index: int) {
	s, has := &t.charts[n]
	kept, had := &t.chart_data[n]
	if !has || !had || len(kept.series) == 0 do return -1, -1
	plot, b := s.plot, s.bounds
	best_d, best_s, best_i := max(f32), -1, -1
	for se, si in kept.series {
		kind := s.kind
		if k, said := se.kind.?; said do kind = k
		bar, bars := chart_bar_of(kept, s.kind, si)
		for p, i in se.points {
			x := chart_x_at(plot, b, p.x)
			d := abs(pos.x - x)
			if kind == .Bar && b.slot > 0 { // a group's bars share a column: the one under the pointer, by its own span
				left, w := chart_bar_span(plot, b, p.x, bar, bars)
				d = max(left - pos.x, pos.x - (left + w), 0)
			}
			if kind == .Scatter { // both axes matter: the nearest mark, not the nearest column
				y := chart_y_at(plot, b, p.y)
				d = math.sqrt((pos.x - x) * (pos.x - x) + (pos.y - y) * (pos.y - y))
			}
			if d < best_d {
				best_d, best_s, best_i = d, si, i
			}
		}
	}
	if best_d > CHART_HIT_SLACK do return -1, -1
	return best_s, best_i
}

// chart_pointer_move shows the value under the pointer. Called by the hover
// pass for a chart node.
@(private)
chart_pointer_move :: proc(ui: ^Ui($Msg), n: Node, pos: [2]f32) -> bool {
	t := &ui.tree
	s, has := &t.charts[n]
	if !has do return false
	si, i := chart_at(t, n, pos)
	if si == s.hover_s && i == s.hover do return false
	s.hover_s, s.hover = si, i
	chart_readout_set(t, n, s)
	set_describe(t, n, chart_summary(t, n, t.chart_note[n]))
	mark_paint_dirty(t, n)
	return true
}

// chart_pointer_leave forgets the pointer's point when it goes.
@(private)
chart_pointer_leave :: proc(t: ^Tree, n: Node) {
	s, has := &t.charts[n]
	if !has || s.hover < 0 do return
	s.hover, s.hover_s = -1, -1
	chart_readout_set(t, n, s)
	mark_paint_dirty(t, n)
}

// chart_press picks the point under the pointer, sending on_select.
@(private)
chart_press :: proc(ui: ^Ui($Msg), n: Node, pos: [2]f32) -> bool {
	t := &ui.tree
	s, has := &t.charts[n]
	if !has do return false
	si, i := chart_at(t, n, pos)
	if si < 0 do return false
	s.cursor_s, s.cursor = si, i
	chart_readout_set(t, n, s)
	set_focus(t, n, false)
	return chart_send(ui, n, si, i)
}

// chart_key walks the points: Left and Right along a series, Up and Down
// between series, Home and End to its ends, Enter to pick — the same keys
// every other widget uses for the same jobs.
@(private)
chart_key :: proc(ui: ^Ui($Msg), key: Key, mods: Mods) -> bool {
	t := &ui.tree
	n := t.focus
	s, has := &t.charts[n]
	if !has do return false
	kept, had := &t.chart_data[n]
	if !had || len(kept.series) == 0 do return false
	if d := node_get(t, n); d == nil || .Disabled in d.flags do return false
	points := len(kept.series[clamp(s.cursor_s, 0, len(kept.series) - 1)].points)
	if points == 0 do return false
	step := 10 if .Shift in mods else 1
	moved := true
	#partial switch key {
	case .Left:  s.cursor = max(0, (s.cursor if s.cursor >= 0 else 0) - step)
	case .Right: s.cursor = min(points - 1, (s.cursor if s.cursor >= 0 else -1) + step)
	case .Home:  s.cursor = 0
	case .End:   s.cursor = points - 1
	case .Up:
		s.cursor_s = (s.cursor_s + len(kept.series) - 1) % len(kept.series)
		if s.cursor < 0 do s.cursor = 0
	case .Down:
		s.cursor_s = (s.cursor_s + 1) % len(kept.series)
		if s.cursor < 0 do s.cursor = 0
	case .Enter, .Space:
		if s.cursor < 0 do return false
		return chart_send(ui, n, s.cursor_s, s.cursor)
	case:
		moved = false
	}
	if !moved do return false
	s.cursor = clamp(s.cursor, 0, max(len(kept.series[s.cursor_s].points) - 1, 0))
	s.hover, s.hover_s = -1, -1 // the keyboard is reading it now
	chart_readout_set(t, n, s)
	set_describe(t, n, chart_summary(t, n, t.chart_note[n])) // …and a reader hears the point it moved to
	mark_paint_dirty(t, n)
	return true
}

@(private)
chart_send :: proc(ui: ^Ui($Msg), n: Node, si, i: int) -> bool {
	t := &ui.tree
	kept, had := &t.chart_data[n]
	if !had || si >= len(kept.series) do return false
	se := kept.series[si]
	if i >= len(se.points) do return false
	h, has := ui.chart_select[n]
	if !has do return false
	return handler_send(ui, h, Chart_Hit{series = si, index = i, point = se.points[i], name = se.name}, n)
}

// chart_hover is the hover pass' hook: the chart under the pointer follows
// it, and the one the pointer left forgets it.
@(private)
chart_hover :: proc(ui: ^Ui($Msg), pos: [2]f32) -> bool {
	t := &ui.tree
	if len(t.charts) == 0 do return false
	// The chart under the pointer is the one whose own rect the pointer is
	// in, asked directly rather than taken from the hover target: what a
	// chart wants to know is *where* in itself the pointer is, which is a
	// finer question than which node it is over.
	changed := false
	for n, _ in t.charts {
		d := node_get(t, n)
		inside := d != nil && d.flags & {.Hidden, .Inert} == {} &&
			pos.x >= d.abs.x && pos.x <= d.abs.x + d.abs.w &&
			pos.y >= d.abs.y && pos.y <= d.abs.y + d.abs.h
		if inside {
			changed = chart_pointer_move(ui, n, pos) || changed
		} else if t.charts[n].hover >= 0 {
			chart_pointer_leave(t, n)
			changed = true
		}
	}
	return changed
}

// chart_press_at gives the press to whichever chart it landed in, for the
// same reason chart_hover asks directly: the interesting question is where
// inside the chart the press was.
@(private)
chart_press_at :: proc(ui: ^Ui($Msg), pos: [2]f32) -> bool {
	t := &ui.tree
	for n, _ in t.charts {
		d := node_get(t, n)
		if d == nil || d.flags & {.Hidden, .Inert, .Disabled} != {} do continue
		if pos.x < d.abs.x || pos.x > d.abs.x + d.abs.w do continue
		if pos.y < d.abs.y || pos.y > d.abs.y + d.abs.h do continue
		if chart_press(ui, n, pos) do return true
	}
	return false
}
