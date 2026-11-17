package baldr

@(require) import "core:testing"
@(require) import "baldr:gpu"

// Behind this `when` so a program importing Baldr does not type-check the
// test suite too, which costs gigabytes. ODIN_TEST is set by `odin test`;
// BALDR_TESTS lets ./build.sh check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

RED  :: Color{1, 0, 0, 1}
BLUE :: Color{0, 0, 1, 1}

@(test)
paint_emits_in_tree_order_and_reports_damage :: proc(t: ^testing.T) {
	tr: Tree
	tree_init(&tr)
	defer tree_destroy(&tr)
	r := node_get(&tr, tr.root)
	r.layout = {axis = .Column, padding = pad4(10)}
	r.style.bg = RED
	c := node_new(&tr, Box_Kind{})
	node_get(&tr, c).layout = {width = 50, height = 50}
	node_get(&tr, c).style.bg = BLUE
	node_append(&tr, tr.root, c)

	frame(&tr, {200, 200})
	cmds := draw_list(&tr)
	testing.expect_value(t, len(cmds), 2)
	testing.expect_value(t, cmds[0].(Draw_Rect).rect, Rect{0, 0, 200, 200})
	testing.expect_value(t, cmds[1].(Draw_Rect).rect, Rect{10, 10, 50, 50})
	testing.expect(t, len(take_damage(&tr)) > 0, "first frame damages")

	// Nothing changed: no rebuild, no damage.
	tr.stats = {}
	frame(&tr, {200, 200})
	testing.expect_value(t, tr.stats.layers_rebuilt, 0)
	testing.expect_value(t, len(take_damage(&tr)), 0)

	// Restyle the child: one layer rebuild; damage is exactly the child's rect.
	st := node_get(&tr, c).style
	st.bg = {0, 1, 0, 1}
	set_style(&tr, c, st)
	frame(&tr, {200, 200})
	testing.expect_value(t, tr.stats.layers_rebuilt, 1)
	testing.expect_value(t, damage_bounds(take_damage(&tr)), Rect{10, 10, 50, 50})
}

@(test)
paint_nested_layers_flatten_in_z_order :: proc(t: ^testing.T) {
	tr: Tree
	tree_init(&tr)
	defer tree_destroy(&tr)
	node_get(&tr, tr.root).layout = {axis = .Column}
	node_get(&tr, tr.root).style.bg = RED
	a := node_new(&tr, Box_Kind{})
	node_get(&tr, a).layout = {width = 100, height = 100, axis = .Column}
	node_get(&tr, a).style.bg = BLUE
	node_append(&tr, tr.root, a)
	set_layer(&tr, a, true)
	g := node_new(&tr, Box_Kind{})
	node_get(&tr, g).layout = {width = 10, height = 10}
	node_get(&tr, g).style.bg = {0, 1, 0, 1}
	node_append(&tr, a, g)
	b := node_new(&tr, Box_Kind{})
	node_get(&tr, b).layout = {width = 20, height = 20}
	node_get(&tr, b).style.bg = {1, 1, 0, 1}
	node_append(&tr, tr.root, b)

	frame(&tr, {200, 200})
	cmds := draw_list(&tr)
	testing.expect_value(t, len(cmds), 4)
	testing.expect_value(t, cmds[0].(Draw_Rect).color, RED)
	testing.expect_value(t, cmds[1].(Draw_Rect).color, BLUE)
	testing.expect_value(t, cmds[2].(Draw_Rect).rect, Rect{0, 0, 10, 10})
	testing.expect_value(t, cmds[3].(Draw_Rect).rect, Rect{0, 100, 20, 20})

	// Restyling the grandchild rebuilds only layer A, not the root layer.
	tr.stats = {}
	st := node_get(&tr, g).style
	st.bg = {0, 0, 0, 1}
	set_style(&tr, g, st)
	frame(&tr, {200, 200})
	testing.expect_value(t, tr.stats.layers_rebuilt, 1)
	testing.expect_value(t, tr.stats.paint_nodes, 2) // a + g
}

@(test)
paint_text_and_clip :: proc(t: ^testing.T) {
	tr: Tree
	tree_init(&tr)
	defer tree_destroy(&tr)
	node_get(&tr, tr.root).flags += {.Clips}
	n := node_new(&tr, Text_Kind{str = "hi", size = 16})
	node_get(&tr, n).style.fg = {1, 1, 1, 1}
	node_append(&tr, tr.root, n)
	frame(&tr, {100, 100})
	cmds := draw_list(&tr)
	testing.expect_value(t, len(cmds), 3)
	_, is_push := cmds[0].(Draw_Clip_Push)
	txt, is_text := cmds[1].(Draw_Text)
	_, is_pop := cmds[2].(Draw_Clip_Pop)
	testing.expect(t, is_push && is_text && is_pop, "clip push, text, clip pop")
	testing.expect_value(t, txt.str, "hi")
}

@(test)
paint_glass_emits_backdrop_or_opaque_fallback :: proc(t: ^testing.T) {
	tr: Tree
	tree_init(&tr)
	defer tree_destroy(&tr)
	node_get(&tr, tr.root).layout = {axis = .Column} // no stretch: keep the child at its own width
	n := node_new(&tr, Box_Kind{})
	node_get(&tr, n).layout = {width = 100, height = 50}
	node_get(&tr, n).style.radius = 8
	node_get(&tr, n).style.material = {tint = {0.1, 0.1, 0.1, 0.7}, blur = 20, saturation = 1}
	node_append(&tr, tr.root, n)

	frame(&tr, {200, 200})
	cmds := draw_list(&tr)
	testing.expect_value(t, len(cmds), 1)
	bd, is_bd := cmds[0].(Draw_Backdrop)
	testing.expect(t, is_bd, "glass on: a backdrop, no plain rect")
	testing.expect_value(t, bd.material.blur, f32(20))

	// Solid glass (reduced transparency): same colour, opaque, no blur.
	tr.theme.glass = .Solid
	mark_paint_dirty(&tr, n)
	frame(&tr, {200, 200})
	cmds = draw_list(&tr)
	testing.expect_value(t, len(cmds), 1)
	r, is_rect := cmds[0].(Draw_Rect)
	testing.expect(t, is_rect, "glass off: an opaque rect")
	testing.expect_value(t, r.color.a, f32(1))
	testing.expect_value(t, r.color.rgb, Color{0.1, 0.1, 0.1, 0.7}.rgb)

	// Device-pixel conversion scales blur and rect.
	tr.theme.glass = .Frosted
	mark_paint_dirty(&tr, n)
	frame(&tr, {200, 200})
	out := make([dynamic]gpu.Cmd, context.temp_allocator)
	render_prepare(&tr, 2, nil, &out)
	testing.expect_value(t, len(out), 1)
	g := out[0].(gpu.Backdrop)
	testing.expect_value(t, g.blur, f32(40))
	testing.expect_value(t, g.rect, [4]f32{0, 0, 200, 100})
}

@(test)
layout_stack_overlaps_children_with_offsets :: proc(t: ^testing.T) {
	tr: Tree
	tree_init(&tr)
	defer tree_destroy(&tr)
	node_get(&tr, tr.root).layout = {axis = .Stack, padding = pad4(10)}
	a := node_new(&tr, Box_Kind{})
	node_get(&tr, a).layout = {width = 100, height = 100}
	b := node_new(&tr, Box_Kind{})
	node_get(&tr, b).layout = {width = 40, height = 40, offset = {10, 20}}
	node_append(&tr, tr.root, a)
	node_append(&tr, tr.root, b)
	layout(&tr, {300, 300})
	testing.expect_value(t, node_get(&tr, a).abs, Rect{10, 10, 100, 100})
	testing.expect_value(t, node_get(&tr, b).abs, Rect{20, 30, 40, 40})
	testing.expect_value(t, hit_test(&tr, {25, 35}), b) // later sibling wins where they overlap
	testing.expect_value(t, hit_test(&tr, {90, 90}), a)
}

} // when ODIN_TEST