#+build linux
package baldr

// Putting the accessibility tree on the accessibility bus, so a screen
// reader can read a Baldr app on a Linux desktop.
//
// The thinnest of three layers: `sys/atspi` does the D-Bus protocol,
// `a11y_model.odin` decides what to say, and this says it in AT-SPI's own
// words (role numbers, state numbers, signals). Decisions about a widget
// belong in the model, where every platform shares them and the tests
// cover them.

import "baldr:sys/atspi"

// The bus connection is this file's own: the model knows that a platform
// has a bridge, not what one is made of.
@(private, thread_local)
atspi_bridge: atspi.Bridge

// atspi_bridge_start connects to the accessibility bus and registers with
// it. False (with a reason) when there is nothing to connect to, which is
// the ordinary case on a desktop with no assistive technology running.
// BALDR_A11Y=0 keeps it off; BALDR_A11Y_DEBUG=1 says what it does.
@(private)
atspi_bridge_start :: proc() -> (ok: bool, why: string) {
	provider := atspi.Provider{
		node         = atspi_node,
		child        = atspi_child,
		text         = atspi_text,
		do_action    = atspi_do_action,
		grab_focus   = atspi_grab_focus,
		set_caret    = atspi_set_caret,
		select_range = atspi_select_range,
		edit         = atspi_edit,
		clip         = atspi_clip,
		app_name     = proc(user: rawptr) -> string { return a11y.app_name },
		toolkit_name = proc(user: rawptr) -> string { return "Baldr" },
		version      = proc(user: rawptr) -> string { return VERSION },
	}
	return atspi.start(&atspi_bridge, provider)
}

@(private)
atspi_bridge_stop :: proc() {
	atspi.stop(&atspi_bridge)
}

// atspi_bridge_fd is the bus socket, for the backend's poll set (-1: none).
@(private)
atspi_bridge_fd :: proc() -> i32 { return i32(atspi.fd(&atspi_bridge)) }

// atspi_bridge_pump answers whatever the desktop asked while we were away.
// The bus can go away under us, so what the model believes is refreshed from
// what the connection now says.
@(private)
atspi_bridge_pump :: proc() {
	if !atspi_bridge.on do return
	atspi.pump(&atspi_bridge)
	a11y.live = atspi_bridge.on
}

@(private)
atspi_bridge_debug :: proc(format: string, args: ..any) {
	atspi.debug_note(&atspi_bridge, format, ..args)
}

// atspi_bridge_deliver puts one of the toolkit's decisions on the bus as the
// signal AT-SPI spells it with.
@(private)
atspi_bridge_deliver :: proc(said: A11y_Said) {
	b := &atspi_bridge
	switch s in said {
	case Said_Focus:
		// atspi.focus_moved sends the focused state *and* the older `focus:`
		// event, because some readers listen only for that one.
		atspi.focus_moved(b, s.id)
	case Said_Flag:
		atspi.state_changed(b, s.id, atspi_state(s.flag), s.on)
	case Said_Window:
		atspi.window_event(b, s.id, "Activate" if s.active else "Deactivate", s.title)
	case Said_Name:
		atspi.name_changed(b, s.id, s.name)
	case Said_Describe:
		atspi.describe_changed(b, s.id, s.describe)
	case Said_Value:
		atspi.value_changed(b, s.id, s.value)
	case Said_Caret:
		atspi.caret_moved(b, s.id, s.at)
	case Said_Text_Edit:
		atspi.text_changed(b, s.id, s.inserted, s.at, s.count, s.text)
	case Said_Text_Selection:
		atspi.text_selection_changed(b, s.id)
	case Said_Active_Item:
		atspi.active_descendant_changed(b, s.id, s.child, s.index)
	case Said_Selection:
		atspi.selection_changed(b, s.id)
	case Said_Children:
		atspi.children_changed(b, s.id, s.added, s.index, s.child)
	case Said_Announce:
		atspi.announce(b, s.id, s.text, s.assertive)
	}
}

// --------------------------------------------------------- answering the bus
//
// The bridge calls these with a `user` pointer it was given; the toolkit's
// own state is thread-local, so they ignore it and ask the model.

@(private)
atspi_node :: proc(user: rawptr, id: u64) -> (atspi.Node, bool) {
	obj, ok := a11y_obj(id)
	if !ok do return {}, false
	return atspi.Node{
		id            = obj.id,
		parent        = obj.parent,
		index         = obj.index,
		child_count   = obj.child_count,
		role          = atspi_role(obj.role),
		name          = obj.name,
		describe      = obj.describe,
		states        = atspi_states(obj.flags),
		extents       = obj.extents,
		origin        = obj.origin,
		origin_known  = obj.origin_known,
		has_value     = obj.has_value,
		value         = obj.value,
		value_min     = obj.value_min,
		value_max     = obj.value_max,
		value_step    = obj.value_step,
		value_text    = obj.value_text,
		has_text      = obj.has_text,
		editable      = obj.editable,
		has_action    = obj.has_action,
		has_selection = obj.has_selection,
	}, true
}

@(private)
atspi_child :: proc(user: rawptr, id: u64, index: int) -> (u64, bool) {
	return a11y_obj_child(id, index)
}

@(private)
atspi_text :: proc(user: rawptr, id: u64) -> (atspi.Text_Info, bool) {
	info, ok := a11y_obj_text(id)
	if !ok do return {}, false
	return atspi.Text_Info{
		text     = info.text,
		caret    = info.caret,
		sel_lo   = info.sel_lo,
		sel_hi   = info.sel_hi,
		editable = info.editable,
	}, true
}

@(private)
atspi_do_action :: proc(user: rawptr, id: u64) -> bool { return a11y_do_action(id) }

@(private)
atspi_grab_focus :: proc(user: rawptr, id: u64) -> bool { return a11y_grab_focus(id) }

@(private)
atspi_set_caret :: proc(user: rawptr, id: u64, byte_off: int) -> bool {
	return a11y_set_caret(id, byte_off)
}

@(private)
atspi_select_range :: proc(user: rawptr, id: u64, from, to: int) -> bool {
	return a11y_select_range(id, from, to)
}

@(private)
atspi_edit :: proc(user: rawptr, id: u64, from, to: int, text: string) -> bool {
	return a11y_edit(id, from, to, text)
}

@(private)
atspi_clip :: proc(user: rawptr, id: u64, act: atspi.Clip_Act) -> bool {
	clip: A11y_Clip
	switch act {
	case .Cut:   clip = .Cut
	case .Copy:  clip = .Copy
	case .Paste: clip = .Paste
	}
	return a11y_clip(id, clip)
}

// ------------------------------------------------------- AT-SPI's own words

// atspi_role is a role in AT-SPI's vocabulary. Where AT-SPI has no word for
// something the nearest one is used and the comment says what was lost.
@(private)
atspi_role :: proc(r: A11y_Role) -> atspi.Role {
	switch r {
	case .None:          return .Invalid
	case .Application:   return .Application
	case .Window:        return .Frame
	case .Panel:         return .Panel
	case .Group:         return .Grouping
	case .Static:        return .Static
	case .Heading:       return .Heading
	case .Label:         return .Label
	case .Image:         return .Image
	case .Button:        return .Button
	case .Toggle_Button: return .Toggle_Button
	case .Link:          return .Link
	case .Check_Box:     return .Check_Box
	case .Radio_Button:  return .Radio_Button
	case .Radio_Group:   return .Grouping // AT-SPI names no radio group; the members carry the relation
	case .Slider:        return .Slider
	case .Spin_Button:   return .Spin_Button
	case .Entry:         return .Entry
	case .Password:      return .Password_Text
	case .Document:      return .Text
	case .Combo_Box:     return .Combo_Box
	case .List:          return .List
	case .List_Item:     return .List_Item
	case .Table:         return .Table
	case .Row:           return .Table_Row
	case .Cell:          return .Table_Cell
	case .Column_Header: return .Table_Column_Header
	case .Tree:          return .Tree
	case .Tree_Item:     return .Tree_Item
	case .Tab_List:      return .Page_Tab_List
	case .Tab:           return .Page_Tab
	case .Menu_Bar:      return .Menu_Bar
	case .Menu:          return .Menu
	case .Menu_Item:     return .Menu_Item
	case .Check_Menu_Item: return .Check_Menu_Item
	case .Radio_Menu_Item: return .Radio_Menu_Item
	case .Dialog:        return .Dialog
	case .Alert:         return .Notification
	case .Status_Bar:    return .Status_Bar
	case .Progress_Bar:  return .Progress_Bar
	case .Tooltip:       return .Tool_Tip
	case .Separator:     return .Separator
	case .Scroll_Area:   return .Scroll_Pane
	case .Tool_Bar:      return .Tool_Bar
	case .Terminal:      return .Terminal
	}
	return .Panel
}

// atspi_state is one state flag in AT-SPI's numbering.
@(private)
atspi_state :: proc(f: A11y_Flag) -> atspi.State {
	switch f {
	case .Active:          return .Active
	case .Busy:            return .Busy
	case .Checkable:       return .Checkable
	case .Checked:         return .Checked
	case .Collapsed:       return .Collapsed
	case .Defunct:         return .Defunct
	case .Editable:        return .Editable
	case .Enabled:         return .Enabled
	case .Expandable:      return .Expandable
	case .Expanded:        return .Expanded
	case .Focusable:       return .Focusable
	case .Focused:         return .Focused
	case .Indeterminate:   return .Indeterminate
	case .Invalid_Entry:   return .Invalid_Entry
	case .Is_Default:      return .Is_Default
	case .Modal:           return .Modal
	case .Multi_Line:      return .Multi_Line
	case .Has_Popup:       return .Has_Popup
	case .Pressed:         return .Pressed
	case .Read_Only:       return .Read_Only
	case .Required:        return .Required
	case .Resizable:       return .Resizable
	case .Selectable_Text: return .Selectable_Text
	case .Selected:        return .Selected
	case .Sensitive:       return .Sensitive
	case .Showing:         return .Showing
	case .Single_Line:     return .Single_Line
	case .Visible:         return .Visible
	}
	return .Invalid_Entry // unreachable: every flag is named above
}

@(private)
atspi_states :: proc(flags: A11y_Flags) -> (out: atspi.States) {
	for f in A11y_Flag do if f in flags do out += {atspi_state(f)}
	return
}
