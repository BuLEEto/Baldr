package baldr

// Hover: a node that hears the pointer resting on it.

import "core:slice"

// hoverable makes `n` report the pointer resting on it through `on_hover`:
// true once when the pointer comes over it or anything inside it, false once
// when the pointer leaves it or the surface, or the node goes away (a toast
// that pauses while it is looked at, a launcher row made current). Only the
// pointer moving counts: content moving or rebuilding under a still pointer
// sends nothing, so keys that walk a list keep working under it. nil stops it.
//
//	r := baldr.list_row(ui, app.name, Launch{i}, theme_icon = app.icon, selected = i == s.current, tag = u64(i))
//	baldr.hoverable(ui, r, proc(e: baldr.Ev(bool)) -> Msg { return Rest{int(e.tag), e.value} })
hoverable :: proc(ui: ^Ui($Msg), n: Node, on_hover: Handler(Msg, bool)) {
	if node_get(&ui.tree, n) == nil do return
	if !handler_live(on_hover) { // not `== nil`: see handler_live
		delete_key(&ui.hovers, n)
		return
	}
	ui.hovers[n] = on_hover
}

// hover_update tells the hoverable nodes the pointer came over or left, now
// that `hit` (NODE_NONE: nothing, the pointer left) is under it: those left
// hear false, innermost first, then those come over hear true, outermost first.
@(private)
hover_update :: proc(ui: ^Ui($Msg), hit: Node) {
	if len(ui.hovers) == 0 && len(ui.hovering) == 0 do return
	t := &ui.tree
	under := make([dynamic]Node, context.temp_allocator)
	for cur := hit; cur != NODE_NONE; cur = node_parent(t, cur) {
		if _, ok := ui.hovers[cur]; ok do append(&under, cur)
	}
	#reverse for n, i in ui.hovering {
		if slice.contains(under[:], n) do continue
		ordered_remove(&ui.hovering, i)
		if h, ok := ui.hovers[n]; ok do handler_send(ui, h, false, n)
	}
	#reverse for n in under {
		if slice.contains(ui.hovering[:], n) do continue
		append(&ui.hovering, n)
		handler_send(ui, ui.hovers[n], true, n)
	}
}

// hover_forget is node `n` going away: if the pointer rested on it, it hears false.
@(private)
hover_forget :: proc(ui: ^Ui($Msg), n: Node) {
	for m, i in ui.hovering do if m == n {
		ordered_remove(&ui.hovering, i)
		if h, ok := ui.hovers[n]; ok do handler_send(ui, h, false, n)
		break
	}
	delete_key(&ui.hovers, n)
}
