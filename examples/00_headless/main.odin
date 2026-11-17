// 00_headless — the Baldr core with no window: build a view with the scoped
// builders, lay it out, paint it into draw lists, and print what a renderer
// would receive plus the accessibility tree and the damage rects.
//
//   ./build.sh example 00_headless run
package main

import "core:fmt"
import "baldr:baldr"

State :: struct { count: int }
Msg   :: enum { Inc, Dec }

view :: proc(ui: ^baldr.Ui(Msg), s: ^State) {
	baldr.column(ui, gap = .md, padding = .xl, bg = baldr.rgb(0x1A1C21)); defer baldr.end(ui)
	baldr.text(ui, fmt.tprintf("Count: %d", s.count), size = 24)
	baldr.row(ui, gap = .sm); {
		defer baldr.end(ui)
		baldr.button(ui, "-", Msg.Dec)
		baldr.button(ui, "+", Msg.Inc)
	}
}

main :: proc() {
	ui: baldr.Ui(Msg)
	baldr.ui_init(&ui)
	defer baldr.ui_destroy(&ui)
	s := State{}

	for step in 0 ..< 3 {
		baldr.begin_view(&ui)
		view(&ui, &s)
		baldr.end_view(&ui)
		ui.stats = {}
		baldr.frame(&ui.tree, {320, 200})

		fmt.printfln("--- frame %d  (layout visited %d nodes, rebuilt %d layers)", step, ui.stats.layout_nodes, ui.stats.layers_rebuilt)
		for r in baldr.take_damage(&ui.tree) do fmt.printfln("damage  %v", r)
		for c in baldr.draw_list(&ui.tree) {
			switch v in c {
			case baldr.Draw_Rect:      fmt.printfln("rect    %v  rgba%v r=%v", v.rect, v.color, v.radius)
			case baldr.Draw_Text:      fmt.printfln("text    %v  %q  %vpx", v.pos, v.str, v.size)
			case baldr.Draw_Clip_Push: fmt.printfln("clip    %v", v.rect)
			case baldr.Draw_Clip_Pop:  fmt.println("unclip")
			case baldr.Draw_Layer:     fmt.printfln("layer   %v", v.node)
			case baldr.Draw_Shadow:    fmt.printfln("shadow  %v  blur=%v", v.rect, v.blur)
			case baldr.Draw_Backdrop:  fmt.printfln("glass   %v  blur=%v", v.rect, v.material.blur)
			case baldr.Draw_Icon:      fmt.printfln("icon    %v  %v %vpx", v.pos, v.icon, v.size)
			case baldr.Draw_Wave:      fmt.printfln("wave    %v  w=%v", v.pos, v.width)
			case baldr.Draw_Line:      fmt.printfln("line    %v → %v  w=%v", v.a, v.b, v.width)
			case baldr.Draw_Image:     fmt.printfln("image   %v", v.rect)
			case baldr.Draw_Theme_Icon: fmt.printfln("theme icon %v  %q", v.rect, v.name)
			case baldr.Draw_Glow_Push: fmt.printfln("glow    %v", v.glow)
			case baldr.Draw_Glow_Pop:  fmt.println("unglow")
			case baldr.Draw_Canvas:    fmt.printfln("canvas  %v", v.rect)
			case baldr.Draw_Cells:     fmt.printfln("cells   node %v at %v", v.node, v.pos)
			case baldr.Draw_Typeset:   fmt.printfln("typeset %v  lines %d..<%d", v.pos, v.first, v.first + v.count)
			}
		}
		if step == 0 do fmt.print("a11y:\n", baldr.access_dump(&ui.tree))

		// "click +" by finding the second button and dispatching it.
		col := baldr.node_first(&ui.tree, ui.root)
		row := baldr.node_next(&ui.tree, baldr.node_first(&ui.tree, col))
		plus := baldr.node_next(&ui.tree, baldr.node_first(&ui.tree, row))
		baldr.click(&ui, plus)
		for m in ui.msgs {
			switch m {
			case .Inc: s.count += 1
			case .Dec: s.count -= 1
			}
		}
		clear(&ui.msgs)
		free_all(context.temp_allocator)
	}
	if baldr.lint(&ui.tree) > 0 do for d in ui.diags do fmt.printfln("lint: %s:%d %s", d.loc.file_path, d.loc.line, d.msg)
}
