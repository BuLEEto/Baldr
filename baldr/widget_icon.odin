package baldr

// icon draws one of the vendored Lucide icons (icons_data.odin) at `size`
// logical px in `color` (the text colour by default). Decorative by
// default (no accessibility node); give it a `label` to make it an Image
// with a name. Buttons, menu items and table cells take an `icon` argument
// and place it themselves.

ICON_SIZE :: f32(16)

icon :: proc(ui: ^Ui($Msg), which: Icon, size: f32 = 0, color: Color = {}, label: string = "",
	key: u64 = 0, loc := #caller_location) -> Node {
	n, created := reconcile_child(ui, .Custom, key, loc)
	t := &ui.tree
	d := node_get(t, n)
	px := size if size > 0 else ICON_SIZE
	if ck, ok := d.kind.(Custom_Kind); !ok || created || ck.size.x != px || ck.paint != paint_icon {
		d.kind = Custom_Kind{size = {px, px}, paint = paint_icon}
		mark_layout_dirty(t, n)
	}
	if d.tag != u64(which) {
		d.tag = u64(which)
		mark_paint_dirty(t, n)
	}
	fg := color if color != {} else t.theme.color.on_surface
	if d.style.fg != fg {
		d.style.fg = fg
		mark_paint_dirty(t, n)
	}
	if label != "" {
		d.access.role = .Image
		set_name(t, n, label)
	} else {
		d.access.role = .None
	}
	return n
}

@(private)
paint_icon :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer) {
	which := Icon(d.tag)
	if which == .None do return
	c := d.style.fg
	c.a *= t.paint_opacity
	if disabled_within(t, n) do c.a *= t.theme.state.disabled_alpha
	append(&l.cmds, Draw_Icon{pos = {d.abs.x, d.abs.y}, icon = which, size = d.abs.w, color = c})
}
