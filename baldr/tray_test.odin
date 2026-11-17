package baldr

@(require) import "core:testing"
@(require) import "baldr:platform"

// A tray item is **declared**, like a surface, and the runtime
// works out what changed. These are the parts that must be right before any
// backend exists: what gets sent and what does not, what an id means, what
// an app hears when there is no tray at all, and what holds the run open.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Tray_T_Msg :: union { Tray_T_Clicked, Tray_T_Chose, Tray_T_Hosted, Tray_T_Gone }

@(private = "file") Tray_T_Clicked :: struct {}
@(private = "file") Tray_T_Chose   :: struct { what: int }
@(private = "file") Tray_T_Hosted  :: struct {}
@(private = "file") Tray_T_Gone    :: struct {}

@(private = "file")
Tray_T_State :: struct {
	paused:  bool,
	line:    string,
	extra:   bool, // a menu item that comes and goes: the structure changed
	drop:    bool, // stop declaring it at all
}

// Tray_T_Spy stands in for a desktop: it counts what it was told and can refuse
// to show anything, which is what a desktop with no tray does.
@(private = "file")
Tray_T_Spy :: struct {
	backend: platform.Backend,
	sets:    int,
	removes: int,
	refuse:  bool,
	last:    platform.Tray_Desc,
}

@(private = "file")
tray_t_spy :: proc(spy: ^Tray_T_Spy) -> ^platform.Backend {
	spy.backend = platform.Backend{
		name = "spy",
		data = spy,
		tray_set = proc(b: ^platform.Backend, t: platform.Tray_Desc) -> bool {
			s := (^Tray_T_Spy)(b.data)
			s.sets += 1
			s.last = t
			return !s.refuse
		},
		tray_remove = proc(b: ^platform.Backend, tag: u64) {
			s := (^Tray_T_Spy)(b.data)
			s.removes += 1
		},
	}
	return &spy.backend
}

@(private = "file")
tray_t_tray :: proc(s: ^Tray_T_State, out: ^[dynamic]Tray_Desc(Tray_T_Msg)) {
	if s.drop do return
	items := make([dynamic]Tray_Item(Tray_T_Msg), context.temp_allocator)
	append(&items, Tray_Item(Tray_T_Msg){label = s.line, disabled = true}) // the status line
	append(&items, Tray_Item(Tray_T_Msg){separator = true})
	append(&items, Tray_Item(Tray_T_Msg){label = "Pause syncing", checked = s.paused, msg = Tray_T_Msg(Tray_T_Chose{1})})
	if s.extra do append(&items, Tray_Item(Tray_T_Msg){label = "Open folder", msg = Tray_T_Msg(Tray_T_Chose{2})})
	append(out, Tray_Desc(Tray_T_Msg){
		tag = 7, icon = .Cloud, tooltip = s.line, menu = items[:],
		on_click = Tray_T_Msg(Tray_T_Clicked{}), on_hosted = Tray_T_Msg(Tray_T_Hosted{}), on_gone = Tray_T_Msg(Tray_T_Gone{}),
	})
}

@(private = "file")
tray_t_rt :: proc(spy: ^Tray_T_Spy) -> Runtime(Tray_T_State, Tray_T_Msg) {
	rt: Runtime(Tray_T_State, Tray_T_Msg)
	rt.app.tray = tray_t_tray
	rt.backend = tray_t_spy(spy)
	rt.state.line = "Up to date"
	return rt
}

// Nothing a desktop can see changed, so nothing is sent again. On Linux a
// menu re-sent is a menu every host re-reads, and the status line changes
// about once a second.
@(test)
a_tray_that_did_not_change_is_not_sent_again :: proc(t: ^testing.T) {
	spy: Tray_T_Spy
	rt := tray_t_rt(&spy)
	defer tray_shutdown(&rt)

	testing.expect(t, tray_sync(&rt), "a tray is declared")
	testing.expect_value(t, spy.sets, 1)
	tray_sync(&rt)
	tray_sync(&rt)
	testing.expectf(t, spy.sets == 1, "three syncs of the same tray sent it %d times", spy.sets)

	rt.state.line = "Syncing 3 files…" // the label changed: the desktop must hear it
	tray_sync(&rt)
	testing.expectf(t, spy.sets == 2, "a changed status line was not sent (%d)", spy.sets)

	rt.state.paused = true // …and so is a checkmark
	tray_sync(&rt)
	testing.expect_value(t, spy.sets, 3)
}

// An id is a position in the menu, depth first from 1, so a menu rebuilt
// with the same shape keeps meaning the same things.
@(test)
a_menu_item_sends_the_app_its_own_message :: proc(t: ^testing.T) {
	spy: Tray_T_Spy
	rt := tray_t_rt(&spy)
	defer tray_shutdown(&rt)
	rt.state.extra = true
	tray_sync(&rt)

	// 1 status line, 2 separator, 3 Pause, 4 Open folder
	testing.expect_value(t, len(spy.last.menu), 4)
	testing.expect_value(t, spy.last.menu[2].id, u32(3))
	testing.expect_value(t, spy.last.menu[3].id, u32(4))

	clear(&rt.msgs)
	tray_event(&rt, platform.Ev_Tray{tag = 7, kind = .Chosen, id = 4})
	testing.expect_value(t, len(rt.msgs), 1)
	if len(rt.msgs) == 1 {
		chose, ok := rt.msgs[0].(Tray_T_Chose)
		testing.expect(t, ok, "it sent the app's own message")
		if ok do testing.expect_value(t, chose.what, 2)
	}

	// the separator carries no message, so choosing it says nothing
	clear(&rt.msgs)
	tray_event(&rt, platform.Ev_Tray{tag = 7, kind = .Chosen, id = 2})
	testing.expect_value(t, len(rt.msgs), 0)

	// and an id past the end is ignored rather than read off the end
	tray_event(&rt, platform.Ev_Tray{tag = 7, kind = .Chosen, id = 99})
	testing.expect_value(t, len(rt.msgs), 0)

	clear(&rt.msgs)
	tray_event(&rt, platform.Ev_Tray{tag = 7, kind = .Clicked})
	testing.expect_value(t, len(rt.msgs), 1)
	if len(rt.msgs) == 1 {
		_, ok := rt.msgs[0].(Tray_T_Clicked)
		testing.expect(t, ok, "the primary click is its own message")
	}
	delete(rt.msgs)
}

// A desktop with no tray is an answer, not a silence: the app hears it on
// the **first** attempt, because one that falls back to its window has to
// know at the start. And it hears when a host turns up later.
@(test)
a_desktop_with_no_tray_says_so_once :: proc(t: ^testing.T) {
	spy: Tray_T_Spy
	spy.refuse = true
	rt := tray_t_rt(&spy)
	defer tray_shutdown(&rt)

	tray_sync(&rt)
	testing.expectf(t, len(rt.msgs) == 1, "it said there is no tray (%d messages)", len(rt.msgs))
	if len(rt.msgs) == 1 {
		_, ok := rt.msgs[0].(Tray_T_Gone)
		testing.expect(t, ok, "…and it said it with on_gone")
	}
	clear(&rt.msgs)
	rt.state.line = "Syncing…"
	tray_sync(&rt)
	tray_sync(&rt)
	testing.expectf(t, len(rt.msgs) == 0, "it said it again %d times", len(rt.msgs))

	// a panel appears
	tray_event(&rt, platform.Ev_Tray{tag = 7, kind = .Hosted})
	testing.expect_value(t, len(rt.msgs), 1)
	if len(rt.msgs) == 1 {
		_, ok := rt.msgs[0].(Tray_T_Hosted)
		testing.expect(t, ok, "…and the app hears that it can stop insisting on its window")
	}
	// …and goes away again
	clear(&rt.msgs)
	tray_event(&rt, platform.Ev_Tray{tag = 7, kind = .Gone})
	testing.expect_value(t, len(rt.msgs), 1)
	tray_event(&rt, platform.Ev_Tray{tag = 7, kind = .Gone}) // not twice
	testing.expect_value(t, len(rt.msgs), 1)
	delete(rt.msgs)
}

// An item the app stops declaring is taken away, and the run ends with it
// if nothing else holds it.
@(test)
a_tray_item_the_app_dropped_is_taken_away :: proc(t: ^testing.T) {
	spy: Tray_T_Spy
	rt := tray_t_rt(&spy)
	defer tray_shutdown(&rt)
	tray_sync(&rt)
	testing.expect(t, run_holds(&rt), "a tray item holds the run open")

	rt.state.drop = true
	testing.expect(t, !tray_sync(&rt), "nothing is declared now")
	testing.expect_value(t, spy.removes, 1)
	testing.expect(t, !run_holds(&rt), "…so nothing holds the run")
	delete(rt.msgs)
}

// A checkbox that is off is not the same as an item with no checkbox: the
// desktops draw them differently and an app that means one must not get the
// other.
@(test)
a_checkbox_that_is_off_is_not_an_item_without_one :: proc(t: ^testing.T) {
	spy: Tray_T_Spy
	rt := tray_t_rt(&spy)
	defer tray_shutdown(&rt)
	tray_sync(&rt)
	line, pause := spy.last.menu[0], spy.last.menu[2]
	_, line_has := line.checked.?
	off, pause_has := pause.checked.?
	testing.expect(t, !line_has, "the status line has no checkbox")
	testing.expect(t, pause_has, "Pause syncing has one")
	testing.expect(t, !off, "…and it is off")
	testing.expect(t, line.disabled, "the status line is disabled, which is what makes it a status line")
	delete(rt.msgs)
}

// The icon is rasterised for every size a desktop might ask for, and it has
// ink in it: a mask of nothing is what an icon name that does not exist
// would give, and it would show as a gap in the panel.
@(test)
the_tray_icon_is_drawn_at_every_size_a_desktop_wants :: proc(t: ^testing.T) {
	spy: Tray_T_Spy
	rt := tray_t_rt(&spy)
	defer tray_shutdown(&rt)
	tray_sync(&rt)
	testing.expect_value(t, len(spy.last.icon), len(TRAY_ICON_SIZES))
	for p, i in spy.last.icon {
		testing.expect_value(t, p.w, TRAY_ICON_SIZES[i])
		testing.expect_value(t, len(p.argb), p.w * p.h)
		ink := 0
		for v in p.argb do if (v >> 24) > 0x20 do ink += 1
		testing.expectf(t, ink > p.w, "the %d px icon has %d inked pixels", p.w, ink)
	}
	delete(rt.msgs)
}

} // when ODIN_TEST
