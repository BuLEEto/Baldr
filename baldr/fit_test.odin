package baldr

@(require) import "core:testing"
@(require) import "baldr:platform"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: about 9 GB without this `when`, 1 GB with it.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A layer surface as long as its content.


@(private = "file")
Fit_Log :: struct {
	asked: [dynamic][2]f32,
}

@(private = "file")
fit_backend :: proc(log: ^Fit_Log) -> platform.Backend {
	b := platform.Backend{data = log}
	b.surface_set_layer = proc(b: ^platform.Backend, s: platform.Surface, l: platform.Layer_Desc, size: [2]f32) -> bool {
		append(&(^Fit_Log)(b.data).asked, size)
		return true
	}
	return b
}

@(private = "file")
Fit_Msg :: union { int }

@(private = "file")
Hint_Log :: struct {
	hints: [dynamic][2]u32,
}

// dock_view: a dock's row of `items` 50 px entries and a spacer that gives way.
@(private = "file")
dock_view :: proc(ui: ^Ui(Fit_Msg), items: int) {
	begin_view(ui)
	row(ui, flex = 1, align = .Center, gap = .sm, padding = .xs)
	for i in 0 ..< items do box(ui, width = 50, height = 30, key = u64(i + 1))
	spacer(ui)
	end(ui)
	end_view(ui)
}

// the natural length of dock_view's row: entries, the gaps between them and
// the spacer, and the padding at both ends.
@(private = "file")
dock_length :: proc(t: ^Tree, items: int) -> f32 {
	return f32(items) * 50 + f32(items) * t.theme.space[.sm] + 2 * t.theme.space[.xs]
}

// A dock declared FIT along its edge asks for its content's length, again
// when an entry comes or goes and not otherwise, is capped at its screen's
// length less its margins, and keeps a length the compositor settles on
// without asking again.
@(test)
a_fit_dock_is_as_long_as_its_content :: proc(t: ^testing.T) {
	log: Fit_Log
	defer delete(log.asked)
	b := fit_backend(&log)
	ui: Ui(Fit_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	layer := Layer_Desc{anchor = {.Bottom}, margin = {0, 0, 8, 0}}
	fc := Frame_Ctx{tree = &ui.tree, backend = &b, surface = 3, size = {FIT_START_LEN, 48}, fit = {true, false}, declared = {FIT, 48}, layer = &layer}

	dock_view(&ui, 3)
	testing.expect(t, fit_sync(&fc), "it asks for its content's length; the frame at the start length is skipped")
	testing.expect_value(t, len(log.asked), 1)
	if len(log.asked) == 1 do testing.expect_value(t, log.asked[0], [2]f32{dock_length(&ui.tree, 3), 48})
	fc.size = {dock_length(&ui.tree, 3), 48} // the compositor's configure
	layout(&ui.tree, fc.size)
	testing.expect(t, !fit_sync(&fc), "at its length: nothing to ask, the frame draws")
	dock_view(&ui, 3) // rebuilt, the same content
	testing.expect(t, !fit_sync(&fc), "the same length: not asked again")

	dock_view(&ui, 5) // two windows opened
	layout(&ui.tree, fc.size) // laid out before the frame, as a surface with popups is: no dirty flag is left to see
	testing.expect(t, fit_sync(&fc), "the longer content is seen all the same")
	testing.expect_value(t, log.asked[len(log.asked) - 1], [2]f32{dock_length(&ui.tree, 5), 48})
	fc.size = {dock_length(&ui.tree, 5), 48}
	layout(&ui.tree, fc.size)
	testing.expect(t, !fit_sync(&fc))
	testing.expect_value(t, len(log.asked), 2)

	fc.fit_cap = fit_cap(layer, "DP-2", {{name = "DP-1", size = {1920, 1080}}, {name = "DP-2", size = {200, 800}}})
	testing.expect_value(t, fc.fit_cap, [2]f32{200, 792}) // its screen, less the margins on each axis
	fc.fit_size = {}
	testing.expect(t, fit_sync(&fc), "on a narrower screen: capped")
	testing.expect_value(t, log.asked[len(log.asked) - 1], [2]f32{200, 48})
	fc.size = {180, 48} // the compositor settles on less
	layout(&ui.tree, fc.size)
	testing.expect(t, !fit_sync(&fc), "and that is kept")
	testing.expect_value(t, len(log.asked), 3)
	testing.expect_value(t, layer_size(&fc), [2]f32{200, 48})
}

// A FIT layer surface opens at a start length until its content is measured;
// without layer shell it is a window of the usual size. A screen not known
// yet caps it at the largest one.
@(test)
fit_surfaces_open_at_a_start_length :: proc(t: ^testing.T) {
	d := Surface_Desc(Fit_Msg){kind = .Layer, size = {FIT, 48}, layer = {anchor = {.Bottom}}}
	testing.expect_value(t, surface_resolve(d, {.Layer_Shell}, "test").size, [2]f32{FIT_START_LEN, 48})
	testing.expect_value(t, surface_resolve(d, {}, "test").size, [2]f32{800, 48})
	screens := []Output{{name = "DP-1", size = {1920, 1080}}, {name = "DP-2", size = {2560, 1440}}}
	testing.expect_value(t, fit_cap(d.layer, "HDMI-1", screens), [2]f32{2560, 1440})
	testing.expect_value(t, fit_cap(d.layer, "", {}), [2]f32{})
	fc := Frame_Ctx{fit = {true, false}, declared = {FIT, 48}}
	testing.expect_value(t, layer_size(&fc), [2]f32{FIT_START_LEN, 48})
}

// An applet's size hint follows its content the same way, when the change
// was laid out before the frame.
@(test)
an_applets_hint_follows_content_laid_out_before_the_frame :: proc(t: ^testing.T) {
	log: Hint_Log
	defer delete(log.hints)
	b := platform.Backend{data = &log}
	b.surface_set_size_hint = proc(b: ^platform.Backend, s: platform.Surface, least, preferred: u32) {
		append(&(^Hint_Log)(b.data).hints, [2]u32{least, preferred})
	}
	ui: Ui(Fit_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	fc := Frame_Ctx{tree = &ui.tree, backend = &b, surface = 5, size = {120, 32}, applet = true, edge = .Bottom}
	dock_view(&ui, 2)
	applet_hints(&fc)
	testing.expect_value(t, len(log.hints), 1)
	layout(&ui.tree, fc.size) // the frame's own layout: nothing new
	applet_hints(&fc)
	testing.expect_value(t, len(log.hints), 1)
	dock_view(&ui, 4)
	layout(&ui.tree, fc.size) // laid out before the frame
	applet_hints(&fc)
	testing.expect_value(t, len(log.hints), 2)
	if len(log.hints) == 2 do testing.expect_value(t, log.hints[1].y, u32(dock_length(&ui.tree, 4)))
}

} // when ODIN_TEST