package baldr

// expander is a disclosure: a header row with a chevron that opens a
// content scope beneath it. `expanded` is the app's state (on_change flips
// it); the content fades up when it appears:
//
//	if baldr.expander(ui, "Advanced", s.more, on_change = proc(e: baldr.Ev(bool)) -> Msg { return More{e.value} }) {
//		defer baldr.end(ui)
//		…
//	}
//
// Accessibility: the header is a Button named `title` with Expanded /
// Collapsed; Enter / Space flip it.

expander :: proc(ui: ^Ui($Msg), title: string, expanded: bool, on_change: Handler(Msg, bool) = nil,
	tag: u64 = 0, key: u64 = 0, loc := #caller_location) -> bool {
	t := &ui.tree
	th := &t.theme
	n, _ := reconcile_child(ui, .Box, key, loc)
	set_layout(t, n, Layout_Props{axis = .Column, align = .Stretch})
	open_scope(ui, n, loc)
	hdr, hcreated := reconcile_child(ui, .Box, 1, loc)
	hd := node_get(t, hdr)
	if hcreated {
		hd.access.role = .Button
		hd.flags += {.Focusable}
	}
	hd.tag = tag
	set_name(t, hdr, title)
	states := hd.access.states - {.Expanded, .Collapsed}
	states += {.Expanded} if expanded else {.Collapsed}
	if states != hd.access.states {
		hd.access.states = states
		mark_paint_dirty(t, hdr)
	}
	ui.on_bool[hdr] = on_change
	set_layout(t, hdr, Layout_Props{axis = .Row, align = .Center, gap = th.space[.xs], padding = {th.space[.xs], th.space[.sm], th.space[.xs], th.space[.xs]}})
	hst := hd.style
	hst.radius = th.radius.sm
	set_style(t, hdr, hst)
	open_scope(ui, hdr, loc)
	chev, ccreated := reconcile_child(ui, .Custom, 0, loc)
	if ccreated do node_get(t, chev).kind = Custom_Kind{size = {TREE_CHEVRON, TREE_CHEVRON}, paint = paint_expander_chevron}
	lbl := text(ui, title, role = .Label, loc = loc)
	set_role(t, lbl, .None)
	close_scope(ui)
	if !expanded {
		close_scope(ui)
		return false
	}
	body, bcreated := reconcile_child(ui, .Box, 2, loc)
	if bcreated do transition(ui, body, .Fade_Up, .None, th.motion.fast)
	set_layout(t, body, Layout_Props{axis = .Column, align = .Stretch, gap = th.space[.sm], padding = {th.space[.xs], 0, th.space[.sm], TREE_CHEVRON + th.space[.xs] + th.space[.xs]}})
	open_scope(ui, body, loc)
	ui.scopes[len(ui.scopes) - 1].extra_pops = 1 // end(ui) closes the body and the expander
	return true
}

@(private)
paint_expander_chevron :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer) {
	hd := node_get(t, d.parent)
	if hd == nil do return
	th := &t.theme
	k := anim_target(t, n, .Value, 1 if .Expanded in hd.access.states else 0, th.motion.fast)
	c := th.color.on_surface
	c.a *= 0.7 * t.paint_opacity
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
