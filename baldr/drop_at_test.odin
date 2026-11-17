package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// `Drop.at`: where a clip is let go says two things on a timeline, the time
// it starts at (the x) and the track (the y). The position travels in the
// message, from the target's own top-left; a shared field such as
// `Ui.context_pos` could be overwritten by the next event before `update`
// reads it.

// `Drop.tag` is the *dragged* thing's; the target's arrives as `Ev.tag`, so
// the message keeps both — which is what an app needs to know which track
// took it and where along that track.
@(private = "file")
Landed :: struct { drop: Drop, target: u64 }

@(private = "file")
Dt_Msg :: union { Landed, Drag_Over }

@(private = "file")
Dt_Fx :: struct {
	ui:            Ui(Dt_Msg),
	src, a, b:     Node,
}

@(private = "file")
dt_view :: proc(fx: ^Dt_Fx, over: bool) {
	ui := &fx.ui
	set_viewport(&ui.tree, {400, 300})
	begin_view(ui)
	column(ui, padding = .none, gap = .none)
	fx.src = box(ui, width = 80, height = 40, key = 1)
	draggable(ui, fx.src, "clip", tag = 7)
	fx.a = box(ui, width = 400, height = 60, key = 2) // "track A"
	fx.b = box(ui, width = 400, height = 60, key = 3) // "track B"
	drop_target(ui, fx.a, proc(e: Ev(Drop)) -> Dt_Msg { return Landed{e.value, e.tag} }, accepts = "clip", tag = 1,
		on_over = proc(e: Ev(Drag_Over)) -> Dt_Msg { return e.value } if over else nil)
	drop_target(ui, fx.b, proc(e: Ev(Drop)) -> Dt_Msg { return Landed{e.value, e.tag} }, accepts = "clip", tag = 2,
		on_over = proc(e: Ev(Drag_Over)) -> Dt_Msg { return e.value } if over else nil)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 300})
}

// A drop says where it landed, from the target's own top-left.
@(test)
a_drop_says_where_it_landed :: proc(t: ^testing.T) {
	fx: Dt_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	dt_view(&fx, false)

	db := node_get(&fx.ui.tree, fx.b)
	if db == nil do testing.fail_now(t, "no second track")
	at := [2]f32{db.abs.x + 137, db.abs.y + 22}

	drag_begin(&fx.ui, fx.src, false)
	pointer_move(&fx.ui, at)
	drag_drop(&fx.ui, fx.b, .On, at = at)

	if !testing.expect_value(t, len(fx.ui.msgs), 1) do return
	l, is := fx.ui.msgs[0].(Landed)
	if !testing.expect(t, is, "a Drop came back") do return
	testing.expect_value(t, l.target, 2)       // the track it landed on
	testing.expect_value(t, l.drop.tag, 7)     // …carrying the clip that was dragged
	testing.expect_value(t, l.drop.at.x, 137)  // …and where along the track
	testing.expect_value(t, l.drop.at.y, 22)
}

// The position is the drop's, not whatever the pointer did next before
// update ran.
@(test)
a_drops_position_is_not_overwritten_by_what_happens_next :: proc(t: ^testing.T) {
	fx: Dt_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	dt_view(&fx, false)

	db := node_get(&fx.ui.tree, fx.b)
	da := node_get(&fx.ui.tree, fx.a)
	if db == nil || da == nil do testing.fail_now(t, "no tracks")
	at := [2]f32{db.abs.x + 200, db.abs.y + 30}

	drag_begin(&fx.ui, fx.src, false)
	pointer_move(&fx.ui, at)
	drag_drop(&fx.ui, fx.b, .On, at = at)

	// the pointer carries on over the other track before update runs
	pointer_move(&fx.ui, {da.abs.x + 5, da.abs.y + 5})

	l, is := fx.ui.msgs[0].(Landed)
	if !testing.expect(t, is, "a Drop came back") do return
	testing.expect_value(t, l.drop.at.x, 200) // still where it was let go
	testing.expect_value(t, l.drop.at.y, 30)
	testing.expect_value(t, l.target, 2)      // …and still the track it landed on
}

// A target that asks hears where the drag is as it moves, and once more
// when it goes — which is what lets a timeline ghost the clip.
@(test)
a_target_hears_where_a_drag_is_over_it :: proc(t: ^testing.T) {
	fx: Dt_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	dt_view(&fx, true)

	da := node_get(&fx.ui.tree, fx.a)
	if da == nil do testing.fail_now(t, "no track")
	drag_begin(&fx.ui, fx.src, false)
	clear(&fx.ui.msgs)

	// two moves along the same track: both are reported, not just the first
	pointer_move(&fx.ui, {da.abs.x + 40, da.abs.y + 20})
	pointer_move(&fx.ui, {da.abs.x + 90, da.abs.y + 20})
	overs := 0
	last_x := f32(0)
	for m in fx.ui.msgs {
		if o, is := m.(Drag_Over); is && !o.left {
			overs += 1
			last_x = o.at.x
		}
	}
	testing.expect(t, overs >= 2, "the target hears the drag slide along it, not only arrive")
	testing.expect_value(t, last_x, 90)

	// …and hears that it has gone
	clear(&fx.ui.msgs)
	drag_finish(&fx.ui, dropped = false)
	left := false
	for m in fx.ui.msgs do if o, is := m.(Drag_Over); is && o.left do left = true
	testing.expect(t, left, "so nothing is left ghosting a clip that is not coming")
}

}
