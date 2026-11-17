package baldr

// table is a grid with a sticky header and virtual rows: only the visible
// rows exist as nodes (it is a `list` underneath). Columns are fixed
// (`width`) or flexible (`flex`, the default); the header's dividers show
// as hairlines, the pointer becomes a resize cursor over them and a guide
// runs down the table while one is dragged; a header cell dragged sideways
// moves its column to another slot (a drop indicator shows where). A
// click on a sortable header asks the app to sort (`on_sort`; the app
// reorders its data). With a header cell focused, Shift+Left/Right resizes
// and Ctrl+Left/Right reorders, so nothing needs the pointer.
//
// Rows are selected by click, Ctrl-click, Shift-click, and the keyboard
// cursor (Up/Down, Shift to extend, Space to toggle, Ctrl+A, Home/End,
// Page Up/Down) — the app-owned `Selection` is edited in place and
// `on_select` carries the cursor row; Enter or a double-click sends
// `on_activate`. Column order and dragged widths are the table's own state
// (like a scroll offset); columns are declared and cells built in the
// declared order regardless. Accessibility: Table named by `label`,
// Column_Header cells (Selected = sorted), Row (Selected) named by its
// first cell, Cell nodes; the table is the focusable widget.
//
//	first, last := baldr.table(ui, COLS, len(s.files), &s.sel, on_select = …, on_activate = …, sort = s.sort, on_sort = …, label = "Files"); {
//		defer baldr.end(ui)
//		for i in first ..< last {
//			baldr.table_row(ui, i); {
//				defer baldr.end(ui)
//				baldr.cell_text(ui, s.files[i].name)
//				baldr.cell_text(ui, size_str(s.files[i].size))
//			}
//		}
//	}

import "core:fmt"

// Column describes one column of a `table`: its heading, how wide it is
// (`width` for a fixed size, otherwise `flex` shares the free width and
// `min_width` bounds it), whether its cells are right-aligned numbers, and
// whether its header sorts. Pass a slice of these to `table`; the app owns
// the slice and the strings in it, and they must outlive the view.
Column :: struct {
	title:     string,
	width:     f32,  // fixed logical px; 0 = flexible
	flex:      f32,  // share of the free width for a flexible column (0 = 1)
	min_width: f32,  // flexible columns never go narrower (0 = 60)
	numeric:   bool, // right-aligned cells
	sortable:  bool,
}

// Sort is the app's current sort; `column` -1 = none. Shown in the header.
Sort :: struct {
	column:     int,
	descending: bool,
}

Table_State :: struct {
	label_of:       Label_Of, // row labels for type-ahead (nil: none)
	label_user:     rawptr,
	reveal_pending: int,      // row + 1 to scroll into view after the next layout (0: none)
	cols:       [dynamic]Column,
	widths:     [dynamic]f32, // per declared column: a width the user dragged to (0 = as declared)
	order:      [dynamic]int, // display slot → declared column
	xs, ws:     [dynamic]f32, // per declared column: resolved x (within the row) and width
	total_w:    f32,
	built_w:    f32,          // inner width the geometry was resolved for
	count:      int,
	row_height: f32,
	header_height: f32,
	look:       Table_Look, // resolved at build, for the rows and cells built inside it
	list:       Node,
	header:     Node,
	sel:        ^Selection,
	cell_i:     int,  // next cell index while a row is being built
	last_click: f64,
	last_row:   int,
	grid:       Grid_Sel, // rubber-band state over the rows (widget_grid.odin)
	hover_col:  int, // display slot whose right divider is under the pointer (-1 none)
	resize_col: int, // display slot being resized (-1 none)
	drag_slot:  int, // display slot being dragged (-1 none)
	drop_slot:  int, // insertion slot the drag would land in (-1 none)
}

// Row_Ref names one row of one table — the table's node and the row index —
// as a table's handlers report it back.
Row_Ref :: struct {
	table: Node,
	index: int,
}

// Col_Ref names one column of one table, by the slot it is displayed in
// rather than by its place in the `Column` slice, which a column move changes.
Col_Ref :: struct {
	table: Node,
	col:   int, // display slot
}

// Col_Resize is a drag on a table's column divider: where it started and how
// wide the column was then.
Col_Resize :: struct {
	table:   Node,
	col:     int, // display slot
	start_x: f32,
	start_w: f32,
}

// Col_Move is a drag of a table's column header to another slot, and whether
// it has travelled far enough to count as a move rather than a click.
Col_Move :: struct {
	table:    Node,
	slot:     int,
	start_x:  f32,
	dragging: bool,
}

TABLE_ROW_HEIGHT      :: f32(36)
TABLE_DIVIDER_ZONE    :: f32(5) // px either side of a header divider that grab it
TABLE_MIN_COL         :: f32(60)
TABLE_DOUBLE_CLICK_MS :: 400.0
TABLE_KEY_RESIZE_STEP :: f32(8)

@(private)
table_state_destroy :: proc(ts: ^Table_State) {
	delete(ts.cols)
	delete(ts.widths)
	delete(ts.order)
	delete(ts.xs)
	delete(ts.ws)
	delete(ts.grid.base)
}

// table builds the grid and opens the scope its rows go in; it returns the
// `first, last` rows to build. `rows` sizes it to that many rows plus its
// header instead of filling the space given (an explicit `height` wins, and
// a sized table does not flex), so an app never estimates a row height from
// its fonts. `row_height` 0 takes the theme's (`table_look`); an app's own
// sets the header's height too. `on_select` follows what is selected, every arrow key
// included, so a row that opens on one click wants `on_click`: a plain
// primary click (no Ctrl or Shift, not the second of a double), as on
// `tree_item`. `on_activate` is a double-click or Enter. An Enter or
// Space the app bound with `shortcut` is the app's, and with no
// `on_activate` Enter goes on to the window.
table :: proc(ui: ^Ui($Msg), columns: []Column, count: int, selection: ^Selection = nil,
	on_select: Handler(Msg, int) = nil, on_click: Handler(Msg, int) = nil,
	on_activate: Handler(Msg, int) = nil, on_context: Handler(Msg, int) = nil,
	sort: Sort = {column = -1}, on_sort: Handler(Msg, int) = nil,
	drag: string = "", on_drop: Handler(Msg, Drop) = nil, accepts: string = "", drag_files: Files_Of = nil, drag_user: rawptr = nil, drag_files_out: Files_Out = nil,
	on_rest: Handler(Msg, Drag_Rest) = nil,
	on_drag_out: Handler(Msg, Drop) = nil, on_range: Handler(Msg, [2]int) = nil,
	on_zoom: Handler(Msg, f32) = nil, on_edit: Handler(Msg, Cell_Ref) = nil,
	label_of: Label_Of = nil, label_user: rawptr = nil,
	row_height: f32 = 0, rows: int = 0, flex: f32 = 1, height: f32 = 0, label: string = "",
	gutter := false, key: u64 = 0, loc := #caller_location) -> (first, last: int) {
	t := &ui.tree
	th := &t.theme
	lk := table_look(th)
	n, created := reconcile_child(ui, .Custom, key, loc)
	d := node_get(t, n)
	if created {
		d.access.role = .Table
		d.flags += {.Focusable, .Clips}
		d.kind = Custom_Kind{paint_over = paint_table_over}
		t.tables[n] = {hover_col = -1, resize_col = -1, drag_slot = -1, drop_slot = -1}
	}
	set_name(t, n, label)
	// `rows` sizes the table to that many rows and its header, instead of
	// filling what it is given. An explicit `height` still wins, and a
	// sized table does not also flex.
	row_px := row_height if row_height > 0 else lk.row_height
	hdr_px := row_height if row_height > 0 else lk.header_height
	box_h, box_flex := height, flex
	if rows > 0 && height <= 0 {
		// The list has no gap. A header as tall as a row keeps the one product,
		// which a sum of the two can miss by an ulp.
		box_h = row_px * f32(rows + 1) if hdr_px == row_px else row_px * f32(rows) + hdr_px
		box_flex = 0
	}
	set_layout(t, n, Layout_Props{axis = .Column, align = .Stretch, flex = box_flex, height = box_h})
	st := d.style
	st.bg = lk.fill
	st.radius = lk.radius
	st.border_w = lk.border_width
	st.border = lk.border
	set_style(t, n, st)
	ts := &t.tables[n]
	if len(ts.cols) != len(columns) {
		clear(&ts.cols)
		append(&ts.cols, ..columns)
		resize(&ts.widths, len(columns))
		clear(&ts.order)
		for i in 0 ..< len(columns) do append(&ts.order, i)
	} else {
		for c, i in columns do ts.cols[i] = c
	}
	ts.count = max(count, 0)
	ts.row_height = row_px
	ts.header_height = hdr_px
	ts.look = lk
	ts.sel = selection
	ts.label_of, ts.label_user = label_of, label_user // type-ahead matches these
	// The `reveal_index` command, taken if it named this table: bring that
	// row into view, once, after layout. Asking for the row already shown is
	// asking again (reveal_cmd.odin).
	if ask, taken := reveal_taken(ui, key, by_index = true); taken && ask.index >= 0 {
		ts.reveal_pending = ask.index + 1
	}
	if selection != nil do selection_ensure(selection)
	inner_w := d.rect.w - 2 * st.border_w
	if inner_w <= 0 do inner_w = max(t.viewport.x - 48, 200) // first build: a guess, corrected after the first frame
	// The gutter comes off the columns, not off the rows alone: the header
	// is not inside the scroll, so narrowing only the body would leave the
	// last column's heading a gutter right of its cells.
	if gutter do inner_w = max(inner_w - scrollbar_look(th).gutter, 1)
	table_resolve(ts, inner_w)
	ui.on_int[n] = on_select
	ui.on_activate[n] = on_activate
	if handler_live(on_click) { ui.on_row_click[n] = on_click } else { delete_key(&ui.on_row_click, n) }
	ui.on_context[n] = on_context
	grid_drag_register(ui, n, drag, on_drop, accepts, drag_files, drag_user, drag_files_out) // rows drag as `drag` (a selection drags whole) and take drops On
	grid_rest_register(ui, n, on_rest) // …and spring open when a drag rests on one
	if handler_live(on_drag_out) { ui.on_drag_out[n] = on_drag_out } else { delete_key(&ui.on_drag_out, n) } // a row dragged out and dropped in another app
	zoom_register(ui, n, on_zoom) // Ctrl + wheel: the app's zoom
	if handler_live(on_edit) { ui.on_edit_cell[n] = on_edit } else { delete_key(&ui.on_edit_cell, n) } // F2 / a slow click: edit a cell in place
	open_scope(ui, n, loc)

	// header
	hdr, hcreated := reconcile_child(ui, .Box, 0, loc)
	hd := node_get(t, hdr)
	if hcreated {
		hd.access.role = .Row
		set_name(t, hdr, "Header")
	}
	set_layout(t, hdr, Layout_Props{axis = .Stack, height = ts.header_height})
	hs := hd.style
	hs.bg = lk.header_fill
	set_style(t, hdr, hs)
	ts.header = hdr
	open_scope(ui, hdr, loc)
	hfam := look_family(t, lk.header_text.family)
	for c, i in ts.cols {
		hc, ccreated := reconcile_child(ui, .Box, u64(i + 1), loc)
		cd := node_get(t, hc)
		if ccreated {
			cd.access.role = .Column_Header
			cd.flags += {.Clips, .Focusable} // keyboard: Enter sorts, Shift+arrows resize, Ctrl+arrows reorder
		}
		cd.tag = u64(i)
		set_name(t, hc, c.title)
		lp := table_cell_layout(ts, i, ts.header_height)
		lp.justify = .End if c.numeric else .Start
		set_layout(t, hc, lp)
		ui.on_int[hc] = on_sort if c.sortable else nil
		open_scope(ui, hc, loc)
		lbl := text(ui, c.title, role = lk.header_text.role, size = lk.header_text.size, color = lk.header_ink, nowrap = true,
			weight = lk.header_text.weight, family = hfam, loc = loc)
		set_role(t, lbl, .None)
		if sort.column == i {
			arrow := text(ui, "⌄" if sort.descending else "⌃", role = lk.header_text.role, size = lk.header_text.size, color = lk.header_ink,
				weight = lk.header_text.weight, family = hfam, loc = loc)
			set_role(t, arrow, .None)
			cd.access.states += {.Selected}
		} else {
			cd.access.states -= {.Selected}
		}
		close_scope(ui)
	}
	close_scope(ui)

	// body: the virtual list; its scope stays open for the caller's rows
	// The rows are a `list` of the table's own, kept out of the app's key
	// space by `view_inner` (reveal_cmd.odin), so an app list keyed 1 still
	// gets its own reveals.
	view_inner_begin(ui)
	// No gap or padding whatever a list's own style says: the rubber band and
	// table_reveal count rows from the list's top at the row pitch.
	first, last = list(ui, ts.count, ts.row_height, gap = f32(0), padding = f32(0), flex = 1, tail_pad = ts.row_height, on_range = on_range, gutter = gutter, key = 1, loc = loc)
	view_inner_end(ui)
	ts.list = ui.scopes[len(ui.scopes) - 1].node
	ui.scopes[len(ui.scopes) - 1].extra_pops = 1 // end(ui) closes the list and the table
	node_get(t, ts.list).access.role = .None // the Table above is the accessible container
	return
}

// table_resolve turns the column declarations, dragged widths and display
// order into an x / width per declared column for `inner_w`.
@(private)
table_resolve :: proc(ts: ^Table_State, inner_w: f32) {
	n := len(ts.cols)
	resize(&ts.xs, n)
	resize(&ts.ws, n)
	fixed_total, flex_total: f32
	for c, i in ts.cols {
		w := ts.widths[i] if ts.widths[i] > 0 else c.width
		if w > 0 {
			ts.ws[i] = w
			fixed_total += w
		} else {
			ts.ws[i] = 0
			flex_total += c.flex if c.flex > 0 else 1
		}
	}
	free := max(inner_w - fixed_total, 0)
	for c, i in ts.cols {
		if ts.ws[i] > 0 do continue
		f := c.flex if c.flex > 0 else 1
		ts.ws[i] = max(free * f / flex_total, c.min_width if c.min_width > 0 else TABLE_MIN_COL)
	}
	x: f32 = 0
	for slot in 0 ..< n {
		i := ts.order[slot]
		ts.xs[i] = x
		x += ts.ws[i]
	}
	ts.total_w = x
	ts.built_w = inner_w
}

// table_cell_layout is the layout every cell of declared column `i` uses
// (header and body alike): a slot in the row's stack at the resolved x,
// `height` tall.
@(private)
table_cell_layout :: proc(ts: ^Table_State, i: int, height: f32) -> Layout_Props {
	return Layout_Props{
		axis = .Row, align = .Center, padding = ts.look.cell_padding, gap = ts.look.cell_gap,
		offset = {ts.xs[i], 0}, width = ts.ws[i], height = height,
	}
}

// table_row opens the row for data index `index` (keyed by it). Build one
// cell per column inside, in declared order, then end.
table_row :: proc(ui: ^Ui($Msg), index: int, loc := #caller_location) -> Node {
	t := &ui.tree
	list_node := ui.scopes[len(ui.scopes) - 1].node
	tbl := node_parent(t, list_node)
	ts := &t.tables[tbl]
	n, created := reconcile_child(ui, .Box, u64(index + 1), loc)
	d := node_get(t, n)
	if created {
		d.access.role = .Row
		d.flags += {.Clips}
	}
	d.tag = u64(index)
	ui.rows[n] = {table = tbl, index = index}
	grid_row_dnd(ui, tbl, n, index, ts.sel if ts != nil else nil)
	if ts != nil {
		ts.cell_i = 0
		set_layout(t, n, Layout_Props{axis = .Stack, height = ts.row_height})
		selected := ts.sel != nil && selection_contains(ts.sel, index)
		is_cursor := ts.sel != nil && ts.sel.cursor == index
		if is_cursor do set_active_item(t, tbl, n) // the table keeps the focus; this is the row a reader should hear
		if was := .Selected in d.access.states; was != selected {
			if selected { d.access.states += {.Selected} } else { d.access.states -= {.Selected} }
		}
		st := d.style
		st.bg = ts.look.selected_fill if selected else Color{}
		st.radius = ts.look.row_radius
		st.border_w = ts.look.cursor_border_width if is_cursor else 0
		st.border = ts.look.cursor_border
		set_style(t, n, st)
		if len(d.access.name) == 0 do set_name(t, n, fmt.tprintf("Row %d", index + 1))
	}
	open_scope(ui, n, loc)
	return n
}

// cell opens the next cell of the row being built (the next declared
// column's slot). Close with end. Use cell_text for the common case.
cell :: proc(ui: ^Ui($Msg), loc := #caller_location) -> Node {
	t := &ui.tree
	row := ui.scopes[len(ui.scopes) - 1].node
	ref, ok := ui.rows[row]
	n, created := reconcile_child(ui, .Box, 0, loc)
	d := node_get(t, n)
	if created {
		d.access.role = .Cell
		d.flags += {.Clips}
	}
	if ok {
		ts := &t.tables[ref.table]
		i := ts.cell_i
		ts.cell_i += 1
		if i < len(ts.cols) {
			lp := table_cell_layout(ts, i, ts.row_height)
			lp.justify = .End if ts.cols[i].numeric else .Start
			set_layout(t, n, lp)
		}
	}
	open_scope(ui, n, loc)
	return n
}

// table_label_cells names a table's unnamed cell controls (a text field,
// a number field, a select built inside `cell`) after their column
// header, the way a screen reader expects a data table to read: the
// control is labelled by the header cell. Called as the rows close.
@(private)
table_label_cells :: proc(ui: ^Ui($Msg), list: Node) {
	t := &ui.tree
	tbl := node_parent(t, list)
	ts, is_table := &t.tables[tbl]
	if !is_table || ts.list != list do return
	headers := make([dynamic]Node, context.temp_allocator)
	for h := node_first(t, ts.header); h != NODE_NONE; h = node_next(t, h) do append(&headers, h)
	for row := node_first(t, list); row != NODE_NONE; row = node_next(t, row) {
		if _, is_row := ui.rows[row]; !is_row do continue
		col := 0
		for c := node_first(t, row); c != NODE_NONE; c = node_next(t, c) {
			if col < len(headers) do label_unnamed(t, c, headers[col])
			col += 1
		}
	}
}

@(private)
label_unnamed :: proc(t: ^Tree, n: Node, by: Node) {
	d := node_get(t, n)
	if d == nil do return
	if d.access.role in INTERACTIVE_ROLES && len(d.access.name) == 0 && d.access.labelled_by == NODE_NONE do d.access.labelled_by = by
	for c := d.first; c != NODE_NONE; c = node_get(t, c).next do label_unnamed(t, c, by)
}

// cell_text is a cell holding one line of text (clipped, never wrapped);
// the first cell's text names the row for assistive technology.
cell_text :: proc(ui: ^Ui($Msg), s: string, muted := false, icon: Icon = .None, tabular := false, loc := #caller_location) -> Node {
	t := &ui.tree
	row := ui.scopes[len(ui.scopes) - 1].node
	lk: Table_Look
	selected, in_table := false, false
	if ref, ok := ui.rows[row]; ok {
		if owner, is_table := &t.tables[ref.table]; is_table {
			lk, in_table = owner.look, true
			if rd := node_get(t, row); rd != nil do selected = .Selected in rd.access.states
		}
	}
	if !in_table do lk = table_look(&t.theme) // a cell outside a table row: the theme's
	ink := lk.muted_ink if muted else lk.ink
	if selected do ink = lk.selected_muted_ink if muted else lk.selected_ink
	n := cell(ui, loc)
	if icon != .None do baldr_icon(ui, icon, lk.icon_size, ink, loc)
	txt := text(ui, s, role = lk.cell_text.role, size = lk.cell_text.size, color = ink, nowrap = true, ellipsis = .End,
		weight = lk.cell_text.weight, family = look_family(t, lk.cell_text.family), tabular = tabular, loc = loc)
	set_role(t, txt, .None)
	close_scope(ui)
	if ref, ok := ui.rows[row]; ok {
		if ts := &t.tables[ref.table]; ts != nil && ts.cell_i == 1 do set_name(t, row, s)
	}
	return n
}

// ------------------------------------------------------------ painting

// paint_table_over draws, after the rows: hairline dividers between header
// cells, the resize guide (a primary line down the whole table while a
// divider is hovered or dragged), and the drop indicator of a column drag.
@(private)
paint_table_over :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer) {
	ts, ok := &t.tables[n]
	if !ok do return
	lk := table_look(&t.theme) // paint's theme: an area's or the glass one where it is swapped
	paint_marquee(t, ts.list, &ts.grid, l, lk.marquee)
	hd := node_get(t, ts.header)
	if hd == nil do return
	line := lk.divider
	line.a *= t.paint_opacity
	for slot in 0 ..< len(ts.order) - 1 {
		x := hd.abs.x + table_divider_x(ts, slot)
		append(&l.cmds, Draw_Rect{rect = {x - lk.divider_width / 2, hd.abs.y + lk.divider_inset, lk.divider_width, hd.abs.h - 2 * lk.divider_inset}, color = line})
	}
	guide := ts.resize_col if ts.resize_col >= 0 else ts.hover_col
	if guide >= 0 && guide < len(ts.order) - 1 {
		x := hd.abs.x + table_divider_x(ts, guide)
		c := lk.indicator
		c.a *= t.paint_opacity
		append(&l.cmds, Draw_Rect{rect = {x - 1, d.abs.y, 2, d.abs.h}, color = c})
	}
	if ts.drag_slot >= 0 && ts.drop_slot >= 0 {
		x := hd.abs.x + (ts.total_w if ts.drop_slot >= len(ts.order) else ts.xs[ts.order[ts.drop_slot]])
		c := lk.indicator
		c.a *= t.paint_opacity
		append(&l.cmds, Draw_Rect{rect = {x - 1.5, d.abs.y, 3, d.abs.h}, color = c, radius = 1.5})
		dim := lk.fill // the dragged heading fades toward the table's own fill
		dim.a = 0.35 * t.paint_opacity
		i := ts.order[ts.drag_slot]
		append(&l.cmds, Draw_Rect{rect = {hd.abs.x + ts.xs[i], hd.abs.y, ts.ws[i], hd.abs.h}, color = dim})
	}
}

// table_divider_x is the x (within the row) of the divider after display slot `slot`.
@(private)
table_divider_x :: proc(ts: ^Table_State, slot: int) -> f32 {
	i := ts.order[slot]
	return ts.xs[i] + ts.ws[i]
}

// ------------------------------------------------------------ behaviour

// table_reveal scrolls the body so data row `index` is visible, whether or
// not it is currently built.
@(private)
table_reveal :: proc(ui: ^Ui($Msg), tbl: Node, index: int) {
	t := &ui.tree
	ts := &t.tables[tbl]
	st, ok := t.scrolls[ts.list]
	if !ok do return
	pitch := ts.row_height + node_get(t, ts.list).layout.gap
	y := f32(index) * pitch
	off := st.offset.y
	if y < off {
		off = y
	} else if y + ts.row_height > off + st.viewport.y {
		off = y + ts.row_height - st.viewport.y
	}
	scroll_to_smooth(t, ts.list, {st.offset.x, off})
}

// table_of_header returns the table a header cell belongs to (or NONE).
@(private)
table_of_header :: proc(t: ^Tree, n: Node) -> (tbl: Node, slot: int) {
	d := node_get(t, n)
	if d == nil || d.access.role != .Column_Header do return NODE_NONE, -1
	hdr := d.parent
	tbl = node_parent(t, hdr)
	ts, ok := &t.tables[tbl]
	if !ok || ts.header != hdr do return NODE_NONE, -1
	for s in 0 ..< len(ts.order) do if ts.order[s] == int(d.tag) do return tbl, s
	return NODE_NONE, -1
}

// table_key handles keys while a table (or one of its header cells) has
// focus. Returns true if consumed.
table_key :: proc(ui: ^Ui($Msg), key: Key, mods: Mods) -> bool {
	t := &ui.tree
	// header cell: Shift+arrows resize, Ctrl+arrows reorder
	if htbl, slot := table_of_header(t, t.focus); htbl != NODE_NONE {
		ts := &t.tables[htbl]
		#partial switch key {
		case .Left, .Right:
			dir := -1 if key == .Left else 1
			if .Ctrl in mods {
				if table_move_column(ts, slot, slot + dir + (1 if dir > 0 else 0)) do ask_rebuild(ui)
				return true
			}
			if .Shift in mods {
				i := ts.order[slot]
				ts.widths[i] = max(ts.ws[i] + f32(dir) * TABLE_KEY_RESIZE_STEP, TABLE_MIN_COL)
				ask_rebuild(ui)
				return true
			}
		}
		return false
	}
	tbl := t.focus
	ts, ok := &t.tables[tbl]
	if !ok || ts.sel == nil || ts.count == 0 do return false
	sel := ts.sel
	move :: proc(ui: ^Ui($Msg), tbl: Node, ts: ^Table_State, to: int, mods: Mods) -> bool {
		row := clamp(to, 0, ts.count - 1)
		if .Shift in mods { selection_range(ts.sel, row) } else { selection_set(ts.sel, row) }
		table_reveal(ui, tbl, row)
		grid_selection_changed(ui, tbl)
		return true
	}
	#partial switch key {
	case .Down:  return move(ui, tbl, ts, sel.cursor + 1, mods)
	case .Up:    return move(ui, tbl, ts, sel.cursor - 1 if sel.cursor > 0 else 0, mods)
	case .Home:  return move(ui, tbl, ts, 0, mods)
	case .End:   return move(ui, tbl, ts, ts.count - 1, mods)
	case .Page_Down, .Page_Up:
		st, has := t.scrolls[ts.list]
		if !has do return false
		page := max(int(st.viewport.y / ts.row_height) - 1, 1)
		return move(ui, tbl, ts, sel.cursor + (page if key == .Page_Down else -page), mods)
	case .Space:
		if sel.cursor < 0 || shortcut_bound(ui, key, mods) do return false // the app's own Space (Quick Look) wins; Ctrl+Space still toggles
		selection_toggle(sel, sel.cursor)
		grid_selection_changed(ui, tbl)
		return true
	case .F2:
		if h, has := ui.on_edit_cell[tbl]; has && sel.cursor >= 0 do return handler_send(ui, h, Cell_Ref{sel.cursor, 0}, tbl)
		return false
	case .Enter:
		if sel.cursor < 0 || shortcut_bound(ui, key, mods) do return false // the app's own Alt+Enter (Properties) wins, as its Space does
		// With nothing to open (no on_activate, or the nil handler the map
		// always holds for one) Enter is not the table's: it goes on to the
		// window's shortcuts, and to a dialog's default button.
		return handler_send(ui, ui.on_activate[tbl], sel.cursor, tbl)
	case .A:
		if .Ctrl in mods && sel.multi {
			selection_all(sel, ts.count)
			grid_selection_changed(ui, tbl)
			return true
		}
	}
	return false
}

// table_move_column moves display slot `from` so that it lands at insertion
// slot `to` (0 ..= len). Returns true if the order changed.
@(private)
table_move_column :: proc(ts: ^Table_State, from, to: int) -> bool {
	n := len(ts.order)
	if from < 0 || from >= n do return false
	dest := clamp(to, 0, n)
	if dest == from || dest == from + 1 do return false
	col := ts.order[from]
	ordered_remove(&ts.order, from)
	if dest > from do dest -= 1
	inject_at(&ts.order, dest, col)
	return true
}

// table_divider_at finds the table and display slot whose divider is within
// TABLE_DIVIDER_ZONE of `pos` in a header.
@(private)
table_divider_at :: proc(t: ^Tree, pos: [2]f32) -> (tbl: Node, slot: int) {
	hit := hit_test(t, pos) // a menu floating over the header must not expose its dividers
	if hit == NODE_NONE || overlay_child_of(t, hit) != NODE_NONE do return NODE_NONE, -1
	for cand, &ts in t.tables {
		hd := node_get(t, ts.header)
		if hd == nil || !node_within(t, hit, ts.header) do continue
		for s in 0 ..< len(ts.order) - 1 {
			x := hd.abs.x + table_divider_x(&ts, s)
			if abs(pos.x - x) <= TABLE_DIVIDER_ZONE do return cand, s
		}
	}
	return NODE_NONE, -1
}

// table_hover_update tracks the divider under the pointer for the cursor
// and the guide line (pass a point outside every table to clear it).
// Returns true if paint changed.
@(private)
table_hover_update :: proc(ui: ^Ui($Msg), pos: [2]f32) -> (changed: bool) {
	t := &ui.tree
	tbl, slot := table_divider_at(t, pos)
	if ui.col_resize.table != NODE_NONE do tbl, slot = NODE_NONE, -1 // a drag owns the guide
	if tbl == ui.col_hover.table && slot == ui.col_hover.col do return false
	if old, ok := &t.tables[ui.col_hover.table]; ok {
		old.hover_col = -1
		mark_paint_dirty(t, ui.col_hover.table)
	}
	ui.col_hover = {table = tbl, col = slot}
	if ts, ok := &t.tables[tbl]; ok {
		ts.hover_col = slot
		mark_paint_dirty(t, tbl)
	}
	return true
}

// table_resize_press starts a column drag if `pos` is on a header divider.
@(private)
table_resize_press :: proc(ui: ^Ui($Msg), pos: [2]f32) -> bool {
	t := &ui.tree
	tbl, slot := table_divider_at(t, pos)
	if tbl == NODE_NONE do return false
	ts := &t.tables[tbl]
	i := ts.order[slot]
	// The divider must follow the pointer: columns to its left keep their
	// current size (flexible ones freeze at it), so only columns to the right
	// move — the convention of every desktop table.
	for s in 0 ..< slot {
		j := ts.order[s]
		if ts.widths[j] <= 0 && ts.cols[j].width <= 0 do ts.widths[j] = ts.ws[j]
	}
	ui.col_resize = {table = tbl, col = slot, start_x = pos.x, start_w = ts.ws[i]}
	ts.resize_col = slot
	mark_paint_dirty(t, tbl)
	return true
}

@(private)
table_resize_drag :: proc(ui: ^Ui($Msg), pos: [2]f32) -> bool {
	r := ui.col_resize
	ts := &ui.tree.tables[r.table]
	if ts == nil {
		ui.col_resize = {}
		return false
	}
	i := ts.order[r.col]
	w := max(r.start_w + (pos.x - r.start_x), TABLE_MIN_COL)
	if ts.widths[i] == w do return false
	ts.widths[i] = w
	ask_rebuild(ui)
	return true
}

// table_resize_release ends a divider drag: the guide goes unless the
// pointer still rests on the divider (then it is the hover guide).
@(private)
table_resize_release :: proc(ui: ^Ui($Msg), pos: [2]f32) {
	t := &ui.tree
	r := ui.col_resize
	ui.col_resize = {}
	if ts, ok := &t.tables[r.table]; ok {
		ts.resize_col = -1
		mark_paint_dirty(t, r.table)
	}
	table_hover_update(ui, pos)
}

// table_header_press remembers a press on a header cell's body as a
// possible column drag; the press itself proceeds as a click (sort).
@(private)
table_header_press :: proc(ui: ^Ui($Msg), pos: [2]f32) {
	t := &ui.tree
	tbl, slot := table_of_header(t, ui.pointer.hover)
	if tbl == NODE_NONE do return
	ui.col_move = {table = tbl, slot = slot, start_x = pos.x}
}

@(private)
table_move_drag :: proc(ui: ^Ui($Msg), pos: [2]f32) -> bool {
	t := &ui.tree
	m := &ui.col_move
	ts, ok := &t.tables[m.table]
	if !ok {
		m^ = {}
		return false
	}
	if !m.dragging {
		if abs(pos.x - m.start_x) < TOUCH_SLOP do return false
		m.dragging = true
		// the press will not become a click any more
		if d := node_get(t, ui.pointer.pressed); d != nil {
			d.flags -= {.Pressed}
			mark_paint_dirty(t, ui.pointer.pressed)
		}
		ui.pointer.pressed = NODE_NONE
		ts.drag_slot = m.slot
	}
	hd := node_get(t, ts.header)
	x := pos.x - hd.abs.x
	drop := len(ts.order)
	for s in 0 ..< len(ts.order) {
		i := ts.order[s]
		if x < ts.xs[i] + ts.ws[i] / 2 {
			drop = s
			break
		}
	}
	if drop != ts.drop_slot {
		ts.drop_slot = drop
		mark_paint_dirty(t, m.table)
	}
	return true
}

// table_move_release finishes a column drag. Returns true if the release
// was a drag (consumed), false if it was a plain click.
@(private)
table_move_release :: proc(ui: ^Ui($Msg)) -> bool {
	t := &ui.tree
	m := ui.col_move
	ui.col_move = {}
	ts, ok := &t.tables[m.table]
	if !ok do return false
	if !m.dragging do return false
	if table_move_column(ts, m.slot, ts.drop_slot) do ask_rebuild(ui)
	ts.drag_slot, ts.drop_slot = -1, -1
	mark_paint_dirty(t, m.table)
	return true
}

// table_tick asks for a rebuild when a table's or icon view's width changed
// since its geometry was resolved (a resize, the first frame).
@(private)
table_tick :: proc(ui: ^Ui($Msg)) {
	t := &ui.tree
	for n, &ts in t.tables { // an asked-for reveal, once the list has a size
		if ts.reveal_pending == 0 do continue
		if st, has := t.scrolls[ts.list]; has && st.viewport.y > 0 {
			table_reveal(ui, n, ts.reveal_pending - 1)
			ts.reveal_pending = 0
		}
	}
	for n, &vs in t.icon_views {
		if vs.reveal_pending == 0 do continue
		if st, has := t.scrolls[vs.list]; has && st.viewport.y > 0 {
			icon_view_reveal(ui, n, vs.reveal_pending - 1)
			vs.reveal_pending = 0
		}
	}
	for n, ts in t.tables {
		d := node_get(t, n)
		if d == nil do continue
		inner := d.rect.w - 2 * d.style.border_w
		if inner > 0 && abs(inner - ts.built_w) > 0.5 {
			ask_rebuild(ui)
			return
		}
	}
	for n, vs in t.icon_views {
		d := node_get(t, n)
		if d == nil do continue
		inner := d.rect.w - d.layout.padding[1] - d.layout.padding[3]
		if inner > 0 && abs(inner - vs.built_w) > 0.5 {
			ask_rebuild(ui)
			return
		}
	}
}
