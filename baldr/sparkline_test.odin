package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A sparkline: a value's recent history beside its number.


@(private = "file")
Spark_Msg :: enum { None }

@(private = "file")
spark_build :: proc(ui: ^Ui(Spark_Msg), values: []f32, span := 0, fill := false, label := "", pinned := false) -> (n: Node) {
	begin_view(ui)
	column(ui, padding = f32(10), align = .Start)
	if pinned {
		n = sparkline(ui, values, span = span, fill = fill, label = label, y_min = 0, y_max = 100, key = 1)
	} else {
		n = sparkline(ui, values, span = span, fill = fill, label = label, key = 1)
	}
	end(ui)
	end_view(ui)
	return
}

@(private = "file")
spark :: proc(ui: ^Ui(Spark_Msg), values: []f32, span := 0, fill := false, label := "", pinned := false) -> (n: Node, lines: [dynamic]Draw_Line, rects: [dynamic]Draw_Rect) {
	n = spark_build(ui, values, span, fill, label, pinned)
	frame(&ui.tree, {300, 200})
	lines = make([dynamic]Draw_Line, context.temp_allocator)
	rects = make([dynamic]Draw_Rect, context.temp_allocator)
	for c in draw_list(&ui.tree) {
		if v, ok := c.(Draw_Line); ok do append(&lines, v)
		if v, ok := c.(Draw_Rect); ok do append(&rects, v)
	}
	return
}

// 64 × 28 by default and nothing but its line: no role, no focus; each
// value a joint, the stroke inside the box at its peaks, the latest at the
// right edge; a pinned scale puts 100 at the top and 0 at the bottom.
@(test)
a_sparkline_is_its_line :: proc(t: ^testing.T) {
	ui: Ui(Spark_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n, lines, _ := spark(&ui, {0, 50, 100, 25}, pinned = true)
	d := node_get(&ui.tree, n)
	r := d.abs
	testing.expect_value(t, [2]f32{r.w, r.h}, [2]f32{64, 28})
	testing.expect(t, d.access.role == .None && .Focusable not_in d.flags, "decoration: the number beside it is read")
	testing.expect_value(t, len(lines), 3)
	if len(lines) != 3 do return
	half := SPARK_LINE_W / 2
	for ln in lines do for p in ([][2]f32{ln.a, ln.b}) {
		testing.expectf(t, p.x >= r.x + half - 0.01 && p.x <= r.x + r.w - half + 0.01 && p.y >= r.y + half - 0.01 && p.y <= r.y + r.h - half + 0.01, "inside the box with its stroke: %v in %v", p, r)
	}
	testing.expect(t, abs(lines[0].a.y - (r.y + r.h - half)) < 0.01, "0 at the bottom")
	testing.expect(t, abs(lines[1].b.y - (r.y + half)) < 0.01, "100 at the top")
	testing.expect(t, abs(lines[2].b.x - (r.x + r.w - half)) < 0.01, "the latest at the right edge")
}

// A history still filling up grows in from the right; one longer than the
// span shows its latest, scaled to what shows.
@(test)
a_sparklines_history_runs_in_from_the_right :: proc(t: ^testing.T) {
	ui: Ui(Spark_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n, lines, _ := spark(&ui, {10, 20, 30}, span = 11)
	r := node_get(&ui.tree, n).abs
	half := SPARK_LINE_W / 2
	step := (r.w - SPARK_LINE_W) / 10
	testing.expect_value(t, len(lines), 2)
	if len(lines) == 2 {
		testing.expect(t, abs(lines[0].a.x - (r.x + half + 8 * step)) < 0.01, "three values in the last three of eleven slots")
		testing.expect(t, abs(lines[1].b.x - (r.x + r.w - half)) < 0.01, "ending at the right")
	}
	_, lines, _ = spark(&ui, {1000, 1000, 1000, 5, 10, 20}, span = 3) // the old peak has left the window
	testing.expect_value(t, len(lines), 2)
	if len(lines) == 2 {
		testing.expect(t, abs(lines[0].a.x - (r.x + half)) < 0.01, "the latest three, edge to edge")
		testing.expect(t, abs(lines[1].b.y - (r.y + half)) < 0.01, "scaled to what shows: 20 at the top, not 1000")
	}
}

// The same values are no repaint; new ones are. `fill` shades between the
// line and 0. A label makes it an Image, described by its range and latest.
@(test)
a_sparkline_repaints_only_for_new_values :: proc(t: ^testing.T) {
	ui: Ui(Spark_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n, _, rects := spark(&ui, {10, 40, 20}, fill = true, label = "CPU")
	d := node_get(&ui.tree, n)
	testing.expect(t, len(rects) > 30, "shaded under the line, a column a pixel")
	base := d.abs.y + d.abs.h - SPARK_LINE_W / 2
	for rc in rects do testing.expectf(t, abs(rc.rect.y + rc.rect.h - base) < 0.01 && rc.color.a < 0.5, "from the line down to 0, quietly: %v", rc)
	testing.expect_value(t, d.access.role, Role.Image)
	testing.expect_value(t, d.access.name, "CPU")
	testing.expect_value(t, d.access.describe, "3 values, 10 to 40, now 20")

	testing.expect_value(t, spark_build(&ui, {10, 40, 20}, fill = true, label = "CPU"), n)
	testing.expect(t, .Dirty_Paint not_in d.flags, "the same values: nothing to paint")
	testing.expect_value(t, spark_build(&ui, {10, 40, 20, 35}, fill = true, label = "CPU"), n)
	testing.expect(t, .Dirty_Paint in d.flags, "a new value: painted again")
	testing.expect_value(t, d.access.describe, "4 values, 10 to 40, now 35")
}

} // when ODIN_TEST