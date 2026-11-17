package baldr

import "base:runtime"

// icon_view is the grid a file manager shows: tiles of an icon over a
// label, laid out in as many columns as fit, virtualised by row (only the
// visible rows exist as nodes). It shares `Selection` with table: click,
// Ctrl-click and Shift-click, a rubber band dragged over empty space (Ctrl
// adds to the selection), arrows that move the cursor across the grid,
// Shift to extend, Space, Ctrl+A, Home/End; `on_select` carries the cursor,
// Enter or a double-click sends `on_activate`. Accessibility: List named by
// `label`, List_Item tiles (Selected) named by their labels; the view is the
// focusable widget.
//
//	first, last := baldr.icon_view(ui, len(s.files), &s.sel, on_select = …, on_activate = …, label = "Files"); {
//		defer baldr.end(ui)
//		for i in first ..< last do baldr.icon_item(ui, i, s.files[i].icon, s.files[i].name)
//	}
//
// With `place_of` it is a placed grid instead of a flow — a desktop, where
// an icon stays where it was put. `place_of` gives each item its cell
// (`{-1, -1}`: the view picks a free one, flowing down the columns), a drag
// inside the view reports where it landed through `on_place`, and the app
// writes that down and hands it back; the view keeps no placement of its
// own, just as it keeps no selection. In that mode the arrows move by
// geometry — the nearest item up, down, left or right — and the band
// selects whoever is in the cells it covers.


Icon_View_State :: struct {
	label_of:       Label_Of, // row labels for type-ahead (nil: none)
	label_user:     rawptr,
	reveal_pending: int,      // row + 1 to scroll into view after the next layout (0: none)
	count:      int,
	tile:       [2]f32, // tile size
	gap:        f32,
	look:       Icon_View_Look, // resolved at build, for the tiles built inside it
	cols:       int,
	built_w:    f32,
	list:       Node,
	sel:        ^Selection,
	row:        Node, // row being filled during a build
	row_index:  int,
	in_row:     int,
	last_click: f64,
	last_item:  int,
	grid:       Grid_Sel, // rubber-band state (widget_grid.odin)
	range_sent: [2]int,   // the items on_range last reported ({-1, -1} before the first)
	// Placed mode: the app says where each item goes and the view keeps
	// nothing, as with the selection.
	over:       Label_Over, // what the labels are drawn over: the app's own surface, or a wallpaper
	variant:    Icon_View_Variant, // icons with a label under, or pictures with a title and subtitle
	placed:     bool,
	place_of:   Place_Of,
	place_user: rawptr,
	cells:      [dynamic][2]int, // resolved cell per item: what place_of said, or where the flow put it
	taken:      map[u64]int,     // cell → item, while resolving
	rows_used:  int,             // the tallest row in use + 1: the content's height
	per_col:    int,             // rows down one screen: the flow for unplaced items wraps there
	band:       [2]int,          // the rows on screen (and one either side), so the rest are not built
	stack:      Node,            // the one container every placed tile sits in, offset to its cell
	animate:    bool,          // tiles glide to new places this build (the builder's `animate`, not on the first show)
	prev:       map[int]Rect,  // where each tile built last time was drawn (mid-glide included), by item (animate)
	viewport_seen: [2]f32,     // the window size at the last build ({} before the first)
	settling:      bool,       // the first show's layout corrects the width guessed before it: that reflow is unanimated
}

ICON_TILE      :: [2]f32{96, 100}
ICON_TILE_ICON :: f32(40)

// Icon_View_Variant is how an icon view's tiles look: an icon or thumbnail
// with a label centred under it (files, apps), or a picture filling a
// square with a title and a muted subtitle under it, and an action over it
// on hover (albums, books).
Icon_View_Variant :: enum u8 { Icons, Pictures }

// PICTURE_TILE is a picture tile's default size: a cover and two lines.
PICTURE_TILE :: [2]f32{168, 214}

// PICTURE_TILE_TEXT is the room a picture tile keeps under its picture for
// its title and subtitle.
@(private)
PICTURE_TILE_TEXT :: f32(46)

// TILE_ACTION is the side of a picture tile's action button over its picture.
@(private)
TILE_ACTION :: f32(40)

// Tile_Action is a picture tile's one action over its picture, as
// icon_item's `action`, `action_icon` and `action_label` give it.
@(private)
Tile_Action :: struct($Msg: typeid) {
	on_click: Maybe(Msg),
	icon:     Icon,
	label:    string,
}

// icon_view opens the grid and returns the items to build with icon_item;
// end(ui) closes it. `on_select` follows what is selected, every arrow key
// included; `on_click` is the gesture — a plain primary click on an item, no
// Ctrl or Shift and not the second click of a double — so "one click opens"
// belongs there, as on `tree_item`; `on_activate` is a double-click or Enter.
// An Enter or Space the app bound with `shortcut` is the app's, and with no
// `on_activate` Enter goes on to the window. `tile`, `gap` and `padding` left
// unset take the theme's (`icon_view_look`).
icon_view :: proc(ui: ^Ui($Msg), count: int, selection: ^Selection = nil,
	on_select: Handler(Msg, int) = nil, on_click: Handler(Msg, int) = nil,
	on_activate: Handler(Msg, int) = nil, on_context: Handler(Msg, int) = nil,
	drag: string = "", on_drop: Handler(Msg, Drop) = nil, accepts: string = "", drag_files: Files_Of = nil, drag_user: rawptr = nil, drag_files_out: Files_Out = nil,
	on_rest: Handler(Msg, Drag_Rest) = nil,
	on_drag_out: Handler(Msg, Drop) = nil, on_range: Handler(Msg, [2]int) = nil,
	on_zoom: Handler(Msg, f32) = nil, on_edit: Handler(Msg, int) = nil,
	label_of: Label_Of = nil, label_user: rawptr = nil, animate := false, label_over: Label_Over = .Surface,
	place_of: Place_Of = nil, place_user: rawptr = nil, on_place: Handler(Msg, Place_Drop) = nil,
	tile: [2]f32 = {}, gap: Space = nil, padding: Space = nil,
	flex: f32 = 1, height: f32 = 0, label: string = "", variant: Icon_View_Variant = .Icons,
	gutter := false, key: u64 = 0, loc := #caller_location) -> (first, last: int) {
	t := &ui.tree
	th := &t.theme
	lk := icon_view_look(th)
	tile := tile
	if tile == {} do tile = lk.picture_tile if variant == .Pictures else lk.tile // a cover's size for pictures, not an icon's
	n, created := reconcile_child(ui, .Custom, key, loc)
	d := node_get(t, n)
	if created {
		d.access.role = .List
		d.flags += {.Focusable, .Clips}
		d.kind = Custom_Kind{paint_over = paint_icon_view_over}
		t.icon_views[n] = {last_item = -1, range_sent = {-1, -1}}
	}
	set_name(t, n, label)
	pad := pad4(space_px(th, padding)) if padding != nil else lk.padding
	set_layout(t, n, Layout_Props{axis = .Column, align = .Stretch, flex = flex, height = height, padding = pad})
	vs := &t.icon_views[n]
	vs.look = lk
	first_show := vs.viewport_seen == {} // no layout yet: the columns are a guess the next build corrects
	vs.viewport_seen = t.viewport
	vs.animate = animate && !first_show && !vs.settling // a zoom, a pane or a window resize glides; the first show does not
	vs.settling = first_show
	if animate { // where each tile is drawn now, by item: one that lands in another row glides on from there
		if vs.prev == nil do vs.prev = make(map[int]Rect, t.allocator)
		clear(&vs.prev)
		for r := node_first(t, vs.list); vs.list != NODE_NONE && r != NODE_NONE; r = node_next(t, r) {
			for tile := node_first(t, r); tile != NODE_NONE; tile = node_next(t, tile) {
				td := node_get(t, tile)
				ref, ok := ui.rows[tile]
				if !ok || ref.table != n || .Exiting in td.flags do continue
				drawn := td.abs // mid-glide it is drawn short of its place: a new move re-targets from there
				if td.move_from != {} {
					k := anim_value(t, tile, .Move)
					drawn.x += td.move_from.x * k
					drawn.y += td.move_from.y * k
				}
				vs.prev[ref.index] = drawn
			}
		}
	}
	old_cols, old_pitch := vs.cols, vs.tile.y + vs.gap
	vs.count = max(count, 0)
	vs.tile = tile
	vs.gap = space_px(th, gap) if gap != nil else lk.gap
	vs.sel = selection
	vs.label_of, vs.label_user = label_of, label_user // type-ahead matches these
	vs.over = label_over // .Anything: the labels carry their own legibility, whatever is behind them
	vs.variant = variant
	// The `reveal_index` command, taken if it named this view: bring that
	// item into view, once, after layout. Asking for the item already shown
	// — a "find next" that lands on it — is asking again (reveal_cmd.odin).
	if ask, taken := reveal_taken(ui, key, by_index = true); taken && ask.index >= 0 {
		vs.reveal_pending = ask.index + 1
	}
	if selection != nil do selection_ensure(selection)
	vs.placed = place_of != nil
	vs.place_of, vs.place_user = place_of, place_user
	inner_w := d.rect.w - (pad[1] + pad[3])
	if inner_w <= 0 do inner_w = max(t.viewport.x - 48, tile.x)
	if gutter do inner_w = max(inner_w - scrollbar_look(th).gutter, tile.x) // the columns fit what the bar leaves
	vs.built_w = inner_w
	vs.cols = max(int((inner_w + vs.gap) / (tile.x + vs.gap)), 1)
	new_pitch := tile.y + vs.gap
	if !vs.placed && old_cols > 0 && vs.list != NODE_NONE && (old_cols != vs.cols || old_pitch != new_pitch) {
		// A zoom (or a narrower window) re-flows the grid: keep the item at
		// the top in view rather than the pixel offset.
		if sc := &t.scrolls[vs.list]; sc != nil && sc.offset.y > 0 {
			row_f := sc.offset.y / old_pitch
			item := int(row_f) * old_cols
			new_row := f32(item / vs.cols) + (row_f - f32(int(row_f)))
			sc.content.y = f32((vs.count + vs.cols - 1) / vs.cols) * new_pitch
			scroll_to(t, vs.list, {sc.offset.x, new_row * new_pitch})
			if ls := &ui.lists[vs.list]; ls != nil do ls.pitch_seen = new_pitch // the list must not re-anchor again
		}
	}
	if handler_live(on_place) { ui.on_place[n] = on_place } else { delete_key(&ui.on_place, n) }
	ui.on_int[n] = on_select
	ui.on_activate[n] = on_activate
	if handler_live(on_click) { ui.on_row_click[n] = on_click } else { delete_key(&ui.on_row_click, n) }
	grid_drag_register(ui, n, drag, on_drop, accepts, drag_files, drag_user, drag_files_out) // tiles drag as `drag` (a selection drags whole) and take drops On
	grid_rest_register(ui, n, on_rest) // …and spring open when a drag rests on one
	if handler_live(on_place) && !handler_live(on_drop) do drop_target_bare(ui, n, drag) // a placed view still takes its own items back
	if handler_live(on_drag_out) { ui.on_drag_out[n] = on_drag_out } else { delete_key(&ui.on_drag_out, n) } // a row dragged out and dropped in another app
	zoom_register(ui, n, on_zoom) // Ctrl + wheel: the app's zoom
	if handler_live(on_edit) { ui.on_edit[n] = on_edit } else { delete_key(&ui.on_edit, n) } // F2 / a slow click: edit a label in place
	ui.on_context[n] = on_context
	open_scope(ui, n, loc)
	if vs.placed {
		// Every item where the app put it: one container, each tile offset
		// to its cell, and only the rows on screen built. The flow's rows
		// cannot do this — an item's row no longer follows from its index.
		icon_view_place(t, n, vs, d)
		first, last = 0, vs.count // the app builds them all; the view skips what is off screen
		sc := scroll(ui, .Column, flex = 1, gutter = gutter, key = 1, loc = loc)
		vs.list = sc
		node_get(t, sc).access.role = .None
		ui.scopes[len(ui.scopes) - 1].extra_pops = 1 // end(ui) closes the scroll and the view
		pitch := icon_view_pitch(vs)
		content := max(f32(vs.rows_used) * pitch.y + tile.y / 2, tile.y)
		stack, _ := reconcile_child(ui, .Box, 1, loc)
		set_layout(t, stack, Layout_Props{axis = .Stack, height = content})
		node_get(t, stack).access.role = .None
		vs.stack = stack
		open_scope(ui, stack, loc)
		ui.scopes[len(ui.scopes) - 1].extra_pops = 2 // …and on the stack, all three
		// the rows on screen, with one either side so a scroll never shows a gap
		off := t.scrolls[sc].offset.y if sc in t.scrolls else 0
		view_h := d.rect.h if d.rect.h > 0 else t.viewport.y
		vs.band = {max(int(off / pitch.y) - 1, 0), int((off + view_h) / pitch.y) + 1}
		if handler_live(on_range) && vs.range_sent != {first, last} {
			vs.range_sent = {first, last}
			handler_send(ui, on_range, [2]int{first, last}, n)
		}
		return
	}
	rows := (vs.count + vs.cols - 1) / vs.cols
	// A list of the icon view's own, keyed inside it: see widget_table.odin.
	view_inner_begin(ui)
	// The resolved gap, and no padding whatever a list's own style says: the
	// grid's pitch and the rubber band are worked out from these.
	fr, lr := list(ui, rows, tile.y, gap = vs.gap, padding = f32(0), flex = 1, tail_pad = tile.y / 2, gutter = gutter, key = 1, loc = loc)
	view_inner_end(ui)
	vs.list = ui.scopes[len(ui.scopes) - 1].node
	ui.scopes[len(ui.scopes) - 1].extra_pops = 1 // end(ui) closes the list and the view
	node_get(t, vs.list).access.role = .None
	vs.row = NODE_NONE
	vs.row_index = fr - 1
	vs.in_row = vs.cols
	first = fr * vs.cols
	last = min(lr * vs.cols, vs.count)
	if handler_live(on_range) && vs.range_sent != {first, last} { // the tiles on screen (and a row either side) changed
		vs.range_sent = {first, last}
		handler_send(ui, on_range, [2]int{first, last}, n)
	}
	return
}

// tile_legible gives one of a tile's own nodes its legibility over whatever
// is behind it. Where the compositor reports the backdrop cell by cell, each
// node takes the ink and halo that work over the cells under it, so only a
// name lying across an edge keeps a halo; with no such map it wears the blind
// halo, which always reads. These labels are held to ordinary text contrast:
// a file's name is read closely, not glanced at.
@(private)
tile_legible :: proc(ui: ^Ui($Msg), n: Node, ink: Color, halo: Glow, measured: bool) {
	if measured {
		legible_over(ui, n, ink, GLASS_TEXT_CONTRAST)
	} else {
		set_glow(&ui.tree, n, halo)
	}
}

// Label_Over says what an icon view's labels are drawn over, because a
// label can only pick a colour that reads if it knows. `.Surface` is the
// app's own background, where the theme's colours are right. `.Anything` is
// a wallpaper, a photograph, a video — something the app did not choose —
// and there the labels and icons carry a halo in the opposite tone, the one
// thing that works where one label is on sky and the next on a hedge.
Label_Over :: enum u8 { Surface, Anything }

// Place_Of says which cell an item belongs in — column and row, counted
// from the view's top-left. `{-1, -1}` means the app has not placed this one
// and the view should put it somewhere free.
Place_Of :: #type proc(user: rawptr, index: int) -> [2]int

// Place_Drop is a drag landing in a placed view: which items moved, and the
// cell the pointer was over when they were let go. The app writes it down
// and gives it back through `place_of`: the view keeps no placement of its
// own.
Place_Drop :: struct {
	items: []int,    // the dragged items (temp memory: valid while the message is handled)
	cells: [][2]int, // where each of `items` lands: the shape kept, a taken cell moved to the nearest free one
	cell:  [2]int,   // the cell the pointer was over, untouched — for an app that would rather work it out itself
	item:  int,      // the dragged item that was under the pointer: the one that lands on `cell`
}

// icon_item adds tile `index` (an icon over a label) to the view being
// built; rows open and close by themselves. With `on_submit` the label is an
// editor instead (after the view's `on_edit` asked for it): it takes focus
// with the name selected up to its extension, Enter or leaving commits
// through `on_submit`, Escape sends `on_cancel`. In a `.Pictures` view the
// tile is `picture` filling a square, cropped (or `which` on a quiet square),
// with `label` as its title and `subtitle` muted under it, a line each ended
// with "…", the subtitle heard after the name; `action` (named by
// `action_label`, drawn as `action_icon`) is a button over the picture's
// corner, shown on hover or for the keyboard's tile, and Tab from the view
// reaches the current tile's.
icon_item :: proc(ui: ^Ui($Msg), index: int, which: Icon, label: string, picture: ^Image = nil,
	on_submit: Handler(Msg, string) = nil, on_cancel: Maybe(Msg) = nil, subtitle: string = "",
	action: Maybe(Msg) = nil, action_icon: Icon = .Play, action_label: string = "", loc := #caller_location) -> Node {
	act := Tile_Action(Msg){on_click = action, icon = action_icon, label = action_label if action_label != "" else ICON_NAMES[action_icon]}
	t := &ui.tree
	// find the view: the open scope is a row (of it) or its list
	top := ui.scopes[len(ui.scopes) - 1].node
	view := node_parent(t, top)
	if _, is_view := t.icon_views[view]; !is_view do view = node_parent(t, view)
	vs, ok := &t.icon_views[view]
	if !ok do return NODE_NONE
	if vs.placed {
		cell := vs.cells[index] if index >= 0 && index < len(vs.cells) else [2]int{0, 0}
		if cell.y < vs.band.x || cell.y > vs.band.y do return NODE_NONE // off screen: not built at all
		pitch := icon_view_pitch(vs)
		n := icon_view_tile(ui, view, vs, index, which, label, picture, on_submit, on_cancel, subtitle, act,
			offset = {f32(cell.x) * pitch.x, f32(cell.y) * pitch.y}, loc = loc)
		return n
	}
	if vs.in_row >= vs.cols {
		if vs.row != NODE_NONE do close_scope(ui)
		vs.row_index += 1
		vs.in_row = 0
		row, rcreated := reconcile_child(ui, .Box, u64(vs.row_index + 1), loc)
		if rcreated do node_get(t, row).access.role = .None
		animate_moves(ui, row, vs.animate)
		rd := node_get(t, row)
		if vs.animate { rd.flags += {.Animate_Resize} } else { rd.flags -= {.Animate_Resize} } // a window resize reflows the grid too
		set_layout(t, row, Layout_Props{axis = .Row, gap = vs.gap, height = vs.tile.y})
		vs.row = row
		open_scope(ui, row, loc)
		ui.scopes[len(ui.scopes) - 1].extra_pops = 2 // end(ui) on an open row closes list and view too
	}
	vs.in_row += 1
	return icon_view_tile(ui, view, vs, index, which, label, picture, on_submit, on_cancel, subtitle, act, loc = loc)
}

// icon_view_edit_width is how wide a tile's rename editor is: two tiles, so
// a long name without spaces is not a column of short lines, and never
// wider than the view it sits in.
@(private)
icon_view_edit_width :: proc(t: ^Tree, view: Node, vs: ^Icon_View_State) -> f32 {
	w := vs.tile.x * 2
	if vd := node_get(t, view); vd != nil && vd.abs.w > 0 do w = min(w, max(vd.abs.w - 2 * scrollbar_look(&t.theme).gutter, vs.tile.x))
	return w
}

// icon_view_tile is the tile itself, which both modes build the same way:
// the flow puts it in a row, a placed view offsets it to its cell.
@(private)
icon_view_tile :: proc(ui: ^Ui($Msg), view: Node, vs: ^Icon_View_State, index: int, which: Icon, label: string,
	picture: ^Image, on_submit: Handler(Msg, string), on_cancel: Maybe(Msg), subtitle: string, action: Tile_Action(Msg),
	offset: [2]f32 = {}, loc := #caller_location) -> Node {
	t := &ui.tree
	lk := &vs.look
	n, created := reconcile_child(ui, .Box, u64(index + 1), loc)
	d := node_get(t, n)
	if created {
		d.access.role = .List_Item
		d.flags += {.Clips}
		if was, seen := vs.prev[index]; vs.animate && seen do d.abs = was // a new node for an item that changed rows: layout glides it from where it was
	}
	d.tag = u64(index)
	ui.rows[n] = {table = view, index = index}
	grid_row_dnd(ui, view, n, index, vs.sel)
	set_name(t, n, label)
	set_describe(t, n, subtitle) // an album's artist, a book's author: heard after its name
	if vs.variant == .Pictures {
		set_layout(t, n, Layout_Props{axis = .Column, align = .Start, offset = offset, width = vs.tile.x, height = vs.tile.y, padding = lk.picture_padding, gap = lk.picture_gap})
	} else {
		set_layout(t, n, Layout_Props{axis = .Column, align = .Center, offset = offset, width = vs.tile.x, height = vs.tile.y, padding = lk.tile_padding, gap = lk.tile_gap})
	}
	selected := vs.sel != nil && selection_contains(vs.sel, index)
	is_cursor := vs.sel != nil && vs.sel.cursor == index
	if is_cursor do set_active_item(t, view, n) // the view keeps the focus; this is the row a reader should hear
	if was := .Selected in d.access.states; was != selected {
		if selected { d.access.states += {.Selected} } else { d.access.states -= {.Selected} }
	}
	st := d.style
	st.bg = lk.selected_fill if selected else Color{}
	st.radius = lk.radius
	st.border_w = lk.cursor_border_width if is_cursor else 0
	st.border = lk.cursor_border
	set_style(t, n, st)
	open_scope(ui, n, loc)
	if vs.variant == .Pictures {
		picture_tile(ui, view, vs, n, index, which, label, picture, on_submit, on_cancel, subtitle, action, selected, is_cursor, loc)
		close_scope(ui)
		return n
	}
	side := max(min(vs.tile.x - 16, vs.tile.y - 46), ICON_TILE_ICON) // the room above two label lines: the tile sets the zoom
	ink := lk.selected_ink if selected else lk.ink
	// Over a wallpaper nothing can be assumed about what is behind a glyph,
	// so the glyphs bring their own contrast: a halo in the opposite tone.
	// A selected tile already has a plate behind it and needs none.
	bare := vs.over == .Anything && !selected
	halo := legible_halo(ink) if bare else Glow{}
	measured := bare && backdrop_mapped(ui)
	if picture != nil {
		p := image(ui, picture, width = side, height = side, radius = lk.thumbnail_radius, fit = .Contain, loc = loc)
		tile_legible(ui, p, ink, halo, measured)
	} else {
		ic := baldr_icon(ui, which, side * (ICON_TILE_ICON / (ICON_TILE.y - 46)), ink, loc)
		tile_legible(ui, ic, ink, halo, measured)
	}
	l := text(ui, label, role = lk.label_text.role, size = lk.label_text.size, color = ink,
		ellipsis = .Middle, max_lines = 2, align = .Center, weight = lk.label_text.weight,
		family = look_family(t, lk.label_text.family), loc = loc) // two centred lines, then "…" in the middle so the extension stays
	set_role(t, l, .None)
	tile_legible(ui, l, ink, halo, measured)
	if handler_live(on_submit) {
		// Renaming: an editor over the tile, wrapping and wider than it, so
		// the whole name shows. The label stays built underneath the card so
		// the tile's icon does not shift while the name is typed.
		inline_edit_over(ui, label, on_submit, on_cancel, true, Edit_Ref{view = view, row = index}, "Rename",
			n, view, icon_view_edit_width(t, view, vs), {0, lk.tile_padding[0] + side + lk.tile_gap}, 2, loc)
	}
	close_scope(ui)
	return n
}

// picture_tile builds a picture tile's inside: the picture
// filling a square with rounded corners, cropped rather than letterboxed (a
// cover is a square; a book's is cropped to one), or the item's icon on a
// quiet square when it has none; its action over the picture's corner,
// shown on hover or for the keyboard's current tile; the title in medium
// weight and the subtitle muted, a line each, ended with "…".
@(private)
picture_tile :: proc(ui: ^Ui($Msg), view: Node, vs: ^Icon_View_State, n: Node, index: int, which: Icon, label: string,
	picture: ^Image, on_submit: Handler(Msg, string), on_cancel: Maybe(Msg), subtitle: string, action: Tile_Action(Msg),
	selected, is_cursor: bool, loc: runtime.Source_Code_Location) {
	t := &ui.tree
	lk := &vs.look
	pp := lk.picture_padding
	side := max(min(vs.tile.x - (pp[1] + pp[3]), vs.tile.y - (pp[0] + pp[2]) - PICTURE_TILE_TEXT), 24)
	ink := lk.selected_ink if selected else lk.ink
	bare := vs.over == .Anything && !selected
	halo := legible_halo(ink) if bare else Glow{}
	measured := bare && backdrop_mapped(ui)
	stack(ui, width = side, height = side, key = 1)
	if picture != nil {
		image(ui, picture, width = side, height = side, radius = lk.picture_radius, fit = .Cover, key = 1)
	} else {
		stack(ui, width = side, height = side, align = .Center, bg = lk.placeholder_fill, radius = lk.picture_radius, key = 2)
		baldr_icon(ui, which, side * 0.4, lk.placeholder_ink, loc, key = 1)
		end(ui)
	}
	if m, acts := action.on_click.?; acts {
		holder := stack(ui, width = TILE_ACTION, height = TILE_ACTION, align = .Center, key = 3)
		if hd := node_get(t, holder); hd != nil {
			at := [2]f32{side - TILE_ACTION - 8, side - TILE_ACTION - 8} // inside the picture's end corner
			if hd.layout.offset != at {
				hd.layout.offset = at
				mark_layout_dirty(t, holder)
			}
		}
		b := button(ui, action.label, m, icon = action.icon, icon_only = true, variant = .Primary, key = 1)
		tooltip(ui, b, action.label)
		if bd := node_get(t, b); bd != nil { // one Tab stop, the current tile's: not one per tile in a grid of hundreds
			if is_cursor { bd.flags += {.Focusable} } else { bd.flags -= {.Focusable} }
			if bd.style.radius != TILE_ACTION { // round, as a player's Play is over a cover
				st := bd.style
				st.radius = TILE_ACTION
				set_style(t, b, st)
			}
		}
		end(ui)
		reveal_within(ui, holder, n, shown = is_cursor && t.focus == view && t.focus_visible)
	}
	end(ui)
	l := text(ui, label, role = lk.title_text.role, size = lk.title_text.size, color = ink, weight = lk.title_text.weight,
		family = look_family(t, lk.title_text.family), nowrap = true, ellipsis = .End, key = 4)
	set_role(t, l, .None)
	tile_legible(ui, l, ink, halo, measured)
	if handler_live(on_submit) { // the same editor over the cover's title
		inline_edit_over(ui, label, on_submit, on_cancel, true, Edit_Ref{view = view, row = index}, "Rename",
			n, view, icon_view_edit_width(t, view, vs), {0, pp[0] + side + lk.picture_gap}, 1, loc)
	}
	if subtitle != "" {
		sub := text(ui, subtitle, role = lk.subtitle_text.role, size = lk.subtitle_text.size, color = ink if selected else lk.subtitle_ink,
			weight = lk.subtitle_text.weight, family = look_family(t, lk.subtitle_text.family), nowrap = true, ellipsis = .End, key = 5)
		set_role(t, sub, .None)
		tile_legible(ui, sub, ink, halo, measured)
	}
}

// The halo a label wears over a wallpaper: tight, and laid down several
// times. A glow is a Gaussian of sigma = radius / 2, and one pass over an
// 11 px glyph is too thin to outline it: over a pale background one pass
// reaches about 2:1, four reach 9.5:1. The cost is four small quads per
// glyph, only in a view that asked to be legible over something unknown.
LABEL_HALO_RADIUS :: f32(2)
LABEL_HALO_ALPHA  :: f32(0.9)
LABEL_HALO_PASSES :: 4

@(private)
paint_icon_view_over :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer) {
	vs, ok := &t.icon_views[n]
	if !ok || !vs.grid.marquee do return
	paint_marquee(t, vs.list, &vs.grid, l, icon_view_look(&t.theme).marquee) // paint's theme: an area's or the glass one where it is swapped
}

// icon_view_reveal scrolls so the row holding `index` is visible.
@(private)
icon_view_reveal :: proc(ui: ^Ui($Msg), view: Node, index: int) {
	t := &ui.tree
	vs := &t.icon_views[view]
	st, ok := t.scrolls[vs.list]
	if !ok do return
	pitch := vs.tile.y + vs.gap
	row := index / max(vs.cols, 1)
	if vs.placed do row = vs.cells[index].y if index >= 0 && index < len(vs.cells) else 0
	y := f32(row) * pitch
	off := st.offset.y
	if y < off {
		off = y
	} else if y + vs.tile.y > off + st.viewport.y {
		off = y + vs.tile.y - st.viewport.y
	}
	scroll_to_smooth(t, vs.list, {st.offset.x, off})
}

icon_view_key :: proc(ui: ^Ui($Msg), key: Key, mods: Mods) -> bool {
	t := &ui.tree
	view := t.focus
	vs, ok := &t.icon_views[view]
	if !ok || vs.sel == nil || vs.count == 0 do return false
	sel := vs.sel
	move :: proc(ui: ^Ui($Msg), view: Node, vs: ^Icon_View_State, to: int, mods: Mods) -> bool {
		i := clamp(to, 0, vs.count - 1)
		if .Shift in mods { selection_range(vs.sel, i) } else { selection_set(vs.sel, i) }
		icon_view_reveal(ui, view, i)
		grid_selection_changed(ui, view)
		return true
	}
	cur := max(sel.cursor, 0)
	if vs.placed { // an arrow goes where the eye goes, not where the index goes
		dir := [2]int{}
		#partial switch key {
		case .Right: dir = {1, 0}
		case .Left:  dir = {-1, 0}
		case .Down:  dir = {0, 1}
		case .Up:    dir = {0, -1}
		}
		if dir != {} {
			if sel.cursor < 0 do return move(ui, view, vs, icon_view_end_placed(vs, last = false), mods)
			to := icon_view_move_placed(vs, cur, dir)
			if to < 0 do return true // nothing that way: the cursor stays where it is
			return move(ui, view, vs, to, mods)
		}
		#partial switch key {
		case .Home: return move(ui, view, vs, icon_view_end_placed(vs, last = false), mods)
		case .End:  return move(ui, view, vs, icon_view_end_placed(vs, last = true), mods)
		case .Page_Down, .Page_Up:
			st, has := t.scrolls[vs.list]
			if !has do return false
			pitch := icon_view_pitch(vs)
			rows := max(int(st.viewport.y / pitch.y) - 1, 1)
			down := [2]int{0, 1 if key == .Page_Down else -1}
			at := cur if sel.cursor >= 0 else icon_view_end_placed(vs, last = false)
			for _ in 0 ..< rows { // a screenful, item by item: it stops at the last one that way
				to := icon_view_move_placed(vs, at, down)
				if to < 0 do break
				at = to
			}
			return move(ui, view, vs, at, mods)
		}
	}
	#partial switch key {
	case .Right: return move(ui, view, vs, sel.cursor + 1, mods)
	case .Left:  return move(ui, view, vs, cur - 1 if sel.cursor > 0 else 0, mods)
	case .Down:  return move(ui, view, vs, cur + vs.cols if sel.cursor >= 0 else 0, mods)
	case .Up:    return move(ui, view, vs, cur - vs.cols if cur >= vs.cols else cur, mods)
	case .Home:  return move(ui, view, vs, 0, mods)
	case .End:   return move(ui, view, vs, vs.count - 1, mods)
	case .Page_Down, .Page_Up: // a viewport of rows, less one to keep context
		st, has := t.scrolls[vs.list]
		if !has do return false
		pitch := vs.tile.y + vs.gap
		rows := max(int(st.viewport.y / pitch) - 1, 1) if pitch > 0 else 1
		return move(ui, view, vs, cur + (rows if key == .Page_Down else -rows) * max(vs.cols, 1), mods)
	case .Space:
		if sel.cursor < 0 || shortcut_bound(ui, key, mods) do return false // the app's own Space (Quick Look) wins; Ctrl+Space still toggles
		selection_toggle(sel, sel.cursor)
		grid_selection_changed(ui, view)
		return true
	case .F2:
		if h, has := ui.on_edit[view]; has && sel.cursor >= 0 do return handler_send(ui, h, sel.cursor, view)
		return false
	case .Enter:
		if sel.cursor < 0 || shortcut_bound(ui, key, mods) do return false // the app's own Alt+Enter (Properties) wins, as its Space does
		// With nothing to open (no on_activate, or the nil handler the map
		// always holds for one) Enter is not the view's: it goes on to the
		// window's shortcuts, and to a dialog's default button.
		return handler_send(ui, ui.on_activate[view], sel.cursor, view)
	case .A:
		if .Ctrl in mods && sel.multi {
			selection_all(sel, vs.count)
			grid_selection_changed(ui, view)
			return true
		}
	}
	return false
}


// ------------------------------------------------------------ placed mode

// icon_view_pitch is the grid's step: a tile and the gap after it. The flow
// and the placed grid share it, so the two modes line up cell for cell.
@(private)
icon_view_pitch :: proc(vs: ^Icon_View_State) -> [2]f32 {
	return {vs.tile.x + vs.gap, vs.tile.y + vs.gap}
}

// icon_view_place works out where every item goes: what `place_of` said,
// and somewhere free for the ones it did not place. Two items asking for the
// same cell is the app's business to avoid, but it must not lose one — the
// second takes the nearest free cell instead.
@(private)
icon_view_place :: proc(t: ^Tree, n: Node, vs: ^Icon_View_State, d: ^Node_Data) {
	if vs.cells == nil do vs.cells = make([dynamic][2]int, t.allocator)
	if vs.taken == nil do vs.taken = make(map[u64]int, t.allocator)
	clear(&vs.cells)
	clear(&vs.taken)
	resize(&vs.cells, vs.count)
	key :: icon_view_cell_key

	// how many rows fit down one column: the flow for unplaced items runs
	// down the column, as a desktop's does, not across the row
	pitch := icon_view_pitch(vs)
	view_h := d.rect.h if d.rect.h > 0 else t.viewport.y
	per_col := max(int(view_h / pitch.y), 1)
	vs.per_col = per_col

	// what the app placed comes first, so the flow fills round it
	for i in 0 ..< vs.count {
		c := vs.place_of(vs.place_user, i)
		if c.x < 0 || c.y < 0 {
			vs.cells[i] = {-1, -1}
			continue
		}
		if other, busy := vs.taken[key(c)]; busy && other != i {
			c = icon_view_free_near(&vs.taken, c) // the cell is spoken for: the nearest free one
		}
		vs.cells[i] = c
		vs.taken[key(c)] = i
	}
	next := [2]int{0, 0}
	for i in 0 ..< vs.count {
		if vs.cells[i].x >= 0 do continue
		for {
			if _, busy := vs.taken[key(next)]; !busy do break
			next.y += 1
			if next.y >= per_col { next.y = 0; next.x += 1 }
		}
		vs.cells[i] = next
		vs.taken[key(next)] = i
	}
	vs.rows_used = 0
	for c in vs.cells do vs.rows_used = max(vs.rows_used, c.y + 1)
}

// icon_view_cell_key packs a cell for the `taken` map.
@(private)
icon_view_cell_key :: proc(c: [2]int) -> u64 { return u64(u32(c.x)) << 32 | u64(u32(c.y)) }

// icon_view_item_at is the item occupying `cell`, or -1. The rubber band
// asks this instead of doing the flow's arithmetic.
@(private)
icon_view_item_at :: proc(vs: ^Icon_View_State, cell: [2]int) -> int {
	i, has := vs.taken[icon_view_cell_key(cell)]
	return i if has else -1
}

// icon_view_free_near is the nearest free cell to `c`, searched in rings, so
// an item dropped on a taken cell lands beside it rather than on top of it
// or at the end.
@(private)
icon_view_free_near :: proc(busy: ^map[u64]int, c: [2]int) -> [2]int {
	key :: icon_view_cell_key
	for ring in 1 ..< 64 {
		for dy in -ring ..= ring {
			for dx in -ring ..= ring {
				if abs(dx) != ring && abs(dy) != ring do continue // the ring's edge only
				p := [2]int{c.x + dx, c.y + dy}
				if p.x < 0 || p.y < 0 do continue
				if _, held := busy[key(p)]; !held do return p
			}
		}
	}
	return c
}

// icon_view_cell_at is the cell a point in the view falls on, for a drop.
@(private)
icon_view_cell_at :: proc(t: ^Tree, view: Node, vs: ^Icon_View_State, pos: [2]f32) -> [2]int {
	sd := node_get(t, vs.stack)
	if sd == nil do return {0, 0}
	pitch := icon_view_pitch(vs)
	rel := [2]f32{pos.x - sd.abs.x, pos.y - sd.abs.y}
	return {max(int(rel.x / pitch.x), 0), max(int(rel.y / pitch.y), 0)}
}

// icon_view_placed_drop: a drag from this view landed in it again, so the
// items it carried move to the cell under the pointer. The app is told; the
// view changes nothing itself.
@(private)
icon_view_placed_drop :: proc(ui: ^Ui($Msg), view: Node, pos: [2]f32) -> bool {
	t := &ui.tree
	vs, is_view := &t.icon_views[view]
	if !is_view || !vs.placed do return false
	h, has := ui.on_place[view]
	if !has do return false
	dragged := int(ui.drag.tag)
	if dragged < 0 || dragged >= len(vs.cells) do return false
	items := make([dynamic]int, context.temp_allocator)
	if vs.sel != nil && selection_contains(vs.sel, dragged) {
		// a selection moves whole, keeping its shape: the item under the
		// pointer lands on the drop cell and the rest keep their offsets
		for i in 0 ..< vs.count do if selection_contains(vs.sel, i) do append(&items, i)
	} else {
		append(&items, dragged)
	}
	cell := icon_view_cell_at(t, view, vs, pos)
	cells := icon_view_drop_cells(vs, items[:], dragged, cell)
	return handler_send(ui, h, Place_Drop{items = items[:], cells = cells, cell = cell, item = dragged}, view)
}

// icon_view_drop_cells is where a dragged set lands: the item under the
// pointer takes the drop cell and the rest keep their offsets from it, so a
// selection keeps its shape. A cell an item that is *not* moving already
// holds is stepped round — the drop must never lose one under another.
@(private)
icon_view_drop_cells :: proc(vs: ^Icon_View_State, items: []int, anchor: int, cell: [2]int) -> [][2]int {
	cells := make([][2]int, len(items), context.temp_allocator)
	delta := cell - vs.cells[anchor]
	moving := make(map[int]struct{}, len(items), context.temp_allocator)
	for it in items do moving[it] = {}
	busy := make(map[u64]int, len(vs.cells), context.temp_allocator)
	for c, i in vs.cells do if i not_in moving do busy[icon_view_cell_key(c)] = i
	for it, k in items {
		want := vs.cells[it] + delta
		want = {max(want.x, 0), max(want.y, 0)} // a drag up or left off the grid stops at its edge
		if _, held := busy[icon_view_cell_key(want)]; held do want = icon_view_free_near(&busy, want)
		cells[k] = want
		busy[icon_view_cell_key(want)] = it
	}
	return cells
}

// icon_view_end_placed is Home and End in a placed view: the first and last
// cells in reading order — down the leftmost column, then the next — which
// is the order the flow fills, so both modes end in the same place.
@(private)
icon_view_end_placed :: proc(vs: ^Icon_View_State, last: bool) -> int {
	best := -1
	for c, i in vs.cells {
		if best < 0 { best = i; continue }
		b := vs.cells[best]
		ahead := c.x < b.x || (c.x == b.x && c.y < b.y)
		if ahead != last do best = i
	}
	return max(best, 0)
}

// icon_view_takes_place: `n` is a placed icon view the drag in hand came
// out of, so letting go over it moves those items rather than dropping them.
@(private)
icon_view_takes_place :: proc(ui: ^Ui($Msg), n: Node) -> bool {
	if !ui.drag.active || ui.drag.external do return false
	if _, has := ui.on_place[n]; !has do return false
	return icon_view_of(&ui.tree, n) == icon_view_of(&ui.tree, ui.drag.source)
}

// icon_view_of is the placed icon view a node belongs to (itself, a tile of
// it, or its content), or NODE_NONE.
@(private)
icon_view_of :: proc(t: ^Tree, n: Node) -> Node {
	for cur := n; cur != NODE_NONE; cur = node_parent(t, cur) {
		if vs, is_view := &t.icon_views[cur]; is_view do return cur if vs.placed else NODE_NONE
	}
	return NODE_NONE
}

// icon_view_move_placed is where an arrow key goes in a placed view: the
// nearest item in that direction by geometry, because the index order an
// app happens to list its items in has nothing to do with where they are on
// screen. Returns -1 when there is nothing that way.
@(private)
icon_view_move_placed :: proc(vs: ^Icon_View_State, from: int, dir: [2]int) -> int {
	if from < 0 || from >= len(vs.cells) do return -1
	origin := vs.cells[from]
	best, best_score := -1, max(int)
	for c, i in vs.cells {
		if i == from do continue
		d := [2]int{c.x - origin.x, c.y - origin.y}
		along := d.x * dir.x + d.y * dir.y     // how far in the direction asked for
		if along <= 0 do continue               // behind, or level: not that way
		across := abs(d.x * dir.y - d.y * dir.x) // …and how far off that line
		score := along * along + across * across * 4 // straight ahead wins over far off to one side
		if score < best_score do best, best_score = i, score
	}
	return best
}
