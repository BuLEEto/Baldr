package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// The references are the frames as a browser shows them: made by Pillow,
// read back by Pillow where it agrees with browsers, and written by hand for
// the cases it does not (it grows the canvas for a frame hanging off it,
// where browsers clip the frame).

// grid_frame copies frame `k` out of an animation's grid.
@(private = "file")
grid_frame :: proc(img: ^Image, k: int) -> []u8 {
	fs := image_frame_size(img)
	w, h := fs.x, fs.y
	out := make([]u8, w * h * 4, context.temp_allocator)
	cx, cy := (k % max(img.cols, 1)) * w, (k / max(img.cols, 1)) * h
	for y in 0 ..< h do copy(out[y * w * 4:(y + 1) * w * 4], img.pixels[((cy + y) * img.width + cx) * 4:][:w * 4])
	return out
}

@(private = "file")
gif_case :: proc(t: ^testing.T, name: string, file, want: []u8, w, h: int, delays: []u16) {
	img, ok := image_load(file)
	if !testing.expectf(t, ok, "%s loads", name) do return
	defer image_destroy(&img)
	n := max(len(delays), 1)
	fs := image_frame_size(&img)
	testing.expectf(t, fs == {w, h}, "%s: frames of %dx%d, got %v", name, w, h, fs)
	testing.expectf(t, max(img.frames, 1) == n, "%s: %d frames, got %d", name, n, img.frames)
	if fs != {w, h} || max(img.frames, 1) != n do return
	for k in 0 ..< n {
		got := grid_frame(&img, k) if n > 1 else img.pixels
		ref := want[k * w * h * 4:(k + 1) * w * h * 4]
		bad := 0
		first := -1
		for i in 0 ..< w * h do if string(got[i * 4:i * 4 + 4]) != string(ref[i * 4:i * 4 + 4]) {
			bad += 1
			if first < 0 do first = i
		}
		testing.expectf(t, bad == 0, "%s frame %d: %d pixels differ, the first at %d: %v, wanted %v", name, k, bad, first,
			got[max(first, 0) * 4:][:4], ref[max(first, 0) * 4:][:4])
	}
	if n > 1 do for d, k in delays do testing.expectf(t, img.delays[k] == d, "%s frame %d shows for %d ms, got %d", name, k, d, img.delays[k])
}

@(test)
a_gif_decodes_as_a_browser_shows_it :: proc(t: ^testing.T) {
	// interlaced, 200 colours
	gif_case(t, "still", #load("../assets/test/gif/still.gif"), #load("../assets/test/gif/still.rgba"), 37, 23, nil)
	// frames 2 on are the rectangle that changed, over a transparent colour;
	// a delay of 0 is shown for 100 ms, as every decoder does
	gif_case(t, "anim", #load("../assets/test/gif/anim.gif"), #load("../assets/test/gif/anim.rgba"), 40, 30, {40, 120, 100, 20, 70})
	// transparent frames, each cleared before the next (disposal 2)
	gif_case(t, "alpha", #load("../assets/test/gif/alpha.gif"), #load("../assets/test/gif/alpha.rgba"), 24, 18, {50, 50, 50, 50})
	// a box put back as it was (disposal 3), then a frame half off the canvas
	gif_case(t, "restore", #load("../assets/test/gif/restore.gif"), #load("../assets/test/gif/restore.rgba"), 12, 8, {100, 100, 100, 100})
}

// A GIF with more frames than its grid holds keeps every k-th, and the
// animation still takes as long as it did.
@(test)
a_long_gif_keeps_what_fits_and_its_length :: proc(t: ^testing.T) {
	// 1000 x 800 frames: twenty fit a 4,096 grid. Each frame is one pixel,
	// coded as a clear, the pixel and the end.
	W, H, N :: 1000, 800, 50
	b := make([dynamic]u8, context.temp_allocator)
	append(&b, "GIF89a")
	append(&b, u8(W & 255), u8(W >> 8), u8(H & 255), u8(H >> 8), 0x81, 0, 0)
	append(&b, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255) // four colours
	for k in 0 ..< N {
		append(&b, 0x21, 0xF9, 4, 0, 3, 0, 0, 0) // 30 ms
		x := k % W
		append(&b, 0x2C, u8(x & 255), u8(x >> 8), 0, 0, 1, 0, 1, 0, 0)
		// min code 2: clear (4), pixel 1, end (5), three bits each
		bits := u32(4) | u32(1) << 3 | u32(5) << 6
		append(&b, 2, 2, u8(bits & 255), u8(bits >> 8), 0)
	}
	append(&b, 0x3B)
	img, ok := image_load(b[:])
	if !testing.expect(t, ok, "it loads") do return
	defer image_destroy(&img)
	_, _, keep := image_grid_fit(W, H, N, IMAGE_GRID_MAX_SIDE)
	testing.expectf(t, img.frames == keep, "the %d frames that fit are kept: %d", keep, img.frames)
	total := 0
	for d in img.delays do total += int(d)
	testing.expectf(t, total == N * 30, "and it still runs %d ms: %d", N * 30, total)
	testing.expect(t, image_frame_size(&img) == {W, H}, "each frame the canvas's size")
}

// A picture pasted from another program arrives in whatever form it offers:
// a GIF or an icon is read as one (an animated GIF stays animated), and PNG
// is still taken first when it is offered beside them.
@(test)
a_pasted_gif_or_icon_is_read :: proc(t: ^testing.T) {
	img, ok := picture_decode("image/gif", #load("../assets/test/gif/anim.gif"), context.allocator)
	testing.expect(t, ok && img.frames == 5, "a pasted GIF keeps its frames")
	if ok do image_destroy(&img)
	ico, iok := picture_decode("image/x-icon", #load("../assets/test/ico/pal8.ico"), context.allocator)
	testing.expect(t, iok && ico.width == 13, "a pasted icon is read")
	if iok do image_destroy(&ico)
	testing.expect_value(t, picture_form({"image/gif", "image/png"}), "image/png")
	testing.expect_value(t, picture_form({"text/plain", "image/webp"}), "image/webp")
}

} // when ODIN_TEST
