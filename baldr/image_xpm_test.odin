package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: behind this `when`, checking a program costs
// 1.0 GB instead of 9.2 GB. ODIN_TEST is set by `odin test`; BALDR_TESTS
// lets ./build.sh check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
xpm_test_px :: proc(img: Image, x, y: int) -> [4]u8 {
	i := (y * img.width + x) * 4
	return {img.pixels[i], img.pixels[i + 1], img.pixels[i + 2], img.pixels[i + 3]}
}

@(test)
xpm_pictures_decode :: proc(t: ^testing.T) {
	src := `/* XPM */
static char * test_xpm[] = {
/* width height colours chars-per-pixel */
"3 2 6 2",
".. c None",
"rr c #FF0000",
"gg s green_symbol c green",
"bb m white c #00F",
"ll c light gray",
"x5 g4 grey50 m black",
/* pixels */
"rr..gg",
"bbllx5"};`
	img, ok := image_load_xpm(transmute([]u8)src, context.temp_allocator)
	testing.expect(t, ok && img.width == 3 && img.height == 2, "a 3 × 2 picture")
	if !ok do return
	testing.expect_value(t, xpm_test_px(img, 0, 0), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, xpm_test_px(img, 1, 0), [4]u8{0, 0, 0, 0}) // None
	testing.expect_value(t, xpm_test_px(img, 2, 0), [4]u8{0, 128, 0, 255}) // a CSS name after a symbolic one
	testing.expect_value(t, xpm_test_px(img, 0, 1), [4]u8{0, 0, 255, 255}) // `c` over `m`, one digit a channel
	testing.expect_value(t, xpm_test_px(img, 1, 1), [4]u8{0xd3, 0xd3, 0xd3, 255}) // a name in two words
	testing.expect_value(t, xpm_test_px(img, 2, 1), [4]u8{128, 128, 128, 255}) // no `c`: the grey level
	deep, deep_ok := image_load_xpm(transmute([]u8)string(`"1 1 1 1", "a c #FFFF80800000", "a"`), context.temp_allocator)
	testing.expect(t, deep_ok && xpm_test_px(deep, 0, 0) == [4]u8{255, 128, 0, 255}, "four digits a channel")
	for bad in ([]string{`"2 2 1 1", "a c #000", "aa"`, `"0 1 1 1", "a c #000", ""`, `no strings`, `"2 1 1 9", "a c #000", "aa"`}) {
		_, bad_ok := image_load_xpm(transmute([]u8)bad, context.temp_allocator)
		testing.expectf(t, !bad_ok, "%q is refused", bad)
	}
}

@(test)
argb32_pixmaps_convert :: proc(t: ^testing.T) {
	bytes := []u8{255, 255, 0, 0, 128, 0, 0, 255} // opaque red; blue at half alpha
	img, ok := image_from_argb32_be(2, 1, bytes, context.temp_allocator)
	testing.expect(t, ok, "converted")
	if !ok do return
	testing.expect_value(t, xpm_test_px(img, 0, 0), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, xpm_test_px(img, 1, 0), [4]u8{0, 0, 255, 128})
	_, short := image_from_argb32_be(2, 2, bytes, context.temp_allocator)
	testing.expect(t, !short, "too few bytes for the size")
}

} // when ODIN_TEST