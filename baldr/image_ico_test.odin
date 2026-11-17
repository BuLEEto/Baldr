package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// An icon file holds several sizes and the largest is shown: a PNG inside
// one, a BMP inside another, and the older palette and 24-bit kinds whose
// see-through pixels are a separate 1-bit mask. References are Pillow's
// reading, where a fully transparent pixel's colour is nobody's business.
@(test)
an_icon_file_shows_its_largest_picture :: proc(t: ^testing.T) {
	Case :: struct { name: string, file, want: []u8, w, h: int }
	cases := []Case{
		{"png inside", #load("../assets/test/ico/png.ico"), #load("../assets/test/ico/png.rgba"), 48, 48},
		{"bmp inside", #load("../assets/test/ico/bmp.ico"), #load("../assets/test/ico/bmp.rgba"), 32, 32},
		{"8-bit", #load("../assets/test/ico/pal8.ico"), #load("../assets/test/ico/pal8.rgba"), 13, 5},
		{"4-bit", #load("../assets/test/ico/pal4.ico"), #load("../assets/test/ico/pal4.rgba"), 9, 4},
		{"1-bit", #load("../assets/test/ico/pal1.ico"), #load("../assets/test/ico/pal1.rgba"), 19, 3},
		{"24-bit", #load("../assets/test/ico/rgb24.ico"), #load("../assets/test/ico/rgb24.rgba"), 5, 4},
	}
	for c in cases {
		testing.expectf(t, image_kind(c.file) == "image/vnd.microsoft.icon", "%s is recognised as an icon", c.name)
		img, ok := image_load(c.file)
		if !testing.expectf(t, ok, "%s loads", c.name) do continue
		defer image_destroy(&img)
		if !testing.expectf(t, img.width == c.w && img.height == c.h, "%s is %dx%d: got %dx%d", c.name, c.w, c.h, img.width, img.height) do continue
		bad := 0
		for i in 0 ..< c.w * c.h {
			g, r := img.pixels[i * 4:][:4], c.want[i * 4:][:4]
			if g[3] != r[3] || (r[3] != 0 && string(g[:3]) != string(r[:3])) do bad += 1
		}
		testing.expectf(t, bad == 0, "%s: %d pixels differ", c.name, bad)
	}
}

} // when ODIN_TEST
