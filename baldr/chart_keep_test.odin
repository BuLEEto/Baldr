package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A chart paints its labels and names by alias into a layer that is kept
// until something repaints it, so the strings it draws must outlive every
// build that does not; and its bars stand where their x says, under their
// labels.

@(private = "file")
Ck_Msg :: union { Chart_Hit }

@(private = "file")
CK_RED :: Color{1, 0, 0, 1}
@(private = "file")
CK_BLUE :: Color{0, 0, 1, 1}

@(private = "file")
ck_build :: proc(ui: ^Ui(Ck_Msg), series: []Chart_Series, labels: []string) -> Node {
	begin_view(ui)
	column(ui)
	chart(ui, series, kind = .Bar, label = "Sales", x_labels = labels, height = 200)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	for n, _ in ui.tree.charts do return n
	return NODE_NONE
}

// ck_fresh copies the labels into new memory, as an app building them each
// view does, so equal strings are not the same bytes.
@(private = "file")
ck_fresh :: proc(labels: []string) -> []string {
	out := make([]string, len(labels), context.temp_allocator)
	for l, i in labels do out[i] = strings.clone(l, context.temp_allocator)
	return out
}

// ck_drawn_from_kept: every label the chart draws is a string the chart
// holds now, not one it has let go of. (The legend draws the series' names
// from its own text nodes, so a name is no evidence either way.)
@(private = "file")
ck_drawn_from_kept :: proc(t: ^Tree, n: Node) -> (drawn: int, ok: bool) {
	kept := &t.chart_data[n]
	ok = true
	for c in draw_list(t) {
		dt, is_text := c.(Draw_Text)
		if !is_text do continue
		for l in kept.x_labels do if dt.str == l {
			drawn += 1
			if raw_data(dt.str) != raw_data(l) do ok = false
		}
	}
	return
}

@(test)
a_chart_rebuilt_with_the_same_data_draws_what_it_still_holds :: proc(t: ^testing.T) {
	ui: Ui(Ck_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {600, 400})
	pts := []Chart_Point{{0, 10}, {1, 30}, {2, 20}, {3, 45}}
	labels := []string{"Oct 20", "Oct 21", "Oct 22", "Oct 23"}
	series := []Chart_Series{{name = "Sales", points = pts}}
	n := ck_build(&ui, series, ck_fresh(labels))
	plot := ui.tree.charts[n].plot
	pointer_move(&ui, {plot.x + plot.w * 0.6, plot.y + plot.h * 0.5}) // a readout too, which is the chart's own string
	frame(&ui.tree, {600, 400})

	for _ in 0 ..< 3 { // rebuilt for something else: the same data, in new memory
		ck_build(&ui, series, ck_fresh(labels))
		drawn, ok := ck_drawn_from_kept(&ui.tree, n)
		testing.expect_value(t, drawn, len(labels))
		testing.expect(t, ok, "and drawn from strings the chart still holds")
	}

	// new data repaints, so what is drawn moves to the new copies with it
	labels[1] = "Oct 31"
	ck_build(&ui, series, ck_fresh(labels))
	drawn, ok := ck_drawn_from_kept(&ui.tree, n)
	testing.expect(t, drawn >= len(labels) && ok, "a change is drawn from the chart's new copies")
}

// ck_bars is the left edge and width of each bar drawn in `color`.
@(private = "file")
ck_bars :: proc(t: ^Tree, color: Color) -> [dynamic]Rect {
	out := make([dynamic]Rect, context.temp_allocator)
	for c in draw_list(t) do if q, ok := c.(Draw_Rect); ok && q.color == color && q.radius == 4 do append(&out, q.rect)
	return out
}

@(test)
bars_stand_on_their_x_under_their_labels :: proc(t: ^testing.T) {
	ui: Ui(Ck_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {600, 400})
	labels := []string{"Mon", "Tue", "Wed", "Thu"}
	full := []Chart_Point{{0, 10}, {1, 30}, {2, 20}, {3, 45}}
	n := ck_build(&ui, []Chart_Series{{name = "Sales", points = full, color = CK_RED}}, labels)
	s := ui.tree.charts[n]
	bars := ck_bars(&ui.tree, CK_RED)
	testing.expect_value(t, len(bars), 4)
	centres: [4]f32
	for c in draw_list(&ui.tree) {
		dt, ok := c.(Draw_Text)
		if !ok do continue
		for l, i in labels do if dt.str == l do centres[i] = dt.pos.x + dt.box_w * 0.5
	}
	for r, i in bars {
		mid := r.x + r.w * 0.5
		testing.expectf(t, abs(mid - centres[i]) < 2, "bar %d is under its label (%v, %v)", i, mid, centres[i])
		testing.expectf(t, abs(mid - chart_x_at(s.plot, s.bounds, f64(i))) < 2, "…and where the pointer's rule for it is drawn")
	}
	testing.expect(t, bars[0].x >= s.plot.x && bars[3].x + bars[3].w <= s.plot.x + s.plot.w, "the outer bars inside the plot")

	// a missing day leaves its place empty rather than sliding the rest left;
	// a second series shorter than the first shares the slots it has
	gap := []Chart_Point{{0, 10}, {1, 30}, {3, 45}}
	short := []Chart_Point{{0, 5}, {1, 8}}
	n = ck_build(&ui, []Chart_Series{{name = "Sales", points = gap, color = CK_RED}, {name = "Costs", points = short, color = CK_BLUE}}, labels)
	s = ui.tree.charts[n]
	reds, blues := ck_bars(&ui.tree, CK_RED), ck_bars(&ui.tree, CK_BLUE)
	testing.expect(t, len(reds) == 3 && len(blues) == 2)
	slot := f32(s.bounds.slot / (s.bounds.x_hi - s.bounds.x_lo)) * s.plot.w
	testing.expect(t, abs(reds[2].x - (chart_x_at(s.plot, s.bounds, 3) - slot * 0.5)) < 4, "Thursday's bar stays over Thursday")
	for i in 0 ..< 2 {
		testing.expect(t, blues[i].x > reds[i].x && blues[i].x - reds[i].x < slot * 0.6, "the two series side by side in the same slot")
		testing.expect(t, abs(blues[i].w - reds[i].w) < 0.01, "at the same width")
	}
}

// In a group of bars every series has the same x, so the pointer reads the
// bar it is over, the ring sits on that bar, and the readout says whose it is.
@(test)
a_grouped_bar_is_read_where_the_pointer_is :: proc(t: ^testing.T) {
	ui: Ui(Ck_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {600, 400})
	uk := []Chart_Point{{0, 10}, {1, 30}, {2, 20}}
	us := []Chart_Point{{0, 15}, {1, 25}, {2, 35}}
	other := []Chart_Point{{0, 5}, {1, 8}, {2, 6}}
	n := ck_build(&ui, []Chart_Series{{name = "UK", points = uk, color = CK_RED}, {name = "US", points = us, color = CK_BLUE}, {name = "Other", points = other}},
		[]string{"Mon", "Tue", "Wed"})
	blues := ck_bars(&ui.tree, CK_BLUE)
	testing.expect_value(t, len(blues), 3)
	bar := blues[1] // US on Tuesday
	si, i := chart_at(&ui.tree, n, {bar.x + bar.w * 0.5, bar.y - 20}) // over it, a little above its top
	testing.expect(t, si == 1 && i == 1, "the bar under the pointer, not the group's first")
	pointer_move(&ui, {bar.x + bar.w * 0.5, bar.y + 4})
	frame(&ui.tree, {600, 400})
	s := ui.tree.charts[n]
	testing.expect_value(t, s.hover_s, 1)
	testing.expect(t, strings.contains(s.readout, "US") && strings.contains(s.readout, "Tue"), s.readout)
	ring := false
	for c in draw_list(&ui.tree) {
		q, ok := c.(Draw_Rect)
		if ok && q.border == CK_BLUE && q.border_w == 2 && abs(q.rect.x + q.rect.w * 0.5 - (bar.x + bar.w * 0.5)) < 1 do ring = true
	}
	testing.expect(t, ring, "the ring is on the bar being read")
}

} // when ODIN_TEST
