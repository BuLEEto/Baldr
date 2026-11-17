package main

// Does a new icon read at the size a button gives it?
//
// An icon is one SVG path rasterised into the atlas at the device size it
// is drawn at — 16 logical px in a button or a list, 20 in the gallery's
// grid, 32 for the same 16 on a HiDPI screen. Small is where a picture
// fails: strokes 2 units wide in a 24-unit box land on 1.3 pixels at 16,
// and two shapes a unit apart merge. A test can say the bitmaps differ; it
// cannot say the thing is still recognisable, and a window capture of a
// 16 px icon is 16 px to look at. So this prints the actual rasters, at
// full resolution, the way `icon_slot` makes them.
//
//	./build.sh spike icon_sheet run sparkles wand-sparkles palette star
//	./build.sh spike icon_sheet run --px 16,32 sparkles
//
// Names are as Lucide names them (`ICON_NAMES`); with none given it prints
// the last few in the enum, which are the newest.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "baldr:baldr"

main :: proc() {
	sizes := []int{16, 20, 32}
	args := os.args[1:]
	if len(args) >= 2 && args[0] == "--px" {
		s := make([dynamic]int)
		for f in strings.split(args[1], ",") {
			if n, ok := strconv.parse_int(strings.trim_space(f)); ok do append(&s, n)
		}
		if len(s) > 0 do sizes = s[:]
		args = args[2:]
	}

	wanted := make([dynamic]baldr.Icon)
	if len(args) == 0 {
		for ic in baldr.Icon do if int(ic) > len(baldr.Icon) - 4 do append(&wanted, ic)
	}
	for name in args {
		found := false
		for ic in baldr.Icon do if baldr.ICON_NAMES[ic] == name {
			append(&wanted, ic)
			found = true
		}
		if !found {
			fmt.eprintln("icon_sheet: no icon named", name)
			os.exit(1)
		}
	}

	for ic in wanted {
		fmt.printfln("\n%s (.%v)", baldr.ICON_NAMES[ic], ic)
		for px in sizes do sheet(ic, px)
	}
}

// sheet rasterises one icon exactly as icon_slot does — scale px/24, the
// stroke 2 units wide with it — and prints the coverage as five steps, so
// a stroke that has faded to a third of a pixel still shows as something
// rather than as nothing.
sheet :: proc(ic: baldr.Icon, px: int) {
	scale := f32(px) / 24
	paths := baldr.svg_flatten(baldr.ICON_PATHS[ic], scale)
	bm := baldr.svg_raster(paths, px, px, 2 * scale)
	ink, solid := 0, 0
	for v in bm {
		if v > 128 do ink += 1
		if v > 230 do solid += 1
	}
	fmt.printfln("  %d px — %d of %d inked, %d solid, %d shapes", px, ink, px * px, solid, len(paths))
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for y in 0 ..< px {
		strings.write_string(&b, "  |")
		for x in 0 ..< px {
			v := bm[y * px + x]
			switch {
			case v > 230: strings.write_string(&b, "##")
			case v > 160: strings.write_string(&b, "++")
			case v > 90:  strings.write_string(&b, "..")
			case v > 24:  strings.write_string(&b, " .")
			case:         strings.write_string(&b, "  ")
			}
		}
		strings.write_string(&b, "|\n")
	}
	fmt.print(strings.to_string(b))
}
