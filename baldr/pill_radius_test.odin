package baldr

@(require) import "core:testing"

when ODIN_TEST || #config(BALDR_TESTS, false) {

// A shape drawn as a pill takes `min(theme.radius.full, h / 2)` rather than
// `h / 2`, so a theme that squares its buttons and fields squares its pills
// with them. `full` is 9999 in every theme the toolkit ships, which is "as
// round as the shape allows", so none of them changes.
//
// What is round *on purpose* does not read `full` at all: a switch's track
// and knob, a slider's thumb, a Large slider's pill, a radio, a dot.

@(private = "file")
Pill_Msg :: union { int, bool, f32 }

// pill_start: a tree whose theme has the given `radius.full`, with motion
// reduced so a segmented control's picked segment is where it belongs on
// the first frame rather than gliding there.
@(private = "file")
pill_start :: proc(ui: ^Ui(Pill_Msg), full: f32) {
	ui_init(ui)
	ui.tree.theme.radius.full = full
	ui.tree.theme.motion.reduce = true
}

// pill_rects: every rect the last frame drew with ink in it — in its fill
// or in its border, because a ring (a focus ring, a radio) is a rect with
// no fill at all and filtering on `color` alone drops it.
@(private = "file")
pill_rects :: proc(ui: ^Ui(Pill_Msg)) -> (out: [dynamic]Draw_Rect) {
	out = make([dynamic]Draw_Rect, context.temp_allocator)
	for c in draw_list(&ui.tree) {
		r, ok := c.(Draw_Rect)
		if !ok do continue
		if r.color.a > 0.001 || (r.border_w > 0 && r.border.a > 0.001) do append(&out, r)
	}
	return
}

// pill_tinted compares two colours by their ink alone: paint scales alpha
// by the tree's opacity and by disabled, which is not what is under test.
@(private = "file")
pill_tinted :: proc(a, b: Color) -> bool {
	return abs(a.r - b.r) < 0.004 && abs(a.g - b.g) < 0.004 && abs(a.b - b.b) < 0.004
}

// pill_in: the first rect the frame drew in `col`, filled or outlined.
@(private = "file")
pill_in :: proc(ui: ^Ui(Pill_Msg), col: Color) -> (Draw_Rect, bool) {
	for r in pill_rects(ui) {
		if r.color.a > 0.001 && pill_tinted(r.color, col) do return r, true
		if r.border_w > 0 && r.border.a > 0.001 && pill_tinted(r.border, col) do return r, true
	}
	return {}, false
}

// pill_segmented draws a hugging segmented control with the middle segment
// picked, and returns the group.
@(private = "file")
pill_segmented :: proc(ui: ^Ui(Pill_Msg)) -> Node {
	labels := []string{"Light", "Dark", "System"}
	begin_view(ui)
	row(ui, padding = .md, align = .Center)
	n := segmented(ui, 1, labels)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 80})
	return n
}

// pill_progress draws a progress bar, determinate or not, and returns it.
@(private = "file")
pill_progress :: proc(ui: ^Ui(Pill_Msg), indeterminate: bool) -> Node {
	begin_view(ui)
	row(ui, padding = .md, align = .Center)
	n := progress(ui, 0.5, width = 200, indeterminate = indeterminate)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 80})
	return n
}

// pill_bars: the two bars a button's progress draws across its icon,
// thinner than the icon is tall (the track first, then the fill).
@(private = "file")
pill_bars :: proc(ui: ^Ui(Pill_Msg)) -> (out: [dynamic]Draw_Rect) {
	out = make([dynamic]Draw_Rect, context.temp_allocator)
	for r in pill_rects(ui) {
		if r.rect.h <= 0 || r.rect.h > BUTTON_PROGRESS_THICKNESS + 0.01 do continue
		append(&out, r)
	}
	return
}

// pill_button_progress draws an icon-only button with progress across it.
@(private = "file")
pill_button_progress :: proc(ui: ^Ui(Pill_Msg)) {
	begin_view(ui)
	row(ui, height = 40, padding = .xs, align = .Center)
	b := button(ui, "Downloads", Pill_Msg(1), variant = .Ghost, icon = .Folder, icon_only = true)
	button_options(ui, b, progress = 0.4)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {200, 40})
}

// A segmented control's track and gliding segment are drawn by the group's
// own paint, which takes the theme's `full` too, and the segment's shadow
// with them: a round shadow under a square corner reads as a smudge.
@(test)
a_square_theme_squares_the_segmented_control :: proc(t: ^testing.T) {
	ui: Ui(Pill_Msg)
	pill_start(&ui, 0)
	defer ui_destroy(&ui)
	n := pill_segmented(&ui)
	th := &ui.tree.theme
	testing.expect(t, node_get(&ui.tree, n).abs.h > 8, "fixture: the control is taller than any radius under test")

	track, has_track := pill_in(&ui, choice_track(th))
	testing.expect(t, has_track, "fixture: the hugging track is drawn")
	testing.expectf(t, track.radius == 0, "the track takes the theme's full, not half its height: %v", track.radius)

	seg, has_seg := pill_in(&ui, th.color.surface_high)
	testing.expect(t, has_seg, "fixture: the picked segment is drawn")
	testing.expectf(t, seg.radius == 0, "and the picked segment: %v", seg.radius)

	shadows := 0
	for c in draw_list(&ui.tree) {
		if s, ok := c.(Draw_Shadow); ok {
			shadows += 1
			testing.expectf(t, s.radius == 0, "and the segment's shadow: %v", s.radius)
		}
	}
	testing.expect(t, shadows > 0, "fixture: the segment casts a shadow")

	// And with the `full` every theme in the toolkit sets, nothing moves.
	round: Ui(Pill_Msg)
	pill_start(&round, 9999)
	defer ui_destroy(&round)
	pill_segmented(&round)
	rt, _ := pill_in(&round, choice_track(&round.tree.theme))
	rs, _ := pill_in(&round, round.tree.theme.color.surface_high)
	testing.expectf(t, rt.radius == rt.rect.h / 2, "still a pill: %v of %v", rt.radius, rt.rect.h)
	testing.expectf(t, rs.radius == rs.rect.h / 2, "still a pill: %v of %v", rs.radius, rs.rect.h)
}

// The focus ring sits 3 px outside the picked segment, so it takes the
// segment's radius plus that offset — or a square segment would wear a
// round ring.
@(test)
the_segmented_focus_ring_follows_the_segment :: proc(t: ^testing.T) {
	square: Ui(Pill_Msg)
	pill_start(&square, 0)
	defer ui_destroy(&square)
	n := pill_segmented(&square)
	set_focus(&square.tree, n, true)
	frame(&square.tree, {400, 80})
	testing.expect(t, ring_shown(&square.tree), "fixture: the ring is drawn")
	ring, has := pill_in(&square, square.tree.theme.color.focus_ring)
	testing.expect(t, has, "fixture: a ring in the ring colour")
	testing.expectf(t, ring.radius == 3, "a square segment's ring is the segment's radius plus its offset: %v", ring.radius)

	round: Ui(Pill_Msg)
	pill_start(&round, 9999)
	defer ui_destroy(&round)
	rn := pill_segmented(&round)
	set_focus(&round.tree, rn, true)
	frame(&round.tree, {400, 80})
	rring, rhas := pill_in(&round, round.tree.theme.color.focus_ring)
	testing.expect(t, rhas, "fixture: a ring in the ring colour")
	// the ring's rect is the segment grown by 3 either side
	testing.expectf(t, rring.radius == (rring.rect.h - 6) / 2 + 3, "a pill's ring is still round: %v of %v", rring.radius, rring.rect.h)
}

// A progress bar's track, its fill and the band it sweeps while it is
// indeterminate are all the same shape, so all three follow `full`.
@(test)
a_square_theme_squares_a_progress_bar :: proc(t: ^testing.T) {
	ui: Ui(Pill_Msg)
	pill_start(&ui, 0)
	defer ui_destroy(&ui)
	pill_progress(&ui, false)
	th := &ui.tree.theme
	track, has_track := pill_in(&ui, th.color.surface_variant)
	fill, has_fill := pill_in(&ui, th.color.primary)
	testing.expect(t, has_track && has_fill, "fixture: a track and a fill")
	testing.expectf(t, track.radius == 0 && fill.radius == 0, "both take the theme's full: %v, %v", track.radius, fill.radius)
	testing.expectf(t, abs(fill.rect.w - track.rect.w / 2) < 0.01, "fixture: the fill is half across")

	// indeterminate: the band that sweeps (and the static one under reduce-motion)
	pill_progress(&ui, true)
	band, has_band := pill_in(&ui, th.color.primary)
	testing.expect(t, has_band, "fixture: a band is drawn")
	testing.expectf(t, band.radius == 0, "the band too: %v", band.radius)
	testing.expect(t, band.rect.w < 200, "fixture: the band is narrower than the bar")

	round: Ui(Pill_Msg)
	pill_start(&round, 9999)
	defer ui_destroy(&round)
	pill_progress(&round, false)
	rt, _ := pill_in(&round, round.tree.theme.color.surface_variant)
	testing.expectf(t, rt.radius == rt.rect.h / 2, "still a pill: %v of %v", rt.radius, rt.rect.h)
}

// The bar across a button's icon is a pill too — thin, but a square theme
// should not have one rounded shape left on the button.
@(test)
a_square_theme_squares_a_buttons_progress_bar :: proc(t: ^testing.T) {
	ui: Ui(Pill_Msg)
	pill_start(&ui, 0)
	defer ui_destroy(&ui)
	pill_button_progress(&ui)
	bars := pill_bars(&ui)
	testing.expectf(t, len(bars) == 2, "fixture: a track and a fill: %d", len(bars))
	for b in bars do testing.expectf(t, b.radius == 0, "the bar takes the theme's full: %v", b.radius)

	round: Ui(Pill_Msg)
	pill_start(&round, 9999)
	defer ui_destroy(&round)
	pill_button_progress(&round)
	rbars := pill_bars(&round)
	testing.expectf(t, len(rbars) == 2, "fixture: a track and a fill: %d", len(rbars))
	for b in rbars do testing.expectf(t, b.radius == b.rect.h / 2, "still a pill: %v of %v", b.radius, b.rect.h)
}

// `full` is a ceiling, not an instruction: a shape never gets *rounder*
// than a pill because a theme asked for a big radius, and a shape shorter
// than the theme's `full` keeps its own round ends. One theme shows both at
// once — a segmented control is tall enough to be squared by full = 4, a
// 6 px progress bar is not.
@(test)
the_full_radius_is_a_ceiling_not_an_override :: proc(t: ^testing.T) {
	ui: Ui(Pill_Msg)
	pill_start(&ui, 4)
	defer ui_destroy(&ui)
	pill_segmented(&ui)
	seg, has_seg := pill_in(&ui, ui.tree.theme.color.surface_high)
	testing.expect(t, has_seg, "fixture: the picked segment is drawn")
	testing.expect(t, seg.rect.h / 2 > 4, "fixture: the segment is taller than the theme's full")
	testing.expectf(t, seg.radius == 4, "a tall pill takes the theme's full: %v", seg.radius)

	pill_progress(&ui, false)
	track, has_track := pill_in(&ui, ui.tree.theme.color.surface_variant)
	testing.expect(t, has_track, "fixture: the progress track is drawn")
	testing.expect_value(t, track.rect.h, PROGRESS_H)
	testing.expectf(t, track.radius == PROGRESS_H / 2, "a short pill keeps its own ends: %v", track.radius)
}

// A switch, a radio, a dot and a slider's thumb are round because of what
// they are, not because of the theme: they keep their round ends under a
// theme with no radius at all. A Large slider is a pill for the same
// reason — its knob is a circle as tall as its track, and squaring the
// track alone would leave corners poking out around it.
@(test)
what_is_round_on_purpose_stays_round :: proc(t: ^testing.T) {
	ui: Ui(Pill_Msg)
	pill_start(&ui, 0)
	defer ui_destroy(&ui)

	// a switch: its track and its knob
	begin_view(&ui)
	row(&ui, padding = .md, align = .Center)
	toggle(&ui, true, "Glass")
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 80})
	sw := pill_rects(&ui)
	testing.expectf(t, len(sw) == 2, "fixture: a track and a knob: %d", len(sw))
	for r in sw do testing.expectf(t, r.radius == r.rect.h / 2, "a switch keeps its round ends: %v of %v", r.radius, r.rect.h)

	// a radio: its ring and its dot
	begin_view(&ui)
	row(&ui, padding = .md, align = .Center)
	options := []string{"One", "Two"}
	radio(&ui, 0, options)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 120})
	rings := 0
	for r in pill_rects(&ui) {
		if abs(r.rect.w - r.rect.h) > 0.01 do continue // the rings and the dot are square rects
		rings += 1
		testing.expectf(t, r.radius == r.rect.w / 2, "a radio stays a circle: %v of %v", r.radius, r.rect.w)
	}
	testing.expect(t, rings >= 2, "fixture: two rings and the picked dot")

	// a Large slider: its pill, the accent in it, and its knob
	begin_view(&ui)
	row(&ui, padding = .md, align = .Center)
	slider(&ui, 0.5, width = 160, size = .Large)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 80})
	large := 0
	for r in pill_rects(&ui) {
		if r.rect.h < SLIDER_LARGE_H - 0.01 do continue
		large += 1
		testing.expectf(t, r.radius == r.rect.h / 2, "a Large slider stays a pill: %v of %v", r.radius, r.rect.h)
	}
	testing.expectf(t, large >= 3, "fixture: the track, the fill and the knob: %d", large)

	// a Regular slider: its thumb, and the thin track it runs in
	begin_view(&ui)
	row(&ui, padding = .md, align = .Center)
	slider(&ui, 0.5, width = 160)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 80})
	thumbs := 0
	for r in pill_rects(&ui) {
		if abs(r.rect.w - SLIDER_THUMB) > 0.01 || abs(r.rect.h - SLIDER_THUMB) > 0.01 do continue
		thumbs += 1
		testing.expectf(t, r.radius == SLIDER_THUMB / 2, "a slider's thumb stays a circle: %v", r.radius)
	}
	testing.expect_value(t, thumbs, 1)
}

} // when ODIN_TEST
