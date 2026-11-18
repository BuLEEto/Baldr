package baldr

import "core:math"

// Component styles: one struct per widget kind on the theme (`th.button`,
// `th.field`, …). Every field is a Maybe: nil derives from the global tokens
// exactly as the toolkit always has, so a theme sets only what it changes,
// and 0 or a transparent colour are values of their own. Widgets read a
// resolved look (`button_look(th)`, …), never the style itself, so defaults
// and density live here.
//
// `Theme.density` moves control heights by DENSITY_STEP a unit (compact −1,
// spacious +1), and where padding makes a height, each side by half that.

// DENSITY_STEP is how far one unit of Theme.density moves a control's
// height, logical px.
DENSITY_STEP :: f32(4)

// Text_Override restyles a text a widget sets itself; nil keeps the
// toolkit's. A size is logical px at text scale 1 and follows the text
// scale, as a role's does.
Text_Override :: struct {
	size:   Maybe(f32),
	weight: Maybe(Font_Weight),
	family: Maybe(string), // named as Theme.font_family is; the app's string
}

// Text_Look is a resolved Text_Override. A size of 0 is the role's own; a
// family of "" is the role's, or the theme's.
Text_Look :: struct {
	role:   Text_Role,
	size:   f32,
	weight: Font_Weight,
	family: string,
}

// text_look resolves a Text_Override over `role`: a size of 0 is the role's
// own, a weight nil is the role's (or the one given), a family nil the role's.
@(private)
text_look :: proc "contextless" (th: ^Theme, role: Text_Role, o: Text_Override, size: f32 = 0, weight: Maybe(Font_Weight) = nil) -> Text_Look {
	return {
		role   = role,
		size   = o.size.? or_else size,
		weight = o.weight.? or_else (weight.? or_else text_style(th, role).weight),
		family = o.family.? or_else "",
	}
}

// dense_height is a control height moved by the theme's density, never
// below `floor` (its content, or the theme's min_target) nor below 0. A
// height of 0 means "as tall as its content" and is left alone.
@(private)
dense_height :: proc "contextless" (th: ^Theme, h: f32, floor: f32 = 0) -> f32 {
	if th.density == 0 || h <= 0 do return h
	return max(h + th.density * DENSITY_STEP, min(h, floor), 0)
}

// dense_pad is a padding that makes a height, moved by half a density step.
@(private)
dense_pad :: proc "contextless" (th: ^Theme, p: f32) -> f32 {
	if th.density == 0 do return p
	return max(p + th.density * DENSITY_STEP / 2, 0)
}

// dense_pad4 moves a padding's top and bottom by half a density step, and
// its sides too when `all` (a square control stays square).
@(private)
dense_pad4 :: proc "contextless" (th: ^Theme, p: [4]f32, all := false) -> [4]f32 {
	q := p
	q[0], q[2] = dense_pad(th, q[0]), dense_pad(th, q[2])
	if all do q[1], q[3] = dense_pad(th, q[1]), dense_pad(th, q[3])
	return q
}

// look_family is the Family_Id for a family a component style names: 0 for
// "", and the theme's own text where this machine has no such family.
@(private)
look_family :: proc(t: ^Tree, name: string) -> Family_Id {
	if name == "" || t == nil || t.text == nil do return 0
	id := text_family(t.text, name)
	return id if text_family_ok(t.text, id) else 0
}

// ---------------------------------------------------------------- button

// ---- Shared by every component style: define once in theme_style.odin ----


// ---- Button ----

// Button_Colors is one look of a button. Hover and press washes still derive
// from `fill`, and a disabled button still dims by state.disabled_alpha.
Button_Colors :: struct {
	fill:         Maybe(Color),        // the background
	fill_bottom:  Maybe(Color),        // the gradient's bottom stop; {} is flat
	ink:          Maybe(Color),        // label and icons, and a mark that names no colour
	border:       Maybe(Color),
	border_width: Maybe(f32),          // drawn inside the edge, taking no room
	shadow:       Maybe(Shadow_Style),
}

// Button_Size_Style is one Button_Size's metrics.
Button_Size_Style :: struct {
	padding:        Maybe([4]f32), // a labelled button's: top, end, bottom, start
	icon_only_size: Maybe(f32),    // an icon-only button's side: it is square
	text:           Text_Override, // the label
}

// Button_Style restyles every `button`, the toolkit's own included. Nil
// derives from the global tokens; density then moves the heights.
Button_Style :: struct {
	radius:       Maybe(f32), // every variant and size
	gap:          Maybe(f32), // between the icons, the picture and the label
	icon_size:    Maybe(f32), // an icon or theme icon; button_options' icon_size wins
	image_size:   Maybe(f32), // a picture (an avatar); button_options' icon_size wins
	image_radius: Maybe(f32),
	regular:      Button_Size_Style,
	small:        Button_Size_Style,
	primary, secondary, outline, ghost, danger: Button_Colors,
	pressed:      Button_Colors, // a toggle that is on: Secondary, Outline, Ghost (Primary and Danger keep their fill)
	unpressed:    Button_Colors, // a toggle that is off: Primary, Secondary, Danger (Outline and Ghost keep their look)
	mark_thickness:     Maybe(f32),   // a Button_Mark that names none
	progress_thickness: Maybe(f32),   // the bar; never more than a third of the icon
	progress_fill:      Maybe(Color), // the value; on a fill it cannot be seen on, the ink that reads there instead
	progress_track:     Maybe(Color), // the rest of the bar or ring
	ring_thickness:     Maybe(f32),
	ring_gap:           Maybe(f32),   // between the icon's box and the ring
	badge_fill:         Maybe(Color), // a Button_Badge with no colour of its own
	badge_ink:          Maybe(Color), // its text
	badge_dot:          Maybe(f32),   // a dot's diameter
	badge_height:       Maybe(f32),   // a pill's height
	badge_padding:      Maybe(f32),   // each side of a pill's text
	badge_text:         Text_Override,
}

// Button_Colors_Look is a resolved Button_Colors.
Button_Colors_Look :: struct {
	fill, fill_bottom, ink, border: Color,
	border_width:                   f32,
	shadow:                         Shadow_Style,
}

// Button_Size_Look is a resolved Button_Size_Style, density applied.
Button_Size_Look :: struct {
	padding:           [4]f32,
	icon_only_padding: [4]f32,
	text:              Text_Look, // size 0: the Label step's
}

// Button_Look is everything a button draws with. Widgets read this, never
// Theme.button.
Button_Look :: struct {
	radius, gap, icon_size, image_size, image_radius: f32,
	sizes:              [Button_Size]Button_Size_Look,
	colors:             [Button_Variant]Button_Colors_Look,
	pressed, unpressed: Button_Colors_Look,
	mark_thickness, progress_thickness, ring_thickness, ring_gap: f32,
	progress_fill, progress_track: Color,
	badge_fill, badge_ink:         Color,
	badge_dot, badge_height, badge_padding: f32,
	badge_text:                    Text_Look,
}

@(private)
button_colors_look :: proc "contextless" (s: Button_Colors, base: Button_Colors_Look) -> Button_Colors_Look {
	return {
		fill         = s.fill.? or_else base.fill,
		fill_bottom  = s.fill_bottom.? or_else base.fill_bottom,
		ink          = s.ink.? or_else base.ink,
		border       = s.border.? or_else base.border,
		border_width = s.border_width.? or_else base.border_width,
		shadow       = s.shadow.? or_else base.shadow,
	}
}

// button_filled_look is a filled variant's colours. Its gradient follows the
// fill it resolved to, so a recoloured fill keeps a matching depth.
@(private)
button_filled_look :: proc "contextless" (th: ^Theme, s: Button_Colors, fill, ink: Color) -> Button_Colors_Look {
	lk := button_colors_look(s, {fill = fill, ink = ink, shadow = th.elev.low})
	if s.fill_bottom == nil do lk.fill_bottom = mix(lk.fill, th.color.bg, 0.18) // subtle top-to-bottom depth
	return lk
}

// button_look resolves Theme.button. Call it with the theme in force where
// the button is built or painted (a popup's, glass's), never a cached one.
button_look :: proc(th: ^Theme) -> (lk: Button_Look) {
	s := &th.button
	c := &th.color
	lk.radius       = s.radius.? or_else th.radius.md
	lk.gap          = s.gap.? or_else th.space[.xs]
	lk.icon_size    = s.icon_size.? or_else ICON_SIZE
	lk.image_size   = s.image_size.? or_else BUTTON_IMAGE_SIZE
	lk.image_radius = s.image_radius.? or_else th.radius.xs

	reg, small := &lk.sizes[.Regular], &lk.sizes[.Small]
	reg.padding = s.regular.padding.? or_else [4]f32{th.space[.sm] - 1, th.space[.lg] - 2, th.space[.sm] - 1, th.space[.lg] - 2}
	reg.icon_only_padding = pad4(th.space[.sm] - 1)
	if side, ok := s.regular.icon_only_size.?; ok do reg.icon_only_padding = pad4(max((side - lk.icon_size) / 2, 0))
	small.padding = s.small.padding.? or_else [4]f32{5, th.space[.md] - 2, 5, th.space[.md] - 2}
	small.icon_only_padding = pad4(max(((s.small.icon_only_size.? or_else BUTTON_SMALL) - lk.icon_size) / 2, 0)) // the side holds whatever the icon's size
	reg.text   = text_look(th, .Label, s.regular.text, 0, th.type.label.weight)
	small.text = text_look(th, .Label, s.small.text, BUTTON_SMALL_TEXT, th.type.label.weight)
	for &z in lk.sizes {
		z.padding = dense_pad4(th, z.padding)
		z.icon_only_padding = dense_pad4(th, z.icon_only_padding, all = true) // icon-only stays square
	}

	lk.colors[.Primary]   = button_filled_look(th, s.primary, c.primary, c.on_primary)
	lk.colors[.Secondary] = button_colors_look(s.secondary, {fill = c.primary_container, ink = c.on_primary_container})
	lk.colors[.Outline]   = button_colors_look(s.outline, {ink = c.on_surface, border = c.outline, border_width = 1})
	lk.colors[.Ghost]     = button_colors_look(s.ghost, {ink = c.accent_text}) // all ink
	lk.colors[.Danger]    = button_filled_look(th, s.danger, c.danger, c.on_danger)
	lk.pressed   = button_colors_look(s.pressed, {fill = c.primary_container, ink = c.on_primary_container})
	lk.unpressed = button_colors_look(s.unpressed, {fill = c.surface_high, ink = c.on_surface})

	lk.mark_thickness     = s.mark_thickness.? or_else BUTTON_MARK_THICKNESS
	lk.progress_thickness = s.progress_thickness.? or_else BUTTON_PROGRESS_THICKNESS
	lk.progress_fill      = s.progress_fill.? or_else c.primary
	track := c.on_surface
	track.a *= BUTTON_PROGRESS_TRACK_ALPHA // a power of two: baking it here is bit-identical to multiplying at paint
	lk.progress_track     = s.progress_track.? or_else track
	lk.ring_thickness     = s.ring_thickness.? or_else BUTTON_RING_THICKNESS
	lk.ring_gap           = s.ring_gap.? or_else BUTTON_RING_GAP
	lk.badge_fill         = s.badge_fill.? or_else c.primary
	lk.badge_ink          = s.badge_ink.? or_else c.on_primary
	lk.badge_dot          = s.badge_dot.? or_else BUTTON_BADGE_DOT
	lk.badge_height       = s.badge_height.? or_else BUTTON_BADGE_HEIGHT
	lk.badge_padding      = s.badge_padding.? or_else BUTTON_BADGE_PADDING
	lk.badge_text         = text_look(th, .Label, s.badge_text, BUTTON_BADGE_TEXT, .Semibold)
	return
}

// ---- Icon toggle ----

// Icon_Toggle_Style restyles every `icon_toggle`. Hover and press washes
// still derive from the fills.
Icon_Toggle_Style :: struct {
	size:         Maybe(f32),   // the diameter; the builder's `size` wins
	icon_size:    Maybe(f32),   // nil: half the diameter, rounded
	fill:         Maybe(Color), // off
	ink:          Maybe(Color), // the icon, off
	pressed_fill: Maybe(Color), // on
	pressed_ink:  Maybe(Color), // the icon, on
}

// Icon_Toggle_Look is a resolved Icon_Toggle_Style, density applied.
Icon_Toggle_Look :: struct {
	size:      f32,
	icon_size: f32, // 0: half the drawn diameter, rounded (the diameter is per instance)
	fill, ink, pressed_fill, pressed_ink: Color,
}

icon_toggle_look :: proc(th: ^Theme) -> (lk: Icon_Toggle_Look) {
	s := &th.icon_toggle
	c := &th.color
	lk.icon_size = s.icon_size.? or_else 0
	lk.size = s.size.? or_else ICON_TOGGLE_SIZE
	if th.density != 0 do lk.size = max(lk.size + th.density * DENSITY_STEP, lk.icon_size, ICON_SIZE) // round: its diameter is its height
	lk.fill         = s.fill.? or_else c.fill_strong
	lk.ink          = s.ink.? or_else c.on_surface
	lk.pressed_fill = s.pressed_fill.? or_else c.primary
	lk.pressed_ink  = s.pressed_ink.? or_else c.on_primary
	return
}

// ---------------------------------------------------------------- field

// Field_Style is the look the single-line fields share: text_input,
// number_input, search_field, and the closed select, date_field,
// time_field and color_field (and time_picker's frame). Nil derives from
// the global tokens; hover and press still mix in from the state layers.
Field_Style :: struct {
	padding:            Maybe([4]f32), // a text field's: text_input, number_input, search_field's text, the hex field
	dropdown_padding:   Maybe([4]f32), // a closed drop-down's: select, date_field, time_field, color_field
	min_height:         Maybe(f32),    // nil: none; the height is a line of text plus padding
	inset:              Maybe(f32),    // edge to a leading magnifier or swatch, and to search_field's clear cross
	gap:                Maybe(f32),    // a drop-down's value to its icon
	radius:             Maybe(f32),
	border_width:       Maybe(f32),
	focus_border_width: Maybe(f32),    // nil: border_width
	fill:               Maybe(Color),
	border:             Maybe(Color),
	focus_border:       Maybe(Color),  // a focused field, an open drop-down
	ink:                Maybe(Color),  // typed text and a drop-down's value
	placeholder:        Maybe(Color),  // a placeholder, and a drop-down with nothing picked
	icon:               Maybe(Color),  // a drop-down's icon or chevron, the magnifier, the clear cross
	icon_size:          Maybe(f32),    // a drop-down's icon, the stepper glyphs
	caret:              Maybe(Color),  // nil: ink
	caret_width:        Maybe(f32),
	text:               Text_Override, // nil parts: the body step
	compact:            Field_Compact_Style,
	stepper:            Field_Stepper_Style,
	search:             Field_Search_Style,
	swatch:             Field_Swatch_Style,
	inline_card:        Field_Card_Style,
}

// Field_Compact_Style is an editor standing in for a label: a table cell's
// or a tree item's (text_input's `compact`).
Field_Compact_Style :: struct {
	padding: Maybe([4]f32),
	radius:  Maybe(f32),
}

// Field_Stepper_Style is number_input's − and + buttons.
Field_Stepper_Style :: struct {
	size:   Maybe(f32),   // square
	gap:    Maybe(f32),   // field to buttons, and between them
	radius: Maybe(f32),   // nil: the field's
	fill:   Maybe(Color), // nil: the field's
	ink:    Maybe(Color), // the glyphs; nil: the field's ink
}

// Field_Search_Style is what search_field adds to a field.
Field_Search_Style :: struct {
	gap:             Maybe(f32), // magnifier, text and clear cross
	icon_size:       Maybe(f32), // the magnifier
	clear_size:      Maybe(f32), // the clear cross's round target
	clear_text_size: Maybe(f32), // the × in it, before the desktop's text scale: text() applies that
}

// Field_Swatch_Style is color_field's swatch.
Field_Swatch_Style :: struct {
	size:   Maybe(f32),
	radius: Maybe(f32),
}

// Field_Card_Style is the wrapping editor laid over an icon view's label to
// rename it. Opaque, since it covers the tiles around it.
Field_Card_Style :: struct {
	padding:   Maybe([4]f32),
	radius:    Maybe(f32),          // nil: compact's
	fill:      Maybe(Color),
	border:    Maybe(Color),        // nil: focus_border, as it always has the keyboard
	shadow:    Maybe(Shadow_Style),
	text_size: Maybe(f32),
}

// Field_Look is Field_Style resolved, density applied. Widgets read this,
// never the style.
Field_Look :: struct {
	padding:            [4]f32,
	dropdown_padding:   [4]f32,
	min_height:         f32, // 0: none
	inset:              f32,
	gap:                f32,
	radius:             f32,
	border_width:       f32,
	focus_border_width: f32,
	fill:               Color,
	border:             Color,
	focus_border:       Color,
	ink:                Color,
	placeholder:        Color,
	icon:               Color,
	icon_size:          f32,
	caret:              Color,
	caret_width:        f32,
	text_size:          f32,         // final px: the text scale is already in it
	text_weight:        Font_Weight, // typed text
	family_name:        string,    // a family the style names; "" uses text_family / value_family
	text_family:        Family_Id,
	value_weight:       Font_Weight, // a drop-down's value, set as a body text is
	value_family:       Family_Id,
	compact:            Field_Compact_Look,
	stepper:            Field_Stepper_Look,
	search:             Field_Search_Look,
	swatch:             Field_Swatch_Look,
	inline_card:        Field_Card_Look,
}

Field_Compact_Look :: struct {
	padding: [4]f32,
	radius:  f32,
}

Field_Stepper_Look :: struct {
	size, gap, radius: f32,
	fill, ink:         Color,
}

Field_Search_Look :: struct {
	gap, icon_size, clear_size: f32,
	clear_text_size:            f32, // unscaled: passed through text(size =)
}

Field_Swatch_Look :: struct {
	size, radius: f32,
}

Field_Card_Look :: struct {
	padding:              [4]f32,
	radius, border_width: f32,
	fill, border:         Color,
	shadow:               Shadow_Style,
	text_size:            f32,
}


// field_look resolves the theme's Field_Style: nil from the global tokens,
// then density on the heights.
field_look :: proc(th: ^Theme) -> Field_Look {
	s := &th.field
	sp := th.space
	l: Field_Look
	l.padding = dense_pad4(th, s.padding.? or_else [4]f32{sp[.sm], sp[.md], sp[.sm], sp[.md]})
	l.dropdown_padding = dense_pad4(th, s.dropdown_padding.? or_else [4]f32{sp[.sm] - 1, sp[.md], sp[.sm] - 1, sp[.md]})
	l.min_height = dense_height(th, s.min_height.? or_else 0)
	l.inset = s.inset.? or_else sp[.sm]
	l.gap = s.gap.? or_else sp[.sm]
	l.radius = s.radius.? or_else th.radius.md
	l.border_width = s.border_width.? or_else 1
	l.focus_border_width = s.focus_border_width.? or_else l.border_width
	l.fill = s.fill.? or_else th.color.surface_variant
	l.border = s.border.? or_else th.color.outline
	l.focus_border = s.focus_border.? or_else th.color.primary
	l.ink = s.ink.? or_else th.color.on_surface
	l.placeholder = s.placeholder.? or_else th.color.on_surface_muted
	l.icon = s.icon.? or_else th.color.on_surface_muted
	l.icon_size = s.icon_size.? or_else ICON_SIZE
	l.caret = s.caret.? or_else l.ink
	l.caret_width = s.caret_width.? or_else 1
	l.text_size = s.text.size.? or_else th.type.body.size
	// Typed text is Regular in the theme's own family; a drop-down's value is
	// a body text. A set weight or family makes them one.
	if w, ok := s.text.weight.?; ok {
		l.text_weight, l.value_weight = w, w
	} else {
		l.text_weight, l.value_weight = .Regular, th.type.body.weight
	}
	if fam, ok := s.text.family.?; ok {
		l.family_name = fam // the widget resolves it: look_family
		l.text_family, l.value_family = 0, 0
	} else {
		l.text_family, l.value_family = 0, role_family(th, .Body)
	}
	l.compact = {
		padding = dense_pad4(th, s.compact.padding.? or_else [4]f32{2, 6, 2, 6}),
		radius  = s.compact.radius.? or_else th.radius.sm,
	}
	step := s.stepper.size.? or_else NUMBER_BUTTON
	l.stepper = {
		size   = dense_height(th, step, l.icon_size), // density never takes it below its glyph
		gap    = s.stepper.gap.? or_else sp[.xxs],
		radius = s.stepper.radius.? or_else l.radius,
		fill   = s.stepper.fill.? or_else l.fill,
		ink    = s.stepper.ink.? or_else l.ink,
	}
	l.search = {
		gap             = s.search.gap.? or_else sp[.xs],
		icon_size       = s.search.icon_size.? or_else SEARCH_ICON_SIZE,
		clear_size      = s.search.clear_size.? or_else SEARCH_CLEAR_SIZE,
		clear_text_size = s.search.clear_text_size.? or_else 15,
	}
	l.swatch = {
		size   = s.swatch.size.? or_else 20,
		radius = s.swatch.radius.? or_else th.radius.sm,
	}
	l.inline_card = {
		padding      = s.inline_card.padding.? or_else pad4(sp[.xxs]),
		radius       = s.inline_card.radius.? or_else l.compact.radius,
		border_width = l.focus_border_width,
		fill         = s.inline_card.fill.? or_else th.color.surface_high,
		border       = s.inline_card.border.? or_else l.focus_border,
		shadow       = s.inline_card.shadow.? or_else th.elev.mid,
		text_size    = s.inline_card.text_size.? or_else th.type.label.size,
	}
	return l
}

// field_value_size is a drop-down value's size as text() takes it: 0 for the
// body step's own (scaled already), otherwise the look's final px over the
// factor text() applies, so the value draws the size typed text does.
@(private)
field_value_size :: proc(t: ^Tree, lk: Field_Look) -> f32 {
	return 0 if lk.text_size == t.theme.type.body.size else lk.text_size / tree_text_scale(t)
}

// field_value_family is the family a drop-down's value is set in.
@(private)
field_value_family :: proc(t: ^Tree, lk: Field_Look) -> Family_Id {
	return lk.value_family if lk.family_name == "" else look_family(t, lk.family_name)
}

// ---------------------------------------------------------------- choice

// ---- Shared by every group: one copy in theme_style.odin ----


// ---- Checkbox and radio ----

// Check_Style is the checkbox and the radio. Their indicator, row and colours
// are shared so the two match; a field named for one applies to it alone. A
// radio's ring and dot are round on purpose and take no radius.
Check_Style :: struct {
	indicator_size:       Maybe(f32),    // the checkbox's box and the radio's ring, across
	gap:                  Maybe(f32),    // indicator to label
	radius:               Maybe(f32),    // a row's corners: its hover wash and focus ring
	text:                 Text_Override, // the label
	ink:                  Maybe(Color),  // the label
	border:               Maybe(Color),  // an unchecked indicator's edge
	selected_fill:        Maybe(Color),  // a checked box; a picked radio's ring and dot
	padding:              Maybe([4]f32), // the checkbox's row
	indicator_radius:     Maybe(f32),    // the checkbox's box corners
	border_width:         Maybe(f32),    // the checkbox's box edge
	fill:                 Maybe(Color),  // an unchecked box
	selected_ink:         Maybe(Color),  // the tick
	radio_padding:        Maybe([4]f32), // one radio option's row
	radio_border_width:   Maybe(f32),    // the radio's ring
	radio_gap:            Maybe(f32),    // between options down the page
	radio_gap_horizontal: Maybe(f32),    // between options across it (`horizontal`)
}

Check_Look :: struct {
	indicator_size, gap, radius:     f32,
	text:                            Text_Look,
	ink, border, selected_fill:      Color,
	padding:                         [4]f32,
	indicator_radius, border_width:  f32,
	fill, selected_ink:              Color,
	radio_padding:                   [4]f32,
	radio_border_width:              f32,
	radio_gap, radio_gap_horizontal: f32,
}

check_look :: proc(th: ^Theme) -> Check_Look {
	s := &th.check
	c := &th.color
	return {
		indicator_size       = s.indicator_size.? or_else CHECKBOX_SIZE,
		gap                  = s.gap.? or_else th.space[.sm],
		radius               = s.radius.? or_else th.radius.sm,
		text                 = text_look(th, .Body, s.text),
		ink                  = s.ink.? or_else c.on_surface,
		border               = s.border.? or_else c.outline,
		selected_fill        = s.selected_fill.? or_else c.primary,
		padding              = dense_pad4(th, s.padding.? or_else pad4(th.space[.xs])),
		indicator_radius     = s.indicator_radius.? or_else th.radius.xs,
		border_width         = s.border_width.? or_else 1,
		fill                 = s.fill.? or_else c.surface_variant,
		selected_ink         = s.selected_ink.? or_else c.on_primary,
		radio_padding        = dense_pad4(th, s.radio_padding.? or_else [4]f32{th.space[.xs], th.space[.sm], th.space[.xs], th.space[.xs]}),
		radio_border_width   = s.radio_border_width.? or_else 2,
		radio_gap            = s.radio_gap.? or_else th.space[.xxs],
		radio_gap_horizontal = s.radio_gap_horizontal.? or_else th.space[.sm],
	}
}

// ---- Switch ----

// Toggle_Style is the switch. Its track and thumb stay round whatever the
// radii: a switch is read by its shape before its colour.
Toggle_Style :: struct {
	track_width:    Maybe(f32),
	track_height:   Maybe(f32),
	thumb_size:     Maybe(f32),          // the thumb, across
	gap:            Maybe(f32),          // switch to label
	padding:        Maybe([4]f32),       // the row
	radius:         Maybe(f32),          // the row's corners: its hover wash and focus ring
	text:           Text_Override,       // the label
	ink:            Maybe(Color),        // the label
	track:          Maybe(Color),        // off
	selected_track: Maybe(Color),        // on
	border:         Maybe(Color),        // the off track's edge; it fades out as the switch comes on
	border_width:   Maybe(f32),
	thumb:          Maybe(Color),        // off
	selected_thumb: Maybe(Color),        // on
	thumb_shadow:   Maybe(Shadow_Style),
}

Toggle_Look :: struct {
	track_width, track_height, thumb_size: f32,
	gap:                                   f32,
	padding:                               [4]f32,
	radius:                                f32,
	text:                                  Text_Look,
	ink, track, selected_track, border:    Color,
	border_width:                          f32,
	thumb, selected_thumb:                 Color,
	thumb_shadow:                          Shadow_Style,
}

toggle_look :: proc(th: ^Theme) -> Toggle_Look {
	s := &th.toggle
	c := &th.color
	return {
		track_width    = s.track_width.? or_else TOGGLE_W,
		track_height   = s.track_height.? or_else TOGGLE_H,
		thumb_size     = s.thumb_size.? or_else SLIDER_THUMB,
		gap            = s.gap.? or_else th.space[.sm],
		padding        = dense_pad4(th, s.padding.? or_else pad4(th.space[.xs])),
		radius         = s.radius.? or_else th.radius.sm,
		text           = text_look(th, .Body, s.text),
		ink            = s.ink.? or_else c.on_surface,
		track          = s.track.? or_else c.surface_high,
		selected_track = s.selected_track.? or_else c.primary,
		border         = s.border.? or_else c.outline,
		border_width   = s.border_width.? or_else 1,
		thumb          = s.thumb.? or_else c.on_surface_muted,
		selected_thumb = s.selected_thumb.? or_else c.on_primary,
		thumb_shadow   = s.thumb_shadow.? or_else Shadow_Style{offset = {0, 1}, blur = 3, color = {0, 0, 0, 0.25}},
	}
}

// ---- Slider ----

// Slider_Style is the slider at both sizes. Its thumbs stay round whatever
// the radii, and a Large slider stays a pill: its knob is as tall as its track.
Slider_Style :: struct {
	width:   Maybe(f32),           // when the call gives none
	regular: Slider_Regular_Style,
	large:   Slider_Large_Style,
	readout: Slider_Readout_Style, // the value shown above it (slider_options' `format`)
}

Slider_Regular_Style :: struct {
	height:             Maybe(f32),          // the slider's own; track and thumb are centred in it
	track_height:       Maybe(f32),
	thumb_size:         Maybe(f32),          // across
	thumb_border_width: Maybe(f32),
	track:              Maybe(Color),        // the groove past the thumb
	fill:               Maybe(Color),        // the groove up to the thumb, and the thumb's hover halo
	thumb:              Maybe(Color),
	thumb_border:       Maybe(Color),        // over a plain track; a sampled one (a colour picker) keeps `surface`
	thumb_shadow:       Maybe(Shadow_Style),
}

Slider_Large_Style :: struct {
	height:       Maybe(f32),          // the pill, and its knob
	icon_size:    Maybe(f32),          // nil: 0.54 of the height
	track:        Maybe(Color),
	fill:         Maybe(Color),        // up to and under the knob, and the knob's hover halo
	thumb:        Maybe(Color),
	thumb_shadow: Maybe(Shadow_Style),
	fill_ink:     Maybe(Color),        // the icon over the fill
	thumb_ink:    Maybe(Color),        // the icon under the knob
	track_ink:    Maybe(Color),        // the icon on the track past the fill
}

Slider_Readout_Style :: struct {
	fill:   Maybe(Color),
	ink:    Maybe(Color),
	border: Maybe(Color),
	radius: Maybe(f32),
	text:   Text_Override,
}

Slider_Regular_Look :: struct {
	height, track_height, thumb_size, thumb_border_width: f32,
	track, fill, thumb, thumb_border:                     Color,
	thumb_shadow:                                         Shadow_Style,
}

Slider_Large_Look :: struct {
	height, icon_size:              f32,
	track, fill, thumb:             Color,
	thumb_shadow:                   Shadow_Style,
	fill_ink, thumb_ink, track_ink: Color,
}

// Slider_Readout_Look: drawn straight to the layer, so `text.size` is the
// px drawn (never 0) and `text.weight` is the readout's own, not the caption's.
Slider_Readout_Look :: struct {
	fill, ink, border: Color,
	radius:            f32,
	text:              Text_Look,
}

Slider_Look :: struct {
	width:   f32,
	regular: Slider_Regular_Look,
	large:   Slider_Large_Look,
	readout: Slider_Readout_Look,
}

slider_look :: proc(th: ^Theme) -> Slider_Look {
	s := &th.slider
	c := &th.color
	r, g, o := &s.regular, &s.large, &s.readout
	lk: Slider_Look
	lk.width = s.width.? or_else 160

	lk.regular.thumb_size         = r.thumb_size.? or_else SLIDER_THUMB
	lk.regular.height             = dense_height(th, r.height.? or_else SLIDER_H, lk.regular.thumb_size)
	lk.regular.track_height       = r.track_height.? or_else 4
	lk.regular.thumb_border_width = r.thumb_border_width.? or_else 2
	lk.regular.track              = r.track.? or_else c.outline
	lk.regular.fill               = r.fill.? or_else c.primary
	lk.regular.thumb              = r.thumb.? or_else c.primary
	lk.regular.thumb_border       = r.thumb_border.? or_else c.on_primary
	lk.regular.thumb_shadow       = r.thumb_shadow.? or_else Shadow_Style{offset = {0, 1}, blur = 4, color = {0, 0, 0, 0.3}}

	lk.large.height       = g.height.? or_else SLIDER_LARGE_H
	lk.large.icon_size    = g.icon_size.? or_else math.round(lk.large.height * 0.54)
	lk.large.track        = g.track.? or_else c.fill_strong
	lk.large.fill         = g.fill.? or_else c.primary
	lk.large.thumb        = g.thumb.? or_else (c.on_surface if th.dark else c.surface_high)
	lk.large.thumb_shadow = g.thumb_shadow.? or_else Shadow_Style{offset = {0, 1}, blur = 4, color = {0, 0, 0, 0.35}}
	lk.large.fill_ink     = g.fill_ink.? or_else c.on_primary
	lk.large.thumb_ink    = g.thumb_ink.? or_else (c.surface if th.dark else c.on_surface)
	lk.large.track_ink    = g.track_ink.? or_else c.on_surface

	lk.readout.fill   = o.fill.? or_else c.surface_high
	lk.readout.ink    = o.ink.? or_else c.on_surface
	lk.readout.border = o.border.? or_else c.outline_variant
	lk.readout.radius = o.radius.? or_else th.radius.sm
	lk.readout.text   = {
		role   = .Caption,
		size   = o.text.size.? or_else th.type.caption.size,
		weight = o.text.weight.? or_else .Regular,
		family = o.text.family.? or_else "",
	}
	return lk
}

// ---- Segmented control ----

// Segmented_Style is the segmented control: a groove of segments with the
// picked one raised in it. A segment's side padding gives way, from
// `padding_x` down to `min_padding_x`, before its label is cut.
Segmented_Style :: struct {
	track_padding:   Maybe([4]f32),       // the groove around the segments
	padding_x:       Maybe(f32),          // a segment's sides while there is room
	min_padding_x:   Maybe(f32),          // …and the least they give way to
	padding_y:       Maybe(f32),
	gap:             Maybe(f32),          // icon to label
	icon_size:       Maybe(f32),
	radius:          Maybe(f32),          // the groove's corners, at most half its height
	segment_radius:  Maybe(f32),          // a segment's: its hover wash, the picked pill, the focus ring
	text:            Text_Override,
	track:           Maybe(Color),        // the groove; nil steps away from `selected_fill` until the two tell apart
	ink:             Maybe(Color),        // an unpicked segment's label and icon
	selected_fill:   Maybe(Color),        // the picked segment
	selected_ink:    Maybe(Color),
	selected_shadow: Maybe(Shadow_Style),
}

Segmented_Look :: struct {
	track_padding:                       [4]f32,
	padding_x, min_padding_x, padding_y: f32,
	gap, icon_size:                      f32,
	radius, segment_radius:              f32,
	text:                                Text_Look,
	track, ink, selected_fill, selected_ink: Color,
	selected_shadow:                     Shadow_Style,
}

segmented_look :: proc(th: ^Theme) -> Segmented_Look {
	s := &th.segmented
	c := &th.color
	lk: Segmented_Look
	lk.track_padding   = s.track_padding.? or_else pad4(3)
	lk.padding_x       = s.padding_x.? or_else th.space[.md]
	lk.min_padding_x   = s.min_padding_x.? or_else th.space[.xs]
	lk.padding_y       = dense_pad(th, s.padding_y.? or_else th.space[.xs])
	lk.gap             = s.gap.? or_else th.space[.xs]
	lk.icon_size       = s.icon_size.? or_else ICON_SIZE
	lk.radius          = s.radius.? or_else th.radius.full
	lk.segment_radius  = s.segment_radius.? or_else lk.radius
	lk.text            = text_look(th, .Label, s.text)
	lk.ink             = s.ink.? or_else c.on_surface_muted
	lk.selected_fill   = s.selected_fill.? or_else c.surface_high
	lk.selected_ink    = s.selected_ink.? or_else c.on_surface
	lk.selected_shadow = s.selected_shadow.? or_else th.elev.low
	lk.track           = s.track.? or_else choice_track_from(th, lk.selected_fill)
	return lk
}


// choice_track_from is the groove stepped away from `against`, the picked
// segment's fill, until the two tell apart; choice_track(th) stays as
// choice_track_from(th, th.color.surface_high) for its callers.
@(private)
choice_track_from :: proc(th: ^Theme, against: Color) -> Color {
	track := th.color.surface_variant
	if contrast_ratio(track, against) >= CHOICE_TRACK_SEPARATION do return track
	for step := f32(0.04); step <= 0.24; step += 0.04 {
		stepped := mix(track, th.color.on_surface, step)
		if contrast_ratio(stepped, against) >= CHOICE_TRACK_SEPARATION do return stepped
	}
	return mix(track, th.color.on_surface, 0.24)
}


// ---------------------------------------------------------------- rows


LIST_ROW_KEYCAP_PADDING_X :: f32(5) // each side of a keycap's text

// ---- List rows (list_row) ----

// List_Row_Style is a theme's list_row. What differs between a plain row and
// a tiled one (Tile, Accent, Avatar) is in the two variant sub-styles.
List_Row_Style :: struct {
	min_height:      Maybe(f32),             // density moves it
	plain:           List_Row_Variant_Style, // variant = .Plain
	tiled:           List_Row_Variant_Style, // .Tile, .Accent, .Avatar
	title_large:     Text_Override,          // size = .Large, either variant
	icon_size:       Maybe(f32),             // a plain row's icon, glyph and picture; the end check and chevron
	image_radius:    Maybe(f32),             // a plain row's picture with image_round = false
	ink:             Maybe(Color),           // the title and a plain row's icons
	detail_ink:      Maybe(Color),           // secondary text: the detail, value and hint while nothing is unread
	selected_fill:   Maybe(Color),
	indicator:       Maybe(Color),           // the bar at the start of a selected or unread row
	indicator_width: Maybe(f32),
	indicator_inset: Maybe(f32),             // from the row's top and bottom
	tile:            List_Row_Tile_Style,
	badge:           List_Row_Badge_Style,
	hint:            List_Row_Hint_Style,
}

// List_Row_Variant_Style is what a plain and a tiled row lay out differently.
List_Row_Variant_Style :: struct {
	gap:     Maybe(f32),
	padding: Maybe([4]f32), // density moves top and bottom
	radius:  Maybe(f32),
	title:   Text_Override,
	detail:  Text_Override,
}

// List_Row_Tile_Style is a tiled row's leading tile; an Avatar is a circle as wide.
List_Row_Tile_Style :: struct {
	size:          Maybe(f32),
	radius:        Maybe(f32),
	icon_size:     Maybe(f32),
	app_icon_size: Maybe(f32),   // a theme icon, which fills the tile
	glyph_size:    Maybe(f32),   // a text size: before the text scale
	fill:          Maybe(Color),
	ink:           Maybe(Color),
	border:        Maybe(Color), // an empty square tile's 1 px outline
	accent_fill:   Maybe(Color), // variant = .Accent
	accent_ink:    Maybe(Color),
}

// List_Row_Badge_Style is the unread count's pill: a circle at one digit.
List_Row_Badge_Style :: struct {
	size:      Maybe(f32), // its height, and its width at one digit
	radius:    Maybe(f32),
	padding_x: Maybe(f32), // each side, past one digit
	fill:      Maybe(Color),
	ink:       Maybe(Color),
	text:      Text_Override,
}

// List_Row_Hint_Style is a selected row's hint: a keycap, then what it does.
List_Row_Hint_Style :: struct {
	gap:              Maybe(f32),
	keycap_height:    Maybe(f32), // also its narrowest width
	keycap_radius:    Maybe(f32),
	keycap_padding_x: Maybe(f32),
	keycap_fill:      Maybe(Color),
	keycap_border:    Maybe(Color), // 1 px
	keycap_text:      Text_Override,
	text:             Text_Override, // the verb
}

List_Row_Look :: struct {
	min_height:      f32, // before target_min, which the row applies
	plain, tiled:    List_Row_Variant_Look,
	title_large:     Text_Look,
	icon_size:       f32,
	image_radius:    f32,
	ink:             Color,
	detail_ink:      Color,
	selected_fill:   Color,
	indicator:       Color,
	indicator_width: f32,
	indicator_inset: f32,
	tile:            List_Row_Tile_Look,
	badge:           List_Row_Badge_Look,
	hint:            List_Row_Hint_Look,
}

List_Row_Variant_Look :: struct {
	gap:           f32,
	padding:       [4]f32,
	radius:        f32,
	title, detail: Text_Look,
}

List_Row_Tile_Look :: struct {
	size, radius, icon_size, app_icon_size, glyph_size: f32,
	fill, ink, border, accent_fill, accent_ink:         Color,
}

List_Row_Badge_Look :: struct {
	size, radius, padding_x: f32,
	fill, ink:               Color,
	text:                    Text_Look,
}

List_Row_Hint_Look :: struct {
	gap, keycap_height, keycap_radius, keycap_padding_x: f32,
	keycap_fill, keycap_border:                          Color,
	keycap_text, text:                                   Text_Look,
}

// list_row_look resolves the theme's list_row: nil from the global tokens,
// density applied. The row still takes target_min when it is larger, since
// that depends on the pointer and not only the theme.
list_row_look :: proc "contextless" (th: ^Theme) -> List_Row_Look {
	s := &th.list_row
	c := &th.color
	body := text_style(th, .Body)
	plain_gap := th.space[.sm] + th.space[.xxs] // 10 px: the design's rows
	tile_size := s.tile.size.? or_else LIST_ROW_TILE
	badge_size := s.badge.size.? or_else LIST_ROW_BADGE
	return {
		min_height = dense_height(th, s.min_height.? or_else LIST_ROW_MIN_H),
		plain = {
			gap     = s.plain.gap.? or_else plain_gap,
			padding = dense_pad4(th, s.plain.padding.? or_else [4]f32{th.space[.sm], plain_gap, th.space[.sm], plain_gap}),
			radius  = s.plain.radius.? or_else th.radius.md,
			title   = text_look(th, .Body, s.plain.title),
			detail  = text_look(th, .Body, s.plain.detail),
		},
		tiled = {
			gap     = s.tiled.gap.? or_else LIST_ROW_TILED_GAP,
			padding = dense_pad4(th, s.tiled.padding.? or_else LIST_ROW_TILED_PADDING),
			radius  = s.tiled.radius.? or_else LIST_ROW_TILED_RADIUS,
			title   = text_look(th, .Body, s.tiled.title, LIST_ROW_TITLE, .Medium),
			detail  = text_look(th, .Body, s.tiled.detail, LIST_ROW_DETAIL, body.weight),
		},
		title_large     = text_look(th, .Body, s.title_large, LIST_ROW_TITLE_LARGE, .Semibold),
		icon_size       = s.icon_size.? or_else ICON_SIZE,
		image_radius    = s.image_radius.? or_else th.radius.xs,
		ink             = s.ink.? or_else c.on_surface,
		detail_ink      = s.detail_ink.? or_else c.on_surface_muted,
		selected_fill   = s.selected_fill.? or_else with_alpha(c.primary, LIST_ROW_SELECTED),
		indicator       = s.indicator.? or_else c.primary,
		indicator_width = s.indicator_width.? or_else LIST_ROW_BAR,
		indicator_inset = s.indicator_inset.? or_else LIST_ROW_BAR_INSET,
		tile = {
			size          = tile_size,
			radius        = s.tile.radius.? or_else LIST_ROW_TILE_RADIUS,
			icon_size     = s.tile.icon_size.? or_else LIST_ROW_TILE_ICON,
			app_icon_size = s.tile.app_icon_size.? or_else LIST_ROW_TILE_APP_ICON,
			glyph_size    = s.tile.glyph_size.? or_else LIST_ROW_TILE_GLYPH,
			fill          = s.tile.fill.? or_else c.fill,
			ink           = s.tile.ink.? or_else c.on_surface_muted,
			border        = s.tile.border.? or_else c.outline_variant,
			accent_fill   = s.tile.accent_fill.? or_else with_alpha(c.primary, LIST_ROW_ACCENT_TILE), // the tile is a fill…
			accent_ink    = s.tile.accent_ink.? or_else c.accent_text,                                // …its glyph is ink
		},
		badge = {
			size      = badge_size,
			radius    = s.badge.radius.? or_else badge_size / 2,
			padding_x = s.badge.padding_x.? or_else th.space[.xs],
			fill      = s.badge.fill.? or_else c.primary,
			ink       = s.badge.ink.? or_else c.on_primary,
			text      = text_look(th, .Caption, s.badge.text),
		},
		hint = {
			gap              = s.hint.gap.? or_else LIST_ROW_HINT_GAP,
			keycap_height    = s.hint.keycap_height.? or_else LIST_ROW_KEYCAP,
			keycap_radius    = s.hint.keycap_radius.? or_else LIST_ROW_KEYCAP_RADIUS,
			keycap_padding_x = s.hint.keycap_padding_x.? or_else LIST_ROW_KEYCAP_PADDING_X,
			keycap_fill      = s.hint.keycap_fill.? or_else with_alpha(c.on_surface, LIST_ROW_KEYCAP_FILL),
			keycap_border    = s.hint.keycap_border.? or_else c.outline_variant,
			keycap_text      = text_look(th, .Body, s.hint.keycap_text, LIST_ROW_KEYCAP_TEXT, body.weight),
			text             = text_look(th, .Body, s.hint.text, LIST_ROW_HINT_TEXT, body.weight),
		},
	}
}

// ---- Tree rows (tree_view, tree_item) ----

// Tree_Row_Style is a theme's tree_item rows, their indent guides and the
// tree_view's indent per level.
Tree_Row_Style :: struct {
	min_height:      Maybe(f32),    // density moves it
	padding:         Maybe([4]f32), // density moves top and bottom
	gap:             Maybe(f32),    // between chevron, icon and label
	radius:          Maybe(f32),    // the row, and the keyboard cursor's ring around it
	indent:          Maybe(f32),    // per level; tree_view's own `indent` wins
	chevron_size:    Maybe(f32),    // the expander's slot, kept on a leaf so labels line up
	icon_size:       Maybe(f32),
	text:            Text_Override,
	ink:             Maybe(Color),  // label and icon
	muted_ink:       Maybe(Color),  // …of a muted row (tree_item's `muted`)
	branch_icon_ink: Maybe(Color),  // a branch's icon while it is not selected
	chevron_ink:     Maybe(Color),
	guide:           Maybe(Color),  // the indent guides, one hairline per level
	selected_fill:   Maybe(Color),
	selected_ink:    Maybe(Color),
}

Tree_Row_Look :: struct {
	min_height:      f32, // before target_min, which the row applies
	padding:         [4]f32,
	gap:             f32,
	radius:          f32,
	indent:          f32,
	chevron_size:    f32,
	icon_size:       f32,
	text:            Text_Look,
	ink:             Color,
	muted_ink:       Color,
	branch_icon_ink: Color,
	chevron_ink:     Color,
	guide:           Color,
	selected_fill:   Color,
	selected_ink:    Color,
}

// tree_row_look resolves the theme's tree_row: nil from the global tokens,
// density applied. Paint reads it too (chevron, guides, cursor ring).
tree_row_look :: proc "contextless" (th: ^Theme) -> Tree_Row_Look {
	s := &th.tree_row
	c := &th.color
	chevron := c.on_surface
	chevron.a *= 0.7 // quieter than the label it opens
	return {
		min_height      = dense_height(th, s.min_height.? or_else TREE_ROW_MIN_H),
		padding         = dense_pad4(th, s.padding.? or_else [4]f32{th.space[.xxs], th.space[.sm], th.space[.xxs], th.space[.sm]}),
		gap             = s.gap.? or_else th.space[.xs],
		radius          = s.radius.? or_else th.radius.sm,
		indent          = s.indent.? or_else TREE_INDENT,
		chevron_size    = s.chevron_size.? or_else TREE_CHEVRON,
		icon_size       = s.icon_size.? or_else ICON_SIZE,
		text            = text_look(th, .Body, s.text),
		ink             = s.ink.? or_else c.on_surface,
		muted_ink       = s.muted_ink.? or_else c.on_surface_muted,
		branch_icon_ink = s.branch_icon_ink.? or_else c.accent_text,
		chevron_ink     = s.chevron_ink.? or_else chevron,
		guide           = s.guide.? or_else c.outline_variant,
		selected_fill   = s.selected_fill.? or_else c.primary_container,
		selected_ink    = s.selected_ink.? or_else c.on_primary_container,
	}
}

// ---------------------------------------------------------------- table

// ---- Shared by every component group: define once in theme_style.odin ----


// text_look_line is about one line of `tl` tall: a floor for density, not a measurement.
@(private)
text_look_line :: proc "contextless" (th: ^Theme, tl: Text_Look) -> f32 {
	st := text_style(th, tl.role)
	return (tl.size if tl.size > 0 else st.size) * st.line_height
}

// ---- table ----

// Table_Style is the theme's say over every `table`; nil follows the global tokens.
// An app's own `row_height` replaces the row and header heights for that table.
Table_Style :: struct {
	row_height:          Maybe(f32),    // body rows; density moves it
	header_height:       Maybe(f32),    // nil: as tall as a row
	fill:                Maybe(Color),  // behind the rows
	border:              Maybe(Color),
	border_width:        Maybe(f32),
	radius:              Maybe(f32),
	header_fill:         Maybe(Color),
	header_ink:          Maybe(Color),  // headings and the sort arrow
	header_text:         Text_Override, // nil fields: the Label step
	cell_padding:        Maybe([4]f32), // header and body cells alike, so headings line up with their cells
	cell_gap:            Maybe(f32),    // between a cell's icon and its text
	cell_text:           Text_Override, // `cell_text`; nil fields: the Body step
	ink:                 Maybe(Color),  // `cell_text`'s text and icon
	muted_ink:           Maybe(Color),  // …when `muted`
	icon_size:           Maybe(f32),    // `cell_text`'s icon
	divider:             Maybe(Color),  // the hairlines between headings
	divider_width:       Maybe(f32),
	divider_inset:       Maybe(f32),    // kept clear above and below a divider
	selected_fill:       Maybe(Color),
	selected_ink:        Maybe(Color),  // `cell_text` in a selected row, muted cells too; nil: as unselected
	row_radius:          Maybe(f32),    // a row's corners; its selection, hover and cursor follow them
	cursor_border:       Maybe(Color),  // the keyboard's row
	cursor_border_width: Maybe(f32),
	indicator:           Maybe(Color),  // the resize guide and a column move's drop marker
	marquee:             Maybe(Color),  // the rubber band: its edge, and its fill at 15 %
}

// Table_Look is a table's style resolved against the theme, density applied.
Table_Look :: struct {
	row_height, header_height:  f32,
	fill, border:               Color,
	border_width, radius:       f32,
	header_fill, header_ink:    Color,
	header_text:                Text_Look,
	cell_padding:               [4]f32,
	cell_gap:                   f32,
	cell_text:                  Text_Look,
	ink, muted_ink:             Color,
	icon_size:                  f32,
	divider:                    Color,
	divider_width:              f32,
	divider_inset:              f32,
	selected_fill:              Color,
	selected_ink:               Color,
	selected_muted_ink:         Color,
	row_radius:                 f32,
	cursor_border:              Color,
	cursor_border_width:        f32,
	indicator, marquee:         Color,
}

// table_look is how every table draws under `th`. An app that zooms its rows
// scales `row_height` from here, so the theme and density still apply.
table_look :: proc(th: ^Theme) -> Table_Look {
	s := &th.table
	l: Table_Look
	l.fill                = s.fill.? or_else th.color.surface
	l.border              = s.border.? or_else th.color.outline_variant
	l.border_width        = s.border_width.? or_else 1
	l.radius              = s.radius.? or_else th.radius.md
	l.header_fill         = s.header_fill.? or_else th.color.surface_variant
	l.header_ink          = s.header_ink.? or_else th.color.on_surface_muted
	l.header_text         = text_look(th, .Label, s.header_text)
	l.cell_padding        = s.cell_padding.? or_else [4]f32{0, 12, 0, 12}
	l.cell_gap            = s.cell_gap.? or_else 4
	l.cell_text           = text_look(th, .Body, s.cell_text)
	l.ink                 = s.ink.? or_else th.color.on_surface
	l.muted_ink           = s.muted_ink.? or_else th.color.on_surface_muted
	l.icon_size           = s.icon_size.? or_else ICON_SIZE
	l.divider             = s.divider.? or_else th.color.outline_variant
	l.divider_width       = s.divider_width.? or_else 1
	l.divider_inset       = s.divider_inset.? or_else 9
	l.selected_fill       = s.selected_fill.? or_else th.color.primary_container
	l.selected_ink        = s.selected_ink.? or_else l.ink
	l.selected_muted_ink  = s.selected_ink.? or_else l.muted_ink
	l.row_radius          = s.row_radius.? or_else 0
	l.cursor_border       = s.cursor_border.? or_else th.color.primary
	l.cursor_border_width = s.cursor_border_width.? or_else 1
	l.indicator           = s.indicator.? or_else th.color.primary
	l.marquee             = s.marquee.? or_else th.color.primary
	pad_y := l.cell_padding[0] + l.cell_padding[2]
	l.row_height = dense_height(th, s.row_height.? or_else TABLE_ROW_HEIGHT,
		max(max(text_look_line(th, l.cell_text), l.icon_size) + pad_y, th.min_target))
	l.header_height = l.row_height
	if h, set := s.header_height.?; set do l.header_height = dense_height(th, h, max(text_look_line(th, l.header_text) + pad_y, th.min_target))
	return l
}

// ---- icon view ----

// Icon_View_Style is the theme's say over every `icon_view`; nil follows the global tokens.
// An app's own `tile`, `gap` or `padding` replaces the theme's for that view.
Icon_View_Style :: struct {
	tile:                Maybe([2]f32),  // an `.Icons` tile; its icon grows with it
	picture_tile:        Maybe([2]f32),  // a `.Pictures` tile
	gap:                 Maybe(f32),     // between tiles, both ways
	padding:             Maybe([4]f32),  // round the grid
	tile_padding:        Maybe([4]f32),  // inside an `.Icons` tile
	tile_gap:            Maybe(f32),     // between its icon and label
	picture_padding:     Maybe([4]f32),  // inside a `.Pictures` tile; the picture's square fits within it
	picture_gap:         Maybe(f32),     // between its picture, title and subtitle
	radius:              Maybe(f32),     // a tile's corners; its selection, hover and cursor follow them
	thumbnail_radius:    Maybe(f32),     // an `.Icons` tile's picture
	picture_radius:      Maybe(f32),     // a `.Pictures` tile's picture, or the square standing in for it
	placeholder_fill:    Maybe(Color),   // that square, for a picture tile with no picture
	placeholder_ink:     Maybe(Color),   // …and the icon on it
	ink:                 Maybe(Color),   // labels, titles and icons
	subtitle_ink:        Maybe(Color),
	selected_fill:       Maybe(Color),
	selected_ink:        Maybe(Color),   // everything on a selected tile, its subtitle too
	cursor_border:       Maybe(Color),   // the keyboard's tile
	cursor_border_width: Maybe(f32),
	label_text:          Text_Override,  // an `.Icons` label; nil fields: the Label step
	title_text:          Text_Override,  // a `.Pictures` title; nil fields: Label at Medium weight
	subtitle_text:       Text_Override,  // nil fields: the Caption step
	marquee:             Maybe(Color),   // the rubber band: its edge, and its fill at 15 %
}

// Icon_View_Look is an icon view's style resolved against the theme.
Icon_View_Look :: struct {
	tile, picture_tile:                     [2]f32,
	gap:                                    f32,
	padding, tile_padding, picture_padding: [4]f32,
	tile_gap, picture_gap:                  f32,
	radius, thumbnail_radius, picture_radius: f32,
	placeholder_fill, placeholder_ink:      Color,
	ink, subtitle_ink:                      Color,
	selected_fill, selected_ink:            Color,
	cursor_border:                          Color,
	cursor_border_width:                    f32,
	label_text, title_text, subtitle_text:  Text_Look,
	marquee:                                Color,
}

// icon_view_look is how every icon view draws under `th`. An app that zooms
// its tiles scales `tile` from here, so the theme still applies.
icon_view_look :: proc(th: ^Theme) -> Icon_View_Look {
	s := &th.icon_view
	return {
		tile                = s.tile.? or_else ICON_TILE,
		picture_tile        = s.picture_tile.? or_else PICTURE_TILE,
		gap                 = s.gap.? or_else th.space[.sm],
		padding             = s.padding.? or_else pad4(th.space[.sm]),
		tile_padding        = s.tile_padding.? or_else [4]f32{6, 4, 4, 4},
		tile_gap            = s.tile_gap.? or_else 4,
		picture_padding     = s.picture_padding.? or_else pad4(6),
		picture_gap         = s.picture_gap.? or_else 2,
		radius              = s.radius.? or_else th.radius.md,
		thumbnail_radius    = s.thumbnail_radius.? or_else th.radius.sm,
		picture_radius      = s.picture_radius.? or_else th.radius.md,
		placeholder_fill    = s.placeholder_fill.? or_else th.color.surface_variant,
		placeholder_ink     = s.placeholder_ink.? or_else th.color.on_surface_muted,
		ink                 = s.ink.? or_else th.color.on_surface,
		subtitle_ink        = s.subtitle_ink.? or_else th.color.on_surface_muted,
		selected_fill       = s.selected_fill.? or_else th.color.primary_container,
		selected_ink        = s.selected_ink.? or_else th.color.on_primary_container,
		cursor_border       = s.cursor_border.? or_else th.color.primary,
		cursor_border_width = s.cursor_border_width.? or_else 1,
		label_text          = text_look(th, .Label, s.label_text),
		title_text          = text_look(th, .Label, s.title_text, weight = .Medium),
		subtitle_text       = text_look(th, .Caption, s.subtitle_text),
		marquee             = s.marquee.? or_else th.color.primary,
	}
}

// ---------------------------------------------------------------- menus

// text_look_family is the `family` to pass to `text` for a look: 0 lets
// `text` take the step's family.
@(private)
text_look_family :: proc(t: ^Tree, tl: Text_Look) -> Family_Id {
	return look_family(t, tl.family)
}

// ---------------------------------------------------------------- tabs

// Tab_Style: a tab_bar's tabs and the indicator under the selected tab.
Tab_Style :: struct {
	gap:              Maybe(f32),     // between tabs
	padding:          Maybe([4]f32),  // top, end, bottom, start; the bottom stops above the indicator
	min_height:       Maybe(f32),     // 0: as tall as the label and padding
	radius:           Maybe(f32),     // corners of the focus ring (a tab draws no fill)
	ink:              Maybe(Color),   // label of an unselected tab
	selected_ink:     Maybe(Color),
	indicator:        Maybe(Color),   // the selected tab's underline
	indicator_height: Maybe(f32),
	indicator_gap:    Maybe(f32),     // between the bottom padding and the indicator
	text:             Text_Override,
}

Tab_Look :: struct {
	gap:              f32,
	padding:          [4]f32, // the bottom includes the indicator and its gap
	min_height:       f32,
	radius:           f32,
	ink:              Color,
	selected_ink:     Color,
	indicator:        Color,
	indicator_height: f32,
	indicator_radius: f32,
	text:             Text_Look,
}

tab_look :: proc(th: ^Theme) -> Tab_Look {
	s := &th.tab
	pad := s.padding.? or_else [4]f32{th.space[.sm], th.space[.md], th.space[.sm], th.space[.md]}
	ih := s.indicator_height.? or_else TAB_INDICATOR_H
	ig := s.indicator_gap.? or_else 2
	return Tab_Look{
		gap              = s.gap.? or_else th.space[.xs],
		padding          = {dense_pad(th, pad[0]), pad[1], dense_pad(th, pad[2]) + ih + ig, pad[3]},
		min_height       = dense_height(th, s.min_height.? or_else 0),
		radius           = s.radius.? or_else th.radius.sm,
		ink              = s.ink.? or_else th.color.on_surface_muted,
		selected_ink     = s.selected_ink.? or_else th.color.on_surface,
		indicator        = s.indicator.? or_else th.color.primary,
		indicator_height = ih,
		indicator_radius = ih / 2,
		text             = text_look(th, .Label, s.text),
	}
}

// ---------------------------------------------------------------- menus

// Menu_Style: the card and rows of a menu, context_menu, submenu, a select's
// list and a menu bar's dropdowns. On glass the card is the theme's popover
// material, which replaces fill, border and shadow.
Menu_Style :: struct {
	fill:            Maybe(Color),
	border:          Maybe(Color),
	border_width:    Maybe(f32),
	radius:          Maybe(f32),
	shadow:          Maybe(Shadow_Style),
	padding:         Maybe([4]f32),  // around the rows; a submenu lines its first row up with the row that opened it
	gap:             Maybe(f32),     // between rows
	item_padding:    Maybe([4]f32),  // menu_item, submenu row, a select's option
	item_min_height: Maybe(f32),     // 0: as tall as the label and padding
	item_gap:        Maybe(f32),     // between the label and the shortcut or chevron
	item_radius:     Maybe(f32),     // the hover wash and the selected or open fill
	icon_gap:        Maybe(f32),     // between the check slot, the icon and the label
	icon_size:       Maybe(f32),     // icons, the check and its slot, a submenu's chevron
	ink:             Maybe(Color),   // label, icon, check and radio dot
	text:            Text_Override,
	shortcut_ink:    Maybe(Color),   // shortcut hints and a submenu's chevron
	shortcut_text:   Text_Override,
	selected_fill:   Maybe(Color),   // a select's chosen option
	selected_ink:    Maybe(Color),
	open_fill:       Maybe(Color),   // a submenu row while its submenu is open
}

Menu_Look :: struct {
	fill:            Color,
	border:          Color,
	border_width:    f32,
	radius:          f32,
	shadow:          Shadow_Style,
	padding:         [4]f32,
	gap:             f32,
	item_padding:    [4]f32,
	item_min_height: f32,
	item_gap:        f32,
	item_radius:     f32,
	icon_gap:        f32,
	icon_size:       f32,
	ink:             Color,
	text:            Text_Look,
	shortcut_ink:    Color,
	shortcut_text:   Text_Look,
	selected_fill:   Color,
	selected_ink:    Color,
	open_fill:       Color,
	submenu_gap:     f32,    // from the row: the parent card's end padding plus 2, so it sits just outside that card
	submenu_nudge:   [2]f32, // lifts a submenu so its first row is level with the row that opened it
}

menu_look :: proc(th: ^Theme) -> Menu_Look {
	s := &th.menu
	card := popover_look(th) // a menu is a popover: a card field the menu style leaves nil follows th.popover
	pad := s.padding.? or_else card.padding
	item_pad := s.item_padding.? or_else [4]f32{th.space[.sm] - 1, th.space[.md], th.space[.sm] - 1, th.space[.md]}
	return Menu_Look{
		fill            = s.fill.? or_else card.fill,
		border          = s.border.? or_else card.border,
		border_width    = s.border_width.? or_else card.border_width,
		radius          = s.radius.? or_else card.radius,
		shadow          = s.shadow.? or_else card.shadow,
		padding         = pad,
		gap             = s.gap.? or_else card.gap,
		item_padding    = dense_pad4(th, item_pad),
		item_min_height = dense_height(th, s.item_min_height.? or_else 0),
		item_gap        = s.item_gap.? or_else th.space[.lg],
		item_radius     = s.item_radius.? or_else th.radius.sm,
		icon_gap        = s.icon_gap.? or_else th.space[.sm],
		icon_size       = s.icon_size.? or_else ICON_SIZE,
		ink             = s.ink.? or_else th.color.on_surface,
		text            = text_look(th, .Body, s.text),
		shortcut_ink    = s.shortcut_ink.? or_else th.color.on_surface_muted,
		shortcut_text   = text_look(th, .Label, s.shortcut_text),
		selected_fill   = s.selected_fill.? or_else th.color.primary_container,
		selected_ink    = s.selected_ink.? or_else th.color.on_primary_container,
		open_fill       = s.open_fill.? or_else th.color.surface_variant,
		submenu_gap     = pad[1] + 2,
		submenu_nudge   = {0, -pad[0]},
	}
}

// ---------------------------------------------------------------- menu bar

// Menu_Bar_Style: the menu_bar strip and its titles. Its dropdowns are menus (Menu_Style).
Menu_Bar_Style :: struct {
	fill:         Maybe(Color),
	padding:      Maybe([4]f32),
	gap:          Maybe(f32),     // between titles
	item_padding: Maybe([4]f32),  // a title's
	item_radius:  Maybe(f32),
	ink:          Maybe(Color),
	open_fill:    Maybe(Color),   // the title whose menu is open
	open_ink:     Maybe(Color),
	text:         Text_Override,
}

Menu_Bar_Look :: struct {
	fill:         Color,
	padding:      [4]f32,
	gap:          f32,
	item_padding: [4]f32,
	item_radius:  f32,
	ink:          Color,
	open_fill:    Color,
	open_ink:     Color,
	text:         Text_Look,
}

menu_bar_look :: proc(th: ^Theme) -> Menu_Bar_Look {
	s := &th.menu_bar
	item_pad := s.item_padding.? or_else [4]f32{th.space[.xs], th.space[.md], th.space[.xs], th.space[.md]}
	return Menu_Bar_Look{
		fill         = s.fill.? or_else th.color.surface_variant,
		padding      = s.padding.? or_else [4]f32{th.space[.xxs], th.space[.xs], th.space[.xxs], th.space[.xs]},
		gap          = s.gap.? or_else th.space[.xxs],
		item_padding = dense_pad4(th, item_pad),
		item_radius  = s.item_radius.? or_else th.radius.sm,
		ink          = s.ink.? or_else th.color.on_surface,
		open_fill    = s.open_fill.? or_else th.color.primary_container,
		open_ink     = s.open_ink.? or_else th.color.on_primary_container,
		text         = text_look(th, .Label, s.text),
	}
}

// ---------------------------------------------------------------- chips

// Chip_Style: a chip, the pill for a tag or a filter.
Chip_Style :: struct {
	padding:         Maybe([4]f32),
	gap:             Maybe(f32),     // between the icon, the label and the ×
	radius:          Maybe(f32),
	fill:            Maybe(Color),
	ink:             Maybe(Color),
	border:          Maybe(Color),
	border_width:    Maybe(f32),     // unselected only; a selected chip's fill is its edge
	selected_fill:   Maybe(Color),
	selected_ink:    Maybe(Color),
	icon_size:       Maybe(f32),     // the leading icon or check
	close_size:      Maybe(f32),     // the ×'s round target
	close_icon_size: Maybe(f32),
	text:            Text_Override,
}

Chip_Look :: struct {
	padding:         [4]f32,
	gap:             f32,
	radius:          f32,
	fill:            Color,
	ink:             Color,
	border:          Color,
	border_width:    f32,
	selected_fill:   Color,
	selected_ink:    Color,
	icon_size:       f32,
	close_size:      f32,
	close_radius:    f32, // round on purpose: half the target
	close_icon_size: f32,
	text:            Text_Look,
}

chip_look :: proc(th: ^Theme) -> Chip_Look {
	s := &th.chip
	pad := s.padding.? or_else [4]f32{th.space[.xs], th.space[.sm], th.space[.xs], th.space[.sm]}
	close := s.close_size.? or_else 18
	return Chip_Look{
		padding         = dense_pad4(th, pad),
		gap             = s.gap.? or_else th.space[.xs],
		radius          = s.radius.? or_else th.radius.full,
		fill            = s.fill.? or_else th.color.surface_high,
		ink             = s.ink.? or_else th.color.on_surface,
		border          = s.border.? or_else th.color.outline_variant,
		border_width    = s.border_width.? or_else 1,
		selected_fill   = s.selected_fill.? or_else th.color.primary_container,
		selected_ink    = s.selected_ink.? or_else th.color.on_primary_container,
		icon_size       = s.icon_size.? or_else ICON_SIZE - 2,
		close_size      = close,
		close_radius    = close / 2,
		close_icon_size = s.close_icon_size.? or_else 12,
		text            = text_look(th, .Label, s.text),
	}
}

// Menu_Chip_Style: a menu_chip, the pill that shows a choice and opens a menu.
Menu_Chip_Style :: struct {
	padding:   Maybe([4]f32),
	gap:       Maybe(f32),    // between the label and the chevron
	radius:    Maybe(f32),
	fill:      Maybe(Color),
	ink:       Maybe(Color),  // label and chevron
	icon_size: Maybe(f32),    // the chevron
	text:      Text_Override,
}

Menu_Chip_Look :: struct {
	padding:   [4]f32,
	gap:       f32,
	radius:    f32,
	fill:      Color,
	ink:       Color,
	icon_size: f32,
	text:      Text_Look,
}

menu_chip_look :: proc(th: ^Theme) -> Menu_Chip_Look {
	s := &th.menu_chip
	return Menu_Chip_Look{
		padding   = dense_pad4(th, s.padding.? or_else MENU_CHIP_PADDING),
		gap       = s.gap.? or_else th.space[.xs],
		radius    = s.radius.? or_else th.radius.full,
		fill      = s.fill.? or_else th.color.fill_strong,
		ink       = s.ink.? or_else th.color.on_surface,
		icon_size = s.icon_size.? or_else MENU_CHIP_CHEVRON,
		text      = text_look(th, .Label, s.text, MENU_CHIP_TEXT, Font_Weight.Medium),
	}
}

// ---------------------------------------------------------------- separator

// Separator_Style: the hairline `separator` draws between groups, in a menu, column or row.
Separator_Style :: struct {
	thickness: Maybe(f32),
	fill:      Maybe(Color),
}

Separator_Look :: struct {
	thickness: f32,
	fill:      Color,
}

separator_look :: proc(th: ^Theme) -> Separator_Look {
	s := &th.separator
	return Separator_Look{
		thickness = s.thickness.? or_else 1,
		fill      = s.fill.? or_else th.color.outline_variant,
	}
}

// ---------------------------------------------------------------- surfaces

// ---- Shared by every group: define once in theme_style.odin ----


// elevation_shadow is the theme's drop shadow for an elevation level.
elevation_shadow :: proc "contextless" (th: ^Theme, level: Elevation_Level) -> Shadow_Style {
	switch level {
	case .None: return {}
	case .Low:  return th.elev.low
	case .Mid:  return th.elev.mid
	case .High: return th.elev.high
	}
	return {}
}

// ---- Theme fields (added to Theme) ----
//	card:    Card_Style,
//	dialog:  Dialog_Style,
//	popover: Popover_Style,
//	tooltip: Tooltip_Style,
//	toast:   Toast_Style,

// ---- Card ----

// Card_Style is `card`'s raised surface. A call's own gap, padding and
// elevation still win over it.
Card_Style :: struct {
	fill:         Maybe(Color),           // without glass; glass takes its colour from the material
	border:       Maybe(Color),
	border_width: Maybe(f32),             // without glass; glass draws its own edge
	radius:       Maybe(f32),
	padding:      Maybe([4]f32),          // top, end, bottom, start
	gap:          Maybe(f32),             // between children
	elevation:    Maybe(Elevation_Level), // which of Theme.elev it casts
}

Card_Look :: struct {
	fill, border:         Color,
	border_width, radius: f32,
	padding:              [4]f32,
	gap:                  f32,
	elevation:            Elevation_Level, // a level, not a shadow: the call may pick another
}

card_look :: proc "contextless" (th: ^Theme) -> Card_Look {
	s := th.card
	return {
		fill         = s.fill.? or_else th.color.surface,
		border       = s.border.? or_else th.color.outline_variant,
		border_width = s.border_width.? or_else 1,
		radius       = s.radius.? or_else th.radius.lg,
		padding      = s.padding.? or_else pad4(th.space[.lg]),
		gap          = s.gap.? or_else th.space[.md],
		elevation    = s.elevation.? or_else Elevation_Level.Mid,
	}
}

// ---- Dialog ----

DIALOG_WIDTH :: f32(420) // a dialog's width when neither the call nor the theme gives one

// Dialog_Style is the modal card `dialog` opens and the scrim behind it.
Dialog_Style :: struct {
	scrim:        Maybe(Color),           // over the window behind the card
	fill:         Maybe(Color),           // without the sheet's glass
	border:       Maybe(Color),
	border_width: Maybe(f32),             // kept over glass too
	radius:       Maybe(f32),
	padding:      Maybe([4]f32),
	gap:          Maybe(f32),
	elevation:    Maybe(Elevation_Level),
	width:        Maybe(f32),             // when the call passes none
	title_text:   Text_Override,   // from the Title step
}

Dialog_Look :: struct {
	scrim, fill, border:  Color,
	border_width, radius: f32,
	padding:              [4]f32,
	gap, width:           f32,
	shadow:               Shadow_Style,
	title_text:           Text_Look,
}

dialog_look :: proc "contextless" (th: ^Theme) -> Dialog_Look {
	s := th.dialog
	return {
		scrim        = s.scrim.? or_else th.color.scrim,
		fill         = s.fill.? or_else th.color.surface_high,
		border       = s.border.? or_else th.color.outline_variant,
		border_width = s.border_width.? or_else 1,
		radius       = s.radius.? or_else th.radius.xl,
		padding      = s.padding.? or_else pad4(th.space[.xl]),
		gap          = s.gap.? or_else th.space[.md],
		width        = s.width.? or_else DIALOG_WIDTH,
		shadow       = elevation_shadow(th, s.elevation.? or_else Elevation_Level.High),
		title_text   = text_look(th, .Title, s.title_text),
	}
}

// ---- Popover ----

// Popover_Style is every popup's surface: popover, menu, submenu, a menu
// bar's menus, a select's list, the date, time and colour pickers. The rows
// inside are the menu's style.
Popover_Style :: struct {
	fill:         Maybe(Color),           // without glass
	border:       Maybe(Color),
	border_width: Maybe(f32),             // without glass; glass draws its own edge
	radius:       Maybe(f32),
	padding:      Maybe([4]f32),
	gap:          Maybe(f32),             // between items
	elevation:    Maybe(Elevation_Level), // glass with a shadow of its own casts that instead
	anchor_gap:   Maybe(f32),             // from the control it opens from
}

Popover_Look :: struct {
	fill, border:         Color,
	border_width, radius: f32,
	padding:              [4]f32,
	gap, anchor_gap:      f32,
	shadow:               Shadow_Style,
}

popover_look :: proc "contextless" (th: ^Theme) -> Popover_Look {
	s := th.popover
	return {
		fill         = s.fill.? or_else th.color.surface_high,
		border       = s.border.? or_else th.color.outline_variant,
		border_width = s.border_width.? or_else 1,
		radius       = s.radius.? or_else th.radius.lg,
		padding      = s.padding.? or_else pad4(th.space[.sm]),
		gap          = s.gap.? or_else th.space[.xxs],
		anchor_gap   = s.anchor_gap.? or_else POPOVER_GAP,
		shadow       = elevation_shadow(th, s.elevation.? or_else Elevation_Level.Mid),
	}
}

// ---- Tooltip ----

TOOLTIP_MAX_WIDTH :: f32(320) // a longer tip wraps

// Tooltip_Style is the tip shown over a control.
Tooltip_Style :: struct {
	fill:         Maybe(Color),           // opaque: the tip is read over anything
	ink:          Maybe(Color),           // unset with fill set: on_surface moved to 4.5:1 on it
	border:       Maybe(Color),
	border_width: Maybe(f32),
	radius:       Maybe(f32),
	padding:      Maybe([4]f32),
	max_width:    Maybe(f32),
	elevation:    Maybe(Elevation_Level),
	anchor_gap:   Maybe(f32),
	text:         Text_Override,   // from the Label step
}

Tooltip_Look :: struct {
	fill, ink, border:     Color,
	border_width, radius:  f32,
	padding:               [4]f32,
	max_width, anchor_gap: f32,
	shadow:                Shadow_Style,
	text:                  Text_Look,
}

tooltip_look :: proc "contextless" (th: ^Theme) -> Tooltip_Look {
	s := th.tooltip
	fill := s.fill.? or_else th.color.surface_high
	return {
		fill         = fill,
		ink          = s.ink.? or_else (ensure_contrast(th.color.on_surface, fill, 4.5) if s.fill != nil else th.color.on_surface),
		border       = s.border.? or_else th.color.outline_variant,
		border_width = s.border_width.? or_else 1,
		radius       = s.radius.? or_else th.radius.sm,
		padding      = s.padding.? or_else [4]f32{th.space[.xs], th.space[.sm], th.space[.xs], th.space[.sm]},
		max_width    = s.max_width.? or_else TOOLTIP_MAX_WIDTH,
		anchor_gap   = s.anchor_gap.? or_else POPOVER_GAP,
		shadow       = elevation_shadow(th, s.elevation.? or_else Elevation_Level.Mid),
		text         = text_look(th, .Label, s.text),
	}
}

// ---- Toast ----

TOAST_MAX_WIDTH  :: f32(440)
TOAST_CLOSE_SIZE :: f32(24) // the × button, square, drawn round
TOAST_CLOSE_ICON :: f32(14)

// Toast_Style is the message card at the window's edge. fill and ink are
// the Neutral tone's; the other tones keep tone_colors, as badges do.
Toast_Style :: struct {
	fill:            Maybe(Color),
	ink:             Maybe(Color),           // text and ×; unset with fill set: on_surface moved to 4.5:1 on it
	border:          Maybe(Color),
	border_width:    Maybe(f32),
	radius:          Maybe(f32),
	padding:         Maybe([4]f32),
	gap:             Maybe(f32),
	max_width:       Maybe(f32),
	elevation:       Maybe(Elevation_Level),
	margin:          Maybe(f32),             // from the window's edge
	stack_gap:       Maybe(f32),             // between stacked toasts
	close_size:      Maybe(f32),
	close_icon_size: Maybe(f32),
	text:            Text_Override,   // from the Body step
}

Toast_Look :: struct {
	fill, ink, border:           Color,
	border_width, radius:        f32,
	padding:                     [4]f32,
	gap, max_width:              f32,
	margin, stack_gap:           f32,
	close_size, close_icon_size: f32,
	shadow:                      Shadow_Style,
	text:                        Text_Look,
}

toast_look :: proc "contextless" (th: ^Theme) -> Toast_Look {
	s := th.toast
	fill := s.fill.? or_else th.color.surface_high
	return {
		fill            = fill,
		ink             = s.ink.? or_else (ensure_contrast(th.color.on_surface, fill, 4.5) if s.fill != nil else th.color.on_surface),
		border          = s.border.? or_else th.color.outline_variant,
		border_width    = s.border_width.? or_else 1,
		radius          = s.radius.? or_else th.radius.md,
		padding         = s.padding.? or_else [4]f32{th.space[.sm], th.space[.sm], th.space[.sm], th.space[.md]},
		gap             = s.gap.? or_else th.space[.md],
		max_width       = s.max_width.? or_else TOAST_MAX_WIDTH,
		margin          = s.margin.? or_else OVERLAY_EDGE_MARGIN,
		stack_gap       = s.stack_gap.? or_else OVERLAY_STACK_GAP,
		close_size      = s.close_size.? or_else TOAST_CLOSE_SIZE,
		close_icon_size = s.close_icon_size.? or_else TOAST_CLOSE_ICON,
		shadow          = elevation_shadow(th, s.elevation.? or_else Elevation_Level.High),
		text            = text_look(th, .Body, s.text),
	}
}


// ---------------------------------------------------------------- chrome

SCROLLBAR_TRACK_ALPHA :: f32(0.06) // the track, over the ink it is drawn in
SCROLLBAR_THUMB_ALPHA :: f32(0.85) // the resting thumb, over the muted ink
SCROLLBAR_PILL        :: f32(1e6)  // a radius wider than any bar: drawn capped at half its width

FOCUS_RING_WIDTH    :: f32(2)
FOCUS_RING_GAP      :: f32(1) // clear space between the control's edge and the stroke, as CSS outline-offset

// Scrollbar_Style is the overlay scrollbar a scroll container draws. Every
// field nil follows the theme. `width` is across the bar on either axis.
// Colours are what the bar shows at full visibility; its fade multiplies
// their alpha. An editor given its own ink keeps drawing its bar in that ink.
Scrollbar_Style :: struct {
	width:       Maybe(f32),   // across the bar at rest
	hover_width: Maybe(f32),   // with the pointer on the bar or a drag holding it; `gutter` keeps this much clear
	margin:      Maybe(f32),   // between the bar and the container's edges
	min_thumb:   Maybe(f32),   // the shortest the thumb gets, however long the content
	radius:      Maybe(f32),   // track and thumb corners, capped at half the drawn width (nil: a pill)
	track:       Maybe(Color),
	thumb:       Maybe(Color),
	hover_thumb: Maybe(Color), // the thumb under the pointer or a drag
}

// Scrollbar_Look is a Scrollbar_Style resolved against the theme.
Scrollbar_Look :: struct {
	width, hover_width, margin, min_thumb, radius: f32,
	track, thumb, hover_thumb:                     Color,
	gutter: f32, // what `scroll(…, gutter = true)` keeps clear: the widest bar and a margin each side
	reach:  f32, // the widest bar's footprint from the edge; a grab zone thinner than this offers no grab
}

scrollbar_look :: proc(th: ^Theme) -> Scrollbar_Look {
	s := th.scrollbar
	wide := s.hover_width.? or_else SCROLLBAR_W_WIDE
	margin := s.margin.? or_else SCROLLBAR_MARGIN
	track, thumb, hover := scrollbar_colors(th.color.on_surface, th.color.on_surface_muted)
	return {
		width       = s.width.? or_else SCROLLBAR_W,
		hover_width = wide,
		margin      = margin,
		min_thumb   = s.min_thumb.? or_else SCROLLBAR_MIN_THUMB,
		radius      = s.radius.? or_else SCROLLBAR_PILL,
		track       = s.track.? or_else track,
		thumb       = s.thumb.? or_else thumb,
		hover_thumb = s.hover_thumb.? or_else hover,
		gutter      = wide + 2 * margin,
		reach       = wide + margin,
	}
}

// scrollbar_colors derives the bar's colours from an ink and its muted form:
// the theme's text, or an editor's own ink. The hover thumb is the ink itself.
@(private)
scrollbar_colors :: proc "contextless" (ink, muted: Color) -> (track, thumb, hover_thumb: Color) {
	track = ink
	track.a = SCROLLBAR_TRACK_ALPHA
	thumb = muted
	thumb.a = SCROLLBAR_THUMB_ALPHA
	return track, thumb, ink
}

// Split_Style is the divider between a split's two panes: a hairline, and a
// bar over it while the pointer is on it or dragging it.
Split_Style :: struct {
	width:           Maybe(f32),   // the hairline across; it takes this room in layout
	fill:            Maybe(Color), // the hairline
	indicator:       Maybe(Color), // the bar while hovered or dragged
	indicator_width: Maybe(f32),   // that bar across, centred on the hairline, round-ended
}

// Split_Look is a Split_Style resolved against the theme.
Split_Look :: struct {
	width, indicator_width: f32,
	fill, indicator:        Color,
}

split_look :: proc(th: ^Theme) -> Split_Look {
	s := th.split
	w := s.width.? or_else SPLIT_DIVIDER_W
	return {
		width           = w,
		fill            = s.fill.? or_else th.color.outline_variant,
		indicator       = s.indicator.? or_else th.color.primary,
		indicator_width = s.indicator_width.? or_else w + 2, // a pixel past the hairline each side
	}
}

// split_indicator_inset is how far the bar reaches past each side of the hairline.
@(private)
split_indicator_inset :: proc "contextless" (lk: Split_Look) -> f32 {
	return (lk.indicator_width - lk.width) / 2
}

// Focus_Ring_Style is the ring round the control the keyboard is on. It
// takes the control's shape: its radius is the control's plus the ring's
// outset (gap + width).
Focus_Ring_Style :: struct {
	width: Maybe(f32),   // the stroke
	gap:   Maybe(f32),   // clear space between the control's edge and the stroke; negative overlaps the control
	color: Maybe(Color),
}

// Focus_Ring_Look is a Focus_Ring_Style resolved against the theme.
Focus_Ring_Look :: struct {
	width, gap: f32,
	color:      Color,
	outset:     f32, // the ring's outer edge from the control's: gap + width
	overhang:   f32, // what it reaches outside the node with anti-aliasing; repaint bounds and clips reserve it
}

focus_ring_look :: proc(th: ^Theme) -> Focus_Ring_Look {
	s := th.focus_ring
	w := s.width.? or_else FOCUS_RING_WIDTH
	gap := s.gap.? or_else FOCUS_RING_GAP
	return {
		width    = w,
		gap      = gap,
		color    = s.color.? or_else th.color.focus_ring,
		outset   = gap + w,
		overhang = max(gap + w, 0) + 1,
	}
}
