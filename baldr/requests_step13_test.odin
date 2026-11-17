package baldr

@(require) import "core:os"
@(require) import "core:strings"
@(require) import "core:testing"
@(require) import "baldr:platform"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them. ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh
// check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Which screens exist, and when they change.


@(private = "file")
OMsg :: enum { None, Screens, Closed }

@(private = "file")
fake_outputs :: proc(b: ^platform.Backend) -> []platform.Output {
	return (^[dynamic]platform.Output)(b.data)[:]
}

@(test)
outputs_are_read_and_announced :: proc(t: ^testing.T) {
	screens: [dynamic]platform.Output
	defer delete(screens)
	append(&screens, platform.Output{name = "DP-1", description = "Dell U2723QE", pos = {0, 0}, size = {2560, 1440}, mode_px = {2560, 1440}, scale = 1})
	backend := platform.Backend{data = &screens, outputs = fake_outputs}
	outputs_take(&backend)
	defer {
		outputs_take(nil)
		delete(known_outputs)
		known_outputs = nil
	}
	testing.expect(t, len(outputs()) == 1 && outputs()[0].name == "DP-1" && outputs()[0].size == {2560, 1440})
	testing.expect(t, raw_data(outputs()[0].name) != raw_data(screens[0].name), "the names are the toolkit's own copies")

	append(&screens, platform.Output{name = "HDMI-A-1", description = "LG TV", pos = {2560, 0}, size = {1920, 1080}, mode_px = {3840, 2160}, scale = 2, transform = .Rotate_90})
	outputs_take(&backend) // Ev_Outputs
	testing.expect(t, len(outputs()) == 2 && outputs()[1].name == "HDMI-A-1" && outputs()[1].scale == 2 && outputs()[1].transform == .Rotate_90)

	s: Sched(OMsg)
	defer sched_destroy(&s, nil, nil)
	sched_sync(&s, []Sub(OMsg){outputs_changed(OMsg, OMsg.Screens)}, 0, nil, nil, nil)
	out: [dynamic]OMsg
	defer delete(out)
	testing.expect(t, sched_outputs_changed(&s, &out) && len(out) == 1 && out[0] == .Screens, "the subscription hears the change")
	sched_sync(&s, []Sub(OMsg){}, 0, nil, nil, nil)
	clear(&out)
	testing.expect(t, !sched_outputs_changed(&s, &out) && len(out) == 0, "and stops with its line")

	bar := Surface_Desc(OMsg){kind = .Layer, layer = {output = "HDMI-A-1"}}
	testing.expect(t, surface_output_present(bar, outputs()), "a bar for a screen that is there opens")
	bar.layer.output = "DP-3"
	testing.expect(t, !surface_output_present(bar, outputs()), "a bar for a screen that is not there waits")
	bar.layer.output = ""
	testing.expect(t, surface_output_present(bar, outputs()), "the compositor's choice can always open")
	testing.expect(t, surface_output_present(Surface_Desc(OMsg){kind = .Window}, outputs()))
}

@(private = "file")
RequestsStep13_RState :: struct {}

@(test)
a_bar_the_compositor_took_away_closes_quietly :: proc(t: ^testing.T) {
	backend := platform.Backend{}
	backend.surface_destroy = proc(b: ^platform.Backend, s: platform.Surface) {}
	rt: Runtime(RequestsStep13_RState, OMsg)
	rt.backend = &backend
	defer delete(rt.ctxs)
	for i in 0 ..< 3 {
		c := new(Surface_Ctx(OMsg))
		ui_init(&c.ui)
		c.surf = platform.Surface(i + 1)
		c.desc.tag = u64(i + 1)
		c.desc.title = strings.clone("bar")
		if i < 2 do c.desc.on_close = OMsg.Closed
		append(&rt.ctxs, c)
	}
	testing.expect(t, !close_event(&rt, {surface = 1, reason = .Compositor}, false), "a bar whose screen went does not end the run")
	testing.expect_value(t, len(rt.ctxs), 2)
	for c in rt.ctxs do testing.expect(t, c.surf != 1 && len(c.ui.msgs) == 0, "it is gone, and no on_close was sent")
	testing.expect(t, !close_event(&rt, {surface = 2, reason = .User}, false))
	testing.expect(t, rt.ctxs[0].surf == 2 && len(rt.ctxs[0].ui.msgs) == 1 && rt.ctxs[0].ui.msgs[0] == .Closed, "the user's close goes to on_close")
	testing.expect(t, close_event(&rt, {surface = 3, reason = .User}, false), "without on_close the user's close ends the run")
	for len(rt.ctxs) > 0 do surface_close(&rt, len(rt.ctxs) - 1)
}

// Which screen is the primary one. The order screens arrive in is no order
// at all to a person: a desktop that took outputs()[0] as "the first screen"
// would put its icons on whichever monitor happened to be plugged in first.
@(test)
the_first_screen_is_the_top_left_one :: proc(t: ^testing.T) {
	screens: [dynamic]platform.Output
	defer delete(screens)
	// arrival order: the right-hand screen came up first
	append(&screens, platform.Output{name = "HDMI-A-1", pos = {1920, 0}, size = {1920, 1080}, mode_px = {1920, 1080}, scale = 1})
	append(&screens, platform.Output{name = "eDP-1", pos = {0, 0}, size = {1920, 1200}, mode_px = {1920, 1200}, scale = 1})
	backend := platform.Backend{data = &screens, outputs = fake_outputs}
	outputs_take(&backend)
	defer {
		outputs_take(nil)
		delete(known_outputs)
		known_outputs = nil
	}
	primary := ""
	for o in outputs() do if o.primary do primary = o.name
	testing.expect_value(t, primary, "eDP-1") // not outputs()[0]
	n := 0
	for o in outputs() do if o.primary do n += 1
	testing.expect_value(t, n, 1) // exactly one, always

	// stacked, not side by side: the top one
	screens[0].pos, screens[1].pos = {0, 0}, {0, 1080}
	outputs_take(&backend)
	primary = ""
	for o in outputs() do if o.primary do primary = o.name
	testing.expect_value(t, primary, "HDMI-A-1")

	// the same corner: the connector name breaks the tie, so the answer is
	// the same on every run
	screens[1].pos = {0, 0}
	outputs_take(&backend)
	primary = ""
	for o in outputs() do if o.primary do primary = o.name
	testing.expect_value(t, primary, "HDMI-A-1")

	// a desktop whose compositor does know says so, and that wins
	os.set_env("BALDR_PRIMARY_OUTPUT", "eDP-1")
	outputs_take(&backend)
	primary = ""
	for o in outputs() do if o.primary do primary = o.name
	testing.expect_value(t, primary, "eDP-1")
	os.set_env("BALDR_PRIMARY_OUTPUT", "DP-9") // a screen that is not here: back to the rule
	outputs_take(&backend)
	primary = ""
	for o in outputs() do if o.primary do primary = o.name
	testing.expect_value(t, primary, "HDMI-A-1")
	os.unset_env("BALDR_PRIMARY_OUTPUT")

	// one screen is its own primary
	clear(&screens)
	append(&screens, platform.Output{name = "DP-3", pos = {0, 0}, size = {2560, 1440}, mode_px = {2560, 1440}, scale = 1})
	outputs_take(&backend)
	testing.expect(t, len(outputs()) == 1 && outputs()[0].primary)
}

} // when ODIN_TEST