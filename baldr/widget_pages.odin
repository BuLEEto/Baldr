package baldr

// Pages: one page of a set shown in the same place, sliding between them.

// pages shows one page of a set in the same place: a popover's grid of
// tiles, then a tile's page, then back again. Build only the current page
// inside it and close it with end; `page` names that page (one value per
// page) and `depth` how deep it is (the grid 0, a tile's page 1, a page
// opened from that 2). When `page` changes, the new page slides in from
// the end while the old one slides out to the start, whole and edge to
// edge (the other way round when `depth` goes down), and the container
// eases its height to the new page's over motion.base, keeping its width;
// under reduce motion the change is at once. A page that leaves keeps its
// nodes, so its scroll, fields and state are there when it comes back.
// Going deeper moves focus to the new page's first control; coming back
// returns it to the control that opened the page (both only when focus was
// in the pages, or nowhere). A Group named by `label`.
pages :: proc(ui: ^Ui($Msg), page: u64, depth := 0, label := "", key: u64 = 0, loc := #caller_location) {
	t := &ui.tree
	th := &t.theme
	n, created := reconcile_child(ui, .Custom, key, loc)
	d := node_get(t, n)
	if created {
		d.kind = Custom_Kind{measure = pages_measure}
		d.flags += {.Clips}
		t.pages[n] = {page = page, depth = depth, openers = make([dynamic]Page_Opener, t.allocator)}
	}
	d.access.role = .Group if label != "" else .None
	set_name(t, n, label)
	ps := &t.pages[n]
	changed := !created && ps.page != page
	back := depth < ps.depth
	here := pages_key(page)
	move_focus := changed && (t.focus == NODE_NONE || pages_holds(t, n, t.focus))
	if changed {
		for c := d.first; c != NODE_NONE; c = node_get(t, c).next {
			cd := node_get(t, c)
			if cd.key == here || .Exiting in cd.flags do continue
			if !back && pages_holds(t, c, t.focus) do pages_remember(ps, ps.page, t.focus) // the control that opened the next page
			cd.flags += {.Exiting} // skipped by focus and hits while it slides away; kept, not destroyed
			cd.style.exit = {kind = .Slide_End if back else .Slide_Start, duration = th.motion.base}
			mark_paint_dirty(t, c)
		}
	}
	open_scope(ui, n, loc)
	child, ccreated := reconcile_child(ui, .Box, here, loc)
	cd := node_get(t, child)
	if ccreated do cd.layout = {axis = .Column, align = .Stretch}
	if changed {
		cd.style.enter = {kind = .Slide_Start if back else .Slide_End, duration = th.motion.base}
		mark_paint_dirty(t, child)
		if move_focus {
			opener := pages_opener(ps, page) if back else NODE_NONE
			ui.pending_focus = opener if node_valid(t, opener) && focusable(t, opener) else child
		}
	}
	ps.page, ps.depth = page, depth
	open_scope(ui, child, loc)
	ui.scopes[len(ui.scopes) - 1].extra_pops = 1 // end closes the page and the container
}

// Pages_State is a pages container's: the page shown, how deep it is, and
// the control that opened the next page from each page.
@(private)
Pages_State :: struct {
	page:     u64,
	depth:    int,
	measured: bool,
	openers:  [dynamic]Page_Opener,
}

@(private)
Page_Opener :: struct {
	page: u64,
	node: Node,
}

// pages_key keys a page's node among its container's children.
@(private)
pages_key :: proc "contextless" (page: u64) -> u64 {
	return (page * 0x9E37_79B9_7F4A_7C15) | 1
}

@(private)
pages_remember :: proc(ps: ^Pages_State, page: u64, node: Node) {
	for &o in ps.openers do if o.page == page {
		o.node = node
		return
	}
	append(&ps.openers, Page_Opener{page, node})
}

@(private)
pages_opener :: proc(ps: ^Pages_State, page: u64) -> Node {
	for o in ps.openers do if o.page == page do return o.node
	return NODE_NONE
}

// pages_holds: whether `n` is `root` or inside it.
@(private)
pages_holds :: proc(t: ^Tree, root, n: Node) -> bool {
	for cur := n; cur != NODE_NONE; cur = node_parent(t, cur) do if cur == root do return true
	return false
}

// pages_around is the pages container `n` is inside, or NONE.
@(private)
pages_around :: proc(t: ^Tree, n: Node) -> Node {
	for cur := node_parent(t, n); cur != NODE_NONE; cur = node_parent(t, cur) do if cur in t.pages do return cur
	return NODE_NONE
}

// pages_measure lays every page out at the container's width, one over the
// other at its origin, and gives the container the current page's height,
// eased over motion.base from the height it had (the first layout takes it
// at once).
@(private)
pages_measure :: proc(t: ^Tree, n: Node, d: ^Node_Data, cc: Constraints) -> [2]f32 {
	w := cc.max.x
	if !is_bounded(w) { // nothing to stretch to: as wide as the widest page
		w = 0
		for c := d.first; c != NODE_NONE; c = node_get(t, c).next {
			if cd := node_get(t, c); .Hidden not_in cd.flags do w = max(w, layout_node(t, c, constraints_loose({UNBOUNDED, UNBOUNDED})).x)
		}
	}
	h: f32
	for c := d.first; c != NODE_NONE; c = node_get(t, c).next {
		cd := node_get(t, c)
		if .Hidden in cd.flags {
			layout_node(t, c, constraints_loose({0, 0}))
			continue
		}
		size := layout_node(t, c, {min = {w, 0}, max = {w, UNBOUNDED}})
		cd.rect.x, cd.rect.y = 0, 0
		if .Exiting not_in cd.flags do h = max(h, size.y)
	}
	eased := anim_target(t, n, .Height, h, t.theme.motion.base)
	if ps, ok := &t.pages[n]; ok && !ps.measured {
		ps.measured = true
		anim_restart(t, n, .Height, h, h, 0)
		eased = h
	}
	return constrain(cc, {w, eased})
}
