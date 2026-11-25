package baldr

import "core:math"
import "core:math/linalg"
import "core:strings"

// A widget of the app's own. `custom` is a node that sizes and paints itself;
// it takes the pointer through the modifiers any node takes (clickable,
// pointer_area, pointer_track, hoverable, draggable, drop_target, tooltip)
// and, while it has focus, the keys it names. It paints with the theme in
// force, so it follows light, dark, contrast and a theme_area like the
// toolkit's own widgets.
//
//	stars :: proc(p: ^baldr.Painter) {
//		value := (^int)(p.user)^
//		for i in 0 ..< 5 {
//			ink := p.theme.color.primary if i < value else p.theme.color.outline_variant
//			baldr.draw_icon(p, .Star, {p.rect.x + f32(i) * 24, p.rect.y + 2}, 20, ink)
//		}
//	}
//
//	n := baldr.custom(ui, stars, &s.rating, width = 120, height = 24, label = "Rating",
//		role = .Slider, focusable = true, keys = {.Left, .Right}, on_key = on_rating_key)
//	baldr.clickable(ui, n, Msg.Rate)
//
// The view is built again after a message, and a custom widget repaints
// every time it is built, so drawing from the app's state needs nothing
// more. What it draws is cached with its layer until then.

// Custom_Paint draws a custom widget. Draw only through the painter's procs.
Custom_Paint :: #type proc(p: ^Painter)

// Custom_Measure is a custom widget's size given the room it is offered,
// logical px; an axis with no limit is UNBOUNDED. A `width` or `height` the
// widget was built with still wins on its axis, as on any node; without a
// measure it is that size, or its share of `flex`.
Custom_Measure :: #type proc(user: rawptr, room: [2]f32) -> [2]f32

// Painter is what a Custom_Paint draws with: where (`rect`, absolute
// logical px), in which theme, and the node's state.
Painter :: struct {
	rect:     Rect,
	theme:    ^Theme,
	user:     rawptr,
	hovered:  bool,
	pressed:  bool,
	focused:  bool,
	disabled: bool, // the painter dims what it draws already
	tree:     ^Tree,
	node:     Node,
	layer:    ^Layer,
}

@(private)
Custom_State :: struct {
	paint:   Custom_Paint,
	measure: Custom_Measure,
	user:    rawptr,
	strings: [dynamic]string, // text drawn last paint: the layer's cached commands point into these
}

@(private)
Custom_Keys :: struct($Msg: typeid) {
	handler: Handler(Msg, Chord),
	keys:    [dynamic]Key,
}

// custom builds a widget of the app's own (see the top of this file).
// `user` is handed to `paint` and `measure` untouched and must outlive the
// node. `label` and `role` are what assistive technology is told; a
// focusable widget with no role is announced as a Group, so give it one.
// `on_key` hears the `keys` it names while the widget has focus; any other
// key goes on to the window.
custom :: proc(ui: ^Ui($Msg), paint: Custom_Paint, user: rawptr = nil, measure: Custom_Measure = nil,
	width: f32 = 0, height: f32 = 0, flex: f32 = 0, label: string = "", role: Role = .None, focusable := false,
	keys: []Key = nil, on_key: Handler(Msg, Chord) = nil, tag: u64 = 0, key: u64 = 0, loc := #caller_location) -> Node {
	n, created := reconcile_child(ui, .Custom, key, loc)
	t := &ui.tree
	d := node_get(t, n)
	if created do d.kind = Custom_Kind{paint = custom_paint_node, measure = custom_measure_node if measure != nil else nil}
	if ck, ok := &d.kind.(Custom_Kind); ok {
		want := custom_measure_node if measure != nil else nil
		if ck.measure != want {
			ck.measure = want
			mark_layout_dirty(t, n)
		}
	}
	cs := &t.customs[n]
	if cs == nil {
		t.customs[n] = {}
		cs = &t.customs[n]
	}
	if cs.measure != measure || cs.user != user do mark_layout_dirty(t, n)
	cs.paint, cs.measure, cs.user = paint, measure, user
	set_layout(t, n, Layout_Props{width = width, height = height, flex = flex})
	if focusable { d.flags += {.Focusable} } else if !created { d.flags -= {.Focusable} }
	if role != .None || created do d.access.role = role if role != .None else (.Group if focusable else .None)
	if label != "" do set_name(t, n, label)
	if tag != 0 do d.tag = tag
	if handler_live(on_key) && len(keys) > 0 {
		ck, has := &ui.custom_keys[n]
		if !has {
			ui.custom_keys[n] = Custom_Keys(Msg){keys = make([dynamic]Key, ui.allocator)}
			ck = &ui.custom_keys[n]
		}
		clear(&ck.keys)
		append(&ck.keys, ..keys)
		ck.handler = on_key
	} else {
		custom_keys_forget(ui, n)
	}
	mark_paint_dirty(t, n) // the app's state is what it draws, and the view is built after it changes
	return n
}

@(private)
custom_paint_node :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer) {
	cs := &t.customs[n]
	if cs == nil || cs.paint == nil do return
	for s in cs.strings do delete(s, t.allocator)
	clear(&cs.strings)
	p := Painter{
		rect = d.abs, theme = &t.theme, user = cs.user,
		hovered = .Hovered in d.flags, pressed = .Pressed in d.flags, focused = .Focused in d.flags,
		disabled = disabled_within(t, n), tree = t, node = n, layer = l,
	}
	cs.paint(&p)
}

@(private)
custom_measure_node :: proc(t: ^Tree, n: Node, d: ^Node_Data, cc: Constraints) -> [2]f32 {
	cs := &t.customs[n]
	if cs == nil || cs.measure == nil do return constrain(cc, {})
	return constrain(cc, cs.measure(cs.user, cc.max))
}

// custom_forget drops a custom widget's paint state and the text it drew.
@(private)
custom_forget :: proc(t: ^Tree, n: Node) {
	cs, has := &t.customs[n]
	if !has do return
	for s in cs.strings do delete(s, t.allocator)
	delete(cs.strings)
	delete_key(&t.customs, n)
}

@(private)
custom_keys_forget :: proc(ui: ^Ui($Msg), n: Node) {
	ck, has := &ui.custom_keys[n]
	if !has do return
	delete(ck.keys)
	delete_key(&ui.custom_keys, n)
}

// custom_key hands a key to the focused custom widget that named it.
@(private)
custom_key :: proc(ui: ^Ui($Msg), key: Key, mods: Mods) -> bool {
	n := ui.tree.focus
	ck, has := &ui.custom_keys[n]
	if !has do return false
	for k in ck.keys {
		if k == key do return handler_send(ui, ck.handler, Chord{key = key, mods = mods}, n)
	}
	return false
}

// painter_ink is a colour as the painter draws it: faded with the node's
// container, dimmed when the widget is disabled.
@(private)
painter_ink :: proc(p: ^Painter, c: Color) -> Color {
	out := c
	out.a *= p.tree.paint_opacity
	if p.disabled do out.a *= p.theme.state.disabled_alpha
	return out
}

// draw_rect fills `r`, rounded by `radius`, with an optional border drawn
// inside its edge.
draw_rect :: proc(p: ^Painter, r: Rect, fill: Color, radius: f32 = 0, border: Color = {}, border_width: f32 = 0) {
	append(&p.layer.cmds, Draw_Rect{rect = r, color = painter_ink(p, fill), radius = radius, border_w = border_width, border = painter_ink(p, border)})
}

// draw_line draws a straight line from `a` to `b` with round ends.
draw_line :: proc(p: ^Painter, a, b: [2]f32, width: f32, color: Color) {
	append(&p.layer.cmds, Draw_Line{a = a, b = b, width = width, color = painter_ink(p, color)})
}

// draw_circle fills a circle of `radius` around `centre`, with an optional
// ring drawn inside its edge: a dot, a knob, a node's port.
draw_circle :: proc(p: ^Painter, centre: [2]f32, radius: f32, fill: Color, border: Color = {}, border_width: f32 = 0) {
	draw_rect(p, Rect{centre.x - radius, centre.y - radius, radius * 2, radius * 2}, fill, radius = radius, border = border, border_width = border_width)
}

// draw_polyline joins `points` with straight segments of `width`, round at
// the joins and the ends. An opaque colour reads as one line; a translucent
// one is darker where two segments meet.
draw_polyline :: proc(p: ^Painter, points: [][2]f32, width: f32, color: Color) {
	for i in 1 ..< len(points) do draw_line(p, points[i - 1], points[i], width, color)
}

// draw_arc strokes the part of the circle of `radius` around `centre` from
// angle `from` to `to`, in radians clockwise from three o'clock (y grows
// down): a gauge, a progress ring. Segments of about 3 px read as a curve.
draw_arc :: proc(p: ^Painter, centre: [2]f32, radius, from, to, width: f32, color: Color) {
	steps := clamp(int(abs(to - from) * radius / 3), 2, 256)
	pts := make([][2]f32, steps + 1, context.temp_allocator)
	for i in 0 ..= steps {
		a := from + (to - from) * f32(i) / f32(steps)
		pts[i] = centre + [2]f32{math.cos(a), math.sin(a)} * radius
	}
	draw_polyline(p, pts, width, color)
}

// draw_bezier strokes the cubic Bézier from `a` to `b` pulled towards `c1`
// and `c2`: a node graph's wire. Segments of about 3 px read as a curve.
draw_bezier :: proc(p: ^Painter, a, c1, c2, b: [2]f32, width: f32, color: Color) {
	reach := linalg.length(c1 - a) + linalg.length(c2 - c1) + linalg.length(b - c2) // the curve is no longer than this
	steps := clamp(int(reach / 3), 2, 256)
	pts := make([][2]f32, steps + 1, context.temp_allocator)
	for i in 0 ..= steps {
		t := f32(i) / f32(steps)
		u := 1 - t
		pts[i] = a * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + b * (t * t * t)
	}
	draw_polyline(p, pts, width, color)
}

// draw_icon draws a Lucide icon `size` px square with its top-left at `pos`.
draw_icon :: proc(p: ^Painter, icon: Icon, pos: [2]f32, size: f32, color: Color) {
	append(&p.layer.cmds, Draw_Icon{pos = pos, icon = icon, size = size, color = painter_ink(p, color)})
}

// draw_text draws `s` with its first line's top-left at `pos` and returns
// the size it takes. `size` 0 is the theme's body size; `wrap_width` > 0
// wraps it. `angle` turns it about `pos`, in radians, clockwise on screen:
// `-math.PI / 2` for a label reading up a chart's side, `-math.PI / 4` for
// one under a crowded axis. The size returned is the upright one. The
// string is copied, so a temporary one is fine.
draw_text :: proc(p: ^Painter, pos: [2]f32, s: string, size: f32 = 0, color: Color = {}, weight := Font_Weight.Regular,
	mono := false, wrap_width: f32 = 0, angle: f32 = 0) -> [2]f32 {
	if s == "" do return {}
	px := size if size > 0 else p.theme.type.body.size
	ink := color if color.a > 0 else p.theme.color.on_surface
	cs := &p.tree.customs[p.node]
	own := s
	if cs != nil {
		own = strings.clone(s, p.tree.allocator)
		append(&cs.strings, own)
	}
	append(&p.layer.cmds, Draw_Text{pos = pos, str = own, size = px, color = painter_ink(p, ink), wrap_w = wrap_width, weight = weight, mono = mono, angle = angle})
	return draw_text_size(p, s, size, weight, mono, wrap_width)
}

// draw_text_size is the size `s` would take, without drawing it.
draw_text_size :: proc(p: ^Painter, s: string, size: f32 = 0, weight := Font_Weight.Regular, mono := false, wrap_width: f32 = 0) -> [2]f32 {
	px := size if size > 0 else p.theme.type.body.size
	return p.tree.measure_text(p.tree, s, px, wrap_width, weight, mono, 0, false)
}

// draw_clip limits what is drawn after it to `r`, until draw_unclip.
draw_clip :: proc(p: ^Painter, r: Rect) {
	append(&p.layer.cmds, Draw_Clip_Push{rect = r})
}

// draw_unclip ends the innermost draw_clip.
draw_unclip :: proc(p: ^Painter) {
	append(&p.layer.cmds, Draw_Clip_Pop{})
}
