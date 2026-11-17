package baldr

@(require) import "core:math"
@(require) import "core:testing"

when ODIN_TEST || #config(BALDR_TESTS, false) {

// A drag that leaves the window takes a picture with it: `drag_leave_window`
// hands the compositor an icon surface, and once the compositor carries the
// drag our own ghost stops drawing, or it would sit frozen at the window's
// edge.
//
// These tests install a real font engine. A headless `Tree` has
// `text = nil`, and with the mono measurer there are no glyph slots to
// blit, so a test of the picture's pixels would read an empty buffer.

@(private = "file")
Dpic_Msg :: union { int }

@(private = "file")
dpic_files :: proc(user: rawptr, tag: u64, count: int, allocator := context.allocator) -> []string {
	out := make([]string, max(count, 1), allocator)
	for i in 0 ..< len(out) do out[i] = "/home/user/Files/row.txt"
	return out
}

@(private = "file")
Dpic_Fake :: struct {
	started:     int,
	icon_size:   [2]i32,
	icon_offset: [2]i32,
	icon_scale:  f32,
	icon_bytes:  int,
}

@(private = "file")
dpic_start :: proc(user: rawptr, surface: u32, items: []Clip_Item, serial: u32, icon: Drag_Icon) -> bool {
	f := (^Dpic_Fake)(user)
	f.started += 1
	f.icon_size, f.icon_offset, f.icon_scale, f.icon_bytes = icon.size, icon.offset, icon.scale, len(icon.pixels)
	return serial != 0
}

@(private = "file")
Dpic_Fx :: struct {
	te:   Text_Engine,
	ui:   Ui(Dpic_Msg),
	fake: Dpic_Fake,
	row:  Node,
}

@(private = "file")
dpic_open :: proc(fx: ^Dpic_Fx, t: ^testing.T, scale: f32 = 1) {
	if !text_engine_init(&fx.te) do testing.fail_now(t, "text_engine_init: embedded fonts failed to load")
	ui_init(&fx.ui)
	fx.ui.tree.text = &fx.te
	fx.ui.surface.scale = scale
	fx.ui.dnd = {user = &fx.fake, surface = 1, start = dpic_start}
}

@(private = "file")
dpic_close :: proc(fx: ^Dpic_Fx) {
	ui_destroy(&fx.ui)
	text_engine_destroy(&fx.te)
}

// dpic_build puts up a window with one draggable row, named `name` and
// standing for `count` files.
@(private = "file")
dpic_build :: proc(fx: ^Dpic_Fx, name := "row.txt", count := 1, with_icon := Icon.None, themed := "", pic: ^Image = nil) {
	ui := &fx.ui
	set_viewport(&ui.tree, {400, 300})
	begin_view(ui)
	column(ui, gap = .md, padding = .md)
	fx.row = row(ui, height = 30, width = 200)
	if pic != nil {
		image(ui, pic, width = 24, height = 24)
	} else if themed != "" {
		theme_icon(ui, themed, fallback = with_icon)
	} else if with_icon != .None {
		icon(ui, with_icon)
	}
	text(ui, name)
	end(ui)
	draggable(ui, fx.row, "file", tag = 1, count = count, files = dpic_files)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 300})
	// The ghost fades in when it is created, so a single frame at time
	// zero paints it at nothing and a test reading pixels would find none.
	// Tick past motion.fast so what is drawn is what settles.
	for _ in 1 ..= 4 {
		anim_tick(&ui.tree, ui.tree.now_ms + f64(ui.tree.theme.motion.fast))
		frame(&ui.tree, {400, 300})
	}
}

// dpic_lift presses on the row and moves past the drag threshold.
@(private = "file")
dpic_lift :: proc(fx: ^Dpic_Fx) {
	rd := node_get(&fx.ui.tree, fx.row)
	start := [2]f32{rd.abs.x + 20, rd.abs.y + 10}
	fx.ui.pointer.press_serial = 42
	pointer_button(&fx.ui, .Left, true, start)
	pointer_move(&fx.ui, start + {20, 0})
}

// dpic_alpha_at reads one pixel's alpha out of a straight-RGBA8 picture.
@(private = "file")
dpic_alpha_at :: proc(pix: []u8, size: [2]i32, x, y: int) -> u8 {
	if x < 0 || y < 0 || x >= int(size.x) || y >= int(size.y) do return 0
	i := (y * int(size.x) + x) * 4 + 3
	return pix[i] if i < len(pix) else 0
}

// dpic_ink_count counts the pixels that differ clearly from the chip's own
// background — the text, the icon and the badge, whatever colours the
// theme gives them, in a light theme or a dark one.
@(private = "file")
dpic_ink_count :: proc(pix: []u8, size: [2]i32, from_x := 0) -> int {
	// the chip's background, sampled just inside its left edge at mid height
	bx, by := 2, int(size.y) / 2
	b := (by * int(size.x) + bx) * 4
	if b + 3 >= len(pix) do return 0
	br, bg, bb := int(pix[b]), int(pix[b + 1]), int(pix[b + 2])
	n := 0
	for y in 0 ..< int(size.y) {
		for x in from_x ..< int(size.x) {
			i := (y * int(size.x) + x) * 4
			if i + 3 >= len(pix) do continue
			if pix[i + 3] < 128 do continue // outside the chip, or its soft edge
			d := abs(int(pix[i]) - br) + abs(int(pix[i + 1]) - bg) + abs(int(pix[i + 2]) - bb)
			if d > 60 do n += 1
		}
	}
	return n
}

@(test)
a_drag_leaves_the_window_with_a_picture :: proc(t: ^testing.T) {
	fx: Dpic_Fx
	dpic_open(&fx, t)
	defer dpic_close(&fx)
	dpic_build(&fx)
	dpic_lift(&fx)
	testing.expect(t, fx.ui.drag.active && !fx.ui.drag.compositor, "the drag is up and still ours")

	pic, ok := drag_picture_make(&fx.ui.tree, &fx.ui.drag, 1, context.temp_allocator)
	if !testing.expect(t, ok, "a drag with a name and files must have a picture") do return
	testing.expect(t, pic.size.x > 0 && pic.size.y > 0, "the picture has a size")
	testing.expect_value(t, len(pic.pixels), int(pic.size.x) * int(pic.size.y) * 4)
	testing.expect_value(t, pic.scale, f32(1))

	// Where it sits: the same offset below-right of the pointer that the
	// in-window ghost sits at, so the picture does not jump as the pointer
	// crosses the edge.
	testing.expect_value(t, pic.offset, [2]i32{i32(DRAG_GHOST_OFFSET.x), i32(DRAG_GHOST_OFFSET.y)})

	// What reaches the pixels: a chip with square-ish middle and rounded
	// corners, and the name drawn on it.
	mid := dpic_alpha_at(pic.pixels, pic.size, int(pic.size.x) / 2, int(pic.size.y) / 2)
	corner := dpic_alpha_at(pic.pixels, pic.size, 0, 0)
	testing.expectf(t, mid > 200, "the chip is drawn: its middle pixel has alpha %d", mid)
	testing.expectf(t, corner < 128, "its corners are rounded: the top-left pixel has alpha %d", corner)
	ink := dpic_ink_count(pic.pixels, pic.size)
	testing.expectf(t, ink > 20, "the name is drawn on it: only %d pixels differ from the chip's background", ink)
}

@(test)
the_picture_is_drawn_in_device_pixels :: proc(t: ^testing.T) {
	// A drag out of a 2× window hands over twice the picture, with the
	// scale that says so — otherwise the compositor shows a chip at half
	// the size, or a blurry one scaled up.
	one, two: Dpic_Fx
	dpic_open(&one, t, 1)
	defer dpic_close(&one)
	dpic_build(&one)
	dpic_lift(&one)
	a, ok_a := drag_picture_make(&one.ui.tree, &one.ui.drag, 1, context.temp_allocator)

	dpic_open(&two, t, 2)
	defer dpic_close(&two)
	dpic_build(&two)
	dpic_lift(&two)
	b, ok_b := drag_picture_make(&two.ui.tree, &two.ui.drag, 2, context.temp_allocator)
	if !testing.expect(t, ok_a && ok_b, "both have a picture") do return

	testing.expect_value(t, b.scale, f32(2))
	testing.expectf(t, abs(f32(b.size.y) - f32(a.size.y) * 2) <= 2,
		"at 2x the picture is %d px tall where 1x is %d", b.size.y, a.size.y)
	testing.expectf(t, abs(f32(b.size.x) - f32(a.size.x) * 2) <= 4,
		"at 2x the picture is %d px wide where 1x is %d", b.size.x, a.size.x)
	testing.expect_value(t, b.offset, [2]i32{i32(DRAG_GHOST_OFFSET.x * 2), i32(DRAG_GHOST_OFFSET.y * 2)})
}

@(test)
a_selection_is_counted_on_the_picture :: proc(t: ^testing.T) {
	one, many: Dpic_Fx
	dpic_open(&one, t)
	defer dpic_close(&one)
	dpic_build(&one, count = 1)
	dpic_lift(&one)
	a, ok_a := drag_picture_make(&one.ui.tree, &one.ui.drag, 1, context.temp_allocator)

	dpic_open(&many, t)
	defer dpic_close(&many)
	dpic_build(&many, count = 12)
	dpic_lift(&many)
	b, ok_b := drag_picture_make(&many.ui.tree, &many.ui.drag, 1, context.temp_allocator)
	if !testing.expect(t, ok_a && ok_b, "both have a picture") do return

	testing.expectf(t, b.size.x > a.size.x,
		"a drag of twelve is wider than one of one: %d against %d", b.size.x, a.size.x)
	// …and the badge is really drawn, not just room left for it: the right
	// end of the picture has ink on it where the single file's has none.
	tail := int(a.size.x)
	testing.expectf(t, dpic_ink_count(b.pixels, b.size, tail) > 10,
		"the count is drawn past %d px: %d ink pixels there", tail, dpic_ink_count(b.pixels, b.size, tail))
}

@(test)
a_long_name_is_cut_to_the_chips_width :: proc(t: ^testing.T) {
	fx: Dpic_Fx
	dpic_open(&fx, t)
	defer dpic_close(&fx)
	dpic_build(&fx, name = "A quarterly reconciliation summary for every branch, final revision (3).ods")
	dpic_lift(&fx)
	pic, ok := drag_picture_make(&fx.ui.tree, &fx.ui.drag, 1, context.temp_allocator)
	if !testing.expect(t, ok, "it has a picture") do return
	testing.expectf(t, f32(pic.size.x) <= DRAG_PICTURE_MAX_W + 1,
		"a long name is cut to the chip's ceiling: %d px against %.0f", pic.size.x, DRAG_PICTURE_MAX_W)
	// and the name was long enough to be cut, or this proves nothing
	full := text_lines(&fx.te, fx.ui.drag.name, text_style(&fx.ui.tree.theme, .Label).size, 0)
	testing.expectf(t, len(full) > 0 && full[0].width > DRAG_PICTURE_MAX_W,
		"the name must be wider than the ceiling for this test to mean anything")
}

@(test)
the_ghost_stops_once_the_compositor_has_the_drag :: proc(t: ^testing.T) {
	// The compositor draws the picture over our own window too, so a ghost
	// of ours as well would be the same drag twice — and ours cannot move,
	// because the pointer it followed now belongs to the compositor.
	fx: Dpic_Fx
	dpic_open(&fx, t)
	defer dpic_close(&fx)
	dpic_build(&fx)
	dpic_lift(&fx)

	// Before: the ghost mirrors the row, which is what draws it.
	dpic_build(&fx)
	before := dpic_draws_of(&fx.ui.tree, "row.txt")
	testing.expectf(t, before == 2, "the row is on screen twice before the hand-over — itself and the ghost mirroring it (%d)", before)

	fx.ui.needs_rebuild = false // so the ask below is this hand-over's, not a leftover
	testing.expect(t, drag_leave_window(&fx.ui), "leaving with files: handed over")
	testing.expect(t, fx.ui.drag.compositor)
	testing.expect_value(t, fx.fake.started, 1)
	// The ghost is built by end_view, so the hand-over must ask for a
	// rebuild: a frame alone paints the ghost where it stood when the
	// pointer left. Rebuilding below only when asked is what tests that.
	testing.expect(t, fx.ui.needs_rebuild, "the hand-over asks for the view to be built again")
	testing.expectf(t, fx.fake.icon_bytes > 0 && fx.fake.icon_size.x > 0,
		"the platform was handed the picture: %d bytes, %dx%d", fx.fake.icon_bytes, fx.fake.icon_size.x, fx.fake.icon_size.y)

	if fx.ui.needs_rebuild do dpic_build(&fx)
	after := dpic_draws_of(&fx.ui.tree, "row.txt")
	testing.expectf(t, after == 1, "and once the compositor carries it only the row itself is drawn (%d)", after)

	// The drag is still announced, though: the ghost node is the live
	// region a screen reader is following, and it stays named.
	ghost := dpic_ghost(&fx.ui.tree)
	if testing.expect(t, ghost != NODE_NONE, "the ghost node is still there for the announcement") {
		testing.expect(t, len(node_get(&fx.ui.tree, ghost).access.name) > 0, "and still named")
	}

	// It comes back into the window: still the compositor's to draw.
	testing.expect(t, drag_ext_enter(&fx.ui, {40, 40}, true))
	dpic_build(&fx)
	back := dpic_draws_of(&fx.ui.tree, "row.txt")
	testing.expectf(t, back == 1, "including when the pointer comes back in (%d)", back)
}

// dpic_draws_of counts how many times `str` is drawn over the whole
// window — the row itself, plus once more for every ghost mirroring it.
// Counting `Draw_Layer`s does not work: `flatten_layer` inlines a layer's
// commands where it is drawn, so no Draw_Layer is left to find.
@(private = "file")
dpic_draws_of :: proc(t: ^Tree, str: string) -> int {
	n := 0
	for c in draw_list(t) {
		if tx, ok := c.(Draw_Text); ok && tx.str == str do n += 1
	}
	return n
}

@(private = "file")
dpic_ghost :: proc(t: ^Tree) -> Node {
	for c := node_first(t, t.overlay); c != NODE_NONE; c = node_next(t, c) {
		if node_get(t, c).key == DRAG_GHOST_KEY do return c
	}
	return NODE_NONE
}

@(test)
a_drag_still_leaves_a_window_with_no_text_engine :: proc(t: ^testing.T) {
	// Headless, and every backend that cannot show a picture: the
	// hand-over is about the files, and it must not come to depend on
	// having drawn one.
	ui: Ui(Dpic_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	fake: Dpic_Fake
	ui.dnd = {user = &fake, surface = 1, start = dpic_start}
	set_viewport(&ui.tree, {400, 300})
	begin_view(&ui)
	n := row(&ui, height = 30, width = 200)
	text(&ui, "row.txt")
	end(&ui)
	draggable(&ui, n, "file", tag = 1, files = dpic_files)
	end_view(&ui)
	frame(&ui.tree, {400, 300})

	rd := node_get(&ui.tree, n)
	start := [2]f32{rd.abs.x + 20, rd.abs.y + 10}
	ui.pointer.press_serial = 42
	pointer_button(&ui, .Left, true, start)
	pointer_move(&ui, start + {20, 0})
	testing.expect(t, drag_leave_window(&ui), "handed over without a picture")
	testing.expect_value(t, fake.started, 1)
	testing.expect_value(t, fake.icon_bytes, 0)

	pic, ok := drag_picture_make(&ui.tree, &ui.drag, 1, context.temp_allocator)
	testing.expect(t, !ok && len(pic.pixels) == 0, "and there is no picture to hand over")
}

@(test)
a_rounded_rect_is_covered_where_it_should_be :: proc(t: ^testing.T) {
	// The chip is drawn on the CPU rather than by the renderer, so its one
	// primitive is worth pinning on its own: inside is covered, outside is
	// not, and a corner is cut by its radius.
	size := [2]i32{40, 20}
	dc := drag_canvas_make(size, context.temp_allocator)
	white := Color{1, 1, 1, 1}
	drag_rrect(&dc, {0, 0, 40, 20}, 6, white, {}, 0)
	pix := drag_canvas_rgba(&dc, context.temp_allocator)
	testing.expect_value(t, dpic_alpha_at(pix, size, 20, 10), 255)       // the middle
	testing.expect_value(t, dpic_alpha_at(pix, size, 0, 0), 0)           // outside the corner's arc
	testing.expect(t, dpic_alpha_at(pix, size, 6, 10) == 255, "inside the left edge")
	testing.expect(t, dpic_alpha_at(pix, size, 6, 1) > 200, "under the top edge, past the corner")
	// On the corner's arc, where coverage is neither nothing nor whole:
	// that is the radius being drawn, and the antialiasing with it. With
	// the radius ignored this pixel is a filled 255 and with the shape
	// missing it is 0.
	edge := dpic_alpha_at(pix, size, 1, 1)
	testing.expectf(t, edge > 0 && edge < 255, "the corner's arc is antialiased, not square or empty (alpha %d)", edge)
}

@(test)
the_sources_icon_comes_with_it :: proc(t: ^testing.T) {
	// A file manager's row is an icon and a name, so the chip has to carry
	// both or it is not the thing that was picked up.
	plain, with: Dpic_Fx
	dpic_open(&plain, t)
	defer dpic_close(&plain)
	dpic_build(&plain)
	dpic_lift(&plain)
	a, ok_a := drag_picture_make(&plain.ui.tree, &plain.ui.drag, 1, context.temp_allocator)

	dpic_open(&with, t)
	defer dpic_close(&with)
	dpic_build(&with, with_icon = .File)
	dpic_lift(&with)
	testing.expect_value(t, with.ui.drag.icon, Icon.File) // the drag found it in the row
	b, ok_b := drag_picture_make(&with.ui.tree, &with.ui.drag, 1, context.temp_allocator)
	if !testing.expect(t, ok_a && ok_b, "both have a picture") do return

	testing.expectf(t, b.size.x > a.size.x,
		"the icon takes room on the chip: %d px wide against %d", b.size.x, a.size.x)
	// …and is drawn there, not merely left room for: the left end of the
	// chip has ink on it, where without an icon it is bare background.
	left := int(ICON_SIZE) + 8
	ink_a := dpic_ink_count(a.pixels, a.size, 0) - dpic_ink_count(a.pixels, a.size, left)
	ink_b := dpic_ink_count(b.pixels, b.size, 0) - dpic_ink_count(b.pixels, b.size, left)
	testing.expectf(t, ink_b > ink_a + 10,
		"the icon is drawn in the chip's first %d px: %d ink pixels there against %d without one", left, ink_b, ink_a)
}

@(test)
a_desktop_theme_icon_is_carried_too :: proc(t: ^testing.T) {
	// A file manager draws the desktop's icon theme, not Lucide, so the
	// drag remembers which icon by name. There is no icon theme in a
	// headless test, so this pins the plumbing: the name is captured, and
	// the icon's own fallback stands in for a Lucide one.
	fx: Dpic_Fx
	dpic_open(&fx, t)
	defer dpic_close(&fx)
	dpic_build(&fx, themed = "text-x-generic", with_icon = .File_Text)
	dpic_lift(&fx)
	testing.expect_value(t, fx.ui.drag.theme_icon, "text-x-generic")
	testing.expect_value(t, fx.ui.drag.icon, Icon.File_Text)
	pic, ok := drag_picture_make(&fx.ui.tree, &fx.ui.drag, 1, context.temp_allocator)
	testing.expect(t, ok && pic.size.x > 0, "and it still draws a picture")
}

@(test)
a_source_carries_its_own_picture :: proc(t: ^testing.T) {
	// A tile that draws an `Image` the app made — a rendered theme icon, a
	// photo's thumbnail — has nothing either icon finder sees, and it is
	// the picture people expect to follow the pointer, so it goes, at the
	// size the window draws it.
	red := make([]u8, 8 * 8 * 4, context.temp_allocator)
	for i in 0 ..< 8 * 8 { red[i * 4], red[i * 4 + 3] = 255, 255 }
	img, made := image_from_rgba(8, 8, red, context.temp_allocator)
	if !testing.expect(t, made, "the test picture was made") do return

	fx: Dpic_Fx
	dpic_open(&fx, t)
	defer dpic_close(&fx)
	dpic_build(&fx, pic = &img)
	dpic_lift(&fx)
	testing.expect(t, fx.ui.drag.picture == &img, "the drag picked up the source's picture")

	pic, ok := drag_picture_make(&fx.ui.tree, &fx.ui.drag, 1, context.temp_allocator)
	if !testing.expect(t, ok, "it has a picture") do return
	// …and it is drawn: the chip carries the red the source showed.
	reds := 0
	for i in 0 ..< int(pic.size.x) * int(pic.size.y) {
		p := pic.pixels[i * 4:]
		if p[3] > 200 && p[0] > 200 && p[1] < 80 && p[2] < 80 do reds += 1
	}
	testing.expectf(t, reds > 100, "the source's own picture is drawn on the chip: %d red pixels", reds)
}

@(test)
a_pictures_box_is_the_one_it_is_drawn_in :: proc(t: ^testing.T) {
	// A list row's little icon must not come over as a 48 px tile, and a
	// tile must not come over as a 16 px one: the picture is carried at
	// the size the window draws it, within the chip's ceiling.
	px := make([]u8, 64 * 64 * 4, context.temp_allocator)
	for i in 0 ..< 64 * 64 { px[i * 4 + 1], px[i * 4 + 3] = 255, 255 }
	img, made := image_from_rgba(64, 64, px, context.temp_allocator)
	if !testing.expect(t, made, "the test picture was made") do return

	small, large: Dpic_Fx
	dpic_open(&small, t)
	defer dpic_close(&small)
	set_viewport(&small.ui.tree, {400, 300})
	begin_view(&small.ui)
	small.row = row(&small.ui, height = 30, width = 200)
	image(&small.ui, &img, width = 16, height = 16)
	text(&small.ui, "row.txt")
	end(&small.ui)
	draggable(&small.ui, small.row, "file", tag = 1, files = dpic_files)
	end_view(&small.ui)
	frame(&small.ui.tree, {400, 300})
	dpic_lift(&small)
	testing.expect_value(t, small.ui.drag.picture_box, f32(16))
	a, ok_a := drag_picture_make(&small.ui.tree, &small.ui.drag, 1, context.temp_allocator)

	dpic_open(&large, t)
	defer dpic_close(&large)
	set_viewport(&large.ui.tree, {400, 300})
	begin_view(&large.ui)
	large.row = row(&large.ui, height = 80, width = 200)
	image(&large.ui, &img, width = 64, height = 64)
	text(&large.ui, "row.txt")
	end(&large.ui)
	draggable(&large.ui, large.row, "file", tag = 1, files = dpic_files)
	end_view(&large.ui)
	frame(&large.ui.tree, {400, 300})
	dpic_lift(&large)
	testing.expect_value(t, large.ui.drag.picture_box, f32(64))
	b, ok_b := drag_picture_make(&large.ui.tree, &large.ui.drag, 1, context.temp_allocator)
	if !testing.expect(t, ok_a && ok_b, "both have a picture") do return

	testing.expectf(t, b.size.y > a.size.y, "the tile's chip is taller than the row's: %d against %d", b.size.y, a.size.y)
	testing.expectf(t, f32(b.size.y) <= DRAG_PICTURE_PIC_MAX + 2 * 8 + 1,
		"and no taller than the ceiling plus its padding: %d", b.size.y)
}

}
