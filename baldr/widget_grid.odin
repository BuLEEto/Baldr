package baldr

// Shared behaviour of the two selection grids, table (one column of rows)
// and icon view (tiles): item clicks with Ctrl / Shift and double-click
// activation, the rubber band dragged over empty space, and context
// requests (right-click, the Menu key, Shift+F10) on an item or on the
// background. A file manager needs all of these in both views.

import "core:math"

// Grid_Sel is the rubber-band state kept by a table or icon view.
Grid_Sel :: struct {
	marquee: bool,
	m_start: [2]f32, // content coordinates: inside the list, scrolled
	m_cur:   [2]f32,
	m_add:   bool,   // Ctrl held: keep the selection that was there
	base:    map[int]struct{},
}

// Grid_Geom describes a grid for arithmetic selection: `cols` tiles of
// `tile` size with `gap` between them, `count` items in all.
Grid_Geom :: struct {
	list:  Node,
	cols:  int,
	tile:  [2]f32,
	gap:   f32,
	count: int,
	sel:   ^Selection,
	g:     ^Grid_Sel,
	placed: ^Icon_View_State, // a placed icon view: cells hold whatever the app put there, not index order
}

// grid_of returns the geometry of a table or icon view node.
@(private)
grid_of :: proc(t: ^Tree, view: Node) -> (geom: Grid_Geom, ok: bool) {
	if ts, is_table := &t.tables[view]; is_table {
		ld := node_get(t, ts.list)
		w := ld.abs.w if ld != nil else ts.total_w
		return {list = ts.list, cols = 1, tile = {max(w, ts.total_w), ts.row_height}, gap = 0, count = ts.count, sel = ts.sel, g = &ts.grid}, true
	}
	if vs, is_view := &t.icon_views[view]; is_view {
		return {list = vs.list, cols = vs.cols, tile = vs.tile, gap = vs.gap, count = vs.count, sel = vs.sel, g = &vs.grid,
			placed = vs if vs.placed else nil}, true
	}
	return {}, false
}

@(private)
grid_selection_changed :: proc(ui: ^Ui($Msg), view: Node) {
	geom, ok := grid_of(&ui.tree, view)
	if !ok do return
	ask_rebuild(ui) // items restyle from the selection
	if h, has := ui.on_int[view]; has do handler_send(ui, h, geom.sel.cursor if geom.sel != nil else -1, view)
}

// grid_item_click handles a click on item `index` of a table or icon view.
@(private)
grid_item_click :: proc(ui: ^Ui($Msg), view: Node, index: int) -> bool {
	t := &ui.tree
	geom, ok := grid_of(t, view)
	if !ok do return false
	set_focus(t, view, false)
	now := t.now_ms
	last_click: ^f64
	last_item: ^int
	if ts, is_table := &t.tables[view]; is_table {
		last_click, last_item = &ts.last_click, &ts.last_row
	} else {
		vs := &t.icon_views[view]
		last_click, last_item = &vs.last_click, &vs.last_item
	}
	double := last_item^ == index && now - last_click^ < TABLE_DOUBLE_CLICK_MS && now > 0
	last_click^, last_item^ = now, index
	mods := ui.pointer.mods
	// a plain click on the one selected item, when the view edits in
	// place: an edit request unless a second click follows (a double)
	was_the_one := geom.sel != nil && mods == {} && selection_count(geom.sel) == 1 && selection_contains(geom.sel, index) && geom.sel.cursor == index
	if geom.sel != nil {
		switch {
		case .Shift in mods: selection_range(geom.sel, index)
		case .Ctrl in mods:  selection_toggle(geom.sel, index)
		case:                selection_set(geom.sel, index)
		}
		grid_selection_changed(ui, view)
	}
	if double {
		ui.edit_pending = {}
		if h, has := ui.on_activate[view]; has do handler_send(ui, h, index, view)
	} else {
		// A plain click on a row, as distinct from arriving at it: on_select
		// fires for every change of selection (arrow keys, a marquee,
		// type-ahead) and cannot tell them apart. Only a plain click counts:
		// a Ctrl or Shift click builds a selection, and the second click of a
		// double belongs to on_activate. Same meaning as `tree_item`'s
		// `on_click`.
		if mods == {} {
			if h, has := ui.on_row_click[view]; has do handler_send(ui, h, index, view)
		}
		if was_the_one && (view in ui.on_edit_cell || view in ui.on_edit) {
			edit_pending_start(ui, view, index, grid_column_at(ui, view))
		}
	}
	return true
}

// grid_column_at is the declared column of the cell under the pointer (a
// table), 0 for a tile.
@(private)
grid_column_at :: proc(ui: ^Ui($Msg), view: Node) -> int {
	t := &ui.tree
	if _, is_table := t.tables[view]; !is_table do return 0
	for cur := ui.pointer.hover; cur != NODE_NONE; cur = node_parent(t, cur) {
		parent := node_parent(t, cur)
		if _, is_row := ui.rows[parent]; is_row {
			i := 0
			for c := node_first(t, parent); c != NODE_NONE && c != cur; c = node_next(t, c) do i += 1
			return i
		}
	}
	return 0
}

// ------------------------------------------------------------ context

// context_press handles a right-click: in an editor with on_context it
// sends the Document position (area_context_press); on an item it selects
// it first if it was not selected (a multi-selection is kept) and sends
// `on_context` with its index; on a table's or icon view's background it
// sends -1. The position is remembered for context_menu.
@(private)
context_press :: proc(ui: ^Ui($Msg), pos: [2]f32) -> bool {
	t := &ui.tree
	if area_context_press(ui, pos) do return true // an editor with on_context: the caret moves there unless it is on the selection
	if input_context_press(ui, pos) do return true // …and a field given one, the same way
	hit := hit_test(t, pos)
	target := interactive_target(ui, hit)
	if ref, ok := ui.rows[target]; ok {
		if geom, has := grid_of(t, ref.table); has && geom.sel != nil && !selection_contains(geom.sel, ref.index) {
			selection_set(geom.sel, ref.index)
			grid_selection_changed(ui, ref.table)
		}
		return context_send(ui, ref.table, ref.index, pos)
	}
	for cur := hit; cur != NODE_NONE; cur = node_get(t, cur).parent {
		if m, has := ui.context_clicks[cur]; has { // a button with a menu of its own (a tray icon)
			if .Disabled in node_get(t, cur).flags do return false
			ui.context_pos = pos
			if .Focusable in node_get(t, cur).flags do set_focus(t, cur, false) // a context_area is no control: focus stays
			append(&ui.msgs, m)
			return true
		}
		if tr, is_tree_row := t.tree_rows[cur]; is_tree_row {
			if _, has := ui.on_context[cur]; has do return tree_context_send(ui, tr.tree, cur, pos)
		}
		if _, is_grid := grid_of(t, cur); is_grid do return context_send(ui, cur, -1, pos)
	}
	return false
}

// tree_context_send: a tree item's context request; the cursor moves to it
// (selection is the app's) and its on_context gets the item's tag.
@(private)
tree_context_send :: proc(ui: ^Ui($Msg), tree, row: Node, pos: [2]f32) -> bool {
	t := &ui.tree
	ui.context_pos = pos
	set_focus(t, tree, false)
	tree_set_cursor(t, tree, row)
	h := ui.on_context[row]
	return handler_send(ui, h, int(node_get(t, row).tag), row)
}

@(private)
context_send :: proc(ui: ^Ui($Msg), view: Node, index: int, pos: [2]f32) -> bool {
	ui.context_pos = pos
	set_focus(&ui.tree, view, false)
	if h, ok := ui.on_context[view]; ok do return handler_send(ui, h, index, view)
	return false
}

// context_key is the keyboard form (Menu key, Shift+F10): a focused
// editor's on_context at its caret, or a focused button's context message,
// its menu opening under it; else the focused grid's cursor item, at the item's position (or the view's top-left corner).
@(private)
context_key :: proc(ui: ^Ui($Msg)) -> bool {
	t := &ui.tree
	view := t.focus
	if view != NODE_NONE do set_focus(t, view, true) // the keyboard is in use: the ring shows, and a menu this opens starts highlighted
	if area_context_key(ui, view) do return true // an editor with on_context: at the caret
	if m, has := ui.context_clicks[view]; has {
		d := node_get(t, view)
		if d == nil || .Disabled in d.flags do return false
		ui.context_pos = {d.abs.x, d.abs.y + d.abs.h}
		append(&ui.msgs, m)
		return true
	}
	if tv, is_tree := t.tree_views[view]; is_tree {
		if _, has := ui.on_context[tv.cursor]; !has do return context_area_key(ui, view)
		rd := node_get(t, tv.cursor)
		if rd == nil do return false
		return tree_context_send(ui, view, tv.cursor, {rd.abs.x + min(rd.abs.w / 2, 24), rd.abs.y + rd.abs.h / 2})
	}
	geom, ok := grid_of(t, view)
	if !ok do return context_area_key(ui, view)
	vd := node_get(t, view)
	index := geom.sel.cursor if geom.sel != nil else -1
	pos := [2]f32{vd.abs.x + 8, vd.abs.y + 8}
	for n, ref in ui.rows {
		if ref.table == view && ref.index == index {
			if d := node_get(t, n); d != nil do pos = {d.abs.x + min(d.abs.w / 2, 24), d.abs.y + d.abs.h / 2}
			break
		}
	}
	return context_send(ui, view, index, pos)
}

// context_area_key: the Menu key on a control without a menu of its own
// asks for the menu of the nearest context_area around it, placed below the
// control as its own would be; a right-click walks up the same way.
@(private)
context_area_key :: proc(ui: ^Ui($Msg), focused: Node) -> bool {
	t := &ui.tree
	fd := node_get(t, focused)
	if fd == nil do return false
	for cur := fd.parent; cur != NODE_NONE; cur = node_get(t, cur).parent {
		m, has := ui.context_clicks[cur]
		if !has do continue
		if .Disabled in node_get(t, cur).flags do return false
		ui.context_pos = {fd.abs.x, fd.abs.y + fd.abs.h}
		append(&ui.msgs, m)
		return true
	}
	return false
}

// ------------------------------------------------------------ marquee

// grid_content converts a window position to content coordinates of the
// list of `view` (scroll offset applied).
@(private)
grid_content :: proc(t: ^Tree, geom: Grid_Geom, pos: [2]f32) -> [2]f32 {
	ld := node_get(t, geom.list)
	off := scroll_offset(t, geom.list)
	return pos - {ld.abs.x + ld.layout.padding[3], ld.abs.y + ld.layout.padding[0]} + off
}

// Band_Pending is a press on the blank part of a table row (past a cell's
// text): a click there selects the row as usual, a drag past the slop turns
// it into a rubber band from the press point.
Band_Pending :: struct {
	view:  Node,
	start: [2]f32,
}

// grid_press starts a rubber band when a press lands on empty space inside a
// table's or icon view's body (not on an item), and arms one when it lands
// on the blank part of a table row.
@(private)
grid_press :: proc(ui: ^Ui($Msg), pos: [2]f32) -> bool {
	t := &ui.tree
	hit := hit_test(t, pos) // the press must land in the list itself, not on something floating over it
	if hit == NODE_NONE || overlay_child_of(t, hit) != NODE_NONE do return false
	if ref, on_item := ui.rows[ui.pointer.hover]; on_item {
		// on a table row: the cell's text / icon is the item; the rest of the
		// cell and the row is blank and may become a band
		if _, is_table := t.tables[ref.table]; is_table {
			hd := node_get(t, hit)
			blank := hd != nil && (hd.access.role == .Cell || hd.access.role == .Row)
			if blank do ui.band_pending = {view = ref.table, start = pos}
		}
		return false
	}
	for view in t.tables do if grid_press_in(ui, view, hit, pos) do return true
	for view in t.icon_views do if grid_press_in(ui, view, hit, pos) do return true
	return false
}

// grid_band_pending_move turns an armed press into a band once the pointer
// moves past the slop; the press stops being a click.
@(private)
grid_band_pending_move :: proc(ui: ^Ui($Msg), pos: [2]f32) -> bool {
	t := &ui.tree
	bp := ui.band_pending
	d := pos - bp.start
	if abs(d.x) < TOUCH_SLOP && abs(d.y) < TOUCH_SLOP do return false
	ui.band_pending = {}
	if pd := node_get(t, ui.pointer.pressed); pd != nil {
		pd.flags -= {.Pressed}
		mark_paint_dirty(t, ui.pointer.pressed)
	}
	ui.pointer.pressed = NODE_NONE
	if !grid_start_band(ui, bp.view, bp.start) do return false
	return grid_marquee_drag(ui, pos)
}

@(private)
grid_press_in :: proc(ui: ^Ui($Msg), view: Node, hit: Node, pos: [2]f32) -> bool {
	t := &ui.tree
	geom, ok := grid_of(t, view)
	if !ok || geom.sel == nil do return false
	ld := node_get(t, geom.list)
	if ld == nil || !node_within(t, hit, geom.list) do return false
	// a control built in a cell or on a tile (a row's ▸, a toggle, a tile's
	// Play) takes its own press, as it does anywhere else, rather than the
	// band swallowing it
	if c := ui.pointer.hover; c != NODE_NONE && c != view && c != geom.list && node_within(t, c, geom.list) do return false
	return grid_start_band(ui, view, pos)
}

// grid_start_band begins a rubber band of `view` at window position `pos`.
@(private)
grid_start_band :: proc(ui: ^Ui($Msg), view: Node, pos: [2]f32) -> bool {
	t := &ui.tree
	geom, ok := grid_of(t, view)
	if !ok || geom.sel == nil do return false
	set_focus(t, view, false)
	g := geom.g
	g.marquee = true
	g.m_start = grid_content(t, geom, pos)
	g.m_cur = g.m_start
	g.m_add = .Ctrl in ui.pointer.mods && geom.sel.multi
	clear(&g.base)
	if g.m_add {
		for i in geom.sel.rows do g.base[i] = {}
	} else if selection_count(geom.sel) > 0 {
		selection_clear(geom.sel)
		grid_selection_changed(ui, view)
	}
	ui.marquee = view
	mark_paint_dirty(t, view)
	return true
}

@(private)
grid_marquee_drag :: proc(ui: ^Ui($Msg), pos: [2]f32) -> bool {
	t := &ui.tree
	view := ui.marquee
	geom, ok := grid_of(t, view)
	if !ok {
		ui.marquee = NODE_NONE
		return false
	}
	g := geom.g
	g.m_cur = grid_content(t, geom, pos)
	// items form a uniform grid, so the band selects by arithmetic — built or not
	lo := [2]f32{min(g.m_start.x, g.m_cur.x), min(g.m_start.y, g.m_cur.y)}
	hi := [2]f32{max(g.m_start.x, g.m_cur.x), max(g.m_start.y, g.m_cur.y)}
	pitch := geom.tile + geom.gap
	c0 := max(int(math.floor(lo.x / pitch.x)), 0)
	c1 := int(math.floor(hi.x / pitch.x))
	if geom.placed == nil do c1 = min(c1, geom.cols - 1)
	r0 := max(int(math.floor(lo.y / pitch.y)), 0)
	r1 := int(math.floor(hi.y / pitch.y))
	sel := geom.sel
	clear(&sel.rows)
	for i in g.base do sel.rows[i] = {}
	if hi.x >= 0 && hi.y >= 0 {
		for r in r0 ..= r1 {
			for c in c0 ..= c1 {
				// the band must touch the item itself, not just the gap after it
				if lo.x > f32(c) * pitch.x + geom.tile.x || lo.y > f32(r) * pitch.y + geom.tile.y do continue
				if geom.placed != nil { // whoever is in that cell, not whoever the index says
					if i := icon_view_item_at(geom.placed, {c, r}); i >= 0 do sel.rows[i] = {}
					continue
				}
				i := r * geom.cols + c
				if i < geom.count do sel.rows[i] = {}
			}
		}
	}
	mark_paint_dirty(t, view)
	ask_rebuild(ui)
	return true
}

@(private)
grid_marquee_release :: proc(ui: ^Ui($Msg)) {
	t := &ui.tree
	view := ui.marquee
	ui.marquee = NODE_NONE
	geom, ok := grid_of(t, view)
	if !ok do return
	geom.g.marquee = false
	mark_paint_dirty(t, view)
	if geom.sel != nil {
		if selection_count(geom.sel) > 0 && geom.sel.cursor < 0 {
			for i in geom.sel.rows {
				geom.sel.cursor, geom.sel.anchor = i, i
				break
			}
		}
		grid_selection_changed(ui, view)
	}
}

// paint_marquee draws the rubber band of `list` (called from the view's
// paint_over): its edge in `color`, its fill the same at 15 %.
@(private)
paint_marquee :: proc(t: ^Tree, list: Node, g: ^Grid_Sel, l: ^Layer, color: Color) {
	if !g.marquee do return
	ld := node_get(t, list)
	if ld == nil do return
	off := scroll_offset(t, list)
	origin := [2]f32{ld.abs.x + ld.layout.padding[3], ld.abs.y + ld.layout.padding[0]} - off
	lo := [2]f32{min(g.m_start.x, g.m_cur.x), min(g.m_start.y, g.m_cur.y)} + origin
	hi := [2]f32{max(g.m_start.x, g.m_cur.x), max(g.m_start.y, g.m_cur.y)} + origin
	fill := color
	fill.a = 0.15 * t.paint_opacity
	border := color
	border.a *= t.paint_opacity
	append(&l.cmds, Draw_Rect{rect = {lo.x, lo.y, hi.x - lo.x, hi.y - lo.y}, color = fill, radius = 2, border_w = 1, border = border})
}
