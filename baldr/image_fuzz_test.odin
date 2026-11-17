package baldr

@(require) import "core:mem"
@(require) import "core:testing"
@(require) import "core:time"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A picture from a stranger may be anything. Thousands of corrupt copies of
// each sample (bytes changed, runs set to 0xFF or 0x00, cut short at every
// length) must each decode or be refused: never a crash (bounds checks are
// on), never a hang, and nothing left allocated.
@(test)
a_corrupt_picture_is_refused_not_trusted :: proc(t: ^testing.T) {
	samples := [][]u8{
		#load("../assets/test/gif/still.gif"), #load("../assets/test/gif/anim.gif"),
		#load("../assets/test/gif/alpha.gif"), #load("../assets/test/gif/restore.gif"),
		#load("../assets/test/ico/png.ico"), #load("../assets/test/ico/bmp.ico"),
		#load("../assets/test/ico/pal8.ico"), #load("../assets/test/ico/pal1.ico"),
		#load("../assets/test/exif/o6.jpg"),
		#load("../assets/test/webp/lossy.webp"), #load("../assets/test/webp/lossless.webp"),
		#load("../assets/test/webp/lossless_palette.webp"), #load("../assets/test/webp/alpha.webp"),
		#load("../assets/test/webp/filter3.webp"), #load("../assets/test/webp/anim.webp"),
		#load("../assets/test/webp/anim_lossless.webp"), #load("../assets/test/webp/blend.webp"),
	}
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	r := u64(0x2545F4914F6CDD1D)
	next :: proc(r: ^u64, n: int) -> int {
		r^ ~= r^ << 13
		r^ ~= r^ >> 7
		r^ ~= r^ << 17
		return int(r^ % u64(max(n, 1)))
	}
	slowest: f64
	decoded := 0
	for s, si in samples {
		bad := make([]u8, len(s)) // not temporary: that is cleared each round, under the bytes being read
		defer delete(bad)
		rounds := 1500 + len(s) // every cut, and changes besides
		for round in 0 ..< rounds {
			copy(bad, s)
			n := len(s)
			if round < len(s) {
				n = round // cut short here
			} else {
				switch round % 3 {
				case 0: for _ in 0 ..< 1 + next(&r, 6) do bad[next(&r, n)] = u8(next(&r, 256))
				case 1:
					at := next(&r, n)
					for i in at ..< min(n, at + 1 + next(&r, 8)) do bad[i] = 0xFF
				case 2:
					at := next(&r, n)
					for i in at ..< min(n, at + 1 + next(&r, 8)) do bad[i] = 0
				}
			}
			start := time.tick_now()
			img, ok := image_load(bad[:n], alloc, max_pixels = 4 * 1024 * 1024)
			if ok {
				decoded += 1
				image_destroy(&img)
			}
			slowest = max(slowest, time.duration_milliseconds(time.tick_since(start)))
			free_all(context.temp_allocator)
			if len(track.allocation_map) > 0 {
				testing.expectf(t, false, "sample %d round %d left %d allocations", si, round, len(track.allocation_map))
				return
			}
		}
	}
	// most single changes land in pixel data, so many copies still decode:
	// the test reaches the decoders, not only the checks in front of them
	testing.expectf(t, decoded > 1000, "corrupt copies that still decoded: %d", decoded)
	testing.expectf(t, slowest < 500, "each one is decided at once: the slowest took %.1f ms", slowest)
}

} // when ODIN_TEST
