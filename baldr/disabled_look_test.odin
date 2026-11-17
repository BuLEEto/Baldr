package baldr

@(require) import "core:fmt"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Every control that takes `disabled` reads as unavailable at a glance: the
// brightest text or icon it draws is dimmed.


@(private = "file")
DisabledLook_AMsg :: enum { None, Go }

@(private = "file")
Look_Case :: struct {
	name:   string,
	build:  proc(ui: ^Ui(DisabledLook_AMsg), disabled: bool, doc: ^Document),
	shapes: bool, // no text or icon (a slider): compare its fills
}

@(private = "file")
LOOK_CASES := []Look_Case{
	{"button", proc(ui: ^Ui(DisabledLook_AMsg), disabled: bool, doc: ^Document) { button(ui, "Go", DisabledLook_AMsg.Go, variant = .Outline, icon = .Check, disabled = disabled) }, false},
	{"chip", proc(ui: ^Ui(DisabledLook_AMsg), disabled: bool, doc: ^Document) { chip(ui, "Wayland", icon = .Check, disabled = disabled) }, false},
	{"menu_chip", proc(ui: ^Ui(DisabledLook_AMsg), disabled: bool, doc: ^Document) { menu_chip(ui, "Speakers", false, DisabledLook_AMsg.Go, disabled = disabled) }, false},
	{"checkbox", proc(ui: ^Ui(DisabledLook_AMsg), disabled: bool, doc: ^Document) { checkbox(ui, true, "Show hidden files", disabled = disabled) }, false},
	{"toggle", proc(ui: ^Ui(DisabledLook_AMsg), disabled: bool, doc: ^Document) { toggle(ui, true, "Preview", disabled = disabled) }, false},
	{"radio", proc(ui: ^Ui(DisabledLook_AMsg), disabled: bool, doc: ^Document) { radio(ui, 0, {"Ask", "Replace"}, label = "Conflicts", disabled = disabled) }, false},
	{"segmented", proc(ui: ^Ui(DisabledLook_AMsg), disabled: bool, doc: ^Document) { segmented(ui, 0, {"List", "Icons"}, label = "View", disabled = disabled) }, false},
	{"select", proc(ui: ^Ui(DisabledLook_AMsg), disabled: bool, doc: ^Document) { select(ui, 0, {"Name", "Size"}, label = "Sort", disabled = disabled) }, false},
	{"text_input", proc(ui: ^Ui(DisabledLook_AMsg), disabled: bool, doc: ^Document) { text_input(ui, nil, initial = "notes.txt", label = "Name", disabled = disabled) }, false},
	{"number_input", proc(ui: ^Ui(DisabledLook_AMsg), disabled: bool, doc: ^Document) { number_input(ui, 12, label = "Size", disabled = disabled) }, false},
	{"slider", proc(ui: ^Ui(DisabledLook_AMsg), disabled: bool, doc: ^Document) { slider(ui, 0.5, label = "Zoom", disabled = disabled) }, true},
	{"color_field", proc(ui: ^Ui(DisabledLook_AMsg), disabled: bool, doc: ^Document) { color_field(ui, rgb(0x3366cc), label = "Accent", disabled = disabled) }, false},
	{"date_field", proc(ui: ^Ui(DisabledLook_AMsg), disabled: bool, doc: ^Document) { date_field(ui, Date{2026, 9, 13}, label = "Date", disabled = disabled) }, false},
	{"time_field", proc(ui: ^Ui(DisabledLook_AMsg), disabled: bool, doc: ^Document) { time_field(ui, Time_Of_Day{9, 30, 0, 0}, label = "Time", disabled = disabled) }, false},
	{"time_picker", proc(ui: ^Ui(DisabledLook_AMsg), disabled: bool, doc: ^Document) { time_picker(ui, Time_Of_Day{9, 30, 0, 0}, label = "Time", disabled = disabled) }, false},
	{"text_area", proc(ui: ^Ui(DisabledLook_AMsg), disabled: bool, doc: ^Document) { text_area(ui, doc, label = "Notes", disabled = disabled) }, false},
	{"code_editor", proc(ui: ^Ui(DisabledLook_AMsg), disabled: bool, doc: ^Document) { code_editor(ui, doc, label = "Code", height = 80, disabled = disabled) }, false},
	{"rich_text", proc(ui: ^Ui(DisabledLook_AMsg), disabled: bool, doc: ^Document) { rich_text(ui, doc, label = "Rich", height = 80, disabled = disabled) }, false},
	{"markdown_editor", proc(ui: ^Ui(DisabledLook_AMsg), disabled: bool, doc: ^Document) { markdown_editor(ui, doc, label = "Markdown", height = 80, disabled = disabled) }, false},
	{"tree_item", proc(ui: ^Ui(DisabledLook_AMsg), disabled: bool, doc: ^Document) {
		tree_view(ui, label = "Places", key = 1)
		tree_item(ui, "Home", DisabledLook_AMsg.Go, icon = .Check, disabled = disabled)
		end(ui)
	}, false},
	{"menu_item", proc(ui: ^Ui(DisabledLook_AMsg), disabled: bool, doc: ^Document) {
		if context_menu(ui, true, DisabledLook_AMsg.None) {
			menu_item(ui, "Rename", DisabledLook_AMsg.Go, shortcut = "F2", icon = .Check, disabled = disabled)
			end(ui)
		}
	}, false},
	{"submenu", proc(ui: ^Ui(DisabledLook_AMsg), disabled: bool, doc: ^Document) {
		if context_menu(ui, true, DisabledLook_AMsg.None) {
			if submenu(ui, "Sort by", icon = .Check, disabled = disabled) do end(ui)
			end(ui)
		}
	}, false},
}

// brightest is the brightest text or icon drawn: luminance × alpha.
@(private = "file")
brightest :: proc(ui: ^Ui(DisabledLook_AMsg), shapes: bool) -> (best: f32) {
	lum :: proc(c: Color) -> f32 { return (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b) * c.a }
	for c in draw_list(&ui.tree) {
		#partial switch v in c {
		case Draw_Text: best = max(best, lum(v.color))
		case Draw_Icon: best = max(best, lum(v.color))
		case Draw_Rect: if shapes do best = max(best, lum(v.color))
		}
	}
	return
}

@(private = "file")
look_of :: proc(c: Look_Case, disabled: bool, doc: ^Document) -> f32 {
	ui: Ui(DisabledLook_AMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	now := 1000.0
	for _ in 0 ..< 30 { // past any entrance (a menu fades in)
		set_viewport(&ui.tree, {600, 400})
		begin_view(&ui)
		column(&ui, padding = .md, gap = .sm)
		c.build(&ui, disabled, doc)
		end(&ui)
		end_view(&ui)
		frame(&ui.tree, {600, 400})
		now += 16
		ui_tick(&ui, now)
	}
	return brightest(&ui, c.shapes)
}

@(test)
disabled_controls_read_as_unavailable :: proc(t: ^testing.T) {
	doc := document_make("fn main() {}") // this test's own: tests run in parallel
	defer document_destroy(&doc)
	da := theme_dark().state.disabled_alpha
	for c in LOOK_CASES {
		on, off := look_of(c, false, &doc), look_of(c, true, &doc)
		testing.expectf(t, on > 0, "%s: draws no text or icon to compare", c.name)
		testing.expectf(t, off <= on * 0.8, "%s: disabled is as bright as enabled (%.3f vs %.3f)", c.name, off, on)
		testing.expectf(t, off >= on * da * da * 1.2, "%s: disabled is dimmed twice over (%.3f vs %.3f)", c.name, off, on)
	}
	_ = fmt.tprint
}

// The control's own box dims with its label: fill, the gradient's second
// stop (Primary), the outline (Outline).
@(test)
disabled_buttons_dim_their_gradient_and_outline :: proc(t: ^testing.T) {
	box :: proc(variant: Button_Variant, disabled: bool) -> Draw_Rect {
		ui: Ui(DisabledLook_AMsg)
		ui_init(&ui)
		defer ui_destroy(&ui)
		set_viewport(&ui.tree, {300, 100})
		begin_view(&ui)
		column(&ui, padding = .md, align = .Start)
		b := button(&ui, "Go", DisabledLook_AMsg.Go, variant = variant, disabled = disabled)
		end(&ui)
		end_view(&ui)
		frame(&ui.tree, {300, 100})
		r := node_get(&ui.tree, b).abs
		for c in draw_list(&ui.tree) do if q, ok := c.(Draw_Rect); ok && q.rect == r do return q
		return {}
	}
	da := theme_dark().state.disabled_alpha
	on, off := box(.Primary, false), box(.Primary, true)
	testing.expectf(t, on.color2.a > 0 && abs(off.color2.a - on.color2.a * da) < 0.01, "the gradient dims (%v vs %v)", off.color2.a, on.color2.a)
	on, off = box(.Outline, false), box(.Outline, true)
	testing.expectf(t, on.border.a > 0 && abs(off.border.a - on.border.a * da) < 0.01, "the outline dims (%v vs %v)", off.border.a, on.border.a)
}

// A control that stops being disabled must be drawn again, not merely
// become clickable. The dimming is decided at paint time (`dim`,
// `disabled_within`), so the style does not change with the flag, and unless
// the node is marked paint-dirty its layer resubmits the grey list it cached.
//
// The first half keeps the test from passing vacuously: a frame that changed
// nothing must rebuild no layer, or the cache is not in play. REPAINTS_AT_REST
// are the controls whose custom painters read state from elsewhere in the
// tree and so repaint on every build; their dimming is still checked, but not
// whether the flag alone would repaint them.
@(test)
a_control_that_stops_being_disabled_is_drawn_again :: proc(t: ^testing.T) {
	doc := document_make("fn main() {}") // this test's own: tests run in parallel
	defer document_destroy(&doc)
	REPAINTS_AT_REST := []string{"toggle", "color_field", "text_area", "code_editor", "rich_text", "markdown_editor"}
	for c in LOOK_CASES {
		if c.name == "menu_item" || c.name == "submenu" do continue // an overlay of their own, which fades
		cached := true
		for name in REPAINTS_AT_REST do if name == c.name do cached = false
		for start in ([2]bool{true, false}) {
			ui: Ui(DisabledLook_AMsg)
			ui_init(&ui)
			defer ui_destroy(&ui)
			// The clock has to run, or an animation that never settles —
			// a toggle's knob, an editor's caret — repaints every frame and
			// the cache is never in play.
			now := 1000.0
			build :: proc(ui: ^Ui(DisabledLook_AMsg), c: Look_Case, disabled: bool, doc: ^Document, now: ^f64) {
				set_viewport(&ui.tree, {600, 400})
				begin_view(ui)
				column(ui, padding = .md, gap = .sm)
				c.build(ui, disabled, doc)
				end(ui)
				end_view(ui)
				frame(&ui.tree, {600, 400})
				now^ += 16
				ui_tick(ui, now^)
			}
			for _ in 0 ..< 30 do build(&ui, c, start, &doc, &now)
			was := brightest(&ui, c.shapes)

			ui.tree.stats = {}
			build(&ui, c, start, &doc, &now) // the same view again: the cache must hold
			at_rest := ui.tree.stats.layers_rebuilt
			testing.expectf(t, (at_rest == 0) == cached,
				"%s (from %v): rebuilt %d layer(s) with nothing changed; REPAINTS_AT_REST says %v",
				c.name, start, at_rest, !cached)

			ui.tree.stats = {}
			build(&ui, c, !start, &doc, &now)
			if cached {
				testing.expectf(t, ui.tree.stats.layers_rebuilt > 0,
					"%s: disabled %v -> %v repainted nothing", c.name, start, !start)
			}
			lit := brightest(&ui, c.shapes)
			testing.expectf(t, abs(lit - was) > was * 0.1,
				"%s: disabled %v -> %v left it drawn the same (%.3f, was %.3f)", c.name, start, !start, lit, was)
		}
	}
}

// Every control fades with what it sits in (a closing dialog).
// Built under a half-transparent column, nothing it draws may be more
// opaque than half.
@(test)
controls_fade_with_their_container :: proc(t: ^testing.T) {
	doc := document_make("fn main() {}") // this test's own: tests run in parallel
	defer document_destroy(&doc)
	for c in LOOK_CASES {
		if c.name == "menu_item" || c.name == "submenu" do continue // in an overlay, not under the column
		ui: Ui(DisabledLook_AMsg)
		ui_init(&ui)
		set_viewport(&ui.tree, {600, 400})
		begin_view(&ui)
		col := column(&ui, padding = .md, gap = .sm)
		c.build(&ui, false, &doc)
		end(&ui)
		end_view(&ui)
		st := node_get(&ui.tree, col).style
		st.opacity = 0.5
		set_style(&ui.tree, col, st)
		frame(&ui.tree, {600, 400})
		worst: f32
		for cmd in draw_list(&ui.tree) {
			#partial switch v in cmd {
			case Draw_Rect:   worst = max(worst, v.color.a, v.color2.a, v.border.a if v.border_w > 0 else 0)
			case Draw_Text:   worst = max(worst, v.color.a)
			case Draw_Icon:   worst = max(worst, v.color.a)
			case Draw_Shadow: worst = max(worst, v.color.a)
			case Draw_Image:  worst = max(worst, v.color.a)
			case Draw_Wave:   worst = max(worst, v.color.a)
			}
		}
		testing.expectf(t, worst <= 0.5 + 1e-3, "%s: draws at alpha %.3f under a half-faded parent", c.name, worst)
		ui_destroy(&ui)
	}

	// a scroll paints into a layer of its own, which must fade too
	ui: Ui(DisabledLook_AMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {600, 400})
	begin_view(&ui)
	col := column(&ui, padding = .md)
	scroll(&ui, height = 80, padding = .sm)
	text(&ui, "fn main() {} in a scroll")
	end(&ui)
	end(&ui)
	end_view(&ui)
	st := node_get(&ui.tree, col).style
	st.opacity = 0.5
	set_style(&ui.tree, col, st)
	frame(&ui.tree, {600, 400})
	seen := false
	for cmd in draw_list(&ui.tree) {
		if q, ok := cmd.(Draw_Text); ok {
			seen = true
			testing.expectf(t, q.color.a <= 0.5 + 1e-3, "text in a scroll draws at alpha %.3f under a half-faded parent", q.color.a)
		}
	}
	testing.expect(t, seen, "the scroll's text is drawn")
}

} // when ODIN_TEST