package baldr

@(require) import "core:math"
@(require) import "core:testing"

// See canvas_test.odin for why test files sit behind this `when`.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Progress as a ring round an icon-only button. The bar style lands on the
// bottom stroke of a line glyph (a drive, a tray), where the eye cannot tell
// where its fill ends.

@(private = "file")
Ring_Msg :: union { int }

@(private = "file")
ring_entry :: proc(ui: ^Ui(Ring_Msg), progress: Maybe(f32), style: Maybe(Progress_Style) = nil, busy: Maybe(bool) = nil,
	variant: Button_Variant = .Ghost) -> Node {
	begin_view(ui)
	row(ui, height = 40, padding = .xs, align = .Center)
	b := button(ui, "Backups", Ring_Msg(1), variant = variant, icon = .Hard_Drive, icon_only = true)
	button_options(ui, b, progress = progress, progress_style = style, indeterminate = busy)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {200, 40})
	return b
}

@(private = "file")
ring_icon :: proc(ui: ^Ui(Ring_Msg), b: Node) -> Rect {
	for ch := node_get(&ui.tree, b).first; ch != NODE_NONE; ch = node_get(&ui.tree, ch).next {
		if cd := node_get(&ui.tree, ch); Control_Part(cd.key) == .Icon do return cd.abs
	}
	return {}
}

// ring_parts: the round outlined rect that is the track, and the segments
// of the arc in the order drawn.
@(private = "file")
ring_parts :: proc(ui: ^Ui(Ring_Msg)) -> (track: Maybe(Draw_Rect), arc: [dynamic]Draw_Line) {
	arc = make([dynamic]Draw_Line, context.temp_allocator)
	for c in draw_list(&ui.tree) {
		#partial switch v in c {
		case Draw_Rect:
			if v.border_w == BUTTON_RING_THICKNESS && v.radius * 2 >= v.rect.w - 0.01 do track = v
		case Draw_Line:
			if v.width == BUTTON_RING_THICKNESS do append(&arc, v)
		}
	}
	return
}

@(private = "file")
near_point :: proc(a, b: [2]f32) -> bool { return abs(a.x - b.x) < 0.05 && abs(a.y - b.y) < 0.05 }

// The ring sits outside the icon's box, inside the button, and fills a
// quarter clockwise from twelve o'clock for 0.25: its first point is straight
// above the centre and its last straight to the right.
@(test)
a_ring_goes_round_the_icon_and_fills_clockwise_from_twelve :: proc(t: ^testing.T) {
	ui: Ui(Ring_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.motion.reduce = true // shown as it is

	b := ring_entry(&ui, f32(0.25), Progress_Style.Ring)
	icon := ring_icon(&ui, b)
	bd := node_get(&ui.tree, b).abs
	track, arc := ring_parts(&ui)
	tr, has_track := track.?
	testing.expect(t, has_track, "the whole circle is drawn faintly as the track")
	if !has_track || len(arc) == 0 {
		testing.expectf(t, len(arc) > 0, "and an arc over it (%d segments)", len(arc))
		return
	}
	cx, cy := icon.x + icon.w / 2, icon.y + icon.h / 2
	r := tr.rect.w / 2 - BUTTON_RING_THICKNESS / 2
	testing.expectf(t, r - BUTTON_RING_THICKNESS / 2 >= icon.w / 2, "the ring's inner edge (%v) clears the icon's box (%v): no stroke of the glyph under it", r - BUTTON_RING_THICKNESS / 2, icon.w / 2)
	testing.expectf(t, tr.rect.x >= bd.x && tr.rect.x + tr.rect.w <= bd.x + bd.w, "and it stays inside the button (%v in %v)", tr.rect, bd)
	testing.expectf(t, near_point(arc[0].a, {cx, cy - r}), "it starts at twelve o'clock: %v, want %v", arc[0].a, [2]f32{cx, cy - r})
	testing.expectf(t, near_point(arc[len(arc) - 1].b, {cx + r, cy}), "a quarter ends at three o'clock: %v, want %v", arc[len(arc) - 1].b, [2]f32{cx + r, cy})
	testing.expect(t, arc[0].color.a > tr.border.a, "the fill reads over its track")
	testing.expect_value(t, arc[0].color.rgb, ui.tree.theme.color.primary.rgb)

	// the bar is not drawn as well
	for c in draw_list(&ui.tree) do if r, is := c.(Draw_Rect); is && r.rect.h == BUTTON_PROGRESS_THICKNESS && abs(r.rect.y + r.rect.h - (icon.y + icon.h)) < 0.01 {
		testing.expect(t, false, "a ring button draws no bar")
	}
}

// Busy: an arc of fixed length with no known end, standing at twelve under
// reduce motion; announced as Busy, with no value.
@(test)
a_busy_ring_is_an_arc_and_is_announced_busy :: proc(t: ^testing.T) {
	ui: Ui(Ring_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.motion.reduce = true

	b := ring_entry(&ui, nil, Progress_Style.Ring, true)
	icon := ring_icon(&ui, b)
	track, arc := ring_parts(&ui)
	tr, has_track := track.?
	testing.expect(t, has_track && len(arc) > 0, "busy draws its track and an arc")
	if !has_track || len(arc) == 0 do return
	cx, cy := icon.x + icon.w / 2, icon.y + icon.h / 2
	r := tr.rect.w / 2 - BUTTON_RING_THICKNESS / 2
	testing.expectf(t, near_point(arc[0].a, {cx, cy - r}), "under reduce motion the arc stands at twelve: %v", arc[0].a)
	end_angle := BUTTON_RING_BUSY_ARC * 2 * math.PI - math.PI / 2
	want := [2]f32{cx + r * math.cos(end_angle), cy + r * math.sin(end_angle)}
	testing.expectf(t, near_point(arc[len(arc) - 1].b, want), "and covers its share of the ring: ends %v, want %v", arc[len(arc) - 1].b, want)

	a := node_get(&ui.tree, b).access
	testing.expect(t, .Busy in a.states, "a reader is told it is busy")
	testing.expect(t, !a.has_value, "with no value to read")
}

// The value is announced, for a ring and a bar alike, and goes with the
// progress.
@(test)
a_buttons_progress_is_announced_as_a_value :: proc(t: ^testing.T) {
	ui: Ui(Ring_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.motion.reduce = true

	for style in Progress_Style {
		b := ring_entry(&ui, f32(0.3), style, false)
		a := node_get(&ui.tree, b).access
		testing.expectf(t, a.has_value && abs(a.value - 0.3) < 0.001 && a.value_max == 1, "%v: the value is 0.3 of 1 (%v, %v of %v)", style, a.has_value, a.value, a.value_max)
		testing.expectf(t, .Busy not_in a.states, "%v: and not busy", style)
		ring_entry(&ui, f32(-1), style)
		testing.expectf(t, !node_get(&ui.tree, b).access.has_value, "%v: taken away, nothing is announced", style)
	}
}

// On a button filled with the accent the accent would vanish, so the ring
// takes the colour that reads on that fill.
@(test)
a_ring_on_an_accent_button_stays_visible :: proc(t: ^testing.T) {
	ui: Ui(Ring_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.motion.reduce = true

	b := ring_entry(&ui, f32(0.5), Progress_Style.Ring, variant = .Primary)
	bg := node_get(&ui.tree, b).style.bg
	_, arc := ring_parts(&ui)
	testing.expect(t, len(arc) > 0, "an arc is drawn")
	if len(arc) == 0 do return
	ratio := contrast_ratio(opaque(arc[0].color), opaque(bg))
	testing.expectf(t, ratio >= 3, "it stands %.2f:1 off the button's own fill (wants 3:1)", ratio)
}

}
