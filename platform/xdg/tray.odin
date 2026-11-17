#+build linux
package xdg

// The tray on Linux: StatusNotifierItem for the item and
// com.canonical.dbusmenu for its menu. Both are D-Bus objects we export and
// a panel reads, the opposite direction from the rest of this package.
//
// There may be no tray at all: SNI needs a watcher running (KDE has one,
// GNOME only with the AppIndicator extension). `tray_set` answers false when
// there is none, and the watcher coming and going is watched, so the app
// hears `.Hosted` when a panel starts and `.Gone` when it stops.
//
// dbusmenu carries a layout revision, and bumping it makes every host fetch
// the whole tree. So a change to properties only (label, checkmark,
// enabled) goes out as `ItemsPropertiesUpdated`; only a change in shape
// bumps the revision.
//
// One item per connection: an SNI item's object lives at
// `/StatusNotifierItem`, so two on one connection would share the path. The
// API takes a list because other platforms allow several; here the second
// is refused rather than replacing the first.

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "baldr:dbus"
import "baldr:platform"

@(private = "file") WATCHER_NAME  :: "org.kde.StatusNotifierWatcher"
@(private = "file") WATCHER_PATH  :: "/StatusNotifierWatcher"
@(private = "file") WATCHER_IFACE :: "org.kde.StatusNotifierWatcher"
@(private = "file") ITEM_IFACE    :: "org.kde.StatusNotifierItem"
@(private = "file") ITEM_PATH     :: "/StatusNotifierItem"
@(private = "file") MENU_IFACE    :: "com.canonical.dbusmenu"
@(private = "file") MENU_PATH     :: "/MenuBar"
@(private = "file") PROPS_IFACE   :: "org.freedesktop.DBus.Properties"
@(private = "file") INTRO_IFACE   :: "org.freedesktop.DBus.Introspectable"

// Tray_Entry is one item we are showing: the description as last given,
// deep-copied into `mem`, and the bus name it lives at.
Tray_Entry :: struct {
	tag:      u64,
	desc:     platform.Tray_Desc,
	mem:      virtual.Arena,
	name:     string, // the well-known name this item owns
	revision: u32,    // dbusmenu's layout revision
	hosted:   bool,   // a host has it (told to the app once)
}

// tray_init installs the method handler and starts watching for a tray to
// appear or go away. Costs nothing on a desktop that has none.
@(private)
tray_init :: proc(x: ^Xdg) {
	if x.bus == nil do return
	dbus.serve(x.bus, tray_serve, x)
	x.tray_watch = dbus.on_signal(x.bus, "org.freedesktop.DBus", "NameOwnerChanged", tray_name_changed, x)
}

@(private)
tray_shutdown :: proc(x: ^Xdg) {
	for &e in x.tray do tray_entry_free(x, &e)
	delete(x.tray)
	if x.bus != nil && x.tray_watch != 0 do dbus.off_signal(x.bus, x.tray_watch)
}

@(private)
tray_entry_free :: proc(x: ^Xdg, e: ^Tray_Entry) {
	if x.bus != nil && len(e.name) > 0 {
		body := []dbus.Value{e.name}
		m := dbus.method_call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ReleaseName", body)
		m.flags = {.No_Reply_Expected}
		_, _ = dbus.send(x.bus, &m)
	}
	delete(e.name, x.alloc)
	virtual.arena_destroy(&e.mem)
}

// tray_set shows the item, or updates the one with this tag in place.
tray_set :: proc(x: ^Xdg, d: platform.Tray_Desc) -> bool {
	if x.bus == nil do return false
	if !tray_watcher_live(x) {
		debugf(x, "tray: no StatusNotifierWatcher on this desktop")
		return false
	}
	idx := -1
	for &e, i in x.tray do if e.tag == d.tag do idx = i
	if idx < 0 {
		if len(x.tray) > 0 {
			// See the note at the top: one item per connection.
			debugf(x, "tray: this desktop takes one item per app; %d was refused", d.tag)
			return false
		}
		append(&x.tray, Tray_Entry{tag = d.tag})
		idx = len(x.tray) - 1
		e := &x.tray[idx]
		if err := virtual.arena_init_growing(&e.mem); err != nil {
			pop(&x.tray)
			return false
		}
		e.name = fmt.aprintf("org.kde.StatusNotifierItem-%d-%d", os.get_pid(), d.tag, allocator = x.alloc)
		if !tray_request_name(x, e.name) do debugf(x, "tray: %s is already owned; carrying on under the unique name", e.name)
		if !tray_register(x, e) {
			tray_entry_free(x, e)
			ordered_remove(&x.tray, idx)
			return false
		}
	}

	e := &x.tray[idx]
	old := e.desc
	had := len(e.name) > 0 && e.revision > 0
	shape := !had || !tray_same_shape(old.menu, d.menu)
	icon_changed := !had || !tray_same_icon(old, d)
	tip_changed := !had || old.tooltip != d.tooltip || old.icon_name != d.icon_name
	title_changed := !had || old.title != d.title
	status_changed := !had || old.status != d.status

	// The copy is remade whole: a tray description is a handful of strings
	// and a few icons, and keeping it in one arena means one call frees it.
	virtual.arena_free_all(&e.mem)
	e.desc = tray_clone(d, virtual.arena_allocator(&e.mem))
	if shape do e.revision += 1

	if icon_changed do tray_emit(x, "NewIcon")
	if tip_changed do tray_emit(x, "NewToolTip")
	if title_changed do tray_emit(x, "NewTitle")
	if status_changed do tray_emit(x, "NewStatus", dbus.Value(tray_status_text(d.status)))
	if x.bus != nil {
		if shape {
			// The shape changed: every host re-reads the tree.
			body := []dbus.Value{u32(e.revision), i32(0)}
			_ = dbus.emit(x.bus, MENU_PATH, MENU_IFACE, "LayoutUpdated", body)
		} else {
			tray_emit_props(x, e, old)
		}
	}
	return true
}

tray_remove :: proc(x: ^Xdg, tag: u64) {
	for &e, i in x.tray {
		if e.tag != tag do continue
		tray_entry_free(x, &e)
		ordered_remove(&x.tray, i)
		return
	}
}

// ------------------------------------------------- the watcher, and hosts

@(private = "file")
tray_request_name :: proc(x: ^Xdg, name: string) -> bool {
	body := []dbus.Value{name, u32(0)}
	m := dbus.method_call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName", body)
	reply, err := dbus.call(x.bus, &m, 3000, x.alloc)
	if err != .None || reply.type == .Error || len(reply.body) < 1 do return false
	got, ok := dbus.as_u32(reply.body[0])
	return ok && (got == 1 || got == 4) // primary owner, or already the owner
}

// tray_register hands the item to the watcher by bus name rather than
// object path: every host understands the name form, not all the path form.
@(private = "file")
tray_register :: proc(x: ^Xdg, e: ^Tray_Entry) -> bool {
	body := []dbus.Value{e.name}
	m := dbus.method_call(WATCHER_NAME, WATCHER_PATH, WATCHER_IFACE, "RegisterStatusNotifierItem", body)
	reply, err := dbus.call(x.bus, &m, 3000, x.alloc)
	if err != .None || reply.type == .Error {
		debugf(x, "tray: the watcher refused the item (%v)", err)
		return false
	}
	// Whether a host is attached changes as panels come and go, so it is
	// read here and watched after.
	e.hosted = tray_host_present(x)
	if e.hosted do push(x, platform.Ev_Tray{tag = e.tag, kind = .Hosted})
	return true
}

@(private = "file")
tray_watcher_live :: proc(x: ^Xdg) -> bool {
	body := []dbus.Value{WATCHER_NAME}
	m := dbus.method_call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner", body)
	reply, err := dbus.call(x.bus, &m, 2000, x.alloc)
	if err != .None || reply.type == .Error || len(reply.body) < 1 do return false
	has, ok := dbus.as_bool(reply.body[0])
	return ok && has
}

@(private = "file")
tray_host_present :: proc(x: ^Xdg) -> bool {
	body := []dbus.Value{WATCHER_IFACE, "IsStatusNotifierHostRegistered"}
	m := dbus.method_call(WATCHER_NAME, WATCHER_PATH, PROPS_IFACE, "Get", body)
	reply, err := dbus.call(x.bus, &m, 2000, x.alloc)
	if err != .None || reply.type == .Error || len(reply.body) < 1 do return false
	v, ok := reply.body[0].(dbus.Variant)
	if !ok || v.value == nil do return false
	has, bok := dbus.as_bool(v.value^)
	return bok && has
}

// tray_name_changed hears the watcher start or stop: a panel restarting is
// the common case, and an item has to be registered again afterwards.
@(private = "file")
tray_name_changed :: proc(conn: ^dbus.Connection, sig: ^dbus.Message, user: rawptr) {
	x := (^Xdg)(user)
	if len(sig.body) < 3 do return
	name, _ := dbus.as_string(sig.body[0])
	if name != WATCHER_NAME do return
	old_owner, _ := dbus.as_string(sig.body[1])
	new_owner, _ := dbus.as_string(sig.body[2])
	context = runtime.default_context()
	if len(new_owner) > 0 {
		for &e in x.tray {
			if tray_register(x, &e) && !e.hosted {
				e.hosted = true
				push(x, platform.Ev_Tray{tag = e.tag, kind = .Hosted})
			}
			// The tree it had is gone with the old watcher.
			e.revision += 1
			body := []dbus.Value{u32(e.revision), i32(0)}
			_ = dbus.emit(x.bus, MENU_PATH, MENU_IFACE, "LayoutUpdated", body)
		}
		return
	}
	if len(old_owner) > 0 {
		for &e in x.tray {
			if !e.hosted do continue
			e.hosted = false
			push(x, platform.Ev_Tray{tag = e.tag, kind = .Gone})
		}
	}
}

@(private = "file")
tray_emit :: proc(x: ^Xdg, member: string, args: ..dbus.Value) {
	if x.bus == nil do return
	_ = dbus.emit(x.bus, ITEM_PATH, ITEM_IFACE, member, args)
}

// tray_emit_props says that some items' properties changed and the layout
// did not, so hosts need not re-read the whole menu.
@(private = "file")
tray_emit_props :: proc(x: ^Xdg, e: ^Tray_Entry, old: platform.Tray_Desc) {
	if x.bus == nil do return
	updated := make([dynamic]dbus.Value, context.temp_allocator)
	tray_prop_diff(e.desc.menu, old.menu, &updated)
	if len(updated) == 0 do return
	none := dbus.Array{sig = "(ias)", items = nil}
	body := []dbus.Value{
		dbus.Array{sig = "(ia{sv})", items = updated[:]},
		none,
	}
	_ = dbus.emit(x.bus, MENU_PATH, MENU_IFACE, "ItemsPropertiesUpdated", body)
}

@(private = "file")
tray_prop_diff :: proc(now, before: []platform.Tray_Item, out: ^[dynamic]dbus.Value) {
	for it, i in now {
		if i >= len(before) do break
		was := before[i]
		same_label := it.label == was.label
		same_enabled := it.disabled == was.disabled
		nc, nhas := it.checked.?
		wc, whas := was.checked.?
		same_check := nhas == whas && (!nhas || nc == wc)
		if !(same_label && same_enabled && same_check) {
			append(out, dbus.Value(dbus.Struct{fields = vals(i32(it.id), menu_props(it))}))
		}
		tray_prop_diff(it.children, was.children, out)
	}
}

// ------------------------------------------------------ what a host reads

// vals copies a struct's fields into temp memory: a slice literal would be
// the stack frame's and could not be returned.
@(private = "file")
vals :: proc(items: ..dbus.Value) -> []dbus.Value {
	out := make([]dbus.Value, len(items), context.temp_allocator)
	copy(out, items)
	return out
}

// menu_props is one item's dbusmenu properties. A property at its default
// is not sent, which keeps the dictionary small enough to re-send alone.
@(private = "file")
menu_props :: proc(it: platform.Tray_Item) -> dbus.Value {
	entries := make([dynamic]dbus.Dict_Entry, context.temp_allocator)
	put :: proc(entries: ^[dynamic]dbus.Dict_Entry, key: string, v: dbus.Value) {
		box := new_clone(v, context.temp_allocator)
		append(entries, dbus.Dict_Entry{key = key, value = dbus.Variant{value = box}})
	}
	if it.separator {
		put(&entries, "type", dbus.Value("separator"))
	} else {
		put(&entries, "label", dbus.Value(it.label))
		if it.disabled do put(&entries, "enabled", dbus.Value(false))
		if on, has := it.checked.?; has {
			put(&entries, "toggle-type", dbus.Value("checkmark"))
			put(&entries, "toggle-state", dbus.Value(i32(1 if on else 0)))
		}
		if len(it.children) > 0 do put(&entries, "children-display", dbus.Value("submenu"))
	}
	return dbus.Dict{key_sig = "s", value_sig = "v", entries = entries[:]}
}

// menu_item is one node of dbusmenu's `(ia{sv}av)`, children and all.
@(private = "file")
menu_item :: proc(it: platform.Tray_Item, depth: int) -> dbus.Value {
	kids := make([dynamic]dbus.Value, context.temp_allocator)
	if depth != 0 {
		for c in it.children {
			v := menu_item(c, depth - 1)
			append(&kids, dbus.Value(dbus.Variant{value = new_clone(v, context.temp_allocator)}))
		}
	}
	return dbus.Struct{fields = vals(i32(it.id), menu_props(it), dbus.Array{sig = "v", items = kids[:]})}
}

// menu_layout is the whole tree under the root, which dbusmenu calls item 0.
@(private = "file")
menu_layout :: proc(e: ^Tray_Entry, depth: int) -> dbus.Value {
	kids := make([dynamic]dbus.Value, context.temp_allocator)
	for it in e.desc.menu {
		v := menu_item(it, depth - 1 if depth > 0 else -1)
		append(&kids, dbus.Value(dbus.Variant{value = new_clone(v, context.temp_allocator)}))
	}
	root_props := make([dynamic]dbus.Dict_Entry, context.temp_allocator)
	box := new_clone(dbus.Value("submenu"), context.temp_allocator)
	append(&root_props, dbus.Dict_Entry{key = "children-display", value = dbus.Variant{value = box}})
	return dbus.Struct{fields = vals(i32(0),
		dbus.Dict{key_sig = "s", value_sig = "v", entries = root_props[:]},
		dbus.Array{sig = "v", items = kids[:]})}
}

// pixmaps is SNI's `a(iiay)`. The wire wants ARGB32 in network order (A, R,
// G, B bytes); ours are host-order words.
@(private = "file")
pixmaps :: proc(src: []platform.Tray_Pixmap) -> dbus.Value {
	items := make([dynamic]dbus.Value, context.temp_allocator)
	for p in src {
		bytes := make([]u8, len(p.argb) * 4, context.temp_allocator)
		for v, i in p.argb {
			bytes[i * 4 + 0] = u8(v >> 24)
			bytes[i * 4 + 1] = u8(v >> 16)
			bytes[i * 4 + 2] = u8(v >> 8)
			bytes[i * 4 + 3] = u8(v)
		}
		append(&items, dbus.Value(dbus.Struct{fields = vals(i32(p.w), i32(p.h), bytes)}))
	}
	return dbus.Array{sig = "(iiay)", items = items[:]}
}

@(private = "file")
tray_status_text :: proc(s: platform.Tray_Status) -> string {
	return "NeedsAttention" if s == .Attention else "Active"
}

// item_prop answers one StatusNotifierItem property.
@(private = "file")
item_prop :: proc(x: ^Xdg, e: ^Tray_Entry, name: string) -> (dbus.Value, bool) {
	id := x.app_id if len(x.app_id) > 0 else "baldr"
	switch name {
	case "Category": return "ApplicationStatus", true
	case "Id":       return id, true
	case "Title":    return (e.desc.title if len(e.desc.title) > 0 else id), true
	case "Status":   return tray_status_text(e.desc.status), true
	case "IconName": return e.desc.icon_name, true
	case "IconPixmap": return pixmaps(e.desc.icon), true
	case "OverlayIconName", "AttentionIconName": return "", true
	case "AttentionIconPixmap": return pixmaps(nil), true
	case "ToolTip":
		// (icon name, icon pixmaps, title, description). Hosts show the last
		// two; the app's tooltip goes in the title, since a lone line reads
		// as a heading anyway.
		return dbus.Struct{fields = vals("", pixmaps(nil), e.desc.tooltip, "")}, true
	case "ItemIsMenu":
		// False: true tells a host the item is only a menu, and it then
		// opens the menu for every click and never sends Activate.
		return false, true
	case "Menu": return dbus.Object_Path{path = MENU_PATH}, true
	case "WindowId": return i32(0), true
	case "IconThemePath": return "", true
	}
	return nil, false
}

@(private = "file")
menu_prop :: proc(name: string) -> (dbus.Value, bool) {
	switch name {
	case "Version":       return u32(3), true
	case "Status":        return "normal", true
	case "TextDirection": return "ltr", true
	case "IconThemePath":
		empty: []dbus.Value
		return dbus.Array{sig = "s", items = empty}, true
	}
	return nil, false
}

@(private = "file")
ITEM_PROPS := [?]string{
	"Category", "Id", "Title", "Status", "IconName", "IconPixmap",
	"OverlayIconName", "AttentionIconName", "AttentionIconPixmap",
	"ToolTip", "ItemIsMenu", "Menu", "WindowId", "IconThemePath",
}

@(private = "file")
MENU_PROPS := [?]string{"Version", "Status", "TextDirection", "IconThemePath"}

// --------------------------------------------------- answering the panel

// tray_serve answers everything a host asks of our two objects. Anything
// else is left for another handler (there is none yet) and the bus's own
// UnknownMethod.
@(private = "file")
tray_serve :: proc(conn: ^dbus.Connection, call: ^dbus.Message, user: rawptr) -> bool {
	x := (^Xdg)(user)
	if len(x.tray) == 0 do return false
	e := &x.tray[0]
	context = runtime.default_context()

	if call.interface == INTRO_IFACE && call.member == "Introspect" {
		// Some hosts introspect before they will talk to an object at all.
		xml := INTROSPECT_ITEM if call.path == ITEM_PATH else INTROSPECT_MENU
		_ = dbus.reply(conn, call, []dbus.Value{xml})
		return true
	}

	if call.interface == PROPS_IFACE {
		iface := ""
		if len(call.body) > 0 {
			if got, ok := dbus.as_string(call.body[0]); ok do iface = got
		}
		switch call.member {
		case "Get":
			if len(call.body) < 2 do return false
			name, _ := dbus.as_string(call.body[1])
			v: dbus.Value
			ok: bool
			if iface == ITEM_IFACE {
				v, ok = item_prop(x, e, name)
			} else {
				v, ok = menu_prop(name)
			}
			if !ok {
				_ = dbus.reply_error(conn, call, "org.freedesktop.DBus.Error.UnknownProperty", name)
				return true
			}
			_ = dbus.reply(conn, call, []dbus.Value{dbus.Variant{value = new_clone(v, context.temp_allocator)}})
			return true
		case "GetAll":
			entries := make([dynamic]dbus.Dict_Entry, context.temp_allocator)
			if iface == ITEM_IFACE {
				for n in ITEM_PROPS {
					if v, ok := item_prop(x, e, n); ok {
						append(&entries, dbus.Dict_Entry{key = n, value = dbus.Variant{value = new_clone(v, context.temp_allocator)}})
					}
				}
			} else {
				for n in MENU_PROPS {
					if v, ok := menu_prop(n); ok {
						append(&entries, dbus.Dict_Entry{key = n, value = dbus.Variant{value = new_clone(v, context.temp_allocator)}})
					}
				}
			}
			_ = dbus.reply(conn, call, []dbus.Value{dbus.Dict{key_sig = "s", value_sig = "v", entries = entries[:]}})
			return true
		case "Set":
			_ = dbus.reply(conn, call, nil) // nothing is writable; answered so the caller does not time out
			return true
		}
		return false
	}

	if call.interface == ITEM_IFACE {
		switch call.member {
		case "Activate":
			// The primary action. Some hosts open the menu for any click and
			// never send it, so nothing may be reachable only this way.
			push(x, platform.Ev_Tray{tag = e.tag, kind = .Clicked})
			_ = dbus.reply(conn, call, nil)
			return true
		case "SecondaryActivate", "ContextMenu", "Scroll":
			// A host opens the menu object without asking us, and a middle
			// click or the wheel means nothing here. Answered so the call
			// does not time out.
			_ = dbus.reply(conn, call, nil)
			return true
		}
		return false
	}

	if call.interface == MENU_IFACE {
		switch call.member {
		case "GetLayout":
			depth := -1
			if len(call.body) > 1 {
				if d, ok := dbus.as_i32(call.body[1]); ok do depth = int(d)
			}
			parent := i32(0)
			if len(call.body) > 0 {
				if p, ok := dbus.as_i32(call.body[0]); ok do parent = p
			}
			layout := menu_layout(e, depth) if parent == 0 else menu_sub(e, parent, depth)
			_ = dbus.reply(conn, call, []dbus.Value{u32(e.revision), layout})
			return true
		case "GetGroupProperties":
			items := make([dynamic]dbus.Value, context.temp_allocator)
			menu_group(e.desc.menu, &items)
			_ = dbus.reply(conn, call, []dbus.Value{dbus.Array{sig = "(ia{sv})", items = items[:]}})
			return true
		case "GetProperty":
			if len(call.body) < 2 do return false
			id, _ := dbus.as_i32(call.body[0])
			name, _ := dbus.as_string(call.body[1])
			if it, ok := menu_find(e.desc.menu, u32(id)); ok {
				props := menu_props(it).(dbus.Dict)
				for entry in props.entries {
					if k, _ := dbus.as_string(entry.key); k == name {
						_ = dbus.reply(conn, call, []dbus.Value{entry.value})
						return true
					}
				}
			}
			_ = dbus.reply_error(conn, call, "org.freedesktop.DBus.Error.InvalidArgs", name)
			return true
		case "Event":
			if len(call.body) >= 2 {
				id, _ := dbus.as_i32(call.body[0])
				what, _ := dbus.as_string(call.body[1])
				if what == "clicked" do push(x, platform.Ev_Tray{tag = e.tag, kind = .Chosen, id = u32(id)})
			}
			_ = dbus.reply(conn, call, nil)
			return true
		case "EventGroup":
			_ = dbus.reply(conn, call, []dbus.Value{dbus.Array{sig = "i", items = nil}})
			return true
		case "AboutToShow":
			// False: nothing is built on demand, so the host's copy is
			// already right and it need not re-read before showing.
			_ = dbus.reply(conn, call, []dbus.Value{false})
			return true
		case "AboutToShowGroup":
			none := dbus.Array{sig = "i", items = nil}
			_ = dbus.reply(conn, call, []dbus.Value{none, none})
			return true
		}
		return false
	}
	return false
}

@(private = "file")
menu_find :: proc(items: []platform.Tray_Item, id: u32) -> (platform.Tray_Item, bool) {
	for it in items {
		if it.id == id do return it, true
		if found, ok := menu_find(it.children, id); ok do return found, true
	}
	return {}, false
}

@(private = "file")
menu_sub :: proc(e: ^Tray_Entry, parent: i32, depth: int) -> dbus.Value {
	if it, ok := menu_find(e.desc.menu, u32(parent)); ok do return menu_item(it, depth)
	return dbus.Struct{fields = vals(parent,
		dbus.Dict{key_sig = "s", value_sig = "v", entries = nil},
		dbus.Array{sig = "v", items = nil})}
}

@(private = "file")
menu_group :: proc(items: []platform.Tray_Item, out: ^[dynamic]dbus.Value) {
	for it in items {
		append(out, dbus.Value(dbus.Struct{fields = vals(i32(it.id), menu_props(it))}))
		menu_group(it.children, out)
	}
}

@(private = "file") INTROSPECT_ITEM :: `<node><interface name="org.kde.StatusNotifierItem"><method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method><method name="SecondaryActivate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method><method name="ContextMenu"><arg type="i" direction="in"/><arg type="i" direction="in"/></method><method name="Scroll"><arg type="i" direction="in"/><arg type="s" direction="in"/></method><signal name="NewIcon"/><signal name="NewTitle"/><signal name="NewToolTip"/><signal name="NewStatus"><arg type="s"/></signal></interface></node>`

@(private = "file") INTROSPECT_MENU :: `<node><interface name="com.canonical.dbusmenu"><method name="GetLayout"><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="as" direction="in"/><arg type="u" direction="out"/><arg type="(ia{sv}av)" direction="out"/></method><method name="Event"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/><arg type="u" direction="in"/></method><method name="AboutToShow"><arg type="i" direction="in"/><arg type="b" direction="out"/></method><signal name="LayoutUpdated"><arg type="u"/><arg type="i"/></signal></interface></node>`

// --------------------------------------------------------- keeping a copy

@(private = "file")
tray_clone :: proc(d: platform.Tray_Desc, allocator: runtime.Allocator) -> platform.Tray_Desc {
	out := d
	out.title = strings.clone(d.title, allocator)
	out.tooltip = strings.clone(d.tooltip, allocator)
	out.icon_name = strings.clone(d.icon_name, allocator)
	out.icon = tray_clone_pixmaps(d.icon, allocator)
	out.menu = tray_clone_items(d.menu, allocator)
	return out
}

@(private = "file")
tray_clone_pixmaps :: proc(src: []platform.Tray_Pixmap, allocator: runtime.Allocator) -> []platform.Tray_Pixmap {
	if len(src) == 0 do return nil
	out := make([]platform.Tray_Pixmap, len(src), allocator)
	for p, i in src {
		out[i] = p
		out[i].argb = make([]u32, len(p.argb), allocator)
		copy(out[i].argb, p.argb)
	}
	return out
}

@(private = "file")
tray_clone_items :: proc(src: []platform.Tray_Item, allocator: runtime.Allocator) -> []platform.Tray_Item {
	if len(src) == 0 do return nil
	out := make([]platform.Tray_Item, len(src), allocator)
	for it, i in src {
		out[i] = it
		out[i].label = strings.clone(it.label, allocator)
		out[i].icon = tray_clone_pixmaps(it.icon, allocator)
		out[i].children = tray_clone_items(it.children, allocator)
	}
	return out
}

// tray_same_shape is whether the menu's structure (ids, separators,
// nesting) is unchanged. Labels, checkmarks and enabled are properties and
// do not count: those go out without a layout re-read.
@(private = "file")
tray_same_shape :: proc(a, b: []platform.Tray_Item) -> bool {
	if len(a) != len(b) do return false
	for x, i in a {
		y := b[i]
		if x.id != y.id || x.separator != y.separator do return false
		_, xc := x.checked.?
		_, yc := y.checked.?
		if xc != yc do return false // a checkbox appearing is a new kind of item
		if !tray_same_shape(x.children, y.children) do return false
	}
	return true
}

@(private = "file")
tray_same_icon :: proc(a, b: platform.Tray_Desc) -> bool {
	if a.icon_name != b.icon_name || len(a.icon) != len(b.icon) do return false
	for p, i in a.icon {
		q := b.icon[i]
		if p.w != q.w || p.h != q.h || len(p.argb) != len(q.argb) do return false
		for v, j in p.argb do if v != q.argb[j] do return false
	}
	return true
}
