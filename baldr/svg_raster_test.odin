package baldr

@(require) import "core:testing"
@(require) import "core:time"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// The bucketed rasteriser must draw what the brute force drew.
@(test)
svg_raster_matches_the_reference_at_every_size :: proc(t: ^testing.T) {
	icons := []Icon{.Folder, .File, .Check, .Circle, .Chevron_Right, .Trash}
	for which in icons do for px in ([]int{16, 24, 40, 64, 128}) {
		scale := f32(px) / 24
		paths := svg_flatten(ICON_PATHS[which], scale, context.temp_allocator)
		fast := svg_raster(paths, px, px, 2 * scale, context.temp_allocator)
		slow := svg_raster_reference(paths, px, px, 2 * scale, context.temp_allocator)
		worst := 0
		for v, i in fast do worst = max(worst, abs(int(v) - int(slow[i])))
		testing.expectf(t, worst <= 1, "%v at %d px: coverage differs by %d", which, px, worst)
	}
}

@(test)
svg_raster_is_fast_for_big_icons :: proc(t: ^testing.T) {
	paths := svg_flatten(ICON_PATHS[.Folder], 128.0 / 24, context.temp_allocator)
	start := time.tick_now()
	for _ in 0 ..< 5 do svg_raster(paths, 128, 128, 2 * 128.0 / 24, context.temp_allocator)
	per := time.duration_milliseconds(time.tick_since(start)) / 5
	testing.expectf(t, per < 20, "a 128 px icon took %.1f ms", per) // the brute force took over 100
}

@(test)
icon_raster_ladder_is_exact_when_small_and_coarse_when_big :: proc(t: ^testing.T) {
	testing.expect_value(t, icon_raster_px(20), 20)
	testing.expect_value(t, icon_raster_px(32), 32)
	testing.expect_value(t, icon_raster_px(33), 40)
	testing.expect_value(t, icon_raster_px(96), 96)
	testing.expect_value(t, icon_raster_px(97), 128)
	testing.expect_value(t, icon_raster_px(300), 256)
	for px in 33 ..= 256 do testing.expect(t, icon_raster_px(px) >= px && f32(icon_raster_px(px)) <= f32(px) * 1.34, "never smaller than asked, at most a third above")
}

} // when ODIN_TEST