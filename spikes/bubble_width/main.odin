package main

// A chat bubble's styled_text must be measured and drawn at the same
// width. The tree is a chat app's bubble, shape for shape: list →
// row(align .End) → column(max_width 520) → column(padding .md, bg) →
// styled_text, with no width on the text.
//
//	./build.sh spike bubble_width run
//
// It prints each styled_text's box once, so the fault is a number rather
// than a squint at pixels: the long message's box should be about 487x145.
// A box as narrow as its first line with the height of the unwrapped lines
// (76x109) means it was measured at one width and drawn at another.

import "core:fmt"
import "baldr:baldr"

Msg :: union { Link }
Link :: struct { href: string }

LONG :: "Hi George,\nMy request on 30 September was for two user accounts, a desk phone for Nev and a headset.\nPlease can I have a quote for what I requested, as that is what I have been asked for.\n\nPlease can i have them promptly as it has now been 2 weeks.\nThanks Richard"
SHORT :: "is that okay"
TWO_A :: "Here is the first paragraph of a message that runs on a bit and should wrap."
TWO_B :: "ok"

Line :: struct { body: string, second: string, outgoing: bool }

LINES := []Line{
	{body = SHORT, outgoing = true},
	{body = LONG},
	{body = TWO_A, second = TWO_B},
	{body = LONG, outgoing = true},
	{body = SHORT},
}

State :: struct { nodes: [8]baldr.Node, bubbles: [8]baldr.Node, n: int, shown: bool }

bubble_row :: proc(s: ^State, ui: ^baldr.Ui(Msg), l: Line, key: u64) {
	th := &ui.tree.theme
	baldr.row(ui, gap = .xs, align = .End, key = key); defer baldr.end(ui)
	if l.outgoing {
		baldr.spacer(ui)
	} else {
		baldr.box(ui, width = 28, height = 28, radius = 14, bg = th.color.surface_variant)
	}
	baldr.column(ui, gap = .xxs, align = .End if l.outgoing else .Start, max_width = 520); {
		defer baldr.end(ui)
		bg := th.color.primary if l.outgoing else th.color.surface_high
		fg := th.color.on_primary if l.outgoing else th.color.on_surface
		bub := baldr.column(ui, gap = .xs, padding = .md, radius = 18, bg = bg); {
			defer baldr.end(ui)
			st := baldr.styled_text(ui, l.body, ink = fg, on = bg, key = 1)
			if s.n < 8 { s.nodes[s.n], s.bubbles[s.n] = st, bub; s.n += 1 }
			if l.second != "" do baldr.styled_text(ui, l.second, ink = fg, on = bg, key = 2)
		}
		baldr.row(ui, gap = .xxs); {
			defer baldr.end(ui)
			baldr.text(ui, "now", role = .Caption, muted = true)
		}
	}
	if !l.outgoing do baldr.spacer(ui)
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	if s.n > 0 && !s.shown {
		s.shown = true
		for i in 0 ..< s.n {
			sd := baldr.node_get(&ui.tree, s.nodes[i])
			bd := baldr.node_get(&ui.tree, s.bubbles[i])
			if sd == nil || bd == nil do continue
			fmt.printf("[bubble_width] styled %d: box %.0fx%.0f at %.0f,%.0f   bubble %.0fx%.0f\n",
				i, sd.abs.w, sd.abs.h, sd.abs.x, sd.abs.y, bd.abs.w, bd.abs.h)
		}
	}
	s.n = 0
	baldr.column(ui, flex = 1); defer baldr.end(ui)
	first, last := baldr.list(ui, len(LINES), estimated_height = 72, follow_end = true,
		gap = .xs, padding = .sm, key = 90)
	for i in first ..= last {
		if i < 0 || i >= len(LINES) do continue
		bubble_row(s, ui, LINES[i], u64(i + 1))
	}
	baldr.end(ui)
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Bubble width",
		app_id = "baldr.bubble_width",
		size = {760, 520},
		view = view,
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) { return {} },
	})
}
