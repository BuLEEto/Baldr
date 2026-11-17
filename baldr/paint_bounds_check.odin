package baldr

import "base:runtime"
import "core:fmt"
import "core:reflect"

// Bounds_Fault is a node that drew outside its paint bounds, the part of the
// window a repaint of it clears: what it drew beyond them can stay on screen
// after it changes, and lands on its neighbours. Collected in
// `Tree.bounds_faults` while `Tree.debug_bounds` is on (BALDR_DEBUG_BOUNDS=1
// for a running app), once per builder line and kind of drawing.
Bounds_Fault :: struct {
	loc:     runtime.Source_Code_Location, // where the node was built
	builder: string,
	cmd:     typeid, // the kind of drawing: Draw_Text, Draw_Rect, …
	drawn:   Rect,   // the visible part of what it drew
	bounds:  Rect,   // what a repaint of it clears
}

// bounds_check holds `cmds`, one node's own drawing, to its paint bounds;
// anything clipped away (`clip`, and clips it pushes itself) is not drawn.
@(private)
bounds_check :: proc(t: ^Tree, d: ^Node_Data, cmds: []Draw_Cmd, bounds, clip: Rect) {
	stack: [8]Rect
	depth := 0
	cur := clip
	room := Rect{bounds.x - 1, bounds.y - 1, bounds.w + 2, bounds.h + 2} // a pixel for rounding and antialiasing
	for c in cmds {
		r: Rect
		switch v in c {
		case Draw_Clip_Push:
			if depth < len(stack) do stack[depth] = cur
			depth += 1
			cur = rect_clip(cur, v.rect)
			continue
		case Draw_Clip_Pop:
			if depth > 0 {
				depth -= 1
				if depth < len(stack) do cur = stack[depth]
			}
			continue
		case Draw_Rect:       r = v.rect
		case Draw_Backdrop:   r = v.rect
		case Draw_Image:      r = v.rect
		case Draw_Canvas:     r = v.rect
		case Draw_Theme_Icon: r = v.rect
		case Draw_Shadow:
			g := shadow_reach(v.blur)
			r = {v.rect.x - g, v.rect.y - g, v.rect.w + 2 * g, v.rect.h + 2 * g}
		case Draw_Text:       r = drawn_text_rect(t, v)
		case Draw_Icon:       r = {v.pos.x, v.pos.y, v.size, v.size}
		case Draw_Wave:       r = {v.pos.x, v.pos.y, v.width, WAVE_H}
		case Draw_Line:
			hw := v.width / 2
			r = {min(v.a.x, v.b.x) - hw, min(v.a.y, v.b.y) - hw, abs(v.a.x - v.b.x) + v.width, abs(v.a.y - v.b.y) + v.width}
		case Draw_Glow_Push, Draw_Glow_Pop, Draw_Layer, Draw_Cells, Draw_Typeset:
			continue // a halo inside the glow's reserved room, another layer, or cells and lines placed by their own widgets
		}
		seen := rect_clip(r, cur)
		if seen.w <= 0 || seen.h <= 0 do continue
		if seen.x >= room.x && seen.y >= room.y && seen.x + seen.w <= room.x + room.w && seen.y + seen.h <= room.y + room.h do continue
		id := reflect.union_variant_typeid(c)
		known := false
		for f in t.bounds_faults do if f.loc == d.loc && f.cmd == id do known = true
		if known do continue
		append(&t.bounds_faults, Bounds_Fault{loc = d.loc, builder = d.builder, cmd = id, drawn = seen, bounds = bounds})
		fmt.eprintfln("baldr/bounds: %s built at %s draws a %v at %v, outside the %v a repaint of it clears", d.builder, loc_text(d.loc), id, seen, bounds)
	}
}

// drawn_text_rect is the box a Draw_Text's lines fill, placed as render
// places them within `box_w`, measured by the engine render draws with.
@(private)
drawn_text_rect :: proc(t: ^Tree, v: Draw_Text) -> Rect {
	if v.str == "" do return {}
	m: [2]f32
	if te := t.text; te != nil && te.ok {
		m = text_measure(t, v.str, v.size, v.wrap_w, v.weight, v.mono, v.family, v.tabular) // what render draws with
	} else if t.measure_text != nil {
		m = t.measure_text(t, v.str, v.size, v.wrap_w, v.weight, v.mono, v.family, v.tabular)
	}
	x := v.pos.x
	if v.box_w > 0 {
		switch v.align {
		case .Start:
		case .Center: x += (v.box_w - m.x) / 2
		case .End:    x += v.box_w - m.x
		}
	}
	return {x, v.pos.y, m.x, m.y}
}
