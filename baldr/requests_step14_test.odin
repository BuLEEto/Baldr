package baldr

@(require) import "core:strings"
@(require) import "core:testing"
@(require) import "baldr:platform"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them. ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh
// check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Changing a layer surface without reopening it.


@(private = "file")
RequestsStep14_LMsg :: enum { None }

@(private = "file")
LState :: struct {}

@(private = "file")
Layer_Log :: struct {
	set_calls: int,
	layer:     platform.Layer_Desc,
	size:      [2]f32,
	created:   int,
	destroyed: [dynamic]platform.Surface,
}

@(test)
what_changed_on_a_layer_surface :: proc(t: ^testing.T) {
	bar := Surface_Desc(RequestsStep14_LMsg){kind = .Layer, size = {0, 44}, layer = {anchor = {.Top, .Left, .Right}, exclusive_zone = 44, output = "DP-1"}}
	taller := bar
	taller.size = {0, 48}
	testing.expect_value(t, surface_changes(bar, taller), Surface_Changes{.Size})
	left := bar
	left.layer.anchor = {.Left, .Top, .Bottom}
	left.size = {44, 0}
	testing.expect_value(t, surface_changes(bar, left), Surface_Changes{.Layer, .Size})
	moved := bar
	moved.layer.output = "DP-2"
	testing.expect_value(t, surface_changes(bar, moved), Surface_Changes{.Output})
	win := Surface_Desc(RequestsStep14_LMsg){kind = .Window, size = {800, 600}}
	bigger := win
	bigger.size = {900, 600}
	// A window's size is the app's to change, like a layer surface's.
	testing.expect_value(t, surface_changes(win, bigger), Surface_Changes{.Size})
	applet := Surface_Desc(RequestsStep14_LMsg){kind = .Applet, size = {100, 40}}
	wider := applet
	wider.size = {200, 40}
	testing.expect_value(t, surface_changes(applet, wider), Surface_Changes{}) // an applet's size is its bar's
}

@(test)
a_layer_surface_changes_in_place_and_moves_screens_with_its_tree :: proc(t: ^testing.T) {
	log: Layer_Log
	defer delete(log.destroyed)
	backend := platform.Backend{data = &log, caps = {.Layer_Shell, .Transparent}}
	backend.surface_set_layer = proc(b: ^platform.Backend, s: platform.Surface, l: platform.Layer_Desc, size: [2]f32) -> bool {
		lg := (^Layer_Log)(b.data)
		lg.set_calls += 1
		lg.layer, lg.size = l, size
		return true
	}
	backend.surface_create = proc(b: ^platform.Backend, d: platform.Surface_Desc) -> (platform.Surface, bool) {
		lg := (^Layer_Log)(b.data)
		lg.created += 1
		return platform.Surface(100 + lg.created), true
	}
	backend.surface_destroy = proc(b: ^platform.Backend, s: platform.Surface) {
		append(&(^Layer_Log)(b.data).destroyed, s)
	}
	rt: Runtime(LState, RequestsStep14_LMsg)
	rt.backend = &backend
	defer delete(rt.ctxs)
	c := new(Surface_Ctx(RequestsStep14_LMsg))
	ui_init(&c.ui)
	c.surf = 1
	bar := Surface_Desc(RequestsStep14_LMsg){tag = 5, kind = .Layer, size = {0, 44}, layer = {level = .Top, anchor = {.Top, .Left, .Right}, exclusive_zone = 44, output = "DP-1"}}
	c.desc = bar
	c.desc.layer.output = strings.clone("DP-1")
	append(&rt.ctxs, c)
	set_viewport(&c.ui.tree, {1920, 44})
	begin_view(&c.ui)
	clock := button(&c.ui, "Clock", RequestsStep14_LMsg.None)
	end_view(&c.ui)
	frame(&c.ui.tree, {1920, 44})
	set_focus(&c.ui.tree, clock, true)

	taller := bar
	taller.size = {0, 48}
	taller.layer.exclusive_zone = 48
	taller.layer.keyboard = .On_Demand
	surface_update(&rt, c, taller)
	testing.expect(t, log.set_calls == 1 && log.size == {0, 48} && log.layer.exclusive_zone == 48 && log.layer.keyboard == .On_Demand && log.layer.output == "DP-1",
		"the size, zone and keyboard reach the surface in place")
	testing.expect(t, c.surf == 1 && log.created == 0, "not reopened")
	testing.expect(t, c.desc.size == {0, 48} && c.desc.layer.exclusive_zone == 48)

	moved := taller
	moved.layer.output = "DP-2"
	surface_update(&rt, c, moved)
	testing.expect(t, log.created == 1 && c.surf == 101 && len(log.destroyed) == 1 && log.destroyed[0] == 1, "a new layer surface on the other screen, the old one gone")
	testing.expect_value(t, c.desc.layer.output, "DP-2")
	testing.expect(t, node_valid(&c.ui.tree, clock) && c.ui.tree.focus == clock, "the same tree: its nodes and focus stay")
	testing.expect_value(t, log.set_calls, 1)
	surface_close(&rt, 0)
}

} // when ODIN_TEST