#+build linux
package atspi

// The bridge: a second D-Bus connection, to the accessibility bus rather
// than the session bus, serving the toolkit's objects to whatever is
// listening (a screen reader, an inspector, an automated test).
//
// Starting it is three steps: ask the session bus where the accessibility
// bus is (org.a11y.Bus.GetAddress), connect there, and hand the registry a
// reference to our root object (org.a11y.atspi.Socket.Embed) so the desktop
// can walk into us. If any step fails the bridge stays off and the app runs
// without it; it is never fatal.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:unicode/utf8"
import "baldr:dbus"

// Bridge is the connection and what it needs to answer calls.
Bridge :: struct {
	conn:      ^dbus.Connection,
	provider:  Provider,
	allocator: runtime.Allocator,
	on:        bool,
	debug:     bool,
	desktop:   struct { name, path: string }, // our parent in the desktop's tree, from Embed
	app_id:    i32,                           // the id the registry gave us
	// Sees every event before the bus does, so a test with no bus can read
	// what an app would say.
	watcher:   proc(user: rawptr, ev: Event_Sent),
	watch_user: rawptr,
}

// Event_Sent is one signal as it goes out: which interface and member, its
// detail string and the two numbers AT-SPI carries with every event.
Event_Sent :: struct {
	id:       u64,
	iface:    string,
	member:   string,
	detail:   string,
	d1, d2:   i32,
	text:     string, // the payload when it is a string (a name, an announcement); "" otherwise
	ref:      u64,    // the object the event points at (a child added, the item a cursor moved to); 0 otherwise
}

// start connects to the accessibility bus and registers with it. False (with
// a reason) when there is nothing to connect to, which is the ordinary case
// on a desktop without assistive technology running: the caller carries on.
start :: proc(b: ^Bridge, provider: Provider, allocator := context.allocator) -> (ok: bool, why: string) {
	b.allocator = allocator
	b.provider = provider
	b.debug = os.get_env("BALDR_A11Y_DEBUG", context.temp_allocator) == "1"
	addr, have := bus_address(b, allocator)
	if !have do return false, "no accessibility bus (org.a11y.Bus said nothing)"
	defer delete(addr, allocator)
	conn, cerr := dbus.connect_address(addr, allocator) // authenticates and says Hello for us
	if cerr != .None do return false, fmt.tprintf("the accessibility bus refused us: %v", cerr)
	b.conn = conn
	dbus.serve(conn, on_call, b)
	if eok, ewhy := embed(b); !eok {
		dbus.serve(conn, nil, nil)
		dbus.disconnect(conn)
		b.conn = nil
		return false, ewhy
	}
	b.on = true
	debugf(b, "registered with the accessibility registry as %s", dbus.unique_name_of(conn))
	return true, ""
}

// stop drops the connection; the desktop sees us go.
stop :: proc(b: ^Bridge) {
	if b.conn == nil do return
	dbus.serve(b.conn, nil, nil)
	dbus.disconnect(b.conn)
	b.conn = nil
	b.on = false
	delete(b.desktop.name, b.allocator)
	delete(b.desktop.path, b.allocator)
	b.desktop = {}
}

// fd is the bridge's socket, to poll alongside the toolkit's own (-1 when
// the bridge is off).
fd :: proc(b: ^Bridge) -> linux.Fd {
	if b.conn == nil do return linux.Fd(-1)
	return dbus.fd(b.conn)
}

// pump answers whatever has arrived. Call it when `fd` polls readable, and
// once a wake-up regardless — it never blocks.
pump :: proc(b: ^Bridge) {
	if b.conn == nil do return
	_, err := dbus.dispatch(b.conn)
	if err == .Disconnected {
		debugf(b, "the accessibility bus went away")
		stop(b)
	}
}

// bus_address asks the session bus where the accessibility bus is. The
// environment wins when it says (AT_SPI_BUS_ADDRESS), as it does inside a
// test harness.
@(private)
bus_address :: proc(b: ^Bridge, allocator := context.allocator) -> (string, bool) {
	if env := os.get_env("AT_SPI_BUS_ADDRESS", context.temp_allocator); env != "" {
		return strings.clone(env, allocator), true
	}
	session, err := dbus.connect_session(context.temp_allocator)
	if err != .None {
		debugf(b, "no session bus: %v", err)
		return "", false
	}
	defer dbus.disconnect(session)
	call := dbus.method_call("org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus", "GetAddress")
	reply, cerr := dbus.call(session, &call, 2000, context.temp_allocator)
	if cerr != .None {
		debugf(b, "org.a11y.Bus.GetAddress: %v (%s)", cerr, dbus.error_text(&reply))
		return "", false
	}
	if len(reply.body) != 1 {
		debugf(b, "org.a11y.Bus.GetAddress answered %d values", len(reply.body))
		return "", false
	}
	addr, is_str := reply.body[0].(string)
	if !is_str || len(addr) == 0 {
		debugf(b, "org.a11y.Bus.GetAddress answered %v", reply.body[0])
		return "", false
	}
	return strings.clone(addr, allocator), true
}

// embed hands the registry a reference to our root object and keeps the
// desktop object it hands back, which is our root's parent.
@(private)
embed :: proc(b: ^Bridge) -> (ok: bool, why: string) {
	body := make([]dbus.Value, 1, context.temp_allocator)
	body[0] = obj_ref(dbus.unique_name_of(b.conn), ROOT_PATH)
	call := dbus.method_call(REGISTRY_NAME, ROOT_PATH, IFACE_SOCKET, "Embed", body)
	reply, err := dbus.call(b.conn, &call, 2000, context.temp_allocator)
	if err != .None do return false, fmt.tprintf("the registry would not embed us: %v", err)
	if len(reply.body) == 1 {
		if s, is_struct := reply.body[0].(dbus.Struct); is_struct && len(s.fields) == 2 {
			name, _ := s.fields[0].(string)
			path, _ := s.fields[1].(dbus.Object_Path)
			b.desktop.name = strings.clone(name, b.allocator)
			b.desktop.path = strings.clone(path.path, b.allocator)
		}
	}
	return true, ""
}

// debug_note is debugf for the toolkit side of the bridge: a line under
// BALDR_A11Y_DEBUG, nothing otherwise.
debug_note :: proc(b: ^Bridge, format: string, args: ..any) {
	debugf(b, format, ..args)
}

@(private)
debugf :: proc(b: ^Bridge, format: string, args: ..any) {
	if !b.debug do return
	fmt.eprintf("baldr/a11y: ")
	fmt.eprintfln(format, ..args)
}

// ------------------------------------------------------------------ serving

// on_call answers one method call. Anything we do not know about is left to
// the connection, which says UnknownMethod.
@(private)
on_call :: proc(conn: ^dbus.Connection, call: ^dbus.Message, user: rawptr) -> bool {
	b := (^Bridge)(user)
	id, ours := id_of(call.path)
	debugf(b, "%s.%s on %s", call.interface, call.member, call.path)
	if call.path == CACHE_PATH { // the whole tree in one call, asked for at the door
		if call.interface == IFACE_CACHE do return cache(b, call)
		return false
	}
	if !ours do return false
	switch call.interface {
	case IFACE_PROPERTIES:  return properties(b, call, id)
	case IFACE_ACCESSIBLE:  return accessible(b, call, id)
	case IFACE_COMPONENT:   return component(b, call, id)
	case IFACE_APPLICATION: return application(b, call, id)
	case IFACE_TEXT:        return text_iface(b, call, id)
	case IFACE_VALUE:       return value_iface(b, call, id)
	case IFACE_ACTION:      return action_iface(b, call, id)
	case IFACE_SELECTION:   return selection_iface(b, call, id)
	case IFACE_INTROSPECT:
		if call.member != "Introspect" do return false
		dbus.reply(conn, call, {introspect_xml(id, node_of(b, id))})
		return true
	}
	return false
}

// node_of reads an object out of the provider; a gone id comes back defunct
// rather than as an error, which is what a reader expects of an object that
// has been taken away under it.
@(private)
node_of :: proc(b: ^Bridge, id: u64) -> Node {
	if b.provider.node != nil {
		if n, have := b.provider.node(b.provider.user, id); have {
			// The wire takes only UTF-8, and one bad byte would lose the whole reply.
			if !utf8.valid_string(n.name) {
				debugf(b, "node %d's name is not UTF-8: %v", id, transmute([]u8)n.name)
				n.name = strings.to_valid_utf8(n.name, "\uFFFD", context.temp_allocator)
			}
			if !utf8.valid_string(n.describe) do n.describe = strings.to_valid_utf8(n.describe, "\uFFFD", context.temp_allocator)
			// …and no NUL, which ends a string there: what the app built is no name at all.
			if strings.index_byte(n.name, 0) >= 0 do n.name, _ = strings.replace_all(n.name, "\x00", "", context.temp_allocator)
			if strings.index_byte(n.describe, 0) >= 0 do n.describe, _ = strings.replace_all(n.describe, "\x00", "", context.temp_allocator)
			return n
		}
	}
	return Node{id = id, role = .Invalid, states = {.Defunct}, index = -1}
}

// obj_ref is the `(so)` pair — bus name and object path — that AT-SPI uses
// wherever it points at an object.
@(private)
obj_ref :: proc(name, path: string) -> dbus.Value {
	f := make([]dbus.Value, 2, context.temp_allocator)
	f[0] = name
	f[1] = dbus.Object_Path{path}
	return dbus.Struct{fields = f}
}

@(private)
ref :: proc(b: ^Bridge, id: u64) -> dbus.Value {
	return obj_ref(dbus.unique_name_of(b.conn), path_of(id))
}

// null_ref is what an object with no parent (or no such child) answers with.
@(private)
null_ref :: proc(b: ^Bridge) -> dbus.Value {
	return obj_ref(dbus.unique_name_of(b.conn), NULL_PATH)
}

@(private)
parent_ref :: proc(b: ^Bridge, id: u64, n: Node) -> dbus.Value {
	if id == APP_ID { // the application's parent is the desktop, if it told us
		if b.desktop.name != "" do return obj_ref(b.desktop.name, b.desktop.path)
		return null_ref(b)
	}
	return ref(b, n.parent)
}

// state_words is AT-SPI's two-word state set: states 0-31 in the first, the
// rest in the second.
@(private)
state_words :: proc(s: States) -> dbus.Value {
	lo, hi: u32
	for st in State do if st in s {
		v := u32(st)
		if v < 32 { lo |= 1 << v } else { hi |= 1 << (v - 32) }
	}
	items := make([]dbus.Value, 2, context.temp_allocator)
	items[0], items[1] = lo, hi
	return dbus.Array{sig = "u", items = items}
}

@(private)
interfaces_of :: proc(id: u64, n: Node) -> dbus.Value {
	items := make([dynamic]dbus.Value, context.temp_allocator)
	append(&items, IFACE_ACCESSIBLE, IFACE_COMPONENT)
	if id == APP_ID do append(&items, IFACE_APPLICATION)
	if n.has_text do append(&items, IFACE_TEXT)
	if n.has_value do append(&items, IFACE_VALUE)
	if n.has_action do append(&items, IFACE_ACTION)
	if n.has_selection do append(&items, IFACE_SELECTION)
	return dbus.Array{sig = "s", items = items[:]}
}

// accessible answers org.a11y.atspi.Accessible: the tree itself.
@(private)
accessible :: proc(b: ^Bridge, call: ^dbus.Message, id: u64) -> bool {
	n := node_of(b, id)
	switch call.member {
	case "GetRole":
		dbus.reply(b.conn, call, {u32(n.role)})
	case "GetRoleName":
		dbus.reply(b.conn, call, {role_name(n.role)})
	case "GetLocalizedRoleName":
		dbus.reply(b.conn, call, {role_name(n.role)}) // no translations of our own yet
	case "GetState":
		dbus.reply(b.conn, call, {state_words(n.states)})
	case "GetIndexInParent":
		dbus.reply(b.conn, call, {i32(n.index)})
	case "GetChildAtIndex":
		want := 0
		if len(call.body) == 1 {
			if v, is_i := call.body[0].(i32); is_i do want = int(v)
		}
		if b.provider.child != nil {
			if cid, have := b.provider.child(b.provider.user, id, want); have {
				dbus.reply(b.conn, call, {ref(b, cid)})
				return true
			}
		}
		dbus.reply(b.conn, call, {null_ref(b)})
	case "GetChildren":
		items := make([dynamic]dbus.Value, context.temp_allocator)
		if b.provider.child != nil {
			for i in 0 ..< n.child_count {
				cid, have := b.provider.child(b.provider.user, id, i)
				if !have do break
				append(&items, ref(b, cid))
			}
		}
		dbus.reply(b.conn, call, {dbus.Array{sig = "(so)", items = items[:]}})
	case "GetApplication":
		dbus.reply(b.conn, call, {ref(b, APP_ID)})
	case "GetInterfaces":
		dbus.reply(b.conn, call, {interfaces_of(id, n)})
	case "GetAttributes":
		dbus.reply(b.conn, call, {dbus.Dict{key_sig = "s", value_sig = "s"}})
	case "GetRelationSet":
		dbus.reply(b.conn, call, {dbus.Array{sig = "(ua(so))"}})
	case:
		return false
	}
	return true
}

// component answers org.a11y.atspi.Component: where an object is.
@(private)
component :: proc(b: ^Bridge, call: ^dbus.Message, id: u64) -> bool {
	n := node_of(b, id)
	// AT-SPI asks in screen (0), window (1) or parent (2) coordinates; the
	// call's last argument says which, and window is what we hold.
	coord := u32(0)
	if len(call.body) >= 1 {
		if c, is_u := call.body[len(call.body) - 1].(u32); is_u do coord = c
	}
	e := n.extents
	switch coord {
	case 0: // the screen, when the desktop told us where the window is
		if n.origin_known {
			e[0] += n.origin[0]
			e[1] += n.origin[1]
		}
	case 2: // its parent, which we hold in the same window coordinates
		if id != APP_ID {
			p := node_of(b, n.parent)
			e[0] -= p.extents[0]
			e[1] -= p.extents[1]
		}
	}
	switch call.member {
	case "GetExtents":
		f := make([]dbus.Value, 4, context.temp_allocator)
		f[0], f[1], f[2], f[3] = e[0], e[1], e[2], e[3]
		dbus.reply(b.conn, call, {dbus.Struct{fields = f}})
	case "GetPosition":
		dbus.reply(b.conn, call, {e[0], e[1]})
	case "GetSize":
		dbus.reply(b.conn, call, {e[2], e[3]})
	case "GetLayer":
		dbus.reply(b.conn, call, {u32(3)}) // ATSPI_LAYER_WIDGET
	case "GetMDIZOrder":
		dbus.reply(b.conn, call, {i16(0)})
	case "GetAlpha":
		dbus.reply(b.conn, call, {f64(1)})
	case "Contains":
		x, y: i32
		if len(call.body) >= 2 {
			x, _ = call.body[0].(i32)
			y, _ = call.body[1].(i32)
		}
		inside := x >= e[0] && y >= e[1] && x < e[0] + e[2] && y < e[1] + e[3]
		dbus.reply(b.conn, call, {inside})
	case "GetAccessibleAtPoint":
		dbus.reply(b.conn, call, {null_ref(b)}) // no hit test through the provider: nothing found
	case "GrabFocus":
		// a reader handing someone what they picked out of the tree
		ok := b.provider.grab_focus != nil && b.provider.grab_focus(b.provider.user, id)
		dbus.reply(b.conn, call, {ok})
	case:
		return false
	}
	return true
}

// application answers org.a11y.atspi.Application: what we are.
@(private)
application :: proc(b: ^Bridge, call: ^dbus.Message, id: u64) -> bool {
	switch call.member {
	case "GetLocale":
		dbus.reply(b.conn, call, {os.get_env("LANG", context.temp_allocator)})
	case "RegisterEventListener", "DeregisterEventListener":
		dbus.reply(b.conn, call, nil)
	case:
		return false
	}
	return true
}

// properties answers org.freedesktop.DBus.Properties, which is how a reader
// asks for most of what it wants.
@(private)
properties :: proc(b: ^Bridge, call: ^dbus.Message, id: u64) -> bool {
	iface, name: string
	if len(call.body) >= 1 { iface, _ = call.body[0].(string) }
	if len(call.body) >= 2 { name, _ = call.body[1].(string) }
	switch call.member {
	case "Get":
		v, have := property(b, id, iface, name)
		if !have {
			dbus.reply_error(b.conn, call, "org.freedesktop.DBus.Error.InvalidArgs", fmt.tprintf("no property %q on %q", name, iface))
			return true
		}
		if err := dbus.reply(b.conn, call, {dbus.variant(v, context.temp_allocator)}); err != .None do debugf(b, "the reply to Get %s.%s on %d could not be sent: %v", iface, name, id, err)
	case "GetAll":
		entries := make([dynamic]dbus.Dict_Entry, context.temp_allocator)
		for prop in properties_of(iface) {
			if v, have := property(b, id, iface, prop); have {
				append(&entries, dbus.Dict_Entry{key = prop, value = dbus.variant(v, context.temp_allocator)})
			}
		}
		dbus.reply(b.conn, call, {dbus.Dict{key_sig = "s", value_sig = "v", entries = entries[:]}})
	case "Set":
		// The registry hands every application its id this way, right after
		// Embed; nothing else of ours is writable.
		if iface == IFACE_APPLICATION && name == "Id" && len(call.body) >= 3 {
			if v, is_i := dbus.as_i32(call.body[2]); is_i {
				b.app_id = v
				debugf(b, "the registry gave us application id %d", v)
			}
		}
		dbus.reply(b.conn, call, nil)
	case:
		return false
	}
	return true
}

@(private)
ACCESSIBLE_PROPS := [?]string{"Name", "Description", "Parent", "ChildCount", "Locale", "AccessibleId"}

@(private)
APPLICATION_PROPS := [?]string{"ToolkitName", "Version", "AtspiVersion", "Id"}

@(private)
TEXT_PROPS := [?]string{"CharacterCount", "CaretOffset"}

@(private)
VALUE_PROPS := [?]string{"MinimumValue", "MaximumValue", "CurrentValue", "MinimumIncrement", "Text"}

@(private)
properties_of :: proc(iface: string) -> []string {
	switch iface {
	case IFACE_ACCESSIBLE:  return ACCESSIBLE_PROPS[:]
	case IFACE_APPLICATION: return APPLICATION_PROPS[:]
	case IFACE_TEXT:        return TEXT_PROPS[:]
	case IFACE_VALUE:       return VALUE_PROPS[:]
	}
	return nil
}

@(private)
property :: proc(b: ^Bridge, id: u64, iface, name: string) -> (dbus.Value, bool) {
	switch iface {
	case IFACE_ACCESSIBLE:
		n := node_of(b, id)
		switch name {
		case "Name":
			if id == APP_ID && b.provider.app_name != nil do return b.provider.app_name(b.provider.user), true
			return n.name, true
		case "Description":   return n.describe, true
		case "Parent":        return parent_ref(b, id, n), true
		case "ChildCount":    return i32(n.child_count), true
		case "Locale":        return os.get_env("LANG", context.temp_allocator), true
		case "AccessibleId":  return "", true
		}
	case IFACE_APPLICATION:
		switch name {
		case "ToolkitName":
			if b.provider.toolkit_name != nil do return b.provider.toolkit_name(b.provider.user), true
			return "Baldr", true
		case "Version":
			if b.provider.version != nil do return b.provider.version(b.provider.user), true
			return "", true
		case "AtspiVersion": return ATSPI_VERSION, true
		case "Id":           return b.app_id, true
		}
	case IFACE_TEXT:
		info, have := text_of(b, id)
		if !have do return nil, false
		switch name {
		case "CharacterCount": return i32(runes_len(info.text)), true
		case "CaretOffset":    return i32(char_at(info.text, info.caret)) if info.caret >= 0 else i32(0), true
		}
	case IFACE_VALUE:
		n := node_of(b, id)
		if !n.has_value do return nil, false
		switch name {
		case "CurrentValue":     return n.value, true
		case "MinimumValue":     return n.value_min, true
		case "MaximumValue":     return n.value_max, true
		case "MinimumIncrement": return n.value_step, true
		case "Text":             return n.value_text, true // AT-SPI 2.46: what a reader says instead of the number
		}
	}
	return nil, false
}

// introspect_xml is the little that Introspectable needs to say: enough for
// a tool to see which interfaces an object has.
@(private)
introspect_xml :: proc(id: u64, n: Node) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">` + "\n<node>\n")
	for iface in ([]string{IFACE_ACCESSIBLE, IFACE_COMPONENT, IFACE_PROPERTIES, IFACE_INTROSPECT}) {
		fmt.sbprintf(&b, "  <interface name=%q/>\n", iface)
	}
	if id == APP_ID do fmt.sbprintf(&b, "  <interface name=%q/>\n", IFACE_APPLICATION)
	if n.has_text do fmt.sbprintf(&b, "  <interface name=%q/>\n", IFACE_TEXT)
	if n.has_value do fmt.sbprintf(&b, "  <interface name=%q/>\n", IFACE_VALUE)
	if n.has_action do fmt.sbprintf(&b, "  <interface name=%q/>\n", IFACE_ACTION)
	if n.has_selection do fmt.sbprintf(&b, "  <interface name=%q/>\n", IFACE_SELECTION)
	strings.write_string(&b, "</node>\n")
	return strings.to_string(b)
}

// role_name is AT-SPI's own spelling of a role ("push button", "entry"),
// which readers show and match on.
@(private)
role_name :: proc(r: Role) -> string {
	switch r {
	case .Invalid:        return "invalid"
	case .Calendar:       return "calendar"
	case .Canvas:         return "canvas"
	case .Check_Box:      return "check box"
	case .Check_Menu_Item: return "check menu item"
	case .Color_Chooser:  return "color chooser"
	case .Combo_Box:      return "combo box"
	case .Date_Editor:    return "date editor"
	case .Dialog:         return "dialog"
	case .Filler:         return "filler"
	case .Frame:          return "frame"
	case .Icon:           return "icon"
	case .Image:          return "image"
	case .Label:          return "label"
	case .List:           return "list"
	case .List_Item:      return "list item"
	case .Menu:           return "menu"
	case .Menu_Bar:       return "menu bar"
	case .Menu_Item:      return "menu item"
	case .Page_Tab:       return "page tab"
	case .Page_Tab_List:  return "page tab list"
	case .Panel:          return "panel"
	case .Password_Text:  return "password text"
	case .Progress_Bar:   return "progress bar"
	case .Button:         return "push button"
	case .Radio_Button:   return "radio button"
	case .Radio_Menu_Item: return "radio menu item"
	case .Scroll_Bar:     return "scroll bar"
	case .Scroll_Pane:    return "scroll pane"
	case .Separator:      return "separator"
	case .Slider:         return "slider"
	case .Spin_Button:    return "spin button"
	case .Split_Pane:     return "split pane"
	case .Status_Bar:     return "status bar"
	case .Table:          return "table"
	case .Table_Cell:     return "table cell"
	case .Table_Column_Header: return "table column header"
	case .Terminal:       return "terminal"
	case .Text:           return "text"
	case .Toggle_Button:  return "toggle button"
	case .Tool_Bar:       return "tool bar"
	case .Tool_Tip:       return "tool tip"
	case .Tree:           return "tree"
	case .Viewport:       return "viewport"
	case .Window:         return "window"
	case .Application:    return "application"
	case .Entry:          return "entry"
	case .Heading:        return "heading"
	case .Link:           return "link"
	case .Table_Row:      return "table row"
	case .Tree_Item:      return "tree item"
	case .Document_Text:  return "document text"
	case .Grouping:       return "grouping"
	case .Notification:   return "notification"
	case .Static:         return "static"
	}
	return "unknown"
}
