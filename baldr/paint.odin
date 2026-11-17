package baldr

import "core:math"

// Paint: each Layer node owns a cached draw list. A frame re-emits only the
// layers that contain a paint-dirty node; clean layers resubmit their cache.
// Damage is the union of the old and new rects of everything that changed.

// Style is the resolved visual of a node (theme tokens are resolved into it
// by the widget layer).
Style :: struct {
	bg, fg:   Color,
	bg2:      Color,        // if alpha > 0: bottom colour of a vertical gradient (bg is the top)
	radius:   f32,
	square:   Corners, // the corners `radius` leaves square (a bar's at the screen edge; square_corners)
	border_w: f32,
	border:   Color,
	opacity:  f32,
	shadow:   Shadow_Style,
	material: Material, // frosted glass; zero = none
	glow:     Glow,     // a halo behind this node's own text or icon, whatever is behind it (icon_view's `label_over`); zero = none
	enter, exit: Transition, // played when the node appears / is removed (see transition())
}

// Transition: how a node appears or leaves. Zero = none (instant).
Transition_Kind :: enum u8 {
	None,
	Fade,
	Fade_Up,   // fade + slide up into place (from +12 px)
	Fade_Down, // fade + slide down into place (from −12 px)
	Fade_Scale, // fade + grow from TRANSITION_SCALE out of the point nearest its anchor: a menu that pops out of the button that opened it
	Slide_Start, // a slide of its whole width from (or out to) the start, shown whole through its container's clip: a page going back comes in this way
	Slide_End,   // …from (or out to) the end: a page going deeper comes in this way (pages)
}
Transition :: struct {
	kind:     Transition_Kind,
	duration: f32, // ms; 0 = theme motion.base
	easing:   Easing,
	whole:    bool, // its backing (fill, border, shadow, glass) shows whole throughout and only what is on it fades: an overlay over controls never shows them through itself
}

TRANSITION_SLIDE :: f32(12)
// How small a Fade_Scale starts. 4% reads as a pop rather than a zoom:
// enough to arrive from its anchor, small enough that the text inside,
// which is not re-rasterised at intermediate sizes (`scaled`), never looks
// the wrong size.
TRANSITION_SCALE :: f32(0.96)

// Material: frosted glass behind a surface. `tint` is mixed over the blurred
// scene by its alpha — and is also the OPAQUE colour used when the theme's
// glass is Solid (OS "reduce transparency"), so text on it must be readable
// either way (over the app's own content the lint requires tint alpha ≥
// 0.55; glass_in_app). Zero = none.
Material :: struct {
	tint:       Color,
	blur:       f32, // px; > 0 enables
	saturation: f32, // 1 = unchanged
	noise:      f32, // grain: fraction of an sRGB step of dither (0.012 ≈ half a step; hides banding without reading as static)
	highlight:  Color, // a bright 1 px line along the top edge, inside the corners (zero: none)
	edge:       Color, // a 1 px line just inside its outline, under the highlight (zero: none)
	shadow:     Shadow_Style, // the drop shadow a card of it casts (zero: the node's own)
}

has_material :: proc "contextless" (m: Material) -> bool { return m.blur > 0 }

// Shadow_Style: a soft drop shadow (elevation), as CSS box-shadow draws it:
// `blur` is its blur radius, a Gaussian of blur / 2 reaching 1.5 × blur past
// the offset shape. Zero = none.
Shadow_Style :: struct {
	offset: [2]f32,
	blur:   f32,
	color:  Color,
}

has_shadow :: proc "contextless" (s: Shadow_Style) -> bool { return s.blur > 0 && s.color.a > 0 }

// shadow_reach is how far past its shape a shadow of blur radius `blur` draws:
// three sigmas of its Gaussian, and a pixel.
shadow_reach :: proc "contextless" (blur: f32) -> f32 { return blur * 1.5 + 1 }

// How far a focus ring and a drop ring reach outside a node, logical px.
FOCUS_RING_OVERHANG :: FOCUS_RING_GAP + FOCUS_RING_WIDTH + 1 // the default ring's: outside the node, plus a pixel of anti-aliasing
DROP_RING_OVERHANG :: f32(3) // a drop ring sits 2 px outside, 2 px wide; an insertion line 2.5

// paint_bounds is the node's rect grown by whatever it draws outside it
// (rings, shadow, glide, overhang, glow): what a repaint dirties. `ring` is
// the focus ring's overhang in the theme it paints with.
paint_bounds :: proc "contextless" (d: ^Node_Data, ring: f32 = FOCUS_RING_OVERHANG) -> Rect {
	r := d.abs
	if .Focusable in d.flags {
		// the focus ring (and its fade-out after focus leaves) is drawn outside the rect
		g := ring
		r = rect_union(r, Rect{d.abs.x - g, d.abs.y - g, d.abs.w + 2 * g, d.abs.h + 2 * g})
	}
	if .Drop_Target in d.flags {
		// a drop's ring and insertion line are drawn outside the rect and
		// come and go without the node changing, so their room is reserved
		// too, or removing the ring would leave its pixels on screen
		g := DROP_RING_OVERHANG
		r = rect_union(r, Rect{d.abs.x - g, d.abs.y - g, d.abs.w + 2 * g, d.abs.h + 2 * g})
	}
	if has_shadow(d.style.shadow) {
		sh := d.style.shadow
		g := shadow_reach(sh.blur)
		r = rect_union(r, Rect{r.x + sh.offset.x - g, r.y + sh.offset.y - g, r.w + 2 * g, r.h + 2 * g})
	}
	if d.move_from != {} { // mid-glide: it is drawn somewhere between its old and new place
		r = rect_union(r, Rect{d.abs.x + d.move_from.x, d.abs.y + d.move_from.y, d.abs.w, d.abs.h})
	}
	if k, ok := d.kind.(Custom_Kind); ok && k.overhang > 0 {
		// a self-painting node may draw outside its rect (a slider's thumb ring)
		r = rect_union(r, Rect{d.abs.x - k.overhang, d.abs.y - k.overhang, d.abs.w + 2 * k.overhang, d.abs.h + 2 * k.overhang})
	}
	// Squeezed into a row shorter than it draws, a text keeps its full lines
	// and an icon its square, below the box: a repaint clears them too.
	if tk, ok := d.kind.(Text_Kind); ok && tk.drawn_h > d.abs.h {
		r = rect_union(r, Rect{d.abs.x, d.abs.y + tk.inset_y, d.abs.w, tk.drawn_h})
	}
	if k, ok := d.kind.(Custom_Kind); ok && k.paint == paint_icon && d.abs.w > d.abs.h {
		r = rect_union(r, Rect{d.abs.x, d.abs.y, d.abs.w, d.abs.w})
	}
	if .Glows in d.flags { // text or icons on Clear glass: the glow reaches past them
		g := GLOW_OVERHANG
		r = rect_union(r, Rect{d.abs.x - g, d.abs.y - g, d.abs.w + 2 * g, d.abs.h + 2 * g})
	}
	return r
}

Draw_Cmd :: union {
	Draw_Rect,
	Draw_Shadow,
	Draw_Backdrop,
	Draw_Text,
	Draw_Icon,
	Draw_Wave,
	Draw_Line,
	Draw_Image,
	Draw_Canvas,
	Draw_Theme_Icon,
	Draw_Clip_Push,
	Draw_Clip_Pop,
	Draw_Glow_Push,
	Draw_Glow_Pop,
	Draw_Layer,
	Draw_Cells,
	Draw_Typeset,
}
Draw_Rect      :: struct { rect: Rect, color: Color, color2: Color, radius, border_w: f32, border: Color, horizontal: bool, square: Corners } // color2 set (even transparent): gradient to the bottom (or right when horizontal)
Draw_Shadow    :: struct { rect: Rect, radius, blur: f32, color: Color, square: Corners, hole: Rect } // `hole`: left clear, the see-through card over it (zero: none)
Draw_Backdrop  :: struct { rect: Rect, radius: f32, material: Material, square: Corners, fade: f32 } // frosted glass: blur what is behind, tint, then draw; faded out by `fade` (0: shown)
Draw_Text      :: struct { pos: [2]f32, str: string, size: f32, color: Color, wrap_w: f32, weight: Font_Weight, mono: bool, italic: bool, no_ligatures: bool, tabular: bool, tab: u8, align: Text_Align, box_w: f32, family: Family_Id } // str aliases node memory; valid until that node's text changes; wrap_w 0 = unwrapped; lines align within box_w; mono = the code face, tab = its cells per tab stop (0 = 4)
Draw_Icon      :: struct { pos: [2]f32, icon: Icon, size: f32, color: Color } // a vendored icon, rasterised into the atlas on first use
Draw_Wave      :: struct { pos: [2]f32, width: f32, color: Color } // a squiggle: WAVE_H tall from pos, tiled along width (spell-check underlines)
Draw_Line      :: struct { a, b: [2]f32, width: f32, color: Color, flat: bool, snap: bool } // a straight segment with round ends, so a polyline joins itself; `flat` cuts the ends square (a chart's series, a grid rule at an angle); `snap` puts a horizontal or vertical one on whole device pixels (a guide, a pixel grid: see render.odin)
Draw_Image     :: struct { rect: Rect, img: ^Image, radius: f32, color: Color, fit: Image_Fit, id, version: u64, size: [2]int, square: Corners, source: Rect, pixels: Pixels, pixel_grid: bool } // an app-owned picture, uploaded on first draw; color tints, alpha fades; source: the part of it shown, in its pixels ({}: all); pixels: how it is sampled where magnified
Draw_Canvas    :: struct { rect: Rect, page: u32, size: [2]int, radius: f32, square: Corners, color: Color, fit: Image_Fit, source: Rect, pixels: Pixels, pixel_grid: bool } // a canvas's texture (canvas.odin); color tints, alpha fades
Draw_Theme_Icon :: struct { rect: Rect, name, dir: string, color: Color, fallback: Icon } // an icon theme's icon (name and dir alias the node's), drawn once loaded; color tints one the desktop may recolour, its alpha fades any; fallback: the Lucide icon drawn when nothing provides it
Draw_Typeset   :: struct { pos: [2]f32, ts: ^Typeset, first, count: int, color: Color, scale: f32 } // lines [first, first+count) of a Typeset the app owns and keeps alive, its first line's top-left at `pos`; a run whose `ink` has no alpha is drawn in `color`; `scale` (0 or 1: as laid out) multiplies the laid-out geometry, since a Typeset's glyphs are placed and cannot be moved after the fact
Draw_Clip_Push :: struct { rect: Rect }
Draw_Clip_Pop  :: struct {}
Draw_Glow_Push :: struct { glow: Glow } // the text and icons that follow, until the matching pop, get this glow behind them (zero: none); text on Clear glass
Draw_Glow_Pop  :: struct {}
Draw_Layer     :: struct { node: Node, opacity: f32, shift: [2]f32, at_rest: bool } // nested layer in z-order; draw_list inlines it at the opacity, and moved by the shift, of what it sits in (its own Fade_Scale is read at flatten time, see layer_grow); `at_rest`: a copy drawn elsewhere, without the glide or slide the layer is part-way through

Layer :: struct {
	cmds:   [dynamic]Draw_Cmd,
	bounds: Rect,
}

// disabled_within says whether `n` or a node it sits in is disabled: its
// text, icons and pictures then draw dimmed, so every control with
// `disabled` reads as unavailable the same way.
@(private)
disabled_within :: proc(t: ^Tree, n: Node) -> bool {
	for cur := n; cur != NODE_NONE; {
		d := node_get(t, cur)
		if d == nil do return false
		if .Disabled in d.flags do return true
		cur = d.parent
	}
	return false
}

// paint rebuilds every dirty layer's draw list. Call after layout.
paint :: proc(t: ^Tree) {
	for n, &l in t.layers {
		d := node_get(t, n)
		if d == nil || .Layer_Dirty not_in d.flags do continue
		clear(&l.cmds)
		l.bounds = {}
		saved: Maybe(Theme)
		owner := overlay_child_of(t, n) if t.popups_on || t.in_app_theme_ok else NODE_NONE
		popup := t.popups_on && owner != NODE_NONE && popup_candidate(t, owner)
		if t.glass.popups && popup { // a glass popup paints with the theme of its own backdrop (glass.odin)
			if th, ok := popup_theme(t, owner); ok {
				saved = t.theme
				t.theme = th
			}
		} else if t.in_app_theme_ok && owner != NODE_NONE {
			// Glass over the app's own content paints in the worst-case
			// theme it was built with, including the layers inside it (a
			// menu's scroll viewport), which are painted here, not under
			// their card.
			if od := node_get(t, owner); od != nil && .Glass_In_App in od.flags {
				saved = t.theme
				t.theme = t.in_app_theme
			}
		}
		t.damage_off = popup // a popup's surface presents whole: what changes in it is no other surface's damage
		emit_node(t, n, &l, true, Rect{-UNBOUNDED / 2, -UNBOUNDED / 2, UNBOUNDED, UNBOUNDED})
		t.damage_off = false
		if th, ok := saved.?; ok do t.theme = th
		d.flags -= {.Layer_Dirty}
		t.stats.layers_rebuilt += 1
	}
}

// frame is layout + paint.
frame :: proc(t: ^Tree, viewport: [2]f32) {
	layout(t, viewport)
	// Between the two: a node that picks its ink from what is measured
	// behind it needs its rect first, and its ink before anything is drawn.
	legible_pass(t)
	paint(t)
}

// emit_node appends a node and its subtree to layer `l`. `clip` is the
// enclosing clip in absolute px: nodes entirely outside it are culled (their
// dirty flag cleared) and damage is limited to it. `opacity` and `shift` are
// the inherited transition state (fade and slide are paint-only: layout is
// never disturbed by a transition). `on_glass` says whether the node sits on
// glass, for the glow behind text on Clear.
@(private)
emit_node :: proc(t: ^Tree, n: Node, l: ^Layer, is_layer_root: bool, clip: Rect, opacity: f32 = 1, shift: [2]f32 = {}, on_glass := false) {
	d := node_get(t, n)
	if d == nil do return
	if .Hidden in d.flags {
		d.flags -= {.Dirty_Paint}
		return
	}
	// This node is the glass on a surface adapted only where it is marked:
	// it and its subtree paint with the theme solved for the wallpaper, and
	// the theme goes back at the end of its subtree. The theme swapped out
	// waits on t.theme_saves, never in this frame: emit_node recurses once a
	// level, and a Theme in each frame overflows a 1 MB thread stack.
	swapped := false
	// Glass over the app's own content comes first: the build gave the
	// popup that theme and `backdrop_area` stood aside for it.
	if t.in_app_theme_ok && .Glass_In_App in d.flags {
		append(&t.theme_saves, t.theme)
		t.theme = t.in_app_theme
		swapped = true
	} else if t.glass_theme_ok && .Backdrop_Area in d.flags && t.theme.color != t.glass_theme.color {
		append(&t.theme_saves, t.theme)
		t.theme = t.glass_theme
		swapped = true
	}
	// …and a theme_area: the subtree is built with its theme, but washes,
	// the focus ring and anything else resolved while painting read the
	// tree's theme, so it is swapped here too until the subtree ends.
	if .Theme_Area in d.flags {
		if th := &t.theme_areas[n]; th != nil {
			if !swapped do append(&t.theme_saves, t.theme)
			t.theme = th^
			swapped = true
		}
	}
	defer if swapped {
		last := len(t.theme_saves) - 1
		t.theme = t.theme_saves[last]
		resize(&t.theme_saves, last)
	}
	fr := focus_ring_look(&t.theme) // after the swaps: the ring is the subtree's theme's
	if !is_layer_root && .Layer in d.flags {
		b := paint_bounds(d, fr.overhang)
		b.x += shift.x
		b.y += shift.y
		op := opacity
		if n == t.drag_source do op *= DRAG_SOURCE_OPACITY // faded where it will land; the ghost's copy is not
		// The layer's own opacity and slide are applied inside it, when it
		// paints as a layer root: `Transition.whole` keeps a popover's glass
		// opaque while its items fade, which one opacity on the finished
		// layer could not express.
		//
		// Its Fade_Scale acts on the finished list (`scaled`) but is not
		// worked out here: this command is cached and `paint` walks layers
		// in map order, so a host painted before its child would store a
		// stale scale and nothing would re-dirty it. `layer_grow` reads it at
		// flatten time instead, after every layer has painted.
		if rect_intersects(b, clip) { // a scroll in a fading dialog fades with it, on a sliding page slides with it
			append(&l.cmds, Draw_Layer{node = n, opacity = op, shift = shift})
		}
		return
	}
	// Transition progress: 0 = fully out, 1 = at rest.
	op := opacity * (d.style.opacity if d.style.opacity > 0 else 1)
	if n == t.drag_source && !is_layer_root do op *= DRAG_SOURCE_OPACITY // the dragged item: a faded copy where it will land (as a layer, its parent fades it instead)
	sh := shift
	if d.move_from != {} do sh += d.move_from * anim_value(t, n, .Move)
	backing_op := op // what its own fill, border, shadow and glass take: its fade too, unless its transition keeps them whole
	if d.style.enter.kind != .None || d.style.exit.kind != .None || .Exiting in d.flags {
		k := transition_progress(t, n, d)
		tr := d.style.exit if .Exiting in d.flags else d.style.enter
		if tr.kind == .Slide_Start || tr.kind == .Slide_End {
			if k <= 0.002 do op = 0 // slid all the way out
		} else {
			op *= k
		}
		if !tr.whole do backing_op = op
		sh += transition_shift(d, k)
	}
	if r, reveals := t.reveals[n]; reveals { // shown while what it belongs to is hovered or focused (reveal.odin)
		k := anim_target(t, n, .Opacity, 1 if reveal_shown(t, n, r) else 0, t.theme.motion.fast)
		op *= k
		backing_op *= k
	}
	if op <= 0.002 {
		paint_left_behind(t, n, {}, clip)
		d.flags -= {.Dirty_Paint}
		return
	}
	// On Clear glass, text and icons get a glow: what this node holds is on
	// glass when it has live glass, off it when it has an opaque fill, and
	// as the node sits otherwise.
	glow := t.theme.material[t.theme.glass].glow
	glowing := glow.radius > 0 && glow.color.a > 0
	mine := glass_under(t, n) if is_layer_root && glowing else on_glass
	if decided_on, decided := glass_decides(t, d); decided do mine = decided_on
	if own := d.style.glow; own.radius > 0 && own.color.a > 0 { // its text is over something the app does not control
		glow, glowing, mine = own, true, true
	}
	_, is_text := d.kind.(Text_Kind)
	_, is_custom := d.kind.(Custom_Kind)
	glowed_before := .Glows in d.flags // what was on screen, before this frame's answer
	if glowing && mine && (is_text || is_custom) {
		d.flags += {.Glows}
	} else {
		d.flags -= {.Glows}
	}
	bounds := paint_bounds(d, fr.overhang)
	// A halo taken away must still be painted over: the flag is already
	// clear, so paint_bounds alone would leave the old halo's edges on
	// screen.
	if glowed_before && .Glows not_in d.flags {
		g := GLOW_OVERHANG
		bounds = rect_union(bounds, Rect{d.abs.x - g, d.abs.y - g, d.abs.w + 2 * g, d.abs.h + 2 * g})
	}
	bounds.x += sh.x
	bounds.y += sh.y
	if !rect_intersects(bounds, clip) {
		paint_left_behind(t, n, {}, clip)
		d.flags -= {.Dirty_Paint}
		return
	}
	if .Dirty_Paint in d.flags {
		if t.debug_damage && !t.damage_off do damage_log(t, n, "painted", rect_clip(bounds, clip))
		damage_add(t, rect_clip(bounds, clip))
		d.flags -= {.Dirty_Paint}
		// the drag ghost draws the dragged item's layer: what changes in it
		// changes on screen where the ghost is too, this same frame
		if t.drag_source != NODE_NONE {
			if sl, has := &t.layers[t.drag_source]; has && l == sl do drag_ghost_damage(t)
		}
	}
	paint_left_behind(t, n, rect_clip(bounds, clip), clip)
	t.stats.paint_nodes += 1
	l.bounds = rect_union(l.bounds, rect_clip(bounds, clip))
	// Everything below draws at `abs` moved by the slide and with alpha × op.
	saved_abs := d.abs
	d.abs.x += sh.x
	d.abs.y += sh.y
	defer d.abs = saved_abs
	t.paint_opacity = op
	own_from := len(l.cmds)

	bg := d.style.bg
	_, self_painted := d.kind.(Custom_Kind) // sliders and toggles draw their own hover/press feedback
	dim := .Disabled in d.flags && d.access.role in INTERACTIVE_ROLES && !self_painted // fill, gradient, border and shadow all dim
	if d.access.role in INTERACTIVE_ROLES && !self_painted && .Quiet not_in d.flags {
		// State layers: mix `on_surface` over the control by the theme's
		// strength, eased over motion.fast; transparent controls get a
		// translucent overlay instead. A quiet control draws none of it: it
		// answers the pointer some other way (a dock's icons grow).
		th := &t.theme
		live := .Disabled not_in d.flags // a disabled control shows no hover or press
		pressed := live && .Pressed in d.flags
		hover_t := anim_target(t, n, .Hover, 1 if (live && .Hovered in d.flags && !pressed) else 0, th.motion.fast)
		press_t := anim_target(t, n, .Press, 1 if pressed else 0, th.motion.fast * 0.6)
		amount := hover_t * th.state.hover + press_t * th.state.press
		if amount > 0 {
			if bg.a > 0 {
				bg = mix(bg, th.color.on_surface, amount)
			} else {
				bg = th.color.on_surface
				bg.a = amount
			}
		}
	}
	glass_card := has_material(d.style.material) && t.theme.glass != .Solid
	if has_shadow(d.style.shadow) && (bg.a > 0 || d.style.bg2.a > 0) && !glass_card do append(&l.cmds, node_shadow(t, d, backing_op, dim, {}))
	if has_material(d.style.material) {
		if glass_card {
			// glass fades as glass with its node's transition: tint and rim at its backing's opacity, never an opaque stand-in
			append(&l.cmds, Draw_Backdrop{rect = d.abs, radius = d.style.radius, material = d.style.material, square = d.style.square, fade = 1 - backing_op})
		} else {
			// Solid glass (reduced transparency, high contrast): the same colour,
			// opaque × its backing's opacity. Same contrast for the text on top, no blur cost.
			opaque := d.style.material.tint
			opaque.a = backing_op
			append(&l.cmds, Draw_Rect{rect = d.abs, color = opaque, radius = d.style.radius, square = d.style.square})
		}
		// see-through, a glass card's shadow leaves the card clear, and comes after the glass so its own blur doesn't take it in
		if glass_card && has_shadow(d.style.shadow) do append(&l.cmds, node_shadow(t, d, backing_op, dim, d.abs))
	}
	if bg.a > 0 || d.style.bg2.a > 0 || (d.style.border_w > 0 && d.style.border.a > 0) {
		bg2 := d.style.bg2
		if bg2.a > 0 && bg != d.style.bg {
			// keep the gradient's second stop in step with the state layer
			bg2 = mix(bg2, bg, 0.5)
		}
		bg.a *= backing_op
		bg2.a *= backing_op
		border := d.style.border
		if .Invalid in d.access.states && d.style.border_w > 0 do border = t.theme.color.danger // set_invalid: a field framed by its style
		border.a *= backing_op
		if dim { // after the state layer's blend, so fill and gradient dim alike
			bg.a *= t.theme.state.disabled_alpha
			bg2.a *= t.theme.state.disabled_alpha
			border.a *= t.theme.state.disabled_alpha
		}
		append(&l.cmds, Draw_Rect{rect = d.abs, color = bg, color2 = bg2, radius = d.style.radius, border_w = d.style.border_w, border = border, square = d.style.square})
	}
	if len(t.button_marks) > 0 do paint_button_mark(t, n, d, l, op, dim) // a button's running mark, over its fill, under its ring
	if .Focusable in d.flags && .Ring_Inside not_in d.flags {
		focus_t := anim_target(t, n, .Focus, 1 if (.Focused in d.flags && ring_shown(t)) else 0, t.theme.motion.fast)
		if focus_t > 0.01 {
			g := fr.outset
			ring := Rect{d.abs.x - g, d.abs.y - g, d.abs.w + 2 * g, d.abs.h + 2 * g}
			col := fr.color
			col.a *= focus_t * op
			append(&l.cmds, Draw_Rect{rect = ring, radius = d.style.radius + g, border_w = fr.width, border = col, square = d.style.square})
		}
	}
	if t.drag_over == n {
		// drop feedback: a ring for On, an insertion line for Before / After
		c := t.theme.color.primary
		c.a *= op
		sideways := drop_flows_sideways(t, n)
		switch t.drag_over_pos {
		case .On:
			append(&l.cmds, Draw_Rect{rect = {d.abs.x - 2, d.abs.y - 2, d.abs.w + 4, d.abs.h + 4}, radius = d.style.radius + 2, border_w = 2, border = c, square = d.style.square})
		case .Before:
			r := Rect{d.abs.x - 2.5, d.abs.y, 3, d.abs.h} if sideways else Rect{d.abs.x, d.abs.y - 2.5, d.abs.w, 3}
			append(&l.cmds, Draw_Rect{rect = r, radius = 1.5, color = c})
		case .After:
			r := Rect{d.abs.x + d.abs.w - 0.5, d.abs.y, 3, d.abs.h} if sideways else Rect{d.abs.x, d.abs.y + d.abs.h - 0.5, d.abs.w, 3}
			append(&l.cmds, Draw_Rect{rect = r, radius = 1.5, color = c})
		}
	}
	glow_pushed := glowing && (is_layer_root || mine != on_glass) // a layer's list says where it starts: it may be drawn on its own
	if glow_pushed do append(&l.cmds, Draw_Glow_Push{glow = glow if mine else {}})
	if tk, ok := d.kind.(Text_Kind); ok && len(tk.str) > 0 {
		fg := d.style.fg
		fg.a *= op
		if disabled_within(t, n) do fg.a *= t.theme.state.disabled_alpha // a disabled control's label, a menu item's shortcut
		shown := tk.display if len(tk.display) > 0 else tk.str
		// cut at the box's sides only: accents and descenders may still overhang
		lines_h := max(d.abs.h, tk.drawn_h)
		if tk.spills do append(&l.cmds, Draw_Clip_Push{rect = {d.abs.x, d.abs.y - lines_h, d.abs.w, lines_h * 3}})
		append(&l.cmds, Draw_Text{pos = {d.abs.x, d.abs.y + tk.inset_y}, str = shown, size = tk.size, color = fg, wrap_w = tk.wrap_w, weight = tk.weight, align = tk.align, box_w = d.abs.w, mono = tk.mono, family = tk.family, tabular = tk.tabular})
		if tk.spills do append(&l.cmds, Draw_Clip_Pop{})
	}
	if ck, ok := d.kind.(Custom_Kind); ok && ck.paint != nil do ck.paint(t, n, d, l)
	child_clip := clip
	if .Clips in d.flags {
		cut := d.abs
		if n in t.pages { // pages clip their slides, not the rings of the controls at their edges
			g := fr.overhang
			cut = {cut.x - g, cut.y - g, cut.w + 2 * g, cut.h + 2 * g}
		}
		append(&l.cmds, Draw_Clip_Push{cut})
		child_clip = rect_clip(clip, cut)
	}
	if _, ok := d.kind.(Text_Input_Kind); ok do paint_text_input(t, n, d, l) // text_input hook
	if t.debug_bounds do bounds_check(t, d, l.cmds[own_from:], bounds, clip)
	for c := d.first; c != NODE_NONE; c = node_get(t, c).next {
		emit_node(t, c, l, false, child_clip, op, sh, mine)
	}
	over_from := len(l.cmds)
	if len(t.button_badges) > 0 do paint_button_badge(t, n, d, l, op, dim, sh) // a button's badge, over its icon
	if len(t.button_progress) > 0 do paint_button_progress(t, n, d, l, op, dim, sh) // …and its progress, across the icon's bottom
	if ck, ok := d.kind.(Custom_Kind); ok && ck.paint_over != nil do ck.paint_over(t, n, d, l)
	if .Scroll_V in d.flags do emit_scrollbar(t, n, l)
	if .Scroll_H in d.flags {
		// A surface that scrolls both ways gets a bar along its bottom too.
		// A strip that only scrolls sideways (a tab bar, a chip row) gets
		// the fades instead, where a bar would cover its contents.
		if .Scroll_V in d.flags { emit_scrollbar(t, n, l, 0) } else { emit_scroll_fades(t, n, l) }
	}
	if t.debug_bounds do bounds_check(t, d, l.cmds[over_from:], bounds, child_clip)
	if .Clips in d.flags do append(&l.cmds, Draw_Clip_Pop{})
	if glow_pushed do append(&l.cmds, Draw_Glow_Pop{})
}

// node_shadow is a node's drop shadow at opacity `op`, leaving `hole` clear.
@(private)
node_shadow :: proc(t: ^Tree, d: ^Node_Data, op: f32, dim: bool, hole: Rect) -> Draw_Shadow {
	shd := d.style.shadow
	sc := shd.color
	sc.a *= op
	if dim do sc.a *= t.theme.state.disabled_alpha
	return Draw_Shadow{rect = {d.abs.x + shd.offset.x, d.abs.y + shd.offset.y, d.abs.w, d.abs.h}, radius = d.style.radius, blur = shd.blur, color = sc, square = d.style.square, hole = hole}
}

// paint_left_behind damages where a node that moves while it paints (a
// transition's slide, a layout move gliding) was drawn before, when it is now
// drawn elsewhere (`now`, clipped) or not at all (zero), so the strip it left
// is presented too. Only nodes with animation state move this way.
@(private)
paint_left_behind :: proc(t: ^Tree, n: Node, now: Rect, clip: Rect) {
	st, ok := &t.anims[n]
	if !ok do return
	if st.painted.w > 0 && st.painted != now {
		if t.debug_damage && !t.damage_off do damage_log(t, n, "left behind", st.painted)
		damage_add(t, st.painted)
	}
	st.painted = now
}

// transition_progress is the node's enter/exit progress (0 = out, 1 = in),
// driving the Enter anim prop: entering nodes tween 0 → 1 once, exiting
// nodes tween 1 → 0 and are destroyed by sweep_exited when they reach 0.
@(private)
transition_progress :: proc(t: ^Tree, n: Node, d: ^Node_Data) -> f32 {
	th := &t.theme
	st := anim_state(t, n)
	if .Exiting in d.flags {
		dur := d.style.exit.duration if d.style.exit.duration > 0 else th.motion.base
		// a node that never entered by a transition (a pages container's first page) was fully shown: it leaves from there, not from rest
		if .Enter not_in st.engaged do anim_restart(t, n, .Enter, 1, 0, dur, d.style.exit.easing)
		return anim_target(t, n, .Enter, 0, dur, d.style.exit.easing)
	}
	// an entrance plays from rest; a node with only an exit transition is shown at once (its first target)
	if d.style.enter.kind != .None do st.engaged += {.Enter}
	dur := d.style.enter.duration if d.style.enter.duration > 0 else th.motion.base
	return anim_target(t, n, .Enter, 1, dur, d.style.enter.easing)
}

@(private)
transition_shift :: proc "contextless" (d: ^Node_Data, k: f32) -> [2]f32 {
	tr := d.style.exit if .Exiting in d.flags else d.style.enter
	rem := 1 - k
	switch tr.kind {
	case .Fade_Up:    return {0, TRANSITION_SLIDE * rem}
	case .Fade_Down:  return {0, -TRANSITION_SLIDE * rem}
	case .Slide_Start: return {-d.abs.w * rem, 0}
	case .Slide_End:   return {d.abs.w * rem, 0}
	case .None, .Fade, .Fade_Scale: // Fade_Scale grows instead of sliding
	}
	return {}
}

// transition_scale is how big a Fade_Scale node is at progress `k`: it grows
// from TRANSITION_SCALE to 1 (and shrinks back on the way out). 1 for every
// other kind, which is what says "do not scale this".
@(private)
transition_scale :: proc "contextless" (d: ^Node_Data, k: f32) -> f32 {
	tr := d.style.exit if .Exiting in d.flags else d.style.enter
	if tr.kind != .Fade_Scale do return 1
	return TRANSITION_SCALE + (1 - TRANSITION_SCALE) * clamp(k, 0, 1)
}

// transition_origin is the point a Fade_Scale grows out of: for an overlay
// with an anchor, the point of its own rect nearest the anchor's centre, so
// a menu comes out of the control that opened it. Anything with no anchor
// grows from its own centre (a dialog's card).
@(private)
transition_origin :: proc(t: ^Tree, n: Node, d: ^Node_Data) -> [2]f32 {
	mid := [2]f32{d.abs.x + d.abs.w / 2, d.abs.y + d.abs.h / 2}
	rule, ruled := t.overlay_rules[n]
	if !ruled do return mid
	a := node_get(t, rule.anchor)
	if a == nil do return mid
	// the anchor's centre, clamped into this node's rect: on the edge that
	// faces it, at its position along that edge
	ac := [2]f32{a.abs.x + a.abs.w / 2, a.abs.y + a.abs.h / 2}
	return {clamp(ac.x, d.abs.x, d.abs.x + d.abs.w), clamp(ac.y, d.abs.y, d.abs.y + d.abs.h)}
}

// emit_scrollbar draws a scroll container's overlay scrollbar — the vertical
// one, or the one along its bottom with `axis = 0` — faded by recent
// activity. Drawn inside the container's clip, over content.
@(private)
emit_scrollbar :: proc(t: ^Tree, n: Node, l: ^Layer, axis := 1) {
	track, thumb, ok := scrollbar_geometry(t, n, axis)
	if !ok do return
	vis := scrollbar_visible(t, n)
	if vis <= 0.01 do return
	lk := scrollbar_look(&t.theme)
	track_c, thumb_c, hover_c := lk.track, lk.thumb, lk.hover_thumb
	// An editor given its own ink is a page the app coloured, so its
	// scrollbar takes that ink: the theme's grey thumb can vanish on it.
	if s, is_area := &t.areas[n]; is_area && s.ink.a > 0 {
		track_c, thumb_c, hover_c = scrollbar_colors(area_ink(t, s), area_ink_muted(t, s))
	}
	track_c.a *= vis // the look's alphas are at full visibility
	thumb_c.a *= vis
	if st, has := t.scrolls[n]; (has && st.thumb_drag && st.thumb_axis == axis) || (t.bar_hover == n && t.bar_hover_axis == axis) do thumb_c = hover_c
	round := min(lk.radius, (track.w if axis == 1 else track.h) / 2)
	append(&l.cmds, Draw_Rect{rect = track, color = track_c, radius = round})
	append(&l.cmds, Draw_Rect{rect = thumb, color = thumb_c, radius = round})
}

// emit_scroll_fades marks the clipped ends of a horizontally scrolling
// container with a short fade to its backdrop colour, so a clipped tab or
// chip reads as "more this way" rather than as a bug.
@(private)
emit_scroll_fades :: proc(t: ^Tree, n: Node, l: ^Layer) {
	d := node_get(t, n)
	if d == nil || .Scroll_H not_in d.flags do return
	st, has := t.scrolls[n]
	if !has || st.content.x <= st.viewport.x + 0.5 do return
	bg := backdrop_color(t, n)
	if bg.a <= 0 do return
	clear := bg
	clear.a = 0
	w := min(SCROLL_FADE_W, d.abs.w / 4)
	if st.offset.x > 0.5 {
		append(&l.cmds, Draw_Rect{rect = {d.abs.x, d.abs.y, w, d.abs.h}, color = bg, color2 = clear, horizontal = true})
	}
	if st.offset.x < st.content.x - st.viewport.x - 0.5 {
		append(&l.cmds, Draw_Rect{rect = {d.abs.x + d.abs.w - w, d.abs.y, w, d.abs.h}, color = clear, color2 = bg, horizontal = true})
	}
}

SCROLL_FADE_W :: f32(28)
WAVE_PERIOD   :: f32(6) // logical px per squiggle cycle
WAVE_H        :: f32(3) // squiggle height

// backdrop_color is the colour behind `n`: its own background, else the
// nearest ancestor's, else the theme background.
@(private)
backdrop_color :: proc(t: ^Tree, n: Node) -> Color {
	for cur := n; cur != NODE_NONE; cur = node_get(t, cur).parent {
		d := node_get(t, cur)
		if d == nil do break
		if d.style.bg.a > 0 do return d.style.bg
		if has_material(d.style.material) do return t.theme.color.surface_high
	}
	return t.theme.color.bg
}

rect_intersects :: proc "contextless" (a, b: Rect) -> bool {
	return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
}

rect_clip :: proc "contextless" (a, b: Rect) -> Rect {
	x0 := max(a.x, b.x)
	y0 := max(a.y, b.y)
	x1 := min(a.x + a.w, b.x + b.w)
	y1 := min(a.y + a.h, b.y + b.h)
	if x1 <= x0 || y1 <= y0 do return {}
	return {x0, y0, x1 - x0, y1 - y0}
}

// draw_list flattens every layer into one z-ordered command slice, in the
// frame's temp memory by default; the strings in it alias the nodes' own.
draw_list :: proc(t: ^Tree, allocator := context.temp_allocator) -> []Draw_Cmd {
	out := make([dynamic]Draw_Cmd, allocator)
	flatten_layer(t, t.root, &out)
	flatten_layer(t, t.overlay, &out, skip_popups = true) // popovers and dialogs paint over everything; popups on their own surfaces
	return out[:]
}

// layer_grow is a layer node's own Fade_Scale, as a scale and a translation.
// Read at flatten time, after every layer has painted, rather than stored on
// the cached Draw_Layer, whose value would depend on the order `paint`
// walked the layers. A popup on its own surface does not come through here
// and does not scale: it would have to resize its window every frame.
@(private)
layer_grow :: proc(t: ^Tree, n: Node) -> (k: f32, off: [2]f32) {
	d := node_get(t, n)
	if d == nil do return 1, {}
	tr := d.style.exit if .Exiting in d.flags else d.style.enter
	if tr.kind != .Fade_Scale do return 1, {}
	sc := transition_scale(d, anim_value(t, n, .Enter))
	if sc == 1 do return 1, {}
	o := transition_origin(t, n, d)
	return sc, {o.x * (1 - sc), o.y * (1 - sc)}
}

// layer_self_shift is how far a layer root draws itself from where it is
// laid out, by what it is part-way through: a glide to a new slot (move_from)
// and a transition's slide, as emit_node adds them. Read from the animation
// values, as layer_grow is, so flattening starts nothing.
@(private)
layer_self_shift :: proc(t: ^Tree, n: Node) -> (sh: [2]f32) {
	d := node_get(t, n)
	if d == nil do return
	if d.move_from != {} do sh += d.move_from * anim_value(t, n, .Move)
	sh += transition_shift(d, anim_value(t, n, .Enter))
	return
}

@(private)
flatten_layer :: proc(t: ^Tree, n: Node, out: ^[dynamic]Draw_Cmd, k: f32 = 1, skip_popups := false,
	shift: [2]f32 = {}, scale: f32 = 1, off: [2]f32 = {}) {
	l, ok := t.layers[n]
	if !ok do return
	for c in l.cmds {
		if dl, is_layer := c.(Draw_Layer); is_layer {
			if skip_popups && popup_candidate(t, dl.node) do continue
			// Its own scale, composed under this one: p × k2 + off2, then
			// × k1 + off1. Two scales-about-an-origin do not compose into a
			// third, which is why these are carried as scale-and-translate.
			k2, off2 := layer_grow(t, dl.node)
			sh := shift + dl.shift
			// A copy drawn elsewhere (the drag ghost) draws the layer as it
			// rests: without the glide or slide it is part-way through where
			// it is laid out, which would carry the copy out of its own box.
			if dl.at_rest {
				sh -= layer_self_shift(t, dl.node)
				k2, off2 = 1, {}
			}
			flatten_layer(t, dl.node, out, k * dl.opacity, shift = sh,
				scale = scale * k2, off = {off2.x * scale + off.x, off2.y * scale + off.y})
		} else {
			f := c if k >= 1 else faded(c, k)
			if shift != {} do f = shifted(f, shift)
			if scale != 1 do f = scaled(f, scale, off)
			append(out, f)
		}
	}
}

// scaled is `c` grown by `k` and moved by `off`: a nested layer's cached
// list drawn inside something that is scaling (a Fade_Scale transition).
// It transforms a list already laid out, so nothing re-wraps, re-measures
// or re-rasterises on the way in.
//
// Two fields are left alone: `size` on text and icons, since scaling it
// would rasterise every glyph afresh each frame (a 4% error on 15 px text
// is 0.6 px, gone by the last frame); and `wrap_w`, which would re-wrap the
// text mid-animation. `box_w` is scaled, or a centred title would drift.
//
// `k` and `off` are `p × k + off`, not a scale about an origin (about `o`
// the offset is `o × (1 − k)`): only this form composes, a layer inside
// another being `k = k1 × k2`, `off = off2 × k1 + off1`.
@(private)
scaled :: proc(c: Draw_Cmd, k: f32, off: [2]f32) -> Draw_Cmd {
	pt :: proc(p: [2]f32, k: f32, off: [2]f32) -> [2]f32 { return {p.x * k + off.x, p.y * k + off.y} }
	bx :: proc(r: Rect, k: f32, off: [2]f32) -> Rect {
		return {r.x * k + off.x, r.y * k + off.y, r.w * k, r.h * k}
	}
	switch v in c {
	case Draw_Typeset:    s := v; s.pos = pt(s.pos, k, off); s.scale = (s.scale if s.scale > 0 else 1) * k; return s
	case Draw_Rect:       s := v; s.rect = bx(s.rect, k, off); s.radius *= k; s.border_w *= k; return s
	case Draw_Shadow:     s := v; s.rect = bx(s.rect, k, off); s.radius *= k; s.blur *= k; if s.hole.w > 0 do s.hole = bx(s.hole, k, off); return s
	case Draw_Backdrop:   s := v; s.rect = bx(s.rect, k, off); s.radius *= k; return s
	case Draw_Image:      s := v; s.rect = bx(s.rect, k, off); s.radius *= k; return s
	case Draw_Canvas:     s := v; s.rect = bx(s.rect, k, off); s.radius *= k; return s
	case Draw_Theme_Icon: s := v; s.rect = bx(s.rect, k, off); return s
	case Draw_Clip_Push:  s := v; s.rect = bx(s.rect, k, off); return s
	case Draw_Text:       s := v; s.pos = pt(s.pos, k, off); s.box_w *= k; return s
	case Draw_Icon:       s := v; s.pos = pt(s.pos, k, off); return s
	case Draw_Wave:       s := v; s.pos = pt(s.pos, k, off); s.width *= k; return s
	case Draw_Line:       s := v; s.a = pt(s.a, k, off); s.b = pt(s.b, k, off); s.width *= k; return s
	case Draw_Cells:      s := v; s.pos = pt(s.pos, k, off); return s
	case Draw_Clip_Pop, Draw_Glow_Push, Draw_Glow_Pop, Draw_Layer:
	}
	return c
}

// faded is `c` at `k` of its alpha: a nested layer's cached list drawn
// inside something fading.
@(private)
faded :: proc(c: Draw_Cmd, k: f32) -> Draw_Cmd {
	#partial switch v in c {
	case Draw_Rect:
		r := v
		r.color.a *= k
		r.color2.a *= k
		r.border.a *= k
		return r
	case Draw_Shadow:
		s := v
		s.color.a *= k
		return s
	case Draw_Text:
		s := v
		s.color.a *= k
		return s
	case Draw_Icon:
		s := v
		s.color.a *= k
		return s
	case Draw_Image:
		s := v
		s.color.a *= k
		return s
	case Draw_Canvas:
		s := v
		s.color.a *= k
		return s
	case Draw_Theme_Icon:
		s := v
		s.color.a *= k
		return s
	case Draw_Wave:
		s := v
		s.color.a *= k
		return s
	case Draw_Line:
		s := v
		s.color.a *= k
		return s
	case Draw_Cells:
		s := v
		s.alpha *= k
		return s
	}
	return c
}

// shifted is `c` moved by `d` (a popup's surface draws its card from its own
// corner).
@(private)
shifted :: proc(c: Draw_Cmd, d: [2]f32) -> Draw_Cmd {
	move :: proc(r: Rect, d: [2]f32) -> Rect { return {r.x + d.x, r.y + d.y, r.w, r.h} }
	switch v in c {
	case Draw_Typeset:    s := v; s.pos += d; return s
	case Draw_Rect:       s := v; s.rect = move(s.rect, d); return s
	case Draw_Shadow:     s := v; s.rect = move(s.rect, d); if s.hole.w > 0 do s.hole = move(s.hole, d); return s
	case Draw_Backdrop:   s := v; s.rect = move(s.rect, d); return s
	case Draw_Image:      s := v; s.rect = move(s.rect, d); return s
	case Draw_Canvas:     s := v; s.rect = move(s.rect, d); return s
	case Draw_Theme_Icon: s := v; s.rect = move(s.rect, d); return s
	case Draw_Clip_Push:  s := v; s.rect = move(s.rect, d); return s
	case Draw_Text:       s := v; s.pos += d; return s
	case Draw_Icon:       s := v; s.pos += d; return s
	case Draw_Wave:       s := v; s.pos += d; return s
	case Draw_Line:       s := v; s.a += d; s.b += d; return s
	case Draw_Cells:      s := v; s.pos += d; return s
	case Draw_Clip_Pop, Draw_Glow_Push, Draw_Glow_Pop, Draw_Layer:
	}
	return c
}

// take_damage returns the rects that changed since the last call and resets
// the list. Empty means "present nothing". The slice is in temp memory by
// default.
take_damage :: proc(t: ^Tree, allocator := context.temp_allocator) -> []Rect {
	out := make([]Rect, len(t.damage), allocator)
	copy(out, t.damage[:])
	clear(&t.damage)
	return out
}

damage_bounds :: proc "contextless" (rects: []Rect) -> (r: Rect) {
	for x in rects do r = rect_union(r, x)
	return
}

// paint_button_mark draws a button's mark (Button_Mark) inside its edge,
// centred along it. Its length and colour ease to what was asked over
// motion.fast; the first paint shows it as it is, so a taskbar that opens
// doesn't grow every mark at once.
@(private)
paint_button_mark :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer, op: f32, dim: bool) {
	use, has := &t.button_marks[n]
	if !has do return
	th := &t.theme
	mk := use.mark
	want := mk.color if mk.color != {} else d.style.fg
	if !use.painted {
		use.painted = true
		use.from, use.to = want, want
		anim_restart(t, n, .Mark_Length, mk.length, mk.length, 0)
		anim_restart(t, n, .Mark_Color, 1, 1, 0)
	}
	if want != use.to {
		use.from = mix(use.from, use.to, anim_state(t, n).value[.Mark_Color])
		use.to = want
		anim_restart(t, n, .Mark_Color, 0, 1, th.motion.fast)
	}
	length := anim_target(t, n, .Mark_Length, mk.length, th.motion.fast)
	if length < 0.5 do return
	thick := mk.thickness if mk.thickness > 0 else button_look(th).mark_thickness
	through := anim_state(t, n).value[.Mark_Color]
	c := use.to if through >= 1 else mix(use.from, use.to, through)
	c.a *= op
	if dim do c.a *= th.state.disabled_alpha
	r := d.abs
	// One mark, or `count` of them sharing its place: the group keeps about
	// the single mark's length, so a mark that starts counting does not jump
	// about, and no pip is shorter than it is thick (a dot, then).
	count := max(mk.count, 1)
	gap := max(thick, 2) if count > 1 else 0
	along := r.w if mk.side == .Top || mk.side == .Bottom else r.h
	length = min(length, along)
	each := max((length - gap * f32(count - 1)) / f32(count), thick) if count > 1 else length
	total := min(each * f32(count) + gap * f32(count - 1), along)
	for i in 0 ..< count {
		at := (along - total) / 2 + f32(i) * (each + gap)
		switch mk.side {
		case .Top, .Bottom:
			y := r.y if mk.side == .Top else r.y + r.h - thick
			append(&l.cmds, Draw_Rect{rect = {r.x + at, y, each, thick}, color = c, radius = thick / 2})
		case .Left, .Right:
			x := r.x if mk.side == .Left else r.x + r.w - thick
			append(&l.cmds, Draw_Rect{rect = {x, r.y + at, thick, each}, color = c, radius = thick / 2})
		}
	}
}

// button_icon_rect is where a button's icon, theme icon or picture is, moved
// by the slide the button is painted with (which its icon's rect doesn't
// carry yet); the button's own rect when it has none.
@(private)
button_icon_rect :: proc(t: ^Tree, d: ^Node_Data, shift: [2]f32) -> Rect {
	for ch := d.first; ch != NODE_NONE; ch = node_get(t, ch).next {
		cd := node_get(t, ch)
		if cd.key >= control_part_icons(0) do continue
		part := Control_Part(cd.key)
		if part == .Icon || part == .Image || part == .Theme_Icon {
			return {cd.abs.x + shift.x, cd.abs.y + shift.y, cd.abs.w, cd.abs.h}
		}
	}
	return d.abs
}

// paint_button_progress draws a button's progress: a bar across the bottom
// of its icon (of the button itself when it has none), or a ring just outside
// it, taking no room either way. The value fills in the accent over a faint
// track; busy, a band runs along the bar or an arc goes round the ring, and
// holds still under reduce motion. It grows in and shrinks away over
// motion.fast, and the value eases over motion.base (both instant under
// reduce motion).
//
// On a button filled with the accent, the accent would be invisible, so the
// progress takes the colour that reads on the fill instead.
@(private)
paint_button_progress :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer, op: f32, dim: bool, shift: [2]f32) {
	use, has := t.button_progress[n]
	if !has do return
	th := &t.theme
	k := anim_target(t, n, .Progress_On, 1 if use.on else 0, th.motion.fast)
	if k <= 0.01 do return
	icon := button_icon_rect(t, d, shift)
	if icon.w <= 0 do return
	fade := op * (th.state.disabled_alpha if dim else 1)
	lk := button_look(th)
	fill, track := lk.progress_fill, lk.progress_track // the track's alpha is in the look
	if bg := d.style.bg; bg.a > 0.5 && contrast_ratio(opaque(fill), opaque(bg)) < SELECTION_BAND_MIN {
		fill = extreme_on(opaque(bg))
		track = fill
		track.a *= BUTTON_PROGRESS_TRACK_ALPHA
	}
	fill.a *= fade * k
	track.a *= fade * k
	if use.style == .Ring {
		paint_button_ring(t, n, d, l, use, icon, fill, track, lk.ring_thickness, lk.ring_gap)
		return
	}
	h := min(lk.progress_thickness, icon.h / 3) * k
	if h <= 0.01 do return
	y := icon.y + icon.h - h
	rad := pill_radius(th, h)
	append(&l.cmds, Draw_Rect{rect = {icon.x, y, icon.w, h}, color = track, radius = rad})
	if use.busy {
		// a band running along the bar, as the progress widget's does
		bw := icon.w * 0.35
		if th.motion.reduce {
			append(&l.cmds, Draw_Rect{rect = {icon.x + (icon.w - bw) / 2, y, bw, h}, color = fill, radius = rad})
			return
		}
		if !anim_running(t, n, .Progress_Spin) do anim_restart(t, n, .Progress_Spin, 0, 1, 1300, .Ease_In_Out)
		x := icon.x - bw + (icon.w + bw) * anim_value(t, n, .Progress_Spin)
		append(&l.cmds, Draw_Clip_Push{{icon.x, y, icon.w, h}})
		append(&l.cmds, Draw_Rect{rect = {x, y, bw, h}, color = fill, radius = rad})
		append(&l.cmds, Draw_Clip_Pop{})
		return
	}
	v := clamp(anim_target(t, n, .Progress, use.value, th.motion.base), 0, 1)
	if v > 0 do append(&l.cmds, Draw_Rect{rect = {icon.x, y, icon.w * v, h}, color = fill, radius = rad})
}

// paint_button_ring draws a button's progress as a ring round its icon:
// outside the icon's box, in the room an icon-only button has round it, so
// it covers no stroke of the glyph and takes no space. The
// track is the whole circle; the value fills clockwise from twelve o'clock,
// with round ends. Busy, an arc goes round, and stands at twelve under
// reduce motion. `stroke` and `ring_gap` are the button look's.
@(private)
paint_button_ring :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer, use: Button_Progress_Use, icon: Rect, fill, track: Color, stroke, ring_gap: f32) {
	th := &t.theme
	cx, cy := icon.x + icon.w / 2, icon.y + icon.h / 2
	r := icon.w / 2 + ring_gap + stroke / 2
	room := min(d.abs.w, d.abs.h) / 2 - stroke / 2 - 0.5 // kept inside the button
	if room > stroke do r = min(r, room)
	o := r + stroke / 2 // the track is a round rect whose border is the ring
	append(&l.cmds, Draw_Rect{rect = {cx - o, cy - o, 2 * o, 2 * o}, radius = o, border_w = stroke, border = track})
	start := f32(-math.PI / 2)
	span: f32
	if use.busy {
		span = 2 * math.PI * BUTTON_RING_BUSY_ARC
		if !th.motion.reduce {
			if !anim_running(t, n, .Progress_Spin) do anim_restart(t, n, .Progress_Spin, 0, 1, 1100, .Linear)
			start += 2 * math.PI * anim_value(t, n, .Progress_Spin)
		}
	} else {
		span = 2 * math.PI * clamp(anim_target(t, n, .Progress, use.value, th.motion.base), 0, 1)
	}
	if span <= 0.001 do return
	segs := max(2, int(math.ceil(span / (2 * math.PI) * 64)))
	prev := [2]f32{cx + r * math.cos(start), cy + r * math.sin(start)}
	for i in 1 ..= segs {
		a := start + span * f32(i) / f32(segs)
		p := [2]f32{cx + r * math.cos(a), cy + r * math.sin(a)}
		append(&l.cmds, Draw_Line{a = prev, b = p, width = stroke, color = fill}) // round ends: the arc joins itself and ends round
		prev = p
	}
}

// paint_button_badge draws a button's badge (Button_Badge) centred on the
// top end corner of its icon (of the button when it has none), kept inside
// the button. It grows in and shrinks away over motion.fast. `shift` is the
// slide the button is painted with, which its icon's rect doesn't carry yet.
@(private)
paint_button_badge :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer, op: f32, dim: bool, shift: [2]f32) {
	use, has := &t.button_badges[n]
	if !has do return
	th := &t.theme
	on := use.badge.dot || use.badge.text != ""
	k := anim_target(t, n, .Badge, 1 if on else 0, th.motion.fast)
	if k <= 0.01 do return
	b := use.shown
	icon := button_icon_rect(t, d, shift)
	corner := [2]f32{icon.x + icon.w, icon.y}
	lk := button_look(th)
	tl := lk.badge_text
	fam := look_family(t, tl.family)
	fill := b.color if b.color != {} else lk.badge_fill
	ink := lk.badge_ink
	if b.color != {} do ink = Color{1, 1, 1, 1} if contrast_ratio({1, 1, 1, 1}, fill) >= contrast_ratio({0, 0, 0, 1}, fill) else Color{0, 0, 0, 1}
	size := [2]f32{lk.badge_dot, lk.badge_dot}
	measured: [2]f32
	if b.text != "" {
		measured = t.measure_text(t, b.text, tl.size, 0, tl.weight, false, fam, false)
		size = {max(lk.badge_height, measured.x + 2 * lk.badge_padding), lk.badge_height}
	}
	centre := [2]f32{
		clamp(corner.x, d.abs.x + size.x / 2, d.abs.x + d.abs.w - size.x / 2),
		clamp(corner.y, d.abs.y + size.y / 2, d.abs.y + d.abs.h - size.y / 2),
	}
	fade := op * (th.state.disabled_alpha if dim else 1)
	fill.a *= fade
	grown := size * k
	append(&l.cmds, Draw_Rect{rect = {centre.x - grown.x / 2, centre.y - grown.y / 2, grown.x, grown.y}, color = fill, radius = grown.y / 2})
	if b.text != "" {
		ink.a *= fade * k
		append(&l.cmds, Draw_Text{pos = centre - measured / 2, str = b.text, size = tl.size, color = ink, weight = tl.weight, family = fam})
	}
}
