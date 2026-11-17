package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Each picture against libwebp's own decoding of it (through Pillow), frame
// by frame, as a PNG with the frames one under another.

@(private = "file")
webp_case :: proc(t: ^testing.T, name: string, file, ref_png: []u8, delays: []u16 = nil) {
	ref, rok := image_load(ref_png)
	if !testing.expectf(t, rok, "%s: the reference loads", name) do return
	defer image_destroy(&ref)
	n := max(len(delays), 1)
	w, h := ref.width, ref.height / n
	img, ok := image_load(file)
	if !testing.expectf(t, ok, "%s loads", name) do return
	defer image_destroy(&img)
	fs := image_frame_size(&img)
	testing.expectf(t, fs == {w, h}, "%s: frames of %dx%d, got %v", name, w, h, fs)
	testing.expectf(t, max(img.frames, 1) == n, "%s: %d frames, got %d", name, n, img.frames)
	if fs != {w, h} || max(img.frames, 1) != n do return
	cols := max(img.cols, 1)
	for k in 0 ..< n {
		cx, cy := (k % cols) * w, (k / cols) * h
		bad, worst, first := 0, 0, -1
		for y in 0 ..< h do for x in 0 ..< w {
			g := img.pixels[((cy + y) * img.width + cx + x) * 4:][:4]
			r := ref.pixels[((k * h + y) * w + x) * 4:][:4]
			if string(g) == string(r) do continue
			bad += 1
			if first < 0 do first = y * w + x
			for c in 0 ..< 4 do worst = max(worst, abs(int(g[c]) - int(r[c])))
		}
		testing.expectf(t, bad == 0, "%s frame %d: %d pixels differ (by up to %d), the first at %d", name, k, bad, worst, first)
	}
	if n > 1 do for d, k in delays do testing.expectf(t, img.delays[k] == d, "%s frame %d shows for %d ms, got %d", name, k, d, img.delays[k])
}

@(test)
a_lossless_webp_decodes_exactly :: proc(t: ^testing.T) {
	webp_case(t, "lossless", #load("../assets/test/webp/lossless.webp"), #load("../assets/test/webp/lossless.png"))
	webp_case(t, "lossless_odd", #load("../assets/test/webp/lossless_odd.webp"), #load("../assets/test/webp/lossless_odd.png"))
	webp_case(t, "lossless_palette", #load("../assets/test/webp/lossless_palette.webp"), #load("../assets/test/webp/lossless_palette.png"))
	// frames blended and written over, rectangles cleared after showing
	webp_case(t, "anim_lossless", #load("../assets/test/webp/anim_lossless.webp"), #load("../assets/test/webp/anim_lossless.png"), {50, 50, 50, 50, 50, 50})
	webp_case(t, "anim_mixed", #load("../assets/test/webp/anim_mixed.webp"), #load("../assets/test/webp/anim_mixed.png"), {50, 50, 50, 50, 50, 50})
	// written by hand, because an encoder steers around it: translucent
	// pixels blended over opaque ones, over translucent ones, over a
	// rectangle cleared to transparent, and written over without blending
	webp_case(t, "blend", #load("../assets/test/webp/blend.webp"), #load("../assets/test/webp/blend.png"), {40, 40, 40, 40, 40})
}

@(test)
a_lossy_webp_decodes_as_libwebp_does :: proc(t: ^testing.T) {
	webp_case(t, "lossy", #load("../assets/test/webp/lossy.webp"), #load("../assets/test/webp/lossy.png"))
	webp_case(t, "lossy_q20", #load("../assets/test/webp/lossy_q20.webp"), #load("../assets/test/webp/lossy_q20.png"))
	webp_case(t, "lossy_q95", #load("../assets/test/webp/lossy_q95.webp"), #load("../assets/test/webp/lossy_q95.png"))
	// alpha beside the colour: losslessly coded, quantised, and through each filter
	webp_case(t, "alpha", #load("../assets/test/webp/alpha.webp"), #load("../assets/test/webp/alpha.png"))
	webp_case(t, "alpha_q50", #load("../assets/test/webp/alpha_q50.webp"), #load("../assets/test/webp/alpha_q50.png"))
	webp_case(t, "alpha_m0", #load("../assets/test/webp/alpha_m0.webp"), #load("../assets/test/webp/alpha_m0.png"))
	webp_case(t, "filter1", #load("../assets/test/webp/filter1.webp"), #load("../assets/test/webp/filter1.png"))
	webp_case(t, "filter2", #load("../assets/test/webp/filter2.webp"), #load("../assets/test/webp/filter2.png"))
	webp_case(t, "filter3", #load("../assets/test/webp/filter3.webp"), #load("../assets/test/webp/filter3.png"))
	// a delay of 0 is shown for 100 ms, as browsers do
	webp_case(t, "anim", #load("../assets/test/webp/anim.webp"), #load("../assets/test/webp/anim.png"), {60, 80, 100, 40, 100, 70})
}

} // when ODIN_TEST
