#+build darwin
package main

// The Baldr side: a real UI, built with real widgets, laid out and painted by
// the real toolkit. Nothing here knows about Metal.

import "baldr:baldr"
import "core:fmt"

Msg :: union { Press, Toggle }
Press :: struct {}
Toggle :: struct { on: bool }

State :: struct {
	presses: int,
	on:      bool,
}

view :: proc(ui: ^baldr.Ui(Msg), s: ^State) {
	baldr.begin_view(ui)
	defer baldr.end_view(ui)

	baldr.column(ui, padding = baldr.Space_Token.xl, gap = baldr.Space_Token.lg)
	defer baldr.end(ui)

	baldr.text(ui, "Baldr on macOS", role = .Title)
	baldr.text(ui, "Real widgets, laid out and painted by the toolkit, rendered by Metal in a Cocoa window. No Vulkan anywhere.")

	baldr.row(ui, gap = baldr.Space_Token.md)
	{
		defer baldr.end(ui)
		baldr.button(ui, "Press me", Msg(Press{}))
		baldr.toggle(ui, s.on, "A toggle", proc(e: baldr.Ev(bool)) -> Msg { return Toggle{e.value} })
	}

	baldr.text(ui, fmt.tprintf("pressed %d times", s.presses), muted = true)

	baldr.card(ui)
	{
		defer baldr.end(ui)
		baldr.text(ui, "A card: rounded rects, borders and elevation, all through the same vertex path.")
	}
}
