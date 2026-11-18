package baldr

// A node graph: boxes with ports, wires between them, and a canvas that pans
// and zooms under them — a shader graph, a signal chain, a build pipeline.
//
// The app owns the graph. It hands over its nodes and wires each build and
// hears what the reader did — a node moved, a wire made or cut, a selection
// changed — as messages, the way a text field hands back an edit. The widget
// owns only how the canvas is being looked at (pan and zoom), because that
// is a property of the looking, not of the graph.
//
// The nodes are accessibility objects with names, their connections are in
// their descriptions, and every gesture — select, move, connect, cut — has
// keys behind it.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strings"

// Graph_Port is a plug on a node: `id` is the app's own, `name` is what a
// reader is told.
Graph_Port :: struct {
	id:   u64,
	name: string,
}

// Graph_Node is one box. `pos` is its top-left in graph coordinates — the
// app's own space, which the canvas pans and zooms over — and the widget
// reports a drag as a new `pos` rather than moving it behind the app's back.
//
// `inputs` and `outputs` are borrowed for the build that passes them and
// copied here, as a text's string is: they must still be alive when the view
// runs, so keep them in the app's state rather than building a slice literal
// in a procedure that has already returned.
Graph_Node :: struct {
	id:       u64,
	title:    string,
	pos:      [2]f32,
	inputs:   []Graph_Port,
	outputs:  []Graph_Port,
	color:    Color, // the header's accent; zero takes the theme's primary
	selected: bool,
	width:    f32, // 0: GRAPH_NODE_W
}

// Graph_Wire joins one node's output to another's input.
Graph_Wire :: struct {
	from_node, from_port: u64,
	to_node, to_port:     u64,
}

// Graph_Event is what the reader did. One handler hears them all, because a
// graph is a node that reports several kinds of thing (`on_event`).
Graph_Event :: union {
	Graph_Moved,     // a node was dragged, or nudged with the keyboard
	Graph_Connected, // a wire was made
	Graph_Cut,       // …or cut
	Graph_Selected,  // the selection changed
	Graph_Activated, // a node was opened (double click, or Enter)
	Graph_Deleted,   // the reader asked for a node to go
}

Graph_Moved     :: struct { node: u64, pos: [2]f32 }
Graph_Connected :: struct { from_node, from_port, to_node, to_port: u64 }
Graph_Cut       :: struct { from_node, from_port, to_node, to_port: u64 }
Graph_Selected  :: struct { node: u64 } // 0 when the selection was cleared
Graph_Activated :: struct { node: u64 }
Graph_Deleted   :: struct { node: u64 }

@(private) GRAPH_NODE_W     :: f32(160)
@(private) GRAPH_HEADER_H   :: f32(26)
@(private) GRAPH_PORT_H     :: f32(20)
@(private) GRAPH_PORT_R     :: f32(5)
@(private) GRAPH_PAD        :: f32(8)
@(private) GRAPH_WIRE_W     :: f32(2)
@(private) GRAPH_WIRE_STEPS :: 18 // a cubic is drawn as this many capsules: joins come free with round ends
@(private) GRAPH_ZOOM_MIN   :: f32(0.25)
@(private) GRAPH_ZOOM_MAX   :: f32(3)
@(private) GRAPH_NUDGE      :: f32(8)  // one arrow press, in graph space
@(private) GRAPH_GRID       :: f32(24) // the dot grid's spacing, in graph space

// Graph_State is how the canvas is being looked at, and what the reader is
// in the middle of doing.
@(private)
Graph_State :: struct {
	pan:       [2]f32, // graph point at the widget's top-left
	zoom:      f32,
	cursor:    u64,  // the node the keyboard is on
	dragging:  u64,  // …the one being dragged, 0 for none
	drag_off:  [2]f32,
	wiring:    bool, // dragging a wire out of a port
	wire_from: struct { node, port: u64, out: bool },
	wire_at:   [2]f32, // where the loose end is, in graph space
	panning:   bool,
	pan_from:  [2]f32,
	hover:     u64, // the node under the pointer
	rect:      Rect,
	note:      string, // what the graph last said about itself, kept for a reader
}

// Graph_Kept is the graph as the widget holds it between builds: the app's
// slices are borrowed only for the build that passed them.
@(private)
Graph_Kept :: struct {
	nodes: [dynamic]Graph_Node,
	wires: [dynamic]Graph_Wire,
	names: [dynamic]string, // every string the two above point at, owned here
}

// graph draws `nodes` and `wires` on a canvas that pans and zooms.
//
// The reader can drag a node, drag from one port to another to wire them,
// click a wire to cut it, drag the background to pan, and Ctrl + wheel to
// zoom — and can do all of it from the keyboard: Tab and the arrows move
// between nodes, Shift + arrows move the node itself, Enter opens it, Delete
// asks for it to go, and Ctrl + the arrows pan the canvas.
//
//	baldr.graph(ui, s.nodes[:], s.wires[:], on_event = proc(e: baldr.Ev(baldr.Graph_Event)) -> Msg {
//		return Graph_Changed{e.value}
//	})
graph :: proc(ui: ^Ui($Msg), nodes: []Graph_Node, wires: []Graph_Wire,
	on_event: Handler(Msg, Graph_Event) = nil, label: string = "", describe: string = "",
	height: f32 = 360, width: f32 = 0, flex: f32 = 0, grid := true,
	tag: u64 = 0, key: u64 = 0, loc := #caller_location) -> Node {
	n, created := reconcile_child(ui, .Custom, key, loc)
	t := &ui.tree
	d := node_get(t, n)
	if created {
		t.graphs[n] = Graph_State{zoom = 1}
		d.flags += {.Focusable}
	}
	s := &t.graphs[n]
	if s.zoom <= 0 do s.zoom = 1
	graph_keep(t, n, nodes, wires)
	for node in nodes do if node.selected && s.cursor == 0 do s.cursor = node.id
	d.kind = Custom_Kind{paint = paint_graph, measure = measure_graph}
	// Stack: the children are the nodes' own accessibility objects, placed
	// exactly over the boxes they stand for (see graph_children).
	set_layout(t, n, Layout_Props{axis = .Stack, width = width, height = height, flex = flex})
	d.tag = tag
	t.graph_grid[n] = grid
	if handler_live(on_event) do ui.graph_event[n] = on_event

	// The nodes are objects of their own for a screen reader, each named
	// with what it is connected to.
	d.access.role = .Group
	set_name(t, n, label if label != "" else "Node graph")
	set_describe(t, n, graph_summary(t, n, describe))
	graph_children(ui, n, nodes, loc)
	return n
}

// ------------------------------------------------------------ what it keeps

@(private)
graph_keep :: proc(t: ^Tree, n: Node, nodes: []Graph_Node, wires: []Graph_Wire) {
	kept, had := &t.graph_data[n]
	if !had {
		t.graph_data[n] = Graph_Kept{
			nodes = make([dynamic]Graph_Node, t.allocator),
			wires = make([dynamic]Graph_Wire, t.allocator),
			names = make([dynamic]string, t.allocator),
		}
		kept = &t.graph_data[n]
	}
	// Paint draws these strings by alias, so the same graph keeps them; a new
	// one repaints, which makes freeing the old copies safe.
	if had && graph_same(kept, nodes, wires) do return
	mark_paint_dirty(t, n)
	graph_kept_clear(t, kept)
	own :: proc(t: ^Tree, kept: ^Graph_Kept, s: string) -> string {
		c := strings.clone(s, t.allocator)
		append(&kept.names, c)
		return c
	}
	for node in nodes {
		k := node
		k.title = own(t, kept, node.title)
		k.inputs = make([]Graph_Port, len(node.inputs), t.allocator)
		k.outputs = make([]Graph_Port, len(node.outputs), t.allocator)
		for p, i in node.inputs  do k.inputs[i]  = {id = p.id, name = own(t, kept, p.name)}
		for p, i in node.outputs do k.outputs[i] = {id = p.id, name = own(t, kept, p.name)}
		append(&kept.nodes, k)
	}
	append(&kept.wires, ..wires)
}

// graph_same: the nodes and wires are what the graph already holds.
@(private)
graph_same :: proc(kept: ^Graph_Kept, nodes: []Graph_Node, wires: []Graph_Wire) -> bool {
	if len(kept.nodes) != len(nodes) || len(kept.wires) != len(wires) do return false
	for w, i in wires do if kept.wires[i] != w do return false
	ports_same :: proc(a, b: []Graph_Port) -> bool {
		if len(a) != len(b) do return false
		for p, i in a do if p.id != b[i].id || p.name != b[i].name do return false
		return true
	}
	for a, i in nodes {
		k := kept.nodes[i]
		if k.id != a.id || k.title != a.title || k.pos != a.pos || k.color != a.color || k.selected != a.selected || k.width != a.width do return false
		if !ports_same(k.inputs, a.inputs) || !ports_same(k.outputs, a.outputs) do return false
	}
	return true
}

// graph_kept_clear lets go of everything the kept graph owns: its strings
// and each node's ports.
@(private)
graph_kept_clear :: proc(t: ^Tree, kept: ^Graph_Kept) {
	for s in kept.names do delete(s, t.allocator)
	for node in kept.nodes {
		delete(node.inputs, t.allocator)
		delete(node.outputs, t.allocator)
	}
	clear(&kept.names)
	clear(&kept.nodes)
	clear(&kept.wires)
}

@(private)
graph_free :: proc(t: ^Tree, n: Node) {
	if kept, has := &t.graph_data[n]; has {
		graph_kept_clear(t, kept)
		delete(kept.names)
		delete(kept.nodes)
		delete(kept.wires)
		delete_key(&t.graph_data, n)
	}
	if s, has := &t.graphs[n]; has do delete(s.note, t.allocator)
	delete_key(&t.graphs, n)
	delete_key(&t.graph_grid, n)
}

// ------------------------------------------------------------ geometry

@(private)
graph_node_h :: proc(node: Graph_Node) -> f32 {
	rows := max(len(node.inputs), len(node.outputs))
	return GRAPH_HEADER_H + f32(rows) * GRAPH_PORT_H + GRAPH_PAD
}

@(private)
graph_node_w :: proc(node: Graph_Node) -> f32 {
	return node.width if node.width > 0 else GRAPH_NODE_W
}

// graph_to_screen and graph_from_screen are the canvas: where a graph point
// is on screen at the current pan and zoom, and back.
@(private)
graph_to_screen :: proc(s: ^Graph_State, p: [2]f32) -> [2]f32 {
	return {s.rect.x + (p.x - s.pan.x) * s.zoom, s.rect.y + (p.y - s.pan.y) * s.zoom}
}

@(private)
graph_from_screen :: proc(s: ^Graph_State, p: [2]f32) -> [2]f32 {
	return {s.pan.x + (p.x - s.rect.x) / s.zoom, s.pan.y + (p.y - s.rect.y) / s.zoom}
}

// graph_port_pos is where a port's dot sits, in graph space: inputs down the
// left, outputs down the right.
@(private)
graph_port_pos :: proc(node: Graph_Node, index: int, out: bool) -> [2]f32 {
	y := node.pos.y + GRAPH_HEADER_H + GRAPH_PORT_H * (f32(index) + 0.5)
	return {node.pos.x + graph_node_w(node) if out else node.pos.x, y}
}

@(private)
graph_find :: proc(kept: ^Graph_Kept, id: u64) -> (Graph_Node, int, bool) {
	for node, i in kept.nodes do if node.id == id do return node, i, true
	return {}, -1, false
}

// ------------------------------------------------------------ what it says

// graph_summary is what a reader hears about the whole graph.
@(private)
graph_summary :: proc(t: ^Tree, n: Node, extra: string) -> string {
	kept, had := &t.graph_data[n]
	s, has := &t.graphs[n]
	if !had || !has do return extra
	b := strings.builder_make(context.temp_allocator)
	if extra != "" {
		strings.write_string(&b, extra)
		strings.write_string(&b, ". ")
	}
	fmt.sbprintf(&b, "%d nodes, %d connections", len(kept.nodes), len(kept.wires))
	if s.zoom != 1 do fmt.sbprintf(&b, ", zoomed to %d percent", int(s.zoom * 100 + 0.5))
	if s.cursor != 0 {
		if node, _, found := graph_find(kept, s.cursor); found {
			fmt.sbprintf(&b, ". %s", node.title)
		}
	}
	return strings.to_string(b)
}

// graph_node_summary is what a reader hears on one node: what it is, and
// what it is joined to — which is the part a picture carries and a name does
// not.
@(private)
graph_node_summary :: proc(t: ^Tree, n: Node, node: Graph_Node) -> string {
	kept, had := &t.graph_data[n]
	if !had do return node.title
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, node.title)
	fmt.sbprintf(&b, ", %d in, %d out", len(node.inputs), len(node.outputs))
	ins, outs := 0, 0
	for w in kept.wires {
		if w.to_node == node.id do ins += 1
		if w.from_node == node.id do outs += 1
	}
	if ins == 0 && outs == 0 {
		strings.write_string(&b, ", not connected")
	} else {
		for w in kept.wires {
			if w.to_node != node.id do continue
			if from, _, found := graph_find(kept, w.from_node); found {
				fmt.sbprintf(&b, ", from %s", from.title)
			}
		}
		for w in kept.wires {
			if w.from_node != node.id do continue
			if to, _, found := graph_find(kept, w.to_node); found {
				fmt.sbprintf(&b, ", to %s", to.title)
			}
		}
	}
	return strings.to_string(b)
}

// graph_children puts every node of the graph in the accessibility tree as
// an object of its own, lying exactly over the box it stands for, named with
// what it is joined to.
//
// They draw nothing and take no pointer (`Hit_Transparent`): the canvas is
// the focus stop and hit-tests in graph space, where the zoom is. They are
// not `inert`, which would take them out of the accessibility tree.
@(private)
graph_children :: proc(ui: ^Ui($Msg), n: Node, nodes: []Graph_Node, loc: runtime.Source_Code_Location) {
	t := &ui.tree
	s := &t.graphs[n]
	open_scope(ui, n, loc)
	defer end(ui)
	for node, i in nodes {
		item, _ := reconcile_child(ui, .Box, u64(i + 1), loc)
		// where it is on screen now, in the widget's own coordinates
		p := [2]f32{(node.pos.x - s.pan.x) * s.zoom, (node.pos.y - s.pan.y) * s.zoom}
		set_layout(t, item, Layout_Props{
			offset = p,
			width  = graph_node_w(node) * s.zoom,
			height = graph_node_h(node) * s.zoom,
		})
		if d := node_get(t, item); d != nil {
			d.flags += {.Hit_Transparent}
			d.access.role = .List_Item
			if node.selected { d.access.states += {.Selected} } else { d.access.states -= {.Selected} }
			set_name(t, item, graph_node_summary(t, n, node))
		}
	}
}

// ------------------------------------------------------------ painting

@(private)
measure_graph :: proc(t: ^Tree, n: Node, d: ^Node_Data, cc: Constraints) -> [2]f32 {
	w := d.layout.width if d.layout.width > 0 else cc.max.x
	h := d.layout.height if d.layout.height > 0 else 360
	return {clamp(w, cc.min.x, cc.max.x), clamp(h, cc.min.y, cc.max.y)}
}

@(private)
paint_graph :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer) {
	s, has := &t.graphs[n]
	kept, had := &t.graph_data[n]
	if !has || !had do return
	th := &t.theme
	rect := Rect{d.abs.x, d.abs.y, d.abs.w, d.abs.h}
	s.rect = rect
	z := s.zoom

	append(&l.cmds, Draw_Rect{rect = rect, radius = th.radius.md, color = th.color.surface_variant})
	append(&l.cmds, Draw_Clip_Push{rect = rect})
	defer append(&l.cmds, Draw_Clip_Pop{})

	// The dot grid: what tells the reader the canvas moved when they pan
	// across empty space.
	if t.graph_grid[n] && z > 0.4 {
		step := GRAPH_GRID * z
		start := graph_to_screen(s, {math.floor(s.pan.x / GRAPH_GRID) * GRAPH_GRID, math.floor(s.pan.y / GRAPH_GRID) * GRAPH_GRID})
		dot := with_alpha(th.color.on_surface_muted, 0.28)
		for y := start.y; y < rect.y + rect.h; y += step {
			for x := start.x; x < rect.x + rect.w; x += step {
				if x < rect.x - 2 || y < rect.y - 2 do continue
				append(&l.cmds, Draw_Rect{rect = {x - 1, y - 1, 2, 2}, radius = 1, color = dot})
			}
		}
	}

	// Wires under the nodes, so a wire never covers what it joins.
	wire_col := with_alpha(th.color.on_surface, 0.55)
	for w in kept.wires {
		a, b, ok := graph_wire_ends(kept, w)
		if !ok do continue
		graph_paint_wire(l, graph_to_screen(s, a), graph_to_screen(s, b), wire_col, z)
	}
	if s.wiring { // the one being dragged out, in the accent so it reads as pending
		if from, _, ok := graph_find(kept, s.wire_from.node); ok {
			idx := graph_port_index(from, s.wire_from.port, s.wire_from.out)
			if idx >= 0 {
				a := graph_port_pos(from, idx, s.wire_from.out)
				graph_paint_wire(l, graph_to_screen(s, a), graph_to_screen(s, s.wire_at), th.color.primary, z)
			}
		}
	}

	for node in kept.nodes {
		graph_paint_node(t, l, s, node, th, z)
	}

	// Flush outside the canvas, with no gap, so it grows by its width alone.
	if t.focus == n && t.focus_visible {
		ring := focus_ring_look(th)
		rw := ring.width
		append(&l.cmds, Draw_Rect{rect = {rect.x - rw, rect.y - rw, rect.w + 2 * rw, rect.h + 2 * rw}, radius = th.radius.md + rw,
			border_w = rw, border = ring.color})
	}
}

// graph_paint_wire draws a cubic from a to b as a run of capsules: the curve
// leaves its port sideways, which is what makes a graph readable when two
// nodes sit level with each other.
@(private)
graph_paint_wire :: proc(l: ^Layer, a, b: [2]f32, color: Color, zoom: f32) {
	reach := max(abs(b.x - a.x) * 0.5, 40 * zoom)
	c1 := [2]f32{a.x + reach, a.y}
	c2 := [2]f32{b.x - reach, b.y}
	prev := a
	for i in 1 ..= GRAPH_WIRE_STEPS {
		u := f32(i) / f32(GRAPH_WIRE_STEPS)
		v := 1 - u
		p := [2]f32{
			v*v*v*a.x + 3*v*v*u*c1.x + 3*v*u*u*c2.x + u*u*u*b.x,
			v*v*v*a.y + 3*v*v*u*c1.y + 3*v*u*u*c2.y + u*u*u*b.y,
		}
		append(&l.cmds, Draw_Line{a = prev, b = p, width = max(GRAPH_WIRE_W * zoom, 1), color = color})
		prev = p
	}
}

@(private)
graph_paint_node :: proc(t: ^Tree, l: ^Layer, s: ^Graph_State, node: Graph_Node, th: ^Theme, z: f32) {
	p := graph_to_screen(s, node.pos)
	w, h := graph_node_w(node) * z, graph_node_h(node) * z
	if p.x > s.rect.x + s.rect.w || p.y > s.rect.y + s.rect.h do return // off the canvas
	if p.x + w < s.rect.x || p.y + h < s.rect.y do return
	accent := node.color if node.color != {} else th.color.primary
	radius := th.radius.sm * z
	selected := node.selected || s.cursor == node.id

	append(&l.cmds, Draw_Shadow{rect = {p.x, p.y + 1, w, h}, radius = radius, blur = 6 * z, color = th.color.shadow})
	append(&l.cmds, Draw_Rect{rect = {p.x, p.y, w, h}, radius = radius, color = th.color.surface,
		border_w = 2 * z if selected else 1, border = th.color.focus_ring if selected else th.color.outline})
	// the header, in the node's own colour: the one place a graph uses colour
	// to say what kind of thing something is
	append(&l.cmds, Draw_Rect{rect = {p.x, p.y, w, GRAPH_HEADER_H * z}, radius = radius, color = accent,
		square = {.Bottom_Left, .Bottom_Right}})
	title_size := th.type.label.size * z
	if title_size >= 6 {
		append(&l.cmds, Draw_Text{pos = {p.x + GRAPH_PAD * z, p.y + (GRAPH_HEADER_H * z - title_size) * 0.5},
			str = node.title, size = title_size, color = ensure_contrast(th.color.on_primary, accent, 4.5), box_w = w - GRAPH_PAD * 2 * z,
			family = role_family(th, .Label)})
	}

	port_size := th.type.caption.size * z
	for port, i in node.inputs {
		c := graph_to_screen(s, graph_port_pos(node, i, false))
		append(&l.cmds, Draw_Rect{rect = {c.x - GRAPH_PORT_R * z, c.y - GRAPH_PORT_R * z, GRAPH_PORT_R * 2 * z, GRAPH_PORT_R * 2 * z},
			radius = GRAPH_PORT_R * z, color = th.color.surface, border_w = max(2 * z, 1), border = accent})
		if port_size >= 6 {
			append(&l.cmds, Draw_Text{pos = {c.x + (GRAPH_PORT_R + 4) * z, c.y - port_size * 0.6}, str = port.name,
				size = port_size, color = th.color.on_surface_muted, box_w = w * 0.5})
		}
	}
	for port, i in node.outputs {
		c := graph_to_screen(s, graph_port_pos(node, i, true))
		append(&l.cmds, Draw_Rect{rect = {c.x - GRAPH_PORT_R * z, c.y - GRAPH_PORT_R * z, GRAPH_PORT_R * 2 * z, GRAPH_PORT_R * 2 * z},
			radius = GRAPH_PORT_R * z, color = accent})
		if port_size >= 6 {
			append(&l.cmds, Draw_Text{pos = {c.x - (GRAPH_PORT_R + 4) * z - w * 0.5, c.y - port_size * 0.6}, str = port.name,
				size = port_size, color = th.color.on_surface_muted, align = .End, box_w = w * 0.5})
		}
	}
}

@(private)
graph_port_index :: proc(node: Graph_Node, port: u64, out: bool) -> int {
	ports := node.outputs if out else node.inputs
	for p, i in ports do if p.id == port do return i
	return -1
}

@(private)
graph_wire_ends :: proc(kept: ^Graph_Kept, w: Graph_Wire) -> (a, b: [2]f32, ok: bool) {
	from, _, found_from := graph_find(kept, w.from_node)
	to, _, found_to := graph_find(kept, w.to_node)
	if !found_from || !found_to do return {}, {}, false
	fi := graph_port_index(from, w.from_port, true)
	ti := graph_port_index(to, w.to_port, false)
	if fi < 0 || ti < 0 do return {}, {}, false
	return graph_port_pos(from, fi, true), graph_port_pos(to, ti, false), true
}

// ------------------------------------------------------------ using it

// graph_hit says what is under a point, in graph space: a port (with its
// node and side), a node, a wire, or the canvas itself.
@(private)
Graph_Hit :: struct {
	node:     u64,
	port:     u64,
	out:      bool,
	on_port:  bool,
	on_node:  bool,
	wire:     int, // index into the wires, -1 for none
}

@(private)
graph_hit :: proc(t: ^Tree, n: Node, at: [2]f32) -> (h: Graph_Hit) {
	h.wire = -1
	kept, had := &t.graph_data[n]
	s, has := &t.graphs[n]
	if !had || !has do return
	slack := GRAPH_PORT_R + 4
	// ports first: they sit on a node's edge, and aiming at one means it
	#reverse for node in kept.nodes {
		for _, i in node.inputs {
			if dist2(graph_port_pos(node, i, false), at) <= slack * slack {
				return {node = node.id, port = node.inputs[i].id, out = false, on_port = true, wire = -1}
			}
		}
		for _, i in node.outputs {
			if dist2(graph_port_pos(node, i, true), at) <= slack * slack {
				return {node = node.id, port = node.outputs[i].id, out = true, on_port = true, wire = -1}
			}
		}
	}
	#reverse for node in kept.nodes { // the last drawn is the top one
		w, hh := graph_node_w(node), graph_node_h(node)
		if at.x >= node.pos.x && at.x <= node.pos.x + w && at.y >= node.pos.y && at.y <= node.pos.y + hh {
			return {node = node.id, on_node = true, wire = -1}
		}
	}
	// a wire, so it can be cut: near any of the points the curve is drawn as
	for wire, wi in kept.wires {
		a, b, ok := graph_wire_ends(kept, wire)
		if !ok do continue
		if graph_wire_near(a, b, at, 6 / max(s.zoom, 0.01)) do return {wire = wi}
	}
	return
}

@(private)
dist2 :: proc(a, b: [2]f32) -> f32 {
	d := a - b
	return d.x * d.x + d.y * d.y
}

@(private)
graph_wire_near :: proc(a, b, p: [2]f32, slack: f32) -> bool {
	reach := max(abs(b.x - a.x) * 0.5, 40)
	c1, c2 := [2]f32{a.x + reach, a.y}, [2]f32{b.x - reach, b.y}
	prev := a
	for i in 1 ..= GRAPH_WIRE_STEPS {
		u := f32(i) / f32(GRAPH_WIRE_STEPS)
		v := 1 - u
		q := [2]f32{
			v*v*v*a.x + 3*v*v*u*c1.x + 3*v*u*u*c2.x + u*u*u*b.x,
			v*v*v*a.y + 3*v*v*u*c1.y + 3*v*u*u*c2.y + u*u*u*b.y,
		}
		if seg_dist2(prev, q, p) <= slack * slack do return true
		prev = q
	}
	return false
}

@(private)
seg_dist2 :: proc(a, b, p: [2]f32) -> f32 {
	ab, ap := b - a, p - a
	len2 := ab.x * ab.x + ab.y * ab.y
	if len2 <= 0 do return dist2(a, p)
	h := clamp((ap.x * ab.x + ap.y * ab.y) / len2, 0, 1)
	return dist2({a.x + ab.x * h, a.y + ab.y * h}, p)
}

// graph_press: a node begins a drag, a port begins a wire, a wire is cut, and
// the background pans.
@(private)
graph_press :: proc(ui: ^Ui($Msg), pos: [2]f32) -> bool {
	t := &ui.tree
	for n, _ in t.graphs {
		d := node_get(t, n)
		if d == nil || d.flags & {.Hidden, .Inert, .Disabled} != {} do continue
		if !rect_contains(d.abs, pos) do continue
		s := &t.graphs[n]
		set_focus(t, n, false)
		at := graph_from_screen(s, pos)
		h := graph_hit(t, n, at)
		kept := &t.graph_data[n]
		switch {
		case h.on_port:
			s.wiring = true
			s.wire_from = {node = h.node, port = h.port, out = h.out}
			s.wire_at = at
		case h.on_node:
			s.dragging = h.node
			s.cursor = h.node
			if node, _, ok := graph_find(kept, h.node); ok do s.drag_off = at - node.pos
			graph_send(ui, n, Graph_Selected{node = h.node})
		case h.wire >= 0:
			w := kept.wires[h.wire]
			graph_send(ui, n, Graph_Cut{from_node = w.from_node, from_port = w.from_port, to_node = w.to_node, to_port = w.to_port})
		case:
			s.panning = true
			s.pan_from = pos
			if s.cursor != 0 {
				s.cursor = 0
				graph_send(ui, n, Graph_Selected{node = 0})
			}
		}
		mark_paint_dirty(t, n)
		return true
	}
	return false
}

// graph_pointer follows a drag: moving a node, pulling a wire, or panning.
@(private)
graph_pointer :: proc(ui: ^Ui($Msg), pos: [2]f32) -> bool {
	t := &ui.tree
	busy := false
	for n, _ in t.graphs {
		s := &t.graphs[n]
		at := graph_from_screen(s, pos)
		switch {
		case s.dragging != 0:
			graph_send(ui, n, Graph_Moved{node = s.dragging, pos = at - s.drag_off})
			busy = true
		case s.wiring:
			s.wire_at = at
			busy = true
		case s.panning:
			d := pos - s.pan_from
			s.pan -= d / s.zoom
			s.pan_from = pos
			busy = true
		case:
			continue
		}
		mark_paint_dirty(t, n)
	}
	return busy
}

// graph_release finishes whatever was in progress: a wire landing on a port
// is a connection, anywhere else is nothing.
@(private)
graph_release :: proc(ui: ^Ui($Msg), pos: [2]f32) -> bool {
	t := &ui.tree
	done := false
	for n, _ in t.graphs {
		s := &t.graphs[n]
		if s.wiring {
			h := graph_hit(t, n, graph_from_screen(s, pos))
			if h.on_port && h.node != s.wire_from.node && h.out != s.wire_from.out {
				from_node, from_port := s.wire_from.node, s.wire_from.port
				to_node, to_port := h.node, h.port
				if !s.wire_from.out { // dragged from an input: the other end is the source
					from_node, from_port, to_node, to_port = h.node, h.port, s.wire_from.node, s.wire_from.port
				}
				graph_send(ui, n, Graph_Connected{from_node = from_node, from_port = from_port, to_node = to_node, to_port = to_port})
			}
			s.wiring = false
			done = true
		}
		if s.dragging != 0 || s.panning {
			s.dragging, s.panning = 0, false
			done = true
		}
		if done do mark_paint_dirty(t, n)
	}
	return done
}

// graph_zoom is Ctrl + wheel: zoom about the pointer, so the point under it
// stays put.
@(private)
graph_zoom :: proc(ui: ^Ui($Msg), pos: [2]f32, delta: f32) -> bool {
	t := &ui.tree
	for n, _ in t.graphs {
		d := node_get(t, n)
		if d == nil || !rect_contains(d.abs, pos) do continue
		s := &t.graphs[n]
		before := graph_from_screen(s, pos)
		s.zoom = clamp(s.zoom * (1 + delta * 0.1), GRAPH_ZOOM_MIN, GRAPH_ZOOM_MAX)
		after := graph_from_screen(s, pos)
		s.pan += before - after // keep the point under the pointer where it was
		set_describe(t, n, graph_summary(t, n, ""))
		mark_paint_dirty(t, n)
		return true
	}
	return false
}

// graph_key is the whole widget without a pointer: Tab and the arrows walk
// the nodes, Shift with an arrow moves the node itself, Ctrl with one pans
// the canvas, +/- zoom, Enter opens, Delete asks for the node to go.
@(private)
graph_key :: proc(ui: ^Ui($Msg), key: Key, mods: Mods) -> bool {
	t := &ui.tree
	n := t.focus
	s, has := &t.graphs[n]
	kept, had := &t.graph_data[n]
	if !has || !had || len(kept.nodes) == 0 do return false

	if .Ctrl in mods { // the canvas, not the nodes
		#partial switch key {
		case .Left:  s.pan.x -= GRAPH_NUDGE * 4 / s.zoom
		case .Right: s.pan.x += GRAPH_NUDGE * 4 / s.zoom
		case .Up:    s.pan.y -= GRAPH_NUDGE * 4 / s.zoom
		case .Down:  s.pan.y += GRAPH_NUDGE * 4 / s.zoom
		case .Equal: s.zoom = clamp(s.zoom * 1.2, GRAPH_ZOOM_MIN, GRAPH_ZOOM_MAX)
		case .Minus: s.zoom = clamp(s.zoom / 1.2, GRAPH_ZOOM_MIN, GRAPH_ZOOM_MAX)
		case .N0:    s.zoom, s.pan = 1, {0, 0}
		case:        return false
		}
		set_describe(t, n, graph_summary(t, n, ""))
		mark_paint_dirty(t, n)
		return true
	}

	current, idx, found := graph_find(kept, s.cursor)
	#partial switch key {
	case .Tab:
		step := -1 if .Shift in mods else 1
		next := (idx + step + len(kept.nodes)) % len(kept.nodes) if found else 0
		s.cursor = kept.nodes[next].id
	case .Left, .Right, .Up, .Down:
		if !found {
			s.cursor = kept.nodes[0].id
			break
		}
		if .Shift in mods { // move the node itself
			p := current.pos
			#partial switch key {
			case .Left:  p.x -= GRAPH_NUDGE
			case .Right: p.x += GRAPH_NUDGE
			case .Up:    p.y -= GRAPH_NUDGE
			case .Down:  p.y += GRAPH_NUDGE
			case: // the other keys never reach here
			}
			graph_send(ui, n, Graph_Moved{node = current.id, pos = p})
			mark_paint_dirty(t, n)
			return true
		}
		if next, ok := graph_nearest(kept, current, key); ok do s.cursor = next
	case .Home: s.cursor = kept.nodes[0].id
	case .End:  s.cursor = kept.nodes[len(kept.nodes) - 1].id
	case .Enter, .Space:
		if !found do return false
		graph_send(ui, n, Graph_Activated{node = current.id})
		return true
	case .Delete, .Backspace:
		if !found do return false
		graph_send(ui, n, Graph_Deleted{node = current.id})
		return true
	case:
		return false
	}
	if s.cursor != 0 {
		graph_send(ui, n, Graph_Selected{node = s.cursor})
		graph_reveal(t, n, s)
	}
	set_describe(t, n, graph_summary(t, n, ""))
	mark_paint_dirty(t, n)
	return true
}

// graph_nearest is the node an arrow key should go to: the closest one in
// that direction, so the keyboard walks the picture the way the eye does
// rather than in the order the app happened to list them.
@(private)
graph_nearest :: proc(kept: ^Graph_Kept, from: Graph_Node, key: Key) -> (u64, bool) {
	best, best_d := u64(0), max(f32)
	fc := [2]f32{from.pos.x + graph_node_w(from) * 0.5, from.pos.y + graph_node_h(from) * 0.5}
	for node in kept.nodes {
		if node.id == from.id do continue
		c := [2]f32{node.pos.x + graph_node_w(node) * 0.5, node.pos.y + graph_node_h(node) * 0.5}
		d := c - fc
		ok := false
		#partial switch key {
		case .Left:  ok = d.x < -1 && abs(d.y) <= abs(d.x) * 2
		case .Right: ok = d.x > 1 && abs(d.y) <= abs(d.x) * 2
		case .Up:    ok = d.y < -1 && abs(d.x) <= abs(d.y) * 2
		case .Down:  ok = d.y > 1 && abs(d.x) <= abs(d.y) * 2
		}
		if !ok do continue
		dist := d.x * d.x + d.y * d.y
		if dist < best_d do best, best_d = node.id, dist
	}
	return best, best != 0
}

// graph_reveal pans so the node the keyboard is on is on screen: a keyboard
// user must never be moved to something they cannot see.
@(private)
graph_reveal :: proc(t: ^Tree, n: Node, s: ^Graph_State) {
	kept, had := &t.graph_data[n]
	if !had do return
	node, _, found := graph_find(kept, s.cursor)
	if !found || s.rect.w <= 0 do return
	view_w, view_h := s.rect.w / s.zoom, s.rect.h / s.zoom
	w, h := graph_node_w(node), graph_node_h(node)
	margin := f32(24)
	if node.pos.x - margin < s.pan.x do s.pan.x = node.pos.x - margin
	if node.pos.y - margin < s.pan.y do s.pan.y = node.pos.y - margin
	if node.pos.x + w + margin > s.pan.x + view_w do s.pan.x = node.pos.x + w + margin - view_w
	if node.pos.y + h + margin > s.pan.y + view_h do s.pan.y = node.pos.y + h + margin - view_h
}

@(private)
graph_send :: proc(ui: ^Ui($Msg), n: Node, ev: Graph_Event) -> bool {
	h, has := ui.graph_event[n]
	if !has do return false
	return handler_send(ui, h, ev, n)
}
