// 13_taskbar — what a taskbar and a workspace switcher see and do: the open
// windows as the compositor lists them, each with buttons to raise,
// minimise, maximise and close it, and the workspaces to switch between.
// Each window shows its app's icon from the icon theme and its title, cut
// with "…" past 220 px; a minimised window's icon is faded, a mark under it
// is a dot for running and a bar for the window in front, and a right-click
// opens a menu of its actions, with theme icons.
// The lists come from `baldr.toplevels()` and `baldr.workspaces()`, which
// `toplevels_changed` / `workspaces_changed` subscriptions keep the view in
// step with; the buttons send commands from update. On a desktop
// that doesn't list windows (a compositor without
// wlr-foreign-toplevel-management or ext-workspace, Windows) the lists are
// empty and it says so.
//
//   ./build.sh example 13_taskbar run
//   BALDR_WAYLAND_DEBUG=1 build/13_taskbar     # what the compositor lists, each request, and
//                                              # where it says each window's button is
package main

import "core:fmt"
import "core:strings"
import "baldr:baldr"

State :: struct {
	changes:   int, // how many times the desktop's lists changed
	menu_for:  u64, // the window whose menu is open
	menu_open: bool,
}

Changed :: struct {}
Act :: struct {
	id:   u64,
	what: baldr.Toplevel_Action,
}
Switch :: struct {
	id: u64,
}
Window_Menu :: struct {
	id: u64,
}
Menu_Closed :: struct {}
Msg :: union { Changed, Act, Switch, Window_Menu, Menu_Closed }

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch v in m {
	case Changed:
		s.changes += 1 // the view is built again from the new lists
	case Window_Menu:
		s.menu_for, s.menu_open = v.id, true
	case Menu_Closed:
		s.menu_open = false
	case Act:
		s.menu_open = false
		switch v.what {
		case .Activate:     return baldr.toplevel_activate(Msg, v.id)
		case .Minimize:     return baldr.toplevel_set_minimized(Msg, v.id, true)
		case .Unminimize:   return baldr.toplevel_set_minimized(Msg, v.id, false)
		case .Maximize:     return baldr.toplevel_set_maximized(Msg, v.id, true)
		case .Unmaximize:   return baldr.toplevel_set_maximized(Msg, v.id, false)
		case .Fullscreen:   return baldr.toplevel_set_fullscreen(Msg, v.id, true)
		case .Unfullscreen: return baldr.toplevel_set_fullscreen(Msg, v.id, false)
		case .Close:        return baldr.toplevel_close(Msg, v.id)
		}
	case Switch:
		return baldr.workspace_activate(Msg, v.id)
	}
	return {}
}

subscriptions :: proc(s: ^State, out: ^[dynamic]baldr.Sub(Msg)) {
	append(out, baldr.toplevels_changed(Msg, Changed{}))
	append(out, baldr.workspaces_changed(Msg, Changed{}))
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, flex = 1, padding = .lg, gap = .md); defer baldr.end(ui)

	baldr.text(ui, "Workspaces", role = .Title)
	spaces := baldr.workspaces()
	if len(spaces) == 0 do baldr.text(ui, "This desktop doesn't list its workspaces.", muted = true)
	baldr.wrap(ui, gap = .sm); {
		defer baldr.end(ui)
		for w in spaces {
			label := w.name if w.name != "" else fmt.tprintf("%d", w.number)
			if len(w.outputs) > 0 do label = fmt.tprintf("%s · %s", label, strings.join(w.outputs, ", ", context.temp_allocator))
			baldr.button(ui, label, Msg(Switch{w.id}), variant = .Outline, pressed = w.active, disabled = !w.can_activate, key = w.id)
		}
	}

	baldr.text(ui, "Windows", role = .Title)
	windows := baldr.toplevels()
	if len(windows) == 0 do baldr.text(ui, "This desktop doesn't list its windows.", muted = true)
	for w in windows {
		baldr.row(ui, gap = .sm, align = .Center, key = w.id); {
			defer baldr.end(ui)
			name := w.title if w.title != "" else w.app_id
			if w.parent != 0 do name = fmt.tprintf("↳ %s", name) // a dialog, under its window
			b := baldr.button(ui, name, Msg(Act{w.id, .Activate}), variant = .Ghost, theme_icon = w.app_id, pressed = w.activated,
				on_context = Msg(Window_Menu{w.id}))
			// a long title stops at 220 px; a minimised window's icon fades (its label's colour, which a full-colour icon ignores);
			// the running mark under it is a dot, and a longer bar for the window in front
			baldr.button_options(ui, b, max_width = 220, icon_color = baldr.with_alpha(ui.tree.theme.color.primary, 0.45) if w.minimized else {},
				mark = baldr.Button_Mark{side = .Bottom, length = 16 if w.activated else 6})
			// …and this button is where that window is, so the compositor can
			// fly it in here as it minimises and back out as it returns. It
			// follows the button along the bar.
			baldr.toplevel_spot(ui, b, w.id)
			baldr.text(ui, fmt.tprintf("%s · %s", w.app_id, strings.join(w.outputs, ", ", context.temp_allocator)), muted = true, ellipsis = .End)
			baldr.spacer(ui)
			baldr.button(ui, "Restore" if w.minimized else "Minimize", Msg(Act{w.id, .Unminimize if w.minimized else .Minimize}), variant = .Ghost)
			baldr.button(ui, "Unmaximize" if w.maximized else "Maximize", Msg(Act{w.id, .Unmaximize if w.maximized else .Maximize}), variant = .Ghost)
			baldr.button(ui, "Close", Msg(Act{w.id, .Close}), variant = .Ghost)
		}
	}

	if baldr.context_menu(ui, s.menu_open, Msg(Menu_Closed{})) {
		defer baldr.end(ui)
		minimized, maximized: bool
		for w in windows do if w.id == s.menu_for do minimized, maximized = w.minimized, w.maximized
		baldr.menu_item(ui, "Restore" if minimized else "Minimize", Msg(Act{s.menu_for, .Unminimize if minimized else .Minimize}), theme_icon = "window-minimize")
		baldr.menu_item(ui, "Unmaximize" if maximized else "Maximize", Msg(Act{s.menu_for, .Unmaximize if maximized else .Maximize}),
			theme_icon = "window-restore" if maximized else "window-maximize")
		baldr.menu_item(ui, "Close", Msg(Act{s.menu_for, .Close}), theme_icon = "window-close")
	}
}

main :: proc() {
	err := baldr.run(baldr.App(State, Msg){
		app_id        = "dev.baldr.taskbar",
		title         = "Windows and workspaces",
		size          = {760, 520},
		update        = update,
		view          = view,
		subscriptions = subscriptions,
	})
	if err != .None do fmt.eprintln("exit:", err)
}
