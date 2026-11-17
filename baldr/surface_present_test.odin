package baldr

@(require) import "core:testing"
@(require) import "baldr:platform"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A surface's corners, picked in its own popover, show on the next frame.


// A rounded glass bar's radius changing marks its next frame to present whole;
// painting it again unchanged doesn't.
@(test)
a_surfaces_new_corners_mark_its_next_frame_whole :: proc(t: ^testing.T) {
	c: Surface_Ctx(int)
	ui_init(&c.ui)
	defer ui_destroy(&c.ui)
	c.desc = Surface_Desc(int){kind = .Layer, transparent = true, backdrop = .Blur, radius = 12, layer = {anchor = {.Bottom, .Left, .Right}}}
	glass_paint(&c, {})
	testing.expect(t, c.fc.shape != {} && c.fc.shape_radius == 12, "fixture: a rounded bar draws its shape")
	c.fc.present_whole = false
	glass_paint(&c, {})
	testing.expect(t, !c.fc.present_whole, "painted again unchanged: nothing to present")
	c.desc.radius = 6
	glass_paint(&c, {})
	testing.expect(t, c.fc.present_whole, "a new radius")
	c.fc.present_whole = false
	c.desc.radius = 0
	glass_paint(&c, {})
	testing.expect(t, c.fc.present_whole, "square: its shape goes")
}

// The only change is in a popup on its own surface, so the bar's frame is
// skipped; with its corners changed it presents whole.
@(test)
a_frame_with_new_corners_presents_whole_though_its_tree_changed_only_in_a_popup :: proc(t: ^testing.T) {
	ui: Ui(int)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	text(&ui, "A bar")
	end_view(&ui)
	frame(&ui.tree, {400, 40})
	take_damage(&ui.tree)
	fc := Frame_Ctx{tree = &ui.tree, size = {400, 40}, size_px = {400, 40}, drawn_px = {400, 40}, scale = 1}
	defer delete(fc.damage)

	ui.tree.damage_elsewhere = true // the segmented control repainted on the popover's surface
	testing.expect(t, !frame_damage(&fc), "nothing changed on it: skipped")
	ui.tree.damage_elsewhere = true
	fc.present_whole = true
	testing.expect(t, frame_damage(&fc) && len(fc.damage) == 0, "its corners changed: all of it presents")
	testing.expect(t, !fc.present_whole, "once")
	ui.tree.damage_elsewhere = true
	testing.expect(t, !frame_damage(&fc), "and the next frame skips again")
	damage_add(&ui.tree, Rect{10, 10, 20, 20})
	testing.expect(t, frame_damage(&fc) && len(fc.damage) == 1, "a change on it: that rect")
}

@(private = "file")
Present_Region_Log :: struct {
	calls: int,
	rects: [dynamic][4]f32,
	all:   bool,
}

// A rounded bar takes the pointer inside its corners only; made square, it
// tells the compositor it takes it everywhere again.
@(test)
a_bar_made_square_takes_the_pointer_in_its_corners_again :: proc(t: ^testing.T) {
	log: Present_Region_Log
	defer delete(log.rects)
	backend := platform.Backend{data = &log}
	backend.surface_set_input_region = proc(b: ^platform.Backend, s: platform.Surface, rects: [][4]f32, all: bool) {
		lg := (^Present_Region_Log)(b.data)
		lg.calls += 1
		clear(&lg.rects)
		append(&lg.rects, ..rects)
		lg.all = all
	}
	ui: Ui(int)
	ui_init(&ui)
	defer ui_destroy(&ui)
	fc := Frame_Ctx{tree = &ui.tree, backend = &backend, surface = 1, size = {400, 40}, input = .All, shape_radius = 12}
	defer delete(fc.input_sent)
	input_region_sync(&fc)
	testing.expect(t, log.calls == 1 && !log.all && len(log.rects) > 1, "rounded: its corners take no pointer")

	fc.shape_radius = 0
	fc.input_sent_ok = false // as a shape change does
	input_region_sync(&fc)
	testing.expect(t, log.calls == 2 && log.all && len(log.rects) == 0, "square: the whole surface again")
}

} // when ODIN_TEST