#+build linux
package baldr

@(require) import "core:fmt"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A drag shows what is being dragged: the ghost is a faded copy of the item
// itself, so an item whose appearance is a thumbnail comes along as that
// thumbnail, not as a chip built from its name and an icon.


@(private = "file")
Dg_Msg :: enum { None }

@(private = "file")
dg_view :: proc(ui: ^Ui(Dg_Msg), sel: ^Selection, img: ^Image) -> Node {
	set_viewport(&ui.tree, {600, 400})
	begin_view(ui)
	column(ui, flex = 1)
	first, last := icon_view(ui, 4, sel, drag = "files", label = "Desktop", key = 12)
	for i in first ..< last do icon_item(ui, i, .File, fmt.tprintf("f-%d", i), picture = img)
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	return node_first(&ui.tree, node_first(&ui.tree, ui.root))
}

@(private = "file")
dg_tile :: proc(ui: ^Ui(Dg_Msg), view: Node, index: int) -> Node {
	for n, ref in ui.rows do if ref.table == view && ref.index == index do return n
	return NODE_NONE
}

@(test)
a_drag_ghost_is_the_item_itself :: proc(t: ^testing.T) {
	ui: Ui(Dg_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	px := []u8{255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255}
	img, made := image_from_rgba(4, 1, px)
	testing.expect(t, made)
	defer image_destroy(&img)

	view := dg_view(&ui, &sel, &img)
	tile := dg_tile(&ui, view, 1)
	testing.expect(t, tile != NODE_NONE)
	r := node_get(&ui.tree, tile).abs
	p := [2]f32{r.x + 10, r.y + 10}
	pointer_button(&ui, .Left, true, p)
	pointer_move(&ui, p + {14, 0})
	testing.expect(t, ui.drag.active)
	testing.expect_value(t, ui.drag.source, tile)
	// the item is a layer of its own while it is carried, so the ghost can
	// draw it rather than compose a chip
	testing.expect(t, .Layer in node_get(&ui.tree, tile).flags)

	ui.needs_rebuild = false
	dg_view(&ui, &sel, &img)
	ghost := node_first(&ui.tree, ui.tree.overlay)
	testing.expect(t, ghost != NODE_NONE)
	gd := node_get(&ui.tree, ghost)
	testing.expect_value(t, gd.access.role, Role.Status)
	testing.expect_value(t, Node(gd.tag), tile) // it names what it is copying
	testing.expect(t, gd.rect.w == r.w && gd.rect.h == r.h, "and is the size of it")
	testing.expect(t, gd.style.bg.a == 0 && gd.style.border_w == 0, "no chip behind it: the item is the ghost")

	// …and what is drawn is that item's layer, faded, moved to the ghost
	// (after its entrance: a ghost fades in)
	for i in 1 ..= 8 do ui_tick(&ui, f64(i) * 16)
	dg_view(&ui, &sel, &img)
	frame(&ui.tree, {600, 400})
	mirrored, faded := false, f32(1)
	for _, l in ui.tree.layers do for c in l.cmds {
		if dl, is_layer := c.(Draw_Layer); is_layer && dl.node == tile && dl.shift != {} {
			mirrored = true
			faded = dl.opacity
		}
	}
	testing.expect(t, mirrored, "the ghost draws the dragged item's own layer")
	testing.expect(t, faded > 0.4 && faded < 1, "faded, but enough to read what it is")

	// the source stays where it was, faded, and the ghost is not that copy
	source_fade := f32(1)
	for _, l in ui.tree.layers do for c in l.cmds {
		if dl, is_layer := c.(Draw_Layer); is_layer && dl.node == tile && dl.shift == {} do source_fade = dl.opacity
	}
	testing.expect(t, source_fade < faded, "where it will land is fainter than what follows the pointer")

	// let go: the ghost springs back, and when it has, the item is an
	// ordinary node again
	pointer_button(&ui, .Left, false, p)
	for i in 1 ..= 40 do ui_tick(&ui, f64(100 + i * 16))
	dg_view(&ui, &sel, &img)
	testing.expect(t, !ui.drag.active, "the drag is over")
	testing.expect(t, .Layer not_in node_get(&ui.tree, tile).flags, "and it is an ordinary node again")
}

} // when ODIN_TEST