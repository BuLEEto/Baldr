#+build linux
// taskbar.odin — windows and workspaces for a taskbar, a dock and a
// workspace switcher. wlr-foreign-toplevel-management (v3)
// lists every open window, with its title, app id, screens, parent and
// states, and acts on it; ext-workspace (v1) lists each screen's workspaces
// and switches between them. The compositor announces what exists as soon
// as a manager is bound, so listeners go on at bind, and every object it
// hands over gets its listener in the event that brings it. The toolkit
// hears one Ev_Toplevels / Ev_Workspaces for each pump in which a `done`
// came.
package wayland

import "core:math"
import "core:strings"
import "baldr:platform"
import wl "baldr:platform/wayland/wl"

// Toplevel_State is one window a zwlr_foreign_toplevel_handle_v1 describes.
@(private)
Toplevel_State :: struct {
	st:      ^State,
	proxy:   wl.Proxy,
	l:       wl.Zwlr_Foreign_Toplevel_Handle_V1_Listener,
	id:      u64,
	title:   string,
	app_id:  string,
	outputs: [dynamic]wl.Proxy, // the wl_outputs it is on
	parent:  wl.Proxy,          // its parent's handle, nil when none
	activated, maximized, minimized, fullscreen: bool,
	names:   [dynamic]string,   // its screens' names, for the list the toolkit reads
}

// Ws_Group is one ext_workspace_group_handle_v1: a screen's workspaces.
@(private)
Ws_Group :: struct {
	st:      ^State,
	proxy:   wl.Proxy,
	l:       wl.Ext_Workspace_Group_Handle_V1_Listener,
	outputs: [dynamic]wl.Proxy,
}

// Ws_State is one ext_workspace_handle_v1.
@(private)
Ws_State :: struct {
	st:         ^State,
	proxy:      wl.Proxy,
	l:          wl.Ext_Workspace_Handle_V1_Listener,
	id:         u64,
	identifier: string,
	name:       string,
	number:     int,
	group:      ^Ws_Group,
	state:      wl.Ext_Workspace_Handle_V1_State,
	caps:       wl.Ext_Workspace_Handle_V1_Workspace_Capabilities,
	names:      [dynamic]string,
}

// ------------------------------------------------------------- windows

@(private)
toplevels_bind :: proc(st: ^State, reg: wl.Proxy, name, version: u32) {
	st.toplevel_mgr = wl.wl_registry_bind(reg, name, &wl.zwlr_foreign_toplevel_manager_v1_interface, min(version, wl.ZWLR_FOREIGN_TOPLEVEL_MANAGER_V1_VERSION))
	st.toplevel_mgr_l = wl.zwlr_foreign_toplevel_manager_v1_listener_noop()
	st.toplevel_mgr_l.toplevel = on_toplevel
	st.toplevel_mgr_l.finished = on_toplevels_finished
	wl.zwlr_foreign_toplevel_manager_v1_add_listener(st.toplevel_mgr, &st.toplevel_mgr_l, st)
}

@(private)
on_toplevel :: proc "c" (data: rawptr, p: wl.Proxy, handle: wl.Proxy) {
	st := (^State)(data)
	context = st.ctx
	st.next_toplevel += 1
	t := new(Toplevel_State)
	t.st, t.proxy, t.id = st, handle, st.next_toplevel
	t.l = wl.zwlr_foreign_toplevel_handle_v1_listener_noop()
	t.l.title = on_toplevel_title
	t.l.app_id = on_toplevel_app_id
	t.l.output_enter = on_toplevel_output_enter
	t.l.output_leave = on_toplevel_output_leave
	t.l.state = on_toplevel_state
	t.l.done = on_toplevel_done
	t.l.closed = on_toplevel_closed
	t.l.parent = on_toplevel_parent
	wl.zwlr_foreign_toplevel_handle_v1_add_listener(handle, &t.l, t)
	append(&st.toplevels, t)
}

@(private)
on_toplevel_title :: proc "c" (data: rawptr, p: wl.Proxy, title: cstring) {
	t := (^Toplevel_State)(data)
	context = t.st.ctx
	delete(t.title)
	t.title = strings.clone_from_cstring(title)
}

@(private)
on_toplevel_app_id :: proc "c" (data: rawptr, p: wl.Proxy, app_id: cstring) {
	t := (^Toplevel_State)(data)
	context = t.st.ctx
	delete(t.app_id)
	t.app_id = strings.clone_from_cstring(app_id)
}

@(private)
on_toplevel_output_enter :: proc "c" (data: rawptr, p: wl.Proxy, output: wl.Proxy) {
	t := (^Toplevel_State)(data)
	context = t.st.ctx
	for o in t.outputs do if o == output do return
	append(&t.outputs, output)
}

@(private)
on_toplevel_output_leave :: proc "c" (data: rawptr, p: wl.Proxy, output: wl.Proxy) {
	t := (^Toplevel_State)(data)
	context = t.st.ctx
	for o, i in t.outputs {
		if o != output do continue
		unordered_remove(&t.outputs, i)
		return
	}
}

@(private)
on_toplevel_state :: proc "c" (data: rawptr, p: wl.Proxy, states: ^wl.Array) {
	t := (^Toplevel_State)(data)
	t.activated, t.maximized, t.minimized, t.fullscreen = false, false, false, false
	for s in wl.array_slice(states, u32) {
		#partial switch wl.Zwlr_Foreign_Toplevel_Handle_V1_State(s) {
		case .Maximized:  t.maximized = true
		case .Minimized:  t.minimized = true
		case .Activated:  t.activated = true
		case .Fullscreen: t.fullscreen = true
		}
	}
}

@(private)
on_toplevel_parent :: proc "c" (data: rawptr, p: wl.Proxy, parent: wl.Proxy) {
	(^Toplevel_State)(data).parent = parent
}

@(private)
on_toplevel_done :: proc "c" (data: rawptr, p: wl.Proxy) {
	(^Toplevel_State)(data).st.toplevels_changed = true
}

@(private)
on_toplevel_closed :: proc "c" (data: rawptr, p: wl.Proxy) {
	t := (^Toplevel_State)(data)
	st := t.st
	context = st.ctx
	for other in st.toplevels do if other.parent == t.proxy do other.parent = nil
	for x, i in st.toplevels {
		if x != t do continue
		ordered_remove(&st.toplevels, i)
		break
	}
	wl.zwlr_foreign_toplevel_handle_v1_destroy(t.proxy)
	toplevel_free(t)
	st.toplevels_changed = true
}

// on_toplevels_finished: the compositor stopped listing windows.
@(private)
on_toplevels_finished :: proc "c" (data: rawptr, p: wl.Proxy) {
	st := (^State)(data)
	context = st.ctx
	for t in st.toplevels {
		wl.zwlr_foreign_toplevel_handle_v1_destroy(t.proxy)
		toplevel_free(t)
	}
	clear(&st.toplevels)
	wl.proxy_destroy(p)
	st.toplevel_mgr = nil
	st.toplevels_changed = true
}

@(private)
toplevel_free :: proc(t: ^Toplevel_State) {
	delete(t.title)
	delete(t.app_id)
	delete(t.outputs)
	delete(t.names)
	free(t)
}

// backend_toplevels is Backend.toplevels: the windows in the order they
// were announced, with their screens' names and their parents' ids.
@(private)
backend_toplevels :: proc(b: ^platform.Backend) -> []platform.Toplevel {
	st := state(b)
	clear(&st.toplevels_view)
	for t in st.toplevels {
		clear(&t.names)
		for o in t.outputs do if out := find_output(st, o); out != nil && out.out_name != "" do append(&t.names, out.out_name)
		parent: u64
		if t.parent != nil do for q in st.toplevels do if q.proxy == t.parent do parent = q.id
		append(&st.toplevels_view, platform.Toplevel{
			id = t.id, handle = wl.proxy_id(t.proxy), // the compositor's name for it, on our connection
			title = t.title, app_id = t.app_id, outputs = t.names[:], parent = parent,
			activated = t.activated, maximized = t.maximized, minimized = t.minimized, fullscreen = t.fullscreen,
		})
	}
	return st.toplevels_view[:]
}

// toplevel_request is Backend.toplevel_request.
@(private)
toplevel_request :: proc(b: ^platform.Backend, id: u64, action: platform.Toplevel_Action) {
	st := state(b)
	for t in st.toplevels {
		if t.id != id do continue
		p := t.proxy
		switch action {
		case .Activate:     if st.seat != nil do wl.zwlr_foreign_toplevel_handle_v1_activate(p, st.seat)
		case .Minimize:     wl.zwlr_foreign_toplevel_handle_v1_set_minimized(p)
		case .Unminimize:   wl.zwlr_foreign_toplevel_handle_v1_unset_minimized(p)
		case .Maximize:     wl.zwlr_foreign_toplevel_handle_v1_set_maximized(p)
		case .Unmaximize:   wl.zwlr_foreign_toplevel_handle_v1_unset_maximized(p)
		case .Fullscreen:   if wl.proxy_version(p) >= 2 do wl.zwlr_foreign_toplevel_handle_v1_set_fullscreen(p, nil)
		case .Unfullscreen: if wl.proxy_version(p) >= 2 do wl.zwlr_foreign_toplevel_handle_v1_unset_fullscreen(p)
		case .Close:        wl.zwlr_foreign_toplevel_handle_v1_close(p)
		}
		wl.display_flush(st.display)
		debugf(st, "window %d (%s): %v", id, t.app_id, action)
		return
	}
}

// toplevel_set_rectangle says where window `id` is shown on surface `s`
// (Backend.toplevel_set_rectangle): the rectangle the compositor flies a
// minimising window into, in that surface's own coordinates, as the
// protocol asks. A zero rect unsets it — the protocol's own meaning for an
// empty rectangle.
@(private)
toplevel_set_rectangle :: proc(b: ^platform.Backend, id: u64, s: platform.Surface, rect: [4]f32) {
	st := state(b)
	ss := lookup(st, s)
	if ss == nil || ss.wl_surface == nil do return
	for t in st.toplevels {
		if t.id != id do continue
		// Rounded rather than truncated: a button at x=10.6 belongs at 11,
		// and a width that loses its fraction leaves a gap the animation
		// lands short of.
		x, y := i32(math.round(rect[0])), i32(math.round(rect[1]))
		w, h := i32(math.round(rect[2])), i32(math.round(rect[3]))
		if w < 0 || h < 0 do return // nothing sensible to say
		wl.zwlr_foreign_toplevel_handle_v1_set_rectangle(t.proxy, ss.wl_surface, x, y, w, h)
		wl.display_flush(st.display)
		debugf(st, "window %d (%s): it is shown at %d,%d %dx%d on surface %d", id, t.app_id, x, y, w, h, s)
		return
	}
}

// ---------------------------------------------------------- workspaces

@(private)
workspaces_bind :: proc(st: ^State, reg: wl.Proxy, name, version: u32) {
	st.workspace_mgr = wl.wl_registry_bind(reg, name, &wl.ext_workspace_manager_v1_interface, min(version, wl.EXT_WORKSPACE_MANAGER_V1_VERSION))
	st.workspace_mgr_l = wl.ext_workspace_manager_v1_listener_noop()
	st.workspace_mgr_l.workspace_group = on_workspace_group
	st.workspace_mgr_l.workspace = on_workspace
	st.workspace_mgr_l.done = on_workspaces_done
	st.workspace_mgr_l.finished = on_workspaces_finished
	wl.ext_workspace_manager_v1_add_listener(st.workspace_mgr, &st.workspace_mgr_l, st)
}

@(private)
on_workspace_group :: proc "c" (data: rawptr, p: wl.Proxy, handle: wl.Proxy) {
	st := (^State)(data)
	context = st.ctx
	g := new(Ws_Group)
	g.st, g.proxy = st, handle
	g.l = wl.ext_workspace_group_handle_v1_listener_noop()
	g.l.output_enter = on_ws_group_output_enter
	g.l.output_leave = on_ws_group_output_leave
	g.l.workspace_enter = on_ws_group_workspace_enter
	g.l.workspace_leave = on_ws_group_workspace_leave
	g.l.removed = on_ws_group_removed
	wl.ext_workspace_group_handle_v1_add_listener(handle, &g.l, g)
	append(&st.ws_groups, g)
}

@(private)
on_workspace :: proc "c" (data: rawptr, p: wl.Proxy, handle: wl.Proxy) {
	st := (^State)(data)
	context = st.ctx
	st.next_workspace += 1
	w := new(Ws_State)
	w.st, w.proxy, w.id, w.number = st, handle, st.next_workspace, -1
	w.l = wl.ext_workspace_handle_v1_listener_noop()
	w.l.id = on_ws_id
	w.l.name = on_ws_name
	w.l.coordinates = on_ws_coordinates
	w.l.state = on_ws_state
	w.l.capabilities = on_ws_capabilities
	w.l.removed = on_ws_removed
	wl.ext_workspace_handle_v1_add_listener(handle, &w.l, w)
	append(&st.ws_list, w)
}

@(private)
on_workspaces_done :: proc "c" (data: rawptr, p: wl.Proxy) {
	(^State)(data).workspaces_changed = true
}

// on_workspaces_finished: the compositor stopped listing workspaces.
@(private)
on_workspaces_finished :: proc "c" (data: rawptr, p: wl.Proxy) {
	st := (^State)(data)
	context = st.ctx
	workspaces_free(st)
	wl.proxy_destroy(p)
	st.workspace_mgr = nil
	st.workspaces_changed = true
}

@(private)
on_ws_group_output_enter :: proc "c" (data: rawptr, p: wl.Proxy, output: wl.Proxy) {
	g := (^Ws_Group)(data)
	context = g.st.ctx
	for o in g.outputs do if o == output do return
	append(&g.outputs, output)
}

@(private)
on_ws_group_output_leave :: proc "c" (data: rawptr, p: wl.Proxy, output: wl.Proxy) {
	g := (^Ws_Group)(data)
	context = g.st.ctx
	for o, i in g.outputs {
		if o != output do continue
		unordered_remove(&g.outputs, i)
		return
	}
}

@(private)
on_ws_group_workspace_enter :: proc "c" (data: rawptr, p: wl.Proxy, workspace: wl.Proxy) {
	g := (^Ws_Group)(data)
	for w in g.st.ws_list do if w.proxy == workspace do w.group = g
}

@(private)
on_ws_group_workspace_leave :: proc "c" (data: rawptr, p: wl.Proxy, workspace: wl.Proxy) {
	g := (^Ws_Group)(data)
	for w in g.st.ws_list do if w.proxy == workspace && w.group == g do w.group = nil
}

@(private)
on_ws_group_removed :: proc "c" (data: rawptr, p: wl.Proxy) {
	g := (^Ws_Group)(data)
	st := g.st
	context = st.ctx
	for w in st.ws_list do if w.group == g do w.group = nil
	for x, i in st.ws_groups {
		if x != g do continue
		ordered_remove(&st.ws_groups, i)
		break
	}
	wl.ext_workspace_group_handle_v1_destroy(g.proxy)
	delete(g.outputs)
	free(g)
}

@(private)
on_ws_id :: proc "c" (data: rawptr, p: wl.Proxy, id: cstring) {
	w := (^Ws_State)(data)
	context = w.st.ctx
	delete(w.identifier)
	w.identifier = strings.clone_from_cstring(id)
}

@(private)
on_ws_name :: proc "c" (data: rawptr, p: wl.Proxy, name: cstring) {
	w := (^Ws_State)(data)
	context = w.st.ctx
	delete(w.name)
	w.name = strings.clone_from_cstring(name)
}

@(private)
on_ws_coordinates :: proc "c" (data: rawptr, p: wl.Proxy, coordinates: ^wl.Array) {
	w := (^Ws_State)(data)
	c := wl.array_slice(coordinates, u32)
	w.number = int(c[0]) if len(c) > 0 else -1
}

@(private)
on_ws_state :: proc "c" (data: rawptr, p: wl.Proxy, state: wl.Ext_Workspace_Handle_V1_State) {
	(^Ws_State)(data).state = state
}

@(private)
on_ws_capabilities :: proc "c" (data: rawptr, p: wl.Proxy, capabilities: wl.Ext_Workspace_Handle_V1_Workspace_Capabilities) {
	(^Ws_State)(data).caps = capabilities
}

@(private)
on_ws_removed :: proc "c" (data: rawptr, p: wl.Proxy) {
	w := (^Ws_State)(data)
	st := w.st
	context = st.ctx
	for x, i in st.ws_list {
		if x != w do continue
		ordered_remove(&st.ws_list, i)
		break
	}
	wl.ext_workspace_handle_v1_destroy(w.proxy)
	ws_free(w)
}

@(private)
ws_free :: proc(w: ^Ws_State) {
	delete(w.identifier)
	delete(w.name)
	delete(w.names)
	free(w)
}

// workspaces_free destroys every workspace and group object.
@(private)
workspaces_free :: proc(st: ^State) {
	for w in st.ws_list {
		wl.ext_workspace_handle_v1_destroy(w.proxy)
		ws_free(w)
	}
	clear(&st.ws_list)
	for g in st.ws_groups {
		wl.ext_workspace_group_handle_v1_destroy(g.proxy)
		delete(g.outputs)
		free(g)
	}
	clear(&st.ws_groups)
}

// backend_workspaces is Backend.workspaces: in the order they were
// announced, each with its group's screens.
@(private)
backend_workspaces :: proc(b: ^platform.Backend) -> []platform.Workspace {
	st := state(b)
	clear(&st.workspaces_view)
	for w in st.ws_list {
		clear(&w.names)
		if w.group != nil do for o in w.group.outputs do if out := find_output(st, o); out != nil && out.out_name != "" do append(&w.names, out.out_name)
		append(&st.workspaces_view, platform.Workspace{
			id = w.id, identifier = w.identifier, name = w.name, number = w.number, outputs = w.names[:],
			active = w.state & wl.EXT_WORKSPACE_HANDLE_V1_STATE_ACTIVE != 0,
			urgent = w.state & wl.EXT_WORKSPACE_HANDLE_V1_STATE_URGENT != 0,
			hidden = w.state & wl.EXT_WORKSPACE_HANDLE_V1_STATE_HIDDEN != 0,
			can_activate = w.caps & wl.EXT_WORKSPACE_HANDLE_V1_WORKSPACE_CAPABILITIES_ACTIVATE != 0,
			can_assign = w.caps & wl.EXT_WORKSPACE_HANDLE_V1_WORKSPACE_CAPABILITIES_ASSIGN != 0,
		})
	}
	return st.workspaces_view[:]
}

// workspace_request is Backend.workspace_request: the request, then the
// manager's commit that applies it.
@(private)
workspace_request :: proc(b: ^platform.Backend, id: u64, action: platform.Workspace_Action, output: string) {
	st := state(b)
	if st.workspace_mgr == nil do return
	for w in st.ws_list {
		if w.id != id do continue
		switch action {
		case .Activate:
			wl.ext_workspace_handle_v1_activate(w.proxy)
		case .Assign:
			group := ws_group_on(st, output)
			if group == nil {
				debugf(st, "workspace %d: no workspace group on %q to move it to", id, output)
				return
			}
			wl.ext_workspace_handle_v1_assign(w.proxy, group.proxy)
		}
		wl.ext_workspace_manager_v1_commit(st.workspace_mgr)
		wl.display_flush(st.display)
		debugf(st, "workspace %d (%s): %v %s", id, w.name, action, output)
		return
	}
}

// ws_group_on is the workspace group of the screen named `output`.
@(private)
ws_group_on :: proc(st: ^State, output: string) -> ^Ws_Group {
	for g in st.ws_groups {
		for o in g.outputs {
			if out := find_output(st, o); out != nil && out.out_name == output do return g
		}
	}
	return nil
}

// taskbar_shutdown destroys every window and workspace object and the managers.
@(private)
taskbar_shutdown :: proc(st: ^State) {
	for t in st.toplevels {
		wl.zwlr_foreign_toplevel_handle_v1_destroy(t.proxy)
		toplevel_free(t)
	}
	delete(st.toplevels)
	delete(st.toplevels_view)
	workspaces_free(st)
	delete(st.ws_list)
	delete(st.ws_groups)
	delete(st.workspaces_view)
	if st.toplevel_mgr != nil {
		wl.proxy_destroy(st.toplevel_mgr)
		st.toplevel_mgr = nil
	}
	if st.workspace_mgr != nil {
		wl.proxy_destroy(st.workspace_mgr)
		st.workspace_mgr = nil
	}
}
