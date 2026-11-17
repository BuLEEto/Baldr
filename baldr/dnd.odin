package baldr

// Drag and drop inside a window. A node becomes a drag source with
// `draggable` (what it is, which one, how many when it stands for a
// selection); a node takes drops with `drop_target` (which kinds, at which
// positions). Press and move past a small threshold (or long-press and
// move on touch) to lift a ghost — the item itself, faded, with a count
// badge when it stands for a selection — that follows the pointer above
// everything and is transparent to hit testing; the target under the pointer shows a ring
// (On) or an insertion line (Before / After); release sends on_drop with
// a Drop; Escape cancels; the pointer near a scroll region's edge scrolls
// it. Keyboard: with a draggable item focused (or under a tree's or
// table's cursor), Ctrl+X picks it up, move focus to a target, Ctrl+V
// drops On it (After when On is not allowed), Escape cancels; a Status
// node in the overlay announces each step.
//
//	chip := baldr.row(ui, …); …; baldr.end(ui)
//	baldr.draggable(ui, chip, "chip", tag = u64(i))
//	baldr.drop_target(ui, chip, proc(e: baldr.Ev(baldr.Drop)) -> Msg { return Reorder{from = e.value.tag, to = e.tag, before = e.value.position == .Before} },
//		accepts = "chip", positions = {.Before, .After})
//
// Across apps: a source with `files` (a proc giving the paths, asked once
// as the drag is picked up) is handed to the compositor as
// text/uri-list, so it can be dropped in a file manager or a terminal;
// another app's drag over the window is a drag of kind "files" that a
// `drop_target(accepts = "files")` receives with the paths in Drop.files.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "baldr:platform"

DRAG_THRESHOLD    :: f32(6)  // px of pointer travel before a press becomes a drag
DRAG_EDGE         :: f32(28) // px from a scroll region's edge that scrolls it while dragging
DRAG_SCROLL_STEP  :: f32(10) // px per tick near the edge
DRAG_GHOST_KEY    :: u64(0xD5A6_0000_0000_0001)
DRAG_GHOST_OFFSET :: [2]f32{14, 10} // the ghost sits just below-right of the pointer

// Drop_Position: where a drop lands relative to the target.
Drop_Position :: enum u8 { On, Before, After }
Drop_Positions :: bit_set[Drop_Position; u8]

// Drop is what on_drop receives: the source's kind / tag / count and where
// it landed. The handler's Ev.tag is the target's tag.
Drop :: struct {
	kind:       string,      // live only while the message is handled, as `files` is
	tag:        u64,
	count:      int,
	position:   Drop_Position,
	source:     Node,        // NODE_NONE for a drag from another app
	files:      []string,    // local paths: another app's files, or this source's own `files`; live only while the message is handled
	background: bool,        // landed on a table's or icon view's empty space (the folder it shows), not on an item; Ev.tag is then the view's
	action:     Drop_Action, // Ctrl copies, Shift moves, Alt (or Ctrl+Shift) asks, Default leaves it to the app; from another app, what was negotiated with it
	mods:       Mods,        // modifiers held at release (best effort for a drag from another app)
	// Where it was let go, from the target's own top-left, in the logical
	// pixels `pointer_samples` reports for that node (a keyboard drop gives
	// the target's own drop point). Carried in the message because
	// `Ui.context_pos` is shared and the next event may overwrite it first.
	at:         [2]f32,
}

// Drag_Over is a drag passing over a target that asked to hear about it:
// where it is, what it carries, and — with `left` — that it has gone.
//
// It lets a target show the drop before it happens: a timeline ghosting the
// clip where it would land, an icon view showing the cell, a list showing
// the line it would go in at.
Drag_Over :: struct {
	at:    [2]f32, // from the target's own top-left, as `Drop.at` is
	kind:  string, // live only while the message is handled
	tag:   u64,
	count: int,
	mods:  Mods,
	left:  bool,   // the drag has left the target; `at` is where it last was
}

// Drag_Rest is a drag that has stopped still on a node for DRAG_REST_MS:
// spring-loading, the way a folder opens or a taskbar button raises its
// window when a file is held over it without letting go. It is heard
// whether or not the node takes the drop, so it is asked for with
// `drag_rest` rather than as part of `drop_target`.
Drag_Rest :: struct {
	at:    [2]f32, // from the node's own top-left, as `Drop.at` is
	kind:  string, // live only while the message is handled
	tag:   u64,
	count: int,
	mods:  Mods,
}

// DRAG_REST_MS is how long a drag has to stand still on a node before the
// node hears it, and DRAG_REST_SLOP how far it may drift meanwhile and
// still count as standing still. 700 ms: long enough that crossing a folder
// on the way somewhere else does not open it, short enough that holding
// still reads as asking.
DRAG_REST_MS   :: f64(700)
DRAG_REST_SLOP :: f32(4)

// Drop_Action is what a drop should do with what it carries.
Drop_Action :: platform.Drag_Action

// drop_action_of_mods is the action the modifiers held at a drop ask for,
// the way file managers read them.
drop_action_of_mods :: proc "contextless" (mods: Mods) -> Drop_Action {
	switch {
	case .Alt in mods, .Ctrl in mods && .Shift in mods: return .Ask
	case .Ctrl in mods:  return .Copy
	case .Shift in mods: return .Move
	}
	return .Default
}

// Files_Of gives a drag source's files: the paths for `tag` (and `count`
// of them when a selection drags whole). It answers a drop inside the app
// and, unless the source also gives a `Files_Out` (dnd_files.odin), a drag
// that leaves the window as well.
//
// It is asked once, as the drag is picked up, and the answer is what the
// drag carries from then on: `tag` is usually a row number, and the view can
// change under a held drag (spring-loading opens a folder), so asking again
// at the drop would move the wrong file. Answer for `tag` and `count` as
// they are now.
Files_Of :: proc(user: rawptr, tag: u64, count: int, allocator: runtime.Allocator) -> []string

// Dnd_Hook is what the platform installs so a drag can cross app
// boundaries (zero in headless tests: drags stay inside the window).
Dnd_Hook :: struct {
	user:    rawptr,
	surface: u32, // the platform surface this tree is
	start:   proc(user: rawptr, surface: u32, items: []Clip_Item, serial: u32, icon: Drag_Icon) -> bool,
	accept:  proc(user: rawptr, accept: bool),
	receive: proc(user: rawptr, mime: string) -> bool, // ask for a drop's data in one form; drag_ext_data brings it
	finish:  proc(user: rawptr, accepted: bool),
}

// Drag_Source is one registered node (per view, like a click handler).
Drag_Source :: struct {
	kind:  string, // owned by the tree allocator
	tag:   u64,
	count: int,
	files: Files_Of, // the paths; nil (and no files_out) = the drag stays inside the window
	files_out: Files_Out, // the paths for a drag that *leaves*, made as it goes
	user:  rawptr,
}

@(private)
drag_source_destroy :: proc(t: ^Tree, ds: ^Drag_Source) {
	if len(ds.kind) > 0 do delete(ds.kind, t.allocator)
	ds.kind = ""
}

// Grid_Drag is a table's or icon view's drag setup: its rows / tiles are
// registered from it as they are built (see grid_row_dnd).
Grid_Drag :: struct {
	kind:    string, // owned; "" = rows are not draggable
	accepts: string, // owned; used when the view has an on_drop
	files:   Files_Of,
	files_out: Files_Out,
	user:    rawptr,
}

@(private)
grid_drag_destroy :: proc(t: ^Tree, gd: ^Grid_Drag) {
	if len(gd.kind) > 0 do delete(gd.kind, t.allocator)
	if len(gd.accepts) > 0 do delete(gd.accepts, t.allocator)
	gd.kind, gd.accepts = "", ""
}

@(private)
owned_set :: proc(t: ^Tree, dst: ^string, v: string) {
	if dst^ == v do return
	if len(dst^) > 0 do delete(dst^, t.allocator)
	dst^ = strings.clone(v, t.allocator)
}

// grid_drag_register stores a table's / icon view's drag setup (called by
// their builders); grid_row_dnd applies it to each row or tile.
@(private)
grid_drag_register :: proc(ui: ^Ui($Msg), view: Node, kind: string, on_drop: Handler(Msg, Drop), accepts: string, files: Files_Of = nil, user: rawptr = nil, files_out: Files_Out = nil) {
	t := &ui.tree
	if kind == "" && !handler_live(on_drop) {
		if gd, ok := &ui.grid_drags[view]; ok {
			grid_drag_destroy(t, gd)
			delete_key(&ui.grid_drags, view)
		}
		delete_key(&ui.on_drop, view)
		drop_target_forget(t, view)
		return
	}
	gd := &ui.grid_drags[view]
	if gd == nil {
		ui.grid_drags[view] = {}
		gd = &ui.grid_drags[view]
	}
	owned_set(t, &gd.kind, kind)
	owned_set(t, &gd.accepts, accepts)
	gd.files, gd.user, gd.files_out = files, user, files_out
	if handler_live(on_drop) {
		drop_target(ui, view, on_drop, accepts = accepts, positions = {.On}) // the view itself: its empty space drops into the folder it shows
	} else {
		delete_key(&ui.on_drop, view)
		drop_target_forget(t, view)
	}
}

// drop_target_bare marks `n` as somewhere a drag can be let go without an
// on_drop handler. A placed icon view uses it for its own items: their move
// is reported through `on_place`, and the view may take nothing else at all.
@(private)
drop_target_bare :: proc(ui: ^Ui($Msg), n: Node, accepts: string) {
	t := &ui.tree
	d := node_get(t, n)
	if d == nil do return
	d.flags += {.Drop_Target} // as drop_target: the ring is drawn outside the rect
	dt := &t.drops[n]
	if dt == nil {
		t.drops[n] = {}
		dt = &t.drops[n]
	}
	dt.positions = {.On}
	if dt.accepts != accepts {
		if len(dt.accepts) > 0 do delete(dt.accepts, t.allocator)
		dt.accepts = strings.clone(accepts, t.allocator)
	}
}

@(private)
drop_target_forget :: proc(t: ^Tree, n: Node) {
	if dt, ok := &t.drops[n]; ok {
		drop_target_destroy(t, dt)
		delete_key(&t.drops, n)
	}
}

// grid_row_dnd makes a row / tile a drag source of the view's kind (tag =
// its index; count = the selection's size when the row is part of it) and
// a drop target when the view has an on_drop (On: into that row).
@(private)
grid_row_dnd :: proc(ui: ^Ui($Msg), view, row: Node, index: int, sel: ^Selection) {
	gd, ok := ui.grid_drags[view]
	if !ok do return
	if gd.kind != "" {
		count := 1
		if sel != nil && selection_contains(sel, index) do count = max(selection_count(sel), 1)
		drag_register(ui, row, gd.kind, tag = u64(index), count = count, files = gd.files, user = gd.user, files_out = gd.files_out)
	}
	if h, has := ui.on_drop[view]; has do drop_target(ui, row, h, accepts = gd.accepts, positions = {.On})
	// Spring-loading on the rows the view builds for itself, which the app
	// has no node of its own to call `drag_rest` on. Heard for any kind,
	// unlike the drop: resting asks the row to get out of the way, not to
	// take what is carried, so the app decides per row.
	if h, has := ui.on_drag_rest[view]; has do drag_rest(ui, row, h)
}

// grid_rest_register records a view's `on_rest` without making the
// view itself a rest target: `rest_target_at` wants both the handler and
// a `t.rests` entry, and the view's own background opens nothing. Its
// rows pick the handler up in grid_row_dnd.
@(private)
grid_rest_register :: proc(ui: ^Ui($Msg), view: Node, on_rest: Handler(Msg, Drag_Rest)) {
	if handler_live(on_rest) { ui.on_drag_rest[view] = on_rest } else { delete_key(&ui.on_drag_rest, view) }
}

// Drop_Target lives in the tree so paint can read it without the message type.
Drop_Target :: struct {
	positions: Drop_Positions,
	accepts:   string, // owned; "" = any kind
}

Drag_State :: struct {
	over_told: Node, // the target last told where the drag is (drag_over_tell)
	source:   Node,
	kind:     string, // owned while a drag lasts
	name:     string, // owned: the source's accessible name, for the ghost
	icon:     Icon,
	// the desktop icon theme's icon, where the source draws one instead of
	// a Lucide icon: owned, and only read by the picture a drag carries out
	// of the window, since inside it the ghost mirrors the source itself
	theme_icon:     string,
	theme_icon_dir: string,
	// …or the picture the source itself shows (an `Image` neither icon
	// finder sees), carried out of the window as the drag's picture
	picture:     ^Image,
	picture_box: f32, // the side it is drawn at in the window, in logical px
	tag:      u64,
	count:    int,
	pending:  bool, // pressed on a draggable, waiting for the threshold
	active:   bool, // the ghost is up
	keyboard: bool, // picked up with Ctrl+X
	start:    [2]f32,
	pos:      [2]f32,
	target:   Node,
	position: Drop_Position,
	external:    bool,    // a drag the compositor carries over the window: another app's, or another of this app's windows' (no source node, no ghost of ours)
	compositor:  bool,    // ours, handed to the compositor as it left the window
	files:       Files_Of, // the source's paths, for Drop.files and for leaving the window
	// …resolved once, as the drag begins, and owned here: `tag` is a row
	// number and spring-loading changes the rows under the drag, so asking
	// again at the drop would move the wrong file.
	paths:       []string,
	files_out:   Files_Out, // …or these, when it has a different answer for leaving
	files_user:  rawptr,
	sibling:     bool,    // external, but another window of this app's drag: dropped as an in-app drag is (drag_sibling_enter)
	receiving:   bool,    // another app's, released: waiting for its data (drag_ext_data)
	drop_pos:    [2]f32,  // …where it was released, and how
	drop_action: Drop_Action,
	drop_mods:   Mods,
	// spring-loading: where the drag settled, when it will have stood still
	// long enough, and the node already told about it. `rest_due` is the
	// deadline, not the moment it settled, because 0 means "nothing armed"
	// and a clock can read 0 at the first instant of a run.
	rest_from:   [2]f32,
	rest_due:    f64,
	rested:      Node,
	rested_epoch: u32, // the build it was told in: a later one means what is under the drag has changed
	rest_done:   bool, // a node that acts once has acted: nothing more until the drag moves
	returning:   bool,    // cancelled: the ghost springs back to the source, then leaves
	return_from: [2]f32,
	return_to:   [2]f32,
	return_at:   f64,
	// live reorder preview: the source is relinked into the slot it would
	// land in, so its siblings part and it shows, faded, where it will go
	previewing:  bool,
	home_parent: Node, // where it came from, to glide back on cancel
	home_next:   Node,
	slot_target: Node, // the neighbour the previewed slot is named by, and which side:
	slot_position: Drop_Position, // a release over the faded source drops here
}

DRAG_RETURN_MS :: 220.0
DRAG_SOURCE_OPACITY :: f32(0.35) // the source while dragged: the faded "here it will land" copy

// draggable marks `n` (a node just built) as a drag source. `count` > 1
// says the drag stands for a selection (the ghost shows a badge). A
// free-standing source becomes a Tab stop (named by its first text when
// it has no name) so the keyboard path — Ctrl+X, move focus, Ctrl+V —
// can reach it; rows inside a tree, table or icon view stay under their
// view's single Tab stop (those register through drag_register).
// `on_drag_out` hears when a drag carrying `files` left the window and
// was dropped in another app: a Drop with the action that app took (a
// Move means the files are gone from here).
draggable :: proc(ui: ^Ui($Msg), n: Node, kind: string, tag: u64 = 0, count: int = 1, files: Files_Of = nil, user: rawptr = nil,
	on_drag_out: Handler(Msg, Drop) = nil, files_out: Files_Out = nil) {
	t := &ui.tree
	d := node_get(t, n)
	if d == nil do return
	d.flags += {.Focusable}
	if d.access.role == .None do d.access.role = .Generic
	if len(d.access.name) == 0 do set_name(t, n, node_label(t, n))
	drag_register(ui, n, kind, tag, count, files, user, files_out)
	if handler_live(on_drag_out) { ui.on_drag_out[n] = on_drag_out } else { delete_key(&ui.on_drag_out, n) }
}

// drag_register records the source without touching focus (rows of the
// one-Tab-stop views).
@(private)
drag_register :: proc(ui: ^Ui($Msg), n: Node, kind: string, tag: u64 = 0, count: int = 1, files: Files_Of = nil, user: rawptr = nil, files_out: Files_Out = nil) {
	t := &ui.tree
	if node_get(t, n) == nil do return
	ds := &ui.drags[n]
	if ds == nil {
		ui.drags[n] = {}
		ds = &ui.drags[n]
	}
	owned_set(t, &ds.kind, kind)
	ds.tag, ds.count = tag, max(count, 1)
	ds.files, ds.user, ds.files_out = files, user, files_out
}

// drop_target makes `n` accept drops of `accepts` kind ("" = any) at
// `positions`. on_drop receives a Drop; its Ev.tag is `n`'s tag (`tag`
// sets it here for nodes whose builder has none, such as a plain row).
// `on_over` hears where a drag is over this target as the pointer moves —
// not only when it arrives — and once more with `left` when it goes,
// however the drag ended, so a target can show the drop before it happens.
drop_target :: proc(ui: ^Ui($Msg), n: Node, on_drop: Handler(Msg, Drop), accepts: string = "", positions: Drop_Positions = {.On}, on_over: Handler(Msg, Drag_Over) = nil, tag: u64 = 0) {
	t := &ui.tree
	d := node_get(t, n)
	if d == nil do return
	if tag != 0 do d.tag = tag
	d.flags += {.Drop_Target} // its ring is drawn outside its rect: paint_bounds reserves the room
	dt := &t.drops[n]
	if dt == nil {
		t.drops[n] = {}
		dt = &t.drops[n]
	}
	if handler_live(on_over) { ui.on_drag_over[n] = on_over } else { delete_key(&ui.on_drag_over, n) }
	dt.positions = positions if positions != {} else {.On}
	if dt.accepts != accepts {
		if len(dt.accepts) > 0 do delete(dt.accepts, t.allocator)
		dt.accepts = strings.clone(accepts, t.allocator)
	}
	ui.on_drop[n] = on_drop
}

@(private)
drop_target_destroy :: proc(t: ^Tree, dt: ^Drop_Target) {
	if len(dt.accepts) > 0 do delete(dt.accepts, t.allocator)
	dt.accepts = ""
}

// Rest_Target lives in the tree so the rest timer can read it without the
// message type, as Drop_Target does.
Rest_Target :: struct {
	accepts: string, // owned; "" = any kind
	repeat:  bool,   // false: acting once is enough, and nothing more is heard until the drag moves
}

@(private)
rest_target_destroy :: proc(t: ^Tree, rt: ^Rest_Target) {
	if len(rt.accepts) > 0 do delete(rt.accepts, t.allocator)
	rt.accepts = ""
}

// drag_rest tells `n` when a drag stands still on it for DRAG_REST_MS —
// spring-loading. A file manager opens the folder rested on, a taskbar
// button raises its window, a sidebar place navigates to itself.
//
// Unlike `drop_target` this says nothing about taking a drop: a node that
// accepts nothing still hears a drag rest on it, since resting asks it to
// get out of the way. `accepts` is the drag kind it hears ("" = any).
//
// It fires once where the drag settles, and again only after the drag moves
// on or the handler puts something else under the pointer. Nothing is heard
// from a keyboard drag, after Escape, or while a cancelled drag springs
// back. When the handler changes what is under the pointer, the drop target
// is worked out again, so a drop lands in the folder that opened.
//
// `repeat = false` says acting once is enough: nothing else is heard until
// the drag moves again. That is for a node whose handler takes the drag
// somewhere else rather than further in — a path bar, which reflows and
// slides an ancestor under a still pointer, would otherwise climb the whole
// path. A folder row, whose contents appear under the pointer, wants the
// default.
drag_rest :: proc(ui: ^Ui($Msg), n: Node, on_rest: Handler(Msg, Drag_Rest), accepts: string = "", repeat := true) {
	t := &ui.tree
	if node_get(t, n) == nil do return
	rt := &t.rests[n]
	if rt == nil {
		t.rests[n] = {}
		rt = &t.rests[n]
	}
	if rt.accepts != accepts {
		rest_target_destroy(t, rt)
		if len(accepts) > 0 do rt.accepts = strings.clone(accepts, t.allocator)
	}
	rt.repeat = repeat
	if handler_live(on_rest) { ui.on_drag_rest[n] = on_rest } else { delete_key(&ui.on_drag_rest, n) }
}

// ---------------------------------------------------------------- pointer

// drag_press remembers a press on a drag source; the press itself goes on
// (a click still fires if the pointer never travels).
@(private)
drag_press :: proc(ui: ^Ui($Msg), target: Node, pos: [2]f32) {
	if ui.drag.returning do drag_end(ui) // a new press cuts the spring-back short
	if ui.drag.active && ui.drag.keyboard do drag_end(ui) // the pointer takes over from a keyboard carry
	if ui.drag.active do return
	src := drag_source_of(ui, target)
	if src == NODE_NONE do return
	ui.drag.pending = true
	ui.drag.source = src
	ui.drag.start = pos
	ui.drag.pos = pos
}

// drag_source_of climbs from `n` to the nearest registered drag source.
@(private)
drag_source_of :: proc(ui: ^Ui($Msg), n: Node) -> Node {
	for cur := n; cur != NODE_NONE; {
		if _, ok := ui.drags[cur]; ok do return cur
		d := node_get(&ui.tree, cur)
		if d == nil do break
		cur = d.parent
	}
	return NODE_NONE
}

// drag_pointer_move advances a pending or active drag. Returns true when
// something visible changed (and whether it consumed the move).
@(private)
drag_pointer_move :: proc(ui: ^Ui($Msg), pos: [2]f32) -> (consumed, changed: bool) {
	t := &ui.tree
	if ui.drag.pending {
		off := pos - ui.drag.start
		if abs(off.x) < DRAG_THRESHOLD && abs(off.y) < DRAG_THRESHOLD do return false, false
		ui.drag.pending = false
		if !drag_begin(ui, ui.drag.source, false) do return false, false
		// the press that started it will not click
		if p := node_get(t, ui.pointer.pressed); p != nil {
			p.flags -= {.Pressed}
			mark_paint_dirty(t, ui.pointer.pressed)
		}
		ui.pointer.pressed = NODE_NONE
		changed = true
	}
	if !ui.drag.active || ui.drag.keyboard || ui.drag.returning do return false, changed
	ui.drag.pos = pos
	drag_rest_moved(ui, pos)
	drag_move_ghost(ui)
	// Past the window's edge with files: the compositor takes the drag
	// (the implicit grab keeps pointer events coming here, so no leave
	// event marks the moment — the position does).
	vp := t.viewport
	if !ui.drag.compositor && ui.drag.files != nil && (pos.x < 0 || pos.y < 0 || (vp.x > 0 && pos.x > vp.x) || (vp.y > 0 && pos.y > vp.y)) {
		if drag_leave_window(ui) do return true, true
	}
	target, position := drop_target_at(ui, pos)
	drag_over_tell(ui, target, pos)
	drag_set_target(ui, target, position)
	return true, true
}

// drag_over_tell sends Drag_Over to the target under the pointer, every
// move — not only when the target changes, because a timeline ghosting a
// clip needs the position as it slides along one track, not just when it
// crosses to another. The target it has just left hears once with `left`.
@(private)
drag_over_tell :: proc(ui: ^Ui($Msg), target: Node, pos: [2]f32) {
	if was := ui.drag.over_told; was != NODE_NONE && was != target {
		if h, ok := ui.on_drag_over[was]; ok {
			handler_send(ui, h, Drag_Over{at = node_local(&ui.tree, was, pos), kind = ui.drag.kind,
				tag = ui.drag.tag, count = ui.drag.count, mods = ui.pointer.mods, left = true}, was)
		}
	}
	ui.drag.over_told = target
	if target == NODE_NONE do return
	if h, ok := ui.on_drag_over[target]; ok {
		handler_send(ui, h, Drag_Over{at = node_local(&ui.tree, target, pos), kind = ui.drag.kind,
			tag = ui.drag.tag, count = ui.drag.count, mods = ui.pointer.mods}, target)
	}
}

// drag_source_gone: the node a drag was lifted from has left the view.
//
// The drag goes on: what it carries was copied when it began. This is the
// ordinary case under spring-loading, where opening the folder a drag rests
// on navigates away from the dragged file's row.
//
// What goes with the node: the reorder preview, and the source's own
// picture, because the app may free an `Image` once nothing shows it (the
// ghost falls back to the icon and name, which are copies).
@(private)
drag_source_gone :: proc(ui: ^Ui($Msg)) {
	t := &ui.tree
	ui.drag.previewing = false
	ui.drag.source = NODE_NONE
	ui.drag.picture, ui.drag.picture_box = nil, 0
	t.drag_source = NODE_NONE
	if ui.drag.returning do drag_end(ui) // it was flying home to a place that is no longer there
}

// drag_begin lifts `src` into a drag. Returns false if it is not a source.
@(private)
drag_begin :: proc(ui: ^Ui($Msg), src: Node, keyboard: bool) -> bool {
	t := &ui.tree
	ds, ok := ui.drags[src]
	if !ok do return false
	d := node_get(t, src)
	if d == nil do return false
	drag_clear_strings(ui)
	ui.drag = {
		source = src, kind = strings.clone(ds.kind, t.allocator), tag = ds.tag, count = ds.count,
		name = strings.clone(node_label(t, src), t.allocator), icon = node_icon(t, src),
		active = true, keyboard = keyboard, start = ui.drag.start, pos = ui.drag.pos, target = NODE_NONE,
		files = ds.files, files_user = ds.user, files_out = ds.files_out,
	}
	if use, has := node_theme_icon(t, src); has {
		ui.drag.theme_icon = strings.clone(use.name, t.allocator)
		ui.drag.theme_icon_dir = strings.clone(use.dir, t.allocator)
		if ui.drag.icon == .None do ui.drag.icon = use.fallback
	}
	ui.drag.picture, ui.drag.picture_box = node_picture(t, src)
	// The paths, now, while the rows they are numbered against are still
	// the rows the user picked from.
	if ds.files != nil {
		src_paths := ds.files(ds.user, ds.tag, ds.count, context.temp_allocator)
		if len(src_paths) > 0 {
			out := make([]string, len(src_paths), t.allocator)
			for p, i in src_paths do out[i] = strings.clone(p, t.allocator)
			ui.drag.paths = out
		}
	}
	ui.drag_out = nil
	if h, has := ui.on_drag_out[src]; has {
		ui.drag_out = h
	} else if ref, is_row := ui.rows[src]; is_row {
		if hv, has_view := ui.on_drag_out[ref.table]; has_view do ui.drag_out = hv
	}
	if keyboard {
		ui.drag.pos = {d.abs.x + d.abs.w / 2, d.abs.y + d.abs.h / 2}
	}
	t.drag_source = src
	// A layer of its own while it is carried: the ghost draws the item
	// itself, faded, by inlining that layer.
	set_layer(t, src, true)
	mark_paint_dirty(t, src)
	ask_rebuild(ui) // the ghost and the announcement are built with the view
	return true
}

// ---------------------------------------------------------------- live reorder preview

// drag_preview_update relinks the source into the slot the current target
// names when that is a reorder among its own siblings (Before / After a
// node with the same parent): the siblings part to make room, the source
// shows faded there, and no insertion line is drawn. No target at all
// (the pointer is over the faded source itself, or a gap) keeps the last
// proposed slot — that is what gives the reorder its hysteresis: once a
// neighbour has slid aside it stays aside until the pointer crosses
// another. Anything else (a drop On, another container, a tree row whose
// branch would stay behind) keeps the line and puts the source back.
@(private)
drag_preview_update :: proc(ui: ^Ui($Msg)) {
	t := &ui.tree
	dr := &ui.drag
	sd := node_get(t, dr.source)
	if sd == nil do return
	if dr.target == NODE_NONE {
		if dr.previewing do t.drag_over = NODE_NONE
		return
	}
	want := false
	before := NODE_NONE
	if dr.active && dr.target != dr.source && dr.position != .On {
		td := node_get(t, dr.target)
		_, src_tree_row := t.tree_rows[dr.source]
		_, dst_tree_row := t.tree_rows[dr.target]
		if td != nil && td.parent == sd.parent && td.parent != NODE_NONE && !src_tree_row && !dst_tree_row {
			want = true
			before = dr.target if dr.position == .Before else td.next
		}
	}
	if !want {
		drag_preview_restore(ui)
		return
	}
	if !dr.previewing {
		dr.previewing = true
		dr.home_parent, dr.home_next = sd.parent, sd.next
	}
	dr.slot_target, dr.slot_position = dr.target, dr.position
	if before != dr.source && sd.next != before do node_insert_before(t, sd.parent, dr.source, before)
	t.drag_over = NODE_NONE // the gap is the feedback
}

// drag_preview_restore puts a previewed source back where it came from.
@(private)
drag_preview_restore :: proc(ui: ^Ui($Msg)) {
	t := &ui.tree
	dr := &ui.drag
	if !dr.previewing do return
	dr.previewing = false
	sd := node_get(t, dr.source)
	if sd == nil || node_get(t, dr.home_parent) == nil do return
	next := dr.home_next
	if nd := node_get(t, next); nd == nil || nd.parent != dr.home_parent do next = NODE_NONE
	if next != dr.source && sd.next != next || sd.parent != dr.home_parent do node_insert_before(t, dr.home_parent, dr.source, next)
}

// drag_preview_reapply runs after a rebuild: the reconciler has put the
// children back in the app's order, so the home slot is read afresh and
// the preview relinked. Over no target (the faded source itself) it is
// relinked into the slot it last proposed, so a rebuild mid-drag (a clock's
// tick) doesn't undo it; a slot whose node went away ends it.
@(private)
drag_preview_reapply :: proc(ui: ^Ui($Msg)) {
	dr := &ui.drag
	if !dr.previewing do return
	dr.previewing = false
	if dr.target != NODE_NONE {
		drag_preview_update(ui)
		return
	}
	target, position := dr.target, dr.position
	dr.target, dr.position = dr.slot_target, dr.slot_position
	drag_preview_update(ui)
	dr.target, dr.position = target, position
}

// node_label: the accessible name, else the first text inside (a plain
// row of a caption has no name of its own).
@(private)
node_label :: proc(t: ^Tree, n: Node) -> string {
	d := node_get(t, n)
	if d == nil do return ""
	if len(d.access.name) > 0 do return d.access.name
	if k, ok := d.kind.(Text_Kind); ok && len(k.str) > 0 do return k.str
	for c := d.first; c != NODE_NONE; c = node_get(t, c).next {
		if s := node_label(t, c); len(s) > 0 do return s
	}
	return ""
}

// node_icon finds the first icon in a node's subtree (the ghost shows it).
@(private)
node_icon :: proc(t: ^Tree, n: Node) -> Icon {
	d := node_get(t, n)
	if d == nil do return .None
	if k, ok := d.kind.(Custom_Kind); ok && k.paint == paint_icon && Icon(d.tag) != .None do return Icon(d.tag)
	for c := d.first; c != NODE_NONE; c = node_get(t, c).next {
		if ic := node_icon(t, c); ic != .None do return ic
	}
	return .None
}

// node_theme_icon finds the first desktop-theme icon in a node's subtree,
// the way node_icon finds a Lucide one: what the source draws, for the
// picture that leaves the window with it.
@(private)
node_theme_icon :: proc(t: ^Tree, n: Node) -> (use: Theme_Icon_Use, found: bool) {
	d := node_get(t, n)
	if d == nil do return {}, false
	if u, has := t.theme_icons[n]; has && u.name != "" do return u, true
	for c := d.first; c != NODE_NONE; c = node_get(t, c).next {
		if u, has := node_theme_icon(t, c); has do return u, true
	}
	return {}, false
}

// node_picture finds the first picture in a node's subtree and the side it
// is drawn at: an image node holds its `^Image` as its custom paint's
// user pointer. An `icon_item` with a `picture` draws this way, which
// neither node_icon nor node_theme_icon finds.
@(private)
node_picture :: proc(t: ^Tree, n: Node) -> (img: ^Image, box: f32) {
	d := node_get(t, n)
	if d == nil do return nil, 0
	if ck, ok := d.kind.(Custom_Kind); ok && ck.paint == paint_image && ck.user != nil {
		if p := (^Image)(ck.user); image_adds_up(p) do return p, min(d.abs.w, d.abs.h)
	}
	for c := d.first; c != NODE_NONE; c = node_get(t, c).next {
		if p, b := node_picture(t, c); p != nil do return p, b
	}
	return nil, 0
}

@(private)
drag_clear_strings :: proc(ui: ^Ui($Msg)) {
	t := &ui.tree
	if len(ui.drag.kind) > 0 do delete(ui.drag.kind, t.allocator)
	if len(ui.drag.name) > 0 do delete(ui.drag.name, t.allocator)
	if len(ui.drag.theme_icon) > 0 do delete(ui.drag.theme_icon, t.allocator)
	if len(ui.drag.theme_icon_dir) > 0 do delete(ui.drag.theme_icon_dir, t.allocator)
	for p in ui.drag.paths do delete(p, t.allocator)
	if ui.drag.paths != nil do delete(ui.drag.paths, t.allocator)
	ui.drag.paths = nil
	ui.drag.kind, ui.drag.name = "", ""
	ui.drag.theme_icon, ui.drag.theme_icon_dir = "", ""
}

// drop_target_at finds the drop target under `pos` that accepts the drag's
// kind, and where on it the drop would land.
@(private)
drop_target_at :: proc(ui: ^Ui($Msg), pos: [2]f32) -> (target: Node, position: Drop_Position) {
	t := &ui.tree
	for cur := hit_test(t, pos); cur != NODE_NONE; {
		if dt, ok := t.drops[cur]; ok && cur != ui.drag.source && (dt.accepts == "" || dt.accepts == ui.drag.kind) {
			// on_place makes a placed icon view a target for its own items
			// with no on_drop: moving an icon about is not a drop
			if _, has := ui.on_drop[cur]; has || icon_view_takes_place(ui, cur) {
				return cur, drop_position_in(node_get(t, cur).abs, pos, dt.positions, drop_flows_sideways(t, cur))
			}
		}
		d := node_get(t, cur)
		if d == nil do break
		cur = d.parent
	}
	return NODE_NONE, .On
}

// drop_flows_sideways: Before / After run along the target's parent's
// axis — left / right in a row or wrap, above / below in a column or a wrap
// running down.
drop_flows_sideways :: proc(t: ^Tree, n: Node) -> bool {
	d := node_get(t, n)
	if d == nil do return false
	p := node_get(t, d.parent)
	return p != nil && (p.layout.axis == .Row || p.layout.axis == .Wrap)
}

// drop_position_in: On in the middle, Before / After near the edges — the
// edge bands are halves when On is not allowed, quarters when it is.
@(private)
drop_position_in :: proc "contextless" (r: Rect, pos: [2]f32, allowed: Drop_Positions, sideways: bool) -> Drop_Position {
	if allowed == {.On} do return .On
	f := (pos.x - r.x) / max(r.w, 1) if sideways else (pos.y - r.y) / max(r.h, 1)
	edge := f32(0.5) if .On not_in allowed else 0.25
	if .Before in allowed && f < edge do return .Before
	if .After in allowed && f > 1 - edge do return .After
	if .On in allowed do return .On
	return .After if .After in allowed else .Before
}

@(private)
drag_set_target :: proc(ui: ^Ui($Msg), target: Node, position: Drop_Position) {
	t := &ui.tree
	if target == ui.drag.target && position == ui.drag.position do return
	if old := node_get(t, ui.drag.target); old != nil do mark_paint_dirty(t, ui.drag.target)
	ui.drag.target, ui.drag.position = target, position
	// Whatever is ringed keeps room for the ring from here on, including rows
	// a view registers for itself. Never taken off: the reserved band must be
	// there on the paint that takes the ring away as on the one that draws it.
	if nd := node_get(t, target); nd != nil do nd.flags += {.Drop_Target}
	// A drag that started inside the target does not ring it: the ring says
	// "this will take it", and a view cannot take what is already in it. The
	// drop still happens; only the feedback is quiet.
	inside := target != NODE_NONE && ui.drag.source != NODE_NONE && node_within(t, ui.drag.source, target)
	t.drag_over, t.drag_over_pos = NODE_NONE if inside else target, position
	if nd := node_get(t, target); nd != nil do mark_paint_dirty(t, target)
	drag_preview_update(ui)
}

// drag_release ends a pointer drag: a drop on the target, else a cancel.
// Returns true if it consumed the release.
@(private)
drag_release :: proc(ui: ^Ui($Msg), pos: [2]f32) -> bool {
	if ui.drag.pending {
		ui.drag.pending = false
		return false // never travelled: the press is a click
	}
	if !ui.drag.active || ui.drag.keyboard do return false
	if ui.drag.returning do return true
	target, position := drop_target_at(ui, pos)
	if target == NODE_NONE && ui.drag.previewing { // over the faded source or a gap: the previewed slot is the drop
		target, position = ui.drag.slot_target, ui.drag.slot_position
	}
	if target == NODE_NONE {
		drag_cancel(ui)
		return true
	}
	drag_drop(ui, target, position, ui.pointer.mods, drop_action_of_mods(ui.pointer.mods), pos)
	return true
}

// drop_point: where a drop without a pointer landed — on its target, a
// little in from the start (as the Menu key opens a row's menu).
@(private)
drop_point :: proc(t: ^Tree, target: Node) -> [2]f32 {
	d := node_get(t, target)
	if d == nil do return {}
	return {d.abs.x + min(d.abs.w / 2, 24), d.abs.y + d.abs.h / 2}
}

// node_local turns a point in the window into one from `n`'s own top-left,
// which is the frame an app thinks in: the same logical pixels
// `pointer_samples` reports for that node.
@(private)
node_local :: proc(t: ^Tree, n: Node, p: [2]f32) -> [2]f32 {
	d := node_get(t, n)
	if d == nil do return p
	return {p.x - d.abs.x, p.y - d.abs.y}
}

// drag_cancel lets the ghost spring back to where it was picked up, then
// ends the drag (instantly under reduce-motion or from the keyboard).
drag_cancel :: proc(ui: ^Ui($Msg)) -> bool {
	if !ui.drag.active do return drag_end(ui)
	t := &ui.tree
	sd := node_get(t, ui.drag.source)
	if ui.drag.keyboard || t.theme.motion.reduce || sd == nil do return drag_end(ui)
	drag_preview_restore(ui) // the source glides home; the spring follows it
	drag_set_target(ui, NODE_NONE, .On)
	ui.drag.returning = true
	ui.drag.return_from = ui.drag.pos
	ui.drag.return_to = [2]f32{sd.abs.x, sd.abs.y} - DRAG_GHOST_OFFSET
	ui.drag.return_at = t.now_ms
	tree_wake_at(t, t.now_ms + 16, ui.drag.source)
	return true
}

// drag_drop delivers on_drop (when there is a target) and ends the drag.
// The drop point (`at`, else the target's row for a keyboard drop) becomes
// Ui.context_pos, so a menu the drop asks for (Copy here / Move here) opens
// where it landed.
@(private)
drag_drop :: proc(ui: ^Ui($Msg), target: Node, position: Drop_Position, mods: Mods = {}, action: Drop_Action = .Default, at: Maybe([2]f32) = nil) {
	// A drag that began in a placed icon view and ended in the same one is a
	// move, not a drop: the items go to the cell under the pointer
	// (widget_icon_view.odin).
	if target != NODE_NONE && !ui.drag.external {
		pos := at.? or_else drop_point(&ui.tree, target)
		if view := icon_view_of(&ui.tree, target); view != NODE_NONE && view == icon_view_of(&ui.tree, ui.drag.source) {
			if icon_view_placed_drop(ui, view, pos) {
				drag_finish(ui, dropped = true)
				return
			}
		}
	}
	if target != NODE_NONE {
		if h, ok := ui.on_drop[target]; ok {
			landed := at.? or_else drop_point(&ui.tree, target)
			ui.context_pos = landed // kept for what already reads it
			files := drag_paths_copy(&ui.drag, context.temp_allocator)
			handler_send(ui, h, Drop{kind = strings.clone(ui.drag.kind, context.temp_allocator), tag = ui.drag.tag, count = ui.drag.count, position = position, source = ui.drag.source, files = files,
				background = target in ui.grid_drags, action = action, mods = mods, at = node_local(&ui.tree, target, landed)}, target)
		}
	}
	drag_finish(ui, dropped = true)
}

// ---------------------------------------------------------------- across apps

// drag_leave_window: a pointer drag with files leaves the window: the
// compositor takes it over with the paths as text/uri-list (and plain
// text). True when it did; the drag stays active and comes back through
// drag_ext_* if the pointer returns, or ends with drag_ext_end.
//
// The source is asked `files_out` if it gave one, and `files` otherwise. A
// `files_out` that hands back a promise has its paths written into the other
// program only once it says the files are there (dnd_files.odin).
drag_leave_window :: proc(ui: ^Ui($Msg)) -> bool {
	dg := &ui.drag
	if !dg.active || dg.keyboard || dg.external || dg.compositor || dg.returning || ui.dnd.start == nil do return false
	paths, wait := drag_paths_out(dg)
	if len(paths) == 0 do return false
	items := clip_files_items(paths) if wait == nil else clip_files_waiting(paths, wait)
	// The picture goes with it: outside the window the desktop draws what the
	// drag carries. The frame's memory; the backend copies what it keeps.
	pic, _ := drag_picture_make(&ui.tree, dg, ui.surface.scale, context.temp_allocator)
	ok := ui.dnd.start(ui.dnd.user, ui.dnd.surface, items, ui.pointer.press_serial, pic)
	// The platform took references of its own for the forms it kept, so
	// ours go back whether it took the drag or not: a refused drag frees
	// them here and a live one when its last reader is done.
	if wait != nil do clip_files_waiting_release(items)
	if !ok do return false
	dg.compositor = true
	// The ghost is built by end_view, so the view must be rebuilt for it to
	// go; the caller only sets needs_frame, and a frame with no rebuild would
	// leave the ghost stuck at the window's edge.
	ask_rebuild(ui)
	return true
}

// drag_paths_out: what a drag leaving the window carries, from whichever
// callback the source gave. Nothing (and no promise) when it gave neither.
// The promise is not retained here: the forms made from these paths each
// take a reference of their own, and a caller that only wants the paths
// (drag_ext_end, reporting where they went) holds nothing.
@(private)
drag_paths_out :: proc(dg: ^Drag_State) -> (paths: []string, wait: ^Files_Later) {
	if dg.files_out != nil do return dg.files_out(dg.files_user, dg.tag, dg.count, context.temp_allocator)
	if dg.paths != nil do return drag_paths_copy(dg, context.temp_allocator), nil
	return nil, nil
}

// drag_paths_copy is what the drag carries, in `allocator`'s memory for a
// handler to read: the snapshot taken when it was picked up, never a
// fresh answer from the source. A `Drop`'s `files` outlive this drag by a
// message, and the snapshot goes with the drag.
@(private)
drag_paths_copy :: proc(dg: ^Drag_State, allocator: runtime.Allocator) -> []string {
	if len(dg.paths) == 0 do return nil
	out := make([]string, len(dg.paths), allocator)
	for p, i in dg.paths do out[i] = strings.clone(p, allocator)
	return out
}

// drag_ext_enter: a drag came over the window: ours coming back, or
// another app's (taken only when it carries files).
drag_ext_enter :: proc(ui: ^Ui($Msg), pos: [2]f32, has_files: bool) -> bool {
	t := &ui.tree
	ui.pointer.inside = true
	if ui.drag.active && ui.drag.compositor do return drag_ext_motion(ui, pos)
	if ui.drag.active || !has_files do return false
	drag_clear_strings(ui)
	ui.drag = {
		kind = strings.clone("files", t.allocator), name = strings.clone("files", t.allocator), icon = .Copy,
		count = 1, active = true, external = true, start = pos, pos = pos, target = NODE_NONE,
	}
	ask_rebuild(ui) // the announcement
	return drag_ext_motion(ui, pos)
}

// drag_sibling_enter: a drag from another window of this app (`from`, where
// it started) came over this one, carried by the compositor. It is taken
// as that drag, its kind, tag, count and files alike, so a drop here is an
// ordinary in-app Drop, with the move-or-copy default and Alt's Copy here /
// Move here as within one window.
drag_sibling_enter :: proc(ui: ^Ui($Msg), from: ^Ui(Msg), pos: [2]f32) -> bool {
	t := &ui.tree
	ui.pointer.inside = true
	src := &from.drag
	if ui.drag.active || !src.active do return false
	drag_clear_strings(ui)
	ui.drag = {
		kind = strings.clone(src.kind, t.allocator), name = strings.clone(src.name, t.allocator), icon = src.icon,
		tag = src.tag, count = src.count, files = src.files, files_user = src.files_user,
		active = true, external = true, sibling = true, start = pos, pos = pos, target = NODE_NONE,
	}
	// The paths come with it, already resolved: they are the source
	// window's answer from when the drag was picked up there, and this
	// window has no rows of its own to number them against.
	if len(src.paths) > 0 {
		out := make([]string, len(src.paths), t.allocator)
		for p, i in src.paths do out[i] = strings.clone(p, t.allocator)
		ui.drag.paths = out
	}
	ask_rebuild(ui) // the announcement
	return drag_ext_motion(ui, pos)
}

// drag_ext_motion moves a cross-app drag: the target under it lights up
// and the source's cursor learns whether a drop would land.
drag_ext_motion :: proc(ui: ^Ui($Msg), pos: [2]f32) -> bool {
	if !ui.drag.active do return false
	ui.drag.pos = pos
	ui.pointer.inside = true
	drag_rest_moved(ui, pos)
	if !ui.drag.external do drag_move_ghost(ui)
	target, position := drop_target_at(ui, pos)
	was := ui.drag.target
	drag_set_target(ui, target, position)
	if ui.drag.external && ui.dnd.accept != nil && (target != was || was == NODE_NONE) do ui.dnd.accept(ui.dnd.user, target != NODE_NONE)
	return true
}

// drag_ext_leave: the drag left the window: another app's is over for
// us; ours goes on outside.
drag_ext_leave :: proc(ui: ^Ui($Msg)) -> bool {
	ui.pointer.inside = false
	if !ui.drag.active do return false
	if ui.drag.external do return drag_finish(ui, dropped = false)
	drag_set_target(ui, NODE_NONE, .On)
	return true
}

// drag_ext_drop: a drag the compositor carried was released over the
// window. Ours, or one from another window of this app (whose window,
// `from`, then ends its drag: the drop landed in the app), drops as an
// in-window drop would. Another app's asks for its paths (text/uri-list);
// drag_ext_data hands them to the target once they arrive, and nothing
// waits for them meanwhile.
drag_ext_drop :: proc(ui: ^Ui($Msg), pos: [2]f32, action: Drop_Action = .Default, mods: Mods = {}, from: ^Ui(Msg) = nil) -> bool {
	if !ui.drag.active || ui.drag.receiving do return false
	target, position := drop_target_at(ui, pos)
	accepted := false
	switch {
	case ui.drag.external && !ui.drag.sibling:
		if target != NODE_NONE && ui.dnd.receive != nil && ui.dnd.receive(ui.dnd.user, MIME_URI_LIST) {
			drag_set_target(ui, target, position)
			ui.drag.receiving = true
			ui.drag.drop_pos, ui.drag.drop_action, ui.drag.drop_mods = pos, action, mods
			return true // the platform hears the outcome with the data
		}
		drag_finish(ui, dropped = false)
	case target != NODE_NONE:
		drag_drop(ui, target, position, mods, action if action != .Default else drop_action_of_mods(mods), pos)
		if from != nil && from != ui do drag_finish(from, dropped = true)
		accepted = true
	case ui.drag.sibling:
		drag_finish(ui, dropped = false) // the window it came from still carries it
	case:
		drag_cancel(ui)
	}
	if ui.dnd.finish != nil do ui.dnd.finish(ui.dnd.user, accepted)
	return true
}

// drag_ext_data: the data another app's drop asked for arrived (ok false:
// the source gave none in time). Its paths go to the target the drop
// landed on, when that is still there and still takes drops, and the
// platform hears whether it landed.
drag_ext_data :: proc(ui: ^Ui($Msg), data: []u8, ok: bool) -> bool {
	if !ui.drag.active || !ui.drag.receiving do return false
	target, position := ui.drag.target, ui.drag.position
	accepted := false
	if ok && node_valid(&ui.tree, target) {
		paths := uri_list_decode(string(data), context.temp_allocator)
		if h, has := ui.on_drop[target]; has && len(paths) > 0 {
			ui.context_pos = ui.drag.drop_pos
			// `at` from where the drop was recorded, not the pointer: this
			// path waits for the data, and the pointer has moved on.
			handler_send(ui, h, Drop{kind = strings.clone(ui.drag.kind, context.temp_allocator), count = len(paths), position = position, source = NODE_NONE, files = paths,
				background = target in ui.grid_drags, action = ui.drag.drop_action, mods = ui.drag.drop_mods,
				at = node_local(&ui.tree, target, ui.drag.drop_pos)}, target)
			accepted = true
		}
	}
	drag_finish(ui, dropped = accepted)
	if ui.dnd.finish != nil do ui.dnd.finish(ui.dnd.user, accepted)
	return true
}

// drag_ext_end: our drag that the compositor held ended elsewhere.
drag_ext_end :: proc(ui: ^Ui($Msg), dropped: bool, action: Drop_Action = .Default) -> bool {
	if ui.drag.active && ui.drag.sibling do return drag_finish(ui, dropped = false) // the drag it stood for ended elsewhere
	if !ui.drag.active || !ui.drag.compositor do return false
	if dropped && ui.drag_out != nil { // the source hears where its files went and what the other app did
		files, _ := drag_paths_out(&ui.drag) // the ones that left: the same answer, which the source is happy to give twice
		handler_deliver(ui.drag_out, Drop{kind = strings.clone(ui.drag.kind, context.temp_allocator), tag = ui.drag.tag, count = ui.drag.count, source = ui.drag.source, files = files, action = action}, ui.drag.tag, &ui.msgs)
	}
	return drag_finish(ui, dropped = dropped)
}

// drag_end cancels or finishes a drag: the ghost leaves, feedback clears,
// a previewed source goes back to its slot.
drag_end :: proc(ui: ^Ui($Msg)) -> bool {
	return drag_finish(ui, dropped = false)
}

// drag_finish: after a drop the previewed order stays — the app's rebuild
// confirms it (or puts it back), so nothing jumps.
@(private)
drag_finish :: proc(ui: ^Ui($Msg), dropped: bool) -> bool {
	if !ui.drag.active && !ui.drag.pending do return false
	t := &ui.tree
	if dropped {
		ui.drag.previewing = false // the previewed order stands until the app's rebuild
	} else {
		drag_preview_restore(ui)
	}
	// However the drag ended — dropped, cancelled, or gone to another app —
	// a target that was showing where it would land hears that it has gone,
	// so nothing is left ghosting a clip that is not coming.
	drag_over_tell(ui, NODE_NONE, ui.drag.pos)
	drag_set_target(ui, NODE_NONE, .On)
	if sd := node_get(t, t.drag_source); sd != nil {
		set_layer(t, t.drag_source, false) // it was one only for the ghost to copy
		mark_paint_dirty(t, t.drag_source)
	}
	t.drag_source = NODE_NONE
	drag_clear_strings(ui)
	ui.drag = {}
	ui.drag_out = nil
	ask_rebuild(ui)
	return true
}

// ---------------------------------------------------------------- keyboard

// drag_key: Ctrl+X picks the focused item up, Ctrl+V drops it on the
// focused target, Escape cancels. Returns true if consumed.
drag_key :: proc(ui: ^Ui($Msg), key: Key, mods: Mods) -> bool {
	t := &ui.tree
	if key == .Escape && ui.drag.active do return drag_cancel(ui)
	if .Ctrl not_in mods do return false
	#partial switch key {
	case .X:
		if shortcut_bound(ui, .X, mods) do return false // the app's own Ctrl+X (a file manager's Cut) wins; its view never carries, so Ctrl+V stays the app's too
		src := keyboard_drag_item(ui)
		if src == NODE_NONE do return false
		if ui.drag.active do drag_end(ui)
		return drag_begin(ui, src, true)
	case .V:
		if !ui.drag.active || !ui.drag.keyboard do return false
		target, position := keyboard_drop_target(ui)
		if target == NODE_NONE do return true // nothing to drop on here; keep carrying
		drag_drop(ui, target, position)
		return true
	}
	_ = t
	return false
}

// keyboard_drag_item: the focused node when it is a drag source, else the
// cursor row of a focused tree view, table or icon view.
@(private)
keyboard_drag_item :: proc(ui: ^Ui($Msg)) -> Node {
	t := &ui.tree
	f := t.focus
	if f == NODE_NONE do return NODE_NONE
	if _, ok := ui.drags[f]; ok do return f
	if tv, is_tree := t.tree_views[f]; is_tree {
		if _, ok := ui.drags[tv.cursor]; ok do return tv.cursor
		return NODE_NONE
	}
	if row := grid_cursor_row(ui, f); row != NODE_NONE {
		if _, ok := ui.drags[row]; ok do return row
	}
	return NODE_NONE
}

// keyboard_drop_target: the focused node or the cursor row, when it takes
// this drag's kind; On when allowed, else After.
@(private)
keyboard_drop_target :: proc(ui: ^Ui($Msg)) -> (Node, Drop_Position) {
	t := &ui.tree
	cands := [2]Node{t.focus, NODE_NONE}
	if tv, is_tree := t.tree_views[t.focus]; is_tree do cands[1] = tv.cursor
	if row := grid_cursor_row(ui, t.focus); row != NODE_NONE do cands[1] = row
	for i := 1; i >= 0; i -= 1 { // the cursor row is more specific than the container
		n := cands[i]
		dt, ok := t.drops[n]
		if !ok || n == ui.drag.source || (dt.accepts != "" && dt.accepts != ui.drag.kind) do continue
		if _, has := ui.on_drop[n]; !has do continue
		if .On in dt.positions do return n, .On
		return n, .After if .After in dt.positions else .Before
	}
	return NODE_NONE, .On
}

// grid_cursor_row: the row node under a focused table's / icon view's cursor.
@(private)
grid_cursor_row :: proc(ui: ^Ui($Msg), view: Node) -> Node {
	t := &ui.tree
	geom, ok := grid_of(t, view)
	if !ok || geom.sel == nil || geom.sel.cursor < 0 do return NODE_NONE
	for n, ref in ui.rows do if ref.table == view && ref.index == geom.sel.cursor do return n
	return NODE_NONE
}

// drag_rest_moved: the drag went somewhere. Past DRAG_REST_SLOP it is on
// the move again, so the clock restarts and whatever was told it rested
// may be told again once it settles.
@(private)
drag_rest_moved :: proc(ui: ^Ui($Msg), pos: [2]f32) {
	dg := &ui.drag
	if dg.rest_due != 0 && abs(pos.x - dg.rest_from.x) <= DRAG_REST_SLOP && abs(pos.y - dg.rest_from.y) <= DRAG_REST_SLOP do return
	dg.rest_from, dg.rested, dg.rested_epoch, dg.rest_done = pos, NODE_NONE, 0, false
	dg.rest_due = ui.tree.now_ms + DRAG_REST_MS
	tree_wake_at(&ui.tree, dg.rest_due)
}

// rest_target_at finds the node under `pos` that hears a rest for this
// drag's kind: the innermost one, as drop_target_at does, and unlike it
// without caring whether anything there takes the drop.
@(private)
rest_target_at :: proc(ui: ^Ui($Msg), pos: [2]f32) -> Node {
	t := &ui.tree
	for cur := hit_test(t, pos); cur != NODE_NONE; cur = node_parent(t, cur) {
		if rt, ok := t.rests[cur]; ok && cur != ui.drag.source && (rt.accepts == "" || rt.accepts == ui.drag.kind) {
			if _, has := ui.on_drag_rest[cur]; has do return cur
		}
	}
	return NODE_NONE
}

// drag_rest_tick fires Drag_Rest once the drag has stood still long
// enough, and keeps the drop target honest under a still pointer.
//
// The handler opens the folder and the app rebuilds under a pointer that has
// not moved, so without working the target out again the drop would land on
// the row that opened rather than inside what it opened.
@(private)
drag_rest_tick :: proc(ui: ^Ui($Msg), now_ms: f64) {
	dg := &ui.drag
	if dg.keyboard || dg.returning || !ui.pointer.inside do return
	if dg.rest_due == 0 do return
	t_done := dg.rest_done
	t := &ui.tree
	// Worked out every time round, not only when a rest is due, so a drop let
	// go the instant a folder opened lands inside it. `drag_set_target`
	// returns at once when nothing moved.
	target, position := drop_target_at(ui, dg.pos)
	drag_set_target(ui, target, position)
	if now_ms < dg.rest_due {
		tree_wake_at(t, dg.rest_due)
		return
	}
	n := rest_target_at(ui, dg.pos)
	// The same node is heard again once the view has been built since: a
	// folder that opens with a folder in the same slot reuses the row node
	// (rows are keyed by index), and holding still should keep descending. A
	// handler that changes nothing causes no build, so is heard only once.
	if n == NODE_NONE || t_done do return
	if n == dg.rested && ui.epoch == dg.rested_epoch do return
	dg.rested, dg.rested_epoch = n, ui.epoch
	dg.rest_due = now_ms + DRAG_REST_MS // whatever this opens waits its own turn
	if rt, ok := t.rests[n]; ok && !rt.repeat do dg.rest_done = true // acting once here is enough
	if h, ok := ui.on_drag_rest[n]; ok {
		handler_send(ui, h, Drag_Rest{at = node_local(t, n, dg.pos), kind = dg.kind,
			tag = dg.tag, count = dg.count, mods = ui.pointer.mods}, n)
	}
}

// drag_after_events keeps keyboard feedback on the current focus, plays
// the spring-back, and scrolls a region the pointer rests near the edge of.
@(private)
drag_after_events :: proc(ui: ^Ui($Msg), now_ms: f64) {
	if !ui.drag.active do return
	drag_rest_tick(ui, now_ms)
	if !ui.drag.active do return // a handler may have ended it
	t := &ui.tree
	if ui.drag.returning {
		if sd := node_get(t, ui.drag.source); sd != nil do ui.drag.return_to = [2]f32{sd.abs.x, sd.abs.y} - DRAG_GHOST_OFFSET // the source may be gliding home
		k := clamp(f32((now_ms - ui.drag.return_at) / DRAG_RETURN_MS), 0, 1)
		ui.drag.pos = ui.drag.return_from + (ui.drag.return_to - ui.drag.return_from) * ease(k, .Ease_Out)
		drag_move_ghost(ui)
		if k >= 1 { drag_end(ui) } else { tree_wake_at(t, now_ms + 16, ui.drag.source) }
		return
	}
	if ui.drag.keyboard {
		target, position := keyboard_drop_target(ui)
		drag_set_target(ui, target, position)
		if sd := node_get(t, ui.drag.source); sd != nil { // the ghost rides on the (previewed) source
			ui.drag.pos = {sd.abs.x + sd.abs.w / 2, sd.abs.y + sd.abs.h / 2}
			drag_move_ghost(ui)
		}
		return
	}
	if !ui.pointer.inside do return
	sc := scroll_ancestor(t, hit_test(t, ui.drag.pos))
	if sc == NODE_NONE do return
	d := node_get(t, sc)
	step: [2]f32
	if .Scroll_V in d.flags {
		if ui.drag.pos.y < d.abs.y + DRAG_EDGE do step.y = -DRAG_SCROLL_STEP
		if ui.drag.pos.y > d.abs.y + d.abs.h - DRAG_EDGE do step.y = DRAG_SCROLL_STEP
	}
	if .Scroll_H in d.flags {
		if ui.drag.pos.x < d.abs.x + DRAG_EDGE do step.x = -DRAG_SCROLL_STEP
		if ui.drag.pos.x > d.abs.x + d.abs.w - DRAG_EDGE do step.x = DRAG_SCROLL_STEP
	}
	if step != {} && scroll_by(t, sc, step) do tree_wake_at(t, now_ms + 16, sc)
}

// ---------------------------------------------------------------- ghost

// drag_ghost_build adds the ghost to the overlay while a drag is active:
// built by end_view, positioned by drag_move_ghost between builds.
@(private)
drag_ghost_build :: proc(ui: ^Ui($Msg), loc: runtime.Source_Code_Location) {
	if !ui.drag.active || ui.drag.external do return // another app's drag shows its own icon
	t := &ui.tree
	th := &t.theme
	n, created := overlay_begin(ui, DRAG_GHOST_KEY, loc)
	d := node_get(t, n)
	if created {
		d.access.role = .Status
		set_live(t, n, .Polite)
		d.flags += {.Hit_Transparent}
		transition(ui, n, .Fade_Scale, .Fade, th.motion.fast)
	}
	if ui.drag.keyboard {
		set_name(t, n, fmt.tprintf("Picked up %s. Move to a target and press Ctrl+V to drop, Escape to cancel.", ui.drag.name))
	} else {
		set_name(t, n, fmt.tprintf("Dragging %s", ui.drag.name))
	}
	// Once the compositor carries the drag it draws the picture we handed it,
	// over our windows too, so a ghost here would show the drag twice. The
	// node stays, named and drawing nothing, because it is the drag's live
	// region for a screen reader.
	if ui.drag.compositor {
		d.kind = Box_Kind{}
		set_style(t, n, Style{})
		set_layout(t, n, Layout_Props{})
		t.overlay_rules[n] = {fixed = true, at = drag_ghost_at(ui)}
		end(ui)
		return
	}
	// What it is, not what it is called: the item itself, faded, wherever
	// that is a picture, a theme icon or a whole row. A chip of the name is
	// the fallback for a source that has gone or was never drawn.
	mirror := drag_mirror_of(t)
	st := d.style
	st.bg = {} if mirror != NODE_NONE else th.color.surface_high
	st.radius = th.radius.md
	st.border_w = 0 if mirror != NODE_NONE else 1
	st.border = th.color.outline_variant
	st.shadow = {} if mirror != NODE_NONE else th.elev.mid
	st.opacity = 1 if mirror != NODE_NONE else 0.94
	set_style(t, n, st)
	t.overlay_rules[n] = {fixed = true, at = drag_ghost_at(ui)}
	if mirror != NODE_NONE {
		md := node_get(t, mirror)
		d.tag = u64(mirror)
		// the copy draws whatever the item draws outside its box (a focus
		// ring, a shadow), so the ghost's repaints clear that much too
		rest := md^
		rest.move_from = {}
		pb := paint_bounds(&rest)
		over := max(md.abs.x - pb.x, md.abs.y - pb.y, pb.x + pb.w - md.abs.x - md.abs.w, pb.y + pb.h - md.abs.y - md.abs.h, 0)
		d.kind = Custom_Kind{paint = paint_drag_mirror, overhang = over}
		set_layout(t, n, Layout_Props{axis = .Stack, width = md.abs.w, height = md.abs.h})
		if ui.drag.count > 1 do drag_ghost_badge(ui, th, {md.abs.w - th.space[.md], -th.space[.xs]}, loc)
		end(ui)
		return
	}
	d.kind = Box_Kind{}
	set_layout(t, n, Layout_Props{axis = .Row, align = .Center, gap = th.space[.xs], padding = {th.space[.xs], th.space[.md], th.space[.xs], th.space[.md]}, max_w = 280})
	if ui.drag.icon != .None do baldr_icon(ui, ui.drag.icon, ICON_SIZE, th.color.accent_text, loc)
	lbl := text(ui, ui.drag.name, role = .Label, nowrap = true, ellipsis = .End, loc = loc)
	set_role(t, lbl, .None)
	if ui.drag.count > 1 do drag_ghost_badge(ui, th, {}, loc)
	end(ui)
}

// DRAG_GHOST_FADE is how much of the item the ghost shows: enough to read
// it as the thing being carried, little enough to read as a ghost.
DRAG_GHOST_FADE :: f32(0.75)

// drag_mirror_of is the node the ghost copies: the drag's source, while it
// is alive, laid out, and a layer of its own (drag_begin makes it one).
@(private)
drag_mirror_of :: proc(t: ^Tree) -> Node {
	src := t.drag_source
	d := node_get(t, src)
	if d == nil || .Layer not_in d.flags do return NODE_NONE
	if d.abs.w <= 0 || d.abs.h <= 0 do return NODE_NONE
	return src
}

// paint_drag_mirror draws the dragged item into the ghost: its own layer,
// inlined where the ghost sits and faded, so a thumbnail, a theme icon or a
// whole row comes along as it looks.
@(private)
paint_drag_mirror :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer) {
	src := Node(d.tag)
	sd := node_get(t, src)
	if sd == nil do return
	append(&l.cmds, Draw_Layer{node = src, opacity = DRAG_GHOST_FADE, shift = {d.abs.x - sd.abs.x, d.abs.y - sd.abs.y}, at_rest = true})
}

// drag_ghost_damage repaints where the ghost is: its copy of the dragged
// item changes whenever the item does.
@(private)
drag_ghost_damage :: proc(t: ^Tree) {
	for c := node_first(t, t.overlay); c != NODE_NONE; c = node_next(t, c) {
		if d := node_get(t, c); d != nil && d.key == DRAG_GHOST_KEY {
			if d.abs.w > 0 && d.abs.h > 0 do damage_add(t, paint_bounds(d, 0))
			return
		}
	}
}

// drag_ghost_badge is the count on a ghost standing for a selection.
@(private)
drag_ghost_badge :: proc(ui: ^Ui($Msg), th: ^Theme, offset: [2]f32, loc: runtime.Source_Code_Location) {
	badge := row(ui, padding = .xxs, bg = th.color.primary, radius = th.radius.full, align = .Center, loc = loc)
	if offset != {} do set_layout(&ui.tree, badge, Layout_Props{axis = .Row, align = .Center, offset = offset, padding = pad4(th.space[.xxs])})
	box(ui, width = 4, loc = loc)
	bt := text(ui, fmt.tprintf("%d", ui.drag.count), role = .Caption, color = th.color.on_primary, loc = loc)
	set_role(&ui.tree, bt, .None)
	box(ui, width = 4, loc = loc)
	end(ui)
}

@(private)
drag_ghost_at :: proc(ui: ^Ui($Msg)) -> [2]f32 {
	return ui.drag.pos + DRAG_GHOST_OFFSET
}

// drag_move_ghost re-places the ghost without a rebuild.
@(private)
drag_move_ghost :: proc(ui: ^Ui($Msg)) {
	t := &ui.tree
	for c := node_first(t, t.overlay); c != NODE_NONE; c = node_next(t, c) {
		if node_get(t, c).key != DRAG_GHOST_KEY do continue
		if rule, ok := &t.overlay_rules[c]; ok {
			rule.at = drag_ghost_at(ui)
			mark_layout_dirty(t, c)
		}
		return
	}
}
