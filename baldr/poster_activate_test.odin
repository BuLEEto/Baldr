package baldr

@(require) import "core:sync"
@(require) import "core:testing"
@(require) import "core:thread"
@(require) import "baldr:platform"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them. ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh
// check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A window that brings itself forward, and a message from a thread Baldr
// did not start.


@(private = "file")
Pa2_Msg :: union { Poster(Pa2_Event), Pa2_Event }
@(private = "file")
Pa2_Event :: struct { n: int }

// A foreign thread (a C library's callback) posts through a Poster the
// run loop gave out, and the loop is woken; once the run has ended the
// same Poster posts nowhere, safely.
@(test)
a_poster_posts_from_any_thread :: proc(t: ^testing.T) {
	rt: Runtime(int, Pa2_Event)
	defer {
		delete(rt.msgs)
		delete(rt.mailbox.mail)
		for p in rt.posters do free((^Poster_Box(Pa2_Event))(p)) // a test may free what the run keeps for good
		delete(rt.posters)
	}
	woke := 0
	rt.mailbox.wake = proc(user: rawptr) { sync.atomic_add((^int)(user), 1) }
	rt.mailbox.wake_user = &woke

	got: Poster(Pa2_Event)
	Holder :: struct { p: ^Poster(Pa2_Event) }
	testing.expect(t, run_cmd(&rt, poster(Pa2_Event, Pa2_Event{n = -1})), "run on")
	testing.expect_value(t, len(rt.posters), 1)
	got = Poster(Pa2_Event){box = (^Poster_Box(Pa2_Event))(rt.posters[0])}

	worker :: proc(p: rawptr) {
		po := (^Poster(Pa2_Event))(p)
		for i in 1 ..= 3 do post_from(po^, Pa2_Event{n = i})
	}
	th := thread.create_and_start_with_data(&got, worker)
	thread.join(th)
	thread.destroy(th)
	clear(&rt.msgs)
	mailbox_drain(&rt.mailbox, nil, &rt.msgs)
	testing.expect_value(t, len(rt.msgs), 3)
	if len(rt.msgs) == 3 do testing.expect(t, rt.msgs[0].n == 1 && rt.msgs[2].n == 3, "in order")
	testing.expect(t, sync.atomic_load(&woke) >= 3, "the loop was woken")

	poster_shut(got.box) // the run ends
	testing.expect(t, !post_from(got, Pa2_Event{n = 9}), "posting after the run goes nowhere")
	testing.expect(t, !post_from(Poster(Pa2_Event){}, Pa2_Event{n = 9}), "nor does a zero Poster")
}

@(private = "file")
Act_Log :: struct {
	calls: [dynamic]struct { surf: platform.Surface, token: string },
}

// `activate` goes to the window whose tag it names, with the token the app
// was handed; one whose window is not open waits until it is.
@(test)
activate_reaches_the_window_it_names :: proc(t: ^testing.T) {
	log: Act_Log
	defer {
		for c in log.calls do delete(c.token)
		delete(log.calls)
	}
	b := platform.Backend{data = &log}
	b.activate = proc(b: ^platform.Backend, s: platform.Surface, token: string) {
		lg := (^Act_Log)(b.data)
		append(&lg.calls, struct { surf: platform.Surface, token: string }{s, dup_str(token)})
	}
	rt: Runtime(int, Pa2_Event)
	rt.backend = &b
	defer {
		for a in rt.activations do delete(a.token)
		delete(rt.activations)
		for c in rt.ctxs do free(c)
		delete(rt.ctxs)
	}
	main_win := new(Surface_Ctx(Pa2_Event))
	main_win.desc.tag, main_win.surf = 1, 7
	append(&rt.ctxs, main_win)

	run_cmd(&rt, activate(Pa2_Event, tag = 1, token = "from-dbus"))
	testing.expect_value(t, len(log.calls), 1)
	if len(log.calls) == 1 do testing.expect(t, log.calls[0].surf == 7 && log.calls[0].token == "from-dbus", "the named window, with the token handed over")

	run_cmd(&rt, activate(Pa2_Event, tag = 2)) // its window is closed (a player playing on)
	testing.expect_value(t, len(log.calls), 1)
	testing.expect_value(t, len(rt.activations), 1)
	player := new(Surface_Ctx(Pa2_Event))
	player.desc.tag, player.surf = 2, 9
	append(&rt.ctxs, player) // opened again
	activations_run(&rt)
	testing.expect_value(t, len(log.calls), 2)
	if len(log.calls) == 2 do testing.expect(t, log.calls[1].surf == 9 && log.calls[1].token == "", "activated once it is open, asking for its own token")
	testing.expect_value(t, len(rt.activations), 0)
}

@(private = "file")
dup_str :: proc(s: string) -> string {
	out := make([]u8, len(s))
	copy(out, s)
	return string(out)
}

} // when ODIN_TEST