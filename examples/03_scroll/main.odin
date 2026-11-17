// 03_scroll — a scrolling list of cards inside a fixed-height region, with
// the overlay scrollbar (wheel, trackpad, drag the thumb, click the track).
//
//   ./build.sh example 03_scroll run
package main

import "core:fmt"
import "baldr:baldr"

State :: struct { picked: int }
Msg :: enum { Pick, Reset }

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch m {
	case .Pick:  s.picked += 1
	case .Reset: s.picked = 0
	}
	return {}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, flex = 1, padding = .xl, gap = .lg); defer baldr.end(ui)
	baldr.row(ui, align = .Center, gap = .md); {
		defer baldr.end(ui)
		baldr.text(ui, "Inbox", role = .Headline)
		baldr.spacer(ui)
		baldr.text(ui, fmt.tprintf("%d picked", s.picked), muted = true)
		baldr.button(ui, "Clear", Msg.Reset, variant = .Outline, disabled = s.picked == 0)
	}
	baldr.scroll(ui, flex = 1, gap = .sm); {
		defer baldr.end(ui)
		for i in 0 ..< 40 {
			baldr.card(ui, elevation = .Low, gap = .xs, padding = .md, key = u64(i + 1)); {
				defer baldr.end(ui)
				baldr.row(ui, align = .Center, gap = .md); {
					defer baldr.end(ui)
					baldr.box(ui, width = 10, height = 10, radius = 5, bg = ui.theme.color.primary if i % 3 == 0 else ui.theme.color.outline)
					baldr.text(ui, fmt.tprintf("Message %d — build finished", i + 1), role = .Title)
					baldr.spacer(ui)
					baldr.button(ui, "Pick", Msg.Pick, variant = .Ghost)
				}
				baldr.text(ui, "All 55 headless tests passed. The Wayland and Win32 backends both presented the counter.", muted = true)
			}
		}
	}
}

main :: proc() {
	err := baldr.run(baldr.App(State, Msg){title = "Scroll", app_id = "baldr.scroll", size = {560, 480}, update = update, view = view})
	if err != .None do fmt.eprintln("exit:", err)
}
