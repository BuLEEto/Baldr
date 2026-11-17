package baldr

@(require) import "core:strings"
@(require) import "core:testing"
@(require) import "baldr:platform"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// The desktop's lists: the windows and workspaces a taskbar sees and acts on.


@(private = "file")
Win_Changed :: struct {}

@(private = "file")
Spaces_Changed :: struct {}

@(private = "file")
Desktop_DMsg :: union { Win_Changed, Spaces_Changed }

@(private = "file")
DState :: struct {}

@(private = "file")
Desk_Call :: struct {
	id:           u64,
	toplevel:     Toplevel_Action,
	workspace:    Workspace_Action,
	output:       string,
	is_workspace: bool,
}

@(private = "file")
Desk :: struct {
	windows: []platform.Toplevel,
	spaces:  []platform.Workspace,
	asked:   [dynamic]Desk_Call,
}

@(private = "file")
desk_backend :: proc(d: ^Desk) -> platform.Backend {
	b := platform.Backend{data = d, caps = {.Toplevels, .Workspaces}}
	b.toplevels = proc(b: ^platform.Backend) -> []platform.Toplevel { return (^Desk)(b.data).windows }
	b.workspaces = proc(b: ^platform.Backend) -> []platform.Workspace { return (^Desk)(b.data).spaces }
	b.toplevel_request = proc(b: ^platform.Backend, id: u64, action: platform.Toplevel_Action) {
		append(&(^Desk)(b.data).asked, Desk_Call{id = id, toplevel = action})
	}
	b.workspace_request = proc(b: ^platform.Backend, id: u64, action: platform.Workspace_Action, output: string) {
		append(&(^Desk)(b.data).asked, Desk_Call{id = id, workspace = action, output = output, is_workspace = true})
	}
	return b
}

// What the desktop lists reaches the app as its own copy; what the app
// asks reaches the desktop; a desktop that lists nothing gives empty lists
// and ignores the commands.
@(test)
a_taskbar_reads_and_acts_on_the_desktops_windows_and_workspaces :: proc(t: ^testing.T) {
	title := strings.clone("Home — Files")
	defer delete(title)
	screens := []string{"DP-1"}
	d := Desk{
		windows = []platform.Toplevel{
			{id = 1, title = title, app_id = "files", outputs = screens, activated = true},
			{id = 2, title = "Rename", app_id = "files", parent = 1},
		},
		spaces = []platform.Workspace{
			{id = 7, identifier = "ws-1", name = "1", number = 1, outputs = screens, active = true, can_activate = true, can_assign = true},
		},
	}
	defer delete(d.asked)
	b := desk_backend(&d)
	toplevels_take(&b)
	workspaces_take(&b)
	defer desktop_lists_free()

	wins := toplevels()
	testing.expect(t, len(wins) == 2 && wins[0].title == "Home — Files" && wins[0].activated && wins[0].outputs[0] == "DP-1", "the windows as listed, with their screens and states")
	if len(wins) == 2 do testing.expect_value(t, wins[1].parent, u64(1)) // the dialog knows its window
	(transmute([]u8)title)[0] = 'X' // the backend's string is gone after its next pump
	testing.expect_value(t, toplevels()[0].title, "Home — Files") // the app's copy stays
	spaces := workspaces()
	testing.expect(t, len(spaces) == 1 && spaces[0].active && spaces[0].number == 1 && spaces[0].outputs[0] == "DP-1" && spaces[0].identifier == "ws-1", "the workspaces with their screen")

	rt: Runtime(DState, Desktop_DMsg)
	rt.backend = &b
	run_cmd(&rt, toplevel_activate(Desktop_DMsg, 2))
	run_cmd(&rt, toplevel_set_minimized(Desktop_DMsg, 1, true))
	run_cmd(&rt, toplevel_set_minimized(Desktop_DMsg, 1, false))
	run_cmd(&rt, toplevel_set_maximized(Desktop_DMsg, 1, true))
	run_cmd(&rt, toplevel_set_fullscreen(Desktop_DMsg, 1, false))
	run_cmd(&rt, toplevel_close(Desktop_DMsg, 2))
	run_cmd(&rt, workspace_activate(Desktop_DMsg, 7))
	run_cmd(&rt, workspace_assign(Desktop_DMsg, 7, "DP-2"))
	want := []Desk_Call{
		{id = 2, toplevel = .Activate},
		{id = 1, toplevel = .Minimize},
		{id = 1, toplevel = .Unminimize},
		{id = 1, toplevel = .Maximize},
		{id = 1, toplevel = .Unfullscreen},
		{id = 2, toplevel = .Close},
		{id = 7, workspace = .Activate, is_workspace = true},
		{id = 7, workspace = .Assign, output = "DP-2", is_workspace = true},
	}
	testing.expect_value(t, len(d.asked), len(want))
	for w, i in want do if i < len(d.asked) do testing.expectf(t, d.asked[i] == w, "command %d reached the desktop as %v, not %v", i, d.asked[i], w)

	none := platform.Backend{}
	toplevels_take(&none)
	workspaces_take(&none)
	testing.expect(t, len(toplevels()) == 0 && len(workspaces()) == 0, "a desktop that lists no windows or workspaces: empty lists")
	rt.backend = &none
	testing.expect(t, run_cmd(&rt, toplevel_close(Desktop_DMsg, 2)) && run_cmd(&rt, workspace_activate(Desktop_DMsg, 7)), "and commands that do nothing")
}

// A toplevels_changed / workspaces_changed line sends its message for each
// change while it stays declared.
@(test)
window_and_workspace_subscriptions_follow_their_lines :: proc(t: ^testing.T) {
	s: Sched(Desktop_DMsg)
	defer sched_destroy(&s, nil, nil)
	lines := []Sub(Desktop_DMsg){toplevels_changed(Desktop_DMsg, Win_Changed{}), workspaces_changed(Desktop_DMsg, Spaces_Changed{})}
	sched_sync(&s, lines, 0, nil, nil, nil)
	out: [dynamic]Desktop_DMsg
	defer delete(out)
	testing.expect(t, sched_signal(s.toplevels[:], &out) && len(out) == 1, "the windows changed: the app hears it")
	if len(out) == 1 {
		_, is_windows := out[0].(Win_Changed)
		testing.expect(t, is_windows)
	}
	clear(&out)
	sched_sync(&s, lines, 0, nil, nil, nil) // declared again: one line each still
	testing.expect(t, sched_signal(s.workspaces[:], &out) && len(out) == 1, "the workspaces changed: one message")
	clear(&out)
	sched_sync(&s, lines[1:], 0, nil, nil, nil) // the windows line goes
	testing.expect(t, !sched_signal(s.toplevels[:], &out) && len(out) == 0, "and stops with its line")
}

// A window the compositor can name. `id` is Baldr's own counter and means
// nothing to the compositor; two windows can share an app id and a title
// ("Home — Files" twice). `handle` — the protocol object id
// of the foreign-toplevel handle on this app's own connection — is the one
// name both sides hold, and it has to reach the app intact.
@(test)
a_toplevel_carries_the_compositors_name_for_it :: proc(t: ^testing.T) {
	d := Desk{
		windows = []platform.Toplevel{
			{id = 1, handle = 41, title = "Home — Files", app_id = "files"},
			{id = 2, handle = 57, title = "Home — Files", app_id = "files"}, // the same app, the same title
		},
	}
	defer delete(d.asked)
	b := desk_backend(&d)
	toplevels_take(&b)
	defer desktop_lists_free() // the list's own memory too, not only what is in it
	ws := toplevels()
	testing.expect_value(t, len(ws), 2)
	testing.expect_value(t, ws[0].handle, u32(41))
	testing.expect_value(t, ws[1].handle, u32(57))
	testing.expect(t, ws[0].title == ws[1].title && ws[0].handle != ws[1].handle, "the handle tells apart what the title cannot")
}

} // when ODIN_TEST