package baldr

// Applet slots: the bar's side of the rikkiti-applet-v1 protocol.
//
// The protocol is one compositor's own (with rikkiti-backdrop-v1, the only
// such one in the toolkit; docs/widgets.md, "What the desktop has to
// support"). The API over it is not: a desktop that cannot embed applets
// gives an empty box that reports nothing rather than an error.
//
// A bar lists other programs' applets among its own; for each it builds an
// `applet_slot`, a node that takes part in layout like a box and draws
// nothing. After each layout the runtime keeps a slot on the bar's layer
// surface in step with the node: made when it first has a place, moved
// with the bar's next commit when it moves or the bar changes edge, and
// removed with the node. The compositor shows the applet's own surface
// there, on the bar's glass. The app hears the slot's token (to start the
// applet with, in RIKKITI_APPLET_TOKEN), when an applet attaches or
// detaches (a new token follows), and the length it would like, which the
// next build can give it. A `key` keeps one slot per applet across
// rebuilds, so a rebuild never restarts an applet.

import "baldr:platform"

// Slot_Event is what an applet slot reports, each carrying the slot's `key`.
Slot_Event :: union { Slot_Token, Slot_Attached, Slot_Detached, Slot_Size_Hint }

// Slot_Token: start the slot's applet with `token` (in RIKKITI_APPLET_TOKEN).
// The string lives only while the message is handled — clone it to keep it.
Slot_Token :: struct {
	key:   u64,
	token: string,
}

// Slot_Attached: an applet bound the slot; `pid` is its process (0 when unknown).
Slot_Attached :: struct {
	key: u64,
	pid: u32,
}

// Slot_Detached: the slot's applet went (it exited or crashed); a new
// token follows, to start another.
Slot_Detached :: struct {
	key: u64,
}

// Slot_Size_Hint: the length along the bar the applet can't go below and
// the one it would like, in logical px (0 = no preference).
Slot_Size_Hint :: struct {
	key:       u64,
	min:       f32,
	preferred: f32,
}

// applet_slot reserves a place in a bar for another program's applet: a
// node `preferred` long along the bar, shrinking to `min` in a tight row
// (the bar's edge decides which way is along), as thick as the bar across,
// that draws nothing, since the applet's own surface shows there. `on_event`
// hears the slot's Slot_Token, Slot_Attached, Slot_Detached and
// Slot_Size_Hint, each carrying `key`, which also keeps one slot per applet
// across rebuilds. `label` names the place for assistive technology (the
// applet's controls belong to its own program). Where the desktop can't
// embed applets (Caps .Applet_Slots) it is an empty box and reports nothing.
applet_slot :: proc(ui: ^Ui($Msg), on_event: Handler(Msg, Slot_Event), min: f32, preferred: f32, label := "",
	key: u64 = 0, loc := #caller_location) -> Node {
	n, created := reconcile_child(ui, .Custom, key, loc)
	t := &ui.tree
	if created do node_get(t, n).kind = Custom_Kind{measure = slot_measure} // draws nothing; as thick as its row allows
	along_x := true
	if e, on_edge := ui.surface.edge.?; on_edge do along_x = e == .Top || e == .Bottom
	props: Layout_Props
	if along_x {
		props.width, props.min_w = preferred, min
	} else {
		props.height, props.min_h = preferred, min
	}
	set_layout(t, n, props)
	d := node_get(t, n)
	d.access.role = .Group if label != "" else .None
	set_name(t, n, label)
	ui.slots[n] = Slot_Use(Msg){on_event = on_event, key = key}
	if n not_in t.slot_places do t.slot_places[n] = {}
	return n
}

// slot_measure sizes a slot node: its length along the bar from its layout
// props, and across, all the thickness the row it sits in allows.
@(private)
slot_measure :: proc(t: ^Tree, n: Node, d: ^Node_Data, cc: Constraints) -> [2]f32 {
	size := [2]f32{d.layout.width, d.layout.height}
	for i in 0 ..< 2 do if size[i] <= 0 do size[i] = cc.max[i] if is_bounded(cc.max[i]) else cc.min[i]
	return constrain(cc, size)
}

// Slot_Use is what an applet_slot node was built with.
@(private)
Slot_Use :: struct($Msg: typeid) {
	on_event: Handler(Msg, Slot_Event),
	key:      u64,
}

// Slot_Place is where a slot node's platform slot is: made or not, and the
// rect and edge last sent.
@(private)
Slot_Place :: struct {
	slot:   platform.Slot,
	rect:   [4]f32,
	edge:   Edge,
	failed: bool, // the backend refused it: not asked again for this node
}

// slots_sync keeps the platform slots in step with the slot nodes after a
// layout: made for a node that has a place, moved when its rect or the
// bar's edge changed, removed for a node that is gone or hidden. Runs
// before the frame is presented, so a move lands with the bar's commit.
@(private)
slots_sync :: proc(fc: ^Frame_Ctx) {
	t := fc.tree
	if len(t.slot_places) == 0 do return
	b := fc.backend
	can := b != nil && .Applet_Slots in b.caps && b.slot_create != nil && b.slot_set_geometry != nil && b.slot_destroy != nil
	edge, on_edge := fc.host_edge.?
	if !on_edge do edge = .Top if fc.size.x >= fc.size.y else .Left
	gone := make([dynamic]Node, context.temp_allocator)
	for n, &place in t.slot_places {
		d := node_get(t, n)
		if d == nil || .Hidden in d.flags {
			if place.slot != 0 && can do b.slot_destroy(b, place.slot)
			place.slot = 0
			if d == nil do append(&gone, n)
			continue
		}
		if !can || d.abs.w < 1 || d.abs.h < 1 do continue // no place yet: the protocol has no empty slot
		rect := [4]f32{d.abs.x, d.abs.y, d.abs.w, d.abs.h}
		switch {
		case place.slot == 0 && !place.failed:
			s, ok := b.slot_create(b, fc.surface, rect, edge)
			if !ok {
				place.failed = true
				continue
			}
			place.slot, place.rect, place.edge = s, rect, edge
		case place.slot != 0 && (place.rect != rect || place.edge != edge):
			b.slot_set_geometry(b, place.slot, rect, edge)
			place.rect, place.edge = rect, edge
		}
	}
	for n in gone do delete_key(&t.slot_places, n)
}

// slots_reset forgets every platform slot of a tree whose surface was
// replaced (a bar moved to another screen): they are made again on the
// new surface.
@(private)
slots_reset :: proc(t: ^Tree) {
	for _, &place in t.slot_places do place = {}
}

// slot_node_of is the node a platform slot belongs to.
@(private)
slot_node_of :: proc(t: ^Tree, slot: platform.Slot) -> (Node, bool) {
	for n, place in t.slot_places do if place.slot == slot do return n, true
	return NODE_NONE, false
}

// slot_deliver turns a slot's report into the node's message.
@(private)
slot_deliver :: proc(ui: ^Ui($Msg), n: Node, e: platform.Ev_Slot) -> bool {
	use, ok := ui.slots[n]
	if !ok do return false
	ev: Slot_Event
	switch e.kind {
	case .Token:     ev = Slot_Token{key = use.key, token = e.token}
	case .Attached:  ev = Slot_Attached{key = use.key, pid = e.pid}
	case .Detached:  ev = Slot_Detached{key = use.key}
	case .Size_Hint: ev = Slot_Size_Hint{key = use.key, min = f32(e.least), preferred = f32(e.preferred)}
	}
	return handler_send(ui, use.on_event, ev, n)
}
