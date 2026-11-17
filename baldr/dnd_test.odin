package baldr

@(require) import "core:fmt"
@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

Dd_Kind :: enum { None, Drop, Click }
Dd_Msg :: struct {
	kind:     Dd_Kind,
	from, to: u64,
	position: Drop_Position,
	count:    int,
}

@(private = "file")
on_drop_msg :: proc(e: Ev(Drop)) -> Dd_Msg {
	return {kind = .Drop, from = e.value.tag, to = e.tag, position = e.value.position, count = e.value.count}
}

// three chips in a row (drag sources and reorder targets), a Folder button
// that takes chips, an Other button that takes only files.
@(private = "file")
dnd_view :: proc(ui: ^Ui(Dd_Msg)) -> (chips: [3]Node, folder, other: Node) {
	names := [3]string{"Wayland", "Win32", "Vulkan"}
	set_viewport(&ui.tree, {500, 300})
	begin_view(ui)
	column(ui, gap = .lg, padding = .lg)
	row(ui, gap = .sm)
	for i in 0 ..< 3 {
		chip := row(ui, padding = .xs, bg = ui.theme.color.surface_high, radius = 12, key = u64(i + 1))
		text(ui, names[i], role = .Caption)
		end(ui)
		draggable(ui, chip, "chip", tag = u64(i + 1), count = 3 if i == 0 else 1)
		drop_target(ui, chip, on_drop_msg, accepts = "chip", positions = {.Before, .After}, tag = u64(i + 1))
		chips[i] = chip
	}
	end(ui)
	folder = button(ui, "Folder", Dd_Msg{kind = .Click}, icon = .Folder, tag = 99)
	drop_target(ui, folder, on_drop_msg, accepts = "chip")
	other = button(ui, "Other", Dd_Msg{kind = .Click}, tag = 7)
	drop_target(ui, other, on_drop_msg, accepts = "file")
	end(ui)
	end_view(ui)
	frame(&ui.tree, {500, 300})
	return
}

@(private = "file")
mid :: proc(ui: ^Ui(Dd_Msg), n: Node) -> [2]f32 {
	r := node_get(&ui.tree, n).abs
	return {r.x + r.w / 2, r.y + r.h / 2}
}

@(private = "file")
overlay_kids :: proc(ui: ^Ui(Dd_Msg)) -> (n: int, first: Node) {
	first = node_first(&ui.tree, ui.tree.overlay)
	for c := first; c != NODE_NONE; c = node_next(&ui.tree, c) do n += 1
	return
}

// A press becomes a drag only after the threshold; the ghost then follows
// the pointer above everything without taking hits, names what is dragged
// and how many, the target under the pointer shows feedback, and the
// release delivers one Drop and no click.
@(test)
drag_lifts_after_the_threshold_and_drops_on_a_target :: proc(t: ^testing.T) {
	ui: Ui(Dd_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	chips, folder, _ := dnd_view(&ui)
	p := mid(&ui, chips[0])
	pointer_button(&ui, .Left, true, p)
	pointer_move(&ui, p + {3, 0})
	testing.expect(t, ui.drag.pending && !ui.drag.active, "3 px is still a press")
	pointer_move(&ui, p + {12, 0})
	testing.expect(t, ui.drag.active, "12 px lifts the drag")
	testing.expect_value(t, ui.drag.source, chips[0])
	testing.expect(t, ui.pointer.pressed == NODE_NONE, "the press will not click")
	testing.expect(t, ui.needs_rebuild, "the ghost is built with the next view")
	ui.needs_rebuild = false
	dnd_view(&ui)
	n, ghost := overlay_kids(&ui)
	testing.expect_value(t, n, 1)
	gd := node_get(&ui.tree, ghost)
	testing.expect_value(t, gd.access.role, Role.Status)
	testing.expect(t, strings.contains(gd.access.name, "Wayland"), gd.access.name)
	testing.expect(t, .Hit_Transparent in gd.flags && hit_test(&ui.tree, {gd.abs.x + 4, gd.abs.y + 4}) != ghost, "the ghost never takes the pointer")
	badge_found := false
	for c := gd.first; c != NODE_NONE; c = node_get(&ui.tree, c).next {
		for g := node_get(&ui.tree, c).first; g != NODE_NONE; g = node_get(&ui.tree, g).next {
			if tk, ok := node_get(&ui.tree, g).kind.(Text_Kind); ok && tk.str == "3" do badge_found = true
		}
	}
	testing.expect(t, badge_found, "a count badge for a multi-selection")
	testing.expect_value(t, cursor_for(&ui), Cursor.Grabbing)
	// over the folder: a ring; the ghost moved along without a rebuild
	fp := mid(&ui, folder)
	pointer_move(&ui, fp)
	testing.expect_value(t, ui.tree.drag_over, folder)
	testing.expect_value(t, ui.tree.drag_over_pos, Drop_Position.On)
	testing.expect(t, !ui.needs_rebuild, "moving the ghost is not a rebuild")
	frame(&ui.tree, {500, 300})
	gd = node_get(&ui.tree, ghost)
	testing.expect(t, abs(gd.abs.x - (fp.x + DRAG_GHOST_OFFSET.x)) < 0.5, "the ghost sits by the pointer")
	pointer_button(&ui, .Left, false, fp)
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0], Dd_Msg{kind = .Drop, from = 1, to = 99, position = .On, count = 3})
	testing.expect(t, !ui.drag.active && ui.tree.drag_over == NODE_NONE, "the drag is over")
	ui.needs_rebuild = false
	dnd_view(&ui)
	n, _ = overlay_kids(&ui)
	testing.expect(t, n <= 1, "the ghost is gone (or fading out)")
	if n == 1 {
		_, g := overlay_kids(&ui)
		testing.expect(t, .Exiting in node_get(&ui.tree, g).flags)
	}
}

// Before / After follow the parent's axis (sideways in a row), the drag
// skips its own source and targets of other kinds, and Escape cancels.
@(test)
drag_positions_kinds_and_escape :: proc(t: ^testing.T) {
	ui: Ui(Dd_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	chips, _, other := dnd_view(&ui)
	p := mid(&ui, chips[0])
	pointer_button(&ui, .Left, true, p)
	pointer_move(&ui, p + {20, 0})
	testing.expect(t, ui.drag.active)
	r3 := node_get(&ui.tree, chips[2]).abs
	pointer_move(&ui, {r3.x + r3.w * 0.2, r3.y + r3.h / 2})
	testing.expect_value(t, ui.drag.target, chips[2])
	testing.expect_value(t, ui.drag.position, Drop_Position.Before)
	testing.expect_value(t, ui.tree.drag_over, NODE_NONE) // a reorder previews live: no insertion line
	pointer_move(&ui, {r3.x + r3.w * 0.8, r3.y + r3.h / 2})
	testing.expect_value(t, ui.drag.position, Drop_Position.After)
	pointer_move(&ui, p) // back over the source itself: no target
	testing.expect_value(t, ui.tree.drag_over, NODE_NONE)
	pointer_move(&ui, mid(&ui, other)) // takes files, not chips
	testing.expect_value(t, ui.tree.drag_over, NODE_NONE)
	testing.expect(t, key_event(&ui, .Escape, true, {}), "Escape cancels")
	testing.expect(t, ui.drag.returning, "…with a spring-back")
	pointer_button(&ui, .Left, false, mid(&ui, other))
	ui_after_events(&ui, 5000) // the spring-back finishes
	testing.expect(t, !ui.drag.active)
	testing.expect_value(t, len(ui.msgs), 0)
	// a drop After chip 3 lands with that position
	pointer_button(&ui, .Left, true, p)
	pointer_move(&ui, {r3.x + r3.w * 0.8, r3.y + r3.h / 2})
	pointer_button(&ui, .Left, false, {r3.x + r3.w * 0.8, r3.y + r3.h / 2})
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0], Dd_Msg{kind = .Drop, from = 1, to = 3, position = .After, count = 3})
}

// A press that never travels is a click, not a drag.
@(test)
drag_press_without_travel_is_a_click :: proc(t: ^testing.T) {
	ui: Ui(Dd_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	_, folder, _ := dnd_view(&ui)
	draggable(&ui, folder, "chip", tag = 99)
	p := mid(&ui, folder)
	pointer_button(&ui, .Left, true, p)
	pointer_button(&ui, .Left, false, p)
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0].kind, Dd_Kind.Click)
	testing.expect(t, !ui.drag.active && !ui.drag.pending)
}

// Keyboard: Ctrl+X picks the focused item up (announced), focus moves to
// the target and Ctrl+V drops On it; Escape puts it back.
@(test)
drag_by_keyboard_ctrl_x_and_ctrl_v :: proc(t: ^testing.T) {
	ui: Ui(Dd_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	_, folder, other := dnd_view(&ui)
	draggable(&ui, other, "chip", tag = 7)
	set_focus(&ui.tree, other, true)
	testing.expect(t, key_event(&ui, .X, true, {.Ctrl}), "Ctrl+X picks up")
	testing.expect(t, ui.drag.active && ui.drag.keyboard)
	ui.needs_rebuild = false
	dnd_view(&ui)
	draggable(&ui, other, "chip", tag = 7)
	_, ghost := overlay_kids(&ui)
	gd := node_get(&ui.tree, ghost)
	testing.expect(t, gd.access.role == .Status && gd.access.live == .Polite && strings.contains(gd.access.name, "Picked up Other"), gd.access.name)
	testing.expect(t, ui.tree.drag_source != NODE_NONE, "the source is marked while carried")
	testing.expect(t, key_event(&ui, .Tab, true, {.Shift}), "focus moves to the folder")
	testing.expect_value(t, ui.tree.focus, folder)
	ui_after_events(&ui, 1000)
	testing.expect_value(t, ui.tree.drag_over, folder)
	testing.expect(t, key_event(&ui, .V, true, {.Ctrl}), "Ctrl+V drops")
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0], Dd_Msg{kind = .Drop, from = 7, to = 99, position = .On, count = 1})
	testing.expect(t, !ui.drag.active)
	// Escape puts it back
	set_focus(&ui.tree, other, true)
	key_event(&ui, .X, true, {.Ctrl})
	testing.expect(t, ui.drag.active)
	key_event(&ui, .Escape, true, {})
	testing.expect(t, !ui.drag.active)
	testing.expect_value(t, len(ui.msgs), 1)
}

// Touch: a finger resting on a drag source for the long-press time lifts
// it; a finger that moves first scrolls or presses instead.
@(test)
drag_by_touch_long_press :: proc(t: ^testing.T) {
	ui: Ui(Dd_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	chips, folder, _ := dnd_view(&ui)
	p := mid(&ui, chips[1])
	touch_down(&ui, 1, p, 1000)
	testing.expect(t, ui.tree.wake_at_ms > 0 && ui.tree.wake_at_ms <= 1000 + TOUCH_LONG_PRESS_MS, "a wake-up is scheduled for the long press")
	ui_after_events(&ui, 1200)
	testing.expect(t, !ui.drag.active, "not yet")
	ui_after_events(&ui, 1500)
	testing.expect(t, ui.drag.active && ui.finger.gesture == .Drag, "the long press lifted it")
	testing.expect_value(t, ui.drag.source, chips[1])
	touch_move(&ui, 1, mid(&ui, folder), 1600)
	testing.expect_value(t, ui.tree.drag_over, folder)
	touch_up(&ui, 1, 1700)
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0], Dd_Msg{kind = .Drop, from = 2, to = 99, position = .On, count = 1})
	testing.expect(t, !ui.drag.active)
	// a finger that moves before the long press is not a drag
	touch_down(&ui, 1, p, 3000)
	touch_move(&ui, 1, p + {20, 0}, 3100)
	ui_after_events(&ui, 3600)
	testing.expect(t, !ui.drag.active && ui.finger.gesture != .Drag, "moved first: a press, not a drag")
	touch_up(&ui, 1, 3700)
}

// A cancelled pointer drag springs the ghost back to where it was picked
// up before it leaves; under reduce-motion it just ends.
@(test)
drag_springs_back_on_cancel :: proc(t: ^testing.T) {
	ui: Ui(Dd_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	chips, _, _ := dnd_view(&ui)
	ui_tick(&ui, 1000)
	p := mid(&ui, chips[0])
	pointer_button(&ui, .Left, true, p)
	pointer_move(&ui, p + {120, 40})
	testing.expect(t, ui.drag.active)
	far := ui.drag.pos
	testing.expect(t, key_event(&ui, .Escape, true, {}))
	testing.expect(t, ui.drag.active && ui.drag.returning, "still up, on its way back")
	testing.expect(t, ui.tree.wake_at_ms > 0, "ticks are scheduled")
	ui_after_events(&ui, 1100)
	testing.expect(t, ui.drag.active && ui.drag.pos.x < far.x && ui.drag.pos.y < far.y, "moving towards the source")
	ui_after_events(&ui, 1400)
	testing.expect(t, !ui.drag.active, "gone once it arrived")
	// a release over nothing springs back too; a new press cuts it short
	pointer_button(&ui, .Left, true, p)
	pointer_move(&ui, p + {300, 0}) // past the chips, over empty column
	testing.expect_value(t, ui.tree.drag_over, NODE_NONE)
	pointer_button(&ui, .Left, false, p + {300, 0})
	testing.expect(t, ui.drag.returning)
	pointer_button(&ui, .Left, true, mid(&ui, chips[1]))
	testing.expect(t, !ui.drag.returning && !ui.drag.active)
	pointer_button(&ui, .Left, false, mid(&ui, chips[1]))
	// reduce-motion: instant
	th := ui.theme
	th.motion.reduce = true
	set_theme(&ui.tree, th)
	pointer_button(&ui, .Left, true, p)
	pointer_move(&ui, p + {120, 40})
	key_event(&ui, .Escape, true, {})
	testing.expect(t, !ui.drag.active)
	testing.expect_value(t, len(ui.msgs), 0)
}

// A table's rows drag as the table's kind; a row that is part of the
// selection drags the whole selection (the count says how many); rows take
// drops On when the table has an on_drop.
@(test)
table_rows_drag_their_selection :: proc(t: ^testing.T) {
	ui: Ui(Dd_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	cols := []Column{{title = "Name"}, {title = "Kind", width = 80}}
	view :: proc(ui: ^Ui(Dd_Msg), cols: []Column, sel: ^Selection) -> (tbl: Node) {
		set_viewport(&ui.tree, {600, 400})
		begin_view(ui)
		column(ui, flex = 1)
		first, last := table(ui, cols, 50, sel, drag = "file", on_drop = on_drop_msg, accepts = "file", label = "Files")
		for i in first ..< last {
			table_row(ui, i)
			cell_text(ui, fmt.tprintf("file-%02d", i))
			cell_text(ui, "Text")
			end(ui)
		}
		end(ui)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {600, 400})
		return node_first(&ui.tree, node_first(&ui.tree, ui.root))
	}
	tbl := view(&ui, cols, &sel)
	for _ in 0 ..< 3 { ui.needs_rebuild = false; ui_after_events(&ui, 1); if !ui.needs_rebuild do break; tbl = view(&ui, cols, &sel) }
	row_of :: proc(ui: ^Ui(Dd_Msg), tbl: Node, index: int) -> Node {
		for n, ref in ui.rows do if ref.table == tbl && ref.index == index do return n
		return NODE_NONE
	}
	selection_set(&sel, 2)
	selection_toggle(&sel, 4)
	ui.needs_rebuild = false
	tbl = view(&ui, cols, &sel)
	r4, r7 := row_of(&ui, tbl, 4), row_of(&ui, tbl, 7)
	testing.expect(t, r4 != NODE_NONE && r7 != NODE_NONE)
	ds, ok := ui.drags[r4]
	testing.expect(t, ok && ds.kind == "file" && ds.tag == 4 && ds.count == 2, "a selected row drags the selection")
	ds7 := ui.drags[r7]
	testing.expect_value(t, ds7.count, 1)
	p := mid(&ui, r4)
	pointer_button(&ui, .Left, true, p)
	pointer_move(&ui, p + {0, 20})
	testing.expect(t, ui.drag.active && ui.drag.count == 2 && ui.drag.kind == "file")
	ui.needs_rebuild = false
	view(&ui, cols, &sel)
	_, ghost := overlay_kids(&ui)
	testing.expect(t, strings.contains(node_get(&ui.tree, ghost).access.name, "file-04"), "the ghost names the row")
	p7 := mid(&ui, r7)
	pointer_move(&ui, p7)
	testing.expect_value(t, ui.tree.drag_over, r7)
	pointer_button(&ui, .Left, false, p7)
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0], Dd_Msg{kind = .Drop, from = 4, to = 7, position = .On, count = 2})
}

// Reordering previews live: while a chip is dragged after another, the
// siblings part and the chip sits, faded, in its future slot with no
// insertion line; Escape glides it home; a drop keeps the previewed order
// so the app's rebuild confirms it without a jump.
@(test)
drag_reorder_previews_live :: proc(t: ^testing.T) {
	ui: Ui(Dd_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	chips, folder, _ := dnd_view(&ui)
	order :: proc(ui: ^Ui(Dd_Msg), chips: [3]Node) -> [3]int {
		out: [3]int
		p := node_get(&ui.tree, chips[0]).parent
		i := 0
		for c := node_first(&ui.tree, p); c != NODE_NONE && i < 3; c = node_next(&ui.tree, c) {
			for ch, k in chips do if ch == c do out[i] = k + 1
			i += 1
		}
		return out
	}
	// a point 80% across chip 3, after a layout of the current order
	after3 :: proc(ui: ^Ui(Dd_Msg), chips: [3]Node) -> [2]f32 {
		frame(&ui.tree, {500, 300})
		r3 := node_get(&ui.tree, chips[2]).abs
		return {r3.x + r3.w * 0.8, r3.y + r3.h / 2}
	}
	testing.expect_value(t, order(&ui, chips), [3]int{1, 2, 3})
	p := mid(&ui, chips[0])
	pointer_button(&ui, .Left, true, p)
	pointer_move(&ui, p + {20, 0})
	testing.expect_value(t, ui.tree.drag_source, chips[0])
	pointer_move(&ui, after3(&ui, chips))
	testing.expect(t, ui.drag.previewing, "a same-parent reorder previews")
	testing.expect_value(t, order(&ui, chips), [3]int{2, 3, 1})
	testing.expect_value(t, ui.tree.drag_over, NODE_NONE)
	frame(&ui.tree, {500, 300})
	testing.expect(t, node_get(&ui.tree, chips[0]).abs.x > node_get(&ui.tree, chips[2]).abs.x, "chip 1 sits after chip 3")
	// staying after chip 3 (now to the left) changes nothing
	pointer_move(&ui, after3(&ui, chips))
	testing.expect_value(t, order(&ui, chips), [3]int{2, 3, 1})
	// the faded source: drawn at reduced opacity. Read the flattened list,
	// not a layer's own commands — a dragged item is a layer of its own (the
	// ghost copies it), so its fade is applied where its parent inlines it.
	faded := false
	for c in draw_list(&ui.tree) {
		if r, ok := c.(Draw_Rect); ok && abs(r.rect.x - node_get(&ui.tree, chips[0]).abs.x) < 0.5 && r.color.a > 0 && r.color.a < 0.5 do faded = true
	}
	testing.expect(t, faded, "the dragged chip is painted faded in its future slot")
	// over the faded source itself (no target) the slot is kept: no flapping
	pointer_move(&ui, mid(&ui, chips[0]))
	testing.expect_value(t, ui.drag.target, NODE_NONE)
	testing.expect(t, ui.drag.previewing, "no target keeps the proposed slot")
	testing.expect_value(t, order(&ui, chips), [3]int{2, 3, 1})
	// over the folder (On): the preview is undone, the ring shows
	pointer_move(&ui, mid(&ui, folder))
	testing.expect(t, !ui.drag.previewing)
	testing.expect_value(t, order(&ui, chips), [3]int{1, 2, 3})
	testing.expect_value(t, ui.tree.drag_over, folder)
	// back to a reorder, then Escape: home again
	pointer_move(&ui, after3(&ui, chips))
	testing.expect_value(t, order(&ui, chips), [3]int{2, 3, 1})
	key_event(&ui, .Escape, true, {})
	testing.expect_value(t, order(&ui, chips), [3]int{1, 2, 3})
	pointer_button(&ui, .Left, false, ui.drag.pos)
	ui_after_events(&ui, 5000)
	testing.expect(t, !ui.drag.active && ui.tree.drag_source == NODE_NONE)
	testing.expect_value(t, len(ui.msgs), 0)
	// a drop keeps the previewed order until the app rebuilds
	frame(&ui.tree, {500, 300})
	p = mid(&ui, chips[0])
	pointer_button(&ui, .Left, true, p)
	pointer_move(&ui, p + {20, 0})
	drop_at := after3(&ui, chips)
	pointer_move(&ui, drop_at)
	testing.expect_value(t, order(&ui, chips), [3]int{2, 3, 1})
	frame(&ui.tree, {500, 300})
	over_source := mid(&ui, chips[0]) // the faded chip now sits under the pointer: releasing there is the drop, not a cancel
	pointer_move(&ui, over_source)
	testing.expect_value(t, ui.drag.target, NODE_NONE)
	pointer_button(&ui, .Left, false, over_source)
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0].position, Drop_Position.After)
	testing.expect_value(t, order(&ui, chips), [3]int{2, 3, 1})
	testing.expect_value(t, ui.tree.drag_source, NODE_NONE)
	dnd_view(&ui) // this view keeps the old order: the reconciler puts it back
	testing.expect_value(t, order(&ui, chips), [3]int{1, 2, 3})
}

// The view rebuilding (a clock's tick) while the pointer is over
// no target, the faded source itself, keeps the previewed slot, and a release
// there drops into it rather than cancelling.
@(test)
drag_reorder_preview_survives_a_rebuild_over_no_target :: proc(t: ^testing.T) {
	ui: Ui(Dd_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	chips, _, _ := dnd_view(&ui)
	order :: proc(ui: ^Ui(Dd_Msg), chips: [3]Node) -> [3]int {
		out: [3]int
		p := node_get(&ui.tree, chips[0]).parent
		i := 0
		for c := node_first(&ui.tree, p); c != NODE_NONE && i < 3; c = node_next(&ui.tree, c) {
			for ch, k in chips do if ch == c do out[i] = k + 1
			i += 1
		}
		return out
	}
	p := mid(&ui, chips[0])
	pointer_button(&ui, .Left, true, p)
	pointer_move(&ui, p + {20, 0})
	frame(&ui.tree, {500, 300})
	r3 := node_get(&ui.tree, chips[2]).abs
	pointer_move(&ui, {r3.x + r3.w * 0.8, r3.y + r3.h / 2})
	testing.expect_value(t, order(&ui, chips), [3]int{2, 3, 1})
	frame(&ui.tree, {500, 300})
	over_source := mid(&ui, chips[0])
	pointer_move(&ui, over_source)
	testing.expect_value(t, ui.drag.target, NODE_NONE) // over the faded source: no target

	dnd_view(&ui) // a message rebuilds the view
	testing.expect(t, ui.drag.previewing, "the previewed slot survives the rebuild")
	testing.expect_value(t, order(&ui, chips), [3]int{2, 3, 1})
	testing.expect_value(t, ui.drag.target, NODE_NONE) // still over no target
	dnd_view(&ui) // and another
	testing.expect_value(t, order(&ui, chips), [3]int{2, 3, 1})

	frame(&ui.tree, {500, 300})
	clear(&ui.msgs)
	pointer_button(&ui, .Left, false, over_source)
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0].kind == .Drop && ui.msgs[0].position == .After, "the release drops into the slot, not a cancel")
	testing.expect_value(t, order(&ui, chips), [3]int{2, 3, 1})
}

} // when ODIN_TEST