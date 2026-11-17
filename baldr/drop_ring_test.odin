#+build linux
package baldr

@(require) import "core:fmt"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// The ring that says "this will take it" is wrong when the drag came from
// inside the thing being ringed: an icon view filling a whole screen would
// be outlined in accent for the length of every move within it.


@(private = "file")
Dr_Msg :: enum { None, Dropped }

@(private = "file")
dr_view :: proc(ui: ^Ui(Dr_Msg), sel: ^Selection) -> Node {
	set_viewport(&ui.tree, {600, 400})
	begin_view(ui)
	column(ui, flex = 1)
	first, last := icon_view(ui, 6, sel,
		drag = "files", accepts = "files",
		on_drop = proc(e: Ev(Drop)) -> Dr_Msg { return .Dropped },
		label = "Desktop", key = 11)
	for i in first ..< last do icon_item(ui, i, .File, fmt.tprintf("f-%d", i))
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	return node_first(&ui.tree, node_first(&ui.tree, ui.root))
}

@(private = "file")
dr_tile :: proc(ui: ^Ui(Dr_Msg), view: Node, index: int) -> Rect {
	for n, ref in ui.rows do if ref.table == view && ref.index == index do return node_get(&ui.tree, n).abs
	return {}
}

@(private = "file")
dr_rings :: proc(ui: ^Ui(Dr_Msg)) -> int {
	n := 0
	for c in draw_list(&ui.tree) do if r, is_rect := c.(Draw_Rect); is_rect && r.border_w == 2 && r.color.a == 0 do n += 1
	return n
}

@(test)
a_drag_from_inside_a_view_does_not_ring_the_view :: proc(t: ^testing.T) {
	ui: Ui(Dr_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	view := dr_view(&ui, &sel)
	tile0, tile3 := dr_tile(&ui, view, 0), dr_tile(&ui, view, 3)

	// lift tile 0 and take it over the view's own empty ground
	p := [2]f32{tile0.x + 10, tile0.y + 10}
	pointer_button(&ui, .Left, true, p)
	pointer_move(&ui, p + {14, 0})
	testing.expect(t, ui.drag.active)
	vd := node_get(&ui.tree, view)
	pointer_move(&ui, {vd.abs.x + vd.abs.w - 30, vd.abs.y + vd.abs.h - 30})
	testing.expect_value(t, ui.drag.target, view)         // the drop still lands on the view…
	testing.expect_value(t, ui.tree.drag_over, NODE_NONE) // …and says nothing about it
	dr_view(&ui, &sel)
	testing.expect_value(t, dr_rings(&ui), 0)

	// over another tile it rings that tile, which is a real question: the
	// drop goes into it, not past it
	pointer_move(&ui, {tile3.x + 10, tile3.y + 10})
	testing.expect(t, ui.tree.drag_over != NODE_NONE && ui.tree.drag_over != view)
	dr_view(&ui, &sel)
	testing.expect_value(t, dr_rings(&ui), 1)
	pointer_button(&ui, .Left, false, {tile3.x + 10, tile3.y + 10})

	// a drag from outside the app has no source of ours: the view rings, as
	// it must — that is the one case where the answer is in doubt
	ui.drag = {active = true, external = true, kind = "files", source = NODE_NONE, target = NODE_NONE}
	drag_set_target(&ui, view, .On)
	testing.expect_value(t, ui.tree.drag_over, view)
	ui.drag = {}
}

@(private = "file")
Dr_Ext :: struct { offer: string, asked: int, finished: int }

@(private = "file")
dr_ext_receive :: proc(user: rawptr, mime: string) -> bool { (^Dr_Ext)(user).asked += 1; return true }
@(private = "file")
dr_ext_finish :: proc(user: rawptr, accepted: bool) { (^Dr_Ext)(user).finished += 1 }
@(private = "file")
dr_ext_accept :: proc(user: rawptr, accept: bool) {}
@(private = "file")
dr_ext_start :: proc(user: rawptr, surface: u32, items: []Clip_Item, serial: u32, icon: Drag_Icon) -> bool { return false }

@(test)
a_drop_from_another_app_puts_its_ring_out :: proc(t: ^testing.T) {
	// A file dropped from another program lands, and the ring that said
	// "this will take it" must go out with the drop.
	ui: Ui(Dr_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	fake := Dr_Ext{offer = "file:///tmp/a.txt\r\n"}
	ui.dnd = {user = &fake, surface = 1, start = dr_ext_start, accept = dr_ext_accept, receive = dr_ext_receive, finish = dr_ext_finish}
	view := dr_view(&ui, &sel)
	tile := dr_tile(&ui, view, 1)
	over := [2]f32{tile.x + tile.w / 2, tile.y + tile.h / 2}

	testing.expect(t, drag_ext_enter(&ui, over, true), "another app's file drag is taken")
	drag_ext_motion(&ui, over)
	dr_view(&ui, &sel)
	testing.expectf(t, dr_rings(&ui) > 0, "it rings what it is over while it is over it (%d)", dr_rings(&ui))

	ringed := ui.drag.target
	testing.expect(t, drag_ext_drop(&ui, over), "and it drops")
	testing.expect(t, drag_ext_data(&ui, transmute([]u8)fake.offer, true), "its paths arrive")
	testing.expect(t, !ui.drag.active, "the drag is over")
	// Before any rebuild: the tree has forgotten the target, and the node
	// that was ringed is marked for repaint. Clearing `t.drag_over` alone
	// leaves the cached ring on screen until something else repaints it.
	testing.expect_value(t, ui.tree.drag_over, NODE_NONE)
	if rd := node_get(&ui.tree, ringed); rd != nil {
		testing.expect(t, .Dirty_Paint in rd.flags, "the node that was ringed is marked for repaint")
		layer := ringed
		for layer != NODE_NONE {
			if .Layer in node_get(&ui.tree, layer).flags do break
			layer = node_get(&ui.tree, layer).parent
		}
		if layer != NODE_NONE {
			testing.expect(t, .Layer_Dirty in node_get(&ui.tree, layer).flags, "and its layer will be built again")
		}
	}
	dr_view(&ui, &sel)
	testing.expectf(t, dr_rings(&ui) == 0, "and the ring goes out with it (%d still lit)", dr_rings(&ui))
}

@(test)
a_ring_that_goes_out_damages_the_pixels_it_drew :: proc(t: ^testing.T) {
	// The half the draw list cannot see: `draw_list` flattens every layer
	// afresh, so it always shows the ring gone, but a window redraws only
	// the damaged rectangles, and a drop ring is drawn 2 px outside the node
	// it rings. Damaging the node's own rect would leave the ring's pixels.
	//
	// The target stands in open space on purpose: inside a clipping view
	// the ring is clipped at the edges anyway, and the fault would not show.
	ui: Ui(Dr_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	fake := Dr_Ext{offer = "file:///tmp/a.txt\r\n"}
	ui.dnd = {user = &fake, surface = 1, start = dr_ext_start, accept = dr_ext_accept, receive = dr_ext_receive, finish = dr_ext_finish}

	zone: Node
	build :: proc(ui: ^Ui(Dr_Msg)) -> Node {
		set_viewport(&ui.tree, {600, 400})
		begin_view(ui)
		column(ui, flex = 1, padding = .lg)
		z := column(ui, width = 320, height = 200)
		text(ui, "another program's window")
		end(ui)
		drop_target(ui, z, proc(e: Ev(Drop)) -> Dr_Msg { return .Dropped }, accepts = "")
		end(ui)
		end_view(ui)
		frame(&ui.tree, {600, 400})
		return z
	}
	zone = build(&ui)
	r := node_get(&ui.tree, zone).abs
	over := [2]f32{r.x + r.w / 2, r.y + r.h / 2}

	drag_ext_enter(&ui, over, true)
	drag_ext_motion(&ui, over)
	testing.expect_value(t, ui.drag.target, zone)
	build(&ui)
	testing.expectf(t, dr_rings(&ui) > 0, "it is ringed while the drag is over it (%d)", dr_rings(&ui))
	take_damage(&ui.tree) // from here on, only what the ring going out damages

	drag_ext_drop(&ui, over)
	drag_ext_data(&ui, transmute([]u8)fake.offer, true)
	build(&ui)
	dmg := take_damage(&ui.tree)
	testing.expectf(t, dr_rings(&ui) == 0, "the ring goes out with the drop (%d still drawn)", dr_rings(&ui))

	// …and the band it drew in is redrawn, or its pixels stay on screen.
	for c in ([][2]f32{
		{r.x - 2, r.y - 2}, {r.x + r.w + 2, r.y - 2},
		{r.x - 2, r.y + r.h + 2}, {r.x + r.w + 2, r.y + r.h + 2},
	}) {
		covered := false
		for d in dmg {
			if c.x >= d.x - 0.01 && c.x <= d.x + d.w + 0.01 && c.y >= d.y - 0.01 && c.y <= d.y + d.h + 0.01 {
				covered = true
				break
			}
		}
		testing.expectf(t, covered, "the ring's pixels at %v are redrawn when it goes out (damage %v)", c, dmg)
	}
}

} // when ODIN_TEST