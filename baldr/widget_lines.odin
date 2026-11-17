package baldr

// Lines drawn over a node: polylines, dashed, with a dash offset that can
// move. An image editor's overlays are these — marching ants round a
// selection, a transform box rotated with its layer, a crop frame and its
// thirds, guides, the pixel grid at high zoom, a lasso as it is drawn: thin
// lines over a `canvas` that move every frame and cannot be boxes. They are
// drawn as the renderer's own capsules rather than rasterised into an image:
// a node in a `stack` over the canvas, placed with `offset`, whose points
// are in its own logical coordinates. A build costs a copy of the points; a
// frame costs walking the dashes, which is arithmetic, not rasterising.

import "core:math"

// Polyline is one run of points in a `lines` node: an open stroke, or a loop
// when `closed`. A selection with holes is several — one loop round the
// outside and one round each hole — and they share the node's thickness,
// colour and dash phase, so the ants march together.
Polyline :: struct {
	points: [][2]f32,
	closed: bool,
}

// LINES_MAX_DASHES is how many lengths a dash pattern may have. Past this it
// is not a dash pattern, it is a path.
LINES_MAX_DASHES :: 8

// Lines_Run is one polyline inside the points a node kept.
@(private)
Lines_Run :: struct {
	from, count: int,
	closed:      bool,
}

// Lines_Kept is what a `lines` node holds past the build that passed its
// points, so paint has them: every run's points end to end, and the style
// they are drawn with.
@(private)
Lines_Kept :: struct {
	points:      [dynamic][2]f32,
	runs:        [dynamic]Lines_Run,
	dashes:      [dynamic]f32,
	thickness:   f32,
	dash_offset: f32,
	color:       Color,
	outline:     Color,
	crisp:       bool,
}

// lines draws `runs` (one or more polylines) over whatever is behind it, in
// the node's own logical coordinates: put it in a `stack` over a `canvas`
// with an `offset` to the canvas's corner. `thickness` is logical px, so a
// 1 px line stays 1 px at any zoom. `dashes` alternates on and off lengths
// along the path (`{4, 4}` even dashes, `{1, 3}` dots; an odd count repeats
// with on and off swapped, as SVG's does), and a rising `dash_offset` slides
// the pattern forward, so the ants march. `outline` fills the gaps between
// dashes, or without dashes is a halo two pixels wider under the line, which
// keeps it readable over any picture. `crisp` (the default) puts horizontal
// and vertical lines on whole device pixels, so a guide is one hard line
// rather than two half-lit ones; angled lines are never moved. It is
// decoration: no pointer or keyboard (an editor hit-tests its own geometry),
// and no place in the accessibility tree unless given a `label`. With no
// `width` and `height` it is as big as its points, from its own origin.
//
//	ants := f32(baldr.now_ms(ui) / 40)                          // 25 px a second
//	baldr.lines(ui, {{outline, true}}, color = baldr.BLACK, outline = baldr.WHITE,
//		dashes = {4, 4}, dash_offset = ants, width = view.w, height = view.h)
lines :: proc(ui: ^Ui($Msg), runs: []Polyline, thickness: f32 = 1, color: Color = {},
	dashes: []f32 = nil, dash_offset: f32 = 0, outline: Color = {}, crisp := true,
	width: f32 = 0, height: f32 = 0, offset: [2]f32 = {}, label: string = "",
	key: u64 = 0, loc := #caller_location) -> Node {
	n, _ := reconcile_child(ui, .Custom, key, loc)
	t := &ui.tree
	d := node_get(t, n)
	kept, had := &t.lines_data[n]
	if !had {
		t.lines_data[n] = Lines_Kept{
			points = make([dynamic][2]f32, t.allocator),
			runs   = make([dynamic]Lines_Run, t.allocator),
			dashes = make([dynamic]f32, t.allocator),
		}
		kept = &t.lines_data[n]
	}

	pat := dashes
	if len(pat) > LINES_MAX_DASHES do pat = pat[:LINES_MAX_DASHES]
	live := 0 // an empty run is not a line, and is not kept: count what will be
	for r in runs do if len(r.points) > 0 do live += 1
	same := had && kept.thickness == thickness && kept.color == color && kept.outline == outline &&
		kept.crisp == crisp && kept.dash_offset == dash_offset && len(kept.dashes) == len(pat) &&
		len(kept.runs) == live
	if same do for v, i in pat do if kept.dashes[i] != v {
		same = false
		break
	}
	if same {
		at, i := 0, 0
		runs_loop: for r in runs {
			if len(r.points) == 0 do continue
			k := kept.runs[i]
			i += 1
			if k.closed != r.closed || k.count != len(r.points) || k.from != at {
				same = false
				break
			}
			for p, j in r.points do if kept.points[at + j] != p {
				same = false
				break runs_loop
			}
			at += len(r.points)
		}
	}
	if !same {
		clear(&kept.points)
		clear(&kept.runs)
		clear(&kept.dashes)
		append(&kept.dashes, ..pat)
		for r in runs {
			if len(r.points) == 0 do continue // an empty run is not a line
			append(&kept.runs, Lines_Run{from = len(kept.points), count = len(r.points), closed = r.closed})
			append(&kept.points, ..r.points)
		}
		kept.thickness, kept.dash_offset = thickness, dash_offset
		kept.color, kept.outline, kept.crisp = color, outline, crisp
		mark_paint_dirty(t, n)
	}

	w, h := width, height
	if w <= 0 || h <= 0 { // as big as its points, measured from the node's own origin
		ex, ey := f32(0), f32(0)
		for p in kept.points do ex, ey = max(ex, p.x), max(ey, p.y)
		half := max(thickness, 1) * 0.5
		if w <= 0 do w = ex + half
		if h <= 0 do h = ey + half
	}
	if d.layout.offset != offset { // where it sits in a `stack` over what it is drawn on
		d.layout.offset = offset
		mark_layout_dirty(t, n)
	}
	// The stroke spills past the box, and an outline without dashes is a halo
	// two wider still: damage has to cover both.
	over := max(thickness, 1) * 0.5 + 2
	if ck, ok := d.kind.(Custom_Kind); !ok || ck.size != {w, h} || ck.overhang != over {
		d.kind = Custom_Kind{size = {w, h}, paint = paint_lines, overhang = over}
		mark_layout_dirty(t, n)
	}
	if label != "" {
		d.access.role = .Image
		set_name(t, n, label)
	} else {
		d.access.role = .None
	}
	return n
}

// lines_node_free gives a node's points back when it goes.
@(private)
lines_node_free :: proc(t: ^Tree, n: Node) {
	kept, has := &t.lines_data[n]
	if !has do return
	delete(kept.points)
	delete(kept.runs)
	delete(kept.dashes)
	delete_key(&t.lines_data, n)
}

@(private)
paint_lines :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer) {
	k, has := &t.lines_data[n]
	if !has || len(k.runs) == 0 do return
	w := max(k.thickness, 0.01)
	org := [2]f32{d.abs.x, d.abs.y}

	col := k.color
	if col == (Color{}) do col = t.theme.color.on_surface
	col.a *= t.paint_opacity
	under := k.outline
	under.a *= t.paint_opacity

	dashed := len(k.dashes) > 0
	for r in k.runs {
		pts := k.points[r.from:][:r.count]
		if under.a > 0 {
			if dashed {
				// The gaps, not the whole line. Marching ants are black and
				// white *alternating*: laying the colour over a solid outline
				// would composite one over the other, and two antialiased 1 px
				// strokes in the same place make grey, not black on white.
				lines_stroke(l, pts, r.closed, org, w, under, k.dashes[:], k.dash_offset, k.crisp, 1)
			} else {
				// Nothing to alternate with, so it is a halo: wider than the
				// line, under it, which is what makes a white guide readable
				// on a white picture.
				lines_stroke(l, pts, r.closed, org, w + 2, under, nil, 0, k.crisp, 0)
			}
		}
		if col.a > 0 do lines_stroke(l, pts, r.closed, org, w, col, k.dashes[:], k.dash_offset, k.crisp, 0)
	}
}

// lines_stroke lays one polyline down as the renderer's capsules. Without a
// pattern that is one per segment with round ends, which join it to the next
// for nothing; with one, it is one per dash, flat-ended, and a round dot
// wherever a dash carries on through a corner — which is the join the flat
// ends would otherwise leave a notch in. `on_parity` is 0 for the dashes and
// 1 for the gaps between them, which is how the outline fills what the
// colour leaves.
@(private)
lines_stroke :: proc(l: ^Layer, pts: [][2]f32, closed: bool, org: [2]f32, w: f32, col: Color,
	pattern: []f32, offset: f32, crisp: bool, on_parity: int) {
	segs := len(pts) - 1
	if closed && len(pts) > 2 do segs += 1
	if segs <= 0 { // a run of one point is a dot: it still shows where it is
		p := pts[0] + org
		append(&l.cmds, Draw_Line{a = p, b = p, width = w, color = col})
		return
	}
	at :: proc(pts: [][2]f32, i: int) -> [2]f32 { return pts[i % len(pts)] }

	if len(pattern) == 0 {
		for i in 0 ..< segs {
			append(&l.cmds, Draw_Line{a = at(pts, i) + org, b = at(pts, i + 1) + org, width = w, color = col, snap = crisp})
		}
		return
	}

	pat: [LINES_MAX_DASHES * 2]f32
	total := lines_pattern(pattern, &pat)
	if total <= 0 { // every length zero: nothing to draw, and no loop to hang in
		return
	}
	// Where in the pattern the path starts. A rising offset slides the
	// pattern forward along the path, which is the direction ants march.
	count := len(pattern) if len(pattern) % 2 == 0 else len(pattern) * 2
	phase := math.mod(-offset, total)
	if phase < 0 do phase += total
	step, left := 0, f32(0)
	for {
		if phase < pat[step] { left = pat[step] - phase; break } // …and total > 0, so a step with room exists
		phase -= pat[step]
		step = (step + 1) % count
	}

	for i in 0 ..< segs {
		a, b := at(pts, i) + org, at(pts, i + 1) + org
		run := math.sqrt((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y))
		if run <= 0 do continue
		dir := [2]f32{(b.x - a.x) / run, (b.y - a.y) / run}
		t := f32(0)
		for t < run {
			take := min(left, run - t)
			if step % 2 == on_parity && take > 0 { // `on_parity` picks the dashes or the gaps between them
				p0 := a + dir * t
				p1 := a + dir * (t + take)
				append(&l.cmds, Draw_Line{a = p0, b = p1, width = w, color = col, flat = true, snap = crisp})
			}
			t += take
			left -= take
			if left <= 1e-6 {
				step = (step + 1) % count
				left = pat[step]
			}
		}
		// Carrying on through a corner: a round dot is the join, and costs
		// one capsule rather than any geometry.
		if step % 2 == on_parity && (i + 1 < segs || closed) {
			append(&l.cmds, Draw_Line{a = b, b = b, width = w, color = col})
		}
	}
}

// lines_pattern writes the on/off lengths out in full — an odd count repeats
// with on and off swapped, as SVG's dasharray does, so `{5}` is five on,
// five off — and answers how long the whole pattern is.
@(private)
lines_pattern :: proc(pattern: []f32, out: ^[LINES_MAX_DASHES * 2]f32) -> (total: f32) {
	n := len(pattern)
	for i in 0 ..< n {
		v := max(pattern[i], 0)
		out[i] = v
		total += v
	}
	if n % 2 == 1 { // odd: run it twice, so the phase alternates
		for i in 0 ..< n {
			out[n + i] = out[i]
			total += out[i]
		}
	}
	return
}
