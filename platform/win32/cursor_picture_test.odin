#+build windows
package win32

@(require) import "core:testing"

// Runs on Windows: `odin test platform/win32`.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// The channel order and, above all, the alpha: Windows blends a 32-bit icon
// from its alpha channel, so premultiplying would put a dark rim on every
// soft edge, such as a brush outline's.
@(test)
a_cursor_picture_keeps_its_colours_and_its_straight_alpha :: proc(t: ^testing.T) {
	// red, green, blue, and a half-transparent white
	src := []u8{
		255, 0, 0, 255,
		0, 255, 0, 255,
		0, 0, 255, 255,
		255, 255, 255, 128,
	}
	dst := make([]u8, len(src), context.temp_allocator)
	rgba_to_bgra(dst, src)

	want := []u8{
		0, 0, 255, 255,   // red   -> B=0   G=0   R=255
		0, 255, 0, 255,   // green unchanged in the middle
		255, 0, 0, 255,   // blue  -> B=255 G=0   R=0
		255, 255, 255, 128, // white at half alpha, NOT premultiplied to 128,128,128
	}
	for w, i in want {
		testing.expectf(t, dst[i] == w, "byte %d is %d, wanted %d", i, dst[i], w)
	}
	testing.expectf(t, dst[15] == 128, "the alpha was not carried through")
	testing.expectf(t, dst[12] == 255, "the colour was premultiplied; it must stay straight")
}

// A short source must not read past its end: the caller checks the length,
// and this is the belt.
@(test)
a_short_cursor_picture_copies_what_there_is :: proc(t: ^testing.T) {
	src := []u8{1, 2, 3, 4}
	dst := make([]u8, 16, context.temp_allocator)
	rgba_to_bgra(dst, src)
	testing.expect(t, dst[0] == 3 && dst[1] == 2 && dst[2] == 1 && dst[3] == 4)
	testing.expect(t, dst[4] == 0, "nothing beyond the source was written")
}

}
