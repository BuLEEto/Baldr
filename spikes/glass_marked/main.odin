// glass_marked — a window that is glass only where it says so.
//
// `transparent = true, backdrop = .Blur, backdrop_region = .Marked`, with
// `backdrop_area` on one pane, an opaque pane beside it, and a rose accent
// set in adjust_theme. Only what is on the marked pane is adapted for the
// wallpaper; the opaque column keeps the rose. It prints both accents, so
// the difference is a number, not an opinion.
//
// It is a **layer** surface on purpose: a compositor may report what is
// behind a layer and never send a report for an ordinary window, which
// leaves `known` false and nothing adapted either way.
//
//   ./build.sh spike glass_marked run
package main

import "core:fmt"
import "baldr:baldr"

ROSE :: baldr.Color{0.72, 0.26, 0.43, 1}

State :: struct { seen: [2]baldr.Color } // the last window / glass accents printed

Msg :: union { Nothing }
Nothing :: struct {}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "glass, only where marked", app_id = "baldr.glassmarked", size = {760, 420},
		init = proc() -> State { return {} },
		surfaces = proc(s: ^State, out: ^[dynamic]baldr.Surface_Desc(Msg)) {
			append(out, baldr.Surface_Desc(Msg){
				tag = 1, kind = .Layer, title = "glass, only where marked", size = {760, 420},
				layer = {level = .Overlay, anchor = {.Top, .Left}, margin = {40, 0, 0, 40}},
				transparent = true, backdrop = .Blur,
				backdrop_region = .Marked, // the sidebar only; the column beside it is opaque
			})
		},
		adjust_theme = proc(th: ^baldr.Theme) { th.color.primary = ROSE },
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) { return {} },
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			// The compositor's report of what is behind arrives a frame or
			// two in, so this says so whenever the answer changes rather
			// than once before it is known.
			now := [2]baldr.Color{ui.tree.theme.color.primary, ui.tree.glass_theme.color.primary}
			if now != s.seen {
				s.seen = now
				fmt.printfln("app %v | window %v | glass %v (adapted %v)",
					ROSE, now[0], now[1], ui.tree.glass_theme_ok)
				fmt.printfln("   level %v | on %v known %v reported %v | marked %v | backdrop %v",
					ui.tree.theme.glass, ui.tree.glass.on, ui.tree.glass.known, ui.tree.glass.reported,
					ui.tree.backdrop_marked, ui.tree.glass.backdrop)
			}
			baldr.row(ui, flex = 1, gap = .none); defer baldr.end(ui)

			// The one pane that is glass. What is built inside it is solved
			// for the wallpaper behind it.
			side := baldr.column(ui, gap = .md, padding = .lg, width = 240, key = 1)
			baldr.backdrop_area(ui, side)
			{
				defer baldr.end(ui)
				baldr.text(ui, "Frosted sidebar", role = .Title)
				baldr.text(ui, "over the wallpaper", muted = true)
				baldr.button(ui, "On the glass", Msg(Nothing{}), key = 2)
			}

			// Everything else paints its own background and keeps the app's
			// colours.
			baldr.column(ui, gap = .md, padding = .lg, flex = 1, bg = ui.theme.color.surface, key = 3)
			{
				defer baldr.end(ui)
				baldr.text(ui, "Opaque column", role = .Title)
				baldr.text(ui, "never sits on the wallpaper", muted = true)
				baldr.button(ui, "The app's accent", Msg(Nothing{}), key = 4)
			}
		},
	})
}
