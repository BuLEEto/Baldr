package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them. ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh
// check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Pictures written as PNG, read back exactly by Odin's own decoder.


@(private = "file")
round_trip :: proc(t: ^testing.T, img: ^Image, what: string) -> int {
	png, ok := image_encode_png(img, context.temp_allocator)
	testing.expectf(t, ok, "%s: encoded", what)
	back, read := image_load(png, context.temp_allocator)
	testing.expectf(t, read, "%s: decoded", what)
	if read {
		testing.expectf(t, back.width == img.width && back.height == img.height, "%s: its size", what)
		testing.expectf(t, string(back.pixels) == string(img.pixels), "%s: every pixel as it was", what)
	}
	return len(png)
}

@(private = "file")
picture :: proc(w, h: int, fill: proc(x, y: int) -> [4]u8) -> Image {
	px := make([]u8, w * h * 4, context.temp_allocator)
	for y in 0 ..< h do for x in 0 ..< w {
		c := fill(x, y)
		copy(px[(y * w + x) * 4:], c[:])
	}
	img, _ := image_from_rgba(w, h, px, context.temp_allocator)
	return img
}

// Flat colour, gradients, noise with and without alpha: each comes back
// pixel for pixel; flat colour shrinks to almost nothing, and noise, which
// cannot shrink, is stored rather than grown.
@(test)
png_round_trips_every_kind_of_picture :: proc(t: ^testing.T) {
	flat := picture(400, 300, proc(x, y: int) -> [4]u8 { return {40, 90, 200, 255} })
	n := round_trip(t, &flat, "flat")
	testing.expectf(t, n < 1500, "flat colour is tiny: %d bytes", n)

	grad := picture(333, 257, proc(x, y: int) -> [4]u8 { return {u8(x), u8(y), u8(x + y), u8(255 - y / 2)} })
	g := round_trip(t, &grad, "gradient with alpha")
	testing.expectf(t, g < 333 * 257 * 4 / 8, "a gradient filters to little: %d bytes", g)

	noise := picture(200, 150, proc(x, y: int) -> [4]u8 {
		v := u32(x * 73856093 ~ y * 19349663) // a hash of the place: noise, the same every run
		v ~= v << 13
		v ~= v >> 17
		v ~= v << 5
		v *= 2654435761
		return {u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)}
	})
	z := round_trip(t, &noise, "noise")
	testing.expectf(t, z < 200 * 150 * 4 * 101 / 100 + 200, "noise is stored, not grown: %d bytes", z)

	// text-like: few colours, long repeats far apart (matches up to the window's end)
	text := picture(1200, 60, proc(x, y: int) -> [4]u8 {
		on := (x / 3 + y / 5) % 7 == 0 || (x * 7 + y * 3) % 23 == 0
		return {20, 20, 20, 255} if on else {250, 250, 250, 255}
	})
	round_trip(t, &text, "text-like")

	tiny := picture(1, 1, proc(x, y: int) -> [4]u8 { return {1, 2, 3, 4} })
	round_trip(t, &tiny, "one pixel")

	bad := Image{width = 10, height = 10}
	_, ok := image_encode_png(&bad)
	testing.expect(t, !ok, "no pixels, no PNG")
}

// An opaque picture is written as RGB, a quarter smaller; one with any
// transparency keeps its alpha.
@(test)
png_drops_alpha_only_when_every_pixel_is_opaque :: proc(t: ^testing.T) {
	opaque := picture(64, 64, proc(x, y: int) -> [4]u8 { return {u8(x * 4), u8(y * 4), 128, 255} })
	png, _ := image_encode_png(&opaque, context.temp_allocator)
	testing.expect_value(t, png[25], 2) // IHDR colour type: RGB
	opaque.pixels[4 * 100 + 3] = 254
	png2, _ := image_encode_png(&opaque, context.temp_allocator)
	testing.expect_value(t, png2[25], 6) // RGBA
	round_trip(t, &opaque, "one pixel not quite opaque")
}

// A PNG is checked before Odin's decoder sees it: one cut short anywhere
// is refused at once (the decoder would run on to 4 GB and past its
// buffer), and sound ones, from other encoders and interlaced, still load.
@(test)
a_png_cut_short_is_refused_before_decoding :: proc(t: ^testing.T) {
	grad := picture(90, 70, proc(x, y: int) -> [4]u8 { return {u8(x * 3), u8(y * 3), u8(x ~ y), u8(200 + x % 50)} })
	png, _ := image_encode_png(&grad, context.temp_allocator)
	testing.expect(t, png_sound(png), "whole")
	for cut in ([]int{len(png) - 13, len(png) - 20, len(png) / 2, 60, 40}) {
		testing.expectf(t, !png_sound(png[:cut]), "cut at %d of %d", cut, len(png))
		_, ok := image_load(png[:cut])
		testing.expectf(t, !ok, "not loaded when cut at %d", cut)
	}
	wrong := make([]u8, len(png), context.temp_allocator)
	copy(wrong, png)
	wrong[19] += 1 // the header's height one more than the pixels
	testing.expect(t, !png_sound(wrong), "a height the data does not fill")

	for sample in ([][]u8{#load("../assets/sample/photo.png"), #load("../assets/sample/avatar.png")}) {
		testing.expect(t, png_sound(sample), "another encoder's PNG")
		_, ok := image_load(sample, context.temp_allocator)
		testing.expect(t, ok, "loads")
	}
	adam7 := #load("../assets/test/adam7.png")
	testing.expect(t, png_sound(adam7), "an interlaced PNG")
	img, ok := image_load(adam7, context.temp_allocator)
	want := #load("../assets/test/adam7.rgba")
	testing.expect(t, ok && img.width == 37 && string(img.pixels) == string(want), "decoded pixel for pixel")
}

} // when ODIN_TEST