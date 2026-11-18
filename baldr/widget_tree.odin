package baldr

// tree_view + tree_item: a hierarchy with expand / collapse — a file
// manager's sidebar, a project explorer, settings sections. Expansion and
// selection are the app's state, echoed back through on_change and
// on_click, so a directory can be loaded the first time it is opened. A
// branch's children scope is open only while it is expanded:
//
//	baldr.tree_view(ui, label = "Project"); {
//		defer baldr.end(ui)
//		if baldr.tree_item(ui, "src", Msg(Pick{1}), expanded = s.open[1], icon = .Folder, key = 1,
//			on_change = proc(e: baldr.Ev(bool)) -> Msg { return Open{e.tag, e.value} }, tag = 1) {
//			defer baldr.end(ui)
//			baldr.tree_item(ui, "main.odin", Msg(Pick{2}), icon = .File_Code, key = 2)
//		}
//	}
//
// An item is a branch when it has an on_change (the chevron toggles it), a
// leaf otherwise. `drag` makes the row a drag source of that kind (tag =
// the item's tag); `on_drop` makes it a target — On a branch (drop into
// the folder), Before / After a leaf (reorder) — see dnd.odin. Keyboard, with the tree view focused (the cursor row
// shows the ring, one Tab stop for the whole tree): Up / Down move and
// select, Right expands or steps into the first child, Left collapses or
// steps to the parent, Home / End, Enter activates (on_activate, else
// on_click) unless the app bound that Enter with `shortcut`,
// Space selects; a double-click activates. Accessibility: Tree
// of Tree_Items with Expanded / Collapsed and Selected states. Not
// virtualised — every visible item is a node — so put a large tree inside
// scroll.

import "core:hash"

TREE_INDENT    :: f32(16) // px per level
TREE_CHEVRON   :: f32(16) // the expander slot; leaves keep it empty so labels line up
TREE_ROW_MIN_H :: f32(28)
TREE_BRANCH_KEY :: u64(0x5452_4545_0000_0000) // xor-ed into an item's key for its children container

// Tree_Row is what the tree knows about one item's row (Tree side table,
// so paint and keys can read it without the message type).
Tree_Row :: struct {
	tree:       Node, // the tree view it belongs to
	chevron:    Node, // the expander, NONE for a leaf
	container:  Node, // the children scope while expanded, else NONE
	depth:      int,
	expandable: bool,
	expanded:   bool,
}

Tree_View_State :: struct {
	cursor:     Node, // row under the keyboard cursor (NONE until a click or key)
	last_click: f64,
	last_row:   Node,
	indent:     f32,
}

// tree_view opens a tree. Give it a size (`height`, or `flex` in a column)
// or let it grow with its items inside a scroll. Close with end. `indent` is
// px per level; nil takes the theme's (`tree_row.indent`).
tree_view :: proc(ui: ^Ui($Msg), label: string = "", flex: f32 = 0, height: f32 = 0, indent: Maybe(f32) = nil,
	padding: Space = Space_Token.none, on_edit: Handler(Msg, int) = nil, key: u64 = 0, loc := #caller_location) -> Node {
	t := &ui.tree
	n, created := reconcile_child(ui, .Custom, key, loc)
	if handler_live(on_edit) { ui.on_edit[n] = on_edit } else { delete_key(&ui.on_edit, n) } // F2 / a slow click: edit the cursor item's label (value: its tag)
	d := node_get(t, n)
	if created {
		d.access.role = .Tree
		d.flags += {.Focusable, .Ring_Inside} // the cursor row shows the ring
		d.kind = Custom_Kind{paint_over = paint_tree_over}
		t.tree_views[n] = {cursor = NODE_NONE, last_row = NODE_NONE}
	}
	set_name(t, n, label)
	set_layout(t, n, Layout_Props{axis = .Column, align = .Stretch, flex = flex, height = height, padding = pad4(space_px(&t.theme, padding)), gap = 1})
	tv := &t.tree_views[n]
	tv.indent = indent.? or_else tree_row_look(&t.theme).indent
	open_scope(ui, n, loc)
	return n
}

// tree_item adds one row to the open tree (or branch). Returns whether its
// children scope is open — close it with end only then. Items without a
// `key` are identified by their label. `muted` draws its label and icon in
// the muted ink and changes nothing else: a file the project leaves out,
// there but not part of it. `disabled` dims it and stops it working too. A
// selected row keeps the selection's ink, which is the one made to read on
// the selection's fill.
tree_item :: proc(ui: ^Ui($Msg), label: string, on_click: Msg, expanded := false, on_change: Handler(Msg, bool) = nil,
	selected := false, icon: Icon = .None, on_activate: Handler(Msg, int) = nil, disabled := false, muted := false,
	drag: string = "", on_drop: Handler(Msg, Drop) = nil, accepts: string = "", on_rest: Handler(Msg, Drag_Rest) = nil,
	on_submit: Handler(Msg, string) = nil, on_cancel: Maybe(Msg) = nil,
	on_context: Handler(Msg, int) = nil, on_middle_click: Maybe(Msg) = nil, drop_positions: Drop_Positions = {},
	tag: u64 = 0, key: u64 = 0, loc := #caller_location) -> bool {
	t := &ui.tree
	th := &t.theme
	scope := ui.scopes[len(ui.scopes) - 1].node
	tree, depth := tree_scope(t, scope)
	if tree == NODE_NONE {
		diag(t, loc, "tree_item outside a tree_view")
		return false
	}
	k := key if key != 0 else tree_label_key(label)
	expandable := handler_live(on_change) // not `!= nil`: a handler passed through a ternary holds a nil proc and is not nil (handler_live)
	open := expandable && expanded
	row, created := reconcile_child(ui, .Box, k, loc)
	d := node_get(t, row)
	if created {
		d.access.role = .Tree_Item // not Focusable: the tree view holds focus and moves a cursor
	}
	d.tag = tag
	set_name(t, row, label)
	states := d.access.states
	states -= {.Expanded, .Collapsed, .Selected, .Disabled}
	if expandable do states += {.Expanded} if open else {.Collapsed}
	if selected do states += {.Selected}
	if disabled do states += {.Disabled}
	if states != d.access.states {
		d.access.states = states
		mark_paint_dirty(t, row)
	}
	if disabled { d.flags += {.Disabled} } else { d.flags -= {.Disabled} }
	lk := tree_row_look(th)
	set_layout(t, row, Layout_Props{
		axis = .Row, align = .Center, gap = lk.gap,
		padding = lk.padding,
		min_h = max(lk.min_height, target_min(t).y),
	})
	st := d.style
	st.radius = lk.radius
	st.bg = lk.selected_fill if selected else Color{}
	set_style(t, row, st)
	fg := lk.selected_ink if selected else lk.muted_ink if muted else lk.ink
	ic := lk.branch_icon_ink if expandable && !selected && !muted else fg // a disabled row's label and icon dim in paint (disabled_within)
	ui.clicks[row] = on_click
	if handler_live(on_context) { ui.on_context[row] = on_context } else { delete_key(&ui.on_context, row) } // right-click / Menu key: the item's tag
	if m, has := on_middle_click.?; has { ui.middle_clicks[row] = m } else { delete_key(&ui.middle_clicks, row) }
	if handler_live(on_activate) { ui.on_activate[row] = on_activate } else { delete_key(&ui.on_activate, row) }
	// drag and drop: `drag` names what the row is when picked up (its tag says
	// which); `on_drop` takes drops — On a branch, Before / After a leaf
	if drag != "" { drag_register(ui, row, drag, tag = tag) } else { delete_key(&ui.drags, row) }
	drag_rest(ui, row, on_rest) // a drag resting on a branch opens it
	if handler_live(on_drop) {
		positions := drop_positions if drop_positions != {} else ({.On} if expandable else {.Before, .After}) // a leaf may take drops On itself (a sidebar place)
		drop_target(ui, row, on_drop, accepts = accepts, positions = positions)
	} else {
		delete_key(&ui.on_drop, row)
	}

	open_scope(ui, row, loc)
	chev, ccreated := reconcile_child(ui, .Custom, 1, loc)
	cd := node_get(t, chev)
	if ccreated do cd.access.role = .None
	csize := [2]f32{lk.chevron_size, lk.chevron_size}
	if ck, ok := cd.kind.(Custom_Kind); ccreated || !ok || ck.size != csize { // every build: a new theme can resize it
		cd.kind = Custom_Kind{size = csize, paint = paint_tree_chevron}
		mark_layout_dirty(t, chev)
	}
	cd.tag = tag // on_change's Ev.tag is the item's
	if expandable {
		ui.on_bool[chev] = on_change
		if open { cd.access.states += {.Checked} } else { cd.access.states -= {.Checked} } // click() flips Checked
	} else {
		delete_key(&ui.on_bool, chev)
	}
	if icon != .None do baldr_icon(ui, icon, lk.icon_size, ic, loc)
	if handler_live(on_submit) {
		inline_edit(ui, label, on_submit, on_cancel, true, Edit_Ref{view = tree, row = int(tag)}, "Rename", 3, loc)
	} else {
		lbl := text(ui, label, role = lk.text.role, size = lk.text.size, color = fg, nowrap = true, ellipsis = .End,
			weight = lk.text.weight, family = look_family(t, lk.text.family), loc = loc)
		set_role(t, lbl, .None) // the row carries the name
	}
	close_scope(ui)

	prev, had := t.tree_rows[row]
	t.tree_rows[row] = Tree_Row{tree = tree, chevron = chev if expandable else NODE_NONE, container = NODE_NONE, depth = depth, expandable = expandable, expanded = open}
	if had && prev.expanded != open do mark_paint_dirty(t, chev)
	if !open do return false
	cont, _ := reconcile_child(ui, .Box, k ~ TREE_BRANCH_KEY, loc)
	indent := t.tree_views[tree].indent
	set_layout(t, cont, Layout_Props{axis = .Column, align = .Stretch, gap = 1, padding = {0, 0, 0, indent}})
	t.tree_branches[cont] = row
	(&t.tree_rows[row]).container = cont
	open_scope(ui, cont, loc)
	return true
}

// tree_label_key identifies an unkeyed item by its label.
@(private)
tree_label_key :: proc(label: string) -> u64 {
	return hash.fnv64a(transmute([]byte)label) | 1
}

// tree_scope finds the tree view an open scope belongs to and the depth of
// items built in it (0 directly under the tree).
@(private)
tree_scope :: proc(t: ^Tree, scope: Node) -> (tree: Node, depth: int) {
	for cur := scope; cur != NODE_NONE; {
		if _, is_tree := t.tree_views[cur]; is_tree do return cur, 0
		if row, is_branch := t.tree_branches[cur]; is_branch {
			if r, ok := t.tree_rows[row]; ok do return r.tree, r.depth + 1
		}
		d := node_get(t, cur)
		if d == nil do break
		cur = d.parent
	}
	return NODE_NONE, 0
}

// tree_rows_in_order lists a tree's visible rows top to bottom, in temp
// memory by default.
tree_rows_in_order :: proc(t: ^Tree, tree: Node, allocator := context.temp_allocator) -> []Node {
	out := make([dynamic]Node, allocator)
	walk :: proc(t: ^Tree, n: Node, out: ^[dynamic]Node) {
		d := node_get(t, n)
		if d == nil do return
		for c := d.first; c != NODE_NONE; c = node_get(t, c).next {
			cd := node_get(t, c)
			if .Hidden in cd.flags do continue
			if _, is_row := t.tree_rows[c]; is_row {
				append(out, c)
				continue // a row's own children are its chevron, icon and label
			}
			walk(t, c, out)
		}
	}
	walk(t, tree, &out)
	return out[:]
}

@(private)
tree_set_cursor :: proc(t: ^Tree, tree, row: Node) {
	tv := &t.tree_views[tree]
	if tv == nil || tv.cursor == row do return
	tv.cursor = row
	set_active_item(t, tree, row) // the tree keeps the focus; this is the row a reader should hear
	mark_paint_dirty(t, tree)
}

// tree_row_click is a pointer click on a row: the tree takes focus, the
// cursor moves, on_click selects; a second click within the double-click
// time activates instead.
@(private)
tree_row_click :: proc(ui: ^Ui($Msg), row: Node) -> bool {
	t := &ui.tree
	tr, ok := t.tree_rows[row]
	if !ok do return false
	tv := &t.tree_views[tr.tree]
	if tv == nil do return false
	set_focus(t, tr.tree, false)
	tree_set_cursor(t, tr.tree, row)
	now := t.now_ms
	double := tv.last_row == row && now - tv.last_click < TABLE_DOUBLE_CLICK_MS && now > 0
	was_the_one := tv.cursor == row && .Selected in node_get(t, row).access.states && ui.pointer.mods == {}
	tv.last_click, tv.last_row = now, row
	if double {
		ui.edit_pending = {}
		if h, has := ui.on_activate[row]; has do return handler_send(ui, h, 0, row)
	} else if was_the_one && tr.tree in ui.on_edit {
		edit_pending_start(ui, tr.tree, int(node_get(t, row).tag), 0) // a slow second click on the selected item: edit it
	}
	if m, has := ui.clicks[row]; has {
		append(&ui.msgs, m)
		return true
	}
	return false
}

@(private)
tree_toggle :: proc(ui: ^Ui($Msg), row: Node, expanded: bool) -> bool {
	tr, ok := ui.tree.tree_rows[row]
	if !ok || !tr.expandable do return false
	if h, has := ui.on_bool[tr.chevron]; has do return handler_send(ui, h, expanded, tr.chevron)
	return false
}

// tree_key moves the focused tree's cursor (selection follows it), expands
// and collapses with Left / Right, activates with Enter.
tree_key :: proc(ui: ^Ui($Msg), key: Key, mods: Mods) -> bool {
	t := &ui.tree
	tree := t.focus
	tv, ok := &t.tree_views[tree]
	if !ok do return false
	rows := tree_rows_in_order(t, tree)
	if len(rows) == 0 do return false
	idx := -1
	for r, i in rows do if r == tv.cursor { idx = i; break }
	go :: proc(ui: ^Ui($Msg), tree: Node, rows: []Node, i: int) -> bool {
		row := rows[clamp(i, 0, len(rows) - 1)]
		tree_set_cursor(&ui.tree, tree, row)
		scroll_into_view(&ui.tree, row)
		if m, has := ui.clicks[row]; has do append(&ui.msgs, m) // selection follows the cursor
		return true
	}
	#partial switch key {
	case .Down: return go(ui, tree, rows, idx + 1 if idx >= 0 else 0)
	case .Up:   return go(ui, tree, rows, idx - 1 if idx > 0 else 0)
	case .Home: return go(ui, tree, rows, 0)
	case .End:  return go(ui, tree, rows, len(rows) - 1)
	case .Page_Down, .Page_Up: // a viewport of rows, less one to keep context; the whole tree without a scroll
		page := len(rows)
		if sc := scroll_ancestor(t, tree); sc != NODE_NONE {
			if st, has := t.scrolls[sc]; has {
				rd := node_get(t, rows[max(idx, 0)])
				if rd != nil && rd.abs.h > 0 do page = max(int(st.viewport.y / rd.abs.h) - 1, 1)
			}
		}
		from := idx if idx >= 0 else 0
		return go(ui, tree, rows, from + (page if key == .Page_Down else -page))
	case .Right:
		if idx < 0 do return go(ui, tree, rows, 0)
		tr := t.tree_rows[rows[idx]]
		if tr.expandable && !tr.expanded do return tree_toggle(ui, rows[idx], true)
		if tr.expanded && idx + 1 < len(rows) && t.tree_rows[rows[idx + 1]].depth > tr.depth do return go(ui, tree, rows, idx + 1)
		return true
	case .Left:
		if idx < 0 do return go(ui, tree, rows, 0)
		tr := t.tree_rows[rows[idx]]
		if tr.expandable && tr.expanded do return tree_toggle(ui, rows[idx], false)
		for j := idx - 1; j >= 0; j -= 1 do if t.tree_rows[rows[j]].depth < tr.depth do return go(ui, tree, rows, j)
		return true
	case .Enter:
		if idx < 0 || shortcut_bound(ui, key, mods) do return false // the app's own Alt+Enter wins, as its Space does
		if h, has := ui.on_activate[rows[idx]]; has do return handler_send(ui, h, 0, rows[idx])
		if m, has := ui.clicks[rows[idx]]; has { append(&ui.msgs, m); return true }
	case .Space:
		if idx < 0 || shortcut_bound(ui, key, mods) do return false // the app's own Space wins, as in a table
		if m, has := ui.clicks[rows[idx]]; has { append(&ui.msgs, m); return true }
	case .F2:
		if idx < 0 do return false
		if h, has := ui.on_edit[tree]; has do return handler_send(ui, h, int(node_get(t, rows[idx]).tag), tree)
	}
	return false
}

// paint_tree_chevron cross-fades the expander between right and down.
@(private)
paint_tree_chevron :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer) {
	tr, ok := t.tree_rows[d.parent]
	if !ok || !tr.expandable do return
	th := &t.theme
	k := anim_target(t, n, .Value, 1 if tr.expanded else 0, th.motion.fast)
	c := tree_row_look(th).chevron_ink
	c.a *= t.paint_opacity
	if rd := node_get(t, d.parent); rd != nil && .Disabled in rd.flags do c.a *= th.state.disabled_alpha
	r := d.abs
	if k < 0.99 {
		c1 := c
		c1.a *= 1 - k
		append(&l.cmds, Draw_Icon{pos = {r.x, r.y}, icon = .Chevron_Right, size = r.w, color = c1})
	}
	if k > 0.01 {
		c2 := c
		c2.a *= k
		append(&l.cmds, Draw_Icon{pos = {r.x, r.y}, icon = .Chevron_Down, size = r.w, color = c2})
	}
}

// paint_tree_over draws the indent guides (one hairline per ancestor level,
// through the chevron column) and the cursor ring while the tree has
// visible focus.
@(private)
paint_tree_over :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer) {
	tv, ok := &t.tree_views[n]
	if !ok do return
	th := &t.theme
	lk := tree_row_look(th)
	guide := lk.guide
	guide.a *= t.paint_opacity
	x0 := d.abs.x + d.layout.padding[3] + lk.padding[3] + lk.chevron_size / 2 // a row's start padding, then the middle of its chevron
	for row, tr in t.tree_rows {
		if tr.tree != n || tr.depth == 0 do continue
		rd := node_get(t, row)
		if rd == nil || .Hidden in rd.flags do continue
		for level in 1 ..= tr.depth {
			x := x0 + f32(level - 1) * tv.indent
			append(&l.cmds, Draw_Rect{rect = {x - 0.5, rd.abs.y, 1, rd.abs.h + 1}, color = guide})
		}
	}
	if t.focus == n && t.focus_visible {
		if rd := node_get(t, tv.cursor); rd != nil && .Hidden not_in rd.flags {
			fr := focus_ring_look(th)
			ring := fr.color
			ring.a *= t.paint_opacity
			append(&l.cmds, Draw_Rect{rect = rd.abs, color = {}, radius = lk.radius, border_w = fr.width, border = ring})
		}
	}
}
