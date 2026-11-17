#+build linux
package atspi

// The signals a screen reader listens to. Walking the tree tells a reader
// what an app *is*; these tell it what just happened — focus moved, the
// caret moved, the text or the value changed — which is how it follows an
// app instead of re-reading it.
//
// One shape carries them all: a signal from the object's own path, with
// (detail, detail1, detail2, any_data, properties). What each field means
// is per event, and the procedures below take care of it.

import "core:strings"
import "baldr:dbus"

// The interfaces events arrive on. AT-SPI sorts them by what kind of thing
// happened rather than by who it happened to.
IFACE_EV_OBJECT :: "org.a11y.atspi.Event.Object"
IFACE_EV_WINDOW :: "org.a11y.atspi.Event.Window"
IFACE_EV_FOCUS  :: "org.a11y.atspi.Event.Focus"

// event sends one. `any` is the event's payload, whatever it is for that
// event; the trailing properties dictionary is left empty.
@(private)
event :: proc(b: ^Bridge, id: u64, iface, member, detail: string, d1, d2: i32, any: dbus.Value, ref: u64 = 0) {
	if b == nil do return
	if b.watcher != nil {
		b.watcher(b.watch_user, Event_Sent{id = id, iface = iface, member = member, detail = detail,
			d1 = d1, d2 = d2, text = payload_text(any), ref = ref})
	}
	debugf(b, "event %s.%s %s (%d, %d) %s", iface, member, detail, d1, d2, payload_text(any))
	if !b.on || b.conn == nil do return
	body := make([]dbus.Value, 5, context.temp_allocator)
	body[0] = detail
	body[1] = d1
	body[2] = d2
	body[3] = dbus.variant(any, context.temp_allocator)
	body[4] = dbus.Dict{key_sig = "s", value_sig = "v"}
	dbus.emit(b.conn, path_of(id), iface, member, body)
}

// payload_text is an event's payload when it is a string, for the log and
// for anything watching what we send.
@(private)
payload_text :: proc(any: dbus.Value) -> string {
	s, is_string := any.(string)
	return s if is_string else ""
}

// state_changed says a state of `id` went on or off ("focused", "checked",
// …). A reader hears "checked" and says so.
state_changed :: proc(b: ^Bridge, id: u64, state: State, on: bool) {
	event(b, id, IFACE_EV_OBJECT, "StateChanged", state_name(state), i32(1) if on else i32(0), 0, i32(0))
}

// focus_moved says the keyboard focus arrived at `id`. Readers watch the
// state change; the older `focus:` event is sent too, as toolkits still do,
// because some readers only listen for that.
focus_moved :: proc(b: ^Bridge, id: u64) {
	state_changed(b, id, .Focused, true)
	event(b, id, IFACE_EV_FOCUS, "Focus", "", 0, 0, i32(0))
}

// window_event says a window was activated, deactivated, or something else
// in AT-SPI's window vocabulary ("Activate", "Deactivate", "Create",
// "Destroy", "Minimize", "Restore").
window_event :: proc(b: ^Bridge, id: u64, member: string, title: string = "") {
	event(b, id, IFACE_EV_WINDOW, member, "", 0, 0, strings.clone(title, context.temp_allocator))
}

// caret_moved says the caret in `id` is now at `offset` — in characters, as
// everything in the Text interface is. A reader reads from there.
caret_moved :: proc(b: ^Bridge, id: u64, offset: int) {
	event(b, id, IFACE_EV_OBJECT, "TextCaretMoved", "", i32(offset), 0, i32(0))
}

// text_changed says `count` characters were inserted at `at`, or deleted
// from there, carrying the text itself so a reader can echo it.
text_changed :: proc(b: ^Bridge, id: u64, inserted: bool, at, count: int, text: string) {
	event(b, id, IFACE_EV_OBJECT, "TextChanged", "insert" if inserted else "delete",
		i32(at), i32(count), strings.clone(text, context.temp_allocator))
}

// text_selection_changed says the text selection inside `id` changed.
text_selection_changed :: proc(b: ^Bridge, id: u64) {
	event(b, id, IFACE_EV_OBJECT, "TextSelectionChanged", "", 0, 0, i32(0))
}

// value_changed says a slider, spin button or progress bar is worth
// something else now.
value_changed :: proc(b: ^Bridge, id: u64, value: f64) {
	event(b, id, IFACE_EV_OBJECT, "PropertyChange", "accessible-value", 0, 0, value)
}

// name_changed and describe_changed say an object's name or description
// changed under the reader.
name_changed :: proc(b: ^Bridge, id: u64, name: string) {
	event(b, id, IFACE_EV_OBJECT, "PropertyChange", "accessible-name", 0, 0, strings.clone(name, context.temp_allocator))
}

describe_changed :: proc(b: ^Bridge, id: u64, describe: string) {
	event(b, id, IFACE_EV_OBJECT, "PropertyChange", "accessible-description", 0, 0, strings.clone(describe, context.temp_allocator))
}

// active_descendant_changed says the item the cursor is on inside `id` is
// now `child`. A view that keeps the focus itself (a list, a grid, a tree)
// has no other way to say which row is current: focus never moves, so a
// reader following the keyboard would hear nothing.
active_descendant_changed :: proc(b: ^Bridge, id: u64, child: u64, index: int) {
	event(b, id, IFACE_EV_OBJECT, "ActiveDescendantChanged", "", i32(index), 0,
		obj_ref(dbus.unique_name_of(b.conn), path_of(child)), ref = child)
}

// selection_changed says what is selected inside `id` changed — another row
// picked, a Ctrl+A, a band drawn over half a grid.
selection_changed :: proc(b: ^Bridge, id: u64) {
	event(b, id, IFACE_EV_OBJECT, "SelectionChanged", "", 0, 0, i32(0))
}

// announce says something a reader should say out loud although nothing
// took focus — a copy that started, a file that finished, an error that
// appeared somewhere else on the screen. `assertive` interrupts what is
// being spoken; polite waits its turn.
announce :: proc(b: ^Bridge, id: u64, text: string, assertive: bool) {
	event(b, id, IFACE_EV_OBJECT, "Announcement", "", i32(2) if assertive else i32(1), 0,
		strings.clone(text, context.temp_allocator))
}

// children_changed says a child arrived at or left index `index` of `id`.
children_changed :: proc(b: ^Bridge, id: u64, added: bool, index: int, child: u64) {
	event(b, id, IFACE_EV_OBJECT, "ChildrenChanged", "add" if added else "remove",
		i32(index), 0, obj_ref(dbus.unique_name_of(b.conn), path_of(child)), ref = child)
}

// state_name is AT-SPI's spelling of a state in an event's detail field.
@(private)
state_name :: proc(s: State) -> string {
	switch s {
	case .Active:        return "active"
	case .Armed:         return "armed"
	case .Busy:          return "busy"
	case .Checked:       return "checked"
	case .Collapsed:     return "collapsed"
	case .Defunct:       return "defunct"
	case .Editable:      return "editable"
	case .Enabled:       return "enabled"
	case .Expandable:    return "expandable"
	case .Expanded:      return "expanded"
	case .Focusable:     return "focusable"
	case .Focused:       return "focused"
	case .Has_Tooltip:   return "has-tooltip"
	case .Horizontal:    return "horizontal"
	case .Modal:         return "modal"
	case .Multi_Line:    return "multi-line"
	case .Multiselectable: return "multiselectable"
	case .Pressed:       return "pressed"
	case .Resizable:     return "resizable"
	case .Selectable:    return "selectable"
	case .Selected:      return "selected"
	case .Sensitive:     return "sensitive"
	case .Showing:       return "showing"
	case .Single_Line:   return "single-line"
	case .Vertical:      return "vertical"
	case .Visible:       return "visible"
	case .Indeterminate: return "indeterminate"
	case .Required:      return "required"
	case .Invalid_Entry: return "invalid-entry"
	case .Selectable_Text: return "selectable-text"
	case .Is_Default:    return "is-default"
	case .Checkable:     return "checkable"
	case .Has_Popup:     return "has-popup"
	case .Read_Only:     return "read-only"
	}
	return ""
}
