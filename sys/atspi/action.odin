#+build linux
package atspi

// org.a11y.atspi.Action and org.a11y.atspi.Selection: the interfaces that
// let a reader act rather than only read — press a button, or learn and
// choose which row of a list is selected.
//
// An object has one action (the press a pointer would give) or none. A
// selection can be read; choosing a child goes through that same press, and
// finer changes (adding, clearing) are refused, because what a pick means
// is the app's business.

import "baldr:dbus"

// action_iface answers org.a11y.atspi.Action.
@(private)
action_iface :: proc(b: ^Bridge, call: ^dbus.Message, id: u64) -> bool {
	n := node_of(b, id)
	count := i32(1) if n.has_action else i32(0)
	switch call.member {
	case "GetNActions":
		dbus.reply(b.conn, call, {count})
	case "GetName", "GetActionName":
		dbus.reply(b.conn, call, {ACTION_CLICK if n.has_action else ""})
	case "GetLocalizedName":
		dbus.reply(b.conn, call, {ACTION_CLICK if n.has_action else ""})
	case "GetDescription":
		dbus.reply(b.conn, call, {""})
	case "GetKeyBinding":
		dbus.reply(b.conn, call, {""}) // a window's shortcuts are not per-object here
	case "GetActions":
		items := make([dynamic]dbus.Value, context.temp_allocator)
		if n.has_action {
			f := make([]dbus.Value, 3, context.temp_allocator)
			f[0], f[1], f[2] = ACTION_CLICK, "", "" // name, description, key binding
			append(&items, dbus.Struct{fields = f})
		}
		dbus.reply(b.conn, call, {dbus.Array{sig = "(sss)", items = items[:]}})
	case "DoAction":
		dbus.reply(b.conn, call, {do_action(b, id)})
	case "DoActionName":
		want := ""
		if len(call.body) == 1 do want, _ = dbus.as_string(call.body[0])
		dbus.reply(b.conn, call, {do_action(b, id) if want == ACTION_CLICK else false})
	case:
		return false
	}
	return true
}

@(private)
do_action :: proc(b: ^Bridge, id: u64) -> bool {
	if b.provider.do_action == nil do return false
	return b.provider.do_action(b.provider.user, id)
}

// selection_iface answers org.a11y.atspi.Selection: which children of a
// list, tree or table are chosen, read from the children's own state.
// SelectChild activates the child; every other change is refused.
@(private)
selection_iface :: proc(b: ^Bridge, call: ^dbus.Message, id: u64) -> bool {
	switch call.member {
	case "GetNSelectedChildren":
		dbus.reply(b.conn, call, {i32(len(selected_of(b, id)))})
	case "GetSelectedChild":
		want := 0
		if len(call.body) == 1 {
			if v, is_i := dbus.as_i32(call.body[0]); is_i do want = int(v)
		}
		sel := selected_of(b, id)
		if want < 0 || want >= len(sel) {
			dbus.reply(b.conn, call, {null_ref(b)})
			return true
		}
		dbus.reply(b.conn, call, {ref(b, sel[want])})
	case "IsChildSelected":
		want := -1
		if len(call.body) == 1 {
			if v, is_i := dbus.as_i32(call.body[0]); is_i do want = int(v)
		}
		chosen := false
		if b.provider.child != nil && want >= 0 {
			if cid, have := b.provider.child(b.provider.user, id, want); have {
				chosen = .Selected in node_of(b, cid).states
			}
		}
		dbus.reply(b.conn, call, {chosen})
	case "SelectChild":
		// Routed through the activation a click uses, so whatever the app
		// means by a pick is what happens.
		want := -1
		if len(call.body) == 1 {
			if v, is_i := dbus.as_i32(call.body[0]); is_i do want = int(v)
		}
		done := false
		if want >= 0 && b.provider.child != nil && b.provider.do_action != nil {
			if cid, have := b.provider.child(b.provider.user, id, want); have {
				done = b.provider.do_action(b.provider.user, cid)
			}
		}
		dbus.reply(b.conn, call, {done})
	case "DeselectChild", "DeselectSelectedChild", "ClearSelection", "SelectAll":
		dbus.reply(b.conn, call, {false}) // no pointer equivalent: refused, not guessed at
	case:
		return false
	}
	return true
}

// selected_of collects the chosen children of `id`, in order.
@(private)
selected_of :: proc(b: ^Bridge, id: u64) -> []u64 {
	out := make([dynamic]u64, context.temp_allocator)
	if b.provider.child == nil do return out[:]
	n := node_of(b, id)
	for i in 0 ..< n.child_count {
		cid, have := b.provider.child(b.provider.user, id, i)
		if !have do break
		if .Selected in node_of(b, cid).states do append(&out, cid)
	}
	return out[:]
}
