package baldr

// styled_text — a paragraph of styled runs the **app** built.
//
// For text that is not CommonMark (`markdown_view`'s input): a chat's own
// flavour — `*bold*`, `_italic_`, `~strike~`, `` `code` ``, auto-linked
// URLs, where CommonMark reads `*x*` as italic and has no strike — parsed
// and cached by the app. It takes text plus `[]Run`, laid
// out as one wrapped paragraph, selectable, copyable as plain text across
// the runs, with a click on a link run reaching `update`.
//
// The whole paragraph is laid out once through the same `rich_layout` the
// editors and `markdown_view` use, and painted through the same
// `rich_draw_lines`, so it wraps inside runs (a row of `text` nodes would
// wrap only between them) and a link, inline code or strike looks the same
// as in an editor.
//
// A run is `Run` from document.odin: the byte it ends at, its `Attrs`
// (Bold, Italic, Underline, Strike, Code, Link, Highlight) and, for a link,
// its `href`. There is no per-run colour: that would widen a core type for
// one widget.

import "core:strings"

// Styled_State is one styled_text's: the text and runs it owns, the layout
// it last built, and what is selected.
@(private)
Styled_State :: struct {
	text:   string, // owned by the tree allocator
	runs:   []Run,  // owned, hrefs included
	lay:    Rich_Layout,
	lay_w:  f32, // the width `lay` was wrapped at
	lay_sz: f32, // …and the size it was built at
	have:   bool,
	size:   f32,
	// What it is drawn in. `ink` zero is the theme's on_surface and the
	// rest follow from it (styled_ink); styled_text_options overrides any
	// of them outright.
	ink:   Color,
	on:    Color,
	pal:   Styled_Palette,
	pal_set: bit_set[Styled_Part],
	// The selection, in bytes of `text`. anchor == caret is no selection.
	anchor, caret: int,
	dragging:      bool,
}

@(private)
styled_state_destroy :: proc(t: ^Tree, s: ^Styled_State) {
	rich_free(&s.lay, t.allocator) // a stale layout is still held
	delete(s.text, t.allocator)
	for r in s.runs do if len(r.href) > 0 do delete(r.href, t.allocator)
	delete(s.runs, t.allocator)
	s^ = {}
}

// styled_runs_same says whether the runs a build gave are the ones already
// held, so a chat that rebuilds every frame does not re-clone every bubble.
@(private)
styled_runs_same :: proc(a, b: []Run) -> bool {
	if len(a) != len(b) do return false
	for r, i in a do if r.end != b[i].end || r.attrs != b[i].attrs || r.href != b[i].href do return false
	return true
}

// styled_text lays `text` out as one wrapped paragraph in `runs`' styles.
// `runs` cover the bytes in order — each up to its `end` — and an empty
// `runs` is plain text. Both are copied, so the app may free or rebuild
// them; nothing is kept beyond the call.
//
// `on_link` is sent the run's `href` when a link run is clicked. The app
// decides what that means: `open_url` for an http one, something of its own
// for a scheme only it knows.
//
// The text is selectable with the pointer and copies as **plain text**
// across runs — the styles are how it is drawn, not what it is.
//
//	runs := []baldr.Run{{end = 5, attrs = {.Bold}}, {end = 11}}
//	baldr.styled_text(ui, "Hello world", runs)
styled_text :: proc(ui: ^Ui($Msg), text: string, runs: []Run = nil,
	on_link: Handler(Msg, string) = nil, role: Text_Role = .Body, size: f32 = 0,
	ink: Color = {}, on: Color = {},
	width: f32 = 0, max_width: f32 = 0, flex: f32 = 0, label: string = "",
	key: u64 = 0, loc := #caller_location) -> Node {
	n, created := reconcile_child(ui, .Custom, key, loc)
	t := &ui.tree
	th := &t.theme
	d := node_get(t, n)
	if created {
		d.access.role = .Text
		// A press gives it the keyboard, so Ctrl+C copies the selection
		// (set_focus silently refuses a node that is not focusable); Tab does
		// not stop on it (unlike `markdown_view`), because a chat has a
		// paragraph per message and dozens of stops would bury the composer.
		// The keyboard reaches the text through the app's per-message Copy.
		d.flags += {.Focusable, .Pointer_Only_Focus}
		t.styled[n] = Styled_State{}
	}
	s := &t.styled[n]
	if s == nil do return n

	if s.ink != ink || s.on != on {
		s.ink, s.on = ink, on
		mark_paint_dirty(t, n)
	}
	px := size if size > 0 else text_style(th, role).size
	if s.size != px {
		s.size = px
		s.have = false
	}
	if s.text != text {
		delete(s.text, t.allocator)
		s.text = strings.clone(text, t.allocator)
		s.have = false
		s.anchor, s.caret = 0, 0 // a bubble whose text changed has no old selection
		mark_layout_dirty(t, n)
	}
	if !styled_runs_same(s.runs, runs) {
		for r in s.runs do if len(r.href) > 0 do delete(r.href, t.allocator)
		delete(s.runs, t.allocator)
		s.runs = make([]Run, len(runs), t.allocator)
		for r, i in runs {
			s.runs[i] = r
			if len(r.href) > 0 do s.runs[i].href = strings.clone(r.href, t.allocator)
		}
		s.have = false
		mark_layout_dirty(t, n)
	}

	if handler_live(on_link) { ui.on_link[n] = on_link } else { delete_key(&ui.on_link, n) }
	set_name(t, n, label if label != "" else text)
	d.kind = Custom_Kind{paint = styled_paint, measure = measure_styled, user = nil}
	set_layout(t, n, Layout_Props{width = width, max_w = max_width, flex = flex})
	return n
}

// styled_layout rebuilds the paragraph's layout when the width, the size or
// the text has changed, and hands back what is there otherwise. The layout
// is the tree's, not the frame's: a chat holds hundreds of these, and
// re-laying all of them every frame is too slow.
@(private)
styled_layout :: proc(t: ^Tree, n: Node, s: ^Styled_State, wrap_w: f32) -> ^Rich_Layout {
	if s.have && s.lay_w == wrap_w && s.lay_sz == s.size do return &s.lay
	// the one it is replacing: a paragraph re-wraps whenever its box
	// changes width, so this runs on every drag of a window's edge. Freed
	// whether or not it was current: a change of text marks it stale first.
	rich_free(&s.lay, t.allocator)
	base := Rich_Style{size = s.size}
	s.lay = rich_layout(t, s.text, s.runs, base, max(wrap_w, 1), t.allocator)
	s.lay_w, s.lay_sz, s.have = wrap_w, s.size, true
	return &s.lay
}

@(private)
measure_styled :: proc(t: ^Tree, n: Node, d: ^Node_Data, cc: Constraints) -> [2]f32 {
	s := &t.styled[n]
	if s == nil do return constrain(cc, {0, 0})
	avail := cc.max.x if is_bounded(cc.max.x) else 10_000
	lay := styled_layout(t, n, s, avail)
	w: f32
	for line in lay.lines do w = max(w, line.x + line.width)
	return constrain(cc, {w, lay.height})
}

@(private)
styled_paint :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer) {
	s := &t.styled[n]
	if s == nil do return
	th := &t.theme
	lay := styled_layout(t, n, s, d.abs.w)
	// Cut at the sides: a grapheme wider than the whole box cannot be broken,
	// and a word cut mid-way can shape wider than it measured whole.
	append(&l.cmds, Draw_Clip_Push{rect = {d.abs.x, d.abs.y - d.abs.h, d.abs.w, d.abs.h * 3}})
	defer append(&l.cmds, Draw_Clip_Pop{})

	// the text, through the one place styled runs become draw commands
	pal := styled_colors(th, s)
	from := len(l.cmds)
	rich_draw_lines(t, l, lay, s.text, .Paragraph, d.abs.x, d.abs.y, 1,
		pal.body, pal.muted, pal.link, pal.code)
	to := len(l.cmds)

	// …and the selection over it, line by line, in a band that can be seen
	// and words that read on it (selection_paint.odin)
	lo, hi := styled_sel(s)
	if hi > lo {
		rects := make([dynamic]Rect, context.temp_allocator)
		for line, li in lay.lines {
			a := max(lo, line.start)
			b := min(hi, line.end)
			if b <= a do continue
			for sp in rich_spans(lay, li, a, b) do append(&rects, Rect{d.abs.x + line.x + sp[0], d.abs.y + line.y, sp[1] - sp[0], lay.line_h})
		}
		band, text := styled_selection_pair(th, s)
		selection_overpaint(t, l, from, to, rects[:], band, text)
	}
}

// styled_selection_pair is the band and the text colour this paragraph's
// selection draws: an app's own band where it named one, else the pair for
// its ink on its fill. A bubble passes both, which is what lets an outgoing
// one — filled with the accent — fall back to reverse video instead of an
// accent band nobody could see on it.
@(private)
styled_selection_pair :: proc(th: ^Theme, s: ^Styled_State) -> (band, text: Color) {
	if .Selection in s.pal_set {
		band = opaque(s.pal.selection)
		body := s.pal.body if .Body in s.pal_set else (s.ink if s.ink != {} else th.color.on_surface)
		return band, ensure_contrast(opaque(body), band, SELECTION_TEXT_MIN)
	}
	fill: Maybe(Color) = s.on if s.on != {} else nil
	ink: Maybe(Color) = s.ink if s.ink != {} else nil
	return selection_pair(th, fill, ink)
}

@(private)
styled_sel :: proc "contextless" (s: ^Styled_State) -> (lo, hi: int) {
	return min(s.anchor, s.caret), max(s.anchor, s.caret)
}

// styled_offset_at is the byte of `text` under a window position.
@(private)
styled_offset_at :: proc(t: ^Tree, n: Node, s: ^Styled_State, pos: [2]f32) -> int {
	d := node_get(t, n)
	if d == nil || !s.have do return 0
	li := rich_line_at(&s.lay, pos.x - d.abs.x, pos.y - d.abs.y)
	return rich_hit(&s.lay, s.text, li, pos.x - d.abs.x)
}

// styled_link_at is the href of the link run under a window position, "" for
// none.
@(private)
styled_link_at :: proc(t: ^Tree, n: Node, s: ^Styled_State, pos: [2]f32) -> string {
	d := node_get(t, n)
	if d == nil || !s.have do return ""
	x, y := pos.x - d.abs.x, pos.y - d.abs.y
	li := rich_line_at(&s.lay, x, y)
	if li < 0 || li >= len(s.lay.lines) do return ""
	line := s.lay.lines[li]
	// past the end of a line is not on its last run: a bubble's blank right
	// edge should not be a link
	if x < line.x || x > line.x + line.width do return ""
	off := rich_hit(&s.lay, s.text, li, x)
	for seg in line.segs {
		if off < seg.start || off >= seg.end do continue
		st := s.lay.styles[seg.run]
		if .Link not_in st.attrs do return ""
		return s.lay.runs[seg.run].href
	}
	return ""
}

// styled_text_selected is what is selected, in the caller's allocator, "" for
// nothing. Plain text: the styles are how it is drawn, not what it is.
@(private)
styled_text_selected :: proc(s: ^Styled_State, allocator := context.allocator) -> string {
	lo, hi := styled_sel(s)
	if hi <= lo || hi > len(s.text) do return ""
	out, err := strings.clone(s.text[lo:hi], allocator)
	return "" if err != nil else out
}

// ------------------------------------------------------------ the pointer
//
// Hooked from events.odin beside the text area's and the markdown view's,
// because a styled_text takes a drag — one that starts in it keeps going
// while the pointer leaves it, as a selection must.

// styled_pointer_button starts or ends a selection drag, and follows a link.
// True when it took the press.
@(private)
styled_pointer_button :: proc(ui: ^Ui($Msg), pressed: bool, pos: [2]f32) -> bool {
	t := &ui.tree
	if !pressed {
		for _, &s in t.styled do if s.dragging {
			s.dragging = false
			return true
		}
		return false
	}
	n := hit_test(t, pos)
	for n != NODE_NONE {
		if _, is := t.styled[n]; is do break
		d := node_get(t, n)
		if d == nil do return false
		n = d.parent
	}
	if n == NODE_NONE do return false
	s := &t.styled[n]
	if s == nil || !s.have do return false
	set_focus(t, n, false)
	// A plain click on a link is the app's, and never also the start of a
	// selection: dragging *from* a link to select it is a modifier's job,
	// and a chat's links are the common case.
	if ui.pointer.clicks.count <= 1 && ui.pointer.mods == {} {
		if href := styled_link_at(t, n, s, pos); len(href) > 0 {
			if h, has := ui.on_link[n]; has {
				handler_send(ui, h, href, n)
				s.anchor, s.caret = 0, 0
				mark_paint_dirty(t, n)
				return true
			}
		}
	}
	at := styled_offset_at(t, n, s, pos)
	switch {
	case ui.pointer.clicks.count >= 3: // the whole paragraph
		s.anchor, s.caret = 0, len(s.text)
	case ui.pointer.clicks.count == 2: // the word under the pointer
		s.anchor, s.caret = word_at(s.text, at)
	case .Shift in ui.pointer.mods: // extend what is there
		s.caret = at
	case:
		s.anchor, s.caret = at, at
	}
	s.dragging = ui.pointer.clicks.count < 2
	styled_clear_others(t, n) // one selection at a time, as in a document
	mark_paint_dirty(t, n)
	return true
}

// styled_pointer_move extends the selection of whichever paragraph is being
// dragged in. True when one is.
@(private)
styled_pointer_move :: proc(ui: ^Ui($Msg), pos: [2]f32) -> bool {
	t := &ui.tree
	for n, &s in t.styled {
		if !s.dragging do continue
		s.caret = styled_offset_at(t, n, &s, pos)
		mark_paint_dirty(t, n)
		return true
	}
	return false
}

// styled_clear_others drops every other paragraph's selection, so a window
// never shows two.
@(private)
styled_clear_others :: proc(t: ^Tree, keep: Node) {
	for n, &s in t.styled {
		if n == keep || s.anchor == s.caret do continue
		s.anchor, s.caret = 0, 0
		mark_paint_dirty(t, n)
	}
}

// styled_key handles the keys a read-only paragraph owns: copy what is
// selected, and select it all. True when it took the key.
@(private)
styled_key :: proc(ui: ^Ui($Msg), key: Key, mods: Mods) -> bool {
	t := &ui.tree
	s := &t.styled[t.focus]
	if s == nil do return false
	if shift_chord_bound(ui, key, mods) do return false // the app's own Ctrl+Shift+C / V / A wins
	#partial switch key {
	case .C:
		if .Ctrl not_in mods do return false
		if t.clipboard.set == nil do return false
		got := styled_text_selected(s, context.temp_allocator)
		if len(got) == 0 do return false
		t.clipboard.set(t.clipboard.user, got)
		return true
	case .A:
		if .Ctrl not_in mods do return false
		s.anchor, s.caret = 0, len(s.text)
		mark_paint_dirty(t, t.focus)
		return true
	}
	return false
}

// styled_cursor is the cursor over a styled paragraph: a hand on a link, an
// I-beam on its words, so a link reads as one before it is clicked and the
// rest reads as selectable. The same pair `md_view_cursor` gives a reply.
@(private)
styled_cursor :: proc(ui: ^Ui($Msg)) -> (Cursor, bool) {
	t := &ui.tree
	n := ui.pointer.hover
	for n != NODE_NONE {
		if _, is := t.styled[n]; is do break
		d := node_get(t, n)
		if d == nil do return .Default, false
		n = d.parent
	}
	if n == NODE_NONE do return .Default, false
	s := &t.styled[n]
	if s == nil || !s.have do return .Default, false
	if len(styled_link_at(t, n, s, ui.pointer.pos)) > 0 do return .Pointer, true
	return .Text, true
}

// ------------------------------------------------------------ colour

// Styled_Part names the colours a styled_text draws with, for
// `styled_text_options` to override one without naming the others.
Styled_Part :: enum u8 { Body, Muted, Link, Code, Selection }

// Styled_Palette is those colours. A zero member is the one derived from
// the ink.
Styled_Palette :: struct {
	body, muted, link, code, selection: Color,
}

// styled_ink derives the palette from one ink colour and the surface it
// sits on, which is what an outgoing chat bubble needs: it is filled with
// the accent, so its text is that fill's "on" colour and everything else
// has to follow. `on` is needed because contrast cannot be computed
// without the fill; fixed alphas over the ink alone fall below 3:1.
// Given the fill, each colour below is computed to meet a ratio, and
// styled_ink_test.odin pins the ratios.
//
//   - muted is the ink moved towards the fill, but never under 4.5:1 on it.
//   - a link is the **ink**, not the accent (an accent link on an accent
//     bubble vanishes); the underline tells it apart, as WCAG asks where
//     colour alone would carry the meaning.
//   - the inline code chip is a wash of the ink, enough to show as a chip.
//   - the selection is an opaque band standing 3:1 off the fill, with the
//     words in it redrawn in a colour that reads on it (`selection_pair`):
//     any translucent wash readable under text is near invisible on a dark
//     bubble.
@(private)
styled_ink :: proc(th: ^Theme, ink, on: Color) -> Styled_Palette {
	if ink == {} {
		return {
			body = th.color.on_surface, muted = th.color.on_surface_muted,
			link = th.color.accent_text, code = th.color.surface_variant,
			selection = opaque(th.color.primary),
		}
	}
	fill := on if on != {} else th.color.surface
	return {
		body      = ink,
		muted     = ensure_contrast(mix(ink, fill, 0.35), fill, 4.5),
		link      = ink,
		code      = with_alpha(ink, 0.16),
		selection = selection_band_on(th, fill, ink),
	}
}

// selection_band_on is the band alone, for the palette's `selection`, so a
// caller reading `styled_colors` sees what is drawn.
@(private)
selection_band_on :: proc(th: ^Theme, fill, ink: Color) -> Color {
	band, _ := selection_pair(th, fill, ink)
	return band
}

// styled_over composites a translucent colour over an opaque one.
@(private)
styled_over :: proc(c, bg: Color) -> Color {
	return {bg.r + (c.r - bg.r) * c.a, bg.g + (c.g - bg.g) * c.a, bg.b + (c.b - bg.b) * c.a, 1}
}

// styled_text_options overrides what a styled_text draws one part in,
// leaving the rest derived from its `ink`. The settings stay until changed,
// as a modifier's do.
//
//	n := baldr.styled_text(ui, body, runs, ink = th.color.on_primary)
//	baldr.styled_text_options(ui, n, link = th.color.on_primary_container)
styled_text_options :: proc(ui: ^Ui($Msg), n: Node,
	body: Maybe(Color) = nil, muted: Maybe(Color) = nil, link: Maybe(Color) = nil,
	code: Maybe(Color) = nil, selection: Maybe(Color) = nil) {
	s := &ui.tree.styled[n]
	if s == nil do return
	set :: proc(s: ^Styled_State, part: Styled_Part, c: Maybe(Color), dst: ^Color) {
		v, has := c.?
		if !has do return
		dst^ = v
		s.pal_set += {part}
	}
	set(s, .Body, body, &s.pal.body)
	set(s, .Muted, muted, &s.pal.muted)
	set(s, .Link, link, &s.pal.link)
	set(s, .Code, code, &s.pal.code)
	set(s, .Selection, selection, &s.pal.selection)
	mark_paint_dirty(&ui.tree, n)
}

// styled_colors is what this node actually draws in: derived from its ink,
// with anything styled_text_options set put back over the top.
@(private)
styled_colors :: proc(th: ^Theme, s: ^Styled_State) -> Styled_Palette {
	p := styled_ink(th, s.ink, s.on)
	if .Body in s.pal_set do p.body = s.pal.body
	if .Muted in s.pal_set do p.muted = s.pal.muted
	if .Link in s.pal_set do p.link = s.pal.link
	if .Code in s.pal_set do p.code = s.pal.code
	if .Selection in s.pal_set do p.selection = s.pal.selection
	return p
}
