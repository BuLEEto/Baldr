// 02_theme_lab — a richer screen for judging themes and typefaces side by
// side: sidebar, headline, card with every button variant, chips, a live
// text input, a disabled danger button, and a visible focus ring.
//
//   ./build.sh example 02_theme_lab run [dark|dim|light|hc-dark|hc-light|solstice|aurora|paper|grey|grey-light|greys|greys-dim|greys-light|seed:<hue>]
//
// A second argument sets the theme's text in a family this machine has —
// the same door a desktop style or a readability setting uses, no rebuild:
//
//   ./build.sh example 02_theme_lab run dark "font:Liberation Sans"
//   ./build.sh example 02_theme_lab run light "font:Atkinson Hyperlegible,Liberation Mono"
//
// …against embedding another face at compile time, which is what the
// binary then carries and draws everywhere:
//
//   odin build examples/02_theme_lab -collection:baldr=. -out:build/lab_face \
//        -define:BALDR_UI_FONT=../path/to/Some-Variable.ttf
//
// (any variable .ttf or .otf, by a path relative to the output binary)
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "baldr:baldr"

State :: struct {
	count:    int,
	search:   baldr.Text, // edited in place by the text input
	searches: int,
}
Msg :: enum { Noop, Inc, Search }

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch m {
	case .Inc:    s.count += 1
	case .Search: s.searches += 1
	case .Noop:
	}
	return {}
}

nav_item :: proc(ui: ^baldr.Ui(Msg), label: string, selected := false) {
	th := ui.theme
	bg := th.color.primary_container if selected else baldr.Color{}
	baldr.row(ui, padding = .sm, gap = .sm, bg = bg, radius = th.radius.sm, align = .Center); defer baldr.end(ui)
	baldr.box(ui, width = 8, height = 8, radius = 4, bg = th.color.primary if selected else th.color.on_surface_muted)
	baldr.text(ui, label, role = .Label, color = th.color.on_primary_container if selected else th.color.on_surface)
}

chip :: proc(ui: ^baldr.Ui(Msg), label: string) {
	th := ui.theme
	baldr.row(ui, padding = .xs, bg = th.color.surface_high, radius = th.radius.full, align = .Center); defer baldr.end(ui)
	baldr.box(ui, width = 6)
	baldr.text(ui, label, role = .Caption)
	baldr.box(ui, width = 6)
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	th := ui.theme
	baldr.row(ui, flex = 1, align = .Stretch); defer baldr.end(ui)

	// sidebar
	baldr.column(ui, width = 200, padding = .lg, gap = .xs, bg = th.color.surface_variant); {
		defer baldr.end(ui)
		baldr.text(ui, "Baldr", role = .Title)
		baldr.spacer(ui, 12)
		nav_item(ui, "Overview", selected = true)
		nav_item(ui, "Projects")
		nav_item(ui, "Activity")
		nav_item(ui, "Settings")
	}

	// content
	baldr.column(ui, flex = 1, padding = .xl, gap = .lg); {
		defer baldr.end(ui)
		baldr.text(ui, "Good evening, Alex", role = .Headline)
		baldr.text(ui, "Three builds finished while you were away. Everything is green.", muted = true)

		// Frosted glass over vivid content: a stack with colour tiles behind a
		// glass card. With reduce-transparency (BALDR_GLASS=0) the card is opaque.
		baldr.stack(ui, height = 170); {
			defer baldr.end(ui)
			baldr.row(ui, gap = .sm, height = 170, align = .Stretch); {
				defer baldr.end(ui)
				tiles := [?]u32{0xE5484D, 0xF2B544, 0x22C55E, 0x3B82F6, 0x8B5CF6, 0xEC4899}
				for c in tiles do baldr.box(ui, flex = 1, bg = baldr.rgb(c), radius = th.radius.md)
			}
			baldr.card(ui, glass = true, width = 340, offset = {36, 28}, elevation = .High); {
				defer baldr.end(ui)
				baldr.text(ui, "Frosted glass", role = .Title)
				baldr.text(ui, "The tiles behind this card are blurred by the renderer, then tinted with the theme's popover material.", muted = true)
				baldr.row(ui, gap = .sm); {
					defer baldr.end(ui)
					baldr.button(ui, "Nice", Msg.Inc)
					baldr.button(ui, "Later", Msg.Noop, variant = .Ghost)
				}
			}
		}

		baldr.card(ui); {
			defer baldr.end(ui)
			baldr.text(ui, "Project Baldr", role = .Title)
			baldr.text(ui, fmt.tprintf("Retained-mode GUI for Odin. %d nudges so far.", s.count), muted = true)
			baldr.row(ui, gap = .sm, align = .Center); {
				defer baldr.end(ui)
				b := baldr.button(ui, "Continue", Msg.Inc)
				baldr.button(ui, "Preview", Msg.Noop, variant = .Secondary)
				baldr.button(ui, "Settings", Msg.Noop, variant = .Outline)
				baldr.button(ui, "Skip", Msg.Noop, variant = .Ghost)
				if ui.focus == baldr.NODE_NONE do baldr.set_focus(&ui.tree, b, true) // show a ring until the user takes over
			}
		}

		baldr.row(ui, gap = .sm); {
			defer baldr.end(ui)
			chip(ui, "Wayland")
			chip(ui, "Vulkan")
			chip(ui, "Pure Odin")
			chip(ui, "Retained")
		}

		// a real text field: click, type, select, Enter submits
		baldr.row(ui, gap = .sm, align = .Center); {
			defer baldr.end(ui)
			baldr.text_input(ui, &s.search, placeholder = "Search everything…", label = "Search", on_submit = Msg.Search, flex = 1)
			baldr.button(ui, "Search", Msg.Search, variant = .Secondary)
		}
		if s.searches > 0 do baldr.text(ui, fmt.tprintf("Searched for “%s” (%d so far)", baldr.str(s.search), s.searches), muted = true)

		baldr.row(ui, gap = .sm); {
			defer baldr.end(ui)
			baldr.button(ui, "Delete", Msg.Noop, variant = .Danger, disabled = true)
			baldr.button(ui, "Archive", Msg.Noop, variant = .Outline)
		}
	}
}

solstice :: proc() -> baldr.Theme {
	th := baldr.theme_dark()
	th.name = "Solstice"
	c := &th.color
	c.bg = baldr.rgb(0x0F1115); c.surface = baldr.rgb(0x171A21); c.surface_variant = baldr.rgb(0x1C2028); c.surface_high = baldr.rgb(0x262B36)
	c.on_bg = baldr.rgb(0xF2EFE8); c.on_surface = baldr.rgb(0xF2EFE8); c.on_surface_muted = baldr.rgb(0x9A9890)
	c.primary = baldr.rgb(0xF2B544); c.on_primary = baldr.rgb(0x1A1300); c.primary_container = baldr.rgb(0x3A2E10); c.on_primary_container = baldr.rgb(0xFFE2A0)
	c.outline = baldr.rgb(0x2B303B); c.outline_variant = baldr.rgb(0x222630); c.focus_ring = baldr.rgb(0xF2B544)
	c.danger = baldr.rgb(0xE5484D); c.shadow = baldr.rgb(0x000000, 0.55)
	th.radius.md, th.radius.lg = 10, 14
	return th
}

aurora :: proc() -> baldr.Theme {
	th := baldr.theme_dark()
	th.name = "Aurora"
	c := &th.color
	c.bg = baldr.rgb(0x0B0E17); c.surface = baldr.rgb(0x131828); c.surface_variant = baldr.rgb(0x171D2F); c.surface_high = baldr.rgb(0x212A40)
	c.on_bg = baldr.rgb(0xE8ECF8); c.on_surface = baldr.rgb(0xE8ECF8); c.on_surface_muted = baldr.rgb(0x8B93AD)
	c.primary = baldr.rgb(0x7C8CFF); c.on_primary = baldr.rgb(0x0B0E17); c.primary_container = baldr.rgb(0x2A3270); c.on_primary_container = baldr.rgb(0xD8DDFF)
	c.outline = baldr.rgb(0x26304A); c.outline_variant = baldr.rgb(0x1C2438); c.focus_ring = baldr.rgb(0xA8B4FF)
	c.shadow = baldr.rgb(0x000000, 0.55)
	th.radius.md, th.radius.lg = 10, 14
	return th
}

paper :: proc() -> baldr.Theme {
	th := baldr.theme_light()
	th.name = "Paper"
	c := &th.color
	c.bg = baldr.rgb(0xF6F3EE); c.surface = baldr.rgb(0xFFFFFF); c.surface_variant = baldr.rgb(0xEEEAE2); c.surface_high = baldr.rgb(0xFFFFFF)
	c.on_bg = baldr.rgb(0x1C1B18); c.on_surface = baldr.rgb(0x1C1B18); c.on_surface_muted = baldr.rgb(0x6B665C)
	c.primary = baldr.rgb(0xD4901F); c.on_primary = baldr.rgb(0x201700); c.primary_container = baldr.rgb(0xFBE6B8); c.on_primary_container = baldr.rgb(0x4A3200)
	c.outline = baldr.rgb(0xD9D2C5); c.outline_variant = baldr.rgb(0xE8E2D6); c.focus_ring = baldr.rgb(0xB8741A)
	c.shadow = baldr.rgb(0x2A2010, 0.18)
	th.radius.md, th.radius.lg = 10, 14
	return th
}

// The greys of an older desktop theme being reproduced: a window, views
// that sit darker than it, and a flat grey selection.
given_greys :: proc(mode: baldr.Theme_Mode) -> baldr.Theme_Palette {
	switch mode {
	case .Light:
		return {
			bg = baldr.rgb(0xcecece), surface = baldr.rgb(0xfcfcfc), surface_variant = baldr.rgb(0xe4e4e4), surface_high = baldr.rgb(0xf5f5f5),
			on_bg = baldr.rgb(0x3c3c3c), on_surface = baldr.rgb(0x212121), on_surface_muted = baldr.rgb(0x858585),
			outline = baldr.rgb(0x828282), primary = baldr.rgb(0x8d8d8d), on_primary = baldr.rgb(0xffffff),
		}
	case .Dim:
		return {
			bg = baldr.rgb(0x4a4d4f), surface = baldr.rgb(0x3c3e40), surface_variant = baldr.rgb(0x44474a), surface_high = baldr.rgb(0x56595c),
			on_bg = baldr.rgb(0xeeeeee), on_surface = baldr.rgb(0xf6f6f6), on_surface_muted = baldr.rgb(0xa3a4a5),
			outline = baldr.rgb(0x2a2c2d), primary = baldr.rgb(0x9a9a9a), on_primary = baldr.rgb(0xffffff),
		}
	case .Dark:
		return {
			bg = baldr.rgb(0x3b3e3f), surface = baldr.rgb(0x2d2e30), surface_variant = baldr.rgb(0x353839), surface_high = baldr.rgb(0x45484a),
			on_bg = baldr.rgb(0xeeeeee), on_surface = baldr.rgb(0xffffff), on_surface_muted = baldr.rgb(0x959697),
			outline = baldr.rgb(0x1d1f1f), primary = baldr.rgb(0x949494), on_primary = baldr.rgb(0xffffff),
		}
	}
	return {}
}

main :: proc() {
	name := os.args[1] if len(os.args) > 1 else "dark"
	th: baldr.Theme
	switch name {
	case "light":    th = baldr.theme_light()
	case "dim":      th = baldr.theme_dim()
	case "hc-dark":  th = baldr.theme_high_contrast(.Dark)
	case "hc-light": th = baldr.theme_high_contrast(.Light)
	// A desktop that has chosen no colour: a neutral grey accent gives a
	// monochrome theme rather than a blue one.
	case "grey":       th = baldr.theme_from_seed(baldr.rgb(0x8a8a8a), .Dark, name = "Grey")
	case "grey-light": th = baldr.theme_from_seed(baldr.rgb(0x8a8a8a), .Light, name = "Grey Light")
	// …and a style whose greys are a design of their own, given outright
	// rather than generated: everything else is derived from them.
	case "greys":       th = baldr.theme_from_palette(given_greys(.Dark), .Dark, name = "Given Greys")
	case "greys-dim":   th = baldr.theme_from_palette(given_greys(.Dim), .Dim, name = "Given Greys Dim")
	case "greys-light": th = baldr.theme_from_palette(given_greys(.Light), .Light, name = "Given Greys Light")
	case "solstice": th = solstice()
	case "aurora":   th = aurora()
	case "paper":    th = paper()
	case:
		th = baldr.theme_dark()
		if strings.has_prefix(name, "seed:") { // seed:<hue 0..360>[,light|dim]
			hue, _ := strconv.parse_f32(strings.split(name[5:], ",", context.temp_allocator)[0])
			mode := baldr.Theme_Mode.Dark
			if strings.has_suffix(name, ",light") do mode = .Light
			if strings.has_suffix(name, ",dim") do mode = .Dim
			th = baldr.theme_from_seed(baldr.oklch(0.6, 0.18, hue), mode, name = name)
		}
	}
	// "font:<family>[,<code family>]": the families the theme's text is set
	// in, as this machine names them. A family that is not installed draws
	// as the embedded face. Cloned, because the theme keeps the name rather
	// than copying it, and temp memory is gone by the first frame.
	for a in os.args[1:] {
		if !strings.has_prefix(a, "font:") do continue
		names := strings.split(a[5:], ",", context.temp_allocator)
		th.font_family = strings.clone(strings.trim_space(names[0]))
		if len(names) > 1 do th.mono_family = strings.clone(strings.trim_space(names[1]))
	}
	title := fmt.tprintf("Theme lab — %s", th.name)
	if th.font_family != "" do title = fmt.tprintf("Theme lab — %s in %s", th.name, th.font_family)
	err := baldr.run(baldr.App(State, Msg){
		title = title, app_id = "baldr.theme_lab", size = {760, 640},
		theme = th, update = update, view = view,
	})
	if err != .None do fmt.eprintln("exit:", err)
}
