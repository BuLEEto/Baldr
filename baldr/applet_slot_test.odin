package baldr

@(require) import "core:testing"
@(require) import "baldr:platform"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Applet slots in a bar: the host's side of the rikkiti-applet-v1 protocol.


@(private = "file")
S_Event :: struct {
	ev: Slot_Event,
}

@(private = "file")
AppletSlot_SMsg :: union { S_Event }

@(private = "file")
Slot_Call :: struct {
	slot: platform.Slot,
	host: platform.Surface,
	rect: [4]f32,
	edge: Edge,
}

@(private = "file")
Slot_Log :: struct {
	made:    [dynamic]Slot_Call,
	moved:   [dynamic]Slot_Call,
	removed: [dynamic]platform.Slot,
	asked:   int,
	next:    platform.Slot,
	refuse:  bool,
}

@(private = "file")
slot_log_free :: proc(log: ^Slot_Log) {
	delete(log.made)
	delete(log.moved)
	delete(log.removed)
}

@(private = "file")
slot_backend :: proc(log: ^Slot_Log) -> platform.Backend {
	b := platform.Backend{data = log, caps = {.Applet_Slots}}
	b.slot_create = proc(b: ^platform.Backend, host: platform.Surface, rect: [4]f32, edge: Edge) -> (platform.Slot, bool) {
		lg := (^Slot_Log)(b.data)
		lg.asked += 1
		if lg.refuse do return 0, false
		lg.next += 1
		append(&lg.made, Slot_Call{slot = lg.next, host = host, rect = rect, edge = edge})
		return lg.next, true
	}
	b.slot_set_geometry = proc(b: ^platform.Backend, slot: platform.Slot, rect: [4]f32, edge: Edge) {
		append(&(^Slot_Log)(b.data).moved, Slot_Call{slot = slot, rect = rect, edge = edge})
	}
	b.slot_destroy = proc(b: ^platform.Backend, slot: platform.Slot) {
		append(&(^Slot_Log)(b.data).removed, slot)
	}
	return b
}

@(private = "file")
on_slot :: proc(e: Ev(Slot_Event)) -> AppletSlot_SMsg {
	return S_Event{e.value}
}

@(private = "file")
Bar_Look :: struct {
	weather_len:  f32,
	swap:         bool,
	no_clock:     bool,
	hide_weather: bool,
}

// bar_view: a bottom bar with a launcher label and two applets' slots.
@(private = "file")
bar_view :: proc(ui: ^Ui(AppletSlot_SMsg), look: Bar_Look) -> (clock, weather: Node) {
	begin_view(ui)
	row(ui, flex = 1, align = .Center, gap = .sm, padding = .xs)
	text(ui, "Launcher")
	for i in 0 ..< 2 {
		if (i == 0) != look.swap {
			if !look.no_clock do clock = applet_slot(ui, on_slot, 60, 120, label = "Clock", key = 1)
		} else {
			weather = applet_slot(ui, on_slot, 40, look.weather_len if look.weather_len > 0 else 80, label = "Weather", key = 2)
			set_hidden(&ui.tree, weather, look.hide_weather)
		}
	}
	end(ui)
	end_view(ui)
	return
}

@(private = "file")
bar_frame :: proc(ui: ^Ui(AppletSlot_SMsg), fc: ^Frame_Ctx, look: Bar_Look) -> (clock, weather: Node) {
	clock, weather = bar_view(ui, look)
	layout(&ui.tree, {800, 36})
	slots_sync(fc)
	return
}

@(private = "file")
rect_of :: proc(t: ^Tree, n: Node) -> [4]f32 {
	d := node_get(t, n)
	return {d.abs.x, d.abs.y, d.abs.w, d.abs.h} if d != nil else {}
}

@(private = "file")
made_at :: proc(log: ^Slot_Log, rect: [4]f32) -> bool {
	for m in log.made do if m.rect == rect do return true
	return false
}

// A slot is made where its node is laid out, moved in place when the node
// moves, kept by its key across a reorder, removed when hidden or gone, made
// again when shown, and follows the bar to another edge.
@(test)
applet_slots_follow_the_bars_layout :: proc(t: ^testing.T) {
	log: Slot_Log
	defer slot_log_free(&log)
	b := slot_backend(&log)
	ui: Ui(AppletSlot_SMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.surface.edge = .Bottom
	fc := Frame_Ctx{tree = &ui.tree, backend = &b, surface = 7, host_edge = .Bottom, size = {800, 36}}

	clock, weather := bar_frame(&ui, &fc, {})
	testing.expect_value(t, len(log.made), 2)
	testing.expect(t, made_at(&log, rect_of(&ui.tree, clock)) && made_at(&log, rect_of(&ui.tree, weather)), "each slot where its node is")
	if len(log.made) > 0 do testing.expect(t, log.made[0].host == 7 && log.made[0].edge == .Bottom, "on the bar's own surface and edge")
	cd := node_get(&ui.tree, clock)
	testing.expectf(t, cd.abs.w == 120 && cd.abs.h == 36 - 2 * ui.tree.theme.space[.xs], "preferred along the bar, as thick as the row across: %v", cd.abs)
	testing.expect(t, cd.access.role == .Group && cd.access.name == "Clock", "a named place for assistive technology")

	clear(&log.made)
	_, weather = bar_frame(&ui, &fc, {weather_len = 100})
	testing.expect(t, len(log.made) == 0 && len(log.moved) == 1, "the weather applet's slot grows in place")
	if len(log.moved) == 1 do testing.expect_value(t, log.moved[0].rect, rect_of(&ui.tree, weather))

	clear(&log.moved)
	bar_frame(&ui, &fc, {weather_len = 100, swap = true})
	testing.expect(t, len(log.made) == 0 && len(log.moved) == 2 && len(log.removed) == 0, "reordered: both move, neither applet restarts")

	clear(&log.moved)
	bar_frame(&ui, &fc, {weather_len = 100, swap = true, hide_weather = true})
	testing.expect_value(t, len(log.removed), 1) // hidden: its slot goes

	bar_frame(&ui, &fc, {weather_len = 100, swap = true, no_clock = true})
	testing.expect(t, len(log.removed) == 2 && len(log.made) == 1, "shown again: a new slot; the clock gone: its slot removed")
	testing.expect_value(t, len(ui.tree.slot_places), 1)

	clear(&log.moved)
	fc.host_edge = .Top
	bar_frame(&ui, &fc, {weather_len = 100, swap = true, no_clock = true})
	testing.expect(t, len(log.moved) == 1 && log.moved[0].edge == .Top, "the bar on another edge: the slot follows")
}

// What the compositor says about a slot reaches its node's handler, with
// the node's key.
@(test)
a_slot_reports_to_its_node :: proc(t: ^testing.T) {
	log: Slot_Log
	defer slot_log_free(&log)
	b := slot_backend(&log)
	ui: Ui(AppletSlot_SMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.surface.edge = .Bottom
	fc := Frame_Ctx{tree = &ui.tree, backend = &b, surface = 7, host_edge = .Bottom, size = {800, 36}}
	clock, _ := bar_frame(&ui, &fc, {})
	id := ui.tree.slot_places[clock].slot
	n, found := slot_node_of(&ui.tree, id)
	testing.expect(t, found && n == clock, "the platform slot leads back to its node")

	slot_deliver(&ui, clock, platform.Ev_Slot{slot = id, kind = .Token, token = "tok-1"})
	slot_deliver(&ui, clock, platform.Ev_Slot{slot = id, kind = .Attached, pid = 42})
	slot_deliver(&ui, clock, platform.Ev_Slot{slot = id, kind = .Size_Hint, least = 90, preferred = 150})
	slot_deliver(&ui, clock, platform.Ev_Slot{slot = id, kind = .Detached})
	testing.expect_value(t, len(ui.msgs), 4)
	if len(ui.msgs) != 4 do return
	evs := [4]Slot_Event{}
	for m, i in ui.msgs do evs[i] = m.(S_Event).ev
	testing.expect_value(t, evs[0].(Slot_Token), Slot_Token{key = 1, token = "tok-1"})
	testing.expect_value(t, evs[1].(Slot_Attached), Slot_Attached{key = 1, pid = 42})
	testing.expect_value(t, evs[2].(Slot_Size_Hint), Slot_Size_Hint{key = 1, min = 90, preferred = 150})
	testing.expect_value(t, evs[3].(Slot_Detached), Slot_Detached{key = 1})
}

// Down a side bar a slot runs along its height; a desktop without slots
// lays it out and asks for nothing; a refused slot isn't asked for again.
@(test)
side_bars_and_desktops_without_slots :: proc(t: ^testing.T) {
	ui: Ui(AppletSlot_SMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.surface.edge = .Left
	begin_view(&ui)
	column(&ui, flex = 1, gap = .sm, padding = .xs)
	slot := applet_slot(&ui, on_slot, 40, 90, key = 1)
	end(&ui)
	end_view(&ui)
	layout(&ui.tree, {48, 600})
	sd := node_get(&ui.tree, slot)
	testing.expectf(t, sd.abs.h == 90 && sd.abs.w == 48 - 2 * ui.tree.theme.space[.xs], "along a side bar's height, as wide as it: %v", sd.abs)
	testing.expect_value(t, sd.access.role, Role.None) // no label: nothing to announce

	none := platform.Backend{}
	fc := Frame_Ctx{tree = &ui.tree, backend = &none, surface = 7, host_edge = .Left, size = {48, 600}}
	slots_sync(&fc) // no slots on this desktop: nothing asked, nothing breaks
	testing.expect_value(t, ui.tree.slot_places[slot].slot, platform.Slot(0))

	log := Slot_Log{refuse = true}
	defer slot_log_free(&log)
	b := slot_backend(&log)
	fc.backend = &b
	slots_sync(&fc)
	slots_sync(&fc)
	testing.expect_value(t, log.asked, 1) // refused once: not asked again for this node
}

} // when ODIN_TEST