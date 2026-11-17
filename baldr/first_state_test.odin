package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: about 9 GB without this `when`, 1 GB with it.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A control shows its state on its first frame, and a page that leaves
// slides out whole.


@(private = "file")
First_Msg :: union { int }

// A control shown for the first time draws its state at once: a switch built
// on has its knob at on, a segmented control its pill at the picked segment.
// Later changes still animate.
@(test)
controls_show_their_state_at_once :: proc(t: ^testing.T) {
	ui: Ui(First_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.motion.reduce = false
	build :: proc(ui: ^Ui(First_Msg), on: bool) -> (sw, seg: Node) {
		begin_view(ui)
		column(ui, padding = .lg, gap = .sm, align = .Start)
		sw = toggle(ui, on, "Wi-Fi", First_Msg(1))
		seg = segmented(ui, 2, {"Saver", "Balanced", "Performance"}, label = "Power mode")
		end(ui)
		end_view(ui)
		frame(&ui.tree, {400, 200})
		return
	}
	sw, seg := build(&ui, true)
	track := node_get(&ui.tree, sw).first
	testing.expect_value(t, anim_value(&ui.tree, track, .Value), 1) // on, at once
	testing.expect_value(t, anim_value(&ui.tree, seg, .Value), 2)   // the pill at the picked segment
	testing.expect(t, !anim_running(&ui.tree, track, .Value), "nothing moving")

	ui_tick(&ui, 1000)
	build(&ui, false)
	ui_tick(&ui, 1000 + f64(ui.tree.theme.motion.fast) / 2)
	frame(&ui.tree, {400, 200})
	v := anim_value(&ui.tree, track, .Value)
	testing.expectf(t, v > 0.01 && v < 0.99, "turning it off still animates: %v", v)
}

// When pages change, the page leaving is fully shown on its first frame, even
// the page that was there from the start and so never entered by a
// transition, and slides out over the theme's base motion, whole and edge to
// edge with the page sliding in. Under reduce motion it goes at once.
@(test)
the_first_page_leaves_from_fully_shown :: proc(t: ^testing.T) {
	ui: Ui(First_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.motion.reduce = false
	base := f64(ui.tree.theme.motion.base)
	build :: proc(ui: ^Ui(First_Msg), page: u64) -> (container: Node) {
		begin_view(ui)
		column(ui, width = 300)
		pages(ui, page, 0 if page == 0 else 1, label = "Control Centre", key = 7)
		container = ui.scopes[len(ui.scopes) - 2].node
		switch page {
		case 0: box(ui, height = 200, bg = {1, 0, 0, 1}, key = 1)
		case 1:
			box(ui, height = 60, bg = {0, 0, 1, 1}, key = 1)
			scroll(ui, max_height = 100, key = 2) // drawn as a layer of its own
			box(ui, height = 40, bg = {0, 1, 0, 1}, key = 1)
			end(ui)
		}
		end(ui)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {400, 400})
		return
	}
	ui_tick(&ui, 100)
	container := build(&ui, 0)
	ui_tick(&ui, 2000) // the grid at rest
	frame(&ui.tree, {400, 400})
	grid := node_get(&ui.tree, container).first
	build(&ui, 1)
	testing.expect(t, .Exiting in node_get(&ui.tree, grid).flags, "fixture: the grid is leaving")
	red_alpha :: proc(tr: ^Tree) -> (a: f32) {
		for c in draw_list(tr) do if r, ok := c.(Draw_Rect); ok && r.color.r == 1 && r.color.g == 0 do a = max(a, r.color.a)
		return
	}
	testing.expectf(t, red_alpha(&ui.tree) > 0.95, "on its first frame leaving, the grid is still fully shown: %v", red_alpha(&ui.tree))
	ui_tick(&ui, 2000 + base / 2)
	frame(&ui.tree, {400, 400})
	mid := anim_value(&ui.tree, grid, .Enter)
	testing.expectf(t, mid > 0.01 && mid < 0.99, "half-way it is on its way out: %v", mid)
	// the pages slide whole, edge to edge: never a moment with neither page to read
	old_page, new_page, scrolled: Draw_Rect
	for c in draw_list(&ui.tree) do if r, ok := c.(Draw_Rect); ok {
		if r.color.r == 1 && r.color.g == 0 do old_page = r
		if r.color.b == 1 && r.color.g == 0 do new_page = r
		if r.color.g == 1 && r.color.r == 0 do scrolled = r
	}
	testing.expectf(t, old_page.color.a == 1 && new_page.color.a == 1, "both pages drawn whole, not faded: %v and %v", old_page.color.a, new_page.color.a)
	testing.expectf(t, old_page.rect.x < -1 && new_page.rect.x > 1, "the grid out towards the start, the new page in from the end: %v, %v", old_page.rect.x, new_page.rect.x)
	testing.expectf(t, abs(old_page.rect.x + old_page.rect.w - new_page.rect.x) < 0.5, "edge to edge: %v + %v against %v", old_page.rect.x, old_page.rect.w, new_page.rect.x)
	testing.expectf(t, scrolled.color.a == 1 && abs(scrolled.rect.x - new_page.rect.x) < 0.5, "a scroll on the page slides with it: %v against %v", scrolled.rect.x, new_page.rect.x)
	ui_tick(&ui, 2000 + base * 2)
	frame(&ui.tree, {400, 400})
	testing.expect_value(t, anim_value(&ui.tree, grid, .Enter), 0)

	rui: Ui(First_Msg)
	ui_init(&rui)
	defer ui_destroy(&rui)
	rui.tree.theme.motion.reduce = true
	rc := build(&rui, 0)
	rgrid := node_get(&rui.tree, rc).first
	build(&rui, 1)
	testing.expect_value(t, anim_value(&rui.tree, rgrid, .Enter), 0) // reduce motion: gone at once
}

// A node with only an exit transition is shown at once and fades out from
// there when it goes; a node with an entrance plays it from nothing.
@(test)
an_exit_only_node_shows_at_once :: proc(t: ^testing.T) {
	ui: Ui(First_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.motion.reduce = false
	base := f64(ui.tree.theme.motion.base)
	build :: proc(ui: ^Ui(First_Msg), show: bool) -> (leaves, enters: Node) {
		begin_view(ui)
		column(ui, padding = .lg, gap = .sm)
		if show {
			leaves = box(ui, width = 40, height = 40, bg = {1, 0, 0, 1}, key = 1)
			transition(ui, leaves, .None, .Fade)
			enters = box(ui, width = 40, height = 40, bg = {0, 0, 1, 1}, key = 2)
			transition(ui, enters, .Fade, .Fade)
		}
		end(ui)
		end_view(ui)
		frame(&ui.tree, {300, 200})
		return
	}
	alpha :: proc(tr: ^Tree, red: bool) -> (a: f32) {
		for c in draw_list(tr) do if r, ok := c.(Draw_Rect); ok && (r.color.r == 1 if red else r.color.b == 1) && r.color.g == 0 do a = max(a, r.color.a)
		return
	}
	ui_tick(&ui, 100)
	leaves, enters := build(&ui, true)
	testing.expectf(t, alpha(&ui.tree, true) > 0.99, "the exit-only node is shown at once: %v", alpha(&ui.tree, true))
	testing.expectf(t, alpha(&ui.tree, false) < 0.05, "the entering node starts from nothing: %v", alpha(&ui.tree, false))
	ui_tick(&ui, 2000)
	frame(&ui.tree, {300, 200})
	build(&ui, false)
	ui_tick(&ui, 2000 + base / 2)
	frame(&ui.tree, {300, 200})
	mid := anim_value(&ui.tree, leaves, .Enter)
	testing.expectf(t, mid > 0.01 && mid < 0.99, "it fades out from fully shown: %v", mid)
	ui_tick(&ui, 2000 + base * 2)
	frame(&ui.tree, {300, 200})
	testing.expect(t, !node_valid(&ui.tree, leaves) && !node_valid(&ui.tree, enters), "both are gone once their fades end")
}

} // when ODIN_TEST