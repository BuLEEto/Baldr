package baldr

@(require) import "core:math"
@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
svg_test_render :: proc(t: ^testing.T, svg: string, w, h: int, colors: ^Svg_Colors = nil, loc := #caller_location) -> Image {
	img, ok := svg_render(transmute([]u8)svg, w, h, colors, allocator = context.temp_allocator)
	testing.expect(t, ok, "the document renders", loc = loc)
	return img
}

// svg_test_px is a pixel as RGBA8 (straight alpha).
@(private = "file")
svg_test_px :: proc(img: Image, x, y: int) -> [4]int {
	if img.pixels == nil do return {-1, -1, -1, -1}
	i := (y * img.width + x) * 4
	return {int(img.pixels[i]), int(img.pixels[i + 1]), int(img.pixels[i + 2]), int(img.pixels[i + 3])}
}

@(private = "file")
svg_test_near :: proc(t: ^testing.T, got, want: [4]int, tol: int, what: string, loc := #caller_location) {
	for k in 0 ..< 4 {
		if abs(got[k] - want[k]) > tol {
			testing.expectf(t, false, "%s: got %v, want %v (±%d)", what, got, want, tol, loc = loc)
			return
		}
	}
}

@(private = "file")
svg_test_alpha :: proc(img: Image, x, y: int) -> int {
	return svg_test_px(img, x, y)[3]
}

@(test)
svg_fills_cover_pixels_exactly :: proc(t: ^testing.T) {
	img := svg_test_render(t, `<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect x="2.5" y="2.25" width="5" height="5" fill="#ff0000"/></svg>`, 10, 10)
	svg_test_near(t, svg_test_px(img, 1, 4), {0, 0, 0, 0}, 0, "left of the rect")
	svg_test_near(t, svg_test_px(img, 2, 4), {255, 0, 0, 128}, 1, "half a pixel across")
	svg_test_near(t, svg_test_px(img, 3, 4), {255, 0, 0, 255}, 0, "inside")
	svg_test_near(t, svg_test_px(img, 7, 4), {255, 0, 0, 128}, 1, "the right edge")
	svg_test_near(t, svg_test_px(img, 4, 2), {255, 0, 0, 191}, 1, "three quarters down into row 2")
	svg_test_near(t, svg_test_px(img, 4, 7), {255, 0, 0, 64}, 1, "a quarter into row 7")
	svg_test_near(t, svg_test_px(img, 2, 2), {255, 0, 0, 96}, 1, "the corner: half by three quarters")
}

@(test)
svg_a_circle_covers_its_area :: proc(t: ^testing.T) {
	img := svg_test_render(t, `<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><circle cx="16" cy="16" r="10"/></svg>`, 32, 32)
	sum: f64
	for i in 0 ..< 32 * 32 do sum += f64(img.pixels[i * 4 + 3]) / 255
	want := math.PI * 100
	testing.expectf(t, abs(sum - want) < want * 0.01, "covered %.2f px², want πr² = %.2f", sum, want)
}

@(test)
svg_the_viewbox_fits_the_picture :: proc(t: ^testing.T) {
	doc := `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><rect width="8" height="16"/></svg>`
	img := svg_test_render(t, doc, 32, 32)
	testing.expect_value(t, svg_test_alpha(img, 15, 10), 255)
	testing.expect_value(t, svg_test_alpha(img, 16, 10), 0)
	wide := svg_test_render(t, doc, 64, 32) // the aspect kept, centred (xMidYMid meet)
	testing.expect_value(t, svg_test_alpha(wide, 15, 10), 0)
	testing.expect_value(t, svg_test_alpha(wide, 16, 10), 255)
	testing.expect_value(t, svg_test_alpha(wide, 32, 10), 0)
	stretch := svg_test_render(t, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" preserveAspectRatio="none"><rect width="8" height="16"/></svg>`, 64, 32)
	testing.expect_value(t, svg_test_alpha(stretch, 31, 10), 255)
	testing.expect_value(t, svg_test_alpha(stretch, 32, 10), 0)
	// no viewBox: the width and height scale to the picture
	sized := svg_test_render(t, `<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="5" height="10"/></svg>`, 20, 20)
	testing.expect_value(t, svg_test_alpha(sized, 9, 10), 255)
	testing.expect_value(t, svg_test_alpha(sized, 10, 10), 0)
}

@(test)
svg_fill_rules :: proc(t: ^testing.T) {
	same :: `<path d="M0 0H20V20H0Z M5 5H15V15H5Z"`
	nonzero := svg_test_render(t, `<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20">` + same + `/></svg>`, 20, 20)
	evenodd := svg_test_render(t, `<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20">` + same + ` fill-rule="evenodd"/></svg>`, 20, 20)
	reversed := svg_test_render(t, `<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><path d="M0 0H20V20H0Z M5 5V15H15V5Z"/></svg>`, 20, 20)
	testing.expect_value(t, svg_test_alpha(nonzero, 10, 10), 255)
	testing.expect_value(t, svg_test_alpha(evenodd, 10, 10), 0)
	testing.expect_value(t, svg_test_alpha(reversed, 10, 10), 0)
	for img in ([3]Image{nonzero, evenodd, reversed}) do testing.expect_value(t, svg_test_alpha(img, 2, 10), 255)
}

@(test)
svg_strokes_have_width_and_caps :: proc(t: ^testing.T) {
	line :: proc(t: ^testing.T, cap: string) -> Image {
		doc := strings.concatenate({`<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><path d="M4 10H16" stroke="#000" stroke-width="4" stroke-linecap="`, cap, `"/></svg>`}, context.temp_allocator)
		return svg_test_render(t, doc, 20, 20)
	}
	butt := line(t, "butt")
	testing.expect_value(t, svg_test_alpha(butt, 10, 8), 255)
	testing.expect_value(t, svg_test_alpha(butt, 10, 11), 255)
	testing.expect_value(t, svg_test_alpha(butt, 10, 7), 0)
	testing.expect_value(t, svg_test_alpha(butt, 10, 12), 0)
	testing.expect_value(t, svg_test_alpha(butt, 4, 10), 255)
	testing.expect_value(t, svg_test_alpha(butt, 3, 10), 0)
	square := line(t, "square")
	testing.expect_value(t, svg_test_alpha(square, 2, 10), 255)
	testing.expect_value(t, svg_test_alpha(square, 1, 10), 0)
	testing.expect_value(t, svg_test_alpha(square, 17, 10), 255)
	testing.expect_value(t, svg_test_alpha(square, 18, 10), 0)
	round := line(t, "round")
	edge := svg_test_alpha(round, 2, 10)
	testing.expectf(t, edge > 0 && edge < 255, "the round cap's edge is partly covered: %d", edge)
	testing.expect_value(t, svg_test_alpha(round, 3, 10), 255)
	testing.expect_value(t, svg_test_alpha(round, 1, 10), 0)
}

@(test)
svg_joins_follow_linejoin_and_the_miter_limit :: proc(t: ^testing.T) {
	corner :: proc(t: ^testing.T, attrs: string) -> Image {
		doc := strings.concatenate({`<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><path d="M2 18L10 4L18 18" fill="none" stroke="#000" stroke-width="2" `, attrs, `/></svg>`}, context.temp_allocator)
		return svg_test_render(t, doc, 20, 20)
	}
	// the corner is at y 4; its outer offsets reach y 3.5, a round join y 3, the miter's tip y 1.98
	above :: proc(img: Image) -> int { return svg_test_alpha(img, 9, 2) + svg_test_alpha(img, 10, 2) }
	testing.expect(t, above(corner(t, `stroke-linejoin="miter"`)) > 0, "a miter reaches above the corner")
	testing.expect_value(t, above(corner(t, `stroke-linejoin="bevel"`)), 0)
	testing.expect_value(t, above(corner(t, `stroke-linejoin="round"`)), 0)
	testing.expect_value(t, above(corner(t, `stroke-miterlimit="1.5"`)), 0) // longer than the limit: bevelled
	round := corner(t, `stroke-linejoin="round"`)
	bevel := corner(t, `stroke-linejoin="bevel"`)
	testing.expect(t, svg_test_alpha(round, 10, 3) > svg_test_alpha(bevel, 10, 3), "a round join covers more of the corner than a bevel")
}

@(test)
svg_dashes_leave_gaps :: proc(t: ^testing.T) {
	dashed :: proc(t: ^testing.T, attrs: string) -> [4]int {
		doc := strings.concatenate({`<svg xmlns="http://www.w3.org/2000/svg" width="20" height="10"><path d="M0 5H20" stroke="#000" stroke-width="2" `, attrs, `/></svg>`}, context.temp_allocator)
		img := svg_test_render(t, doc, 20, 10)
		return {svg_test_alpha(img, 2, 5), svg_test_alpha(img, 6, 5), svg_test_alpha(img, 10, 5), svg_test_alpha(img, 14, 5)}
	}
	testing.expect_value(t, dashed(t, `stroke-dasharray="4 4"`), [4]int{255, 0, 255, 0})
	testing.expect_value(t, dashed(t, `stroke-dasharray="4"`), [4]int{255, 0, 255, 0})
	testing.expect_value(t, dashed(t, `stroke-dasharray="4,4" stroke-dashoffset="4"`), [4]int{0, 255, 0, 255})
	testing.expect_value(t, dashed(t, `style="stroke-dasharray:none"`), [4]int{255, 255, 255, 255})
	testing.expect_value(t, dashed(t, `stroke-dasharray="4 -1"`), [4]int{255, 255, 255, 255}) // a negative entry: solid
}

@(test)
svg_transforms_move_shapes :: proc(t: ^testing.T) {
	img := svg_test_render(t, `<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20">
		<rect width="4" height="4" transform="translate(10 2)"/>
		<rect x="10" width="10" height="2" transform="rotate(90 10 10)"/>
		<rect width="2" height="2" transform="matrix(1 0 0 1 2 16) scale(1.5)"/>
	</svg>`, 20, 20)
	testing.expect_value(t, svg_test_alpha(img, 11, 3), 255)
	testing.expect_value(t, svg_test_alpha(img, 1, 1), 0)
	testing.expect_value(t, svg_test_alpha(img, 19, 15), 255) // the top-right strip turned a quarter clockwise about the centre
	testing.expect_value(t, svg_test_alpha(img, 15, 1), 0)
	testing.expect_value(t, svg_test_alpha(img, 4, 18), 255) // 3 × 3 at (2, 16): scaled, then moved
	testing.expect_value(t, svg_test_alpha(img, 5, 18), 0)
}

@(test)
svg_styles_cascade :: proc(t: ^testing.T) {
	img := svg_test_render(t, `<svg xmlns="http://www.w3.org/2000/svg" width="60" height="10">
		<style><![CDATA[
			/* a comment */
			.c { fill: #00ff00 }
			.i { fill: #ffff00 !important }
			#idd { fill: #00ffff }
			g.outer rect { fill: #ff00ff }
			g.parent > rect.kid { fill: #0000ff }
			rect[x], rect:hover { fill: #ff0000 }
		]]></style>
		<rect x="0" width="10" height="10" fill="#f00" class="c"/>
		<rect x="10" width="10" height="10" class="c" style="fill:#0000ff"/>
		<rect x="20" width="10" height="10" class="i" style="fill:#0000ff"/>
		<rect x="30" width="10" height="10" class="c" id="idd"/>
		<g class="outer"><g><rect x="40" width="10" height="10"/></g></g>
		<g class="parent"><g><rect class="kid" x="50" width="10" height="10" fill="#000"/></g></g>
	</svg>`, 60, 10)
	svg_test_near(t, svg_test_px(img, 5, 5), {0, 255, 0, 255}, 0, "a class rule beats the attribute")
	svg_test_near(t, svg_test_px(img, 15, 5), {0, 0, 255, 255}, 0, "the style attribute beats a rule")
	svg_test_near(t, svg_test_px(img, 25, 5), {255, 255, 0, 255}, 0, "an !important rule beats the style attribute")
	svg_test_near(t, svg_test_px(img, 35, 5), {0, 255, 255, 255}, 0, "an id beats a class")
	svg_test_near(t, svg_test_px(img, 45, 5), {255, 0, 255, 255}, 0, "a descendant selector")
	svg_test_near(t, svg_test_px(img, 55, 5), {0, 0, 0, 255}, 0, "a child selector doesn't reach a grandchild")
}

@(private = "file")
SVG_TEST_SCHEME :: `<style id="current-color-scheme" type="text/css">
	.ColorScheme-Text { color:#dfdfdf; } .ColorScheme-NegativeText { color:#f44336; }
</style>`

@(test)
svg_icons_follow_the_colours_given :: proc(t: ^testing.T) {
	doc := `<svg xmlns="http://www.w3.org/2000/svg" width="12" height="4">` + SVG_TEST_SCHEME + `
		<rect width="4" height="4" style="fill:currentColor" class="ColorScheme-Text"/>
		<rect x="4" width="4" height="4" style="fill:currentColor" class="ColorScheme-NegativeText"/>
		<rect x="8" width="4" height="4" fill="currentColor"/>
	</svg>`
	own := svg_test_render(t, doc, 12, 4)
	svg_test_near(t, svg_test_px(own, 1, 1), {0xdf, 0xdf, 0xdf, 255}, 0, "the sheet's text colour")
	svg_test_near(t, svg_test_px(own, 5, 1), {0xf4, 0x43, 0x36, 255}, 0, "the sheet's negative colour")
	svg_test_near(t, svg_test_px(own, 9, 1), {0, 0, 0, 255}, 0, "currentColor starts black")
	colors := Svg_Colors{text = rgb(0x336699), negative = rgb(0xaa0000)}
	given := svg_test_render(t, doc, 12, 4, &colors)
	svg_test_near(t, svg_test_px(given, 1, 1), {0x33, 0x66, 0x99, 255}, 1, "the text colour given")
	svg_test_near(t, svg_test_px(given, 5, 1), {0xaa, 0, 0, 255}, 1, "the negative colour given")
	svg_test_near(t, svg_test_px(given, 9, 1), {0x33, 0x66, 0x99, 255}, 1, "currentColor starts as the text colour")
}

@(test)
svg_symbolic_icons_take_the_text_and_status_colours :: proc(t: ^testing.T) {
	doc := `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="4">
		<path d="M0 0H4V4H0Z" fill="#bebebe"/>
		<rect x="4" width="4" height="4" fill="#bebebe" class="error"/>
		<rect x="8" width="4" height="4" style="opacity:.35"/>
		<rect x="12" width="4" height="4" fill="none"/>
	</svg>`
	colors := Svg_Colors{text = rgb(0x336699), negative = rgb(0xaa0000), symbolic = true}
	img := svg_test_render(t, doc, 16, 4, &colors)
	svg_test_near(t, svg_test_px(img, 1, 1), {0x33, 0x66, 0x99, 255}, 1, "a grey fill takes the text colour")
	svg_test_near(t, svg_test_px(img, 5, 1), {0xaa, 0, 0, 255}, 1, "class error takes the negative colour")
	svg_test_near(t, svg_test_px(img, 9, 1), {0x33, 0x66, 0x99, 89}, 1, "opacity stays")
	testing.expect_value(t, svg_test_alpha(img, 13, 1), 0) // fill none stays none
}

@(test)
svg_a_papirus_symbolic_icon :: proc(t: ^testing.T) {
	doc := `<svg xmlns="http://www.w3.org/2000/svg" width="22" height="22" version="1.1">
 <defs>
  <style id="current-color-scheme" type="text/css">
   .ColorScheme-Text { color:#dfdfdf; } .ColorScheme-Highlight { color:#4285f4; } .ColorScheme-NeutralText { color:#ff9800; } .ColorScheme-PositiveText { color:#4caf50; } .ColorScheme-NegativeText { color:#f44336; }
  </style>
 </defs>
 <path style="opacity:.35;fill:currentColor" class="ColorScheme-Text" d="m 3,7 c 2.0806,-1.9268 4.9494,-3 8,-3 3.051,0 5.919,1.0731 8,3 l -8,11 z"/>
 <path style="fill:currentColor" class="ColorScheme-Text" d="M 11,7 A 8,8 0 0 0 4.9863281,9.7324219 L 11,18 17.009766,9.734375 A 8,8 0 0 0 11,7 Z"/>
</svg>`
	colors := Svg_Colors{text = rgb(0x202020)}
	img := svg_test_render(t, doc, 22, 22, &colors)
	svg_test_near(t, svg_test_px(img, 10, 12), {0x20, 0x20, 0x20, 255}, 1, "the signal drawn in the text colour")
	svg_test_near(t, svg_test_px(img, 10, 5), {0x20, 0x20, 0x20, 89}, 2, "the rest of the fan at 35%")
	testing.expect_value(t, svg_test_alpha(img, 1, 20), 0)
}

@(test)
svg_linear_gradients :: proc(t: ^testing.T) {
	img := svg_test_render(t, `<svg xmlns="http://www.w3.org/2000/svg" width="256" height="1">
		<linearGradient id="g"><stop offset="0" stop-color="#000"/><stop offset="1" stop-color="#fff"/></linearGradient>
		<rect width="256" height="1" fill="url(#g)"/>
	</svg>`, 256, 1)
	svg_test_near(t, svg_test_px(img, 0, 0), {0, 0, 0, 255}, 1, "the first stop")
	svg_test_near(t, svg_test_px(img, 128, 0), {128, 128, 128, 255}, 1, "halfway, interpolated in sRGB")
	svg_test_near(t, svg_test_px(img, 255, 0), {255, 255, 255, 255}, 1, "the last stop")
	// inherited stops, user space units, a vertical axis, and the xlink prefix
	inherited := svg_test_render(t, `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="20" height="20">
		<defs><linearGradient id="base"><stop offset="0" stop-color="#f00"/><stop offset="100%" stop-color="#00f"/></linearGradient></defs>
		<linearGradient id="g" xlink:href="#base" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="0" y2="20"/>
		<rect width="20" height="20" fill="url(#g)"/>
	</svg>`, 20, 20)
	top, bottom := svg_test_px(inherited, 10, 0), svg_test_px(inherited, 10, 19)
	testing.expectf(t, top.r > 240 && top.b < 15, "the top is red: %v", top)
	testing.expectf(t, bottom.b > 240 && bottom.r < 15, "the bottom is blue: %v", bottom)
	// a missing server falls back to the colour after it
	fallback := svg_test_render(t, `<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"><rect width="4" height="4" fill="url(#none) #00ff00"/></svg>`, 4, 4)
	svg_test_near(t, svg_test_px(fallback, 1, 1), {0, 255, 0, 255}, 0, "the fallback colour")
}

@(test)
svg_radial_gradients :: proc(t: ^testing.T) {
	img := svg_test_render(t, `<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20">
		<radialGradient id="r"><stop offset="0" stop-color="#fff"/><stop offset="1" stop-color="#000"/></radialGradient>
		<rect width="20" height="20" fill="url(#r)"/>
	</svg>`, 20, 20)
	centre, edge, corner := svg_test_px(img, 10, 10), svg_test_px(img, 19, 10), svg_test_px(img, 0, 0)
	testing.expectf(t, centre.r > 220, "white at the centre: %v", centre)
	testing.expectf(t, edge.r < 30, "nearly black at the edge: %v", edge)
	svg_test_near(t, corner, {0, 0, 0, 255}, 0, "padded beyond the circle")
	reflect := svg_test_render(t, `<svg xmlns="http://www.w3.org/2000/svg" width="40" height="1">
		<linearGradient id="g" gradientUnits="userSpaceOnUse" x2="10" spreadMethod="reflect"><stop offset="0" stop-color="#000"/><stop offset="1" stop-color="#fff"/></linearGradient>
		<rect width="40" height="1" fill="url(#g)"/>
	</svg>`, 40, 1)
	testing.expectf(t, svg_test_px(reflect, 9, 0).r > 230 && svg_test_px(reflect, 10, 0).r > 230 && svg_test_px(reflect, 19, 0).r < 25, "reflect runs back: %v %v", svg_test_px(reflect, 9, 0), svg_test_px(reflect, 19, 0))
}

@(test)
svg_group_opacity_composites_the_group_once :: proc(t: ^testing.T) {
	img := svg_test_render(t, `<svg xmlns="http://www.w3.org/2000/svg" width="30" height="10">
		<g opacity="0.5"><rect width="10" height="10"/><rect x="5" width="10" height="10"/></g>
		<rect x="20" width="10" height="10" fill="#f00" stroke="#00f" stroke-width="4" opacity="0.5"/>
	</svg>`, 30, 10)
	testing.expect_value(t, svg_test_alpha(img, 2, 5), 128)
	testing.expect_value(t, svg_test_alpha(img, 7, 5), 128) // not 191: the rects overlap inside the group
	stroke := svg_test_px(img, 20, 5) // the stroke's inner half over the fill, faded as one
	svg_test_near(t, stroke, {0, 0, 255, 128}, 1, "fill and stroke fade together")
}

@(test)
svg_clip_paths_and_masks :: proc(t: ^testing.T) {
	img := svg_test_render(t, `<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20">
		<clipPath id="c"><circle cx="10" cy="10" r="8"/></clipPath>
		<clipPath id="half" clipPathUnits="objectBoundingBox"><rect width="0.5" height="1"/></clipPath>
		<rect width="20" height="20" clip-path="url(#c)"/>
		<rect x="20" width="20" height="10" clip-path="url(#half)"/>
	</svg>`, 40, 20)
	testing.expect_value(t, svg_test_alpha(img, 10, 10), 255)
	testing.expect_value(t, svg_test_alpha(img, 1, 1), 0)
	testing.expect_value(t, svg_test_alpha(img, 25, 5), 255)
	testing.expect_value(t, svg_test_alpha(img, 35, 5), 0)
	masked := svg_test_render(t, `<svg xmlns="http://www.w3.org/2000/svg" width="30" height="10">
		<mask id="m"><rect width="30" height="10" fill="#fff"/><rect x="10" width="10" height="10" fill="#000"/><rect x="20" width="10" height="10" fill="#808080"/></mask>
		<rect width="30" height="10" fill="#f00" mask="url(#m)"/>
	</svg>`, 30, 10)
	svg_test_near(t, svg_test_px(masked, 5, 5), {255, 0, 0, 255}, 0, "under white")
	testing.expect_value(t, svg_test_alpha(masked, 15, 5), 0)
	svg_test_near(t, svg_test_px(masked, 25, 5), {255, 0, 0, 128}, 1, "under mid grey: its luminance")
}

@(test)
svg_use_and_symbols :: proc(t: ^testing.T) {
	img := svg_test_render(t, `<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20">
		<defs>
			<rect id="r" width="4" height="4" fill="#0f0"/>
			<path id="p" d="M0 0H4V4H0Z"/>
			<symbol id="s" viewBox="0 0 2 2"><rect width="1" height="1" fill="#00f"/></symbol>
		</defs>
		<use href="#r" x="10"/>
		<use href="#p" x="10" y="10" fill="#f00"/>
		<use href="#s" y="10" width="8" height="8"/>
	</svg>`, 20, 20)
	svg_test_near(t, svg_test_px(img, 12, 2), {0, 255, 0, 255}, 0, "the used rect")
	testing.expect_value(t, svg_test_alpha(img, 2, 2), 0) // defs draw nothing where they are
	svg_test_near(t, svg_test_px(img, 12, 12), {255, 0, 0, 255}, 0, "a used path inherits the use's fill")
	svg_test_near(t, svg_test_px(img, 2, 12), {0, 0, 255, 255}, 0, "a symbol's viewBox fits the use's size")
	testing.expect_value(t, svg_test_alpha(img, 6, 16), 0)
}

@(test)
svg_filters :: proc(t: ^testing.T) {
	blurred := svg_test_render(t, `<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20">
		<filter id="b"><feGaussianBlur stdDeviation="1"/></filter>
		<rect x="5" y="5" width="10" height="10" filter="url(#b)"/>
	</svg>`, 20, 20)
	testing.expect(t, svg_test_alpha(blurred, 4, 10) > 0, "the blur spreads past the edge")
	testing.expect(t, svg_test_alpha(blurred, 5, 10) < 255, "and softens it")
	testing.expect(t, svg_test_alpha(blurred, 10, 10) > 250, "the middle stays solid")
	testing.expect_value(t, svg_test_alpha(blurred, 2, 10), 0) // outside the filter region
	// an icon theme's masks: a colour matrix turns black content white, so its alpha masks
	whitened := svg_test_render(t, `<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20">
		<filter id="w" x="0%" y="0%" width="100%" height="100%"><feColorMatrix in="SourceGraphic" type="matrix" values="0 0 0 0 1 0 0 0 0 1 0 0 0 0 1 0 0 0 1 0"/></filter>
		<mask id="m"><g filter="url(#w)"><rect width="20" height="20" fill-opacity="0.5"/></g></mask>
		<rect width="20" height="20" mask="url(#m)"/>
	</svg>`, 20, 20)
	half := svg_test_alpha(whitened, 10, 10)
	testing.expectf(t, abs(half - 128) <= 1, "masked to half: %d", half)
	shadow := svg_test_render(t, `<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20">
		<filter id="s" x="-50%" y="-50%" width="200%" height="200%">
			<feOffset in="SourceAlpha" dx="4" result="o"/>
			<feFlood flood-color="#f00" result="f"/>
			<feComposite in="f" in2="o" operator="in" result="sh"/>
			<feMerge><feMergeNode in="sh"/><feMergeNode in="SourceGraphic"/></feMerge>
		</filter>
		<rect x="4" y="4" width="8" height="8" fill="#00f" filter="url(#s)"/>
	</svg>`, 20, 20)
	svg_test_near(t, svg_test_px(shadow, 8, 8), {0, 0, 255, 255}, 0, "the source over its shadow")
	svg_test_near(t, svg_test_px(shadow, 14, 8), {255, 0, 0, 255}, 0, "the offset shadow")
	testing.expect_value(t, svg_test_alpha(shadow, 2, 8), 0)
}

@(test)
svg_display_and_visibility :: proc(t: ^testing.T) {
	img := svg_test_render(t, `<svg xmlns="http://www.w3.org/2000/svg" width="30" height="10">
		<g display="none"><rect width="10" height="10"/></g>
		<g visibility="hidden"><rect x="10" width="10" height="10"/><rect x="20" width="10" height="10" visibility="visible"/></g>
	</svg>`, 30, 10)
	testing.expect_value(t, svg_test_alpha(img, 5, 5), 0)
	testing.expect_value(t, svg_test_alpha(img, 15, 5), 0)
	testing.expect_value(t, svg_test_alpha(img, 25, 5), 255)
}

@(test)
svg_patterns_repeat :: proc(t: ^testing.T) {
	img := svg_test_render(t, `<svg xmlns="http://www.w3.org/2000/svg" width="20" height="4">
		<pattern id="p" width="4" height="4" patternUnits="userSpaceOnUse"><rect width="2" height="4"/></pattern>
		<rect width="20" height="4" fill="url(#p)"/>
	</svg>`, 20, 4)
	testing.expect_value(t, [4]int{svg_test_alpha(img, 1, 2), svg_test_alpha(img, 3, 2), svg_test_alpha(img, 17, 2), svg_test_alpha(img, 19, 2)}, [4]int{255, 0, 255, 0})
}

@(test)
svg_embedded_pictures :: proc(t: ^testing.T) {
	img := svg_test_render(t, `<svg xmlns="http://www.w3.org/2000/svg" width="20" height="10">
		<image width="20" height="10" href="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAADklEQVR4nGP4z8AAQv8BD/kD/YURmXYAAAAASUVORK5CYII="/>
	</svg>`, 20, 10)
	svg_test_near(t, svg_test_px(img, 2, 5), {255, 0, 0, 255}, 0, "the left pixel of the picture")
	svg_test_near(t, svg_test_px(img, 17, 5), {0, 0, 255, 255}, 0, "the right pixel")
}

@(test)
svg_viewports_and_lengths :: proc(t: ^testing.T) {
	img := svg_test_render(t, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 10">
		<svg width="10" height="10" viewBox="0 0 1 1"><rect width="2" height="2"/></svg>
		<rect x="50%" width="25%" height="100%" fill="#f00"/>
	</svg>`, 40, 10)
	testing.expect_value(t, svg_test_alpha(img, 5, 5), 255)
	testing.expect_value(t, svg_test_alpha(img, 15, 5), 0) // a nested viewport clips
	svg_test_near(t, svg_test_px(img, 25, 5), {255, 0, 0, 255}, 0, "percentages of the viewBox")
	testing.expect_value(t, svg_test_alpha(img, 31, 5), 0)
}

@(test)
svg_size_is_the_documents_own :: proc(t: ^testing.T) {
	cases := []struct {
		doc:  string,
		want: [2]f32,
	}{
		{`<svg xmlns="http://www.w3.org/2000/svg" width="48" height="32"/>`, {48, 32}},
		{`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 8"/>`, {16, 8}},
		{`<svg xmlns="http://www.w3.org/2000/svg" width="32" viewBox="0 0 16 8"/>`, {32, 16}},
		{`<svg xmlns="http://www.w3.org/2000/svg" width="1in" height="12pt"/>`, {96, 16}},
	}
	for c in cases {
		size, ok := svg_size(transmute([]u8)c.doc)
		testing.expectf(t, ok && abs(size.x - c.want.x) < 0.01 && abs(size.y - c.want.y) < 0.01, "%s: %v, want %v", c.doc, size, c.want)
	}
	_, ok := svg_size(transmute([]u8)string(`<svg xmlns="http://www.w3.org/2000/svg"/>`))
	testing.expect(t, !ok, "no size given")
}

@(test)
svg_bad_documents_fail_or_stop_safely :: proc(t: ^testing.T) {
	for doc in ([]string{`not xml at all`, `<html><body/></html>`, ``}) {
		_, ok := svg_render(transmute([]u8)doc, 16, 16, allocator = context.temp_allocator)
		testing.expectf(t, !ok, "%q doesn't render", doc)
	}
	_, ok := svg_render(transmute([]u8)string(`<svg xmlns="http://www.w3.org/2000/svg"/>`), SVG_MAX_SIDE + 1, 16, allocator = context.temp_allocator)
	testing.expect(t, !ok, "too big a picture")
	// a path draws up to its first error
	broken := svg_test_render(t, `<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><path d="M0 0H10V10H0Z L 5 x 7"/></svg>`, 10, 10)
	testing.expect_value(t, svg_test_alpha(broken, 5, 5), 255)
	// references that loop end
	looped := svg_test_render(t, `<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
		<g id="g"><rect width="5" height="5"/><use href="#g" x="1"/></g>
		<use id="u" href="#u"/>
		<clipPath id="c" clip-path="url(#c)"><rect width="10" height="10"/></clipPath>
		<rect x="5" y="5" width="5" height="5" clip-path="url(#c)"/>
		<pattern id="p" width="2" height="2" patternUnits="userSpaceOnUse"><rect width="2" height="2" fill="url(#p)"/></pattern>
		<rect y="5" width="5" height="5" fill="url(#p)"/>
		<mask id="m" mask="url(#m)"><use href="#g"/></mask>
		<filter id="f"><feGaussianBlur stdDeviation="-1"/><feTurbulence/></filter>
		<rect width="1" height="1" mask="url(#m)" filter="url(#f)"/>
	</svg>`, 10, 10)
	testing.expect_value(t, svg_test_alpha(looped, 2, 2), 255)
}

// svg_test_bbox is the box of the pixels with any coverage.
@(private = "file")
svg_test_bbox :: proc(img: Image) -> (lo, hi: [2]int, any: bool) {
	lo, hi = {max(int), max(int)}, {min(int), min(int)}
	for y in 0 ..< img.height {
		for x in 0 ..< img.width {
			if img.pixels[(y * img.width + x) * 4 + 3] == 0 do continue
			lo, hi, any = {min(lo.x, x), min(lo.y, y)}, {max(hi.x, x), max(hi.y, y)}, true
		}
	}
	return
}

@(private = "file")
svg_test_text :: proc(t: ^testing.T, body: string, loc := #caller_location) -> Image {
	doc := strings.concatenate({`<svg xmlns="http://www.w3.org/2000/svg" width="60" height="40">`, body, `</svg>`}, context.temp_allocator)
	return svg_test_render(t, doc, 60, 40, loc = loc)
}

@(test)
svg_text_sits_on_its_baseline_and_anchors :: proc(t: ^testing.T) {
	lo, hi, any := svg_test_bbox(svg_test_text(t, `<text x="4" y="30" font-size="30">H</text>`))
	testing.expect(t, any, "the H is drawn")
	testing.expectf(t, hi.y <= 30 && lo.y >= 6 && lo.y <= 10, "a cap height above the baseline at 30: rows %d to %d", lo.y, hi.y)
	testing.expectf(t, lo.x >= 4 && lo.x <= 8, "starting at x 4: %d", lo.x)
	mlo, mhi, _ := svg_test_bbox(svg_test_text(t, `<text x="30" y="30" font-size="30" text-anchor="middle">H</text>`))
	testing.expectf(t, abs((mlo.x + mhi.x + 1) / 2 - 30) <= 2, "centred on 30: %d to %d", mlo.x, mhi.x)
	_, ehi, _ := svg_test_bbox(svg_test_text(t, `<text x="56" y="30" font-size="30" text-anchor="end">H</text>`))
	testing.expectf(t, ehi.x < 56 && ehi.x >= 50, "ending at 56: %d", ehi.x)
	slo, _, _ := svg_test_bbox(svg_test_text(t, `<text x="4" y="30" font-size="30">
		  H  </text>`))
	testing.expect_value(t, slo.x, lo.x) // white space collapses and the ends are trimmed
	_, collapsed, _ := svg_test_bbox(svg_test_text(t, `<text x="2" y="30" font-size="20">H   H</text>`))
	_, preserved, _ := svg_test_bbox(svg_test_text(t, `<text x="2" y="30" font-size="20" xml:space="preserve">H   H</text>`))
	testing.expectf(t, preserved.x >= collapsed.x + 8, "preserved spaces keep their width: %d against %d", preserved.x, collapsed.x)
}

@(test)
svg_text_spans_keep_their_own_style :: proc(t: ^testing.T) {
	img := svg_test_text(t, `<text x="2" y="30" font-size="24">H<tspan fill="#ff0000">H</tspan></text>`)
	black, red := max(int), max(int)
	for y in 0 ..< 40 {
		for x in 0 ..< 60 {
			px := svg_test_px(img, x, y)
			if px.a < 255 do continue
			if px.r < 20 do black = min(black, x)
			if px.r > 230 && px.g < 20 do red = min(red, x)
		}
	}
	testing.expectf(t, black < 10 && red > black + 10 && red < 60, "a black H then a red one: from %d and %d", black, red)
	coverage :: proc(img: Image) -> (sum: int) {
		for i in 0 ..< img.width * img.height do sum += int(img.pixels[i * 4 + 3])
		return
	}
	regular := coverage(svg_test_text(t, `<text x="2" y="30" font-size="24">HH</text>`))
	bold := coverage(svg_test_text(t, `<text x="2" y="30" font-size="24" font-weight="bold">HH</text>`))
	testing.expectf(t, f64(bold) > f64(regular) * 1.15, "bold covers more: %d against %d", bold, regular)
}

@(test)
svg_lighting_filters :: proc(t: ^testing.T) {
	lit :: proc(t: ^testing.T, primitive: string) -> [4]int {
		doc := strings.concatenate({`<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><filter id="l" x="0" y="0" width="1" height="1">`, primitive, `</filter><rect width="20" height="20" filter="url(#l)"/></svg>`}, context.temp_allocator)
		return svg_test_px(svg_test_render(t, doc, 20, 20), 10, 10)
	}
	svg_test_near(t, lit(t, `<feDiffuseLighting lighting-color="#808080"><feDistantLight elevation="90"/></feDiffuseLighting>`), {128, 128, 128, 255}, 1, "a flat surface lit from above takes the light's colour")
	svg_test_near(t, lit(t, `<feDiffuseLighting><feDistantLight elevation="0"/></feDiffuseLighting>`), {0, 0, 0, 255}, 0, "lit edge-on it is dark")
	svg_test_near(t, lit(t, `<feSpecularLighting><feDistantLight elevation="90"/></feSpecularLighting>`), {255, 255, 255, 255}, 0, "a highlight straight on")
}

@(test)
svg_doctype_entities_expand :: proc(t: ^testing.T) {
	img := svg_test_render(t, `<?xml version="1.0" encoding="iso-8859-1"?>
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 20000303 Stylable//EN" "http://www.w3.org/TR/2000/03/WD-SVG-20000303/DTD/svg-20000303-stylable.dtd" [
	<!ENTITY st0 "fill:#00ff00;stroke:none;">
	<!ENTITY ns_svg "http://www.w3.org/2000/svg">
]>
<svg xmlns="&ns_svg;" width="4" height="4"><rect width="4" height="4" style="&st0;"/></svg>`, 4, 4)
	svg_test_near(t, svg_test_px(img, 1, 1), {0, 255, 0, 255}, 0, "the style an entity held")
}

@(test)
svg_pictures_drawn_small_are_filtered :: proc(t: ^testing.T) {
	// one white pixel and seven black, squeezed into one: the average, not whichever pixel a sample hits
	img := svg_test_render(t, `<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1">
		<image width="1" height="1" preserveAspectRatio="none" href="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAgAAAABCAYAAADjAO9DAAAAEElEQVR4nGP4DwQMDAw4MQDUTAr2GrLQ+gAAAABJRU5ErkJggg=="/>
	</svg>`, 1, 1)
	svg_test_near(t, svg_test_px(img, 0, 0), {32, 32, 32, 255}, 3, "an eighth of white")
}

@(test)
svg_info_tells_masks_from_coloured_pictures :: proc(t: ^testing.T) {
	info_of :: proc(t: ^testing.T, doc: string, symbolic: bool, loc := #caller_location) -> Svg_Info {
		colors := Svg_Colors{text = rgb(0x336699), negative = rgb(0xaa0000), symbolic = symbolic}
		info: Svg_Info
		_, ok := svg_render(transmute([]u8)doc, 16, 16, &colors, &info, context.temp_allocator)
		testing.expect(t, ok, "rendered", loc = loc)
		return info
	}
	SVG :: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16">`
	testing.expect_value(t, info_of(t, SVG + `<path d="M0 0H16V16H0Z" fill="#bebebe"/></svg>`, true), Svg_Info{recolored = true, monochrome = true})
	testing.expect_value(t, info_of(t, SVG + `<rect width="16" height="16" fill="#ff0000"/></svg>`, false), Svg_Info{})
	testing.expect_value(t, info_of(t, SVG + `<rect width="8" height="16"/><rect x="8" width="8" height="16" class="error"/></svg>`, true), Svg_Info{recolored = true})
	testing.expect_value(t, info_of(t, SVG + `<style>.ColorScheme-Text{color:#444}</style><rect width="8" height="16" style="fill:currentColor" class="ColorScheme-Text"/><rect x="8" width="8" height="16" fill="#00ff00"/></svg>`, false), Svg_Info{recolored = true})
	testing.expect_value(t, info_of(t, SVG + `<rect width="16" height="16" style="fill:currentColor"/></svg>`, false), Svg_Info{recolored = true, monochrome = true}) // currentColor starts as the text colour
	testing.expect_value(t, info_of(t, SVG + `<rect width="16" height="16" style="color:#123456;fill:currentColor"/></svg>`, false), Svg_Info{}) // the document's own colour
	masked := SVG + `<filter id="w"><feColorMatrix values="0 0 0 0 1 0 0 0 0 1 0 0 0 0 1 0 0 0 1 0"/></filter><mask id="m"><g filter="url(#w)"><rect width="16" height="16" fill-opacity=".5"/></g></mask><rect width="16" height="16" fill="#2e3436" mask="url(#m)"/></svg>`
	testing.expect_value(t, info_of(t, masked, true), Svg_Info{recolored = true, monochrome = true}) // what a mask holds doesn't count
}

} // when ODIN_TEST