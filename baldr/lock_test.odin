package baldr

@(require) import "core:fmt"
@(require) import "core:strings"
@(require) import "core:testing"
@(require) import "baldr:platform"

// Behind this `when` so a program importing Baldr does not type-check the
// test suite too, which costs gigabytes. ODIN_TEST is set by `odin test`;
// BALDR_TESTS lets ./build.sh check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Locking the session. The protocol is the backend's; here is the runtime's
// side: what the app hears, what opens while the session is locked, and that
// nothing but unlock_session ever asks the backend to unlock.


@(private = "file")
Lk_Msg :: enum u8 { None, Locked, Finished, Shown, Screens }

@(private = "file")
Lk_State :: struct {
	locking: bool,     // the lock surfaces are declared
	screens: []string, // …one for each of these
	window:  bool,     // a window (tag 1) is declared
	toast:   bool,     // a toast layer (tag 2) is declared
	bar:     string,   // a bar (tag 3) for this screen is declared, when not ""
}

// Lk_Log is the fake backend: its screens, and what it was asked.
@(private = "file")
Lk_Log :: struct {
	screens: [dynamic]platform.Output,
	lock_ok: bool,
	locks:   int,
	unlocks: int,
	calls:   [dynamic]string, // "create Lock DP-1", "destroy 5", in order
}

@(private = "file")
lk_backend :: proc(log: ^Lk_Log, caps: platform.Caps = {.Session_Lock, .Layer_Shell}) -> platform.Backend {
	b := platform.Backend{data = log, caps = caps}
	b.outputs = proc(b: ^platform.Backend) -> []platform.Output { return (^Lk_Log)(b.data).screens[:] }
	b.session_lock = proc(b: ^platform.Backend) -> bool {
		lg := (^Lk_Log)(b.data)
		lg.locks += 1
		return lg.lock_ok
	}
	b.session_unlock = proc(b: ^platform.Backend) { (^Lk_Log)(b.data).unlocks += 1 }
	// what the runtime asks to open is noted and refused, so nothing needs a GPU
	b.surface_create = proc(b: ^platform.Backend, d: platform.Surface_Desc) -> (platform.Surface, bool) {
		lg := (^Lk_Log)(b.data)
		append(&lg.calls, fmt.aprintf("create %v %s transparent=%v backdrop=%v", d.kind, d.output if d.kind == .Lock else d.layer.output, d.transparent, d.backdrop))
		return 0, false
	}
	b.surface_destroy = proc(b: ^platform.Backend, s: platform.Surface) {
		append(&(^Lk_Log)(b.data).calls, fmt.aprintf("destroy %d", s))
	}
	return b
}

@(private = "file")
lk_surfaces :: proc(s: ^Lk_State, out: ^[dynamic]Surface_Desc(Lk_Msg)) {
	if s.window do append(out, Surface_Desc(Lk_Msg){tag = 1, kind = .Window})
	if s.toast do append(out, Surface_Desc(Lk_Msg){tag = 2, kind = .Layer})
	if s.bar != "" do append(out, Surface_Desc(Lk_Msg){tag = 3, kind = .Layer, layer = {output = s.bar}})
	if s.locking do for name, i in s.screens {
		append(out, Surface_Desc(Lk_Msg){tag = 100 + u64(i), kind = .Lock, output = name, transparent = true, backdrop = .Blur})
	}
}

// lk_open puts a surface in the runtime as if it had opened.
@(private = "file")
lk_open :: proc(rt: ^Runtime(Lk_State, Lk_Msg), tag: u64, kind: Surface_Kind, surf: platform.Surface, output := "") {
	c := new(Surface_Ctx(Lk_Msg))
	ui_init(&c.ui)
	c.kind = kind
	c.surf = surf
	c.desc = {tag = tag, kind = kind}
	c.desc.output = strings.clone(output)
	append(&rt.ctxs, c)
}

@(private = "file")
lk_done :: proc(rt: ^Runtime(Lk_State, Lk_Msg), log: ^Lk_Log) {
	for len(rt.ctxs) > 0 do surface_close(rt, len(rt.ctxs) - 1)
	delete(rt.ctxs)
	delete(rt.frames)
	delete(rt.wanted)
	delete(rt.msgs)
	for c in log.calls do delete(c)
	delete(log.calls)
	delete(log.screens)
	outputs_take(nil)
	delete(known_outputs)
	known_outputs = nil
}

@(private = "file")
lk_calls :: proc(log: ^Lk_Log) -> string {
	return strings.join(log.calls[:], "; ", context.temp_allocator)
}

@(test)
the_lock_tells_the_app_and_only_unlock_session_unlocks :: proc(t: ^testing.T) {
	log := Lk_Log{lock_ok = true}
	b := lk_backend(&log)
	rt: Runtime(Lk_State, Lk_Msg)
	rt.backend = &b
	defer lk_done(&rt, &log)

	run_cmd(&rt, lock_session(Lk_Msg, Lk_Msg.Locked, Lk_Msg.Finished, on_shown = Lk_Msg.Shown))
	testing.expect_value(t, log.locks, 1)
	testing.expect_value(t, rt.lock.phase, Lock_Phase.Asked)
	run_cmd(&rt, lock_session(Lk_Msg, Lk_Msg.Locked, Lk_Msg.Finished))
	testing.expect(t, log.locks == 1 && len(rt.msgs) == 0, "a second lock while one is live is ignored, and says nothing that reads as the first ending")

	lock_event(&rt, .Shown)
	testing.expect_value(t, len(rt.msgs), 0) // nothing is shown of a lock that has not locked
	lock_event(&rt, .Locked)
	lock_event(&rt, .Shown)
	testing.expect(t, len(rt.msgs) == 2 && rt.msgs[0] == .Locked && rt.msgs[1] == .Shown, "locked, then the lock screen is up")
	clear(&rt.msgs)

	// what must never unlock: the lock surfaces going, the desktop's finished, quitting
	lk_open(&rt, 100, .Lock, 5, "DP-1")
	rt.app.surfaces = proc(s: ^Lk_State, out: ^[dynamic]Surface_Desc(Lk_Msg)) {} // the app dropped them
	sync_surfaces(&rt)
	testing.expect(t, len(rt.ctxs) == 0 && lk_calls(&log) == "destroy 5", "the lock surface closes")
	lock_event(&rt, .Finished)
	testing.expect(t, rt.lock.phase == .Ended && len(rt.msgs) == 1 && rt.msgs[0] == .Finished, "the app hears the desktop ended it")
	testing.expect(t, lock_live(&rt), "and it is still the app's to let go")
	lock_event(&rt, .Finished)
	testing.expect_value(t, len(rt.msgs), 1) // heard once
	testing.expect(t, !run_cmd(&rt, quit(Lk_Msg)), "quit ends the run…")
	testing.expect_value(t, log.unlocks, 0) // …and none of it unlocked

	run_cmd(&rt, unlock_session(Lk_Msg))
	testing.expect(t, log.unlocks == 1 && rt.lock.phase == .None, "unlock_session does")
	run_cmd(&rt, unlock_session(Lk_Msg))
	testing.expect_value(t, log.unlocks, 1) // no lock, nothing to do
}

@(test)
a_lock_that_cannot_be_had_says_finished :: proc(t: ^testing.T) {
	log: Lk_Log
	b := lk_backend(&log, caps = {})
	rt: Runtime(Lk_State, Lk_Msg)
	rt.backend = &b
	defer lk_done(&rt, &log)

	run_cmd(&rt, lock_session(Lk_Msg, Lk_Msg.Locked, Lk_Msg.Finished))
	testing.expect(t, log.locks == 0 && len(rt.msgs) == 1 && rt.msgs[0] == .Finished && !lock_live(&rt), "no lock protocol: finished at once")
	clear(&rt.msgs)

	b.caps = {.Session_Lock} // the backend can ask, and fails to
	run_cmd(&rt, lock_session(Lk_Msg, Lk_Msg.Locked, Lk_Msg.Finished))
	testing.expect(t, log.locks == 1 && len(rt.msgs) == 1 && rt.msgs[0] == .Finished && !lock_live(&rt), "the ask failed: finished at once")
	clear(&rt.msgs)

	// the desktop refuses (another lock is live): the lock surfaces made meanwhile close
	log.lock_ok = true
	run_cmd(&rt, lock_session(Lk_Msg, Lk_Msg.Locked, Lk_Msg.Finished))
	lk_open(&rt, 1, .Window, 4)
	lk_open(&rt, 100, .Lock, 5, "DP-1")
	lock_event(&rt, .Finished)
	testing.expect(t, len(rt.msgs) == 1 && rt.msgs[0] == .Finished && !lock_live(&rt), "refused: finished")
	testing.expect(t, len(rt.ctxs) == 1 && rt.ctxs[0].kind == .Window && lk_calls(&log) == "destroy 5", "its lock surface closed, the window stays")
	testing.expect_value(t, log.unlocks, 0) // the backend let the refused lock go itself; nothing unlocks

	// withdrawn before the desktop answered: the backend is told, and a late answer is not the app's news
	clear(&rt.msgs)
	run_cmd(&rt, lock_session(Lk_Msg, Lk_Msg.Locked, Lk_Msg.Finished))
	run_cmd(&rt, unlock_session(Lk_Msg))
	testing.expect(t, log.unlocks == 1 && !lock_live(&rt), "withdrawn")
	lock_event(&rt, .Locked)
	lock_event(&rt, .Finished)
	testing.expect_value(t, len(rt.msgs), 0)
}

@(test)
while_locked_only_lock_surfaces_open :: proc(t: ^testing.T) {
	log := Lk_Log{lock_ok = true}
	append(&log.screens, platform.Output{name = "DP-1", size = {2560, 1440}, mode_px = {2560, 1440}, scale = 1})
	append(&log.screens, platform.Output{name = "DP-2", size = {1920, 1080}, mode_px = {1920, 1080}, scale = 1})
	b := lk_backend(&log)
	rt: Runtime(Lk_State, Lk_Msg)
	rt.backend = &b
	rt.app.surfaces = lk_surfaces
	defer lk_done(&rt, &log)
	outputs_take(&b)

	rt.state = {locking = true, screens = {"DP-1", "DP-2"}}
	testing.expect(t, sync_surfaces(&rt), "lock surfaces declared before the lock wait for it…")
	testing.expect_value(t, lk_calls(&log), "") // …and nothing opens

	run_cmd(&rt, lock_session(Lk_Msg, Lk_Msg.Locked, Lk_Msg.Finished))
	lk_open(&rt, 1, .Window, 4) // open before the lock
	rt.state.window, rt.state.toast = true, true
	rt.state.screens = {"DP-1", "DP-1", "", "HDMI-A-1", "DP-2"}
	sync_surfaces(&rt)
	testing.expect_value(t, lk_calls(&log), "create Lock DP-1 transparent=false backdrop=None; create Lock DP-2 transparent=false backdrop=None")
	testing.expect(t, len(rt.ctxs) == 1 && rt.ctxs[0].desc.tag == 1, "the window open before the lock stays open")
	// DP-1 twice: the second ignored; no screen named, or one not there: waits; the toast waits for the unlock

	// a lock surface declared for another screen closes before it opens there: never two on one screen
	for c in log.calls do delete(c)
	clear(&log.calls)
	lk_open(&rt, 100, .Lock, 5, "DP-2")
	lk_open(&rt, 101, .Lock, 6, "DP-1")
	rt.state.window, rt.state.toast = true, false
	rt.state.screens = {"DP-1", "DP-2"} // 100 now covers DP-1, 101 DP-2
	sync_surfaces(&rt)
	testing.expect_value(t, lk_calls(&log), "destroy 6; destroy 5; create Lock DP-1 transparent=false backdrop=None; create Lock DP-2 transparent=false backdrop=None")

	// unlocked: the lock surfaces close with it, and what waited opens
	for c in log.calls do delete(c)
	clear(&log.calls)
	lk_open(&rt, 100, .Lock, 7, "DP-1")
	run_cmd(&rt, unlock_session(Lk_Msg))
	testing.expect_value(t, lk_calls(&log), "destroy 7")
	rt.state = {window = true, toast = true}
	sync_surfaces(&rt)
	testing.expect_value(t, lk_calls(&log), "destroy 7; create Layer  transparent=false backdrop=None")
}

@(test)
a_lock_surface_is_only_ever_one :: proc(t: ^testing.T) {
	d := Surface_Desc(Lk_Msg){kind = .Lock, output = "DP-1", title = "Locked", transparent = true, backdrop = .Blur, size = {800, 600}}
	for caps in ([]platform.Caps{{.Transparent, .Backdrop_Blur, .Session_Lock}, {}}) {
		p := surface_resolve(d, caps, "baldr.locker")
		testing.expect(t, p.kind == .Lock && p.output == "DP-1", "a lock surface, on its screen, whatever the desktop can do: never a window standing in")
		testing.expect(t, !p.transparent && p.backdrop == .None && p.size == {}, "opaque, no glass (behind it is the session it hides), the screen's size")
	}
	outs := []Output{{name = "DP-1"}}
	testing.expect(t, surface_output_present(d, outs))
	d.output = "DP-3"
	testing.expect(t, !surface_output_present(d, outs), "its screen went: it closes")
	d.output = ""
	testing.expect(t, !surface_output_present(d, outs), "no screen named: it never opens")
}

// A change of screens is heard through outputs_changed, and opens a bar
// that was waiting for its screen.
@(test)
a_change_of_screens_is_heard_and_opens_what_waited :: proc(t: ^testing.T) {
	log: Lk_Log
	append(&log.screens, platform.Output{name = "DP-1", size = {2560, 1440}, mode_px = {2560, 1440}, scale = 1})
	b := lk_backend(&log)
	rt: Runtime(Lk_State, Lk_Msg)
	rt.backend = &b
	rt.app.surfaces = lk_surfaces
	defer lk_done(&rt, &log)
	defer sched_destroy(&rt.sched, nil, nil)
	sched_sync(&rt.sched, []Sub(Lk_Msg){outputs_changed(Lk_Msg, Lk_Msg.Screens)}, 0, nil, nil, nil)
	outputs_take(&b)

	rt.state.bar = "HDMI-A-1"
	testing.expect(t, sync_surfaces(&rt), "the bar waits for its screen")
	testing.expect_value(t, lk_calls(&log), "")

	append(&log.screens, platform.Output{name = "HDMI-A-1", size = {1920, 1080}, mode_px = {1920, 1080}, scale = 1})
	outputs_event(&rt) // (the fake refuses to open the bar, so the run would end: what counts is that it was asked)
	testing.expect(t, len(rt.msgs) == 1 && rt.msgs[0] == .Screens, "outputs_changed is heard")
	testing.expect_value(t, lk_calls(&log), "create Layer HDMI-A-1 transparent=false backdrop=None")
}

} // when ODIN_TEST