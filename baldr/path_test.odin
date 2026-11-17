package baldr

@(require) import "core:math"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them. ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh
// check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Paths into pixels: a lasso into a mask, a shape, a stroke, at any offset
// and any size.


@(private = "file")
cover :: proc(m: ^Mask, x, y: int) -> f32 {
	return f32(mask_at(m, {x, y})) / 255
}

@(private = "file")
total :: proc(m: ^Mask) -> (sum: f32) {
	for v in m.alpha do sum += f32(v) / 255
	return
}

// Each pixel gets the area the shape covers: a rectangle with fractional
// edges shades its edge pixels by how much of them it holds.
@(test)
a_fill_covers_each_pixel_by_its_area :: proc(t: ^testing.T) {
	m, ok := mask_make({0, 0}, {32, 32})
	testing.expect(t, ok)
	defer mask_destroy(&m)
	p := path_make()
	defer path_destroy(&p)
	path_rect(&p, {10.25, 4, 10.5, 8}) // 10.25 → 20.75 across, 4 → 12 down
	path_fill(&p, &m)
	testing.expect_value(t, mask_at(&m, {15, 6}), 255)
	testing.expect(t, abs(cover(&m, 10, 6) - 0.75) < 0.01, "the left edge pixel, three quarters in")
	testing.expect(t, abs(cover(&m, 20, 6) - 0.75) < 0.01, "the right edge pixel, three quarters in")
	testing.expect_value(t, mask_at(&m, {9, 6}), 0)
	testing.expect_value(t, mask_at(&m, {15, 12}), 0)
	testing.expect(t, abs(total(&m) - 10.5 * 8) < 0.1, "the area, whole")

	c, _ := mask_make({0, 0}, {64, 64})
	defer mask_destroy(&c)
	disc := path_make()
	defer path_destroy(&disc)
	path_ellipse(&disc, {32, 32}, {20, 20})
	path_fill(&disc, &c)
	area := f32(math.PI) * 400
	testing.expectf(t, abs(total(&c) - area) <= 2 * f32(math.PI) * 20 * SVG_TOLERANCE, "a disc's area, short only by its curve's flattening: %v of %v", total(&c), area)
}

// The mask sits anywhere in the path's space: a shape far along a big
// document lands in a small mask placed over it, and a mask elsewhere
// gets nothing. Neither is capped at SVG's 4096 a side.
@(test)
a_mask_can_be_anywhere_and_any_size :: proc(t: ^testing.T) {
	p := path_make()
	defer path_destroy(&p)
	path_rect(&p, {5000, 3000, 20, 10})
	near, _ := mask_make({4990, 2995}, {40, 20})
	defer mask_destroy(&near)
	path_fill(&p, &near)
	testing.expect_value(t, mask_at(&near, {5000, 3000}), 255) // its first pixel, in the path's space
	testing.expect_value(t, near.alpha[5 * 40 + 10], 255)      // which is 10, 5 in the mask
	testing.expect_value(t, mask_at(&near, {4999, 3000}), 0)
	testing.expect(t, abs(total(&near) - 200) < 0.1, "all of it")

	far, _ := mask_make({0, 0}, {100, 100})
	defer mask_destroy(&far)
	path_fill(&p, &far)
	testing.expect_value(t, total(&far), 0)

	wide, ok := mask_make({0, 0}, {6000, 4})
	testing.expect(t, ok, "wider than 4096")
	defer mask_destroy(&wide)
	band := path_make()
	defer path_destroy(&band)
	path_rect(&band, {0, 1, 6000, 2})
	path_fill(&band, &wide)
	testing.expect_value(t, mask_at(&wide, {5999, 1}), 255)
	testing.expect_value(t, mask_at(&wide, {4500, 2}), 255)
	testing.expect_value(t, mask_at(&wide, {4500, 0}), 0)

	_, bad := mask_make({0, 0}, {0, 10})
	testing.expect(t, !bad, "no mask of no pixels")
}

// Nonzero fills a square inside a square wound the same way; evenodd
// leaves it a hole. Wound the other way, both leave the hole.
@(test)
fill_rules_decide_a_hole :: proc(t: ^testing.T) {
	for rule in Fill_Rule {
		m, _ := mask_make({0, 0}, {40, 40})
		defer mask_destroy(&m)
		p := path_make()
		defer path_destroy(&p)
		path_rect(&p, {0, 0, 40, 40})
		path_rect(&p, {10, 10, 20, 20}) // the same way round
		path_fill(&p, &m, rule)
		testing.expect_value(t, mask_at(&m, {20, 20}), 255 if rule == .Nonzero else 0)
		testing.expect_value(t, mask_at(&m, {5, 5}), 255)

		back := path_make()
		defer path_destroy(&back)
		path_rect(&back, {0, 0, 40, 40})
		assert(path_svg(&back, "M10 10 V30 H30 V10 Z")) // the other way round
		clear_mask(&m)
		path_fill(&back, &m, rule)
		testing.expect_value(t, mask_at(&m, {20, 20}), 0)
	}
}

@(private = "file")
clear_mask :: proc(m: ^Mask) {
	for &v in m.alpha do v = 0
}

// Without anti-aliasing a pixel is covered or not by its centre.
@(test)
without_antialiasing_a_pixel_is_in_by_its_centre :: proc(t: ^testing.T) {
	m, _ := mask_make({0, 0}, {40, 40})
	defer mask_destroy(&m)
	p := path_make()
	defer path_destroy(&p)
	path_rect(&p, {10.4, 10.6, 10.2, 5}) // x 10.4 → 20.6, y 10.6 → 15.6
	path_rect(&p, {10.6, 20.2, 9.8, 3}) // x 10.6 → 20.4: the edge pixels' centres are outside
	path_ellipse(&p, {30, 30}, {6, 6})
	path_fill(&p, &m, antialias = false)
	for v in m.alpha do testing.expect(t, v == 0 || v == 255, "hard edges only")
	testing.expect_value(t, mask_at(&m, {10, 12}), 255) // centre 10.5 is in
	testing.expect_value(t, mask_at(&m, {20, 12}), 255) // centre 20.5 is in
	testing.expect_value(t, mask_at(&m, {21, 12}), 0)
	testing.expect_value(t, mask_at(&m, {12, 10}), 0)   // centre 10.5 is above 10.6
	testing.expect_value(t, mask_at(&m, {12, 15}), 255) // centre 15.5 is above 15.6
	testing.expect_value(t, mask_at(&m, {12, 16}), 0)
	testing.expect_value(t, mask_at(&m, {10, 21}), 0)  // centre 10.5 is left of 10.6
	testing.expect_value(t, mask_at(&m, {11, 21}), 255)
	testing.expect_value(t, mask_at(&m, {19, 21}), 255)
	testing.expect_value(t, mask_at(&m, {20, 21}), 0)  // centre 20.5 is right of 20.4
}

// The selection modes: add keeps the greater, subtract takes away,
// intersect keeps the overlap and clears the rest, replace keeps only the
// new shape.
@(test)
mask_ops_are_the_selection_modes :: proc(t: ^testing.T) {
	left := path_make()
	defer path_destroy(&left)
	path_rect(&left, {0, 0, 20, 10})
	right := path_make()
	defer path_destroy(&right)
	path_rect(&right, {10, 0, 20, 10})
	at :: proc(m: ^Mask) -> [3]u8 { return {mask_at(m, {5, 5}), mask_at(m, {15, 5}), mask_at(m, {25, 5})} }
	run :: proc(a, b: ^Path, op: Mask_Op) -> [3]u8 {
		m, _ := mask_make({0, 0}, {30, 10})
		defer mask_destroy(&m)
		path_fill(a, &m)
		path_fill(b, &m, op = op)
		return at(&m)
	}
	testing.expect_value(t, run(&left, &right, .Add), [3]u8{255, 255, 255})
	testing.expect_value(t, run(&left, &right, .Subtract), [3]u8{255, 0, 0})
	testing.expect_value(t, run(&left, &right, .Intersect), [3]u8{0, 255, 0})
	testing.expect_value(t, run(&left, &right, .Replace), [3]u8{0, 255, 255})

	twice, _ := mask_make({0, 0}, {40, 40})
	defer mask_destroy(&twice)
	disc := path_make()
	defer path_destroy(&disc)
	path_ellipse(&disc, {20, 20}, {12.3, 12.3})
	path_fill(&disc, &twice)
	once := total(&twice)
	path_fill(&disc, &twice)
	testing.expect_value(t, total(&twice), once) // adding a shape again changes nothing
}

// A stroke is its width about the line; caps and joins as asked; dashes
// break it.
@(test)
a_stroke_follows_its_width_caps_and_dashes :: proc(t: ^testing.T) {
	line := path_make()
	defer path_destroy(&line)
	path_move(&line, {10, 20})
	path_line(&line, {50, 20})

	m, _ := mask_make({0, 0}, {64, 40})
	defer mask_destroy(&m)
	path_stroke(&line, &m, 4)
	testing.expect_value(t, mask_at(&m, {30, 18}), 255)
	testing.expect_value(t, mask_at(&m, {30, 21}), 255)
	testing.expect_value(t, mask_at(&m, {30, 17}), 0)
	testing.expect_value(t, mask_at(&m, {30, 22}), 0)
	testing.expect_value(t, mask_at(&m, {9, 20}), 0) // butt: it stops at the end
	testing.expect(t, abs(total(&m) - 40 * 4) < 0.1, "a 40 × 4 bar")

	clear_mask(&m)
	path_stroke(&line, &m, 4, cap = .Square)
	testing.expect_value(t, mask_at(&m, {8, 20}), 255) // square: half the width past each end
	testing.expect(t, abs(total(&m) - 44 * 4) < 0.1, "a 44 × 4 bar")

	clear_mask(&m)
	path_stroke(&line, &m, 4, dashes = {5, 5})
	testing.expect_value(t, mask_at(&m, {12, 20}), 255) // 10–15 on
	testing.expect_value(t, mask_at(&m, {17, 20}), 0)   // 15–20 off
	testing.expect(t, abs(total(&m) - 20 * 4) < 0.1, "half of it")

	corner := path_make()
	defer path_destroy(&corner)
	path_move(&corner, {10, 30})
	path_line(&corner, {30, 10})
	path_line(&corner, {50, 30})
	miter, _ := mask_make({0, 0}, {64, 40})
	defer mask_destroy(&miter)
	bevel, _ := mask_make({0, 0}, {64, 40})
	defer mask_destroy(&bevel)
	path_stroke(&corner, &miter, 6)
	path_stroke(&corner, &bevel, 6, join = .Bevel)
	testing.expectf(t, mask_at(&miter, {30, 6}) > 128 && mask_at(&bevel, {30, 6}) == 0, "the miter's point (tip at y 5.76), cut off by a bevel (at 7.88): %v, %v", mask_at(&miter, {30, 6}), mask_at(&bevel, {30, 6}))

	nothing, _ := mask_make({0, 0}, {10, 10})
	defer mask_destroy(&nothing)
	for &v in nothing.alpha do v = 255
	path_stroke(&line, &nothing, 0, op = .Replace)
	testing.expect_value(t, total(&nothing), 0) // a stroke of no width replaces the mask with nothing
}

// SVG path data draws what the same moves and lines do; a broken one keeps
// what came before the error and says so.
@(test)
path_svg_reads_path_data :: proc(t: ^testing.T) {
	a := path_make()
	defer path_destroy(&a)
	testing.expect(t, path_svg(&a, "M 4 4 h 20 v 12 h -20 z"))
	b := path_make()
	defer path_destroy(&b)
	path_rect(&b, {4, 4, 20, 12})
	ma, _ := mask_make({0, 0}, {32, 32})
	defer mask_destroy(&ma)
	mb, _ := mask_make({0, 0}, {32, 32})
	defer mask_destroy(&mb)
	path_fill(&a, &ma)
	path_fill(&b, &mb)
	testing.expect(t, string(ma.alpha) == string(mb.alpha), "the same pixels")
	r, ok := path_bounds(&a)
	testing.expect(t, ok && r == Rect{4, 4, 20, 12}, "its bounds")

	broken := path_make()
	defer path_destroy(&broken)
	testing.expect(t, !path_svg(&broken, "M 4 4 h 20 v 12 h -20 z L 1"), "an error")
	_, kept := path_bounds(&broken)
	testing.expect(t, kept, "what came before it is kept")

	zero: Path // the zero value works, with the context's allocator
	defer path_destroy(&zero)
	path_rect(&zero, {0, 0, 2, 2})
	_, zok := path_bounds(&zero)
	testing.expect(t, zok)
}

// image_paint lays a colour through a mask on the stored sRGB values, with
// straight alpha, and marks the part it changed.
@(test)
image_paint_lays_a_colour_through_a_mask :: proc(t: ^testing.T) {
	px := make([]u8, 8 * 8 * 4, context.temp_allocator)
	img, _ := image_from_rgba(8, 8, px)
	defer image_destroy(&img)
	for i in 0 ..< 8 * 4 do copy(img.pixels[i * 4:], []u8{255, 255, 255, 255}) // the top four rows white
	m, _ := mask_make({2, 1}, {4, 4})
	defer mask_destroy(&m)
	for &v in m.alpha do v = 255
	m.alpha[0] = 128
	image_paint(&img, &m, rgb(0xFF0000, 0.5))
	pix :: proc(img: ^Image, x, y: int) -> [4]u8 { return {img.pixels[(y * img.width + x) * 4], img.pixels[(y * img.width + x) * 4 + 1], img.pixels[(y * img.width + x) * 4 + 2], img.pixels[(y * img.width + x) * 4 + 3]} }
	testing.expect_value(t, pix(&img, 3, 1), [4]u8{255, 128, 128, 255}) // half red over white, on the encoded values
	testing.expect_value(t, pix(&img, 3, 4), [4]u8{255, 0, 0, 128})     // over nothing: red, half there
	testing.expect_value(t, pix(&img, 2, 1), [4]u8{255, 191, 191, 255}) // the quarter-covered pixel
	testing.expect_value(t, pix(&img, 1, 1), [4]u8{255, 255, 255, 255}) // outside the mask
	testing.expect_value(t, img.dirty, [4]int{2, 1, 6, 5})

	edge, _ := mask_make({6, 6}, {10, 10}) // hangs off the picture
	defer mask_destroy(&edge)
	for &v in edge.alpha do v = 255
	image_paint(&img, &edge, rgb(0x0000FF))
	testing.expect_value(t, pix(&img, 7, 7), [4]u8{0, 0, 255, 255})
}

} // when ODIN_TEST