package baldr

// markdown_view: a reply, rendered. It shows a Markdown_Doc and nothing
// else — no caret, no undo, no source revealed under a selection — so an
// answer can be read while it is still arriving. The app owns the document
// and grows it with `md_append`; the view lays out only the blocks that
// changed, so a reply streaming at thirty updates a second does not re-lay
// what the person is reading further up.
//
// It draws through `rich_draw_lines`, the same path the rich editor paints
// with, so the same markdown looks the same read or edited.

import "base:runtime"
import "core:math"
import "core:fmt"
import "core:slice"
import "core:strings"

// MD_VIEW_DEFAULT_WIDTH is what a view takes when nothing bounds it.
MD_VIEW_DEFAULT_WIDTH :: f32(560)

// MD_BULLET_R is a bullet's radius, and MD_LIST_DEPTHS how deep a list is
// followed when its markers are counted and measured (deeper items share
// the last level's column, which no real answer reaches).
@(private) MD_BULLET_R    :: f32(3)
// MD_COPY_BTN is a code block's Copy button, and MD_COPIED_MS how long it
// shows a tick after copying.
@(private) MD_COPY_BTN    :: f32(26)
// MD_CODE_HEAD is the band over a fenced block that holds its language and
// its Copy button, so neither covers the first line of the code.
@(private) MD_CODE_HEAD   :: f32(28)
@(private) MD_COPIED_MS   :: f64(1500)
@(private) MD_LIST_DEPTHS :: 8

// Md_Line_Cache is one block's laid-out state, kept so an append does not
// re-lay the blocks above it. `from`/`to` are the source range the layout
// was built from and `wrap_w` the width it was built for: either changing
// is what makes it stale.
@(private)
Md_Line_Cache :: struct {
	from, to: int,
	wrap_w:   f32,
	lay:      Rich_Layout,
	text:     string, // the display text the layout indexes into (tree-owned)
	src:      []int,  // display byte → source byte, for selection and copying
	height:   f32,
	top:      f32, // where the block sits in the content, from the top
	indent:   f32, // where its text starts, from the view's left edge
	shift:    f32, // …of which this much is the reading column's centring (0 without one)
	band:     f32, // a fenced run's drawn width, on its first block only (0 elsewhere)
	mark_col: f32, // a list item's marker column, shared by its whole list
	mark_at:  int, // …and the marker's bytes in the view's `marks`
	mark_n:   int,
	picture:  ^Image, // an image block's picture, when the app handed one over
	number:   int,    // a numbered item's ordinal, counted down its own list
	cols:     []f32,  // a table row's column starts (the last entry is the table's width)
	cols_src: [2]int, // …and the source range of the table they were measured over
}

// Md_View_State is a markdown view's own state: the document it shows, what
// it has laid out, and how tall that came to.
@(private)
Md_View_State :: struct {
	md:       ^Markdown_Doc,
	md_id:    u64, // …and its name, so a new document at the same address is not mistaken for it
	rev:      u64, // the document revision the cache was built from
	wrap_w:   f32,
	blocks:   [dynamic]Md_Line_Cache,
	marks:    [dynamic]u8, // the list markers the blocks point into, as drawn
	words:    [dynamic]u8, // the reply as a reader reads it: what access.value_text points at
	content:  f32, // total height
	language: proc(name: string) -> ^Language, // the app's: a fence's language by name, nil = plain
	images:   map[string]^Image, // the pictures the app handed over this build, by their markdown src
	copied_at: f64, // when a code block was last copied, for the tick the button shows
	copied_of: int, // …and which run it was (-1: none; the clock reads 0 before the first frame)
	prose_w:  f32, // > 0: prose wraps at this and is centred; tables and code may run wider
	laid_prose: f32, // the reading width the blocks were laid out at
	laid_size:  f32, // …and the body size, so a text-size change re-lays them
	sel_a:    int, // where the selection started, a source byte offset
	sel_b:    int, // …and where it is now; equal means nothing is selected
	dragging: bool, // the pointer is down and extending it
}

// markdown_view shows `md` as rendered markdown: headings, paragraphs,
// lists, quotes, code and rules, with **bold**, *italic*, `code`, ~~strike~~
// and links styled inline. It is read-only by design — a reply is not a
// document being edited.
//
// The app owns `md` and keeps it alive while the view is built; growing it
// with `md_append` is what a streaming reply does, and only the blocks that
// changed are laid out again. The node sizes itself to its content, so it
// sits in a list of messages.
//
// `label` names it for a screen reader (else "Message"). Links, pictures
// and the reading width are set with `md_view_options` and `md_view_image`.
markdown_view :: proc(ui: ^Ui($Msg), md: ^Markdown_Doc, label: string = "", width: f32 = 0,
	max_width: f32 = 0, flex: f32 = 0, tag: u64 = 0, key: u64 = 0, loc := #caller_location) -> Node {
	n, _ := reconcile_child(ui, .Custom, key, loc)
	t := &ui.tree
	d := node_get(t, n)
	if d == nil do return n
	s := &t.md_views[n]
	if s == nil {
		t.md_views[n] = Md_View_State{copied_of = -1}
		s = &t.md_views[n]
		s.blocks = make([dynamic]Md_Line_Cache, t.allocator)
		s.marks = make([dynamic]u8, t.allocator)
		s.words = make([dynamic]u8, t.allocator)
	}
	// A different reply in the same slot: nothing cached carries over. The
	// document's own name is checked as well as its address, because an app
	// that frees a reply and makes another often gets the same address back.
	if s.md != md || s.md_id != (md.id if md != nil else 0) {
		s.md = md
		s.md_id = md.id if md != nil else 0
		md_view_cache_clear(t, s)
		s.rev = 0
		s.copied_of = -1
	}
	if md != nil && s.rev != md.rev do mark_layout_dirty(t, n) // it grew: measure it again
	d.kind = Custom_Kind{paint = paint_markdown_view, measure = measure_markdown_view}
	d.tag = tag
	set_layout(t, n, Layout_Props{width = width, max_w = max_width, flex = flex})
	d.flags += {.Focusable} // a reply can be tabbed to, selected and copied
	set_role(t, n, .Text) // a reply is static text to a reader, not a container
	set_name(t, n, label if label != "" else "Message")
	md_view_access(t, n, s)
	md_view_copy_buttons(ui, n, s, loc)
	md_view_link_tip(ui, n, loc)
	mark_paint_dirty(t, n)
	return n
}

// md_view_access gives a reader the reply as the object's text, not as a
// description (a note *about* it): a screen reader then reads it line by
// line, word by word, and follows it as it arrives (the bridge turns the
// growing text into insertions). The bytes belong to the view, because
// `access.value_text` aliases the widget's own storage.
@(private)
md_view_access :: proc(t: ^Tree, n: Node, s: ^Md_View_State) {
	if s.md == nil do return
	sb := strings.builder_make(context.temp_allocator)
	current := s.rev == s.md.rev && len(s.blocks) == len(s.md.blocks)
	for b, i in s.md.blocks {
		// the rendered words, never the source: "**bold**" is read "bold".
		// The laid-out text is already rendered, so a streaming reply costs
		// nothing here; before the first layout it is rendered into temp.
		line := s.blocks[i].text if current else
			markdown_render_line(string(s.md.src[b.from:b.to]), b.in_fence, false, context.temp_allocator).text
		if len(strings.trim_space(line)) == 0 do continue
		if strings.builder_len(sb) > 0 do strings.write_byte(&sb, '\n')
		// "1. Pull … 2. Compare …": a numbered list's numbers are content, so
		// a reader hears them. They come from the source, which is as the
		// answer wrote them, and needs no layout to have happened yet.
		if b.meta.kind == .Numbered && b.body > b.from {
			strings.write_string(&sb, strings.trim_space(string(s.md.src[b.from:b.body])))
			strings.write_byte(&sb, ' ')
		}
		strings.write_string(&sb, line)
	}
	clear(&s.words)
	append(&s.words, ..transmute([]u8)strings.to_string(sb))
	d := node_get(t, n)
	if d != nil do d.access.value_text = string(s.words[:])
}

// md_view_style is the face a block is set in: its size, weight and colour
// follow the theme's roles, so a reply matches the app around it.
@(private)
md_view_style :: proc(t: ^Tree, kind: Block_Kind, level: u8) -> Rich_Style {
	th := &t.theme
	st := Rich_Style{size = th.type.body.size, family = 0}
	#partial switch kind {
	case .Heading:
		// Relative to the *body* size, not the UI's headline and title roles:
		// an app may shrink those for its own chrome, and a heading that
		// matches the paragraph under it is not a heading.
		base := th.type.body.size
		switch level {
		case 1: st.size = base * 1.5
		case 2: st.size = base * 1.3
		case:   st.size = base * 1.15
		}
		st.bold = true
	case .Code:
		st.mono = true
		st.size = th.type.body.size * 0.95
	case .Quote:
		st.italic = true
	case .Table:
		if level == 1 do st.bold = true // the header row
	}
	return st
}

// md_view_indent is how far a block's text starts from the left: a list's
// depth plus the marker column its own list shares (`mark_col`, measured in
// md_view_relayout), a quote's bar, a code block's padding.
@(private)
md_view_indent :: proc(t: ^Tree, b: Md_Block, mark_col: f32 = 0) -> f32 {
	th := &t.theme
	#partial switch b.meta.kind {
	case .Bullet, .Numbered, .Task: return th.space[.lg] * f32(b.meta.depth) + mark_col + th.space[.sm]
	case .Quote:                    return th.space[.md]
	case .Code:                     return th.space[.sm]
	}
	return 0
}

// md_view_is_item says whether a block is a list item — the three kinds
// that are set with a marker beside them.
@(private)
md_view_is_item :: proc(k: Block_Kind) -> bool {
	return k == .Bullet || k == .Numbered || k == .Task
}

// md_view_cache_free lets go of one block's laid-out state. A streaming
// reply re-lays its last block on every append, so anything missed here
// leaks hundreds of times per answer. The `href` strings belong to the
// layout's runs: rich_layout copied the run array, not the strings.
@(private)
md_view_cache_free :: proc(t: ^Tree, c: ^Md_Line_Cache) {
	for r in c.lay.runs do if len(r.href) > 0 do delete(r.href, t.allocator)
	rich_free(&c.lay, t.allocator)
	delete(c.text, t.allocator)
	delete(c.src, t.allocator)
	delete(c.cols, t.allocator)
	c^ = {}
}

// md_view_cache_clear drops every block's layout: a different reply in the
// same slot, or the view going away.
@(private)
md_view_cache_clear :: proc(t: ^Tree, s: ^Md_View_State) {
	for &c in s.blocks do md_view_cache_free(t, &c)
	clear(&s.blocks)
	clear(&s.marks)
}

// md_view_wide_block says whether a block may use the view's whole width
// rather than the reading column: a table, a code block or a picture.
// Prose is capped because a long line loses the eye on its way back (WCAG
// 1.4.8 asks for under 80 characters); a table is scanned across and only
// wraps when narrowed, and breaking a line of code changes what it seems
// to say.
@(private)
md_view_wide_block :: proc(k: Block_Kind) -> bool {
	#partial switch k {
	case .Table, .Table_Sep, .Code, .Image: return true
	}
	return false
}

// md_view_relayout brings the cache up to date with the document, keeping
// every block whose source range, width and marker column are unchanged —
// which, for an append, is all of them but the last.
@(private)
md_view_relayout :: proc(t: ^Tree, n: Node, s: ^Md_View_State, wrap_w_in: f32) {
	if s.md == nil do return
	// Whole pixels: this width keys every block's cached layout, so a
	// sub-pixel wobble would re-lay the whole reply.
	wrap_w := math.floor(wrap_w_in)
	// The body size is part of the check because every size md_view_style
	// hands out derives from it; without it a text-size change would return
	// here with nothing re-laid.
	body_size := t.theme.type.body.size
	if s.rev == s.md.rev && s.wrap_w == wrap_w && s.laid_prose == s.prose_w && s.laid_size == body_size && len(s.blocks) == len(s.md.blocks) do return
	// Cached layouts and columns belong to the size they were made at, and a
	// paragraph's `indent` does not move with the size, so the reuse checks
	// below would not notice on their own.
	size_changed := s.laid_size != body_size
	s.laid_size = body_size
	s.laid_prose = s.prose_w
	// The last paint's commands alias memory this pass rewrites (display
	// text, the marker buffer), so the view is drawn again even where
	// nothing moved.
	mark_paint_dirty(t, n)
	old := s.blocks
	fresh := make([dynamic]Md_Line_Cache, 0, len(s.md.blocks), t.allocator)

	// One pass for the markers before anything is laid out, because a list's
	// text starts after them.
	//
	//   * The bytes go in a buffer the *view* owns: the layer keeps its
	//     commands across frames and a Draw_Text's `str` aliases that
	//     memory, so a marker formatted into temp at paint time would vanish.
	//   * Every item in one list shares one column, as wide as its widest
	//     marker, so the numbers end on a column and the words start on one.
	Mark :: struct { at, n: int, w: f32, run: int }
	marks := make([]Mark, len(s.md.blocks), context.temp_allocator)
	nums := make([]int, len(s.md.blocks), context.temp_allocator)
	run_w := make([dynamic]f32, context.temp_allocator)
	base := md_view_style(t, .Numbered, 0)
	by_len: [16]f32 // a marker's width by its length: a font's digits share an advance
	count: [MD_LIST_DEPTHS]int        // the ordinal reached at each depth
	open: [MD_LIST_DEPTHS]int         // …and the list (a column) open there
	open_kind: [MD_LIST_DEPTHS]Block_Kind // …and whether that list is numbered
	for &o in open do o = -1
	clear(&s.marks)
	for b, i in s.md.blocks {
		marks[i].run = -1
		if !md_view_is_item(b.meta.kind) { // a paragraph, a heading, a table: every list has ended
			count = {}
			for &o in open do o = -1
			// A fenced run's language is drawn in its band, from this same
			// buffer: the document's own copy is a slice of source that
			// moves whenever the reply grows.
			if b.meta.kind == .Code && len(b.meta.lang) > 0 && (i == 0 || s.md.blocks[i - 1].meta.kind != .Code) {
				marks[i] = {at = len(s.marks), n = len(b.meta.lang), run = -1}
				append(&s.marks, ..transmute([]u8)b.meta.lang)
			}
			continue
		}
		depth := min(int(b.meta.depth), MD_LIST_DEPTHS - 1)
		for k in depth + 1 ..< MD_LIST_DEPTHS { count[k], open[k] = 0, -1 } // back out to this depth
		if b.meta.kind == .Numbered { count[depth] += 1 } else { count[depth] = 0 }
		// A bullet list under a numbered one is another list with a column of
		// its own (the blank line between them is no block, so the kind is the
		// only sign). A task is a bullet with a box, and belongs to the same list.
		kind := Block_Kind.Numbered if b.meta.kind == .Numbered else .Bullet
		if open[depth] >= 0 && open_kind[depth] != kind do open[depth] = -1
		if open[depth] < 0 { open[depth] = len(run_w); append(&run_w, f32(0)) }
		open_kind[depth] = kind
		nums[i] = count[depth]

		mark: string
		buf: [24]u8
		#partial switch b.meta.kind {
		case .Numbered: mark = fmt.bprintf(buf[:], "%d.", count[depth])
		case .Task:     mark = "☑" if b.meta.checked else "☐"
		}
		m := Mark{at = len(s.marks), n = len(mark), w = MD_BULLET_R * 2, run = open[depth]}
		if len(mark) > 0 {
			append(&s.marks, ..transmute([]u8)mark)
			at := min(len(mark), 15)
			if by_len[at] == 0 do by_len[at] = t.measure_text(t, mark, base.size, 0, .Regular, false, 0, false).x
			m.w = by_len[at]
		}
		marks[i] = m
		run_w[m.run] = max(run_w[m.run], m.w)
	}
	for &m in marks do if m.run >= 0 do m.w = run_w[m.run]

	// A table's columns belong to the table, not the row: measured per row, a
	// streaming table keeps its first rows' narrow columns and later rows do
	// not line up. They are measured once per table, again only when its
	// source or the width changes, and against the view less the reading
	// column's offset — sized to the whole view, the shifted table's last
	// column would run `shift` px past the edge.
	shift_all := f32(0)
	if s.prose_w > 0 do shift_all = max((wrap_w - min(s.prose_w, wrap_w)) / 2, 0)
	wide_w := wrap_w - shift_all

	cols := make([][]f32, len(s.md.blocks), context.temp_allocator)
	src := make([][2]int, len(s.md.blocks), context.temp_allocator)
	for i := 0; i < len(s.md.blocks); i += 1 {
		if s.md.blocks[i].meta.kind != .Table do continue
		first, last := md_view_table_group(s, i)
		at := [2]int{s.md.blocks[first].from, s.md.blocks[last].to}
		group: []f32
		// The reuse check uses the width the rows are cached under, or a
		// table could never be reused once a reading width was set.
		if !size_changed && first < len(old) && old[first].cols != nil && old[first].cols_src == at && old[first].wrap_w == wide_w {
			group = slice.clone(old[first].cols, context.temp_allocator) // unchanged: and the row it came from may be freed below
		} else {
			group = md_view_table_cols(t, s, i, wide_w)
		}
		for r in first ..= last { cols[r], src[r] = group, at }
		i = last
	}

	y: f32 = 0
	for b, i in s.md.blocks {
		// The width this block is given. With a reading width set, every block
		// shares one left edge (the centred column's) and only the width
		// differs: prose stops at the reading width, a table, code or picture
		// may run on to the view's right edge. Centring each wide block on its
		// own would give three left edges and a scattered page. The shift
		// rides on `indent`, which paint, hit-testing and selection already
		// go through.
		avail := wrap_w
		shift := shift_all
		if s.prose_w > 0 {
			avail = min(s.prose_w, wrap_w) if !md_view_wide_block(b.meta.kind) else wide_w
		}
		indent := md_view_indent(t, b, marks[i].w) + shift
		reuse := !size_changed && i < len(old) && old[i].from == b.from && old[i].to == b.to &&
			old[i].wrap_w == avail && old[i].indent == indent
		if reuse && b.meta.kind == .Table do reuse = slice.equal(old[i].cols, cols[i]) // the table grew a wider cell
		if reuse && b.meta.kind == .Image { // a different picture is a different height
			img, _ := s.images[b.meta.src]
			reuse = old[i].picture == img
		}
		c: Md_Line_Cache
		if reuse {
			c = old[i]
		} else {
			if i < len(old) do md_view_cache_free(t, &old[i]) // its text is what the last paint drew: see below
			line := string(s.md.src[b.from:b.to])
			shown := markdown_render_line(line, b.in_fence, false, t.allocator)
			style := md_view_style(t, b.meta.kind, b.meta.level)
			c = Md_Line_Cache{from = b.from, to = b.to, wrap_w = avail, text = shown.text, src = shown.src}
			if b.meta.kind == .Table { // a row sits on the table's columns, not on its own wrap
				c.cols, c.cols_src = slice.clone(cols[i], t.allocator), src[i]
				c.lay = table_row_layout(t, shown.text, shown.runs, style, c.cols, false, t.allocator,
					md_view_table_align(t, s, i))
			} else {
				c.lay = rich_layout(t, shown.text, shown.runs, style, max(avail - (indent - shift), 1), t.allocator)
			}
			delete(shown.runs, t.allocator) // rich_layout copied them; the `href` strings stay with the copy
			c.height = max(c.lay.height, c.lay.line_h)
			if b.meta.kind == .Rule do c.height = t.theme.space[.md]
			if b.meta.kind == .Image { // a picture fits the width it is given, never grown past its own size (a design call)
				if img, has := s.images[b.meta.src]; has && image_sides_ok(img) { // the room it takes, before its pixels are in
					scale := min(avail / f32(img.width), 1)
					c.height = f32(img.height) * scale
					c.picture = img
				}
			}
		}
		c.indent = indent
		c.shift = shift
		c.number, c.mark_col, c.mark_at, c.mark_n = nums[i], marks[i].w, marks[i].at, marks[i].n
		c.top = y
		if b.meta.kind == .Code && (i == 0 || s.md.blocks[i - 1].meta.kind != .Code) {
			c.top += MD_CODE_HEAD // the band the language and the Copy button sit in
		}
		if i > 0 {
			// One line ending between two blocks is a wrap; two is a blank
			// line, which separates paragraphs. Counting newlines rather than
			// bytes reads CRLF as well as LF.
			p := s.md.blocks[i - 1]
			joined := p.to <= b.from && strings.count(string(s.md.src[p.to:b.from]), "\n") == 1
			c.top += md_view_gap(t, p.meta.kind, b.meta.kind, joined)
		}
		y = c.top + c.height
		append(&fresh, c)
	}
	for i in len(s.md.blocks) ..< len(old) do md_view_cache_free(t, &old[i]) // the reply got shorter
	delete(old)
	s.blocks = fresh
	// A fenced run's wash reaches a small step past its last line (paint), so
	// a reply that ends in one is that much taller and keeps the wash inside.
	if nb := len(s.blocks); nb > 0 && nb <= len(s.md.blocks) && s.md.blocks[nb - 1].meta.kind == .Code do y += t.theme.space[.sm]
	s.content = max(y, 0)
	// A fenced run's band: as wide as its longest line needs, never narrower
	// than the reading column nor wider than the room there is. Settled here,
	// not at paint, because measure places the Copy button from it.
	for i := 0; i < len(s.blocks) && i < len(s.md.blocks); i += 1 {
		if s.md.blocks[i].meta.kind != .Code do continue
		last := i
		for j := i + 1; j < len(s.md.blocks) && j < len(s.blocks); j += 1 {
			if s.md.blocks[j].meta.kind != .Code do break
			last = j
		}
		band := wrap_w - s.blocks[i].shift
		if s.prose_w > 0 {
			longest := f32(0)
			for j := i; j <= last; j += 1 do for ln in s.blocks[j].lay.lines do longest = max(longest, ln.width)
			// The floor is the *prose* width, not the block's own: a code
			// block already has the full width, so clamping to that does nothing.
			band = clamp(longest + t.theme.space[.sm] * 2, min(s.prose_w, wrap_w), band)
		}
		s.blocks[i].band = band
		i = last
	}
	s.rev, s.wrap_w = s.md.rev, wrap_w
}

@(private)
measure_markdown_view :: proc(t: ^Tree, n: Node, d: ^Node_Data, cc: Constraints) -> [2]f32 {
	s := &t.md_views[n]
	if s == nil do return constrain(cc, {MD_VIEW_DEFAULT_WIDTH, 0})
	w := cc.max.x if is_bounded(cc.max.x) else MD_VIEW_DEFAULT_WIDTH
	if cc.min.x > w do w = cc.min.x
	md_view_relayout(t, n, s, max(w, 1))
	size := constrain(cc, {w, s.content})
	// The Copy buttons are this node's children, and a custom measure lays
	// its own out: each one over its block's top right corner, inside the
	// wash the run is drawn on.
	th := &t.theme
	ch := d.first
	for b, i in s.md.blocks {
		if ch == NODE_NONE do break
		if b.meta.kind != .Code do continue
		if i > 0 && s.md.blocks[i - 1].meta.kind == .Code do continue
		if i >= len(s.blocks) do break
		layout_node(t, ch, constraints_tight({MD_COPY_BTN, MD_COPY_BTN}))
		cd := node_get(t, ch)
		if cd != nil {
			right := s.blocks[i].shift + s.blocks[i].band if s.blocks[i].band > 0 else size.x
			cd.rect.x = max(right - MD_COPY_BTN - th.space[.xs], 0)
			cd.rect.y = s.blocks[i].top - MD_CODE_HEAD + (MD_CODE_HEAD - MD_COPY_BTN) * 0.5
		}
		ch = cd.next if cd != nil else NODE_NONE
	}
	return size
}

@(private)
paint_markdown_view :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer) {
	s := &t.md_views[n]
	if s == nil || s.md == nil do return
	th := &t.theme
	ink := th.color.on_surface
	muted := th.color.on_surface_muted
	accent := th.color.accent_text // links are ink, so they take the text-contrast accent
	wash := th.color.surface_variant
	sel_lo, sel_hi := min(s.sel_a, s.sel_b), max(s.sel_a, s.sel_b)
	// Cut at the sides: a grapheme wider than the whole view cannot be broken,
	// and a word cut mid-way can shape wider than it measured whole.
	append(&l.cmds, Draw_Clip_Push{rect = {d.abs.x, d.abs.y - d.abs.h, d.abs.w, d.abs.h * 3}})
	defer append(&l.cmds, Draw_Clip_Pop{})
	for c, i in s.blocks {
		if i >= len(s.md.blocks) do break
		b := s.md.blocks[i]
		x := d.abs.x + c.indent
		y := d.abs.y + c.top
		if y > d.abs.y + d.abs.h || y + c.height < d.abs.y do continue // out of view
		#partial switch b.meta.kind {
		case .Rule:
			// the reading column's width, not the view's: a rule that ran the
			// whole way across would cut through the margin the prose sits in
			rule_w := c.wrap_w if c.shift > 0 else d.abs.w
			append(&l.cmds, Draw_Rect{rect = {d.abs.x + c.shift, y + c.height * 0.5, rule_w, 1}, color = muted})
			continue
		case .Quote: // the bar down the side of a quotation
			append(&l.cmds, Draw_Rect{rect = {d.abs.x + c.shift, y, 2, c.height}, radius = 1, color = muted})
		case .Code:
			// One background behind the whole fenced run: per-line rects show
			// their seams.
			if i > 0 && s.md.blocks[i - 1].meta.kind == .Code do break // the run's background is already down
			last := i
			for j := i + 1; j < len(s.md.blocks) && j < len(s.blocks); j += 1 {
				if s.md.blocks[j].meta.kind != .Code do break
				last = j
			}
			pad := th.space[.sm]
			top := y - MD_CODE_HEAD // the band over the code, not just padding
			bottom := d.abs.y + s.blocks[last].top + s.blocks[last].height + pad
			// The band md_view_relayout settled: as wide as the longest line
			// needs, so a short fence does not run out past the prose.
			band := c.band if c.band > 0 else d.abs.w - c.shift
			append(&l.cmds, Draw_Rect{rect = {d.abs.x + c.shift, top, band, bottom - top}, radius = th.radius.md, color = wash})
			if c.mark_n > 0 { // the language, at the band's left: "sql", "odin"
				size := th.type.body.size * 0.85
				append(&l.cmds, Draw_Text{pos = {d.abs.x + c.shift + th.space[.sm], top + (MD_CODE_HEAD - size * 1.25) * 0.5},
					str = string(s.marks[c.mark_at:][:c.mark_n]), size = size, color = muted})
			}
		case .Bullet, .Numbered, .Task:
			// A marker sits on the line of the item's *text*, at its size: the
			// layout's ascent is the tallest run's, which an inline `code`
			// chip would push below the words.
			st := md_view_style(t, b.meta.kind, b.meta.level)
			asc := st.size * 0.8
			if te := t.text; te != nil && te.ok do asc = text_ascent(te, st.size, st.mono, st.family)
			base_y := y + max(c.lay.ascent - asc, 0) // the top of the item's own text
			gap := th.space[.sm] // the same air between marker and words, whatever the marker
			if b.meta.kind == .Bullet {
				r := MD_BULLET_R
				append(&l.cmds, Draw_Rect{rect = {x - gap - r * 2, base_y + asc * 0.55 - r, r * 2, r * 2}, radius = r, color = muted})
				break
			}
			if c.mark_n == 0 do break
			// Right-aligned in the column its list shares, as the rich
			// editor sets its numbers: "9." and "10." end on one column.
			mark := string(s.marks[c.mark_at:][:c.mark_n])
			append(&l.cmds, Draw_Text{pos = {x - gap - c.mark_col, base_y}, str = mark, size = st.size,
				color = muted, align = .End, box_w = c.mark_col})
		}
		if b.meta.kind == .Image && image_adds_up(c.picture) {
			img := c.picture
			scale := min(d.abs.w / f32(img.width), 1)
			w, h := f32(img.width) * scale, f32(img.height) * scale
			append(&l.cmds, Draw_Image{rect = {d.abs.x, y, w, h}, img = img, radius = th.radius.md,
				id = img.id, version = img.version, size = {img.width, img.height}, color = {1, 1, 1, 1}})
			continue
		}
		if b.meta.kind == .Code && s.language != nil && len(b.meta.lang) > 0 {
			if lang := s.language(b.meta.lang); lang != nil {
				from := len(l.cmds)
				md_view_paint_code(t, l, c, lang, x, y, ink)
				// The selection goes over a highlighted block too, before the
				// `continue` skips the plain path.
				md_view_overpaint(t, l, c, b, sel_lo, sel_hi, from, x, y)
				continue
			}
		}
		if b.meta.kind == .Table {
			_, last := md_view_table_group(s, i)
			// `x`, not the view's left edge: with a reading width set the
			// table is shifted, and its rules travel with it.
			md_view_paint_table(t, l, c, b.meta.level == 1, i == last, x, y, muted)
		}
		lay := c.lay
		from := len(l.cmds) // the words only: a marker or a table's rules are not redrawn in the selection
		rich_draw_lines(t, l, &lay, c.text, b.meta.kind, x, y, 1, ink, muted, accent, wash)
		md_view_overpaint(t, l, c, b, sel_lo, sel_hi, from, x, y)
	}
}

// md_view_overpaint lays the part of the selection that falls in block `b`
// over the words `l.cmds[from:]` just drew (selection_paint.odin). A reply sits
// on one of the theme's surfaces, which the theme's pair always stands off.
@(private)
md_view_overpaint :: proc(t: ^Tree, l: ^Layer, c: Md_Line_Cache, b: Md_Block, sel_lo, sel_hi, from: int, x, y: f32) {
	if !(sel_lo < sel_hi && b.to > sel_lo && b.from < sel_hi) do return
	rects := md_view_selection_rects(c, max(sel_lo, b.from), min(sel_hi, b.to), x, y)
	band, text := selection_pair(&t.theme)
	selection_overpaint(t, l, from, len(l.cmds), rects, band, text)
}

// Selection. The anchors are *source* byte offsets, not block and line, so
// a selection survives the reply growing underneath it (bytes land at the
// end) and a re-layout at a new width (the lines change; the bytes do not).

// md_view_selection is the source byte range the person has selected in the
// view built as `n`, low first. Both zero means nothing is selected. The
// offsets index the document's own text (`md_text`), so `md_markdown` turns
// them into the markdown behind the selection.
md_view_selection :: proc(t: ^Tree, n: Node) -> (lo, hi: int) {
	s := &t.md_views[n]
	if s == nil do return 0, 0
	return min(s.sel_a, s.sel_b), max(s.sel_a, s.sel_b)
}

// md_view_selected_text is the selection as clean text, ready for the
// clipboard: the words as they are drawn, a list item's marker written out
// ("- ", "1. ", "[x] ") and one newline between blocks. No markup, no
// invisible characters. The string is the caller's to free (temp by
// default). Empty when nothing is selected.
md_view_selected_text :: proc(t: ^Tree, n: Node, allocator := context.temp_allocator) -> string {
	s := &t.md_views[n]
	if s == nil || s.md == nil do return ""
	lo, hi := md_view_selection(t, n)
	if lo >= hi do return ""
	sb := strings.builder_make(allocator)
	for c, i in s.blocks {
		if i >= len(s.md.blocks) do break
		b := s.md.blocks[i]
		if b.to <= lo || b.from >= hi do continue
		// the part of this block's display text the selection covers
		first, last := md_view_display_range(c, max(lo, b.from), min(hi, b.to))
		if first >= last do continue
		if strings.builder_len(sb) > 0 do strings.write_byte(&sb, '\n')
		if first == 0 { // a marker belongs to the item, when the item is taken from its start
			#partial switch b.meta.kind {
			case .Bullet:   strings.write_string(&sb, "- ")
			case .Numbered: // its own ordinal: the numbers are the content of a list of steps
				strings.write_string(&sb, string(s.marks[c.mark_at:][:c.mark_n]) if c.mark_n > 0 else "1.")
				strings.write_byte(&sb, ' ')
			case .Task:     strings.write_string(&sb, "[x] " if b.meta.checked else "[ ] ")
			}
		}
		strings.write_string(&sb, c.text[first:last])
	}
	return strings.to_string(sb)
}

// md_view_display_range maps a source byte range onto one block's display
// text, using the map `markdown_render_line` built (display byte → source
// byte). The marks are not in the display text, so a selection that covers
// "**bold**" covers "bold".
@(private)
md_view_display_range :: proc(c: Md_Line_Cache, src_lo, src_hi: int) -> (lo, hi: int) {
	lo, hi = len(c.text), 0
	for d in 0 ..= len(c.text) {
		if d >= len(c.src) do break
		sv := c.from + c.src[d] // line-relative, as md_view_at notes
		if sv >= src_lo && sv < src_hi {
			lo = min(lo, d)
			hi = max(hi, d + 1)
		}
	}
	if lo > hi do return 0, 0
	return clamp(lo, 0, len(c.text)), clamp(hi, 0, len(c.text))
}

// md_view_at is the source byte offset nearest `pos` (absolute), so a press
// lands between the characters the person aimed between.
@(private)
md_view_at :: proc(t: ^Tree, n: Node, s: ^Md_View_State, pos: [2]f32) -> int {
	d := node_get(t, n)
	if d == nil || s.md == nil || len(s.blocks) == 0 do return 0
	y := pos.y - d.abs.y
	bi := 0
	for c, i in s.blocks { // the block the pointer is in, or the last one above it
		if y >= c.top do bi = i
	}
	c := s.blocks[bi]
	b := s.md.blocks[bi]
	lay := c.lay
	if len(lay.lines) == 0 do return b.from
	x := pos.x - d.abs.x - c.indent
	li := rich_line_at(&lay, x, y - c.top)
	off := rich_hit(&lay, c.text, li, x)
	if off < 0 do off = 0
	if off >= len(c.src) do return b.to
	// `src` is the map markdown_render_line built for *this line*, so its
	// offsets are relative to the line's start, not the document's.
	return b.from + c.src[off]
}

// Md_Step is how far one press of a keyboard selection moves its end.
@(private)
Md_Step :: enum { Char_Prev, Char_Next, Word_Prev, Word_Next, Line_Prev, Line_Next, Line_Start, Line_End, Doc_Start, Doc_End }

// md_view_place is where a source offset sits in the laid-out reply: which
// block, which of that block's wrapped lines, and where in its display text.
@(private)
md_view_place :: proc(s: ^Md_View_State, at: int) -> (bi, li, off: int) {
	if len(s.blocks) == 0 do return 0, 0, 0
	bi = 0
	for b, i in s.md.blocks {
		if i >= len(s.blocks) do break
		if at >= b.from do bi = i // the block it is in, or the last one above it
	}
	c := s.blocks[bi]
	off = md_view_display_at(c, at)
	for l, i in c.lay.lines {
		li = i
		if off <= l.end do break
	}
	return
}

// md_view_display_at is where a source offset sits in a block's display
// text. md_view_display_range gives 0 for an empty range, which is right
// for painting and wrong for placing a selection's end.
@(private)
md_view_display_at :: proc(c: Md_Line_Cache, src_at: int) -> int {
	for d in 0 ..< len(c.src) {
		if c.from + c.src[d] >= src_at do return min(d, len(c.text))
	}
	return len(c.text)
}

// md_view_source_at is the source offset of a display offset in block `bi`
// — the other direction, through the line-relative map the renderer built.
@(private)
md_view_source_at :: proc(s: ^Md_View_State, bi, off: int) -> int {
	if bi < 0 || bi >= len(s.blocks) do return 0
	c, b := s.blocks[bi], s.md.blocks[bi]
	if len(c.src) == 0 do return b.from
	return b.from + c.src[clamp(off, 0, len(c.src) - 1)]
}

// md_view_step moves a selection's end one step from source offset `at`.
// The steps are the ones every editor in the toolkit has, and they move
// through the reply *as it is drawn* — a wrapped line is a line, and the
// markup that is not shown is not stepped through.
@(private)
md_view_step :: proc(s: ^Md_View_State, at: int, step: Md_Step) -> int {
	if s.md == nil || len(s.blocks) == 0 do return at
	last := len(s.blocks) - 1
	#partial switch step {
	case .Doc_Start: return 0
	case .Doc_End:   return len(s.md.src)
	}
	bi, li, off := md_view_place(s, at)
	c := s.blocks[bi]
	line := c.lay.lines[li] if li < len(c.lay.lines) else Rich_Line{}
	switch step {
	case .Char_Next:
		if off < len(c.text) do return md_view_source_at(s, bi, grapheme_next(c.text, off))
		if bi < last do return s.md.blocks[bi + 1].from
		return len(s.md.src)
	case .Char_Prev:
		if off > 0 do return md_view_source_at(s, bi, grapheme_prev(c.text, off))
		if bi > 0 do return s.md.blocks[bi - 1].to
		return 0
	case .Word_Next:
		_, hi := md_view_word_at(s, at)
		if hi > at do return hi
		next := min(at + 1, len(s.md.src))
		_, beyond := md_view_word_at(s, next)
		return max(beyond, next)
	case .Word_Prev:
		lo, _ := md_view_word_at(s, max(at - 1, 0))
		if lo < at do return lo
		return max(at - 1, 0)
	case .Line_Start: return md_view_source_at(s, bi, line.start)
	case .Line_End:   return md_view_source_at(s, bi, line.end)
	case .Line_Next:
		x := rich_x(&c.lay, li, off)
		if li + 1 < len(c.lay.lines) do return md_view_source_at(s, bi, rich_hit(&c.lay, c.text, li + 1, x))
		if bi < last {
			n := s.blocks[bi + 1]
			return md_view_source_at(s, bi + 1, rich_hit(&n.lay, n.text, 0, x))
		}
		return len(s.md.src)
	case .Line_Prev:
		x := rich_x(&c.lay, li, off)
		if li > 0 do return md_view_source_at(s, bi, rich_hit(&c.lay, c.text, li - 1, x))
		if bi > 0 {
			p := s.blocks[bi - 1]
			return md_view_source_at(s, bi - 1, rich_hit(&p.lay, p.text, max(len(p.lay.lines) - 1, 0), x))
		}
		return 0
	case .Doc_Start, .Doc_End:
	}
	return at
}

// md_view_reveal brings the selection's moving end into view: the reply is
// as tall as its content and sits in the app's own scroll, so it is the
// *point* that has to be shown, not the node (scroll_rect_into_view).
@(private)
md_view_reveal :: proc(t: ^Tree, n: Node, s: ^Md_View_State, at: int) {
	d := node_get(t, n)
	if d == nil || len(s.blocks) == 0 do return
	bi, li, off := md_view_place(s, at)
	c := s.blocks[bi]
	x := d.abs.x + c.indent + rich_x(&c.lay, li, off)
	y := d.abs.y + c.top + (c.lay.lines[li].y if li < len(c.lay.lines) else 0)
	scroll_rect_into_view(t, n, Rect{x, y, 1, max(c.lay.line_h, 1)})
}

// md_view_word_at widens `at` to the word around it, in source bytes.
@(private)
md_view_word_at :: proc(s: ^Md_View_State, at: int) -> (lo, hi: int) {
	if s.md == nil do return at, at
	text := string(s.md.src[:])
	word :: proc(c: u8) -> bool {
		return c == '_' || c == '\'' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c >= 0x80
	}
	lo, hi = clamp(at, 0, len(text)), clamp(at, 0, len(text))
	if lo >= len(text) || !word(text[lo]) { // not in a word: take the single character
		return lo, min(lo + 1, len(text))
	}
	for lo > 0 && word(text[lo - 1]) do lo -= 1
	for hi < len(text) && word(text[hi]) do hi += 1
	return
}

// md_view_pointer_button places or extends a selection. It is called before
// the general press handling, as a text area's is.
md_view_pointer_button :: proc(ui: ^Ui($Msg), pressed: bool, pos: [2]f32) -> bool {
	t := &ui.tree
	if !pressed {
		for _, &s in t.md_views do if s.dragging { s.dragging = false; return true }
		return false
	}
	n := hit_test(t, pos)
	for n != NODE_NONE {
		// A reply's own controls sit inside it: a press on a code block's
		// Copy button (or the icon in it) is the button's, not the start of
		// a selection — the view would otherwise swallow it on the way past.
		if _, is_copy := t.md_copy_of[n]; is_copy do return false
		if _, is := t.md_views[n]; is do break
		d := node_get(t, n)
		if d == nil do return false
		n = d.parent
	}
	if n == NODE_NONE do return false
	s := &t.md_views[n]
	if s == nil || s.md == nil do return false
	set_focus(t, n, false)
	md_view_selection_clear_others(t, n) // one selection at a time, as in a document
	if ui.pointer.clicks.count <= 1 && md_view_link_press(ui, n, pos) do return true // a link is the app's
	if ui.pointer.clicks.count <= 1 && md_view_image_press(ui, n, s, pos) do return true // …and so is a picture
	at := md_view_at(t, n, s, pos)
	clicks := ui.pointer.clicks.count
	switch {
	case clicks >= 3: // the whole block under the pointer
		bi := 0
		for c, i in s.blocks do if pos.y - node_get(t, n).abs.y >= c.top do bi = i
		if bi < len(s.md.blocks) do s.sel_a, s.sel_b = s.md.blocks[bi].from, s.md.blocks[bi].to
	case clicks == 2: // the word
		s.sel_a, s.sel_b = md_view_word_at(s, at)
	case .Shift in ui.pointer.mods: // extend from where the selection started
		s.sel_b = at
	case:
		s.sel_a, s.sel_b = at, at
	}
	s.dragging = clicks < 2
	mark_paint_dirty(t, n)
	return true
}

// md_view_pointer_move extends a selection while the button is held.
md_view_pointer_move :: proc(ui: ^Ui($Msg), pos: [2]f32) -> bool {
	t := &ui.tree
	for n, &s in t.md_views {
		if !s.dragging do continue
		s.sel_b = md_view_at(t, n, &s, pos)
		mark_paint_dirty(t, n)
		return true
	}
	return false
}

// md_view_key gives a focused reply the keys a reader needs: Ctrl+A to
// select it, Ctrl+C to copy what is selected, Escape to let it go. Nothing
// else is taken, so the window's own shortcuts still work.
md_view_key :: proc(ui: ^Ui($Msg), key: Key, mods: Mods) -> bool {
	t := &ui.tree
	n := t.focus
	if n == NODE_NONE do return false
	s := &t.md_views[n]
	if s == nil || s.md == nil do return false
	if shift_chord_bound(ui, key, mods) do return false // the app's own Ctrl+Shift+C / V / A wins
	#partial switch key {
	case .A:
		if .Ctrl not_in mods do return false
		return md_view_action(t, n, s, .Select_All)
	case .C:
		if .Ctrl not_in mods do return false
		return md_view_action(t, n, s, .Copy)
	case .Escape:
		if s.sel_a == s.sel_b do return false
		s.sel_a, s.sel_b = 0, 0
		mark_paint_dirty(t, n)
		return true
	case .Left, .Right, .Up, .Down, .Home, .End:
		// Selecting by keyboard, once a reply has focus: Shift moves the
		// end, as it does in every editor here, and no caret is drawn
		// because there is nothing to type. An arrow with no Shift is not
		// the reply's — it goes on to the window and its scroll.
		if .Shift not_in mods do return false
		word := .Ctrl in mods
		step: Md_Step
		#partial switch key {
		case .Left:  step = .Word_Prev if word else .Char_Prev
		case .Right: step = .Word_Next if word else .Char_Next
		case .Up:    step = .Line_Prev
		case .Down:  step = .Line_Next
		case .Home:  step = .Doc_Start if .Ctrl in mods else .Line_Start
		case .End:   step = .Doc_End if .Ctrl in mods else .Line_End
		}
		md_view_selection_clear_others(t, n)
		s.sel_b = clamp(md_view_step(s, s.sel_b, step), 0, len(s.md.src))
		md_view_reveal(t, n, s, s.sel_b)
		mark_paint_dirty(t, n)
		return true
	}
	return false
}

// md_view_action is an Editor_Action in a reply: Copy and Select All, the
// two a read-only text has.
@(private)
md_view_action :: proc(t: ^Tree, n: Node, s: ^Md_View_State, action: Editor_Action) -> bool {
	if s.md == nil do return false
	#partial switch action {
	case .Copy:
		lo, hi := md_view_selection(t, n)
		if lo >= hi || t.clipboard.set == nil do return false
		return t.clipboard.set(t.clipboard.user, md_view_selected_text(t, n))
	case .Select_All:
		if len(s.md.src) == 0 do return false
		md_view_selection_clear_others(t, n)
		s.sel_a, s.sel_b = 0, len(s.md.src)
		mark_paint_dirty(t, n)
		return true
	}
	return false
}

@(private)
md_view_actions :: proc(t: ^Tree, s: ^Md_View_State) -> (can: Editor_Actions) {
	if s.md == nil do return
	if s.sel_a != s.sel_b && t.clipboard.set != nil do can += {.Copy}
	if len(s.md.src) > 0 do can += {.Select_All}
	return
}

// md_view_context_press: a right-click in a reply with `on_context` keeps a
// selection it lands on and drops one it misses, then asks for the menu
// there. A code block's Copy button is the button's.
@(private)
md_view_context_press :: proc(ui: ^Ui($Msg), pos: [2]f32) -> bool {
	t := &ui.tree
	n := hit_test(t, pos)
	for n != NODE_NONE {
		if _, is_copy := t.md_copy_of[n]; is_copy do return false
		if _, is := t.md_views[n]; is do break
		d := node_get(t, n)
		if d == nil do return false
		n = d.parent
	}
	if n == NODE_NONE do return false
	h, has := ui.editor_contexts[n]
	s := &t.md_views[n]
	if !has || s == nil || s.md == nil do return false
	set_focus(t, n, false)
	s.dragging = false
	at := md_view_at(t, n, s, pos)
	lo, hi := md_view_selection(t, n)
	inside := hi > lo && at >= lo && at <= hi
	if !inside {
		s.sel_a, s.sel_b = at, at
		md_view_selection_clear_others(t, n)
		mark_paint_dirty(t, n)
	}
	ui.context_pos = pos
	return handler_send(ui, h, Editor_Context{pos = {0, at}, in_selection = inside, at = pos}, n)
}

// md_view_context_key: the Menu key (or Shift+F10) in a focused reply with
// `on_context` asks for the menu under the selection's moving end, or under
// the reply's first line when nothing is selected.
@(private)
md_view_context_key :: proc(ui: ^Ui($Msg), n: Node) -> bool {
	t := &ui.tree
	h, has := ui.editor_contexts[n]
	if !has do return false
	s := &t.md_views[n]
	d := node_get(t, n)
	if s == nil || d == nil || s.md == nil do return false
	lo, hi := md_view_selection(t, n)
	at := [2]f32{d.abs.x, d.abs.y}
	if len(s.blocks) > 0 do at += {s.blocks[0].indent, s.blocks[0].top + s.blocks[0].lay.line_h}
	if hi > lo && len(s.blocks) > 0 {
		bi, li, off := md_view_place(s, s.sel_b)
		c := s.blocks[bi]
		y := c.top + (c.lay.lines[li].y if li < len(c.lay.lines) else 0) + c.lay.line_h
		at = {d.abs.x + c.indent + rich_x(&c.lay, li, off), d.abs.y + y}
	}
	ui.context_pos = at
	return handler_send(ui, h, Editor_Context{pos = {0, s.sel_b}, in_selection = hi > lo, at = at}, n)
}

// md_view_selection_rects is the selected part of a block's lines, as the
// rects the selection wash covers. The frame's memory.
@(private)
md_view_selection_rects :: proc(c: Md_Line_Cache, lo, hi: int, x, y: f32) -> []Rect {
	out := make([dynamic]Rect, context.temp_allocator)
	first, last := md_view_display_range(c, lo, hi)
	if first >= last do return out[:]
	lay := c.lay
	for line, li in lay.lines {
		a := max(first, line.start)
		b := min(last, line.end)
		if a >= b do continue
		for sp in rich_spans(&lay, li, a, b) do append(&out, Rect{x + sp[0], y + lay.lines[li].y, max(sp[1] - sp[0], 1), lay.line_h})
	}
	return out[:]
}

// Links. A link in a reply belongs to the app, not to the view: the view
// says which one was pressed and the app decides what to do with it —
// usually `open_url`, which is strict about its schemes.

// md_view_link_at is the link target under `pos` (absolute), "" when there
// is none. It is a view into the document's runs — clone what you keep.
md_view_link_at :: proc(t: ^Tree, n: Node, pos: [2]f32) -> string {
	href, _, _ := md_view_link_here(t, n, pos)
	return href
}

// md_view_link_here finds the link under `pos`: its target, where a tooltip
// for it belongs (under the line it is on, at its first letter, in absolute
// coordinates) and `id`, the source offset the link starts at — which names
// *this* link, so moving along one keeps its tooltip up and moving to the
// next brings a new one. `id` is -1 when the pointer is on no link.
@(private)
md_view_link_here :: proc(t: ^Tree, n: Node, pos: [2]f32) -> (href: string, at: [2]f32, id: int) {
	id = -1
	s := &t.md_views[n]
	d := node_get(t, n)
	if s == nil || d == nil || s.md == nil || len(s.blocks) == 0 do return
	y := pos.y - d.abs.y
	bi := -1
	for c, i in s.blocks do if y >= c.top && y < c.top + c.height do bi = i
	if bi < 0 do return
	c := s.blocks[bi]
	lay := c.lay
	if len(lay.lines) == 0 do return
	x := pos.x - d.abs.x - c.indent
	li := rich_line_at(&lay, x, y - c.top)
	if x < lay.lines[li].x || x > lay.lines[li].x + lay.lines[li].width do return
	off := rich_hit(&lay, c.text, li, x)
	for seg in lay.lines[li].segs {
		if off < seg.start || off >= seg.end do continue
		st := lay.styles[seg.run]
		if .Link not_in st.attrs do return
		href = lay.runs[seg.run].href
		// the run's own first byte, not the line's: a link that wraps is
		// still one link, and keeps one tooltip
		start := 0 if seg.run == 0 else lay.runs[seg.run - 1].end
		id = s.md.blocks[bi].from + (c.src[start] if start >= 0 && start < len(c.src) else 0)
		at = {d.abs.x + c.indent + rich_x(&lay, li, seg.start),
			d.abs.y + c.top + lay.lines[li].y + lay.line_h + 2}
		return
	}
	return
}

// md_view_link_id is the link under `pos`, named by where it starts in the
// source (-1: none). tooltip_tick asks, to know a reply has something to
// say on hover and when the pointer has moved from one link to another.
@(private)
md_view_link_id :: proc(t: ^Tree, n: Node, pos: [2]f32) -> int {
	href, _, id := md_view_link_here(t, n, pos)
	return id if len(href) > 0 else -1
}

// md_view_code_run is the fenced block `b` belongs to, first and last.
@(private)
md_view_code_run :: proc(s: ^Md_View_State, b: int) -> (first, last: int) {
	first, last = b, b
	for first > 0 && s.md.blocks[first - 1].meta.kind == .Code do first -= 1
	for last + 1 < len(s.md.blocks) && s.md.blocks[last + 1].meta.kind == .Code do last += 1
	return
}

// md_view_copy_buttons gives every fenced block a real Copy button — its
// own hit target, hover, place in the focus order and the name "Copy
// code", not a rectangle painted on the block. One per fenced *run*, keyed
// by where the run starts in the source so a streaming reply keeps the
// buttons it has. measure_markdown_view places them at the right of the
// band over the code.
@(private)
md_view_copy_buttons :: proc(ui: ^Ui($Msg), n: Node, s: ^Md_View_State, loc: runtime.Source_Code_Location) {
	t := &ui.tree
	th := &t.theme
	if s.md == nil do return
	open_scope(ui, n, loc)
	defer close_scope(ui)
	for b, i in s.md.blocks {
		if b.meta.kind != .Code do continue
		if i > 0 && s.md.blocks[i - 1].meta.kind == .Code do continue // one button for the run
		btn, created := reconcile_child(ui, .Box, u64(b.from) + 1, loc)
		d := node_get(t, btn)
		if d == nil do continue
		if created {
			d.access.role = .Button
			d.flags += {.Focusable}
		}
		t.md_copy_of[btn] = n
		d.tag = u64(i)
		copied := s.copied_of == i
		set_name(t, btn, "Copy code")
		// Not a live region: those announce the *name*, so it would say "Copy
		// code" when a reply appears and never "Copied". A reader hears the
		// press through the action it took.
		set_describe(t, btn, "Copied" if copied else "")
		set_layout(t, btn, Layout_Props{axis = .Row, align = .Center, justify = .Center, width = MD_COPY_BTN, height = MD_COPY_BTN})
		st := d.style
		st.radius = th.radius.sm
		set_style(t, btn, st)
		open_scope(ui, btn, loc)
		baldr_icon(ui, .Check if copied else .Copy, ICON_SIZE, th.color.accent_text if copied else th.color.on_surface_muted, loc)
		close_scope(ui)
	}
}

// md_view_tick takes the tick off a Copy button when its moment has passed.
// A timer wakes the frame but only a build changes what the button shows,
// so the moment is noticed here and a build asked for, as tooltip_tick does.
@(private)
md_view_tick :: proc(ui: ^Ui($Msg), now_ms: f64) {
	for n, &s in ui.tree.md_views {
		if s.copied_of < 0 do continue
		if now_ms - s.copied_at < MD_COPIED_MS {
			tree_wake_at(&ui.tree, s.copied_at + MD_COPIED_MS, n)
			continue
		}
		s.copied_at, s.copied_of = 0, -1
		ask_rebuild(ui)
	}
}

// md_view_copy_click copies a fenced block, exactly as it was written: the
// source lines between its fences, without them.
@(private)
md_view_copy_click :: proc(ui: ^Ui($Msg), n: Node) -> bool {
	t := &ui.tree
	view, has := t.md_copy_of[n]
	d := node_get(t, n)
	s := &t.md_views[view]
	if !has || d == nil || s == nil || s.md == nil do return false
	at := int(d.tag)
	if at < 0 || at >= len(s.md.blocks) || s.md.blocks[at].meta.kind != .Code do return false
	first, last := md_view_code_run(s, at)
	if t.clipboard.set == nil do return false
	t.clipboard.set(t.clipboard.user, string(s.md.src[s.md.blocks[first].from:s.md.blocks[last].to]))
	s.copied_at, s.copied_of = t.now_ms, first
	ask_rebuild(ui) // the button shows a tick for a moment
	return true
}

// md_view_cursor is the pointer's shape over a reply: the hand on a link,
// as a browser shows, and the I-beam over the words, because they are
// there to be selected and copied. Read by cursor_for.
@(private)
md_view_cursor :: proc(ui: ^Ui($Msg)) -> (Cursor, bool) {
	n := ui.pointer.hover
	if !ui.pointer.inside do return .Default, false
	if s := &ui.tree.md_views[n]; s == nil do return .Default, false
	if len(md_view_link_at(&ui.tree, n, ui.pointer.pos)) > 0 do return .Pointer, true
	return .Text, true
}

// md_view_link_tip shows a hovered link's target by the pointer, under the
// line it is on, rather than in a browser-style status strip an app would
// have to grow for this alone. The same shape as an editor's mark tooltip.
@(private)
md_view_link_tip :: proc(ui: ^Ui($Msg), n: Node, loc: runtime.Source_Code_Location) {
	if ui.tip_anchor != n || ui.tip_mark < 0 do return
	href, at, id := md_view_link_here(&ui.tree, n, ui.pointer.pos)
	if id < 0 || len(href) == 0 do return
	tooltip_show(ui, n, href, loc, at = at, fixed = true)
}

// md_view_options sets what a reply does beyond being read: `on_link` hears
// a link being pressed, with its target, and the app decides whether to
// open it (`open_url` only takes http, https and mailto). `on_context` is
// sent on a right-click or the Menu key, as a `styled_text`'s is, for a
// `context_menu` whose Copy and Select All call `editor_action` with the
// view. Each setting stays until changed.
//
// The target `on_link` and `on_image` carry is the *view's* memory, and the
// view lets it go the next time that block is laid out — which, while a
// reply streams, is straight away. Open it or clone it in the same update;
// do not put it in the app's state as it stands.
//
// `prose_width` caps how wide *prose* is and centres it in the view;
// tables, code blocks and pictures share its left edge but may run on to
// the view's right edge. 0 (the default) leaves everything full width. For
// a wide window: the table gets room, the paragraphs stay readable (45-75
// characters; WCAG 1.4.8 asks for under 80). Inter at 14.5 px averages
// about 7 px a character, so 680 is about 95; measure your own body face.
//
//	baldr.md_view_options(ui, reply, prose_width = 680) // in a 1,200 px view
md_view_options :: proc(ui: ^Ui($Msg), n: Node, on_link: Handler(Msg, string) = nil,
	on_image: Handler(Msg, string) = nil, language: proc(name: string) -> ^Language = nil,
	prose_width: f32 = 0, on_context: Handler(Msg, Editor_Context) = nil) {
	if handler_live(on_link) { ui.md_links[n] = on_link } else { delete_key(&ui.md_links, n) }
	if handler_live(on_image) { ui.md_images[n] = on_image } else { delete_key(&ui.md_images, n) }
	if handler_live(on_context) { ui.editor_contexts[n] = on_context } else { delete_key(&ui.editor_contexts, n) }
	s := &ui.tree.md_views[n]
	if s == nil do return
	if s.language != language { // a different lookup may colour a fence differently
		s.language = language
		s.rev = 0
		mark_layout_dirty(&ui.tree, n)
	}
	if s.prose_w != prose_width {
		s.prose_w = prose_width
		mark_layout_dirty(&ui.tree, n)
	}
}

// md_view_image hands the view a picture it is to draw for `src` — the
// target of a `![alt](src)` in the document. The view never fetches
// anything: what it is not given, it shows as its alt text. Call it while
// building, every build, for each picture the app has; `img` stays the
// app's.
//
// The view holds the pointer until the app hands over another picture for
// that `src`, the view goes, or `image_forget(ui, img)` says it is about to
// be freed — a build that skips it (an unchanged `component`) must not make
// pictures disappear. So call `image_forget` before freeing one. The pixels
// come from the app's memory; the toolkit never puts them on disk.
md_view_image :: proc(ui: ^Ui($Msg), n: Node, src: string, img: ^Image) {
	s := &ui.tree.md_views[n]
	if s == nil || len(src) == 0 || img == nil do return
	key := strings.clone(src, ui.tree.allocator)
	if old, had := s.images[src]; had {
		delete(key, ui.tree.allocator)
		if old != img { // a different picture is a different height: lay it out again
			s.images[src] = img
			s.rev = 0
			mark_layout_dirty(&ui.tree, n)
		}
		return
	}
	s.images[key] = img
	s.rev = 0 // a picture the layout has not seen changes the height
	mark_layout_dirty(&ui.tree, n)
}

// md_view_link_press sends the app a link the person pressed. It runs
// before the selection does, so a press on a link is a press on the link.
@(private)
md_view_link_press :: proc(ui: ^Ui($Msg), n: Node, pos: [2]f32) -> bool {
	h, has := ui.md_links[n]
	if !has do return false
	href := md_view_link_at(&ui.tree, n, pos)
	if len(href) == 0 do return false
	return handler_send(ui, h, href, n)
}

// md_view_paint_code draws a fenced block in its language's colours, from
// the same tokenizer and the same theme colours the code editor uses, so a
// snippet in a reply and the same snippet being edited look alike. Text no
// token claims is drawn in the ordinary ink.
@(private)
md_view_paint_code :: proc(t: ^Tree, l: ^Layer, c: Md_Line_Cache, lang: ^Language, x0, y0: f32, ink: Color) {
	th := &t.theme
	lay := c.lay
	st := lay.styles[0] if len(lay.styles) > 0 else Rich_Style{size = th.type.body.size, mono = true}
	toks := make([dynamic]Token, 0, 32, context.temp_allocator)
	tokenize_line(lang, c.text, 0, &toks) // the language's own tokenizer, as the code editor uses
	piece :: proc(l: ^Layer, text: string, lay: ^Rich_Layout, li, a, b: int, x0, y: f32, st: Rich_Style, col: Color) {
		if b <= a do return
		spans := rich_spans(lay, li, a, b) // a token is drawn from its left, whichever way it runs
		left := spans[0][0] if len(spans) > 0 else rich_x(lay, li, a)
		for sp in spans do left = min(left, sp[0])
		append(&l.cmds, Draw_Text{pos = {x0 + left, y}, str = text[a:b], size = st.size,
			color = col, mono = true, family = st.family})
	}
	for line, li in lay.lines {
		y := y0 + line.y
		at := line.start
		for tk in toks {
			a, b := max(tk.start, line.start), min(tk.end, line.end)
			if b <= a do continue
			piece(l, c.text, &lay, li, at, a, x0, y, st, ink) // what no token claimed
			piece(l, c.text, &lay, li, a, b, x0, y, st, code_token_color(th, tk.kind))
			at = b
		}
		piece(l, c.text, &lay, li, at, line.end, x0, y, st, ink)
	}
}

// md_view_image_press sends the app a picture the person pressed, by its
// markdown src, so it can be opened the app's own way (from memory, since
// the pictures need never touch disk).
@(private)
md_view_image_press :: proc(ui: ^Ui($Msg), n: Node, s: ^Md_View_State, pos: [2]f32) -> bool {
	h, has := ui.md_images[n]
	if !has || s.md == nil do return false
	d := node_get(&ui.tree, n)
	if d == nil do return false
	y := pos.y - d.abs.y
	for c, i in s.blocks {
		if i >= len(s.md.blocks) do continue
		b := s.md.blocks[i]
		if b.meta.kind != .Image || c.picture == nil do continue
		if y < c.top || y >= c.top + c.height do continue
		return handler_send(ui, h, b.meta.src, n)
	}
	return false
}

// md_view_images_free lets go of the picture map's keys (the pictures
// themselves are the app's).
@(private)
md_view_images_free :: proc(t: ^Tree, s: ^Md_View_State) {
	for key in s.images do delete(key, t.allocator)
	delete(s.images)
	s.images = nil
}

// md_view_gap is the space above a block, by what it is and what came
// before it. Uniform spacing reads as a wall of text — a heading needs air
// above it, list items belong together, and a code block wants room on
// both sides.
@(private)
md_view_gap :: proc(t: ^Tree, prev, kind: Block_Kind, joined := false) -> f32 {
	sp := &t.theme.space
	list :: proc(k: Block_Kind) -> bool { return k == .Bullet || k == .Numbered || k == .Task }
	switch {
	// Two paragraph lines with no blank line between them are one paragraph
	// hard-wrapped by its writer. A blank line leaves a hole in the source
	// ranges, which is how the two tell apart.
	case joined && kind == .Paragraph && prev == .Paragraph: return 0
	case kind == .Heading:                   return sp[.lg]  // air above a new section
	case prev == .Heading:                   return sp[.xs]  // …and its text follows close
	case list(kind) && list(prev):           return sp[.xs]  // items of one list belong together
	case kind == .Code && prev == .Code:     return 0        // lines of one fence: their line height is the spacing
	case kind == .Code || prev == .Code:     return sp[.md]
	case kind == .Rule || prev == .Rule:     return sp[.md]
	case kind == .Table && prev == .Table:   return 0        // rows of one table
	case kind == .Image || prev == .Image:   return sp[.md]
	}
	return sp[.sm]
}

// md_view_table_group is the run of rows the table containing `b` is made
// of, consecutive .Table blocks being one table.
@(private)
md_view_table_group :: proc(s: ^Md_View_State, b: int) -> (first, last: int) {
	first, last = b, b
	for first > 0 && s.md.blocks[first - 1].meta.kind == .Table do first -= 1
	for last + 1 < len(s.md.blocks) && s.md.blocks[last + 1].meta.kind == .Table do last += 1
	return
}

// md_view_table_align is how each of a table's columns is set: what the
// separator line asked for, and for any column it said nothing about, a
// right alignment when every body cell in it is a number.
//
// The separator is not kept as a block, so it is read back out of the
// source between the header and the next row. Alignment rows are rare in
// practice, which is why the numeric rule matters. The frame's memory.
@(private)
md_view_table_align :: proc(t: ^Tree, s: ^Md_View_State, b: int, allocator := context.temp_allocator) -> []Table_Align {
	first, last := md_view_table_group(s, b)
	cells_of :: proc(s: ^Md_View_State, r: int) -> (string, [][2]int) {
		blk := s.md.blocks[r]
		line := string(s.md.src[blk.from:blk.to])
		shown := markdown_render_line(line, false, false, context.temp_allocator)
		return shown.text, table_cells(shown.text)
	}
	_, head := cells_of(s, first)
	if len(head) == 0 do return nil
	out := make([]Table_Align, len(head), allocator)

	// what the table asked for, if it asked
	if first + 1 <= last {
		gap := string(s.md.src[s.md.blocks[first].to:s.md.blocks[first + 1].from])
		for line in strings.split_lines_iterator(&gap) {
			said := table_sep_align(line)
			for a, i in said do if i < len(out) do out[i] = a
			if len(said) > 0 do break
		}
	}

	// …and for the rest, a column whose body is all figures lines up right
	for ci in 0 ..< len(out) {
		if out[ci] != .Default do continue
		all_numbers, seen := true, false
		for r in first + 1 ..= last {
			text, cells := cells_of(s, r)
			if ci >= len(cells) do continue
			one := [1][2]int{cells[ci]}
			if strings.trim_space(text[cells[ci][0]:cells[ci][1]]) == "" do continue
			seen = true
			if !table_cells_numeric(text, one[:]) {
				all_numbers = false
				break
			}
		}
		if seen && all_numbers do out[ci] = .Right
	}
	return out
}

// md_view_table_cols measures the table `b` belongs to: every column as
// wide as its widest cell, scaled down together to fit the view. The same
// shape the editors use (`area_table_cols`), so a table reads the same
// whether it is in a reply or in a document being edited.
@(private)
md_view_table_cols :: proc(t: ^Tree, s: ^Md_View_State, b: int, wrap_w: f32, allocator := context.temp_allocator) -> []f32 {
	first, last := md_view_table_group(s, b)
	widths := make([dynamic]f32, context.temp_allocator)
	mins := make([dynamic]f32, context.temp_allocator)
	// Measure each row in the style it is *drawn* in: the header row is bold,
	// and bold is wider, so measured as regular its column would be too
	// narrow for its own heading.
	body := md_view_style(t, .Table, 0) // for the minimum width below: the size is the same either way
	for r in first ..= last {
		blk := s.md.blocks[r]
		base := md_view_style(t, .Table, blk.meta.level)
		line := string(s.md.src[blk.from:blk.to])
		shown := markdown_render_line(line, false, false, context.temp_allocator)
		lay := rich_layout(t, shown.text, shown.runs, base, 0, context.temp_allocator)
		for cell, ci in table_cells(shown.text) {
			w := lay.cum[cell[1]] - lay.cum[cell[0]] + TABLE_CELL_PAD * 2
			m := table_cell_min(&lay, shown.text, cell) + TABLE_CELL_PAD * 2
			if ci >= len(widths) {
				append(&widths, w)
				append(&mins, m)
			} else {
				widths[ci] = max(widths[ci], w)
				mins[ci] = max(mins[ci], m)
			}
		}
	}
	for &w in widths do w = max(w, TABLE_CELL_PAD * 2 + body.size)
	for &m, i in mins do m = clamp(m, TABLE_CELL_PAD * 2 + body.size, widths[i])
	// Whole pixels, so a column is never a hair under its own cell:
	// table_row_layout recovers a cell's room as `cols[ci+1] - cols[ci] -
	// TABLE_CELL_PAD * 2`, and that f32 round trip can land a few ULPs under
	// the natural width, wrapping the very cell the column was sized for.
	// Only the widths: rounding up `mins` would inflate table_fit_cols's
	// floor and tip it into proportional scaling that starves a narrow
	// column of its heading.
	for &w in widths do w = math.ceil(w)
	table_fit_cols(widths[:], mins[:], wrap_w)
	cols := make([]f32, len(widths) + 1, allocator)
	x: f32
	for w, i in widths {
		cols[i] = x
		x += w
	}
	cols[len(widths)] = x
	return cols
}

// md_view_paint_table draws the rules a table needs to be read as one: a
// line under the header row, and a hairline between the rows under it —
// never under the last row, which is the table's edge.
//
// Every rule is one logical pixel high: a half-pixel one is rounded to the
// device grid at both edges, so it survives or vanishes with the fraction
// its row lands on.
@(private)
md_view_paint_table :: proc(t: ^Tree, l: ^Layer, c: Md_Line_Cache, header, last: bool, x, y: f32, line: Color) {
	w := c.cols[len(c.cols) - 1] if len(c.cols) > 0 else 0
	if w <= 0 || last do return
	col := line
	col.a *= 0.9 if header else 0.45
	append(&l.cmds, Draw_Rect{rect = {x, y + c.height - 1, w, 1}, color = col})
}

// md_view_selection_clear_others lets go of every other reply's selection.
// A chat is a column of views, each with its own selection; two lit at once
// makes Ctrl+C look like a guess. One selection at a time, as in a document.
@(private)
md_view_selection_clear_others :: proc(t: ^Tree, keep: Node) {
	for n, &other in t.md_views {
		if n == keep || other.sel_a == other.sel_b do continue
		other.sel_a, other.sel_b = 0, 0
		other.dragging = false
		mark_paint_dirty(t, n)
	}
}
