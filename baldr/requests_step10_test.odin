package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them. ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh
// check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// `update` learns which window a message came from.


@(private = "file")
RequestsStep10_WMsg :: enum { None, Back, Job_Done }

@(private = "file")
RequestsStep10_Seen :: struct { msg: RequestsStep10_WMsg, tag: u64, ok: bool }

@(private = "file")
WState :: struct { seen: [dynamic]RequestsStep10_Seen }

@(private = "file")
window :: proc(ui: ^Ui(RequestsStep10_WMsg)) -> (back: Node) {
	set_viewport(&ui.tree, {300, 200})
	begin_view(ui)
	column(ui, padding = .md)
	shortcut(ui, "Alt+Left", RequestsStep10_WMsg.Back)
	back = button(ui, "Back", RequestsStep10_WMsg.Back)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {300, 200})
	return
}

@(test)
update_learns_which_surface_sent_a_message :: proc(t: ^testing.T) {
	rt: Runtime(WState, RequestsStep10_WMsg)
	defer delete(rt.state.seen)
	defer delete(rt.msgs)
	defer delete(rt.ctxs)
	rt.app.update = proc(s: ^WState, m: RequestsStep10_WMsg) -> Cmd(RequestsStep10_WMsg) {
		tag, ok := message_surface()
		append(&s.seen, RequestsStep10_Seen{m, tag, ok})
		return {}
	}
	a, b := new(Surface_Ctx(RequestsStep10_WMsg)), new(Surface_Ctx(RequestsStep10_WMsg))
	defer free(a)
	defer free(b)
	ui_init(&a.ui)
	defer ui_destroy(&a.ui)
	ui_init(&b.ui)
	defer ui_destroy(&b.ui)
	a.desc.tag, b.desc.tag = 7, 8
	append(&rt.ctxs, a, b)
	window(&a.ui)
	back := window(&b.ui)

	append(&rt.msgs, RequestsStep10_WMsg.Job_Done) // a worker's post: the app routes it itself
	bd := node_get(&b.ui.tree, back)
	at := [2]f32{bd.abs.x + bd.abs.w / 2, bd.abs.y + bd.abs.h / 2}
	pointer_button(&b.ui, .Left, true, at) // Back clicked in window 8
	pointer_button(&b.ui, .Left, false, at)
	testing.expect(t, shortcut_fire(&a.ui, .Left, true, {.Alt})) // Alt+Left in window 7

	got, running := dispatch_msgs(&rt)
	testing.expect(t, got && running)
	testing.expect_value(t, len(rt.state.seen), 3)
	if len(rt.state.seen) == 3 {
		testing.expect_value(t, rt.state.seen[0], RequestsStep10_Seen{.Job_Done, 0, false})
		testing.expect_value(t, rt.state.seen[1], RequestsStep10_Seen{.Back, 7, true})
		testing.expect_value(t, rt.state.seen[2], RequestsStep10_Seen{.Back, 8, true})
	}
	_, ok := message_surface()
	testing.expect(t, !ok, "nothing is named outside update")
	testing.expect(t, len(a.ui.msgs) == 0 && len(b.ui.msgs) == 0 && len(rt.msgs) == 0, "the queues are drained")
}

} // when ODIN_TEST