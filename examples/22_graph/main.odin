package main

// A node graph: drag a node, drag from one port to another to wire them,
// click a wire to cut it, drag the background to pan, Ctrl + wheel to zoom —
// and all of it from the keyboard: Tab and the arrows walk the nodes,
// Shift + arrow moves one, Ctrl + arrow pans, Enter opens, Delete removes.

import "core:fmt"
import "baldr:baldr"

State :: struct {
	nodes: [dynamic]baldr.Graph_Node,
	wires: [dynamic]baldr.Graph_Wire,
	said:  string,
	// the ports live here, not in a slice literal inside init: the widget
	// copies what it is given each build, but what it is given has to still
	// be there when the view runs
	mic_out:   [1]baldr.Graph_Port,
	gain_in:   [2]baldr.Graph_Port,
	gain_out:  [1]baldr.Graph_Port,
	verb_in:   [1]baldr.Graph_Port,
	verb_out:  [1]baldr.Graph_Port,
	speak_in:  [2]baldr.Graph_Port,
}

Did :: struct { ev: baldr.Graph_Event }
Msg :: union { Did }

init :: proc() -> State {
	s := State{
		mic_out  = {{id = 11, name = "out"}},
		gain_in  = {{id = 21, name = "in"}, {id = 22, name = "gain"}},
		gain_out = {{id = 23, name = "out"}},
		verb_in  = {{id = 31, name = "in"}},
		verb_out = {{id = 32, name = "out"}},
		speak_in = {{id = 41, name = "left"}, {id = 42, name = "right"}},
	}
	return s
}

// nodes are built from the state's own arrays each view, so nothing the
// widget is handed has gone out of scope
build_nodes :: proc(s: ^State) {
	if len(s.nodes) > 0 do return
	append(&s.nodes, baldr.Graph_Node{id = 1, title = "Microphone", pos = {40, 60}, outputs = s.mic_out[:]})
	append(&s.nodes, baldr.Graph_Node{id = 2, title = "Gain", pos = {260, 50}, inputs = s.gain_in[:], outputs = s.gain_out[:]})
	append(&s.nodes, baldr.Graph_Node{id = 3, title = "Reverb", pos = {260, 190}, inputs = s.verb_in[:], outputs = s.verb_out[:]})
	append(&s.nodes, baldr.Graph_Node{id = 4, title = "Speakers", pos = {500, 120}, inputs = s.speak_in[:]})
	append(&s.wires, baldr.Graph_Wire{from_node = 1, from_port = 11, to_node = 2, to_port = 21})
	append(&s.wires, baldr.Graph_Wire{from_node = 2, from_port = 23, to_node = 4, to_port = 41})
	append(&s.wires, baldr.Graph_Wire{from_node = 3, from_port = 32, to_node = 4, to_port = 42})
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	build_nodes(s)
	baldr.column(ui, padding = .lg, gap = .sm); defer baldr.end(ui)
	baldr.text(ui, "Signal chain", role = .Title)
	baldr.graph(ui, s.nodes[:], s.wires[:], label = "Signal chain", describe = "A microphone through a gain and a reverb to the speakers",
		height = 380, on_event = proc(e: baldr.Ev(baldr.Graph_Event)) -> Msg { return Did{e.value} })
	baldr.text(ui, s.said if s.said != "" else "Drag a node, wire two ports, or press Tab and use the arrows.", muted = true)
}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch v in m {
	case Did:
		switch e in v.ev {
		case baldr.Graph_Moved:
			for &n in s.nodes do if n.id == e.node do n.pos = e.pos
		case baldr.Graph_Connected:
			append(&s.wires, baldr.Graph_Wire{from_node = e.from_node, from_port = e.from_port, to_node = e.to_node, to_port = e.to_port})
			s.said = fmt.aprintf("wired %d → %d", e.from_node, e.to_node)
		case baldr.Graph_Cut:
			for w, i in s.wires do if w == (baldr.Graph_Wire{e.from_node, e.from_port, e.to_node, e.to_port}) {
				ordered_remove(&s.wires, i)
				s.said = fmt.aprintf("cut %d → %d", e.from_node, e.to_node)
				break
			}
		case baldr.Graph_Selected:
			for &n in s.nodes do n.selected = n.id == e.node
		case baldr.Graph_Activated:
			for n in s.nodes do if n.id == e.node do s.said = fmt.aprintf("opened %s", n.title)
		case baldr.Graph_Deleted:
			for n, i in s.nodes do if n.id == e.node {
				s.said = fmt.aprintf("removed %s", n.title)
				ordered_remove(&s.nodes, i)
				break
			}
			for i := len(s.wires) - 1; i >= 0; i -= 1 {
				if s.wires[i].from_node == e.node || s.wires[i].to_node == e.node do ordered_remove(&s.wires, i)
			}
		}
	}
	return {}
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Node graph", app_id = "baldr.graph", size = {880, 560},
		init = init, view = view, update = update,
	})
}
