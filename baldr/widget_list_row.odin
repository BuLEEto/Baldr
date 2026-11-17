package baldr

// A full-width row for a list or a popover's page: a control centre's power
// menu, its sound outputs, networks and devices.

import "base:runtime"
import "core:fmt"
import "core:strings"

// Row_End is what a list_row shows at its end, after its value: a check
// while it is on (the device in use), a switch showing it (a tunnel), or a
// chevron (a page to open).
Row_End :: enum u8 { None, Check, Switch, Chevron }

LIST_ROW_MIN_H :: f32(38)

// Row_Variant is how a list_row shows its icon: plain before its label, or
// in a tile (a launcher's results), an app's own icon filling it, an icon or
// glyph on a quiet tile, or on one tinted with the accent (a calculator), or
// in a circle (`Avatar`: a chat app's conversation list). `Avatar` keeps a
// mixed list lined up: a picture at the tile's 36 px beside an initial at an
// icon's 16 would start the labels at different places, so the leading slot
// is one circle whatever it holds.
Row_Variant :: enum u8 { Plain, Tile, Accent, Avatar }

// Row_Size is how big a list_row's label is: Regular, or Large (a
// calculator's answer).
Row_Size :: enum u8 { Regular, Large }

// A tiled row's measures (the launcher design): its tile, the icons in it,
// its corners and padding, its label and detail, and a selected row's accent
// behind it and bar at its start, inset from its top and bottom.
LIST_ROW_TILE          :: f32(36)
LIST_ROW_TILE_RADIUS   :: f32(9)
LIST_ROW_TILE_APP_ICON :: f32(32)
LIST_ROW_TILE_ICON     :: f32(18)
LIST_ROW_TILE_GLYPH    :: f32(22)
LIST_ROW_TILED_RADIUS  :: f32(10)
LIST_ROW_TILED_GAP     :: f32(13)
LIST_ROW_TILED_PADDING :: [4]f32{9, 12, 9, 12}
LIST_ROW_TITLE         :: f32(14)
LIST_ROW_TITLE_LARGE   :: f32(23)
LIST_ROW_DETAIL        :: f32(12.5)
LIST_ROW_SELECTED      :: f32(0.16)
LIST_ROW_ACCENT_TILE   :: f32(0.18)
LIST_ROW_BAR           :: f32(3)
LIST_ROW_BAR_INSET     :: f32(9)
LIST_ROW_BADGE         :: f32(18) // the unread pill: a circle at one digit

// list_row is one full-width row: at its start `icon`, or `theme_icon` (an
// icon theme's, `icon` standing in when the theme has none), or `glyph` (an
// emoji or a letter), or `image` (a decoded picture, which takes precedence:
// cropped to fill its variant's leading slot, round unless `image_round =
// false`; pass the initial as `glyph` too for a contact with no picture);
// then the label with a quieter `detail` under it (`detail_mark`: the byte
// range a search matched, drawn in full colour and heavier); at its end
// `value` ("Connected", "80 %"), an `unread` pill and what `end` asks for,
// `on` saying whether a check or switch shows on. `variant` puts the icon in
// a tile and `size = .Large` makes the label big. `selected` marks it the
// list's current row, the accent behind it and a bar at its start, without
// moving focus, so a search field walking its results keeps it (and names the
// row with set_active_item), and shows `hint` at its end ("↵ open": its first
// word in a keycap). The whole row is one control: a click, Enter or Space
// queues `on_click`, a right-click or the Menu key `on_context`, and what
// sits at its end is part of it, not a control of its own; Up and Down walk
// rows inside a popover. Role Button, or Radio (.Check) or Switch (.Switch)
// with Checked while on, Selected while selected; named by its label and
// described by its detail, value and unread count.
list_row :: proc(ui: ^Ui($Msg), label: string, on_click: Msg, icon: Icon = .None, theme_icon := "", glyph := "",
	image: ^Image = nil, image_round := true, detail := "", detail_mark: [2]int = {},
	unread: int = 0, value := "",
	end: Row_End = .None, on := false, selected := false, hint := "", variant: Row_Variant = .Plain, size: Row_Size = .Regular,
	disabled := false, on_context: Maybe(Msg) = nil, tag: u64 = 0, key: u64 = 0, loc := #caller_location) -> Node {
	n, created := reconcile_child(ui, .Box, key, loc)
	t := &ui.tree
	th := &t.theme
	d := node_get(t, n)
	if created do d.flags += {.Focusable}
	role: Role = .Button
	#partial switch end {
	case .Check:  role = .Radio
	case .Switch: role = .Switch
	}
	d.access.role = role
	d.tag = tag
	set_name(t, n, label)
	// The unread count is part of what the row *is*, so a screen reader
	// hears it: the accent pill is no use to someone who cannot see it.
	unread_said := ""
	if unread > 0 do unread_said = fmt.tprintf("%d unread", unread)
	switch {
	case detail != "" && value != "": set_describe(t, n, join_parts(detail, value, unread_said))
	case detail != "":                set_describe(t, n, join_parts(detail, unread_said))
	case:                             set_describe(t, n, join_parts(value, unread_said))
	}
	set_checked(t, n, on && (end == .Check || end == .Switch))
	set_disabled(t, n, disabled)
	was := .Selected in d.access.states
	if selected { d.access.states += {.Selected} } else { d.access.states -= {.Selected} }
	if selected != was do mark_paint_dirty(t, n)
	tiled := variant != .Plain
	lk := list_row_look(th)
	rv := lk.tiled if tiled else lk.plain
	min_h := max(lk.min_height, target_min(t).y)
	set_layout(t, n, Layout_Props{axis = .Row, align = .Center, gap = rv.gap, padding = rv.padding, min_h = min_h})
	st := d.style
	st.radius = rv.radius
	st.bg = lk.selected_fill if selected else {}
	set_style(t, n, st)
	// The bar marks the row the list is on and a row with something unread
	// in it: both are "look here".
	marked := selected || unread > 0
	if marked || n in t.button_marks { // the bar at its start: drawn as a button's mark is, easing in and out
		h := d.abs.h if d.abs.h > 0 else max(min_h, lk.tile.size + lk.tiled.padding[0] + lk.tiled.padding[2] if tiled else min_h)
		bar := Button_Mark{side = .Left, length = max(h - 2 * lk.indicator_inset, 0) if marked else 0, thickness = lk.indicator_width, color = lk.indicator}
		if use := t.button_marks[n]; use.mark != bar {
			use.mark = bar
			t.button_marks[n] = use
			mark_paint_dirty(t, n)
		}
	}
	ui.clicks[n] = on_click
	if m, has := on_context.?; has { ui.context_clicks[n] = m } else { delete_key(&ui.context_clicks, n) } // its menu

	open_scope(ui, n, loc)
	if tiled {
		tile := box(ui, width = lk.tile.size, height = lk.tile.size, radius = lk.tile.radius, key = u64(Control_Part.Tile), loc = loc)
		set_role(t, tile, .None)
		set_layout(t, tile, Layout_Props{axis = .Row, align = .Center, justify = .Center, width = lk.tile.size, height = lk.tile.size})
		ts := node_get(t, tile).style
		round := variant == .Avatar
		ts.radius, ts.bg, ts.border_w, ts.border = lk.tile.size / 2 if round else lk.tile.radius, {}, 0, {}
		ink := lk.tile.ink
		switch {
		case variant == .Accent:
			ts.bg = lk.tile.accent_fill
			ink = lk.tile.accent_ink
		case image != nil: // a contact's avatar fills its slot, as an app's icon does
		case theme_icon != "": // an app's own icon fills its tile
		case glyph != "":
			ts.bg = lk.tile.fill
		case:
			ts.bg = lk.tile.fill
			// A circle reads as a place for a face whether or not one has
			// loaded, so it needs no outline; a square tile does.
			if !round { ts.border_w, ts.border = 1, lk.tile.border }
		}
		set_style(t, tile, ts)
		open_scope(ui, tile, loc)
		switch {
		case image != nil:
			baldr_image(ui, image, lk.tile.size, lk.tile.size / 2 if image_round else lk.tile.radius, loc, key = u64(Control_Part.Avatar))
		case variant == .Avatar && glyph == "" && theme_icon == "" && icon == .None:
		case theme_icon != "":
			baldr_theme_icon(ui, theme_icon, lk.tile.app_icon_size if variant != .Accent else lk.tile.icon_size, ink if variant == .Accent else lk.ink, loc, key = u64(Control_Part.Theme_Icon), fallback = icon)
		case glyph != "":
			g := text(ui, glyph, size = lk.tile.glyph_size, color = ink, nowrap = true, key = u64(Control_Part.Label), loc = loc)
			set_role(t, g, .None)
		case icon != .None:
			baldr_icon(ui, icon, lk.tile.icon_size, ink, loc, key = u64(Control_Part.Icon))
		}
		close_scope(ui)
	} else if image != nil {
		// A plain row's leading slot is an icon's size, so a picture in it is
		// too: a bigger one would push the label out of line with the rows
		// around it. A real avatar is `variant = .Avatar`.
		baldr_image(ui, image, lk.icon_size, lk.icon_size / 2 if image_round else lk.image_radius, loc, key = u64(Control_Part.Avatar))
	} else {
		if icon != .None && theme_icon == "" do baldr_icon(ui, icon, lk.icon_size, lk.ink, loc, key = u64(Control_Part.Icon))
		if theme_icon != "" do baldr_theme_icon(ui, theme_icon, lk.icon_size, lk.ink, loc, key = u64(Control_Part.Theme_Icon), fallback = icon)
		if glyph != "" {
			g := text(ui, glyph, size = lk.icon_size, color = lk.ink, nowrap = true, key = u64(Control_Part.Image), loc = loc)
			set_role(t, g, .None)
		}
	}
	words := column(ui, flex = 1, key = u64(Control_Part.Label), loc = loc)
	set_role(t, words, .None)
	tt := lk.title_large if size == .Large else rv.title
	lbl := text(ui, label, role = tt.role, size = tt.size, color = lk.ink, nowrap = true, ellipsis = .End, weight = tt.weight,
		family = look_family(t, tt.family), loc = loc)
	set_role(t, lbl, .None) // the row carries the name
	if detail != "" {
		// An unread row's last message is drawn in the ordinary text
		// colour, not the muted one: the row is saying there is something
		// here to read.
		dt := rv.detail
		dfam := look_family(t, dt.family)
		dink := lk.detail_ink if unread == 0 else lk.ink
		lo, hi := detail_mark[0], detail_mark[1]
		marked_text := lo >= 0 && hi > lo && hi <= len(detail)
		if !marked_text {
			det := text(ui, detail, role = dt.role, size = dt.size, color = dink, weight = dt.weight, family = dfam, nowrap = true, ellipsis = .End, loc = loc)
			set_role(t, det, .None)
		} else {
			// A search result shows *why* it matched, so the matched words
			// are drawn in the full colour and a heavier weight while the
			// rest stays quiet. Trim the snippet around the match before
			// passing it: this is one line, and what does not fit is cut
			// from the end as any row's detail is.
			dr := row(ui, gap = 0, align = .Center, key = u64(Control_Part.Hint) + 1, loc = loc)
			set_role(t, dr, .None)
			part :: proc(ui: ^Ui($Msg), s: string, tl: Text_Look, family: Family_Id, color: Color, fx: f32, key: u64, loc: runtime.Source_Code_Location) {
				if s == "" do return
				x := text(ui, s, role = tl.role, size = tl.size, color = color, weight = tl.weight, family = family, nowrap = true, ellipsis = .End, flex = fx, loc = loc, key = key)
				set_role(&ui.tree, x, .None)
			}
			heavy := dt
			heavy.weight = .Semibold
			part(ui, detail[:lo], dt, dfam, dink, 0, 1, loc)
			part(ui, detail[lo:hi], heavy, dfam, lk.ink, 0, 2, loc)
			part(ui, detail[hi:], dt, dfam, dink, 1, 3, loc)
			close_scope(ui) // `end` is this builder's Row_End parameter here
		}
	}
	close_scope(ui)
	if value != "" {
		v := text(ui, value, color = th.color.accent_text if unread > 0 else lk.detail_ink,
			nowrap = true, key = u64(Control_Part.Value), loc = loc)
		set_role(t, v, .None)
	}
	if unread > 0 {
		// "99+" past ninety-nine: a count wider than that stops being a
		// count and starts being a column.
		n_txt := fmt.tprintf("%d", unread) if unread <= 99 else "99+"
		b, b_made := reconcile_child(ui, .Box, u64(Control_Part.Avatar) + 1, loc)
		bd := node_get(t, b)
		if b_made do bd.access.role = .None // the row says "3 unread" in its description
		pad := f32(0) if len(n_txt) <= 1 else lk.badge.padding_x // a single digit is a circle, not a stretched pill
		set_layout(t, b, Layout_Props{axis = .Row, align = .Center, justify = .Center,
			min_w = lk.badge.size, height = lk.badge.size, padding = {0, pad, 0, pad}})
		bs := bd.style
		bs.bg = lk.badge.fill
		bs.radius = lk.badge.radius
		set_style(t, b, bs)
		open_scope(ui, b, loc)
		bt := lk.badge.text
		bl := text(ui, n_txt, role = bt.role, size = bt.size, color = lk.badge.ink, weight = bt.weight, family = look_family(t, bt.family), nowrap = true, loc = loc)
		set_role(t, bl, .None)
		close_scope(ui)
	}
	switch end {
	case .None:
	case .Check:
		if on do baldr_icon(ui, .Check, lk.icon_size, th.color.accent_text, loc, key = u64(Control_Part.End))
	case .Chevron:
		baldr_icon(ui, .Chevron_Right, lk.icon_size, th.color.on_surface_muted, loc, key = u64(Control_Part.End))
	case .Switch:
		// The switch's size is the theme's toggle, so a row's matches a form's.
		tl := toggle_look(th)
		tsize := [2]f32{tl.track_width, tl.track_height}
		track, tc := reconcile_child(ui, .Custom, u64(Control_Part.End), loc)
		td := node_get(t, track)
		if ck, ok := td.kind.(Custom_Kind); tc || !ok || ck.size != tsize {
			td.kind = Custom_Kind{size = tsize, paint = paint_toggle, overhang = 7} // it draws the row's Checked state
			mark_layout_dirty(t, track)
		}
		mark_paint_dirty(t, track)
	}
	if selected && hint != "" { // "↵ open": the key in a cap, then what it does
		cap, verb := hint, ""
		if i := strings.index_byte(hint, ' '); i > 0 do cap, verb = hint[:i], strings.trim_space(hint[i + 1:])
		hl := lk.hint
		h := row(ui, gap = hl.gap, align = .Center, key = u64(Control_Part.Hint), loc = loc)
		set_role(t, h, .None)
		kc := box(ui, height = hl.keycap_height, radius = hl.keycap_radius, bg = hl.keycap_fill, key = 1, loc = loc)
		set_role(t, kc, .None)
		set_layout(t, kc, Layout_Props{axis = .Row, align = .Center, justify = .Center, height = hl.keycap_height, min_w = hl.keycap_height,
			padding = {0, hl.keycap_padding_x, 0, hl.keycap_padding_x}})
		ks := node_get(t, kc).style
		ks.border_w, ks.border = 1, hl.keycap_border
		set_style(t, kc, ks)
		open_scope(ui, kc, loc)
		kt := hl.keycap_text
		ct := text(ui, cap, role = kt.role, size = kt.size, color = lk.detail_ink, weight = kt.weight, family = look_family(t, kt.family), nowrap = true, key = 1, loc = loc)
		set_role(t, ct, .None)
		close_scope(ui)
		if verb != "" {
			vt := text(ui, verb, role = hl.text.role, size = hl.text.size, color = lk.detail_ink, weight = hl.text.weight, family = look_family(t, hl.text.family), nowrap = true, key = 2, loc = loc)
			set_role(t, vt, .None)
		}
		close_scope(ui)
	}
	close_scope(ui)
	return n
}

// A selected row's hint: its keycap's height, corners, fill and text, and the verb beside it.
LIST_ROW_KEYCAP        :: f32(19)
LIST_ROW_KEYCAP_RADIUS :: f32(5)
LIST_ROW_KEYCAP_FILL   :: f32(0.07)
LIST_ROW_KEYCAP_TEXT   :: f32(11)
LIST_ROW_HINT_TEXT     :: f32(12)
LIST_ROW_HINT_GAP      :: f32(7)

// join_parts joins the non-empty parts with ", ", for a row's description.
@(private)
join_parts :: proc(parts: ..string) -> string {
	out: [8]string
	n := 0
	for p in parts {
		if p == "" || n >= len(out) do continue
		out[n] = p
		n += 1
	}
	if n == 0 do return ""
	return strings.join(out[:n], ", ", context.temp_allocator)
}
