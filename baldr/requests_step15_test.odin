package baldr

@(require) import "core:testing"
@(require) import "baldr:platform"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them. ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh
// check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Input regions: where a surface takes the pointer.


@(private = "file")
IMsg :: enum { None }

@(private = "file")
Region_Log :: struct {
	calls: int,
	rects: [dynamic][4]f32,
	all:   bool,
}

@(test)
the_input_region_follows_the_marked_nodes :: proc(t: ^testing.T) {
	log: Region_Log
	defer delete(log.rects)
	backend := platform.Backend{data = &log}
	backend.surface_set_input_region = proc(b: ^platform.Backend, s: platform.Surface, rects: [][4]f32, all: bool) {
		lg := (^Region_Log)(b.data)
		lg.calls += 1
		clear(&lg.rects)
		append(&lg.rects, ..rects)
		lg.all = all
	}
	ui: Ui(IMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	shelf, strip: Node
	build :: proc(ui: ^Ui(IMsg), hidden_dock: bool) -> (shelf, strip: Node) {
		set_viewport(&ui.tree, {1920, 120})
		begin_view(ui)
		column(ui, align = .Center, justify = .End, flex = 1)
		shelf = row(ui, width = 600, height = 72, key = 1)
		end(ui)
		set_hidden(&ui.tree, shelf, hidden_dock)
		input_area(ui, shelf)
		strip = box(ui, width = 1920, height = 4, key = 2) // the reveal strip at the screen edge
		input_area(ui, strip)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {1920, 120})
		return
	}
	shelf, strip = build(&ui, false)
	fc := Frame_Ctx{tree = &ui.tree, backend = &backend, surface = 1}
	defer delete(fc.input_sent)

	input_region_sync(&fc)
	testing.expect_value(t, log.calls, 0) // the whole surface: nothing to say

	fc.input = .Marked
	input_region_sync(&fc)
	sd, td := node_get(&ui.tree, shelf), node_get(&ui.tree, strip)
	testing.expect(t, log.calls == 1 && !log.all && len(log.rects) == 2, "the shelf and the strip")
	testing.expect(t, log.rects[0] == {sd.abs.x, sd.abs.y, sd.abs.w, sd.abs.h} && log.rects[1] == {td.abs.x, td.abs.y, td.abs.w, td.abs.h})
	input_region_sync(&fc)
	testing.expect_value(t, log.calls, 1) // unchanged: not sent again

	build(&ui, true) // the dock hides: only its reveal strip takes the pointer
	input_region_sync(&fc)
	testing.expect(t, log.calls == 2 && len(log.rects) == 1 && log.rects[0] == {td.abs.x, td.abs.y, td.abs.w, td.abs.h})

	fc.input = .None
	input_region_sync(&fc)
	testing.expect(t, log.calls == 3 && !log.all && len(log.rects) == 0, "nowhere: an empty region")
	fc.input = .All
	input_region_sync(&fc)
	testing.expect(t, log.calls == 4 && log.all, "everywhere again")

	a := Surface_Desc(IMsg){kind = .Layer}
	b := a
	b.input = .Marked
	testing.expect_value(t, surface_changes(a, b), Surface_Changes{.Input})
	input_area(&ui, shelf, false)
	testing.expect(t, .Input_Area not_in node_get(&ui.tree, shelf).flags)
}

} // when ODIN_TEST