package baldr

// Each piece of text reads what is behind *that* piece.
//
// One backdrop range for a whole surface gives all its text one ink, and
// over a wallpaper running from light to near-black no single colour reads,
// so every line gets a halo. The compositor can also report the backdrop
// cell by cell (`rikkiti-backdrop-v1` version 3); with that map a node
// takes the range under its own laid-out rect and picks its own ink: dark
// over the light part, light over the dark part, and a halo only on a node
// that straddles an edge.
//
// A node asks once with `legible_over`; the toolkit re-picks its ink
// whenever layout moves it or a new map arrives, without rebuilding the
// view. `backdrop_range_in` gives the range under any rect. With no map
// (not offered, or not arrived yet) every answer falls back to the
// surface-wide range.

import "core:fmt"
import "core:math"
import "core:os"

// Backdrop_Map is how bright what lies behind a surface is, cell by cell.
//
// `cell` is a cell's side in logical pixels and `origin` the map's top-left
// corner in surface-local logical pixels — not {0, 0} when the surface is
// partly off screen, because only what is shown is measured. The last
// column and row may be cut short by the screen's edge.
//
// `lum` is one relative luminance per cell, row after row: the compositor's
// sRGB grey bytes are decoded once, on arrival.
@(private)
Backdrop_Map :: struct {
	columns: int,
	rows:    int,
	cell:    int,
	origin:  [2]i32,
	lum:     []f32, // owned
}

// Legible_Want is what a node asked to be: the colour it would rather keep
// and the contrast it must reach over whatever is behind it.
@(private)
Legible_Want :: struct {
	preferred: Color,
	contrast:  f32,
}

// legible_over makes a node pick its own ink and halo from what is measured
// behind it, and keep picking as the wallpaper or the layout moves.
//
// The per-node form of `legible_ink`, over the range under this node's
// laid-out rect. `preferred` is kept where it reads; `contrast` is the
// ratio to reach (3 for large or decorative text). Set it on the text or
// icon node, not its row, as with `set_glow`. With no map the node uses the
// surface-wide range, and with no backdrop at all it keeps `preferred`.
legible_over :: proc(ui: ^Ui($Msg), n: Node, preferred: Color, contrast: f32 = GLASS_TEXT_CONTRAST) {
	t := &ui.tree
	if node_get(t, n) == nil do return
	t.legibles[n] = Legible_Want{preferred = preferred, contrast = contrast}
	legible_apply(t, n, t.legibles[n])
}

// backdrop_range_in is how bright what lies behind one rectangle of this
// surface is — the cells under it, where the compositor reports them, and
// the surface's whole range where it does not.
//
// The rect is in surface-local logical px, as a node's `abs` is, so an app
// drawing its own rule, fill or sparkline can pick colours as `legible_ink`
// does for text. `ok` is false when nothing has been measured at all. The
// numbers are cell averages: detail finer than a cell (thin dark stripes)
// does not show in them.
backdrop_range_in :: proc(ui: ^Ui($Msg), rect: Rect) -> (bd: Backdrop_Range, ok: bool) {
	return tree_range_in(&ui.tree, rect)
}

// backdrop_mapped says whether the compositor is reporting the backdrop cell
// by cell, so each piece of this surface can read what is behind that piece.
//
// False on a compositor that does not offer it, on a surface that did not
// ask, and before the first map; everything here then falls back to the
// surface's one range, so an app rarely needs to look.
backdrop_mapped :: proc(ui: ^Ui($Msg)) -> bool {
	m := &ui.tree.backdrop_map
	return m.columns > 0 && m.rows > 0 && len(m.lum) > 0
}

// ---------------------------------------------------------------- the inside

// tree_range_in is backdrop_range_in against a tree, which is what the
// per-node pass uses.
@(private)
tree_range_in :: proc(t: ^Tree, rect: Rect) -> (bd: Backdrop_Range, ok: bool) {
	if !t.glass.known do return {}, false
	m := &t.backdrop_map
	if m.columns <= 0 || m.rows <= 0 || m.cell <= 0 || len(m.lum) == 0 {
		return t.glass.backdrop, true // no map: the whole surface's range
	}

	// The cells the rect touches, clamped to the map. A rect wholly outside
	// what was measured (a surface partly off screen) falls back rather than
	// inventing a range.
	x0 := int(math.floor((rect.x - f32(m.origin.x)) / f32(m.cell)))
	y0 := int(math.floor((rect.y - f32(m.origin.y)) / f32(m.cell)))
	x1 := int(math.ceil((rect.x + rect.w - f32(m.origin.x)) / f32(m.cell)))
	y1 := int(math.ceil((rect.y + rect.h - f32(m.origin.y)) / f32(m.cell)))
	x0, y0 = max(x0, 0), max(y0, 0)
	x1, y1 = min(x1, m.columns), min(y1, m.rows)
	if x0 >= x1 || y0 >= y1 do return t.glass.backdrop, true

	lo, hi, sum := f32(1), f32(0), f32(0)
	n := 0
	for row in y0 ..< y1 {
		base := row * m.columns
		for col in x0 ..< x1 {
			v := m.lum[base + col]
			lo = min(lo, v)
			hi = max(hi, v)
			sum += v
			n += 1
		}
	}
	if n == 0 do return t.glass.backdrop, true
	return Backdrop_Range{min = lo, avg = sum / f32(n), max = hi}, true
}

// tree_backdrop_map takes a new map. True when anything the surface draws
// may now want a different colour, which is what makes the run loop re-pick
// and repaint.
@(private)
tree_backdrop_map :: proc(t: ^Tree, columns, rows, cell: int, origin: [2]i32, cells: []u8) -> bool {
	if columns <= 0 || rows <= 0 || cell <= 0 || len(cells) < columns * rows do return false
	m := &t.backdrop_map
	same := m.columns == columns && m.rows == rows && m.cell == cell && m.origin == origin && len(m.lum) == columns * rows
	if len(m.lum) != columns * rows {
		delete(m.lum, t.allocator)
		m.lum = make([]f32, columns * rows, t.allocator)
		same = false
	}
	m.columns, m.rows, m.cell, m.origin = columns, rows, cell, origin
	changed := !same
	for i in 0 ..< columns * rows {
		// The byte is an sRGB grey: dividing by 255 alone would make a
		// mid-grey read about twice as bright as it is.
		v := srgb_to_linear(f32(cells[i]) / 255)
		if m.lum[i] != v {
			m.lum[i] = v
			changed = true
		}
	}
	if changed do t.glass.known = true
	return changed
}

// tree_backdrop_map_free drops the map with its tree.
@(private)
tree_backdrop_map_free :: proc(t: ^Tree) {
	delete(t.backdrop_map.lum, t.allocator)
	t.backdrop_map = {}
}

// legible_pass re-picks the ink of every node that asked, after layout (the
// rect decides) and whenever a new map arrives. Its cost is proportional to
// the nodes that asked, not to the tree.
@(private)
legible_pass :: proc(t: ^Tree) {
	if len(t.legibles) == 0 do return
	for n, want in t.legibles do legible_apply(t, n, want)
}

// legible_apply gives one node the ink and halo that read over what is
// behind it.
@(private)
legible_apply :: proc(t: ^Tree, n: Node, want: Legible_Want) {
	d := node_get(t, n)
	if d == nil do return
	// The glow overhangs the glyphs, so read what is behind the rect grown
	// by that much.
	r := Rect{
		d.abs.x - GLOW_OVERHANG, d.abs.y - GLOW_OVERHANG,
		d.abs.w + GLOW_OVERHANG * 2, d.abs.h + GLOW_OVERHANG * 2,
	}
	bd, ok := tree_range_in(t, r)
	if !ok do return // nothing measured: the node keeps the colour it was built with
	ink, glow := legible_ink(bd, want.preferred, want.contrast)
	// BALDR_BACKDROP_DEBUG=1 logs what each node found behind it and what
	// it chose.
	if backdrop_debug() {
		fmt.eprintfln("baldr/backdrop: node at %.0f,%.0f %.0fx%.0f behind %.3f / %.3f / %.3f -> ink %.3f halo %v",
			d.abs.x, d.abs.y, d.abs.w, d.abs.h, bd.min, bd.avg, bd.max, luminance(ink), glow != Glow{})
	}
	st := d.style
	st.fg, st.glow = ink, glow
	set_style(t, n, st) // marks it for repaint, and does nothing when neither moved
}

@(private)
backdrop_debug :: proc() -> bool {
	@(static) asked, on: bool
	if !asked {
		asked = true
		on = os.get_env("BALDR_BACKDROP_DEBUG", context.temp_allocator) == "1"
	}
	return on
}

// legible_forget drops a node's ask. The map itself is keyed by node, so a
// node that goes away takes its entry with it when the tree is reconciled.
@(private)
legible_forget :: proc(t: ^Tree, n: Node) {
	delete_key(&t.legibles, n)
}
