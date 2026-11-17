package baldr

import "baldr:platform"

// Theme is plain data: semantic colour roles, state-layer strengths, radii,
// a spacing scale, a type scale, and motion tokens. Widgets read tokens; they
// never hold literal colours. Dark and light ship in-tree; a custom theme is a
// struct literal or a copy of one of these with fields changed. Colours are
// authored in sRGB via rgb()/rgba() and stored linear.

// Theme is everything a widget needs to draw itself consistently: colour
// roles, state layers, a corner-radius ladder, the spacing scale, a type
// scale, motion timings, elevation and glass materials. An app usually sets
// none of it — the default follows the desktop's light/dark, accent and
// contrast — and reads it when drawing something of its own
// (`ui.tree.theme`).
//
// Three ways in, in increasing order of "and then it follows nothing":
// `App.accent` gives a brand colour the theme is generated from, still
// following the desktop; `App.adjust_theme` is the app's last word on every
// theme the runtime hands it, which is the right door for a style knob
// because it survives a light/dark switch and an in-app theme picker; and
// `App.theme` names one outright. `set_theme` changes a tree's theme while
// it runs.
//
// The knobs an app most often turns in `adjust_theme`: `font_family` and
// `mono_family`, the faces all its text and its code are set in;
// `type.<step>.family`, a face of its own for one step of the type scale —
// headings on `display` / `headline` / `title`, every control's label on
// `label` (Text_Style); `radius`, the corner ladder; and `min_target`, the
// smallest a control is laid out across and down, 44 for targets anyone can
// hit.
Theme :: struct {
	name:    string,
	dark:    bool,          // Dim and Dark modes
	mode:    Theme_Mode,
	contrast: Theme_Contrast,
	seed:    Color,         // the accent it was made from (theme_from_seed); Clear glass takes its text families from it (zero: the theme's own colours only)
	// The families its text is set in, named as this machine has them
	// (`installed_fonts`): "" is the face embedded in the binary — Inter,
	// and JetBrains Mono for the code one. Everything the toolkit draws
	// follows them; a family this machine has not got draws as the embedded
	// face, with no error. The strings are the app's,
	// as `name` is: valid when the theme is installed, and copied then.
	font_family: string,
	mono_family: string,
	color:   Color_Roles,
	state:   State_Layers,
	radius:  Radii,
	space:   [Space_Token]f32, // logical px per token
	type:    Type_Scale,
	motion:  Motion,
	elev:    Elevation,
	glass:   Glass_Level,   // how much desktop shows through glass; reduce transparency and high contrast make it Solid and opaque
	material: [Glass_Level]Materials, // every level's materials, tuned for the mode; material[glass] is the one in use
	density: f32, // control heights: 0 comfortable, -1 compact, +1 spacious (DENSITY_STEP a unit; fractions too)
	// The smallest an interactive control is laid out, across and down, in
	// logical px, whatever the pointer: buttons, checkboxes, switches,
	// sliders, fields, selects, tabs, menu items, list and tree rows. 0 is
	// the toolkit's own sizes (a button about 32 px tall, a checkbox 26);
	// 44 is what the accessibility guidelines ask for. A control grows to it
	// with its content centred, and one given a fixed `width` or `height`
	// keeps it.
	min_target: f32,
	// Component styles (theme_style.odin): every field nil derives from the
	// tokens above, so set only what you change — `th.button.radius = 4`.
	button:      Button_Style,
	icon_toggle: Icon_Toggle_Style,
	field:       Field_Style,
	check:       Check_Style,
	toggle:      Toggle_Style,
	slider:      Slider_Style,
	segmented:   Segmented_Style,
	list_row:    List_Row_Style,
	tree_row:    Tree_Row_Style,
	table:       Table_Style,
	icon_view:   Icon_View_Style,
	tab:         Tab_Style,
	menu:        Menu_Style,
	menu_bar:    Menu_Bar_Style,
	chip:        Chip_Style,
	menu_chip:   Menu_Chip_Style,
	separator:   Separator_Style,
	card:        Card_Style,
	dialog:      Dialog_Style,
	popover:     Popover_Style,
	tooltip:     Tooltip_Style,
	toast:       Toast_Style,
	scrollbar:   Scrollbar_Style,
	split:       Split_Style,
	focus_ring:  Focus_Ring_Style,
}

// Glass_Level: one glass setting for every theme. Clear shows the most
// desktop, with a soft glow behind text and icons; Frosted (the default) a
// milky blur; Solid a near-opaque tint and no blur. Each level is tuned per
// mode, so Clear looks as clear in Light as in Dark, and on a glass surface
// the tint rises only as far as its text needs to read over what is behind
// it (glass.odin).
Glass_Level :: enum u8 { Clear, Frosted, Solid }

// Materials: frosted-glass presets per surface class. `window` and `panel`
// also tint whole surfaces over the blurred desktop (behind-window blur).
// `glow` goes behind text and icons that sit on glass (Clear only).
Materials :: struct {
	popover, sidebar, sheet, panel, window: Material,
	glow: Glow,
}

// Glow: a soft halo of `color` behind text and icons, blurred over `radius`
// logical px (at most GLOW_MAX_RADIUS). Zero = none.
Glow :: struct {
	color:  Color,
	radius: f32,
	passes: int, // how many times it is laid down (0 or 1: once). A blur of a glyph is thin stuff — an outline that has to carry white text over a white wallpaper needs several
}

// Elevation: drop-shadow presets. Colour comes from color.shadow.
Elevation :: struct {
	low, mid, high: Shadow_Style,
}

// Color_Roles is a theme's palette by *job* rather than by hue: what a
// surface is, what goes on top of it, and what each state and accent means.
// A widget asks for the role it needs — `surface_variant` for a well,
// `on_surface` for text on a card — so one theme change recolours everything
// coherently and the contrast ratios hold in light, dark and high contrast.
//
// The accent is two roles because it does two jobs. `primary` is the accent
// as a *fill*: a selection, a switched-on toggle, a Primary button, a
// progress bar, a focus ring. `accent_text` is the accent as *ink*: a ghost
// button's label and icon, a breadcrumb's current place, a link, an unread
// count. Every generated theme sets them to the same colour; they differ only
// for a style whose accent reads well as a fill and badly as text, as a mid
// grey does. `accent_text` is always at least 4.5:1 on `surface`.
Color_Roles :: struct {
	bg:                   Color, // window background
	surface:              Color, // cards, sheets
	surface_variant:      Color, // inputs, wells
	surface_high:         Color, // popovers, elevated
	on_bg:                Color,
	on_surface:           Color,
	on_surface_muted:     Color, // secondary text
	primary:              Color,
	on_primary:           Color,
	primary_container:    Color,
	on_primary_container: Color,
	// accent_text is the accent drawn as ink, where `primary` is the accent
	// drawn as a fill (see above). Always 4.5:1 on `surface`, the bar the
	// text roles meet.
	accent_text:          Color,
	secondary:            Color,
	on_secondary:         Color,
	danger:               Color,
	on_danger:            Color,
	warning:              Color,
	success:              Color,
	fill:                 Color, // a faint fill of the content colour that reads on any surface or glass: tiles, chips
	fill_strong:          Color, // …a stronger one: slider tracks, switched-off toggles, a tile's controls
	outline:              Color, // borders
	outline_variant:      Color, // dividers
	focus_ring:           Color,
	selection:            Color, // a 35 % wash of the accent, for an app drawing its own selection. No widget draws with it: it falls under the 3:1 a change of state wants, so the toolkit's selections are `primary` with the text in `on_primary` (selection_paint.odin)
	scrim:                Color,
	shadow:               Color,
	code:                 Code_Colors, // syntax colours over surface_variant (the editor's well)
}

// Code_Colors: one colour per token kind, each readable (≥ 4.5:1) over
// surface_variant; derived from the seed hue so a themed app's editor
// belongs to the app. `current_line` is the caret line's wash, `gutter`
// the line numbers, `match` the bracket-pair box.
Code_Colors :: struct {
	keyword, type, string, number, comment, operator, punct, constant, attribute: Color,
	current_line, gutter, gutter_current, match: Color,
}

// State_Layers: how strongly interaction states mix `on_surface` over a
// control's colour (0..1), and the alpha applied to disabled controls.
State_Layers :: struct {
	hover, press, focus, drag: f32,
	disabled_alpha:            f32,
}

// Radii: the corner radii a theme draws with, from `none` to `xl`, and
// `full` for a pill — a shape whose ends want to be round. Every theme in
// the toolkit sets `full` to 9999, which is "as round as the shape allows";
// a theme with square corners sets it low, and the pills follow. What is
// round on purpose — a switch's knob, a slider's thumb, a radio, a dot, a
// swatch, an avatar — does not read `full` at all.
Radii :: struct {
	none, xs, sm, md, lg, xl, full: f32,
}

// pill_radius is the radius of a shape drawn as a pill `h` tall: half its
// height, unless the theme's `full` is smaller, in which case it is the
// theme's. A shape that hard-codes `h / 2` cannot be squared by a theme and
// so is a pill in a square-cornered desktop; one that goes through here
// matches the buttons and fields around it.
@(private)
pill_radius :: proc "contextless" (th: ^Theme, h: f32) -> f32 {
	return min(th.radius.full, h / 2)
}

// Text_Style is one step of the type scale: font size (logical px),
// line-height multiplier, the role's weight, and the family it is set in.
//
// `family` is for a design whose headings or control labels are set in a
// face of their own: name it on `display`, `headline` and `title` for the
// headings, on `label` for what the toolkit sets at that step (button, tab,
// chip, segmented and menu-bar labels, table headers, breadcrumbs,
// tooltips). "" is the theme's `font_family`. It is named as `font_family`
// is — a family this machine has, or one registered with
// `text_family_bytes` — and one that cannot be found draws as
// `font_family`, with no error. Body text, fields and editors follow
// `font_family` itself. The string is the app's, as `font_family`'s is.
Text_Style :: struct {
	size, line_height: f32,
	weight:            Font_Weight,
	family:            string,
}
// Type_Scale is the theme's six text styles, one per `Text_Role`.
// `text_style(th, role)` is how a widget asks for one.
Type_Scale :: struct {
	display, headline, title, body, label, caption: Text_Style,
}

// Text_Role is which step of the theme's type scale a text is set at: `Body`
// for prose, `Display` / `Headline` / `Title` for headings in decreasing
// size, `Label` for a control's own text, `Caption` for the smallest
// supporting text. Each carries a size, line height and weight from
// `Theme.type`, and every one of them follows the desktop's text-size
// setting — so reach for a role before a `size` in pixels.
Text_Role :: enum u8 { Body, Display, Headline, Title, Label, Caption }

text_style :: proc "contextless" (th: ^Theme, role: Text_Role) -> Text_Style {
	switch role {
	case .Display:  return th.type.display
	case .Headline: return th.type.headline
	case .Title:    return th.type.title
	case .Body:     return th.type.body
	case .Label:    return th.type.label
	case .Caption:  return th.type.caption
	}
	return th.type.body
}

// type_families is the family each step of a type scale names ("" for
// the theme's own).
@(private)
type_families :: proc "contextless" (ts: Type_Scale) -> [Text_Role]string {
	return {.Body = ts.body.family, .Display = ts.display.family, .Headline = ts.headline.family, .Title = ts.title.family, .Label = ts.label.family, .Caption = ts.caption.family}
}

// role_family is the Family_Id a text at `role` asks for when it names
// none of its own: 0 when the theme sets that step in its own family, and
// otherwise one that stands for "the family the theme names for this
// step", which the engine resolves when the text is measured and drawn
// (family_now). Resolved then rather than now, so a family that arrives
// with the font list, or that the app registers after the view was built,
// is drawn without the view being built again.
@(private)
role_family :: proc "contextless" (th: ^Theme, role: Text_Role) -> Family_Id {
	return FAMILY_OF_ROLE + Family_Id(role) if text_style(th, role).family != "" else 0
}

// Motion durations in milliseconds; `reduce` mirrors the OS reduce-motion setting.
Motion :: struct {
	fast, base, slow: f32,
	reduce:           bool,
}

@(private)
theme_common :: proc(th: ^Theme) {
	th.state = {hover = 0.08, press = 0.14, focus = 0.12, drag = 0.16, disabled_alpha = 0.45}
	th.radius = {none = 0, xs = 4, sm = 6, md = 8, lg = 12, xl = 16, full = 9999}
	th.space = {.none = 0, .xxs = 2, .xs = 4, .sm = 8, .md = 12, .lg = 16, .xl = 24, .xxl = 32, .xxxl = 48}
	th.type = {
		display  = {size = 32, line_height = 1.20, weight = .Semibold},
		headline = {size = 24, line_height = 1.25, weight = .Semibold},
		title    = {size = 18, line_height = 1.30, weight = .Semibold},
		body     = {size = 15, line_height = 1.45, weight = .Regular},
		label    = {size = 13, line_height = 1.35, weight = .Semibold},
		caption  = {size = 12, line_height = 1.35, weight = .Regular},
	}
	th.motion = {fast = 100, base = 200, slow = 350}
	th.glass = .Frosted
}

// Glass_Recipe: one glass level in one mode: the bar's tint alpha, blur and
// saturation, the popover's, and the window's tint alpha.
@(private)
Glass_Recipe :: struct {
	panel_a, panel_blur, panel_sat, popover_a, popover_blur, popover_sat, window_a: f32,
}

// GLASS_RECIPES are the glass values per level and mode. Light takes
// materially less tint than Dim and Dark, and more saturation: what shows
// through is `1 - a` of the blurred desktop, and against a near-white tint
// everything behind lands within a few percent of white, so the variation the
// eye reads as depth goes much sooner than against a dark tint. A tint thin
// enough to look like glass stays readable because glass_adapt raises it as
// far as the text needs over what the compositor reports behind it, and
// takes the worst case where nothing is reported.
@(private)
GLASS_RECIPES :: [Glass_Level][Theme_Mode]Glass_Recipe{
	.Clear = {
		.Light = {0.14, 22, 2.1, 0.36, 26, 2.0, 0.48},
		.Dim   = {0.22, 22, 1.6, 0.50, 26, 1.5, 0.72},
		.Dark  = {0.24, 22, 1.6, 0.52, 26, 1.5, 0.72},
	},
	.Frosted = {
		.Light = {0.42, 36, 1.95, 0.50, 28, 1.85, 0.55},
		.Dim   = {0.62, 36, 1.4, 0.70, 28, 1.3, 0.82},
		.Dark  = {0.62, 36, 1.4, 0.72, 28, 1.3, 0.82},
	},
	.Solid = {
		.Light = {0.97, 0, 1, 0.98, 0, 1, 0.99},
		.Dim   = {0.97, 0, 1, 0.98, 0, 1, 0.99},
		.Dark  = {0.97, 0, 1, 0.98, 0, 1, 0.99},
	},
}

// Glass_Tokens are the design's alphas for glass, as a browser blends them
// (in sRGB): the faint and strong fills in the content colour (a tile,
// a track on it), a popover's 1 px edge, the rim along the top of glass on
// Frosted and Clear, and a popover's shadow. Baldr blends in linear light,
// so each converts to the alpha that lands where the design put it
// (glass_token_alpha); the shadow, black, needs none.
@(private)
Glass_Tokens :: struct {
	fill, fill_strong, edge, rim_frosted, rim_clear, shadow: f32,
}

@(private)
GLASS_TOKENS :: [Theme_Mode]Glass_Tokens{
	// Light's fills look weaker than Dim's here and are not: glass_token_alpha
	// converts them for the ink and glass they land on, and Light's dark ink
	// on light glass comes out at 0.115 against Dim's 0.029 — about the same
	// perceptual step. fill_strong is 0.09 to stay within 2x of Dark's step
	// in OKLab lightness. See also glass_fills_for.
	.Light = {fill = 0.045, fill_strong = 0.09, edge = 0.08, rim_frosted = 0.75, rim_clear = 0.95, shadow = 0.30},
	.Dim   = {fill = 0.07,  fill_strong = 0.12, edge = 0.07, rim_frosted = 0.10, rim_clear = 0.18, shadow = 0.40},
	.Dark  = {fill = 0.07,  fill_strong = 0.12, edge = 0.07, rim_frosted = 0.10, rim_clear = 0.18, shadow = 0.40},
}

GLOW_RADIUS     :: f32(5) // Clear's glow behind text and icons, logical px
GLOW_MAX_RADIUS :: f32(5.5) // what paint leaves room for around glowing text (GLOW_OVERHANG)

// theme_materials fills every glass level's materials from the recipes,
// tinted with the theme's own surface colours: bars and windows with bg,
// popovers with surface_high, sidebars with surface_variant, sheets with
// surface. Glass levels put a bright line along the top edge of bars,
// popovers and sheets, and give a popover a 1 px edge and a drop shadow, all
// from the design's tokens (GLASS_TOKENS); Clear adds a glow behind text in
// the opposite tone.
@(private)
theme_materials :: proc(th: ^Theme) {
	c := &th.color
	tint :: proc "contextless" (c: Color, a: f32) -> Color { return {c.r, c.g, c.b, a} }
	recipes := GLASS_RECIPES
	tokens := GLASS_TOKENS
	light := th.mode == .Light
	for level in Glass_Level {
		r := recipes[level][th.mode]
		glass := level != .Solid
		noise: f32 = 0.012 if glass else 0
		window_blur: f32 = 40 if glass else 0
		side_a := min(r.window_a - 0.10, 0.90) if glass else r.window_a
		th.material[level] = {
			popover = {tint = tint(c.surface_high, r.popover_a),  blur = r.popover_blur, saturation = r.popover_sat, noise = noise},
			sidebar = {tint = tint(c.surface_variant, side_a),    blur = window_blur * 0.8, saturation = 1.10 if glass else 1, noise = noise},
			sheet   = {tint = tint(c.surface, r.window_a),        blur = window_blur, saturation = r.popover_sat, noise = noise},
			panel   = {tint = tint(c.bg, r.panel_a),              blur = r.panel_blur, saturation = r.panel_sat, noise = noise},
			window  = {tint = tint(c.bg, r.window_a),             blur = window_blur, saturation = 1.15 if glass else 1, noise = noise},
		}
		if level == .Clear do th.material[level].glow = {color = {1, 1, 1, 0.70} if light else {0, 0, 0, 0.55}, radius = GLOW_RADIUS}
		if glass {
			ms := &th.material[level]
			tok := tokens[th.mode]
			rim := tok.rim_clear if level == .Clear else tok.rim_frosted
			ink := c.on_surface.rgb if light else [3]f32{1, 1, 1} // the edge: the content colour on light glass, white on dark
			edge := glass_token_alpha(ink, tok.edge, ms.popover.tint)
			ms.popover.edge = {ink.r, ink.g, ink.b, edge}
			ms.popover.highlight = {1, 1, 1, glass_token_alpha({1, 1, 1}, rim, ms.popover.tint, under_ink = ink, under = edge, under_token = tok.edge)} // over its edge, as the design lays it
			for m in ([]^Material{&ms.sheet, &ms.panel}) do m.highlight = {1, 1, 1, glass_token_alpha({1, 1, 1}, rim, m.tint)}
			ms.popover.shadow = {offset = {0, 16}, blur = 40, color = {0, 0, 0, tok.shadow}}
		}
	}
}

// theme_opaque makes glass Solid with every material fully opaque and no
// glow: what reduce transparency and high contrast ask for. For an app that
// reads its own reduce-transparency setting; the desktop's is folded in by
// the toolkit.
theme_opaque :: proc(th: ^Theme) {
	th.glass = .Solid
	for &ms in th.material {
		ms.popover.tint.a, ms.sidebar.tint.a, ms.sheet.tint.a, ms.panel.tint.a, ms.window.tint.a = 1, 1, 1, 1, 1
		ms.glow = {}
	}
}

@(private)
theme_elevation :: proc(th: ^Theme) {
	sh := th.color.shadow
	a := sh.a
	th.elev = {
		low  = {offset = {0, 1},  blur = 3,  color = {sh.r, sh.g, sh.b, a * 0.6}},
		mid  = {offset = {0, 6},  blur = 16, color = {sh.r, sh.g, sh.b, a}},
		high = {offset = {0, 16}, blur = 40, color = {sh.r, sh.g, sh.b, a}},
	}
}

// Theme_Mode picks the lightness family: Light for daylight rooms, Dim
// (a soft mid-dark, easier on the eyes than full dark for long sessions),
// Dark for low light and OLED.
Theme_Mode :: enum u8 { Light, Dim, Dark }

// Theme_Contrast: Normal meets WCAG AA/AAA for text; High pushes text and
// edges further apart for low vision and mirrors the OS high-contrast
// setting (it also turns glass off).
Theme_Contrast :: enum u8 { Normal, High }

// BALDR_BLUE is the default accent: a calm blue that reads well on both
// light and dark ground.
BALDR_BLUE :: Color{0.04, 0.22, 0.90, 1} // ≈ #3B82F6 in linear sRGB

// NEUTRAL_CODE_HUE is the hue the code palette is laid out around when the
// accent has none of its own to lend it — a neutral theme. It is a blue near
// the default accent's, so an editor on a grey theme keeps the syntax colours
// of the shipped themes.
@(private)
NEUTRAL_CODE_HUE :: f32(262)

// NEUTRAL_SEED_C is the seed chroma from which an accent is taken at full
// strength. Below it a theme fades toward neutral, reaching grey for a seed
// with no chroma at all — see theme_from_seed.
NEUTRAL_SEED_C :: f32(0.02)

// theme_dark, theme_dim and theme_light are the shipped defaults, generated
// from BALDR_BLUE; theme_high_contrast is their accessible counterpart.
theme_dark  :: proc() -> Theme { return theme_from_seed(BALDR_BLUE, .Dark, name = "Baldr Dark") }
theme_dim   :: proc() -> Theme { return theme_from_seed(BALDR_BLUE, .Dim, name = "Baldr Dim") }
theme_light :: proc() -> Theme { return theme_from_seed(BALDR_BLUE, .Light, name = "Baldr Light") }
theme_high_contrast :: proc(mode: Theme_Mode) -> Theme {
	return theme_from_seed(BALDR_BLUE, mode, .High, name = "Baldr High Contrast Light" if mode == .Light else "Baldr High Contrast Dark")
}

// theme_from_seed builds a complete theme from one accent colour: neutrals
// are tinted with the accent's hue at very low chroma (no pure black or
// white anywhere — comfortable on the eyes and consistent with the accent),
// surfaces step up in perceptual lightness per elevation tier, the accent
// is toned for the mode (lighter and softer on dark ground, deeper on
// light), and every text/background pair is pushed to at least AAA (7:1)
// for body text and AA (4.5:1) for secondary text and controls, so a theme
// made from any seed is readable by construction. Every value is in OKLCH,
// so the same recipe gives a matching family across hues.
//
// A seed with (almost) no chroma is a choice of no colour, and gives a
// neutral theme: the accent, its container, the focus ring and the
// selection come out grey, and the neutrals take no tint. Danger, warning
// and success keep their own hues, and so does the code palette, because
// those colours carry meaning rather than identity.
theme_from_seed :: proc(accent: Color, mode: Theme_Mode, contrast: Theme_Contrast = .Normal, name := "") -> (th: Theme) {
	_, seed_c, hue := oklch_of(accent)
	// `tint` is how much of the mode's chroma this seed asks for: 1 for any
	// ordinary accent, 0 for one with no colour in it, which is a choice of a
	// grey theme. The accent roles and the neutrals' tint fade together while
	// every lightness stays put, so each pair that carries text keeps its
	// contrast. A ramp rather than a threshold, because two seeds either side
	// of one look alike and must not give very different interfaces. The
	// semantic colours keep their own hues: a grey theme still warns in amber
	// and refuses in red.
	tint := clamp(seed_c / NEUTRAL_SEED_C, 0, 1)
	th.name = name if name != "" else "Custom"
	th.seed = accent
	th.mode = mode
	th.contrast = contrast
	th.dark = mode != .Light
	theme_common(&th)
	high := contrast == .High
	c := &th.color
	nc := 0.006 * tint // neutral tint chroma: none at all for a neutral seed
	switch mode {
	case .Dark:
		c.bg              = oklch(0.185, nc, hue)
		c.surface         = oklch(0.225, nc, hue)
		c.surface_variant = oklch(0.265, nc, hue)
		c.surface_high    = oklch(0.315, nc, hue)
		c.on_bg           = oklch(0.98 if high else 0.90, nc, hue)
		c.on_surface      = c.on_bg
		c.on_surface_muted = oklch(0.85 if high else 0.70, nc, hue)
		c.outline         = oklch(0.58 if high else 0.37, nc * 1.5, hue)
		c.outline_variant = oklch(0.46 if high else 0.30, nc * 1.5, hue)
		c.primary         = oklch(0.74, 0.13 * tint, hue)
		c.on_primary      = oklch(0.18, 0.04 * tint, hue)
		c.primary_container    = oklch(0.36, 0.09 * tint, hue)
		c.on_primary_container = oklch(0.93, 0.05 * tint, hue)
		c.secondary       = oklch(0.31, 0.02 * tint, hue)
		c.on_secondary    = oklch(0.92, nc, hue)
		c.danger          = oklch(0.68, 0.17, 25)
		c.on_danger       = oklch(0.15, 0.05, 25)
		c.warning         = oklch(0.78, 0.15, 75)
		c.success         = oklch(0.74, 0.14, 150)
		c.focus_ring      = oklch(0.90 if high else 0.80, 0.12 * tint, hue)
		c.selection       = oklch(0.60, 0.14 * tint, hue, 0.35)
		c.scrim           = {0, 0, 0, 0.5}
		c.shadow          = {0, 0, 0, 0.5}
	case .Dim:
		c.bg              = oklch(0.29, nc, hue)
		c.surface         = oklch(0.33, nc, hue)
		c.surface_variant = oklch(0.37, nc, hue)
		c.surface_high    = oklch(0.42, nc, hue)
		c.on_bg           = oklch(0.985 if high else 0.93, nc, hue)
		c.on_surface      = c.on_bg
		c.on_surface_muted = oklch(0.88 if high else 0.74, nc, hue)
		c.outline         = oklch(0.66 if high else 0.47, nc * 1.5, hue)
		c.outline_variant = oklch(0.55 if high else 0.41, nc * 1.5, hue)
		c.primary         = oklch(0.78, 0.12 * tint, hue)
		c.on_primary      = oklch(0.22, 0.04 * tint, hue)
		c.primary_container    = oklch(0.45, 0.08 * tint, hue)
		c.on_primary_container = oklch(0.95, 0.04 * tint, hue)
		c.secondary       = oklch(0.42, 0.02 * tint, hue)
		c.on_secondary    = oklch(0.94, nc, hue)
		c.danger          = oklch(0.72, 0.16, 25)
		c.on_danger       = oklch(0.18, 0.05, 25)
		c.warning         = oklch(0.80, 0.14, 75)
		c.success         = oklch(0.76, 0.13, 150)
		c.focus_ring      = oklch(0.92 if high else 0.84, 0.10 * tint, hue)
		c.selection       = oklch(0.64, 0.13 * tint, hue, 0.35)
		c.scrim           = {0, 0, 0, 0.45}
		c.shadow          = {0, 0, 0, 0.4}
	case .Light:
		// Light has no lightness left above a card, so the ladder is built
		// downwards from white: the window sits back in a light grey, a card
		// is near white, a popover is white, and the shadow (below) does the
		// work a dark theme does with lightness. An almost-white card on an
		// almost-white background is no card at all (1.06:1, where Dim's is
		// 1.16:1).
		c.bg              = oklch(0.938, nc * 0.8, hue)
		c.surface         = oklch(0.990, nc * 0.3, hue)
		c.surface_variant = oklch(0.965, nc, hue)
		c.surface_high    = oklch(1.000, 0, hue)
		c.on_bg           = oklch(0.12 if high else 0.25, nc, hue)
		c.on_surface      = c.on_bg
		c.on_surface_muted = oklch(0.32 if high else 0.50, nc, hue)
		c.outline         = oklch(0.62 if high else 0.83, nc * 2, hue)
		c.outline_variant = oklch(0.74 if high else 0.90, nc * 2, hue)
		c.primary         = oklch(0.56, 0.19 * tint, hue)
		c.on_primary      = oklch(0.99, 0.01 * tint, hue)
		c.primary_container    = oklch(0.92, 0.05 * tint, hue)
		c.on_primary_container = oklch(0.34, 0.12 * tint, hue)
		c.secondary       = oklch(0.92, 0.012 * tint, hue)
		c.on_secondary    = oklch(0.25, nc, hue)
		c.danger          = oklch(0.57, 0.20, 25)
		c.on_danger       = oklch(0.99, 0.01, 25)
		c.warning         = oklch(0.66, 0.16, 72)
		c.success         = oklch(0.60, 0.16, 150)
		c.focus_ring      = oklch(0.40 if high else 0.56, 0.19 * tint, hue)
		c.selection       = oklch(0.62, 0.17 * tint, hue, 0.30)
		c.scrim           = {0, 0, 0, 0.35}
		// A dark theme separates by lightness and hardly needs a shadow; a
		// light one has none to spend, so the shadow is its depth.
		c.shadow          = {0, 0, 0, 0.30}
	}
	theme_states(&th) // the hover and press washes: a step the eye judges, not an alpha
	code_colors(&th)
	if high {
		c.primary = oklch(0.86 if mode != .Light else 0.42, 0.14 * tint, hue)
		c.on_primary = oklch(0.12 if mode != .Light else 0.99, 0.02 * tint, hue)
		th.state.focus, th.state.drag, th.state.disabled_alpha = 0.20, 0.24, 0.55 // hover and press are solved above, with the high-contrast boost
	}
	// Readable by construction, whatever the seed.
	body: f32 = 10 if high else 7
	c.on_bg           = ensure_contrast(c.on_bg, c.bg, body)
	c.on_surface      = ensure_contrast(c.on_surface, c.surface, body)
	c.on_surface_muted = ensure_contrast(c.on_surface_muted, c.surface_variant, 7 if high else 4.5)
	c.on_primary      = ensure_contrast(c.on_primary, c.primary, 4.5)
	c.on_primary_container = ensure_contrast(c.on_primary_container, c.primary_container, 4.5)
	c.on_secondary    = ensure_contrast(c.on_secondary, c.secondary, 4.5)
	c.on_danger       = ensure_contrast(c.on_danger, c.danger, 4.5)
	c.primary         = ensure_contrast(c.primary, c.surface, 4.5) // as text: links, ghost buttons
	// A generated accent is picked for its mode and then moved until it
	// reads as text, so one colour serves both jobs here and the ink simply
	// follows the fill. A given accent cannot assume that — see
	// theme_from_palette.
	c.accent_text     = c.primary
	c.danger          = ensure_contrast(c.danger, c.surface, 3)
	c.focus_ring      = ensure_contrast(c.focus_ring, c.bg, 3)
	c.outline         = ensure_contrast(c.outline, c.surface, 3 if high else 1.35)
	theme_elevation(&th)
	theme_materials(&th)
	theme_fills(&th, high) // converted against the glass: after the materials
	if high do theme_opaque(&th) // nothing shows through under high contrast
	return
}

// A11y_Prefs are the desktop's accessibility preferences, which every theme
// follows whoever built it.
A11y_Prefs :: struct {
	reduce_motion:       bool, // transitions off
	reduce_transparency: bool, // glass becomes opaque surfaces
	text_scale:          f32,  // the desktop's text size: 1 normal, 1.5 = "large text" (0 is read as 1)
}

// TEXT_SCALE_MIN / TEXT_SCALE_MAX bound what a desktop can ask for, so a
// stray setting cannot make text unreadable or unlayoutable.
TEXT_SCALE_MIN :: f32(0.5)
TEXT_SCALE_MAX :: f32(3)

// text_scale_of is the multiplier to draw text at: the desktop's, clamped.
text_scale_of :: proc "contextless" (p: A11y_Prefs) -> f32 {
	if p.text_scale <= 0 do return 1
	return clamp(p.text_scale, TEXT_SCALE_MIN, TEXT_SCALE_MAX)
}

// theme_text_scale multiplies every text size in the theme's type scale,
// the way a desktop's text-scaling factor asks for ("Large Text").
@(private)
theme_text_scale :: proc(th: ^Theme, scale: f32) {
	if scale == 1 do return
	th.type.display.size  *= scale
	th.type.headline.size *= scale
	th.type.title.size    *= scale
	th.type.body.size     *= scale
	th.type.label.size    *= scale
	th.type.caption.size  *= scale
	// A field style's text sizes are final px in its look, so they scale here with the steps.
	if v, ok := th.field.text.size.?; ok do th.field.text.size = v * scale
	if v, ok := th.field.inline_card.text_size.?; ok do th.field.inline_card.text_size = v * scale
}

// set_theme swaps the tree's theme. The desktop's accessibility preferences
// are folded in and stay current (a preference turned off gives the theme
// back as set), and a theme the app sets stays through the desktop's
// light / dark changes until `follow_system_theme` gives it back. Builders
// resolve tokens when they run, so the app's view must be re-run afterwards
// (the run loop does this); paint-only tokens (focus ring, state layers)
// take effect immediately.
//
// `App.adjust_theme` runs over it, as over every other theme the app runs
// with, so an app's own type scale or radii survive a theme picked in its
// settings.
set_theme :: proc(t: ^Tree, th: Theme) {
	t.theme_app = true
	t.theme_app_raw = th // kept unadjusted, so refresh_theme can start again from it
	th := th
	theme_finish(&th, t.adjust_theme)
	tree_theme(t, th)
}

// tree_start_theme gives a new surface's tree its first theme, once
// `tree_desktop_theme` has told it the desktop's: the app's own where it
// named one (`App.theme`), pinned exactly as `set_theme` pins it, and the
// desktop's otherwise.
//
// Pinned, not installed as if it were the desktop's: otherwise
// `follow_system_theme` (an appearance setting's System choice) would put
// the app's own theme straight back, and an app that starts on its own
// theme could never show the desktop's.
@(private)
tree_start_theme :: proc(t: ^Tree, app_theme: Theme) {
	if app_theme.name != "" {
		set_theme(t, app_theme)
		return
	}
	tree_theme(t, t.theme_desktop)
}

// tree_desktop_theme records the desktop's theme and the unadjusted one it
// came from. The two go together — refresh_theme re-derives from the raw
// one — so there is one proc that sets them rather than two fields to
// remember.
@(private)
tree_desktop_theme :: proc(t: ^Tree, finished, raw: Theme) {
	t.theme_desktop = finished
	t.theme_desktop_raw = raw
}

// refresh_theme runs the app's `adjust_theme` over the current theme again,
// from the theme as it was *before* the last adjust — because the app's
// adjust has new inputs.
//
// Call it when something `adjust_theme` reads of the app's own — a text
// size in its settings, a density, a chosen font — has changed; it works
// whether the tree is pinned or following the desktop.
//
// It starts from the unadjusted theme, not the running one: an adjust run
// over its own output compounds (a size times 1.2 becomes 1.44, then 1.73).
//
// The view must be re-run afterwards, as after `set_theme`; the run loop
// does this.
refresh_theme :: proc(t: ^Tree) {
	th := t.theme_app_raw if t.theme_app else t.theme_desktop_raw
	theme_finish(&th, t.adjust_theme)
	if !t.theme_app do t.theme_desktop = th // what follow_system_theme goes back to, freshly adjusted
	tree_theme(t, th)
}

// follow_system_theme puts the tree back on the desktop's theme after
// `set_theme` pinned one, and lets the desktop's light / dark changes reach
// it again: the System choice beside Light and Dark in an appearance
// setting.
//
// The view must be re-run afterwards, as after `set_theme`; the run loop
// does this. Harmless on a tree that was already following.
follow_system_theme :: proc(t: ^Tree) {
	t.theme_app = false
	// The app's adjust runs again, so a size it works out from its own
	// settings is current, not as it was at the last desktop change.
	refresh_theme(t)
}

// set_a11y_prefs swaps the accessibility preferences this tree runs with —
// text size, reduce motion, reduce transparency — for a desktop that owns
// them and would rather say than be asked. They are folded into the theme
// the same way the desktop's are, they reach a size the app set itself as
// well as the theme's roles, and once set the desktop's preferences leave
// this tree alone (as a theme the app sets does). `App.a11y` says it for
// every surface at start-up. Builders resolve sizes when they run, so the
// view must be re-run afterwards; the run loop does this.
set_a11y_prefs :: proc(t: ^Tree, p: A11y_Prefs) {
	t.a11y_app = true
	tree_a11y_prefs(t, p)
}

// follow_system_a11y puts the tree back on the desktop's accessibility
// preferences after `set_a11y_prefs` pinned the app's, and lets the
// desktop's changes — text size, reduce motion, reduce transparency — reach
// it again. It is `follow_system_theme`'s counterpart; an app that offers
// "use the desktop's appearance" as a setting needs both.
//
// The desktop's preferences as they are *now* are installed, not as they
// were when the app pinned its own, so a change made meanwhile is not
// missed. The view must be re-run afterwards, as after `set_a11y_prefs`;
// the run loop does this. Harmless on a tree that was already following.
follow_system_a11y :: proc(t: ^Tree) {
	t.a11y_app = false
	tree_a11y_prefs(t, t.a11y_desktop)
}

// a11y_prefs is the accessibility preferences in force: the desktop's, or
// the app's where it set them with `set_a11y_prefs`. Read it before
// changing one of them, so the other two are carried over rather than
// quietly switched off.
//
// `text_scale` here is the **desktop's** factor. An app's own text-size
// setting belongs in `set_text_scale`, which multiplies this rather than
// replacing it.
a11y_prefs :: proc(t: ^Tree) -> A11y_Prefs {
	return t.a11y_prefs
}

// set_text_scale is the app's own text size — an S / M / L / XL setting in
// its preferences — **multiplied** with the desktop's, not replacing it. 1
// (or 0) is no scaling of its own.
//
// Multiplying keeps the desktop's Large Text an accessibility setting the
// app cannot take away: its 1.5 and the app's 1.25 compose, as a zoom does.
// The product is clamped to TEXT_SCALE_MIN…TEXT_SCALE_MAX, so neither
// setting can make the other unreadable. Use it, not `set_a11y_prefs`, for
// a text size alone: that takes all three preferences over and stops the
// desktop's reaching the tree, while here reduce-motion and
// reduce-transparency keep following the desktop.
set_text_scale :: proc(t: ^Tree, scale: f32) {
	s := 0 if scale == 1 else scale // 1 and 0 both mean "the app has no say"
	if t.app_text_scale == s do return
	t.app_text_scale = s
	tree_theme(t, t.theme_asked) // refold: the type scale changes
}

// text_scale is the factor text is actually drawn at: the desktop's and
// the app's own together, clamped. What `set_text_scale` asked for is not
// always what comes back.
text_scale :: proc(t: ^Tree) -> f32 {
	return tree_text_scale(t)
}

// tree_text_scale folds the app's own factor into the desktop's and clamps
// the product.
@(private)
tree_text_scale :: proc(t: ^Tree) -> f32 {
	s := text_scale_of(t.a11y_prefs)
	if t.app_text_scale > 0 do s *= t.app_text_scale
	return clamp(s, TEXT_SCALE_MIN, TEXT_SCALE_MAX)
}

// tree_a11y_prefs takes the desktop's latest preferences and refolds the theme.
@(private)
tree_a11y_prefs :: proc(t: ^Tree, p: A11y_Prefs) {
	t.a11y_prefs = p
	tree_theme(t, t.theme_asked)
}

// tree_desktop_a11y records what the desktop's accessibility preferences
// are, and installs them unless the app has pinned its own — the same shape
// as tree_desktop_theme, and for the same reason: `follow_system_a11y` has
// to have somewhere to go back to.
@(private)
tree_desktop_a11y :: proc(t: ^Tree, p: A11y_Prefs) {
	t.a11y_desktop = p
	if !t.a11y_app do tree_a11y_prefs(t, p)
}

// tree_theme installs `th` with the preferences folded in, and adapted to
// what shows through when the tree's surface is glass (glass.odin).
@(private)
tree_theme :: proc(t: ^Tree, th: Theme) {
	// The type scale this tree was laid out with, before the new theme lands.
	// Every text size a widget asks for comes from here, so a change to it
	// makes every measurement in the tree stale.
	type_was := t.theme.type
	target_was := t.theme.min_target
	t.theme_asked = th
	t.theme = th
	if t.a11y_prefs.reduce_transparency do theme_opaque(&t.theme)
	if t.a11y_prefs.reduce_motion do t.theme.motion.reduce = true
	theme_text_scale(&t.theme, tree_text_scale(t)) // the desktop's text size and the app's own, folded in like the other preferences
	glow_was := t.theme_base.material[t.theme_base.glass].glow.radius > 0
	t.theme_base = t.theme
	t.glass_theme, t.glass_theme_ok = {}, false
	if t.glass.on {
		if t.backdrop_marked {
			// Only the marked nodes are over the wallpaper, so only what is
			// drawn on them is adapted. Adapting the tree would re-solve
			// colours the app chose — its accent, its muted text — for a
			// backdrop most of its window never sits on.
			t.glass_theme = t.theme
			glass_adapt(t, &t.glass_theme, t.glass.role, t.glass.known, t.glass.backdrop)
			t.glass_theme_ok = true
		} else {
			glass_adapt(t, &t.theme, t.glass.role, t.glass.known, t.glass.backdrop)
		}
	}
	// Glass *inside* the window — a menu, a popover, a select's list, drawn
	// over whatever the app put beneath it — has no report to go on: the
	// compositor measures what is behind the window, not the page the menu
	// opened over. It takes the worst case, as glass over any unmeasured
	// backdrop does.
	t.in_app_theme, t.in_app_theme_ok = {}, false
	if t.theme_base.glass != .Solid && has_material(t.theme_base.material[t.theme_base.glass].popover) {
		t.in_app_theme = t.theme_base
		// `linear`: this glass is drawn by the toolkit over the app's own
		// content, which `ui.frag` mixes in linear light — not by the
		// compositor over the wallpaper, which mixes in sRGB. Solved with the
		// compositor's maths it would promise more contrast than is drawn.
		glass_adapt(t, &t.in_app_theme, .Popover, false, {}, waited = true, linear = true)
		t.in_app_theme_ok = true
	}
	clear(&t.popup_themes)
	if glow_was do damage_add(t, {0, 0, t.viewport.x, t.viewport.y}) // a glow gone leaves no halo outside what repaints
	mark_paint_dirty(t, t.root)
	for &d, i in t.nodes {
		if i == 0 || .Alive not_in d.flags do continue
		d.flags += {.Dirty_Paint}
	}
	for n, _ in t.layers {
		if d := node_get(t, n); d != nil do d.flags += {.Layer_Dirty}
	}
	tree_fonts_follow(t) // the theme may set its text in a family of this machine's
	// A type scale that moved invalidates every measurement, not only paint:
	// `layout_node` skips a node whose constraints have not changed, so a
	// custom measure (an editor, a terminal) would keep its old size.
	// `tree_fonts_changed` dirties layout and paint on every node and drops
	// the editors' cached rich layouts and the terminals' draws, as for a
	// font family change or a GPU reset.
	if t.theme.type != type_was do tree_fonts_changed(t)
	if t.theme.min_target != target_was do relayout_all(t) // every control's size depends on it, and layout keeps a node whose constraints did not change
}

// mix blends a toward b by t (linear space).
mix :: proc "contextless" (a, b: Color, t: f32) -> Color {
	return a + (b - a) * t
}

// code_colors derives the syntax colours from the seed hue, each pushed
// to at least AA contrast over surface_variant (the editor's background).
@(private)
code_colors :: proc(th: ^Theme) {
	c := &th.color
	_, pc, hue := oklch_of(c.primary)
	// A neutral accent has no hue to lend: syntax colours
	// tell one token from another, so they stay coloured on a grey theme
	// and fall back to the family the shipped themes use.
	if pc < 0.01 do hue = NEUTRAL_CODE_HUE
	dark := th.dark
	high := th.contrast == .High
	L: f32 = 0.80 if dark else 0.42 // text lightness for coloured tokens
	C: f32 = 0.11 if dark else 0.14
	if high { L = 0.88 if dark else 0.30 }
	min: f32 = 7 if high else 4.5
	tone :: proc(L, C, h: f32, bg: Color, min: f32) -> Color { return ensure_contrast(oklch(L, C, h), bg, min) }
	bg := c.surface_variant
	c.code.keyword   = tone(L, C + 0.02, hue + 40, bg, min)  // near the accent, a step warmer
	c.code.type      = tone(L, C, hue - 70, bg, min)         // teal / cyan side of blue
	c.code.string    = tone(L, C, hue + 200, bg, min)        // greens
	c.code.number    = tone(L, C, hue + 130, bg, min)        // amber / orange
	c.code.constant  = tone(L, C, hue + 130, bg, min)
	c.code.attribute = tone(L, C - 0.03, hue + 90, bg, min)  // olive / gold
	c.code.operator  = c.on_surface_muted
	c.code.punct     = c.on_surface_muted
	c.code.comment   = ensure_contrast(oklch(0.66 if dark else 0.52, 0.02, hue + 200, 1), bg, min)
	if high do c.code.comment = c.on_surface_muted
	c.code.current_line   = oklch(0.6, 0.05, hue, 0.10 if dark else 0.08)
	c.code.gutter         = c.on_surface_muted
	c.code.gutter_current = c.on_surface
	c.code.match          = oklch(0.7, 0.12, hue, 0.35)
}

// STATE_DL is how far a hover or a press moves what is under it, in OKLab
// lightness — the yardstick that leans neither light nor dark. An alpha
// cannot be shared across modes: `on_surface` at 0.08 is a near-black wash
// on white, worth dL 0.027, and a near-white wash on near-black, worth
// 0.185 — seven times more. Light is kept subtler than the dark themes, but
// within a factor of two rather than seven.
@(private)
STATE_DL :: [Theme_Mode]struct{ hover, press: f32 }{
	.Light = {0.070, 0.105},
	.Dim   = {0.130, 0.190}, // about what alphas 0.08 / 0.14 give on Dim
	.Dark  = {0.185, 0.250},
}

// theme_states solves the hover and press alphas for the step they are
// meant to make, from whichever end the theme starts.
@(private)
theme_states :: proc(th: ^Theme) {
	want := STATE_DL
	boost: f32 = 1.5 if th.contrast == .High else 1
	th.state.hover = theme_state_alpha(th.color.surface, th.color.on_surface, want[th.mode].hover * boost)
	th.state.press = theme_state_alpha(th.color.surface, th.color.on_surface, want[th.mode].press * boost)
}

// theme_state_alpha is the alpha of `ink` over `base` that moves it by
// `want` in OKLab lightness.
@(private)
theme_state_alpha :: proc(base, ink: Color, want: f32) -> f32 {
	l0, _, _ := oklch_of(base)
	lo, hi := f32(0), f32(0.8)
	for _ in 0 ..< 20 {
		mid := (lo + hi) * 0.5
		l, _, _ := oklch_of(Color{
			ink.r * mid + base.r * (1 - mid),
			ink.g * mid + base.g * (1 - mid),
			ink.b * mid + base.b * (1 - mid),
			1,
		})
		if abs(l - l0) < want { lo = mid } else { hi = mid }
	}
	return (lo + hi) * 0.5
}

// theme_fills sets the fills from the content colour: faint for tiles and
// chips, strong for tracks and switched-off toggles on a tile. Being the
// content colour at an alpha they sit on any surface, and on glass they
// follow the text (a glass surface whose text flips family takes that
// family's fills). Their alphas are the design's tokens converted against
// the popover's Frosted glass, so a tile and a track on it separate as the
// design shows in every mode; high contrast takes more.
@(private)
theme_fills :: proc(th: ^Theme, high: bool) {
	c := &th.color
	tokens := GLASS_TOKENS
	tok := tokens[th.mode]
	boost: f32 = 1.8 if high else 1
	glass := th.material[.Frosted].popover.tint
	faint := glass_token_alpha(c.on_surface.rgb, tok.fill * boost, glass)
	strong := glass_token_alpha(c.on_surface.rgb, tok.fill_strong * boost, glass, under_ink = c.on_surface.rgb, under = faint, under_token = tok.fill * boost)
	c.fill = with_alpha(c.on_surface, faint)
	c.fill_strong = with_alpha(c.on_surface, strong)
}

// Theme_Palette names the neutral roles outright, for a style whose
// colours are a design in their own right rather than something to
// generate — a desktop that reproduces a known look. Every field is
// optional: a colour left zero is the generated theme's own, so a palette
// can give as little as a window and a view colour. `primary` is the accent
// as a **fill** (a selection, a primary button) and `on_primary` the text on
// it; the rest are the neutrals, in the order they stack.
//
// `accent_text` is the accent as **ink** — a ghost button's label, a
// breadcrumb, a link, an unread count. Left unset it is `primary` lifted
// until it clears 4.5:1 on the view. Set it for a style whose accent cannot
// be read as text at any lightness (a grey selection colour is right as a
// fill and dim as ink); `primary` is kept exactly as given either way.
Theme_Palette :: struct {
	bg:               Color, // the window
	surface:          Color, // views and cards
	surface_variant:  Color, // sidebars and wells
	surface_high:     Color, // popovers
	on_bg:            Color, // text on the window
	on_surface:       Color, // text on a view
	on_surface_muted: Color, // secondary text
	outline:          Color, // borders
	primary:          Color, // the accent, as a fill
	on_primary:       Color, // text on the accent
	accent_text:      Color, // the accent as ink (a link, a ghost button's label); unset = primary
}

// theme_from_palette builds a complete theme from colours given outright,
// for a style whose palette is the design — the exact greys of a desktop
// theme being reproduced — rather than one generated from an accent
// (`theme_from_seed`).
//
// What the palette names is taken as asked. What it leaves out is derived
// from what it gives, as `theme_on_ground` does: the accent's container is
// mixed toward the window, the secondary ground steps from the surface
// toward the ink, the subtler outline toward the surface, and the focus ring
// and selection are the accent. The hover
// and press washes, syntax palette, shadows, glass materials and fills are
// computed afresh for these colours. Danger, warning and success are the
// generated theme's, since they mean the same thing on any ground.
//
// Readability still wins: every pair that carries text goes through
// `ensure_contrast`, so a palette whose muted text falls short comes back
// with that one colour moved. **Under High contrast the palette is not used
// at all** and the generated theme comes back: a mid-grey window cannot
// carry 10:1 text. With a neutral accent that theme is itself grey.
//
// `mode` is the caller's and is never inferred from the colours: a
// reproduced dark window may be lighter than Baldr's own Dim one and is
// still Dark. The ladder is the palette's business too — a style whose
// views sit *darker* than their window is saying so. For a style with no
// glass, call `theme_opaque` on what comes back.
theme_from_palette :: proc(p: Theme_Palette, mode: Theme_Mode, contrast: Theme_Contrast = .Normal, name := "") -> (th: Theme) {
	pick :: proc "contextless" (given, generated: Color) -> Color { return given if given.a > 0 else generated }
	th = theme_from_seed(pick(p.primary, BALDR_BLUE), mode, contrast, name)
	// High contrast is an accessibility setting, not a palette's to
	// override: a style's grounds may not carry 10:1 text, so the generated
	// theme, built to reach it, comes back (grey for a grey accent).
	if contrast == .High do return
	c := &th.color
	c.bg               = pick(p.bg, c.bg)
	c.surface          = pick(p.surface, c.surface)
	c.surface_variant  = pick(p.surface_variant, c.surface_variant)
	c.surface_high     = pick(p.surface_high, c.surface_high)
	c.on_bg            = pick(p.on_bg, c.on_bg)
	c.on_surface       = pick(p.on_surface, c.on_surface)
	c.on_surface_muted = pick(p.on_surface_muted, c.on_surface_muted)
	c.outline          = pick(p.outline, c.outline)
	c.primary          = pick(p.primary, c.primary)
	c.on_primary       = pick(p.on_primary, c.on_primary)
	c.accent_text      = pick(p.accent_text, c.primary) // ink follows the fill unless the style splits them
	// A role the palette does not name is derived from the ones it does, not
	// left at the generated theme's lightnesses. A step in OKLCH L, not a mix
	// in linear light: a linear mix toward a near-white ink lands far lighter
	// than it reads, and can put a secondary ground above its window. A
	// secondary ground is its surface stepped 0.085 toward the ink; a subtler
	// outline is 0.07 toward the surface.
	toward :: proc "contextless" (from, to: Color, by: f32) -> Color {
		L, C, h := oklch_of(from)
		tl, _, _ := oklch_of(to)
		return oklch(clamp(L + (by if tl >= L else -by), 0, 1), C, h, from.a)
	}
	ink, bg := c.on_surface, c.bg
	if p.outline.a > 0 do c.outline_variant = toward(c.outline, c.surface, 0.07)
	if p.on_surface.a > 0 || p.surface.a > 0 {
		c.secondary    = toward(c.surface, ink, 0.085)
		c.on_secondary = ink
	}
	if p.primary.a > 0 {
		c.primary_container    = mix(c.primary, bg, 0.80)
		c.on_primary_container = mix(c.primary, ink, 0.45)
		c.focus_ring           = c.primary
		c.selection            = {c.primary.r, c.primary.g, c.primary.b, 0.30}
	}
	theme_states(&th) // the washes, solved for this ink on this ground
	code_colors(&th)
	body: f32 = 7
	c.on_bg           = ensure_contrast_either(c.on_bg, c.bg, body)
	c.on_surface      = ensure_contrast_either(c.on_surface, c.surface, body)
	c.on_surface_muted = ensure_contrast_either(c.on_surface_muted, c.surface_variant, 4.5)
	// A given accent is a fill, and it is kept exactly: one colour cannot be
	// both an exact fill and readable ink. The 4.5:1 text bar sits on
	// `accent_text`, the accent as ink, which defaults to the fill and is
	// moved until it reads.
	c.accent_text     = ensure_contrast(c.accent_text, c.surface, 4.5) // as text: links, ghost buttons
	c.on_primary      = ensure_contrast_either(c.on_primary, c.primary, 4.5)
	c.on_primary_container = ensure_contrast_either(c.on_primary_container, c.primary_container, 4.5)
	c.on_secondary    = ensure_contrast_either(c.on_secondary, c.secondary, 4.5)
	c.danger          = ensure_contrast(c.danger, c.surface, 3)
	c.on_danger       = ensure_contrast(c.on_danger, c.danger, 4.5)
	c.warning         = ensure_contrast(c.warning, c.surface, 3)
	c.success         = ensure_contrast(c.success, c.surface, 3)
	c.focus_ring      = ensure_contrast(c.focus_ring, c.bg, 3)
	c.outline         = ensure_contrast(c.outline, c.surface, 1.35)
	theme_settle(&th, high = false, solid = th.glass == .Solid)
	return
}

// theme_from_system builds the theme from the desktop's own colour scheme:
// a Windows contrast theme or a KDE colour scheme (`Ev_Theme.palette`).
// In high contrast the colours are used exactly — the person chose them to
// read by — on the structure of the toolkit's contrast theme; otherwise the
// scheme goes through theme_from_palette, which keeps text readable.
// `accent`, the app's own, takes the selection colour's place except in
// high contrast.
theme_from_system :: proc(p: platform.System_Palette, high_contrast: bool, accent: Color = {}) -> Theme {
	lin :: proc "contextless" (c: [4]f32) -> Color { return {srgb_to_linear(c[0]), srgb_to_linear(c[1]), srgb_to_linear(c[2]), 1} }
	window := lin(p.window)
	mode := Theme_Mode.Dark if luminance(window) < 0.18 else .Light
	if high_contrast {
		th := theme_high_contrast(mode)
		th.name = "System Contrast"
		c := &th.color
		ink := lin(p.window_text)
		c.bg, c.surface, c.surface_variant, c.surface_high = window, lin(p.view), lin(p.button), window
		c.on_bg, c.on_surface = ink, lin(p.view_text)
		c.on_surface_muted = ink // a contrast theme keeps secondary text at full ink; its grey is for disabled
		c.primary, c.on_primary = lin(p.selection), lin(p.selection_text)
		c.primary_container, c.on_primary_container = c.primary, c.on_primary
		c.secondary, c.on_secondary = lin(p.button), lin(p.button_text)
		c.accent_text = lin(p.link)
		c.outline, c.outline_variant, c.focus_ring = ink, ink, ink
		c.selection = c.primary
		c.danger = ensure_contrast(c.danger, c.surface, 4.5)
		c.warning = ensure_contrast(c.warning, c.surface, 4.5)
		c.success = ensure_contrast(c.success, c.surface, 4.5)
		theme_states(&th)
		code_colors(&th)
		theme_settle(&th, high = true, solid = true)
		return th
	}
	own := accent.a > 0
	tp := Theme_Palette{
		bg = window, surface = lin(p.view), surface_variant = lin(p.button), surface_high = lin(p.view),
		on_bg = lin(p.window_text), on_surface = lin(p.view_text), on_surface_muted = lin(p.inactive_text),
		primary = accent if own else lin(p.selection),
	}
	if !own do tp.on_primary, tp.accent_text = lin(p.selection_text), lin(p.link)
	return theme_from_palette(tp, mode, .Normal, "System")
}

// ensure_contrast_either pushes `fg` away from `bg` on the side it is
// already on, and swaps to the other side when that side cannot reach the
// ratio: white text on a mid grey can only ever be *darkened*, and
// `ensure_contrast` alone would hand back white and a failing pair. A
// generated theme never meets this — its text colours are picked for their
// ground — but a palette's are given, so one can sit on the wrong side of
// its own accent.
@(private)
ensure_contrast_either :: proc(fg, bg: Color, min: f32) -> Color {
	near := ensure_contrast(fg, bg, min)
	if contrast_ratio(near, bg) >= min do return near
	L, C, h := oklch_of(fg)
	far := ensure_contrast(oklch(0 if L >= 0.5 else 1, C, h, fg.a), bg, min)
	return far if contrast_ratio(far, bg) > contrast_ratio(near, bg) else near
}

// theme_on_ground derives a whole theme for a ground an app picks: a
// reader's Paper, Sepia, Dusk or Night page, a photo editor's dark canvas,
// a terminal's own colours. `bg` is the ground, `ink` the
// text on it, `accent` what a link or a primary button is made of (the
// base's own accent when it is left out).
//
// What comes back is `base` with **only its colours re-derived**: the type,
// the radii, the spacing, the motion and the desktop's accessibility
// preferences are the ones the app is already running with, so a page in
// the app's colours still obeys reduce motion, reduce transparency, high
// contrast and the desktop's text size. The ladder of surfaces steps away
// from the ground toward whichever side has room — lighter over a dark
// page, darker over cream paper, where stepping lighter would run out of
// white — and every pair that carries text is put through
// `ensure_contrast`, so a ghost button on Sepia hovers in a darker sepia
// and still reads, rather than in the desktop's grey.
//
// Give it to a part of a window with `theme_area`.
theme_on_ground :: proc(base: Theme, bg, ink: Color, accent: Color = {}, name := "") -> (th: Theme) {
	th = base
	th.name = name if name != "" else base.name
	bgL, bgC, bgH := oklch_of(bg)
	th.dark = bgL < 0.5
	th.mode = .Light if bgL >= 0.5 else (.Dim if bgL >= 0.22 else .Dark)
	high := base.contrast == .High
	seed := accent if accent.a > 0 else base.seed
	if seed.a > 0 do th.seed = seed

	// The ladder: away from the ground, toward the side with room to move.
	// A near-white page has none above it, so its cards are a shade of the
	// page rather than a whiter white nobody can see (Light's own surfaces
	// are built the same way, downwards from white).
	dir: f32 = 1 if 1 - bgL >= 0.08 else -1
	step :: proc(L, C, h, by: f32) -> Color { return oklch(clamp(L + by, 0, 1), C, h) }
	c := &th.color
	c.bg              = bg
	c.surface         = step(bgL, bgC, bgH, dir * 0.045)
	c.surface_variant = step(bgL, bgC, bgH, dir * 0.075)
	c.surface_high    = step(bgL, bgC, bgH, dir * 0.110)
	c.on_bg           = ink
	c.on_surface      = ink
	c.on_surface_muted = mix(ink, bg, 0.30 if high else 0.42)
	c.outline         = mix(ink, bg, 0.62)
	c.outline_variant = mix(ink, bg, 0.78)
	c.primary         = seed if seed.a > 0 else ink
	c.on_primary      = bg if contrast_ratio(bg, c.primary) >= contrast_ratio(ink, c.primary) else ink
	c.primary_container    = mix(c.primary, bg, 0.80)
	c.on_primary_container = mix(c.primary, ink, 0.45)
	c.secondary       = mix(ink, bg, 0.86)
	c.on_secondary    = ink
	c.focus_ring      = c.primary
	c.selection       = {c.primary.r, c.primary.g, c.primary.b, 0.30}
	// danger, warning and success keep the base's hues — they mean the same
	// thing on any ground — and are re-seated on this one below.
	theme_states(&th) // the hover and press washes, solved for ink on this ground
	code_colors(&th)

	// Readable by construction, exactly as theme_from_seed does it: the
	// app chose a ground and an ink, and the roles derived from them are
	// moved until they pass rather than taken on trust.
	body: f32 = 10 if high else 7
	c.on_bg           = ensure_contrast(c.on_bg, c.bg, body)
	c.on_surface      = ensure_contrast(c.on_surface, c.surface, body)
	c.on_surface_muted = ensure_contrast(c.on_surface_muted, c.surface_variant, 7 if high else 4.5)
	c.on_primary      = ensure_contrast(c.on_primary, c.primary, 4.5)
	c.on_primary_container = ensure_contrast(c.on_primary_container, c.primary_container, 4.5)
	c.on_secondary    = ensure_contrast(c.on_secondary, c.secondary, 4.5)
	c.primary         = ensure_contrast(c.primary, c.surface, 4.5) // as text: links, ghost buttons
	c.accent_text     = c.primary // derived from the app's ground, so readable already
	c.danger          = ensure_contrast(c.danger, c.surface, 3)
	c.on_danger       = ensure_contrast(c.on_danger, c.danger, 4.5)
	c.warning         = ensure_contrast(c.warning, c.surface, 3)
	c.success         = ensure_contrast(c.success, c.surface, 3)
	c.focus_ring      = ensure_contrast(c.focus_ring, c.bg, 3)
	c.outline         = ensure_contrast(c.outline, c.surface, 3 if high else 1.35)
	// Glass that was turned off stays off: the desktop's reduce
	// transparency and high contrast are the user's word, not the ground's.
	theme_settle(&th, high, solid = base.glass == .Solid)
	return
}

// theme_settle is the last of the colour work for a theme whose roles were
// given rather than generated (theme_on_ground, theme_from_palette): the
// shadows, the glass materials and the fills, in that order, because the
// fills are converted against the materials. `solid` keeps glass off for a
// theme that already had it off; High contrast turns it off regardless.
@(private)
theme_settle :: proc(th: ^Theme, high: bool, solid: bool) {
	theme_elevation(th)
	theme_materials(th)
	theme_fills(th, high)
	if high || solid do theme_opaque(th)
}
