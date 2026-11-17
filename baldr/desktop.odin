package baldr

// Windows and workspaces: what a taskbar, a dock and a workspace switcher
// see and do. The compositor lists the open windows (their titles, app ids,
// screens, parents and states) and each screen's workspaces. `toplevels()` and `workspaces()` return them as last listed,
// and a `toplevels_changed` / `workspaces_changed` subscription says when
// they changed, once for each batch of the compositor's changes. What a
// bar asks of them goes back as commands from update. Where the desktop
// doesn't offer this (a compositor without wlr-foreign-toplevel-management
// or ext-workspace, Windows, macOS) the lists are empty and the commands do
// nothing.
//
//	subscriptions :: proc(s: ^State, out: ^[dynamic]baldr.Sub(Msg)) {
//		append(out, baldr.toplevels_changed(Msg, Windows_Changed{}))
//	}
//	update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
//		switch v in m {
//		case Raise: return baldr.toplevel_activate(Msg, v.id)
//		…

import "core:strings"
import "baldr:platform"

Toplevel         :: platform.Toplevel
Toplevel_Action  :: platform.Toplevel_Action
Workspace        :: platform.Workspace
Workspace_Action :: platform.Workspace_Action

// toplevels is the open windows as the compositor last listed them, in
// the order it announced them. Valid until they change (a
// `toplevels_changed` subscription says when); empty where the desktop
// doesn't list windows.
toplevels :: proc() -> []Toplevel {
	return known_toplevels[:]
}

// workspaces is the workspaces as the compositor last listed them, each
// with its screens. Valid until they change (`workspaces_changed`); empty
// where the desktop doesn't list workspaces.
workspaces :: proc() -> []Workspace {
	return known_workspaces[:]
}

@(private, thread_local)
known_toplevels: [dynamic]Toplevel // strings and output lists owned

@(private, thread_local)
known_workspaces: [dynamic]Workspace // strings and output lists owned

// toplevels_changed sends `msg` whenever a window opens, closes or changes
// (its title, screens or states); `toplevels()` then has the new list.
toplevels_changed :: proc($Msg: typeid, msg: Msg, tag: u64 = 0) -> Sub(Msg) {
	return {kind = .Toplevels, msg = msg, tag = tag}
}

// workspaces_changed sends `msg` whenever a workspace or its screen, name
// or state changes; `workspaces()` then has the new list.
workspaces_changed :: proc($Msg: typeid, msg: Msg, tag: u64 = 0) -> Sub(Msg) {
	return {kind = .Workspaces, msg = msg, tag = tag}
}

// toplevel_activate raises and focuses window `id` (a taskbar button's click).
toplevel_activate :: proc($Msg: typeid, id: u64) -> Cmd(Msg) {
	return {kind = .Toplevel, id = id, toplevel = .Activate}
}

// toplevel_set_minimized minimises window `id`, or brings it back.
toplevel_set_minimized :: proc($Msg: typeid, id: u64, minimized: bool) -> Cmd(Msg) {
	return {kind = .Toplevel, id = id, toplevel = .Minimize if minimized else .Unminimize}
}

// toplevel_set_maximized maximises window `id`, or restores it.
toplevel_set_maximized :: proc($Msg: typeid, id: u64, maximized: bool) -> Cmd(Msg) {
	return {kind = .Toplevel, id = id, toplevel = .Maximize if maximized else .Unmaximize}
}

// toplevel_set_fullscreen makes window `id` fullscreen on its screen, or
// takes it out of fullscreen.
toplevel_set_fullscreen :: proc($Msg: typeid, id: u64, fullscreen: bool) -> Cmd(Msg) {
	return {kind = .Toplevel, id = id, toplevel = .Fullscreen if fullscreen else .Unfullscreen}
}

// toplevel_close asks window `id` to close, as its close button would (the
// app may ask first).
toplevel_close :: proc($Msg: typeid, id: u64) -> Cmd(Msg) {
	return {kind = .Toplevel, id = id, toplevel = .Close}
}

// workspace_activate switches to workspace `id` on its screen.
workspace_activate :: proc($Msg: typeid, id: u64) -> Cmd(Msg) {
	return {kind = .Workspace, id = id, workspace = .Activate}
}

// activate asks the desktop to bring the app's own window — the surface
// whose `tag` it is (0: the app's first window) — to the front and give it
// the keyboard (xdg-activation): for MPRIS's Raise, a second launch, a
// notification's click. `token` is the activation token the app
// was handed (a D-Bus caller's, a launcher's); without one the app asks the
// desktop for one itself, which a desktop may grant only after recent
// input. A window the app is opening again in the same update (a player
// kept running with it closed) is activated as it shows. The desktop
// decides what an activation does: it may raise the window, or only mark it
// as wanting attention.
activate :: proc($Msg: typeid, tag: u64 = 0, token := "") -> Cmd(Msg) {
	return {kind = .Activate, tag = tag, token = token}
}

// workspace_assign moves workspace `id` to the screen named `output`; it
// does nothing when that screen has no workspaces or the workspace can't
// move (Workspace.can_assign).
workspace_assign :: proc($Msg: typeid, id: u64, output: string) -> Cmd(Msg) {
	return {kind = .Workspace, id = id, workspace = .Assign, output = output}
}

// toplevels_take copies the backend's windows into known_toplevels.
@(private)
toplevels_take :: proc(b: ^platform.Backend) {
	toplevels_clear()
	if b == nil || b.toplevels == nil do return
	for t in b.toplevels(b) {
		c := t
		c.title = strings.clone(t.title)
		c.app_id = strings.clone(t.app_id)
		c.outputs = clone_names(t.outputs)
		append(&known_toplevels, c)
	}
}

// workspaces_take copies the backend's workspaces into known_workspaces.
@(private)
workspaces_take :: proc(b: ^platform.Backend) {
	workspaces_clear()
	if b == nil || b.workspaces == nil do return
	for w in b.workspaces(b) {
		c := w
		c.identifier = strings.clone(w.identifier)
		c.name = strings.clone(w.name)
		c.outputs = clone_names(w.outputs)
		append(&known_workspaces, c)
	}
}

@(private)
toplevels_clear :: proc() {
	for t in known_toplevels {
		delete(t.title)
		delete(t.app_id)
		delete_names(t.outputs)
	}
	clear(&known_toplevels)
}

@(private)
workspaces_clear :: proc() {
	for w in known_workspaces {
		delete(w.identifier)
		delete(w.name)
		delete_names(w.outputs)
	}
	clear(&known_workspaces)
}

// desktop_lists_free lets go of the windows and workspaces at the end of a run.
@(private)
desktop_lists_free :: proc() {
	toplevels_clear()
	workspaces_clear()
	delete(known_toplevels)
	delete(known_workspaces)
	known_toplevels, known_workspaces = nil, nil
}

@(private)
clone_names :: proc(names: []string) -> []string {
	if len(names) == 0 do return nil
	out := make([]string, len(names))
	for n, i in names do out[i] = strings.clone(n)
	return out
}

@(private)
delete_names :: proc(names: []string) {
	for n in names do delete(n)
	delete(names)
}

// ---------------------------------------------- where a window is shown

// toplevel_spot says that node `n` is where window `id` is shown — a
// taskbar button, a dock icon — so the compositor can fly the window into
// it as it minimises and back out of it as it returns
// (`zwlr_foreign_toplevel_handle_v1.set_rectangle`). Without it the
// compositor has to guess.
//
//	for w in baldr.toplevels() {
//		b := baldr.button(ui, w.title, Raise{w.id}, key = w.id)
//		baldr.toplevel_spot(ui, b, w.id)
//	}
//
// Declare it every build. Baldr sends the node's rectangle whenever layout
// moves it, and tells the compositor to forget it when the node goes, the
// window closes, or the node is no longer on screen. One button stands for
// several windows (an app group) by saying it once per window. Where several
// surfaces show the same window (a bar on each screen), the one on the
// window's own screen is sent last, since the compositor keeps the last; a
// window on a screen with no bar still gets whichever rectangle shows it.
// Nothing happens where the desktop does not list windows (no
// wlr-foreign-toplevel-management, Windows, macOS).
toplevel_spot :: proc(ui: ^Ui($Msg), n: Node, id: u64) {
	if id == 0 || node_get(&ui.tree, n) == nil do return
	ui.tree.toplevel_spots[id] = Toplevel_Spot{node = n, epoch = ui.epoch}
}

// Toplevel_Spot is one declaration: the node that stands for a window, and
// the build that said so. The epoch lets a node withdraw a spot by not
// declaring it again, while a skipped `component` (never asked) keeps it.
@(private)
Toplevel_Spot :: struct {
	node:  Node,
	epoch: u32,
}

// Toplevel_Rect is one window's place on one surface: what the compositor
// is told, and what the runtime compares against what it said last.
@(private)
Toplevel_Rect :: struct {
	id:      u64,
	surface: u32,
	rect:    [4]f32, // logical px in that surface
	own:     bool,   // the surface is on a screen the window is on
}

// toplevel_spots_of collects where surface `surface` says each window is,
// and forgets the spots that no longer mean anything: a node that has gone,
// a node with nothing on screen (zero-sized, fading out, or drawn on a
// popup's own surface), and a window the compositor no longer lists.
// `output` is the screen the surface is on and `windows` the compositor's
// list.
//
// Only a node that has gone for good loses its spot; one merely not showing
// keeps it, so a hidden bar's buttons come back without re-declaring.
@(private)
toplevel_spots_of :: proc(t: ^Tree, surface: u32, output: string, windows: []Toplevel, out: ^[dynamic]Toplevel_Rect) {
	stale := make([dynamic]u64, 0, len(t.toplevel_spots), context.temp_allocator)
	// The epoch of the latest build, which begin_view stamps on the root.
	built: u32
	if rd := node_get(t, t.root); rd != nil do built = rd.epoch
	for id, s in t.toplevel_spots {
		n := s.node
		d := node_get(t, n)
		if d == nil {
			append(&stale, id) // its button has gone for good
			continue
		}
		// Built again without saying it again: this node has stopped standing
		// for this window. A node the latest build never reached (a skipped
		// `component`) keeps what it declared, which is why the epochs are
		// compared rather than the table cleared.
		if d.epoch == built && s.epoch != built {
			append(&stale, id)
			continue
		}
		w, listed := toplevel_of(id, windows)
		if !listed {
			append(&stale, id) // the window closed
			continue
		}
		if .Exiting in d.flags || d.abs.w <= 0 || d.abs.h <= 0 do continue // nothing to fly into just now
		// A node inside a popover shown on its own surface is laid out in this
		// tree's coordinates but drawn on that surface, so its rectangle would
		// name a place on the wrong one: say nothing rather than something wrong.
		if popup_holds(t, n) do continue
		own := false
		for o in w.outputs do if o == output && output != "" { own = true; break }
		append(out, Toplevel_Rect{id = id, surface = surface, rect = {d.abs.x, d.abs.y, d.abs.w, d.abs.h}, own = own})
	}
	for id in stale do delete_key(&t.toplevel_spots, id)
}

@(private)
toplevel_of :: proc(id: u64, windows: []Toplevel) -> (Toplevel, bool) {
	for w in windows do if w.id == id do return w, true
	return {}, false
}

// toplevel_rect_changes says what to tell the compositor: `sends` are the
// rectangles that have moved or appeared, in the order they must go, and
// `clears` are the windows that are no longer shown anywhere, which take a
// zero rectangle so the compositor chooses for itself again.
//
// The protocol keeps the last rectangle a client sent for a window, so a
// surface on the window's own screen is sent after the ones that are not,
// and it is the one that stands.
//
// Both slices are temp-allocated.
@(private)
toplevel_rect_changes :: proc(was, now: []Toplevel_Rect) -> (clears, sends: []Toplevel_Rect) {
	cl := make([dynamic]Toplevel_Rect, 0, len(was), context.temp_allocator)
	sd := make([dynamic]Toplevel_Rect, 0, len(now), context.temp_allocator)
	for w in was {
		here := false
		for n in now do if n.id == w.id && n.surface == w.surface { here = true; break }
		if !here do append(&cl, Toplevel_Rect{id = w.id, surface = w.surface})
	}
	for n in now {
		same := false
		for w in was do if w.id == n.id && w.surface == n.surface && w.rect == n.rect { same = true; break }
		if !same do append(&sd, n)
	}
	// …and the one on the window's own screen goes last. A stable partition
	// keeps everything else in the order it was collected.
	ordered := make([dynamic]Toplevel_Rect, 0, len(sd), context.temp_allocator)
	for r in sd do if !r.own do append(&ordered, r)
	for r in sd do if r.own do append(&ordered, r)
	return cl[:], ordered[:]
}
