package baldr

// SVG documents as icon themes draw them: shapes and paths, groups, `use`
// and `symbol`, nested `svg`, transforms, fills (nonzero and evenodd) and
// strokes (joins, caps, dashes), linear and radial gradients, patterns,
// clip paths, masks, group opacity, embedded PNG and JPEG pictures, and
// the filter primitives icons use. Styles come from presentation
// attributes, `style`, and `<style>` sheets (type, class and id selectors,
// descendant and child combinators, `!important`), and simple text in
// Baldr's own faces (svg_text.odin). Pure Odin: core's XML parser, then
// svg_draw.odin's rasteriser and svg_paint.odin's paints and filters.
// Colours composite in sRGB, as browsers do, so icons look as their
// designers drew them.

import "core:encoding/xml"
import "core:math"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import runa "baldr:third_party/runa"

SVG_MAX_SIDE :: 4096
@(private)
SVG_MAX_DEPTH :: 48

// SVG_MAX_ELEMENTS is how many elements one drawing visits before it stops:
// far beyond any icon or illustration, and a bound on a document whose
// `use` elements each repeat the one before, which grows tenfold a level
// inside the depth limit and would hold the app for minutes.
@(private)
SVG_MAX_ELEMENTS :: 100_000

// Svg_Colors are the colours an icon takes from where it is drawn. `text`
// is what `currentColor` starts as and what KDE's `.ColorScheme-Text` sets;
// highlight, positive, neutral and negative go to `.ColorScheme-Highlight`,
// `-PositiveText`, `-NeutralText` and `-NegativeText`. `symbolic` applies
// GTK's rule for `*-symbolic` icons: every painted fill and stroke takes
// `text`, or the colour its class names (`success`, `warning`, `error`, or
// the KDE class).
Svg_Colors :: struct {
	text, highlight, positive, neutral, negative: Color,
	symbolic:                                     bool,
}

// Svg_Info is what svg_render saw while drawing with Svg_Colors: whether a
// given colour painted anything (`recolored`), and whether everything
// painted took the text colour (`monochrome`: the picture's alpha is then a
// mask to draw in any colour). Masks don't count; embedded pictures,
// gradients, patterns and filters count as the document's own colours.
Svg_Info :: struct {
	recolored, monochrome: bool,
}

// svg_render draws an SVG document into a w × h Image (RGBA8, sRGB,
// straight alpha), fitting its viewBox by its preserveAspectRatio. With
// `colors`, the icon follows them (see Svg_Colors), and `info` says how.
// Fails when the document doesn't parse or a side is over SVG_MAX_SIDE.
// The Image's pixels are the caller's, from `allocator` (image_destroy).
// Safe on any thread: all its working memory is its own.
svg_render :: proc(data: []u8, w, h: int, colors: ^Svg_Colors = nil, info: ^Svg_Info = nil, allocator := context.allocator) -> (img: Image, ok: bool) {
	if w <= 0 || h <= 0 || w > SVG_MAX_SIDE || h > SVG_MAX_SIDE do return
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	d: Svg_Doc
	svg_open(&d, data, colors) or_return
	c := svg_canvas_make(w, h)
	style := d.initial
	svg_draw(&d, d.root, &style, svg_root_xf(&d, w, h), c, false)
	if info != nil do info^ = {recolored = d.text_paint || d.role_paint, monochrome = d.text_paint && !d.other_paint}
	pixels := make([]u8, w * h * 4, allocator)
	for i in 0 ..< w * h {
		px := c.px[i * 4:]
		a := clamp(px[3], 0, 1)
		if a <= 0 do continue
		for k in 0 ..< 3 do pixels[i * 4 + k] = u8(clamp(px[k] / a, 0, 1) * 255 + 0.5)
		pixels[i * 4 + 3] = u8(a * 255 + 0.5)
	}
	return Image{width = w, height = h, pixels = pixels, version = 1, allocator = allocator}, true
}

// svg_size is a document's own size in pixels: its width and height, or
// what its viewBox gives.
svg_size :: proc(data: []u8) -> (size: [2]f32, ok: bool) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	d: Svg_Doc
	svg_open(&d, data, nil) or_return
	e := &d.x.elements[d.root]
	vb, has_vb := svg_viewbox(e)
	w, w_ok := svg_intrinsic(e, "width")
	h, h_ok := svg_intrinsic(e, "height")
	switch {
	case w_ok && h_ok:   return {w, h}, true
	case w_ok && has_vb: return {w, w * vb[3] / vb[2]}, true
	case h_ok && has_vb: return {h * vb[2] / vb[3], h}, true
	case has_vb:         return {vb[2], vb[3]}, true
	}
	return
}

@(private)
Svg_Doc :: struct {
	x:       ^xml.Document,
	root:    xml.Element_ID,
	ids:     map[string]xml.Element_ID,
	rules:   [dynamic]Svg_Rule,
	colors:  ^Svg_Colors,
	palette: [Svg_Role][4]f32, // the colours, in sRGB
	initial: Svg_Style,
	view:    [2]f32, // the nearest viewport's size in user units, for percentages
	depth:   int,
	visited: int, // elements drawn so far, against SVG_MAX_ELEMENTS
	uses:    [dynamic]xml.Element_ID, // the `use` elements being drawn, so a reference loop ends
	busy:    [dynamic]xml.Element_ID, // the clip paths, masks, filters and patterns being drawn
	rasters:  [dynamic]^Svg_Raster,
	pool:     [dynamic]^Svg_Canvas,
	pictures: map[string]^Svg_Picture, // embedded pictures by their data URI, decoded once
	fonts:    map[Svg_Font_Key]^runa.Font, // loaded when text is first drawn
	// for Svg_Info: what painted colours came from (outside masks)
	text_paint, role_paint, other_paint: bool,
	mask_depth:                          int,
}

@(private)
Svg_Kind :: enum u8 { Other, Svg, G, Use, Switch, Path, Rect, Circle, Ellipse, Line, Polyline, Polygon, Image, Text }

@(private)
SVG_SHAPES :: bit_set[Svg_Kind]{.Path, .Rect, .Circle, .Ellipse, .Line, .Polyline, .Polygon}

@(private)
Svg_Role :: enum u8 { None, Text, Highlight, Positive, Neutral, Negative }

@(private)
Svg_Paint_Kind :: enum u8 { None, Color, Current, Url }

@(private)
Svg_Paint :: struct {
	kind:           Svg_Paint_Kind,
	color:          [4]f32, // sRGB, straight alpha
	url:            string, // the paint server's id
	fallback:       Svg_Paint_Kind, // when the server is missing
	fallback_color: [4]f32,
}

@(private)
Svg_Fill_Rule :: enum u8 { Nonzero, Evenodd }
@(private)
Svg_Cap :: enum u8 { Butt, Round, Square }
@(private)
Svg_Join :: enum u8 { Miter, Round, Bevel }
@(private)
Svg_Unit :: enum u8 { Px, Percent, Em, Ex }
@(private)
Svg_Axis :: enum u8 { X, Y, Diag }

@(private)
Svg_Length :: struct {
	v:    f32,
	unit: Svg_Unit,
}

@(private)
Svg_Style :: struct {
	// inherited
	fill, stroke:                 Svg_Paint,
	fill_opacity, stroke_opacity: f32,
	fill_rule, clip_rule:         Svg_Fill_Rule,
	stroke_width:                 Svg_Length,
	cap:                          Svg_Cap,
	join:                         Svg_Join,
	miter_limit:                  f32,
	dashes:                       []Svg_Length,
	dash_offset:                  Svg_Length,
	color:                        [4]f32,
	color_role:                   Svg_Role, // the given colour `color` is, or None for the document's own
	visible:                      bool,
	role:                         Svg_Role,
	linear_filters:               bool, // color-interpolation-filters: linearRGB
	font_size:                    f32,
	font_family:                  string,
	font_weight:                  f32,
	font_italic:                  bool,
	anchor:                       Svg_Anchor,
	letter_spacing, word_spacing: Svg_Length,
	preserve_space:               bool, // xml:space="preserve"
	// not inherited
	opacity:                      f32,
	display:                      bool,
	clip_path, mask, filter:      string, // referenced ids
	stop_color, flood_color:      Svg_Paint,
	stop_opacity, flood_opacity:  f32,
	mask_alpha:                   bool, // mask-type: alpha
	lighting_color:               Svg_Paint,
}

@(private)
Svg_Anchor :: enum u8 { Start, Middle, End }

@(private)
Svg_Xf :: [6]f32 // a b c d e f: x' = a·x + c·y + e, y' = b·x + d·y + f

@(private)
SVG_XF_ID :: Svg_Xf{1, 0, 0, 1, 0, 0}

@(private)
Svg_Box :: struct {
	lo, hi: [2]f32,
	ok:     bool,
}

@(private)
svg_open :: proc(d: ^Svg_Doc, data: []u8, colors: ^Svg_Colors) -> bool {
	quiet :: proc(pos: xml.Pos, format: string, args: ..any) {}
	doc, err := xml.parse_bytes(svg_expand_entities(data), {flags = {.Ignore_Unsupported, .Unbox_CDATA, .Decode_SGML_Entities}}, "", quiet)
	if err != .None || doc == nil || doc.element_count == 0 do return false
	if name, ours := svg_local(doc.elements[0].ident); !ours || name != "svg" do return false
	d.x = doc
	d.ids = make(map[string]xml.Element_ID)
	sheet := strings.builder_make()
	for i in 0 ..< int(doc.element_count) {
		e := &doc.elements[i]
		if e.kind != .Element do continue
		if id := svg_attr(e, "id"); id != "" && id not_in d.ids do d.ids[id] = xml.Element_ID(i)
		name, ours := svg_local(e.ident)
		if !ours || name != "style" do continue
		if t := svg_attr(e, "type"); t != "" && t != "text/css" do continue
		for v in e.value {
			if text, is := v.(string); is {
				strings.write_string(&sheet, text)
				strings.write_byte(&sheet, '\n')
			}
		}
	}
	svg_sheet(d, strings.to_string(sheet))
	slice.stable_sort_by(d.rules[:], proc(a, b: Svg_Rule) -> bool { return a.spec < b.spec })
	d.colors = colors
	if colors != nil {
		srgb :: proc(c: Color) -> [4]f32 { return {linear_to_srgb(c.r), linear_to_srgb(c.g), linear_to_srgb(c.b), c.a} }
		d.palette[.Text] = srgb(colors.text)
		d.palette[.Highlight] = srgb(colors.highlight)
		d.palette[.Positive] = srgb(colors.positive)
		d.palette[.Neutral] = srgb(colors.neutral)
		d.palette[.Negative] = srgb(colors.negative)
	}
	black := Svg_Paint{kind = .Color, color = {0, 0, 0, 1}}
	d.initial = {
		fill = black, fill_opacity = 1, stroke_opacity = 1,
		stroke_width = {1, .Px}, miter_limit = 4,
		color = d.palette[.Text] if colors != nil else {0, 0, 0, 1},
		color_role = .Text if colors != nil else .None,
		visible = true, linear_filters = true, font_size = 16, font_weight = 400,
		opacity = 1, display = true,
		stop_color = black, stop_opacity = 1, flood_color = black, flood_opacity = 1,
		lighting_color = {kind = .Color, color = {1, 1, 1, 1}},
	}
	return true
}

// svg_expand_entities replaces the general entities a document declares in
// its DOCTYPE (some editors keep their styles there) and drops the
// DOCTYPE: core's parser knows only the predefined entities. Values are not
// expanded again, and past 64 MB it gives up, so an entity bomb stays small.
@(private)
svg_expand_entities :: proc(data: []u8) -> []u8 {
	s := string(data)
	dt := strings.index(s, "<!DOCTYPE")
	if dt < 0 do return data
	open, gt := strings.index_byte(s[dt:], '['), strings.index_byte(s[dt:], '>')
	if open < 0 || gt < open do return data // no internal subset
	subset_start := dt + open + 1
	body := ""
	subset := ""
	for i := subset_start; i < len(s); i += 1 { // the ']' with only space before the closing '>'
		if s[i] != ']' do continue
		j := i + 1
		for j < len(s) && (s[j] == ' ' || s[j] == '\t' || s[j] == '\r' || s[j] == '\n') do j += 1
		if j < len(s) && s[j] == '>' {
			subset, body = s[subset_start:i], s[j + 1:]
			break
		}
	}
	if subset == "" do return data
	names := make(map[string]string)
	rest := subset
	for {
		at := strings.index(rest, "<!ENTITY")
		if at < 0 do break
		rest = strings.trim_left_space(rest[at + len("<!ENTITY"):])
		if strings.has_prefix(rest, "%") do continue // a parameter entity
		sp := strings.index_any(rest, " \t\r\n")
		if sp < 0 do break
		name := rest[:sp]
		rest = strings.trim_left_space(rest[sp:])
		if rest == "" || (rest[0] != '"' && rest[0] != '\'') do continue
		q := strings.index_byte(rest[1:], rest[0])
		if q < 0 do break
		names[name] = rest[1:1 + q]
		rest = rest[q + 2:]
	}
	if len(names) == 0 do return data
	b := strings.builder_make()
	strings.write_string(&b, s[:dt])
	for i := 0; i < len(body); {
		if body[i] == '&' {
			if semi := strings.index_byte(body[i:min(i + 64, len(body))], ';'); semi > 1 {
				if value, known := names[body[i + 1:i + semi]]; known {
					strings.write_string(&b, value)
					i += semi + 1
					if len(b.buf) > 64 * 1024 * 1024 do return data
					continue
				}
			}
		}
		strings.write_byte(&b, body[i])
		i += 1
	}
	return b.buf[:]
}

// svg_root_xf maps the root's viewBox (or its own width and height) onto
// the w × h picture.
@(private)
svg_root_xf :: proc(d: ^Svg_Doc, w, h: int) -> Svg_Xf {
	e := &d.x.elements[d.root]
	vb, has := svg_viewbox(e)
	if !has {
		iw, w_ok := svg_intrinsic(e, "width")
		ih, h_ok := svg_intrinsic(e, "height")
		if !w_ok || !h_ok || iw <= 0 || ih <= 0 {
			d.view = {f32(w), f32(h)}
			return SVG_XF_ID
		}
		vb = {0, 0, iw, ih}
	}
	d.view = {vb[2], vb[3]}
	return svg_fit(vb, {0, 0, f32(w), f32(h)}, svg_aspect(svg_attr(e, "preserveAspectRatio")))
}

// Drawing

@(private)
svg_draw :: proc(d: ^Svg_Doc, id: xml.Element_ID, parent: ^Svg_Style, ctm: Svg_Xf, c: ^Svg_Canvas, clip: bool) {
	e := &d.x.elements[id]
	if e.kind != .Element do return
	name, ours := svg_local(e.ident)
	if !ours do return
	kind := svg_kind_of(name)
	if kind == .Other do return
	if clip && kind not_in SVG_SHAPES && kind != .Use && kind != .Text do return // what a clip path may hold
	if d.depth >= SVG_MAX_DEPTH || d.visited >= SVG_MAX_ELEMENTS do return
	d.visited += 1
	d.depth += 1
	defer d.depth -= 1
	s := svg_style(d, id, parent)
	if !s.display do return
	xf := svg_xf_mul(ctm, svg_transform(svg_attr(e, "transform")))
	nested := kind == .Svg && id != d.root
	layer: bool
	if clip {
		layer = s.clip_path != ""
	} else {
		both := kind in SVG_SHAPES && s.fill.kind != .None && s.stroke.kind != .None
		grouping := kind not_in SVG_SHAPES && kind != .Image
		layer = s.clip_path != "" || s.mask != "" || s.filter != "" || nested || (s.opacity < 1 && (grouping || both))
	}
	target := svg_layer(d, c.w, c.h) if layer else c
	opacity: f32 = 1 if layer || clip else s.opacity // a lone fill or stroke fades by itself
	#partial switch kind {
	case .Svg:
		if nested {
			fs := s.font_size
			rect := [4]f32{
				svg_attr_len(d, e, "x", .X, fs), svg_attr_len(d, e, "y", .Y, fs),
				svg_attr_length(d, e, "width", .X, fs, {100, .Percent}), svg_attr_length(d, e, "height", .Y, fs, {100, .Percent}),
			}
			if rect[2] > 0 && rect[3] > 0 do svg_viewport(d, e, &s, xf, rect, target, false)
		} else {
			svg_children(d, e, &s, xf, target, clip)
		}
	case .G:
		svg_children(d, e, &s, xf, target, clip)
	case .Switch: // the first child it can draw
		for v in e.value {
			child, is := v.(xml.Element_ID)
			if !is do continue
			ce := &d.x.elements[child]
			cname, cours := svg_local(ce.ident)
			if ce.kind != .Element || !cours || svg_kind_of(cname) == .Other do continue
			svg_draw(d, child, &s, xf, target, clip)
			break
		}
	case .Use:
		svg_draw_use(d, e, id, &s, xf, target, clip)
	case .Text:
		svg_draw_text(d, e, &s, xf, target, clip)
	case .Image:
		svg_draw_image(d, e, &s, xf, target, opacity)
	case:
		svg_draw_shape(d, e, kind, &s, xf, target, clip, opacity)
	}
	if !layer do return
	if !clip && s.filter != "" do svg_filter_apply(d, s.filter, id, xf, target)
	if s.clip_path != "" do svg_clip_apply(d, s.clip_path, id, xf, target)
	if !clip && s.mask != "" do svg_mask_apply(d, s.mask, id, xf, target)
	svg_canvas_over(c, target, 1 if clip else s.opacity)
	svg_layer_release(d, target)
}

@(private)
svg_children :: proc(d: ^Svg_Doc, e: ^xml.Element, s: ^Svg_Style, xf: Svg_Xf, c: ^Svg_Canvas, clip: bool) {
	for v in e.value {
		if child, is := v.(xml.Element_ID); is do svg_draw(d, child, s, xf, c, clip)
	}
}

// svg_viewport draws a nested svg's or a symbol's children, their viewBox
// fitted to `rect` and clipped to it.
@(private)
svg_viewport :: proc(d: ^Svg_Doc, e: ^xml.Element, s: ^Svg_Style, xf: Svg_Xf, rect: [4]f32, c: ^Svg_Canvas, own_layer: bool) {
	inner := svg_xf_mul(xf, svg_xf_translate(rect[0], rect[1]))
	view := [2]f32{rect[2], rect[3]}
	if vb, has := svg_viewbox(e); has {
		inner = svg_xf_mul(xf, svg_fit(vb, rect, svg_aspect(svg_attr(e, "preserveAspectRatio"))))
		view = {vb[2], vb[3]}
	}
	saved := d.view
	d.view = view
	defer d.view = saved
	target := svg_layer(d, c.w, c.h) if own_layer else c
	svg_children(d, e, s, inner, target, false)
	svg_clip_rect(d, target, xf, rect)
	if own_layer {
		svg_canvas_over(c, target, 1)
		svg_layer_release(d, target)
	}
}

@(private)
svg_draw_use :: proc(d: ^Svg_Doc, e: ^xml.Element, id: xml.Element_ID, s: ^Svg_Style, xf: Svg_Xf, c: ^Svg_Canvas, clip: bool) {
	ref, found := svg_ref(d, svg_href(e))
	if !found || slice.contains(d.uses[:], id) do return
	append(&d.uses, id)
	defer pop(&d.uses)
	fs := s.font_size
	x, y := svg_attr_len(d, e, "x", .X, fs), svg_attr_len(d, e, "y", .Y, fs)
	if svg_name(d, ref) != "symbol" {
		svg_draw(d, ref, s, svg_xf_mul(xf, svg_xf_translate(x, y)), c, clip)
		return
	}
	if clip do return
	ss := svg_style(d, ref, s)
	w := svg_attr_length(d, e, "width", .X, fs, {100, .Percent})
	h := svg_attr_length(d, e, "height", .Y, fs, {100, .Percent})
	if !ss.display || w <= 0 || h <= 0 do return
	svg_viewport(d, &d.x.elements[ref], &ss, xf, {x, y, w, h}, c, true)
}

@(private)
svg_draw_shape :: proc(d: ^Svg_Doc, e: ^xml.Element, kind: Svg_Kind, s: ^Svg_Style, xf: Svg_Xf, c: ^Svg_Canvas, clip: bool, opacity: f32) {
	if !s.visible do return
	path, ok := svg_shape_path(d, e, kind, s, xf)
	if !ok do return
	box: Svg_Box
	svg_path_box(&path, SVG_XF_ID, &box)
	svg_paint_path(d, &path, s, xf, c, clip, opacity, box, kind != .Line)
}

// svg_paint_path fills, then strokes, a path in its style; inside a clip
// path only its coverage counts. `box` is what objectBoundingBox paints fit.
@(private)
svg_paint_path :: proc(d: ^Svg_Doc, path: ^Svg_Path, s: ^Svg_Style, xf: Svg_Xf, c: ^Svg_Canvas, clip: bool, opacity: f32, box: Svg_Box, fillable := true) {
	r := svg_raster_for(d, c)
	if clip {
		svg_raster_path(r, path, xf)
		svg_raster_fill(r, s.clip_rule == .Evenodd)
		white := Svg_Shader{kind = .Solid, color = {1, 1, 1, 1}}
		svg_composite(c, r, &white, 1)
		return
	}
	fill, stroke := s.fill, s.stroke
	forced := Svg_Role.None
	if d.colors != nil && d.colors.symbolic {
		forced = s.role if s.role != .None else .Text
		if fill.kind != .None do fill = {kind = .Color, color = d.palette[forced]}
		if stroke.kind != .None do stroke = {kind = .Color, color = d.palette[forced]}
	}
	width := svg_len(d, s.stroke_width, .Diag, s.font_size)
	if d.mask_depth == 0 {
		if fill.kind != .None && fillable do svg_note_paint(d, fill, s, forced)
		if stroke.kind != .None && width > 0 do svg_note_paint(d, stroke, s, forced)
	}
	if fill.kind != .None && fillable {
		if sh, painted := svg_shader(d, &fill, s, xf, box); painted {
			svg_raster_path(r, path, xf)
			svg_raster_fill(r, s.fill_rule == .Evenodd)
			svg_composite(c, r, &sh, opacity * s.fill_opacity)
		}
	}
	if stroke.kind == .None || width <= 0 do return
	sh, painted := svg_shader(d, &stroke, s, xf, box)
	if !painted do return
	dashes, dash_offset := svg_dashes(d, s)
	svg_stroke(r, path, s, width, xf, dashes, dash_offset)
	svg_raster_fill(r, false)
	svg_composite(c, r, &sh, opacity * s.stroke_opacity)
}

// svg_note_paint records where a painted colour came from, for Svg_Info:
// the text colour, another given colour, or the document's own.
@(private)
svg_note_paint :: proc(d: ^Svg_Doc, p: Svg_Paint, s: ^Svg_Style, forced: Svg_Role) {
	role := Svg_Role.None
	switch p.kind {
	case .Color:      role = forced
	case .Current:    role = s.color_role
	case .None, .Url:
	}
	switch role {
	case .Text: d.text_paint = true
	case .None: d.other_paint = true
	case .Highlight, .Positive, .Neutral, .Negative:
		d.role_paint = true
		d.other_paint = true
	}
}

// svg_dashes resolves stroke-dasharray to user units, repeated to an even
// count; nil draws solid (none, a negative entry, or nothing to draw).
@(private)
svg_dashes :: proc(d: ^Svg_Doc, s: ^Svg_Style) -> (dashes: []f32, offset: f32) {
	if len(s.dashes) == 0 do return
	n := len(s.dashes) * (2 if len(s.dashes) % 2 == 1 else 1)
	out := make([]f32, n)
	sum: f32
	for i in 0 ..< n {
		v := svg_len(d, s.dashes[i % len(s.dashes)], .Diag, s.font_size)
		if v < 0 do return
		out[i] = v
		sum += v
	}
	if sum <= 0 do return
	return out, svg_len(d, s.dash_offset, .Diag, s.font_size)
}

// svg_clip_apply keeps what of `c` the clip path covers.
@(private)
svg_clip_apply :: proc(d: ^Svg_Doc, ref: string, el: xml.Element_ID, xf: Svg_Xf, c: ^Svg_Canvas) {
	cid, found := d.ids[ref]
	if !found || svg_name(d, cid) != "clipPath" do return // a broken reference clips nothing
	if slice.contains(d.busy[:], cid) {
		svg_canvas_clear(c) // a clip path that clips itself is in error: nothing shows
		return
	}
	append(&d.busy, cid)
	defer pop(&d.busy)
	ce := &d.x.elements[cid]
	cs := svg_style_chain(d, cid)
	m := svg_xf_mul(xf, svg_transform(svg_attr(ce, "transform")))
	if svg_attr(ce, "clipPathUnits") == "objectBoundingBox" {
		box := svg_bbox(d, el)
		if !svg_box_has_area(box) {
			svg_canvas_clear(c)
			return
		}
		m = svg_xf_mul(m, svg_box_xf(box))
	}
	mask := svg_layer(d, c.w, c.h)
	defer svg_layer_release(d, mask)
	svg_children(d, ce, &cs, m, mask, true)
	if cs.clip_path != "" do svg_clip_apply(d, cs.clip_path, el, xf, mask)
	for i := 0; i < len(c.px); i += 4 {
		k := mask.px[i + 3]
		c.px[i] *= k
		c.px[i + 1] *= k
		c.px[i + 2] *= k
		c.px[i + 3] *= k
	}
}

// svg_mask_apply multiplies `c` by the mask's luminance (or alpha, under
// mask-type: alpha), within the mask's region.
@(private)
svg_mask_apply :: proc(d: ^Svg_Doc, ref: string, el: xml.Element_ID, xf: Svg_Xf, c: ^Svg_Canvas) {
	mid, found := d.ids[ref]
	if !found || svg_name(d, mid) != "mask" do return
	if slice.contains(d.busy[:], mid) {
		svg_canvas_clear(c)
		return
	}
	append(&d.busy, mid)
	defer pop(&d.busy)
	me := &d.x.elements[mid]
	ms := svg_style_chain(d, mid)
	obb := svg_attr(me, "maskUnits") != "userSpaceOnUse"
	content_obb := svg_attr(me, "maskContentUnits") == "objectBoundingBox"
	box: Svg_Box
	if obb || content_obb {
		box = svg_bbox(d, el)
		if !svg_box_has_area(box) {
			svg_canvas_clear(c)
			return
		}
	}
	region := svg_region(d, me, obb, box)
	mask := svg_layer(d, c.w, c.h)
	defer svg_layer_release(d, mask)
	m := svg_xf_mul(xf, svg_box_xf(box)) if content_obb else xf
	d.mask_depth += 1
	svg_children(d, me, &ms, m, mask, false)
	d.mask_depth -= 1
	svg_clip_rect(d, mask, xf, region)
	for i := 0; i < len(c.px); i += 4 {
		k := mask.px[i + 3] if ms.mask_alpha else 0.2125 * mask.px[i] + 0.7154 * mask.px[i + 1] + 0.0721 * mask.px[i + 2]
		c.px[i] *= k
		c.px[i + 1] *= k
		c.px[i + 2] *= k
		c.px[i + 3] *= k
	}
}

// svg_region is a mask's or filter's x, y, width and height (by default
// 10% beyond the box on every side), in user space.
@(private)
svg_region :: proc(d: ^Svg_Doc, e: ^xml.Element, obb: bool, box: Svg_Box) -> [4]f32 {
	get :: proc(d: ^Svg_Doc, e: ^xml.Element, name: string, fallback: f32, axis: Svg_Axis, obb: bool) -> (f32, bool) {
		l, ok := svg_parse_length(svg_attr(e, name))
		if !ok do return fallback, obb // the fallbacks are fractions of the box, or of the viewport
		if obb do return l.v / 100 if l.unit == .Percent else l.v, true
		return svg_len(d, l, axis, 16), false
	}
	out: [4]f32
	names := [4]string{"x", "y", "width", "height"}
	fallbacks := [4]f32{-0.1, -0.1, 1.2, 1.2}
	axes := [4]Svg_Axis{.X, .Y, .X, .Y}
	size := [2]f32{box.hi.x - box.lo.x, box.hi.y - box.lo.y}
	for k in 0 ..< 4 {
		v, fraction := get(d, e, names[k], fallbacks[k], axes[k], obb)
		if !fraction {
			out[k] = v
			continue
		}
		// fractions: of the box when obb, else of the viewport
		span := size[k % 2] if obb else d.view[k % 2]
		origin := box.lo[k % 2] if obb else 0
		out[k] = origin + v * span if k < 2 else v * span
	}
	return out
}

// svg_bbox is an element's bounding box in its own user space (inside its
// transform), its descendants' through theirs; strokes are not included.
@(private)
svg_bbox :: proc(d: ^Svg_Doc, id: xml.Element_ID) -> Svg_Box {
	box: Svg_Box
	s := d.initial
	svg_bbox_add(d, id, SVG_XF_ID, false, &s, &box)
	return box
}

@(private)
svg_bbox_add :: proc(d: ^Svg_Doc, id: xml.Element_ID, xf: Svg_Xf, own_transform: bool, parent: ^Svg_Style, box: ^Svg_Box) {
	e := &d.x.elements[id]
	if e.kind != .Element do return
	name, ours := svg_local(e.ident)
	kind := svg_kind_of(name)
	if !ours || kind == .Other || d.depth >= SVG_MAX_DEPTH do return
	d.depth += 1
	defer d.depth -= 1
	s := svg_style(d, id, parent)
	if !s.display do return
	m := svg_xf_mul(xf, svg_transform(svg_attr(e, "transform"))) if own_transform else xf
	fs := s.font_size
	#partial switch kind {
	case .G, .Svg, .Switch:
		for v in e.value {
			if child, is := v.(xml.Element_ID); is do svg_bbox_add(d, child, m, true, &s, box)
		}
	case .Use:
		ref, found := svg_ref(d, svg_href(e))
		if !found || slice.contains(d.uses[:], id) || svg_name(d, ref) == "symbol" do return
		append(&d.uses, id)
		defer pop(&d.uses)
		inner := svg_xf_mul(m, svg_xf_translate(svg_attr_len(d, e, "x", .X, fs), svg_attr_len(d, e, "y", .Y, fs)))
		svg_bbox_add(d, ref, inner, true, &s, box)
	case .Text:
		svg_text_box(d, e, &s, m, box)
	case .Image:
		x, y := svg_attr_len(d, e, "x", .X, fs), svg_attr_len(d, e, "y", .Y, fs)
		w, h := svg_attr_len(d, e, "width", .X, fs), svg_attr_len(d, e, "height", .Y, fs)
		for corner in ([4][2]f32{{x, y}, {x + w, y}, {x, y + h}, {x + w, y + h}}) do svg_box_add(box, svg_xf_apply(m, corner))
	case:
		if path, ok := svg_shape_path(d, e, kind, &s, m); ok do svg_path_box(&path, m, box)
	}
}

@(private)
svg_box_add :: proc "contextless" (b: ^Svg_Box, p: [2]f32) {
	if !b.ok {
		b^ = {p, p, true}
		return
	}
	b.lo = {min(b.lo.x, p.x), min(b.lo.y, p.y)}
	b.hi = {max(b.hi.x, p.x), max(b.hi.y, p.y)}
}

@(private)
svg_box_has_area :: proc "contextless" (b: Svg_Box) -> bool {
	return b.ok && b.hi.x > b.lo.x && b.hi.y > b.lo.y
}

// svg_box_xf maps the unit square onto the box (objectBoundingBox units).
@(private)
svg_box_xf :: proc "contextless" (b: Svg_Box) -> Svg_Xf {
	return {b.hi.x - b.lo.x, 0, 0, b.hi.y - b.lo.y, b.lo.x, b.lo.y}
}

// Styles

// svg_style is an element's computed style: its parent's inherited
// properties, then presentation attributes, sheet rules in specificity
// order, the `style` attribute, and the `!important` declarations in the
// same order; then the colours its classes name.
@(private)
svg_style :: proc(d: ^Svg_Doc, id: xml.Element_ID, parent: ^Svg_Style) -> Svg_Style {
	s := parent^
	s.opacity, s.display, s.mask_alpha = 1, true, false
	s.clip_path, s.mask, s.filter = "", "", ""
	s.stop_color, s.stop_opacity = d.initial.stop_color, 1
	s.flood_color, s.flood_opacity = d.initial.flood_color, 1
	s.lighting_color = d.initial.lighting_color
	e := &d.x.elements[id]
	for a in e.attribs {
		if a.key != "style" && a.key != "class" do svg_declare(d, &s, parent, a.key, a.val)
	}
	matched := make([dynamic]int, 0, 4)
	for &r, i in d.rules do if svg_selector_matches(d, id, r.parts) do append(&matched, i)
	inline := svg_decls(svg_attr(e, "style"))
	for important in ([2]bool{false, true}) {
		for i in matched {
			for decl in d.rules[i].decls do if decl.important == important do svg_declare(d, &s, parent, decl.name, decl.value)
		}
		for decl in inline do if decl.important == important do svg_declare(d, &s, parent, decl.name, decl.value)
	}
	classes := svg_attr(e, "class")
	for cls in strings.fields_iterator(&classes) {
		role, kde := svg_class_role(cls)
		if role == .None do continue
		s.role = role
		if kde && d.colors != nil do s.color, s.color_role = d.palette[role], role
	}
	return s
}

// svg_style_chain computes an element's style down from the root, for
// what is drawn by reference (gradient stops, clip paths, masks).
@(private)
svg_style_chain :: proc(d: ^Svg_Doc, id: xml.Element_ID) -> Svg_Style {
	chain := make([dynamic]xml.Element_ID, 0, 8)
	for cur := id; len(chain) < 256; cur = d.x.elements[cur].parent {
		append(&chain, cur)
		if cur == 0 do break
	}
	s := d.initial
	#reverse for cur in chain {
		next := svg_style(d, cur, &s)
		s = next
	}
	return s
}

@(private)
svg_class_role :: proc(cls: string) -> (role: Svg_Role, kde: bool) {
	switch cls {
	case "ColorScheme-Text", "ColorScheme-ButtonText", "ColorScheme-ViewText", "ColorScheme-ComplementaryText", "ColorScheme-HeaderText":
		return .Text, true
	case "ColorScheme-Highlight", "ColorScheme-ButtonFocus", "ColorScheme-ViewFocus", "ColorScheme-ButtonHover", "ColorScheme-ViewHover":
		return .Highlight, true
	case "ColorScheme-PositiveText": return .Positive, true
	case "ColorScheme-NeutralText":  return .Neutral, true
	case "ColorScheme-NegativeText": return .Negative, true
	case "success":                  return .Positive, false
	case "warning":                  return .Neutral, false
	case "error":                    return .Negative, false
	}
	return .None, false
}

// svg_declare applies one declaration; what it doesn't know or can't
// parse leaves the style as it was.
@(private)
svg_declare :: proc(d: ^Svg_Doc, s: ^Svg_Style, parent: ^Svg_Style, name, value: string) {
	v := strings.trim_space(value)
	if v == "" do return
	p := parent if parent != nil else &d.initial
	inherit := v == "inherit"
	switch name {
	case "fill":
		if inherit { s.fill = p.fill } else if paint, ok := svg_parse_paint(v); ok { s.fill = paint }
	case "stroke":
		if inherit { s.stroke = p.stroke } else if paint, ok := svg_parse_paint(v); ok { s.stroke = paint }
	case "fill-opacity":
		if inherit { s.fill_opacity = p.fill_opacity } else if o, ok := svg_parse_opacity(v); ok { s.fill_opacity = o }
	case "stroke-opacity":
		if inherit { s.stroke_opacity = p.stroke_opacity } else if o, ok := svg_parse_opacity(v); ok { s.stroke_opacity = o }
	case "opacity":
		if inherit { s.opacity = p.opacity } else if o, ok := svg_parse_opacity(v); ok { s.opacity = o }
	case "stop-opacity":
		if inherit { s.stop_opacity = p.stop_opacity } else if o, ok := svg_parse_opacity(v); ok { s.stop_opacity = o }
	case "flood-opacity":
		if inherit { s.flood_opacity = p.flood_opacity } else if o, ok := svg_parse_opacity(v); ok { s.flood_opacity = o }
	case "fill-rule":
		switch v {
		case "inherit": s.fill_rule = p.fill_rule
		case "evenodd": s.fill_rule = .Evenodd
		case "nonzero": s.fill_rule = .Nonzero
		}
	case "clip-rule":
		switch v {
		case "inherit": s.clip_rule = p.clip_rule
		case "evenodd": s.clip_rule = .Evenodd
		case "nonzero": s.clip_rule = .Nonzero
		}
	case "stroke-width":
		if inherit { s.stroke_width = p.stroke_width } else if l, ok := svg_parse_length(v); ok && l.v >= 0 { s.stroke_width = l }
	case "stroke-linecap":
		switch v {
		case "inherit": s.cap = p.cap
		case "butt":    s.cap = .Butt
		case "round":   s.cap = .Round
		case "square":  s.cap = .Square
		}
	case "stroke-linejoin":
		switch v {
		case "inherit":                     s.join = p.join
		case "miter", "miter-clip", "arcs": s.join = .Miter
		case "round":                       s.join = .Round
		case "bevel":                       s.join = .Bevel
		}
	case "stroke-miterlimit":
		if inherit {
			s.miter_limit = p.miter_limit
		} else {
			i := 0
			if m, ok := svg_scan_number(v, &i); ok && m >= 1 do s.miter_limit = m
		}
	case "stroke-dasharray":
		switch {
		case inherit:   s.dashes = p.dashes
		case v == "none": s.dashes = nil
		case:
			list := make([dynamic]Svg_Length)
			items := v
			for item in strings.split_iterator(&items, ",") {
				words := item
				for word in strings.fields_iterator(&words) {
					l, ok := svg_parse_length(word)
					if !ok do return
					append(&list, l)
				}
			}
			s.dashes = list[:]
		}
	case "stroke-dashoffset":
		if inherit { s.dash_offset = p.dash_offset } else if l, ok := svg_parse_length(v); ok { s.dash_offset = l }
	case "color":
		switch {
		case inherit, v == "currentColor", v == "currentcolor": s.color, s.color_role = p.color, p.color_role
		case:
			if c, ok := svg_parse_color(v); ok do s.color, s.color_role = c, .None
		}
	case "visibility":
		switch v {
		case "inherit":              s.visible = p.visible
		case "visible":              s.visible = true
		case "hidden", "collapse":   s.visible = false
		}
	case "display":
		s.display = p.display if inherit else v != "none"
	case "clip-path":
		s.clip_path = p.clip_path if inherit else svg_url_id(v)
	case "mask":
		s.mask = p.mask if inherit else svg_url_id(v)
	case "filter":
		s.filter = p.filter if inherit else svg_url_id(v)
	case "stop-color":
		if inherit { s.stop_color = p.stop_color } else if paint, ok := svg_parse_paint(v); ok && (paint.kind == .Color || paint.kind == .Current) { s.stop_color = paint }
	case "flood-color":
		if inherit { s.flood_color = p.flood_color } else if paint, ok := svg_parse_paint(v); ok && (paint.kind == .Color || paint.kind == .Current) { s.flood_color = paint }
	case "color-interpolation-filters":
		switch v {
		case "inherit":             s.linear_filters = p.linear_filters
		case "sRGB":                s.linear_filters = false
		case "linearRGB", "auto":   s.linear_filters = true
		}
	case "mask-type":
		s.mask_alpha = p.mask_alpha if inherit else v == "alpha"
	case "lighting-color":
		if inherit { s.lighting_color = p.lighting_color } else if paint, ok := svg_parse_paint(v); ok && (paint.kind == .Color || paint.kind == .Current) { s.lighting_color = paint }
	case "font-family":
		s.font_family = p.font_family if inherit else v
	case "font-weight":
		switch v {
		case "inherit": s.font_weight = p.font_weight
		case "normal":  s.font_weight = 400
		case "bold":    s.font_weight = 700
		case "bolder":  s.font_weight = 400 if p.font_weight < 350 else 700 if p.font_weight < 550 else 900
		case "lighter": s.font_weight = 100 if p.font_weight < 550 else 400 if p.font_weight < 750 else 700
		case:
			i := 0
			if w, ok := svg_scan_number(v, &i); ok && i == len(v) && w >= 1 && w <= 1000 do s.font_weight = w
		}
	case "font-style":
		switch v {
		case "inherit":           s.font_italic = p.font_italic
		case "italic", "oblique": s.font_italic = true
		case "normal":            s.font_italic = false
		}
	case "text-anchor":
		switch v {
		case "inherit": s.anchor = p.anchor
		case "start":   s.anchor = .Start
		case "middle":  s.anchor = .Middle
		case "end":     s.anchor = .End
		}
	case "letter-spacing":
		switch {
		case inherit:       s.letter_spacing = p.letter_spacing
		case v == "normal": s.letter_spacing = {}
		case:
			if l, ok := svg_parse_length(v); ok do s.letter_spacing = l
		}
	case "word-spacing":
		switch {
		case inherit:       s.word_spacing = p.word_spacing
		case v == "normal": s.word_spacing = {}
		case:
			if l, ok := svg_parse_length(v); ok do s.word_spacing = l
		}
	case "xml:space":
		s.preserve_space = p.preserve_space if inherit else v == "preserve"
	case "font-size":
		if inherit {
			s.font_size = p.font_size
		} else if l, ok := svg_parse_length(v); ok {
			switch l.unit {
			case .Px:      s.font_size = l.v
			case .Em:      s.font_size = l.v * p.font_size
			case .Ex:      s.font_size = l.v * p.font_size / 2
			case .Percent: s.font_size = l.v / 100 * p.font_size
			}
		}
	}
}

// Style sheets

@(private)
Svg_Decl :: struct {
	name, value: string,
	important:   bool,
}

@(private)
Svg_Compound :: struct {
	tag, id: string,
	classes: [dynamic]string,
	child:   bool, // joined to the compound before it by '>' (else by a descendant space)
}

@(private)
Svg_Rule :: struct {
	parts: []Svg_Compound,
	spec:  int,
	decls: []Svg_Decl,
}

@(private)
svg_decls :: proc(body: string) -> []Svg_Decl {
	if body == "" do return nil
	out := make([dynamic]Svg_Decl, 0, 4)
	rest := body
	for part in strings.split_iterator(&rest, ";") {
		colon := strings.index_byte(part, ':')
		if colon < 0 do continue
		decl := Svg_Decl{name = strings.trim_space(part[:colon]), value = strings.trim_space(part[colon + 1:])}
		if bang := strings.last_index_byte(decl.value, '!'); bang >= 0 && strings.trim_space(decl.value[bang + 1:]) == "important" {
			decl.important = true
			decl.value = strings.trim_space(decl.value[:bang])
		}
		append(&out, decl)
	}
	return out[:]
}

// svg_sheet reads a style sheet's rules. Selectors it can't match (with
// attributes, pseudo-classes or sibling combinators) are dropped, as are
// at-rules.
@(private)
svg_sheet :: proc(d: ^Svg_Doc, css: string) {
	if strings.trim_space(css) == "" do return
	b := strings.builder_make()
	for i := 0; i < len(css); {
		if i + 1 < len(css) && css[i] == '/' && css[i + 1] == '*' {
			end := strings.index(css[i + 2:], "*/")
			if end < 0 do break
			i += end + 4
			continue
		}
		strings.write_byte(&b, css[i])
		i += 1
	}
	s := strings.to_string(b)
	for i := 0; i < len(s); {
		open := strings.index_byte(s[i:], '{')
		if open < 0 do break
		head := s[i:i + open]
		if semi := strings.last_index_byte(head, ';'); semi >= 0 do head = head[semi + 1:] // after an @import
		head = strings.trim_space(head)
		depth, j := 0, i + open
		for ; j < len(s); j += 1 {
			if s[j] == '{' do depth += 1
			if s[j] == '}' {
				depth -= 1
				if depth == 0 do break
			}
		}
		body := s[i + open + 1:min(j, len(s))]
		i = j + 1
		if strings.has_prefix(head, "@") do continue
		decls := svg_decls(body)
		rest := head
		for sel in strings.split_iterator(&rest, ",") {
			if parts, spec, ok := svg_selector(strings.trim_space(sel)); ok {
				append(&d.rules, Svg_Rule{parts = parts, spec = spec, decls = decls})
			}
		}
	}
}

@(private)
svg_selector :: proc(sel: string) -> (parts: []Svg_Compound, spec: int, ok: bool) {
	ident :: proc(c: u8) -> bool {
		return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c >= 0x80
	}
	out := make([dynamic]Svg_Compound, 0, 2)
	i := 0
	for {
		child := false
		for i < len(sel) && (sel[i] == ' ' || sel[i] == '\t' || sel[i] == '\n' || sel[i] == '\r' || sel[i] == '>') {
			if sel[i] == '>' do child = true
			i += 1
		}
		if i >= len(sel) do break
		if child && len(out) == 0 do return
		c := Svg_Compound{child = child}
		start := i
		compound: for i < len(sel) {
			ch := sel[i]
			switch {
			case ch == '*':
				i += 1
			case ch == '.' || ch == '#':
				i += 1
				from := i
				for i < len(sel) && ident(sel[i]) do i += 1
				if i == from do return
				if ch == '.' {
					append(&c.classes, sel[from:i])
					spec += 100
				} else {
					c.id = sel[from:i]
					spec += 10000
				}
			case ident(ch):
				from := i
				for i < len(sel) && ident(sel[i]) do i += 1
				c.tag = sel[from:i]
				spec += 1
			case ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' || ch == '>':
				break compound
			case:
				return // attribute selectors, pseudo-classes, sibling combinators
			}
		}
		if i == start do return
		append(&out, c)
	}
	if len(out) == 0 do return
	return out[:], spec, true
}

@(private)
svg_selector_matches :: proc(d: ^Svg_Doc, id: xml.Element_ID, parts: []Svg_Compound) -> bool {
	return svg_match_from(d, id, parts, len(parts) - 1)
}

@(private)
svg_match_from :: proc(d: ^Svg_Doc, id: xml.Element_ID, parts: []Svg_Compound, i: int) -> bool {
	if !svg_compound_matches(d, id, &parts[i]) do return false
	if i == 0 do return true
	if id == 0 do return false
	parent := d.x.elements[id].parent
	if parts[i].child do return svg_match_from(d, parent, parts, i - 1)
	for anc := parent; ; anc = d.x.elements[anc].parent {
		if svg_match_from(d, anc, parts, i - 1) do return true
		if anc == 0 do break
	}
	return false
}

@(private)
svg_compound_matches :: proc(d: ^Svg_Doc, id: xml.Element_ID, c: ^Svg_Compound) -> bool {
	e := &d.x.elements[id]
	if c.tag != "" {
		name, ours := svg_local(e.ident)
		if !ours || name != c.tag do return false
	}
	if c.id != "" && svg_attr(e, "id") != c.id do return false
	for want in c.classes {
		classes := svg_attr(e, "class")
		found := false
		for cls in strings.fields_iterator(&classes) {
			if cls == want {
				found = true
				break
			}
		}
		if !found do return false
	}
	return true
}

// Values

@(private)
svg_parse_paint :: proc(v: string) -> (p: Svg_Paint, ok: bool) {
	switch v {
	case "none":                         return {kind = .None}, true
	case "currentColor", "currentcolor": return {kind = .Current}, true
	}
	if strings.has_prefix(v, "url(") {
		close := strings.index_byte(v, ')')
		if close < 0 do return
		p = {kind = .Url, url = svg_url_id(v[:close + 1])}
		switch rest := strings.trim_space(v[close + 1:]); rest {
		case "", "none":                     p.fallback = .None
		case "currentColor", "currentcolor": p.fallback = .Current
		case:
			if c, cok := svg_parse_color(rest); cok {
				p.fallback = .Color
				p.fallback_color = c
			}
		}
		return p, true
	}
	c := svg_parse_color(v) or_return
	return {kind = .Color, color = c}, true
}

@(private)
svg_url_id :: proc(v: string) -> string {
	if !strings.has_prefix(v, "url(") do return ""
	close := strings.index_byte(v, ')')
	if close < 0 do return ""
	inner := strings.trim(strings.trim_space(v[4:close]), "'\"")
	if len(inner) < 2 || inner[0] != '#' do return ""
	return inner[1:]
}

@(private)
svg_parse_opacity :: proc(v: string) -> (o: f32, ok: bool) {
	i := 0
	o = svg_scan_number(v, &i) or_return
	if i < len(v) && v[i] == '%' do o /= 100
	return clamp(o, 0, 1), true
}

// svg_parse_color reads #rgb, #rgba, #rrggbb, #rrggbbaa, rgb(), rgba(),
// hsl(), hsla(), the CSS colour names and `transparent`.
@(private)
svg_parse_color :: proc(value: string) -> (c: [4]f32, ok: bool) {
	v := strings.trim_space(value)
	if v == "" do return
	if v[0] == '#' {
		hex := v[1:]
		n: u32
		for ch in transmute([]u8)hex {
			digit: u32
			switch ch {
			case '0' ..= '9': digit = u32(ch - '0')
			case 'a' ..= 'f': digit = u32(ch - 'a' + 10)
			case 'A' ..= 'F': digit = u32(ch - 'A' + 10)
			case:             return
			}
			n = n << 4 | digit
		}
		nib :: proc(n: u32, shift: u32) -> f32 { return f32((n >> shift) & 0xf) * 17 / 255 }
		byte_ :: proc(n: u32, shift: u32) -> f32 { return f32((n >> shift) & 0xff) / 255 }
		switch len(hex) {
		case 3: return {nib(n, 8), nib(n, 4), nib(n, 0), 1}, true
		case 4: return {nib(n, 12), nib(n, 8), nib(n, 4), nib(n, 0)}, true
		case 6: return {byte_(n, 16), byte_(n, 8), byte_(n, 0), 1}, true
		case 8: return {byte_(n, 24), byte_(n, 16), byte_(n, 8), byte_(n, 0)}, true
		}
		return
	}
	lower := strings.to_lower(v)
	if strings.contains_rune(lower, '(') do return svg_color_function(lower)
	if lower == "transparent" do return {0, 0, 0, 0}, true
	hex := svg_color_name(lower) or_return
	return {f32(hex >> 16 & 0xff) / 255, f32(hex >> 8 & 0xff) / 255, f32(hex & 0xff) / 255, 1}, true
}

@(private)
svg_color_function :: proc(v: string) -> (c: [4]f32, ok: bool) {
	open, close := strings.index_byte(v, '('), strings.last_index_byte(v, ')')
	if open < 0 || close < open do return
	fname := strings.trim_space(v[:open])
	args := v[open + 1:close]
	vals: [4]f32
	pct: [4]bool
	n, i := 0, 0
	for n < 4 {
		for i < len(args) && (args[i] == ' ' || args[i] == ',' || args[i] == '/' || args[i] == '\t') do i += 1
		if i >= len(args) do break
		vals[n] = svg_scan_number(args, &i) or_return
		if i < len(args) && args[i] == '%' {
			pct[n] = true
			i += 1
		}
		for i < len(args) && args[i] >= 'a' && args[i] <= 'z' do i += 1 // deg
		n += 1
	}
	if n < 3 do return
	c.a = 1
	if n == 4 do c.a = clamp(vals[3] / 100 if pct[3] else vals[3], 0, 1)
	switch fname {
	case "rgb", "rgba":
		for k in 0 ..< 3 do c[k] = clamp(vals[k] / 100 if pct[k] else vals[k] / 255, 0, 1)
	case "hsl", "hsla":
		h := vals[0] / 360
		h -= math.floor(h)
		sat, l := clamp(vals[1] / 100, 0, 1), clamp(vals[2] / 100, 0, 1)
		q := l * (1 + sat) if l < 0.5 else l + sat - l * sat
		p := 2 * l - q
		hue :: proc(p, q, t_in: f32) -> f32 {
			t := t_in - math.floor(t_in)
			switch {
			case t < 1.0 / 6: return p + (q - p) * 6 * t
			case t < 0.5:     return q
			case t < 2.0 / 3: return p + (q - p) * (2.0 / 3 - t) * 6
			}
			return p
		}
		c.r, c.g, c.b = hue(p, q, h + 1.0 / 3), hue(p, q, h), hue(p, q, h - 1.0 / 3)
	case:
		return
	}
	return c, true
}

@(private)
svg_parse_length :: proc(v: string) -> (l: Svg_Length, ok: bool) {
	s := strings.trim_space(v)
	i := 0
	n := svg_scan_number(s, &i) or_return
	switch strings.trim_space(s[i:]) {
	case "", "px": return {n, .Px}, true
	case "%":      return {n, .Percent}, true
	case "pt":     return {n * 4.0 / 3, .Px}, true
	case "pc":     return {n * 16, .Px}, true
	case "mm":     return {n * 96 / 25.4, .Px}, true
	case "cm":     return {n * 96 / 2.54, .Px}, true
	case "in":     return {n * 96, .Px}, true
	case "em":     return {n, .Em}, true
	case "ex":     return {n, .Ex}, true
	}
	return
}

@(private)
svg_len :: proc(d: ^Svg_Doc, l: Svg_Length, axis: Svg_Axis, font_size: f32) -> f32 {
	switch l.unit {
	case .Px: return l.v
	case .Em: return l.v * font_size
	case .Ex: return l.v * font_size / 2
	case .Percent:
		switch axis {
		case .X:    return l.v / 100 * d.view.x
		case .Y:    return l.v / 100 * d.view.y
		case .Diag: return l.v / 100 * math.sqrt((d.view.x * d.view.x + d.view.y * d.view.y) / 2)
		}
	}
	return l.v
}

@(private)
svg_attr_len :: proc(d: ^Svg_Doc, e: ^xml.Element, name: string, axis: Svg_Axis, font_size: f32, fallback: f32 = 0) -> f32 {
	return svg_attr_length(d, e, name, axis, font_size, {fallback, .Px})
}

@(private)
svg_attr_length :: proc(d: ^Svg_Doc, e: ^xml.Element, name: string, axis: Svg_Axis, font_size: f32, fallback: Svg_Length) -> f32 {
	v := svg_attr(e, name)
	l, ok := svg_parse_length(v)
	if !ok do l = fallback
	return svg_len(d, l, axis, font_size)
}

// svg_intrinsic is the root's width or height in pixels, if absolute.
@(private)
svg_intrinsic :: proc(e: ^xml.Element, name: string) -> (f32, bool) {
	l, ok := svg_parse_length(svg_attr(e, name))
	if !ok || l.unit == .Percent || l.v <= 0 do return 0, false
	switch l.unit {
	case .Em:           return l.v * 16, true
	case .Ex:           return l.v * 8, true
	case .Px, .Percent:
	}
	return l.v, true
}

// svg_scan_number reads a number after any spaces and commas, advancing
// past it only when there is one ("1.5.5" is two numbers, "1-2" too).
@(private)
svg_scan_number :: proc(s: string, i: ^int) -> (v: f32, ok: bool) {
	svg_skip_separators(s, i)
	j := i^
	if j < len(s) && (s[j] == '-' || s[j] == '+') do j += 1
	digits := 0
	for j < len(s) && s[j] >= '0' && s[j] <= '9' {
		j += 1
		digits += 1
	}
	if j < len(s) && s[j] == '.' {
		j += 1
		for j < len(s) && s[j] >= '0' && s[j] <= '9' {
			j += 1
			digits += 1
		}
	}
	if digits == 0 do return 0, false
	if j < len(s) && (s[j] == 'e' || s[j] == 'E') {
		k := j + 1
		if k < len(s) && (s[k] == '-' || s[k] == '+') do k += 1
		if k < len(s) && s[k] >= '0' && s[k] <= '9' {
			for k < len(s) && s[k] >= '0' && s[k] <= '9' do k += 1
			j = k
		}
	}
	v = svg_parse_f32(s[i^:j])
	i^ = j
	return v, true
}

// svg_parse_f32 reads a well-formed decimal (as svg_scan_number found it).
@(private)
svg_parse_f32 :: proc(s: string) -> f32 {
	i := 0
	neg := false
	if i < len(s) && (s[i] == '-' || s[i] == '+') {
		neg = s[i] == '-'
		i += 1
	}
	mant: f64
	exp := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		mant = mant * 10 + f64(s[i] - '0')
		i += 1
	}
	if i < len(s) && s[i] == '.' {
		i += 1
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			mant = mant * 10 + f64(s[i] - '0')
			exp -= 1
			i += 1
		}
	}
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		i += 1
		eneg := false
		if i < len(s) && (s[i] == '-' || s[i] == '+') {
			eneg = s[i] == '-'
			i += 1
		}
		e := 0
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			e = min(e * 10 + int(s[i] - '0'), 10000)
			i += 1
		}
		exp += -e if eneg else e
	}
	v := mant * math.pow(10, f64(clamp(exp, -330, 330)))
	return f32(-v if neg else v)
}

@(private)
svg_skip_separators :: proc "contextless" (s: string, i: ^int) {
	for i^ < len(s) {
		switch s[i^] {
		case ' ', ',', '\t', '\n', '\r': i^ += 1
		case: return
		}
	}
}

// Transforms

@(private)
svg_transform :: proc(v: string) -> Svg_Xf {
	m := SVG_XF_ID
	i := 0
	for {
		svg_skip_separators(v, &i)
		if i >= len(v) do return m
		start := i
		for i < len(v) && ((v[i] >= 'a' && v[i] <= 'z') || (v[i] >= 'A' && v[i] <= 'Z')) do i += 1
		name := v[start:i]
		for i < len(v) && (v[i] == ' ' || v[i] == '\t' || v[i] == '\n' || v[i] == '\r') do i += 1
		if i >= len(v) || v[i] != '(' do return SVG_XF_ID // malformed: as if there were none
		i += 1
		args: [6]f32
		n := 0
		for n < 6 {
			a, ok := svg_scan_number(v, &i)
			if !ok do break
			args[n] = a
			n += 1
		}
		svg_skip_separators(v, &i)
		if i >= len(v) || v[i] != ')' do return SVG_XF_ID
		i += 1
		t: Svg_Xf
		switch name {
		case "matrix":
			if n != 6 do return SVG_XF_ID
			t = args
		case "translate":
			if n != 1 && n != 2 do return SVG_XF_ID
			t = svg_xf_translate(args[0], args[1] if n == 2 else 0)
		case "scale":
			if n != 1 && n != 2 do return SVG_XF_ID
			t = {args[0], 0, 0, args[1] if n == 2 else args[0], 0, 0}
		case "rotate":
			if n != 1 && n != 3 do return SVG_XF_ID
			a := args[0] * math.PI / 180
			cs, sn := math.cos(a), math.sin(a)
			t = {cs, sn, -sn, cs, 0, 0}
			if n == 3 do t = svg_xf_mul(svg_xf_mul(svg_xf_translate(args[1], args[2]), t), svg_xf_translate(-args[1], -args[2]))
		case "skewX":
			if n != 1 do return SVG_XF_ID
			t = {1, 0, math.tan(args[0] * math.PI / 180), 1, 0, 0}
		case "skewY":
			if n != 1 do return SVG_XF_ID
			t = {1, math.tan(args[0] * math.PI / 180), 0, 1, 0, 0}
		case:
			return SVG_XF_ID
		}
		m = svg_xf_mul(m, t)
	}
}

// svg_xf_mul is m after n: points go through n first.
@(private)
svg_xf_mul :: proc "contextless" (m, n: Svg_Xf) -> Svg_Xf {
	return {
		m[0] * n[0] + m[2] * n[1],
		m[1] * n[0] + m[3] * n[1],
		m[0] * n[2] + m[2] * n[3],
		m[1] * n[2] + m[3] * n[3],
		m[0] * n[4] + m[2] * n[5] + m[4],
		m[1] * n[4] + m[3] * n[5] + m[5],
	}
}

@(private)
svg_xf_apply :: proc "contextless" (m: Svg_Xf, p: [2]f32) -> [2]f32 {
	return {m[0] * p.x + m[2] * p.y + m[4], m[1] * p.x + m[3] * p.y + m[5]}
}

@(private)
svg_xf_translate :: proc "contextless" (x, y: f32) -> Svg_Xf {
	return {1, 0, 0, 1, x, y}
}

@(private)
svg_xf_inverse :: proc "contextless" (m: Svg_Xf) -> (inv: Svg_Xf, ok: bool) {
	det := m[0] * m[3] - m[1] * m[2]
	if abs(det) < 1e-12 do return
	k := 1 / det
	a, b, c, d := m[3] * k, -m[1] * k, -m[2] * k, m[0] * k
	return {a, b, c, d, -(a * m[4] + c * m[5]), -(b * m[4] + d * m[5])}, true
}

// svg_xf_scale is the most the transform stretches any length.
@(private)
svg_xf_scale :: proc "contextless" (m: Svg_Xf) -> f32 {
	e := m[0] * m[0] + m[1] * m[1] + m[2] * m[2] + m[3] * m[3]
	det := m[0] * m[3] - m[1] * m[2]
	return math.sqrt((e + math.sqrt(max(e * e - 4 * det * det, 0))) / 2)
}

@(private)
Svg_Align :: struct {
	x, y:        f32, // 0, 0.5 or 1
	none, slice: bool,
}

@(private)
svg_aspect :: proc(v: string) -> Svg_Align {
	a := Svg_Align{x = 0.5, y = 0.5}
	rest := v
	for tok in strings.fields_iterator(&rest) {
		switch tok {
		case "none":  a.none = true
		case "slice": a.slice = true
		case "defer", "meet":
		case:
			if len(tok) != 8 || tok[0] != 'x' || tok[4] != 'Y' do continue
			pos :: proc(s: string) -> f32 { return 0 if s == "Min" else 1 if s == "Max" else 0.5 }
			a.x, a.y = pos(tok[1:4]), pos(tok[5:8])
		}
	}
	return a
}

// svg_fit maps the viewBox `vb` onto `rect`.
@(private)
svg_fit :: proc "contextless" (vb, rect: [4]f32, a: Svg_Align) -> Svg_Xf {
	sx, sy := rect[2] / vb[2], rect[3] / vb[3]
	if !a.none {
		s := max(sx, sy) if a.slice else min(sx, sy)
		sx, sy = s, s
	}
	tx, ty := rect[0] - vb[0] * sx, rect[1] - vb[1] * sy
	if !a.none {
		tx += (rect[2] - vb[2] * sx) * a.x
		ty += (rect[3] - vb[3] * sy) * a.y
	}
	return {sx, 0, 0, sy, tx, ty}
}

@(private)
svg_viewbox :: proc(e: ^xml.Element) -> (vb: [4]f32, ok: bool) {
	v := svg_attr(e, "viewBox")
	if v == "" do return
	i := 0
	for k in 0 ..< 4 do vb[k] = svg_scan_number(v, &i) or_return
	return vb, vb[2] > 0 && vb[3] > 0
}

// XML

@(private)
svg_attr :: proc(e: ^xml.Element, name: string) -> string {
	for a in e.attribs do if a.key == name do return a.val
	return ""
}

@(private)
svg_href :: proc(e: ^xml.Element) -> string {
	for a in e.attribs do if a.key == "href" || a.key == "xlink:href" do return strings.trim_space(a.val)
	return ""
}

// svg_ref finds the element a local reference ("#id") names.
@(private)
svg_ref :: proc(d: ^Svg_Doc, href: string) -> (xml.Element_ID, bool) {
	if len(href) < 2 || href[0] != '#' do return 0, false
	return d.ids[href[1:]]
}

// svg_local is an element's name without the svg prefix; `ours` is false
// for other namespaces (an editor's own, RDF metadata).
@(private)
svg_local :: proc(ident: string) -> (name: string, ours: bool) {
	colon := strings.index_byte(ident, ':')
	if colon < 0 do return ident, true
	if ident[:colon] == "svg" do return ident[colon + 1:], true
	return ident, false
}

@(private)
svg_name :: proc(d: ^Svg_Doc, id: xml.Element_ID) -> string {
	name, ours := svg_local(d.x.elements[id].ident)
	return name if ours else ""
}

@(private)
svg_kind_of :: proc(name: string) -> Svg_Kind {
	switch name {
	case "svg":      return .Svg
	case "g", "a":   return .G
	case "use":      return .Use
	case "switch":   return .Switch
	case "path":     return .Path
	case "rect":     return .Rect
	case "circle":   return .Circle
	case "ellipse":  return .Ellipse
	case "line":     return .Line
	case "polyline": return .Polyline
	case "polygon":  return .Polygon
	case "image":    return .Image
	case "text":     return .Text
	}
	return .Other
}

@(private)
svg_color_name :: proc(name: string) -> (hex: u32, ok: bool) {
	switch name {
	case "aliceblue": return 0xf0f8ff, true
	case "antiquewhite": return 0xfaebd7, true
	case "aqua", "cyan": return 0x00ffff, true
	case "aquamarine": return 0x7fffd4, true
	case "azure": return 0xf0ffff, true
	case "beige": return 0xf5f5dc, true
	case "bisque": return 0xffe4c4, true
	case "black": return 0x000000, true
	case "blanchedalmond": return 0xffebcd, true
	case "blue": return 0x0000ff, true
	case "blueviolet": return 0x8a2be2, true
	case "brown": return 0xa52a2a, true
	case "burlywood": return 0xdeb887, true
	case "cadetblue": return 0x5f9ea0, true
	case "chartreuse": return 0x7fff00, true
	case "chocolate": return 0xd2691e, true
	case "coral": return 0xff7f50, true
	case "cornflowerblue": return 0x6495ed, true
	case "cornsilk": return 0xfff8dc, true
	case "crimson": return 0xdc143c, true
	case "darkblue": return 0x00008b, true
	case "darkcyan": return 0x008b8b, true
	case "darkgoldenrod": return 0xb8860b, true
	case "darkgray", "darkgrey": return 0xa9a9a9, true
	case "darkgreen": return 0x006400, true
	case "darkkhaki": return 0xbdb76b, true
	case "darkmagenta": return 0x8b008b, true
	case "darkolivegreen": return 0x556b2f, true
	case "darkorange": return 0xff8c00, true
	case "darkorchid": return 0x9932cc, true
	case "darkred": return 0x8b0000, true
	case "darksalmon": return 0xe9967a, true
	case "darkseagreen": return 0x8fbc8f, true
	case "darkslateblue": return 0x483d8b, true
	case "darkslategray", "darkslategrey": return 0x2f4f4f, true
	case "darkturquoise": return 0x00ced1, true
	case "darkviolet": return 0x9400d3, true
	case "deeppink": return 0xff1493, true
	case "deepskyblue": return 0x00bfff, true
	case "dimgray", "dimgrey": return 0x696969, true
	case "dodgerblue": return 0x1e90ff, true
	case "firebrick": return 0xb22222, true
	case "floralwhite": return 0xfffaf0, true
	case "forestgreen": return 0x228b22, true
	case "fuchsia", "magenta": return 0xff00ff, true
	case "gainsboro": return 0xdcdcdc, true
	case "ghostwhite": return 0xf8f8ff, true
	case "gold": return 0xffd700, true
	case "goldenrod": return 0xdaa520, true
	case "gray", "grey": return 0x808080, true
	case "green": return 0x008000, true
	case "greenyellow": return 0xadff2f, true
	case "honeydew": return 0xf0fff0, true
	case "hotpink": return 0xff69b4, true
	case "indianred": return 0xcd5c5c, true
	case "indigo": return 0x4b0082, true
	case "ivory": return 0xfffff0, true
	case "khaki": return 0xf0e68c, true
	case "lavender": return 0xe6e6fa, true
	case "lavenderblush": return 0xfff0f5, true
	case "lawngreen": return 0x7cfc00, true
	case "lemonchiffon": return 0xfffacd, true
	case "lightblue": return 0xadd8e6, true
	case "lightcoral": return 0xf08080, true
	case "lightcyan": return 0xe0ffff, true
	case "lightgoldenrodyellow": return 0xfafad2, true
	case "lightgray", "lightgrey": return 0xd3d3d3, true
	case "lightgreen": return 0x90ee90, true
	case "lightpink": return 0xffb6c1, true
	case "lightsalmon": return 0xffa07a, true
	case "lightseagreen": return 0x20b2aa, true
	case "lightskyblue": return 0x87cefa, true
	case "lightslategray", "lightslategrey": return 0x778899, true
	case "lightsteelblue": return 0xb0c4de, true
	case "lightyellow": return 0xffffe0, true
	case "lime": return 0x00ff00, true
	case "limegreen": return 0x32cd32, true
	case "linen": return 0xfaf0e6, true
	case "maroon": return 0x800000, true
	case "mediumaquamarine": return 0x66cdaa, true
	case "mediumblue": return 0x0000cd, true
	case "mediumorchid": return 0xba55d3, true
	case "mediumpurple": return 0x9370db, true
	case "mediumseagreen": return 0x3cb371, true
	case "mediumslateblue": return 0x7b68ee, true
	case "mediumspringgreen": return 0x00fa9a, true
	case "mediumturquoise": return 0x48d1cc, true
	case "mediumvioletred": return 0xc71585, true
	case "midnightblue": return 0x191970, true
	case "mintcream": return 0xf5fffa, true
	case "mistyrose": return 0xffe4e1, true
	case "moccasin": return 0xffe4b5, true
	case "navajowhite": return 0xffdead, true
	case "navy": return 0x000080, true
	case "oldlace": return 0xfdf5e6, true
	case "olive": return 0x808000, true
	case "olivedrab": return 0x6b8e23, true
	case "orange": return 0xffa500, true
	case "orangered": return 0xff4500, true
	case "orchid": return 0xda70d6, true
	case "palegoldenrod": return 0xeee8aa, true
	case "palegreen": return 0x98fb98, true
	case "paleturquoise": return 0xafeeee, true
	case "palevioletred": return 0xdb7093, true
	case "papayawhip": return 0xffefd5, true
	case "peachpuff": return 0xffdab9, true
	case "peru": return 0xcd853f, true
	case "pink": return 0xffc0cb, true
	case "plum": return 0xdda0dd, true
	case "powderblue": return 0xb0e0e6, true
	case "purple": return 0x800080, true
	case "rebeccapurple": return 0x663399, true
	case "red": return 0xff0000, true
	case "rosybrown": return 0xbc8f8f, true
	case "royalblue": return 0x4169e1, true
	case "saddlebrown": return 0x8b4513, true
	case "salmon": return 0xfa8072, true
	case "sandybrown": return 0xf4a460, true
	case "seagreen": return 0x2e8b57, true
	case "seashell": return 0xfff5ee, true
	case "sienna": return 0xa0522d, true
	case "silver": return 0xc0c0c0, true
	case "skyblue": return 0x87ceeb, true
	case "slateblue": return 0x6a5acd, true
	case "slategray", "slategrey": return 0x708090, true
	case "snow": return 0xfffafa, true
	case "springgreen": return 0x00ff7f, true
	case "steelblue": return 0x4682b4, true
	case "tan": return 0xd2b48c, true
	case "teal": return 0x008080, true
	case "thistle": return 0xd8bfd8, true
	case "tomato": return 0xff6347, true
	case "turquoise": return 0x40e0d0, true
	case "violet": return 0xee82ee, true
	case "wheat": return 0xf5deb3, true
	case "white": return 0xffffff, true
	case "whitesmoke": return 0xf5f5f5, true
	case "yellow": return 0xffff00, true
	case "yellowgreen": return 0x9acd32, true
	}
	return 0, false
}
