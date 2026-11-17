// glass_contrast — does Baldr's glass deliver the contrast it solves for?
//
// `glass_legible` raises a material's tint until text reads at
// GLASS_TEXT_CONTRAST (4.5:1) over the darkest *and* brightest part of what
// the compositor says is behind. This puts a **known** colour behind the
// glass — its own patch, not somebody's desktop — and prints every number
// the solve used, so the composite can be measured against the model.
//
// Two things to know when reading the result:
//
// The blur flattens the backdrop. The range the compositor reports is a
// range across the *surface*, not across what any part of the panel sits
// on, so solving against the reported min is conservative: the real
// composite is at or above the model's worst case. BALDR_GC_SPLIT=1 splits
// the patch dark and bright to show it.
//
// Rendered glyph pixels are not the colour pair. Only a handful of pixels
// in a text band reach full coverage, so sampling one that looks solid gives
// a number far under the truth. WCAG contrast is defined on the specified
// foreground and background colours, not on an antialiased rendering of
// them: measure the background pixel and pair it with the colour the theme
// says, which is what this probe prints.
//
//   ./build.sh spike glass_contrast run
//   BALDR_GC_SPLIT=1 BALDR_GC_BEHIND=0A0A14 ./build/glass_contrast
//   …then capture the whole output to build/gc.png and crop to the patch
//
// BALDR_GC_BEHIND=RRGGBB sets the colour behind (default 0A0A0A).
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "baldr:baldr"

PATCH :: [2]f32{560, 340} // the known colour, behind
GLASS :: [2]f32{440, 240} // the glass panel, over it
AT    :: 80               // both anchored this far from the top-left

State :: struct {
	behind: baldr.Color,
	bright: baldr.Color,
	split:  bool, // BALDR_GC_SPLIT=1: dark on the left, bright on the right
	said:   bool,
}

Msg :: union { Nothing }
Nothing :: struct {}

behind_colour :: proc() -> baldr.Color {
	hex := os.get_env("BALDR_GC_BEHIND", context.temp_allocator)
	if len(hex) != 6 do hex = "0A0A0A"
	v, ok := strconv.parse_u64_of_base(hex, 16)
	if !ok do v = 0x0A0A0A
	return baldr.rgb(u32(v))
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "glass contrast", app_id = "baldr.glasscontrast", size = GLASS,
		theme = baldr.theme_light(), // the hard case: light theme over a dark backdrop
		init = proc() -> State {
			return {
				behind = behind_colour(),
				bright = baldr.rgb(0xF2F2F2),
				split  = os.get_env("BALDR_GC_SPLIT", context.temp_allocator) == "1",
			}
		},
		surfaces = proc(s: ^State, out: ^[dynamic]baldr.Surface_Desc(Msg)) {
			// The known colour, opaque, underneath.
			append(out, baldr.Surface_Desc(Msg){
				tag = 1, kind = .Layer, title = "behind", size = PATCH,
				layer = {level = .Bottom, anchor = {.Top, .Left}, margin = {AT, 0, 0, AT}},
			})
			// The glass panel, over it, inset so the patch shows around it.
			append(out, baldr.Surface_Desc(Msg){
				tag = 2, kind = .Layer, title = "glass", size = GLASS,
				layer = {level = .Overlay, anchor = {.Top, .Left}, margin = {AT + 50, 0, 0, AT + 60}},
				transparent = true, backdrop = .Blur, backdrop_region = .All,
			})
		},
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) { return {} },
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			if ui.surface.tag == 1 {
				// The known colour behind. Split, it gives the backdrop a real
				// range — which is the case `glass_worst` exists for: it solves
				// against the darkest *and* brightest part, so a backdrop with
				// both is where a report that flattens the extremes would show.
				baldr.row(ui, flex = 1, gap = .none); defer baldr.end(ui)
				baldr.box(ui, flex = 1, bg = s.behind)
				if s.split do baldr.box(ui, flex = 1, bg = s.bright)
				return
			}
			th := ui.theme
			if !s.said && ui.tree.glass.known {
				s.said = true
				m := th.material[th.glass].panel
				fmt.printfln("behind       %v", s.behind)
				fmt.printfln("glass level  %v", th.glass)
				fmt.printfln("tint         rgb %.5f %.5f %.5f  alpha %.4f (linear, as stored)",
					m.tint.r, m.tint.g, m.tint.b, m.tint.a)
				fmt.printfln("backdrop     min %.4f avg %.4f max %.4f",
					ui.tree.glass.backdrop.min, ui.tree.glass.backdrop.avg, ui.tree.glass.backdrop.max)
				fmt.printfln("on_surface   %v", th.color.on_surface)
				fmt.printfln("surface      %v", th.color.surface)
				fmt.printfln("-- capture region \"%d,%d %dx%d\" and measure the panel's own background --",
					AT, AT, int(PATCH.x), int(PATCH.y))
			}
			baldr.column(ui, gap = .md, padding = .lg, flex = 1); defer baldr.end(ui)
			baldr.text(ui, "Body text on glass", role = .Title)
			baldr.text(ui, "Body text at the theme's own size, which is what 4.5:1 is for.")
		},
	})
}
