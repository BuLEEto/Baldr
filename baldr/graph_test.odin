package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: about 9 GB without this `when`, 1 GB with it.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A node graph without a pointer: every gesture has keys behind it, the
// canvas pans and zooms about the right point, and each node is an object a
// screen reader can find and be told what it is joined to.


@(private = "file")
Gr_Msg :: union { Graph_Event }

@(private = "file")
did :: proc(e: Ev(Graph_Event)) -> Gr_Msg { return e.value }

@(private = "file")
Gr :: struct {
	nodes:   [4]Graph_Node,
	wires:   [2]Graph_Wire,
	mic_out: [1]Graph_Port,
	amp_in:  [1]Graph_Port,
	amp_out: [1]Graph_Port,
	out_in:  [1]Graph_Port,
}

// Filled in place, never returned by value: the port slices point into the
// struct itself, so a returned copy's slices would point into a dead stack
// frame. A graph's ports are borrowed for the build, like every other string
// and slice in this toolkit.
@(private = "file")
make_graph :: proc(g: ^Gr) {
	g.mic_out = {{id = 11, name = "out"}}
	g.amp_in  = {{id = 21, name = "in"}}
	g.amp_out = {{id = 22, name = "out"}}
	g.out_in  = {{id = 31, name = "in"}}
	g.nodes[0] = {id = 1, title = "Microphone", pos = {0, 0}, outputs = g.mic_out[:]}
	g.nodes[1] = {id = 2, title = "Amplifier", pos = {240, 0}, inputs = g.amp_in[:], outputs = g.amp_out[:]}
	g.nodes[2] = {id = 3, title = "Speakers", pos = {480, 0}, inputs = g.out_in[:]}
	g.nodes[3] = {id = 4, title = "Meter", pos = {240, 200}, inputs = g.out_in[:]}
	g.wires[0] = {from_node = 1, from_port = 11, to_node = 2, to_port = 21}
	g.wires[1] = {from_node = 2, from_port = 22, to_node = 3, to_port = 31}
}

@(private = "file")
build :: proc(ui: ^Ui(Gr_Msg), g: ^Gr) -> Node {
	begin_view(ui)
	column(ui)
	n := graph(ui, g.nodes[:], g.wires[:], on_event = did, label = "Signal chain", height = 300)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {800, 500})
	return n
}

@(test)
a_graph_can_be_walked_and_moved_with_the_keyboard :: proc(t: ^testing.T) {
	ui: Ui(Gr_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	g: Gr
	make_graph(&g)
	n := build(&ui, &g)
	set_focus(&ui.tree, n, true)
	s := &ui.tree.graphs[n]

	// Tab walks the nodes in order
	testing.expect(t, graph_key(&ui, .Tab, {}), "Tab moves to a node")
	testing.expect_value(t, s.cursor, 1)
	graph_key(&ui, .Tab, {})
	testing.expect_value(t, s.cursor, 2)

	// an arrow goes to the nearest node *in that direction*, which is how the
	// eye reads a graph — not the order the app listed them in
	graph_key(&ui, .Right, {})
	testing.expect_value(t, s.cursor, 3) // Speakers is to the right of the Amplifier
	graph_key(&ui, .Left, {})
	testing.expect_value(t, s.cursor, 2)
	graph_key(&ui, .Down, {})
	testing.expect_value(t, s.cursor, 4) // the Meter is below it

	// Shift + arrow moves the node itself, and the app is told where it went
	clear(&ui.msgs)
	testing.expect(t, graph_key(&ui, .Right, {.Shift}))
	moved, is_moved := ui.msgs[len(ui.msgs) - 1].(Graph_Event).(Graph_Moved)
	testing.expect(t, is_moved, "a nudge is reported as a move")
	testing.expect_value(t, moved.node, 4)
	testing.expect_value(t, moved.pos.x, 240 + GRAPH_NUDGE)

	// Enter opens it, Delete asks for it to go
	clear(&ui.msgs)
	graph_key(&ui, .Enter, {})
	_, opened := ui.msgs[0].(Graph_Event).(Graph_Activated)
	testing.expect(t, opened, "Enter activates the node")
	clear(&ui.msgs)
	graph_key(&ui, .Delete, {})
	_, deleted := ui.msgs[0].(Graph_Event).(Graph_Deleted)
	testing.expect(t, deleted, "Delete asks for it to go — the app decides")
}

@(test)
a_graph_canvas_pans_and_zooms_from_the_keyboard :: proc(t: ^testing.T) {
	ui: Ui(Gr_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	g: Gr
	make_graph(&g)
	n := build(&ui, &g)
	set_focus(&ui.tree, n, true)
	s := &ui.tree.graphs[n]

	before := s.pan
	testing.expect(t, graph_key(&ui, .Right, {.Ctrl}), "Ctrl and an arrow pans the canvas")
	testing.expect(t, s.pan.x > before.x, "…rightwards")
	graph_key(&ui, .Equal, {.Ctrl})
	testing.expect(t, s.zoom > 1, "Ctrl and plus zooms in")
	graph_key(&ui, .N0, {.Ctrl})
	testing.expect_value(t, s.zoom, 1)
	testing.expect_value(t, s.pan, [2]f32{0, 0}) // …and Ctrl+0 puts it back
}

@(test)
a_graph_zooms_about_the_pointer :: proc(t: ^testing.T) {
	// The point under the pointer must stay under it, or a canvas feels like
	// a slider rather than a surface.
	ui: Ui(Gr_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	g: Gr
	make_graph(&g)
	n := build(&ui, &g)
	s := &ui.tree.graphs[n]
	at := [2]f32{s.rect.x + 200, s.rect.y + 120}
	under := graph_from_screen(s, at)

	testing.expect(t, graph_zoom(&ui, at, 3), "Ctrl and the wheel zooms")
	testing.expect(t, s.zoom > 1)
	after := graph_from_screen(s, at)
	testing.expectf(t, abs(after.x - under.x) < 0.5 && abs(after.y - under.y) < 0.5,
		"the point under the pointer stayed there: %v became %v", under, after)

	// and it does not run away to nothing or to the moon
	for _ in 0 ..< 60 do graph_zoom(&ui, at, 5)
	testing.expect_value(t, s.zoom, GRAPH_ZOOM_MAX)
	for _ in 0 ..< 60 do graph_zoom(&ui, at, -5)
	testing.expect_value(t, s.zoom, GRAPH_ZOOM_MIN)
}

@(test)
a_graph_hits_what_the_reader_aimed_at :: proc(t: ^testing.T) {
	ui: Ui(Gr_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	g: Gr
	make_graph(&g)
	n := build(&ui, &g)

	// the Amplifier's body
	h := graph_hit(&ui.tree, n, {260, 10})
	testing.expect(t, h.on_node, "a node")
	testing.expect_value(t, h.node, 2)

	// its input port, which sits on the node's own edge — the port wins
	port := graph_port_pos(g.nodes[1], 0, false)
	h = graph_hit(&ui.tree, n, port)
	testing.expect(t, h.on_port, "a port, not the node under it")
	testing.expect_value(t, h.port, 21)
	testing.expect(t, !h.out)

	// the wire between the Microphone and the Amplifier, halfway along
	a, b, ok := graph_wire_ends(&ui.tree.graph_data[n], g.wires[0])
	testing.expect(t, ok)
	h = graph_hit(&ui.tree, n, {(a.x + b.x) * 0.5, (a.y + b.y) * 0.5})
	testing.expect_value(t, h.wire, 0)

	// empty canvas is nothing at all
	h = graph_hit(&ui.tree, n, {0, 400})
	testing.expect(t, !h.on_node && !h.on_port && h.wire == -1)
}

@(test)
every_node_of_a_graph_is_in_the_accessibility_tree :: proc(t: ^testing.T) {
	// A graph is the widget that usually has no accessibility story at all:
	// the nodes are objects, and what they are joined to is in their names,
	// because that is the part the picture carries and a title does not.
	ui: Ui(Gr_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	g: Gr
	make_graph(&g)
	n := build(&ui, &g)
	d := node_get(&ui.tree, n)
	testing.expect_value(t, d.access.role, Role.Group)
	testing.expect_value(t, d.access.name, "Signal chain")
	testing.expect(t, strings.contains(d.access.describe, "4 nodes, 2 connections"), d.access.describe)

	dump := access_dump(&ui.tree)
	testing.expect(t, strings.contains(dump, "Microphone, 0 in, 1 out, to Amplifier"), dump)
	testing.expect(t, strings.contains(dump, "Amplifier, 1 in, 1 out, from Microphone, to Speakers"), dump)
	testing.expect(t, strings.contains(dump, "Meter, 1 in, 0 out, not connected"), dump)

	// the keyboard's node is named in the graph's own description, so a
	// reader hears where it has moved to
	set_focus(&ui.tree, n, true)
	graph_key(&ui, .Tab, {})
	testing.expect(t, strings.contains(node_get(&ui.tree, n).access.describe, "Microphone"), node_get(&ui.tree, n).access.describe)
}

@(test)
a_graph_keeps_the_keyboards_node_on_screen :: proc(t: ^testing.T) {
	// Moving the cursor to something off-canvas and leaving it there would
	// strand a keyboard reader: the canvas follows.
	ui: Ui(Gr_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	g: Gr
	make_graph(&g)
	g.nodes[2].pos = {2000, 900} // far away
	n := build(&ui, &g)
	set_focus(&ui.tree, n, true)
	s := &ui.tree.graphs[n]

	s.cursor = 3
	graph_reveal(&ui.tree, n, s)
	on := graph_to_screen(s, g.nodes[2].pos)
	testing.expect(t, on.x >= s.rect.x - 1 && on.x <= s.rect.x + s.rect.w, "it is on the canvas now")
	testing.expect(t, on.y >= s.rect.y - 1 && on.y <= s.rect.y + s.rect.h)
}

// The graph draws its titles and port names by alias into a kept layer, so
// a rebuild with the same graph must leave those strings alone, and a new
// graph is drawn at once. Rebuilding many times leaks nothing.
@(test)
a_graph_rebuilt_draws_what_it_still_holds :: proc(t: ^testing.T) {
	ui: Ui(Gr_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	g: Gr
	make_graph(&g)
	set_viewport(&ui.tree, {800, 500})
	drawn_from_kept :: proc(tr: ^Tree, n: Node, title: string) -> (found, ok: bool) {
		kept := &tr.graph_data[n]
		ok = true
		for c in draw_list(tr) {
			dt, is_text := c.(Draw_Text)
			if !is_text || dt.str != title do continue
			found = true
			mine := false
			for k in kept.names do if raw_data(k) == raw_data(dt.str) do mine = true
			if !mine do ok = false
		}
		return
	}
	n := build(&ui, &g)
	for i in 0 ..< 4 {
		for &node in g.nodes do node.title = strings.clone(node.title, context.temp_allocator) // equal, in new memory
		build(&ui, &g)
		found, ok := drawn_from_kept(&ui.tree, n, "Amplifier")
		testing.expectf(t, found && ok, "build %d: the title is drawn from a string the graph holds", i)
	}
	g.nodes[1].title = "Mixer"
	build(&ui, &g)
	found, ok := drawn_from_kept(&ui.tree, n, "Mixer")
	testing.expect(t, found && ok, "a new title is drawn at once, from the graph's new copy")
	found, _ = drawn_from_kept(&ui.tree, n, "Amplifier")
	testing.expect(t, !found, "and the old one is gone")
}

} // when ODIN_TEST