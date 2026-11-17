package baldr

// Zoom: Ctrl + wheel over a node that asked for it. Tables and icon views
// take `on_zoom` in their builders (a file manager's icon size and row
// density); any other node gets it through `zoomable`. The handler's
// value is the wheel travel in logical px, positive to zoom in (one notch
// is 48); the app scales its tile, row height or image by it. Ctrl++ and
// Ctrl+- are the app's `shortcut`s.

// zoomable makes `n` report Ctrl + wheel through `on_zoom`.
//
//	pic := baldr.image(ui, &s.photo, width = s.zoom * 400)
//	baldr.zoomable(ui, pic, proc(e: baldr.Ev(f32)) -> Msg { return Zoom{e.value} })
zoomable :: proc(ui: ^Ui($Msg), n: Node, on_zoom: Handler(Msg, f32)) {
	zoom_register(ui, n, on_zoom)
}

@(private)
zoom_register :: proc(ui: ^Ui($Msg), n: Node, on_zoom: Handler(Msg, f32)) {
	if node_get(&ui.tree, n) == nil do return
	if !handler_live(on_zoom) { // not `== nil`: see handler_live
		delete_key(&ui.zooms, n)
		return
	}
	ui.zooms[n] = on_zoom
}

// zoom_event routes a Ctrl + wheel at `pos` to the nearest node with an
// on_zoom. Returns true when one took it.
zoom_event :: proc(ui: ^Ui($Msg), pos: [2]f32, delta: [2]f32) -> bool {
	t := &ui.tree
	// A node graph zooms its own canvas rather than reporting a number: the
	// zoom is how the widget is being looked at, not a value the app holds.
	if graph_zoom(ui, pos, -delta.y / 48) do return true
	for cur := hit_test(t, pos); cur != NODE_NONE; cur = node_parent(t, cur) {
		if h, ok := ui.zooms[cur]; ok do return handler_send(ui, h, -delta.y, cur)
	}
	return false
}
