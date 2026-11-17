package baldr

@(require) import "core:testing"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Progress across a button's icon, as a taskbar or dock entry shows it.


@(private = "file")
ButtonProgress_PMsg :: union { int }

// entry: a taskbar entry, one icon-only button, with `progress` and `badge` as given.
@(private = "file")
entry :: proc(ui: ^Ui(ButtonProgress_PMsg), progress: Maybe(f32), badge: Maybe(Button_Badge) = nil) -> Node {
	begin_view(ui)
	row(ui, height = 40, padding = .xs, align = .Center)
	b := button(ui, "Downloads", ButtonProgress_PMsg(1), variant = .Ghost, icon = .Folder, icon_only = true)
	if v, ok := progress.?; ok do button_options(ui, b, progress = v)
	if v, ok := badge.?; ok do button_options(ui, b, badge = v)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {200, 40})
	return b
}

@(private = "file")
icon_of :: proc(ui: ^Ui(ButtonProgress_PMsg), b: Node) -> Rect {
	for ch := node_get(&ui.tree, b).first; ch != NODE_NONE; ch = node_get(&ui.tree, ch).next {
		if cd := node_get(&ui.tree, ch); Control_Part(cd.key) == .Icon do return cd.abs
	}
	return {}
}

// bars: the rects drawn across the bottom of button `b`'s icon, thinner than
// the icon is tall: the track first, then the fill.
@(private = "file")
bars :: proc(ui: ^Ui(ButtonProgress_PMsg), b: Node) -> (out: [dynamic]Draw_Rect) {
	icon := icon_of(ui, b)
	out = make([dynamic]Draw_Rect, context.temp_allocator)
	for c in draw_list(&ui.tree) {
		r, is_rect := c.(Draw_Rect)
		if !is_rect || r.color.a == 0 do continue
		if r.rect.h > BUTTON_PROGRESS_THICKNESS + 0.01 || r.rect.h <= 0 do continue
		if abs(r.rect.y + r.rect.h - (icon.y + icon.h)) > 0.01 || abs(r.rect.x - icon.x) > 0.01 do continue
		append(&out, r)
	}
	return
}

// Progress takes no room, sits across the bottom of the icon inside its
// width, fills to its value over a faint track, and goes when it is taken
// away. With a badge as well, the two don't overlap.
@(test)
a_buttons_progress_crosses_its_icon_and_takes_no_room :: proc(t: ^testing.T) {
	ui: Ui(ButtonProgress_PMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.motion.reduce = true // the bar shows as it is, and goes at once

	plain := entry(&ui, nil)
	plain_w, plain_h := node_get(&ui.tree, plain).abs.w, node_get(&ui.tree, plain).abs.h
	testing.expect_value(t, len(bars(&ui, plain)), 0)

	b := entry(&ui, f32(0.35))
	icon := icon_of(&ui, b)
	drawn := bars(&ui, b)
	testing.expectf(t, len(drawn) == 2, "a track and a fill: %d", len(drawn))
	if len(drawn) != 2 do return
	track, fill := drawn[0], drawn[1]
	testing.expect_value(t, track.rect.w, icon.w)
	testing.expectf(t, abs(fill.rect.w - icon.w * 0.35) < 0.01, "the fill is the value across the icon: %v of %v", fill.rect.w, icon.w)
	testing.expect(t, fill.color.a > track.color.a, "the fill reads over its track")
	testing.expect_value(t, fill.color.rgb, ui.tree.theme.color.primary.rgb)
	bd := node_get(&ui.tree, b)
	testing.expect(t, bd.abs.w == plain_w && bd.abs.h == plain_h, "it takes no room")

	// with a badge, the two stay clear of each other
	b = entry(&ui, f32(0.5), Button_Badge{text = "3"})
	drawn = bars(&ui, b)
	testing.expect_value(t, len(drawn), 2)
	pill: Rect
	for c in draw_list(&ui.tree) {
		if r, ok := c.(Draw_Rect); ok && r.color.a > 0 && abs(r.radius - r.rect.h / 2) < 0.01 && r.rect.h > BUTTON_PROGRESS_THICKNESS do pill = r.rect
	}
	testing.expect(t, pill.h > 0, "fixture: the badge is drawn")
	if len(drawn) == 2 {
		testing.expect(t, pill.y + pill.h <= drawn[0].rect.y + 0.01, "the badge is above the bar")
	}

	// taken away
	b = entry(&ui, f32(-1))
	testing.expect_value(t, len(bars(&ui, b)), 0)
	// and an option left out keeps what it had
	b = entry(&ui, f32(0.6))
	b = entry(&ui, nil)
	testing.expect_value(t, len(bars(&ui, b)), 2)
}

} // when ODIN_TEST