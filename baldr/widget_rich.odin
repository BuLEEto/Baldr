package baldr

// rich_text is the text area engine with the document's kinds and runs
// switched on: headings, bullet / numbered / task lists (nested), quotes,
// code blocks and rules, with bold, italic, underline, strike, inline
// code and links inside. A toolbar above reflects the selection and
// applies formatting; the keys do the same (Ctrl+B / I / U, Ctrl+E code,
// Ctrl+K link); typing markdown at the start of a line converts it
// ("# ", "- ", "1. ", "[ ] ", "> ", "```"); Enter on an empty list item
// leaves the list, Backspace at the start of a styled block makes it a
// paragraph, Tab / Shift+Tab nest list items. A click on a task's box
// ticks it; Ctrl+click on a link sends `on_link`. The Document is the
// app's; document_markdown / document_set_markdown move it to and from
// markdown. Accessibility: Text_Input named `label`, the toolbar a
// Toolbar of named Buttons with Pressed states, the link bar a Group.
//
//	baldr.rich_text(ui, &s.notes, on_change = proc(e: baldr.Ev(int)) -> Msg { return Edited{} }, label = "Notes")

import "base:runtime"
import "core:fmt"
import "core:strings"

// Image_Source resolves an image block's `src` (a path, a URL, a name) to
// a picture the app keeps alive; nil = not available (the alt text shows).
Image_Source :: #type proc(src: string) -> ^Image

Rich_State :: struct {
	images:     Image_Source,
	on:         bool,
	pending:    Attrs, // style toggled at a caret, applied to the next typing
	pending_at: Pos,
	pending_valid: bool,
	link_open:  bool,
	image_bar:  bool,  // the bar asks for an image source instead of a link
	link_text:  Text,  // the link bar's href (owned)
	link_field: Node,
	toolbar:    bool,
	frame:      Node,
	numbers:    [dynamic]u8, // list numbers for the draw list (borrowed by it)
	built_caret, built_anchor: Pos, // what the toolbar was built for
	built_version: u64,
	built_pending: Attrs,
	built_pending_valid: bool,
	asked: bool, // a rebuild was asked for and the builder has not run since (a skipped component)
	asked_caret, asked_anchor: Pos,
	asked_version: u64,
}

// rich_tick rebuilds an editor whose toolbar no longer matches its
// selection (a caret move does not rebuild on its own). It asks once per
// change: an editor inside a skipped `component` cannot rebuild, and
// asking again every wake-up would spin.
rich_tick :: proc(ui: ^Ui($Msg)) {
	// An editor with `follow_caret` (its app draws something that depends on
	// where the caret is, as the toolbar's pressed states do) is built again
	// when the caret moves, whatever kind of editor it is.
	for _, &s in ui.tree.areas {
		if s.follow_caret && s.doc != nil && (s.caret != s.caret_built || s.anchor != s.anchor_built) {
			ask_rebuild(ui)
			return
		}
	}
	for _, &s in ui.tree.areas {
		if !s.rich || !s.rich_state.toolbar || s.doc == nil do continue
		r := &s.rich_state
		stale := r.built_caret != s.caret || r.built_anchor != s.anchor || r.built_version != s.doc.version ||
			r.built_pending != r.pending || r.built_pending_valid != r.pending_valid
		if !stale do continue
		if r.asked && r.asked_caret == s.caret && r.asked_anchor == s.anchor && r.asked_version == s.doc.version do continue
		r.asked = true
		r.asked_caret, r.asked_anchor, r.asked_version = s.caret, s.anchor, s.doc.version
		ask_rebuild(ui)
		return
	}
}

@(private)
rich_state_destroy :: proc(t: ^Tree, r: ^Rich_State) {
	text_destroy(&r.link_text)
	delete(r.numbers)
	r^ = {}
}

// Rich actions (toolbar buttons and keys share them).
Rich_Action :: enum u8 {
	None, Bold, Italic, Underline, Strike, Code, Highlight, Link, H1, H2, H3, Paragraph,
	Bullet, Numbered, Task, Quote, Code_Block, Rule, Undo, Redo, Link_Apply, Link_Remove, Link_Close,
	Image, Image_Apply, Table,
}

// editor_images gives a rich or live editor the pictures behind its image
// blocks (`![alt](src)` in markdown). Stays until changed.
editor_images :: proc(ui: ^Ui($Msg), n: Node, images: Image_Source) {
	t := &ui.tree
	area := n
	if a, has := t.area_of_frame[n]; has do area = a
	if s := &t.areas[area]; s != nil && s.rich_state.images != images {
		s.rich_state.images = images
		s.tops_valid = false // the pictures' heights change the layout
		mark_layout_dirty(t, area)
	}
}

// rich_image_height is the height an image block draws at: the picture
// scaled to the text width, capped, or a placeholder when unresolved.
@(private)
rich_image_height :: proc(t: ^Tree, s: ^Text_Area_State, b: int) -> f32 {
	meta := area_meta(t, s, b)
	if img := rich_image_of(s, meta.src); image_sides_ok(img) {
		w := min(f32(img.width), max(s.wrap_w, 1) if s.wrap_w > 0 else f32(img.width))
		return min(w * f32(img.height) / f32(img.width), RICH_IMAGE_MAX_H)
	}
	return RICH_IMAGE_PLACEHOLDER_H
}

@(private)
rich_image_of :: proc(s: ^Text_Area_State, src: string) -> ^Image {
	if s.rich_state.images == nil || len(src) == 0 do return nil
	return s.rich_state.images(src)
}

RICH_ACTION_BASE :: u64(200)

rich_text :: proc(ui: ^Ui($Msg), doc: ^Document, on_change: Handler(Msg, int) = nil, label: string = "Text",
	placeholder: string = "", width: f32 = 0, height: f32 = 0, flex: f32 = 0, on_link: Handler(Msg, string) = nil,
	on_context: Handler(Msg, Editor_Context) = nil, disabled := false, focus := false, tag: u64 = 0, key: u64 = 0, loc := #caller_location) -> Node {
	t := &ui.tree
	frame := column(ui, gap = .xs, width = width, flex = flex, key = key, loc = loc)
	area := t.area_of_frame[frame]
	s := &t.areas[area]
	toolbar := s == nil || s.rich_state.toolbar // a fresh editor has one
	readonly := s != nil && s.readonly
	if toolbar && !disabled do rich_toolbar_build(ui, area, s, doc, readonly, loc) // on the first build with no state yet: all toggles off
	if s != nil && s.rich_state.link_open && !disabled do rich_link_bar_build(ui, area, s, loc)
	area = area_build(ui, doc, placeholder, on_change, nil, on_context, label, 0, height, 1 if height == 0 else 0, disabled, tag, 1, loc, focus = focus,
		mono = false, def_wrap = true, def_min_lines = 6)
	if t.area_of_frame[frame] != area do ask_rebuild(ui) // first build: the toolbar was wired before the area existed
	t.area_of_frame[frame] = area
	s = &t.areas[area]
	if !s.rich {
		s.rich = true
		s.tops_valid = false
		s.rich_state.toolbar = true
		s.rich_state.link_text = text_make("", t.allocator)
		s.rich_state.numbers = make([dynamic]u8, t.allocator)
		mark_layout_dirty(t, area)
	}
	s.rich_state.asked = false
	s.rich_state.on = true
	s.rich_state.frame = frame
	s.rich_state.built_caret, s.rich_state.built_anchor = s.caret, s.anchor
	s.rich_state.built_version = doc.version if doc != nil else 0
	s.rich_state.built_pending, s.rich_state.built_pending_valid = s.rich_state.pending, s.rich_state.pending_valid
	ui.on_link[area] = on_link
	if s.rich_state.pending_valid && s.rich_state.pending_at != s.caret do s.rich_state.pending_valid = false
	end(ui)
	return frame
}

// ------------------------------------------------------------ toolbar

@(private)
rich_toolbar_build :: proc(ui: ^Ui($Msg), area: Node, s: ^Text_Area_State, doc: ^Document, readonly: bool, loc: runtime.Source_Code_Location) {
	t := &ui.tree
	bar := wrap(ui, gap = .xxs, align = .Center, key = 2, loc = loc)
	set_role(t, bar, .Toolbar)
	set_name(t, bar, "Formatting")
	all: Attrs
	meta: Block_Meta
	can_undo, can_redo := false, false
	if s != nil && s.doc != nil {
		all, _ = document_attrs(s.doc, s.caret, s.anchor)
		if s.rich_state.pending_valid && s.caret == s.anchor do all = s.rich_state.pending
		meta = block_meta(s.doc, s.caret.block)
		can_undo, can_redo = len(s.doc.undo) > 0, len(s.doc.redo) > 0
	} else if doc != nil {
		meta = block_meta(doc, 0)
	}
	tb :: proc(ui: ^Ui($Msg), area: Node, ic: Icon, name: string, action: Rich_Action, on: bool, disabled: bool, key: u64, loc: runtime.Source_Code_Location) {
		rich_tool_button(ui, area, ic, name, action, on, disabled, key, loc)
	}
	tb(ui, area, .Bold, "Bold", .Bold, .Bold in all, readonly, 10, loc)
	tb(ui, area, .Italic, "Italic", .Italic, .Italic in all, readonly, 11, loc)
	tb(ui, area, .Underline, "Underline", .Underline, .Underline in all, readonly, 12, loc)
	tb(ui, area, .Strikethrough, "Strikethrough", .Strike, .Strike in all, readonly, 13, loc)
	tb(ui, area, .Code, "Inline code", .Code, .Code in all, readonly, 14, loc)
	tb(ui, area, .Highlighter, "Highlight", .Highlight, .Highlight in all, readonly, 33, loc)
	tb(ui, area, .Link, "Link", .Link, .Link in all, readonly, 15, loc)
	rich_tool_gap(ui, 16, loc)
	tb(ui, area, .Heading_1, "Heading 1", .H1, meta.kind == .Heading && meta.level == 1, readonly, 17, loc)
	tb(ui, area, .Heading_2, "Heading 2", .H2, meta.kind == .Heading && meta.level == 2, readonly, 18, loc)
	tb(ui, area, .Heading_3, "Heading 3", .H3, meta.kind == .Heading && meta.level == 3, readonly, 19, loc)
	tb(ui, area, .Pilcrow, "Paragraph", .Paragraph, meta.kind == .Paragraph, readonly, 20, loc)
	rich_tool_gap(ui, 21, loc)
	tb(ui, area, .List, "Bullet list", .Bullet, meta.kind == .Bullet, readonly, 22, loc)
	tb(ui, area, .List_Ordered, "Numbered list", .Numbered, meta.kind == .Numbered, readonly, 23, loc)
	tb(ui, area, .List_Todo, "Task list", .Task, meta.kind == .Task, readonly, 24, loc)
	tb(ui, area, .Text_Quote, "Quote", .Quote, meta.kind == .Quote, readonly, 25, loc)
	tb(ui, area, .File_Code, "Code block", .Code_Block, meta.kind == .Code, readonly, 26, loc)
	tb(ui, area, .Minus, "Horizontal rule", .Rule, false, readonly, 27, loc)
	tb(ui, area, .Image, "Image", .Image, meta.kind == .Image, readonly, 31, loc)
	tb(ui, area, .Table, "Table", .Table, meta.kind == .Table, readonly, 32, loc)
	rich_tool_gap(ui, 28, loc)
	tb(ui, area, .Undo_2, "Undo", .Undo, false, readonly || !can_undo, 29, loc)
	tb(ui, area, .Redo_2, "Redo", .Redo, false, readonly || !can_redo, 30, loc)
	end(ui)
}

@(private)
rich_tool_gap :: proc(ui: ^Ui($Msg), key: u64, loc: runtime.Source_Code_Location) {
	th := &ui.tree.theme
	r := row(ui, width = 11, height = 28, align = .Center, justify = .Center, key = key, loc = loc)
	set_role(&ui.tree, r, .Separator)
	box(ui, width = 1, height = 18, bg = th.color.outline_variant, loc = loc)
	end(ui)
}

// rich_tool_button: an icon toggle routed to the editor.
@(private)
rich_tool_button :: proc(ui: ^Ui($Msg), area: Node, ic: Icon, name: string, action: Rich_Action, on, disabled: bool, key: u64, loc: runtime.Source_Code_Location) -> Node {
	t := &ui.tree
	th := &t.theme
	b, created := reconcile_child(ui, .Box, key, loc)
	d := node_get(t, b)
	if created {
		d.access.role = .Button
		d.flags += {.Focusable}
	}
	set_name(t, b, name)
	set_disabled(t, b, disabled)
	if on { d.access.states += {.Pressed}; d.flags += {.Pressed} } else { d.access.states -= {.Pressed}; d.flags -= {.Pressed} }
	d.tag = RICH_ACTION_BASE + u64(action)
	t.editor_ctl_of[b] = area
	set_layout(t, b, Layout_Props{axis = .Row, align = .Center, justify = .Center, width = 30, height = 28})
	st := d.style
	st.radius = th.radius.sm
	st.bg = th.color.primary_container if on else Color{}
	set_style(t, b, st)
	open_scope(ui, b, loc)
	col := th.color.on_primary_container if on else th.color.on_surface
	baldr_icon(ui, ic, ICON_SIZE, col, loc)
	close_scope(ui)
	return b
}

// rich_link_bar_build: the href field with Apply / Remove / Close.
@(private)
rich_link_bar_build :: proc(ui: ^Ui($Msg), area: Node, s: ^Text_Area_State, loc: runtime.Source_Code_Location) {
	t := &ui.tree
	th := &t.theme
	r := &s.rich_state
	bar := row(ui, gap = .sm, align = .Center, padding = .xs, bg = th.color.surface_high, radius = th.radius.sm, key = 3, loc = loc)
	set_role(t, bar, .Group)
	set_name(t, bar, "Image" if r.image_bar else "Link")
	baldr_icon(ui, .Image if r.image_bar else .Link, ICON_SIZE, th.color.on_surface_muted, loc)
	r.link_field = text_input(ui, &r.link_text, placeholder = "picture.png" if r.image_bar else "https://", label = "Image source" if r.image_bar else "Link address", width = 260, key = 4, loc = loc)
	t.editor_ctl_of[r.link_field] = area
	if r.image_bar {
		rich_text_button(ui, area, "Insert", .Image_Apply, 5, loc)
	} else {
		rich_text_button(ui, area, "Apply", .Link_Apply, 5, loc)
		rich_text_button(ui, area, "Remove", .Link_Remove, 6, loc)
	}
	spacer(ui, loc = loc)
	rich_tool_button(ui, area, .X, "Close link", .Link_Close, false, false, 7, loc)
	if r.link_field != NODE_NONE && t.focus != r.link_field && t.focus == area do ui.pending_focus = r.link_field
	end(ui)
}

@(private)
rich_text_button :: proc(ui: ^Ui($Msg), area: Node, label: string, action: Rich_Action, key: u64, loc: runtime.Source_Code_Location) -> Node {
	t := &ui.tree
	th := &t.theme
	b, created := reconcile_child(ui, .Box, key, loc)
	d := node_get(t, b)
	if created {
		d.access.role = .Button
		d.flags += {.Focusable}
	}
	set_name(t, b, label)
	d.tag = RICH_ACTION_BASE + u64(action)
	t.editor_ctl_of[b] = area
	set_layout(t, b, Layout_Props{axis = .Row, align = .Center, justify = .Center, height = 28, padding = {0, th.space[.sm], 0, th.space[.sm]}})
	st := d.style
	st.radius = th.radius.sm
	st.border_w = 1
	st.border = th.color.outline
	set_style(t, b, st)
	open_scope(ui, b, loc)
	lbl := text(ui, label, role = .Label, nowrap = true, loc = loc)
	set_role(t, lbl, .None)
	close_scope(ui)
	return b
}

// rich_ctl_click routes a toolbar / link bar button to its action.
@(private)
rich_ctl_click :: proc(ui: ^Ui($Msg), n: Node) -> bool {
	t := &ui.tree
	area, ok := t.editor_ctl_of[n]
	if !ok do return false
	d := node_get(t, n)
	s := &t.areas[area]
	if d == nil || s == nil || !s.rich || d.tag < RICH_ACTION_BASE do return false
	if .Disabled in d.flags do return true
	action := Rich_Action(d.tag - RICH_ACTION_BASE)
	rich_act(ui, area, s, action)
	// a click on a toolbar button returns focus to the text, so the caret and selection carry on;
	// the link actions manage focus themselves (the bar's field takes it)
	if action != .Link && action != .Link_Apply && action != .Link_Remove && action != .Link_Close && action != .Image && action != .Image_Apply do set_focus(t, area, false)
	return true
}

// ------------------------------------------------------------ actions

// rich_apply performs a formatting action on the rich or markdown editor
// built as `frame` (its frame or the area) — what its toolbar and its
// shortcuts do — for an app's own toolbar or menu:
// `rich_apply(ui, editor, .Bold)`. It acts on the selection, or on the word
// at the caret where a mark needs one (Bold, Italic, Code, Strike,
// Highlight, Link), and is one undo step.
//
// A rich editor keeps the formatting in the Document's runs and kinds; a
// markdown editor edits its source instead, putting `**`, `` ` ``, `==`,
// `#`, `- `, `> ` or ``` ``` ``` in the text, so what is saved is the
// markdown. Its Link and Image write `[text](url)` and `![text](url)` with
// the address selected, since it has no link bar, and the bar's own actions
// (Link_Apply, Link_Remove, Link_Close, Image_Apply) do nothing there.
// Focus returns to the text, as it does from the toolbar.
rich_apply :: proc(ui: ^Ui($Msg), frame: Node, action: Rich_Action) {
	t := &ui.tree
	area, ok := t.area_of_frame[frame]
	if !ok do area = frame
	s := &t.areas[area]
	if s == nil || !s.rich || s.doc == nil do return
	if s.live { live_act(ui, area, s, action) } else { rich_act(ui, area, s, action) }
	// the link and image bars take the focus themselves; everything else hands it back to the text
	if s.live || (action != .Link && action != .Link_Apply && action != .Link_Remove && action != .Link_Close && action != .Image && action != .Image_Apply) do set_focus(t, area, false)
}

// editor_selection is the selection of a text area, code editor or rich
// editor built as `n` (its frame or the area), as ordered positions in
// its Document; an app formats or inspects that range through the
// Document API.
//
// `lo` is always before `hi`, whichever way the person dragged. When the
// direction matters, read `editor_caret`, which gives the caret and its
// anchor unswapped.
editor_selection :: proc(t: ^Tree, n: Node) -> (lo, hi: Pos, ok: bool) {
	area := n
	if a, has := t.area_of_frame[n]; has do area = a
	s := &t.areas[area]
	if s == nil || s.doc == nil do return
	lo, hi = pos_order(s.caret, s.anchor)
	return lo, hi, true
}

// rich_act performs one formatting action on the editor.
@(private)
rich_act :: proc(ui: ^Ui($Msg), n: Node, s: ^Text_Area_State, action: Rich_Action) {
	t := &ui.tree
	r := &s.rich_state
	if s.readonly && action != .Link_Close do return
	lo, hi := pos_order(s.caret, s.anchor)
	switch action {
	case .None:
	case .Bold:      rich_toggle_attr(ui, n, s, .Bold)
	case .Italic:    rich_toggle_attr(ui, n, s, .Italic)
	case .Underline: rich_toggle_attr(ui, n, s, .Underline)
	case .Strike:    rich_toggle_attr(ui, n, s, .Strike)
	case .Code:      rich_toggle_attr(ui, n, s, .Code)
	case .Highlight: rich_toggle_attr(ui, n, s, .Highlight)
	case .Link:
		r.link_open = true
		r.image_bar = false
		text_set(&r.link_text, href_at(s.doc, lo))
		ask_rebuild(ui)
		return
	case .Image:
		r.link_open = true
		r.image_bar = true
		text_set(&r.link_text, block_meta(s.doc, lo.block).src)
		ask_rebuild(ui)
		return
	case .Image_Apply:
		src := strings.trim_space(str(r.link_text))
		s.group += 1
		if block_meta(s.doc, lo.block).kind == .Image { // change the picture
			m := block_meta(s.doc, lo.block)
			m.src = src
			document_set_meta(s.doc, lo.block, m, s.group)
		} else if len(src) > 0 { // an image block after the caret's, then a paragraph to go on in
			end := Pos{lo.block, len(s.doc.blocks[lo.block].text)}
			p := document_replace(s.doc, end, end, "\n\n", s.group)
			document_set_meta(s.doc, lo.block + 1, {kind = .Image, src = src}, s.group)
			document_set_meta(s.doc, lo.block + 2, {kind = .Paragraph}, s.group)
			s.anchor, s.caret = p, p
		}
		rich_link_close(ui, n, s)
		rich_changed(ui, n, s)
		return
	case .Link_Apply:
		href := strings.trim_space(str(r.link_text))
		if lo == hi { // no selection: the word at the caret
			w0, w1 := word_at(block_str(s.doc, lo.block), lo.off)
			lo, hi = {lo.block, w0}, {lo.block, w1}
		}
		s.group += 1
		if len(href) > 0 {
			document_set_attrs(s.doc, lo, hi, {.Link}, {}, href = href, group = s.group)
		} else {
			document_set_attrs(s.doc, lo, hi, {}, {.Link}, group = s.group)
		}
		s.anchor, s.caret = lo, hi
		rich_link_close(ui, n, s)
		rich_changed(ui, n, s)
		return
	case .Link_Remove:
		if lo == hi {
			w0, w1 := word_at(block_str(s.doc, lo.block), lo.off)
			lo, hi = {lo.block, w0}, {lo.block, w1}
		}
		s.group += 1
		document_set_attrs(s.doc, lo, hi, {}, {.Link}, group = s.group)
		rich_link_close(ui, n, s)
		rich_changed(ui, n, s)
		return
	case .Link_Close:
		rich_link_close(ui, n, s)
		return
	case .H1:        rich_set_kind(ui, n, s, {kind = .Heading, level = 1})
	case .H2:        rich_set_kind(ui, n, s, {kind = .Heading, level = 2})
	case .H3:        rich_set_kind(ui, n, s, {kind = .Heading, level = 3})
	case .Paragraph: rich_set_kind(ui, n, s, {kind = .Paragraph})
	case .Bullet:    rich_set_kind(ui, n, s, {kind = .Bullet}, toggle = true)
	case .Numbered:  rich_set_kind(ui, n, s, {kind = .Numbered}, toggle = true)
	case .Task:      rich_set_kind(ui, n, s, {kind = .Task}, toggle = true)
	case .Quote:     rich_set_kind(ui, n, s, {kind = .Quote}, toggle = true)
	case .Code_Block: rich_set_kind(ui, n, s, {kind = .Code}, toggle = true)
	case .Rule:
		// a rule after the caret's block, then a paragraph to go on typing in
		end := Pos{lo.block, len(s.doc.blocks[lo.block].text)}
		s.group += 1
		p := document_replace(s.doc, end, end, "\n\n", s.group)
		document_set_meta(s.doc, lo.block + 1, {kind = .Rule}, s.group)
		document_set_meta(s.doc, lo.block + 2, {kind = .Paragraph}, s.group)
		s.anchor, s.caret = p, p
		rich_changed(ui, n, s)
	case .Table:
		// a two-column table after the caret's block: a header row and one row, the caret in the first cell
		end := Pos{lo.block, len(s.doc.blocks[lo.block].text)}
		s.group += 1
		document_replace(s.doc, end, end, "\n| Column | Column |\n|  |  |\n", s.group)
		document_set_meta(s.doc, lo.block + 1, {kind = .Table, level = 1}, s.group)
		document_set_meta(s.doc, lo.block + 2, {kind = .Table}, s.group)
		document_set_meta(s.doc, lo.block + 3, {kind = .Paragraph}, s.group)
		s.anchor, s.caret = {lo.block + 1, 2}, {lo.block + 1, 8}
		rich_changed(ui, n, s)
	case .Undo:
		if p, did := document_undo(s.doc); did do area_after_history(ui, n, s, p)
	case .Redo:
		if p, did := document_redo(s.doc); did do area_after_history(ui, n, s, p)
	}
	_ = t
}

@(private)
rich_changed :: proc(ui: ^Ui($Msg), n: Node, s: ^Text_Area_State) {
	t := &ui.tree
	area_break_typing(s) // typing after an action starts its own undo group
	s.goal_x = -1
	mark_layout_dirty(t, n)
	area_touch(t, n, s)
	area_changed(ui, n, s)
}

// rich_toggle_attr flips one attribute over the selection, or pends it at
// a caret for the next typing.
@(private)
rich_toggle_attr :: proc(ui: ^Ui($Msg), n: Node, s: ^Text_Area_State, a: Attr) {
	t := &ui.tree
	r := &s.rich_state
	lo, hi := pos_order(s.caret, s.anchor)
	if lo == hi {
		if !r.pending_valid || r.pending_at != s.caret {
			r.pending = attrs_at(s.doc, s.caret)
			r.pending_at = s.caret
			r.pending_valid = true
		}
		if a in r.pending { r.pending -= {a} } else { r.pending += {a} }
		ask_rebuild(ui) // the toolbar reflects it
		mark_paint_dirty(t, n)
		return
	}
	all, _ := document_attrs(s.doc, lo, hi)
	s.group += 1
	if a in all {
		document_set_attrs(s.doc, lo, hi, {}, {a}, group = s.group)
	} else {
		document_set_attrs(s.doc, lo, hi, {a}, {}, group = s.group)
	}
	rich_changed(ui, n, s)
}

// rich_set_kind sets the kind of every block in the selection (toggling
// back to a paragraph when they all have it already and `toggle`).
@(private)
rich_set_kind :: proc(ui: ^Ui($Msg), n: Node, s: ^Text_Area_State, meta: Block_Meta, toggle := false) {
	lo, hi := pos_order(s.caret, s.anchor)
	all := true
	for b in lo.block ..= hi.block do if block_meta(s.doc, b).kind != meta.kind do all = false
	s.group += 1
	for b in lo.block ..= hi.block {
		cur := block_meta(s.doc, b)
		m := meta
		if toggle && all do m = {kind = .Paragraph}
		if m.kind == cur.kind && (m.kind == .Bullet || m.kind == .Numbered || m.kind == .Task) do m.depth = cur.depth // keep nesting
		if m.kind == .Code do m.lang = cur.lang
		document_set_meta(s.doc, b, m, s.group)
	}
	rich_changed(ui, n, s)
}

@(private)
rich_link_close :: proc(ui: ^Ui($Msg), n: Node, s: ^Text_Area_State) {
	r := &s.rich_state
	if !r.link_open do return
	r.link_open = false
	r.link_field = NODE_NONE
	set_focus(&ui.tree, n, false)
	ask_rebuild(ui)
}

// rich_typing_style is the style the next typed text takes: the pending
// toggles at the caret, else nothing (the document continues the run).
@(private)
rich_typing_style :: proc(s: ^Text_Area_State) -> Maybe(Run) {
	r := &s.rich_state
	if r.pending_valid && r.pending_at == s.caret && s.caret == s.anchor {
		return Run{attrs = r.pending}
	}
	return nil
}

// rich_after_type: markdown shortcuts at the start of a block, and the
// pending style is spent.
@(private)
rich_after_type :: proc(ui: ^Ui($Msg), n: Node, s: ^Text_Area_State, typed: string) {
	r := &s.rich_state
	if r.pending_valid { // the typed text carries the style now; typing on continues it
		r.pending_valid = false
		ask_rebuild(ui)
	}
	if s.readonly || (typed != " " && typed != "`") do return
	b := s.caret.block
	line := block_str(s.doc, b)
	head := line[:s.caret.off]
	meta := block_meta(s.doc, b)
	if meta.kind == .Code do return
	want: Block_Meta
	cut := 0
	switch {
	case head == "# ":      want, cut = {kind = .Heading, level = 1}, 2
	case head == "## ":     want, cut = {kind = .Heading, level = 2}, 3
	case head == "### ":    want, cut = {kind = .Heading, level = 3}, 4
	case head == "- " || head == "* ": want, cut = {kind = .Bullet}, 2
	case head == "1. ":     want, cut = {kind = .Numbered}, 3
	case head == "[] " || head == "[ ] " || head == "- [ ] ": want, cut = {kind = .Task}, len(head)
	case head == "> ":      want, cut = {kind = .Quote}, 2
	case head == "```":     want, cut = {kind = .Code}, 3
	case:
		return
	}
	if meta.kind == want.kind && meta.level == want.level do return
	// the same group as the keystroke that triggered it: one undo takes both back
	document_replace(s.doc, {b, 0}, {b, cut}, "", s.group)
	document_set_meta(s.doc, b, want, s.group)
	s.caret, s.anchor = {b, 0}, {b, 0}
	rich_changed(ui, n, s)
}

// rich_key: formatting shortcuts and the structural keys.
@(private)
rich_key :: proc(ui: ^Ui($Msg), n: Node, s: ^Text_Area_State, key: Key, mods: Mods) -> bool {
	t := &ui.tree
	ctrl, shift, alt := .Ctrl in mods, .Shift in mods, .Alt in mods
	lo, hi := pos_order(s.caret, s.anchor)
	meta := block_meta(s.doc, lo.block)
	listy := meta.kind == .Bullet || meta.kind == .Numbered || meta.kind == .Task
	#partial switch key {
	case .B:
		if !ctrl || shift || alt do return false
		rich_act(ui, n, s, .Bold)
		return true
	case .I:
		if !ctrl || shift || alt do return false
		rich_act(ui, n, s, .Italic)
		return true
	case .U:
		if !ctrl || shift || alt do return false
		rich_act(ui, n, s, .Underline)
		return true
	case .E:
		if !ctrl || shift || alt do return false
		rich_act(ui, n, s, .Code)
		return true
	case .H:
		if !ctrl || !shift || alt do return false // Ctrl+H alone is the code editor's replace
		rich_act(ui, n, s, .Highlight)
		return true
	case .K:
		if !ctrl || shift || alt do return false
		rich_act(ui, n, s, .Link)
		return true
	case .Tab:
		if ctrl || s.readonly do return false
		if meta.kind == .Table { // the next / previous cell, a new row past the last cell
			if table_step(ui, n, s, -1 if shift else +1) do return true
			return true
		}
		if !listy do return false
		s.group += 1
		for b in lo.block ..= hi.block {
			m := block_meta(s.doc, b)
			if m.kind != .Bullet && m.kind != .Numbered && m.kind != .Task do continue
			if shift { m.depth = m.depth - 1 if m.depth > 0 else 0 } else { m.depth = min(m.depth + 1, 6) }
			document_set_meta(s.doc, b, m, s.group)
		}
		rich_changed(ui, n, s)
		return true
	case .Enter:
		if ctrl || s.readonly do return false
		if meta.kind == .Table && lo.block == hi.block {
			// Shift+Enter, or Enter on an empty last row, leaves the table into a paragraph after it;
			// otherwise a new row below with as many cells (a selected cell is left as it is)
			_, last := table_group_of(s, lo.block)
			if shift || (lo.block == last && table_row_empty(block_str(s.doc, lo.block))) {
				table_leave(ui, n, s, lo.block)
			} else {
				table_add_row(ui, n, s, lo.block)
			}
			return true
		}
		if lo != hi do return false
		if meta.kind == .Rule { // typing past a rule starts a paragraph after it
			return false
		}
		if listy && len(block_str(s.doc, lo.block)) == 0 { // an empty item ends the list
			s.group += 1
			document_set_meta(s.doc, lo.block, {kind = .Paragraph}, s.group)
			rich_changed(ui, n, s)
			return true
		}
	case .Backspace:
		if lo != hi || lo.off != 0 || s.readonly do return false
		if meta.kind != .Paragraph { // the start of a styled block: back to a paragraph first
			s.group += 1
			document_set_meta(s.doc, lo.block, {kind = .Paragraph}, s.group)
			rich_changed(ui, n, s)
			return true
		}
		if lo.block > 0 && block_meta(s.doc, lo.block - 1).kind == .Rule { // remove the rule above
			s.group += 1
			document_replace(s.doc, {lo.block - 1, 0}, {lo.block, 0}, "", s.group)
			s.caret, s.anchor = {lo.block - 1, 0}, {lo.block - 1, 0}
			rich_changed(ui, n, s)
			return true
		}
	case .Escape:
		if s.rich_state.link_open {
			rich_link_close(ui, n, s)
			return true
		}
	}
	_ = t
	return false
}

// rich_ctl_key: keys in the link bar's field.
rich_ctl_key :: proc(ui: ^Ui($Msg), key: Key, mods: Mods) -> bool {
	t := &ui.tree
	area, ok := t.editor_ctl_of[t.focus]
	if !ok do return false
	s := &t.areas[area]
	if s == nil || !s.rich || t.focus != s.rich_state.link_field do return false
	#partial switch key {
	case .Enter:
		rich_act(ui, area, s, .Image_Apply if s.rich_state.image_bar else .Link_Apply)
		return true
	case .Escape:
		rich_link_close(ui, area, s)
		return true
	}
	return false
}

// rich_press: a click on a task's box ticks it; Ctrl+click on a link
// follows it. Returns true when the press was taken.
@(private)
rich_press :: proc(ui: ^Ui($Msg), n: Node, d: ^Node_Data, s: ^Text_Area_State, pos: [2]f32) -> bool {
	t := &ui.tree
	inner := input_inner(d)
	scroll := scroll_offset(t, n)
	y := pos.y - inner.y + scroll.y
	b := block_at_y(t, s, y)
	meta := block_meta(s.doc, b)
	x := pos.x - inner.x + scroll.x
	if meta.kind == .Task && x < block_indent(t, s, b) && !s.readonly {
		m := meta
		m.checked = !m.checked
		s.group += 1
		document_set_meta(s.doc, b, m, s.group)
		rich_changed(ui, n, s)
		return true
	}
	if follow_click(ui.pointer.mods) {
		p := area_hit(t, n, d, s, pos)
		if href := href_at(s.doc, p); len(href) > 0 {
			if h, has := ui.on_link[n]; has do handler_send(ui, h, href, n)
			return true
		}
	}
	return false
}

// ------------------------------------------------------------ paint

// rich_paint_block_under draws a block's box: a code block's background,
// a quote's bar, a rule, a list's bullet / number / checkbox. `first` is
// the first block painted; `view_lo` / `view_hi` bound what shows.
@(private)
rich_paint_block_under :: proc(t: ^Tree, s: ^Text_Area_State, l: ^Layer, b: int, first: bool, x0, top, inner_w, view_lo, view_hi, alpha: f32) {
	th := &t.theme
	meta := area_meta(t, s, b)
	blk := &meta
	_, indent, before, _ := area_block_style(t, s, b)
	lh := area_line_h(t, s, b)
	ty := top + before
	h := block_text_height(t, s, b)
	switch blk.kind {
	case .Paragraph, .Heading:
	case .Code:
		// a code block's lines are one box, rounded at its outer corners only: its first line
		// in view draws it whole, as far as it goes or past the view's edges, where the clip hides the ends
		if code_joins(t, s, b) && !first do break
		bg := th.color.surface_high
		bg.a *= alpha
		pad := th.space[.xs]
		reach := th.radius.sm + pad // a box end this far out of view shows nothing
		origin := block_top(t, s, b)
		a := b
		for code_joins(t, s, a) && top + block_top(t, s, a) - origin > view_lo - reach do a -= 1
		z := b
		for code_joins(t, s, z + 1) && top + block_top(t, s, z + 1) - origin < view_hi + reach do z += 1
		_, _, before_a, _ := area_block_style(t, s, a)
		_, _, before_z, _ := area_block_style(t, s, z)
		y0 := top + block_top(t, s, a) - origin + before_a - pad
		y1 := top + block_top(t, s, z) - origin + before_z + block_text_height(t, s, z) + pad
		append(&l.cmds, Draw_Rect{rect = {x0, y0, inner_w, y1 - y0}, radius = th.radius.sm, color = bg})
	case .Quote:
		bar := th.color.outline
		bar.a *= alpha
		append(&l.cmds, Draw_Rect{rect = {x0 + 4, ty, 3, h}, radius = 1.5, color = bar})
	case .Rule:
		line := th.color.outline_variant
		line.a *= alpha
		append(&l.cmds, Draw_Rect{rect = {x0, ty + lh / 2, inner_w, 1}, color = line})
	case .Table_Sep:
	case .Table:
		cols := area_table_cols(t, s, b)
		if len(cols) < 2 do break
		first, last := area_table_group(t, s, b)
		w := cols[len(cols) - 1]
		line := th.color.outline_variant
		line.a *= alpha
		if blk.level == 1 { // the header row
			tint := th.color.surface_high
			tint.a *= alpha
			append(&l.cmds, Draw_Rect{rect = {x0, ty, w, lh}, color = tint})
		}
		if b == first do append(&l.cmds, Draw_Rect{rect = {x0, ty, w, 1}, color = line})
		append(&l.cmds, Draw_Rect{rect = {x0, ty + lh - 1, w, 1}, color = line})
		for cx in cols do append(&l.cmds, Draw_Rect{rect = {x0 + cx - (1 if cx >= w else 0), ty, 1, lh}, color = line})
		_ = last
	case .Image:
		if area_raw(s, b) do break // raw: the source line shows
		ih := rich_image_height(t, s, b)
		if img := rich_image_of(s, blk.src); image_adds_up(img) {
			w := ih * f32(img.width) / f32(img.height)
			tint := Color{1, 1, 1, alpha}
			append(&l.cmds, Draw_Image{rect = {x0, ty, w, ih}, img = img, radius = th.radius.md, color = tint, fit = .Stretch})
		} else { // a placeholder box with the source's name
			bg := th.color.surface_high
			bg.a *= alpha
			append(&l.cmds, Draw_Rect{rect = {x0, ty, inner_w, ih}, radius = th.radius.md, color = bg, border_w = 1, border = th.color.outline_variant})
			ic := th.color.on_surface_muted
			ic.a *= alpha
			append(&l.cmds, Draw_Icon{pos = {x0 + 12, ty + ih / 2 - 10}, icon = .Image, size = 20, color = ic})
			append(&l.cmds, Draw_Text{pos = {x0 + 40, ty + ih / 2 - s.line_h / 2}, str = blk.src, size = s.size, color = ic, family = s.family})
		}
	case .Bullet:
		dot := area_ink_muted(t, s)
		dot.a *= alpha
		r: f32 = 2.5 if blk.depth == 0 else 2
		append(&l.cmds, Draw_Rect{rect = {x0 + indent - 14 - r, ty + lh / 2 - r, r * 2, r * 2}, radius = r, color = dot})
	case .Numbered:
		num := live_numbered_index(t, s, b) if s.live else numbered_index(s.doc, b)
		col := area_ink_muted(t, s)
		col.a *= alpha
		at := len(s.rich_state.numbers)
		buf: [16]u8
		label := fmt.bprintf(buf[:], "%d.", num)
		append(&s.rich_state.numbers, ..transmute([]u8)label)
		str := string(s.rich_state.numbers[at:at + len(label)])
		append(&l.cmds, Draw_Text{pos = {x0 + indent - RICH_LIST_INDENT, ty}, str = str, size = s.size, color = col, align = .End, box_w = RICH_LIST_INDENT - 8, family = s.family})
	case .Task:
		box_c := th.color.primary if blk.checked else th.color.outline
		box_c.a *= alpha
		size: f32 = 16
		bx := x0 + indent - RICH_LIST_INDENT + 2
		by := ty + (lh - size) / 2
		if blk.checked {
			append(&l.cmds, Draw_Rect{rect = {bx, by, size, size}, radius = 4, color = box_c})
			tick := th.color.on_primary
			tick.a *= alpha
			append(&l.cmds, Draw_Icon{pos = {bx + 2, by + 2}, icon = .Check, size = size - 4, color = tick})
		} else {
			append(&l.cmds, Draw_Rect{rect = {bx, by, size, size}, radius = 4, border_w = 1.5, border = box_c})
		}
	}
}

// rich_paint_block draws one block of an editor's document, in the ink the
// editor was given, through the shared `rich_draw_lines`.
@(private)
rich_paint_block :: proc(t: ^Tree, s: ^Text_Area_State, l: ^Layer, b: int, x0, y0, alpha: f32) {
	meta := area_meta(t, s, b)
	blk := &meta
	if blk.kind == .Rule && !(s.live && len(area_text(t, s, b)) > 0) do return // a raw "---" shows while edited
	if blk.kind == .Table_Sep && !area_raw(s, b) do return
	lay := area_rich(t, s, b)
	text := area_text(t, s, b)
	rich_draw_lines(t, l, lay, text, blk.kind, x0, y0, alpha,
		area_ink(t, s), area_ink_muted(t, s), area_ink_accent(t, s), area_ink_wash(t, s),
		area_mark_tints(t, s, b)) // a Dim or Tint mark colours the words themselves
}

// rich_draw_lines draws a laid-out block's text: one Draw_Text per run per
// line in the run's face, with underline, strike, inline code wash and link
// colour. It is the one place styled markdown text becomes draw commands —
// the editors paint through it with their own ink, a `markdown_view` with
// the theme's — so a reply and the same document being edited look alike.
@(private)
rich_draw_lines :: proc(t: ^Tree, l: ^Layer, lay: ^Rich_Layout, text: string, kind: Block_Kind,
	x0, y0, alpha: f32, ink, muted, accent, wash_col: Color, tints: []Mark_Tint = nil) {
	th := &t.theme
	lh := lay.line_h
	te := t.text
	for line in lay.lines {
		y := y0 + line.y
		for seg in line.segs {
			st := lay.styles[seg.run]
			col := ink
			if kind == .Quote || kind == .Image do col = muted
			if .Link in st.attrs do col = accent
			if .Mark in st.attrs do col = muted // a markdown mark, shown while the block is edited
			col.a *= alpha
			x := x0 + seg.x
			if .Code in st.attrs && kind != .Code {
				wash := wash_col
				wash.a *= alpha
				append(&l.cmds, Draw_Rect{rect = {x - 2, y + 1, seg.width + 4, lh - 2}, radius = 3, color = wash})
			}
			if .Highlight in st.attrs && .Mark not_in st.attrs { // a highlighter pen's stripe behind the words
				pen := th.color.warning
				pen.a = 0.28 * alpha
				append(&l.cmds, Draw_Rect{rect = {x - 1, y + 1, seg.width + 2, lh - 2}, radius = 2, color = pen})
			}
			// a smaller face sits on the line's baseline
			dy: f32
			if te != nil && te.ok do dy = lay.ascent - text_ascent(te, st.size, st.mono, st.family)
			if len(tints) > 0 {
				// A mark recolours these words: the segment goes down in
				// pieces of one colour each, at the x the layout already
				// gives every byte, so nothing moves.
				at := seg.start
				for at < seg.end {
					c := mark_tint_at(tints, at, col)
					z := at + 1
					for z < seg.end && mark_tint_at(tints, z, col) == c do z += 1
					c.a *= alpha
					dx := lay.cum[at] - lay.cum[seg.start] // within the segment, which knows its own x
					append(&l.cmds, Draw_Text{pos = {x + dx, y + dy}, str = text[at:z],
						size = st.size, color = c, weight = .Semibold if st.bold else .Regular,
						italic = st.italic, mono = st.mono, family = st.family})
					at = z
				}
			} else {
				append(&l.cmds, Draw_Text{pos = {x, y + dy}, str = text[seg.start:seg.end], size = st.size, color = col, weight = .Semibold if st.bold else .Regular, italic = st.italic, mono = st.mono, family = st.family})
			}
			if (.Underline in st.attrs || .Link in st.attrs) && .Mark not_in st.attrs {
				append(&l.cmds, Draw_Rect{rect = {x, y + lh - 3, seg.width, 1}, color = col})
			}
			if .Strike in st.attrs {
				append(&l.cmds, Draw_Rect{rect = {x, y + lh * 0.55, seg.width, 1}, color = col})
			}
		}
	}
}

// table_step moves the caret to the next (dir > 0) or previous cell of the
// table it is in, across rows; past the last cell it adds a row.
@(private)
table_step :: proc(ui: ^Ui($Msg), n: Node, s: ^Text_Area_State, dir: int) -> bool {
	t := &ui.tree
	b := s.caret.block
	row := block_str(s.doc, b)
	cells := table_cells(row)
	i := table_cell_at(row, s.caret.off) + dir
	if i >= 0 && i < len(cells) {
		area_move(t, n, s, {b, cells[i][0]}, false)
		s.anchor = {b, cells[i][1]} // the cell's text selected, so typing replaces it
		mark_paint_dirty(t, n)
		return true
	}
	nb := b + dir
	if nb >= 0 && nb < len(s.doc.blocks) && block_meta(s.doc, nb).kind == .Table {
		nrow := block_str(s.doc, nb)
		ncells := table_cells(nrow)
		j := 0 if dir > 0 else len(ncells) - 1
		if len(ncells) > 0 {
			area_move(t, n, s, {nb, ncells[j][0]}, false)
			s.anchor = {nb, ncells[j][1]}
			mark_paint_dirty(t, n)
		}
		return true
	}
	if dir > 0 {
		table_add_row(ui, n, s, b)
		return true
	}
	return true
}

// table_add_row inserts an empty row under block `b` and puts the caret in its first cell.
@(private)
table_add_row :: proc(ui: ^Ui($Msg), n: Node, s: ^Text_Area_State, b: int) {
	row := block_str(s.doc, b)
	ncells := len(table_cells(row))
	end := Pos{b, len(row)}
	s.group += 1
	ins := strings.concatenate({"\n", table_empty_row(ncells)}, context.temp_allocator)
	document_replace(s.doc, end, end, ins, s.group)
	document_set_meta(s.doc, b + 1, {kind = .Table}, s.group)
	s.anchor, s.caret = {b + 1, 2}, {b + 1, 2}
	rich_changed(ui, n, s)
}

// table_group_of is the run of table rows around block `b` in the document.
@(private)
table_group_of :: proc(s: ^Text_Area_State, b: int) -> (first, last: int) {
	first, last = b, b
	for first > 0 && block_meta(s.doc, first - 1).kind == .Table do first -= 1
	for last + 1 < len(s.doc.blocks) && block_meta(s.doc, last + 1).kind == .Table do last += 1
	return
}

// table_leave puts the caret in a paragraph after the table: an empty last
// row becomes that paragraph, otherwise one is added after the last row.
@(private)
table_leave :: proc(ui: ^Ui($Msg), n: Node, s: ^Text_Area_State, b: int) {
	_, last := table_group_of(s, b)
	s.group += 1
	if b == last && table_row_empty(block_str(s.doc, b)) {
		document_replace(s.doc, {b, 0}, {b, len(s.doc.blocks[b].text)}, "", s.group)
		document_set_meta(s.doc, b, {kind = .Paragraph}, s.group)
		s.anchor, s.caret = {b, 0}, {b, 0}
	} else {
		end := Pos{last, len(s.doc.blocks[last].text)}
		p := document_replace(s.doc, end, end, "\n", s.group)
		document_set_meta(s.doc, last + 1, {kind = .Paragraph}, s.group)
		s.anchor, s.caret = p, p
	}
	rich_changed(ui, n, s)
}
