package baldr

@(require) import "core:testing"

// An animated picture runs itself. The app decodes the frames (so an
// attachment decrypted in memory never touches disk) and hands them over;
// the toolkit runs them while they are on screen and stops when they are
// not, with no message and no view rebuilt per frame.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Ia_Msg :: union { int }

// A tiny animation: three 2×2 frames, each a flat colour, 40/60/100 ms.
@(private = "file")
ia_make :: proc() -> Image {
	f0 := []u8{255,0,0,255, 255,0,0,255, 255,0,0,255, 255,0,0,255}
	f1 := []u8{0,255,0,255, 0,255,0,255, 0,255,0,255, 0,255,0,255}
	f2 := []u8{0,0,255,255, 0,0,255,255, 0,0,255,255, 0,0,255,255}
	img, _ := image_from_rgba_frames(2, 2, [][]u8{f0, f1, f2}, []int{40, 60, 100})
	return img
}

@(private = "file")
ia_build :: proc(ui: ^Ui(Ia_Msg), img: ^Image, offscreen := false) -> Node {
	set_viewport(&ui.tree, {200, 200})
	begin_view(ui)
	column(ui, padding = .none)
	if offscreen do box(ui, height = 400, key = 9) // pushes the picture past the bottom
	n := image(ui, img, width = 40, height = 40, key = 1)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {200, 200})
	return n
}

// The frames go into one picture as a grid, so a frame is a source
// rectangle of a texture uploaded once, not an upload every 40 ms, and
// the texture stays inside what a GPU will take.
@(test)
frames_become_one_grid_with_their_delays :: proc(t: ^testing.T) {
	img := ia_make()
	defer image_destroy(&img)
	// three 2x2 frames go into a 2x2 grid: 4x4, not a 2x6 column
	testing.expect_value(t, img.width, 4)
	testing.expect_value(t, img.height, 4)
	testing.expect_value(t, img.cols, 2)
	testing.expect_value(t, img.frames, 3)
	testing.expect_value(t, len(img.delays), 3)
	testing.expect_value(t, img.delays[0], u16(40))
	testing.expect_value(t, len(img.pixels), 4 * 4 * 4)
	testing.expect_value(t, img.pixels[0], u8(255))             // frame 0, at 0,0: red
	testing.expect_value(t, img.pixels[2 * 4 + 1], u8(255))     // frame 1, at 2,0: green
	testing.expect_value(t, img.pixels[2 * 4 * 4 + 2], u8(255)) // frame 2, at 0,2: blue

	// …and the rectangles follow the grid, left to right then down
	testing.expect_value(t, image_frame_rect(&img, 0), Rect{0, 0, 2, 2})
	testing.expect_value(t, image_frame_rect(&img, 1), Rect{2, 0, 2, 2})
	testing.expect_value(t, image_frame_rect(&img, 2), Rect{0, 2, 2, 2})

	// a delay of 0 means "as fast as possible" in old GIFs: read as 100 ms
	one := []u8{1,2,3,4}
	z, ok := image_from_rgba_frames(1, 1, [][]u8{one, one}, []int{0, 5})
	defer image_destroy(&z)
	testing.expect(t, ok)
	testing.expect_value(t, z.delays[0], u16(100))
	testing.expect_value(t, z.delays[1], u16(20)) // …and nothing faster than 20

	// one frame is just a picture, with no animation machinery at all
	sgl, _ := image_from_rgba_frames(1, 1, [][]u8{one}, []int{40})
	defer image_destroy(&sgl)
	testing.expect_value(t, sgl.frames, 0)
	testing.expect_value(t, sgl.height, 1)

	bad, bad_ok := image_from_rgba_frames(1, 1, [][]u8{one, one}, []int{40}) // delays do not match
	testing.expect(t, !bad_ok)
	testing.expect(t, bad.pixels == nil, "and nothing was allocated for it")
}

// Its natural size is one frame, not the whole strip.
@(test)
an_animation_is_laid_out_as_one_frame :: proc(t: ^testing.T) {
	img := ia_make()
	defer image_destroy(&img)
	ui: Ui(Ia_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	set_viewport(&ui.tree, {200, 200})
	begin_view(&ui)
	column(&ui, padding = .none)
	n := image(&ui, &img, key = 1) // no size given: its own pixels
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {200, 200})

	d := node_get(&ui.tree, n)
	testing.expect_value(t, d.rect.w, f32(2))
	testing.expect_value(t, d.rect.h, f32(2)) // one frame, not the 6-tall strip
	testing.expect_value(t, ui.tree.pictures[n].source, Rect{0, 0, 2, 2})
}

// `anim_tick` advances the frame and marks the paint dirty; the view is not
// built again, and the app hears nothing.
@(test)
an_animation_advances_without_a_rebuild :: proc(t: ^testing.T) {
	img := ia_make()
	defer image_destroy(&img)
	ui: Ui(Ia_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := ia_build(&ui, &img)

	start := ui.tree.now_ms
	testing.expect_value(t, ui.tree.pictures[n].frame, 0)

	ui.needs_rebuild = false
	clear(&ui.msgs)
	active := anim_tick(&ui.tree, start + 50) // into frame 1 (40 ms in)
	testing.expect(t, active, "an animation on screen keeps the frames coming")
	testing.expect_value(t, ui.tree.pictures[n].frame, 1)
	testing.expect_value(t, ui.tree.pictures[n].source, Rect{2, 0, 2, 2}) // frame 1 is to the right in the grid
	testing.expect(t, !ui.needs_rebuild, "and the view is NOT built again")
	testing.expect_value(t, len(ui.msgs), 0) // nor is the app told anything

	anim_tick(&ui.tree, start + 110) // 40 + 60: frame 2
	testing.expect_value(t, ui.tree.pictures[n].frame, 2)
	anim_tick(&ui.tree, start + 215) // 200 is one loop: back to frame 0
	testing.expect_value(t, ui.tree.pictures[n].frame, 0)
}

// Off screen it costs nothing: not stepped, and no frame asked for.
@(test)
an_animation_off_screen_is_not_stepped :: proc(t: ^testing.T) {
	img := ia_make()
	defer image_destroy(&img)
	ui: Ui(Ia_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := ia_build(&ui, &img, offscreen = true)

	d := node_get(&ui.tree, n)
	testing.expectf(t, d.abs.y >= ui.tree.viewport.y, "the picture is below the fold (%.0f)", d.abs.y)

	start := ui.tree.now_ms
	active := anim_tick(&ui.tree, start + 500)
	testing.expect(t, !active, "it asks for no frames")
	testing.expect_value(t, ui.tree.pictures[n].frame, 0) // and has not moved
}

// Reduce-motion means it does not move: frame 0 stands.
@(test)
reduce_motion_holds_an_animation_on_its_first_frame :: proc(t: ^testing.T) {
	img := ia_make()
	defer image_destroy(&img)
	ui: Ui(Ia_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tree_a11y_prefs(&ui.tree, A11y_Prefs{reduce_motion = true})
	n := ia_build(&ui, &img)

	start := ui.tree.now_ms
	testing.expect(t, !anim_tick(&ui.tree, start + 500), "nothing is asked for")
	testing.expect_value(t, ui.tree.pictures[n].frame, 0)
	testing.expect_value(t, ui.tree.pictures[n].source, Rect{0, 0, 2, 2})
}

// A rebuild does not restart it: scrolling a chat, or typing beside it,
// must not send every GIF back to frame 0.
@(test)
a_rebuild_does_not_restart_an_animation :: proc(t: ^testing.T) {
	img := ia_make()
	defer image_destroy(&img)
	ui: Ui(Ia_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := ia_build(&ui, &img)
	start := ui.tree.now_ms

	anim_tick(&ui.tree, start + 110)
	testing.expect_value(t, ui.tree.pictures[n].frame, 2)
	was := ui.tree.pictures[n].started_ms

	ia_build(&ui, &img) // the view ran again for some other reason
	testing.expect_value(t, ui.tree.pictures[n].started_ms, was)
	testing.expect_value(t, ui.tree.pictures[n].frame, 2)
	testing.expect_value(t, ui.tree.pictures[n].source, Rect{0, 2, 2, 2}) // second row of the grid
}


// A long animation must not make a texture the GPU will refuse: one column
// of 70 frames at 480x270 is 18,900 px tall, past the 4,096 Vulkan
// promises. An oversized picture falls back to the atlas path, which
// integer-downscales anything over a page, so each frame would be a smudge.
@(test)
a_long_animation_fits_the_gpus_texture_limit :: proc(t: ^testing.T) {
	// one frame's worth of pixels, reused: the content does not matter here
	px := make([]u8, 480 * 270 * 4, context.temp_allocator)
	frames := make([][]u8, 100, context.temp_allocator)
	delays := make([]int, 100, context.temp_allocator)
	for i in 0 ..< 100 {
		frames[i] = px
		delays[i] = 40
	}
	img, ok := image_from_rgba_frames(480, 270, frames, delays)
	defer image_destroy(&img)
	testing.expect(t, ok, "a hundred frames of 480x270 is an ordinary GIF")

	testing.expectf(t, img.width <= IMAGE_GRID_MAX_SIDE && img.height <= IMAGE_GRID_MAX_SIDE,
		"the texture is within what every conformant device allows: %dx%d (limit %d)",
		img.width, img.height, IMAGE_GRID_MAX_SIDE)
	testing.expectf(t, img.frames == 100, "and every frame was kept (%d)", img.frames)
	testing.expectf(t, img.width > 1022 || img.height > 1022, "it is still a big picture, as it should be")
}

// When even a grid cannot hold them all, every k-th frame is kept and the
// delays of the dropped ones are added to the one before, so a three
// second GIF still takes three seconds: it loses smoothness rather than
// sharpness, and is never a downscaled strip.
@(test)
frames_past_the_limit_are_dropped_not_downscaled :: proc(t: ^testing.T) {
	// 1280x720 at the guaranteed 4096 takes 3 across and 5 down: 15 frames
	px := make([]u8, 1280 * 720 * 4, context.temp_allocator)
	N :: 26
	frames := make([][]u8, N, context.temp_allocator)
	delays := make([]int, N, context.temp_allocator)
	total := 0
	for i in 0 ..< N {
		frames[i] = px
		delays[i] = 40
		total += 40
	}
	img, ok := image_from_rgba_frames(1280, 720, frames, delays)
	defer image_destroy(&img)
	testing.expect(t, ok)
	testing.expectf(t, img.width <= IMAGE_GRID_MAX_SIDE && img.height <= IMAGE_GRID_MAX_SIDE,
		"it still fits: %dx%d", img.width, img.height)
	testing.expectf(t, img.frames < N, "some frames were dropped (%d of %d)", img.frames, N)
	testing.expect_value(t, img.frames, 15)

	// and the whole thing still runs to the same length
	kept := 0
	for d in img.delays do kept += int(d)
	testing.expectf(t, abs(kept - total) <= 20, "the timing is kept: %d ms against %d", kept, total)

	// the frames are full size: a cell is one frame's own pixels
	r := image_frame_rect(&img, 0)
	testing.expect_value(t, r.w, f32(1280))
	testing.expect_value(t, r.h, f32(720))

	// an app that knows its device keeps the lot
	big, big_ok := image_from_rgba_frames(1280, 720, frames, delays, max_side = 16384)
	defer image_destroy(&big)
	testing.expect(t, big_ok)
	testing.expect_value(t, big.frames, N)
}

// A frame too big for the limit on its own cannot be helped: it is refused
// rather than quietly shrunk.
@(test)
a_frame_larger_than_the_limit_is_refused :: proc(t: ^testing.T) {
	px := make([]u8, 8 * 8 * 4, context.temp_allocator)
	frames := [][]u8{px, px}
	delays := []int{40, 40}
	img, ok := image_from_rgba_frames(8, 8, frames, delays, max_side = 4)
	testing.expect(t, !ok, "one frame does not fit, so there is nothing to make")
	testing.expect(t, img.pixels == nil, "and nothing was allocated")
}

// `width` and `height` are the whole grid, so an app sizing a bubble needs
// one frame's size; `height / frames` gives 35 px for 100 frames of
// 480x270, not 270. The grid arithmetic is the toolkit's to own.
@(test)
an_animation_reports_one_frames_size :: proc(t: ^testing.T) {
	px := make([]u8, 480 * 270 * 4, context.temp_allocator)
	frames := make([][]u8, 100, context.temp_allocator)
	delays := make([]int, 100, context.temp_allocator)
	for i in 0 ..< 100 {
		frames[i] = px
		delays[i] = 40
	}
	img, _ := image_from_rgba_frames(480, 270, frames, delays)
	defer image_destroy(&img)

	testing.expect_value(t, image_frame_size(&img), [2]int{480, 270})
	testing.expectf(t, img.height / img.frames != 270,
		"and the old arithmetic really is wrong now (%d)", img.height / img.frames)
	testing.expect_value(t, image_frame_rows(&img), 13)

	// it agrees with where the frames actually are
	r := image_frame_rect(&img, 0)
	testing.expect_value(t, [2]int{int(r.w), int(r.h)}, image_frame_size(&img))
	last := image_frame_rect(&img, img.frames - 1)
	testing.expect(t, last.x + last.w <= f32(img.width), "the last frame is inside the grid")
	testing.expect(t, last.y + last.h <= f32(img.height), "…in both directions")

	// a still picture answers its own size, so an app need not ask whether
	// what it holds is animated
	one := []u8{1, 2, 3, 4}
	sgl, _ := image_from_rgba(1, 1, one)
	defer image_destroy(&sgl)
	testing.expect_value(t, image_frame_size(&sgl), [2]int{1, 1})
	testing.expect_value(t, image_frame_rows(&sgl), 1)
	testing.expect_value(t, image_frame_size(nil), [2]int{})
}

}
