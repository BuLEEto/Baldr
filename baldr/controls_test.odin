package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

Ctl_Kind :: enum { None, Check, Slide, Plain }
Ctl_Msg :: struct {
	kind: Ctl_Kind,
	b:    bool,
	f:    f32,
	tag:  u64,
}

@(private = "file")
on_check :: proc(e: Ev(bool)) -> Ctl_Msg { return {kind = .Check, b = e.value, tag = e.tag} }
@(private = "file")
on_slide :: proc(e: Ev(f32)) -> Ctl_Msg { return {kind = .Slide, f = e.value, tag = e.tag} }

@(test)
controls_checkbox_and_toggle_send_flipped_values :: proc(t: ^testing.T) {
	ui: Ui(Ctl_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	cb := checkbox(&ui, false, "Remember me", on_check, tag = 7)
	tg := toggle(&ui, true, "Dark", Ctl_Msg{kind = .Plain})
	dis := checkbox(&ui, false, "Nope", on_check, disabled = true)
	end_view(&ui)
	frame(&ui.tree, {400, 300})

	testing.expect_value(t, node_get(&ui.tree, cb).access.role, Role.Checkbox)
	testing.expect_value(t, node_get(&ui.tree, cb).access.name, "Remember me")
	testing.expect(t, .Checked not_in node_get(&ui.tree, cb).access.states)
	testing.expect(t, .Checked in node_get(&ui.tree, tg).access.states)

	testing.expect(t, click(&ui, cb))
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0].kind, Ctl_Kind.Check)
	testing.expect(t, ui.msgs[0].b, "unchecked → sends true")
	testing.expect_value(t, ui.msgs[0].tag, u64(7))

	testing.expect(t, click(&ui, tg))
	testing.expect_value(t, ui.msgs[1].kind, Ctl_Kind.Plain)
	testing.expect(t, !click(&ui, dis), "disabled ignores clicks")

	// Pointer path: press + release on the checkbox row.
	r := node_get(&ui.tree, cb).abs
	p := [2]f32{r.x + 4, r.y + 4}
	pointer_button(&ui, .Left, true, p)
	pointer_button(&ui, .Left, false, p)
	testing.expect_value(t, len(ui.msgs), 3)
	// Keyboard: Space on the focused toggle.
	set_focus(&ui.tree, tg, true)
	testing.expect(t, key_event(&ui, .Space, true, {}))
	testing.expect_value(t, len(ui.msgs), 4)
}

@(test)
controls_toggle_knob_glides :: proc(t: ^testing.T) {
	ui: Ui(Ctl_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	view := proc(ui: ^Ui(Ctl_Msg), on: bool) -> Node {
		begin_view(ui)
		tg := toggle(ui, on, "Dark", Ctl_Msg{kind = .Plain})
		end_view(ui)
		frame(&ui.tree, {400, 300})
		return tg
	}
	tg := view(&ui, false)
	track := node_first(&ui.tree, tg)
	anim_tick(&ui.tree, 1000)
	frame(&ui.tree, {400, 300})
	testing.expect_value(t, anim_value(&ui.tree, track, .Value), f32(0))
	view(&ui, true)                      // target flips → tween starts at t=1000
	testing.expect(t, ui.anim_active)
	anim_tick(&ui.tree, 1000 + f64(ui.theme.motion.fast) / 2)
	frame(&ui.tree, {400, 300})
	mid := anim_value(&ui.tree, track, .Value)
	testing.expect(t, mid > 0.3 && mid < 1, "knob part way")
	anim_tick(&ui.tree, 5000)
	frame(&ui.tree, {400, 300})
	testing.expect_value(t, anim_value(&ui.tree, track, .Value), f32(1))
}

// A slider can be dragged without taking the keyboard. A focused slider
// answers Left and Right, and where those keys belong to the window (a
// picture viewer's next and previous) a press on a playback bar must move
// it without stealing them: `focus_on_click`, as on `button` and
// `clickable`.
@(test)
a_slider_can_be_dragged_without_taking_focus :: proc(t: ^testing.T) {
	press_at :: proc(ui: ^Ui(Ctl_Msg), focus_on_click: bool) -> (Node, Node) {
		begin_view(ui)
		column(ui, padding = 20)
		other := button(ui, "Elsewhere", Ctl_Msg{}, key = 1)
		sl := slider(ui, 20, min = 0, max = 100, on_change = on_slide, step = 5, width = 200,
			focus_on_click = focus_on_click, key = 2)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {400, 300})
		d := node_get(&ui.tree, sl)
		pos := [2]f32{d.abs.x + d.abs.w * 0.5, d.abs.y + d.abs.h / 2}
		pointer_button(ui, .Left, true, pos)
		pointer_button(ui, .Left, false, pos)
		return sl, other
	}

	// By default a press focuses it.
	{
		ui: Ui(Ctl_Msg)
		ui_init(&ui); defer ui_destroy(&ui)
		sl, _ := press_at(&ui, true)
		testing.expect_value(t, ui.focus, sl)
	}

	// And with focus_on_click = false it drags without taking the keyboard,
	// so the keys stay where they were.
	{
		ui: Ui(Ctl_Msg)
		ui_init(&ui); defer ui_destroy(&ui)
		sl, other := press_at(&ui, false)
		testing.expect(t, ui.focus != sl, "the slider did not take the keyboard")
		_ = other
		// It still moved: the press is a drag, only the focus is withheld.
		testing.expect(t, len(ui.msgs) > 0, "the press still set a value")
	}
}

@(test)
controls_slider_maps_pointer_to_value_with_step :: proc(t: ^testing.T) {
	ui: Ui(Ctl_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	column(&ui, padding = 20)
	sl := slider(&ui, 20, min = 0, max = 100, on_change = on_slide, step = 5, width = 200, tag = 3)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 300})
	d := node_get(&ui.tree, sl)
	testing.expect_value(t, d.access.role, Role.Slider)
	testing.expect(t, d.access.has_value)
	testing.expect_value(t, d.access.value, f32(20))
	testing.expect_value(t, d.abs.w, f32(200))

	// Press at 75% of the usable track: value 75 (step 5).
	usable := d.abs.w - SLIDER_THUMB
	x := d.abs.x + SLIDER_THUMB / 2 + usable * 0.75
	y := d.abs.y + d.abs.h / 2
	testing.expect(t, pointer_button(&ui, .Left, true, {x, y}))
	testing.expect_value(t, ui.pointer.slider_drag, sl)
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0].kind, Ctl_Kind.Slide)
	testing.expect_value(t, ui.msgs[0].f, f32(75))
	testing.expect_value(t, ui.msgs[0].tag, u64(3))
	// Drag past the end clamps; step snapping keeps multiples of 5.
	pointer_move(&ui, {x + 1000, y})
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1].f, f32(100))
	pointer_move(&ui, {d.abs.x + SLIDER_THUMB / 2 + usable * 0.333, y})
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1].f, f32(35)) // 33.3 → 35
	pointer_button(&ui, .Left, false, {x, y})
	testing.expect_value(t, ui.pointer.slider_drag, NODE_NONE)
	testing.expect(t, !ui.sliders[sl].dragging)
	// The slider never fires a button click.
	for m in ui.msgs do testing.expect(t, m.kind == Ctl_Kind.Slide)
}

// A toggle's knob is what shows its state, so it reads on its track (at
// least 3:1) off as well as on, in every mode and contrast: off it is the
// muted content colour, on the on-accent colour.
@(test)
controls_toggle_knob_reads_on_its_track :: proc(t: ^testing.T) {
	for contrast in Theme_Contrast {
		for mode in Theme_Mode {
			for on in ([]bool{false, true}) {
				ui: Ui(Ctl_Msg)
				ui_init(&ui)
				ui.tree.theme = theme_from_seed(BALDR_BLUE, mode, contrast)
				begin_view(&ui)
				tg := toggle(&ui, on, "Dark", Ctl_Msg{kind = .Plain})
				end_view(&ui)
				frame(&ui.tree, {200, 60})
				ui_tick(&ui, 10_000) // the knob has glided
				frame(&ui.tree, {200, 60})
				track, knob: Maybe(Draw_Rect)
				for c in draw_list(&ui.tree) {
					r, ok := c.(Draw_Rect)
					if !ok do continue
					if r.rect.w == TOGGLE_W && r.rect.h == TOGGLE_H do track = r
					if r.rect.w == SLIDER_THUMB && r.rect.h == SLIDER_THUMB do knob = r
				}
				tr, has_track := track.?
				kn, has_knob := knob.?
				testing.expectf(t, has_track && has_knob, "%v %v %v: the track and knob are drawn", mode, contrast, on)
				if has_track && has_knob {
					ratio := contrast_ratio(kn.color, tr.color)
					testing.expectf(t, ratio >= 3, "%v %v on=%v: the knob reads on its track: %.2f:1", mode, contrast, on, ratio)
				}
				_ = tg
				ui_destroy(&ui)
			}
		}
	}
}

} // when ODIN_TEST