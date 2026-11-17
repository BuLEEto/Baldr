package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them. ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh
// check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Trimmed labels that must never draw freed text, and icon view tiles that
// glide.


@(private = "file")
RequestsStep12_ZMsg :: enum { None, Pick }

// dangling_texts counts Draw_Text commands whose string is not the memory
// a live text node holds now (freed text a render would read).
@(private = "file")
dangling_texts :: proc(t: ^Tree) -> (n: int) {
	held := make(map[rawptr]bool, context.temp_allocator)
	for &d in t.nodes {
		if .Alive not_in d.flags do continue
		if tk, ok := d.kind.(Text_Kind); ok {
			if len(tk.display) > 0 do held[raw_data(tk.display)] = true
			if len(tk.str) > 0 do held[raw_data(tk.str)] = true
		}
	}
	for _, l in t.layers do for c in l.cmds {
		if dt, ok := c.(Draw_Text); ok && len(dt.str) > 0 && !(raw_data(dt.str) in held) do n += 1
	}
	return
}

@(private = "file")
sidebar :: proc(ui: ^Ui(RequestsStep12_ZMsg), width: f32, caption: string) {
	set_viewport(&ui.tree, {600, 400})
	begin_view(ui)
	row(ui, flex = 1)
	column(ui, width = width, gap = .xs, padding = .sm)
	tree_view(ui, label = "Places", key = 1)
	tree_item(ui, "Rubbish Bin", RequestsStep12_ZMsg.Pick, icon = .Check, tag = 1)
	tree_item(ui, "Downloads and other things", RequestsStep12_ZMsg.Pick, icon = .Check, tag = 2)
	tree_item(ui, "Browse Network", RequestsStep12_ZMsg.Pick, icon = .Check, tag = 3)
	end(ui)
	text(ui, caption, role = .Caption, muted = true, nowrap = true, ellipsis = .End)
	end(ui)
	column(ui, flex = 1)
	text(ui, "Files")
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
}

// The same sidebar as a file manager builds it: a scroll (its own layer), and a
// label in a row beside a flexible spacer (measured loose, then tight).
@(private = "file")
sidebar_scrolled :: proc(ui: ^Ui(RequestsStep12_ZMsg), width: f32, caption: string) {
	set_viewport(&ui.tree, {600, 400})
	begin_view(ui)
	row(ui, flex = 1)
	column(ui, width = width)
	scroll(ui, flex = 1, padding = .sm, gap = .xs)
	tree_view(ui, label = "Places", key = 1)
	tree_item(ui, "Rubbish Bin", RequestsStep12_ZMsg.Pick, icon = .Check, tag = 1)
	tree_item(ui, "Downloads and other things", RequestsStep12_ZMsg.Pick, icon = .Check, tag = 2)
	tree_item(ui, "Browse Network", RequestsStep12_ZMsg.Pick, icon = .Check, tag = 3)
	end(ui)
	row(ui, gap = .xs)
	text(ui, "Squiggles external drive", nowrap = true, ellipsis = .End)
	spacer(ui)
	end(ui)
	text(ui, caption, role = .Caption, muted = true, nowrap = true, ellipsis = .End)
	end(ui)
	end(ui)
	column(ui, flex = 1)
	text(ui, "Files")
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
}

@(test)
trimmed_labels_in_a_scroll_never_draw_freed_text :: proc(t: ^testing.T) {
	ui: Ui(RequestsStep12_ZMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	captions := []string{"742 GB free of 1.8 TB", "741 GB free of 1.8 TB", "740 GB free of 1.8 TB"}
	for step in 0 ..< 24 {
		w := f32(90 + (step % 6) * 12)
		sidebar_scrolled(&ui, w, captions[step % len(captions)])
		testing.expectf(t, dangling_texts(&ui.tree) == 0, "step %d (width %v): %d draws point at freed text", step, w, dangling_texts(&ui.tree))
		sidebar_scrolled(&ui, w, captions[(step + 1) % len(captions)])
		testing.expectf(t, dangling_texts(&ui.tree) == 0, "step %d relaid at %v: %d draws point at freed text", step, w, dangling_texts(&ui.tree))
	}
}

// Rows that come and go (a drive unmounted, a bookmark removed) while the
// rows above stay where they are, and a caption whose text changes but not
// its size.
@(private = "file")
places :: proc(ui: ^Ui(RequestsStep12_ZMsg), count: int, caption: string) {
	names := []string{"Recent", "Home", "Desktop", "Rubbish Bin", "Documents", "Downloads", "Music"}
	set_viewport(&ui.tree, {600, 400})
	begin_view(ui)
	row(ui, flex = 1)
	column(ui, width = 110)
	scroll(ui, flex = 1, padding = .sm, gap = .xs)
	text(ui, caption, role = .Caption, muted = true, nowrap = true, ellipsis = .End)
	tree_view(ui, label = "Places", key = 1)
	for i in 0 ..< count do tree_item(ui, names[i], RequestsStep12_ZMsg.Pick, icon = .Check, tag = u64(i + 1))
	end(ui)
	end(ui)
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
}

@(test)
rows_that_go_and_captions_that_change_leave_no_freed_text :: proc(t: ^testing.T) {
	ui: Ui(RequestsStep12_ZMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	captions := []string{"742 GB free", "741 GB free", "740 GB free"}
	for step in 0 ..< 12 {
		places(&ui, 7 if step % 2 == 0 else 4, captions[step % len(captions)])
		for _ in 0 ..< 3 { // any exit fades run their course
			ui_tick(&ui, f64(1000 + step * 400))
			places(&ui, 7 if step % 2 == 0 else 4, captions[step % len(captions)])
		}
		testing.expectf(t, dangling_texts(&ui.tree) == 0, "step %d: %d draws point at freed text", step, dangling_texts(&ui.tree))
	}
}

@(test)
trimmed_labels_never_draw_freed_text :: proc(t: ^testing.T) {
	ui: Ui(RequestsStep12_ZMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	captions := []string{"742 GB free of 1.8 TB", "741 GB free of 1.8 TB", "740 GB free of 1.8 TB"}
	for step in 0 ..< 24 {
		w := f32(90 + (step % 6) * 12) // a sidebar dragged narrow and back
		sidebar(&ui, w, captions[step % len(captions)])
		testing.expectf(t, dangling_texts(&ui.tree) == 0, "step %d (width %v): %d draws point at freed text", step, w, dangling_texts(&ui.tree))
		sidebar(&ui, w, captions[(step + 1) % len(captions)]) // same width, the caption changes: a relayout
		testing.expectf(t, dangling_texts(&ui.tree) == 0, "step %d relaid at %v: %d draws point at freed text", step, w, dangling_texts(&ui.tree))
	}
}

@(private = "file")
tiles :: proc(ui: ^Ui(RequestsStep12_ZMsg), sel: ^Selection, width: f32, animate: bool, viewport := [2]f32{800, 600}) -> (view: Node) {
	set_viewport(&ui.tree, viewport)
	begin_view(ui)
	row(ui, flex = 1)
	column(ui, width = width)
	first, last := icon_view(ui, 30, sel, label = "Files", animate = animate, key = 1)
	for i in first ..< last do icon_item(ui, i, .None, "file")
	end(ui)
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, viewport)
	for n in ui.tree.icon_views do view = n
	return
}

@(private = "file")
tile_of :: proc(ui: ^Ui(RequestsStep12_ZMsg), view: Node, index: int) -> Node {
	for n, ref in ui.rows do if ref.table == view && ref.index == index do return n
	return NODE_NONE
}

// A column-count change glides the tiles that change rows from
// where they were; nothing moves without `animate`, or when the window
// itself is resized.
@(test)
icon_view_tiles_glide_when_the_columns_change :: proc(t: ^testing.T) {
	for animate in ([]bool{true, false}) {
		ui: Ui(RequestsStep12_ZMsg)
		ui_init(&ui)
		sel := selection_make(multi = true)
		view := tiles(&ui, &sel, 560, animate)
		tiles(&ui, &sel, 560, animate) // the columns follow the laid-out width
		cols := ui.tree.icon_views[view].cols
		k := cols + 1 // row 1, column 1: moves row when a column goes
		before := node_get(&ui.tree, tile_of(&ui, view, k)).abs
		tiles(&ui, &sel, 440, animate) // a pane made narrower
		tiles(&ui, &sel, 440, animate)
		testing.expect(t, ui.tree.icon_views[view].cols < cols, "fewer columns")
		n := tile_of(&ui, view, k)
		d := node_get(&ui.tree, n)
		if animate {
			want := [2]f32{before.x - d.abs.x, before.y - d.abs.y}
			testing.expectf(t, want != {} && abs(d.move_from.x - want.x) < 0.5 && abs(d.move_from.y - want.y) < 0.5,
				"tile %d glides from where it was (move_from %v, moved %v)", k, d.move_from, want)
		} else {
			testing.expect_value(t, d.move_from, [2]f32{})
		}
		selection_destroy(&sel)
		ui_destroy(&ui)
	}

	// A window resize glides too, the first show does not, and a
	// tile still gliding re-targets from where it is drawn.
	ui: Ui(RequestsStep12_ZMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	now := 1000.0
	ui_tick(&ui, now)
	view := tiles(&ui, &sel, 0, true, {800, 600})
	tiles(&ui, &sel, 0, true, {800, 600})
	for index in 0 ..< 12 {
		if n := tile_of(&ui, view, index); n != NODE_NONE do testing.expectf(t, node_get(&ui.tree, n).move_from == {}, "tile %d glided on the first show", index)
	}
	drawn :: proc(ui: ^Ui(RequestsStep12_ZMsg), n: Node) -> [2]f32 {
		d := node_get(&ui.tree, n)
		k := anim_value(&ui.tree, n, .Move)
		return {d.abs.x + d.move_from.x * k, d.abs.y + d.move_from.y * k}
	}
	was := make(map[int][2]f32, context.temp_allocator)
	for index in 0 ..< 24 do if n := tile_of(&ui, view, index); n != NODE_NONE do was[index] = drawn(&ui, n)
	tiles(&ui, &sel, 0, true, {560, 600}) // the window made narrower
	tiles(&ui, &sel, 0, true, {560, 600}) // the reflow lands here
	glided := 0
	for index, from in was {
		n := tile_of(&ui, view, index)
		if n == NODE_NONE do continue
		d := node_get(&ui.tree, n)
		if d.abs.x == from.x && d.abs.y == from.y do continue
		glided += 1
		testing.expectf(t, abs(d.abs.x + d.move_from.x - from.x) < 0.5 && abs(d.abs.y + d.move_from.y - from.y) < 0.5,
			"tile %d glides from where it was on a window resize (drawn at %v, now at %v, move_from %v)", index, from, d.abs, d.move_from)
	}
	testing.expect(t, glided > 0, "a window resize moved tiles, and they glide")

	now += f64(ui.tree.theme.motion.base) / 2 // halfway through the glide
	ui_tick(&ui, now)
	clear(&was)
	for index in 0 ..< 24 do if n := tile_of(&ui, view, index); n != NODE_NONE do was[index] = drawn(&ui, n)
	tiles(&ui, &sel, 0, true, {400, 600}) // narrower again, mid-glide
	tiles(&ui, &sel, 0, true, {400, 600})
	retargeted := 0
	for index, from in was {
		n := tile_of(&ui, view, index)
		if n == NODE_NONE do continue
		d := node_get(&ui.tree, n)
		if d.move_from == {} do continue
		retargeted += 1
		k := anim_value(&ui.tree, n, .Move)
		testing.expectf(t, abs(d.abs.x + d.move_from.x * k - from.x) < 0.5 && abs(d.abs.y + d.move_from.y * k - from.y) < 0.5,
			"tile %d re-targets from where it was drawn (%v), not from where its glide began", index, from)
	}
	testing.expect(t, retargeted > 0, "tiles still gliding took the new move")

	// a live drag: every build has a new window size, so each reflow lands in
	// a layout that is itself a window resize
	now += f64(ui.tree.theme.motion.base) * 10 // earlier glides are over
	ui_tick(&ui, now)
	for w in ([]f32{380, 340, 300, 260, 220, 180}) do tiles(&ui, &sel, 0, true, {w, 600})
	moving := 0
	for index in 0 ..< 24 do if n := tile_of(&ui, view, index); n != NODE_NONE && node_get(&ui.tree, n).move_from != {} do moving += 1
	testing.expect(t, moving > 0, "tiles glide during a live resize, whose every layout is a window resize")
}

// Layout can trim a label again (a row's first pass, then its shrink pass,
// in another frame) without its box moving, and the shortened text it frees
// is what the layer's cached Draw_Text points at. So every time layout
// replaces a label's shortened text, the label and its layer must be
// repainted before the frame renders.
@(test)
a_retrimmed_label_is_repainted :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init: embedded fonts failed to load")
	defer text_engine_destroy(&te)
	for engine in ([]bool{false, true}) {
		ui: Ui(RequestsStep12_ZMsg)
		ui_init(&ui)
		if engine do tree_use_text_engine(&ui.tree, &te)
		set_viewport(&ui.tree, {400, 200})
		begin_view(&ui)
		column(&ui, padding = .sm)
		n := text(&ui, "Downloads and other things", nowrap = true, ellipsis = .End)
		end(&ui)
		end_view(&ui)
		frame(&ui.tree, {400, 200})
		replaced := 0
		for w in ([]f32{120, 60, 90, 60}) {
			d := node_get(&ui.tree, n)
			d.flags -= {.Dirty_Paint} // as after a paint
			root := node_get(&ui.tree, ui.tree.root)
			root.flags -= {.Layer_Dirty}
			before := raw_data(d.kind.(Text_Kind).display)
			layout_node(&ui.tree, n, Constraints{max = {w, 100}}) // one layout pass reaching the label with other room
			d = node_get(&ui.tree, n)
			if raw_data(d.kind.(Text_Kind).display) == before do continue
			replaced += 1
			testing.expectf(t, .Dirty_Paint in d.flags && .Layer_Dirty in node_get(&ui.tree, ui.tree.root).flags,
				"engine %v, width %v: the shortened text was replaced but nothing will repaint the label", engine, w)
		}
		testing.expectf(t, replaced >= 1, "engine %v: the trim changed at least once (%d times)", engine, replaced) // the headless measurer steps less finely
		ui_destroy(&ui)
	}
}

} // when ODIN_TEST