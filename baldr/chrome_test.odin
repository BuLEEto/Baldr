package baldr

@(require) import "core:testing"
@(require) import "baldr:platform"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A window that draws its own frame has to do everything the desktop's frame
// did: move on a drag, maximise on a double click, resize from its edges,
// and have buttons a keyboard can reach. These check the asking — what the
// desktop does with it is the desktop's business.


@(private = "file")
Chr_Msg :: union { int }

// Fixed-size and thread-local: the test runner puts tests on several
// threads, and a shared growable log would be both a race and a double free.
@(private = "file")
Asked :: struct {
	acts:   [16]platform.Window_Act,
	edges:  [16]platform.Window_Edges,
	n:      int,
	closed: int,
}

@(private = "file", thread_local)
asked: Asked

@(private = "file")
last_act :: proc() -> platform.Window_Act {
	return asked.acts[asked.n - 1] if asked.n > 0 else .Move
}

@(private = "file")
stub_hook :: proc(t: ^Tree) {
	asked = {}
	t.window = {
		user = nil, surface = 1,
		act = proc(user: rawptr, surface: u32, act: platform.Window_Act, edges: platform.Window_Edges, at: [2]f32) -> bool {
			if asked.n < len(asked.acts) {
				asked.acts[asked.n], asked.edges[asked.n] = act, edges
				asked.n += 1
			}
			return true
		},
		close = proc(user: rawptr, surface: u32) { asked.closed += 1 },
	}
}

@(private = "file")
build :: proc(ui: ^Ui(Chr_Msg), buttons: Chrome_Buttons = CHROME_ALL) -> Node {
	begin_view(ui)
	column(ui)
	bar := window_chrome(ui, "Notes")
	window_buttons(ui, buttons)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	return bar
}

@(test)
a_title_bar_moves_the_window_and_maximises_on_a_double_click :: proc(t: ^testing.T) {
	ui: Ui(Chr_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	bar := build(&ui)
	stub_hook(&ui.tree)

	d := node_get(&ui.tree, bar)
	at := [2]f32{d.abs.x + 40, d.abs.y + 8}
	testing.expect(t, chrome_press(&ui, at, .Left), "a press on the bar is the bar's")
	testing.expect_value(t, asked.n, 1)
	testing.expect_value(t, asked.acts[0], platform.Window_Act.Move)

	// a second press in quick succession is a double click: maximise
	ui.tree.now_ms += 100
	chrome_press(&ui, at, .Left)
	testing.expect_value(t, last_act(), platform.Window_Act.Maximize)

	// …and a slow second press is just another move
	ui.tree.now_ms += 5000
	chrome_press(&ui, at, .Left)
	testing.expect_value(t, last_act(), platform.Window_Act.Move)

	// the right button asks the desktop for its own window menu
	chrome_press(&ui, at, .Right)
	testing.expect_value(t, last_act(), platform.Window_Act.Menu)
}

@(test)
a_title_bars_buttons_do_what_they_say :: proc(t: ^testing.T) {
	ui: Ui(Chr_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	build(&ui)
	stub_hook(&ui.tree)

	mini, maxi, closer := NODE_NONE, NODE_NONE, NODE_NONE
	for n, b in ui.tree.chrome_btn {
		switch b {
		case .Minimize: mini = n
		case .Maximize: maxi = n
		case .Close:    closer = n
		}
	}
	testing.expect(t, mini != NODE_NONE && maxi != NODE_NONE && closer != NODE_NONE, "all three are there")

	// they are real objects: named, and reachable by keyboard
	testing.expect_value(t, node_get(&ui.tree, mini).access.role, Role.Button)
	testing.expect_value(t, node_get(&ui.tree, mini).access.name, "Minimise")
	testing.expect_value(t, node_get(&ui.tree, closer).access.name, "Close")
	testing.expect(t, .Focusable in node_get(&ui.tree, maxi).flags, "the keyboard can reach them")

	// `click` is the one path: a pointer press and an Enter arrive here alike
	testing.expect(t, click(&ui, mini))
	testing.expect_value(t, last_act(), platform.Window_Act.Minimize)
	testing.expect(t, click(&ui, maxi))
	testing.expect_value(t, last_act(), platform.Window_Act.Maximize)

	// with no on_close from the app, the window goes the way the desktop's
	// own close goes
	testing.expect(t, click(&ui, closer))
	testing.expect_value(t, asked.closed, 1)
}

@(test)
a_frameless_window_resizes_from_its_edges :: proc(t: ^testing.T) {
	ui: Ui(Chr_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	build(&ui)
	stub_hook(&ui.tree)
	size := ui.tree.viewport

	// the sides, and the corners, which reach further along so they can be hit
	testing.expect_value(t, chrome_edge_at(size, {2, 200}), platform.Window_Edges{.Left})
	testing.expect_value(t, chrome_edge_at(size, {size.x - 2, 200}), platform.Window_Edges{.Right})
	testing.expect_value(t, chrome_edge_at(size, {300, 1}), platform.Window_Edges{.Top})
	testing.expect_value(t, chrome_edge_at(size, {2, 2}), platform.Window_Edges{.Top, .Left})
	testing.expect_value(t, chrome_edge_at(size, {size.x - 2, size.y - 8}), platform.Window_Edges{.Bottom, .Right})
	testing.expect_value(t, chrome_edge_at(size, {300, 200}), platform.Window_Edges{}) // the middle is not an edge

	// a press on a border asks for a resize with those edges
	testing.expect(t, chrome_resize_press(&ui, {2, 2}), "a corner press resizes")
	testing.expect_value(t, asked.acts[0], platform.Window_Act.Resize)
	testing.expect_value(t, asked.edges[0], platform.Window_Edges{.Top, .Left})

	// …and the pointer says so before anyone presses
	c, on_edge := chrome_cursor(&ui.tree, {2, 2})
	testing.expect(t, on_edge)
	testing.expect_value(t, c, Cursor.Resize_NWSE)

	// a maximised window has no edges to drag
	ui.surface.maximized = true
	testing.expect(t, !chrome_resize_press(&ui, {2, 2}), "nothing to resize when it fills the screen")
}

@(test)
a_window_can_offer_fewer_buttons :: proc(t: ^testing.T) {
	ui: Ui(Chr_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	build(&ui, {.Close}) // a dialog
	count := 0
	for _, b in ui.tree.chrome_btn do if b == .Close do count += 1
	testing.expect_value(t, len(ui.tree.chrome_btn), 1)
	testing.expect_value(t, count, 1)
}

// A title bar on paper the app chose: an undecorated window whose bar is
// part of its own surface must draw its title and buttons in the app's ink,
// not the theme's, or a dark theme's near-white lands on a light page.
@(test)
a_title_bar_writes_in_the_ink_it_is_given :: proc(t: ^testing.T) {
	ui: Ui(Chr_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_theme(&ui.tree, theme_dark()) // a dark desktop: the theme's ink is near-white
	slate := Color{0.08, 0.07, 0.05, 1}

	build_bar :: proc(ui: ^Ui(Chr_Msg), ink: Maybe(Color)) -> Node {
		set_viewport(&ui.tree, {480, 200})
		begin_view(ui)
		column(ui, flex = 1)
		bar := window_chrome(ui, "Shopping", ink = ink)
		window_buttons(ui, on_close = Chr_Msg(1), ink = ink)
		end(ui)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {480, 200})
		return bar
	}
	bar := build_bar(&ui, slate)

	// the title is the app's ink, not the theme's
	titles, icons := 0, 0
	for c in draw_list(&ui.tree) {
		#partial switch v in c {
		case Draw_Text:
			if v.str == "Shopping" {
				titles += 1
				testing.expect_value(t, Color{v.color.r, v.color.g, v.color.b, 1}, slate)
			}
		case Draw_Icon:
			icons += 1
			testing.expectf(t, luminance(v.color) < 0.2, "a window button is drawn at luminance %.3f", luminance(v.color))
		}
	}
	testing.expect_value(t, titles, 1)
	testing.expect(t, icons >= 3, "minimise, maximise and close are all on that paper")

	// …and it stays until changed, as an editor's ink does
	again := build_bar(&ui, nil)
	testing.expect_value(t, again, bar)
	testing.expect_value(t, chrome_ink(&ui.tree, bar), slate)
}

// A title bar stays open so an app can build its own controls into it, and
// those controls must get their presses. The trap is an icon-only button:
// its icon is what a hit test returns, and an icon answers nothing, so the
// bar must not take the press for itself.
@(test)
an_apps_own_buttons_in_a_title_bar_are_not_eaten_by_it :: proc(t: ^testing.T) {
	ui: Ui(Chr_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	stub_hook(&ui.tree)

	build_with_buttons :: proc(ui: ^Ui(Chr_Msg)) -> (bar, plain, icon_only: Node) {
		begin_view(ui)
		column(ui)
		bar = window_chrome(ui, "Notes")
		plain = button(ui, "New", Chr_Msg(7), size = .Small)
		icon_only = button(ui, "Delete", Chr_Msg(8), icon = .Trash, icon_only = true, variant = .Ghost, size = .Small)
		window_buttons(ui)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {600, 400})
		return
	}
	bar, plain, icon_only := build_with_buttons(&ui)
	testing.expect(t, plain != NODE_NONE && icon_only != NODE_NONE)

	// a press on the app's plain button is the button's, not the bar's
	asked = {}
	clear(&ui.msgs)
	pd := node_get(&ui.tree, plain).abs
	at := [2]f32{pd.x + pd.w / 2, pd.y + pd.h / 2}
	pointer_button(&ui, .Left, true, at)
	pointer_button(&ui, .Left, false, at)
	testing.expect_value(t, asked.n, 0) // the window was not moved
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == Chr_Msg(7), "the button's own message")

	// …and so is one on an icon-only button, whose icon is what the hit
	// test returns
	clear(&ui.msgs)
	id := node_get(&ui.tree, icon_only).abs
	at = {id.x + id.w / 2, id.y + id.h / 2}
	pointer_button(&ui, .Left, true, at)
	pointer_button(&ui, .Left, false, at)
	testing.expect_value(t, asked.n, 0)
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == Chr_Msg(8), "the icon-only button's message")

	// the bar itself still moves the window, between the controls
	clear(&ui.msgs)
	bd := node_get(&ui.tree, bar).abs
	pointer_button(&ui, .Left, true, {bd.x + bd.w - 200, bd.y + bd.h / 2})
	testing.expect(t, asked.n > 0 && last_act() == .Move, "a press on the bar is still a move")
}

} // when ODIN_TEST