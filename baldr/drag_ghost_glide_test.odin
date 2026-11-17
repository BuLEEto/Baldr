package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// The drag ghost draws the dragged item's own layer beside the pointer.
// When the item glides to a new slot mid-drag (the order changed under the
// drag, as a reorderable wrap does), the ghost's copy stays in the ghost's
// box rather than carrying the glide with it; and whatever repaints the item
// repaints where the ghost is. Without either, fragments of the label were
// left on screen wherever the copy had been.

@(private = "file")
Glide_Msg :: struct {}

@(private = "file")
glide_build :: proc(ui: ^Ui(Glide_Msg), order: []int) -> (chips: [3]Node) {
	names := [3]string{"Chip A", "Chip B", "Chip C"}
	set_viewport(&ui.tree, {500, 200})
	begin_view(ui)
	column(ui, padding = .md)
	wrap(ui, gap = .sm, animate = true)
	for i in order {
		chips[i] = row(ui, padding = .xs, key = u64(i + 1))
		text(ui, names[i])
		end(ui)
		draggable(ui, chips[i], "chip", tag = u64(i + 1))
	}
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {500, 200})
	return
}

@(private = "file")
glide_ghost :: proc(t: ^Tree) -> ^Node_Data {
	for c := node_first(t, t.overlay); c != NODE_NONE; c = node_next(t, c) {
		if d := node_get(t, c); d != nil && d.key == DRAG_GHOST_KEY do return d
	}
	return nil
}

@(test)
the_drag_ghost_stays_whole_while_its_item_glides :: proc(t: ^testing.T) {
	ui: Ui(Glide_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.now_ms = 1000
	chips := glide_build(&ui, {0, 1, 2})
	c := node_get(&ui.tree, chips[2])
	from := [2]f32{c.abs.x + c.abs.w / 2, c.abs.y + c.abs.h / 2}
	ui.pointer.press_serial = 7
	pointer_button(&ui, .Left, true, from)
	pointer_move(&ui, from + {20, 0})
	pointer_move(&ui, from + {40, 30})
	if !testing.expect(t, ui.drag.active, "the drag is up") do return
	// the ghost fades in as the drag starts: let it finish
	glide_build(&ui, {0, 1, 2})
	anim_tick(&ui.tree, ui.tree.now_ms + 500)
	frame(&ui.tree, {500, 200})

	// the order changes under the drag: the dragged chip glides to the front
	chips = glide_build(&ui, {2, 0, 1})
	src := node_get(&ui.tree, chips[2])
	if !testing.expect(t, src.move_from != {}, "the dragged chip is gliding") do return
	g := glide_ghost(&ui.tree)
	if !testing.expect(t, g != nil && g.abs.w > 0, "the ghost is drawn") do return

	// every copy of the label the ghost draws lies in the ghost's box
	room := paint_bounds(g, 0)
	copies := 0
	for cmd in draw_list(&ui.tree) {
		dt, is_text := cmd.(Draw_Text)
		if !is_text || dt.str != "Chip C" do continue
		r := drawn_text_rect(&ui.tree, dt)
		if !rect_intersects(r, room) && !rect_intersects(r, paint_bounds(src)) {
			testing.expectf(t, false, "a copy of the label at %v, in neither the ghost %v nor the chip", r, room)
			continue
		}
		if rect_intersects(r, room) {
			copies += 1
			inside := r.x >= room.x - 0.5 && r.y >= room.y - 0.5 && r.x + r.w <= room.x + room.w + 0.5 && r.y + r.h <= room.y + room.h + 0.5
			testing.expectf(t, inside, "the ghost's copy %v lies inside the ghost %v", r, room)
		}
	}
	testing.expect_value(t, copies, 1)

	// with everything settled, a repaint of the item alone (its look
	// changing with no rebuild: a hover fading, a thumbnail arriving)
	// repaints where the ghost is, since the ghost draws the item
	anim_tick(&ui.tree, ui.tree.now_ms + 2000)
	frame(&ui.tree, {500, 200})
	_ = take_damage(&ui.tree)
	mark_paint_dirty(&ui.tree, node_first(&ui.tree, chips[2]))
	frame(&ui.tree, {500, 200})
	room = paint_bounds(glide_ghost(&ui.tree), 0)
	hit := false
	for r in take_damage(&ui.tree) do if rect_intersects(r, room) do hit = true
	testing.expect(t, hit, "repainting the item repaints where the ghost is")
}

} // when ODIN_TEST
