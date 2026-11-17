package baldr

@(require) import "core:testing"
@(require) import "baldr:gpu"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: behind this `when`, checking a program costs
// 1.0 GB instead of 9.2 GB. ODIN_TEST is set by `odin test`; BALDR_TESTS
// lets ./build.sh check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(test)
svg_path_parses_and_flattens :: proc(t: ^testing.T) {
	line := svg_flatten("M2 2L22 22", 1)
	testing.expect_value(t, len(line), 1)
	testing.expect_value(t, len(line[0].pts), 2)
	testing.expect_value(t, line[0].pts[1], [2]f32{22, 22})
	two := svg_flatten("M18 6 6 18 | m6 6 12 12", 1) // two shapes; the second's relative m starts at the origin
	testing.expect_value(t, len(two), 2)
	testing.expect_value(t, two[1].pts[0], [2]f32{6, 6})
	testing.expect_value(t, two[1].pts[1], [2]f32{18, 18})
	rel := svg_flatten("m14 12 4 4 4-4", 1) // implicit lineto repeats, relative
	testing.expect_value(t, len(rel[0].pts), 3)
	testing.expect_value(t, rel[0].pts[2], [2]f32{22, 12})
	circle := svg_flatten(ICON_PATHS[.Circle], 1)
	testing.expect_value(t, len(circle), 1)
	testing.expect(t, circle[0].closed && len(circle[0].pts) > 12, "an arc-built circle is a closed polyline")
	for p in circle[0].pts {
		r := linalg_len(p - {12, 12})
		testing.expect(t, abs(r - 10) < 0.15, "every point lies on the radius")
	}
	glued := svg_flatten("M1.704.706L2 2", 1) // two numbers share one space-less '.'
	testing.expect_value(t, glued[0].pts[0], [2]f32{1.704, 0.706})
	// every vendored icon stays inside its 24-unit box (relative movetos after a joined path would leave it)
	for ic in Icon {
		if ic == .None do continue
		for sp in svg_flatten(ICON_PATHS[ic], 1) do for pt in sp.pts {
			testing.expect(t, pt.x >= -0.01 && pt.x <= 24.01 && pt.y >= -0.01 && pt.y <= 24.01, ICON_NAMES[ic])
		}
	}
	filled := svg_flatten("#M0 0H10V10H0Z", 2)
	testing.expect(t, filled[0].filled && filled[0].pts[2] == {20, 20})
}

@(test)
svg_raster_strokes_with_antialiasing :: proc(t: ^testing.T) {
	paths := svg_flatten("M2 12H22", 1) // horizontal 2 px stroke through row 12
	bm := svg_raster(paths, 24, 24, 2)
	testing.expect(t, bm[12 * 24 + 12] > 200, "on the stroke")
	testing.expect(t, bm[11 * 24 + 12] > 200, "stroke is 2 px tall")
	testing.expect(t, bm[9 * 24 + 12] == 0, "clear above")
	testing.expect(t, bm[0] == 0 && bm[24 * 24 - 1] == 0, "corners empty")
	testing.expect(t, bm[12 * 24 + 0] == 0 && bm[12 * 24 + 23] < 200, "round caps end the stroke")
	fill := svg_raster(svg_flatten("#M4 4H20V20H4Z", 1), 24, 24, 2)
	testing.expect(t, fill[12 * 24 + 12] == 255, "filled interior")
	testing.expect(t, fill[1 * 24 + 1] == 0, "outside stays clear")
}

@(test)
icon_builder_and_atlas_cache :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	te: Text_Engine
	text_engine_init(&te)
	defer text_engine_destroy(&te)
	tree_use_text_engine(&ui.tree, &te)
	begin_view(&ui)
	row(&ui, gap = .sm, align = .Center)
	deco := icon(&ui, .Folder)
	named := icon(&ui, .Star, size = 24, label = "Favourite")
	b := button(&ui, "Close", Ov_Msg{}, icon = .X, icon_only = true)
	b2 := button(&ui, "Save", Ov_Msg{}, icon = .Save)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 100})
	dd := node_get(&ui.tree, deco)
	testing.expect_value(t, dd.abs.w, ICON_SIZE)
	testing.expect_value(t, dd.access.role, Role.None)
	nd := node_get(&ui.tree, named)
	testing.expect_value(t, nd.abs.w, 24)
	testing.expect_value(t, nd.access.role, Role.Image)
	testing.expect_value(t, nd.access.name, "Favourite")
	bd := node_get(&ui.tree, b)
	testing.expect_value(t, bd.access.name, "Close")
	testing.expect_value(t, node_child_count(&ui.tree, b), 1) // the icon only
	testing.expect_value(t, bd.abs.w, bd.abs.h)                // square
	testing.expect_value(t, node_child_count(&ui.tree, b2), 2) // icon + label
	testing.expect(t, lint(&ui.tree) == 0)
	icons := 0
	for c in draw_list(&ui.tree) do if _, ok := c.(Draw_Icon); ok do icons += 1
	testing.expect_value(t, icons, 4)
	cmds := make([dynamic]gpu.Cmd, context.temp_allocator)
	render_prepare(&ui.tree, 1, nil, &cmds)
	glyphs := 0
	for c in cmds do if _, ok := c.(gpu.Glyph); ok do glyphs += 1
	testing.expect(t, glyphs >= 4, "icons became atlas glyphs")
	testing.expect_value(t, len(te.icons), 4) // Folder@16, Star@24, X@16, Save@16
	clear(&cmds)
	render_prepare(&ui.tree, 1, nil, &cmds)
	testing.expect_value(t, len(te.icons), 4) // cached, not rasterised again
	render_prepare(&ui.tree, 2, nil, &cmds)
	testing.expect_value(t, len(te.icons), 8) // a new device size rasterises anew
	// the squiggle tile: one cycle, seamless (the middle column and the edge columns both carry ink)
	slot, ok := wave_slot(&te, 2)
	testing.expect(t, ok)
	testing.expect_value(t, slot.px_size.x, 12)
	testing.expect_value(t, slot.px_size.y, 6)
	// the tile must carry ink in every column (a continuous wave), top and bottom rows included
	pages := atlas_pages(&te, .Alpha8)
	pg := pages[slot.page_index]
	ox := int(slot.uv_rect[0] * f32(pg.width) + 0.5)
	oy := int(slot.uv_rect[1] * f32(pg.height) + 0.5)
	for x in 0 ..< 12 {
		col := 0
		for y in 0 ..< 6 do col += int(pg.pixels[(oy + y) * int(pg.width) + ox + x])
		testing.expect(t, col > 0, "wave column has ink")
	}
	top, bottom := 0, 0
	for x in 0 ..< 12 {
		top += int(pg.pixels[oy * int(pg.width) + ox + x])
		bottom += int(pg.pixels[(oy + 5) * int(pg.width) + ox + x])
	}
	testing.expect(t, top > 0 && bottom > 0, "the wave reaches both edges: peaks and troughs")
	testing.expect_value(t, len(te.icons), 9)
	clear(&cmds)
	wave := Draw_Wave{pos = {10, 10}, width = 20, color = ui.theme.color.danger}
	render_wave(&te, wave, 2, nil, &cmds)
	testing.expect_value(t, len(cmds), 4) // 40 device px / 12 per tile → 3 full tiles + a 4 px remainder
	last := cmds[3].(gpu.Glyph)
	testing.expect_value(t, last.rect.z, 4)
}

// Each kind of Bluetooth device draws a picture of its own at the 16 px a
// list row gives an icon.
@(test)
device_icons_draw_at_list_size :: proc(t: ^testing.T) {
	devices := [?]Icon{.Headphones, .Speaker, .Mouse, .Keyboard, .Gamepad_2, .Tablet, .Smartphone, .Laptop, .Printer, .Camera}
	names := [?]string{"headphones", "speaker", "mouse", "keyboard", "gamepad-2", "tablet", "smartphone", "laptop", "printer", "camera"}
	expect_distinct_icons(t, devices[:], names[:])
}

// A thumb up and a thumb down are mirror images, so the check that matters
// is that they draw as distinct pictures at 16 px.
@(test)
thumb_icons_draw_and_differ :: proc(t: ^testing.T) {
	thumbs := [?]Icon{.Thumbs_Up, .Thumbs_Down}
	names := [?]string{"thumbs-up", "thumbs-down"}
	expect_distinct_icons(t, thumbs[:], names[:])
}

// Lucide renamed `smile` to `face-slightly-smiling`, so icons.txt carries
// it as an alias: this checks the alias resolves to a real picture, not an
// empty path.
@(test)
smiley_icons_draw_and_differ :: proc(t: ^testing.T) {
	expect_distinct_icons(t, []Icon{.Smile, .Sticker}, []string{"smile", "sticker"})
}

// The reply arrow shares the undo arrow's elbow, and beside a message an
// undo arrow reads as "undo": the two must draw differently.
@(test)
reply_icon_draws_and_is_not_the_undo_arrow :: proc(t: ^testing.T) {
	expect_distinct_icons(t, []Icon{.Reply, .Undo_2}, []string{"reply", "undo-2"})
}

// A media player's bar. Captions and captions-off differ by a single
// stroke, a pair a "draws something" check would pass while they look
// identical on screen, hence the distinctness check.
@(test)
a_players_icons_draw_and_differ_from_one_another :: proc(t: ^testing.T) {
	media := [?]Icon{.Captions, .Captions_Off, .Picture_In_Picture}
	names := [?]string{"captions", "captions-off", "picture-in-picture"}
	expect_distinct_icons(t, media[:], names[:])
}

// Sparkles marks effects (a blurred background, fixed light). It must not
// be confused with Palette, which reads as "colours", with Star (five
// points, no second mark), or with the wand, which carries the same
// sparkles.
@(test)
the_effects_icons_draw_and_differ_from_what_stood_in :: proc(t: ^testing.T) {
	fx := [?]Icon{.Sparkles, .Wand_Sparkles, .Palette, .Star}
	names := [?]string{"sparkles", "wand-sparkles", "palette", "star"}
	expect_distinct_icons(t, fx[:], names[:])
}

// The forecast icons each draw a picture of their own at the 16 px a bar
// applet or a calendar day gives an icon.
@(test)
weather_icons_draw_at_list_size :: proc(t: ^testing.T) {
	weather := [?]Icon{.Cloud, .Cloud_Sun, .Cloud_Moon, .Cloud_Rain, .Cloud_Drizzle, .Cloud_Snow, .Cloud_Fog, .Cloud_Lightning, .Wind, .Droplets, .Thermometer, .Sun, .Sun_Dim}
	names := [?]string{"cloud", "cloud-sun", "cloud-moon", "cloud-rain", "cloud-drizzle", "cloud-snow", "cloud-fog", "cloud-lightning", "wind", "droplets", "thermometer", "sun", "sun-dim"}
	expect_distinct_icons(t, weather[:], names[:])
}

// expect_distinct_icons: each icon is named as Lucide names it and draws a
// stroked picture at 16 px, unlike every other in the set.
@(private = "file")
expect_distinct_icons :: proc(t: ^testing.T, icons: []Icon, names: []string, loc := #caller_location) {
	px :: 16
	scale := f32(px) / 24
	bitmaps := make([][]u8, len(icons), context.temp_allocator)
	for ic, i in icons {
		testing.expect_value(t, ICON_NAMES[ic], names[i], loc = loc)
		bm := svg_raster(svg_flatten(ICON_PATHS[ic], scale, context.temp_allocator), px, px, 2 * scale, context.temp_allocator)
		ink := 0
		for v in bm do if v > 128 do ink += 1
		testing.expectf(t, ink >= px && ink <= px * px / 2, "%s draws a stroked picture: %d of %d px inked", names[i], ink, px * px, loc = loc)
		bitmaps[i] = bm
	}
	for i in 0 ..< len(icons) do for j in i + 1 ..< len(icons) {
		same := len(bitmaps[i]) == len(bitmaps[j])
		for k in 0 ..< len(bitmaps[i]) do if same && bitmaps[i][k] != bitmaps[j][k] do same = false
		testing.expectf(t, !same, "%s and %s look alike", names[i], names[j], loc = loc)
	}
}

} // when ODIN_TEST