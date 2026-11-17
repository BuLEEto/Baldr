package baldr

@(require) import "core:fmt"
@(require) import "core:math"
@(require) import "core:math/linalg"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A widget of the app's own: it paints and measures itself, takes the keys
// it names while focused and lets the rest go on, answers clicks through
// `clickable`, and tells assistive technology its role and name.

@(private = "file")
Cw_Msg :: union { int, Chord }

@(private = "file")
CW_INK :: Color{0.2, 0.6, 0.3, 1}

@(private = "file")
cw_paint :: proc(p: ^Painter) {
	value := (^int)(p.user)^
	draw_rect(p, p.rect, CW_INK, radius = 4)
	draw_text(p, {p.rect.x + 4, p.rect.y + 2}, fmt.tprintf("value %d", value)) // a temporary string: draw_text keeps its own copy
}

@(private = "file")
cw_measure :: proc(user: rawptr, room: [2]f32) -> [2]f32 {
	return {70, 24}
}

@(private = "file")
cw_key :: proc(e: Ev(Chord)) -> Cw_Msg { return e.value }

@(private = "file")
cw_build :: proc(ui: ^Ui(Cw_Msg), value: ^int, with_measure := true, show := true) -> (n: Node) {
	begin_view(ui)
	column(ui, align = .Start)
	if show {
		n = custom(ui, cw_paint, value, measure = cw_measure if with_measure else nil, width = 0 if with_measure else 80, height = 0 if with_measure else 30,
			label = "Rating", role = .Slider, focusable = true, keys = {.Right}, on_key = cw_key)
		clickable(ui, n, Cw_Msg(7), label = "Rating")
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {300, 200})
	return
}

@(private = "file")
cw_drawn_text :: proc(ui: ^Ui(Cw_Msg)) -> (string, bool) {
	for c in draw_list(&ui.tree) do if dt, ok := c.(Draw_Text); ok && len(dt.str) > 5 && dt.str[:5] == "value" do return dt.str, true
	return "", false
}

@(test)
a_custom_widget_paints_and_measures_itself :: proc(t: ^testing.T) {
	ui: Ui(Cw_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	value := 3
	n := cw_build(&ui, &value)
	d := node_get(&ui.tree, n)
	testing.expect_value(t, d.abs.w, 70) // its measure decides
	testing.expect_value(t, d.abs.h, 24)
	rect_drawn := false
	for c in draw_list(&ui.tree) do if r, ok := c.(Draw_Rect); ok && r.color == CW_INK && r.rect == d.abs do rect_drawn = true
	testing.expect(t, rect_drawn, "its rectangle is drawn where it is")
	s, ok := cw_drawn_text(&ui)
	testing.expect(t, ok && s == "value 3", "its text is drawn")

	// The layer keeps its commands between frames; the text it points at must
	// outlive the temporary string it was drawn from.
	free_all(context.temp_allocator)
	_ = fmt.tprintf("%s", "overwrite the temporary memory with something else entirely")
	s, ok = cw_drawn_text(&ui)
	testing.expect(t, ok && s == "value 3", "the cached text is the widget's own copy")

	// A new value repaints on the next build.
	value = 4
	cw_build(&ui, &value)
	s, ok = cw_drawn_text(&ui)
	testing.expect(t, ok && s == "value 4", "drawn again from the new state")

	// Without a measure it is the size it was built with.
	n = cw_build(&ui, &value, with_measure = false)
	testing.expect_value(t, node_get(&ui.tree, n).abs.w, 80)
	testing.expect_value(t, node_get(&ui.tree, n).abs.h, 30)

	// And gone from the view, it leaves nothing behind (the leak check sees the rest).
	cw_build(&ui, &value, show = false)
	testing.expect_value(t, len(ui.tree.customs), 0)
	testing.expect_value(t, len(ui.custom_keys), 0)
}

@(test)
a_custom_widget_takes_the_keys_it_names :: proc(t: ^testing.T) {
	ui: Ui(Cw_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	value := 0
	n := cw_build(&ui, &value)
	set_focus(&ui.tree, n, true)
	testing.expect(t, key_event(&ui, .Right, true, {}), "a key it named is taken")
	testing.expect_value(t, len(ui.msgs), 1)
	chord, is_chord := ui.msgs[0].(Chord)
	testing.expect(t, is_chord && chord.key == .Right, "and handed over as a chord")
	clear(&ui.msgs)
	key_event(&ui, .Down, true, {})
	for m in ui.msgs do testing.expect(t, !(type_of(m) == Chord), "a key it did not name is not its")

	// A click goes through clickable, as on any node.
	clear(&ui.msgs)
	r := node_get(&ui.tree, n).abs
	pointer_move(&ui, {r.x + 5, r.y + 5})
	pointer_button(&ui, .Left, true, {r.x + 5, r.y + 5})
	pointer_button(&ui, .Left, false, {r.x + 5, r.y + 5})
	clicked := false
	for m in ui.msgs do if v, ok := m.(int); ok && v == 7 do clicked = true
	testing.expect(t, clicked, "clicked")

	// What a screen reader is told.
	dump := access_dump(&ui.tree)
	testing.expectf(t, contains_text(dump, "Rating"), "named in the accessibility tree: %s", dump)
	testing.expect_value(t, node_get(&ui.tree, n).access.role, Role.Slider) // its own role, though clickable
}

@(private = "file")
contains_text :: proc(s, sub: string) -> bool {
	for i in 0 ..= len(s) - len(sub) do if s[i:i + len(sub)] == sub do return true
	return false
}

@(private = "file")
cw_shapes :: proc(p: ^Painter) {
	c := [2]f32{p.rect.x + p.rect.w / 2, p.rect.y + p.rect.h / 2}
	draw_circle(p, c, 10, CW_INK)
	draw_arc(p, c, 30, 0, math.PI, 2, CW_INK)
	draw_bezier(p, {p.rect.x + 4, p.rect.y + 4}, {p.rect.x + 40, p.rect.y + 4}, {p.rect.x + 40, p.rect.y + 60}, {p.rect.x + 76, p.rect.y + 60}, 2, CW_INK)
}

// The shapes a custom widget draws from: a circle is a fully rounded
// square, an arc and a curve are lines along them, every point on them.
@(test)
a_custom_widget_draws_circles_arcs_and_curves :: proc(t: ^testing.T) {
	ui: Ui(Cw_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	column(&ui, align = .Start)
	n := custom(&ui, cw_shapes, nil, width = 80, height = 80, label = "Shapes", role = .Image)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {200, 200})
	r := node_get(&ui.tree, n).abs
	c := [2]f32{r.x + 40, r.y + 40}
	circle, on_arc, lines := false, 0, 0
	for cmd in draw_list(&ui.tree) {
		#partial switch v in cmd {
		case Draw_Rect:
			if v.color == CW_INK && v.radius == 10 && v.rect == (Rect{c.x - 10, c.y - 10, 20, 20}) do circle = true
		case Draw_Line:
			lines += 1
			if abs(linalg.length(v.a - c) - 30) < 0.01 && v.a.y >= c.y - 0.01 do on_arc += 1 // the lower half: 0 to pi, y down
		}
	}
	testing.expect(t, circle, "the circle is a square rounded all the way")
	testing.expectf(t, on_arc >= 10, "the arc is fine segments along its circle: %d", on_arc)
	testing.expectf(t, lines > on_arc + 10, "and the curve is segments too: %d lines", lines)
	testing.expect_value(t, len(ui.tree.bounds_faults), 0)
}

} // when ODIN_TEST
