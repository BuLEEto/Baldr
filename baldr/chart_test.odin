package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// What a chart promises: honest bounds, ticks on round numbers in the
// desktop's notation, a point found where the reader aims, a keyboard path
// through every value, and every series readable in the accessibility tree.


@(private = "file")
Chart_Msg :: union { Chart_Hit }

@(private = "file")
picked :: proc(e: Ev(Chart_Hit)) -> Chart_Msg { return e.value }

@(private = "file")
SALES := [4]Chart_Point{{0, 10}, {1, 30}, {2, 20}, {3, 45}}
@(private = "file")
COSTS := [4]Chart_Point{{0, 8}, {1, 12}, {2, 18}, {3, 15}}

@(private = "file")
build :: proc(ui: ^Ui(Chart_Msg), kind: Chart_Kind) -> Node {
	begin_view(ui)
	column(ui)
	n := chart(ui, []Chart_Series{
		{name = "Sales", points = SALES[:]},
		{name = "Costs", points = COSTS[:]},
	}, kind = kind, label = "Sales and costs", x_labels = []string{"Q1", "Q2", "Q3", "Q4"}, height = 200, on_select = picked)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	return n
}

// the custom node inside the column the builder returns
@(private = "file")
plot_of :: proc(ui: ^Ui(Chart_Msg)) -> Node {
	for n, _ in ui.tree.charts do return n
	return NODE_NONE
}

@(test)
a_bar_chart_is_read_from_zero :: proc(t: ^testing.T) {
	// A bar is a length, and a length starts at zero: an axis that starts at
	// 10 says the last bar is seven times the first when it is four.
	ui: Ui(Chart_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	build(&ui, .Bar)
	s := &ui.tree.charts[plot_of(&ui)]
	testing.expect_value(t, s.bounds.y_lo, 0)
	testing.expect(t, s.bounds.y_hi >= 45, "and reaches the tallest bar")

	// a line is not a length, so it crops to what it shows: values far from
	// zero are read against each other, not against an empty axis
	begin_view(&ui)
	column(&ui)
	far := [3]Chart_Point{{0, 980}, {1, 1010}, {2, 995}}
	chart(&ui, []Chart_Series{{name = "Pressure", points = far[:]}}, kind = .Line, label = "Pressure", height = 200)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 400})
	s = &ui.tree.charts[plot_of(&ui)]
	testing.expect(t, s.bounds.y_lo >= 900, "a line chart crops to what it shows")

	// …but the same data as bars is read from zero, whatever that costs it
	begin_view(&ui)
	column(&ui)
	chart(&ui, []Chart_Series{{name = "Pressure", points = far[:]}}, kind = .Bar, label = "Pressure", height = 200)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 400})
	s = &ui.tree.charts[plot_of(&ui)]
	testing.expect_value(t, s.bounds.y_lo, 0)
}

@(test)
chart_ticks_land_on_round_numbers :: proc(t: ^testing.T) {
	testing.expect_value(t, chart_step(0.7), 1)
	testing.expect_value(t, chart_step(1.3), 2)
	testing.expect_value(t, chart_step(4), 5)
	testing.expect_value(t, chart_step(7), 10)
	testing.expect_value(t, chart_step(23), 50)
	testing.expect_value(t, chart_step(0.03), 0.05)
}

@(test)
chart_ticks_are_written_the_way_the_desktop_writes_numbers :: proc(t: ^testing.T) {
	ui: Ui(Chart_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree
	tr.locale.decimal, tr.locale.thousands = ".", ","
	testing.expect_value(t, chart_tick_text(tr, 1234567, 1000), "1,234,567")
	testing.expect_value(t, chart_tick_text(tr, 950, 100), "950")
	testing.expect_value(t, chart_tick_text(tr, 0.25, 0.05), "0.25")
	testing.expect_value(t, chart_tick_text(tr, -4200, 100), "-4,200")

	// a desktop that writes 1.234.567,89
	tr.locale.decimal, tr.locale.thousands = ",", "."
	testing.expect_value(t, chart_tick_text(tr, 1234567, 1000), "1.234.567")
	testing.expect_value(t, chart_tick_text(tr, 0.25, 0.05), "0,25")

	// …and one that groups with a space
	tr.locale.thousands = " "
	testing.expect_value(t, chart_tick_text(tr, 12345, 100), "12 345")
}

@(test)
a_chart_finds_the_point_the_reader_aims_at :: proc(t: ^testing.T) {
	ui: Ui(Chart_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	build(&ui, .Line)
	n := plot_of(&ui)
	s := &ui.tree.charts[n]
	d := node_get(&ui.tree, n)
	testing.expect(t, d != nil)
	plot := s.plot
	testing.expect(t, plot.w > 0 && plot.h > 0, "the plot has been laid out")

	// aim at the third column
	x := chart_x_at(plot, s.bounds, 2)
	si, i := chart_at(&ui.tree, n, {x + 3, plot.y + plot.h * 0.5})
	testing.expect_value(t, i, 2)
	testing.expect(t, si >= 0)

	// …and far away from any of it, nothing is claimed
	_, none := chart_at(&ui.tree, n, {plot.x + plot.w + 300, plot.y})
	testing.expect_value(t, none, -1)
}

@(test)
a_chart_can_be_read_with_the_keyboard :: proc(t: ^testing.T) {
	ui: Ui(Chart_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	build(&ui, .Line)
	n := plot_of(&ui)
	set_focus(&ui.tree, n, true)
	s := &ui.tree.charts[n]

	testing.expect(t, chart_key(&ui, .Right, {}), "the keyboard moves along the series")
	testing.expect_value(t, s.cursor, 0)
	chart_key(&ui, .Right, {})
	testing.expect_value(t, s.cursor, 1)
	chart_key(&ui, .End, {})
	testing.expect_value(t, s.cursor, 3)
	chart_key(&ui, .Home, {})
	testing.expect_value(t, s.cursor, 0)

	// Down moves to the next series, and the reading follows
	chart_key(&ui, .Down, {})
	testing.expect_value(t, s.cursor_s, 1)
	testing.expect(t, strings.contains(s.readout, "Q1"), "the value being read names its place")

	// Enter picks the point, and the app hears which
	clear(&ui.msgs)
	testing.expect(t, chart_key(&ui, .Enter, {}), "Enter picks")
	testing.expect_value(t, len(ui.msgs), 1)
	hit, is_hit := ui.msgs[0].(Chart_Hit)
	testing.expect(t, is_hit)
	testing.expect_value(t, hit.series, 1)
	testing.expect_value(t, hit.name, "Costs")
	testing.expect_value(t, hit.point.y, 8)
}

@(test)
every_series_is_in_the_accessibility_tree :: proc(t: ^testing.T) {
	// The numbers have to reach a reader who cannot see the marks: the chart
	// says what it is, and the legend rows carry each series' own summary.
	ui: Ui(Chart_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	build(&ui, .Line)
	n := plot_of(&ui)
	d := node_get(&ui.tree, n)
	testing.expect_value(t, d.access.role, Role.Group)
	testing.expect_value(t, d.access.name, "Sales and costs")
	testing.expect(t, strings.contains(d.access.describe, "Line chart"), d.access.describe)
	testing.expect(t, strings.contains(d.access.describe, "2 series"), d.access.describe)

	dump := access_dump(&ui.tree)
	testing.expect(t, strings.contains(dump, "Sales, 4 points, 10 to 45, ending 45"), dump)
	testing.expect(t, strings.contains(dump, "Costs, 4 points, 8 to 18, ending 15"), dump)

	// and the reading follows the keyboard, so a reader hears the point
	set_focus(&ui.tree, n, true)
	chart_key(&ui, .Right, {})
	testing.expect(t, strings.contains(node_get(&ui.tree, n).access.describe, "Q1"), node_get(&ui.tree, n).access.describe)
}

@(test)
a_chart_follows_the_pointer :: proc(t: ^testing.T) {
	ui: Ui(Chart_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	build(&ui, .Line)
	n := plot_of(&ui)
	s := &ui.tree.charts[n]
	plot := s.plot
	at := [2]f32{chart_x_at(plot, s.bounds, 1), plot.y + plot.h * 0.5}

	testing.expect(t, pointer_move(&ui, at), "the pointer moving over a chart changes what it shows")
	testing.expect_value(t, ui.tree.charts[n].hover, 1)
	testing.expect(t, strings.contains(ui.tree.charts[n].readout, "Q2"), ui.tree.charts[n].readout)

	// away from the marks, it stops claiming a value
	pointer_move(&ui, {plot.x + plot.w + 400, plot.y})
	testing.expect_value(t, ui.tree.charts[n].hover, -1)
	testing.expect_value(t, ui.tree.charts[n].readout, "")
}

// The value axis' labels are the chart's own, not the frame's: a layer's
// draw list is kept and drawn again on later frames, after the frame's temp
// memory has gone and been written over. Painted from temp memory, the axis
// would come out as empty boxes, and then as nothing.
@(test)
chart_ticks_outlive_the_frame_that_painted_them :: proc(t: ^testing.T) {
	ui: Ui(Chart_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	pts := [5]Chart_Point{{0, 5}, {1, 40}, {2, 90}, {3, 60}, {4, 20}}
	begin_view(&ui)
	column(&ui)
	chart(&ui, []Chart_Series{{name = "CPU", points = pts[:]}}, kind = .Area, y_min = 0, y_max = 100, legend = false, height = 280)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 400})
	ticks :: proc(ui: ^Ui(Chart_Msg)) -> (out: [dynamic]string) {
		out = make([dynamic]string, context.allocator)
		for c in draw_list(&ui.tree) do if tx, ok := c.(Draw_Text); ok && tx.align == .End {
			append(&out, strings.clone(tx.str))
		}
		return
	}
	first := ticks(&ui)
	defer { for s in first do delete(s); delete(first) }
	testing.expect_value(t, len(first), CHART_TICKS + 1)
	if len(first) == CHART_TICKS + 1 do testing.expect(t, first[0] == "0" && first[CHART_TICKS] == "100", "0 to 100 up the axis")

	free_all(context.temp_allocator) // the frame is over…
	junk := make([]u8, 1 << 16, context.temp_allocator)
	for &b in junk do b = 'X' // …and its memory is someone else's now
	again := ticks(&ui) // the kept draw list, drawn again without a rebuild
	defer { for s in again do delete(s); delete(again) }
	testing.expect_value(t, len(again), len(first))
	for s, i in again do if i < len(first) do testing.expectf(t, s == first[i], "tick %d still reads %q, not %q", i, first[i], s)
}

// An area's shade is columns a pixel wide that meet without overlapping:
// overlapping ones would double the shade at every joint and stripe the fill.
@(test)
chart_area_shade_has_no_seams :: proc(t: ^testing.T) {
	ui: Ui(Chart_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	pts := [7]Chart_Point{{0, 5}, {1, 40}, {2, 90}, {3, 60}, {4, 20}, {5, 55}, {6, 30}}
	begin_view(&ui)
	column(&ui)
	chart(&ui, []Chart_Series{{name = "CPU", points = pts[:]}}, kind = .Area, y_min = 0, y_max = 100, legend = false, height = 200)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {437, 300}) // a width whose joints fall between pixels
	shade := make([dynamic]Rect, context.temp_allocator)
	for c in draw_list(&ui.tree) do if r, ok := c.(Draw_Rect); ok && r.color.a > 0.1 && r.color.a < 0.3 && r.rect.w <= 1.5 do append(&shade, r.rect)
	testing.expect(t, len(shade) > 100, "shaded")
	for i in 1 ..< len(shade) {
		testing.expectf(t, abs(shade[i].x - (shade[i - 1].x + shade[i - 1].w)) < 0.001, "column %d starts where the last ended: %v after %v", i, shade[i], shade[i - 1])
	}
}

// A chart against a moving window of time: x_min / x_max pin
// the bottom axis, a series with only its latest readings is drawn from
// where it starts with nothing before it, and the vertical grid at fixed x
// values moves as the window moves.
@(test)
chart_scrolls_with_time :: proc(t: ^testing.T) {
	ui: Ui(Chart_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	draw :: proc(ui: ^Ui(Chart_Msg), n_now: int, readings: int) -> (plot: Rect, lines: [dynamic]Draw_Line, shade: [dynamic]Rect) {
		pts := make([]Chart_Point, readings, context.temp_allocator)
		for i in 0 ..< readings do pts[i] = {f64(n_now - readings + 1 + i), 45}
		begin_view(ui)
		column(ui)
		chart(ui, []Chart_Series{{name = "Memory", points = pts}}, kind = .Area, y_min = 0, y_max = 100, legend = false, height = 200,
			x_min = f64(n_now - 90), x_max = f64(n_now), x_grid = 15)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {600, 300})
		for _, s in ui.tree.charts do plot = s.plot
		lines = make([dynamic]Draw_Line, context.temp_allocator)
		shade = make([dynamic]Rect, context.temp_allocator)
		for c in draw_list(&ui.tree) {
			if l, ok := c.(Draw_Line); ok do append(&lines, l)
			if r, ok := c.(Draw_Rect); ok && r.color.a > 0.1 && r.color.a < 0.3 && r.rect.w <= 1.5 do append(&shade, r.rect)
		}
		return
	}
	x_at :: proc(plot: Rect, x, lo, hi: f64) -> f32 { return plot.x + f32((x - lo) / (hi - lo)) * plot.w }

	plot, lines, shade := draw(&ui, 30, 20) // 20 readings so far, of a 90-reading window
	start := x_at(plot, 11, -60, 30)
	series_left := max(f32)
	for l in lines do if l.width == CHART_LINE_W do series_left = min(series_left, l.a.x, l.b.x)
	testing.expectf(t, abs(series_left - start) < 0.5, "the line starts at its first reading (%v), not the plot's edge (%v)", series_left, plot.x)
	for r in shade do testing.expectf(t, r.x >= start - 1, "no fill before the first reading: %v", r)

	grid :: proc(plot: Rect, lines: [dynamic]Draw_Line) -> (xs: [dynamic]f32) {
		xs = make([dynamic]f32, context.temp_allocator)
		for l in lines do if l.width == 1 && l.a.x == l.b.x && l.a.y <= plot.y + 0.5 && l.b.y >= plot.y + plot.h - 0.5 do append(&xs, l.a.x)
		return
	}
	has :: proc(xs: [dynamic]f32, x: f32) -> bool {
		for v in xs do if abs(v - x) < 0.5 do return true
		return false
	}
	g1 := grid(plot, lines)
	testing.expect_value(t, len(g1), 7) // -60 (the window's edge), -45, -30, -15, 0, 15, 30
	zero1 := x_at(plot, 0, -60, 30)
	testing.expect(t, has(g1, zero1), "a line at reading 0")
	_, lines, _ = draw(&ui, 32, 22) // two readings on
	g2 := grid(plot, lines)
	zero2 := x_at(plot, 0, -58, 32)
	testing.expectf(t, has(g2, zero2) && abs((zero1 - zero2) - plot.w * 2 / 90) < 0.5, "the line at reading 0 moved left by two readings: %v then %v", zero1, zero2)
	testing.expect(t, !has(g2, zero1), "and is not where it was")

	_, lines, _ = draw(&ui, 120, 91) // one reading more than the window: its segment enters from the edge
	testing.expect(t, true, "drawn")
	clipped := false
	for c in draw_list(&ui.tree) do if cl, ok := c.(Draw_Clip_Push); ok && abs(cl.rect.x - plot.x) < 0.5 do clipped = true
	testing.expect(t, clipped, "the marks are clipped to the plot")

	th := ui.tree.theme
	testing.expect_value(t, chart_color(&th, 0), chart_colors(&th)[0]) // public: a sidebar's sparkline matches its chart
	testing.expect_value(t, chart_color(&th, 9), chart_colors(&th)[1])
}

// New readings are a repaint, whatever else is on the page, including for a
// chart alone in its layer.
@(test)
a_chart_repaints_for_new_readings :: proc(t: ^testing.T) {
	ui: Ui(Chart_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	// The readings live in the test, not in `build`: `chart` copies them, but
	// the compiler's escape analysis warns about a slice of a proc's own stack
	// handed to a tree that outlives the call. A reading that moves in place
	// is closer to a live chart anyway.
	pts := [3]Chart_Point{{0, 10}, {1, 20}, {2, 30}}
	series := [1]Chart_Series{{name = "CPU", points = pts[:]}}
	build :: proc(ui: ^Ui(Chart_Msg), series: []Chart_Series) -> Node {
		begin_view(ui)
		column(ui)
		chart(ui, series, y_min = 0, y_max = 100, legend = false, key = 1)
		end(ui)
		end_view(ui)
		for n, _ in ui.tree.charts do return n
		return NODE_NONE
	}
	n := build(&ui, series[:])
	frame(&ui.tree, {400, 300})
	d := node_get(&ui.tree, n)
	testing.expect_value(t, build(&ui, series[:]), n)
	testing.expect(t, .Dirty_Paint not_in d.flags, "the same readings: nothing to paint")
	pts[2] = {2, 80}
	build(&ui, series[:])
	testing.expect(t, .Dirty_Paint in d.flags, "a new reading: painted again")
}

} // when ODIN_TEST