package baldr

@(require) import "core:strings"
@(require) import "core:testing"
@(require) import "baldr:platform"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A title bar the window draws itself follows the desktop's
// choices — which buttons, on which side, what a double click and the wheel
// do — and rolls the window up to its bar and back.


@(private = "file")
Tb_Msg :: union { int }

// what the stub hook was asked, per test thread
@(private = "file")
Tb_Asked :: struct {
	acts:   [16]platform.Window_Act,
	n:      int,
	rolls:  [8]struct { up: bool, height: f32 },
	n_roll: int,
}

@(private = "file", thread_local)
tb: Tb_Asked

@(private = "file")
tb_hook :: proc(t: ^Tree) {
	tb = {}
	t.window = {
		surface = 1,
		act = proc(user: rawptr, surface: u32, act: platform.Window_Act, edges: platform.Window_Edges, at: [2]f32) -> bool {
			if tb.n < len(tb.acts) {
				tb.acts[tb.n] = act
				tb.n += 1
			}
			return true
		},
		roll = proc(user: rawptr, surface: u32, up: bool, height: f32) -> bool {
			if tb.n_roll < len(tb.rolls) {
				tb.rolls[tb.n_roll] = {up, height}
				tb.n_roll += 1
			}
			return true
		},
	}
}

@(private = "file")
tb_build :: proc(ui: ^Ui(Tb_Msg), buttons: Chrome_Buttons = CHROME_ALL, content := false) -> Node {
	begin_view(ui)
	column(ui)
	bar := window_chrome(ui, "Notes")
	window_buttons(ui, buttons)
	end(ui)
	if content {
		column(ui, padding = .md, flex = 1)
		text_input(ui, nil, label = "Body")
		end(ui)
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	return bar
}

// tb_order is the bar's own buttons and title in tree order: what a reader
// and Tab meet, and (in a row) what shows left to right.
@(private = "file")
tb_order :: proc(t: ^Tree, bar: Node) -> string {
	out := make([dynamic]string, context.temp_allocator)
	walk :: proc(t: ^Tree, n: Node, out: ^[dynamic]string) {
		for c := node_first(t, n); c != NODE_NONE; c = node_next(t, c) {
			d := node_get(t, c)
			if d == nil do continue
			if b, is := t.chrome_btn[c]; is {
				append(out, "close" if b == .Close else "min" if b == .Minimize else "max")
				continue
			}
			if _, is_text := d.kind.(Text_Kind); is_text do append(out, "title")
			walk(t, c, out)
		}
	}
	walk(t, bar, &out)
	return strings.join(out[:], " ", context.temp_allocator)
}

@(test)
the_desktops_button_layout_is_read_as_gnome_writes_it :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, layout: string, left, right: []Chrome_Button, loc := #caller_location) {
		p := chrome_prefs({button_layout = layout})
		l, r := p.left, p.right
		testing.expect(t, p.set && slice_eq(l[:p.n_left], left) && slice_eq(r[:p.n_right], right), layout, loc = loc)
	}
	slice_eq :: proc(a, b: []Chrome_Button) -> bool {
		if len(a) != len(b) do return false
		for x, i in a do if x != b[i] do return false
		return true
	}
	check(t, "", {}, {.Minimize, .Maximize, .Close})                         // nothing said: the usual
	check(t, ":minimize,maximize,close", {}, {.Minimize, .Maximize, .Close})
	check(t, "close,minimize,maximize:", {.Close, .Minimize, .Maximize}, {}) // as on a Mac
	check(t, "appmenu:close", {}, {.Close})                                  // GNOME's own default: no minimise or maximise
	check(t, "close:maximize", {.Close}, {.Maximize})                        // split between the ends
	check(t, "minimize:maximize", {.Minimize}, {.Maximize, .Close})          // close left out: it is shown all the same
	check(t, "icon,close,close:spacer,minimize", {.Close}, {.Minimize})      // what isn't the window's, and a second close, passed over
	check(t, "close,maximize", {.Close, .Maximize}, {})                      // no colon: all on the left

	Word :: struct { w: string, want: Titlebar_Action }
	for c in ([]Word{{"toggle-maximize", .Maximize}, {"minimize", .Minimize}, {"toggle-shade", .Roll_Up}, {"roll_up", .Roll_Up},
		{"menu", .Menu}, {"none", .None}, {"nothing", .None}, {"lower", .None}}) {
		got, ok := titlebar_action_of(c.w)
		testing.expectf(t, ok && got == c.want, "%q is %v", c.w, c.want)
	}
	_, known := titlebar_action_of("toggle-maximize-diagonally")
	testing.expect(t, !known, "a word it doesn't know says so")
	p := titlebar_of(platform.Ev_Theme{button_layout = "close:", double_click = "toggle-shade"})
	testing.expect(t, p.n_left == 1 && p.left[0] == .Close && p.n_right == 0 && p.double_click == .Roll_Up, "the desktop's, from the portal's words")
}

@(test)
the_buttons_go_where_the_desktop_puts_them :: proc(t: ^testing.T) {
	ui: Ui(Tb_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	bar := tb_build(&ui)
	testing.expect_value(t, tb_order(&ui.tree, bar), "title min max close") // the usual

	set_titlebar_prefs(&ui.tree, {button_layout = "close,minimize,maximize:"})
	bar = tb_build(&ui)
	testing.expect_value(t, tb_order(&ui.tree, bar), "close min max title") // before the title, in the desktop's order
	title_x, close_x: f32
	for n, b in ui.tree.chrome_btn do if b == .Close do close_x = node_get(&ui.tree, n).abs.x
	for c := node_first(&ui.tree, bar); c != NODE_NONE; c = node_next(&ui.tree, c) {
		if d := node_get(&ui.tree, c); d != nil {
			if _, is_text := d.kind.(Text_Kind); is_text do title_x = d.abs.x
		}
	}
	testing.expect(t, close_x < title_x && close_x < 20, "and drawn there: at the bar's left end")

	set_titlebar_prefs(&ui.tree, {button_layout = "appmenu:close"})
	bar = tb_build(&ui)
	testing.expect_value(t, tb_order(&ui.tree, bar), "title close") // the desktop shows no minimise or maximise

	set_titlebar_prefs(&ui.tree, {button_layout = ":close,maximize,minimize"})
	bar = tb_build(&ui, {.Close})
	testing.expect_value(t, tb_order(&ui.tree, bar), "title close") // a dialog offers close alone, wherever the desktop wants the rest
	bar = tb_build(&ui)
	testing.expect_value(t, tb_order(&ui.tree, bar), "title close max min")

	// back to the right: the place on the left goes, and nothing is left behind in the lint
	set_titlebar_prefs(&ui.tree, {})
	bar = tb_build(&ui)
	testing.expect_value(t, tb_order(&ui.tree, bar), "title min max close")
	testing.expect_value(t, lint(&ui.tree), 0)
}

@(test)
a_double_click_does_what_the_desktop_says :: proc(t: ^testing.T) {
	ui: Ui(Tb_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	double :: proc(ui: ^Ui(Tb_Msg), bar: Node) {
		d := node_get(&ui.tree, bar)
		at := [2]f32{d.abs.x + 200, d.abs.y + 8}
		ui.tree.now_ms += 5000
		chrome_press(ui, at, .Left)
		ui.tree.now_ms += 100
		chrome_press(ui, at, .Left)
	}
	for action in Titlebar_Action {
		set_titlebar_prefs(&ui.tree, {double_click = action})
		bar := tb_build(&ui)
		tb_hook(&ui.tree)
		double(&ui, bar)
		last := tb.acts[tb.n - 1]
		switch action {
		case .Maximize: testing.expect_value(t, last, platform.Window_Act.Maximize)
		case .Minimize: testing.expect_value(t, last, platform.Window_Act.Minimize)
		case .Menu:     testing.expect_value(t, last, platform.Window_Act.Menu)
		case .None:     testing.expect(t, tb.n == 2 && last == .Move && tb.n_roll == 0, "nothing: the second press is a press that can drag, as the first")
		case .Roll_Up:
			d := node_get(&ui.tree, bar)
			testing.expect(t, tb.n_roll == 1 && tb.rolls[0].up && tb.rolls[0].height == d.abs.y + d.abs.h, "rolled up to the bar's bottom")
			ui.surface.rolled = true
			double(&ui, bar)
			testing.expect(t, tb.n_roll == 2 && !tb.rolls[1].up, "and back down")
			ui.surface.rolled = false
			ui.surface.maximized = true
			double(&ui, bar)
			testing.expect_value(t, tb.n_roll, 2) // never a maximised window
			ui.surface.maximized, ui.surface.tiled = false, true
			double(&ui, bar)
			testing.expect_value(t, tb.n_roll, 2) // nor a tiled one
			ui.surface.tiled = false
		}
	}

	// maximising a rolled-up window brings it down first
	set_titlebar_prefs(&ui.tree, {})
	tb_build(&ui)
	tb_hook(&ui.tree)
	ui.surface.rolled = true
	for n, b in ui.tree.chrome_btn do if b == .Maximize do click(&ui, n)
	testing.expect(t, tb.n_roll == 1 && !tb.rolls[0].up && tb.n == 1 && tb.acts[0] == .Maximize, "down, then maximised")
}

@(test)
the_wheel_rolls_the_window_where_the_desktop_says :: proc(t: ^testing.T) {
	ui: Ui(Tb_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	bar := tb_build(&ui)
	tb_hook(&ui.tree)
	d := node_get(&ui.tree, bar)
	over := [2]f32{d.abs.x + 200, d.abs.y + 8}
	testing.expect(t, !scroll_event(&ui, over, {0, -SCROLL_STEP_PX}) && tb.n_roll == 0, "unless it says so, the wheel isn't the bar's")

	set_titlebar_prefs(&ui.tree, {wheel = .Roll_Up})
	bar = tb_build(&ui)
	testing.expect(t, scroll_event(&ui, over, {0, -SCROLL_STEP_PX / 3}) && tb.n_roll == 0, "a touchpad's small step is the bar's, not yet a notch")
	scroll_event(&ui, over, {0, -SCROLL_STEP_PX / 3})
	scroll_event(&ui, over, {0, -SCROLL_STEP_PX / 2})
	testing.expect(t, tb.n_roll == 1 && tb.rolls[0].up, "up: rolled up")
	ui.surface.rolled = true
	scroll_event(&ui, over, {0, SCROLL_STEP_PX})
	testing.expect(t, tb.n_roll == 2 && !tb.rolls[1].up, "down: back down")
	for n, _ in ui.tree.chrome_btn {
		bd := node_get(&ui.tree, n)
		testing.expect(t, !scroll_event(&ui, {bd.abs.x + bd.abs.w / 2, bd.abs.y + bd.abs.h / 2}, {0, -SCROLL_STEP_PX}), "over a button the wheel isn't the bar's")
	}
	testing.expect_value(t, tb.n_roll, 2)
}

@(test)
rolled_up_what_is_below_the_bar_is_out_of_reach :: proc(t: ^testing.T) {
	ui: Ui(Tb_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	bar := tb_build(&ui, content = true)
	field := NODE_NONE
	for n, _ in ui.tree.inputs do field = n
	body := node_next(&ui.tree, bar)
	testing.expect(t, set_focus(&ui.tree, field, true))

	ui.tree.roll_bar = bar
	roll_inert(&ui.tree, true)
	testing.expect(t, .Inert in node_get(&ui.tree, body).flags, "the body below the bar is inert")
	testing.expect(t, .Inert not_in node_get(&ui.tree, bar).flags, "the bar isn't")
	_, on_bar := ui.tree.chrome_btn[ui.tree.focus]
	testing.expect(t, on_bar, "the keyboard went to the bar's first control")
	testing.expect(t, hit_test(&ui.tree, {50, 200}) != field, "the pointer can't reach the field")

	roll_inert(&ui.tree, true) // after a build, as the run loop does: still inert, still one entry
	testing.expect_value(t, len(ui.tree.roll_inert), 1)

	roll_inert(&ui.tree, false)
	testing.expect(t, .Inert not_in node_get(&ui.tree, body).flags && ui.tree.focus == field, "back down: reachable again, the keyboard back where it was")

	// a node the app made inert while rolled stays the app's
	roll_inert(&ui.tree, true)
	set_inert(&ui.tree, body, true)
	roll_inert(&ui.tree, false)
	testing.expect(t, .Inert in node_get(&ui.tree, body).flags, "the app's inert stays")
}

@(test)
a_window_rolls_to_a_size_of_its_own_and_back :: proc(t: ^testing.T) {
	Sizes :: struct { asked: [8][2]f32, n: int }
	sizes: Sizes
	b := platform.Backend{data = &sizes}
	b.surface_set_size = proc(b: ^platform.Backend, s: platform.Surface, size: [2]f32) {
		z := (^Sizes)(b.data)
		z.asked[z.n] = size
		z.n += 1
	}
	fc := Frame_Ctx{backend = &b, surface = 3, size = {640, 480}}
	testing.expect(t, !window_roll(&fc, false, 0), "not rolled: nothing to bring down")
	testing.expect(t, !window_roll(&fc, true, 480), "a bar as tall as the window: nothing to roll")
	testing.expect(t, window_roll(&fc, true, 36))
	testing.expect(t, sizes.n == 1 && sizes.asked[0] == {640, 36} && fc.rolled == {640, 480}, "its bar's height, its width kept")
	fc.size = {640, 36} // the configure that follows
	testing.expect_value(t, frame_layout_size(&fc), [2]f32{640, 480}) // laid out at the size it had: nothing in it moves
	testing.expect(t, !window_roll(&fc, true, 36), "rolled once is enough")
	testing.expect(t, window_roll(&fc, false, 0))
	testing.expect(t, sizes.n == 3 && sizes.asked[1] == {640, 480} && sizes.asked[2] == {}, "the size it had, then the desktop's to change")
	testing.expect_value(t, fc.rolled, [2]f32{})

	b.surface_set_size = nil
	testing.expect(t, !window_roll(&fc, true, 36), "a backend that can't: nothing")
}

} // when ODIN_TEST