package baldr

// The colours a chart's series are drawn in.
//
// Not derived from the theme's seed: a categorical palette must tell series
// apart for a colour-blind reader, on light and dark surfaces, and that is
// measured, not derived from an app's accent. The slots are fixed and
// assigned to series in order — never shuffled when a series is filtered
// out, so a series keeps its colour when its neighbours come and go.
//
// Measured against the toolkit's surfaces (light #fdfdff, dark #1a1c1f) with
// the Machado-Oliveira-Fernandes CVD simulation at severity 1.0, Δ E as
// Euclidean OKLab distance × 100:
//
//   adjacent pairs   worst CVD Δ E 9.1 light / 8.4 dark   (target ≥ 8)
//                    worst normal-vision Δ E 19.6 / 19.3  (floor ≥ 15)
//   all pairs        the first three slots: CVD 9.2 / 9.4, normal 24.0 / 20.9
//
// So colour is never the only carrier:
//
//   - On the light surface, aqua, yellow and magenta sit below 3:1 against
//     it, so a chart always carries a legend for two or more series, direct
//     labels for four or fewer, and the whole series in its accessibility
//     tree.
//   - In a scatter any two marks can be neighbours, and only the first three
//     slots clear the floors on every pair, so scatter series take a marker
//     shape as well as a colour.
Chart_Palette :: [8]Color

// chart_colors: the palette for a theme, light or dark. The dark column is
// the same eight hues stepped for a dark surface — chosen for it, not a
// lightened copy of the light one.
@(private)
chart_colors :: proc(th: ^Theme) -> Chart_Palette {
	dark := th.dark
	hexes := [8]string{"#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#4a3aa7", "#e34948"}
	if dark do hexes = {"#3987e5", "#d95926", "#199e70", "#c98500", "#d55181", "#008300", "#9085e9", "#e66767"}
	out: Chart_Palette
	for h, i in hexes {
		c, ok := color_parse_hex(h)
		out[i] = c if ok else th.color.primary
	}
	return out
}

// palette_color is the colour of series `i`: its slot, and past the eighth
// the slots again — past eight series a chart is no longer readable, and
// only the app can group its data.
@(private)
palette_color :: proc(pal: Chart_Palette, i: int) -> Color {
	return pal[i % len(pal)]
}

// chart_color is the colour a chart gives series `i` in theme `th`: for
// marks elsewhere that stand for the same thing — a sparkline in a sidebar
// beside the page whose chart draws that series — so they match. The slots
// are chosen to be told apart, and repeat past the eighth.
chart_color :: proc(th: ^Theme, i: int) -> Color {
	return palette_color(chart_colors(th), i)
}

// Chart_Marker is the shape a scatter's points are drawn as, the second
// carrier of identity beside the colour (see the note above).
@(private)
Chart_Marker :: enum u8 { Circle, Square, Triangle, Diamond }

@(private)
chart_marker :: proc(i: int) -> Chart_Marker {
	return Chart_Marker(i % (int(max(Chart_Marker)) + 1))
}
